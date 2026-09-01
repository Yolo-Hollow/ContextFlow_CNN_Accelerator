"""Aggregate deterministic r5 Ethernet timing-only performance runs."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import statistics
from typing import Any, Sequence

from .assets import sha256_file, write_json_atomic
from .net_protocol import EXTENDED_TIMING_BYTES, ExtendedTiming


FORMAT = "kv260-coco80-ethernet-performance"
VERSION = 1
LAYER_NAMES = (
    "m0", "m2", "m4", "m6", "m8", "m10", "m13", "m14", "m15",
    "m16", "m19", "p4_detect", "p5_detect",
)
A53_NAMES = (
    "pool1", "pool3", "pool5", "pool7", "pool9", "pool12",
    "upsample17", "requant_concat18", "p5_copy", "reserved",
)


class PerformanceError(RuntimeError):
    """Performance evidence is incomplete or internally inconsistent."""


def _json(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise PerformanceError(f"{label} is not a regular file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PerformanceError(f"cannot parse {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise PerformanceError(f"{label} must contain one object")
    return value


def _percentile(sorted_values: list[float], q: float) -> float:
    if not sorted_values:
        raise PerformanceError("cannot summarize an empty timing series")
    position = (len(sorted_values) - 1) * q
    low = math.floor(position); high = math.ceil(position)
    if low == high:
        return sorted_values[low]
    return sorted_values[low] + (sorted_values[high] - sorted_values[low]) * (position - low)


def _stats(values: list[float]) -> dict[str, float]:
    ordered = sorted(values)
    return {
        "min": ordered[0], "mean": statistics.fmean(ordered),
        "p50": _percentile(ordered, 0.50), "p90": _percentile(ordered, 0.90),
        "p95": _percentile(ordered, 0.95), "p99": _percentile(ordered, 0.99),
        "max": ordered[-1],
    }


def _us(ticks: int, tick_hz: int) -> float:
    return ticks * 1_000_000.0 / tick_hz


def run_performance(args: argparse.Namespace) -> dict[str, Any]:
    if len(args.run_dir) != args.expected_runs or args.expected_timed <= 0 or args.warmup < 0:
        raise PerformanceError("run count/timed/warmup arguments are invalid")
    all_timed: list[ExtendedTiming] = []
    run_meta: list[dict[str, Any]] = []
    reference_crc: list[int] | None = None
    binding: str | None = None
    first_record: int | None = None
    for run_number, raw_dir in enumerate(args.run_dir, 1):
        directory = Path(raw_dir).resolve()
        summary_path = directory / "summary.json"
        summary = _json(summary_path, f"run {run_number} summary")
        if (
            summary.get("format") != "kv260-coco80-ethernet-validation"
            or summary.get("status") != "PASS" or summary.get("mode") != "timing-demo"
            or summary.get("record_count") != args.warmup + args.expected_timed
            or summary.get("warmup_records") != args.warmup
        ):
            raise PerformanceError(f"run {run_number} is not the expected timing-demo contract")
        if binding is None:
            binding = summary.get("binding_sha256")
            first_record = summary.get("first_record")
        elif summary.get("binding_sha256") != binding or summary.get("first_record") != first_record:
            raise PerformanceError("performance runs use different artifacts/input selection")
        timing_path = directory / "extended_timing.bin"
        expected_records = args.warmup + args.expected_timed
        if timing_path.stat().st_size != expected_records * EXTENDED_TIMING_BYTES:
            raise PerformanceError(f"run {run_number} timing file has the wrong size")
        raw = timing_path.read_bytes()
        timings = [
            ExtendedTiming.unpack(raw[index:index + EXTENDED_TIMING_BYTES])
            for index in range(0, len(raw), EXTENDED_TIMING_BYTES)
        ]
        for index, timing in enumerate(timings):
            if timing.output_kind != 2 or timing.decode_profile != 1 or timing.pl_dispatches != 13:
                raise PerformanceError(f"run {run_number} timing {index} has the wrong profile/counters")
        crcs = [timing.output_crc32 for timing in timings]
        if reference_crc is None:
            reference_crc = crcs
        elif crcs != reference_crc:
            mismatch = next(index for index, pair in enumerate(zip(crcs, reference_crc)) if pair[0] != pair[1])
            raise PerformanceError(f"output CRC is nondeterministic at record {mismatch}, run {run_number}")
        timed = timings[args.warmup:]
        all_timed.extend(timed)
        chunks = summary.get("chunks")
        if not isinstance(chunks, list):
            raise PerformanceError(f"run {run_number} lacks chunk timing records")
        timed_first = int(summary["first_record"]) + args.warmup
        timed_chunks = [chunk for chunk in chunks if int(chunk["first_record"]) >= timed_first]
        if sum(int(chunk["record_count"]) for chunk in timed_chunks) != args.expected_timed:
            raise PerformanceError(f"run {run_number} chunk boundaries do not isolate warmup")
        pipeline_seconds = sum(float(chunk["host_wall_seconds"]) for chunk in timed_chunks)
        run_meta.append({
            "run": run_number, "directory": str(directory),
            "summary_sha256": sha256_file(summary_path),
            "timing_sha256": sha256_file(timing_path),
            "timed_records": len(timed), "timed_pipeline_seconds": pipeline_seconds,
            "timed_pipeline_fps": args.expected_timed / pipeline_seconds,
        })
    if len(all_timed) != args.expected_runs * args.expected_timed:
        raise PerformanceError("combined timed record count is incomplete")
    tick_hz = {item.tick_hz for item in all_timed}
    if len(tick_hz) != 1:
        raise PerformanceError("timing records use multiple clock frequencies")
    stream_configs = {item.stream_config for item in all_timed}
    if len(stream_configs) != 1:
        raise PerformanceError("timing records use multiple STREAM_CFG values")

    def field(name: str) -> list[float]:
        return [_us(int(getattr(item, name)), item.tick_hz) for item in all_timed]

    summary: dict[str, Any] = {
        "format": FORMAT, "version": VERSION, "status": "PASS",
        "runs": args.expected_runs, "warmup_per_run": args.warmup,
        "timed_per_run": args.expected_timed, "timed_total": len(all_timed),
        "binding_sha256": binding, "tick_hz": next(iter(tick_hz)),
        "stream_config": f"0x{next(iter(stream_configs)):02X}",
        "latency_us": {
            "resident_total": _stats(field("total_ticks")),
            "pl_total": _stats(field("pl_ticks")),
            "a53_total_including_decode": _stats(field("a53_ticks")),
            "decode_total": _stats(field("decode_ticks")),
            "candidate": _stats(field("candidate_ticks")),
            "sort": _stats(field("sort_ticks")),
            "nms": _stats(field("nms_ticks")),
            "pl_layers": {
                name: _stats([_us(item.pl_layer_ticks[index], item.tick_hz) for item in all_timed])
                for index, name in enumerate(LAYER_NAMES)
            },
            "a53_ops": {
                name: _stats([_us(item.a53_op_ticks[index], item.tick_hz) for item in all_timed])
                for index, name in enumerate(A53_NAMES)
            },
        },
        "resident_fps_from_mean": 1_000_000.0 / statistics.fmean(field("total_ticks")),
        "pipeline": {
            "runs": run_meta,
            "combined_seconds": sum(item["timed_pipeline_seconds"] for item in run_meta),
        },
        "determinism": {
            "records_compared_per_run": len(reference_crc or []),
            "output_crc_mismatches": 0,
            "output_crc_sequence_sha256": __import__("hashlib").sha256(
                b"".join(int(value).to_bytes(4, "little") for value in (reference_crc or []))
            ).hexdigest(),
        },
    }
    telemetry_fields = tuple(item for item in vars(all_timed[0].layer_telemetry[0]) if item)
    summary["pl_layer_telemetry"] = {}
    for layer_index, layer_name in enumerate(LAYER_NAMES):
        rows = [item.layer_telemetry[layer_index] for item in all_timed]
        layer_summary: dict[str, Any] = {
            name: _stats([float(getattr(row, name)) for row in rows])
            for name in telemetry_fields
        }
        layer_summary["compute_fire_per_stage_cycle"] = _stats([
            row.compute_fire / row.stage_compute_cycles
            if row.stage_compute_cycles else 0.0 for row in rows
        ])
        summary["pl_layer_telemetry"][layer_name] = layer_summary
    summary["pipeline"]["combined_fps"] = len(all_timed) / summary["pipeline"]["combined_seconds"]
    output = Path(args.output_dir).resolve()
    if output.exists():
        raise PerformanceError(f"refusing to overwrite output directory: {output}")
    output.mkdir(parents=True)
    write_json_atomic(output / "summary.json", summary)
    return summary


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", action="append", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--expected-runs", type=int, default=3)
    parser.add_argument("--warmup", type=int, default=20)
    parser.add_argument("--expected-timed", type=int, default=1000)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        summary = run_performance(args)
    except (PerformanceError, OSError, ValueError) as exc:
        print(f"FAIL: {exc}")
        return 1
    print(json.dumps({
        "status": summary["status"], "timed": summary["timed_total"],
        "resident_p50_us": summary["latency_us"]["resident_total"]["p50"],
        "pipeline_fps": summary["pipeline"]["combined_fps"],
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

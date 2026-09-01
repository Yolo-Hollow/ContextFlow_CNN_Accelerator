"""Parse and aggregate fixed-address A53 CPU baseline result records."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
import struct
from pathlib import Path


MAGIC = 0x42433843
HEADER = struct.Struct("<IIIIQ11I")
RESULT_BYTES = 1216
GOPS_PER_IMAGE = 5.565
LAYER_NAMES = (
    "m0", "m2", "m4", "m6", "m8", "m10", "m13", "m14", "m15",
    "m16", "m19", "p4_detect", "p5_detect",
)


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _stats(values: list[float]) -> dict[str, float]:
    ordered = sorted(values)
    def percentile(q: float) -> float:
        if len(ordered) == 1:
            return ordered[0]
        position = (len(ordered) - 1) * q
        lower = math.floor(position); upper = math.ceil(position)
        if lower == upper:
            return ordered[lower]
        return ordered[lower] * (upper - position) + ordered[upper] * (position - lower)
    return {
        "min_ms": ordered[0], "mean_ms": statistics.fmean(ordered),
        "p50_ms": percentile(0.50), "p90_ms": percentile(0.90),
        "p95_ms": percentile(0.95), "p99_ms": percentile(0.99),
        "max_ms": ordered[-1],
    }


def parse_result(path: Path) -> dict:
    raw = path.read_bytes()
    if len(raw) < RESULT_BYTES:
        raise ValueError(f"{path}: result is shorter than {RESULT_BYTES} bytes")
    fields = HEADER.unpack_from(raw)
    (magic, version, status_u32, mode, tick_hz, warmups, timed, image_id,
     detections, param_crc, input_crc, expected_crc, actual_crc, mismatches,
     first_mismatch, _reserved) = fields
    status = struct.unpack("<i", struct.pack("<I", status_u32))[0]
    if magic != MAGIC or version != 1 or status != 2 or mode not in (1, 4):
        raise ValueError(f"{path}: failed/unsupported result header")
    if timed < 1 or timed > 8 or mismatches != 0 or expected_crc != actual_crc:
        raise ValueError(f"{path}: correctness/timed-run gate failed")
    offset = 72
    arrays = []
    for _ in range(4):
        arrays.append(struct.unpack_from("<8Q", raw, offset))
        offset += 64
    layer_rows = []
    for sample in range(8):
        layer_rows.append(struct.unpack_from("<13Q", raw, offset + sample * 13 * 8))
    scale = 1000.0 / tick_hz
    total = [value * scale for value in arrays[0][:timed]]
    conv = [value * scale for value in arrays[1][:timed]]
    tensor = [value * scale for value in arrays[2][:timed]]
    decode = [value * scale for value in arrays[3][:timed]]
    layers = {
        name: [layer_rows[sample][index] * scale for sample in range(timed)]
        for index, name in enumerate(LAYER_NAMES)
    }
    return {
        "path": str(path.resolve()), "bytes": path.stat().st_size,
        "sha256": _sha(path), "mode": "scalar1" if mode == 1 else "neon4",
        "tick_hz": tick_hz, "warmup_runs": warmups, "timed_runs": timed,
        "image_id": image_id, "detection_count": detections,
        "correctness": {"mismatch_bytes": mismatches, "first_mismatch_offset": first_mismatch,
                        "parameter_crc32": param_crc, "input_crc32": input_crc,
                        "expected_heads_crc32": expected_crc, "actual_heads_crc32": actual_crc},
        "samples_ms": {"resident": total, "conv": conv, "tensor": tensor, "decode": decode,
                       "layers": layers},
    }


def aggregate(paths: list[Path], mode: str) -> dict:
    parsed = [parse_result(path) for path in paths]
    if not parsed or any(item["mode"] != mode for item in parsed):
        raise ValueError(f"all results must have mode {mode}")
    for key in ("image_id", "detection_count", "tick_hz"):
        if len({item[key] for item in parsed}) != 1:
            raise ValueError(f"{mode}: inconsistent {key}")
    if any(item["correctness"]["mismatch_bytes"] != 0 for item in parsed):
        raise ValueError(f"{mode}: byte mismatch")
    def collect(name: str) -> list[float]:
        return [value for item in parsed for value in item["samples_ms"][name]]
    resident = collect("resident")
    result = {
        "mode": mode, "repetitions": len(parsed), "timed_samples": len(resident),
        "image_id": parsed[0]["image_id"], "detection_count": parsed[0]["detection_count"],
        "correctness": "BYTE_EXACT", "records": parsed,
        "resident": _stats(resident), "conv": _stats(collect("conv")),
        "tensor": _stats(collect("tensor")), "decode": _stats(collect("decode")),
        "effective_gops": GOPS_PER_IMAGE / (statistics.fmean(resident) / 1000.0),
        "layers": {},
    }
    for name in LAYER_NAMES:
        values = [v for item in parsed for v in item["samples_ms"]["layers"][name]]
        result["layers"][name] = _stats(values)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scalar", type=Path, action="append", required=True)
    parser.add_argument("--neon4", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    scalar = aggregate(args.scalar, "scalar1")
    neon = aggregate(args.neon4, "neon4")
    summary = {
        "format": "kv260-coco80-a53-cpu-baseline-results", "version": 1,
        "workload": {"model": "YOLOv3-tiny COCO80 INT8", "input": "1x416x416",
                     "gops_per_image": GOPS_PER_IMAGE, "parameters_resident": True,
                     "io_excluded": ["JTAG", "SD", "TCP", "UART"]},
        "scalar1": scalar, "neon4": neon,
        "speedup": {
            "resident_mean": scalar["resident"]["mean_ms"] / neon["resident"]["mean_ms"],
            "conv_mean": scalar["conv"]["mean_ms"] / neon["conv"]["mean_ms"],
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({
        "output": str(args.output.resolve()),
        "scalar_mean_ms": scalar["resident"]["mean_ms"],
        "neon4_mean_ms": neon["resident"]["mean_ms"],
        "speedup": summary["speedup"]["resident_mean"],
    }, sort_keys=True))


if __name__ == "__main__":
    main()

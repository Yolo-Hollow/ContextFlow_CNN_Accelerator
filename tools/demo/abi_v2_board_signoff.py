#!/usr/bin/env python3
"""Validate ABI-v2 warm-up plus configurable-run KV260 timing signoff logs."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from pathlib import Path
from typing import Any


TOTAL_PREFIX = "ABI_V2_TOTAL "
TIMING_PREFIX = "ABI_V2_TIMING "
RUN_BEGIN_PREFIX = "ABI_V2_RUN_BEGIN "
RUN_END_PREFIX = "ABI_V2_RUN_END "
PASS_RECORD = "PASS: ABI v2 ten-layer four-DMA dispatch complete"
INTEGER_RE = re.compile(r"^[+-]?(?:0[xX][0-9a-fA-F]+|[0-9]+)$")

EXACT_TOTALS = {
    "contexts": 29_253,
    "compute_fire": 3_889_197,
    "ifm_bytes": 2_249_728,
    "ofm_bytes": 1_734_616,
    "ofm_beats": 216_827,
    "dma_bias": 10,
    "dma_weight": 10,
    "dma_ifm": 10,
    "dma_ofm": 10,
    "errors": 0,
}

MAX_TOTALS = {
    "feeder": 2_000_000,
    "context_psum_gap": 300_000,
    "drain_ofm": 600_000,
    "bias_weight": 200_000,
    "unclassified": 10_000,
}


class SignoffError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_fields(line: str, prefix: str) -> dict[str, int | str]:
    fields: dict[str, int | str] = {}
    for token in line[len(prefix) :].split():
        if "=" not in token:
            raise SignoffError(f"malformed token in {prefix.strip()}: {token!r}")
        key, value = token.split("=", 1)
        if not key or key in fields:
            raise SignoffError(f"invalid or duplicate field {key!r}")
        fields[key] = int(value, 0) if INTEGER_RE.fullmatch(value) else value
    return fields


def parse_logs(paths: list[Path]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    pending: dict[str, Any] | None = None

    def expected_record_type() -> str:
        return (
            "ABI_V2_RUN_BEGIN"
            if pending is None
            else {
                "begin": "ABI_V2_TOTAL",
                "total": "ABI_V2_TIMING",
                "timing": "PASS",
                "pass": "ABI_V2_RUN_END",
            }[pending["phase"]]
        )

    def unexpected(record_type: str) -> SignoffError:
        return SignoffError(
            f"unexpected {record_type}; expected {expected_record_type()}"
        )

    for path in paths:
        if not path.is_file():
            raise SignoffError(f"board log not found: {path}")
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if line.startswith(RUN_BEGIN_PREFIX):
                if pending is not None:
                    raise unexpected("ABI_V2_RUN_BEGIN")
                pending = {
                    "phase": "begin",
                    "begin": parse_fields(line, RUN_BEGIN_PREFIX),
                }
            elif line.startswith(TOTAL_PREFIX):
                if pending is None or pending["phase"] != "begin":
                    raise unexpected("ABI_V2_TOTAL")
                pending["total"] = parse_fields(line, TOTAL_PREFIX)
                pending["phase"] = "total"
            elif line.startswith(TIMING_PREFIX):
                if pending is None or pending["phase"] != "total":
                    raise unexpected("ABI_V2_TIMING")
                pending["timing"] = parse_fields(line, TIMING_PREFIX)
                pending["phase"] = "timing"
            elif line.startswith(RUN_END_PREFIX):
                if pending is None or pending["phase"] != "pass":
                    raise unexpected("ABI_V2_RUN_END")
                marker = parse_fields(line, RUN_END_PREFIX)
                begin = pending["begin"]
                if marker != begin:
                    raise SignoffError(
                        f"run marker pair mismatch: begin={begin!r} end={marker!r}"
                    )
                index = len(records)
                if marker.get("index") != index or marker.get("warmup") != int(
                    index == 0
                ):
                    raise SignoffError(
                        f"invalid run marker at record {index}: {marker!r}"
                    )
                records.append(
                    {
                        "total": pending["total"],
                        "timing": pending["timing"],
                        "marker": marker,
                    }
                )
                pending = None
            elif line == PASS_RECORD:
                if pending is None or pending["phase"] != "timing":
                    raise unexpected("PASS")
                pending["phase"] = "pass"
    if pending is not None:
        raise SignoffError(
            f"incomplete result record after {pending['phase']}; "
            f"expected {expected_record_type()}"
        )
    return records


def require_integer(fields: dict[str, int | str], key: str) -> int:
    value = fields.get(key)
    if not isinstance(value, int):
        raise SignoffError(f"missing integer field {key!r}")
    return value


def validate_record(
    record: dict[str, Any],
    index: int,
    enforce_wall_timing: bool,
    expected_clock_hz: int,
    max_us: int,
    max_busy_cycles: int,
    max_busy_us: int,
    max_unhidden_us: int,
) -> None:
    total = record["total"]
    timing = record["timing"]
    for key, expected in EXACT_TOTALS.items():
        actual = require_integer(total, key)
        if actual != expected:
            raise SignoffError(
                f"run {index} {key}={actual}, expected {expected}"
            )
    for key, maximum in MAX_TOTALS.items():
        actual = require_integer(total, key)
        if actual > maximum:
            raise SignoffError(
                f"run {index} {key}={actual}, maximum {maximum}"
            )
    busy_cycles = require_integer(total, "busy")
    if busy_cycles > max_busy_cycles:
        raise SignoffError(
            f"run {index} busy={busy_cycles}, maximum {max_busy_cycles} cycles"
        )
    if timing.get("mode") != "performance":
        raise SignoffError(f"run {index} is not a performance-mode record")
    clock_hz = timing.get("clock_hz")
    if clock_hz is None and expected_clock_hz == 100_000_000:
        clock_hz = 100_000_000
    if clock_hz != expected_clock_hz:
        raise SignoffError(
            f"run {index} clock_hz={clock_hz!r}, expected {expected_clock_hz}"
        )
    if require_integer(timing, "ifm_pack_us") != 0 or require_integer(
        timing, "ofm_parse_us"
    ) != 0:
        raise SignoffError(f"run {index} performed timed IFM pack/OFM parse")
    total_us = require_integer(timing, "total_us")
    pl_busy_us = require_integer(timing, "pl_busy_us")
    unhidden_us = require_integer(timing, "unhidden_us")
    require_integer(timing, "final_cache_us")
    expected_busy_us = (
        busy_cycles * 1_000_000 + expected_clock_hz - 1
    ) // expected_clock_hz
    expected_unhidden_us = max(total_us - expected_busy_us, 0)
    if pl_busy_us != expected_busy_us or unhidden_us != expected_unhidden_us:
        raise SignoffError(
            f"run {index} inconsistent wall/PL timing decomposition"
        )
    if enforce_wall_timing and total_us >= max_us:
        raise SignoffError(f"run {index} total_us={total_us}, must be <{max_us}")
    if pl_busy_us > max_busy_us:
        raise SignoffError(
            f"run {index} pl_busy_us={pl_busy_us}, maximum {max_busy_us}"
        )
    if enforce_wall_timing and unhidden_us > max_unhidden_us:
        raise SignoffError(
            f"run {index} unhidden_us={unhidden_us}, maximum {max_unhidden_us}"
        )


def nearest_rank_p95(samples: list[int]) -> tuple[int, int]:
    if not samples:
        raise SignoffError("cannot calculate p95 from an empty sample set")
    ordered = sorted(samples)
    rank = math.ceil(0.95 * len(ordered))
    return rank, ordered[rank - 1]


def validate_signoff(
    paths: list[Path],
    expected_runs: int = 30,
    max_us_exclusive: int = 100_000,
    p95_us_exclusive: int = 90_000,
    max_busy_cycles: int = 7_000_000,
    max_busy_us: int = 70_000,
    max_unhidden_us: int = 15_000,
    expected_clock_hz: int = 100_000_000,
) -> dict[str, Any]:
    records = parse_logs(paths)
    expected_records = expected_runs + 1
    if len(records) != expected_records:
        raise SignoffError(
            f"expected one warm-up plus {expected_runs} timed runs, "
            f"found {len(records)} records"
        )
    samples = [
        require_integer(record["timing"], "total_us") for record in records[1:]
    ]
    ordered = sorted(samples)
    p95_rank, p95_us = nearest_rank_p95(samples)
    maximum_us = ordered[-1]
    if p95_us >= p95_us_exclusive:
        raise SignoffError(
            f"nearest-rank p95={p95_us} us, must be <{p95_us_exclusive} us"
        )
    if maximum_us >= max_us_exclusive:
        raise SignoffError(
            f"maximum={maximum_us} us, must be <{max_us_exclusive} us"
        )
    for index, record in enumerate(records):
        validate_record(
            record,
            index,
            enforce_wall_timing=index != 0,
            expected_clock_hz=expected_clock_hz,
            max_us=max_us_exclusive,
            max_busy_cycles=max_busy_cycles,
            max_busy_us=max_busy_us,
            max_unhidden_us=max_unhidden_us,
        )
    return {
        "schema_version": 1,
        "status": "PASS",
        "warmup_us": require_integer(records[0]["timing"], "total_us"),
        "warmup_record_count": 1,
        "timed_run_count": len(samples),
        "validated_record_count": len(records),
        "exact_totals": dict(EXACT_TOTALS),
        "p95_rank": p95_rank,
        "p95_us": p95_us,
        "maximum_us": maximum_us,
        "minimum_us": ordered[0],
        "samples_us": samples,
        "clock_hz": expected_clock_hz,
        "gates": {
            "expected_runs": expected_runs,
            "max_us_exclusive": max_us_exclusive,
            "p95_us_exclusive": p95_us_exclusive,
            "max_busy_cycles_inclusive": max_busy_cycles,
            "max_busy_us_inclusive": max_busy_us,
            "max_unhidden_us_inclusive": max_unhidden_us,
        },
        "logs": [
            {"path": str(path.resolve()), "sha256": sha256_file(path)}
            for path in paths
        ],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+", type=Path)
    parser.add_argument("--expected-runs", type=int, default=30)
    parser.add_argument("--max-us-exclusive", type=int, default=100_000)
    parser.add_argument("--p95-us-exclusive", type=int, default=90_000)
    parser.add_argument("--max-busy-cycles", type=int, default=7_000_000)
    parser.add_argument("--max-busy-us", type=int, default=70_000)
    parser.add_argument("--max-unhidden-us", type=int, default=15_000)
    parser.add_argument("--expected-clock-hz", type=int, default=100_000_000)
    parser.add_argument("--json-out", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        for name in (
            "expected_runs", "max_us_exclusive", "p95_us_exclusive",
            "max_busy_cycles", "max_busy_us",
            "max_unhidden_us", "expected_clock_hz",
        ):
            if getattr(args, name) <= 0:
                raise SignoffError(f"--{name.replace('_', '-')} must be positive")
        result = validate_signoff(
            args.logs,
            args.expected_runs,
            args.max_us_exclusive,
            args.p95_us_exclusive,
            args.max_busy_cycles,
            args.max_busy_us,
            args.max_unhidden_us,
            args.expected_clock_hz,
        )
    except (OSError, SignoffError) as error:
        print(f"FAIL: ABI v2 board signoff: {error}", file=sys.stderr)
        return 1
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json_out is not None:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(rendered, encoding="utf-8")
    print(
        "PASS: ABI v2 board signoff "
        f"runs={result['timed_run_count']} p95={result['p95_us']} us "
        f"max={result['maximum_us']} us"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

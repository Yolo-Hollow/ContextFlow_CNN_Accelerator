#!/usr/bin/env python3
"""Measure one non-release 125 MHz ABI-v2 warm-up plus 30-run board log."""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path
from typing import Any


DEMO_DIR = Path(__file__).resolve().parent
if str(DEMO_DIR) not in sys.path:
    sys.path.insert(0, str(DEMO_DIR))
import abi_v2_board_signoff as signoff  # noqa: E402


EXPECTED_CLOCK_HZ = 125_000_000
EXPECTED_RUNS = 30
DEVELOPMENT_PROFILE = "abi_v2_frequency_sweep_125"
TARGET_US_EXCLUSIVE = 30_000


class PerformanceMeasurementError(RuntimeError):
    pass


def require_file(path: Path, label: str) -> Path:
    resolved = path.expanduser().resolve()
    if not resolved.is_file():
        raise PerformanceMeasurementError(f"{label} is not a file: {resolved}")
    return resolved


def load_manifest(path: Path) -> dict[str, Any]:
    path = require_file(path, "candidate manifest")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as error:
        raise PerformanceMeasurementError(
            f"cannot read candidate manifest {path}: {error}"
        ) from error
    if not isinstance(value, dict):
        raise PerformanceMeasurementError("candidate manifest root is not an object")
    hardware = value.get("hardware")
    runtime = value.get("runtime")
    software = value.get("software")
    if not all(isinstance(item, dict) for item in (hardware, runtime, software)):
        raise PerformanceMeasurementError(
            "candidate manifest is missing hardware/runtime/software identity"
        )
    expected = {
        "state": "complete",
        "release_eligible": False,
        "hardware.profile": DEVELOPMENT_PROFILE,
        "hardware.clock_hz": EXPECTED_CLOCK_HZ,
        "hardware.release_eligible": False,
        "runtime.clock_hz": EXPECTED_CLOCK_HZ,
        "software.clock_hz": EXPECTED_CLOCK_HZ,
        "software.long_stream_runtime_enabled": 1,
        "software.stream_cfg": 0xBF,
        "software.performance_mode": True,
        "software.benchmark_runs": EXPECTED_RUNS,
        "software.run_mode": "benchmark",
        "software.soak_seconds": 0,
        "software.soak_temp_limit_millic": 0,
    }
    actual = {
        "state": value.get("state"),
        "release_eligible": value.get("release_eligible"),
        "hardware.profile": hardware.get("profile"),
        "hardware.clock_hz": hardware.get("clock_hz"),
        "hardware.release_eligible": hardware.get("release_eligible"),
        "runtime.clock_hz": runtime.get("clock_hz"),
        "software.clock_hz": software.get("clock_hz"),
        "software.long_stream_runtime_enabled": software.get(
            "long_stream_runtime_enabled"
        ),
        "software.stream_cfg": software.get("stream_cfg"),
        "software.performance_mode": software.get("performance_mode"),
        "software.benchmark_runs": software.get("benchmark_runs"),
        "software.run_mode": software.get("run_mode"),
        "software.soak_seconds": software.get("soak_seconds"),
        "software.soak_temp_limit_millic": software.get(
            "soak_temp_limit_millic"
        ),
    }
    mismatches = [
        f"{key}={actual[key]!r}, expected {wanted!r}"
        for key, wanted in expected.items()
        if actual[key] != wanted
    ]
    if mismatches:
        raise PerformanceMeasurementError(
            "manifest is not a non-release 125 MHz performance candidate: "
            + "; ".join(mismatches)
        )
    return value


def distribution(values: list[int]) -> dict[str, int | float | list[int]]:
    if len(values) != EXPECTED_RUNS:
        raise PerformanceMeasurementError(
            f"expected {EXPECTED_RUNS} measured values, found {len(values)}"
        )
    ordered = sorted(values)
    p95_rank, p95 = signoff.nearest_rank_p95(values)
    return {
        "minimum_us": ordered[0],
        "maximum_us": ordered[-1],
        "median_us": statistics.median(ordered),
        "mean_us": round(sum(ordered) / len(ordered), 3),
        "p95_rank": p95_rank,
        "p95_us": p95,
        "samples_us": values,
    }


def validate_performance_measurement(
    log_path: Path, manifest_path: Path
) -> dict[str, Any]:
    log_path = require_file(log_path, "board log")
    manifest_path = require_file(manifest_path, "candidate manifest")
    load_manifest(manifest_path)
    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    for line in log_text.splitlines():
        stripped = line.strip()
        if "FAIL:" in stripped or "mismatch_count=" in stripped:
            raise PerformanceMeasurementError(f"target reported failure: {stripped}")
        if " full compare=" in stripped:
            raise PerformanceMeasurementError(
                "performance log unexpectedly contains timed golden comparisons"
            )
    try:
        records = signoff.parse_logs([log_path])
    except signoff.SignoffError as error:
        raise PerformanceMeasurementError(str(error)) from error
    expected_records = EXPECTED_RUNS + 1
    if len(records) != expected_records:
        raise PerformanceMeasurementError(
            f"expected one warm-up plus {EXPECTED_RUNS} measured runs, "
            f"found {len(records)} records"
        )
    try:
        for index, record in enumerate(records):
            signoff.validate_record(
                record,
                index,
                enforce_wall_timing=False,
                expected_clock_hz=EXPECTED_CLOCK_HZ,
                max_us=1_000_000,
                max_busy_cycles=7_000_000,
                max_busy_us=70_000,
                max_unhidden_us=1_000_000,
            )
    except signoff.SignoffError as error:
        raise PerformanceMeasurementError(str(error)) from error

    timed = records[1:]
    total_values = [
        signoff.require_integer(record["timing"], "total_us") for record in timed
    ]
    busy_values = [
        signoff.require_integer(record["timing"], "pl_busy_us")
        for record in timed
    ]
    unhidden_values = [
        signoff.require_integer(record["timing"], "unhidden_us")
        for record in timed
    ]
    total_stats = distribution(total_values)
    target_met = (
        int(total_stats["maximum_us"]) < TARGET_US_EXCLUSIVE
        and int(total_stats["p95_us"]) < TARGET_US_EXCLUSIVE
    )
    return {
        "schema_version": 1,
        "status": "DEVELOPMENT_PERFORMANCE_MEASURED",
        "release_eligible": False,
        "performance_signoff": False,
        "timing_gate_applied": False,
        "hardware_profile": DEVELOPMENT_PROFILE,
        "clock_hz": EXPECTED_CLOCK_HZ,
        "warmup_record_count": 1,
        "timed_run_count": EXPECTED_RUNS,
        "validated_record_count": len(records),
        "exact_totals": dict(signoff.EXACT_TOTALS),
        "warmup": dict(records[0]["timing"]),
        "timing": {
            "total": total_stats,
            "pl_busy": distribution(busy_values),
            "unhidden": distribution(unhidden_values),
        },
        "target_30ms": {
            "exclusive_us": TARGET_US_EXCLUSIVE,
            "maximum_met": int(total_stats["maximum_us"]) < TARGET_US_EXCLUSIVE,
            "p95_met": int(total_stats["p95_us"]) < TARGET_US_EXCLUSIVE,
            "met": target_met,
        },
        "log": {
            "path": str(log_path),
            "sha256": signoff.sha256_file(log_path),
        },
        "manifest": {
            "path": str(manifest_path),
            "sha256": signoff.sha256_file(manifest_path),
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--artifact-manifest", type=Path, required=True)
    parser.add_argument("--json-out", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        result = validate_performance_measurement(args.log, args.artifact_manifest)
    except (OSError, PerformanceMeasurementError) as error:
        print(
            f"FAIL: ABI v2 125 MHz development performance: {error}",
            file=sys.stderr,
        )
        return 1
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json_out is not None:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(rendered, encoding="utf-8")
    total = result["timing"]["total"]
    print(
        "PASS: ABI v2 125 MHz development performance measured "
        f"runs={result['timed_run_count']} median={total['median_us']} us "
        f"p95={total['p95_us']} us max={total['maximum_us']} us "
        f"target_30ms_met={result['target_30ms']['met']} "
        "(non-release, no performance signoff)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

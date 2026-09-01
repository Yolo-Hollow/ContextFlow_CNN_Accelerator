#!/usr/bin/env python3
"""Parse a Vivado post-route power report into a fail-closed JSON summary."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_kv(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if raw and "=" in raw:
            key, value = raw.split("=", 1)
            values[key] = value
    return values


def table_value(text: str, label: str) -> str:
    match = re.search(
        rf"(?m)^\|\s*{re.escape(label)}\s*\|\s*([^|]+?)\s*\|",
        text,
    )
    if not match:
        raise ValueError(f"missing report row: {label}")
    return match.group(1).strip()


def table_float(text: str, label: str) -> float:
    value = table_value(text, label)
    if value.startswith("<"):
        value = value[1:]
    return float(value)


def header_value(text: str, label: str) -> str:
    match = re.search(
        rf"(?m)^\|\s*{re.escape(label)}\s*:\s*(.*?)\s*$", text
    )
    if not match:
        raise ValueError(f"missing report header: {label}")
    return match.group(1).strip()


def route_count(text: str, label: str) -> int:
    match = re.search(
        rf"(?m)^\s*# of {re.escape(label)}\.*\s*:\s*(\d+)\s*:", text
    )
    if not match:
        raise ValueError(f"missing route-status field: {label}")
    return int(match.group(1))


def hierarchy_power(text: str, name: str) -> float:
    match = re.search(
        rf"(?m)^\|\s+{re.escape(name)}\s+\|\s*([0-9.]+)\s*\|", text
    )
    if not match:
        raise ValueError(f"missing hierarchy power: {name}")
    return float(match.group(1))


def confidence_value(text: str, label: str) -> str:
    match = re.search(
        rf"(?m)^\|\s*{re.escape(label)}\s*\|\s*([^|]+?)\s*\|",
        text,
    )
    if not match:
        raise ValueError(f"missing confidence row: {label}")
    return match.group(1).strip()


def atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    os.replace(temp, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--hierarchy-report", required=True, type=Path)
    parser.add_argument("--route-report", required=True, type=Path)
    parser.add_argument("--assumptions", required=True, type=Path)
    parser.add_argument("--dcp", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--rpx", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    inputs = {
        "report": args.report.resolve(),
        "hierarchy_report": args.hierarchy_report.resolve(),
        "route_report": args.route_report.resolve(),
        "assumptions": args.assumptions.resolve(),
        "dcp": args.dcp.resolve(),
        "vivado_log": args.log.resolve(),
        "rpx": args.rpx.resolve(),
    }
    missing = [str(path) for path in inputs.values() if not path.is_file()]
    if missing:
        raise FileNotFoundError("missing power evidence: " + ", ".join(missing))

    report = inputs["report"].read_text(encoding="utf-8", errors="strict")
    hierarchy = inputs["hierarchy_report"].read_text(
        encoding="utf-8", errors="strict"
    )
    route = inputs["route_report"].read_text(encoding="utf-8", errors="strict")
    log = inputs["vivado_log"].read_text(encoding="utf-8", errors="strict")
    assumptions = read_kv(inputs["assumptions"])

    if "report_power completed successfully" not in log:
        raise ValueError("Vivado log lacks successful report_power completion")
    if "CRITICAL WARNING" in log or re.search(r"(?m)^ERROR:", log):
        raise ValueError("Vivado log contains a critical warning or error")

    routable = route_count(route, "routable nets")
    fully_routed = route_count(route, "fully routed nets")
    route_errors = route_count(route, "nets with routing errors")
    if fully_routed != routable or route_errors != 0:
        raise ValueError("power checkpoint is not fully routed")

    total = table_float(report, "Total On-Chip Power (W)")
    dynamic = table_float(report, "Dynamic (W)")
    static = table_float(report, "Device Static (W)")
    ps8 = table_float(report, "PS8")
    pl_dynamic = dynamic - ps8
    if abs(total - dynamic - static) > 0.002:
        raise ValueError("power summary does not add up")

    payload: dict[str, Any] = {
        "format": "lasa-vivado-post-route-power",
        "version": 1,
        "status": "PASS",
        "measurement": "post_route_estimated",
        "design": {
            "name": header_value(report, "Design"),
            "device": header_value(report, "Device"),
            "state": header_value(report, "Design State"),
            "grade": header_value(report, "Grade"),
            "process": header_value(report, "Process"),
            "characterization": header_value(report, "Characterization"),
        },
        "activity": {
            "source": assumptions["activity_source"],
            "saif": assumptions["saif"],
            "default_toggle_rate_percent": float(
                assumptions["default_toggle_rate_percent"]
            ),
            "default_static_probability": float(
                assumptions["default_static_probability"]
            ),
            "resets": assumptions["resets"],
        },
        "environment": {
            "ambient_temp_c": table_float(report, "Ambient Temp (C)"),
            "junction_temp_c": table_float(report, "Junction Temperature (C)"),
            "effective_tja_c_per_w": table_float(report, "Effective TJA (C/W)"),
            "airflow_lfm": table_float(report, "Airflow (LFM)"),
            "heat_sink": table_value(report, "Heat Sink"),
            "board": table_value(report, "Board Selection"),
        },
        "confidence": {
            "overall": table_value(report, "Confidence Level"),
            "implementation": confidence_value(
                report, "Design implementation state"
            ),
            "clock_activity": confidence_value(report, "Clock nodes activity"),
            "io_activity": confidence_value(report, "I/O nodes activity"),
            "internal_activity": confidence_value(
                report, "Internal nodes activity"
            ),
            "device_models": confidence_value(report, "Device models"),
        },
        "power_w": {
            "total_on_chip": total,
            "dynamic": dynamic,
            "device_static": static,
            "ps8_dynamic": ps8,
            "pl_dynamic": round(pl_dynamic, 3),
            "pl_dynamic_plus_device_static": round(pl_dynamic + static, 3),
            "accelerator_hierarchy_dynamic": hierarchy_power(hierarchy, "accel"),
            "components": {
                "clocks": table_float(report, "Clocks"),
                "clb_logic": table_float(report, "CLB Logic"),
                "signals": table_float(report, "Signals"),
                "block_ram": table_float(report, "Block RAM"),
                "uram": table_float(report, "URAM"),
                "mmcm": table_float(report, "MMCM"),
                "dsps": table_float(report, "DSPs"),
            },
        },
        "route": {
            "routable_nets": routable,
            "fully_routed_nets": fully_routed,
            "routing_errors": route_errors,
        },
        "artifacts": {
            key: {
                "path": str(path),
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
            }
            for key, path in inputs.items()
        },
    }
    atomic_json(args.output.resolve(), payload)
    print(
        json.dumps(
            {
                "status": "PASS",
                "output": str(args.output.resolve()),
                "total_on_chip_w": total,
                "confidence": payload["confidence"]["overall"],
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

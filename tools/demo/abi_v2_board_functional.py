#!/usr/bin/env python3
"""Validate one staged ABI-v2 functional board run."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any, Mapping


TOTAL_PREFIX = "ABI_V2_TOTAL "
TIMING_PREFIX = "ABI_V2_TIMING "
PASS_RECORD = "PASS: ABI v2 ten-layer four-DMA dispatch complete"
INTEGER_RE = re.compile(r"^[+-]?(?:0[xX][0-9a-fA-F]+|[0-9]+)$")
EXPECTED_CLOCK_HZ = 125_000_000
DEVELOPMENT_PROFILE = "abi_v2_frequency_sweep_125"
RELEASE_CLOCK_HZ = 200_000_000
RELEASE_PROFILE = "abi_v2_release_200"
STAGED_STREAM_CONFIGS = (0x2B, 0x3B, 0x3F, 0xBF)

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

EXPECTED_OFM_COMPARES = (
    ("conv0_pool", 692_224),
    ("conv1_pool", 346_112),
    ("conv2_pool", 173_056),
    ("conv3_pool", 86_528),
    ("conv4_pool", 43_264),
    ("conv5", 86_528),
    ("conv6", 173_056),
    ("conv7_native1x1", 43_264),
    ("conv8", 86_528),
    ("conv9_detect_native1x1", 4_056),
)
COMPARE_RE = re.compile(r"^(\S+) full compare=([0-9]+) bytes$")


class FunctionalError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require_file(path: Path, label: str) -> Path:
    resolved = path.expanduser().resolve()
    if not resolved.is_file():
        raise FunctionalError(f"{label} not found: {resolved}")
    return resolved


def require_integer(fields: Mapping[str, int | str], key: str) -> int:
    value = fields.get(key)
    if not isinstance(value, int):
        raise FunctionalError(f"missing integer field {key!r}")
    return value


def parse_fields(line: str, prefix: str) -> dict[str, int | str]:
    fields: dict[str, int | str] = {}
    for token in line[len(prefix) :].split():
        if "=" not in token:
            raise FunctionalError(
                f"malformed token in {prefix.strip()}: {token!r}"
            )
        key, value = token.split("=", 1)
        if not key or key in fields:
            raise FunctionalError(f"invalid or duplicate field {key!r}")
        fields[key] = int(value, 0) if INTEGER_RE.fullmatch(value) else value
    return fields


def identity_for(
    expected_clock_hz: int, expected_stream_cfg: int
) -> dict[str, Any]:
    if expected_clock_hz == EXPECTED_CLOCK_HZ:
        if expected_stream_cfg != 0xBF:
            raise FunctionalError(
                "125 MHz development functional identity requires STREAM_CFG=0xBF"
            )
        return {
            "profile": DEVELOPMENT_PROFILE,
            "release_eligible": False,
            "status": "DEVELOPMENT_FUNCTIONAL_PASS",
            "qualification": "development",
        }
    if expected_clock_hz == RELEASE_CLOCK_HZ:
        if expected_stream_cfg not in STAGED_STREAM_CONFIGS:
            raise FunctionalError(
                "200 MHz release functional identity requires staged "
                "STREAM_CFG=0x2B/0x3B/0x3F/0xBF"
            )
        return {
            "profile": RELEASE_PROFILE,
            "release_eligible": True,
            "status": "RELEASE_FUNCTIONAL_STAGE_PASS",
            "qualification": "release_staged",
        }
    raise FunctionalError(
        f"unsupported functional clock_hz={expected_clock_hz}; "
        f"expected {EXPECTED_CLOCK_HZ} or {RELEASE_CLOCK_HZ}"
    )


def validate_functional_manifest(
    path: Path,
    expected_clock_hz: int = EXPECTED_CLOCK_HZ,
    expected_stream_cfg: int = 0xBF,
) -> dict[str, Any]:
    identity = identity_for(expected_clock_hz, expected_stream_cfg)
    path = require_file(path, "candidate manifest")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FunctionalError(f"invalid candidate manifest: {error}") from error
    if not isinstance(value, dict):
        raise FunctionalError("candidate manifest root must be an object")
    hardware = value.get("hardware")
    runtime = value.get("runtime")
    software = value.get("software")
    if not all(isinstance(section, dict) for section in (hardware, runtime, software)):
        raise FunctionalError("candidate manifest is missing hardware/runtime/software")
    expected = {
        "state": "complete",
        "candidate_profile": "abi_v2_candidate",
        "release_eligible": identity["release_eligible"],
    }
    mismatches = [
        f"{key}={value.get(key)!r}, expected {wanted!r}"
        for key, wanted in expected.items()
        if value.get(key) != wanted
    ]
    hardware_expected = {
        "profile": identity["profile"],
        "clock_hz": expected_clock_hz,
        "release_eligible": identity["release_eligible"],
        "git_dirty": 0,
    }
    mismatches.extend(
        f"hardware.{key}={hardware.get(key)!r}, expected {wanted!r}"
        for key, wanted in hardware_expected.items()
        if hardware.get(key) != wanted
    )
    runtime_expected = {
        "abi_version": 2,
        "rows": 18,
        "cols": 16,
        "cout_tile": 32,
        "clock_hz": expected_clock_hz,
    }
    mismatches.extend(
        f"runtime.{key}={runtime.get(key)!r}, expected {wanted!r}"
        for key, wanted in runtime_expected.items()
        if runtime.get(key) != wanted
    )
    software_expected = {
        "long_stream_runtime_enabled": 1,
        "stream_cfg": expected_stream_cfg,
        "performance_mode": False,
        "benchmark_runs": 0,
        "clock_hz": expected_clock_hz,
        "run_mode": "functional",
        "soak_seconds": 0,
        "soak_temp_limit_millic": 0,
        "git_dirty": 0,
    }
    mismatches.extend(
        f"software.{key}={software.get(key)!r}, expected {wanted!r}"
        for key, wanted in software_expected.items()
        if software.get(key) != wanted
    )
    if mismatches:
        raise FunctionalError(
            "manifest does not match the requested functional identity: "
            + "; ".join(mismatches)
        )
    return value


def parse_log(path: Path) -> dict[str, Any]:
    path = require_file(path, "board log")
    compares: list[tuple[str, int]] = []
    total: dict[str, int | str] | None = None
    timing: dict[str, int | str] | None = None
    pass_seen = False
    for raw_line in path.read_text(
        encoding="utf-8", errors="replace"
    ).splitlines():
        line = raw_line.strip()
        if "FAIL:" in line or "mismatch_count=" in line or " mismatch[" in line:
            raise FunctionalError(f"target reported failure: {line}")
        if line.startswith("ABI_V2_RUN_BEGIN ") or line.startswith(
            "ABI_V2_RUN_END "
        ):
            raise FunctionalError(
                "benchmark run markers are forbidden in a functional board log"
            )
        compare_match = COMPARE_RE.fullmatch(line)
        if compare_match:
            if total is not None or timing is not None or pass_seen:
                raise FunctionalError("OFM compare appeared after aggregate records")
            compares.append((compare_match.group(1), int(compare_match.group(2))))
            continue
        if line.startswith(TOTAL_PREFIX):
            if total is not None or timing is not None or pass_seen:
                raise FunctionalError("duplicate or out-of-order ABI_V2_TOTAL")
            if tuple(compares) != EXPECTED_OFM_COMPARES:
                raise FunctionalError(
                    f"OFM golden compare sequence is {tuple(compares)!r}, "
                    f"expected {EXPECTED_OFM_COMPARES!r}"
                )
            total = parse_fields(line, TOTAL_PREFIX)
            continue
        if line.startswith(TIMING_PREFIX):
            if total is None or timing is not None or pass_seen:
                raise FunctionalError("duplicate or out-of-order ABI_V2_TIMING")
            timing = parse_fields(line, TIMING_PREFIX)
            continue
        if line == PASS_RECORD:
            if total is None or timing is None or pass_seen:
                raise FunctionalError("duplicate or out-of-order functional PASS")
            pass_seen = True
    if tuple(compares) != EXPECTED_OFM_COMPARES:
        raise FunctionalError(
            f"OFM golden compare sequence is {tuple(compares)!r}, "
            f"expected {EXPECTED_OFM_COMPARES!r}"
        )
    if total is None or timing is None or not pass_seen:
        raise FunctionalError("functional aggregate/timing/PASS record is incomplete")
    return {"total": total, "timing": timing}


def validate_functional(
    log_path: Path,
    manifest_path: Path,
    expected_clock_hz: int = EXPECTED_CLOCK_HZ,
    expected_stream_cfg: int = 0xBF,
) -> dict[str, Any]:
    identity = identity_for(expected_clock_hz, expected_stream_cfg)
    manifest_path = require_file(manifest_path, "candidate manifest")
    log_path = require_file(log_path, "board log")
    validate_functional_manifest(
        manifest_path, expected_clock_hz, expected_stream_cfg
    )
    record = parse_log(log_path)
    total = record["total"]
    timing = record["timing"]
    for key, wanted in EXACT_TOTALS.items():
        actual = require_integer(total, key)
        if actual != wanted:
            raise FunctionalError(f"{key}={actual}, expected {wanted}")
    for key in (
        "busy",
        "feeder",
        "context_psum_gap",
        "drain_ofm",
        "bias_weight",
        "unclassified",
    ):
        if require_integer(total, key) < 0:
            raise FunctionalError(f"{key} must be non-negative")
    if timing.get("mode") != "functional":
        raise FunctionalError(f"timing mode={timing.get('mode')!r}, expected functional")
    if require_integer(timing, "clock_hz") != expected_clock_hz:
        raise FunctionalError(
            f"clock_hz={timing.get('clock_hz')!r}, expected {expected_clock_hz}"
        )
    if require_integer(timing, "ifm_pack_us") != 0 or require_integer(
        timing, "ofm_parse_us"
    ) != 0:
        raise FunctionalError("functional run performed IFM pack or OFM parse")
    total_us = require_integer(timing, "total_us")
    pl_busy_us = require_integer(timing, "pl_busy_us")
    unhidden_us = require_integer(timing, "unhidden_us")
    final_cache_us = require_integer(timing, "final_cache_us")
    if min(total_us, pl_busy_us, unhidden_us, final_cache_us) < 0:
        raise FunctionalError("timing values must be non-negative")
    busy_cycles = require_integer(total, "busy")
    expected_busy_us = (
        busy_cycles * 1_000_000 + expected_clock_hz - 1
    ) // expected_clock_hz
    expected_unhidden_us = max(total_us - expected_busy_us, 0)
    if pl_busy_us != expected_busy_us or unhidden_us != expected_unhidden_us:
        raise FunctionalError("wall/PL timing decomposition is inconsistent")
    return {
        "schema_version": 1,
        "status": identity["status"],
        "release_eligible": identity["release_eligible"],
        "performance_signoff": False,
        "timing_gate_applied": False,
        "qualification": identity["qualification"],
        "hardware_profile": identity["profile"],
        "clock_hz": expected_clock_hz,
        "stream_cfg": expected_stream_cfg,
        "final_stream_cfg": expected_stream_cfg == 0xBF,
        "exact_totals": dict(EXACT_TOTALS),
        "ofm_golden_compares": [
            {"layer": layer, "bytes": size}
            for layer, size in EXPECTED_OFM_COMPARES
        ],
        "timing": dict(timing),
        "log": {"path": str(log_path), "sha256": sha256_file(log_path)},
        "manifest": {
            "path": str(manifest_path),
            "sha256": sha256_file(manifest_path),
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--artifact-manifest", type=Path, required=True)
    parser.add_argument(
        "--expected-clock-hz",
        type=int,
        choices=(EXPECTED_CLOCK_HZ, RELEASE_CLOCK_HZ),
        default=EXPECTED_CLOCK_HZ,
    )
    parser.add_argument(
        "--expected-stream-cfg",
        type=lambda value: int(value, 0),
        choices=STAGED_STREAM_CONFIGS,
        default=0xBF,
    )
    parser.add_argument("--json-out", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        result = validate_functional(
            args.log,
            args.artifact_manifest,
            args.expected_clock_hz,
            args.expected_stream_cfg,
        )
    except (OSError, FunctionalError) as error:
        print(f"FAIL: ABI v2 staged functional: {error}", file=sys.stderr)
        return 1
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json_out is not None:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(rendered, encoding="utf-8")
    print(
        "PASS: ABI v2 staged functional "
        f"clock_hz={args.expected_clock_hz} "
        f"stream_cfg=0x{args.expected_stream_cfg:02x} "
        "(no performance signoff)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

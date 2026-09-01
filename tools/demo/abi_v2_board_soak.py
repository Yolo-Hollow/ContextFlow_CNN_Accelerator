#!/usr/bin/env python3
"""Validate the fail-closed ABI-v2 KV260 ten-minute soak UART contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


BEGIN_PREFIX = "ABI_V2_SOAK_BEGIN "
PROGRESS_PREFIX = "ABI_V2_SOAK_PROGRESS "
END_PREFIX = "ABI_V2_SOAK_END "
PASS_RECORD = "PASS: ABI v2 soak complete"
INTEGER_RE = re.compile(r"^[+-]?(?:0[xX][0-9a-fA-F]+|[0-9]+)$")


class SoakError(RuntimeError):
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
            raise SoakError(f"malformed token in {prefix.strip()}: {token!r}")
        key, value = token.split("=", 1)
        if not key or key in fields:
            raise SoakError(f"invalid or duplicate field {key!r}")
        fields[key] = int(value, 0) if INTEGER_RE.fullmatch(value) else value
    return fields


def require_integer(fields: dict[str, int | str], key: str) -> int:
    value = fields.get(key)
    if not isinstance(value, int):
        raise SoakError(f"missing integer field {key!r}")
    return value


def parse_soak_log(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise SoakError(f"board log not found: {path}")
    begin: dict[str, int | str] | None = None
    progress: list[dict[str, int | str]] = []
    end: dict[str, int | str] | None = None
    passed = False

    for raw_line in path.read_text(
        encoding="utf-8", errors="replace"
    ).splitlines():
        line = raw_line.strip()
        if line.startswith("FAIL:"):
            raise SoakError(f"target reported failure: {line}")
        if line.startswith((
            "ABI_V2_RUN_BEGIN ", "ABI_V2_RUN_END ", "ABI_V2_TOTAL ",
            "ABI_V2_TIMING ",
        )) or line == "PASS: ABI v2 ten-layer four-DMA dispatch complete":
            raise SoakError(f"finite benchmark record found in soak log: {line}")
        if line.startswith(BEGIN_PREFIX):
            if begin is not None or progress or end is not None or passed:
                raise SoakError("duplicate or out-of-order ABI_V2_SOAK_BEGIN")
            begin = parse_fields(line, BEGIN_PREFIX)
        elif line.startswith(PROGRESS_PREFIX):
            if begin is None or end is not None or passed:
                raise SoakError("out-of-order ABI_V2_SOAK_PROGRESS")
            progress.append(parse_fields(line, PROGRESS_PREFIX))
        elif line.startswith(END_PREFIX):
            if begin is None or not progress or end is not None or passed:
                raise SoakError("duplicate or out-of-order ABI_V2_SOAK_END")
            end = parse_fields(line, END_PREFIX)
        elif line == PASS_RECORD:
            if end is None or passed:
                raise SoakError("duplicate or out-of-order soak PASS record")
            passed = True
    if begin is None or not progress or end is None or not passed:
        raise SoakError(
            "incomplete soak record; require BEGIN, progress, END, and PASS"
        )
    return {"begin": begin, "progress": progress, "end": end}


def validate_soak(
    path: Path,
    expected_seconds: int = 600,
    expected_clock_hz: int = 200_000_000,
    temp_limit_millic: int = 85_000,
    max_progress_gap_ms: int = 15_000,
) -> dict[str, Any]:
    record = parse_soak_log(path)
    begin = record["begin"]
    progress = record["progress"]
    end = record["end"]
    if require_integer(begin, "min_seconds") != expected_seconds:
        raise SoakError("soak duration contract does not match the expected ELF")
    progress_seconds = require_integer(begin, "progress_seconds")
    if progress_seconds <= 0:
        raise SoakError("soak progress interval must be positive")
    if require_integer(begin, "temp_limit_millic") != temp_limit_millic:
        raise SoakError("soak temperature contract does not match the manifest")
    temp_min_millic = require_integer(begin, "temp_min_millic")
    if temp_min_millic != -40_000:
        raise SoakError("soak minimum plausible temperature contract changed")
    if require_integer(begin, "clock_hz") != expected_clock_hz:
        raise SoakError("soak clock does not match the manifest")
    if begin.get("sensor") != "ps_onchip":
        raise SoakError(f"unexpected soak temperature sensor: {begin.get('sensor')!r}")

    previous_elapsed = 0
    previous_runs = 0
    observed_max = -2**31
    for index, sample in enumerate(progress, start=1):
        elapsed = require_integer(sample, "elapsed_ms")
        runs = require_integer(sample, "runs")
        temp = require_integer(sample, "temp_millic")
        max_temp = require_integer(sample, "max_temp_millic")
        warnings = require_integer(sample, "thermal_warnings")
        if elapsed <= previous_elapsed or runs <= previous_runs:
            raise SoakError(f"progress {index} is not strictly monotonic")
        if elapsed - previous_elapsed > max_progress_gap_ms:
            raise SoakError(
                f"progress {index} gap={elapsed - previous_elapsed} ms, "
                f"maximum {max_progress_gap_ms} ms"
            )
        if temp < temp_min_millic or max_temp < temp_min_millic:
            raise SoakError(f"progress {index} contains an invalid SysMon sample")
        if temp >= temp_limit_millic or max_temp >= temp_limit_millic:
            raise SoakError(
                f"progress {index} reached {max(temp, max_temp)} mC, "
                f"must be <{temp_limit_millic} mC"
            )
        if warnings != 0:
            raise SoakError(f"progress {index} reported a thermal warning")
        if max_temp < temp or max_temp < observed_max:
            raise SoakError(f"progress {index} maximum temperature regressed")
        previous_elapsed = elapsed
        previous_runs = runs
        observed_max = max_temp

    elapsed_ms = require_integer(end, "elapsed_ms")
    runs = require_integer(end, "runs")
    verified_runs = require_integer(end, "verified_runs")
    max_temp_millic = require_integer(end, "max_temp_millic")
    if elapsed_ms < expected_seconds * 1000:
        raise SoakError(
            f"soak elapsed_ms={elapsed_ms}, expected at least "
            f"{expected_seconds * 1000}"
        )
    if elapsed_ms != previous_elapsed or runs != previous_runs:
        raise SoakError("final soak summary does not match the last progress record")
    if verified_runs != runs or runs <= 0:
        raise SoakError("not every completed dispatch has an exact-counter check")
    if max_temp_millic != observed_max or max_temp_millic >= temp_limit_millic:
        raise SoakError("final soak maximum temperature is invalid")
    for key in (
        "thermal_warnings", "dma_errors", "counter_errors", "timeouts"
    ):
        if require_integer(end, key) != 0:
            raise SoakError(f"soak summary {key} is nonzero")
    if require_integer(end, "clock_hz") != expected_clock_hz:
        raise SoakError("final soak clock does not match the manifest")
    return {
        "schema_version": 1,
        "status": "PASS",
        "elapsed_ms": elapsed_ms,
        "minimum_seconds": expected_seconds,
        "runs": runs,
        "verified_runs": verified_runs,
        "progress_record_count": len(progress),
        "progress_seconds": progress_seconds,
        "max_progress_gap_ms": max_progress_gap_ms,
        "clock_hz": expected_clock_hz,
        "temperature_sensor": "ps_onchip",
        "temperature_limit_millic_exclusive": temp_limit_millic,
        "temperature_min_millic_inclusive": temp_min_millic,
        "max_temp_millic": max_temp_millic,
        "thermal_warnings": 0,
        "dma_errors": 0,
        "counter_errors": 0,
        "timeouts": 0,
        "log": {
            "path": str(path.resolve()),
            "sha256": sha256_file(path),
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--expected-seconds", type=int, default=600)
    parser.add_argument("--expected-clock-hz", type=int, default=200_000_000)
    parser.add_argument("--temp-limit-millic", type=int, default=85_000)
    parser.add_argument("--max-progress-gap-ms", type=int, default=15_000)
    parser.add_argument("--json-out", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        for name in (
            "expected_seconds", "expected_clock_hz", "temp_limit_millic",
            "max_progress_gap_ms",
        ):
            if getattr(args, name) <= 0:
                raise SoakError(f"--{name.replace('_', '-')} must be positive")
        if args.expected_seconds < 600:
            raise SoakError("--expected-seconds must be at least 600")
        result = validate_soak(
            args.log,
            args.expected_seconds,
            args.expected_clock_hz,
            args.temp_limit_millic,
            args.max_progress_gap_ms,
        )
    except (OSError, SoakError) as error:
        print(f"FAIL: ABI v2 board soak: {error}", file=sys.stderr)
        return 1
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json_out is not None:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(rendered, encoding="utf-8")
    print(
        "PASS: ABI v2 board soak "
        f"elapsed={result['elapsed_ms']} ms runs={result['runs']} "
        f"max_temp={result['max_temp_millic']} mC"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

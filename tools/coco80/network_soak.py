"""Run a fail-closed 600-second Ethernet soak over a fixed 128-image set."""

from __future__ import annotations

import argparse
from dataclasses import asdict
import json
from pathlib import Path
import secrets
import socket
import time
from typing import Any, Mapping, Sequence
import zlib

from .assets import sha256_file, write_json_atomic
from .net_protocol import (
    CHUNK_TIMING_BYTES, DECODE_DEMO, EXTENDED_TIMING_BYTES,
    FLAG_ACK_REQUIRED, FLAG_NON_RELEASE, MSG_END, MSG_HELLO,
    MSG_INPUT_CHUNK, MSG_PARAMETERS, MSG_RUN, MSG_STATUS, MSG_TIMING_CHUNK,
    OUTPUT_TIMING, ChunkTiming, EndSummary, ExtendedTiming, NetProtocolError,
    binding_sha256, make_header, pack_hello, send_message,
)
from .net_runner import (
    NetworkRunnerError, _file, _json, _load_chunk, _manifest_file, _response,
)
from .sd_pack import parse_input_binary_index, parse_parameter_package, validate_input_shard_set


FORMAT = "kv260-coco80-ethernet-soak"
VERSION = 1


class SoakError(RuntimeError):
    """The soak run failed a transport, inference, thermal, or determinism gate."""


def run_soak(args: argparse.Namespace) -> dict[str, Any]:
    if args.seconds < 60 or not 1 <= args.record_count <= 128:
        raise SoakError("seconds must be >=60 and record_count must be in [1,128]")
    runner_path, runner = _json(args.runner_manifest, "network runner manifest")
    if runner.get("format") != "kv260-coco80-ethernet-runner" or runner.get("version") != 1:
        raise SoakError("runner manifest format/version is unsupported")
    if runner.get("development_build") and not args.allow_development:
        raise SoakError("development ELF requires --allow-development")
    bit, bit_sha = _manifest_file(runner.get("bit", {}), "r5 bitstream")
    xsa, xsa_sha = _manifest_file(runner.get("xsa", {}), "r5 XSA")
    elf, elf_sha = _manifest_file(runner.get("elf", {}), "network ELF")
    parameter, parameter_sha = _manifest_file(runner.get("parameter_package", {}), "parameter package")
    parameter_info = parse_parameter_package(parameter)
    quant = _file(args.quantization_manifest, "quantization manifest")
    quant_sha = sha256_file(quant)
    if runner.get("quantization_manifest_sha256") != quant_sha:
        raise SoakError("quantization manifest differs from the network runner")
    input_manifest_path = _file(args.input_index_json, "input shard manifest")
    if not args.skip_full_input_validation:
        validate_input_shard_set(input_manifest_path)
    _manifest_file_path, input_manifest = _json(input_manifest_path, "input shard manifest")
    binary_meta = input_manifest.get("binary_index")
    if not isinstance(binary_meta, Mapping):
        raise SoakError("input shard manifest lacks binary_index")
    binary_path = _file(input_manifest_path.parent / str(binary_meta.get("path", "")), "input binary index")
    binary = parse_input_binary_index(binary_path)
    if args.start_record < 0 or args.start_record + args.record_count > binary["image_count"]:
        raise SoakError("fixed soak selection is outside the input data set")
    payload, _package_crcs = _load_chunk(
        binary["entries"], binary["shards"], input_manifest_path.parent,
        list(range(args.start_record, args.start_record + args.record_count)),
    )
    binding = binding_sha256(
        bit_sha256=bit_sha, xsa_sha256=xsa_sha, elf_sha256=elf_sha,
        parameter_sha256=parameter_sha, dataset_index_sha256=binary["sha256"],
        quantization_sha256=quant_sha,
    )
    output = Path(args.output_dir).resolve()
    if output.exists():
        raise SoakError(f"refusing to overwrite output directory: {output}")
    output.mkdir(parents=True)
    timing_path = output / "extended_timing.bin"
    progress: list[dict[str, Any]] = []
    baseline_crcs: list[int] | None = None
    session_id = secrets.randbits(64) or 1
    sequence = 1
    records = 0
    loops = 0
    input_crc = 0
    logical_first = args.start_record
    max_temp = -40000
    flags = FLAG_ACK_REQUIRED | FLAG_NON_RELEASE
    started = time.perf_counter()
    try:
        with socket.create_connection((args.board_ip, args.port), timeout=args.connect_timeout) as stream, timing_path.open("wb") as timings:
            stream.settimeout(args.io_timeout)
            hello_payload = pack_hello(
                flags=flags, bit_sha256=bit_sha, xsa_sha256=xsa_sha,
                elf_sha256=elf_sha, parameter_sha256=parameter_sha,
                dataset_index_sha256=binary["sha256"], quantization_sha256=quant_sha,
                software_build_crc32=runner["software_build_crc32"],
                hardware_build_crc32=runner["hardware_build_crc32"],
                parameter_package_bytes=parameter.stat().st_size,
            )
            request = make_header(
                message_type=MSG_HELLO, session_id=session_id, sequence=sequence,
                binding=binding, payload=hello_payload, flags=flags,
            ); send_message(stream, request, hello_payload)
            _response(stream, expected_types={MSG_STATUS}, request=request); sequence += 1
            parameter_bytes = parameter.read_bytes()
            request = make_header(
                message_type=MSG_PARAMETERS, session_id=session_id, sequence=sequence,
                binding=binding, payload=parameter_bytes, flags=flags,
            ); send_message(stream, request, parameter_bytes)
            _response(stream, expected_types={MSG_STATUS}, request=request); sequence += 1
            soak_started = time.perf_counter()
            while time.perf_counter() - soak_started < args.seconds:
                chunk_started = time.perf_counter()
                request = make_header(
                    message_type=MSG_INPUT_CHUNK, session_id=session_id, sequence=sequence,
                    binding=binding, payload=payload, flags=flags,
                    first_record=logical_first, record_count=args.record_count,
                    output_kind=OUTPUT_TIMING, decode_profile=DECODE_DEMO,
                ); send_message(stream, request, payload)
                _response(stream, expected_types={MSG_STATUS}, request=request); sequence += 1
                input_crc = zlib.crc32(payload, input_crc) & 0xFFFFFFFF
                request = make_header(
                    message_type=MSG_RUN, session_id=session_id, sequence=sequence,
                    binding=binding, payload=b"", flags=flags,
                    first_record=logical_first, record_count=args.record_count,
                    output_kind=OUTPUT_TIMING, decode_profile=DECODE_DEMO,
                ); send_message(stream, request)
                _timing_header, timing_payload = _response(
                    stream, expected_types={MSG_TIMING_CHUNK}, request=request
                ); sequence += 1
                chunk = ChunkTiming.unpack(timing_payload[:CHUNK_TIMING_BYTES], args.record_count)
                if (
                    chunk.first_record != logical_first
                    or chunk.input_chunk_crc32 != zlib.crc32(payload) & 0xFFFFFFFF
                    or chunk.result_payload_bytes != 0 or chunk.result_chunk_crc32 != 0
                ):
                    raise SoakError("soak chunk timing/input binding is invalid")
                rows = timing_payload[CHUNK_TIMING_BYTES:]
                if len(rows) != args.record_count * EXTENDED_TIMING_BYTES:
                    raise SoakError("soak timing table has the wrong size")
                current_crcs: list[int] = []
                for local in range(args.record_count):
                    raw = rows[local * EXTENDED_TIMING_BYTES:(local + 1) * EXTENDED_TIMING_BYTES]
                    item = ExtendedTiming.unpack(raw)
                    expected_image = binary["entries"][args.start_record + local]["image_id"]
                    if item.image_id != expected_image or item.output_kind != OUTPUT_TIMING or item.decode_profile != DECODE_DEMO:
                        raise SoakError("soak per-image identity/profile mismatch")
                    current_crcs.append(item.output_crc32)
                    timings.write(raw)
                if baseline_crcs is None:
                    baseline_crcs = current_crcs
                elif current_crcs != baseline_crcs:
                    mismatch = next(index for index, pair in enumerate(zip(current_crcs, baseline_crcs)) if pair[0] != pair[1])
                    raise SoakError(f"output CRC changed at fixed-set record {mismatch}")
                max_temp = max(max_temp, chunk.max_temp_millic)
                if chunk.max_temp_millic >= args.temp_limit_millic:
                    raise SoakError(f"temperature reached {chunk.max_temp_millic} mC")
                records += args.record_count; loops += 1; logical_first += args.record_count
                elapsed = time.perf_counter() - soak_started
                progress.append({
                    "elapsed_seconds": elapsed, "loops": loops, "records": records,
                    "chunk_wall_seconds": time.perf_counter() - chunk_started,
                    "current_temp_millic": chunk.current_temp_millic,
                    "max_temp_millic": chunk.max_temp_millic,
                })
                print(
                    f"soak: elapsed={elapsed:.1f}s loops={loops} records={records} "
                    f"temp={chunk.current_temp_millic}mC max={chunk.max_temp_millic}mC",
                    flush=True,
                )
            timings.flush()
            host_end = EndSummary(
                status=0, records_received=records, records_completed=records,
                results_sent=records, error_count=0, input_crc32=input_crc,
                result_crc32=0, parameter_crc32=parameter_info["package_crc32"],
                reconnect_count=0, elapsed_ticks=0,
            ).pack()
            request = make_header(
                message_type=MSG_END, session_id=session_id, sequence=sequence,
                binding=binding, payload=host_end, flags=flags,
            ); send_message(stream, request, host_end)
            _end_header, end_payload = _response(stream, expected_types={MSG_END}, request=request)
            end = EndSummary.unpack(end_payload)
            if (
                end.status != 0 or end.error_count != 0 or end.records_received != records
                or end.records_completed != records or end.results_sent != records
                or end.input_crc32 != input_crc or end.result_crc32 != 0
                or end.parameter_crc32 != parameter_info["package_crc32"]
            ):
                raise SoakError("board soak END counters/CRCs are inconsistent")
    except (OSError, NetProtocolError, NetworkRunnerError) as exc:
        raise SoakError(f"soak failed after {records} records: {exc}") from exc
    elapsed = time.perf_counter() - soak_started
    if elapsed < args.seconds or not progress:
        raise SoakError("soak duration/progress is incomplete")
    max_gap = max(item["chunk_wall_seconds"] for item in progress)
    if max_gap > args.max_progress_gap:
        raise SoakError(f"soak progress gap {max_gap:.3f}s exceeds {args.max_progress_gap}s")
    summary = {
        "format": FORMAT, "version": VERSION, "status": "PASS",
        "requested_seconds": args.seconds, "elapsed_seconds": elapsed,
        "fixed_first_record": args.start_record, "fixed_record_count": args.record_count,
        "loops": loops, "records": records, "max_progress_gap_seconds": max_gap,
        "max_temp_millic": max_temp, "temp_limit_millic": args.temp_limit_millic,
        # The host keeps one TCP socket for the entire soak. Any disconnect raises
        # above, so a successful session has no in-session reconnect. The board
        # counter is cumulative since ELF boot and includes earlier validation
        # clients; keep it separately so it is not mistaken for a soak failure.
        "output_crc_mismatches": 0, "protocol_errors": 0, "reconnects": 0,
        "board_reconnect_count_since_boot": end.reconnect_count,
        "binding_sha256": binding, "end": asdict(end), "progress": progress,
        "artifacts": {
            "runner_manifest": {"path": str(runner_path), "sha256": sha256_file(runner_path)},
            "bit": {"path": str(bit), "sha256": bit_sha},
            "xsa": {"path": str(xsa), "sha256": xsa_sha},
            "elf": {"path": str(elf), "sha256": elf_sha},
            "parameter": {"path": str(parameter), "sha256": parameter_sha},
            "input_index": {"path": str(binary_path), "sha256": binary["sha256"]},
            "timing": {"path": str(timing_path), "bytes": timing_path.stat().st_size, "sha256": sha256_file(timing_path)},
        },
        "wall_seconds_including_setup": time.perf_counter() - started,
    }
    write_json_atomic(output / "summary.json", summary)
    return summary


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner-manifest", type=Path, required=True)
    parser.add_argument("--quantization-manifest", type=Path, required=True)
    parser.add_argument("--input-index-json", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--board-ip", default="192.168.10.2")
    parser.add_argument("--port", type=int, default=5001)
    parser.add_argument("--start-record", type=int, default=0)
    parser.add_argument("--record-count", type=int, default=128)
    parser.add_argument("--seconds", type=float, default=600.0)
    parser.add_argument("--temp-limit-millic", type=int, default=85000)
    parser.add_argument("--max-progress-gap", type=float, default=15.0)
    parser.add_argument("--connect-timeout", type=float, default=10.0)
    parser.add_argument("--io-timeout", type=float, default=600.0)
    parser.add_argument("--allow-development", action="store_true")
    parser.add_argument("--skip-full-input-validation", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        summary = run_soak(args)
    except (SoakError, ValueError) as exc:
        print(f"FAIL: {exc}")
        return 1
    print(json.dumps({
        "status": summary["status"], "elapsed_seconds": summary["elapsed_seconds"],
        "records": summary["records"], "max_temp_millic": summary["max_temp_millic"],
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

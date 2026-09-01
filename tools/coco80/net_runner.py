"""Fail-closed host runner for the r5 COCO80 bare-metal TCP service."""

from __future__ import annotations

import argparse
from contextlib import ExitStack
from dataclasses import asdict
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import time
from typing import Any, Mapping, Sequence
import zlib

from .assets import sha256_file, write_json_atomic
from .conformance import parse_conformance_binary
from .net_protocol import (
    CHUNK_RECORDS,
    CHUNK_TIMING_BYTES,
    DECODE_ACCURACY,
    DECODE_DEMO,
    END_BYTES,
    EXTENDED_TIMING_BYTES,
    FLAG_ACK_REQUIRED,
    FLAG_NON_RELEASE,
    FLAG_TRANSPORT_ONLY,
    MSG_END,
    MSG_ERROR,
    MSG_HELLO,
    MSG_INPUT_CHUNK,
    MSG_PARAMETERS,
    MSG_RESULT_CHUNK,
    MSG_RUN,
    MSG_STATUS,
    MSG_TIMING_CHUNK,
    OUTPUT_DETECTIONS,
    OUTPUT_RAW,
    OUTPUT_TIMING,
    ChunkTiming,
    EndSummary,
    ExtendedTiming,
    NetHeader,
    NetProtocolError,
    binding_sha256,
    crc32,
    iter_result_records,
    make_header,
    pack_hello,
    recv_message,
    send_message,
)
from .sd_pack import (
    HEADER_BYTES,
    INPUT_TENSOR_BYTES,
    MAGIC_DETECTIONS,
    MAGIC_RAW_HEADS,
    OUTPUT_INDEX_ENTRY,
    OUTPUT_INDEX_HEADER,
    P4_BYTES,
    P5_BYTES,
    crc32_file,
    parse_input_binary_index,
    parse_parameter_package,
    validate_input_shard_set,
)


FORMAT = "kv260-coco80-ethernet-validation"
VERSION = 1
INPUT_PACKAGE_BYTES = HEADER_BYTES + INPUT_TENSOR_BYTES
RAW_PACKAGE_BYTES = HEADER_BYTES + P4_BYTES + P5_BYTES
EXTENDED = struct.Struct("<8I7Q13Q10Q4I")
COMMON = struct.Struct("<32I")


class NetworkRunnerError(RuntimeError):
    """The Ethernet run cannot be proven to satisfy its artifact contract."""


def _json(path: str | Path, label: str) -> tuple[Path, dict[str, Any]]:
    target = Path(path).resolve()
    if target.is_symlink() or not target.is_file():
        raise NetworkRunnerError(f"{label} is not a regular file: {target}")
    try:
        value = json.loads(target.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise NetworkRunnerError(f"cannot parse {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise NetworkRunnerError(f"{label} must contain one JSON object")
    return target, value


def _file(path: str | Path, label: str) -> Path:
    target = Path(path).resolve()
    if target.is_symlink() or not target.is_file():
        raise NetworkRunnerError(f"{label} is not a regular file: {target}")
    return target


def _manifest_file(meta: Mapping[str, Any], label: str) -> tuple[Path, str]:
    path = _file(str(meta.get("path", "")), label)
    digest = sha256_file(path)
    if meta.get("sha256") != digest or meta.get("bytes", path.stat().st_size) != path.stat().st_size:
        raise NetworkRunnerError(f"{label} differs from the runner manifest")
    return path, digest


def _mode(value: str) -> tuple[bool, int, int]:
    table = {
        "transport": (True, OUTPUT_TIMING, DECODE_DEMO),
        "raw-accuracy": (False, OUTPUT_RAW, DECODE_ACCURACY),
        "detections-accuracy": (False, OUTPUT_DETECTIONS, DECODE_ACCURACY),
        "detections-demo": (False, OUTPUT_DETECTIONS, DECODE_DEMO),
        "timing-demo": (False, OUTPUT_TIMING, DECODE_DEMO),
    }
    try:
        return table[value]
    except KeyError as exc:
        raise NetworkRunnerError(f"unsupported network mode: {value}") from exc


def _package_words(record: bytes, magic: int, expected_bytes: int | None = None) -> tuple[int, ...]:
    if len(record) < HEADER_BYTES:
        raise NetworkRunnerError("board result package is shorter than its header")
    words = COMMON.unpack_from(record)
    canonical = bytearray(record[:HEADER_BYTES])
    canonical[7 * 4:8 * 4] = bytes(4)
    if (
        words[0] != magic or words[1] != 1 or words[2] != HEADER_BYTES
        or words[3] != len(record) or words[4] != HEADER_BYTES
        or words[5] != len(record) - HEADER_BYTES
        or (zlib.crc32(canonical) & 0xFFFFFFFF) != words[7]
        or (zlib.crc32(record[HEADER_BYTES:]) & 0xFFFFFFFF) != words[6]
        or (expected_bytes is not None and len(record) != expected_bytes)
    ):
        raise NetworkRunnerError("board result package common header/CRC is invalid")
    return words


def _validate_result_record(
    record: bytes, *, output_kind: int, image_id: int,
    input_crc32: int, parameter_crc32: int,
) -> tuple[int, int]:
    if output_kind == OUTPUT_RAW:
        words = _package_words(record, MAGIC_RAW_HEADS, RAW_PACKAGE_BYTES)
        if words[30] != input_crc32 or words[31] != parameter_crc32:
            raise NetworkRunnerError("raw-head package is not bound to its input/parameters")
        return 0, image_id
    if output_kind == OUTPUT_DETECTIONS:
        words = _package_words(record, MAGIC_DETECTIONS)
        count = words[9]
        if words[8] != image_id or words[16] != input_crc32 or count > 300:
            raise NetworkRunnerError("detection package identity/count/input binding is invalid")
        if len(record) != HEADER_BYTES + count * 64:
            raise NetworkRunnerError("detection package count and byte length differ")
        return count, words[8]
    raise NetworkRunnerError("timing-only mode unexpectedly returned result records")


def _response(
    stream: socket.socket, *, expected_types: set[int], request: NetHeader,
) -> tuple[NetHeader, bytes]:
    header, payload = recv_message(stream)
    if header.message_type == MSG_ERROR:
        raise NetworkRunnerError(
            f"board rejected sequence {request.sequence}: status={header.status} error={header.error_code}"
        )
    if header.message_type not in expected_types:
        raise NetworkRunnerError(
            f"unexpected response type {header.message_type}, expected {sorted(expected_types)}"
        )
    if (
        header.session_id != request.session_id or header.sequence != request.sequence
        or header.binding_sha256 != request.binding_sha256
        or header.first_record != request.first_record
        or header.record_count != request.record_count
        or header.status != 0 or header.error_code != 0
        or (header.flags & FLAG_NON_RELEASE) == 0
    ):
        raise NetworkRunnerError("board response identity/status differs from its request")
    return header, payload


def _send(
    stream: socket.socket, *, message_type: int, session_id: int,
    sequence: int, binding: str, payload: bytes = b"", flags: int,
    first_record: int = 0, record_count: int = 0,
    output_kind: int = 0, decode_profile: int = 0,
) -> NetHeader:
    header = make_header(
        message_type=message_type, session_id=session_id, sequence=sequence,
        binding=binding, payload=payload, flags=flags,
        first_record=first_record, record_count=record_count,
        output_kind=output_kind, decode_profile=decode_profile,
    )
    send_message(stream, header, payload)
    return header


def _load_chunk(
    entries: list[dict[str, int]], shards: list[dict[str, Any]], root: Path,
    record_indices: Sequence[int],
) -> tuple[bytes, list[int]]:
    output = bytearray(len(record_indices) * INPUT_PACKAGE_BYTES)
    package_crcs: list[int] = []
    with ExitStack() as stack:
        streams: dict[int, Any] = {}
        for local, record_index in enumerate(record_indices):
            entry = entries[record_index]
            if entry["record_index"] != record_index or entry["bytes"] != INPUT_PACKAGE_BYTES:
                raise NetworkRunnerError(f"input entry {record_index} violates the fixed package contract")
            shard_id = entry["shard_id"]
            if shard_id not in streams:
                shard_path = _file(root / shards[shard_id]["path"], f"input shard {shard_id}")
                streams[shard_id] = stack.enter_context(shard_path.open("rb"))
            stream = streams[shard_id]
            stream.seek(entry["offset"])
            package = stream.read(INPUT_PACKAGE_BYTES)
            if len(package) != INPUT_PACKAGE_BYTES or crc32(package) != entry["package_crc32"]:
                raise NetworkRunnerError(f"input package {record_index} CRC/size mismatch")
            begin = local * INPUT_PACKAGE_BYTES
            output[begin:begin + INPUT_PACKAGE_BYTES] = package
            package_crcs.append(entry["package_crc32"])
    return bytes(output), package_crcs


def _output_index(
    path: Path, data_path: Path, entries: list[dict[str, int]], *, mode: int,
    input_records: int, parameter_crc32: int, input_index_crc32: int,
    software_build_crc32: int, hardware_build_crc32: int,
    selection_index_crc32: int = 0,
) -> None:
    rows = bytearray()
    for item in entries:
        total = item["total_ticks"]
        rows.extend(OUTPUT_INDEX_ENTRY.pack(
            item["image_id"], item["record_index"], item["offset"], item["bytes"],
            item["crc32"], item["detection_count"], total & 0xFFFFFFFF, total >> 32,
        ))
    words = [0] * 32
    words[:17] = [
        int.from_bytes(b"C8OX", "little"), 2, OUTPUT_INDEX_HEADER.size, mode,
        input_records, len(entries), OUTPUT_INDEX_ENTRY.size, len(rows),
        data_path.stat().st_size, crc32_file(data_path), crc32(rows),
        parameter_crc32, input_index_crc32, software_build_crc32,
        hardware_build_crc32, 0, selection_index_crc32,
    ]
    canonical = bytearray(OUTPUT_INDEX_HEADER.pack(*words))
    words[15] = crc32(canonical)
    temporary = path.with_name(path.name + ".partial")
    with temporary.open("wb") as stream:
        stream.write(OUTPUT_INDEX_HEADER.pack(*words))
        stream.write(rows)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def _timing_dict(raw: bytes) -> dict[str, Any]:
    timing = ExtendedTiming.unpack(raw)
    result = asdict(timing)
    result["pl_layer_ticks"] = list(timing.pl_layer_ticks)
    result["a53_op_ticks"] = list(timing.a53_op_ticks)
    for key in (
        "total_ticks", "pl_ticks", "a53_ticks", "decode_ticks",
        "candidate_ticks", "sort_ticks", "nms_ticks",
    ):
        result[key[:-6] + "us"] = result[key] * 1_000_000.0 / timing.tick_hz
    return result


def run_network(args: argparse.Namespace) -> dict[str, Any]:
    transport_only, output_kind, decode_profile = _mode(args.mode)
    runner_path, runner = _json(args.runner_manifest, "network runner manifest")
    if runner.get("format") != "kv260-coco80-ethernet-runner" or runner.get("version") != 1:
        raise NetworkRunnerError("runner manifest format/version is unsupported")
    if runner.get("development_build") and not args.allow_development:
        raise NetworkRunnerError("development ELF requires --allow-development")
    bit, bit_sha = _manifest_file(runner.get("bit", {}), "r5 bitstream")
    xsa, xsa_sha = _manifest_file(runner.get("xsa", {}), "r5 XSA")
    elf, elf_sha = _manifest_file(runner.get("elf", {}), "network ELF")
    parameter, parameter_sha = _manifest_file(runner.get("parameter_package", {}), "parameter package")
    parameter_info = parse_parameter_package(parameter)
    quant = _file(args.quantization_manifest, "quantization manifest")
    quant_sha = sha256_file(quant)
    if runner.get("quantization_manifest_sha256") != quant_sha:
        raise NetworkRunnerError("quantization manifest differs from the network runner")
    if not isinstance(runner.get("software_build_crc32"), int) or not isinstance(
        runner.get("hardware_build_crc32"), int
    ):
        raise NetworkRunnerError("runner manifest lacks software/hardware build CRCs")

    input_manifest_path = _file(args.input_index_json, "input shard manifest")
    if not args.skip_full_input_validation:
        validate_input_shard_set(input_manifest_path)
    _manifest_path, input_manifest = _json(input_manifest_path, "input shard manifest")
    binary_meta = input_manifest.get("binary_index")
    if not isinstance(binary_meta, Mapping):
        raise NetworkRunnerError("input shard manifest lacks binary_index")
    binary_path = _file(input_manifest_path.parent / str(binary_meta.get("path", "")), "input binary index")
    binary = parse_input_binary_index(binary_path)
    if binary_meta.get("sha256") != binary["sha256"]:
        raise NetworkRunnerError("input JSON and binary index SHA256 differ")
    total_images = binary["image_count"]
    selection_path: Path | None = None
    selection: dict[str, Any] | None = None
    selection_arg = getattr(args, "selection_index_bin", None)
    if selection_arg is not None:
        selection_path = _file(selection_arg, "conformance selection index")
        selection = parse_conformance_binary(selection_path, binary_path)
        if args.start_record != 0 or (
            args.record_count is not None and args.record_count != selection["count"]
        ):
            raise NetworkRunnerError(
                "selection-index runs require start_record=0 and the complete selection"
            )
        first = 0
        count = selection["count"]
        record_indices = [int(item["record_index"]) for item in selection["records"]]
        dataset_binding_sha256 = selection["sha256"]
        selection_index_crc32 = selection["crc32"]
    else:
        first = args.start_record
        count = total_images - first if args.record_count is None else args.record_count
        if first < 0 or count <= 0 or first + count > total_images:
            raise NetworkRunnerError("selected input record range is outside the data set")
        record_indices = list(range(first, first + count))
        dataset_binding_sha256 = binary["sha256"]
        selection_index_crc32 = 0
    if args.warmup_records < 0 or args.warmup_records >= count:
        raise NetworkRunnerError("warmup_records must be in [0, record_count)")
    if not 1 <= args.chunk_records <= CHUNK_RECORDS:
        raise NetworkRunnerError(f"chunk_records must be in [1,{CHUNK_RECORDS}]")

    output_dir = Path(args.output_dir).resolve()
    checkpoint_path = output_dir / "checkpoint.json"
    data_path = output_dir / ("raw_heads.bin" if output_kind == OUTPUT_RAW else "detections.bin")
    timing_path = output_dir / "extended_timing.bin"
    output_dir.mkdir(parents=True, exist_ok=args.resume)
    completed = 0
    output_entries: list[dict[str, int]] = []
    chunk_summaries: list[dict[str, Any]] = []
    if args.resume:
        if not checkpoint_path.is_file():
            raise NetworkRunnerError("--resume requires an existing checkpoint.json")
        _cp_path, checkpoint = _json(checkpoint_path, "network checkpoint")
        if (
            checkpoint.get("mode") != args.mode or checkpoint.get("first_record") != first
            or checkpoint.get("record_count") != count
            or checkpoint.get("warmup_records") != args.warmup_records
        ):
            raise NetworkRunnerError("checkpoint selection/mode differs from this run")
        completed = int(checkpoint.get("completed", -1))
        output_entries = list(checkpoint.get("output_entries", []))
        chunk_summaries = list(checkpoint.get("chunks", []))
        if completed < 0 or completed > count or checkpoint.get("timing_records") != (
            0 if transport_only else completed
        ):
            raise NetworkRunnerError("checkpoint counters are invalid")
    elif any(output_dir.iterdir()):
        raise NetworkRunnerError("refusing to overwrite a nonempty output directory")

    output_offset = sum(int(item["bytes"]) for item in output_entries)
    timing_offset = 0 if transport_only else completed * EXTENDED_TIMING_BYTES
    data_stream = None
    if output_kind != OUTPUT_TIMING:
        data_stream = data_path.open("r+b" if data_path.exists() else "w+b")
        data_stream.truncate(output_offset)
        data_stream.seek(output_offset)
    timing_stream = timing_path.open("r+b" if timing_path.exists() else "w+b")
    timing_stream.truncate(timing_offset)
    timing_stream.seek(timing_offset)

    binding = binding_sha256(
        bit_sha256=bit_sha, xsa_sha256=xsa_sha, elf_sha256=elf_sha,
        parameter_sha256=parameter_sha, dataset_index_sha256=dataset_binding_sha256,
        quantization_sha256=quant_sha,
    )
    if args.resume and checkpoint.get("binding_sha256") != binding:
        raise NetworkRunnerError("checkpoint artifact binding differs from this run")
    flags = FLAG_ACK_REQUIRED | FLAG_NON_RELEASE | (FLAG_TRANSPORT_ONLY if transport_only else 0)
    session_id = secrets.randbits(64) or 1
    sequence = 1
    input_session_crc = 0
    result_session_crc = 0
    session_records = 0
    started = time.perf_counter()
    try:
        with socket.create_connection((args.board_ip, args.port), timeout=args.connect_timeout) as stream:
            stream.settimeout(args.io_timeout)
            hello = pack_hello(
                flags=flags, bit_sha256=bit_sha, xsa_sha256=xsa_sha,
                elf_sha256=elf_sha, parameter_sha256=parameter_sha,
                dataset_index_sha256=dataset_binding_sha256, quantization_sha256=quant_sha,
                software_build_crc32=runner["software_build_crc32"],
                hardware_build_crc32=runner["hardware_build_crc32"],
                parameter_package_bytes=parameter.stat().st_size,
            )
            request = _send(
                stream, message_type=MSG_HELLO, session_id=session_id,
                sequence=sequence, binding=binding, payload=hello, flags=flags,
            )
            _response(stream, expected_types={MSG_STATUS}, request=request)
            sequence += 1
            parameter_bytes = parameter.read_bytes()
            request = _send(
                stream, message_type=MSG_PARAMETERS, session_id=session_id,
                sequence=sequence, binding=binding, payload=parameter_bytes, flags=flags,
            )
            _response(stream, expected_types={MSG_STATUS}, request=request)
            sequence += 1

            while completed < count:
                chunk_count = min(args.chunk_records, count - completed)
                if completed < args.warmup_records:
                    chunk_count = min(chunk_count, args.warmup_records - completed)
                chunk_first = completed if selection is not None else first + completed
                chunk_record_indices = record_indices[completed:completed + chunk_count]
                chunk_started = time.perf_counter_ns()
                payload, package_crcs = _load_chunk(
                    binary["entries"], binary["shards"], input_manifest_path.parent,
                    chunk_record_indices,
                )
                input_session_crc = zlib.crc32(payload, input_session_crc) & 0xFFFFFFFF
                request = _send(
                    stream, message_type=MSG_INPUT_CHUNK, session_id=session_id,
                    sequence=sequence, binding=binding, payload=payload, flags=flags,
                    first_record=chunk_first, record_count=chunk_count,
                    output_kind=output_kind, decode_profile=decode_profile,
                )
                _response(stream, expected_types={MSG_STATUS}, request=request)
                sequence += 1
                chunk_result = b""
                chunk_timing: ChunkTiming | None = None
                new_entries: list[dict[str, int]] = []
                if not transport_only:
                    request = _send(
                        stream, message_type=MSG_RUN, session_id=session_id,
                        sequence=sequence, binding=binding, flags=flags,
                        first_record=chunk_first, record_count=chunk_count,
                        output_kind=output_kind, decode_profile=decode_profile,
                    )
                    if output_kind != OUTPUT_TIMING:
                        result_header, chunk_result = _response(
                            stream, expected_types={MSG_RESULT_CHUNK}, request=request
                        )
                        if result_header.output_kind != output_kind or result_header.decode_profile != decode_profile:
                            raise NetworkRunnerError("result chunk profile differs from RUN")
                    timing_header, timing_payload = _response(
                        stream, expected_types={MSG_TIMING_CHUNK}, request=request
                    )
                    if timing_header.output_kind != output_kind or timing_header.decode_profile != decode_profile:
                        raise NetworkRunnerError("timing chunk profile differs from RUN")
                    chunk_timing = ChunkTiming.unpack(timing_payload[:CHUNK_TIMING_BYTES], chunk_count)
                    if (
                        chunk_timing.first_record != chunk_first
                        or chunk_timing.output_kind != output_kind
                        or chunk_timing.decode_profile != decode_profile
                        or chunk_timing.input_chunk_crc32 != crc32(payload)
                        or chunk_timing.result_payload_bytes != len(chunk_result)
                        or chunk_timing.result_chunk_crc32 != crc32(chunk_result)
                    ):
                        raise NetworkRunnerError("chunk timing does not bind the input/result payloads")
                    result_session_crc = zlib.crc32(chunk_result, result_session_crc) & 0xFFFFFFFF
                    records = list(iter_result_records(chunk_result, chunk_count)) if chunk_result else []
                    if output_kind != OUTPUT_TIMING and len(records) != chunk_count:
                        raise NetworkRunnerError("result chunk cardinality differs from its input")
                    timing_bytes = timing_payload[CHUNK_TIMING_BYTES:]
                    if len(timing_bytes) != chunk_count * EXTENDED_TIMING_BYTES:
                        raise NetworkRunnerError("timing chunk record table has the wrong size")
                    for local in range(chunk_count):
                        raw_timing = timing_bytes[
                            local * EXTENDED_TIMING_BYTES:(local + 1) * EXTENDED_TIMING_BYTES
                        ]
                        parsed_timing = _timing_dict(raw_timing)
                        entry = binary["entries"][chunk_record_indices[local]]
                        if (
                            parsed_timing["image_id"] != entry["image_id"]
                            or parsed_timing["output_kind"] != output_kind
                            or parsed_timing["decode_profile"] != decode_profile
                        ):
                            raise NetworkRunnerError("per-image timing identity/profile mismatch")
                        timing_stream.write(raw_timing)
                        if output_kind != OUTPUT_TIMING:
                            result_image, record = records[local]
                            if result_image != entry["image_id"]:
                                raise NetworkRunnerError("result image order differs from input index")
                            if parsed_timing["output_crc32"] != crc32(record):
                                raise NetworkRunnerError("per-image timing output CRC differs from the result package")
                            detections, package_image = _validate_result_record(
                                record, output_kind=output_kind, image_id=result_image,
                                input_crc32=package_crcs[local],
                                parameter_crc32=parameter_info["package_crc32"],
                            )
                            if package_image != result_image:
                                raise NetworkRunnerError("result package image id mismatch")
                            if data_stream is None:
                                raise NetworkRunnerError("result stream is unavailable")
                            data_stream.write(record)
                            new_entries.append({
                                "image_id": result_image,
                                "record_index": completed + local if selection is not None else chunk_first + local,
                                "offset": output_offset,
                                "bytes": len(record), "crc32": crc32(record),
                                "detection_count": detections,
                                "total_ticks": parsed_timing["total_ticks"],
                            })
                            output_offset += len(record)
                    sequence += 1
                session_records += chunk_count
                completed += chunk_count
                output_entries.extend(new_entries)
                if data_stream is not None:
                    data_stream.flush(); os.fsync(data_stream.fileno())
                timing_stream.flush(); os.fsync(timing_stream.fileno())
                chunk_summaries.append({
                    "first_record": chunk_first, "record_count": chunk_count,
                    "input_bytes": len(payload), "input_crc32": crc32(payload),
                    "result_bytes": len(chunk_result), "result_crc32": crc32(chunk_result),
                    "host_wall_seconds": (time.perf_counter_ns() - chunk_started) / 1e9,
                    "board": asdict(chunk_timing) if chunk_timing is not None else None,
                })
                checkpoint = {
                    "format": FORMAT + ".checkpoint", "version": VERSION,
                    "mode": args.mode, "binding_sha256": binding,
                    "first_record": first, "record_count": count,
                    "warmup_records": args.warmup_records,
                    "completed": completed, "output_entries": output_entries,
                    "timing_records": 0 if transport_only else completed,
                    "chunks": chunk_summaries,
                }
                write_json_atomic(checkpoint_path, checkpoint)
                print(f"ethernet: {completed}/{count} records", flush=True)

            host_end = EndSummary(
                status=0, records_received=session_records,
                records_completed=session_records,
                results_sent=0 if transport_only else session_records,
                error_count=0, input_crc32=input_session_crc,
                result_crc32=result_session_crc,
                parameter_crc32=parameter_info["package_crc32"],
                reconnect_count=0, elapsed_ticks=0,
            ).pack()
            request = _send(
                stream, message_type=MSG_END, session_id=session_id,
                sequence=sequence, binding=binding, payload=host_end, flags=flags,
            )
            end_header, end_payload = _response(stream, expected_types={MSG_END}, request=request)
            if end_header.payload_bytes != END_BYTES:
                raise NetworkRunnerError("board END response has the wrong size")
            board_end = EndSummary.unpack(end_payload)
            if (
                board_end.status != 0 or board_end.error_count != 0
                or board_end.records_received != session_records
                or board_end.records_completed != session_records
                or board_end.results_sent != (0 if transport_only else session_records)
                or board_end.input_crc32 != input_session_crc
                or board_end.result_crc32 != result_session_crc
                or board_end.parameter_crc32 != parameter_info["package_crc32"]
            ):
                raise NetworkRunnerError("board END counters/CRCs differ from the host session")
    except (OSError, NetProtocolError) as exc:
        raise NetworkRunnerError(f"network session failed after {completed}/{count} records: {exc}") from exc
    finally:
        if data_stream is not None:
            data_stream.close()
        timing_stream.close()

    if output_kind == OUTPUT_RAW:
        _output_index(
            output_dir / "output_index.bin", data_path, output_entries, mode=0,
            input_records=count, parameter_crc32=parameter_info["package_crc32"],
            input_index_crc32=binary["crc32"],
            software_build_crc32=runner["software_build_crc32"],
            hardware_build_crc32=runner["hardware_build_crc32"],
            selection_index_crc32=selection_index_crc32,
        )
    if output_entries:
        write_json_atomic(output_dir / "results_index.json", {
            "format": FORMAT + ".results-index", "version": VERSION,
            "mode": args.mode, "first_record": first, "record_count": count,
            "entries": output_entries,
        })
    summary = {
        "format": FORMAT, "version": VERSION, "status": "PASS",
        "mode": args.mode, "transport_only": transport_only,
        "first_record": first, "record_count": count,
        "warmup_records": args.warmup_records,
        "binding_sha256": binding, "session_id": session_id,
        "elapsed_seconds": time.perf_counter() - started,
        "network": {"board_ip": args.board_ip, "port": args.port, "chunk_records": args.chunk_records},
        "end": asdict(board_end), "chunks": chunk_summaries,
        "artifacts": {
            "runner_manifest": {"path": str(runner_path), "sha256": sha256_file(runner_path)},
            "bit": {"path": str(bit), "sha256": bit_sha},
            "xsa": {"path": str(xsa), "sha256": xsa_sha},
            "elf": {"path": str(elf), "sha256": elf_sha},
            "parameter": {"path": str(parameter), "sha256": parameter_sha},
            "quantization": {"path": str(quant), "sha256": quant_sha},
            "input_index": {"path": str(binary_path), "sha256": binary["sha256"]},
            "timing": {"path": str(timing_path), "bytes": timing_path.stat().st_size, "sha256": sha256_file(timing_path)},
        },
    }
    if data_path.is_file():
        summary["artifacts"]["results"] = {
            "path": str(data_path), "bytes": data_path.stat().st_size, "sha256": sha256_file(data_path)
        }
    if selection_path is not None and selection is not None:
        summary["selection"] = {
            "count": selection["count"], "crc32": selection["crc32"],
            "sha256": selection["sha256"],
        }
        summary["artifacts"]["selection_index"] = {
            "path": str(selection_path), "bytes": selection_path.stat().st_size,
            "sha256": selection["sha256"],
        }
    write_json_atomic(output_dir / "summary.json", summary)
    checkpoint_path.unlink(missing_ok=True)
    return summary


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner-manifest", type=Path, required=True)
    parser.add_argument("--quantization-manifest", type=Path, required=True)
    parser.add_argument("--input-index-json", type=Path, required=True)
    parser.add_argument("--selection-index-bin", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--mode", choices=("transport", "raw-accuracy", "detections-accuracy", "detections-demo", "timing-demo"),
        required=True,
    )
    parser.add_argument("--board-ip", default="192.168.10.2")
    parser.add_argument("--port", type=int, default=5001)
    parser.add_argument("--start-record", type=int, default=0)
    parser.add_argument("--record-count", type=int)
    parser.add_argument("--warmup-records", type=int, default=0)
    parser.add_argument("--chunk-records", type=int, default=128)
    parser.add_argument("--connect-timeout", type=float, default=10.0)
    parser.add_argument("--io-timeout", type=float, default=600.0)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--allow-development", action="store_true")
    parser.add_argument("--skip-full-input-validation", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        summary = run_network(args)
    except (NetworkRunnerError, ValueError) as exc:
        print(f"FAIL: {exc}")
        return 1
    print(json.dumps({
        "status": summary["status"], "mode": summary["mode"],
        "records": summary["record_count"], "output": str(Path(args.output_dir).resolve()),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

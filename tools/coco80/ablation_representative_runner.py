"""Run byte-exact LASA representative-layer ablations over the TCP/DDR path."""

from __future__ import annotations

import argparse
from dataclasses import asdict
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import secrets
import socket
import struct
import time
from typing import Any, Sequence
import zlib

import torch

from .ablation_prepack import pack_legacy_ifm
from .assets import sha256_file, write_json_atomic
from .conformance import parse_conformance_binary
from .net_protocol import (
    CHUNK_TIMING_BYTES, DECODE_DEMO, END_BYTES, EXTENDED_TIMING_BYTES,
    FLAG_ABLATION_REPRESENTATIVE, FLAG_ACK_REQUIRED, FLAG_NON_RELEASE,
    MSG_END, MSG_HELLO, MSG_INPUT_CHUNK, MSG_PARAMETERS, MSG_RESULT_CHUNK,
    MSG_RUN, MSG_STATUS, MSG_TIMING_CHUNK, OUTPUT_RAW, OUTPUT_TIMING,
    REP_OUTPUT_MAGIC, ChunkTiming, EndSummary, ExtendedTiming,
    REP_OVERRIDE_NONE, REP_OVERRIDE_SPARSE_3X3, REP_OVERRIDE_TILE,
    binding_sha256, crc32, iter_result_records, pack_hello,
    pack_representative_input, unpack_representative,
)
from .net_runner import (
    NetworkRunnerError, _file, _json, _load_chunk, _manifest_file,
    _response, _send,
)
from .ptq_runner import RtlPtqRunner
from .hardware_plan import get_schedule, schedule_layer
from .parameter_package import build_bias_tile, build_weight_tile
from .sd_pack import HEADER_BYTES, INPUT_TENSOR_BYTES, parse_input_binary_index


FORMAT = "kv260-lasa-representative-session"
VERSION = 1
LAYER_CONTRACT = {
    "m0": (0, None, "pool1"),
    "m13": (6, "pool12", "m13"),
    "m14": (7, "m13", "m14"),
    "m16": (9, "m14", "m16"),
    "m19": (10, "concat18", "m19"),
    "p4_detect": (11, "m19", "p4_detect"),
    "p5_detect": (12, "m15", "p5_detect"),
}
COMMON = struct.Struct("<32I")


def _hwc(tensor: torch.Tensor) -> bytes:
    if tensor.dtype != torch.uint8 or tensor.ndim != 4 or tensor.shape[0] != 1:
        raise NetworkRunnerError("representative tensor is not [1,C,H,W] uint8")
    return tensor[0].permute(1, 2, 0).contiguous().cpu().numpy().tobytes()


def _model_layer(path: Path, name: str) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    matches = [item for item in value.get("conv_layers", []) if item.get("name") == name]
    if value.get("format") != "kv260-coco80-yolov3-tiny-dag" or len(matches) != 1:
        raise NetworkRunnerError("model spec representative layer is missing/ambiguous")
    return matches[0]


def _input_tensor(package: bytes, image_id: int) -> torch.Tensor:
    if len(package) != HEADER_BYTES + INPUT_TENSOR_BYTES:
        raise NetworkRunnerError("C8IN package length is invalid")
    words = COMMON.unpack_from(package)
    if words[0] != int.from_bytes(b"C8IN", "little") or words[8] != image_id:
        raise NetworkRunnerError("C8IN package identity differs from its index")
    payload = package[HEADER_BYTES:]
    return torch.frombuffer(bytearray(payload), dtype=torch.uint8).reshape(
        416, 416, 3
    ).permute(2, 0, 1).contiguous()


def _prepare(
    host: RtlPtqRunner, package: bytes, image_id: int, layer_name: str,
    layer_spec: dict[str, Any], a0: bool,
) -> tuple[bytes, bytes, float]:
    started = time.perf_counter_ns()
    image = _input_tensor(package, image_id)
    nodes = host.run(image, image_is_quantized=True)
    _layer_index, input_node, output_node = LAYER_CONTRACT[layer_name]
    raw_ifm = _hwc(image.unsqueeze(0) if input_node is None else nodes[input_node])
    expected = _hwc(nodes[output_node])
    if a0:
        h, w, c = (int(value) for value in layer_spec["ifm_hwc"])
        input_zero_point = int(host.layers[layer_name]["quant"]["input"]["zero_point"])
        ifm, _tiles = pack_legacy_ifm(
            raw_ifm, height=h, width=w, channels=c,
            output_channels=int(layer_spec["ofm_hwc"][2]),
            kernel=int(layer_spec["kernel"]), pad=int(layer_spec["pad"]),
            tile_h=int(layer_spec["tile_h"]), input_zero_point=input_zero_point,
        )
    else:
        ifm = raw_ifm
    return ifm, expected, (time.perf_counter_ns() - started) / 1000.0


def _bound_file(root: Path, raw: object, label: str) -> bytes:
    if not isinstance(raw, dict) or set(raw) != {"path", "bytes", "sha256"}:
        raise NetworkRunnerError(f"{label} file binding is malformed")
    relative = str(raw["path"]).replace("\\", "/")
    path = (root / relative).resolve()
    if root.resolve() not in path.parents or not path.is_file() or path.is_symlink():
        raise NetworkRunnerError(f"{label} source path escapes/is missing")
    payload = path.read_bytes()
    if len(payload) != int(raw["bytes"]) or sha256_file(path) != raw["sha256"]:
        raise NetworkRunnerError(f"{label} source size/hash mismatch")
    return payload


def _secondary_parameters(
    quant_path: Path, layer_name: str, secondary: str,
) -> tuple[int, int, int, bytes, bytes, int, int]:
    if secondary == "none":
        return REP_OVERRIDE_NONE, 0, 0, b"", b"", 0, 0
    quant = json.loads(quant_path.read_text(encoding="utf-8-sig"))
    layers = [item for item in quant.get("layers", []) if item.get("name") == layer_name]
    if len(layers) != 1:
        raise NetworkRunnerError("secondary layer is missing from quantization manifest")
    entry = layers[0]
    files = entry.get("files", {})
    raw_bias = _bound_file(quant_path.parent, files.get("bias_i32"), "bias")
    raw_weight = _bound_file(
        quant_path.parent, files.get("weight_raw_oihw_s8"), "weight")
    base = get_schedule(layer_name)
    if secondary == "sparse3x3":
        if base.layer.kernel != 1 or layer_name not in {
            "m14", "m16", "p4_detect", "p5_detect"
        }:
            raise NetworkRunnerError("sparse3x3 is valid only for native 1x1 layers")
        expanded = bytearray(base.layer.cout * base.layer.cin * 9)
        for cout in range(base.layer.cout):
            for cin in range(base.layer.cin):
                expanded[(cout * base.layer.cin + cin) * 9 + 4] = raw_weight[
                    cout * base.layer.cin + cin
                ]
        raw_weight = bytes(expanded)
        sparse_tile_h = {
            "m14": 4, "m16": 13, "p4_detect": 8, "p5_detect": 8,
        }[layer_name]
        layer = replace(base.layer, kernel=3, pad=1, tile_h=sparse_tile_h)
        mode = REP_OVERRIDE_SPARSE_3X3
    elif secondary == "tile":
        tile_h = {"m13": 4, "m19": 3}.get(layer_name)
        if tile_h is None:
            raise NetworkRunnerError("small-tile override is valid only for m13/m19")
        layer = replace(base.layer, tile_h=tile_h)
        mode = REP_OVERRIDE_TILE
    else:
        raise NetworkRunnerError("unknown secondary representative experiment")
    schedule = schedule_layer(layer)
    bias_tile = build_bias_tile(raw_bias, schedule)
    weight_tile = build_weight_tile(raw_weight, schedule)
    bias = bias_tile * schedule.tile_count
    weight = weight_tile * schedule.tile_count
    if len(bias) != schedule.bias_bytes or len(weight) != schedule.weight_bytes:
        raise NetworkRunnerError("secondary parameter packing length mismatch")
    return (
        mode, schedule.layer.tile_h, schedule.layer.kernel, bias, weight,
        schedule.bias_packets, schedule.weight_packets,
    )


def run(args: argparse.Namespace) -> dict[str, Any]:
    runner_path, runner = _json(args.runner_manifest, "representative runner manifest")
    ablation = runner.get("ablation", {})
    if (
        runner.get("format") != "kv260-coco80-ethernet-runner"
        or runner.get("version") != 1 or not ablation.get("enabled")
        or not ablation.get("representative")
        or ablation.get("representative_layer") != args.layer
        or ablation.get("representative_layer_index") != LAYER_CONTRACT[args.layer][0]
        or str(ablation.get("secondary_experiment") or "none") != args.secondary
    ):
        raise NetworkRunnerError("ELF manifest is not the requested representative runner")
    a0 = ablation.get("hardware_profile") == "abi_v2_ablation_200_a0"
    input_mode = 1 if a0 else 0
    stream_config = 0x29 if a0 else 0x2B
    if (
        ablation.get("representative_input_mode") != input_mode
        or int(str(ablation.get("stream_config")), 0) != stream_config
    ):
        raise NetworkRunnerError("representative ELF input/stream mode is inconsistent")
    bit, bit_sha = _manifest_file(runner.get("bit", {}), "ablation bitstream")
    xsa, xsa_sha = _manifest_file(runner.get("xsa", {}), "ablation XSA")
    elf, elf_sha = _manifest_file(runner.get("elf", {}), "representative ELF")
    parameter, parameter_sha = _manifest_file(
        runner.get("parameter_package", {}), "parameter package"
    )
    quant_path = _file(args.quantization_manifest, "quantization manifest")
    quant_sha = sha256_file(quant_path)
    if quant_sha != runner.get("quantization_manifest_sha256"):
        raise NetworkRunnerError("quantization manifest differs from the ELF binding")
    input_json_path, input_json = _json(args.input_index_json, "input shard manifest")
    binary_meta = input_json.get("binary_index", {})
    binary_path = _file(input_json_path.parent / str(binary_meta.get("path", "")), "input index")
    binary = parse_input_binary_index(binary_path)
    selection_path = _file(args.selection_index_bin, "conformance index")
    selection = parse_conformance_binary(selection_path, binary_path)
    selected = selection["records"][: args.record_count]
    if len(selected) != args.record_count:
        raise NetworkRunnerError("representative record count exceeds the frozen selection")
    model_spec = _file(args.model_spec, "model spec")
    layer_spec = _model_layer(model_spec, args.layer)
    host = RtlPtqRunner(quant_path.parent, "cpu", exact=True)
    (override_mode, override_tile_h, override_kernel, override_bias,
     override_weight, override_bias_packets, override_weight_packets) = (
        _secondary_parameters(quant_path, args.layer, args.secondary)
    )
    if (
        int(ablation.get("representative_override_mode", 0)) != override_mode
        or int(ablation.get("representative_override_tile_h", 0)) != override_tile_h
        or int(ablation.get("representative_override_kernel", 0)) != override_kernel
    ):
        raise NetworkRunnerError("ELF secondary override differs from host request")
    output_dir = Path(args.output_dir).resolve()
    if output_dir.exists() and any(output_dir.iterdir()):
        raise NetworkRunnerError("refusing to overwrite representative output")
    output_dir.mkdir(parents=True, exist_ok=True)
    timing_path = output_dir / "extended_timing.bin"
    samples: list[dict[str, Any]] = []
    binding = binding_sha256(
        bit_sha256=bit_sha, xsa_sha256=xsa_sha, elf_sha256=elf_sha,
        parameter_sha256=parameter_sha, dataset_index_sha256=selection["sha256"],
        quantization_sha256=quant_sha,
    )
    flags = FLAG_ACK_REQUIRED | FLAG_NON_RELEASE | FLAG_ABLATION_REPRESENTATIVE
    session_id = secrets.randbits(64) or 1
    sequence = 1
    input_session_crc = 0
    result_session_crc = 0
    output_kind = OUTPUT_RAW if args.mode == "correctness" else OUTPUT_TIMING
    with timing_path.open("wb") as timing_stream, socket.create_connection(
        (args.board_ip, args.port), timeout=args.connect_timeout
    ) as stream:
        stream.settimeout(args.io_timeout)
        hello = pack_hello(
            flags=flags, bit_sha256=bit_sha, xsa_sha256=xsa_sha,
            elf_sha256=elf_sha, parameter_sha256=parameter_sha,
            dataset_index_sha256=selection["sha256"], quantization_sha256=quant_sha,
            software_build_crc32=int(runner["software_build_crc32"]),
            hardware_build_crc32=int(runner["hardware_build_crc32"]),
            parameter_package_bytes=parameter.stat().st_size, representative=True,
        )
        request = _send(
            stream, message_type=MSG_HELLO, session_id=session_id, sequence=sequence,
            binding=binding, payload=hello, flags=flags,
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
        for logical_index, selected_item in enumerate(selected):
            record_index = int(selected_item["record_index"])
            package, _ = _load_chunk(
                binary["entries"], binary["shards"], input_json_path.parent,
                [record_index],
            )
            image_id = int(selected_item["image_id"])
            ifm, expected, prep_us = _prepare(
                host, package, image_id, args.layer, layer_spec, a0,
            )
            expected_crc = crc32(expected)
            rep_input = pack_representative_input(
                image_id=image_id, layer_index=LAYER_CONTRACT[args.layer][0],
                input_mode=input_mode, stream_config=stream_config, ifm=ifm,
                ofm_bytes=len(expected), expected_ofm_crc32=expected_crc,
                override_mode=override_mode, override_tile_h=override_tile_h,
                override_kernel=override_kernel, bias=override_bias,
                weight=override_weight, bias_packets=override_bias_packets,
                weight_packets=override_weight_packets,
            )
            input_session_crc = zlib.crc32(rep_input, input_session_crc) & 0xFFFFFFFF
            request = _send(
                stream, message_type=MSG_INPUT_CHUNK, session_id=session_id,
                sequence=sequence, binding=binding, payload=rep_input, flags=flags,
                first_record=logical_index, record_count=1, output_kind=output_kind,
                decode_profile=DECODE_DEMO,
            )
            _response(stream, expected_types={MSG_STATUS}, request=request)
            sequence += 1
            request = _send(
                stream, message_type=MSG_RUN, session_id=session_id,
                sequence=sequence, binding=binding, flags=flags,
                first_record=logical_index, record_count=1, output_kind=output_kind,
                decode_profile=DECODE_DEMO,
            )
            result_payload = b""
            if output_kind == OUTPUT_RAW:
                _header, result_payload = _response(
                    stream, expected_types={MSG_RESULT_CHUNK}, request=request
                )
            _header, timing_payload = _response(
                stream, expected_types={MSG_TIMING_CHUNK}, request=request
            )
            chunk = ChunkTiming.unpack(
                timing_payload[:CHUNK_TIMING_BYTES], 1,
                expected_input_payload_bytes=len(rep_input),
            )
            if (
                chunk.first_record != logical_index
                or chunk.input_chunk_crc32 != crc32(rep_input)
                or chunk.result_payload_bytes != len(result_payload)
                or chunk.result_chunk_crc32 != crc32(result_payload)
            ):
                raise NetworkRunnerError("representative timing does not bind its chunk")
            timing_raw = timing_payload[CHUNK_TIMING_BYTES:]
            if len(timing_raw) != EXTENDED_TIMING_BYTES:
                raise NetworkRunnerError("representative timing table has the wrong size")
            timing = ExtendedTiming.unpack(timing_raw)
            if (
                timing.image_id != image_id or timing.stream_config != stream_config
                or timing.output_crc32 != expected_crc
                or timing.pl_layer_ticks[LAYER_CONTRACT[args.layer][0]] == 0
            ):
                raise NetworkRunnerError("representative timing identity/CRC mismatch")
            timing_stream.write(timing_raw)
            if output_kind == OUTPUT_RAW:
                records = list(iter_result_records(result_payload, 1))
                if len(records) != 1 or records[0][0] != image_id:
                    raise NetworkRunnerError("representative result identity mismatch")
                meta, actual = unpack_representative(
                    records[0][1], expected_magic=REP_OUTPUT_MAGIC
                )
                if meta["expected_ofm_crc32"] != expected_crc or actual != expected:
                    raise NetworkRunnerError("representative OFM differs from RTL host golden")
            result_session_crc = zlib.crc32(result_payload, result_session_crc) & 0xFFFFFFFF
            samples.append({
                "logical_index": logical_index, "record_index": record_index,
                "image_id": image_id, "ifm_bytes": len(ifm), "ofm_bytes": len(expected),
                "ofm_crc32": expected_crc, "host_prepare_us": prep_us,
                "pl_us": timing.pl_ticks * 1_000_000.0 / timing.tick_hz,
                "total_us": timing.total_ticks * 1_000_000.0 / timing.tick_hz,
            })
            sequence += 1
        host_end = EndSummary(
            status=0, records_received=len(selected), records_completed=len(selected),
            results_sent=len(selected), error_count=0, input_crc32=input_session_crc,
            result_crc32=result_session_crc,
            parameter_crc32=zlib.crc32(parameter_bytes) & 0xFFFFFFFF,
            reconnect_count=0, elapsed_ticks=0,
        ).pack()
        request = _send(
            stream, message_type=MSG_END, session_id=session_id, sequence=sequence,
            binding=binding, payload=host_end, flags=flags | 2,
        )
        _header, board_end_raw = _response(stream, expected_types={MSG_END}, request=request)
        if len(board_end_raw) != END_BYTES:
            raise NetworkRunnerError("representative END payload size mismatch")
        board_end = EndSummary.unpack(board_end_raw)
        if (
            board_end.status != 0 or board_end.error_count != 0
            or board_end.records_completed != len(selected)
            or board_end.input_crc32 != input_session_crc
            or board_end.result_crc32 != result_session_crc
        ):
            raise NetworkRunnerError("representative END summary mismatch")
    result = {
        "format": FORMAT, "version": VERSION, "status": "PASS",
        "mode": args.mode, "layer": args.layer, "variant": ablation["hardware_profile"],
        "stream_config": f"0x{stream_config:02X}", "records": len(samples),
        "mismatches": 0, "input_mode": "a0_prepacked" if a0 else "raw_hwc",
        "secondary_experiment": args.secondary,
        "artifacts": {
            "runner_manifest": {"path": str(runner_path), "sha256": sha256_file(runner_path)},
            "bit": {"path": str(bit), "sha256": bit_sha},
            "xsa": {"path": str(xsa), "sha256": xsa_sha},
            "elf": {"path": str(elf), "sha256": elf_sha},
            "quantization": {"path": str(quant_path), "sha256": quant_sha},
            "selection": {"path": str(selection_path), "sha256": selection["sha256"]},
            "timing": {"path": str(timing_path), "sha256": sha256_file(timing_path)},
        },
        "samples": samples,
        "end": asdict(board_end),
    }
    write_json_atomic(output_dir / "representative_session.json", result)
    return result


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner-manifest", type=Path, required=True)
    parser.add_argument("--quantization-manifest", type=Path, required=True)
    parser.add_argument("--input-index-json", type=Path, required=True)
    parser.add_argument("--selection-index-bin", type=Path, required=True)
    parser.add_argument("--model-spec", type=Path, required=True)
    parser.add_argument("--layer", choices=tuple(LAYER_CONTRACT), required=True)
    parser.add_argument("--mode", choices=("correctness", "performance"), required=True)
    parser.add_argument(
        "--secondary", choices=("none", "sparse3x3", "tile"), default="none")
    parser.add_argument("--record-count", type=int, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--board-ip", default="192.168.10.2")
    parser.add_argument("--port", type=int, default=5001)
    parser.add_argument("--connect-timeout", type=float, default=30.0)
    parser.add_argument("--io-timeout", type=float, default=180.0)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if not 1 <= args.record_count <= 128:
            raise NetworkRunnerError("record-count must be in [1,128]")
        result = run(args)
    except (OSError, ValueError, KeyError, json.JSONDecodeError, NetworkRunnerError) as exc:
        print(f"FAIL: {exc}")
        return 1
    print(json.dumps({"status": "PASS", "layer": result["layer"],
                      "records": result["records"]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

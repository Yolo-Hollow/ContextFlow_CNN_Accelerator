"""Byte-exact r5 board conformance against the authoritative RTL PTQ graph."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import struct
import subprocess
from typing import Any, Iterable, Mapping
import zlib

import torch

from .assets import sha256_file, write_json_atomic
from .conformance import parse_conformance_binary
from .ptq_runner import RtlPtqRunner
from .sd_pack import (
    HEADER_BYTES,
    HEAD_CHANNELS,
    INPUT_QUANT_MAX,
    INPUT_TENSOR_BYTES,
    MAGIC_INPUT,
    MAGIC_RAW_HEADS,
    P4_BYTES,
    P4_HEIGHT,
    P4_WIDTH,
    P5_BYTES,
    P5_HEIGHT,
    P5_WIDTH,
    crc32_file,
    parse_input_binary_index,
    parse_parameter_package,
    validate_board_node_index,
    validate_board_output_index,
)
from .vitis_headers import TENSOR_NAMES


REPORT_FORMAT = "kv260-coco80-board-conformance-report"
REPORT_VERSION = 1
_HEADER = struct.Struct("<32I")


class BoardConformanceError(RuntimeError):
    pass


class BoardMismatch(BoardConformanceError):
    def __init__(self, message: str, details: Mapping[str, Any]):
        super().__init__(message)
        self.details = dict(details)


def _read_exact(stream: Any, offset: int, size: int, label: str) -> bytes:
    stream.seek(offset)
    payload = stream.read(size)
    if len(payload) != size:
        raise BoardConformanceError(f"short read for {label}: {len(payload)} != {size}")
    return payload


def _first_difference(expected: bytes, actual: bytes) -> int:
    limit = min(len(expected), len(actual))
    for index in range(limit):
        if expected[index] != actual[index]:
            return index
    return limit


def _tensor_hwc_bytes(tensor: torch.Tensor) -> bytes:
    if tensor.dtype != torch.uint8 or tensor.ndim != 4 or tensor.shape[0] != 1:
        raise BoardConformanceError(
            f"host tensor must be [1,C,H,W] uint8, got {tuple(tensor.shape)} {tensor.dtype}"
        )
    return tensor[0].permute(1, 2, 0).contiguous().cpu().numpy().tobytes()


def _validate_raw_package(
    package: bytes,
    *,
    input_crc32: int,
    parameter_crc32: int,
    p4_scale_bits: int,
    p4_zero_point: int,
    p5_scale_bits: int,
    p5_zero_point: int,
) -> tuple[bytes, bytes]:
    expected_bytes = HEADER_BYTES + P4_BYTES + P5_BYTES
    if len(package) != expected_bytes:
        raise BoardConformanceError("raw-head package length is invalid")
    words = _HEADER.unpack_from(package)
    canonical = bytearray(package[:HEADER_BYTES])
    canonical[7 * 4 : 8 * 4] = bytes(4)
    if (
        words[0] != MAGIC_RAW_HEADS
        or words[1] != 1
        or words[2] != HEADER_BYTES
        or words[3] != expected_bytes
        or words[4] != HEADER_BYTES
        or words[5] != P4_BYTES + P5_BYTES
        or words[6] != zlib.crc32(package[HEADER_BYTES:]) & 0xFFFFFFFF
        or words[7] != zlib.crc32(canonical) & 0xFFFFFFFF
        or words[8:14] != (416, 416, 80, 85, 3, 2)
        or words[14:17] != (P4_WIDTH, P4_HEIGHT, HEAD_CHANNELS)
        or words[17:19] != (HEADER_BYTES, P4_BYTES)
        or words[19:21] != (p4_scale_bits, p4_zero_point)
        or words[22:25] != (P5_WIDTH, P5_HEIGHT, HEAD_CHANNELS)
        or words[25:27] != (HEADER_BYTES + P4_BYTES, P5_BYTES)
        or words[27:29] != (p5_scale_bits, p5_zero_point)
        or words[30] != input_crc32
        or words[31] != parameter_crc32
    ):
        raise BoardConformanceError("raw-head package header/binding is invalid")
    p4 = package[HEADER_BYTES : HEADER_BYTES + P4_BYTES]
    p5 = package[HEADER_BYTES + P4_BYTES :]
    if words[21] != zlib.crc32(p4) & 0xFFFFFFFF or words[29] != zlib.crc32(p5) & 0xFFFFFFFF:
        raise BoardConformanceError("raw-head section CRC32 mismatch")
    return p4, p5


def _f32_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", float(value)))[0]


def _require_artifact(path: Path, expected_sha256: str, label: str) -> dict[str, Any]:
    path = path.resolve()
    if not path.is_file() or path.is_symlink():
        raise BoardConformanceError(f"missing regular {label}: {path}")
    digest = sha256_file(path)
    if digest != expected_sha256:
        raise BoardConformanceError(f"{label} SHA256 mismatch")
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": digest}


def _clean_git_provenance() -> dict[str, Any]:
    root = Path(__file__).resolve().parents[2]
    head = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    dirty = subprocess.run(
        ["git", "-C", str(root), "status", "--porcelain"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    if dirty:
        raise BoardConformanceError("formal conformance comparison requires a clean Git worktree")
    tool = Path(__file__).resolve()
    return {
        "git_root": str(root),
        "git_sha": head,
        "git_dirty": False,
        "tool": {
            "path": str(tool),
            "bytes": tool.stat().st_size,
            "sha256": sha256_file(tool),
        },
    }


def compare_board_conformance(
    *,
    sd_root: Path,
    board_output: Path,
    quant_dir: Path,
    runner_manifest: Path,
    elf: Path,
    bit: Path,
    xsa: Path,
) -> dict[str, Any]:
    sd_root = sd_root.resolve()
    board_output = board_output.resolve()
    quant_dir = quant_dir.resolve()
    runner_manifest = runner_manifest.resolve()
    input_root = sd_root / "INPUT"
    input_index_path = input_root / "input_index.bin"
    selection_path = input_root / "conformance_index.bin"
    selection_manifest_path = input_root / "conformance_selection.json"
    parameter_path = sd_root / "PARAM" / "coco80_parameters.c8pa"
    raw_path = board_output / "raw_heads.bin"
    output_index_path = board_output / "output_index.bin"
    nodes_path = board_output / "nodes.bin"
    node_index_path = board_output / "node_index.bin"
    quant_manifest_path = quant_dir / "quantization_manifest.json"
    comparison_provenance = _clean_git_provenance()

    # Windows PowerShell 5.1 writes UTF-8 JSON with a BOM.  The manifest hash
    # remains authoritative; accept that encoding explicitly rather than
    # silently rewriting the build artifact.
    runner_binding = json.loads(runner_manifest.read_text(encoding="utf-8-sig"))
    if (
        runner_binding.get("format") != "kv260-coco80-vitis-elf"
        or runner_binding.get("version") != 1
        or runner_binding.get("mode") != "conformance"
        or runner_binding.get("image_limit") != 128
        or runner_binding.get("release_eligible") is not False
        or runner_binding.get("deployment_override") is not True
    ):
        raise BoardConformanceError("runner manifest is not the epoch1 conformance contract")
    artifacts = {
        "runner_manifest": {
            "path": str(runner_manifest),
            "bytes": runner_manifest.stat().st_size,
            "sha256": sha256_file(runner_manifest),
        },
        "elf": _require_artifact(elf, runner_binding["elf"]["sha256"], "ELF"),
        "bit": _require_artifact(bit, runner_binding["bit_sha256"], "BIT"),
        "xsa": _require_artifact(xsa, runner_binding["xsa_sha256"], "XSA"),
        "quantization_manifest": _require_artifact(
            quant_manifest_path,
            runner_binding["quantization_manifest_sha256"],
            "quantization manifest",
        ),
        "parameter_package": _require_artifact(
            parameter_path,
            runner_binding["sd_parameter_package_sha256"],
            "SD parameter package",
        ),
    }
    parameter = parse_parameter_package(parameter_path)
    parameter_crc = crc32_file(parameter_path)
    selection = parse_conformance_binary(selection_path, input_index_path)
    if sha256_file(selection_manifest_path) != selection["selection_manifest_sha256"]:
        raise BoardConformanceError("selection JSON differs from the selection index binding")
    dense = parse_input_binary_index(input_index_path)
    output = validate_board_output_index(output_index_path, raw_path)
    nodes = validate_board_node_index(node_index_path, nodes_path)
    selected_ids = [entry["image_id"] for entry in selection["records"]]
    if (
        selection["count"] != 128
        or output["input_records"] != 128
        or output["output_records"] != 128
        or nodes["image_records"] != 128
        or nodes["node_records"] != 128 * len(TENSOR_NAMES)
        or output["selection_index_crc32"] != selection["crc32"]
        or nodes["selection_index_crc32"] != selection["crc32"]
        or output["input_index_crc32"] != selection["input_index_crc32"]
        or nodes["input_index_crc32"] != selection["input_index_crc32"]
        or output["parameter_crc32"] != parameter_crc
        or nodes["parameter_crc32"] != parameter_crc
        or [entry["image_id"] for entry in output["entries"]] != selected_ids
        or [nodes["entries"][index * len(TENSOR_NAMES)]["image_id"] for index in range(128)]
        != selected_ids
    ):
        raise BoardConformanceError("board output provenance/count/order binding is inconsistent")

    runner = RtlPtqRunner(quant_dir, "cpu", exact=True)
    p4_quant = runner.layers["p4_detect"]["quant"]["output"]
    p5_quant = runner.layers["p5_detect"]["quant"]["output"]
    per_tensor = {
        name: {
            "tensor_id": tensor_id,
            "records": 0,
            "bytes": 0,
            "host_sha256_state": hashlib.sha256(),
            "board_sha256_state": hashlib.sha256(),
        }
        for tensor_id, name in enumerate(TENSOR_NAMES)
    }
    host_all = hashlib.sha256()
    board_all = hashlib.sha256()
    raw_host = hashlib.sha256()
    raw_board = hashlib.sha256()
    compared_bytes = 0
    shard_streams: dict[int, Any] = {}
    try:
        with nodes_path.open("rb") as node_stream, raw_path.open("rb") as raw_stream:
            for logical_index, selected in enumerate(selection["records"]):
                source_index = selected["record_index"]
                dense_entry = dense["entries"][source_index]
                if dense_entry["image_id"] != selected["image_id"]:
                    raise BoardConformanceError("selection changed after initial validation")
                shard_id = dense_entry["shard_id"]
                if shard_id not in shard_streams:
                    shard_streams[shard_id] = (
                        input_root / dense["shards"][shard_id]["path"]
                    ).open("rb")
                package = _read_exact(
                    shard_streams[shard_id], dense_entry["offset"], dense_entry["bytes"],
                    f"input image {selected['image_id']}",
                )
                package_crc = zlib.crc32(package) & 0xFFFFFFFF
                words = _HEADER.unpack_from(package)
                payload = package[HEADER_BYTES:]
                if (
                    package_crc != dense_entry["package_crc32"]
                    or words[0] != MAGIC_INPUT
                    or words[3] != len(package)
                    or words[4] != HEADER_BYTES
                    or words[5] != INPUT_TENSOR_BYTES
                    or words[8] != selected["image_id"]
                    or len(payload) != INPUT_TENSOR_BYTES
                    or max(payload) > INPUT_QUANT_MAX
                ):
                    raise BoardConformanceError(
                        f"selected input package is invalid for image {selected['image_id']}"
                    )
                image = torch.frombuffer(bytearray(payload), dtype=torch.uint8).reshape(
                    416, 416, 3
                ).permute(2, 0, 1).contiguous()
                host_nodes = runner.run(image, image_is_quantized=True)
                if tuple(host_nodes) != TENSOR_NAMES:
                    raise BoardConformanceError("RTL runner node order changed")
                expected_heads: dict[str, bytes] = {}
                for tensor_id, name in enumerate(TENSOR_NAMES):
                    expected = _tensor_hwc_bytes(host_nodes[name])
                    node_entry = nodes["entries"][logical_index * len(TENSOR_NAMES) + tensor_id]
                    actual = _read_exact(
                        node_stream, node_entry["offset"], node_entry["bytes"],
                        f"board node {logical_index}:{name}",
                    )
                    if node_entry["image_id"] != selected["image_id"] or len(actual) != len(expected):
                        raise BoardConformanceError(
                            f"board node metadata differs for image {selected['image_id']} tensor {name}"
                        )
                    if actual != expected:
                        first = _first_difference(expected, actual)
                        raise BoardMismatch(
                            "board tensor differs from RTL-semantic golden",
                            {
                                "logical_index": logical_index,
                                "image_id": selected["image_id"],
                                "tensor_id": tensor_id,
                                "tensor": name,
                                "byte_index": first,
                                "expected": expected[first] if first < len(expected) else None,
                                "actual": actual[first] if first < len(actual) else None,
                                "host_sha256": hashlib.sha256(expected).hexdigest(),
                                "board_sha256": hashlib.sha256(actual).hexdigest(),
                            },
                        )
                    stats = per_tensor[name]
                    stats["records"] += 1
                    stats["bytes"] += len(expected)
                    stats["host_sha256_state"].update(expected)
                    stats["board_sha256_state"].update(actual)
                    host_all.update(expected)
                    board_all.update(actual)
                    compared_bytes += len(expected)
                    if name in ("p4_detect", "p5_detect"):
                        expected_heads[name] = expected
                raw_entry = output["entries"][logical_index]
                raw_package = _read_exact(
                    raw_stream, raw_entry["offset"], raw_entry["bytes"],
                    f"raw heads {logical_index}",
                )
                p4, p5 = _validate_raw_package(
                    raw_package,
                    input_crc32=package_crc,
                    parameter_crc32=parameter_crc,
                    p4_scale_bits=_f32_bits(p4_quant["scale"]),
                    p4_zero_point=int(p4_quant["zero_point"]),
                    p5_scale_bits=_f32_bits(p5_quant["scale"]),
                    p5_zero_point=int(p5_quant["zero_point"]),
                )
                expected_raw = expected_heads["p4_detect"] + expected_heads["p5_detect"]
                actual_raw = p4 + p5
                if actual_raw != expected_raw:
                    first = _first_difference(expected_raw, actual_raw)
                    raise BoardMismatch(
                        "board raw heads differ from RTL-semantic golden",
                        {
                            "logical_index": logical_index,
                            "image_id": selected["image_id"],
                            "byte_index": first,
                            "expected": expected_raw[first],
                            "actual": actual_raw[first],
                        },
                    )
                raw_host.update(expected_raw)
                raw_board.update(actual_raw)
    finally:
        for stream in shard_streams.values():
            stream.close()

    tensor_results = []
    for name in TENSOR_NAMES:
        stats = per_tensor[name]
        tensor_results.append({
            "name": name,
            "tensor_id": stats["tensor_id"],
            "records": stats["records"],
            "bytes": stats["bytes"],
            "host_sha256": stats["host_sha256_state"].hexdigest(),
            "board_sha256": stats["board_sha256_state"].hexdigest(),
            "exact": stats["host_sha256_state"].digest() == stats["board_sha256_state"].digest(),
        })
    artifacts.update({
        "selection_manifest": {
            "path": str(selection_manifest_path),
            "bytes": selection_manifest_path.stat().st_size,
            "sha256": sha256_file(selection_manifest_path),
        },
        "selection_index": {
            "path": str(selection_path), "bytes": selection["bytes"],
            "sha256": selection["sha256"], "crc32": selection["crc32"],
        },
        "input_index": {
            "path": str(input_index_path), "bytes": dense["bytes"],
            "sha256": dense["sha256"], "crc32": dense["crc32"],
        },
        "board_output_index": {
            "path": str(output_index_path), "sha256": output["index_sha256"],
        },
        "board_raw_heads": {
            "path": str(raw_path), "bytes": output["data_bytes"],
            "sha256": output["data_sha256"],
        },
        "board_node_index": {
            "path": str(node_index_path), "sha256": nodes["index_sha256"],
        },
        "board_nodes": {
            "path": str(nodes_path), "bytes": nodes["data_bytes"],
            "sha256": nodes["data_sha256"],
        },
    })
    return {
        "format": REPORT_FORMAT,
        "version": REPORT_VERSION,
        "status": "PASS",
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "authority": "RtlPtqRunner exact=True float64 integer convolution",
        "release_eligible": False,
        "deployment_override": True,
        "comparison_provenance": comparison_provenance,
        "images": 128,
        "nodes_per_image": len(TENSOR_NAMES),
        "node_records": 128 * len(TENSOR_NAMES),
        "node_bytes_compared": compared_bytes,
        "raw_head_records": 128,
        "raw_head_payload_bytes_compared": 128 * (P4_BYTES + P5_BYTES),
        "mismatch_count": 0,
        "node_stream": {
            "host_sha256": host_all.hexdigest(),
            "board_sha256": board_all.hexdigest(),
            "exact": host_all.digest() == board_all.digest(),
        },
        "raw_head_stream": {
            "host_sha256": raw_host.hexdigest(),
            "board_sha256": raw_board.hexdigest(),
            "exact": raw_host.digest() == raw_board.digest(),
        },
        "tensors": tensor_results,
        "selection": {
            "count": selection["count"],
            "first": selection["records"][0],
            "last": selection["records"][-1],
            "image_ids": selected_ids,
        },
        "parameter": {
            "package_crc32": parameter_crc,
            "model_sha256": parameter["model_sha256"],
        },
        "artifacts": artifacts,
    }


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sd-root", type=Path, required=True)
    parser.add_argument("--board-output", type=Path, required=True)
    parser.add_argument("--quant-dir", type=Path, required=True)
    parser.add_argument("--runner-manifest", type=Path, required=True)
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--bit", type=Path, required=True)
    parser.add_argument("--xsa", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args(list(argv) if argv is not None else None)
    try:
        report = compare_board_conformance(
            sd_root=args.sd_root,
            board_output=args.board_output,
            quant_dir=args.quant_dir,
            runner_manifest=args.runner_manifest,
            elf=args.elf,
            bit=args.bit,
            xsa=args.xsa,
        )
        exit_code = 0
    except Exception as error:
        report = {
            "format": REPORT_FORMAT,
            "version": REPORT_VERSION,
            "status": "FAIL",
            "generated_utc": datetime.now(timezone.utc).isoformat(),
            "error_type": type(error).__name__,
            "error": str(error),
        }
        if isinstance(error, BoardMismatch):
            report["first_mismatch"] = error.details
        exit_code = 1
    write_json_atomic(args.report, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

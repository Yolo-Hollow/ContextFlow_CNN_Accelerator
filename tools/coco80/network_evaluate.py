"""Compare Ethernet A53 detections with canonical host post-processing."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import struct
from typing import Any, Mapping, Sequence
import zlib

import numpy as np
import torch

from .assets import sha256_file, write_json_atomic
from .board_conformance import BoardConformanceError, _validate_raw_package
from .board_evaluate import _head_quantization
from .conformance import parse_conformance_binary
from .evaluate import evaluate_coco_detailed
from .postprocess import NmsConfig, decode_quantized_heads_u8, non_max_suppression
from .schemas import LetterboxMetadata
from .sd_pack import (
    COCO80_TO_COCO91, DETECTION_RECORD_BYTES, HEADER_BYTES, MAGIC_DETECTIONS,
    MAX_DETECTIONS, MAX_NMS, P4_HEIGHT, P4_WIDTH, P5_HEIGHT, P5_WIDTH,
    parse_parameter_package, validate_board_output_index,
)


FORMAT = "kv260-coco80-ethernet-product-evaluation"
VERSION = 1
HEADER = struct.Struct("<32I")
DETECTION = struct.Struct("<16I")


class NetworkEvaluationError(RuntimeError):
    """The product output cannot be proven equivalent to the host contract."""


def _json(path: str | Path, label: str) -> tuple[Path, dict[str, Any]]:
    target = Path(path).resolve()
    if target.is_symlink() or not target.is_file():
        raise NetworkEvaluationError(f"{label} is not a regular file: {target}")
    try:
        value = json.loads(target.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise NetworkEvaluationError(f"cannot parse {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise NetworkEvaluationError(f"{label} must be one JSON object")
    return target, value


def _f32(word: int) -> float:
    return struct.unpack("<f", struct.pack("<I", word))[0]


def _board_detections(
    package: bytes, *, image_id: int, input_crc32: int,
    raw_crc32: int, profile: str,
) -> list[dict[str, Any]]:
    if len(package) < HEADER_BYTES:
        raise NetworkEvaluationError("detection package is shorter than its header")
    words = HEADER.unpack_from(package)
    header = bytearray(package[:HEADER_BYTES]); header[28:32] = bytes(4)
    confidence, iou = _f32(words[20]), _f32(words[21])
    expected = (0.001, 0.65, 1) if profile == "accuracy" else (0.25, 0.45, 0)
    if (
        words[0] != MAGIC_DETECTIONS or words[1] != 1 or words[2] != HEADER_BYTES
        or words[3] != len(package) or words[4] != HEADER_BYTES
        or words[5] != len(package) - HEADER_BYTES
        or (zlib.crc32(header) & 0xFFFFFFFF) != words[7]
        or (zlib.crc32(package[HEADER_BYTES:]) & 0xFFFFFFFF) != words[6]
        or words[8] != image_id or words[9] > MAX_DETECTIONS
        or words[10] != DETECTION_RECORD_BYTES or words[11] != MAX_NMS
        or words[12] != MAX_DETECTIONS or words[13] != 80 or words[14] != 1
        or words[15] != raw_crc32 or words[16] != input_crc32
        or words[17] != HEADER_BYTES or words[18] != words[9] * DETECTION_RECORD_BYTES
        or words[19] != (zlib.crc32(package[HEADER_BYTES:]) & 0xFFFFFFFF)
        or abs(confidence - expected[0]) > 1e-8
        or abs(iou - expected[1]) > 1e-7 or words[22] != expected[2]
        or words[23] != 1 or words[24] == 0 or words[25] == 0 or any(words[26:])
    ):
        raise NetworkEvaluationError(f"detection package {image_id} header/binding is invalid")
    records: list[dict[str, Any]] = []
    previous: tuple[float, int, int] | None = None
    for index in range(words[9]):
        row = DETECTION.unpack_from(package, HEADER_BYTES + index * DETECTION_RECORD_BYTES)
        x1, y1, x2, y2, score = (_f32(value) for value in row[1:6])
        class_id, category_id, source = row[6:9]
        head_id, anchor_id, grid_x, grid_y = row[9:13]
        grid_w, grid_h, base = (26, 26, 0) if head_id == 0 else (13, 13, 2028)
        expected_source = base + anchor_id * grid_w * grid_h + grid_y * grid_w + grid_x
        key = (score, source, class_id)
        if (
            row[0] != image_id or not all(math.isfinite(value) for value in (x1, y1, x2, y2, score))
            or x1 < 0 or y1 < 0 or x2 < x1 or y2 < y1
            or not score > confidence or score > 1 or class_id >= 80
            or category_id != COCO80_TO_COCO91[class_id]
            or head_id > 1 or anchor_id >= 3 or grid_x >= grid_w or grid_y >= grid_h
            or source != expected_source or any(row[13:])
            or (previous is not None and (
                score > previous[0]
                or (score == previous[0] and (source < previous[1] or (source == previous[1] and class_id < previous[2])))
            ))
        ):
            raise NetworkEvaluationError(f"detection package {image_id} record {index} is invalid")
        previous = key
        records.append({
            "image_id": image_id, "x1": x1, "y1": y1, "x2": x2, "y2": y2,
            "score": score, "class_id": class_id, "category_id": category_id,
            "source_index": source,
        })
    return records


def _inverse_host(row: Sequence[float], meta: LetterboxMetadata) -> dict[str, Any]:
    x1, y1, x2, y2, score, class_id, source = row
    x1 = min(max((x1 - meta.pad_left) / meta.scale, 0.0), float(meta.source_width))
    y1 = min(max((y1 - meta.pad_top) / meta.scale, 0.0), float(meta.source_height))
    x2 = min(max((x2 - meta.pad_left) / meta.scale, 0.0), float(meta.source_width))
    y2 = min(max((y2 - meta.pad_top) / meta.scale, 0.0), float(meta.source_height))
    class_index = int(class_id)
    return {
        "x1": x1, "y1": y1, "x2": x2, "y2": y2, "score": float(score),
        "class_id": class_index, "category_id": COCO80_TO_COCO91[class_index],
        "source_index": int(source),
    }


def _prediction(record: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "image_id": int(record["image_id"]),
        "category_id": int(record["category_id"]),
        "bbox": [
            float(record["x1"]), float(record["y1"]),
            max(0.0, float(record["x2"]) - float(record["x1"])),
            max(0.0, float(record["y2"]) - float(record["y1"])),
        ],
        "score": float(record["score"]),
    }


@torch.inference_mode()
def run_evaluation(args: argparse.Namespace) -> dict[str, Any]:
    if args.score_tolerance < 0 or args.box_tolerance < 0 or args.metric_tolerance < 0:
        raise NetworkEvaluationError("comparison tolerances must be nonnegative")
    network_dir = Path(args.network_output).resolve()
    network_summary_path, network_summary = _json(network_dir / "summary.json", "network summary")
    result_index_path, result_index = _json(network_dir / "results_index.json", "network result index")
    network_mode = network_summary.get("mode")
    if (
        network_summary.get("format") != "kv260-coco80-ethernet-validation"
        or network_summary.get("status") != "PASS"
        or network_mode not in ("detections-accuracy", "detections-demo")
        or result_index.get("mode") != network_mode
    ):
        raise NetworkEvaluationError("network output is not a completed detection run")
    profile = "accuracy" if network_mode == "detections-accuracy" else "demo"
    result_file = network_dir / "detections.bin"
    if not result_file.is_file():
        raise NetworkEvaluationError("network detection stream is missing")
    result_meta = network_summary.get("artifacts", {}).get("results", {})
    if result_meta.get("bytes") != result_file.stat().st_size or result_meta.get("sha256") != sha256_file(result_file):
        raise NetworkEvaluationError("network detection stream differs from its summary")
    result_entries = result_index.get("entries")
    if not isinstance(result_entries, list) or len(result_entries) != network_summary.get("record_count"):
        raise NetworkEvaluationError("network result index cardinality is invalid")

    input_path, input_manifest = _json(args.input_index_json, "input index manifest")
    input_entries = input_manifest.get("entries")
    if not isinstance(input_entries, list) or len(input_entries) < len(result_entries):
        raise NetworkEvaluationError("input index does not cover the product output")
    selection: dict[str, Any] | None = None
    selection_meta = network_summary.get("selection")
    if selection_meta is not None:
        selection_artifact = network_summary.get("artifacts", {}).get("selection_index", {})
        binary_meta = input_manifest.get("binary_index", {})
        selection_path = Path(str(selection_artifact.get("path", ""))).resolve()
        binary_path = (input_path.parent / str(binary_meta.get("path", ""))).resolve()
        if (
            not isinstance(selection_meta, dict)
            or selection_path.is_symlink() or not selection_path.is_file()
            or binary_path.is_symlink() or not binary_path.is_file()
            or selection_artifact.get("bytes") != selection_path.stat().st_size
            or selection_artifact.get("sha256") != sha256_file(selection_path)
            or binary_meta.get("sha256") != sha256_file(binary_path)
        ):
            raise NetworkEvaluationError("selection/input-index artifact binding is invalid")
        try:
            selection = parse_conformance_binary(selection_path, binary_path)
        except RuntimeError as exc:
            raise NetworkEvaluationError(f"selection index is invalid: {exc}") from exc
        if (
            selection_meta.get("count") != selection["count"]
            or selection_meta.get("crc32") != selection["crc32"]
            or selection_meta.get("sha256") != selection["sha256"]
            or selection["count"] != len(result_entries)
        ):
            raise NetworkEvaluationError("selection summary differs from its validated index")
    raw_dir = Path(args.canonical_raw_output).resolve()
    raw_index = validate_board_output_index(raw_dir / "output_index.bin", raw_dir / "raw_heads.bin")
    if raw_index["mode"] != 0 or len(raw_index["entries"]) < len(result_entries):
        raise NetworkEvaluationError("canonical raw-head output does not cover product records")
    quant = _head_quantization(Path(args.quantization_manifest))
    parameter = parse_parameter_package(args.parameter_package)
    if raw_index["parameter_crc32"] != parameter["package_crc32"]:
        raise NetworkEvaluationError("canonical raw heads use a different parameter package")
    expected_selection_crc = 0 if selection is None else selection["crc32"]
    if raw_index.get("selection_index_crc32", 0) != expected_selection_crc:
        raise NetworkEvaluationError("canonical raw heads use a different record selection")

    config = NmsConfig.accuracy() if profile == "accuracy" else NmsConfig.demo()
    device = torch.device(args.device)
    board_predictions: list[dict[str, Any]] = []
    host_predictions: list[dict[str, Any]] = []
    max_score_delta = 0.0
    max_box_delta = 0.0
    compared = 0
    first_record = int(network_summary.get("first_record", -1))
    with result_file.open("rb") as board_stream, (raw_dir / "raw_heads.bin").open("rb") as raw_stream:
        for local, result_entry in enumerate(result_entries):
            stream_record_index = first_record + local
            dataset_record_index = stream_record_index
            if selection is not None:
                stream_record_index = local
                dataset_record_index = int(selection["records"][local]["record_index"])
            input_entry = input_entries[dataset_record_index]
            raw_entry = raw_index["entries"][stream_record_index]
            if (
                result_entry.get("record_index") != stream_record_index
                or raw_entry.get("record_index") != stream_record_index
                or result_entry.get("image_id") != input_entry.get("image_id")
                or raw_entry["image_id"] != input_entry.get("image_id")
            ):
                raise NetworkEvaluationError(
                    f"input/raw/product ordering differs at stream record {stream_record_index}"
                )
            board_stream.seek(result_entry["offset"])
            package = board_stream.read(result_entry["bytes"])
            if len(package) != result_entry["bytes"] or (zlib.crc32(package) & 0xFFFFFFFF) != result_entry["crc32"]:
                raise NetworkEvaluationError(
                    f"product package {stream_record_index} CRC/size mismatch"
                )
            raw_stream.seek(raw_entry["offset"])
            raw_package = raw_stream.read(raw_entry["bytes"])
            try:
                p4_bytes, p5_bytes = _validate_raw_package(
                    raw_package,
                    input_crc32=input_entry["package"]["package_crc32"],
                    parameter_crc32=parameter["package_crc32"],
                    p4_scale_bits=quant["p4_detect"]["scale_bits"],
                    p4_zero_point=quant["p4_detect"]["zero_point"],
                    p5_scale_bits=quant["p5_detect"]["scale_bits"],
                    p5_zero_point=quant["p5_detect"]["zero_point"],
                )
            except BoardConformanceError as exc:
                raise NetworkEvaluationError(
                    f"canonical raw package {stream_record_index} is invalid: {exc}"
                ) from exc
            board = _board_detections(
                package, image_id=input_entry["image_id"],
                input_crc32=input_entry["package"]["package_crc32"],
                raw_crc32=raw_entry["crc32"], profile=profile,
            )
            p4 = torch.from_numpy(
                np.frombuffer(p4_bytes, dtype=np.uint8).reshape(1, P4_HEIGHT, P4_WIDTH, 255).copy()
            ).to(device).permute(0, 3, 1, 2).contiguous()
            p5 = torch.from_numpy(
                np.frombuffer(p5_bytes, dtype=np.uint8).reshape(1, P5_HEIGHT, P5_WIDTH, 255).copy()
            ).to(device).permute(0, 3, 1, 2).contiguous()
            decoded = decode_quantized_heads_u8(
                p4, p5,
                p4_scale=quant["p4_detect"]["scale"],
                p4_zero_point=quant["p4_detect"]["zero_point"],
                p5_scale=quant["p5_detect"]["scale"],
                p5_zero_point=quant["p5_detect"]["zero_point"],
            )
            host_tensor = non_max_suppression(decoded, config)[0]
            meta = LetterboxMetadata.from_dict(input_entry["letterbox"])
            host = [_inverse_host(row, meta) for row in host_tensor.cpu().tolist()]
            if len(board) != len(host):
                raise NetworkEvaluationError(
                    f"detection count differs at image {input_entry['image_id']}: board={len(board)} host={len(host)}"
                )
            for position, (actual, expected) in enumerate(zip(board, host)):
                if (
                    actual["class_id"] != expected["class_id"]
                    or actual["source_index"] != expected["source_index"]
                    or actual["category_id"] != expected["category_id"]
                ):
                    board_key = (actual["class_id"], actual["source_index"])
                    host_key = (expected["class_id"], expected["source_index"])
                    actual_host_position = next(
                        (i for i, item in enumerate(host)
                         if (item["class_id"], item["source_index"]) == board_key),
                        None,
                    )
                    expected_board_position = next(
                        (i for i, item in enumerate(board)
                         if (item["class_id"], item["source_index"]) == host_key),
                        None,
                    )
                    raise NetworkEvaluationError(
                        f"class/source/order differs at image {input_entry['image_id']} "
                        f"detection {position}: board={actual} host={expected} "
                        f"board_item_host_position={actual_host_position} "
                        f"host_item_board_position={expected_board_position}"
                    )
                score_delta = abs(actual["score"] - expected["score"])
                box_delta = max(abs(actual[key] - expected[key]) for key in ("x1", "y1", "x2", "y2"))
                max_score_delta = max(max_score_delta, score_delta)
                max_box_delta = max(max_box_delta, box_delta)
                if score_delta > args.score_tolerance or box_delta > args.box_tolerance:
                    raise NetworkEvaluationError(
                        f"numeric mismatch at image {input_entry['image_id']} detection {position}: "
                        f"score={score_delta} box={box_delta}"
                    )
                board_predictions.append(_prediction(actual))
                host_predictions.append(_prediction({"image_id": input_entry["image_id"], **expected}))
            compared += 1
            if compared % 100 == 0 or compared == len(result_entries):
                print(f"product: {compared}/{len(result_entries)} images", flush=True)

    if selection is None:
        selected_input_entries = input_entries[first_record:first_record + len(result_entries)]
    else:
        selected_input_entries = [
            input_entries[int(item["record_index"])] for item in selection["records"]
        ]
    image_ids = [entry["image_id"] for entry in selected_input_entries]
    board_coco = evaluate_coco_detailed(args.annotations, board_predictions, image_ids=image_ids)
    host_coco = evaluate_coco_detailed(args.annotations, host_predictions, image_ids=image_ids)
    metric_delta = max(
        abs(float(board_coco["metrics"][key]) - float(host_coco["metrics"][key]))
        for key in board_coco["metrics"]
        if isinstance(board_coco["metrics"][key], (int, float))
        and isinstance(host_coco["metrics"].get(key), (int, float))
    )
    if metric_delta > args.metric_tolerance:
        raise NetworkEvaluationError(f"board and canonical product metrics differ by {metric_delta}")
    output = Path(args.output_dir).resolve()
    if output.exists():
        raise NetworkEvaluationError(f"refusing to overwrite output directory: {output}")
    output.mkdir(parents=True)
    write_json_atomic(output / "board_predictions.json", board_predictions)
    write_json_atomic(output / "host_predictions.json", host_predictions)
    summary = {
        "format": FORMAT, "version": VERSION, "status": "PASS", "images": compared,
        "profile": profile,
        "comparison": {
            "score_tolerance": args.score_tolerance,
            "bbox_tolerance_pixels": args.box_tolerance,
            "metric_tolerance": args.metric_tolerance,
            "max_score_abs_delta": max_score_delta,
            "max_bbox_abs_delta_pixels": max_box_delta,
            "max_metric_abs_delta": metric_delta,
        },
        "board_coco": board_coco, "canonical_host_coco": host_coco,
        "artifacts": {
            "network_summary": {"path": str(network_summary_path), "sha256": sha256_file(network_summary_path)},
            "result_index": {"path": str(result_index_path), "sha256": sha256_file(result_index_path)},
            "detections": {"path": str(result_file), "sha256": sha256_file(result_file)},
            "canonical_raw": {"path": str(raw_dir / "raw_heads.bin"), "sha256": raw_index["data_sha256"]},
            "input_index": {"path": str(input_path), "sha256": sha256_file(input_path)},
        },
    }
    write_json_atomic(output / "summary.json", summary)
    return summary


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--network-output", type=Path, required=True)
    parser.add_argument("--canonical-raw-output", type=Path, required=True)
    parser.add_argument("--input-index-json", type=Path, required=True)
    parser.add_argument("--quantization-manifest", type=Path, required=True)
    parser.add_argument("--parameter-package", type=Path, required=True)
    parser.add_argument("--annotations", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--score-tolerance", type=float, default=2e-5)
    parser.add_argument("--box-tolerance", type=float, default=1e-3)
    parser.add_argument("--metric-tolerance", type=float, default=1e-6)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        summary = run_evaluation(args)
    except (NetworkEvaluationError, OSError, ValueError) as exc:
        print(f"FAIL: {exc}")
        return 1
    print(json.dumps({
        "status": summary["status"], "images": summary["images"],
        "max_score_delta": summary["comparison"]["max_score_abs_delta"],
        "max_box_delta": summary["comparison"]["max_bbox_abs_delta_pixels"],
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

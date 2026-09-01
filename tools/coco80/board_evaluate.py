"""Evaluate aggregate r5 board raw heads with the canonical COCO80 contract."""

from __future__ import annotations

import argparse
import json
import math
import platform
from pathlib import Path
import subprocess
import time
from typing import Any, Mapping, Sequence

import numpy as np
import torch

from .assets import sha256_file, write_json_atomic
from .board_conformance import BoardConformanceError, _f32_bits, _validate_raw_package
from .evaluate import evaluate_coco_detailed
from .postprocess import NmsConfig, decode_heads, detections_to_coco, non_max_suppression
from .schemas import LetterboxMetadata
from .sd_pack import (
    P4_BYTES,
    P4_HEIGHT,
    P4_WIDTH,
    P5_BYTES,
    P5_HEIGHT,
    P5_WIDTH,
    crc32_file,
    parse_input_binary_index,
    parse_parameter_package,
    validate_board_output_index,
)


FORMAT = "kv260-coco80-board-network-evaluation"
VERSION = 1


class BoardEvaluationError(RuntimeError):
    """The board output cannot be proven to satisfy the evaluation contract."""


def _regular(path: str | Path, label: str) -> Path:
    target = Path(path).resolve()
    if target.is_symlink() or not target.is_file():
        raise BoardEvaluationError(f"{label} is not a regular file: {target}")
    return target


def _load_json(path: str | Path, label: str) -> tuple[Path, dict[str, Any]]:
    target = _regular(path, label)
    try:
        # PowerShell 5.1 emits UTF-8 JSON with a BOM.  Decode it explicitly
        # while continuing to hash and archive the exact on-disk bytes.
        value = json.loads(target.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BoardEvaluationError(f"cannot parse {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise BoardEvaluationError(f"{label} must contain one JSON object")
    return target, value


def _head_quantization(path: Path) -> dict[str, dict[str, Any]]:
    target, manifest = _load_json(path, "quantization manifest")
    if (
        manifest.get("format") != "kv260-coco80-rtl-quantization"
        or manifest.get("version") != 1
        or manifest.get("activation_quant_range") != [0, 127]
        or manifest.get("weight_qscheme") != "per_tensor_symmetric_s8_zp0"
    ):
        raise BoardEvaluationError("quantization manifest is not the r5 reduced-range contract")
    layers = manifest.get("layers")
    if not isinstance(layers, list) or len(layers) != 13:
        raise BoardEvaluationError("quantization manifest must contain exactly 13 layers")
    result: dict[str, dict[str, Any]] = {}
    for name, shape in (("p4_detect", [26, 26, 255]), ("p5_detect", [13, 13, 255])):
        matches = [layer for layer in layers if isinstance(layer, Mapping) and layer.get("name") == name]
        if len(matches) != 1 or matches[0].get("ofm_hwc") != shape:
            raise BoardEvaluationError(f"quantization manifest has an invalid {name} layer")
        quant = matches[0].get("quant")
        output = quant.get("output") if isinstance(quant, Mapping) else None
        if not isinstance(output, Mapping) or output.get("qmin") != 0 or output.get("qmax") != 127:
            raise BoardEvaluationError(f"{name} output is not reduced-range uint8")
        scale = output.get("scale")
        zero_point = output.get("zero_point")
        if (
            isinstance(scale, bool)
            or not isinstance(scale, (int, float))
            or not math.isfinite(float(scale))
            or float(scale) <= 0.0
            or isinstance(zero_point, bool)
            or not isinstance(zero_point, int)
            or not 0 <= zero_point <= 127
        ):
            raise BoardEvaluationError(f"{name} output quantization is invalid")
        result[name] = {
            "scale": float(scale),
            "scale_bits": _f32_bits(float(scale)),
            "zero_point": zero_point,
        }
    result["manifest"] = {
        "path": str(target),
        "bytes": target.stat().st_size,
        "sha256": sha256_file(target),
    }
    return result


def _input_contract(
    json_path: Path,
    binary_path: Path,
    board: Mapping[str, Any],
    expected_count: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    json_file, manifest = _load_json(json_path, "input shard manifest")
    binary_file = _regular(binary_path, "binary input index")
    if (
        manifest.get("schema") != "coco80.sd-input-shards.v1"
        or manifest.get("protocol_version") != 1
        or manifest.get("image_count") != expected_count
        or manifest.get("model_shape_hwc") != [416, 416, 3]
        or manifest.get("input_quant_range") != [0, 127]
    ):
        raise BoardEvaluationError("input shard manifest is not the expected full-val contract")
    canonical = (
        json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n"
    ).encode("utf-8")
    if json_file.read_bytes() != canonical:
        raise BoardEvaluationError("input shard manifest is not canonical JSON")
    binary = parse_input_binary_index(binary_file)
    meta = manifest.get("binary_index")
    if not isinstance(meta, Mapping):
        raise BoardEvaluationError("input shard manifest lacks binary_index")
    for key in ("bytes", "crc32", "sha256", "content_sha256", "source_set_sha256"):
        if meta.get(key) != binary.get(key):
            raise BoardEvaluationError(f"input JSON and binary index differ at {key}")
    if (
        binary["image_count"] != expected_count
        or board["input_records"] != expected_count
        or board["output_records"] != expected_count
        or board["input_index_crc32"] != binary["crc32"]
    ):
        raise BoardEvaluationError("board output is not bound to the expected input index")
    json_entries = manifest.get("entries")
    if not isinstance(json_entries, list) or len(json_entries) != expected_count:
        raise BoardEvaluationError("input JSON entry count is invalid")
    for index, (json_entry, binary_entry, output_entry) in enumerate(
        zip(json_entries, binary["entries"], board["entries"])
    ):
        package = json_entry.get("package") if isinstance(json_entry, Mapping) else None
        if (
            not isinstance(json_entry, Mapping)
            or not isinstance(package, Mapping)
            or json_entry.get("image_id") != binary_entry["image_id"]
            or json_entry.get("record_index") != index
            or binary_entry["record_index"] != index
            or binary_entry["package_crc32"] != package.get("package_crc32")
            or output_entry["image_id"] != binary_entry["image_id"]
            or output_entry["record_index"] != index
        ):
            raise BoardEvaluationError(f"input/output ordering differs at record {index}")
        try:
            LetterboxMetadata.from_dict(json_entry.get("letterbox"))
        except (TypeError, ValueError) as exc:
            raise BoardEvaluationError(f"invalid letterbox metadata at record {index}: {exc}") from exc
    return json_entries, {
        "manifest": {
            "path": str(json_file),
            "bytes": json_file.stat().st_size,
            "sha256": sha256_file(json_file),
        },
        "binary_index": {
            "path": str(binary_file),
            "bytes": binary["bytes"],
            "crc32": binary["crc32"],
            "sha256": binary["sha256"],
            "source_set_sha256": binary["source_set_sha256"],
        },
    }


def _runner_binding(
    runner_manifest_path: Path,
    quant_sha256: str,
    parameter_manifest_path: Path,
    parameter_package_path: Path,
    bit_path: Path,
    xsa_path: Path,
    elf_path: Path,
    expected_count: int,
) -> dict[str, Any]:
    runner_file, runner = _load_json(runner_manifest_path, "Vitis runner manifest")
    parameter_manifest = _regular(parameter_manifest_path, "parameter manifest")
    bit = _regular(bit_path, "r5 bitstream")
    xsa = _regular(xsa_path, "r5 XSA")
    elf = _regular(elf_path, "accuracy ELF")
    parameter_package = _regular(parameter_package_path, "SD parameter package")
    parameter = parse_parameter_package(parameter_package)
    expected = {
        "quantization_manifest_sha256": quant_sha256,
        "parameter_manifest_sha256": sha256_file(parameter_manifest),
        "sd_parameter_package_sha256": sha256_file(parameter_package),
        "bit_sha256": sha256_file(bit),
        "xsa_sha256": sha256_file(xsa),
    }
    if (
        runner.get("format") != "kv260-coco80-vitis-elf"
        or runner.get("version") != 1
        or runner.get("mode") != "accuracy"
        or runner.get("image_limit") != expected_count
        or runner.get("release_eligible") is not False
        or runner.get("deployment_override") is not True
    ):
        raise BoardEvaluationError("Vitis runner manifest is not the epoch1 accuracy contract")
    for key, value in expected.items():
        if runner.get(key) != value:
            raise BoardEvaluationError(f"Vitis runner manifest differs at {key}")
    elf_meta = runner.get("elf")
    elf_sha = sha256_file(elf)
    if not isinstance(elf_meta, Mapping) or elf_meta.get("bytes") != elf.stat().st_size or elf_meta.get("sha256") != elf_sha:
        raise BoardEvaluationError("accuracy ELF differs from the Vitis runner manifest")
    return {
        "runner_manifest": {
            "path": str(runner_file),
            "bytes": runner_file.stat().st_size,
            "sha256": sha256_file(runner_file),
            "git_sha": runner.get("git_sha"),
        },
        "parameter_manifest": {
            "path": str(parameter_manifest),
            "bytes": parameter_manifest.stat().st_size,
            "sha256": expected["parameter_manifest_sha256"],
        },
        "parameter_package": {
            "path": str(parameter_package),
            "bytes": parameter_package.stat().st_size,
            "sha256": expected["sd_parameter_package_sha256"],
            "crc32": parameter["package_crc32"],
        },
        "bit": {"path": str(bit), "bytes": bit.stat().st_size, "sha256": expected["bit_sha256"]},
        "xsa": {"path": str(xsa), "bytes": xsa.stat().st_size, "sha256": expected["xsa_sha256"]},
        "elf": {"path": str(elf), "bytes": elf.stat().st_size, "sha256": elf_sha},
    }


def _git_provenance(require_clean: bool) -> dict[str, Any]:
    root = Path(__file__).resolve().parents[2]
    head = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"], check=True, capture_output=True, text=True
    ).stdout.strip()
    dirty_text = subprocess.run(
        ["git", "-C", str(root), "status", "--porcelain"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    if require_clean and dirty_text:
        raise BoardEvaluationError("formal board evaluation requires a clean Git worktree")
    tool = Path(__file__).resolve()
    return {
        "git_root": str(root),
        "git_sha": head,
        "git_dirty": bool(dirty_text),
        "tool": {"path": str(tool), "bytes": tool.stat().st_size, "sha256": sha256_file(tool)},
    }


def _compare_reference(board_coco: Mapping[str, Any], reference_path: Path, tolerance: float) -> dict[str, Any]:
    reference_file, reference = _load_json(reference_path, "host INT8 reference summary")
    reference_coco = reference.get("coco")
    if reference.get("images") != 5000 or not isinstance(reference_coco, Mapping):
        raise BoardEvaluationError("host INT8 reference is not a full 5000-image COCO evaluation")
    board_metrics = board_coco.get("metrics")
    reference_metrics = reference_coco.get("metrics")
    if not isinstance(board_metrics, Mapping) or not isinstance(reference_metrics, Mapping):
        raise BoardEvaluationError("COCO metric mappings are missing")
    deltas: dict[str, float] = {}
    for name in sorted(reference_metrics):
        if name not in board_metrics:
            raise BoardEvaluationError(f"board metrics lack {name}")
        deltas[name] = float(board_metrics[name]) - float(reference_metrics[name])
    board_class = board_coco.get("per_class")
    reference_class = reference_coco.get("per_class")
    if not isinstance(board_class, list) or not isinstance(reference_class, list) or len(board_class) != 80 or len(reference_class) != 80:
        raise BoardEvaluationError("per-class COCO results are incomplete")
    class_max = 0.0
    for index, (actual, expected) in enumerate(zip(board_class, reference_class)):
        if actual.get("class_index") != index or expected.get("class_index") != index:
            raise BoardEvaluationError("per-class COCO results are not in dense class order")
        for name in ("AP50_95", "AP50"):
            class_max = max(class_max, abs(float(actual[name]) - float(expected[name])))
    maximum = max([abs(value) for value in deltas.values()] + [class_max])
    result = {
        "reference_summary": {
            "path": str(reference_file),
            "bytes": reference_file.stat().st_size,
            "sha256": sha256_file(reference_file),
        },
        "metric_deltas": deltas,
        "per_class_max_abs_delta": class_max,
        "tolerance": tolerance,
        "pass": maximum <= tolerance,
    }
    if not result["pass"]:
        raise BoardEvaluationError(f"board network metrics differ from host INT8 reference (max delta {maximum})")
    return result


@torch.inference_mode()
def run_board_evaluation(args: argparse.Namespace) -> dict[str, Any]:
    if args.expected_count <= 0 or args.batch_size <= 0:
        raise BoardEvaluationError("expected_count and batch_size must be positive")
    if args.metric_tolerance < 0.0 or not math.isfinite(args.metric_tolerance):
        raise BoardEvaluationError("metric_tolerance must be finite and nonnegative")
    output_dir = Path(args.output_dir).resolve()
    if output_dir.exists():
        raise BoardEvaluationError(f"refusing to overwrite output directory: {output_dir}")
    board_dir = Path(args.board_output).resolve()
    index_path = board_dir / "output_index.bin"
    data_path = board_dir / "raw_heads.bin"
    board = validate_board_output_index(index_path, data_path)
    if board["schema"] != "coco80.board-output-index.v2" or board["mode"] != 0 or board["selection_index_crc32"] != 0:
        raise BoardEvaluationError("board output is not a full accuracy-mode v2 stream")
    quant = _head_quantization(Path(args.quant_manifest))
    inputs, input_artifacts = _input_contract(
        Path(args.input_index_json), Path(args.input_index_bin), board, args.expected_count
    )
    binding = _runner_binding(
        Path(args.runner_manifest),
        quant["manifest"]["sha256"],
        Path(args.parameter_manifest),
        Path(args.parameter_package),
        Path(args.bit),
        Path(args.xsa),
        Path(args.elf),
        args.expected_count,
    )
    if board["parameter_crc32"] != binding["parameter_package"]["crc32"]:
        raise BoardEvaluationError("board output parameter CRC32 differs from the bound package")
    device = torch.device(args.device)
    config = NmsConfig.accuracy()
    predictions: list[dict[str, Any]] = []
    p4_batch: list[np.ndarray] = []
    p5_batch: list[np.ndarray] = []
    meta_batch: list[tuple[int, LetterboxMetadata]] = []
    post_seconds = 0.0
    processed = 0

    def flush() -> None:
        nonlocal post_seconds, processed
        if not p4_batch:
            return
        p4 = torch.from_numpy(np.stack(p4_batch)).to(device=device)
        p5 = torch.from_numpy(np.stack(p5_batch)).to(device=device)
        p4 = (p4.permute(0, 3, 1, 2).float() - quant["p4_detect"]["zero_point"]) * quant["p4_detect"]["scale"]
        p5 = (p5.permute(0, 3, 1, 2).float() - quant["p5_detect"]["zero_point"]) * quant["p5_detect"]["scale"]
        if device.type == "cuda":
            torch.cuda.synchronize(device)
        started = time.perf_counter()
        outputs = non_max_suppression(decode_heads(p4, p5), config)
        for detections, (image_id, meta) in zip(outputs, meta_batch):
            predictions.extend(
                detections_to_coco(
                    detections,
                    image_id=image_id,
                    original_width=meta.source_width,
                    original_height=meta.source_height,
                    scale=meta.scale,
                    pad_left=meta.pad_left,
                    pad_top=meta.pad_top,
                )
            )
        if device.type == "cuda":
            torch.cuda.synchronize(device)
        post_seconds += time.perf_counter() - started
        processed += len(outputs)
        p4_batch.clear()
        p5_batch.clear()
        meta_batch.clear()
        if processed % 100 == 0 or processed == args.expected_count:
            print(f"board: {processed}/{args.expected_count} images", flush=True)

    started_total = time.perf_counter()
    try:
        with data_path.open("rb") as stream:
            for input_entry, output_entry in zip(inputs, board["entries"]):
                stream.seek(output_entry["offset"])
                package = stream.read(output_entry["bytes"])
                try:
                    p4_bytes, p5_bytes = _validate_raw_package(
                        package,
                        input_crc32=input_entry["package"]["package_crc32"],
                        parameter_crc32=board["parameter_crc32"],
                        p4_scale_bits=quant["p4_detect"]["scale_bits"],
                        p4_zero_point=quant["p4_detect"]["zero_point"],
                        p5_scale_bits=quant["p5_detect"]["scale_bits"],
                        p5_zero_point=quant["p5_detect"]["zero_point"],
                    )
                except BoardConformanceError as exc:
                    raise BoardEvaluationError(
                        f"raw package {output_entry['record_index']} is invalid: {exc}"
                    ) from exc
                p4_batch.append(np.frombuffer(p4_bytes, dtype=np.uint8).reshape(P4_HEIGHT, P4_WIDTH, 255))
                p5_batch.append(np.frombuffer(p5_bytes, dtype=np.uint8).reshape(P5_HEIGHT, P5_WIDTH, 255))
                meta_batch.append(
                    (input_entry["image_id"], LetterboxMetadata.from_dict(input_entry["letterbox"]))
                )
                if len(p4_batch) == args.batch_size:
                    flush()
        flush()
    except OSError as exc:
        raise BoardEvaluationError(f"cannot stream board raw heads: {exc}") from exc
    if processed != args.expected_count:
        raise BoardEvaluationError(f"processed {processed} board records, expected {args.expected_count}")
    annotations = _regular(args.annotations, "COCO annotations")
    image_ids = [entry["image_id"] for entry in inputs]
    coco = evaluate_coco_detailed(annotations, predictions, image_ids=image_ids)
    reference = _compare_reference(coco, Path(args.reference_summary), args.metric_tolerance)
    provenance = _git_provenance(args.require_clean_git)
    output_dir.mkdir(parents=True, exist_ok=False)
    predictions_path = output_dir / "predictions.json"
    write_json_atomic(predictions_path, predictions)
    ticks = np.asarray([entry["total_ticks"] for entry in board["entries"]], dtype=np.uint64)
    summary = {
        "format": FORMAT,
        "version": VERSION,
        "status": "PASS",
        "images": processed,
        "board": {
            "index": {"path": str(index_path), "sha256": board["index_sha256"]},
            "raw_heads": {
                "path": str(data_path),
                "bytes": board["data_bytes"],
                "crc32": board["data_crc32"],
                "sha256": board["data_sha256"],
            },
            "software_build_crc32": board["software_build_crc32"],
            "hardware_build_crc32": board["hardware_build_crc32"],
            "timing_ticks": {
                "clock_hz": 200_000_000,
                "min": int(ticks.min()),
                "mean": float(ticks.mean()),
                "p50": float(np.percentile(ticks, 50)),
                "p95": float(np.percentile(ticks, 95)),
                "p99": float(np.percentile(ticks, 99)),
                "max": int(ticks.max()),
            },
        },
        "input": input_artifacts,
        "binding": binding,
        "quantization": quant["manifest"],
        "heads": {"p4": quant["p4_detect"], "p5": quant["p5_detect"]},
        "decode": {
            "confidence": config.confidence,
            "iou": config.iou,
            "multi_label": config.multi_label,
            "class_aware": True,
            "max_nms": config.max_nms,
            "max_det": config.max_det,
        },
        "coco": coco,
        "host_reference": reference,
        "timing_seconds": {
            "decode_nms_export": post_seconds,
            "total_including_validation_and_cocoeval": time.perf_counter() - started_total,
        },
        "artifacts": {
            "annotations": {"path": str(annotations), "sha256": sha256_file(annotations)},
            "predictions": {
                "path": str(predictions_path),
                "bytes": predictions_path.stat().st_size,
                "sha256": sha256_file(predictions_path),
            },
        },
        "environment": {
            "python": platform.python_version(),
            "torch": torch.__version__,
            "device": str(device),
        },
        "provenance": provenance,
    }
    write_json_atomic(output_dir / "summary.json", summary)
    return summary


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--board-output", type=Path, required=True)
    parser.add_argument("--input-index-json", type=Path, required=True)
    parser.add_argument("--input-index-bin", type=Path, required=True)
    parser.add_argument("--quant-manifest", type=Path, required=True)
    parser.add_argument("--parameter-manifest", type=Path, required=True)
    parser.add_argument("--parameter-package", type=Path, required=True)
    parser.add_argument("--runner-manifest", type=Path, required=True)
    parser.add_argument("--bit", type=Path, required=True)
    parser.add_argument("--xsa", type=Path, required=True)
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--annotations", type=Path, required=True)
    parser.add_argument("--reference-summary", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--device", default="cuda:0" if torch.cuda.is_available() else "cpu")
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--expected-count", type=int, default=5000)
    parser.add_argument("--metric-tolerance", type=float, default=1e-12)
    parser.add_argument("--allow-dirty-git", action="store_true")
    args = parser.parse_args(argv)
    args.require_clean_git = not args.allow_dirty_git
    try:
        summary = run_board_evaluation(args)
    except (BoardEvaluationError, OSError, ValueError) as exc:
        parser.exit(1, f"board evaluation failed: {exc}\n")
    print(json.dumps(summary["coco"]["metrics"], indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

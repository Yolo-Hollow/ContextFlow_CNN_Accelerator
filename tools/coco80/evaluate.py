"""Evaluate deploy416 FP32 or r5 PTQ on COCO with canonical postprocessing."""

from __future__ import annotations

import argparse
import json
import platform
import time
from pathlib import Path
from typing import Any, Sequence

import numpy as np
import torch
from torch.utils.data import DataLoader

from .assets import sha256_file, write_json_atomic
from .common import COCO80_CLASS_NAMES
from .dataset import CocoFixed416Dataset, collate_fixed416
from .model import forward_float_dag, load_official_model
from .postprocess import NmsConfig, decode_heads, detections_to_coco, non_max_suppression
from .ptq_runner import RtlPtqRunner
from .schemas import LetterboxMetadata


def _mean_valid(values: np.ndarray, label: str) -> float:
    selected = values[values > -1]
    if not selected.size:
        raise RuntimeError(f"COCO evaluator has no valid samples for {label}")
    return float(selected.mean())


def metrics_from_coco_evaluator(evaluator: Any) -> dict[str, float]:
    """Compute the twelve COCO metrics at the configured maxDet=300.

    pycocotools' stock ``summarize()`` hard-codes maxDet=100 for its first AP
    row.  Once ``params.maxDets`` is intentionally [1, 10, 300], that row is
    therefore empty (-1).  The accumulated precision/recall tensors remain
    authoritative, so select their explicit area, IoU, and maxDet axes.
    """

    precision = np.asarray(evaluator.eval["precision"])
    recall = np.asarray(evaluator.eval["recall"])
    params = evaluator.params
    area_indices = {name: index for index, name in enumerate(params.areaRngLbl)}
    max_indices = {int(value): index for index, value in enumerate(params.maxDets)}
    if not {"all", "small", "medium", "large"}.issubset(area_indices):
        raise RuntimeError("COCO evaluator area ranges are incomplete")
    if not {1, 10, 300}.issubset(max_indices):
        raise RuntimeError("COCO evaluator maxDets must be [1,10,300]")
    ious = np.asarray(params.iouThrs, dtype=np.float64)

    def ap(area: str, iou: float | None = None) -> float:
        values = precision[:, :, :, area_indices[area], max_indices[300]]
        if iou is not None:
            matches = np.flatnonzero(np.isclose(ious, iou, rtol=0.0, atol=1e-9))
            if matches.size != 1:
                raise RuntimeError(f"COCO evaluator lacks IoU={iou}")
            values = values[matches[0] : matches[0] + 1]
        return _mean_valid(values, f"AP/{area}/{iou if iou is not None else 'all'}")

    def ar(area: str, maximum: int) -> float:
        values = recall[:, :, area_indices[area], max_indices[maximum]]
        return _mean_valid(values, f"AR/{area}/{maximum}")

    return {
        "AP50_95": ap("all"),
        "AP50": ap("all", 0.50),
        "AP75": ap("all", 0.75),
        "AP_small": ap("small"),
        "AP_medium": ap("medium"),
        "AP_large": ap("large"),
        "AR_1": ar("all", 1),
        "AR_10": ar("all", 10),
        "AR_300": ar("all", 300),
        "AR_small": ar("small", 300),
        "AR_medium": ar("medium", 300),
        "AR_large": ar("large", 300),
    }


def evaluate_coco_detailed(
    annotations: Path,
    predictions: list[dict[str, Any]],
    *,
    image_ids: Sequence[int] | None = None,
) -> dict[str, Any]:
    from pycocotools.coco import COCO
    from pycocotools.cocoeval import COCOeval

    ground_truth = COCO(str(annotations))
    if predictions:
        detected = ground_truth.loadRes(predictions)
    else:
        detected = COCO()
        detected.dataset = {
            "images": list(ground_truth.dataset["images"]),
            "categories": list(ground_truth.dataset["categories"]),
            "annotations": [],
        }
        detected.createIndex()
    evaluator = COCOeval(ground_truth, detected, "bbox")
    evaluator.params.maxDets = [1,10,300]
    if image_ids is not None:
        normalized = [int(value) for value in image_ids]
        if not normalized or len(normalized) != len(set(normalized)):
            raise RuntimeError("COCO evaluation image_ids must be nonempty and unique")
        unknown = sorted(set(normalized) - set(ground_truth.getImgIds()))
        if unknown:
            raise RuntimeError(f"COCO evaluation contains unknown image ids: {unknown[:8]}")
        evaluator.params.imgIds = normalized
    evaluator.evaluate()
    evaluator.accumulate()
    metrics = metrics_from_coco_evaluator(evaluator)
    print(json.dumps({"pycocotools_maxDets_300": metrics}, indent=2))
    precision = evaluator.eval["precision"]  # [IoU,recall,class,area,maxDet]
    category_ids = list(evaluator.params.catIds)
    if len(category_ids) != 80 or precision.shape[2] != 80:
        raise RuntimeError("COCO evaluator did not produce 80-class precision")
    per_class = []
    iou50_index = int(np.argmin(np.abs(np.asarray(evaluator.params.iouThrs) - 0.5)))
    for dense_index, (name, category_id) in enumerate(zip(COCO80_CLASS_NAMES, category_ids)):
        all_precision = precision[:,:,dense_index,0,-1]
        valid_all = all_precision[all_precision > -1]
        at_50 = precision[iou50_index,:,dense_index,0,-1]
        valid_50 = at_50[at_50 > -1]
        per_class.append(
            {
                "class_index": dense_index,
                "category_id": int(category_id),
                "name": name,
                "AP50_95": float(valid_all.mean()) if valid_all.size else -1.0,
                "AP50": float(valid_50.mean()) if valid_50.size else -1.0,
            }
        )
    return {"metrics": metrics, "per_class": per_class}


@torch.inference_mode()
def run_evaluation(args: argparse.Namespace) -> dict[str, Any]:
    device = torch.device(args.device)
    dataset = CocoFixed416Dataset(args.annotations, args.image_root)
    loader = DataLoader(
        dataset,
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=args.workers,
        collate_fn=collate_fixed416,
        pin_memory=device.type == "cuda",
    )
    model = None
    ptq = None
    if args.mode == "fp32":
        model = load_official_model(args.upstream, args.weights, device, fuse=True)
    else:
        ptq = RtlPtqRunner(args.quant_dir, device, exact=False)
    config = NmsConfig.accuracy()
    predictions: list[dict[str, Any]] = []
    infer_seconds = 0.0
    post_seconds = 0.0
    seen = 0
    start_total = time.perf_counter()
    for batch in loader:
        images = batch["image_float"].to(device, non_blocking=True)
        if device.type == "cuda":
            torch.cuda.synchronize(device)
        start = time.perf_counter()
        if model is not None:
            nodes = forward_float_dag(model, images)
            p4, p5 = nodes["p4_detect"], nodes["p5_detect"]
        else:
            assert ptq is not None
            qnodes = ptq.run(images)
            p4, p5 = ptq.dequantized_heads(qnodes)
        if device.type == "cuda":
            torch.cuda.synchronize(device)
        infer_seconds += time.perf_counter() - start
        start = time.perf_counter()
        outputs = non_max_suppression(decode_heads(p4,p5), config)
        for index, detections in enumerate(outputs):
            meta = LetterboxMetadata.from_dict(batch["metadata"][index])
            predictions.extend(
                detections_to_coco(
                    detections,
                    image_id=batch["image_id"][index],
                    original_width=meta.source_width,
                    original_height=meta.source_height,
                    scale=meta.scale,
                    pad_left=meta.pad_left,
                    pad_top=meta.pad_top,
                )
            )
        post_seconds += time.perf_counter() - start
        seen += len(outputs)
        if seen % 100 == 0 or seen == len(dataset):
            print(f"{args.mode}: {seen}/{len(dataset)} images")
    total_seconds = time.perf_counter() - start_total
    if seen != len(dataset) or len(dataset) != 5000:
        raise RuntimeError(f"full val2017 requires exactly 5000 images, processed {seen}/{len(dataset)}")
    args.output_dir.mkdir(parents=True, exist_ok=False)
    predictions_path = args.output_dir / "predictions.json"
    write_json_atomic(predictions_path, predictions)
    coco = evaluate_coco_detailed(args.annotations, predictions)
    summary = {
        "format": "kv260-coco80-deploy416-evaluation",
        "version": 1,
        "mode": args.mode,
        "images": seen,
        "input": {
            "shape": [1,416,416,3],
            "layout": "RGB HWC source bytes; model consumes NCHW float/255",
            "letterbox": "PIL bilinear, centered, fill=114",
        },
        "decode": {
            "confidence": config.confidence,
            "iou": config.iou,
            "multi_label": config.multi_label,
            "class_aware": True,
            "max_nms": config.max_nms,
            "max_det": config.max_det,
        },
        "coco": coco,
        "timing_seconds": {"inference": infer_seconds, "postprocess": post_seconds, "total": total_seconds},
        "environment": {
            "python": platform.python_version(),
            "torch": torch.__version__,
            "device": str(device),
        },
        "artifacts": {
            "annotations_sha256": sha256_file(args.annotations),
            "weights_sha256": sha256_file(args.weights),
            "predictions_sha256": sha256_file(predictions_path),
            "quant_manifest_sha256": sha256_file(args.quant_dir / "quantization_manifest.json") if args.quant_dir else None,
        },
    }
    write_json_atomic(args.output_dir / "summary.json", summary)
    return summary


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("fp32","ptq"), required=True)
    parser.add_argument("--annotations", type=Path, required=True)
    parser.add_argument("--image-root", type=Path, required=True)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--quant-dir", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--device", default="cuda:0" if torch.cuda.is_available() else "cpu")
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--workers", type=int, default=2)
    args = parser.parse_args(argv)
    if args.mode == "ptq" and args.quant_dir is None:
        parser.error("--mode ptq requires --quant-dir")
    summary = run_evaluation(args)
    print(json.dumps(summary["coco"]["metrics"], indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

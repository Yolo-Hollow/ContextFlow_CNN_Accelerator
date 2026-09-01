"""Thin, strict wrapper around pycocotools bbox evaluation."""

from __future__ import annotations

import argparse
from contextlib import nullcontext, redirect_stdout
import io
import json
import math
import numpy as np
from pathlib import Path
import sys
from typing import Any, Iterable, Mapping, Sequence

from .assets import write_json_atomic
from .common import COCO91_TO_COCO80, coco80_to_coco91
from .schemas import CocoEvalSummary


class CocoEvaluationError(RuntimeError):
    """Raised for invalid inputs or an unsuccessful COCO API evaluation."""


class CocoEvalDependencyError(CocoEvaluationError):
    """Raised when pycocotools is unavailable."""


def _load_pycocotools():
    try:
        from pycocotools.coco import COCO
        from pycocotools.cocoeval import COCOeval
    except ImportError as exc:  # pragma: no cover - depends on host environment
        raise CocoEvalDependencyError(
            "pycocotools is required for COCO evaluation; install it with "
            "'python -m pip install pycocotools'"
        ) from exc
    return COCO, COCOeval


def _finite_float(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CocoEvaluationError(f"{label} must be numeric, got {value!r}")
    result = float(value)
    if not math.isfinite(result):
        raise CocoEvaluationError(f"{label} must be finite, got {value!r}")
    return result


def coco_result_from_xyxy(
    image_id: int,
    class_index: int,
    bbox_xyxy: Sequence[float],
    score: float,
) -> dict[str, Any]:
    """Create a COCO result, mapping dense class index and XYXY to COCO form."""

    if isinstance(image_id, bool) or not isinstance(image_id, int) or image_id < 0:
        raise CocoEvaluationError(f"image_id must be a non-negative integer, got {image_id!r}")
    if len(bbox_xyxy) != 4:
        raise CocoEvaluationError("bbox_xyxy must contain exactly four values")
    x1, y1, x2, y2 = (
        _finite_float(value, f"bbox_xyxy[{index}]")
        for index, value in enumerate(bbox_xyxy)
    )
    if x2 <= x1 or y2 <= y1:
        raise CocoEvaluationError("bbox_xyxy must have positive width and height")
    confidence = _finite_float(score, "score")
    if not 0.0 <= confidence <= 1.0:
        raise CocoEvaluationError("score must be in [0, 1]")
    return {
        "image_id": image_id,
        "category_id": coco80_to_coco91(class_index),
        "bbox": [x1, y1, x2 - x1, y2 - y1],
        "score": confidence,
    }


def validate_coco_results(results: Any) -> list[dict[str, Any]]:
    """Validate and normalize COCO bbox result records before evaluation."""

    if not isinstance(results, list):
        raise CocoEvaluationError("predictions must be a JSON array")
    normalized: list[dict[str, Any]] = []
    for index, item in enumerate(results):
        if not isinstance(item, Mapping):
            raise CocoEvaluationError(f"prediction {index} must be a JSON object")
        required = {"image_id", "category_id", "bbox", "score"}
        missing = required - set(item)
        if missing:
            raise CocoEvaluationError(
                f"prediction {index} is missing fields {sorted(missing)}"
            )
        image_id = item["image_id"]
        category_id = item["category_id"]
        if isinstance(image_id, bool) or not isinstance(image_id, int) or image_id < 0:
            raise CocoEvaluationError(f"prediction {index} has invalid image_id")
        if (
            isinstance(category_id, bool)
            or not isinstance(category_id, int)
            or category_id not in COCO91_TO_COCO80
        ):
            raise CocoEvaluationError(
                f"prediction {index} category_id is not an official COCO80 id"
            )
        bbox = item["bbox"]
        if not isinstance(bbox, (list, tuple)) or len(bbox) != 4:
            raise CocoEvaluationError(f"prediction {index} bbox must be [x,y,w,h]")
        coordinates = [
            _finite_float(value, f"prediction {index} bbox[{position}]")
            for position, value in enumerate(bbox)
        ]
        if coordinates[2] <= 0.0 or coordinates[3] <= 0.0:
            raise CocoEvaluationError(f"prediction {index} bbox must have positive area")
        score = _finite_float(item["score"], f"prediction {index} score")
        if not 0.0 <= score <= 1.0:
            raise CocoEvaluationError(f"prediction {index} score must be in [0, 1]")
        normalized.append(
            {
                "image_id": image_id,
                "category_id": category_id,
                "bbox": coordinates,
                "score": score,
            }
        )
    return normalized


def load_coco_results(path: str | Path) -> list[dict[str, Any]]:
    source = Path(path)
    if not source.is_file():
        raise CocoEvaluationError(f"prediction JSON does not exist: {source}")
    try:
        payload = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise CocoEvaluationError(f"cannot read prediction JSON {source}: {exc}") from exc
    return validate_coco_results(payload)


def _max_detections(values: Sequence[int]) -> tuple[int, int, int]:
    if len(values) != 3:
        raise CocoEvaluationError("max_detections must contain exactly three limits")
    parsed: list[int] = []
    for value in values:
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise CocoEvaluationError("max_detections entries must be positive integers")
        parsed.append(value)
    if not parsed[0] < parsed[1] < parsed[2]:
        raise CocoEvaluationError("max_detections must be strictly increasing")
    return parsed[0], parsed[1], parsed[2]


def _metrics_from_accumulated(evaluator: Any, limits: tuple[int, int, int]) -> dict[str, float]:
    """Read metrics from COCOeval tensors at the requested maxDet limits.

    ``COCOeval.summarize`` hard-codes maxDet=100 for several AP rows.  It is
    therefore not authoritative when the deployment contract intentionally
    uses ``(1, 10, 300)``.  The accumulated precision and recall tensors retain
    every configured maxDet axis and are safe to query directly.
    """

    try:
        precision = np.asarray(evaluator.eval["precision"])
        recall = np.asarray(evaluator.eval["recall"])
        params = evaluator.params
        area_indices = {
            str(name): index for index, name in enumerate(params.areaRngLbl)
        }
        max_indices = {
            int(value): index for index, value in enumerate(params.maxDets)
        }
        ious = np.asarray(params.iouThrs, dtype=np.float64)
    except (AttributeError, KeyError, TypeError, ValueError) as exc:
        raise CocoEvaluationError(
            f"pycocotools accumulated tensors are incomplete: {exc}"
        ) from exc

    if precision.ndim != 5 or recall.ndim != 4:
        raise CocoEvaluationError(
            "pycocotools precision/recall tensors have unexpected rank"
        )
    required_areas = {"all", "small", "medium", "large"}
    if not required_areas.issubset(area_indices):
        raise CocoEvaluationError("pycocotools area ranges are incomplete")
    if not set(limits).issubset(max_indices):
        raise CocoEvaluationError("pycocotools maxDet axes do not match the request")

    def mean_valid(values: np.ndarray, label: str) -> float:
        selected = values[values > -1]
        if not selected.size:
            raise CocoEvaluationError(f"pycocotools has no valid samples for {label}")
        return _finite_float(float(selected.mean()), f"pycocotools metric {label}")

    high = limits[2]

    def ap(area: str, iou: float | None = None) -> float:
        values = precision[:, :, :, area_indices[area], max_indices[high]]
        if iou is not None:
            matches = np.flatnonzero(np.isclose(ious, iou, rtol=0.0, atol=1e-9))
            if matches.size != 1:
                raise CocoEvaluationError(f"pycocotools lacks IoU={iou}")
            values = values[matches[0] : matches[0] + 1]
        return mean_valid(values, f"AP/{area}/{iou if iou is not None else 'all'}")

    def ar(area: str, maximum: int) -> float:
        values = recall[:, :, area_indices[area], max_indices[maximum]]
        return mean_valid(values, f"AR/{area}/{maximum}")

    return {
        "AP": ap("all"),
        "AP50": ap("all", 0.50),
        "AP75": ap("all", 0.75),
        "AP_small": ap("small"),
        "AP_medium": ap("medium"),
        "AP_large": ap("large"),
        "AR_max_det_1": ar("all", limits[0]),
        "AR_max_det_10": ar("all", limits[1]),
        "AR_max_det_limit": ar("all", high),
        "AR_small": ar("small", high),
        "AR_medium": ar("medium", high),
        "AR_large": ar("large", high),
    }


def evaluate_coco(
    annotations: str | Path,
    predictions: str | Path | Sequence[Mapping[str, Any]],
    *,
    image_ids: Iterable[int] | None = None,
    max_detections: Sequence[int] = (1, 10, 100),
    quiet: bool = False,
) -> CocoEvalSummary:
    """Run official pycocotools bbox evaluation and return named metrics."""

    annotation_path = Path(annotations).resolve(strict=False)
    if not annotation_path.is_file():
        raise CocoEvaluationError(f"annotation JSON does not exist: {annotation_path}")
    if isinstance(predictions, (str, Path)):
        results = load_coco_results(predictions)
    else:
        results = validate_coco_results(list(predictions))
    limits = _max_detections(max_detections)

    selected_ids: tuple[int, ...] = ()
    if image_ids is not None:
        parsed_ids: set[int] = set()
        for value in image_ids:
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise CocoEvaluationError(f"invalid image id {value!r}")
            parsed_ids.add(value)
        if not parsed_ids:
            raise CocoEvaluationError("image_ids must not be empty when supplied")
        selected_ids = tuple(sorted(parsed_ids))

    COCO, COCOeval = _load_pycocotools()
    sink = io.StringIO()
    context = redirect_stdout(sink) if quiet else nullcontext()
    try:
        with context:
            coco_gt = COCO(str(annotation_path))
            if results:
                coco_dt = coco_gt.loadRes(results)
            else:
                # COCO.loadRes historically indexes anns[0].  Construct an
                # equivalent empty result set so zero-detection runs remain valid.
                coco_dt = COCO()
                coco_dt.dataset = {
                    "images": list(coco_gt.dataset.get("images", [])),
                    "categories": list(coco_gt.dataset.get("categories", [])),
                    "annotations": [],
                }
                coco_dt.createIndex()
            evaluator = COCOeval(coco_gt, coco_dt, "bbox")
            evaluator.params.maxDets = list(limits)
            if selected_ids:
                evaluator.params.imgIds = list(selected_ids)
            evaluator.evaluate()
            evaluator.accumulate()
            evaluator.summarize()
    except CocoEvaluationError:
        raise
    except Exception as exc:
        raise CocoEvaluationError(f"pycocotools evaluation failed: {exc}") from exc

    metrics = _metrics_from_accumulated(evaluator, limits)
    evaluated_ids = selected_ids or tuple(sorted(int(value) for value in evaluator.params.imgIds))
    return CocoEvalSummary(
        annotation_file=str(annotation_path),
        prediction_count=len(results),
        image_count=len(evaluated_ids),
        image_ids=evaluated_ids,
        max_detections=limits,
        metrics=metrics,
    )


def _load_image_ids(path: Path) -> list[int]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise CocoEvaluationError(f"cannot read image id JSON {path}: {exc}") from exc
    if not isinstance(payload, list):
        raise CocoEvaluationError("image id JSON must be an array")
    return payload


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Evaluate COCO80 bbox predictions")
    parser.add_argument("--annotations", required=True, type=Path)
    parser.add_argument("--predictions", required=True, type=Path)
    parser.add_argument("--image-ids", type=Path, help="optional JSON array of image ids")
    parser.add_argument(
        "--max-detections", nargs=3, type=int, default=(1, 10, 100),
        metavar=("LOW", "MID", "HIGH"),
    )
    parser.add_argument("--quiet", action="store_true", help="suppress COCO API table")
    parser.add_argument("--output", type=Path, help="optional atomic summary JSON")
    args = parser.parse_args(argv)
    try:
        ids = _load_image_ids(args.image_ids) if args.image_ids else None
        summary = evaluate_coco(
            args.annotations,
            args.predictions,
            image_ids=ids,
            max_detections=args.max_detections,
            quiet=args.quiet,
        )
        payload = summary.to_dict()
        if args.output:
            write_json_atomic(args.output, payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    except (OSError, ValueError, CocoEvaluationError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":  # pragma: no cover - exercised through CLI
    raise SystemExit(main())

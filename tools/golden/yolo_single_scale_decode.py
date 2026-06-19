import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path


GRID_W = 13
GRID_H = 13
ANCHORS = ((81.0, 82.0), (135.0, 169.0), (344.0, 319.0))
VALUES_PER_ANCHOR = 8
CHANNELS = len(ANCHORS) * VALUES_PER_ANCHOR
CLASS_NAMES = ("with_mask", "without_mask", "mask_weared_incorrect")
STRIDE = 32.0
OUTPUT_SCALE = 0.28766438364982605
OUTPUT_ZERO_POINT = 80
MODEL_SIZE = 416.0
DEFAULT_CONFIDENCE = 0.25
DEFAULT_IOU = 0.45
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_INPUT = REPO_ROOT / "repro" / "expected" / "conv9_golden_ofm_u8_hwc.bin"
DEFAULT_OUTPUT = REPO_ROOT / "repro" / "expected" / "decode_golden.json"


@dataclass
class Detection:
    x1: float
    y1: float
    x2: float
    y2: float
    score: float
    class_id: int
    source_index: int


def sigmoid(value):
    if value >= 0.0:
        z = math.exp(-value)
        return 1.0 / (1.0 + z)
    z = math.exp(value)
    return z / (1.0 + z)


def clip(value, low, high):
    return min(max(value, low), high)


def box_iou(a, b):
    inter_w = max(0.0, min(a.x2, b.x2) - max(a.x1, b.x1))
    inter_h = max(0.0, min(a.y2, b.y2) - max(a.y1, b.y1))
    inter = inter_w * inter_h
    area_a = max(0.0, a.x2 - a.x1) * max(0.0, a.y2 - a.y1)
    area_b = max(0.0, b.x2 - b.x1) * max(0.0, b.y2 - b.y1)
    union = area_a + area_b - inter
    return 0.0 if union <= 0.0 else inter / union


def class_aware_nms(candidates, iou_threshold, max_detections=507):
    ordered = sorted(candidates, key=lambda d: (-d.score, d.source_index))
    kept = []
    for candidate in ordered:
        if any(
            candidate.class_id == accepted.class_id
            and box_iou(candidate, accepted) > iou_threshold
            for accepted in kept
        ):
            continue
        kept.append(candidate)
        if len(kept) >= max_detections:
            break
    return kept


def decode_hwc(
    tensor,
    confidence_threshold=DEFAULT_CONFIDENCE,
    iou_threshold=DEFAULT_IOU,
    max_detections=507,
):
    if len(tensor) != GRID_H * GRID_W * CHANNELS:
        raise ValueError(f"Expected {GRID_H * GRID_W * CHANNELS} bytes, got {len(tensor)}")

    candidates = []
    for gy in range(GRID_H):
        for gx in range(GRID_W):
            pixel_base = (gy * GRID_W + gx) * CHANNELS
            for anchor_id, (anchor_w, anchor_h) in enumerate(ANCHORS):
                base = pixel_base + anchor_id * VALUES_PER_ANCHOR
                values = [
                    (tensor[base + index] - OUTPUT_ZERO_POINT) * OUTPUT_SCALE
                    for index in range(VALUES_PER_ANCHOR)
                ]
                probs = [sigmoid(value) for value in values]
                objectness = probs[4]
                if objectness <= confidence_threshold:
                    continue
                class_id = max(range(len(CLASS_NAMES)), key=lambda index: probs[5 + index])
                score = objectness * probs[5 + class_id]
                if score <= confidence_threshold:
                    continue

                center_x = (probs[0] * 2.0 - 0.5 + gx) * STRIDE
                center_y = (probs[1] * 2.0 - 0.5 + gy) * STRIDE
                width = (probs[2] * 2.0) ** 2 * anchor_w
                height = (probs[3] * 2.0) ** 2 * anchor_h
                source_index = (gy * GRID_W + gx) * len(ANCHORS) + anchor_id
                candidates.append(
                    Detection(
                        x1=clip(center_x - width * 0.5, 0.0, MODEL_SIZE),
                        y1=clip(center_y - height * 0.5, 0.0, MODEL_SIZE),
                        x2=clip(center_x + width * 0.5, 0.0, MODEL_SIZE),
                        y2=clip(center_y + height * 0.5, 0.0, MODEL_SIZE),
                        score=score,
                        class_id=class_id,
                        source_index=source_index,
                    )
                )
    return class_aware_nms(candidates, iou_threshold, max_detections)


def inverse_letterbox(detection, original_w=512.0, original_h=366.0,
                      scale=0.8125, pad_x=0.0, pad_y=59.0):
    return Detection(
        x1=clip((detection.x1 - pad_x) / scale, 0.0, original_w),
        y1=clip((detection.y1 - pad_y) / scale, 0.0, original_h),
        x2=clip((detection.x2 - pad_x) / scale, 0.0, original_w),
        y2=clip((detection.y2 - pad_y) / scale, 0.0, original_h),
        score=detection.score,
        class_id=detection.class_id,
        source_index=detection.source_index,
    )


def export_decode_golden(input_path, output_path, confidence, iou):
    tensor = input_path.read_bytes()
    model_detections = decode_hwc(tensor, confidence, iou)
    detections = []
    for index, model_detection in enumerate(model_detections):
        original_detection = inverse_letterbox(model_detection)
        detections.append(
            {
                "index": index,
                "class_id": model_detection.class_id,
                "class_name": CLASS_NAMES[model_detection.class_id],
                "score": model_detection.score,
                "source_index": model_detection.source_index,
                "model_xyxy": [
                    model_detection.x1,
                    model_detection.y1,
                    model_detection.x2,
                    model_detection.y2,
                ],
                "original_xyxy": [
                    original_detection.x1,
                    original_detection.y1,
                    original_detection.x2,
                    original_detection.y2,
                ],
            }
        )
    result = {
        "description": "Software decode golden for the RTL-semantic single-scale Conv0-Conv9 chain.",
        "input_tensor": str(input_path.resolve()),
        "tensor_layout": "HWC, channel = anchor * 8 + value",
        "value_order": ["x", "y", "w", "h", "objectness", *CLASS_NAMES],
        "shape_hwc": [GRID_H, GRID_W, CHANNELS],
        "quant": {"scale": OUTPUT_SCALE, "zero_point": OUTPUT_ZERO_POINT},
        "anchors": [list(anchor) for anchor in ANCHORS],
        "stride": STRIDE,
        "confidence_threshold": confidence,
        "iou_threshold": iou,
        "nms": "class-aware, descending score, source-index tie break",
        "letterbox": {
            "model_size": 416,
            "original_size_wh": [512, 366],
            "scale": 0.8125,
            "pad_x": 0,
            "pad_y": 59,
        },
        "detection_count": len(detections),
        "detections": detections,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
    return result


def main():
    parser = argparse.ArgumentParser(description="Decode the RTL-chain 13x13x24 YOLO tensor.")
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--confidence", type=float, default=DEFAULT_CONFIDENCE)
    parser.add_argument("--iou", type=float, default=DEFAULT_IOU)
    args = parser.parse_args()
    result = export_decode_golden(args.input, args.output, args.confidence, args.iou)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

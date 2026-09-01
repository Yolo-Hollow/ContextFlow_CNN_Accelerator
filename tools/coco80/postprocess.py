"""Canonical dual-head decode, multi-label class-aware NMS, and COCO export."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable

import torch


COCO80_TO_91 = (
    1,2,3,4,5,6,7,8,9,10,11,13,14,15,16,17,18,19,20,21,
    22,23,24,25,27,28,31,32,33,34,35,36,37,38,39,40,41,42,43,44,
    46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,
    67,70,72,73,74,75,76,77,78,79,80,81,82,84,85,86,87,88,89,90,
)
P4_ANCHORS = ((10.0,14.0),(23.0,27.0),(37.0,58.0))
P5_ANCHORS = ((81.0,82.0),(135.0,169.0),(344.0,319.0))


@dataclass(frozen=True)
class NmsConfig:
    confidence: float = 0.001
    iou: float = 0.65
    multi_label: bool = True
    max_nms: int = 30000
    max_det: int = 300

    @classmethod
    def accuracy(cls) -> "NmsConfig":
        return cls(0.001, 0.65, True, 30000, 300)

    @classmethod
    def demo(cls) -> "NmsConfig":
        return cls(0.25, 0.45, False, 30000, 300)

    def validate(self) -> None:
        if not (0.0 < self.confidence < 1.0 and 0.0 < self.iou < 1.0):
            raise ValueError("confidence and IoU thresholds must be in (0,1)")
        if self.max_nms < self.max_det or self.max_det <= 0:
            raise ValueError("max_nms must be >= max_det > 0")


def _reshape_head(raw_nchw: torch.Tensor) -> torch.Tensor:
    n, channels, height, width = raw_nchw.shape
    if channels != 255:
        raise ValueError(f"COCO80 raw head must have 255 channels, got {channels}")
    return raw_nchw.view(n, 3, 85, height, width).permute(0,1,3,4,2).contiguous()


def decode_heads(p4_nchw: torch.Tensor, p5_nchw: torch.Tensor) -> torch.Tensor:
    """Return decoded predictions as ``[N,2535,85]`` in 416 coordinates."""

    decoded = []
    for raw, anchors, stride, expected_hw in (
        (p4_nchw, P4_ANCHORS, 16.0, (26,26)),
        (p5_nchw, P5_ANCHORS, 32.0, (13,13)),
    ):
        head = _reshape_head(raw)
        if tuple(head.shape[2:4]) != expected_hw:
            raise ValueError(f"head spatial shape {tuple(head.shape[2:4])} != {expected_hw}")
        n, na, h, w, no = head.shape
        y = head.sigmoid()
        gy, gx = torch.meshgrid(
            torch.arange(h, device=head.device, dtype=head.dtype),
            torch.arange(w, device=head.device, dtype=head.dtype),
            indexing="ij",
        )
        grid = torch.stack((gx, gy), dim=-1).view(1,1,h,w,2)
        anchor = torch.tensor(anchors, device=head.device, dtype=head.dtype).view(1,na,1,1,2)
        xy = (y[...,0:2] * 2.0 - 0.5 + grid) * stride
        wh = (y[...,2:4] * 2.0).square() * anchor
        decoded.append(torch.cat((xy, wh, y[...,4:]), dim=-1).view(n,-1,no))
    output = torch.cat(decoded, dim=1)
    if output.shape[1:] != (2535,85):
        raise RuntimeError(f"decoded shape {tuple(output.shape)} is not [N,2535,85]")
    return output


def xywh_to_xyxy(boxes: torch.Tensor) -> torch.Tensor:
    result = boxes.clone()
    result[:,0] = boxes[:,0] - boxes[:,2] / 2
    result[:,1] = boxes[:,1] - boxes[:,3] / 2
    result[:,2] = boxes[:,0] + boxes[:,2] / 2
    result[:,3] = boxes[:,1] + boxes[:,3] / 2
    return result


def _decode_probability_head(
    probabilities: torch.Tensor,
    anchors: tuple[tuple[float, float], ...],
    stride: float,
    expected_hw: tuple[int, int],
) -> torch.Tensor:
    if tuple(probabilities.shape[2:4]) != expected_hw:
        raise ValueError(
            f"head spatial shape {tuple(probabilities.shape[2:4])} != {expected_hw}"
        )
    n, na, h, w, no = probabilities.shape
    gy, gx = torch.meshgrid(
        torch.arange(h, device=probabilities.device, dtype=probabilities.dtype),
        torch.arange(w, device=probabilities.device, dtype=probabilities.dtype),
        indexing="ij",
    )
    grid = torch.stack((gx,gy), dim=-1).view(1,1,h,w,2)
    anchor = torch.tensor(
        anchors, device=probabilities.device, dtype=probabilities.dtype
    ).view(1,na,1,1,2)
    xy = (probabilities[...,0:2] * 2.0 - 0.5 + grid) * stride
    wh = (probabilities[...,2:4] * 2.0).square() * anchor
    return torch.cat((xy,wh,probabilities[...,4:]), dim=-1).view(n,-1,no)


def decode_quantized_heads_u8(
    p4_u8_nchw: torch.Tensor,
    p5_u8_nchw: torch.Tensor,
    *,
    p4_scale: float,
    p4_zero_point: int,
    p5_scale: float,
    p5_zero_point: int,
) -> torch.Tensor:
    """Decode uint8 heads through one deterministic 256-entry LUT per head."""

    decoded = []
    for raw, scale, zero_point, anchors, stride, expected_hw in (
        (p4_u8_nchw,p4_scale,p4_zero_point,P4_ANCHORS,16.0,(26,26)),
        (p5_u8_nchw,p5_scale,p5_zero_point,P5_ANCHORS,32.0,(13,13)),
    ):
        if raw.dtype != torch.uint8:
            raise ValueError("quantized raw heads must use torch.uint8")
        if not (scale > 0.0 and 0 <= zero_point <= 255):
            raise ValueError("quantized head scale/zero-point is invalid")
        codes = torch.arange(256, device=raw.device, dtype=torch.float32)
        lut = torch.sigmoid((codes - float(zero_point)) * float(scale))
        probabilities = lut[_reshape_head(raw).to(torch.long)]
        decoded.append(
            _decode_probability_head(probabilities, anchors, stride, expected_hw)
        )
    output = torch.cat(decoded, dim=1)
    if output.shape[1:] != (2535,85):
        raise RuntimeError(f"decoded shape {tuple(output.shape)} is not [N,2535,85]")
    return output


def _box_iou_one_to_many(box: torch.Tensor, boxes: torch.Tensor) -> torch.Tensor:
    left_top = torch.maximum(box[:2], boxes[:,:2])
    right_bottom = torch.minimum(box[2:], boxes[:,2:])
    intersection = (right_bottom - left_top).clamp(min=0).prod(dim=1)
    area_one = (box[2:] - box[:2]).clamp(min=0).prod()
    area_many = (boxes[:,2:] - boxes[:,:2]).clamp(min=0).prod(dim=1)
    return intersection / (area_one + area_many - intersection + 1e-12)


def _deterministic_class_nms(detections: torch.Tensor, config: NmsConfig) -> torch.Tensor:
    # Input columns: xyxy, score, class, source_index.  Stable pre-sort makes
    # equal-score output independent of backend sorting details.
    source_order = torch.argsort(detections[:,6], stable=True)
    detections = detections[source_order]
    score_order = torch.argsort(detections[:,4], descending=True, stable=True)
    detections = detections[score_order[:config.max_nms]]
    try:
        from torchvision.ops import nms as torchvision_nms

        # 7680 is the upstream YOLOv3 class offset and is larger than every
        # possible 416-space box coordinate, so different classes cannot
        # suppress one another.  Scores and returned payloads are untouched;
        # the offset is used only by the NMS overlap calculation.
        # torchvision's equal-score order is backend-dependent even after a
        # stable input sort.  The rows already have the required strict total
        # order (score descending, then source index ascending), so pass NMS
        # a synthetic strictly descending rank.  NMS only consumes relative
        # score order; returned scores remain the original values, and boxes
        # stay float32 to preserve the deployed IoU arithmetic.
        offsets = detections[:,5:6] * 7680.0
        boxes = detections[:,:4] + offsets
        nms_scores = torch.arange(
            detections.shape[0], 0, -1,
            device=detections.device, dtype=boxes.dtype,
        )
        keep = torchvision_nms(boxes, nms_scores, config.iou)
        return detections[keep[:config.max_det]]
    except (ImportError, OSError):
        # The pure-Torch path keeps unit tests and minimal CPU environments
        # functional.  Refuse an accidentally quadratic full-dataset run.
        if detections.shape[0] > 4096:
            raise RuntimeError(
                "torchvision NMS is required when more than 4096 candidates survive"
            )
    kept = []
    active = torch.arange(detections.shape[0], device=detections.device)
    while active.numel() and len(kept) < config.max_det:
        current = int(active[0].item())
        kept.append(current)
        if active.numel() == 1:
            break
        rest = active[1:]
        same_class = detections[rest,5] == detections[current,5]
        suppress = same_class & (_box_iou_one_to_many(detections[current,:4], detections[rest,:4]) > config.iou)
        active = rest[~suppress]
    return detections[torch.tensor(kept, device=detections.device, dtype=torch.long)] if kept else detections[:0]


def non_max_suppression(prediction: torch.Tensor, config: NmsConfig | None = None) -> list[torch.Tensor]:
    config = config or NmsConfig.accuracy()
    config.validate()
    if prediction.ndim != 3 or prediction.shape[2] != 85:
        raise ValueError(f"expected [N,boxes,85], got {tuple(prediction.shape)}")
    outputs = []
    for sample in prediction:
        source_indices = torch.arange(sample.shape[0], device=sample.device)
        mask = sample[:,4] > config.confidence
        sample = sample[mask]
        source_indices = source_indices[mask]
        if not sample.numel():
            outputs.append(torch.empty((0,7), device=prediction.device, dtype=prediction.dtype))
            continue
        scores = sample[:,5:] * sample[:,4:5]
        boxes = xywh_to_xyxy(sample[:,:4])
        if config.multi_label:
            row, cls = torch.where(scores > config.confidence)
            detections = torch.cat(
                (boxes[row], scores[row,cls,None], cls[:,None].to(boxes.dtype), source_indices[row,None].to(boxes.dtype)),
                dim=1,
            )
        else:
            best_score, cls = scores.max(dim=1)
            keep = best_score > config.confidence
            detections = torch.cat(
                (boxes[keep], best_score[keep,None], cls[keep,None].to(boxes.dtype), source_indices[keep,None].to(boxes.dtype)),
                dim=1,
            )
        outputs.append(_deterministic_class_nms(detections, config))
    return outputs


def detections_to_coco(
    detections: torch.Tensor,
    *,
    image_id: int,
    original_width: int,
    original_height: int,
    scale: float,
    pad_left: int,
    pad_top: int,
) -> list[dict[str, Any]]:
    result = []
    for row in detections.detach().cpu().tolist():
        x1,y1,x2,y2,score,class_index,_source_index = row
        x1 = min(max((x1 - pad_left) / scale, 0.0), float(original_width))
        y1 = min(max((y1 - pad_top) / scale, 0.0), float(original_height))
        x2 = min(max((x2 - pad_left) / scale, 0.0), float(original_width))
        y2 = min(max((y2 - pad_top) / scale, 0.0), float(original_height))
        width = max(0.0, x2 - x1)
        height = max(0.0, y2 - y1)
        # Clipping can collapse an off-image prediction to a line.  Such a
        # record is not a valid COCO bbox and must not enter predictions.json.
        if width <= 0.0 or height <= 0.0:
            continue
        class_id = int(class_index)
        if not 0 <= class_id < 80:
            raise RuntimeError(f"decoded class index {class_id} is outside COCO80")
        result.append(
            {
                "image_id": int(image_id),
                "category_id": COCO80_TO_91[class_id],
                "bbox": [x1,y1,width,height],
                "score": float(score),
            }
        )
    return result

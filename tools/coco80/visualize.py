"""Render COCO-format board predictions on one source image."""

from __future__ import annotations

import argparse
import colorsys
import json
import math
from pathlib import Path
from typing import Any, Mapping, Sequence

from PIL import Image, ImageDraw, ImageFont

from .assets import sha256_file, write_json_atomic
from .common import COCO91_TO_COCO80, coco_class_name


class VisualizationError(RuntimeError):
    """The source image or prediction set violates the visualization contract."""


def _regular(path: str | Path, label: str) -> Path:
    target = Path(path).resolve()
    if target.is_symlink() or not target.is_file():
        raise VisualizationError(f"{label} is not a regular file: {target}")
    return target


def _json(path: str | Path, label: str) -> Any:
    target = _regular(path, label)
    try:
        return json.loads(target.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise VisualizationError(f"cannot parse {label}: {exc}") from exc


def _resolve_image(args: argparse.Namespace) -> tuple[Path, int]:
    if args.image is not None:
        if args.image_id is None:
            raise VisualizationError("--image requires --image-id")
        return _regular(args.image, "source image"), args.image_id
    if args.annotations is None or args.image_root is None or args.image_id is None:
        raise VisualizationError(
            "provide either --image/--image-id or --annotations/--image-root/--image-id"
        )
    annotations = _json(args.annotations, "COCO annotations")
    if not isinstance(annotations, Mapping) or not isinstance(annotations.get("images"), list):
        raise VisualizationError("COCO annotations lack an images array")
    matches = [row for row in annotations["images"] if row.get("id") == args.image_id]
    if len(matches) != 1 or not isinstance(matches[0].get("file_name"), str):
        raise VisualizationError(f"COCO image id {args.image_id} is absent or duplicated")
    root = Path(args.image_root).resolve()
    image = (root / matches[0]["file_name"]).resolve()
    try:
        image.relative_to(root)
    except ValueError as exc:
        raise VisualizationError("annotation image path escapes --image-root") from exc
    return _regular(image, "source image"), args.image_id


def _color(class_index: int) -> tuple[int, int, int]:
    # The golden-ratio hue step gives stable, well-separated neighboring classes.
    hue = (class_index * 0.618033988749895) % 1.0
    red, green, blue = colorsys.hsv_to_rgb(hue, 0.78, 1.0)
    return round(red * 255), round(green * 255), round(blue * 255)


def _predictions(
    path: str | Path, *, image_id: int, confidence: float, max_boxes: int
) -> list[dict[str, Any]]:
    payload = _json(path, "predictions JSON")
    if not isinstance(payload, list):
        raise VisualizationError("predictions JSON must be an array")
    selected: list[dict[str, Any]] = []
    for index, row in enumerate(payload):
        if not isinstance(row, Mapping) or row.get("image_id") != image_id:
            continue
        category = row.get("category_id")
        bbox = row.get("bbox")
        score = row.get("score")
        if (
            isinstance(category, bool) or not isinstance(category, int)
            or category not in COCO91_TO_COCO80
            or not isinstance(bbox, list) or len(bbox) != 4
            or isinstance(score, bool) or not isinstance(score, (int, float))
            or not all(isinstance(value, (int, float)) and math.isfinite(value) for value in bbox)
            or not math.isfinite(float(score)) or not 0.0 <= float(score) <= 1.0
            or float(bbox[2]) < 0.0 or float(bbox[3]) < 0.0
        ):
            raise VisualizationError(f"prediction row {index} is invalid")
        if float(score) >= confidence:
            selected.append({
                "category_id": category,
                "class_index": COCO91_TO_COCO80[category],
                "bbox": [float(value) for value in bbox],
                "score": float(score),
                "source_order": index,
            })
    selected.sort(key=lambda row: (-row["score"], row["source_order"]))
    return selected[:max_boxes]


def render(args: argparse.Namespace) -> dict[str, Any]:
    if not 0.0 <= args.confidence <= 1.0 or args.max_boxes <= 0:
        raise VisualizationError("confidence must be in [0,1] and max-boxes must be positive")
    image_path, image_id = _resolve_image(args)
    predictions_path = _regular(args.predictions, "predictions JSON")
    rows = _predictions(
        predictions_path,
        image_id=image_id,
        confidence=args.confidence,
        max_boxes=args.max_boxes,
    )
    try:
        image = Image.open(image_path).convert("RGB")
    except (OSError, ValueError) as exc:
        raise VisualizationError(f"cannot decode source image: {exc}") from exc
    draw = ImageDraw.Draw(image)
    width, height = image.size
    line_width = max(2, round(max(width, height) / 320))
    try:
        font = ImageFont.load_default(size=max(12, round(max(width, height) / 45)))
    except TypeError:  # Pillow < 10 compatibility.
        font = ImageFont.load_default()
    for row in reversed(rows):
        x, y, box_width, box_height = row["bbox"]
        x1 = min(max(x, 0.0), float(width - 1))
        y1 = min(max(y, 0.0), float(height - 1))
        x2 = min(max(x + box_width, x1), float(width - 1))
        y2 = min(max(y + box_height, y1), float(height - 1))
        color = _color(row["class_index"])
        draw.rectangle((x1, y1, x2, y2), outline=color, width=line_width)
        label = f"{coco_class_name(row['class_index'])} {row['score']:.3f}"
        bounds = draw.textbbox((x1, y1), label, font=font, stroke_width=1)
        label_width = bounds[2] - bounds[0] + 8
        label_height = bounds[3] - bounds[1] + 6
        label_x = min(x1, max(0.0, width - label_width))
        label_y = y1 - label_height if y1 >= label_height else y1
        draw.rectangle(
            (label_x, label_y, min(label_x + label_width, width), label_y + label_height),
            fill=color,
        )
        draw.text((label_x + 4, label_y + 2), label, fill=(0, 0, 0), font=font, stroke_width=0)
    if args.title:
        bounds = draw.textbbox((0, 0), args.title, font=font)
        title_width = bounds[2] - bounds[0] + 12
        title_height = bounds[3] - bounds[1] + 8
        draw.rectangle((0, 0, min(title_width, width), title_height), fill=(0, 0, 0))
        draw.text((6, 4), args.title, fill=(255, 255, 255), font=font)
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() and not args.overwrite:
        raise VisualizationError(f"refusing to overwrite output: {output}")
    image.save(output, quality=95, subsampling=0)
    summary = {
        "format": "kv260-coco80-visualization",
        "version": 1,
        "image_id": image_id,
        "confidence": args.confidence,
        "detections_drawn": len(rows),
        "source_image": {"path": str(image_path), "sha256": sha256_file(image_path)},
        "predictions": {"path": str(predictions_path), "sha256": sha256_file(predictions_path)},
        "output": {"path": str(output), "bytes": output.stat().st_size, "sha256": sha256_file(output)},
    }
    write_json_atomic(output.with_suffix(output.suffix + ".json"), summary)
    return summary


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--predictions", required=True, type=Path)
    parser.add_argument("--image-id", required=True, type=int)
    parser.add_argument("--image", type=Path)
    parser.add_argument("--annotations", type=Path)
    parser.add_argument("--image-root", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--confidence", type=float, default=0.25)
    parser.add_argument("--max-boxes", type=int, default=300)
    parser.add_argument("--title", default="")
    parser.add_argument("--overwrite", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    try:
        summary = render(_parser().parse_args(argv))
    except (VisualizationError, OSError, ValueError) as exc:
        print(f"FAIL: {exc}")
        return 1
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

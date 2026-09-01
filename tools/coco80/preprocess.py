"""Fixed preprocessing contract for the 416x416 hardware baseline."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import TYPE_CHECKING, Sequence

from .schemas import LetterboxMetadata

if TYPE_CHECKING:  # pragma: no cover - imports used only by type checkers
    from PIL import Image as ImageModule


MODEL_SIZE = 416
FILL_VALUE = 114


class PreprocessDependencyError(RuntimeError):
    """Raised when Pillow is not installed in the selected host environment."""


def _pillow():
    try:
        from PIL import Image
    except ImportError as exc:  # pragma: no cover - environment dependent
        raise PreprocessDependencyError(
            "Pillow is required for COCO80 preprocessing; install it with "
            "'python -m pip install Pillow'"
        ) from exc
    return Image


def letterbox_416(image: "ImageModule.Image") -> tuple["ImageModule.Image", LetterboxMetadata]:
    """Convert to RGB and apply centered PIL-bilinear 416x416 letterboxing.

    The geometry intentionally matches the existing board demo: the scaled
    dimensions use Python ``round()``, and an odd padding remainder is placed
    on the right or bottom.
    """

    Image = _pillow()
    if not isinstance(image, Image.Image):
        raise TypeError(f"image must be a PIL.Image.Image, got {type(image).__name__}")
    source = image.convert("RGB")
    source_width, source_height = source.size
    if source_width <= 0 or source_height <= 0:
        raise ValueError("source image dimensions must be positive")

    scale = min(MODEL_SIZE / source_width, MODEL_SIZE / source_height)
    resized_width = int(round(source_width * scale))
    resized_height = int(round(source_height * scale))
    resized_width = min(MODEL_SIZE, max(1, resized_width))
    resized_height = min(MODEL_SIZE, max(1, resized_height))

    try:
        bilinear = Image.Resampling.BILINEAR
    except AttributeError:  # Pillow < 9.1
        bilinear = Image.BILINEAR
    resized = source.resize((resized_width, resized_height), resample=bilinear)

    pad_left = (MODEL_SIZE - resized_width) // 2
    pad_top = (MODEL_SIZE - resized_height) // 2
    pad_right = MODEL_SIZE - resized_width - pad_left
    pad_bottom = MODEL_SIZE - resized_height - pad_top
    output = Image.new("RGB", (MODEL_SIZE, MODEL_SIZE), (FILL_VALUE,) * 3)
    output.paste(resized, (pad_left, pad_top))

    metadata = LetterboxMetadata(
        source_width=source_width,
        source_height=source_height,
        resized_width=resized_width,
        resized_height=resized_height,
        scale=scale,
        pad_left=pad_left,
        pad_top=pad_top,
        pad_right=pad_right,
        pad_bottom=pad_bottom,
    )
    return output, metadata


def letterbox_file(
    input_path: str | Path,
    output_path: str | Path,
) -> LetterboxMetadata:
    """Letterbox one image and save it, returning its geometry metadata."""

    Image = _pillow()
    source_path = Path(input_path)
    destination = Path(output_path)
    if not source_path.is_file():
        raise FileNotFoundError(f"input image does not exist: {source_path}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(source_path) as image:
        output, metadata = letterbox_416(image)
    output.save(destination)
    return metadata


def inverse_letterbox_xyxy(
    box: Sequence[float], metadata: LetterboxMetadata
) -> tuple[float, float, float, float]:
    """Map one model-space XYXY box to clipped source-image coordinates."""

    if len(box) != 4:
        raise ValueError("box must contain exactly four XYXY values")
    try:
        x1, y1, x2, y2 = (float(value) for value in box)
    except (TypeError, ValueError) as exc:
        raise ValueError("box values must be numeric") from exc
    values = (x1, y1, x2, y2)
    if not all(value == value and abs(value) != float("inf") for value in values):
        raise ValueError("box values must be finite")
    x1 = (x1 - metadata.pad_left) / metadata.scale
    x2 = (x2 - metadata.pad_left) / metadata.scale
    y1 = (y1 - metadata.pad_top) / metadata.scale
    y2 = (y2 - metadata.pad_top) / metadata.scale
    return (
        min(max(x1, 0.0), float(metadata.source_width)),
        min(max(y1, 0.0), float(metadata.source_height)),
        min(max(x2, 0.0), float(metadata.source_width)),
        min(max(y2, 0.0), float(metadata.source_height)),
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Apply the fixed RGB/PIL-bilinear/fill-114 416x416 letterbox"
    )
    parser.add_argument("input", type=Path, help="source image")
    parser.add_argument("output", type=Path, help="letterboxed image")
    parser.add_argument(
        "--metadata",
        type=Path,
        help="optional JSON metadata output (written atomically)",
    )
    args = parser.parse_args(argv)
    try:
        metadata = letterbox_file(args.input, args.output)
        payload = metadata.to_dict()
        if args.metadata:
            from .assets import write_json_atomic

            write_json_atomic(args.metadata, payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    except (OSError, ValueError, TypeError, PreprocessDependencyError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":  # pragma: no cover - exercised through CLI
    raise SystemExit(main())

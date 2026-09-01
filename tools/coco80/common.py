"""Constants and small helpers shared by the COCO80 host tools."""

from __future__ import annotations

from typing import Final


COCO_CLASS_COUNT: Final = 80

# COCO's annotation category ids are sparse.  Model class indices are dense
# [0, 79], so predictions must use this mapping before COCO API evaluation.
COCO80_TO_COCO91: Final[tuple[int, ...]] = (
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
    11, 13, 14, 15, 16, 17, 18, 19, 20, 21,
    22, 23, 24, 25, 27, 28, 31, 32, 33, 34,
    35, 36, 37, 38, 39, 40, 41, 42, 43, 44,
    46, 47, 48, 49, 50, 51, 52, 53, 54, 55,
    56, 57, 58, 59, 60, 61, 62, 63, 64, 65,
    67, 70, 72, 73, 74, 75, 76, 77, 78, 79,
    80, 81, 82, 84, 85, 86, 87, 88, 89, 90,
)

COCO91_TO_COCO80: Final[dict[int, int]] = {
    category_id: class_index
    for class_index, category_id in enumerate(COCO80_TO_COCO91)
}

COCO80_CLASS_NAMES: Final[tuple[str, ...]] = (
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train",
    "truck", "boat", "traffic light", "fire hydrant", "stop sign",
    "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep",
    "cow", "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella",
    "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard",
    "sports ball", "kite", "baseball bat", "baseball glove", "skateboard",
    "surfboard", "tennis racket", "bottle", "wine glass", "cup", "fork",
    "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
    "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
    "couch", "potted plant", "bed", "dining table", "toilet", "tv",
    "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave",
    "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase",
    "scissors", "teddy bear", "hair drier", "toothbrush",
)


class CocoCategoryError(ValueError):
    """Raised when a dense or sparse COCO class id is outside the contract."""


def coco80_to_coco91(class_index: int) -> int:
    """Return the official annotation category id for a dense class index."""

    if isinstance(class_index, bool) or not isinstance(class_index, int):
        raise CocoCategoryError(
            f"COCO80 class index must be an integer, got {class_index!r}"
        )
    if not 0 <= class_index < COCO_CLASS_COUNT:
        raise CocoCategoryError(
            f"COCO80 class index must be in [0, 79], got {class_index}"
        )
    return COCO80_TO_COCO91[class_index]


def coco91_to_coco80(category_id: int) -> int:
    """Return the dense model index for an official COCO category id."""

    if isinstance(category_id, bool) or not isinstance(category_id, int):
        raise CocoCategoryError(
            f"COCO category id must be an integer, got {category_id!r}"
        )
    try:
        return COCO91_TO_COCO80[category_id]
    except KeyError as exc:
        raise CocoCategoryError(
            f"category id {category_id} is not one of the 80 COCO categories"
        ) from exc


def coco_class_name(class_index: int) -> str:
    """Return the canonical COCO80 name for a dense model class index."""

    coco80_to_coco91(class_index)  # shared strict range/type validation
    return COCO80_CLASS_NAMES[class_index]


def coco80_to_coco91_class() -> list[int]:
    """Compatibility form used by Ultralytics v9.5: return a mutable copy."""

    return list(COCO80_TO_COCO91)

"""Deterministic, leakage-free COCO train2017 calibration/holdout selection."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


DEFAULT_SEED = 20260814


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def area_bucket(area: float) -> str:
    if area < 32.0 * 32.0:
        return "small"
    if area < 96.0 * 96.0:
        return "medium"
    return "large"


def load_train_index(annotation_path: Path) -> tuple[dict[int, dict[str, Any]], dict[int, set[tuple[int, str]]], list[int]]:
    payload = json.loads(annotation_path.read_text(encoding="utf-8"))
    images = {int(x["id"]): x for x in payload["images"]}
    category_ids = sorted(int(x["id"]) for x in payload["categories"])
    category_to_index = {category_id: index for index, category_id in enumerate(category_ids)}
    if len(category_to_index) != 80:
        raise RuntimeError(f"expected 80 COCO categories, got {len(category_to_index)}")
    coverage: dict[int, set[tuple[int, str]]] = defaultdict(set)
    for annotation in payload["annotations"]:
        if int(annotation.get("iscrowd", 0)) != 0:
            continue
        image_id = int(annotation["image_id"])
        category_id = int(annotation["category_id"])
        if image_id not in images or category_id not in category_to_index:
            raise RuntimeError("annotation references an unknown image/category")
        coverage[image_id].add((category_to_index[category_id], area_bucket(float(annotation["area"]))))
    return images, coverage, category_ids


def _stable_tie(seed: int, image_id: int) -> int:
    raw = f"{seed}:{image_id}".encode("ascii")
    return int.from_bytes(hashlib.sha256(raw).digest()[:8], "big")


def stratified_select(
    image_ids: Iterable[int],
    coverage: dict[int, set[tuple[int, str]]],
    count: int,
    seed: int,
    *,
    excluded: set[int] | None = None,
) -> list[int]:
    """Greedy rare-stratum coverage followed by deterministic seeded fill."""

    excluded = excluded or set()
    candidates = sorted(set(int(x) for x in image_ids) - excluded)
    if count <= 0 or count > len(candidates):
        raise ValueError(f"invalid selection count {count} for {len(candidates)} candidates")
    strata_frequency: Counter[tuple[int, str]] = Counter()
    for image_id in candidates:
        strata_frequency.update(coverage.get(image_id, set()))
    required = {(class_index, size) for class_index in range(80) for size in ("small", "medium", "large")}
    impossible = sorted(required - set(strata_frequency))
    if impossible:
        raise RuntimeError(f"COCO train annotations do not cover required strata: {impossible[:8]}")

    uncovered = set(required)
    remaining = set(candidates)
    selected: list[int] = []
    while uncovered and len(selected) < count:
        best = max(
            remaining,
            key=lambda image_id: (
                sum(1.0 / strata_frequency[item] for item in coverage.get(image_id, set()) & uncovered),
                len(coverage.get(image_id, set()) & uncovered),
                -_stable_tie(seed, image_id),
            ),
        )
        newly_covered = coverage.get(best, set()) & uncovered
        if not newly_covered:
            raise RuntimeError(f"selection stalled with {len(uncovered)} uncovered strata")
        selected.append(best)
        remaining.remove(best)
        uncovered -= newly_covered

    fill = list(remaining)
    random.Random(seed ^ 0xC0802017).shuffle(fill)
    selected.extend(fill[: count - len(selected)])
    if len(selected) != count or len(set(selected)) != count:
        raise RuntimeError("selection count/uniqueness invariant failed")
    return selected


def _list_sha256(image_ids: list[int]) -> str:
    text = "".join(f"{image_id:012d}\n" for image_id in image_ids).encode("ascii")
    return hashlib.sha256(text).hexdigest()


def build_split_manifest(
    annotation_path: Path,
    image_root: Path,
    output_path: Path,
    calibration_count: int = 1024,
    holdout_count: int = 512,
    seed: int = DEFAULT_SEED,
    *,
    hash_images: bool = True,
) -> dict[str, Any]:
    images, coverage, category_ids = load_train_index(annotation_path)
    image_ids = sorted(images)
    calibration_ids = stratified_select(image_ids, coverage, calibration_count, seed)
    holdout_ids = stratified_select(
        image_ids, coverage, holdout_count, seed ^ 0x51A7, excluded=set(calibration_ids)
    )
    if set(calibration_ids) & set(holdout_ids):
        raise RuntimeError("calibration and holdout sets overlap")

    def records(ids: list[int]) -> list[dict[str, Any]]:
        result = []
        for image_id in ids:
            metadata = images[image_id]
            image_path = image_root / metadata["file_name"]
            if not image_path.is_file():
                raise RuntimeError(f"missing train image: {image_path}")
            result.append(
                {
                    "image_id": image_id,
                    "file_name": metadata["file_name"],
                    "bytes": image_path.stat().st_size,
                    "sha256": sha256_file(image_path) if hash_images else None,
                    "strata": [list(x) for x in sorted(coverage.get(image_id, set()))],
                }
            )
        return result

    manifest: dict[str, Any] = {
        "format": "kv260-coco80-calibration-split",
        "version": 1,
        "seed": seed,
        "annotation": {
            "path": str(annotation_path.resolve()),
            "bytes": annotation_path.stat().st_size,
            "sha256": sha256_file(annotation_path),
        },
        "image_root": str(image_root.resolve()),
        "category_ids": category_ids,
        "calibration": {
            "count": len(calibration_ids),
            "image_id_list_sha256": _list_sha256(calibration_ids),
            "images": records(calibration_ids),
        },
        "holdout": {
            "count": len(holdout_ids),
            "image_id_list_sha256": _list_sha256(holdout_ids),
            "images": records(holdout_ids),
        },
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_suffix(output_path.suffix + ".tmp")
    temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(output_path)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--annotations", type=Path, required=True)
    parser.add_argument("--image-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--calibration-count", type=int, default=1024)
    parser.add_argument("--holdout-count", type=int, default=512)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--skip-image-hashes", action="store_true")
    args = parser.parse_args()
    manifest = build_split_manifest(
        args.annotations.resolve(),
        args.image_root.resolve(),
        args.output.resolve(),
        args.calibration_count,
        args.holdout_count,
        args.seed,
        hash_images=not args.skip_image_hashes,
    )
    print(
        f"calibration={manifest['calibration']['count']} "
        f"holdout={manifest['holdout']['count']} output={args.output.resolve()}"
    )


if __name__ == "__main__":
    main()

"""Select the frozen 128-image board conformance and 16-image golden sets."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import random
import struct
from typing import Any, Iterable
import zlib

from .assets import sha256_file, write_json_atomic
from .calibration import DEFAULT_SEED, area_bucket


CONFORMANCE_COUNT = 128
GOLDEN_COUNT = 16
CROWDED_OBJECTS = 50
SELECTION_MAGIC = 0x58533843  # C8SX
SELECTION_VERSION = 1
SELECTION_HEADER_BYTES = 128
SELECTION_ENTRY_BYTES = 8
_SELECTION_HEADER = struct.Struct("<32I")
_SELECTION_ENTRY = struct.Struct("<2I")


def aspect_bucket(width: int, height: int) -> str:
    if width <= 0 or height <= 0:
        raise ValueError("image dimensions must be positive")
    ratio = width / height
    if ratio >= 1.5:
        return "wide"
    if ratio <= 2.0 / 3.0:
        return "tall"
    return "square"


def _tie(seed: int, image_id: int) -> int:
    return int.from_bytes(hashlib.sha256(f"{seed}:{image_id}".encode("ascii")).digest()[:8], "big")


def _list_sha256(ids: Iterable[int]) -> str:
    payload = "".join(f"{value:012d}\n" for value in ids).encode("ascii")
    return hashlib.sha256(payload).hexdigest()


def _sha_words(value: str, label: str) -> tuple[int, ...]:
    if not isinstance(value, str) or len(value) != 64:
        raise RuntimeError(f"{label} is not a SHA256 digest")
    try:
        raw = bytes.fromhex(value)
    except ValueError as exc:
        raise RuntimeError(f"{label} is not hexadecimal") from exc
    return struct.unpack("<8I", raw)


def _header_crc(raw: bytes) -> int:
    if len(raw) != SELECTION_HEADER_BYTES:
        raise RuntimeError("conformance index header must contain 128 bytes")
    canonical = bytearray(raw)
    canonical[10 * 4 : 11 * 4] = bytes(4)
    return zlib.crc32(canonical) & 0xFFFFFFFF


def build_conformance_binary(
    selection_manifest: Path, input_index: Path, output: Path
) -> dict[str, Any]:
    """Bind the frozen 128-image order to the dense 5000-image SD index."""

    from .sd_pack import crc32_file, parse_input_binary_index

    selection_manifest = selection_manifest.resolve()
    input_index = input_index.resolve()
    output = output.resolve()
    selection = json.loads(selection_manifest.read_text(encoding="utf-8"))
    group = selection.get("conformance")
    images = group.get("images") if isinstance(group, dict) else None
    if (
        selection.get("format") != "kv260-coco80-board-conformance-selection"
        or selection.get("version") != 1
        or not isinstance(images, list)
        or len(images) != CONFORMANCE_COUNT
        or group.get("count") != CONFORMANCE_COUNT
    ):
        raise RuntimeError("unsupported frozen conformance selection manifest")
    selected_ids = [item.get("image_id") if isinstance(item, dict) else None for item in images]
    if (
        any(isinstance(value, bool) or not isinstance(value, int) or value <= 0 for value in selected_ids)
        or len(set(selected_ids)) != CONFORMANCE_COUNT
        or group.get("image_id_list_sha256") != _list_sha256(selected_ids)
    ):
        raise RuntimeError("conformance image-id order is invalid")
    dense = parse_input_binary_index(input_index)
    by_image = {entry["image_id"]: entry for entry in dense["entries"]}
    if len(by_image) != dense["image_count"]:
        raise RuntimeError("input index contains duplicate image ids")
    entries = bytearray()
    records: list[dict[str, int]] = []
    for image_id in selected_ids:
        indexed = by_image.get(image_id)
        if indexed is None:
            raise RuntimeError(f"conformance image {image_id} is absent from the input index")
        record_index = int(indexed["record_index"])
        entries.extend(_SELECTION_ENTRY.pack(image_id, record_index))
        records.append({"image_id": image_id, "record_index": record_index})
    selection_sha = sha256_file(selection_manifest)
    input_sha = sha256_file(input_index)
    words = [0] * 32
    words[0:12] = [
        SELECTION_MAGIC,
        SELECTION_VERSION,
        SELECTION_HEADER_BYTES,
        SELECTION_HEADER_BYTES + len(entries),
        len(records),
        SELECTION_ENTRY_BYTES,
        SELECTION_HEADER_BYTES,
        len(entries),
        crc32_file(input_index),
        zlib.crc32(entries) & 0xFFFFFFFF,
        0,
        0,
    ]
    words[12:20] = _sha_words(selection_sha, "selection manifest SHA256")
    words[20:28] = _sha_words(input_sha, "input index SHA256")
    raw_header = _SELECTION_HEADER.pack(*words)
    words[10] = _header_crc(raw_header)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp")
    try:
        with temporary.open("wb") as stream:
            stream.write(_SELECTION_HEADER.pack(*words))
            stream.write(entries)
            stream.flush()
            import os
            os.fsync(stream.fileno())
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    parsed = parse_conformance_binary(output, input_index)
    parsed["selection_manifest"] = str(selection_manifest)
    parsed["selection_manifest_sha256"] = selection_sha
    return parsed


def parse_conformance_binary(path: Path, input_index: Path) -> dict[str, Any]:
    """Validate a C8SX table and its complete binding to the SD input index."""

    from .sd_pack import crc32_file, parse_input_binary_index

    path = path.resolve()
    input_index = input_index.resolve()
    raw = path.read_bytes()
    if len(raw) < SELECTION_HEADER_BYTES:
        raise RuntimeError("conformance index is shorter than its header")
    header = raw[:SELECTION_HEADER_BYTES]
    words = _SELECTION_HEADER.unpack(header)
    if (
        words[0] != SELECTION_MAGIC
        or words[1] != SELECTION_VERSION
        or words[2] != SELECTION_HEADER_BYTES
        or words[3] != len(raw)
        or words[4] != CONFORMANCE_COUNT
        or words[5] != SELECTION_ENTRY_BYTES
        or words[6] != SELECTION_HEADER_BYTES
        or words[7] != words[4] * SELECTION_ENTRY_BYTES
        or words[6] + words[7] != len(raw)
        or words[8] != crc32_file(input_index)
        or words[11] != 0
        or not any(words[12:20])
        or _sha_words(sha256_file(input_index), "input index SHA256") != words[20:28]
        or any(words[28:32])
        or _header_crc(header) != words[10]
    ):
        raise RuntimeError("conformance index header is invalid")
    entry_raw = raw[words[6] :]
    if zlib.crc32(entry_raw) & 0xFFFFFFFF != words[9]:
        raise RuntimeError("conformance index entry CRC32 mismatch")
    dense = parse_input_binary_index(input_index)
    records = []
    seen_images: set[int] = set()
    seen_records: set[int] = set()
    for index in range(words[4]):
        image_id, record_index = _SELECTION_ENTRY.unpack_from(
            entry_raw, index * SELECTION_ENTRY_BYTES
        )
        if (
            image_id == 0
            or image_id in seen_images
            or record_index in seen_records
            or record_index >= dense["image_count"]
            or dense["entries"][record_index]["image_id"] != image_id
        ):
            raise RuntimeError(f"conformance index entry {index} is invalid")
        seen_images.add(image_id)
        seen_records.add(record_index)
        records.append({"image_id": image_id, "record_index": record_index})
    return {
        "format": "kv260-coco80-board-conformance-index",
        "version": SELECTION_VERSION,
        "path": str(path),
        "bytes": len(raw),
        "sha256": sha256_file(path),
        "crc32": crc32_file(path),
        "selection_manifest_sha256": bytes(struct.pack("<8I", *words[12:20])).hex(),
        "input_index_sha256": sha256_file(input_index),
        "input_index_crc32": words[8],
        "count": len(records),
        "records": records,
    }


def _pick_diversity_anchors(
    ids: list[int], metadata: dict[int, dict[str, Any]], counts: Counter[int], seed: int
) -> list[int]:
    result: list[int] = []

    def append_best(candidates: Iterable[int], *, dense: bool = False) -> None:
        candidates = list(candidates)
        if not candidates:
            raise RuntimeError("COCO val2017 lacks a required diversity category")
        if dense:
            best = max(candidates, key=lambda value: (counts[value], -_tie(seed, value)))
        else:
            best = min(candidates, key=lambda value: _tie(seed, value))
        if best not in result:
            result.append(best)

    append_best((value for value in ids if counts[value] == 0))
    append_best((value for value in ids if counts[value] >= CROWDED_OBJECTS), dense=True)
    for aspect in ("wide", "tall", "square"):
        append_best(
            value for value in ids
            if aspect_bucket(int(metadata[value]["width"]), int(metadata[value]["height"])) == aspect
        )
    return result


def _greedy_select(
    ids: list[int],
    coverage: dict[int, set[tuple[int, str]]],
    count: int,
    seed: int,
    initial: Iterable[int],
    *,
    require_full: bool,
) -> list[int]:
    selected = list(dict.fromkeys(int(value) for value in initial))
    if len(selected) > count or any(value not in ids for value in selected):
        raise RuntimeError("invalid conformance diversity anchors")
    required = {(class_index, size) for class_index in range(80) for size in ("small", "medium", "large")}
    frequencies: Counter[tuple[int, str]] = Counter()
    for image_id in ids:
        frequencies.update(coverage.get(image_id, set()))
    missing = required - set(frequencies)
    if missing:
        raise RuntimeError(f"COCO val2017 lacks required class/area strata: {sorted(missing)[:8]}")
    uncovered = required - set().union(*(coverage.get(value, set()) for value in selected))
    remaining = set(ids) - set(selected)
    while uncovered and len(selected) < count:
        best = max(
            remaining,
            key=lambda image_id: (
                sum(1.0 / frequencies[item] for item in coverage.get(image_id, set()) & uncovered),
                len(coverage.get(image_id, set()) & uncovered),
                -_tie(seed, image_id),
            ),
        )
        gained = coverage.get(best, set()) & uncovered
        if not gained:
            break
        selected.append(best)
        remaining.remove(best)
        uncovered -= gained
    if require_full and uncovered:
        raise RuntimeError(f"{count} conformance images leave {len(uncovered)} strata uncovered")
    fill = sorted(remaining)
    random.Random(seed ^ 0xC080C0DE).shuffle(fill)
    selected.extend(fill[: count - len(selected)])
    if len(selected) != count or len(set(selected)) != count:
        raise RuntimeError("conformance selection cardinality invariant failed")
    return selected


def build_conformance_manifest(
    annotations: Path,
    image_root: Path,
    output: Path,
    *,
    seed: int = DEFAULT_SEED,
) -> dict[str, Any]:
    raw = json.loads(annotations.read_text(encoding="utf-8"))
    metadata = {int(item["id"]): item for item in raw["images"]}
    category_ids = sorted(int(item["id"]) for item in raw["categories"])
    if len(metadata) != 5000 or len(category_ids) != 80:
        raise RuntimeError("conformance selection requires full COCO val2017")
    category_to_index = {value: index for index, value in enumerate(category_ids)}
    coverage: dict[int, set[tuple[int, str]]] = defaultdict(set)
    counts: Counter[int] = Counter()
    for annotation in raw["annotations"]:
        if int(annotation.get("iscrowd", 0)):
            continue
        image_id = int(annotation["image_id"])
        category_id = int(annotation["category_id"])
        if image_id not in metadata or category_id not in category_to_index:
            raise RuntimeError("annotation references an unknown image/category")
        counts[image_id] += 1
        coverage[image_id].add((category_to_index[category_id], area_bucket(float(annotation["area"]))))
    ids = sorted(metadata)
    anchors = _pick_diversity_anchors(ids, metadata, counts, seed)
    conformance = _greedy_select(
        ids, coverage, CONFORMANCE_COUNT, seed, anchors, require_full=True
    )
    golden = _greedy_select(
        conformance, coverage, GOLDEN_COUNT, seed ^ 0x16, anchors, require_full=False
    )
    golden_set = set(golden)
    represented = set().union(*(coverage.get(value, set()) for value in conformance))
    records = []
    for image_id in conformance:
        item = metadata[image_id]
        path = image_root / str(item["file_name"])
        if not path.is_file():
            raise RuntimeError(f"missing conformance image: {path}")
        records.append({
            "image_id": image_id,
            "file_name": str(item["file_name"]),
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
            "width": int(item["width"]),
            "height": int(item["height"]),
            "aspect": aspect_bucket(int(item["width"]), int(item["height"])),
            "object_count": counts[image_id],
            "empty": counts[image_id] == 0,
            "crowded": counts[image_id] >= CROWDED_OBJECTS,
            "golden16": image_id in golden_set,
            "strata": [list(value) for value in sorted(coverage.get(image_id, set()))],
        })
    manifest = {
        "format": "kv260-coco80-board-conformance-selection",
        "version": 1,
        "seed": seed,
        "annotation": {
            "path": str(annotations.resolve()),
            "bytes": annotations.stat().st_size,
            "sha256": sha256_file(annotations),
        },
        "image_root": str(image_root.resolve()),
        "category_ids": category_ids,
        "conformance": {
            "count": len(conformance),
            "image_id_list_sha256": _list_sha256(conformance),
            "covered_classes": len({value[0] for value in represented}),
            "covered_class_area_strata": len(represented),
            "images": records,
        },
        "golden16": {
            "count": len(golden),
            "image_ids": golden,
            "image_id_list_sha256": _list_sha256(golden),
        },
    }
    write_json_atomic(output, manifest)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--annotations", type=Path)
    parser.add_argument("--image-root", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--binary-from", type=Path)
    parser.add_argument("--input-index", type=Path)
    parser.add_argument("--binary-output", type=Path)
    args = parser.parse_args()
    binary_args = (args.input_index, args.binary_output)
    if args.binary_from is not None:
        if any(value is not None for value in (args.annotations, args.image_root, args.output)):
            parser.error("--binary-from cannot be combined with selection-generation arguments")
        if any(value is None for value in binary_args):
            parser.error("--binary-from requires --input-index and --binary-output")
        built = build_conformance_binary(
            args.binary_from, args.input_index, args.binary_output
        )
        result = {key: built[key] for key in (
            "format", "version", "path", "bytes", "sha256", "crc32",
            "selection_manifest_sha256", "input_index_sha256",
            "input_index_crc32", "count",
        )}
    else:
        if any(value is None for value in (args.annotations, args.image_root, args.output)):
            parser.error("selection generation requires --annotations, --image-root, and --output")
        if (args.input_index is None) != (args.binary_output is None):
            parser.error("--input-index and --binary-output must be supplied together")
        manifest = build_conformance_manifest(
            args.annotations.resolve(), args.image_root.resolve(), args.output.resolve(), seed=args.seed
        )
        result = {
            "conformance": manifest["conformance"]["count"],
            "golden": manifest["golden16"]["count"],
            "classes": manifest["conformance"]["covered_classes"],
            "strata": manifest["conformance"]["covered_class_area_strata"],
            "output": str(args.output.resolve()),
        }
        if args.input_index is not None:
            result["binary"] = build_conformance_binary(
                args.output, args.input_index, args.binary_output
            )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

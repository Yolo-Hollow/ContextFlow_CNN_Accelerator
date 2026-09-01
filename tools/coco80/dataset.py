"""Canonical COCO image iteration using the shared fixed-416 byte contract."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterator, Sequence

import numpy as np
import torch
from PIL import Image
from torch.utils.data import Dataset

from .preprocess import letterbox_416


class CocoFixed416Dataset(Dataset):
    def __init__(
        self,
        annotations: Path,
        image_root: Path,
        *,
        image_ids: Sequence[int] | None = None,
        verify_file_names: bool = True,
    ) -> None:
        payload = json.loads(annotations.read_text(encoding="utf-8"))
        records = {int(item["id"]): item for item in payload["images"]}
        selected = sorted(records) if image_ids is None else [int(value) for value in image_ids]
        if len(selected) != len(set(selected)):
            raise RuntimeError("image id selection contains duplicates")
        unknown = sorted(set(selected) - set(records))
        if unknown:
            raise RuntimeError(f"annotation file does not contain selected images: {unknown[:8]}")
        self.annotations = annotations.resolve()
        self.image_root = image_root.resolve()
        self.records = [records[image_id] for image_id in selected]
        if verify_file_names:
            missing = [x["file_name"] for x in self.records if not (self.image_root / x["file_name"]).is_file()]
            if missing:
                raise RuntimeError(f"missing COCO image files: {missing[:8]}")

    def __len__(self) -> int:
        return len(self.records)

    def __getitem__(self, index: int) -> dict[str, Any]:
        record = self.records[index]
        path = self.image_root / record["file_name"]
        with Image.open(path) as image:
            fixed, metadata = letterbox_416(image)
        hwc = np.asarray(fixed, dtype=np.uint8).copy()
        chw_u8 = torch.from_numpy(hwc).permute(2,0,1).contiguous()
        return {
            "image_u8": chw_u8,
            "image_float": chw_u8.to(torch.float32) / 255.0,
            "image_id": int(record["id"]),
            "file_name": str(record["file_name"]),
            "metadata": metadata.to_dict(),
        }


def collate_fixed416(samples: list[dict[str, Any]]) -> dict[str, Any]:
    if not samples:
        raise ValueError("cannot collate an empty batch")
    return {
        "image_u8": torch.stack([x["image_u8"] for x in samples]),
        "image_float": torch.stack([x["image_float"] for x in samples]),
        "image_id": [x["image_id"] for x in samples],
        "file_name": [x["file_name"] for x in samples],
        "metadata": [x["metadata"] for x in samples],
    }


def tensors_from_split_manifest(
    split_manifest: Path,
    split: str,
    *,
    batch_size: int = 1,
) -> Iterator[torch.Tensor]:
    payload = json.loads(split_manifest.read_text(encoding="utf-8"))
    if payload.get("format") != "kv260-coco80-calibration-split" or payload.get("version") != 1:
        raise RuntimeError("unsupported calibration split manifest")
    if split not in ("calibration", "holdout"):
        raise ValueError("split must be calibration or holdout")
    image_root = Path(payload["image_root"])
    records = payload[split]["images"]
    pending = []
    for record in records:
        path = image_root / record["file_name"]
        with Image.open(path) as image:
            fixed, _metadata = letterbox_416(image)
        array = np.asarray(fixed, dtype=np.uint8).copy()
        pending.append(torch.from_numpy(array).permute(2,0,1).to(torch.float32) / 255.0)
        if len(pending) == batch_size:
            yield torch.stack(pending)
            pending.clear()
    if pending:
        yield torch.stack(pending)

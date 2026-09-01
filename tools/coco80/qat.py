"""Hardware-constrained QAT fallback for a failed COCO80 PTQ accuracy gate.

The trainer is deliberately unavailable until a recorded full-val PTQ result
misses the requested budget.  It then trains the fused v9.5.0 convolution
weights with the exact frozen per-tensor activation/weight domains used by r5,
no AMP, batch four and eight-step accumulation.  Checkpoint selection uses only
the disjoint 512-image train2017 holdout from the calibration manifest.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import OrderedDict, defaultdict
from pathlib import Path
from types import MethodType
from typing import Any, Callable, Sequence

import numpy as np
import torch
import yaml
from PIL import Image
from torch.utils.data import DataLoader, Dataset

from .assets import sha256_file, write_json_atomic
from .common import COCO80_TO_COCO91
from .dataset import CocoFixed416Dataset, collate_fixed416
from .evaluate import evaluate_coco_detailed
from .model import conv_modules, forward_float_dag, load_official_model
from .postprocess import NmsConfig, decode_heads, detections_to_coco, non_max_suppression
from .preprocess import letterbox_416
from .qaware import FakeRtlYolo
from .quantization import (
    TensorQParams,
    build_quant_plan,
    qparams_from_plan,
    save_quant_checkpoint,
)
from .schemas import LetterboxMetadata


MAX_EPOCHS = 20
BATCH_SIZE = 4
EFFECTIVE_BATCH = 32
GRADIENT_ACCUMULATION = EFFECTIVE_BATCH // BATCH_SIZE
INITIAL_LR = 1.0e-4
SELECTION_PATIENCE = 3


def accuracy_budget_met(fp32: dict[str, Any], candidate: dict[str, Any]) -> bool:
    fp = fp32["coco"]["metrics"]
    quant = candidate["coco"]["metrics"]
    return (fp["AP50_95"] - quant["AP50_95"] <= 0.010) and (
        fp["AP50"] - quant["AP50"] <= 0.020
    )


def require_qat(
    fp32_summary: Path, ptq_summary: Path
) -> tuple[dict[str, Any], dict[str, Any]]:
    fp32 = json.loads(fp32_summary.read_text(encoding="utf-8"))
    ptq = json.loads(ptq_summary.read_text(encoding="utf-8"))
    if accuracy_budget_met(fp32, ptq):
        raise RuntimeError("PTQ already satisfies the accuracy budget; QAT is forbidden")
    return fp32, ptq


def frozen_qparams(
    quant_manifest: dict[str, Any],
) -> OrderedDict[str, dict[str, object]]:
    result: OrderedDict[str, dict[str, object]] = OrderedDict()
    for layer in quant_manifest["layers"]:
        quant = layer["quant"]
        if quant["weight_zero_point"] != 0:
            raise RuntimeError("QAT requires symmetric weight zero_point=0")
        input_q = TensorQParams(**quant["input"])
        output_q = TensorQParams(**quant["output"])
        input_q.validate()
        output_q.validate()
        result[layer["name"]] = {
            "input": input_q,
            "output": output_q,
            "weight_scale": float(quant["weight_scale"]),
            "activation": str(quant["activation"]),
        }
    if len(result) != 13:
        raise RuntimeError("QAT requires all 13 deployment layers")
    return result


def make_fake_rtl_model(
    model: torch.nn.Module, quant_manifest: dict[str, Any]
) -> FakeRtlYolo:
    return FakeRtlYolo(model, frozen_qparams(quant_manifest))


def enable_fused_conv_gradients(model: torch.nn.Module) -> int:
    """Enable only the 13 fused convolution weight/bias tensors for QAT."""

    count = 0
    for conv in conv_modules(model).values():
        conv.weight.requires_grad_(True)
        count += 1
        if conv.bias is None:
            raise RuntimeError("QAT requires every fused convolution to have a bias")
        conv.bias.requires_grad_(True)
        count += 1
    if count != 26:
        raise RuntimeError(f"QAT expected 26 trainable conv tensors, got {count}")
    return count


def cosine_lr(epoch: int) -> float:
    if not 0 <= epoch < MAX_EPOCHS:
        raise ValueError("epoch outside QAT schedule")
    return INITIAL_LR * 0.5 * (1.0 + math.cos(math.pi * epoch / MAX_EPOCHS))


def _split_ids(split: dict[str, Any], name: str) -> list[int]:
    records = split[name]["images"]
    result = [int(record["image_id"]) for record in records]
    if len(result) != len(set(result)) or len(result) != int(split[name]["count"]):
        raise RuntimeError(f"invalid {name} identity list")
    return result


class CocoQatDataset(Dataset):
    """Fixed-416 train2017 images and YOLO targets for the upstream loss."""

    def __init__(
        self,
        annotations: Path,
        image_root: Path,
        *,
        excluded_image_ids: set[int],
        limit: int | None = None,
    ) -> None:
        payload = json.loads(annotations.read_text(encoding="utf-8"))
        category_ids = sorted(int(item["id"]) for item in payload["categories"])
        if category_ids != list(COCO80_TO_COCO91):
            raise RuntimeError("train annotations do not use the official COCO80 categories")
        dense = {category_id: index for index, category_id in enumerate(category_ids)}
        images = {
            int(item["id"]): item
            for item in payload["images"]
            if int(item["id"]) not in excluded_image_ids
        }
        labels: dict[int, list[dict[str, Any]]] = defaultdict(list)
        for annotation in payload["annotations"]:
            image_id = int(annotation["image_id"])
            if image_id in images and int(annotation.get("iscrowd", 0)) == 0:
                labels[image_id].append(annotation)
        selected = sorted(images)
        if limit is not None:
            if limit <= 0:
                raise ValueError("training image limit must be positive")
            selected = selected[:limit]
        self.image_root = image_root.resolve()
        self.records = [images[image_id] for image_id in selected]
        self.labels = labels
        self.dense = dense
        missing = [
            record["file_name"]
            for record in self.records
            if not (self.image_root / record["file_name"]).is_file()
        ]
        if missing:
            raise RuntimeError(f"missing QAT images: {missing[:8]}")

    def __len__(self) -> int:
        return len(self.records)

    def __getitem__(self, index: int) -> tuple[torch.Tensor, torch.Tensor]:
        record = self.records[index]
        image_id = int(record["id"])
        with Image.open(self.image_root / record["file_name"]) as source:
            fixed, metadata = letterbox_416(source)
        array = np.asarray(fixed, dtype=np.uint8).copy()
        image = torch.from_numpy(array).permute(2, 0, 1).to(torch.float32) / 255.0
        targets = []
        for annotation in self.labels.get(image_id, []):
            x, y, width, height = (float(value) for value in annotation["bbox"])
            if width <= 0.0 or height <= 0.0:
                continue
            center_x = (x + width * 0.5) * metadata.scale + metadata.pad_left
            center_y = (y + height * 0.5) * metadata.scale + metadata.pad_top
            targets.append(
                [
                    0.0,
                    float(self.dense[int(annotation["category_id"])]),
                    center_x / 416.0,
                    center_y / 416.0,
                    width * metadata.scale / 416.0,
                    height * metadata.scale / 416.0,
                ]
            )
        tensor = torch.tensor(targets, dtype=torch.float32)
        if tensor.numel() == 0:
            tensor = torch.zeros((0, 6), dtype=torch.float32)
        return image, tensor


def collate_qat(
    samples: list[tuple[torch.Tensor, torch.Tensor]],
) -> tuple[torch.Tensor, torch.Tensor]:
    images = torch.stack([sample[0] for sample in samples])
    targets = []
    for batch_index, (_image, labels) in enumerate(samples):
        labels = labels.clone()
        labels[:, 0] = batch_index
        targets.append(labels)
    return images, torch.cat(targets, dim=0) if targets else torch.zeros((0, 6))


def _build_targets_v95_torch24(self: Any, p: Sequence[torch.Tensor], targets: torch.Tensor):
    """Ultralytics v9.5 target builder with Torch 2.4-safe integer clamps.

    The frozen upstream implementation passes floating scalar tensors as the
    bounds to in-place ``clamp_`` on int64 grid indices. Torch 2.4 rejects that
    lossy cast. Keep the v9.5 matching and zero-offset semantics, but derive
    grid bounds as Python integers. The upstream checkout remains untouched.
    """

    na, nt = self.na, targets.shape[0]
    tcls: list[torch.Tensor] = []
    tbox: list[torch.Tensor] = []
    indices: list[tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]] = []
    anch: list[torch.Tensor] = []
    gain = torch.ones(7, device=targets.device)
    anchor_ids = (
        torch.arange(na, device=targets.device).float().view(na, 1).repeat(1, nt)
    )
    targets = torch.cat((targets.repeat(na, 1, 1), anchor_ids[:, :, None]), 2)
    offsets_template = torch.tensor([[0, 0]], device=targets.device).float() * 0.5

    for index in range(self.nl):
        anchors = self.anchors[index]
        gain[2:6] = torch.tensor(
            p[index].shape, device=targets.device
        )[[3, 2, 3, 2]]
        selected = targets * gain
        if nt:
            ratio = selected[:, :, 4:6] / anchors[:, None]
            matches = torch.max(ratio, 1.0 / ratio).max(2)[0] < self.hyp["anchor_t"]
            selected = selected[matches]
            grid_xy = selected[:, 2:4]
            # v9.5 deliberately has only the zero offset enabled.
            mask = torch.stack((torch.ones_like(matches[matches]),))
            selected = selected.repeat((offsets_template.shape[0], 1, 1))[mask]
            offsets = (
                torch.zeros_like(grid_xy)[None] + offsets_template[:, None]
            )[mask]
        else:
            selected = targets[0]
            offsets = 0

        batch, classes = selected[:, :2].long().T
        grid_xy = selected[:, 2:4]
        grid_wh = selected[:, 4:6]
        grid_ij = (grid_xy - offsets).long()
        grid_x, grid_y = grid_ij.T
        anchor_index = selected[:, 6].long()
        max_y = int(p[index].shape[2]) - 1
        max_x = int(p[index].shape[3]) - 1
        indices.append(
            (
                batch,
                anchor_index,
                grid_y.clamp_(0, max_y),
                grid_x.clamp_(0, max_x),
            )
        )
        tbox.append(torch.cat((grid_xy - grid_ij, grid_wh), 1))
        anch.append(anchors[anchor_index])
        tcls.append(classes)
    return tcls, tbox, indices, anch


@torch.inference_mode()
def evaluate_holdout(
    model: torch.nn.Module,
    *,
    fake_rtl: bool,
    annotations: Path,
    image_root: Path,
    image_ids: list[int],
    device: torch.device,
    batch_size: int,
    workers: int,
) -> dict[str, Any]:
    dataset = CocoFixed416Dataset(annotations, image_root, image_ids=image_ids)
    loader = DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=False,
        num_workers=workers,
        collate_fn=collate_fixed416,
        pin_memory=device.type == "cuda",
    )
    predictions: list[dict[str, Any]] = []
    config = NmsConfig.accuracy()
    was_training = model.training
    model.eval()
    for batch in loader:
        image = batch["image_float"].to(device, non_blocking=True)
        if fake_rtl:
            node = model.forward_nodes(image)  # type: ignore[attr-defined]
        else:
            node = forward_float_dag(model, image)
        outputs = non_max_suppression(
            decode_heads(node["p4_detect"], node["p5_detect"]), config
        )
        for offset, detections in enumerate(outputs):
            metadata = LetterboxMetadata.from_dict(batch["metadata"][offset])
            predictions.extend(
                detections_to_coco(
                    detections,
                    image_id=batch["image_id"][offset],
                    original_width=metadata.source_width,
                    original_height=metadata.source_height,
                    scale=metadata.scale,
                    pad_left=metadata.pad_left,
                    pad_top=metadata.pad_top,
                )
            )
    model.train(was_training)
    return {
        "format": "kv260-coco80-qat-holdout-evaluation",
        "version": 1,
        "images": len(image_ids),
        "coco": evaluate_coco_detailed(
            annotations, predictions, image_ids=image_ids
        ),
    }


def _clone_conv_state(model: torch.nn.Module) -> dict[str, dict[str, torch.Tensor | None]]:
    return {
        name: {
            "weight": conv.weight.detach().cpu().clone(),
            "bias": conv.bias.detach().cpu().clone() if conv.bias is not None else None,
        }
        for name, conv in conv_modules(model).items()
    }


def _restore_conv_state(
    model: torch.nn.Module, state: dict[str, dict[str, torch.Tensor | None]]
) -> None:
    for name, conv in conv_modules(model).items():
        conv.weight.data.copy_(state[name]["weight"].to(conv.weight.device))  # type: ignore[union-attr]
        if conv.bias is not None:
            bias = state[name]["bias"]
            if bias is None:
                raise RuntimeError(f"saved QAT state is missing {name}.bias")
            conv.bias.data.copy_(bias.to(conv.bias.device))


def _save_conv_checkpoint_atomic(
    path: Path,
    epoch: int,
    state: dict[str, dict[str, torch.Tensor | None]],
) -> None:
    """Persist the best epoch before the next epoch can mutate its weights."""

    temporary = path.with_suffix(path.suffix + ".tmp")
    torch.save(
        {
            "format": "kv260-coco80-qat-conv-state",
            "version": 1,
            "epoch": epoch,
            "state": state,
        },
        temporary,
    )
    temporary.replace(path)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--quant-manifest", type=Path, required=True)
    parser.add_argument("--fp32-summary", type=Path, required=True)
    parser.add_argument("--ptq-summary", type=Path, required=True)
    parser.add_argument("--split-manifest", type=Path, required=True)
    parser.add_argument("--train-annotations", type=Path, required=True)
    parser.add_argument("--train-image-root", type=Path, required=True)
    parser.add_argument("--hyp", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--device", default="cuda:0")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--holdout-batch-size", type=int, default=8)
    parser.add_argument("--max-epochs", type=int, default=MAX_EPOCHS)
    parser.add_argument("--train-image-limit", type=int)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument(
        "--allow-budget-failure-for-deployment",
        action="store_true",
        help=(
            "export an explicitly non-release checkpoint even when the holdout "
            "accuracy budget fails"
        ),
    )
    args = parser.parse_args(argv)

    require_qat(args.fp32_summary, args.ptq_summary)
    split = json.loads(args.split_manifest.read_text(encoding="utf-8"))
    if split.get("format") != "kv260-coco80-calibration-split" or split.get("version") != 1:
        raise RuntimeError("unsupported calibration split manifest")
    if split["calibration"]["count"] != 1024 or split["holdout"]["count"] != 512:
        raise RuntimeError("QAT requires the frozen 1024/512 disjoint train split")
    calibration_ids = set(_split_ids(split, "calibration"))
    holdout_ids = _split_ids(split, "holdout")
    if calibration_ids & set(holdout_ids):
        raise RuntimeError("calibration and QAT holdout identities overlap")
    if not 1 <= args.max_epochs <= MAX_EPOCHS:
        raise RuntimeError(f"QAT epochs must be in [1,{MAX_EPOCHS}]")

    device = torch.device(args.device)
    base = load_official_model(args.upstream, args.weights, device, fuse=True)
    quant_manifest = json.loads(args.quant_manifest.read_text(encoding="utf-8"))
    fake = make_fake_rtl_model(base, quant_manifest).to(device)
    trainable_tensor_count = enable_fused_conv_gradients(base)
    hyperparameters = yaml.safe_load(args.hyp.read_text(encoding="utf-8"))
    for required in ("box", "obj", "cls", "cls_pw", "obj_pw", "fl_gamma", "anchor_t"):
        if required not in hyperparameters:
            raise RuntimeError(f"YOLO loss hyperparameters missing {required}")
    fake.hyp = hyperparameters
    fake.gr = 1.0

    if args.prepare_only:
        print(
            json.dumps(
                {
                    "status": "PASS",
                    "layers": list(fake.fake),
                    "epochs": args.max_epochs,
                    "batch": BATCH_SIZE,
                    "accumulation": GRADIENT_ACCUMULATION,
                    "initial_lr": INITIAL_LR,
                    "amp": False,
                    "holdout": len(holdout_ids),
                },
                indent=2,
            )
        )
        return 0

    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    dataset = CocoQatDataset(
        args.train_annotations,
        args.train_image_root,
        excluded_image_ids=set(holdout_ids),
        limit=args.train_image_limit,
    )
    generator = torch.Generator().manual_seed(20260814)
    loader = DataLoader(
        dataset,
        batch_size=BATCH_SIZE,
        shuffle=True,
        generator=generator,
        num_workers=args.workers,
        pin_memory=device.type == "cuda",
        collate_fn=collate_qat,
        drop_last=False,
    )
    upstream_text = str(args.upstream.resolve())
    if upstream_text not in sys.path:
        sys.path.insert(0, upstream_text)
    from utils.loss import ComputeLoss

    compute_loss = ComputeLoss(fake)
    compute_loss.build_targets = MethodType(  # type: ignore[method-assign]
        _build_targets_v95_torch24, compute_loss
    )
    trainable = [parameter for parameter in fake.parameters() if parameter.requires_grad]
    if len(trainable) != trainable_tensor_count:
        raise RuntimeError(
            "fake-RTL parameter registration differs from the 13 fused convolutions"
        )
    optimizer = torch.optim.SGD(
        trainable, lr=INITIAL_LR, momentum=0.937, nesterov=True
    )
    fp32_holdout = evaluate_holdout(
        base,
        fake_rtl=False,
        annotations=args.train_annotations,
        image_root=args.train_image_root,
        image_ids=holdout_ids,
        device=device,
        batch_size=args.holdout_batch_size,
        workers=args.workers,
    )
    write_json_atomic(output / "fp32_holdout_summary.json", fp32_holdout)

    history: list[dict[str, Any]] = []
    best_key = (-float("inf"), -float("inf"))
    best_state: dict[str, dict[str, torch.Tensor | None]] | None = None
    best_epoch = -1
    consecutive_passes = 0
    optimizer.zero_grad(set_to_none=True)
    for epoch in range(args.max_epochs):
        fake.train()
        lr = cosine_lr(epoch)
        for group in optimizer.param_groups:
            group["lr"] = lr
        loss_sum = 0.0
        optimizer_steps = 0
        for batch_index, (images, targets) in enumerate(loader):
            images = images.to(device, non_blocking=True)
            targets = targets.to(device, non_blocking=True)
            predictions = fake(images)
            loss, _parts = compute_loss(predictions, targets)
            (loss / GRADIENT_ACCUMULATION).backward()
            loss_sum += float(loss.detach().item())
            if (batch_index + 1) % GRADIENT_ACCUMULATION == 0 or batch_index + 1 == len(loader):
                optimizer.step()
                optimizer.zero_grad(set_to_none=True)
                optimizer_steps += 1
        holdout = evaluate_holdout(
            fake,
            fake_rtl=True,
            annotations=args.train_annotations,
            image_root=args.train_image_root,
            image_ids=holdout_ids,
            device=device,
            batch_size=args.holdout_batch_size,
            workers=args.workers,
        )
        metrics = holdout["coco"]["metrics"]
        passed = accuracy_budget_met(fp32_holdout, holdout)
        consecutive_passes = consecutive_passes + 1 if passed else 0
        record = {
            "epoch": epoch + 1,
            "lr": lr,
            "mean_batch_loss": loss_sum / max(1, len(loader)),
            "optimizer_steps": optimizer_steps,
            "holdout": holdout,
            "budget_pass": passed,
            "consecutive_budget_passes": consecutive_passes,
        }
        history.append(record)
        write_json_atomic(output / "history.json", history)
        key = (float(metrics["AP50_95"]), float(metrics["AP50"]))
        if key > best_key:
            best_key = key
            best_epoch = epoch + 1
            best_state = _clone_conv_state(base)
            _save_conv_checkpoint_atomic(
                output / "qat_best_conv_state.pt", best_epoch, best_state
            )
        print(
            f"QAT epoch={epoch + 1}/{args.max_epochs} loss={record['mean_batch_loss']:.6f} "
            f"AP50_95={key[0]:.6f} AP50={key[1]:.6f} budget={passed}"
        )
        if consecutive_passes >= SELECTION_PATIENCE:
            break

    if best_state is None:
        raise RuntimeError("QAT did not produce a selectable checkpoint")
    _restore_conv_state(base, best_state)
    checkpoint = output / "qat_best_conv_state.pt"
    if not checkpoint.is_file():
        raise RuntimeError("QAT best checkpoint was not persisted at epoch boundary")
    outputs, preacts = qparams_from_plan(quant_manifest)
    qat_plan, weights, luts = build_quant_plan(
        base, outputs, preacts, frozen_plan=quant_manifest
    )
    save_quant_checkpoint(
        output / "quant",
        qat_plan,
        weights,
        luts,
        source_weights=checkpoint,
        calibration_manifest=args.split_manifest,
    )
    best = history[best_epoch - 1]
    summary = {
        "format": "kv260-coco80-hardware-constrained-qat",
        "version": 1,
        "status": "PASS" if best["budget_pass"] else "FAIL",
        "release_eligible": bool(best["budget_pass"]),
        "deployment_override": bool(
            args.allow_budget_failure_for_deployment and not best["budget_pass"]
        ),
        "best_epoch": best_epoch,
        "best_holdout": best["holdout"],
        "settings": {
            "max_epochs": args.max_epochs,
            "completed_epochs": len(history),
            "batch": BATCH_SIZE,
            "effective_batch": EFFECTIVE_BATCH,
            "gradient_accumulation": GRADIENT_ACCUMULATION,
            "initial_lr": INITIAL_LR,
            "schedule": "cosine",
            "optimizer": "SGD(momentum=0.937,nesterov=True)",
            "amp": False,
            "fused_bn": True,
            "frozen_activation_and_weight_qparams": True,
            "trainable_conv_tensors": trainable_tensor_count,
            "upstream_loss_compatibility": "v9.5.0_torch24_integer_clamp_bounds",
            "selection_images": len(holdout_ids),
            "train_images": len(dataset),
        },
        "artifacts": {
            "source_weights_sha256": sha256_file(args.weights),
            "ptq_quant_manifest_sha256": sha256_file(args.quant_manifest),
            "split_manifest_sha256": sha256_file(args.split_manifest),
            "checkpoint_sha256": sha256_file(checkpoint),
            "qat_quant_manifest_sha256": sha256_file(
                output / "quant" / "quantization_manifest.json"
            ),
        },
    }
    write_json_atomic(output / "summary.json", summary)
    if summary["status"] != "PASS" and not args.allow_budget_failure_for_deployment:
        raise SystemExit("QAT exhausted its budget without satisfying holdout precision")
    if summary["status"] != "PASS":
        print(
            "WARNING: exporting a non-release QAT checkpoint under the explicit "
            "deployment-only override"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

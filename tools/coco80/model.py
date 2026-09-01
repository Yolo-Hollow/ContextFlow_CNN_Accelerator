"""Trusted loading and explicit full-DAG execution for YOLOv3-tiny COCO80.

The upstream ``Detect`` module combines the two raw heads with floating-point
decode.  Deployment needs the raw convolution tensors, so this module runs the
21-node graph explicitly and exposes both detector convolutions independently.
"""

from __future__ import annotations

import hashlib
import json
import sys
from collections import OrderedDict
from pathlib import Path
from typing import Any

import torch


OFFICIAL_WEIGHT_SHA256 = (
    "74fb61c9593f563fc8c87a6d792cfe127632e402440acd9c142a396813946280"
)
UPSTREAM_COMMIT = "8eb4cde090022af73db12cfa725ec4bf01d49c0e"
EXPECTED_RAW_SHAPES = ((1, 255, 26, 26), (1, 255, 13, 13))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_spec(path: Path | None = None) -> dict[str, Any]:
    path = path or Path(__file__).with_name("model_spec.json")
    spec = json.loads(path.read_text(encoding="utf-8"))
    if spec.get("format") != "kv260-coco80-yolov3-tiny-dag" or spec.get("version") != 1:
        raise RuntimeError(f"unsupported COCO80 DAG specification: {path}")
    if len(spec.get("conv_layers", [])) != 13:
        raise RuntimeError("COCO80 DAG must contain exactly 13 convolution dispatches")
    return spec


def _git_output(repo: Path, *args: str) -> str:
    import subprocess

    return subprocess.check_output(
        ["git", "-C", str(repo), *args], text=True, stderr=subprocess.STDOUT
    ).strip()


def verify_upstream(upstream_root: Path, weights: Path) -> dict[str, Any]:
    upstream_root = upstream_root.resolve()
    weights = weights.resolve()
    if not (upstream_root / ".git").is_dir():
        raise RuntimeError(f"upstream checkout is not a Git repository: {upstream_root}")
    commit = _git_output(upstream_root, "rev-parse", "HEAD")
    tag = _git_output(upstream_root, "describe", "--tags", "--exact-match")
    dirty = bool(_git_output(upstream_root, "status", "--porcelain"))
    if commit != UPSTREAM_COMMIT or tag != "v9.5.0" or dirty:
        raise RuntimeError(
            f"upstream identity mismatch: commit={commit}, tag={tag}, dirty={dirty}"
        )
    actual_sha = sha256_file(weights)
    if actual_sha != OFFICIAL_WEIGHT_SHA256:
        raise RuntimeError(
            f"official weight hash mismatch: {actual_sha} != {OFFICIAL_WEIGHT_SHA256}"
        )
    return {
        "upstream_commit": commit,
        "upstream_tag": tag,
        "upstream_dirty": dirty,
        "weights": str(weights),
        "weights_sha256": actual_sha,
        "weights_bytes": weights.stat().st_size,
    }


def load_official_model(
    upstream_root: Path,
    weights: Path,
    device: str | torch.device = "cpu",
    *,
    fuse: bool = True,
) -> torch.nn.Module:
    """Load the hash-pinned v9.5.0 checkpoint and validate its COCO topology."""

    verify_upstream(upstream_root, weights)
    root_text = str(upstream_root.resolve())
    if root_text not in sys.path:
        sys.path.insert(0, root_text)
    # PyTorch 2.6 changes the default to weights_only=True.  This historical
    # checkpoint contains a serialized Model and therefore requires False.
    checkpoint = torch.load(str(weights), map_location="cpu", weights_only=False)
    model = checkpoint.get("ema") or checkpoint.get("model") if isinstance(checkpoint, dict) else checkpoint
    if model is None:
        raise RuntimeError("checkpoint contains neither ema nor model")
    model = model.float().eval()
    if fuse:
        model = model.fuse().eval()
    model = model.to(device)
    detect = model.model[20]
    if int(detect.nc) != 80 or int(detect.no) != 85 or len(detect.m) != 2:
        raise RuntimeError(
            f"unexpected Detect topology: nc={detect.nc}, no={detect.no}, heads={len(detect.m)}"
        )
    expected = ((255, 256, 1, 1), (255, 512, 1, 1))
    actual = tuple(tuple(int(x) for x in conv.weight.shape) for conv in detect.m)
    if actual != expected:
        raise RuntimeError(f"unexpected Detect convolution shapes: {actual} != {expected}")
    return model


def forward_float_dag(model: torch.nn.Module, image_nchw: torch.Tensor) -> OrderedDict[str, torch.Tensor]:
    """Run the complete float graph and return all named nodes plus raw heads."""

    if image_nchw.ndim != 4 or tuple(image_nchw.shape[1:]) != (3, 416, 416):
        raise ValueError(f"expected NCHW [N,3,416,416], got {tuple(image_nchw.shape)}")
    m = model.model
    nodes: OrderedDict[str, torch.Tensor] = OrderedDict()
    nodes["input"] = image_nchw
    nodes["m0"] = m[0](nodes["input"])
    nodes["pool1"] = m[1](nodes["m0"])
    nodes["m2"] = m[2](nodes["pool1"])
    nodes["pool3"] = m[3](nodes["m2"])
    nodes["m4"] = m[4](nodes["pool3"])
    nodes["pool5"] = m[5](nodes["m4"])
    nodes["m6"] = m[6](nodes["pool5"])
    nodes["pool7"] = m[7](nodes["m6"])
    nodes["m8"] = m[8](nodes["pool7"])
    nodes["pool9"] = m[9](nodes["m8"])
    nodes["m10"] = m[10](nodes["pool9"])
    nodes["pad11"] = m[11](nodes["m10"])
    nodes["pool12"] = m[12](nodes["pad11"])
    nodes["m13"] = m[13](nodes["pool12"])
    nodes["m14"] = m[14](nodes["m13"])
    nodes["m15"] = m[15](nodes["m14"])
    nodes["m16"] = m[16](nodes["m14"])
    nodes["upsample17"] = m[17](nodes["m16"])
    nodes["concat18"] = m[18]([nodes["upsample17"], nodes["m8"]])
    nodes["m19"] = m[19](nodes["concat18"])
    detect = m[20]
    nodes["p4_detect"] = detect.m[0](nodes["m19"])
    nodes["p5_detect"] = detect.m[1](nodes["m15"])
    batch = int(image_nchw.shape[0])
    expected = ((batch, 255, 26, 26), (batch, 255, 13, 13))
    actual = (tuple(nodes["p4_detect"].shape), tuple(nodes["p5_detect"].shape))
    if actual != expected:
        raise RuntimeError(f"raw detector head shape mismatch: {actual} != {expected}")
    return nodes


def raw_head_nahwc(raw_nchw: torch.Tensor, classes: int = 80) -> torch.Tensor:
    """Convert NCHW 255-channel logits to [N,3,H,W,85]."""

    no = classes + 5
    n, c, h, w = raw_nchw.shape
    if c != 3 * no:
        raise ValueError(f"raw head channels {c} != 3*{no}")
    return raw_nchw.view(n, 3, no, h, w).permute(0, 1, 3, 4, 2).contiguous()


def conv_modules(model: torch.nn.Module) -> OrderedDict[str, torch.nn.Conv2d]:
    """Return the 13 fused Conv2d modules in deployment dispatch order."""

    result: OrderedDict[str, torch.nn.Conv2d] = OrderedDict()
    for name, index in (
        ("m0", 0), ("m2", 2), ("m4", 4), ("m6", 6), ("m8", 8),
        ("m10", 10), ("m13", 13), ("m14", 14), ("m15", 15),
        ("m16", 16), ("m19", 19),
    ):
        module = model.model[index]
        if not hasattr(module, "conv") or hasattr(module, "bn"):
            raise RuntimeError(f"model layer {index} is not a fused Conv module")
        result[name] = module.conv
    detect = model.model[20]
    result["p4_detect"] = detect.m[0]
    result["p5_detect"] = detect.m[1]
    return result

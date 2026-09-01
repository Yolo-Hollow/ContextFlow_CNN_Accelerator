"""Executable r5 PTQ graph used for host accuracy and exact golden export.

``fast`` mode uses float32 convolution over integer-valued operands and is for
full-dataset accuracy throughput. ``exact`` uses float64 CPU convolution; all
integer operands and sums are exactly representable and it is the authority for
byte-exact conformance fixtures.
"""

from __future__ import annotations

import json
from collections import OrderedDict
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F

from .quantization import TensorQParams, quantize_u8


def _qparams(value: dict[str, Any]) -> TensorQParams:
    return TensorQParams(
        scale=float(value["scale"]),
        zero_point=int(value["zero_point"]),
        qmin=int(value["qmin"]),
        qmax=int(value["qmax"]),
    )


def _read_i8(path: Path, shape: list[int]) -> torch.Tensor:
    data = bytearray(path.read_bytes())
    expected = 1
    for value in shape:
        expected *= int(value)
    if len(data) != expected:
        raise RuntimeError(f"{path}: {len(data)} bytes, expected {expected}")
    return torch.frombuffer(data, dtype=torch.int8).clone().reshape(shape)


def _read_lut(path: Path) -> torch.Tensor:
    data = path.read_bytes()
    if len(data) != 256:
        raise RuntimeError(f"{path}: activation LUT must contain 256 bytes")
    return torch.tensor(list(data), dtype=torch.uint8)


def signed_round_shift(value: torch.Tensor, shift: int) -> torch.Tensor:
    """Match RTL: add positive half, then arithmetic right shift."""

    if shift <= 0:
        raise ValueError("effective shift must be positive")
    return torch.floor_divide(value + (1 << (shift - 1)), 1 << shift)


def affine_ratio(multiplier: int, shift: int) -> float:
    return multiplier / float(1 << shift)


def solve_affine_multiplier(ratio: float) -> tuple[int, int]:
    if not (ratio > 0.0):
        raise RuntimeError(f"invalid affine ratio {ratio}")
    best = None
    for shift in range(8, 31):
        multiplier = int(round(ratio * (1 << shift)))
        if not 1 <= multiplier <= 0x7FFFFFFF:
            continue
        error = abs(affine_ratio(multiplier, shift) - ratio)
        candidate = (error, -shift, multiplier)
        if best is None or candidate < best:
            best = candidate
    if best is None:
        raise RuntimeError(f"affine ratio {ratio} cannot be represented")
    return int(best[2]), int(-best[1])


def requant_affine_u8(
    source: torch.Tensor,
    source_q: TensorQParams,
    target_q: TensorQParams,
    multiplier: int | None = None,
    shift: int | None = None,
) -> torch.Tensor:
    if multiplier is None or shift is None:
        multiplier, shift = solve_affine_multiplier(source_q.scale / target_q.scale)
    delta = source.to(torch.int64) - source_q.zero_point
    product = delta * int(multiplier)
    half = 1 << (int(shift) - 1)
    # Symmetric nearest, ties away from zero.  The same formula is used by the
    # A53 C implementation and is independent of the host FPU rounding mode.
    rounded = torch.where(
        product >= 0,
        torch.floor_divide(product + half, 1 << int(shift)),
        -torch.floor_divide(-product + half, 1 << int(shift)),
    )
    return torch.clamp(rounded + target_q.zero_point, target_q.qmin, target_q.qmax).to(torch.uint8)


class RtlPtqRunner:
    def __init__(self, quant_dir: Path, device: str | torch.device = "cpu", *, exact: bool = False):
        self.quant_dir = quant_dir.resolve()
        self.plan = json.loads((self.quant_dir / "quantization_manifest.json").read_text(encoding="utf-8"))
        if self.plan.get("format") != "kv260-coco80-rtl-quantization" or self.plan.get("version") != 1:
            raise RuntimeError("unsupported quantization manifest")
        self.exact = exact
        self.device = torch.device("cpu" if exact else device)
        self.compute_dtype = torch.float64 if exact else torch.float32
        if not exact and self.device.type == "cuda":
            torch.backends.cuda.matmul.allow_tf32 = False
            torch.backends.cudnn.allow_tf32 = False
        self.layers: OrderedDict[str, dict[str, Any]] = OrderedDict()
        self.weights: dict[str, torch.Tensor] = {}
        self.biases: dict[str, torch.Tensor] = {}
        self.luts: dict[str, torch.Tensor] = {}
        for layer in self.plan["layers"]:
            name = layer["name"]
            files = layer["files"]
            self.layers[name] = layer
            self.weights[name] = _read_i8(
                self.quant_dir / files["weight_raw_oihw_s8"]["path"], layer["weight_shape_oihw"]
            ).to(self.device)
            bias_path = self.quant_dir / files["bias_i32"]["path"]
            raw_bias = bytearray(bias_path.read_bytes())
            self.biases[name] = torch.frombuffer(raw_bias, dtype=torch.int32).clone().to(self.device)
            self.luts[name] = _read_lut(self.quant_dir / files["activation_lut_u8"]["path"]).to(self.device)

    @property
    def input_qparams(self) -> TensorQParams:
        return _qparams(self.layers["m0"]["quant"]["input"])

    def _conv(self, name: str, source_u8: torch.Tensor) -> torch.Tensor:
        layer = self.layers[name]
        quant = layer["quant"]
        input_q = _qparams(quant["input"])
        if int(source_u8.min()) < input_q.qmin or int(source_u8.max()) > input_q.qmax:
            raise RuntimeError(f"{name}: source bytes outside declared quant range")
        centered = torch.clamp(source_u8.to(torch.int16) - input_q.zero_point, -128, 127)
        acc = F.conv2d(
            centered.to(self.compute_dtype),
            self.weights[name].to(self.compute_dtype),
            self.biases[name].to(self.compute_dtype),
            stride=int(layer["stride"]),
            padding=int(layer["pad"]),
        )
        # Integer-valued operands produce exact float64 sums.  Fast float32 is
        # explicitly not used as the conformance authority.
        acc_i64 = torch.round(acc).to(torch.int64)
        effective_shift = 15 + int(quant["shift"])
        requant = signed_round_shift(acc_i64 * int(quant["multiplier"]), effective_shift)
        requant = torch.clamp(requant, -128, 127)
        indices = torch.bitwise_and(requant, 0xFF).to(torch.long)
        return self.luts[name][indices]

    @staticmethod
    def _pool2(source: torch.Tensor) -> torch.Tensor:
        return F.max_pool2d(source.to(torch.float32), 2, 2).to(torch.uint8)

    @staticmethod
    def _special_pool(source: torch.Tensor, zero_point: int) -> torch.Tensor:
        padded = F.pad(source.to(torch.float32), (0, 1, 0, 1), value=float(zero_point))
        return F.max_pool2d(padded, 2, 1).to(torch.uint8)

    @torch.inference_mode()
    def run(self, image: torch.Tensor, *, image_is_quantized: bool = False) -> OrderedDict[str, torch.Tensor]:
        if image.ndim == 3:
            image = image.unsqueeze(0)
        if tuple(image.shape[1:]) != (3, 416, 416):
            raise ValueError(f"expected [N,3,416,416], got {tuple(image.shape)}")
        nodes: OrderedDict[str, torch.Tensor] = OrderedDict()
        nodes["input"] = image.to(self.device, dtype=torch.uint8) if image_is_quantized else quantize_u8(image.to(self.device), self.input_qparams)
        nodes["m0"] = self._conv("m0", nodes["input"])
        nodes["pool1"] = self._pool2(nodes["m0"])
        nodes["m2"] = self._conv("m2", nodes["pool1"])
        nodes["pool3"] = self._pool2(nodes["m2"])
        nodes["m4"] = self._conv("m4", nodes["pool3"])
        nodes["pool5"] = self._pool2(nodes["m4"])
        nodes["m6"] = self._conv("m6", nodes["pool5"])
        nodes["pool7"] = self._pool2(nodes["m6"])
        nodes["m8"] = self._conv("m8", nodes["pool7"])
        nodes["pool9"] = self._pool2(nodes["m8"])
        nodes["m10"] = self._conv("m10", nodes["pool9"])
        m10_q = _qparams(self.layers["m10"]["quant"]["output"])
        nodes["pool12"] = self._special_pool(nodes["m10"], m10_q.zero_point)
        nodes["m13"] = self._conv("m13", nodes["pool12"])
        nodes["m14"] = self._conv("m14", nodes["m13"])
        nodes["m15"] = self._conv("m15", nodes["m14"])
        nodes["m16"] = self._conv("m16", nodes["m14"])
        nodes["upsample17"] = nodes["m16"].repeat_interleave(2, dim=2).repeat_interleave(2, dim=3)
        m8_q = _qparams(self.layers["m8"]["quant"]["output"])
        m16_q = _qparams(self.layers["m16"]["quant"]["output"])
        route = requant_affine_u8(nodes["m8"], m8_q, m16_q)
        nodes["concat18"] = torch.cat((nodes["upsample17"], route), dim=1)
        nodes["m19"] = self._conv("m19", nodes["concat18"])
        nodes["p4_detect"] = self._conv("p4_detect", nodes["m19"])
        nodes["p5_detect"] = self._conv("p5_detect", nodes["m15"])
        expected = ((image.shape[0],255,26,26), (image.shape[0],255,13,13))
        actual = (tuple(nodes["p4_detect"].shape), tuple(nodes["p5_detect"].shape))
        if actual != expected:
            raise RuntimeError(f"raw head shapes {actual} != {expected}")
        return nodes

    def dequantized_heads(self, nodes: dict[str, torch.Tensor]) -> tuple[torch.Tensor, torch.Tensor]:
        result = []
        for name in ("p4_detect", "p5_detect"):
            qparams = _qparams(self.layers[name]["quant"]["output"])
            result.append((nodes[name].to(torch.float32) - qparams.zero_point) * qparams.scale)
        return result[0], result[1]

"""Differentiable fake-RTL quantization modules used by the optional QAT path."""

from __future__ import annotations

import torch
import torch.nn.functional as F

from .model import conv_modules, raw_head_nahwc
from .quantization import QMAX_ACTIVATION, QMAX_WEIGHT, TensorQParams


def ste_quantize_activation(value: torch.Tensor, qparams: TensorQParams) -> torch.Tensor:
    quant = torch.clamp(torch.round(value / qparams.scale) + qparams.zero_point, 0, QMAX_ACTIVATION)
    dequant = (quant - qparams.zero_point) * qparams.scale
    return value + (dequant - value).detach()


def ste_quantize_weight(value: torch.Tensor, scale: float) -> torch.Tensor:
    quant = torch.clamp(torch.round(value / scale), -QMAX_WEIGHT, QMAX_WEIGHT)
    dequant = quant * scale
    return value + (dequant - value).detach()


class FakeRtlConv(torch.nn.Module):
    """Wrap a fused Conv2d and fake-quantize per tensor with frozen qparams."""

    def __init__(
        self,
        conv: torch.nn.Conv2d,
        input_qparams: TensorQParams,
        output_qparams: TensorQParams,
        weight_scale: float,
        activation: str,
    ) -> None:
        super().__init__()
        self.conv = conv
        self.input_qparams = input_qparams
        self.output_qparams = output_qparams
        self.weight_scale = float(weight_scale)
        self.activation = activation

    def forward(self, value: torch.Tensor) -> torch.Tensor:
        value = ste_quantize_activation(value, self.input_qparams)
        weight = ste_quantize_weight(self.conv.weight, self.weight_scale)
        value = torch.nn.functional.conv2d(
            value, weight, self.conv.bias, self.conv.stride, self.conv.padding,
            self.conv.dilation, self.conv.groups,
        )
        if self.activation == "leaky_relu_0p1":
            value = torch.nn.functional.leaky_relu(value, 0.1)
        elif self.activation != "identity":
            raise RuntimeError(f"unsupported activation {self.activation}")
        return ste_quantize_activation(value, self.output_qparams)


class FakeRtlYolo(torch.nn.Module):
    """Differentiable full YOLOv3-tiny DAG in the frozen r5 quant domains.

    The wrapper exposes ``model[-1]``, ``hyp`` and ``gr`` exactly as the
    upstream ``ComputeLoss`` contract expects, while bypassing Detect's float
    decode and returning the two raw ``[N,3,H,W,85]`` tensors.
    """

    def __init__(
        self,
        base: torch.nn.Module,
        qparams: dict[str, dict[str, object]],
    ) -> None:
        super().__init__()
        self.model = base.model
        self.yaml = getattr(base, "yaml", None)
        self.nc = 80
        self.gr = float(getattr(base, "gr", 1.0))
        self.hyp = dict(getattr(base, "hyp", {}))
        modules = conv_modules(base)
        if list(modules) != list(qparams):
            raise RuntimeError("fake-RTL layer identity/order differs from quant manifest")
        self.fake = torch.nn.ModuleDict(
            {
                name: FakeRtlConv(
                    modules[name],
                    value["input"],  # type: ignore[arg-type]
                    value["output"],  # type: ignore[arg-type]
                    float(value["weight_scale"]),
                    str(value["activation"]),
                )
                for name, value in qparams.items()
            }
        )
        self.output_qparams = {
            name: value["output"] for name, value in qparams.items()
        }

    def forward_nodes(self, image: torch.Tensor) -> dict[str, torch.Tensor]:
        if image.ndim != 4 or tuple(image.shape[1:]) != (3, 416, 416):
            raise ValueError(f"expected [N,3,416,416], got {tuple(image.shape)}")
        node: dict[str, torch.Tensor] = {"input": image}
        node["m0"] = self.fake["m0"](node["input"])
        node["pool1"] = F.max_pool2d(node["m0"], 2, 2)
        node["m2"] = self.fake["m2"](node["pool1"])
        node["pool3"] = F.max_pool2d(node["m2"], 2, 2)
        node["m4"] = self.fake["m4"](node["pool3"])
        node["pool5"] = F.max_pool2d(node["m4"], 2, 2)
        node["m6"] = self.fake["m6"](node["pool5"])
        node["pool7"] = F.max_pool2d(node["m6"], 2, 2)
        node["m8"] = self.fake["m8"](node["pool7"])
        node["pool9"] = F.max_pool2d(node["m8"], 2, 2)
        node["m10"] = self.fake["m10"](node["pool9"])
        # The quantized padding byte is m10.output zero_point, i.e. real zero.
        node["pool12"] = F.max_pool2d(F.pad(node["m10"], (0, 1, 0, 1), value=0.0), 2, 1)
        node["m13"] = self.fake["m13"](node["pool12"])
        node["m14"] = self.fake["m14"](node["m13"])
        node["m15"] = self.fake["m15"](node["m14"])
        node["m16"] = self.fake["m16"](node["m14"])
        node["upsample17"] = F.interpolate(node["m16"], scale_factor=2, mode="nearest")
        # Route bytes are explicitly requantized to the m16 output domain.
        route = ste_quantize_activation(
            node["m8"], self.output_qparams["m16"]  # type: ignore[arg-type]
        )
        node["concat18"] = torch.cat((node["upsample17"], route), dim=1)
        node["m19"] = self.fake["m19"](node["concat18"])
        node["p4_detect"] = self.fake["p4_detect"](node["m19"])
        node["p5_detect"] = self.fake["p5_detect"](node["m15"])
        return node

    def forward(self, image: torch.Tensor) -> list[torch.Tensor]:
        node = self.forward_nodes(image)
        return [raw_head_nahwc(node["p4_detect"]), raw_head_nahwc(node["p5_detect"])]

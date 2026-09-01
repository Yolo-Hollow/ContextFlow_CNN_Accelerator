"""Hardware-compatible per-tensor PTQ for the r5 YOLOv3-tiny datapath."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from collections import OrderedDict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable

import torch
import torch.nn.functional as F
from torch.ao.quantization.observer import HistogramObserver

from .model import conv_modules, forward_float_dag, load_official_model, load_spec, sha256_file


QMIN_ACTIVATION = 0
QMAX_ACTIVATION = 127
QMIN_WEIGHT = -127
QMAX_WEIGHT = 127


@dataclass(frozen=True)
class TensorQParams:
    scale: float
    zero_point: int
    qmin: int
    qmax: int

    def validate(self) -> None:
        if not math.isfinite(self.scale) or self.scale <= 0.0:
            raise RuntimeError(f"invalid quantization scale {self.scale}")
        if not self.qmin <= self.zero_point <= self.qmax:
            raise RuntimeError(f"zero point {self.zero_point} outside [{self.qmin},{self.qmax}]")


@dataclass(frozen=True)
class ConvQuantParams:
    name: str
    input: TensorQParams
    output: TensorQParams
    preactivation_scale: float
    weight_scale: float
    weight_zero_point: int
    multiplier: int
    shift: int
    effective_scale: float
    effective_scale_error: float
    activation: str
    input_center_saturation_possible: bool
    bias_min: int
    bias_max: int
    accumulator_abs_bound: int


def _activation_observer() -> HistogramObserver:
    return HistogramObserver(
        dtype=torch.quint8,
        qscheme=torch.per_tensor_affine,
        quant_min=QMIN_ACTIVATION,
        quant_max=QMAX_ACTIVATION,
        reduce_range=False,
    )


def _preactivation_observer() -> HistogramObserver:
    return HistogramObserver(
        dtype=torch.qint8,
        qscheme=torch.per_tensor_symmetric,
        quant_min=-128,
        quant_max=127,
        reduce_range=False,
    )


def observer_qparams(observer: HistogramObserver, *, signed: bool = False) -> TensorQParams:
    scale, zero_point = observer.calculate_qparams()
    qparams = TensorQParams(
        float(scale.item()), int(zero_point.item()), -128 if signed else 0, 127
    )
    qparams.validate()
    if signed and qparams.zero_point != 0:
        raise RuntimeError(f"symmetric preactivation observer produced zp={qparams.zero_point}")
    return qparams


def quantize_u8(tensor: torch.Tensor, qparams: TensorQParams) -> torch.Tensor:
    return torch.clamp(torch.round(tensor / qparams.scale) + qparams.zero_point, qparams.qmin, qparams.qmax).to(torch.uint8)


def dequantize_u8(tensor: torch.Tensor, qparams: TensorQParams) -> torch.Tensor:
    return (tensor.to(torch.float32) - qparams.zero_point) * qparams.scale


def quantize_weight(weight: torch.Tensor) -> tuple[torch.Tensor, float]:
    maximum = float(weight.detach().abs().max().item())
    scale = maximum / QMAX_WEIGHT if maximum > 0.0 else 1.0
    quantized = torch.clamp(torch.round(weight.detach() / scale), QMIN_WEIGHT, QMAX_WEIGHT).to(torch.int8)
    return quantized, scale


def quantize_weight_fixed(weight: torch.Tensor, scale: float) -> torch.Tensor:
    """Quantize a QAT weight tensor in the frozen deployment domain."""

    if not math.isfinite(scale) or scale <= 0.0:
        raise RuntimeError(f"invalid frozen weight scale {scale}")
    return torch.clamp(
        torch.round(weight.detach() / scale), QMIN_WEIGHT, QMAX_WEIGHT
    ).to(torch.int8)


def solve_multiplier(real_scale: float) -> tuple[int, int, float, float]:
    """Fit ``mult / 2**(15+shift)`` to the requested positive scale."""

    if not math.isfinite(real_scale) or real_scale <= 0.0 or real_scale >= 2.0:
        raise RuntimeError(f"RTL multiplier scale {real_scale} is outside (0,2)")
    best: tuple[float, int, int, float] | None = None
    for shift in range(16):
        multiplier = int(round(real_scale * (1 << (15 + shift))))
        if not 1 <= multiplier <= 0xFFFF:
            continue
        represented = multiplier / float(1 << (15 + shift))
        error = abs(represented - real_scale)
        candidate = (error, -shift, multiplier, represented)
        if best is None or candidate < best:
            best = candidate
    if best is None:
        raise RuntimeError(f"RTL multiplier scale {real_scale} is not representable")
    error, neg_shift, multiplier, represented = best
    return multiplier, -neg_shift, represented, error


def activation_lut(
    preactivation_scale: float,
    output: TensorQParams,
    activation: str,
) -> bytes:
    values = bytearray(256)
    for index in range(256):
        signed = index if index < 128 else index - 256
        real = signed * preactivation_scale
        if activation == "leaky_relu_0p1":
            real = real if real >= 0.0 else real * 0.1
        elif activation != "identity":
            raise RuntimeError(f"unsupported activation {activation}")
        quantized = int(round(real / output.scale)) + output.zero_point
        values[index] = max(output.qmin, min(output.qmax, quantized))
    return bytes(values)


def _forward_calibration_batch(
    model: torch.nn.Module,
    image: torch.Tensor,
    output_observers: dict[str, HistogramObserver],
    pre_observers: dict[str, HistogramObserver],
) -> None:
    m = model.model
    output_observers["input"](image.detach())

    def conv(name: str, module: torch.nn.Module, value: torch.Tensor) -> torch.Tensor:
        pre = module.conv(value)
        out = module.act(pre)
        pre_observers[name](pre.detach())
        output_observers[name](out.detach())
        return out

    x0 = conv("m0", m[0], image)
    p1 = m[1](x0)
    x2 = conv("m2", m[2], p1)
    p3 = m[3](x2)
    x4 = conv("m4", m[4], p3)
    p5 = m[5](x4)
    x6 = conv("m6", m[6], p5)
    p7 = m[7](x6)
    x8 = conv("m8", m[8], p7)
    p9 = m[9](x8)
    x10 = conv("m10", m[10], p9)
    p12 = m[12](m[11](x10))
    x13 = conv("m13", m[13], p12)
    x14 = conv("m14", m[14], x13)
    x15 = conv("m15", m[15], x14)
    x16 = conv("m16", m[16], x14)
    up17 = m[17](x16)
    cat18 = m[18]([up17, x8])
    x19 = conv("m19", m[19], cat18)
    detect = m[20]
    for name, module, value in (
        ("p4_detect", detect.m[0], x19),
        ("p5_detect", detect.m[1], x15),
    ):
        out = module(value)
        pre_observers[name](out.detach())
        output_observers[name](out.detach())


@torch.inference_mode()
def calibrate(
    model: torch.nn.Module,
    images: Iterable[torch.Tensor],
    *,
    device: str | torch.device,
    expected_count: int | None = None,
) -> tuple[dict[str, TensorQParams], dict[str, TensorQParams], int]:
    names = [layer["name"] for layer in load_spec()["conv_layers"]]
    outputs = {name: _activation_observer().to(device) for name in ["input", *names]}
    preacts = {name: _preactivation_observer().to(device) for name in names}
    count = 0
    for image in images:
        if image.ndim == 3:
            image = image.unsqueeze(0)
        if tuple(image.shape[1:]) != (3, 416, 416):
            raise RuntimeError(f"calibration tensor has invalid shape {tuple(image.shape)}")
        _forward_calibration_batch(model, image.to(device, non_blocking=True), outputs, preacts)
        count += int(image.shape[0])
    if count == 0 or (expected_count is not None and count != expected_count):
        raise RuntimeError(f"calibration count {count}, expected {expected_count}")
    return (
        {name: observer_qparams(observer) for name, observer in outputs.items()},
        {name: observer_qparams(observer, signed=True) for name, observer in preacts.items()},
        count,
    )


def _input_quant_name(layer_name: str) -> str:
    return {
        "m0": "input", "m2": "m0", "m4": "m2", "m6": "m4", "m8": "m6",
        "m10": "m8", "m13": "m10", "m14": "m13", "m15": "m14",
        "m16": "m14", "m19": "m16", "p4_detect": "m19", "p5_detect": "m15",
    }[layer_name]


def build_quant_plan(
    model: torch.nn.Module,
    output_qparams: dict[str, TensorQParams],
    preactivation_qparams: dict[str, TensorQParams],
    *,
    frozen_plan: dict[str, Any] | None = None,
) -> tuple[dict[str, Any], dict[str, torch.Tensor], dict[str, bytes]]:
    spec = load_spec()
    modules = conv_modules(model)
    weight_tensors: dict[str, torch.Tensor] = {}
    luts: dict[str, bytes] = {}
    layer_entries = []
    frozen_by_name: dict[str, dict[str, Any]] = {}
    if frozen_plan is not None:
        if frozen_plan.get("format") != "kv260-coco80-rtl-quantization" or frozen_plan.get("version") != 1:
            raise RuntimeError("unsupported frozen quantization plan")
        frozen_layers = frozen_plan.get("layers")
        if not isinstance(frozen_layers, list) or len(frozen_layers) != 13:
            raise RuntimeError("frozen quantization plan must contain 13 layers")
        frozen_by_name = {str(entry["name"]): entry for entry in frozen_layers}
    for layer in spec["conv_layers"]:
        name = layer["name"]
        module = modules[name]
        input_q = output_qparams[_input_quant_name(name)]
        output_q = output_qparams[name]
        pre_q = preactivation_qparams[name]
        if frozen_plan is None:
            weight_q, weight_scale = quantize_weight(module.weight)
        else:
            frozen = frozen_by_name.get(name)
            if frozen is None:
                raise RuntimeError(f"frozen quantization plan is missing {name}")
            quant = frozen.get("quant")
            if not isinstance(quant, dict) or quant.get("weight_zero_point") != 0:
                raise RuntimeError(f"{name}: invalid frozen symmetric weight domain")
            frozen_input = TensorQParams(**quant["input"])
            frozen_output = TensorQParams(**quant["output"])
            if frozen_input != input_q or frozen_output != output_q:
                raise RuntimeError(f"{name}: frozen activation qparams drifted")
            if not math.isclose(float(quant["preactivation_scale"]), pre_q.scale, rel_tol=0.0, abs_tol=1e-15):
                raise RuntimeError(f"{name}: frozen preactivation scale drifted")
            weight_scale = float(quant["weight_scale"])
            weight_q = quantize_weight_fixed(module.weight, weight_scale)
        weight_tensors[name] = weight_q.cpu()
        bias_float = module.bias.detach() if module.bias is not None else torch.zeros(module.out_channels, device=module.weight.device)
        bias_scale = input_q.scale * weight_scale
        bias_i64 = torch.round(bias_float / bias_scale).to(torch.int64)
        if torch.any(bias_i64 > 0x7FFFFFFF) or torch.any(bias_i64 < -0x80000000):
            raise RuntimeError(f"{name}: quantized bias exceeds int32")
        accumulator_abs_bound = int(layer["ifm_hwc"][2]) * int(layer["kernel"]) ** 2 * 128 * 127
        accumulator_abs_bound += int(bias_i64.abs().max().item())
        if accumulator_abs_bound > 0x7FFFFFFF:
            raise RuntimeError(f"{name}: conservative accumulator bound exceeds int32")
        real_scale = bias_scale / pre_q.scale
        multiplier, shift, represented, error = solve_multiplier(real_scale)
        lut = activation_lut(pre_q.scale, output_q, layer["activation"])
        luts[name] = lut
        params = ConvQuantParams(
            name=name,
            input=input_q,
            output=output_q,
            preactivation_scale=pre_q.scale,
            weight_scale=weight_scale,
            weight_zero_point=0,
            multiplier=multiplier,
            shift=shift,
            effective_scale=represented,
            effective_scale_error=error,
            activation=layer["activation"],
            input_center_saturation_possible=(input_q.zero_point > 128),
            bias_min=int(bias_i64.min().item()),
            bias_max=int(bias_i64.max().item()),
            accumulator_abs_bound=accumulator_abs_bound,
        )
        if params.input_center_saturation_possible:
            raise RuntimeError(f"{name}: input zero point can exceed signed-centering range")
        entry = dict(layer)
        entry["quant"] = asdict(params)
        entry["weight_shape_oihw"] = list(weight_q.shape)
        entry["bias_i32"] = [int(x) for x in bias_i64.cpu().tolist()]
        entry["activation_lut_sha256"] = hashlib.sha256(lut).hexdigest()
        layer_entries.append(entry)
    plan = {
        "format": "kv260-coco80-rtl-quantization",
        "version": 1,
        "activation_quant_range": [QMIN_ACTIVATION, QMAX_ACTIVATION],
        "weight_quant_range": [QMIN_WEIGHT, QMAX_WEIGHT],
        "weight_qscheme": "per_tensor_symmetric_s8_zp0",
        "activation_qscheme": "per_tensor_affine_u8_reduced_range",
        "rounding": "add_positive_half_then_arithmetic_right_shift",
        "layers": layer_entries,
    }
    return plan, weight_tensors, luts


def qparams_from_plan(
    plan: dict[str, Any],
) -> tuple[dict[str, TensorQParams], dict[str, TensorQParams]]:
    """Recover the frozen output/preactivation domains from an exported plan."""

    if plan.get("format") != "kv260-coco80-rtl-quantization" or plan.get("version") != 1:
        raise RuntimeError("unsupported quantization plan")
    layers = plan.get("layers")
    if not isinstance(layers, list) or len(layers) != 13:
        raise RuntimeError("quantization plan must contain 13 layers")
    outputs: dict[str, TensorQParams] = {}
    preacts: dict[str, TensorQParams] = {}
    for entry in layers:
        name = str(entry["name"])
        quant = entry["quant"]
        input_q = TensorQParams(**quant["input"])
        output_q = TensorQParams(**quant["output"])
        input_q.validate()
        output_q.validate()
        if name == "m0":
            outputs["input"] = input_q
        outputs[name] = output_q
        preacts[name] = TensorQParams(
            scale=float(quant["preactivation_scale"]),
            zero_point=0,
            qmin=-128,
            qmax=127,
        )
        preacts[name].validate()
    expected_inputs = {
        name: outputs[_input_quant_name(name)] for name in outputs if name != "input"
    }
    for entry in layers:
        name = str(entry["name"])
        if TensorQParams(**entry["quant"]["input"]) != expected_inputs[name]:
            raise RuntimeError(f"{name}: quantization graph input domain is inconsistent")
    return outputs, preacts


def save_quant_checkpoint(
    output_dir: Path,
    plan: dict[str, Any],
    weights: dict[str, torch.Tensor],
    luts: dict[str, bytes],
    *,
    source_weights: Path,
    calibration_manifest: Path,
) -> dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=False)
    source_hash = sha256_file(source_weights)
    calibration_hash = sha256_file(calibration_manifest)
    for layer in plan["layers"]:
        name = layer["name"]
        layer_dir = output_dir / f"{int(layer['infer_index']):02d}_{name}"
        layer_dir.mkdir()
        weight_path = layer_dir / "weight_raw_oihw_s8.bin"
        weight_path.write_bytes(weights[name].contiguous().numpy().tobytes())
        bias_values = torch.tensor(layer["bias_i32"], dtype=torch.int32).numpy().tobytes()
        (layer_dir / "bias_i32.bin").write_bytes(bias_values)
        (layer_dir / "activation_lut_u8.bin").write_bytes(luts[name])
        layer["files"] = {
            "weight_raw_oihw_s8": {"path": weight_path.relative_to(output_dir).as_posix(), "sha256": sha256_file(weight_path), "bytes": weight_path.stat().st_size},
            "bias_i32": {"path": (layer_dir / 'bias_i32.bin').relative_to(output_dir).as_posix(), "sha256": sha256_file(layer_dir / "bias_i32.bin"), "bytes": (layer_dir / "bias_i32.bin").stat().st_size},
            "activation_lut_u8": {"path": (layer_dir / 'activation_lut_u8.bin').relative_to(output_dir).as_posix(), "sha256": sha256_file(layer_dir / "activation_lut_u8.bin"), "bytes": 256},
        }
    plan["provenance"] = {
        "source_weights": str(source_weights.resolve()),
        "source_weights_sha256": source_hash,
        "calibration_manifest": str(calibration_manifest.resolve()),
        "calibration_manifest_sha256": calibration_hash,
    }
    manifest_path = output_dir / "quantization_manifest.json"
    manifest_path.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return plan


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--calibration-manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--device", default="cuda:0" if torch.cuda.is_available() else "cpu")
    parser.add_argument("--dry-run", action="store_true", help="validate model/assets without running calibration")
    args = parser.parse_args()
    model = load_official_model(args.upstream.resolve(), args.weights.resolve(), args.device, fuse=True)
    if args.dry_run:
        print(json.dumps({"device": args.device, "conv_layers": list(conv_modules(model)), "status": "PASS"}, indent=2))
        return
    raise SystemExit(
        "Use tools/coco80/pipeline.py ptq so calibration images use the canonical fixed-416 loader."
    )


if __name__ == "__main__":
    main()

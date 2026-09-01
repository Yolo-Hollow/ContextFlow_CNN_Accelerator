"""Manifest-driven ABI-v2 parameter images for COCO80 YOLOv3-tiny.

Only the existing bias and weight AXI streams are emitted.  Quantization and
activation metadata (including the LUT digest) are bound into the package
manifest so software can program AXI-Lite registers without silently mixing
artifacts from another calibration/export.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
from pathlib import Path
from typing import Any, Iterable, Mapping

try:  # Support both ``python -m`` and direct script execution.
    from .hardware_plan import (
        BIAS_PACKET_BYTES,
        COUT_TILE,
        EXPECTED_BIAS_PACKAGE_BYTES,
        EXPECTED_LAYER_COUNT,
        EXPECTED_WEIGHT_PACKAGE_BYTES,
        PARAMETER_ALIGNMENT,
        ROWS,
        WEIGHT_PACKET_BYTES,
        COCO80_HARDWARE_PLAN,
        HardwarePlan,
        LayerSchedule,
    )
except ImportError:  # pragma: no cover - exercised by direct CLI use
    from hardware_plan import (  # type: ignore
        BIAS_PACKET_BYTES,
        COUT_TILE,
        EXPECTED_BIAS_PACKAGE_BYTES,
        EXPECTED_LAYER_COUNT,
        EXPECTED_WEIGHT_PACKAGE_BYTES,
        PARAMETER_ALIGNMENT,
        ROWS,
        WEIGHT_PACKET_BYTES,
        COCO80_HARDWARE_PLAN,
        HardwarePlan,
        LayerSchedule,
    )


LAYER_MANIFEST_MAGIC = "coco80-yolov3-tiny-rtl-layer-fixture"
LAYER_MANIFEST_VERSION = 1
PARAMETER_PACKAGE_MAGIC = "kv260-coco80-yolov3-tiny-abi-v2-parameters"
PARAMETER_PACKAGE_VERSION = 1

BIAS_IMAGE_NAME = "coco80_bias_cout32.bin"
WEIGHT_IMAGE_NAME = "coco80_weight_cout32.bin"
PACKAGE_MANIFEST_NAME = "coco80_parameter_manifest.json"
QUANTIZATION_MANIFEST_NAME = "quantization_manifest.json"
QUANTIZATION_MANIFEST_FORMAT = "kv260-coco80-rtl-quantization"
QUANTIZATION_MANIFEST_VERSION = 1


class PackageValidationError(ValueError):
    """A source fixture or generated package violates its bound contract."""


POOL_MODES: Mapping[str, str] = {
    schedule.layer.layer_id: (
        "fused_maxpool2x2s2" if schedule.layer.pool_stride else "bypass"
    )
    for schedule in COCO80_HARDWARE_PLAN.layers
}

ROUTE_SEMANTICS: Mapping[str, str] = {
    "m0": "pl_fused_maxpool2x2s2_to_pool1",
    "m2": "pl_fused_maxpool2x2s2_to_pool3",
    "m4": "pl_fused_maxpool2x2s2_to_pool5",
    "m6": "pl_fused_maxpool2x2s2_to_pool7",
    "m8": "preserve_m8_route_then_ps_maxpool2x2s2_to_pool9",
    "m10": "ps_pad_right_bottom_output_zp_then_maxpool2x2s1_to_pool12",
    "m13": "linear",
    "m14": "fork_to_m15_and_m16",
    "m15": "p5_detect_source",
    "m16": "nearest_upsample2x_then_requant_concat_m8",
    "m19": "requantized_concat_to_p4_detect_source",
    "p4_detect": "detect_head_p4_stride16",
    "p5_detect": "detect_head_p5_stride32",
}


def sha256_bytes(data: bytes | bytearray | memoryview) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path, chunk_bytes: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(chunk_bytes)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_sha256(value: object) -> str:
    return sha256_bytes(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    )


def align_up(value: int, alignment: int = PARAMETER_ALIGNMENT) -> int:
    if isinstance(value, bool) or isinstance(alignment, bool):
        raise PackageValidationError("boolean size/alignment is invalid")
    if value < 0 or alignment <= 0 or alignment & (alignment - 1):
        raise PackageValidationError("alignment must be a positive power of two")
    return (value + alignment - 1) // alignment * alignment


def _dict(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PackageValidationError(f"{label} must be an object")
    return value


def _integer(
    value: object, label: str, minimum: int, maximum: int | None = None
) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise PackageValidationError(f"{label} must be an integer")
    if value < minimum or (maximum is not None and value > maximum):
        suffix = f"..{maximum}" if maximum is not None else " or greater"
        raise PackageValidationError(f"{label} must be {minimum}{suffix}")
    return value


def _positive_float(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PackageValidationError(f"{label} must be numeric")
    result = float(value)
    if not math.isfinite(result) or result <= 0.0:
        raise PackageValidationError(f"{label} must be finite and positive")
    return result


def _sha256(value: object, label: str) -> str:
    if not isinstance(value, str) or len(value) != 64:
        raise PackageValidationError(f"{label} must be a SHA256 hex digest")
    try:
        int(value, 16)
    except ValueError as error:
        raise PackageValidationError(f"{label} must be hexadecimal") from error
    return value.lower()


def _string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise PackageValidationError(f"{label} must be a non-empty string")
    return value


def _shape(value: object, label: str) -> list[int]:
    if not isinstance(value, list) or len(value) != 3:
        raise PackageValidationError(f"{label} must be a three-element HWC list")
    return [_integer(item, f"{label}[{index}]", 1) for index, item in enumerate(value)]


def _file_entry(
    manifest_dir: Path,
    raw: object,
    label: str,
    expected_bytes: int,
) -> tuple[Path, dict[str, object]]:
    entry = _dict(raw, label)
    relative = _string(entry.get("path"), f"{label}.path")
    path = (manifest_dir / relative).resolve()
    try:
        path.relative_to(manifest_dir.resolve())
    except ValueError as error:
        raise PackageValidationError(f"{label}.path escapes its fixture directory") from error
    declared_bytes = _integer(entry.get("bytes"), f"{label}.bytes", 0)
    declared_sha = _sha256(entry.get("sha256"), f"{label}.sha256")
    if declared_bytes != expected_bytes:
        raise PackageValidationError(
            f"{label} declares {declared_bytes} bytes, expected {expected_bytes}"
        )
    if not path.is_file():
        raise PackageValidationError(f"{label} file is missing: {relative}")
    actual_bytes = path.stat().st_size
    if actual_bytes != expected_bytes:
        raise PackageValidationError(
            f"{label} has {actual_bytes} bytes, expected {expected_bytes}"
        )
    actual_sha = sha256_file(path)
    if actual_sha != declared_sha:
        raise PackageValidationError(f"{label} SHA256 mismatch")
    return path, {
        "path": relative.replace("\\", "/"),
        "bytes": actual_bytes,
        "sha256": actual_sha,
    }


def _validate_quant(
    raw: object, label: str
) -> dict[str, object]:
    quant = _dict(raw, label)
    if quant.get("weight_dtype") != "int8":
        raise PackageValidationError(f"{label}.weight_dtype must be int8")
    if quant.get("weight_granularity") != "per_tensor":
        raise PackageValidationError(
            f"{label}.weight_granularity must be per_tensor for one layer-long dispatch"
        )
    weight_zero_point = _integer(
        quant.get("weight_zero_point"), f"{label}.weight_zero_point", -128, 127
    )
    if weight_zero_point != 0:
        raise PackageValidationError(
            f"{label}.weight_zero_point must be zero for signed r5 weights"
        )
    normalized = {
        "input_scale": _positive_float(quant.get("input_scale"), f"{label}.input_scale"),
        "input_zero_point": _integer(
            quant.get("input_zero_point"), f"{label}.input_zero_point", 0, 255
        ),
        "output_scale": _positive_float(quant.get("output_scale"), f"{label}.output_scale"),
        "output_zero_point": _integer(
            quant.get("output_zero_point"), f"{label}.output_zero_point", 0, 255
        ),
        "weight_scale": _positive_float(quant.get("weight_scale"), f"{label}.weight_scale"),
        "weight_zero_point": weight_zero_point,
        "weight_dtype": "int8",
        "weight_granularity": "per_tensor",
        "rtl_mult": _integer(quant.get("rtl_mult"), f"{label}.rtl_mult", 1, 65535),
        "rtl_shift": _integer(quant.get("rtl_shift"), f"{label}.rtl_shift", 0, 15),
        "rtl_multiplier_fractional_bits": 15,
        "rtl_rounding": "add_positive_half_then_arithmetic_shift",
    }
    has_preactivation = "preactivation_scale" in quant
    has_rtl_output_zp = "rtl_output_zero_point" in quant
    if has_preactivation != has_rtl_output_zp:
        raise PackageValidationError(
            f"{label}: preactivation_scale and rtl_output_zero_point must coexist"
        )
    if has_preactivation:
        normalized["preactivation_scale"] = _positive_float(
            quant.get("preactivation_scale"), f"{label}.preactivation_scale"
        )
        normalized["rtl_output_zero_point"] = _integer(
            quant.get("rtl_output_zero_point"),
            f"{label}.rtl_output_zero_point",
            0,
            255,
        )
    return normalized


def _validate_provenance(raw: object, label: str) -> dict[str, str]:
    provenance = _dict(raw, label)
    return {
        "checkpoint_sha256": _sha256(
            provenance.get("checkpoint_sha256"), f"{label}.checkpoint_sha256"
        ),
        "calibration_sha256": _sha256(
            provenance.get("calibration_sha256"), f"{label}.calibration_sha256"
        ),
        "export_sha256": _sha256(
            provenance.get("export_sha256"), f"{label}.export_sha256"
        ),
    }


def _validate_layer_manifest(
    path: Path, raw: object, schedule: LayerSchedule
) -> dict[str, object]:
    data = _dict(raw, str(path))
    layer = schedule.layer
    if data.get("magic") != LAYER_MANIFEST_MAGIC:
        raise PackageValidationError(f"{path}: wrong layer manifest magic")
    if data.get("version") != LAYER_MANIFEST_VERSION:
        raise PackageValidationError(f"{path}: unsupported layer manifest version")
    layer_id = _string(data.get("layer_id"), f"{path}.layer_id")
    if layer_id != layer.layer_id:
        raise PackageValidationError(f"{path}: layer_id disagrees with hardware plan")

    shape = _dict(data.get("shape"), f"{path}.shape")
    expected_shapes = {
        "ifm_hwc": [layer.fm_h, layer.fm_w, layer.cin],
        "conv_ofm_hwc": [schedule.conv_h, schedule.conv_w, layer.cout],
        "final_ofm_hwc": [schedule.output_h, schedule.output_w, layer.cout],
    }
    for field, expected in expected_shapes.items():
        if _shape(shape.get(field), f"{path}.shape.{field}") != expected:
            raise PackageValidationError(f"{path}: shape.{field} changed")
    conv = _dict(data.get("conv"), f"{path}.conv")
    for field, expected in {
        "kernel": layer.kernel, "stride": layer.stride, "pad": layer.pad
    }.items():
        if _integer(conv.get(field), f"{path}.conv.{field}", 0) != expected:
            raise PackageValidationError(f"{path}: convolution {field} changed")
    expected_graph = {
        "input_tensor": layer.input_tensor,
        "output_tensor": layer.output_tensor,
        "pool_mode": POOL_MODES[layer_id],
        "route_semantics": ROUTE_SEMANTICS[layer_id],
    }
    graph = _dict(data.get("graph"), f"{path}.graph")
    if graph != expected_graph:
        raise PackageValidationError(f"{path}: graph semantics changed")

    quant = _validate_quant(data.get("quant"), f"{path}.quant")
    provenance = _validate_provenance(data.get("provenance"), f"{path}.provenance")
    files = _dict(data.get("files"), f"{path}.files")
    bias_path, bias_source = _file_entry(
        path.parent, files.get("bias_i32"), f"{path}.files.bias_i32", layer.cout * 4
    )
    weight_path, weight_source = _file_entry(
        path.parent,
        files.get("weight_raw_oihw_s8"),
        f"{path}.files.weight_raw_oihw_s8",
        layer.cout * layer.cin * layer.kernel * layer.kernel,
    )
    activation = _dict(data.get("activation"), f"{path}.activation")
    if activation.get("mode") != "lut256":
        raise PackageValidationError(f"{path}: activation.mode must be lut256")
    function = "identity" if layer.detect_index is not None else "leaky_relu_0p1"
    if "function" in activation and activation.get("function") != function:
        raise PackageValidationError(f"{path}: activation.function changed")
    if "lut_u8" in files:
        _, lut_source = _file_entry(
            path.parent, files.get("lut_u8"), f"{path}.files.lut_u8", 256
        )
        declared = activation.get("lut_sha256")
        if declared is not None and _sha256(
            declared, f"{path}.activation.lut_sha256"
        ) != lut_source["sha256"]:
            raise PackageValidationError(f"{path}: activation LUT digest mismatch")
    else:
        lut_source = {
            "path": None,
            "bytes": 256,
            "sha256": _sha256(
                activation.get("lut_sha256"), f"{path}.activation.lut_sha256"
            ),
        }
    return {
        "path": path,
        "manifest_sha256": sha256_file(path),
        "bias_path": bias_path,
        "weight_path": weight_path,
        "source_files": {
            "bias_i32": bias_source,
            "weight_raw_oihw_s8": weight_source,
            "lut_u8": lut_source,
        },
        "quant": quant,
        "activation": {
            "mode": "lut256",
            "function": function,
            "lut_sha256": lut_source["sha256"],
            "lut_programming": "AXI-Lite before layer start; not in DMA package",
        },
        "graph": expected_graph,
        "provenance": provenance,
    }


def _canonical_qparams(raw: object, label: str) -> dict[str, object]:
    qparams = _dict(raw, label)
    if qparams.get("qmin") != 0 or qparams.get("qmax") != 127:
        raise PackageValidationError(f"{label}: canonical range must be [0,127]")
    return {
        "scale": _positive_float(qparams.get("scale"), f"{label}.scale"),
        "zero_point": _integer(
            qparams.get("zero_point"), f"{label}.zero_point", 0, 127
        ),
    }


def _canonical_bias_values(raw: object, schedule: LayerSchedule, label: str) -> list[int]:
    if not isinstance(raw, list) or len(raw) != schedule.layer.cout:
        raise PackageValidationError(
            f"{label} must contain exactly {schedule.layer.cout} int32 values"
        )
    return [
        _integer(value, f"{label}[{index}]", -0x80000000, 0x7FFFFFFF)
        for index, value in enumerate(raw)
    ]


def _validate_canonical_quant_layer(
    root: Path,
    manifest_path: Path,
    raw: object,
    schedule: LayerSchedule,
    index: int,
    provenance: dict[str, str],
    manifest_sha256: str,
) -> dict[str, object]:
    label = f"{manifest_path}.layers[{index}]"
    data = _dict(raw, label)
    layer = schedule.layer
    if data.get("infer_index") != index or data.get("name") != layer.layer_id:
        raise PackageValidationError(f"{label}: canonical identity/order changed")
    if data.get("model_index") != layer.model_index:
        raise PackageValidationError(f"{label}.model_index changed")
    if layer.detect_index is None:
        if "detect_head" in data:
            raise PackageValidationError(f"{label}.detect_head must be absent")
    elif data.get("detect_head") != layer.detect_index:
        raise PackageValidationError(f"{label}.detect_head changed")
    function = "identity" if layer.detect_index is not None else "leaky_relu_0p1"
    expected_fields: dict[str, object] = {
        "source": layer.input_tensor,
        "ifm_hwc": [layer.fm_h, layer.fm_w, layer.cin],
        "ofm_hwc": [schedule.conv_h, schedule.conv_w, layer.cout],
        "kernel": layer.kernel,
        "stride": layer.stride,
        "pad": layer.pad,
        "tile_h": layer.tile_h,
        "activation": function,
        "weight_shape_oihw": [layer.cout, layer.cin, layer.kernel, layer.kernel],
    }
    for field, expected in expected_fields.items():
        if data.get(field) != expected:
            raise PackageValidationError(f"{label}.{field} changed")

    quant_raw = _dict(data.get("quant"), f"{label}.quant")
    if quant_raw.get("name") != layer.layer_id:
        raise PackageValidationError(f"{label}.quant.name changed")
    input_q = _canonical_qparams(quant_raw.get("input"), f"{label}.quant.input")
    output_q = _canonical_qparams(quant_raw.get("output"), f"{label}.quant.output")
    if quant_raw.get("input_center_saturation_possible") is not False:
        raise PackageValidationError(f"{label}: unsafe IFM centering declaration")
    preactivation_scale = _positive_float(
        quant_raw.get("preactivation_scale"), f"{label}.quant.preactivation_scale"
    )
    weight_scale = _positive_float(
        quant_raw.get("weight_scale"), f"{label}.quant.weight_scale"
    )
    if quant_raw.get("weight_zero_point") != 0:
        raise PackageValidationError(f"{label}.quant.weight_zero_point must be zero")
    multiplier = _integer(
        quant_raw.get("multiplier"), f"{label}.quant.multiplier", 1, 65535
    )
    shift = _integer(quant_raw.get("shift"), f"{label}.quant.shift", 0, 15)
    represented = _positive_float(
        quant_raw.get("effective_scale"), f"{label}.quant.effective_scale"
    )
    expected_represented = multiplier / float(1 << (15 + shift))
    if not math.isclose(represented, expected_represented, rel_tol=0.0, abs_tol=1e-15):
        raise PackageValidationError(f"{label}.quant.effective_scale changed")
    requested = float(input_q["scale"]) * weight_scale / preactivation_scale
    declared_error = quant_raw.get("effective_scale_error")
    if isinstance(declared_error, bool) or not isinstance(declared_error, (int, float)):
        raise PackageValidationError(f"{label}.quant.effective_scale_error must be numeric")
    error = float(declared_error)
    if not math.isfinite(error) or error < 0.0 or not math.isclose(
        error, abs(represented - requested), rel_tol=0.0, abs_tol=1e-15
    ):
        raise PackageValidationError(f"{label}.quant.effective_scale_error changed")
    if quant_raw.get("activation") != function:
        raise PackageValidationError(f"{label}.quant.activation changed")

    bias_values = _canonical_bias_values(data.get("bias_i32"), schedule, f"{label}.bias_i32")
    bias_min = _integer(
        quant_raw.get("bias_min"), f"{label}.quant.bias_min", -0x80000000, 0x7FFFFFFF
    )
    bias_max = _integer(
        quant_raw.get("bias_max"), f"{label}.quant.bias_max", -0x80000000, 0x7FFFFFFF
    )
    if bias_min != min(bias_values) or bias_max != max(bias_values):
        raise PackageValidationError(f"{label}: bias min/max metadata changed")
    expected_bound = (
        layer.cin * layer.kernel * layer.kernel * 128 * 127
        + max(abs(bias_min), abs(bias_max))
    )
    if quant_raw.get("accumulator_abs_bound") != expected_bound:
        raise PackageValidationError(f"{label}: accumulator bound metadata changed")

    files = _dict(data.get("files"), f"{label}.files")
    bias_path, bias_source = _file_entry(
        root, files.get("bias_i32"), f"{label}.files.bias_i32", layer.cout * 4
    )
    weight_path, weight_source = _file_entry(
        root,
        files.get("weight_raw_oihw_s8"),
        f"{label}.files.weight_raw_oihw_s8",
        layer.cout * layer.cin * layer.kernel * layer.kernel,
    )
    _, lut_source = _file_entry(
        root, files.get("activation_lut_u8"), f"{label}.files.activation_lut_u8", 256
    )
    expected_bias = b"".join(struct.pack("<i", value) for value in bias_values)
    if bias_path.read_bytes() != expected_bias:
        raise PackageValidationError(f"{label}: bias_i32 list/file mismatch")
    if _sha256(
        data.get("activation_lut_sha256"), f"{label}.activation_lut_sha256"
    ) != lut_source["sha256"]:
        raise PackageValidationError(f"{label}: activation LUT digest mismatch")

    return {
        "path": manifest_path,
        "manifest_sha256": manifest_sha256,
        "bias_path": bias_path,
        "weight_path": weight_path,
        "source_files": {
            "bias_i32": bias_source,
            "weight_raw_oihw_s8": weight_source,
            "lut_u8": lut_source,
        },
        "quant": {
            "input_scale": input_q["scale"],
            "input_zero_point": input_q["zero_point"],
            "output_scale": output_q["scale"],
            "output_zero_point": output_q["zero_point"],
            "weight_scale": weight_scale,
            "weight_zero_point": 0,
            "weight_dtype": "int8",
            "weight_granularity": "per_tensor",
            "rtl_mult": multiplier,
            "rtl_shift": shift,
            "rtl_multiplier_fractional_bits": 15,
            "rtl_rounding": "add_positive_half_then_arithmetic_shift",
            "preactivation_scale": preactivation_scale,
            "rtl_output_zero_point": 0,
        },
        "activation": {
            "mode": "lut256",
            "function": function,
            "lut_sha256": lut_source["sha256"],
            "lut_programming": "AXI-Lite before layer start; not in DMA package",
        },
        "graph": {
            "input_tensor": layer.input_tensor,
            "output_tensor": layer.output_tensor,
            "pool_mode": POOL_MODES[layer.layer_id],
            "route_semantics": ROUTE_SEMANTICS[layer.layer_id],
        },
        "provenance": provenance,
    }


def _load_canonical_quantization_manifest(
    path: Path, plan: HardwarePlan
) -> list[dict[str, object]]:
    try:
        data = _dict(json.loads(path.read_text(encoding="utf-8")), str(path))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PackageValidationError(f"cannot read quantization manifest {path}") from error
    for field, expected in {
        "format": QUANTIZATION_MANIFEST_FORMAT,
        "version": QUANTIZATION_MANIFEST_VERSION,
        "activation_quant_range": [0, 127],
        "weight_quant_range": [-127, 127],
        "weight_qscheme": "per_tensor_symmetric_s8_zp0",
        "activation_qscheme": "per_tensor_affine_u8_reduced_range",
        "rounding": "add_positive_half_then_arithmetic_right_shift",
    }.items():
        if data.get(field) != expected:
            raise PackageValidationError(f"{path}.{field} changed")
    layers = data.get("layers")
    if not isinstance(layers, list) or len(layers) != EXPECTED_LAYER_COUNT:
        raise PackageValidationError(f"{path}: canonical manifest must contain 13 layers")
    source_provenance = _dict(data.get("provenance"), f"{path}.provenance")
    _string(source_provenance.get("source_weights"), f"{path}.provenance.source_weights")
    _string(
        source_provenance.get("calibration_manifest"),
        f"{path}.provenance.calibration_manifest",
    )
    manifest_sha256 = sha256_file(path)
    provenance = {
        "checkpoint_sha256": _sha256(
            source_provenance.get("source_weights_sha256"),
            f"{path}.provenance.source_weights_sha256",
        ),
        "calibration_sha256": _sha256(
            source_provenance.get("calibration_manifest_sha256"),
            f"{path}.provenance.calibration_manifest_sha256",
        ),
        "export_sha256": manifest_sha256,
    }
    return [
        _validate_canonical_quant_layer(
            path.parent, path, raw, schedule, index, provenance, manifest_sha256
        )
        for index, (raw, schedule) in enumerate(zip(layers, plan.layers))
    ]


def load_layer_manifests(
    model_root: Path, plan: HardwarePlan = COCO80_HARDWARE_PLAN
) -> list[dict[str, object]]:
    root = model_root.resolve()
    if not root.is_dir():
        raise PackageValidationError(f"model root is not a directory: {root}")
    canonical_path = root / QUANTIZATION_MANIFEST_NAME
    if canonical_path.exists():
        layer_local_paths = sorted(root.rglob("manifest.json"))
        if layer_local_paths:
            raise PackageValidationError(
                "ambiguous parameter source: canonical and layer-local manifests coexist"
            )
        if not canonical_path.is_file():
            raise PackageValidationError("quantization_manifest.json is not a file")
        return _load_canonical_quantization_manifest(canonical_path, plan)
    paths = sorted(root.rglob("manifest.json"))
    if len(paths) != EXPECTED_LAYER_COUNT:
        raise PackageValidationError(
            f"expected exactly {EXPECTED_LAYER_COUNT} layer manifests, found {len(paths)}"
        )
    raw_by_id: dict[str, tuple[Path, object]] = {}
    for path in paths:
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise PackageValidationError(f"cannot read layer manifest {path}") from error
        data = _dict(raw, str(path))
        layer_id = _string(data.get("layer_id"), f"{path}.layer_id")
        if layer_id in raw_by_id:
            raise PackageValidationError(f"duplicate layer manifest for {layer_id}")
        raw_by_id[layer_id] = (path, raw)

    expected = [item.layer.layer_id for item in plan.layers]
    if set(raw_by_id) != set(expected):
        missing = sorted(set(expected) - set(raw_by_id))
        extra = sorted(set(raw_by_id) - set(expected))
        raise PackageValidationError(
            f"layer manifest set mismatch: missing={missing}, extra={extra}"
        )
    return [
        _validate_layer_manifest(raw_by_id[layer_id][0], raw_by_id[layer_id][1], schedule)
        for layer_id, schedule in zip(expected, plan.layers)
    ]


def build_bias_tile(raw_bias: bytes, schedule: LayerSchedule) -> bytes:
    expected = schedule.layer.cout * 4
    if len(raw_bias) != expected:
        raise PackageValidationError("raw bias byte count changed after validation")
    output = bytearray(schedule.cout_blocks * BIAS_PACKET_BYTES)
    for block in range(schedule.cout_blocks):
        for lane in range(COUT_TILE):
            channel = block * COUT_TILE + lane
            if channel < schedule.layer.cout:
                source = channel * 4
                target = (block * COUT_TILE + lane) * 4
                output[target : target + 4] = raw_bias[source : source + 4]
    return bytes(output)


def build_weight_tile(raw_oihw: bytes, schedule: LayerSchedule) -> bytes:
    layer = schedule.layer
    kernel_area = layer.kernel * layer.kernel
    expected = layer.cout * layer.cin * kernel_area
    if len(raw_oihw) != expected:
        raise PackageValidationError("raw weight byte count changed after validation")
    output = bytearray(
        schedule.cout_blocks * schedule.k_passes * WEIGHT_PACKET_BYTES
    )
    target = 0
    for block in range(schedule.cout_blocks):
        cout_base = block * COUT_TILE
        for k_pass in range(schedule.k_passes):
            k_base = k_pass * ROWS
            for row in range(ROWS):
                global_k = k_base + row
                if global_k < schedule.k_total:
                    channel_in = global_k // kernel_area
                    kernel_index = global_k % kernel_area
                    for lane in range(COUT_TILE):
                        channel_out = cout_base + lane
                        if channel_out < layer.cout:
                            source = (
                                (channel_out * layer.cin + channel_in) * kernel_area
                                + kernel_index
                            )
                            output[target + lane] = raw_oihw[source]
                target += COUT_TILE
    if target != len(output):
        raise PackageValidationError("internal weight pack cursor mismatch")
    return bytes(output)


def _add_section(package: bytearray, payload: bytes) -> int:
    offset = align_up(len(package))
    package.extend(bytes(offset - len(package)))
    package.extend(payload)
    return offset


def _read_bound_file(path: object) -> bytes:
    if not isinstance(path, Path):
        raise PackageValidationError("validated source path was lost")
    try:
        return path.read_bytes()
    except OSError as error:
        raise PackageValidationError(f"cannot reread bound source file: {path}") from error


def generate_package(
    model_root: Path,
    output_dir: Path,
    plan: HardwarePlan = COCO80_HARDWARE_PLAN,
) -> dict[str, object]:
    """Build two aligned images and their hash-bound JSON manifest."""

    if plan.magic != COCO80_HARDWARE_PLAN.magic or plan.version != COCO80_HARDWARE_PLAN.version:
        raise PackageValidationError("unsupported hardware plan identity")
    if plan.sha256() != COCO80_HARDWARE_PLAN.sha256():
        raise PackageValidationError("hardware plan differs from the COCO80 release contract")
    sources = load_layer_manifests(model_root, plan)
    bias_image = bytearray()
    weight_image = bytearray()
    layer_entries: list[dict[str, object]] = []

    for schedule, source in zip(plan.layers, sources):
        bias_tile = build_bias_tile(_read_bound_file(source["bias_path"]), schedule)
        weight_tile = build_weight_tile(_read_bound_file(source["weight_path"]), schedule)
        bias_payload = bias_tile * schedule.tile_count
        weight_payload = weight_tile * schedule.tile_count
        if len(bias_payload) != schedule.bias_bytes:
            raise PackageValidationError(f"{schedule.layer.layer_id}: bias stream size mismatch")
        if len(weight_payload) != schedule.weight_bytes:
            raise PackageValidationError(f"{schedule.layer.layer_id}: weight stream size mismatch")
        bias_offset = _add_section(bias_image, bias_payload)
        weight_offset = _add_section(weight_image, weight_payload)
        layer_entries.append(
            {
                "index": len(layer_entries),
                "layer_id": schedule.layer.layer_id,
                "model_index": schedule.layer.model_index,
                "detect_index": schedule.layer.detect_index,
                "source_manifest_sha256": source["manifest_sha256"],
                "source_files": source["source_files"],
                "provenance": source["provenance"],
                "graph": source["graph"],
                "quant": source["quant"],
                "activation": source["activation"],
                "schedule": {
                    "tile_h": schedule.layer.tile_h,
                    "tile_count": schedule.tile_count,
                    "k_total": schedule.k_total,
                    "k_passes": schedule.k_passes,
                    "cout_total": schedule.layer.cout,
                    "cout_blocks": schedule.cout_blocks,
                    "cout_tail_channels": schedule.cout_tail_channels,
                    "expected_contexts": schedule.expected_contexts,
                    "ifm_bytes": schedule.ifm_bytes,
                    "ofm_bytes": schedule.ofm_bytes,
                },
                "bias": {
                    "offset": bias_offset,
                    "bytes": len(bias_payload),
                    "packets": schedule.bias_packets,
                    "sha256": sha256_bytes(bias_payload),
                },
                "weight": {
                    "offset": weight_offset,
                    "bytes": len(weight_payload),
                    "packets": schedule.weight_packets,
                    "sha256": sha256_bytes(weight_payload),
                },
            }
        )

    if len(bias_image) != EXPECTED_BIAS_PACKAGE_BYTES:
        raise PackageValidationError(
            f"bias image is {len(bias_image)} bytes, expected {EXPECTED_BIAS_PACKAGE_BYTES}"
        )
    if len(weight_image) != EXPECTED_WEIGHT_PACKAGE_BYTES:
        raise PackageValidationError(
            f"weight image is {len(weight_image)} bytes, expected {EXPECTED_WEIGHT_PACKAGE_BYTES}"
        )
    if len(bias_image) > plan.limits.bias_window_bytes:
        raise PackageValidationError("bias image exceeds the configured DDR window")
    if len(weight_image) > plan.limits.weight_window_bytes:
        raise PackageValidationError("weight image exceeds the configured DDR window")

    output = output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    bias_path = output / BIAS_IMAGE_NAME
    weight_path = output / WEIGHT_IMAGE_NAME
    bias_path.write_bytes(bias_image)
    weight_path.write_bytes(weight_image)
    plan_manifest = plan.to_manifest()
    manifest: dict[str, object] = {
        "magic": PARAMETER_PACKAGE_MAGIC,
        "version": PARAMETER_PACKAGE_VERSION,
        "alignment_bytes": PARAMETER_ALIGNMENT,
        "array": {"rows": ROWS, "cols": 16, "cout_tile": COUT_TILE},
        "packet_bytes": {"bias": BIAS_PACKET_BYTES, "weight": WEIGHT_PACKET_BYTES},
        "hardware_plan": {
            "magic": plan.magic,
            "version": plan.version,
            "sha256": _canonical_sha256(plan_manifest),
        },
        "files": {
            "bias": {
                "path": BIAS_IMAGE_NAME,
                "payload_bytes": sum(int(item["bias"]["bytes"]) for item in layer_entries),  # type: ignore[index]
                "file_bytes": len(bias_image),
                "window_bytes": plan.limits.bias_window_bytes,
                "sha256": sha256_bytes(bias_image),
            },
            "weight": {
                "path": WEIGHT_IMAGE_NAME,
                "payload_bytes": sum(int(item["weight"]["bytes"]) for item in layer_entries),  # type: ignore[index]
                "file_bytes": len(weight_image),
                "window_bytes": plan.limits.weight_window_bytes,
                "sha256": sha256_bytes(weight_image),
            },
        },
        "provenance": {
            "checkpoint_sha256": sorted(
                {str(item["provenance"]["checkpoint_sha256"]) for item in layer_entries}  # type: ignore[index]
            ),
            "calibration_sha256": sorted(
                {str(item["provenance"]["calibration_sha256"]) for item in layer_entries}  # type: ignore[index]
            ),
            "export_sha256": sorted(
                {str(item["provenance"]["export_sha256"]) for item in layer_entries}  # type: ignore[index]
            ),
        },
        "layers": layer_entries,
    }
    manifest_path = output / PACKAGE_MANIFEST_NAME
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    verify_package(manifest_path, plan)
    return manifest


def _section_bytes(image: bytes, entry: Mapping[str, object], label: str) -> bytes:
    offset = _integer(entry.get("offset"), f"{label}.offset", 0)
    size = _integer(entry.get("bytes"), f"{label}.bytes", 1)
    if offset % PARAMETER_ALIGNMENT:
        raise PackageValidationError(f"{label} is not {PARAMETER_ALIGNMENT}-byte aligned")
    end = offset + size
    if end > len(image):
        raise PackageValidationError(f"{label} exceeds its image")
    return image[offset:end]


def _verify_padding(
    bias: bytes, weight: bytes, entry: Mapping[str, object], schedule: LayerSchedule
) -> None:
    bias_entry = _dict(entry.get("bias"), "layer.bias")
    weight_entry = _dict(entry.get("weight"), "layer.weight")
    bias_section = _section_bytes(bias, bias_entry, f"{schedule.layer.layer_id}.bias")
    weight_section = _section_bytes(weight, weight_entry, f"{schedule.layer.layer_id}.weight")
    bias_tile_bytes = schedule.cout_blocks * BIAS_PACKET_BYTES
    weight_block_bytes = schedule.k_passes * WEIGHT_PACKET_BYTES
    weight_tile_bytes = schedule.cout_blocks * weight_block_bytes
    if len(bias_section) != bias_tile_bytes * schedule.tile_count:
        raise PackageValidationError(f"{schedule.layer.layer_id}: repeated bias size changed")
    if len(weight_section) != weight_tile_bytes * schedule.tile_count:
        raise PackageValidationError(f"{schedule.layer.layer_id}: repeated weight size changed")
    for tile in range(schedule.tile_count):
        bias_tile = tile * bias_tile_bytes
        weight_tile = tile * weight_tile_bytes
        for block in range(schedule.cout_blocks):
            valid_channels = min(COUT_TILE, schedule.layer.cout - block * COUT_TILE)
            bias_tail = bias_tile + block * BIAS_PACKET_BYTES + valid_channels * 4
            bias_end = bias_tile + (block + 1) * BIAS_PACKET_BYTES
            if any(bias_section[bias_tail:bias_end]):
                raise PackageValidationError(f"{schedule.layer.layer_id}: nonzero bias tail padding")
            for k_pass in range(schedule.k_passes):
                packet = weight_tile + block * weight_block_bytes + k_pass * WEIGHT_PACKET_BYTES
                valid_rows = min(ROWS, schedule.k_total - k_pass * ROWS)
                for row in range(ROWS):
                    row_start = packet + row * COUT_TILE
                    if row >= valid_rows:
                        if any(weight_section[row_start : row_start + COUT_TILE]):
                            raise PackageValidationError(
                                f"{schedule.layer.layer_id}: nonzero K-tail padding"
                            )
                    elif valid_channels < COUT_TILE and any(
                        weight_section[row_start + valid_channels : row_start + COUT_TILE]
                    ):
                        raise PackageValidationError(
                            f"{schedule.layer.layer_id}: nonzero Cout-tail padding"
                        )


def verify_package(
    manifest_path: Path, plan: HardwarePlan = COCO80_HARDWARE_PLAN
) -> dict[str, object]:
    """Re-hash every file/section and reject any ABI or capacity drift."""

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PackageValidationError(f"cannot read package manifest {manifest_path}") from error
    root = manifest_path.resolve().parent
    data = _dict(manifest, str(manifest_path))
    if data.get("magic") != PARAMETER_PACKAGE_MAGIC:
        raise PackageValidationError("wrong parameter package magic")
    if data.get("version") != PARAMETER_PACKAGE_VERSION:
        raise PackageValidationError("unsupported parameter package version")
    if data.get("alignment_bytes") != PARAMETER_ALIGNMENT:
        raise PackageValidationError("parameter alignment contract changed")
    if data.get("array") != {"rows": ROWS, "cols": 16, "cout_tile": COUT_TILE}:
        raise PackageValidationError("systolic array contract changed")
    if data.get("packet_bytes") != {
        "bias": BIAS_PACKET_BYTES,
        "weight": WEIGHT_PACKET_BYTES,
    }:
        raise PackageValidationError("ABI-v2 packet size contract changed")
    hardware_plan = _dict(data.get("hardware_plan"), "hardware_plan")
    if hardware_plan.get("magic") != plan.magic or hardware_plan.get("version") != plan.version:
        raise PackageValidationError("package is bound to a different hardware plan")
    if _sha256(hardware_plan.get("sha256"), "hardware_plan.sha256") != plan.sha256():
        raise PackageValidationError("hardware plan SHA256 mismatch")

    files = _dict(data.get("files"), "files")
    images: dict[str, bytes] = {}
    expected_totals = {
        "bias": EXPECTED_BIAS_PACKAGE_BYTES,
        "weight": EXPECTED_WEIGHT_PACKAGE_BYTES,
    }
    expected_paths = {"bias": BIAS_IMAGE_NAME, "weight": WEIGHT_IMAGE_NAME}
    expected_windows = {
        "bias": plan.limits.bias_window_bytes,
        "weight": plan.limits.weight_window_bytes,
    }
    for kind, expected_total in expected_totals.items():
        entry = _dict(files.get(kind), f"files.{kind}")
        relative = _string(entry.get("path"), f"files.{kind}.path")
        if relative != expected_paths[kind]:
            raise PackageValidationError(f"files.{kind}.path contract changed")
        if entry.get("window_bytes") != expected_windows[kind]:
            raise PackageValidationError(f"files.{kind}.window_bytes changed")
        if expected_total > expected_windows[kind]:
            raise PackageValidationError(f"{kind} package exceeds its DDR window")
        path = (root / relative).resolve()
        try:
            path.relative_to(root)
        except ValueError as error:
            raise PackageValidationError(f"files.{kind}.path escapes package") from error
        if not path.is_file():
            raise PackageValidationError(f"missing {kind} package image")
        image = path.read_bytes()
        if _integer(entry.get("file_bytes"), f"files.{kind}.file_bytes", 1) != len(image):
            raise PackageValidationError(f"{kind} package file length changed")
        if len(image) != expected_total:
            raise PackageValidationError(f"{kind} package total contract changed")
        if sha256_bytes(image) != _sha256(entry.get("sha256"), f"files.{kind}.sha256"):
            raise PackageValidationError(f"{kind} package SHA256 mismatch")
        images[kind] = image

    layers = data.get("layers")
    if not isinstance(layers, list) or len(layers) != EXPECTED_LAYER_COUNT:
        raise PackageValidationError("package must contain exactly 13 layers")
    previous_end = {"bias": 0, "weight": 0}
    payload_total = {"bias": 0, "weight": 0}
    for index, (raw_entry, schedule) in enumerate(zip(layers, plan.layers)):
        entry = _dict(raw_entry, f"layers[{index}]")
        if entry.get("index") != index or entry.get("layer_id") != schedule.layer.layer_id:
            raise PackageValidationError(f"layers[{index}] identity/order changed")
        if entry.get("model_index") != schedule.layer.model_index:
            raise PackageValidationError(f"layers[{index}].model_index changed")
        if entry.get("detect_index") != schedule.layer.detect_index:
            raise PackageValidationError(f"layers[{index}].detect_index changed")
        _sha256(
            entry.get("source_manifest_sha256"),
            f"layers[{index}].source_manifest_sha256",
        )
        schedule_entry = _dict(entry.get("schedule"), f"layers[{index}].schedule")
        expected_schedule = {
            "tile_h": schedule.layer.tile_h,
            "tile_count": schedule.tile_count,
            "k_total": schedule.k_total,
            "k_passes": schedule.k_passes,
            "cout_total": schedule.layer.cout,
            "cout_blocks": schedule.cout_blocks,
            "cout_tail_channels": schedule.cout_tail_channels,
            "expected_contexts": schedule.expected_contexts,
            "ifm_bytes": schedule.ifm_bytes,
            "ofm_bytes": schedule.ofm_bytes,
        }
        for field, expected in expected_schedule.items():
            if schedule_entry.get(field) != expected:
                raise PackageValidationError(
                    f"{schedule.layer.layer_id}: schedule.{field} changed"
                )
        quant_entry = _dict(entry.get("quant"), f"layers[{index}].quant")
        if _validate_quant(quant_entry, f"layers[{index}].quant") != quant_entry:
            raise PackageValidationError(f"layers[{index}]: quant schema changed")
        _validate_provenance(entry.get("provenance"), f"layers[{index}].provenance")
        activation = _dict(entry.get("activation"), f"layers[{index}].activation")
        if activation.get("mode") != "lut256":
            raise PackageValidationError(f"layers[{index}]: activation mode changed")
        expected_function = (
            "identity" if schedule.layer.detect_index is not None else "leaky_relu_0p1"
        )
        if activation.get("function") != expected_function:
            raise PackageValidationError(f"layers[{index}]: activation function changed")
        activation_lut_sha = _sha256(
            activation.get("lut_sha256"), f"layers[{index}].activation.lut_sha256"
        )
        if activation.get("lut_programming") != (
            "AXI-Lite before layer start; not in DMA package"
        ):
            raise PackageValidationError(
                f"layers[{index}]: activation LUT programming contract changed"
            )
        source_files = _dict(entry.get("source_files"), f"layers[{index}].source_files")
        expected_source_bytes = {
            "bias_i32": schedule.layer.cout * 4,
            "weight_raw_oihw_s8": (
                schedule.layer.cout
                * schedule.layer.cin
                * schedule.layer.kernel
                * schedule.layer.kernel
            ),
            "lut_u8": 256,
        }
        for source_name, expected_bytes in expected_source_bytes.items():
            source_entry = _dict(
                source_files.get(source_name),
                f"layers[{index}].source_files.{source_name}",
            )
            if source_entry.get("bytes") != expected_bytes:
                raise PackageValidationError(
                    f"layers[{index}].source_files.{source_name}.bytes changed"
                )
            _sha256(
                source_entry.get("sha256"),
                f"layers[{index}].source_files.{source_name}.sha256",
            )
            source_path = source_entry.get("path")
            if source_name == "lut_u8":
                if source_path is not None and not isinstance(source_path, str):
                    raise PackageValidationError(
                        f"layers[{index}].source_files.lut_u8.path is invalid"
                    )
            elif not isinstance(source_path, str) or not source_path:
                raise PackageValidationError(
                    f"layers[{index}].source_files.{source_name}.path is invalid"
                )
        if source_files["lut_u8"]["sha256"] != activation_lut_sha:
            raise PackageValidationError(
                f"layers[{index}]: activation LUT source binding changed"
            )
        graph = _dict(entry.get("graph"), f"layers[{index}].graph")
        expected_graph = {
            "input_tensor": schedule.layer.input_tensor,
            "output_tensor": schedule.layer.output_tensor,
            "pool_mode": POOL_MODES[schedule.layer.layer_id],
            "route_semantics": ROUTE_SEMANTICS[schedule.layer.layer_id],
        }
        if graph != expected_graph:
            raise PackageValidationError(f"layers[{index}]: graph semantics changed")

        for kind, expected_bytes, expected_packets in (
            ("bias", schedule.bias_bytes, schedule.bias_packets),
            ("weight", schedule.weight_bytes, schedule.weight_packets),
        ):
            section_entry = _dict(entry.get(kind), f"layers[{index}].{kind}")
            section = _section_bytes(
                images[kind], section_entry, f"layers[{index}].{kind}"
            )
            offset = int(section_entry["offset"])
            if offset < previous_end[kind]:
                raise PackageValidationError(f"layers[{index}].{kind} overlaps prior section")
            if len(section) != expected_bytes:
                raise PackageValidationError(f"layers[{index}].{kind} byte contract changed")
            if section_entry.get("packets") != expected_packets:
                raise PackageValidationError(f"layers[{index}].{kind} packet contract changed")
            if sha256_bytes(section) != _sha256(
                section_entry.get("sha256"), f"layers[{index}].{kind}.sha256"
            ):
                raise PackageValidationError(f"layers[{index}].{kind} section SHA256 mismatch")
            previous_end[kind] = offset + len(section)
            payload_total[kind] += len(section)
        _verify_padding(images["bias"], images["weight"], entry, schedule)

    for kind in ("bias", "weight"):
        file_entry = _dict(files[kind], f"files.{kind}")
        if file_entry.get("payload_bytes") != payload_total[kind]:
            raise PackageValidationError(f"files.{kind}.payload_bytes changed")
        if payload_total[kind] != expected_totals[kind]:
            raise PackageValidationError(f"{kind} section payload total changed")
    provenance = _dict(data.get("provenance"), "provenance")
    for field in (
        "checkpoint_sha256",
        "calibration_sha256",
        "export_sha256",
    ):
        expected_values = sorted(
            {
                str(_dict(layer, "layer")["provenance"][field])
                for layer in layers
            }
        )
        values = provenance.get(field)
        if not isinstance(values, list) or values != expected_values:
            raise PackageValidationError(f"provenance.{field} aggregate changed")
        for value_index, value in enumerate(values):
            _sha256(value, f"provenance.{field}[{value_index}]")
    return data


def main(argv: Iterable[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-root", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--verify", type=Path)
    args = parser.parse_args(list(argv) if argv is not None else None)
    if args.verify is not None:
        verify_package(args.verify)
        print(f"PASS: verified {args.verify}")
        return
    if args.model_root is None or args.output_dir is None:
        parser.error("--model-root and --output-dir are required when not using --verify")
    manifest = generate_package(args.model_root, args.output_dir)
    files = manifest["files"]
    print(
        "Wrote COCO80 ABI-v2 package: "
        f"bias={files['bias']['file_bytes']} B, "  # type: ignore[index]
        f"weight={files['weight']['file_bytes']} B"  # type: ignore[index]
    )


if __name__ == "__main__":
    main()

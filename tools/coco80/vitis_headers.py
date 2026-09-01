"""Generate the freestanding Vitis configuration header for COCO80 r5.

The generator accepts only a verified ABI-v2 parameter package and the exact
``quantization_manifest.json`` produced by ``save_quant_checkpoint``.  It
cross-binds those two artifacts before emitting any C.  No timestamp, source
path, Python repr, or platform newline enters the output, so identical inputs
produce identical header bytes and SHA256 on every host.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import struct
import tempfile
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping

try:
    from .hardware_plan import COCO80_HARDWARE_PLAN, HardwarePlan
    from .parameter_package import (
        QUANTIZATION_MANIFEST_FORMAT,
        QUANTIZATION_MANIFEST_NAME,
        QUANTIZATION_MANIFEST_VERSION,
        load_layer_manifests,
        sha256_file,
        verify_package,
    )
except ImportError:  # pragma: no cover - direct script execution
    from hardware_plan import COCO80_HARDWARE_PLAN, HardwarePlan  # type: ignore
    from parameter_package import (  # type: ignore
        QUANTIZATION_MANIFEST_FORMAT,
        QUANTIZATION_MANIFEST_NAME,
        QUANTIZATION_MANIFEST_VERSION,
        load_layer_manifests,
        sha256_file,
        verify_package,
    )


VITIS_HEADER_MAGIC = "kv260-coco80-yolov3-tiny-vitis-config"
VITIS_HEADER_VERSION = 1
VITIS_HEADER_GUARD = "COCO80_GENERATED_CONFIG_H"

TENSOR_NAMES = (
    "input",
    "m0",
    "pool1",
    "m2",
    "pool3",
    "m4",
    "pool5",
    "m6",
    "pool7",
    "m8",
    "pool9",
    "m10",
    "pool12",
    "m13",
    "m14",
    "m15",
    "m16",
    "upsample17",
    "concat18",
    "m19",
    "p4_detect",
    "p5_detect",
)

POOL_QPARAM_EDGES = (
    ("m0", "pool1"),
    ("m2", "pool3"),
    ("m4", "pool5"),
    ("m6", "pool7"),
    ("m8", "pool9"),
    ("m10", "pool12"),
)


class VitisHeaderError(ValueError):
    """Inputs do not form one self-consistent board configuration."""


@dataclass(frozen=True)
class HeaderArtifact:
    path: Path
    bytes: int
    sha256: str
    binding_sha256: str


def _dict(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise VitisHeaderError(f"{label} must be an object")
    return value


def _sha256(value: object, label: str, *, nonzero: bool = False) -> str:
    if not isinstance(value, str) or len(value) != 64:
        raise VitisHeaderError(f"{label} must be a SHA256 hex digest")
    try:
        raw = bytes.fromhex(value)
    except ValueError as error:
        raise VitisHeaderError(f"{label} must be hexadecimal") from error
    if len(raw) != 32 or (nonzero and not any(raw)):
        raise VitisHeaderError(f"{label} must be a nonzero SHA256 digest")
    return value.lower()


def _u32(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFF:
        raise VitisHeaderError(f"{label} must be uint32")
    return value


def _float(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise VitisHeaderError(f"{label} must be numeric")
    result = float(value)
    if not math.isfinite(result) or result <= 0.0:
        raise VitisHeaderError(f"{label} must be finite and positive")
    return result


def _float32_bits(value: object, label: str) -> int:
    number = _float(value, label)
    try:
        packed = struct.pack("<f", number)
    except OverflowError as error:
        raise VitisHeaderError(f"{label} is not finite float32") from error
    bits = struct.unpack("<I", packed)[0]
    restored = struct.unpack("<f", packed)[0]
    if not math.isfinite(restored) or restored <= 0.0:
        raise VitisHeaderError(f"{label} is not positive finite float32")
    return bits


def _canonical_sha256(value: object) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _same(left: object, right: object, label: str) -> None:
    if left != right:
        raise VitisHeaderError(f"{label} is not bound to the canonical export")


def solve_a53_requant_multiplier(ratio: float) -> tuple[int, int]:
    """Mirror ``ptq_runner.solve_affine_multiplier`` without importing torch."""

    if not math.isfinite(ratio) or ratio <= 0.0:
        raise VitisHeaderError("A53 requant ratio must be finite and positive")
    best: tuple[float, int, int] | None = None
    for shift in range(8, 31):
        multiplier = int(round(ratio * (1 << shift)))
        if not 1 <= multiplier <= 0x7FFFFFFF:
            continue
        error = abs(multiplier / float(1 << shift) - ratio)
        candidate = (error, -shift, multiplier)
        if best is None or candidate < best:
            best = candidate
    if best is None:
        raise VitisHeaderError("A53 requant ratio is not representable")
    return best[2], -best[1]


def _add_tensor_qparam(
    values: dict[str, tuple[float, int, int, int]],
    name: str,
    scale: object,
    zero_point: object,
    label: str,
) -> None:
    if name not in TENSOR_NAMES:
        raise VitisHeaderError(f"unexpected tensor edge {name!r}")
    qparam = (
        _float(scale, f"{label}.scale"),
        _u32(zero_point, f"{label}.zero_point"),
        0,
        127,
    )
    if qparam[1] > 127:
        raise VitisHeaderError(f"{label}.zero_point exceeds reduced uint8 range")
    if name in values and values[name] != qparam:
        raise VitisHeaderError(f"tensor edge {name} has conflicting qparams")
    values[name] = qparam


def _read_lut(root: Path, source_files: Mapping[str, object], label: str) -> bytes:
    lut_entry = _dict(source_files.get("lut_u8"), f"{label}.lut_u8")
    relative = lut_entry.get("path")
    if not isinstance(relative, str) or not relative:
        raise VitisHeaderError(f"{label}.lut_u8.path must name the canonical LUT file")
    path = (root / relative).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        raise VitisHeaderError(f"{label}.lut_u8.path escapes quantization root") from error
    try:
        data = path.read_bytes()
    except OSError as error:
        raise VitisHeaderError(f"cannot read {path}") from error
    if len(data) != 256:
        raise VitisHeaderError(f"{label}.lut_u8 must contain 256 bytes")
    if hashlib.sha256(data).hexdigest() != _sha256(
        lut_entry.get("sha256"), f"{label}.lut_u8.sha256"
    ):
        raise VitisHeaderError(f"{label}.lut_u8 SHA256 mismatch")
    return data


def build_vitis_config(
    parameter_manifest: Path,
    quantization_manifest: Path,
    *,
    bit_sha256: str,
    xsa_sha256: str,
    sd_parameter_package: Path | None = None,
    plan: HardwarePlan = COCO80_HARDWARE_PLAN,
) -> dict[str, object]:
    """Validate/cross-bind all inputs and return a deterministic render model."""

    parameter_path = parameter_manifest.resolve()
    quant_path = quantization_manifest.resolve()
    if quant_path.name != QUANTIZATION_MANIFEST_NAME or not quant_path.is_file():
        raise VitisHeaderError(
            f"canonical input must be a file named {QUANTIZATION_MANIFEST_NAME}"
        )
    try:
        quant_top = _dict(
            json.loads(quant_path.read_text(encoding="utf-8")), str(quant_path)
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VitisHeaderError(f"cannot read canonical manifest {quant_path}") from error
    if (
        quant_top.get("format") != QUANTIZATION_MANIFEST_FORMAT
        or quant_top.get("version") != QUANTIZATION_MANIFEST_VERSION
    ):
        raise VitisHeaderError("unsupported canonical quantization manifest")

    try:
        package = verify_package(parameter_path, plan)
        canonical = load_layer_manifests(quant_path.parent, plan)
    except ValueError as error:
        raise VitisHeaderError(str(error)) from error
    package_layers = package.get("layers")
    if not isinstance(package_layers, list) or len(package_layers) != len(plan.layers):
        raise VitisHeaderError("parameter package layer table changed")
    if len(canonical) != len(plan.layers):
        raise VitisHeaderError("canonical layer table changed")

    bit_digest = _sha256(bit_sha256, "bit_sha256", nonzero=True)
    xsa_digest = _sha256(xsa_sha256, "xsa_sha256", nonzero=True)
    quant_digest = sha256_file(quant_path)
    parameter_digest = sha256_file(parameter_path)
    tensor_qparams: dict[str, tuple[float, int, int, int]] = {}
    layers: list[dict[str, object]] = []
    luts: list[bytes] = []

    for index, (schedule, raw_package, source) in enumerate(
        zip(plan.layers, package_layers, canonical)
    ):
        package_layer = _dict(raw_package, f"package.layers[{index}]")
        layer_id = schedule.layer.layer_id
        if package_layer.get("layer_id") != layer_id:
            raise VitisHeaderError(f"package.layers[{index}] identity changed")
        _same(
            package_layer.get("source_manifest_sha256"),
            source.get("manifest_sha256"),
            f"{layer_id}.source_manifest_sha256",
        )
        for field in ("source_files", "quant", "activation", "graph", "provenance"):
            _same(package_layer.get(field), source.get(field), f"{layer_id}.{field}")
        if source.get("manifest_sha256") != quant_digest:
            raise VitisHeaderError(f"{layer_id} is not bound to the canonical manifest")

        quant = _dict(package_layer.get("quant"), f"{layer_id}.quant")
        activation = _dict(package_layer.get("activation"), f"{layer_id}.activation")
        schedule_entry = _dict(package_layer.get("schedule"), f"{layer_id}.schedule")
        bias = _dict(package_layer.get("bias"), f"{layer_id}.bias")
        weight = _dict(package_layer.get("weight"), f"{layer_id}.weight")
        if quant.get("rtl_output_zero_point") != 0:
            raise VitisHeaderError(f"{layer_id}: PL preactivation zero point must be zero")
        if activation.get("mode") != "lut256":
            raise VitisHeaderError(f"{layer_id}: activation must be lut256")
        _add_tensor_qparam(
            tensor_qparams,
            schedule.layer.input_tensor,
            quant.get("input_scale"),
            quant.get("input_zero_point"),
            f"{layer_id}.input",
        )
        _add_tensor_qparam(
            tensor_qparams,
            schedule.layer.output_tensor,
            quant.get("output_scale"),
            quant.get("output_zero_point"),
            f"{layer_id}.output",
        )
        # A fused maxpool changes geometry but not the uint8 quantization
        # domain.  Keep the logical pre-pool convolution node in the qparam
        # table even though the production PL stream emits only the pooled
        # tensor consumed by the next dispatch.
        if schedule.layer.pool_stride:
            _add_tensor_qparam(
                tensor_qparams,
                layer_id,
                quant.get("output_scale"),
                quant.get("output_zero_point"),
                f"{layer_id}.pre_pool_output",
            )
        source_files = _dict(source.get("source_files"), f"{layer_id}.source_files")
        lut = _read_lut(quant_path.parent, source_files, f"{layer_id}.source_files")
        if hashlib.sha256(lut).hexdigest() != activation.get("lut_sha256"):
            raise VitisHeaderError(f"{layer_id}: LUT is not bound to package activation")
        luts.append(lut)

        layers.append(
            {
                "index": index,
                "name": layer_id,
                "model_index": _u32(package_layer.get("model_index"), f"{layer_id}.model_index"),
                "detect_index": (
                    0xFFFFFFFF
                    if package_layer.get("detect_index") is None
                    else _u32(package_layer.get("detect_index"), f"{layer_id}.detect_index")
                ),
                "input_tensor": schedule.layer.input_tensor,
                "output_tensor": schedule.layer.output_tensor,
                "ifm_h": schedule.layer.fm_h,
                "ifm_w": schedule.layer.fm_w,
                "ifm_c": schedule.layer.cin,
                "ofm_h": schedule.output_h,
                "ofm_w": schedule.output_w,
                "ofm_c": schedule.layer.cout,
                "kernel": schedule.layer.kernel,
                "stride": schedule.layer.stride,
                "pad": schedule.layer.pad,
                "pool_stride": schedule.layer.pool_stride,
                "tile_h": schedule.layer.tile_h,
                "tile_count": schedule.tile_count,
                "last_tile_h": schedule.last_tile_h,
                "k_total": schedule.k_total,
                "k_passes": schedule.k_passes,
                "cout_blocks": schedule.cout_blocks,
                "cout_tail": schedule.cout_tail_channels,
                "ifm_bytes": schedule.ifm_bytes,
                "ofm_bytes": schedule.ofm_bytes,
                "bias_offset": _u32(bias.get("offset"), f"{layer_id}.bias.offset"),
                "bias_bytes": _u32(bias.get("bytes"), f"{layer_id}.bias.bytes"),
                "bias_packets": _u32(bias.get("packets"), f"{layer_id}.bias.packets"),
                "weight_offset": _u32(weight.get("offset"), f"{layer_id}.weight.offset"),
                "weight_bytes": _u32(weight.get("bytes"), f"{layer_id}.weight.bytes"),
                "weight_packets": _u32(weight.get("packets"), f"{layer_id}.weight.packets"),
                "expected_contexts": _u32(
                    schedule_entry.get("expected_contexts"),
                    f"{layer_id}.schedule.expected_contexts",
                ),
                "input_scale_bits": _float32_bits(
                    quant.get("input_scale"), f"{layer_id}.quant.input_scale"
                ),
                "input_zero_point": _u32(
                    quant.get("input_zero_point"), f"{layer_id}.quant.input_zero_point"
                ),
                "output_scale_bits": _float32_bits(
                    quant.get("output_scale"), f"{layer_id}.quant.output_scale"
                ),
                "output_zero_point": _u32(
                    quant.get("output_zero_point"), f"{layer_id}.quant.output_zero_point"
                ),
                "weight_scale_bits": _float32_bits(
                    quant.get("weight_scale"), f"{layer_id}.quant.weight_scale"
                ),
                "preactivation_scale_bits": _float32_bits(
                    quant.get("preactivation_scale"),
                    f"{layer_id}.quant.preactivation_scale",
                ),
                "quant_mult": _u32(quant.get("rtl_mult"), f"{layer_id}.quant.rtl_mult"),
                "quant_shift": _u32(quant.get("rtl_shift"), f"{layer_id}.quant.rtl_shift"),
                "rtl_output_zero_point": 0,
                "activation_lut_index": index,
            }
        )

    tensor_qparams["upsample17"] = tensor_qparams["m16"]
    if set(tensor_qparams) != set(TENSOR_NAMES):
        missing = sorted(set(TENSOR_NAMES) - set(tensor_qparams))
        extra = sorted(set(tensor_qparams) - set(TENSOR_NAMES))
        raise VitisHeaderError(f"tensor qparam set changed: missing={missing}, extra={extra}")
    for source, target in POOL_QPARAM_EDGES:
        if tensor_qparams[source] != tensor_qparams[target]:
            raise VitisHeaderError(f"pool edge {source}->{target} changed qparams")
    if tensor_qparams["m16"] != tensor_qparams["upsample17"]:
        raise VitisHeaderError("nearest upsample changed qparams")
    if tensor_qparams["m16"] != tensor_qparams["concat18"]:
        raise VitisHeaderError("concat18 target domain must equal m16 output domain")

    m8_scale, m8_zp, _, _ = tensor_qparams["m8"]
    m16_scale, m16_zp, _, _ = tensor_qparams["m16"]
    route_mult, route_shift = solve_a53_requant_multiplier(m8_scale / m16_scale)
    files = _dict(package.get("files"), "package.files")
    bias_file = _dict(files.get("bias"), "package.files.bias")
    weight_file = _dict(files.get("weight"), "package.files.weight")
    provenance = _dict(package.get("provenance"), "package.provenance")
    checkpoints = provenance.get("checkpoint_sha256")
    if not isinstance(checkpoints, list) or len(checkpoints) != 1:
        raise VitisHeaderError("parameter package must bind exactly one model checkpoint")
    model_checkpoint = _sha256(
        checkpoints[0], "package.provenance.checkpoint_sha256[0]", nonzero=True
    )
    hashes = {
        "bit": bit_digest,
        "xsa": xsa_digest,
        "hardware_plan": plan.sha256(),
        "parameter_manifest": parameter_digest,
        "quantization_manifest": quant_digest,
        "bias_package": _sha256(bias_file.get("sha256"), "package.files.bias.sha256"),
        "weight_package": _sha256(weight_file.get("sha256"), "package.files.weight.sha256"),
        "model_checkpoint": model_checkpoint,
    }
    config: dict[str, object] = {
        "magic": VITIS_HEADER_MAGIC,
        "version": VITIS_HEADER_VERSION,
        "hashes": hashes,
        "bias_package_bytes": _u32(bias_file.get("file_bytes"), "bias.file_bytes"),
        "weight_package_bytes": _u32(weight_file.get("file_bytes"), "weight.file_bytes"),
        "layers": layers,
        "luts": [lut.hex() for lut in luts],
        "tensor_qparams": [
            {
                "index": index,
                "name": name,
                "scale_bits": _float32_bits(tensor_qparams[name][0], f"{name}.scale"),
                "zero_point": tensor_qparams[name][1],
                "qmin": tensor_qparams[name][2],
                "qmax": tensor_qparams[name][3],
            }
            for index, name in enumerate(TENSOR_NAMES)
        ],
        "route_m8_to_m16": {
            "source_tensor": "m8",
            "target_tensor": "m16",
            "source_zero_point": m8_zp,
            "target_zero_point": m16_zp,
            "multiplier": route_mult,
            "shift": route_shift,
            "rounding": "symmetric_nearest_ties_away_from_zero",
        },
    }
    config["binding_sha256"] = _canonical_sha256(config)
    if sd_parameter_package is not None:
        _bind_sd_parameter_package(config, Path(sd_parameter_package))
    return config


def _binding_words(config: Mapping[str, object]) -> list[list[int]]:
    layers = config.get("layers")
    luts = config.get("luts")
    if not isinstance(layers, list) or len(layers) != 13:
        raise VitisHeaderError("runtime binding requires 13 layers")
    if not isinstance(luts, list) or len(luts) != 13:
        raise VitisHeaderError("runtime binding requires 13 activation LUTs")
    output: list[list[int]] = []
    for index, (raw, raw_lut) in enumerate(zip(layers, luts)):
        layer = _dict(raw, f"layers[{index}]")
        if not isinstance(raw_lut, str):
            raise VitisHeaderError(f"LUT {index} is not hexadecimal")
        lut = bytes.fromhex(raw_lut)
        values = [
            _u32(layer.get("bias_offset"), f"layers[{index}].bias_offset"),
            _u32(layer.get("bias_bytes"), f"layers[{index}].bias_bytes"),
            _u32(layer.get("weight_offset"), f"layers[{index}].weight_offset"),
            _u32(layer.get("weight_bytes"), f"layers[{index}].weight_bytes"),
            _u32(layer.get("bias_packets"), f"layers[{index}].bias_packets"),
            _u32(layer.get("weight_packets"), f"layers[{index}].weight_packets"),
            _u32(layer.get("input_scale_bits"), f"layers[{index}].input_scale_bits"),
            _u32(layer.get("input_zero_point"), f"layers[{index}].input_zero_point"),
            _u32(layer.get("output_scale_bits"), f"layers[{index}].output_scale_bits"),
            _u32(layer.get("output_zero_point"), f"layers[{index}].output_zero_point"),
            _u32(layer.get("quant_mult"), f"layers[{index}].quant_mult"),
            _u32(layer.get("quant_shift"), f"layers[{index}].quant_shift"),
            _u32(layer.get("rtl_output_zero_point"), f"layers[{index}].rtl_output_zero_point"),
            index * 256,
            zlib.crc32(lut) & 0xFFFFFFFF,
        ]
        output.append(values)
    return output


def _bind_sd_parameter_package(config: dict[str, object], package_path: Path) -> None:
    """Bind the generated C table to the exact SD parameter package bytes."""

    from .sd_pack import copy_package_section, crc32_file, parse_parameter_package

    package_path = package_path.resolve()
    parsed = parse_parameter_package(package_path)
    hashes = _dict(config.get("hashes"), "hashes")
    if parsed.get("model_sha256") != hashes.get("model_checkpoint"):
        raise VitisHeaderError("SD parameter model SHA256 differs from quantized checkpoint")
    bindings = _binding_words(config)
    expected_binding = b"".join(struct.pack("<15I", *values) for values in bindings)
    expected_luts = b"".join(bytes.fromhex(value) for value in config["luts"])
    with tempfile.TemporaryDirectory(prefix="coco80-vitis-bind-") as directory:
        root = Path(directory)
        binding_path = root / "bindings.bin"
        lut_path = root / "luts.bin"
        sections = _dict(parsed.get("sections"), "SD parameter sections")
        copy_package_section(package_path, _dict(sections.get("quantization"), "quantization section"), binding_path)
        copy_package_section(package_path, _dict(sections.get("activation_luts"), "activation LUT section"), lut_path)
        if binding_path.read_bytes() != expected_binding:
            raise VitisHeaderError("SD parameter binding table differs from generated C table")
        if lut_path.read_bytes() != expected_luts:
            raise VitisHeaderError("SD parameter LUT section differs from generated C LUTs")
    package_crc = crc32_file(package_path)
    if package_crc == 0:
        raise VitisHeaderError("SD parameter package CRC32 must be nonzero")
    route = _dict(config.get("route_m8_to_m16"), "route_m8_to_m16")
    plan_digest = _sha256(hashes.get("hardware_plan"), "hashes.hardware_plan")
    model_digest = _sha256(hashes.get("model_checkpoint"), "hashes.model_checkpoint")
    software_crc = zlib.crc32(bytes.fromhex(str(hashes["quantization_manifest"]))) & 0xFFFFFFFF
    hardware_crc = zlib.crc32(bytes.fromhex(str(hashes["bit"]))) & 0xFFFFFFFF
    if software_crc == 0 or hardware_crc == 0:
        raise VitisHeaderError("build identity CRC32 must be nonzero")
    scalars = [
        0x46433843, 1, 13, 200_000_000, 0xBF,
        package_path.stat().st_size, package_crc,
        int(route["source_zero_point"]), int(route["target_zero_point"]),
        int(route["multiplier"]), int(route["shift"]), software_crc, hardware_crc,
    ]
    plan_words = [int(plan_digest[start : start + 8], 16) for start in range(0, 64, 8)]
    model_words = list(struct.unpack("<8I", bytes.fromhex(model_digest)))
    crc_payload = b"".join(
        struct.pack("<I", word)
        for word in scalars + plan_words + model_words + [word for row in bindings for word in row]
    )
    config_crc = zlib.crc32(crc_payload) & 0xFFFFFFFF
    if config_crc == 0:
        raise VitisHeaderError("generated runtime config CRC32 must be nonzero")
    config["runtime"] = {
        "scalars": scalars,
        "plan_words": plan_words,
        "model_words": model_words,
        "bindings": bindings,
        "config_crc32": config_crc,
    }


def _macro_name(value: str) -> str:
    result = "".join(character.upper() if character.isalnum() else "_" for character in value)
    while "__" in result:
        result = result.replace("__", "_")
    return result.strip("_")


def _digest_array(name: str, digest: str) -> list[str]:
    values = bytes.fromhex(digest)
    lines = [f"static const uint8_t {name}[32] = {{"]
    for start in range(0, 32, 16):
        lines.append(
            "    " + ", ".join(f"0x{value:02x}U" for value in values[start : start + 16]) + ","
        )
    lines.append("};")
    return lines


def render_vitis_header(config: Mapping[str, object]) -> str:
    """Render a previously validated configuration with LF-only newlines."""

    if config.get("magic") != VITIS_HEADER_MAGIC or config.get("version") != VITIS_HEADER_VERSION:
        raise VitisHeaderError("unsupported render configuration")
    layers = config.get("layers")
    tensors = config.get("tensor_qparams")
    luts = config.get("luts")
    if not isinstance(layers, list) or len(layers) != 13:
        raise VitisHeaderError("render configuration must contain 13 layers")
    if not isinstance(tensors, list) or len(tensors) != len(TENSOR_NAMES):
        raise VitisHeaderError("render tensor table changed")
    if not isinstance(luts, list) or len(luts) != 13:
        raise VitisHeaderError("render LUT table changed")
    hashes = _dict(config.get("hashes"), "hashes")
    route = _dict(config.get("route_m8_to_m16"), "route_m8_to_m16")

    lines = [
        "/* Generated by tools/coco80/vitis_headers.py; do not edit. */",
        f"#ifndef {VITIS_HEADER_GUARD}",
        f"#define {VITIS_HEADER_GUARD}",
        "",
        "#include <stdint.h>",
        "",
        f'#define COCO80_GENERATED_CONFIG_MAGIC "{VITIS_HEADER_MAGIC}"',
        f"#define COCO80_GENERATED_CONFIG_VERSION {VITIS_HEADER_VERSION}U",
        "#define COCO80_GENERATED_LAYER_COUNT 13U",
        f"#define COCO80_GENERATED_TENSOR_COUNT {len(TENSOR_NAMES)}U",
        "#define COCO80_GENERATED_LUT_BYTES 256U",
        f"#define COCO80_BIAS_PACKAGE_BYTES {config['bias_package_bytes']}U",
        f"#define COCO80_WEIGHT_PACKAGE_BYTES {config['weight_package_bytes']}U",
        f'#define COCO80_CONFIG_BINDING_SHA256_HEX "{config["binding_sha256"]}"',
    ]
    for key in (
        "bit", "xsa", "hardware_plan", "parameter_manifest",
        "quantization_manifest", "bias_package", "weight_package",
    ):
        macro = _macro_name(key)
        digest = _sha256(hashes.get(key), f"hashes.{key}")
        lines.append(f'#define COCO80_EXPECTED_{macro}_SHA256_HEX "{digest}"')
    lines.extend(["", "enum coco80_generated_layer_id {"])
    for layer in layers:
        entry = _dict(layer, "layer")
        lines.append(
            f"    COCO80_LAYER_{_macro_name(str(entry['name']))} = {entry['index']}U,"
        )
    lines.extend(["};", "", "enum coco80_generated_tensor_id {"])
    for tensor in tensors:
        entry = _dict(tensor, "tensor")
        lines.append(
            f"    COCO80_TENSOR_{_macro_name(str(entry['name']))} = {entry['index']}U,"
        )
    lines.extend(
        [
            "};",
            "",
            "enum coco80_a53_rounding_mode {",
            "    COCO80_A53_ROUND_SYMMETRIC_NEAREST_TIES_AWAY = 1U,",
            "};",
            "",
            "typedef struct {",
            "    uint32_t layer_id, model_index, detect_index;",
            "    uint32_t input_tensor_id, output_tensor_id;",
            "    uint32_t ifm_h, ifm_w, ifm_c, ofm_h, ofm_w, ofm_c;",
            "    uint32_t kernel, stride, pad, pool_stride;",
            "    uint32_t tile_h, tile_count, last_tile_h;",
            "    uint32_t k_total, k_passes, cout_blocks, cout_tail_channels;",
            "    uint32_t ifm_bytes, ofm_bytes;",
            "    uint32_t bias_offset, bias_bytes, bias_packets;",
            "    uint32_t weight_offset, weight_bytes, weight_packets;",
            "    uint32_t expected_contexts;",
            "    uint32_t input_scale_f32, input_zero_point;",
            "    uint32_t output_scale_f32, output_zero_point;",
            "    uint32_t weight_scale_f32, preactivation_scale_f32;",
            "    uint32_t quant_mult, quant_shift, rtl_output_zero_point;",
            "    uint32_t activation_lut_index;",
            "} coco80_generated_layer_t;",
            "",
            "typedef struct {",
            "    uint32_t tensor_id, scale_f32, zero_point, qmin, qmax;",
            "} coco80_generated_tensor_qparam_t;",
            "",
            "typedef struct {",
            "    uint32_t source_tensor_id, target_tensor_id;",
            "    uint32_t source_zero_point, target_zero_point;",
            "    uint32_t multiplier, shift, rounding_mode;",
            "} coco80_generated_a53_requant_t;",
            "",
            "static const coco80_generated_layer_t coco80_generated_layers[13] = {",
        ]
    )
    tensor_ids = {name: index for index, name in enumerate(TENSOR_NAMES)}
    fields = (
        "index", "model_index", "detect_index", "input_tensor_id", "output_tensor_id",
        "ifm_h", "ifm_w", "ifm_c", "ofm_h", "ofm_w", "ofm_c",
        "kernel", "stride", "pad", "pool_stride", "tile_h", "tile_count",
        "last_tile_h", "k_total", "k_passes", "cout_blocks", "cout_tail",
        "ifm_bytes", "ofm_bytes", "bias_offset", "bias_bytes", "bias_packets",
        "weight_offset", "weight_bytes", "weight_packets", "expected_contexts",
        "input_scale_bits", "input_zero_point", "output_scale_bits",
        "output_zero_point", "weight_scale_bits", "preactivation_scale_bits",
        "quant_mult", "quant_shift", "rtl_output_zero_point", "activation_lut_index",
    )
    for raw in layers:
        entry = _dict(raw, "layer")
        rendered = dict(entry)
        rendered["input_tensor_id"] = tensor_ids[str(entry["input_tensor"])]
        rendered["output_tensor_id"] = tensor_ids[str(entry["output_tensor"])]
        values = [int(rendered[field]) for field in fields]
        lines.append(f"    /* {entry['name']} */")
        lines.append("    {" + ", ".join(f"{value}U" for value in values) + "},")
    lines.extend(["};", "", "static const coco80_generated_tensor_qparam_t coco80_generated_tensor_qparams[] = {"])
    for raw in tensors:
        entry = _dict(raw, "tensor")
        lines.append(
            f"    /* {entry['name']} */ "
            + "{" + ", ".join(
                f"{int(entry[field])}U"
                for field in ("index", "scale_bits", "zero_point", "qmin", "qmax")
            ) + "},"
        )
    lines.extend(["};", "", "static const uint8_t coco80_generated_activation_luts[13][256] = {"])
    for index, (layer, raw_hex) in enumerate(zip(layers, luts)):
        entry = _dict(layer, "layer")
        if not isinstance(raw_hex, str):
            raise VitisHeaderError(f"LUT {index} is not hexadecimal")
        try:
            lut = bytes.fromhex(raw_hex)
        except ValueError as error:
            raise VitisHeaderError(f"LUT {index} is not hexadecimal") from error
        if len(lut) != 256:
            raise VitisHeaderError(f"LUT {index} must contain 256 bytes")
        lines.append(f"    {{ /* {entry['name']} */")
        for start in range(0, 256, 16):
            lines.append(
                "        "
                + ", ".join(f"0x{value:02x}U" for value in lut[start : start + 16])
                + ","
            )
        lines.append("    },")
    lines.extend(
        [
            "};",
            "",
            "static const coco80_generated_a53_requant_t coco80_generated_m8_to_m16_requant = {",
            f"    {tensor_ids['m8']}U, {tensor_ids['m16']}U,",
            f"    {route['source_zero_point']}U, {route['target_zero_point']}U,",
            f"    {route['multiplier']}U, {route['shift']}U,",
            "    COCO80_A53_ROUND_SYMMETRIC_NEAREST_TIES_AWAY,",
            "};",
            "",
        ]
    )
    for key in (
        "bit", "xsa", "hardware_plan", "parameter_manifest",
        "quantization_manifest", "bias_package", "weight_package",
    ):
        lines.extend(_digest_array(f"coco80_expected_{key}_sha256", str(hashes[key])))
        lines.append("")
    lines.extend([f"#endif /* {VITIS_HEADER_GUARD} */", ""])
    runtime = config.get("runtime")
    if runtime is not None:
        # Insert before the include guard closes; the descriptive tables above
        # remain usable by host-only consumers when no SD package was supplied.
        runtime_obj = _dict(runtime, "runtime")
        bindings = runtime_obj.get("bindings")
        scalars = runtime_obj.get("scalars")
        plan_words = runtime_obj.get("plan_words")
        model_words = runtime_obj.get("model_words")
        if not all(isinstance(value, list) for value in (bindings, scalars, plan_words, model_words)):
            raise VitisHeaderError("runtime render model is invalid")
        lines = lines[:-2]
        lines.extend([
            f"#define COCO80_SD_PARAMETER_PACKAGE_BYTES {int(scalars[5])}U",
            f"#define COCO80_SD_PARAMETER_PACKAGE_CRC32 0x{int(scalars[6]):08x}U",
            "",
            '#include "coco80_accel.h"',
            "",
            "static const coco80_accel_layer_binding_t coco80_runtime_layer_bindings[13] = {",
        ])
        for row in bindings:
            lines.append("    {" + ", ".join(f"{int(value)}U" for value in row) + "},")
        lines.extend([
            "};",
            "",
            "static const coco80_accel_generated_config_t coco80_runtime_config = {",
            "    " + ", ".join(f"{int(value)}U" for value in scalars) + ",",
            "    {" + ", ".join(f"0x{int(value):08x}U" for value in plan_words) + "},",
            "    {" + ", ".join(f"0x{int(value):08x}U" for value in model_words) + "},",
            f"    0x{int(runtime_obj['config_crc32']):08x}U,",
            "    coco80_runtime_layer_bindings,",
            "};",
            "",
            f"#endif /* {VITIS_HEADER_GUARD} */",
            "",
        ])
    return "\n".join(lines)


def generate_vitis_header(
    parameter_manifest: Path,
    quantization_manifest: Path,
    output: Path,
    *,
    bit_sha256: str,
    xsa_sha256: str,
    sd_parameter_package: Path | None = None,
    plan: HardwarePlan = COCO80_HARDWARE_PLAN,
) -> HeaderArtifact:
    config = build_vitis_config(
        parameter_manifest,
        quantization_manifest,
        bit_sha256=bit_sha256,
        xsa_sha256=xsa_sha256,
        sd_parameter_package=sd_parameter_package,
        plan=plan,
    )
    content = render_vitis_header(config).encode("ascii")
    destination = output.resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=destination.parent, prefix=destination.name + ".", delete=False
        ) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return HeaderArtifact(
        path=destination,
        bytes=len(content),
        sha256=hashlib.sha256(content).hexdigest(),
        binding_sha256=str(config["binding_sha256"]),
    )


write_vitis_header = generate_vitis_header


def main(argv: Iterable[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parameter-manifest", type=Path, required=True)
    parser.add_argument("--quantization-manifest", type=Path, required=True)
    parser.add_argument("--bit-sha256", required=True)
    parser.add_argument("--xsa-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sd-parameter-package", type=Path)
    args = parser.parse_args(list(argv) if argv is not None else None)
    artifact = generate_vitis_header(
        args.parameter_manifest,
        args.quantization_manifest,
        args.output,
        bit_sha256=args.bit_sha256,
        xsa_sha256=args.xsa_sha256,
        sd_parameter_package=args.sd_parameter_package,
    )
    print(
        json.dumps(
            {
                "bytes": artifact.bytes,
                "header": str(artifact.path),
                "sha256": artifact.sha256,
                "binding_sha256": artifact.binding_sha256,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()


__all__ = [
    "HeaderArtifact",
    "TENSOR_NAMES",
    "VITIS_HEADER_MAGIC",
    "VITIS_HEADER_VERSION",
    "VitisHeaderError",
    "build_vitis_config",
    "generate_vitis_header",
    "render_vitis_header",
    "solve_a53_requant_multiplier",
    "write_vitis_header",
]

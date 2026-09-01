"""Build the resident A53 baseline parameter/input/golden package.

The package deliberately uses unpadded K-major/Cout-contiguous weights.  It is
independent of the PL parameter stream and is downloaded once by XSCT before
the timed CPU runs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import zlib
from pathlib import Path

import numpy as np


ALIGNMENT = 64
INPUT_BYTES = 416 * 416 * 3
P4_BYTES = 26 * 26 * 255
P5_BYTES = 13 * 13 * 255


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def _read_checked(root: Path, spec: dict) -> bytes:
    path = root / Path(spec["path"])
    data = path.read_bytes()
    if len(data) != int(spec["bytes"]):
        raise ValueError(f"size mismatch: {path}")
    if hashlib.sha256(data).hexdigest() != spec["sha256"].lower():
        raise ValueError(f"hash mismatch: {path}")
    return data


def _align(blob: bytearray) -> None:
    blob.extend(b"\0" * ((-len(blob)) % ALIGNMENT))


def _append(blob: bytearray, data: bytes) -> tuple[int, int]:
    _align(blob)
    offset = len(blob)
    blob.extend(data)
    return offset, len(data)


def _c_float(value: float) -> str:
    text = f"{value:.9g}"
    if "." not in text and "e" not in text.lower():
        text += ".0"
    return text + "f"


def build(args: argparse.Namespace) -> None:
    quant_path = args.quant_manifest.resolve()
    quant_root = quant_path.parent
    quant = json.loads(quant_path.read_text(encoding="utf-8"))
    layers = quant.get("layers")
    if quant.get("version") != 1 or not isinstance(layers, list) or len(layers) != 13:
        raise ValueError("expected the 13-layer v1 COCO80 quantization manifest")
    if quant.get("weight_qscheme") != "per_tensor_symmetric_s8_zp0" or \
       quant.get("activation_quant_range") != [0, 127]:
        raise ValueError("quantization contract is not compatible with r5")

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    params = bytearray()
    generated_layers: list[dict] = []
    for expected_index, layer in enumerate(layers):
        if int(layer["infer_index"]) != expected_index or int(layer["stride"]) != 1:
            raise ValueError(f"invalid layer order/stride: {layer['name']}")
        shape = [int(v) for v in layer["weight_shape_oihw"]]
        ofm_c, ifm_c, kh, kw = shape
        if kh != int(layer["kernel"]) or kw != kh:
            raise ValueError(f"weight/kernel mismatch: {layer['name']}")
        files = layer["files"]
        raw_weight = _read_checked(quant_root, files["weight_raw_oihw_s8"])
        weight = np.frombuffer(raw_weight, dtype=np.int8).reshape(shape)
        weight_kco = np.transpose(weight, (1, 2, 3, 0)).copy(order="C").tobytes()
        bias = _read_checked(quant_root, files["bias_i32"])
        lut = _read_checked(quant_root, files["activation_lut_u8"])
        if len(bias) != ofm_c * 4 or len(lut) != 256:
            raise ValueError(f"bias/LUT mismatch: {layer['name']}")
        weight_offset, weight_bytes = _append(params, weight_kco)
        bias_offset, bias_bytes = _append(params, bias)
        lut_offset, lut_bytes = _append(params, lut)
        q = layer["quant"]
        generated_layers.append({
            "name": layer["name"],
            "ifm": [int(v) for v in layer["ifm_hwc"]],
            "ofm": [int(v) for v in layer["ofm_hwc"]],
            "kernel": int(layer["kernel"]), "stride": 1, "pad": int(layer["pad"]),
            "input_zero_point": int(q["input"]["zero_point"]),
            "output_zero_point": int(q["output"]["zero_point"]),
            "output_scale": float(q["output"]["scale"]),
            "multiplier": int(q["multiplier"]), "shift": int(q["shift"]),
            "weight_offset": weight_offset, "weight_bytes": weight_bytes,
            "bias_offset": bias_offset, "bias_bytes": bias_bytes,
            "lut_offset": lut_offset, "lut_bytes": lut_bytes,
            "source_weight_sha256": files["weight_raw_oihw_s8"]["sha256"],
            "kco_weight_sha256": hashlib.sha256(weight_kco).hexdigest(),
        })
    _align(params)
    params_path = output / "coco80_cpu_params_kco.bin"
    params_path.write_bytes(params)

    index_path = args.input_index.resolve()
    index = json.loads(index_path.read_text(encoding="utf-8"))
    entries = index.get("entries")
    record = entries[int(args.record_index)]
    package = record["package"]
    shard = index_path.parent / package["path"]
    with shard.open("rb") as stream:
        stream.seek(int(package["offset"]) + int(package["payload_offset"]))
        input_payload = stream.read(int(package["payload_bytes"]))
    if len(input_payload) != INPUT_BYTES or (zlib.crc32(input_payload) & 0xFFFFFFFF) != int(package["payload_crc32"]):
        raise ValueError("input payload failed size/CRC validation")
    input_path = output / "coco80_cpu_input_u8.bin"
    input_path.write_bytes(input_payload)

    raw_package = args.raw_heads.resolve().read_bytes()
    if len(raw_package) != 128 + P4_BYTES + P5_BYTES:
        raise ValueError("raw-head package has the wrong size")
    expected_heads = raw_package[128:]
    heads_path = output / "coco80_cpu_expected_heads_u8.bin"
    heads_path.write_bytes(expected_heads)

    letterbox = record["letterbox"]
    header_path = output / "coco80_cpu_generated.h"
    lines = [
        "#ifndef COCO80_CPU_GENERATED_H", "#define COCO80_CPU_GENERATED_H", "",
        "#include \"coco80_cpu_conv.h\"", "", "#include <stdint.h>", "",
        f"#define COCO80_CPU_PARAM_BYTES {len(params)}U",
        f"#define COCO80_CPU_PARAM_CRC32 0x{zlib.crc32(params) & 0xFFFFFFFF:08x}U",
        f"#define COCO80_CPU_INPUT_CRC32 0x{zlib.crc32(input_payload) & 0xFFFFFFFF:08x}U",
        f"#define COCO80_CPU_EXPECTED_HEADS_CRC32 0x{zlib.crc32(expected_heads) & 0xFFFFFFFF:08x}U",
        f"#define COCO80_CPU_IMAGE_ID {int(record['image_id'])}U", "",
        "static const coco80_cpu_layer_t coco80_cpu_layers[COCO80_CPU_LAYER_COUNT] = {",
    ]
    for layer in generated_layers:
        ih, iw, ic = layer["ifm"]; oh, ow, oc = layer["ofm"]
        lines.append(
            f'    {{"{layer["name"]}", {ih}U, {iw}U, {ic}U, {oh}U, {ow}U, {oc}U, '
            f'{layer["kernel"]}U, 1U, {layer["pad"]}U, '
            f'{layer["input_zero_point"]}U, {layer["output_zero_point"]}U, '
            f'{layer["multiplier"]}U, {layer["shift"]}U, '
            f'{layer["weight_offset"]}U, {layer["weight_bytes"]}U, '
            f'{layer["bias_offset"]}U, {layer["bias_bytes"]}U, '
            f'{layer["lut_offset"]}U, {layer["lut_bytes"]}U}},'
        )
    lines.extend([
        "};", "",
        f"#define COCO80_CPU_P4_SCALE {_c_float(generated_layers[11]['output_scale'])}",
        f"#define COCO80_CPU_P4_ZERO_POINT {generated_layers[11]['output_zero_point']}",
        f"#define COCO80_CPU_P5_SCALE {_c_float(generated_layers[12]['output_scale'])}",
        f"#define COCO80_CPU_P5_ZERO_POINT {generated_layers[12]['output_zero_point']}",
        "#define COCO80_CPU_ROUTE_INPUT_ZERO_POINT 19",
        "#define COCO80_CPU_ROUTE_OUTPUT_ZERO_POINT 16",
        "#define COCO80_CPU_ROUTE_MULTIPLIER 1474574406U",
        "#define COCO80_CPU_ROUTE_SHIFT 30U", "",
        f"#define COCO80_CPU_ORIGINAL_WIDTH {int(letterbox['source_width'])}U",
        f"#define COCO80_CPU_ORIGINAL_HEIGHT {int(letterbox['source_height'])}U",
        f"#define COCO80_CPU_LETTERBOX_SCALE {_c_float(float(letterbox['scale']))}",
        f"#define COCO80_CPU_PAD_X {_c_float(float(letterbox['pad_left']))}",
        f"#define COCO80_CPU_PAD_Y {_c_float(float(letterbox['pad_top']))}",
        "", "#endif", "",
    ])
    header_path.write_text("\n".join(lines), encoding="utf-8", newline="\n")

    manifest = {
        "format": "kv260-coco80-a53-baseline-package", "version": 1,
        "quantization_manifest": {"path": str(quant_path), "sha256": _sha256(quant_path)},
        "input_index": {"path": str(index_path), "sha256": _sha256(index_path), "record_index": int(args.record_index)},
        "raw_heads_source": {"path": str(args.raw_heads.resolve()), "sha256": _sha256(args.raw_heads.resolve())},
        "image_id": int(record["image_id"]), "layers": generated_layers,
        "files": {
            "params": {"path": params_path.name, "bytes": len(params), "sha256": _sha256(params_path), "crc32": zlib.crc32(params) & 0xFFFFFFFF},
            "input": {"path": input_path.name, "bytes": len(input_payload), "sha256": _sha256(input_path), "crc32": zlib.crc32(input_payload) & 0xFFFFFFFF},
            "expected_heads": {"path": heads_path.name, "bytes": len(expected_heads), "sha256": _sha256(heads_path), "crc32": zlib.crc32(expected_heads) & 0xFFFFFFFF},
            "header": {"path": header_path.name, "bytes": header_path.stat().st_size, "sha256": _sha256(header_path)},
        },
    }
    manifest_path = output / "coco80_cpu_baseline_package.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"manifest": str(manifest_path), "params_bytes": len(params), "image_id": record["image_id"]}, sort_keys=True))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--quant-manifest", type=Path, required=True)
    parser.add_argument("--input-index", type=Path, required=True)
    parser.add_argument("--record-index", type=int, default=0)
    parser.add_argument("--raw-heads", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    build(parser.parse_args())


if __name__ == "__main__":
    main()

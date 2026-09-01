#!/usr/bin/env python3
"""Build the ABI-v2 COUT32 bias/weight DDR images from repository fixtures."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path
from typing import Any


ROWS = 18
COLS = 16
COUT_TILE = 32
BIAS_PACKET_BYTES = COUT_TILE * 4
WEIGHT_PACKET_BYTES = ROWS * COUT_TILE
ALIGNMENT = 64
TILE_H_MAX = (2, 4, 8, 8, 8, 8, 8, 13, 8, 13)
EXPECTED_CONTEXTS = (416, 416, 416, 896, 2048, 4096, 16384, 456, 4096, 29)
EXPECTED_BIAS_BYTES = 61_824
EXPECTED_WEIGHT_BYTES = 16_849_728


def sha256_bytes(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def align_up(value: int, alignment: int = ALIGNMENT) -> int:
    return (value + alignment - 1) // alignment * alignment


def load_layer_manifests(model_root: Path) -> list[tuple[Path, dict[str, Any]]]:
    indexed: dict[int, tuple[Path, dict[str, Any]]] = {}
    for path in model_root.glob("*/manifest.json"):
        metadata = json.loads(path.read_text(encoding="utf-8"))
        index = int(metadata["infer_index"])
        if index in indexed:
            raise RuntimeError(f"duplicate infer_index {index}: {path}")
        indexed[index] = (path.parent, metadata)
    missing = [index for index in range(10) if index not in indexed]
    if missing:
        raise RuntimeError(f"missing layer manifests for infer_index {missing}")
    return [indexed[index] for index in range(10)]


def read_exact(path: Path, expected_bytes: int) -> bytes:
    data = path.read_bytes()
    if len(data) != expected_bytes:
        raise RuntimeError(
            f"{path} has {len(data)} bytes, expected {expected_bytes}"
        )
    return data


def build_bias_tile(raw_bias: bytes, cout: int, cout_blocks: int) -> bytes:
    output = bytearray()
    for block in range(cout_blocks):
        cout_base = block * COUT_TILE
        for lane in range(COUT_TILE):
            channel = cout_base + lane
            output.extend(
                raw_bias[channel * 4 : channel * 4 + 4]
                if channel < cout
                else b"\x00\x00\x00\x00"
            )
    return bytes(output)


def build_weight_tile(
    raw_oihw: bytes,
    cin: int,
    cout: int,
    kernel: int,
    k_passes: int,
    cout_blocks: int,
) -> bytes:
    output = bytearray()
    kernel_area = kernel * kernel
    k_total = cin * kernel_area
    for block in range(cout_blocks):
        cout_base = block * COUT_TILE
        for k_pass in range(k_passes):
            k_base = k_pass * ROWS
            for row in range(ROWS):
                gk = k_base + row
                for lane in range(COUT_TILE):
                    channel_out = cout_base + lane
                    if gk < k_total and channel_out < cout:
                        channel_in = gk // kernel_area
                        kernel_index = gk % kernel_area
                        source = (
                            (channel_out * cin + channel_in) * kernel_area
                            + kernel_index
                        )
                        output.append(raw_oihw[source])
                    else:
                        output.append(0)
    return bytes(output)


def add_aligned_section(package: bytearray, payload: bytes) -> int:
    offset = align_up(len(package))
    package.extend(b"\x00" * (offset - len(package)))
    package.extend(payload)
    return offset


def emit_binding_header(path: Path, manifest: dict[str, Any]) -> None:
    bias = manifest["files"]["bias"]
    weight = manifest["files"]["weight"]
    layers = manifest["layers"]
    lines = [
        "#ifndef ACCEL_V2_PARAMETER_PACKAGE_H",
        "#define ACCEL_V2_PARAMETER_PACKAGE_H",
        "",
        "#include <stdint.h>",
        "",
        f"#define ACCEL_V2_PARAMETER_PACKAGE_VERSION {manifest['version']}U",
        f"#define ACCEL_V2_PARAMETER_PACKAGE_ALIGNMENT {ALIGNMENT}U",
        f"#define ACCEL_V2_PARAMETER_LAYER_COUNT {len(layers)}U",
        f"#define ACCEL_V2_BIAS_PACKAGE_BYTES {bias['file_bytes']}U",
        f"#define ACCEL_V2_WEIGHT_PACKAGE_BYTES {weight['file_bytes']}U",
        f'#define ACCEL_V2_BIAS_PACKAGE_SHA256 "{bias["sha256"]}"',
        f'#define ACCEL_V2_WEIGHT_PACKAGE_SHA256 "{weight["sha256"]}"',
        "",
        "typedef struct {",
        "    uint32_t bias_offset;",
        "    uint32_t bias_bytes;",
        "    uint32_t weight_offset;",
        "    uint32_t weight_bytes;",
        "    uint32_t bias_packets;",
        "    uint32_t weight_packets;",
        "} accel_v2_parameter_layer_t;",
        "",
        f"static const accel_v2_parameter_layer_t accel_v2_parameter_layers[{len(layers)}] = {{",
    ]
    for layer in layers:
        lines.append(
            "    {%dU, %dU, %dU, %dU, %dU, %dU},"
            % (
                layer["bias"]["offset"],
                layer["bias"]["bytes"],
                layer["weight"]["offset"],
                layer["weight"]["bytes"],
                layer["bias"]["packets"],
                layer["weight"]["packets"],
            )
        )
    lines.extend(["};", "", "#endif", ""])
    path.write_text("\n".join(lines), encoding="ascii", newline="\n")


def generate_package(model_root: Path, output_dir: Path) -> dict[str, Any]:
    layers = load_layer_manifests(model_root)
    bias_package = bytearray()
    weight_package = bytearray()
    layer_entries: list[dict[str, Any]] = []

    for index, (layer_dir, metadata) in enumerate(layers):
        ifm_h, ifm_w, cin = (int(value) for value in metadata["shape"]["ifm_hwc"])
        conv_h, conv_w, cout = (
            int(value) for value in metadata["shape"]["conv_ofm_hwc"]
        )
        kernel = int(metadata["conv"]["kernel"])
        k_total = cin * kernel * kernel
        k_passes = (k_total + ROWS - 1) // ROWS
        cout_blocks = (cout + COUT_TILE - 1) // COUT_TILE
        tile_count = (conv_h + TILE_H_MAX[index] - 1) // TILE_H_MAX[index]
        bias_packets = tile_count * cout_blocks
        weight_packets = bias_packets * k_passes

        raw_bias = read_exact(layer_dir / "bias_i32.bin", cout * 4)
        raw_weight = read_exact(
            layer_dir / "weight_raw_oihw_s8.bin",
            cout * cin * kernel * kernel,
        )
        bias_tile = build_bias_tile(raw_bias, cout, cout_blocks)
        weight_tile = build_weight_tile(
            raw_weight, cin, cout, kernel, k_passes, cout_blocks
        )
        bias_payload = bias_tile * tile_count
        weight_payload = weight_tile * tile_count

        if len(bias_payload) != bias_packets * BIAS_PACKET_BYTES:
            raise RuntimeError(f"{layer_dir.name}: bias packet size mismatch")
        if len(weight_payload) != weight_packets * WEIGHT_PACKET_BYTES:
            raise RuntimeError(f"{layer_dir.name}: weight packet size mismatch")
        if weight_packets != EXPECTED_CONTEXTS[index]:
            raise RuntimeError(
                f"{layer_dir.name}: contexts {weight_packets}, "
                f"expected {EXPECTED_CONTEXTS[index]}"
            )

        bias_offset = add_aligned_section(bias_package, bias_payload)
        weight_offset = add_aligned_section(weight_package, weight_payload)
        layer_entries.append(
            {
                "index": index,
                "name": metadata["name"],
                "shape": {
                    "ifm_hwc": [ifm_h, ifm_w, cin],
                    "conv_ofm_hwc": [conv_h, conv_w, cout],
                    "kernel": kernel,
                    "k_total": k_total,
                    "k_passes": k_passes,
                    "cout_blocks": cout_blocks,
                    "tile_h_max": TILE_H_MAX[index],
                    "tile_count": tile_count,
                },
                "bias": {
                    "offset": bias_offset,
                    "bytes": len(bias_payload),
                    "packets": bias_packets,
                    "sha256": sha256_bytes(bias_payload),
                },
                "weight": {
                    "offset": weight_offset,
                    "bytes": len(weight_payload),
                    "packets": weight_packets,
                    "sha256": sha256_bytes(weight_payload),
                },
            }
        )

    bias_payload_bytes = sum(layer["bias"]["bytes"] for layer in layer_entries)
    weight_payload_bytes = sum(layer["weight"]["bytes"] for layer in layer_entries)
    if bias_payload_bytes != EXPECTED_BIAS_BYTES:
        raise RuntimeError(
            f"bias payload total {bias_payload_bytes}, expected {EXPECTED_BIAS_BYTES}"
        )
    if weight_payload_bytes != EXPECTED_WEIGHT_BYTES:
        raise RuntimeError(
            f"weight payload total {weight_payload_bytes}, "
            f"expected {EXPECTED_WEIGHT_BYTES}"
        )
    if any(
        layer[kind]["offset"] % ALIGNMENT != 0
        for layer in layer_entries
        for kind in ("bias", "weight")
    ):
        raise RuntimeError("a layer package section is not 64-byte aligned")

    output_dir.mkdir(parents=True, exist_ok=True)
    bias_name = "abi_v2_bias_cout32.bin"
    weight_name = "abi_v2_weight_cout32.bin"
    (output_dir / bias_name).write_bytes(bias_package)
    (output_dir / weight_name).write_bytes(weight_package)
    manifest: dict[str, Any] = {
        "format": "kv260-accelerator-abi-v2-parameters",
        "version": 1,
        "array": {"rows": ROWS, "cols": COLS, "cout_tile": COUT_TILE},
        "alignment_bytes": ALIGNMENT,
        "packet_bytes": {
            "bias": BIAS_PACKET_BYTES,
            "weight": WEIGHT_PACKET_BYTES,
        },
        "files": {
            "bias": {
                "path": bias_name,
                "payload_bytes": bias_payload_bytes,
                "file_bytes": len(bias_package),
                "sha256": sha256_bytes(bias_package),
            },
            "weight": {
                "path": weight_name,
                "payload_bytes": weight_payload_bytes,
                "file_bytes": len(weight_package),
                "sha256": sha256_bytes(weight_package),
            },
        },
        "layers": layer_entries,
    }
    manifest_path = output_dir / "abi_v2_parameter_manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    emit_binding_header(output_dir / "accel_v2_parameter_package.h", manifest)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate the aligned ABI-v2 COUT32 bias/weight DDR package."
    )
    parser.add_argument(
        "--model-root",
        type=Path,
        default=Path("repro/model"),
        help="repository single-scale model fixture directory",
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    manifest = generate_package(args.model_root.resolve(), args.output_dir.resolve())
    print(
        "Wrote ABI v2 parameter package: "
        f"bias={manifest['files']['bias']['payload_bytes']} B, "
        f"weight={manifest['files']['weight']['payload_bytes']} B"
    )


if __name__ == "__main__":
    main()

"""Generate the exact legacy A0 IFM DMA stream for representative layers."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Sequence

from .assets import sha256_file, write_json_atomic


ROWS = 18
COUT_TILE = 32
IFM_BANKS = 2
FORMAT = "kv260-lasa-a0-prepacked-ifm"
VERSION = 1


class PrepackError(RuntimeError):
    pass


def _ceil_div(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


def _layer(model_spec: Path, name: str) -> dict[str, Any]:
    value = json.loads(model_spec.read_text(encoding="utf-8-sig"))
    layers = [item for item in value.get("conv_layers", []) if item.get("name") == name]
    if value.get("format") != "kv260-coco80-yolov3-tiny-dag" or len(layers) != 1:
        raise PrepackError("model spec/layer identity mismatch")
    return layers[0]


def _channel_for_bank(cin: int, k_base: int, bank: int) -> int | None:
    for channel in range(cin):
        if (channel % IFM_BANKS == bank and k_base < (channel + 1) * 9
                and k_base + ROWS > channel * 9):
            return channel
    return None


def pack_legacy_ifm(
    raw_hwc: bytes, *, height: int, width: int, channels: int,
    output_channels: int, kernel: int, pad: int, tile_h: int,
    input_zero_point: int,
) -> tuple[bytes, list[dict[str, int]]]:
    expected = height * width * channels
    if len(raw_hwc) != expected:
        raise PrepackError(f"raw HWC bytes={len(raw_hwc)}, expected={expected}")
    if kernel not in (1, 3) or pad not in (0, 1) or not 0 <= input_zero_point <= 127:
        raise PrepackError("unsupported layer/prepack geometry")
    if tile_h <= 0 or tile_h > height:
        raise PrepackError("invalid tile height")
    k_total = channels * kernel * kernel
    passes = _ceil_div(k_total, ROWS)
    blocks = _ceil_div(output_channels, COUT_TILE)
    stream = bytearray()
    tiles: list[dict[str, int]] = []
    for tile_index, base_y in enumerate(range(0, height, tile_h)):
        active_h = min(tile_h, height - base_y)
        base_stream = bytearray()
        if kernel == 1:
            for k_pass in range(passes):
                k_base = k_pass * ROWS
                for y in range(base_y, base_y + active_h):
                    for x in range(width):
                        pixel = (y * width + x) * channels
                        vector = bytearray()
                        for lane in range(24):
                            channel = k_base + lane
                            vector.append(
                                raw_hwc[pixel + channel]
                                if lane < ROWS and channel < channels
                                else input_zero_point
                            )
                        base_stream.extend(vector)
            packets = passes * active_h * width * blocks
        else:
            first_y = max(0, base_y - pad)
            last_y = min(height - 1, base_y + active_h - 1 + pad)
            for k_pass in range(passes):
                k_base = k_pass * ROWS
                selected = tuple(
                    _channel_for_bank(channels, k_base, bank)
                    for bank in range(IFM_BANKS)
                )
                for y in range(first_y, last_y + 1):
                    for x in range(width):
                        pixel = (y * width + x) * channels
                        word = bytearray(8)
                        for bank, channel in enumerate(selected):
                            if channel is not None:
                                word[bank] = raw_hwc[pixel + channel]
                        base_stream.extend(word)
            packets = passes * (last_y - first_y + 1) * blocks
        offset = len(stream)
        for _ in range(blocks):
            stream.extend(base_stream)
        tiles.append({
            "tile_index": tile_index, "base_y": base_y, "height": active_h,
            "offset": offset, "bytes": len(base_stream) * blocks,
            "packets": packets, "k_passes": passes, "cout_blocks": blocks,
        })
    return bytes(stream), tiles


def run(args: argparse.Namespace) -> dict[str, Any]:
    layer = _layer(args.model_spec, args.layer)
    height, width, channels = (int(value) for value in layer["ifm_hwc"])
    output_channels = int(layer["ofm_hwc"][2])
    raw = args.input.read_bytes()
    packed, tiles = pack_legacy_ifm(
        raw, height=height, width=width, channels=channels,
        output_channels=output_channels, kernel=int(layer["kernel"]),
        pad=int(layer["pad"]), tile_h=int(layer["tile_h"]),
        input_zero_point=args.input_zero_point,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(packed)
    result = {
        "format": FORMAT, "version": VERSION, "status": "PASS",
        "layer": args.layer, "image_id": args.image_id,
        "input": {"path": str(args.input.resolve()), "bytes": len(raw),
                  "sha256": sha256_file(args.input)},
        "output": {"path": str(args.output.resolve()), "bytes": len(packed),
                   "sha256": sha256_file(args.output)},
        "geometry": {"height": height, "width": width, "channels": channels,
                     "output_channels": output_channels,
                     "kernel": int(layer["kernel"]), "pad": int(layer["pad"]),
                     "tile_h": int(layer["tile_h"]), "rows": ROWS,
                     "cout_tile": COUT_TILE, "input_zero_point": args.input_zero_point},
        "tiles": tiles,
    }
    write_json_atomic(args.manifest, result)
    return result


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-spec", type=Path, required=True)
    parser.add_argument("--layer", choices=("m0", "m13", "m19", "p4_detect"), required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--input-zero-point", type=int, required=True)
    parser.add_argument("--image-id", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        result = run(args)
    except (OSError, ValueError, KeyError, json.JSONDecodeError, PrepackError) as exc:
        print(f"FAIL: {exc}")
        return 1
    print(json.dumps({"status": "PASS", "layer": result["layer"],
                      "bytes": result["output"]["bytes"]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

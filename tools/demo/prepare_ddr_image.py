import argparse
import json
import struct
from pathlib import Path

import numpy as np
from PIL import Image


MODEL_SIZE = 416
FILL_VALUE = 114
INPUT_SCALE = 0.007874015718698502
INPUT_ZERO_POINT = 0
PACKAGE_MAGIC = 0x4F4C4F59
PACKAGE_VERSION = 1
PACKAGE_HEADER_BYTES = 64
PACKAGE_HEADER = struct.Struct("<6I3fI24x")


def fnv1a32(data):
    value = 2166136261
    for byte in data:
        value ^= byte
        value = (value * 16777619) & 0xFFFFFFFF
    return value


def letterbox_rgb(image, size=MODEL_SIZE, fill=FILL_VALUE):
    original_w, original_h = image.size
    scale = min(size / original_w, size / original_h)
    resized_w = int(round(original_w * scale))
    resized_h = int(round(original_h * scale))
    resized = image.resize((resized_w, resized_h), Image.Resampling.BILINEAR)
    output = Image.new("RGB", (size, size), (fill, fill, fill))
    pad_x = (size - resized_w) // 2
    pad_y = (size - resized_h) // 2
    output.paste(resized, (pad_x, pad_y))
    return output, {
        "original_width": original_w,
        "original_height": original_h,
        "model_size": size,
        "scale": scale,
        "resized_width": resized_w,
        "resized_height": resized_h,
        "pad_x": pad_x,
        "pad_y": pad_y,
        "fill": fill,
    }


def quantize_rgb(rgb):
    normalized = rgb.astype(np.float64) / 255.0
    quantized = np.rint(normalized / INPUT_SCALE + INPUT_ZERO_POINT)
    return np.clip(quantized, 0, 255).astype(np.uint8)


def prepare_image(image_path, package_path, metadata_path, preview_path):
    image = Image.open(image_path).convert("RGB")
    letterboxed, letterbox = letterbox_rgb(image)
    tensor = np.ascontiguousarray(quantize_rgb(np.asarray(letterboxed)))
    tensor_bytes = tensor.tobytes()
    checksum = fnv1a32(tensor_bytes)
    header = PACKAGE_HEADER.pack(
        PACKAGE_MAGIC,
        PACKAGE_VERSION,
        PACKAGE_HEADER_BYTES,
        len(tensor_bytes),
        letterbox["original_width"],
        letterbox["original_height"],
        letterbox["scale"],
        float(letterbox["pad_x"]),
        float(letterbox["pad_y"]),
        checksum,
    )
    if len(header) != PACKAGE_HEADER_BYTES:
        raise RuntimeError(f"Unexpected package header size: {len(header)}")

    package_path.parent.mkdir(parents=True, exist_ok=True)
    package_path.write_bytes(header + tensor_bytes)
    letterboxed.save(preview_path)
    metadata = {
        "image": str(image_path.resolve()),
        "package": str(package_path.resolve()),
        "package_address": "0x10000000",
        "package_bytes": PACKAGE_HEADER_BYTES + len(tensor_bytes),
        "tensor_layout": "HWC RGB uint8",
        "tensor_shape": [MODEL_SIZE, MODEL_SIZE, 3],
        "tensor_bytes": len(tensor_bytes),
        "tensor_checksum_fnv1a32": f"0x{checksum:08X}",
        "input_quant": {
            "scale": INPUT_SCALE,
            "zero_point": INPUT_ZERO_POINT,
            "formula": "round((rgb_u8 / 255) / scale + zero_point)",
        },
        "letterbox": letterbox,
        "letterbox_preview": str(preview_path.resolve()),
    }
    metadata_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    return metadata


def main():
    parser = argparse.ArgumentParser(
        description="Prepare a runtime DDR image package for the KV260 Conv0-Conv9 demo."
    )
    parser.add_argument("image", type=Path)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--preview", type=Path, required=True)
    args = parser.parse_args()

    metadata = prepare_image(args.image, args.package, args.metadata, args.preview)
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()

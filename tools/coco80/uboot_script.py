"""Create and verify deterministic U-Boot legacy script images."""

from __future__ import annotations

import argparse
import binascii
import struct
from pathlib import Path


MAGIC = 0x27051956
HEADER_BYTES = 64
OS_LINUX = 5
ARCH_ARM64 = 22
TYPE_SCRIPT = 6
COMP_NONE = 0


class UBootScriptError(ValueError):
    pass


def _crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def build_image(script: bytes, name: str = "KV260 COCO80 r5 boot") -> bytes:
    if not script or b"\x00" in script:
        raise UBootScriptError("script must be non-empty text without NUL bytes")
    name_bytes = name.encode("ascii", "strict")
    if not name_bytes or len(name_bytes) > 32:
        raise UBootScriptError("image name must contain 1..32 ASCII bytes")
    padding = bytes((-len(script)) & 3)
    payload = struct.pack(">II", len(script), 0) + script + padding
    header = bytearray(
        struct.pack(
            ">7I4B32s",
            MAGIC,
            0,
            0,
            len(payload),
            0,
            0,
            _crc32(payload),
            OS_LINUX,
            ARCH_ARM64,
            TYPE_SCRIPT,
            COMP_NONE,
            name_bytes.ljust(32, b"\x00"),
        )
    )
    struct.pack_into(">I", header, 4, _crc32(header))
    return bytes(header) + payload


def verify_image(image: bytes, expected_script: bytes | None = None) -> bytes:
    if len(image) < HEADER_BYTES + 8:
        raise UBootScriptError("legacy image is truncated")
    fields = struct.unpack(">7I4B32s", image[:HEADER_BYTES])
    magic, header_crc, timestamp, payload_bytes, load, entry, data_crc = fields[:7]
    os_id, arch, image_type, compression = fields[7:11]
    if magic != MAGIC or timestamp != 0 or load != 0 or entry != 0:
        raise UBootScriptError("legacy image header contract mismatch")
    if (os_id, arch, image_type, compression) != (
        OS_LINUX,
        ARCH_ARM64,
        TYPE_SCRIPT,
        COMP_NONE,
    ):
        raise UBootScriptError("legacy image type contract mismatch")
    header = bytearray(image[:HEADER_BYTES])
    struct.pack_into(">I", header, 4, 0)
    if _crc32(header) != header_crc:
        raise UBootScriptError("legacy image header CRC mismatch")
    payload = image[HEADER_BYTES:]
    if len(payload) != payload_bytes or _crc32(payload) != data_crc:
        raise UBootScriptError("legacy image payload length or CRC mismatch")
    script_bytes, terminator = struct.unpack(">II", payload[:8])
    if terminator != 0 or script_bytes == 0 or script_bytes > len(payload) - 8:
        raise UBootScriptError("legacy script table is invalid")
    script = payload[8:8 + script_bytes]
    if any(payload[8 + script_bytes:]):
        raise UBootScriptError("legacy script padding is non-zero")
    if expected_script is not None and script != expected_script:
        raise UBootScriptError("legacy image script differs from expected input")
    return script


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--name", default="KV260 COCO80 r5 boot")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    source = args.input.read_bytes()
    if args.verify:
        verify_image(args.output.read_bytes(), source)
        return
    image = build_image(source, args.name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    verify_image(args.output.read_bytes(), source)


if __name__ == "__main__":
    main()

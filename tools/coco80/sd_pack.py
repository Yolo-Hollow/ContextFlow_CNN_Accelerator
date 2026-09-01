"""Streaming host tools for the 128-byte COCO80 SD wire protocol.

The wire contract is owned by ``sw/vitis_2022_2/src/coco80_sd_protocol.h``.
Every field is a little-endian uint32, every package is individually bounded
by that 32-bit ABI, and large data sets are represented by many packages plus
an atomic JSON index.  File payloads, CRC32 checks, SHA256 checks, and copies
are all streamed so a collection larger than 2 GiB is never materialized in
memory.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import struct
import sys
import tempfile
from typing import Any, Iterable, Iterator, Mapping, Sequence
import zlib

from .assets import sha256_file, write_json_atomic
from .common import COCO80_TO_COCO91
from .preprocess import letterbox_416


UINT32_MAX = (1 << 32) - 1
UINT64_MAX = (1 << 64) - 1
HEADER_BYTES = 128
HEADER_WORDS = 32
PROTOCOL_VERSION = 1
DETECTION_RECORD_BYTES = 64
PARAMETER_LAYER_COUNT = 13
MODEL_WIDTH = 416
MODEL_HEIGHT = 416
CLASS_COUNT = 80
INPUT_CHANNELS = 3
INPUT_ROW_BYTES = MODEL_WIDTH * INPUT_CHANNELS
INPUT_TENSOR_BYTES = MODEL_WIDTH * MODEL_HEIGHT * INPUT_CHANNELS
INPUT_QUANT_MIN = 0
INPUT_QUANT_MAX = 127
VALUES_PER_ANCHOR = 85
ANCHORS_PER_HEAD = 3
HEAD_COUNT = 2
HEAD_CHANNELS = VALUES_PER_ANCHOR * ANCHORS_PER_HEAD
P4_WIDTH = P4_HEIGHT = 26
P5_WIDTH = P5_HEIGHT = 13
P4_BYTES = P4_WIDTH * P4_HEIGHT * HEAD_CHANNELS
P5_BYTES = P5_WIDTH * P5_HEIGHT * HEAD_CHANNELS
P4_ANCHORS = P4_WIDTH * P4_HEIGHT * ANCHORS_PER_HEAD
TOTAL_ANCHORS = P4_ANCHORS + P5_WIDTH * P5_HEIGHT * ANCHORS_PER_HEAD
MAX_NMS = 30_000
MAX_DETECTIONS = 300
COPY_CHUNK_BYTES = 1024 * 1024


def _fourcc(text: str) -> int:
    if len(text) != 4 or not text.isascii():
        raise ValueError("FOURCC must contain exactly four ASCII characters")
    return int.from_bytes(text.encode("ascii"), "little")


MAGIC_INPUT = _fourcc("C8IN")
MAGIC_PARAMETERS = _fourcc("C8PA")
MAGIC_RAW_HEADS = _fourcc("C8RH")
MAGIC_DETECTIONS = _fourcc("C8DT")
MAGIC_RESULT = _fourcc("C8RS")
MAGIC_INPUT_INDEX = _fourcc("C8IX")
MAGIC_OUTPUT_INDEX = _fourcc("C8OX")
MAGIC_NODE_INDEX = _fourcc("C8NX")
MAGIC_NAMES = {
    MAGIC_INPUT: "input",
    MAGIC_PARAMETERS: "parameters",
    MAGIC_RAW_HEADS: "raw_heads",
    MAGIC_DETECTIONS: "detections",
    MAGIC_RESULT: "result",
}

_HEADER = struct.Struct("<32I")
_DETECTION = struct.Struct("<16I")
_INDEX_HEADER = struct.Struct("<32I")
_INDEX_SHARD = struct.Struct("<20I")
_INDEX_ENTRY = struct.Struct("<8I")
INDEX_HEADER_BYTES = _INDEX_HEADER.size
INDEX_SHARD_BYTES = _INDEX_SHARD.size
INDEX_ENTRY_BYTES = _INDEX_ENTRY.size
BINDING_WORDS = 15
BINDING_BYTES = PARAMETER_LAYER_COUNT * BINDING_WORDS * 4
OUTPUT_INDEX_HEADER = struct.Struct("<32I")
OUTPUT_INDEX_ENTRY = struct.Struct("<8I")
OUTPUT_INDEX_HEADER_BYTES = OUTPUT_INDEX_HEADER.size
OUTPUT_INDEX_ENTRY_BYTES = OUTPUT_INDEX_ENTRY.size
NODE_INDEX_HEADER = struct.Struct("<32I")
NODE_INDEX_ENTRY = struct.Struct("<6I")
NODE_TENSOR_COUNT = 22


class SdPackError(RuntimeError):
    """Raised when an SD package cannot be proven to match the wire ABI."""


@dataclass(frozen=True)
class Section:
    offset: int
    bytes: int
    crc32: int

    def to_dict(self) -> dict[str, int]:
        return {"offset": self.offset, "bytes": self.bytes, "crc32": self.crc32}


@dataclass(frozen=True)
class PackageHeader:
    path: Path
    words: tuple[int, ...]
    package_crc32: int
    sha256: str

    @property
    def magic(self) -> int:
        return self.words[0]

    @property
    def kind(self) -> str:
        return MAGIC_NAMES.get(self.magic, f"unknown-0x{self.magic:08x}")

    @property
    def total_bytes(self) -> int:
        return self.words[3]

    @property
    def payload_offset(self) -> int:
        return self.words[4]

    @property
    def payload_bytes(self) -> int:
        return self.words[5]

    @property
    def payload_crc32(self) -> int:
        return self.words[6]

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": str(self.path),
            "kind": self.kind,
            "magic": self.magic,
            "version": self.words[1],
            "header_bytes": self.words[2],
            "total_bytes": self.total_bytes,
            "payload_offset": self.payload_offset,
            "payload_bytes": self.payload_bytes,
            "payload_crc32": self.payload_crc32,
            "header_crc32": self.words[7],
            "package_crc32": self.package_crc32,
            "sha256": self.sha256,
        }


def _integer(value: Any, label: str, minimum: int = 0, maximum: int = UINT32_MAX) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise SdPackError(f"{label} must be an integer")
    if value < minimum or value > maximum:
        raise SdPackError(f"{label} must be in [{minimum}, {maximum}], got {value}")
    return value


def _f32_bits(value: Any, label: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SdPackError(f"{label} must be a finite number")
    number = float(value)
    if not math.isfinite(number) or (positive and number <= 0.0):
        qualifier = "positive and finite" if positive else "finite"
        raise SdPackError(f"{label} must be {qualifier}")
    try:
        return struct.unpack("<I", struct.pack("<f", number))[0]
    except OverflowError as exc:
        raise SdPackError(f"{label} is outside float32 range") from exc


def _bits_f32(value: int) -> float:
    return struct.unpack("<f", struct.pack("<I", value))[0]


def _sha_words(value: str, label: str) -> tuple[int, ...]:
    if not isinstance(value, str) or len(value) != 64:
        raise SdPackError(f"{label} must be a 64-character SHA256 hex digest")
    try:
        digest = bytes.fromhex(value)
    except ValueError as exc:
        raise SdPackError(f"{label} must be hexadecimal") from exc
    if digest == bytes(32):
        raise SdPackError(f"{label} must not be all zero")
    return struct.unpack("<8I", digest)


def _words_sha(words: Sequence[int]) -> str:
    if len(words) != 8:
        raise SdPackError("internal SHA word count mismatch")
    return struct.pack("<8I", *words).hex()


def _regular_file(path: str | Path, label: str = "file") -> Path:
    target = Path(path)
    if target.is_symlink():
        raise SdPackError(f"{label} must not be a symlink: {target}")
    if not target.is_file():
        raise SdPackError(f"{label} is not a regular file: {target}")
    return target


def _range(offset: int, size: int, total: int, label: str) -> None:
    if offset < 0 or size < 0 or offset > total or size > total - offset:
        raise SdPackError(
            f"{label} range [{offset}, {offset + size}) exceeds package size {total}"
        )


def crc32_file(
    path: str | Path,
    *,
    offset: int = 0,
    size: int | None = None,
    chunk_bytes: int = COPY_CHUNK_BYTES,
) -> int:
    """Return a standard CRC32 for a file range using bounded memory."""

    target = _regular_file(path)
    if isinstance(chunk_bytes, bool) or not isinstance(chunk_bytes, int) or chunk_bytes <= 0:
        raise ValueError("chunk_bytes must be a positive integer")
    total = target.stat().st_size
    if isinstance(offset, bool) or not isinstance(offset, int) or offset < 0:
        raise ValueError("offset must be a non-negative integer")
    selected = total - offset if size is None else size
    if isinstance(selected, bool) or not isinstance(selected, int) or selected < 0:
        raise ValueError("size must be a non-negative integer")
    _range(offset, selected, total, "CRC32")
    crc = 0
    remaining = selected
    with target.open("rb") as stream:
        stream.seek(offset)
        while remaining:
            chunk = stream.read(min(chunk_bytes, remaining))
            if not chunk:
                raise SdPackError(f"short read while checksumming {target}")
            crc = zlib.crc32(chunk, crc)
            remaining -= len(chunk)
    return crc & UINT32_MAX


def _sha256_concat(paths: Sequence[Path]) -> str:
    digest = hashlib.sha256()
    for path in paths:
        with _regular_file(path).open("rb") as stream:
            while True:
                chunk = stream.read(COPY_CHUNK_BYTES)
                if not chunk:
                    break
                digest.update(chunk)
    return digest.hexdigest()


def _sha256_file_range(path: Path, offset: int, size: int) -> str:
    total = _regular_file(path).stat().st_size
    _range(offset, size, total, "SHA256")
    digest = hashlib.sha256()
    remaining = size
    with path.open("rb") as stream:
        stream.seek(offset)
        while remaining:
            chunk = stream.read(min(COPY_CHUNK_BYTES, remaining))
            if not chunk:
                raise SdPackError(f"short read while hashing {path}")
            digest.update(chunk)
            remaining -= len(chunk)
    return digest.hexdigest()


def _header_crc(header: bytes) -> int:
    if len(header) != HEADER_BYTES:
        raise SdPackError("header must contain exactly 128 bytes")
    canonical = bytearray(header)
    canonical[28:32] = bytes(4)
    return zlib.crc32(canonical) & UINT32_MAX


def _check_magic(value: int | str | None) -> int | None:
    if value is None:
        return None
    if isinstance(value, str):
        if value in MAGIC_NAMES.values():
            return next(key for key, name in MAGIC_NAMES.items() if name == value)
        return _fourcc(value)
    return _integer(value, "magic")


def read_package_header(
    path: str | Path,
    expected_magic: int | str | None = None,
    *,
    verify_payload: bool = True,
) -> PackageHeader:
    """Parse and fail-closed validate the common 128-byte package header."""

    target = _regular_file(path, "package")
    file_bytes = target.stat().st_size
    if file_bytes < HEADER_BYTES or file_bytes > UINT32_MAX:
        raise SdPackError(f"package size {file_bytes} is outside the uint32 ABI")
    with target.open("rb") as stream:
        raw = stream.read(HEADER_BYTES)
    if len(raw) != HEADER_BYTES:
        raise SdPackError(f"short header in {target}")
    words = tuple(_HEADER.unpack(raw))
    wanted = _check_magic(expected_magic)
    if wanted is not None and words[0] != wanted:
        raise SdPackError(
            f"wrong package magic: expected 0x{wanted:08x}, got 0x{words[0]:08x}"
        )
    if words[0] not in MAGIC_NAMES:
        raise SdPackError(f"unknown package magic 0x{words[0]:08x}")
    if words[1] != PROTOCOL_VERSION:
        raise SdPackError(f"unsupported protocol version {words[1]}")
    if words[2] != HEADER_BYTES:
        raise SdPackError(f"header_bytes must be {HEADER_BYTES}, got {words[2]}")
    if words[3] != file_bytes:
        raise SdPackError(f"total_bytes {words[3]} does not match file size {file_bytes}")
    if words[4] != HEADER_BYTES or words[5] != file_bytes - HEADER_BYTES:
        raise SdPackError("payload offset/size does not cover the exact post-header bytes")
    if _header_crc(raw) != words[7]:
        raise SdPackError("header CRC32 mismatch")
    if verify_payload and crc32_file(target, offset=words[4], size=words[5]) != words[6]:
        raise SdPackError("payload CRC32 mismatch")
    return PackageHeader(
        path=target.resolve(),
        words=words,
        package_crc32=crc32_file(target),
        sha256=sha256_file(target),
    )


def _validate_section(
    package: PackageHeader,
    offset: int,
    size: int,
    crc32: int,
    label: str,
    *,
    allow_empty: bool = False,
) -> Section:
    payload_end = package.payload_offset + package.payload_bytes
    if size == 0:
        if not allow_empty or not package.payload_offset <= offset <= payload_end or crc32 != 0:
            raise SdPackError(f"invalid empty {label} section")
    else:
        if offset < package.payload_offset:
            raise SdPackError(f"{label} begins before payload")
        _range(offset, size, payload_end, label)
        if crc32_file(package.path, offset=offset, size=size) != crc32:
            raise SdPackError(f"{label} CRC32 mismatch")
    return Section(offset, size, crc32)


def _overlap(left: Section, right: Section) -> bool:
    if left.bytes == 0 or right.bytes == 0:
        return False
    return left.offset < right.offset + right.bytes and right.offset < left.offset + left.bytes


def _payload_size(source: bytes | bytearray | memoryview | Path) -> int:
    if isinstance(source, Path):
        return _regular_file(source, "payload").stat().st_size
    return len(source)


def _iter_payload(source: bytes | bytearray | memoryview | Path) -> Iterator[bytes]:
    if isinstance(source, Path):
        with _regular_file(source, "payload").open("rb") as stream:
            while True:
                chunk = stream.read(COPY_CHUNK_BYTES)
                if not chunk:
                    break
                yield chunk
    else:
        view = memoryview(source)
        for start in range(0, len(view), COPY_CHUNK_BYTES):
            yield bytes(view[start : start + COPY_CHUNK_BYTES])


def _write_package(
    destination: str | Path,
    magic: int,
    payloads: Sequence[tuple[str, bytes | bytearray | memoryview | Path]],
    make_words: Any,
) -> PackageHeader:
    """Atomically stream payloads, seal the header, and validate the result."""

    output = Path(destination)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w+b",
            prefix=f".{output.name}.",
            suffix=".tmp",
            dir=output.parent,
            delete=False,
        ) as stream:
            temporary = Path(stream.name)
            stream.write(bytes(HEADER_BYTES))
            payload_crc = 0
            sections: dict[str, Section] = {}
            cursor = HEADER_BYTES
            for name, source in payloads:
                declared = _payload_size(source)
                if declared > UINT32_MAX - cursor:
                    raise SdPackError(
                        f"package would exceed uint32 total_bytes while adding {name}"
                    )
                section_crc = 0
                written = 0
                for chunk in _iter_payload(source):
                    stream.write(chunk)
                    written += len(chunk)
                    section_crc = zlib.crc32(chunk, section_crc)
                    payload_crc = zlib.crc32(chunk, payload_crc)
                if written != declared:
                    raise SdPackError(f"payload {name} changed while it was copied")
                sections[name] = Section(cursor, written, section_crc & UINT32_MAX)
                cursor += written
            words = list(make_words(sections))
            if len(words) != HEADER_WORDS:
                raise SdPackError("header builder did not return 32 uint32 words")
            words[0:8] = [
                magic,
                PROTOCOL_VERSION,
                HEADER_BYTES,
                cursor,
                HEADER_BYTES,
                cursor - HEADER_BYTES,
                payload_crc & UINT32_MAX,
                0,
            ]
            for index, word in enumerate(words):
                _integer(word, f"header word {index}")
            header = bytearray(_HEADER.pack(*words))
            words[7] = _header_crc(header)
            header = _HEADER.pack(*words)
            stream.seek(0)
            stream.write(header)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, output)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return read_package_header(output, magic)


def _package_ref(value: str | Path | int, expected_magic: int, label: str) -> int:
    if isinstance(value, int) and not isinstance(value, bool):
        return _integer(value, label, 1)
    return read_package_header(value, expected_magic).package_crc32


def pack_input_tensor(
    tensor: bytes | bytearray | memoryview | str | Path,
    destination: str | Path,
    *,
    image_id: int,
    original_width: int,
    original_height: int,
    input_scale: float,
    input_zero_point: int,
    letterbox_scale: float,
    pad_x: int,
    pad_y: int,
    source_sha256: str,
) -> PackageHeader:
    """Wrap one fixed 416x416 HWC uint8 tensor as a ``C8IN`` package."""

    payload: bytes | bytearray | memoryview | Path
    payload = Path(tensor) if isinstance(tensor, (str, Path)) else tensor
    if _payload_size(payload) != INPUT_TENSOR_BYTES:
        raise SdPackError(f"input tensor must contain exactly {INPUT_TENSOR_BYTES} bytes")
    if isinstance(payload, Path):
        with payload.open("rb") as stream:
            for chunk in iter(lambda: stream.read(COPY_CHUNK_BYTES), b""):
                if chunk and max(chunk) > INPUT_QUANT_MAX:
                    raise SdPackError("input tensor exceeds the reduced uint8 range 0..127")
    elif payload and max(payload) > INPUT_QUANT_MAX:
        raise SdPackError("input tensor exceeds the reduced uint8 range 0..127")
    image_id = _integer(image_id, "image_id", 1)
    original_width = _integer(original_width, "original_width", 1)
    original_height = _integer(original_height, "original_height", 1)
    input_zero_point = _integer(input_zero_point, "input_zero_point", 0, 255)
    pad_x = _integer(pad_x, "pad_x", 0, MODEL_WIDTH // 2)
    pad_y = _integer(pad_y, "pad_y", 0, MODEL_HEIGHT // 2)
    source_words = _sha_words(source_sha256, "source_sha256")
    input_scale_bits = _f32_bits(input_scale, "input_scale", positive=True)
    letterbox_bits = _f32_bits(letterbox_scale, "letterbox_scale", positive=True)
    resized_width = original_width * _bits_f32(letterbox_bits)
    resized_height = original_height * _bits_f32(letterbox_bits)
    if not (0.5 <= resized_width <= MODEL_WIDTH + 0.5):
        raise SdPackError("letterbox resized width is outside the C validator tolerance")
    if not (0.5 <= resized_height <= MODEL_HEIGHT + 0.5):
        raise SdPackError("letterbox resized height is outside the C validator tolerance")
    if resized_width < MODEL_WIDTH - 0.5 and resized_height < MODEL_HEIGHT - 0.5:
        raise SdPackError("letterbox scale does not fill either model dimension")
    if not (MODEL_WIDTH - 1.5 <= resized_width + 2 * pad_x <= MODEL_WIDTH + 0.5):
        raise SdPackError("horizontal letterbox geometry is inconsistent")
    if not (MODEL_HEIGHT - 1.5 <= resized_height + 2 * pad_y <= MODEL_HEIGHT + 0.5):
        raise SdPackError("vertical letterbox geometry is inconsistent")

    def header(_: Mapping[str, Section]) -> list[int]:
        words = [0] * HEADER_WORDS
        words[8:22] = [
            image_id,
            MODEL_WIDTH,
            MODEL_HEIGHT,
            INPUT_CHANNELS,
            original_width,
            original_height,
            1,
            1,
            input_scale_bits,
            input_zero_point,
            letterbox_bits,
            _f32_bits(float(pad_x), "pad_x"),
            _f32_bits(float(pad_y), "pad_y"),
            INPUT_ROW_BYTES,
        ]
        words[22:30] = source_words
        return words

    return _write_package(destination, MAGIC_INPUT, [("tensor", payload)], header)


def pack_input_image(
    source_image: str | Path,
    destination: str | Path,
    *,
    image_id: int,
    input_scale: float,
    input_zero_point: int,
) -> dict[str, Any]:
    """Letterbox one image and atomically write its input package."""

    source = _regular_file(source_image, "source image")
    try:
        from PIL import Image
    except ImportError as exc:  # pragma: no cover - dependency-specific
        raise SdPackError("Pillow is required to build input packages") from exc
    input_scale_bits = _f32_bits(input_scale, "input_scale", positive=True)
    effective_scale = _bits_f32(input_scale_bits)
    input_zero_point = _integer(input_zero_point, "input_zero_point", 0, 127)
    quantize_table = [
        max(
            INPUT_QUANT_MIN,
            min(
                INPUT_QUANT_MAX,
                int(round((value / 255.0) / effective_scale)) + input_zero_point,
            ),
        )
        for value in range(256)
    ]
    with Image.open(source) as image:
        tensor, metadata = letterbox_416(image)
        payload = tensor.point(quantize_table * len(tensor.getbands())).tobytes()
    source_digest = sha256_file(source)
    package = pack_input_tensor(
        payload,
        destination,
        image_id=image_id,
        original_width=metadata.source_width,
        original_height=metadata.source_height,
        input_scale=input_scale,
        input_zero_point=input_zero_point,
        letterbox_scale=metadata.scale,
        pad_x=metadata.pad_left,
        pad_y=metadata.pad_top,
        source_sha256=source_digest,
    )
    return {
        "image_id": image_id,
        "source_name": source.name,
        "source_sha256": source_digest,
        "letterbox": metadata.to_dict(),
        "input_quant_range": [INPUT_QUANT_MIN, INPUT_QUANT_MAX],
        "tensor_min": min(payload),
        "tensor_max": max(payload),
        "package": package.to_dict(),
    }


def _image_record(value: Any) -> tuple[int, Path]:
    if isinstance(value, Mapping):
        image_id = value.get("image_id", value.get("id"))
        image_path = value.get("image_path", value.get("path"))
    elif isinstance(value, (tuple, list)) and len(value) == 2:
        image_id, image_path = value
    else:
        raise SdPackError("each image must be (image_id, path) or a mapping")
    return _integer(image_id, "image_id", 1), Path(image_path)


def build_input_packages(
    images: Iterable[Any],
    destination: str | Path,
    *,
    input_scale: float,
    input_zero_point: int,
    expected_count: int = 5000,
    index_name: str = "inputs.json",
) -> dict[str, Any]:
    """Build exactly ``expected_count`` input packages and an atomic index."""

    expected_count = _integer(expected_count, "expected_count", 1)
    root = Path(destination)
    package_root = root / "inputs"
    package_root.mkdir(parents=True, exist_ok=True)
    if PurePosixPath(index_name).name != index_name or index_name in {".", ".."}:
        raise SdPackError("index_name must be one plain relative filename")
    entries: list[dict[str, Any]] = []
    seen: set[int] = set()
    for raw in images:
        if len(entries) >= expected_count:
            raise SdPackError(f"image iterable contains more than {expected_count} entries")
        image_id, image_path = _image_record(raw)
        if image_id in seen:
            raise SdPackError(f"duplicate image_id {image_id}")
        seen.add(image_id)
        relative = PurePosixPath("inputs") / f"{image_id:012d}.bin"
        entry = pack_input_image(
            image_path,
            root.joinpath(*relative.parts),
            image_id=image_id,
            input_scale=input_scale,
            input_zero_point=input_zero_point,
        )
        entry["package"]["path"] = relative.as_posix()
        entries.append(entry)
    if len(entries) != expected_count:
        raise SdPackError(f"expected exactly {expected_count} images, got {len(entries)}")
    manifest: dict[str, Any] = {
        "schema": "coco80.sd-input-index.v1",
        "protocol_version": PROTOCOL_VERSION,
        "header_bytes": HEADER_BYTES,
        "image_count": expected_count,
        "model_shape_hwc": [MODEL_HEIGHT, MODEL_WIDTH, INPUT_CHANNELS],
        "input_scale": float(input_scale),
        "input_zero_point": input_zero_point,
        "input_quant_range": [INPUT_QUANT_MIN, INPUT_QUANT_MAX],
        "entries": entries,
    }
    write_json_atomic(root / index_name, manifest)
    return manifest


def _index_header_crc(raw: bytes) -> int:
    if len(raw) != INDEX_HEADER_BYTES:
        raise SdPackError("input index header must contain exactly 128 bytes")
    canonical = bytearray(raw)
    canonical[14 * 4 : 15 * 4] = bytes(4)
    return zlib.crc32(canonical) & UINT32_MAX


def _atomic_binary(path: Path, chunks: Iterable[bytes]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
            delete=False,
        ) as stream:
            temporary = Path(stream.name)
            for chunk in chunks:
                stream.write(chunk)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _write_input_binary_index(
    path: Path,
    shards: Sequence[Mapping[str, Any]],
    entries: Sequence[Mapping[str, Any]],
    source_set_sha256: str,
) -> dict[str, Any]:
    """Write the fixed-width little-endian table consumed by bare metal."""

    shard_table = bytearray()
    for expected_id, shard in enumerate(shards):
        shard_id = _integer(shard.get("shard_id"), "shard_id")
        if shard_id != expected_id:
            raise SdPackError("shard ids must be dense and ordered from zero")
        filename = shard.get("path")
        if not isinstance(filename, str):
            raise SdPackError("shard path must be a string")
        encoded = filename.encode("ascii", errors="strict")
        if len(encoded) > 16:
            raise SdPackError("bare-metal shard filename exceeds 16 ASCII bytes")
        name_words = struct.unpack("<4I", encoded.ljust(16, b"\0"))
        sha_words = _sha_words(shard.get("sha256"), "shard.sha256")
        words = [
            shard_id,
            _integer(shard.get("first_record"), "shard.first_record"),
            _integer(shard.get("record_count"), "shard.record_count", 1),
            _integer(shard.get("bytes"), "shard.bytes", 1, UINT32_MAX),
            _integer(shard.get("crc32"), "shard.crc32"),
            len(encoded),
            *name_words,
            *sha_words,
            0,
            0,
        ]
        shard_table.extend(_INDEX_SHARD.pack(*words))
    entry_table = bytearray()
    for expected_index, entry in enumerate(entries):
        if entry.get("record_index") != expected_index:
            raise SdPackError("input index records must be dense and ordered")
        package = entry.get("package")
        letterbox = entry.get("letterbox")
        if not isinstance(package, Mapping) or not isinstance(letterbox, Mapping):
            raise SdPackError("input index entry lacks package/letterbox metadata")
        entry_table.extend(
            _INDEX_ENTRY.pack(
                _integer(entry.get("image_id"), "entry.image_id", 1),
                _integer(entry.get("shard_id"), "entry.shard_id"),
                expected_index,
                _integer(entry.get("offset"), "entry.offset"),
                _integer(package.get("total_bytes"), "entry.package.total_bytes", 1),
                _integer(package.get("package_crc32"), "entry.package.package_crc32", 1),
                _integer(letterbox.get("source_width"), "entry.source_width", 1),
                _integer(letterbox.get("source_height"), "entry.source_height", 1),
            )
        )
    shards_offset = INDEX_HEADER_BYTES
    entries_offset = shards_offset + len(shard_table)
    total_bytes = entries_offset + len(entry_table)
    if total_bytes > UINT32_MAX:
        raise SdPackError("binary input index exceeds the uint32 ABI")
    content_sha = hashlib.sha256(shard_table + entry_table).hexdigest()
    words = [0] * HEADER_WORDS
    words[0:16] = [
        MAGIC_INPUT_INDEX,
        1,
        INDEX_HEADER_BYTES,
        total_bytes,
        len(entries),
        len(shards),
        INDEX_SHARD_BYTES,
        INDEX_ENTRY_BYTES,
        shards_offset,
        len(shard_table),
        entries_offset,
        len(entry_table),
        zlib.crc32(shard_table) & UINT32_MAX,
        zlib.crc32(entry_table) & UINT32_MAX,
        0,
        0,
    ]
    words[16:24] = _sha_words(content_sha, "index content SHA256")
    words[24:32] = _sha_words(source_set_sha256, "source set SHA256")
    raw_header = bytearray(_INDEX_HEADER.pack(*words))
    words[14] = _index_header_crc(raw_header)
    _atomic_binary(path, (_INDEX_HEADER.pack(*words), bytes(shard_table), bytes(entry_table)))
    return {
        "path": path.name,
        "bytes": path.stat().st_size,
        "crc32": crc32_file(path),
        "sha256": sha256_file(path),
        "content_sha256": content_sha,
        "source_set_sha256": source_set_sha256,
        "shard_record_bytes": INDEX_SHARD_BYTES,
        "entry_record_bytes": INDEX_ENTRY_BYTES,
    }


def parse_input_binary_index(path: str | Path) -> dict[str, Any]:
    """Validate the complete fixed-width input shard index."""

    target = _regular_file(path, "binary input index")
    total = target.stat().st_size
    if total < INDEX_HEADER_BYTES or total > UINT32_MAX:
        raise SdPackError("binary input index size is outside the ABI")
    with target.open("rb") as stream:
        raw_header = stream.read(INDEX_HEADER_BYTES)
        if len(raw_header) != INDEX_HEADER_BYTES:
            raise SdPackError("short binary input index header")
        w = _INDEX_HEADER.unpack(raw_header)
        if (
            w[0] != MAGIC_INPUT_INDEX
            or w[1] != 1
            or w[2] != INDEX_HEADER_BYTES
            or w[3] != total
            or w[4] == 0
            or w[5] == 0
            or w[6] != INDEX_SHARD_BYTES
            or w[7] != INDEX_ENTRY_BYTES
            or w[8] != INDEX_HEADER_BYTES
            or w[9] != w[5] * INDEX_SHARD_BYTES
            or w[10] != w[8] + w[9]
            or w[11] != w[4] * INDEX_ENTRY_BYTES
            or w[10] + w[11] != total
            or w[15] != 0
            or not any(w[16:24])
            or not any(w[24:32])
            or _index_header_crc(raw_header) != w[14]
        ):
            raise SdPackError("binary input index header is invalid")
        shard_table = stream.read(w[9])
        entry_table = stream.read(w[11])
    if len(shard_table) != w[9] or len(entry_table) != w[11]:
        raise SdPackError("binary input index tables are truncated")
    if zlib.crc32(shard_table) & UINT32_MAX != w[12]:
        raise SdPackError("binary input index shard-table CRC32 mismatch")
    if zlib.crc32(entry_table) & UINT32_MAX != w[13]:
        raise SdPackError("binary input index entry-table CRC32 mismatch")
    if hashlib.sha256(shard_table + entry_table).hexdigest() != _words_sha(w[16:24]):
        raise SdPackError("binary input index content SHA256 mismatch")
    shards: list[dict[str, Any]] = []
    for index in range(w[5]):
        row = _INDEX_SHARD.unpack_from(shard_table, index * INDEX_SHARD_BYTES)
        if row[0] != index or row[2] == 0 or row[3] == 0 or row[5] > 16 or any(row[18:20]):
            raise SdPackError(f"binary input shard record {index} is invalid")
        name_bytes = struct.pack("<4I", *row[6:10])
        if any(name_bytes[row[5] :]):
            raise SdPackError(f"binary input shard record {index} name padding is nonzero")
        try:
            name = name_bytes[: row[5]].decode("ascii")
        except UnicodeDecodeError as exc:
            raise SdPackError(f"binary input shard record {index} name is not ASCII") from exc
        shards.append(
            {
                "shard_id": row[0],
                "first_record": row[1],
                "record_count": row[2],
                "bytes": row[3],
                "crc32": row[4],
                "path": name,
                "sha256": _words_sha(row[10:18]),
            }
        )
    entries: list[dict[str, int]] = []
    expected_record = 0
    for shard in shards:
        if shard["first_record"] != expected_record:
            raise SdPackError("binary input shards do not cover a dense record range")
        expected_record += shard["record_count"]
    if expected_record != w[4]:
        raise SdPackError("binary input shard record counts do not match image_count")
    for index in range(w[4]):
        row = _INDEX_ENTRY.unpack_from(entry_table, index * INDEX_ENTRY_BYTES)
        if row[0] == 0 or row[1] >= w[5] or row[2] != index or row[4] < HEADER_BYTES or row[5] == 0:
            raise SdPackError(f"binary input entry {index} is invalid")
        shard = shards[row[1]]
        if row[2] < shard["first_record"] or row[2] >= shard["first_record"] + shard["record_count"]:
            raise SdPackError(f"binary input entry {index} is outside its shard record range")
        if row[3] > shard["bytes"] or row[4] > shard["bytes"] - row[3]:
            raise SdPackError(f"binary input entry {index} exceeds its shard")
        entries.append(
            {
                "image_id": row[0],
                "shard_id": row[1],
                "record_index": row[2],
                "offset": row[3],
                "bytes": row[4],
                "package_crc32": row[5],
                "original_width": row[6],
                "original_height": row[7],
            }
        )
    return {
        "schema": "coco80.sd-input-binary-index.v1",
        "path": str(target.resolve()),
        "bytes": total,
        "image_count": w[4],
        "shard_count": w[5],
        "shards": shards,
        "entries": entries,
        "content_sha256": _words_sha(w[16:24]),
        "source_set_sha256": _words_sha(w[24:32]),
        "crc32": crc32_file(target),
        "sha256": sha256_file(target),
    }


def build_input_shards(
    images: Iterable[Any],
    destination: str | Path,
    *,
    input_scale: float,
    input_zero_point: int,
    expected_count: int = 5000,
    shard_target_bytes: int = 1024 * 1024 * 1024,
    index_name: str = "input_index.bin",
    manifest_name: str = "input_index.json",
) -> dict[str, Any]:
    """Build a versioned shard set, binary table, and canonical JSON audit index.

    Each record inside a shard remains a complete, independently valid C8IN
    package.  Shards and package copies are streamed; only the small metadata
    tables are retained in memory.
    """

    expected_count = _integer(expected_count, "expected_count", 1)
    shard_target_bytes = _integer(
        shard_target_bytes, "shard_target_bytes", INPUT_TENSOR_BYTES + HEADER_BYTES, UINT32_MAX
    )
    for value, label in ((index_name, "index_name"), (manifest_name, "manifest_name")):
        if not isinstance(value, str) or PurePosixPath(value).name != value or value in {".", ".."}:
            raise SdPackError(f"{label} must be one plain relative filename")
    root = Path(destination)
    root.mkdir(parents=True, exist_ok=True)
    entries: list[dict[str, Any]] = []
    shards: list[dict[str, Any]] = []
    seen: set[int] = set()
    source_set = hashlib.sha256()
    with tempfile.NamedTemporaryFile(
        mode="wb", prefix=".c8in-record.", suffix=".tmp", dir=root, delete=False
    ) as staging_stream:
        package_staging = Path(staging_stream.name)
    shard_stream: Any = None
    shard_temporary: Path | None = None
    shard_name = ""
    shard_id = -1
    shard_first = 0
    shard_count = 0
    shard_bytes = 0
    shard_crc = 0
    shard_sha = hashlib.sha256()

    def begin_shard() -> None:
        nonlocal shard_stream, shard_temporary, shard_name, shard_id
        nonlocal shard_first, shard_count, shard_bytes, shard_crc, shard_sha
        shard_id += 1
        shard_name = f"in_{shard_id:04d}.bin"
        if len(shard_name.encode("ascii")) > 16:
            raise SdPackError("too many shards for the fixed filename field")
        shard_first = len(entries)
        shard_count = 0
        shard_bytes = 0
        shard_crc = 0
        shard_sha = hashlib.sha256()
        shard_stream = tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{shard_name}.",
            suffix=".tmp",
            dir=root,
            delete=False,
        )
        shard_temporary = Path(shard_stream.name)

    def finish_shard() -> None:
        nonlocal shard_stream, shard_temporary
        if shard_stream is None or shard_temporary is None:
            return
        shard_stream.flush()
        os.fsync(shard_stream.fileno())
        shard_stream.close()
        if shard_count == 0:
            shard_temporary.unlink(missing_ok=True)
            shard_stream = None
            shard_temporary = None
            return
        final = root / shard_name
        os.replace(shard_temporary, final)
        shard_temporary = None
        shard_stream = None
        shards.append(
            {
                "shard_id": shard_id,
                "path": shard_name,
                "first_record": shard_first,
                "record_count": shard_count,
                "bytes": shard_bytes,
                "crc32": shard_crc & UINT32_MAX,
                "sha256": shard_sha.hexdigest(),
            }
        )

    try:
        begin_shard()
        for raw in images:
            if len(entries) >= expected_count:
                raise SdPackError(f"image iterable contains more than {expected_count} entries")
            image_id, image_path = _image_record(raw)
            if image_id in seen:
                raise SdPackError(f"duplicate image_id {image_id}")
            seen.add(image_id)
            built = pack_input_image(
                image_path,
                package_staging,
                image_id=image_id,
                input_scale=input_scale,
                input_zero_point=input_zero_point,
            )
            package = built["package"]
            package_bytes = _integer(package["total_bytes"], "package.total_bytes", 1)
            if shard_bytes and package_bytes > shard_target_bytes - shard_bytes:
                finish_shard()
                begin_shard()
            if package_bytes > shard_target_bytes:
                raise SdPackError("one input package exceeds shard_target_bytes")
            offset = shard_bytes
            copied = 0
            with package_staging.open("rb") as source:
                while True:
                    chunk = source.read(COPY_CHUNK_BYTES)
                    if not chunk:
                        break
                    shard_stream.write(chunk)
                    copied += len(chunk)
                    shard_crc = zlib.crc32(chunk, shard_crc)
                    shard_sha.update(chunk)
            if copied != package_bytes:
                raise SdPackError("staged input package changed while sharding")
            record_index = len(entries)
            built["record_index"] = record_index
            built["shard_id"] = shard_id
            built["offset"] = offset
            package["path"] = shard_name
            package["offset"] = offset
            entries.append(built)
            shard_count += 1
            shard_bytes += copied
            source_set.update(struct.pack("<I", image_id))
            source_set.update(bytes.fromhex(built["source_sha256"]))
            package_staging.unlink(missing_ok=True)
        if len(entries) != expected_count:
            raise SdPackError(f"expected exactly {expected_count} images, got {len(entries)}")
        finish_shard()
    finally:
        package_staging.unlink(missing_ok=True)
        if shard_stream is not None:
            shard_stream.close()
        if shard_temporary is not None:
            shard_temporary.unlink(missing_ok=True)
    source_set_sha = source_set.hexdigest()
    binary = _write_input_binary_index(
        root / index_name, shards, entries, source_set_sha
    )
    manifest: dict[str, Any] = {
        "schema": "coco80.sd-input-shards.v1",
        "protocol_version": PROTOCOL_VERSION,
        "image_count": expected_count,
        "shard_count": len(shards),
        "shard_limit_bytes": shard_target_bytes,
        "model_shape_hwc": [MODEL_HEIGHT, MODEL_WIDTH, INPUT_CHANNELS],
        "input_scale": float(input_scale),
        "input_zero_point": input_zero_point,
        "input_quant_range": [INPUT_QUANT_MIN, INPUT_QUANT_MAX],
        "source_set_sha256": source_set_sha,
        "binary_index": binary,
        "shards": shards,
        "entries": entries,
    }
    write_json_atomic(root / manifest_name, manifest)
    return manifest


def _embedded_input_header(shard: Path, offset: int, size: int) -> tuple[int, ...]:
    total = shard.stat().st_size
    _range(offset, size, total, "embedded input package")
    if size < HEADER_BYTES:
        raise SdPackError("embedded input package is shorter than its header")
    with shard.open("rb") as stream:
        stream.seek(offset)
        raw = stream.read(HEADER_BYTES)
    if len(raw) != HEADER_BYTES:
        raise SdPackError("short embedded input package header")
    words = _HEADER.unpack(raw)
    if (
        words[0] != MAGIC_INPUT
        or words[1] != PROTOCOL_VERSION
        or words[2] != HEADER_BYTES
        or words[3] != size
        or words[4] != HEADER_BYTES
        or words[5] != size - HEADER_BYTES
        or _header_crc(raw) != words[7]
    ):
        raise SdPackError("embedded input common header is invalid")
    if crc32_file(shard, offset=offset + words[4], size=words[5]) != words[6]:
        raise SdPackError("embedded input payload CRC32 mismatch")
    remaining = words[5]
    with shard.open("rb") as stream:
        stream.seek(offset + words[4])
        while remaining:
            chunk = stream.read(min(COPY_CHUNK_BYTES, remaining))
            if not chunk:
                raise SdPackError("embedded input payload is truncated")
            if max(chunk) > INPUT_QUANT_MAX:
                raise SdPackError("embedded input payload exceeds reduced uint8 range 0..127")
            remaining -= len(chunk)
    return words


def validate_input_shard_set(manifest_path: str | Path) -> dict[str, Any]:
    """Close the JSON -> binary table -> shard -> C8IN package hash chain."""

    manifest_file = _regular_file(manifest_path, "input shard manifest")
    try:
        raw_json = manifest_file.read_bytes()
        data = json.loads(raw_json.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SdPackError(f"cannot parse input shard manifest: {exc}") from exc
    if not isinstance(data, Mapping) or data.get("schema") != "coco80.sd-input-shards.v1":
        raise SdPackError("unsupported input shard manifest schema")
    if data.get("input_quant_range") != [INPUT_QUANT_MIN, INPUT_QUANT_MAX]:
        raise SdPackError("input shard manifest is not bound to reduced uint8 range 0..127")
    canonical = (
        json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n"
    ).encode("utf-8")
    if raw_json != canonical:
        raise SdPackError("input shard manifest is not canonical JSON")
    root = manifest_file.parent.resolve()

    def member(name: Any, label: str) -> Path:
        if not isinstance(name, str) or PurePosixPath(name).name != name:
            raise SdPackError(f"{label} must be one relative filename")
        candidate = root / name
        if candidate.is_symlink():
            raise SdPackError(f"{label} must not be a symlink")
        resolved = candidate.resolve(strict=True)
        try:
            resolved.relative_to(root)
        except ValueError as exc:
            raise SdPackError(f"{label} escapes the shard-set directory") from exc
        return _regular_file(resolved, label)

    binary_meta = data.get("binary_index")
    if not isinstance(binary_meta, Mapping):
        raise SdPackError("input shard manifest lacks binary_index")
    binary_path = member(binary_meta.get("path"), "binary index")
    binary = parse_input_binary_index(binary_path)
    for key in ("bytes", "crc32", "sha256", "content_sha256", "source_set_sha256"):
        if binary_meta.get(key) != binary[key]:
            raise SdPackError(f"binary index {key} differs from JSON manifest")
    image_count = _integer(data.get("image_count"), "image_count", 1)
    shard_count = _integer(data.get("shard_count"), "shard_count", 1)
    if (
        binary["image_count"] != image_count
        or binary["shard_count"] != shard_count
        or binary["source_set_sha256"] != data.get("source_set_sha256")
    ):
        raise SdPackError("binary index cardinality/source-set binding differs from JSON")
    json_shards = data.get("shards")
    json_entries = data.get("entries")
    if not isinstance(json_shards, list) or len(json_shards) != shard_count:
        raise SdPackError("JSON shard list cardinality is invalid")
    if not isinstance(json_entries, list) or len(json_entries) != image_count:
        raise SdPackError("JSON entry list cardinality is invalid")
    shard_paths: list[Path] = []
    for index, (json_shard, table_shard) in enumerate(zip(json_shards, binary["shards"])):
        if not isinstance(json_shard, Mapping):
            raise SdPackError(f"JSON shard {index} is not an object")
        for key in ("shard_id", "path", "first_record", "record_count", "bytes", "crc32", "sha256"):
            if json_shard.get(key) != table_shard[key]:
                raise SdPackError(f"JSON and binary shard {index} differ at {key}")
        shard = member(json_shard.get("path"), f"shard {index}")
        if shard.stat().st_size != json_shard["bytes"]:
            raise SdPackError(f"shard {index} byte size mismatch")
        if crc32_file(shard) != json_shard["crc32"]:
            raise SdPackError(f"shard {index} CRC32 mismatch")
        if sha256_file(shard) != json_shard["sha256"]:
            raise SdPackError(f"shard {index} SHA256 mismatch")
        shard_paths.append(shard)
    shard_cursor = [0] * shard_count
    seen_ids: set[int] = set()
    for index, (json_entry, table_entry) in enumerate(zip(json_entries, binary["entries"])):
        if not isinstance(json_entry, Mapping):
            raise SdPackError(f"JSON input entry {index} is not an object")
        package = json_entry.get("package")
        letterbox = json_entry.get("letterbox")
        if not isinstance(package, Mapping) or not isinstance(letterbox, Mapping):
            raise SdPackError(f"JSON input entry {index} lacks package/letterbox")
        comparisons = {
            "image_id": json_entry.get("image_id"),
            "shard_id": json_entry.get("shard_id"),
            "record_index": json_entry.get("record_index"),
            "offset": json_entry.get("offset"),
            "bytes": package.get("total_bytes"),
            "package_crc32": package.get("package_crc32"),
            "original_width": letterbox.get("source_width"),
            "original_height": letterbox.get("source_height"),
        }
        if comparisons != table_entry:
            raise SdPackError(f"JSON and binary input entry {index} differ")
        image_id = table_entry["image_id"]
        if image_id in seen_ids:
            raise SdPackError(f"duplicate image_id {image_id} in input entries")
        seen_ids.add(image_id)
        shard_id = table_entry["shard_id"]
        offset = table_entry["offset"]
        size = table_entry["bytes"]
        if offset != shard_cursor[shard_id]:
            raise SdPackError(f"input entry {index} is not tightly packed in its shard")
        shard = shard_paths[shard_id]
        words = _embedded_input_header(shard, offset, size)
        if (
            words[8] != image_id
            or words[12] != table_entry["original_width"]
            or words[13] != table_entry["original_height"]
            or crc32_file(shard, offset=offset, size=size) != table_entry["package_crc32"]
            or _sha256_file_range(shard, offset, size) != package.get("sha256")
            or _words_sha(words[22:30]) != json_entry.get("source_sha256")
        ):
            raise SdPackError(f"embedded C8IN package {index} differs from its indexes")
        shard_cursor[shard_id] += size
    for shard_id, cursor in enumerate(shard_cursor):
        if cursor != shard_paths[shard_id].stat().st_size:
            raise SdPackError(f"indexed packages do not cover shard {shard_id}")
    return {
        "status": "ok",
        "manifest": str(manifest_file.resolve()),
        "manifest_sha256": sha256_file(manifest_file),
        "image_count": image_count,
        "shard_count": shard_count,
        "binary_index_sha256": binary["sha256"],
        "source_set_sha256": binary["source_set_sha256"],
    }


def validate_board_output_index(
    index_path: str | Path, data_path: str | Path
) -> dict[str, Any]:
    """Validate a board-created C8OX index and its complete data stream."""

    index_file = _regular_file(index_path, "board output index")
    data_file = _regular_file(data_path, "board output data")
    raw = index_file.read_bytes()
    if len(raw) < OUTPUT_INDEX_HEADER_BYTES:
        raise SdPackError("board output index is shorter than its header")
    header_raw = raw[:OUTPUT_INDEX_HEADER_BYTES]
    words = OUTPUT_INDEX_HEADER.unpack(header_raw)
    canonical = bytearray(header_raw)
    canonical[15 * 4 : 16 * 4] = bytes(4)
    if (
        words[0] != MAGIC_OUTPUT_INDEX
        or words[1] not in (1, 2)
        or words[2] != OUTPUT_INDEX_HEADER_BYTES
        or words[3] > 2
        or words[4] == 0
        or words[5] == 0
        or words[5] > words[4]
        or words[6] != OUTPUT_INDEX_ENTRY_BYTES
        or words[7] != words[5] * OUTPUT_INDEX_ENTRY_BYTES
        or OUTPUT_INDEX_HEADER_BYTES + words[7] != len(raw)
        or words[8] != data_file.stat().st_size
        or words[11] == 0
        or words[12] == 0
        or words[13] == 0
        or words[14] == 0
        or (words[1] == 1 and any(words[16:32]))
        or (words[1] == 2 and any(words[17:32]))
        or (zlib.crc32(canonical) & UINT32_MAX) != words[15]
    ):
        raise SdPackError("board output index header is invalid")
    entry_raw = raw[OUTPUT_INDEX_HEADER_BYTES:]
    if zlib.crc32(entry_raw) & UINT32_MAX != words[10]:
        raise SdPackError("board output entry-table CRC32 mismatch")
    if crc32_file(data_file) != words[9]:
        raise SdPackError("board output data CRC32 mismatch")
    entries: list[dict[str, int]] = []
    offset = 0
    previous_record = -1
    with data_file.open("rb") as stream:
        for index in range(words[5]):
            row = OUTPUT_INDEX_ENTRY.unpack_from(entry_raw, index * OUTPUT_INDEX_ENTRY_BYTES)
            if (
                row[0] == 0
                or row[1] <= previous_record
                or row[2] != offset
                or row[3] == 0
                or row[3] > words[8] - offset
                or row[4] == 0
                or row[5] > MAX_DETECTIONS
            ):
                raise SdPackError(f"board output record {index} is invalid")
            payload = stream.read(row[3])
            if len(payload) != row[3] or zlib.crc32(payload) & UINT32_MAX != row[4]:
                raise SdPackError(f"board output record {index} CRC32 mismatch")
            if words[3] == 0:
                if row[3] != HEADER_BYTES + P4_BYTES + P5_BYTES or struct.unpack_from("<I", payload)[0] != MAGIC_RAW_HEADS:
                    raise SdPackError(f"accuracy output record {index} is not a raw-head package")
            elif words[3] == 1:
                if row[3] < HEADER_BYTES or struct.unpack_from("<I", payload)[0] != MAGIC_RESULT:
                    raise SdPackError(f"product output record {index} is not a result package")
            elif row[3] != 64:
                raise SdPackError(f"performance output record {index} is not a timing record")
            entries.append(
                {
                    "image_id": row[0],
                    "record_index": row[1],
                    "offset": row[2],
                    "bytes": row[3],
                    "crc32": row[4],
                    "detection_count": row[5],
                    "total_ticks": row[6] | (row[7] << 32),
                }
            )
            offset += row[3]
            previous_record = row[1]
    if offset != words[8]:
        raise SdPackError("board output records do not cover the exact data file")
    return {
        "schema": f"coco80.board-output-index.v{words[1]}",
        "mode": words[3],
        "input_records": words[4],
        "output_records": words[5],
        "data_bytes": words[8],
        "data_crc32": words[9],
        "parameter_crc32": words[11],
        "input_index_crc32": words[12],
        "software_build_crc32": words[13],
        "hardware_build_crc32": words[14],
        "selection_index_crc32": words[16] if words[1] >= 2 else 0,
        "entries": entries,
        "index_sha256": sha256_file(index_file),
        "data_sha256": sha256_file(data_file),
    }


def validate_board_node_index(
    index_path: str | Path, data_path: str | Path
) -> dict[str, Any]:
    """Validate the 22-tensor-per-image conformance stream from the A53."""

    index_file = _regular_file(index_path, "board node index")
    data_file = _regular_file(data_path, "board node data")
    raw = index_file.read_bytes()
    if len(raw) < NODE_INDEX_HEADER.size:
        raise SdPackError("board node index is shorter than its header")
    header_raw = raw[: NODE_INDEX_HEADER.size]
    words = NODE_INDEX_HEADER.unpack(header_raw)
    canonical = bytearray(header_raw)
    canonical[15 * 4 : 16 * 4] = bytes(4)
    if (
        words[0] != MAGIC_NODE_INDEX
        or words[1] not in (1, 2)
        or words[2] != NODE_INDEX_HEADER.size
        or words[3] == 0
        or words[4] != words[3] * NODE_TENSOR_COUNT
        or words[5] != NODE_INDEX_ENTRY.size
        or words[6] != words[4] * NODE_INDEX_ENTRY.size
        or NODE_INDEX_HEADER.size + words[6] != len(raw)
        or words[7] != data_file.stat().st_size
        or words[10] == 0
        or words[11] == 0
        or words[12] == 0
        or words[13] == 0
        or words[14] != NODE_TENSOR_COUNT
        or (words[1] == 1 and any(words[16:32]))
        or (words[1] == 2 and any(words[17:32]))
        or zlib.crc32(canonical) & UINT32_MAX != words[15]
    ):
        raise SdPackError("board node index header is invalid")
    entry_raw = raw[NODE_INDEX_HEADER.size :]
    if zlib.crc32(entry_raw) & UINT32_MAX != words[9]:
        raise SdPackError("board node entry-table CRC32 mismatch")
    if crc32_file(data_file) != words[8]:
        raise SdPackError("board node data CRC32 mismatch")
    entries: list[dict[str, int]] = []
    offset = 0
    current_image = 0
    with data_file.open("rb") as stream:
        for index in range(words[4]):
            row = NODE_INDEX_ENTRY.unpack_from(entry_raw, index * NODE_INDEX_ENTRY.size)
            expected_tensor = index % NODE_TENSOR_COUNT
            if (
                row[0] == 0
                or row[1] != expected_tensor
                or row[2] != offset
                or row[3] == 0
                or row[3] > words[7] - offset
                or row[4] == 0
                or row[5] != index
                or (expected_tensor == 0 and row[0] == current_image)
                or (expected_tensor != 0 and row[0] != current_image)
            ):
                raise SdPackError(f"board node record {index} is invalid")
            if expected_tensor == 0:
                current_image = row[0]
            payload = stream.read(row[3])
            if len(payload) != row[3] or zlib.crc32(payload) & UINT32_MAX != row[4]:
                raise SdPackError(f"board node record {index} CRC32 mismatch")
            entries.append(
                {
                    "image_id": row[0], "tensor_id": row[1], "offset": row[2],
                    "bytes": row[3], "crc32": row[4], "sequence": row[5],
                }
            )
            offset += row[3]
    if offset != words[7]:
        raise SdPackError("board node records do not cover the exact data file")
    return {
        "schema": f"coco80.board-node-index.v{words[1]}",
        "image_records": words[3],
        "node_records": words[4],
        "data_bytes": words[7],
        "data_crc32": words[8],
        "parameter_crc32": words[10],
        "input_index_crc32": words[11],
        "software_build_crc32": words[12],
        "hardware_build_crc32": words[13],
        "selection_index_crc32": words[16] if words[1] >= 2 else 0,
        "entries": entries,
        "index_sha256": sha256_file(index_file),
        "data_sha256": sha256_file(data_file),
    }


def _coco_image_records(
    annotation_json: str | Path, image_root: str | Path
) -> list[tuple[int, Path]]:
    annotation = _regular_file(annotation_json, "COCO annotation JSON")
    try:
        payload = json.loads(annotation.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SdPackError(f"cannot parse {annotation}: {exc}") from exc
    images = payload.get("images") if isinstance(payload, Mapping) else None
    if not isinstance(images, list):
        raise SdPackError("COCO JSON must contain an images array")
    root = Path(image_root).resolve(strict=True)
    records: list[tuple[int, Path]] = []
    for item in images:
        if not isinstance(item, Mapping):
            raise SdPackError("COCO images entries must be objects")
        image_id = _integer(item.get("id"), "COCO image id", 1)
        filename = item.get("file_name")
        if not isinstance(filename, str) or not filename:
            raise SdPackError(f"image {image_id} has no valid file_name")
        pure = PurePosixPath(filename)
        if pure.is_absolute() or ".." in pure.parts or "\\" in filename:
            raise SdPackError(f"image {image_id} has unsafe file_name {filename!r}")
        candidate = root.joinpath(*pure.parts).resolve(strict=True)
        try:
            candidate.relative_to(root)
        except ValueError as exc:
            raise SdPackError(f"image {image_id} escapes image_root") from exc
        records.append((image_id, candidate))
    records.sort(key=lambda item: item[0])
    return records


def build_input_packages_from_coco(
    annotation_json: str | Path,
    image_root: str | Path,
    destination: str | Path,
    *,
    input_scale: float,
    input_zero_point: int,
    expected_count: int = 5000,
) -> dict[str, Any]:
    """Build individual packages from the COCO ``images`` array, sorted by id."""

    return build_input_packages(
        _coco_image_records(annotation_json, image_root),
        destination,
        input_scale=input_scale,
        input_zero_point=input_zero_point,
        expected_count=expected_count,
    )


def build_input_shards_from_coco(
    annotation_json: str | Path,
    image_root: str | Path,
    destination: str | Path,
    *,
    input_scale: float,
    input_zero_point: int,
    expected_count: int = 5000,
    shard_target_bytes: int = 1024 * 1024 * 1024,
) -> dict[str, Any]:
    """Build the bare-metal shard set from a COCO images array."""

    return build_input_shards(
        _coco_image_records(annotation_json, image_root),
        destination,
        input_scale=input_scale,
        input_zero_point=input_zero_point,
        expected_count=expected_count,
        shard_target_bytes=shard_target_bytes,
    )


def pack_parameter_package(
    destination: str | Path,
    *,
    weights: str | Path,
    biases: str | Path,
    activation_luts: str | Path,
    quantization: str | Path,
    model_sha256: str | None = None,
) -> PackageHeader:
    """Stream four non-empty parameter images into a ``C8PA`` package."""

    sources = [
        _regular_file(weights, "weights"),
        _regular_file(biases, "biases"),
        _regular_file(activation_luts, "activation LUTs"),
        _regular_file(quantization, "quantization"),
    ]
    if any(path.stat().st_size == 0 for path in sources):
        raise SdPackError("all four parameter sections must be non-empty")
    digest = model_sha256 or _sha256_concat(sources)
    digest_words = _sha_words(digest, "model_sha256")

    def header(sections: Mapping[str, Section]) -> list[int]:
        words = [0] * HEADER_WORDS
        words[8:12] = [MODEL_WIDTH, MODEL_HEIGHT, CLASS_COUNT, PARAMETER_LAYER_COUNT]
        cursor = 12
        for name in ("weights", "biases", "activation_luts", "quantization"):
            section = sections[name]
            words[cursor : cursor + 3] = [section.offset, section.bytes, section.crc32]
            cursor += 3
        words[24:32] = digest_words
        return words

    return _write_package(
        destination,
        MAGIC_PARAMETERS,
        list(zip(("weights", "biases", "activation_luts", "quantization"), sources)),
        header,
    )


def _binding_bytes_from_manifests(
    parameter_manifest: Path, quantization_manifest: Path
) -> bytes:
    """Create the fixed freestanding C binding section from verified manifests."""

    from .vitis_headers import build_vitis_config

    config = build_vitis_config(
        parameter_manifest,
        quantization_manifest,
        bit_sha256="11" * 32,
        xsa_sha256="22" * 32,
    )
    layers = config.get("layers")
    if not isinstance(layers, list) or len(layers) != PARAMETER_LAYER_COUNT:
        raise SdPackError("Vitis binding generator did not return 13 layers")
    output = bytearray()
    for index, raw in enumerate(layers):
        if not isinstance(raw, Mapping):
            raise SdPackError(f"generated binding layer {index} is invalid")
        fields = (
            "bias_offset", "bias_bytes", "weight_offset", "weight_bytes",
            "bias_packets", "weight_packets", "input_scale_bits",
            "input_zero_point", "output_scale_bits", "output_zero_point",
            "quant_mult", "quant_shift", "rtl_output_zero_point",
            "activation_lut_index",
        )
        values: list[int] = []
        for field in fields:
            value = raw.get(field)
            if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= UINT32_MAX:
                raise SdPackError(f"generated binding {index}.{field} is not uint32")
            values.append(value)
        values[13] *= 256
        luts = config.get("luts")
        if not isinstance(luts, list) or index >= len(luts) or not isinstance(luts[index], str):
            raise SdPackError(f"missing generated activation LUT for {raw['name']}")
        lut = bytes.fromhex(luts[index])
        if len(lut) != 256:
            raise SdPackError(f"generated activation LUT for {raw['name']} is not 256 bytes")
        values.append(zlib.crc32(lut) & UINT32_MAX)
        output.extend(struct.pack("<15I", *values))
    if len(output) != BINDING_BYTES:
        raise SdPackError("binding section byte contract changed")
    return bytes(output)


def pack_parameter_package_from_manifest(
    manifest_path: str | Path,
    destination: str | Path,
    *,
    activation_luts: str | Path | None = None,
    quantization: str | Path | None = None,
    quantization_root: str | Path | None = None,
    model_sha256: str | None = None,
) -> PackageHeader:
    """Wrap the existing host parameter manifest without loading its images."""

    manifest_file = _regular_file(manifest_path, "parameter manifest")
    try:
        data = json.loads(manifest_file.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SdPackError(f"cannot parse parameter manifest: {exc}") from exc
    if not isinstance(data, Mapping):
        raise SdPackError("parameter manifest must be a JSON object")
    from .hardware_plan import COCO80_HARDWARE_PLAN
    from .parameter_package import (
        BIAS_IMAGE_NAME,
        PARAMETER_PACKAGE_MAGIC,
        PARAMETER_PACKAGE_VERSION,
        WEIGHT_IMAGE_NAME,
    )

    if (
        data.get("magic") != PARAMETER_PACKAGE_MAGIC
        or data.get("version") != PARAMETER_PACKAGE_VERSION
    ):
        raise SdPackError("unsupported parameter_package.py manifest identity")
    hardware = data.get("hardware_plan")
    if (
        not isinstance(hardware, Mapping)
        or hardware.get("magic") != COCO80_HARDWARE_PLAN.magic
        or hardware.get("version") != COCO80_HARDWARE_PLAN.version
        or hardware.get("sha256") != COCO80_HARDWARE_PLAN.sha256()
    ):
        raise SdPackError("parameter manifest hardware-plan binding is invalid")
    files = data.get("files")
    if not isinstance(files, Mapping):
        raise SdPackError("parameter manifest has no files object")
    resolved: dict[str, Path] = {}
    for kind in ("weight", "bias"):
        entry = files.get(kind)
        if not isinstance(entry, Mapping):
            raise SdPackError(f"parameter manifest has no files.{kind} object")
        relative = entry.get("path")
        if not isinstance(relative, str) or not relative:
            raise SdPackError(f"files.{kind}.path is invalid")
        expected_name = WEIGHT_IMAGE_NAME if kind == "weight" else BIAS_IMAGE_NAME
        if relative != expected_name:
            raise SdPackError(f"files.{kind}.path differs from parameter_package.py output")
        pure = PurePosixPath(relative)
        if pure.is_absolute() or ".." in pure.parts or "\\" in relative:
            raise SdPackError(f"files.{kind}.path is unsafe")
        target = manifest_file.parent.joinpath(*pure.parts).resolve(strict=True)
        try:
            target.relative_to(manifest_file.parent.resolve())
        except ValueError as exc:
            raise SdPackError(f"files.{kind}.path escapes the manifest directory") from exc
        target = _regular_file(target, kind)
        expected_bytes = entry.get("file_bytes")
        if _integer(expected_bytes, f"files.{kind}.file_bytes", 1) != target.stat().st_size:
            raise SdPackError(f"files.{kind} size does not match its manifest")
        expected_sha = entry.get("sha256")
        if not isinstance(expected_sha, str) or sha256_file(target) != expected_sha:
            raise SdPackError(f"files.{kind} SHA256 does not match its manifest")
        resolved[kind] = target
    inferred = model_sha256
    if inferred is None:
        provenance = data.get("provenance")
        checkpoints = provenance.get("checkpoint_sha256") if isinstance(provenance, Mapping) else None
        if isinstance(checkpoints, list) and len(checkpoints) == 1 and isinstance(checkpoints[0], str):
            inferred = checkpoints[0]
        else:
            raise SdPackError(
                "parameter manifest must bind exactly one checkpoint SHA256 or model_sha256 must be supplied"
            )
    generated_luts: Path | None = None
    generated_bindings: Path | None = None
    quant_path: Path | None = Path(quantization) if quantization is not None else None
    if activation_luts is None or quant_path is None:
        if quant_path is not None:
            candidate = quant_path
        elif quantization_root is None:
            candidate = manifest_file.parent / "quantization_manifest.json"
        else:
            candidate = Path(quantization_root)
            if candidate.is_dir():
                candidate = candidate / "quantization_manifest.json"
        quant_manifest = _regular_file(candidate, "canonical quantization manifest")
        if quant_path is None:
            quant_path = quant_manifest
        if activation_luts is None:
            try:
                quant_data = json.loads(quant_manifest.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError) as exc:
                raise SdPackError(f"cannot parse canonical quantization manifest: {exc}") from exc
            if (
                not isinstance(quant_data, Mapping)
                or quant_data.get("format") != "kv260-coco80-rtl-quantization"
                or quant_data.get("version") != 1
            ):
                raise SdPackError("unsupported canonical quantization manifest identity")
            quant_layers = quant_data.get("layers")
            output_layers = data.get("layers") if isinstance(data, Mapping) else None
            if (
                not isinstance(quant_layers, list)
                or len(quant_layers) != PARAMETER_LAYER_COUNT
                or not isinstance(output_layers, list)
                or len(output_layers) != PARAMETER_LAYER_COUNT
            ):
                raise SdPackError("quantization and parameter manifests must each contain 13 layers")
            destination_parent = Path(destination).parent
            destination_parent.mkdir(parents=True, exist_ok=True)
            try:
                with tempfile.NamedTemporaryFile(
                    mode="wb",
                    prefix=".c8pa-luts.",
                    suffix=".tmp",
                    dir=destination_parent,
                    delete=False,
                ) as stream:
                    generated_luts = Path(stream.name)
                    for index, (quant_layer, output_layer) in enumerate(zip(quant_layers, output_layers)):
                        if not isinstance(quant_layer, Mapping) or not isinstance(output_layer, Mapping):
                            raise SdPackError(f"parameter layer {index} is not an object")
                        quant_name = quant_layer.get("name")
                        output_name = output_layer.get("layer_id")
                        if quant_name != output_name:
                            raise SdPackError(f"parameter/quantization layer order differs at {index}")
                        layer_files = quant_layer.get("files")
                        lut_entry = (
                            layer_files.get("activation_lut_u8")
                            if isinstance(layer_files, Mapping)
                            else None
                        )
                        if not isinstance(lut_entry, Mapping):
                            raise SdPackError(f"quantization layer {index} has no activation LUT")
                        relative = lut_entry.get("path")
                        if not isinstance(relative, str) or not relative:
                            raise SdPackError(f"quantization layer {index} LUT path is invalid")
                        # Quantization manifests created on Windows before the
                        # portable-path fix used backslashes for otherwise
                        # canonical relative paths.  Normalize those separators
                        # while retaining the same fail-closed traversal and
                        # absolute-path checks used for POSIX manifests.
                        normalized = relative.replace("\\", "/")
                        pure = PurePosixPath(normalized)
                        if (
                            pure.is_absolute()
                            or ".." in pure.parts
                            or any(":" in part for part in pure.parts)
                        ):
                            raise SdPackError(f"quantization layer {index} LUT path is unsafe")
                        lut_path = quant_manifest.parent.joinpath(*pure.parts).resolve(strict=True)
                        try:
                            lut_path.relative_to(quant_manifest.parent.resolve())
                        except ValueError as exc:
                            raise SdPackError(f"quantization layer {index} LUT escapes its root") from exc
                        lut_path = _regular_file(lut_path, f"layer {index} LUT")
                        if lut_path.stat().st_size != 256 or lut_entry.get("bytes") != 256:
                            raise SdPackError(f"quantization layer {index} LUT must contain 256 bytes")
                        if sha256_file(lut_path) != lut_entry.get("sha256"):
                            raise SdPackError(f"quantization layer {index} LUT SHA256 mismatch")
                        with lut_path.open("rb") as source:
                            chunk = source.read()
                        stream.write(chunk)
                    stream.flush()
                    os.fsync(stream.fileno())
            except BaseException:
                if generated_luts is not None:
                    generated_luts.unlink(missing_ok=True)
                    generated_luts = None
                raise
            activation_luts = generated_luts
    if quant_path is None or activation_luts is None:
        raise SdPackError("activation LUT and quantization sections could not be resolved")
    # The host manifest is JSON, but the board ABI consumes the fixed binary
    # table.  Generate it beside the destination and remove it after wrapping.
    if quant_path.suffix.lower() == ".json":
        destination_parent = Path(destination).parent
        destination_parent.mkdir(parents=True, exist_ok=True)
        try:
            with tempfile.NamedTemporaryFile(
                mode="wb", prefix=".c8pa-bindings.", suffix=".tmp",
                dir=destination_parent, delete=False
            ) as stream:
                generated_bindings = Path(stream.name)
                stream.write(_binding_bytes_from_manifests(manifest_file, quant_path))
                stream.flush()
                os.fsync(stream.fileno())
            quant_path = generated_bindings
        except BaseException:
            if generated_bindings is not None:
                generated_bindings.unlink(missing_ok=True)
                generated_bindings = None
            raise
    try:
        return pack_parameter_package(
            destination,
            weights=resolved["weight"],
            biases=resolved["bias"],
            activation_luts=activation_luts,
            quantization=quant_path,
            model_sha256=inferred,
        )
    finally:
        if generated_luts is not None:
            generated_luts.unlink(missing_ok=True)
        if generated_bindings is not None:
            generated_bindings.unlink(missing_ok=True)


pack_parameter_package_from_output = pack_parameter_package_from_manifest


def pack_raw_heads(
    destination: str | Path,
    *,
    p4: str | Path,
    p5: str | Path,
    p4_scale: float,
    p4_zero_point: int,
    p5_scale: float,
    p5_zero_point: int,
    input_package: str | Path | int,
    parameter_package: str | Path | int,
) -> PackageHeader:
    """Wrap the fixed dual HWC uint8 heads and bind their input/parameters."""

    p4_path = _regular_file(p4, "P4 head")
    p5_path = _regular_file(p5, "P5 head")
    if p4_path.stat().st_size != P4_BYTES or p5_path.stat().st_size != P5_BYTES:
        raise SdPackError(f"raw heads must be exactly P4={P4_BYTES}, P5={P5_BYTES} bytes")
    p4_scale_bits = _f32_bits(p4_scale, "p4_scale", positive=True)
    p5_scale_bits = _f32_bits(p5_scale, "p5_scale", positive=True)
    p4_zero_point = _integer(p4_zero_point, "p4_zero_point", 0, 255)
    p5_zero_point = _integer(p5_zero_point, "p5_zero_point", 0, 255)
    input_crc = _package_ref(input_package, MAGIC_INPUT, "input_package_crc32")
    parameter_crc = _package_ref(
        parameter_package, MAGIC_PARAMETERS, "parameter_package_crc32"
    )

    def header(sections: Mapping[str, Section]) -> list[int]:
        words = [0] * HEADER_WORDS
        words[8:14] = [
            MODEL_WIDTH,
            MODEL_HEIGHT,
            CLASS_COUNT,
            VALUES_PER_ANCHOR,
            ANCHORS_PER_HEAD,
            HEAD_COUNT,
        ]
        for start, name, width, height, scale, zero_point in (
            (14, "p4", P4_WIDTH, P4_HEIGHT, p4_scale_bits, p4_zero_point),
            (22, "p5", P5_WIDTH, P5_HEIGHT, p5_scale_bits, p5_zero_point),
        ):
            section = sections[name]
            words[start : start + 8] = [
                width,
                height,
                HEAD_CHANNELS,
                section.offset,
                section.bytes,
                scale,
                zero_point,
                section.crc32,
            ]
        words[30:32] = [input_crc, parameter_crc]
        return words

    return _write_package(
        destination,
        MAGIC_RAW_HEADS,
        [("p4", p4_path), ("p5", p5_path)],
        header,
    )


def _package_result(package: PackageHeader, extra: Mapping[str, Any]) -> dict[str, Any]:
    result = package.to_dict()
    result.update(extra)
    return result


def parse_input_package(path: str | Path) -> dict[str, Any]:
    package = read_package_header(path, MAGIC_INPUT)
    w = package.words
    scale = _bits_f32(w[16])
    letterbox = _bits_f32(w[18])
    pad_x = _bits_f32(w[19])
    pad_y = _bits_f32(w[20])
    if (
        w[8] == 0
        or w[9:12] != (MODEL_WIDTH, MODEL_HEIGHT, INPUT_CHANNELS)
        or w[12] == 0
        or w[13] == 0
        or w[14:16] != (1, 1)
        or not math.isfinite(scale)
        or scale <= 0
        or w[17] > 255
        or not math.isfinite(letterbox)
        or letterbox <= 0
        or not math.isfinite(pad_x)
        or pad_x < 0
        or not math.isfinite(pad_y)
        or pad_y < 0
        or w[21] != INPUT_ROW_BYTES
        or package.payload_bytes != INPUT_TENSOR_BYTES
        or w[30:32] != (0, 0)
        or not any(w[22:30])
    ):
        raise SdPackError("input package shape/format/hash fields are invalid")
    if abs(pad_x - math.floor(pad_x)) > 1e-4 or abs(pad_y - math.floor(pad_y)) > 1e-4:
        raise SdPackError("input padding must be integer-valued float32")
    with package.path.open("rb") as stream:
        stream.seek(package.payload_offset)
        remaining = package.payload_bytes
        while remaining:
            chunk = stream.read(min(COPY_CHUNK_BYTES, remaining))
            if not chunk:
                raise SdPackError("input package payload is truncated")
            if max(chunk) > INPUT_QUANT_MAX:
                raise SdPackError("input package exceeds reduced uint8 range 0..127")
            remaining -= len(chunk)
    resized_width = w[12] * letterbox
    resized_height = w[13] * letterbox
    if (
        not 0.5 <= resized_width <= MODEL_WIDTH + 0.5
        or not 0.5 <= resized_height <= MODEL_HEIGHT + 0.5
        or pad_x > MODEL_WIDTH / 2
        or pad_y > MODEL_HEIGHT / 2
        or (resized_width < MODEL_WIDTH - 0.5 and resized_height < MODEL_HEIGHT - 0.5)
        or not MODEL_WIDTH - 1.5 <= resized_width + 2 * pad_x <= MODEL_WIDTH + 0.5
        or not MODEL_HEIGHT - 1.5 <= resized_height + 2 * pad_y <= MODEL_HEIGHT + 0.5
    ):
        raise SdPackError("input letterbox geometry is invalid")
    return _package_result(
        package,
        {
            "image_id": w[8],
            "model_shape_hwc": [w[10], w[9], w[11]],
            "original_width": w[12],
            "original_height": w[13],
            "input_scale": scale,
            "input_zero_point": w[17],
            "letterbox_scale": letterbox,
            "pad_x": pad_x,
            "pad_y": pad_y,
            "source_sha256": _words_sha(w[22:30]),
        },
    )


def parse_parameter_package(path: str | Path) -> dict[str, Any]:
    package = read_package_header(path, MAGIC_PARAMETERS)
    w = package.words
    if w[8:12] != (MODEL_WIDTH, MODEL_HEIGHT, CLASS_COUNT, PARAMETER_LAYER_COUNT):
        raise SdPackError("parameter model shape/class/layer count is invalid")
    if not any(w[24:32]):
        raise SdPackError("parameter model SHA256 reference is zero")
    sections: dict[str, Section] = {}
    cursor = 12
    for name in ("weights", "biases", "activation_luts", "quantization"):
        sections[name] = _validate_section(package, *w[cursor : cursor + 3], name)
        cursor += 3
    if sections["activation_luts"].bytes != PARAMETER_LAYER_COUNT * 256:
        raise SdPackError("activation LUT section must contain 13x256 bytes")
    if sections["quantization"].bytes != BINDING_BYTES:
        raise SdPackError("quantization section must contain the fixed 13x15 uint32 bindings")
    expected = package.payload_offset
    for name in ("weights", "biases", "activation_luts", "quantization"):
        section = sections[name]
        if section.offset != expected:
            raise SdPackError(f"parameter section {name} is not tightly packed")
        expected += section.bytes
    if expected != package.total_bytes:
        raise SdPackError("parameter sections do not cover the exact payload")
    return _package_result(
        package,
        {
            "model_width": w[8],
            "model_height": w[9],
            "class_count": w[10],
            "layer_count": w[11],
            "sections": {name: section.to_dict() for name, section in sections.items()},
            "model_sha256": _words_sha(w[24:32]),
        },
    )


def parse_raw_head_package(path: str | Path) -> dict[str, Any]:
    package = read_package_header(path, MAGIC_RAW_HEADS)
    w = package.words
    if w[8:14] != (
        MODEL_WIDTH,
        MODEL_HEIGHT,
        CLASS_COUNT,
        VALUES_PER_ANCHOR,
        ANCHORS_PER_HEAD,
        HEAD_COUNT,
    ):
        raise SdPackError("raw-head model contract is invalid")
    heads: dict[str, dict[str, Any]] = {}
    previous_end = package.payload_offset
    for start, name, width, height, size in (
        (14, "p4", P4_WIDTH, P4_HEIGHT, P4_BYTES),
        (22, "p5", P5_WIDTH, P5_HEIGHT, P5_BYTES),
    ):
        if w[start : start + 3] != (width, height, HEAD_CHANNELS):
            raise SdPackError(f"{name} shape is invalid")
        scale = _bits_f32(w[start + 5])
        if not math.isfinite(scale) or scale <= 0 or w[start + 6] > 255:
            raise SdPackError(f"{name} quantization is invalid")
        section = _validate_section(
            package, w[start + 3], w[start + 4], w[start + 7], name
        )
        if section.bytes != size or section.offset != previous_end:
            raise SdPackError(f"{name} size/offset is invalid")
        previous_end += section.bytes
        heads[name] = {
            "width": width,
            "height": height,
            "channels": HEAD_CHANNELS,
            "scale": scale,
            "zero_point": w[start + 6],
            **section.to_dict(),
        }
    if previous_end != package.total_bytes or w[30] == 0 or w[31] == 0:
        raise SdPackError("raw-head payload coverage or package references are invalid")
    return _package_result(
        package,
        {
            "heads": heads,
            "input_package_crc32": w[30],
            "parameter_package_crc32": w[31],
        },
    )


def _detection_fields(words: tuple[int, ...]) -> dict[str, Any]:
    confidence = _bits_f32(words[20])
    iou = _bits_f32(words[21])
    accuracy = (
        abs(confidence - 0.001) <= 1e-8
        and abs(iou - 0.65) <= 1e-7
        and words[22] == 1
    )
    demo = (
        abs(confidence - 0.25) <= 1e-8
        and abs(iou - 0.45) <= 1e-7
        and words[22] == 0
    )
    if not accuracy and not demo:
        raise SdPackError("detection decode profile is neither accuracy nor demo")
    return {
        "profile": "accuracy" if accuracy else "demo",
        "confidence_threshold": confidence,
        "iou_threshold": iou,
        "multi_label": bool(words[22]),
    }


def _decode_record(raw: bytes, *, image_id: int | None, confidence: float) -> dict[str, Any]:
    values = _DETECTION.unpack(raw)
    x1, y1, x2, y2, score = (_bits_f32(value) for value in values[1:6])
    class_id = values[6]
    head_id = values[9]
    anchor_id = values[10]
    if image_id is not None and values[0] != image_id:
        raise SdPackError("detection record image_id differs from its header")
    if (
        not all(math.isfinite(value) for value in (x1, y1, x2, y2, score))
        or x1 < 0
        or y1 < 0
        or x2 < x1
        or y2 < y1
        or not score > confidence
        or score > 1
        or class_id >= CLASS_COUNT
        or values[7] != COCO80_TO_COCO91[class_id]
        or head_id >= HEAD_COUNT
        or anchor_id >= ANCHORS_PER_HEAD
        or any(values[13:16])
    ):
        raise SdPackError("detection record format is invalid")
    if head_id == 0:
        grid_width = P4_WIDTH
        grid_height = P4_HEIGHT
        source_base = 0
    else:
        grid_width = P5_WIDTH
        grid_height = P5_HEIGHT
        source_base = P4_ANCHORS
    grid_x, grid_y = values[11], values[12]
    expected_source = source_base + anchor_id * grid_width * grid_height + grid_y * grid_width + grid_x
    if grid_x >= grid_width or grid_y >= grid_height or values[8] != expected_source:
        raise SdPackError("detection record source index is invalid")
    return {
        "image_id": values[0],
        "x1": x1,
        "y1": y1,
        "x2": x2,
        "y2": y2,
        "score": score,
        "class_id": class_id,
        "category_id": values[7],
        "source_index": values[8],
        "head_id": head_id,
        "anchor_id": anchor_id,
        "grid_x": grid_x,
        "grid_y": grid_y,
    }


def _iter_records(
    path: Path,
    section: Section,
    count: int,
    *,
    image_id: int | None,
    confidence: float,
    ordered: bool,
) -> Iterator[dict[str, Any]]:
    previous: tuple[float, int, int] | None = None
    with path.open("rb") as stream:
        stream.seek(section.offset)
        for _ in range(count):
            raw = stream.read(DETECTION_RECORD_BYTES)
            if len(raw) != DETECTION_RECORD_BYTES:
                raise SdPackError("short detection record")
            record = _decode_record(raw, image_id=image_id, confidence=confidence)
            key = (record["score"], record["source_index"], record["class_id"])
            if ordered and previous is not None:
                if key[0] > previous[0] or (
                    key[0] == previous[0]
                    and (key[1] < previous[1] or (key[1] == previous[1] and key[2] < previous[2]))
                ):
                    raise SdPackError("detection records are not in canonical score/source/class order")
            previous = key
            yield record


def parse_detection_package(path: str | Path) -> dict[str, Any]:
    package = read_package_header(path, MAGIC_DETECTIONS)
    w = package.words
    if (
        w[8] == 0
        or w[10] != DETECTION_RECORD_BYTES
        or w[11] != MAX_NMS
        or w[12] != MAX_DETECTIONS
        or w[9] > w[12]
        or w[13] != CLASS_COUNT
        or w[14] != 1
        or w[15] == 0
        or w[16] == 0
        or w[23] != 1
        or w[24] == 0
        or w[25] == 0
        or any(w[26:32])
    ):
        raise SdPackError("detection header shape/format/hash references are invalid")
    records = _validate_section(package, w[17], w[18], w[19], "records", allow_empty=True)
    if records.offset != package.payload_offset or records.bytes != package.payload_bytes:
        raise SdPackError("detection records must cover the exact payload")
    if records.bytes != w[9] * DETECTION_RECORD_BYTES:
        raise SdPackError("detection count and record section size differ")
    profile = _detection_fields(w)
    # Exhaust the iterator here: parse means validation, not merely header decoding.
    for _ in _iter_records(
        package.path,
        records,
        w[9],
        image_id=w[8],
        confidence=profile["confidence_threshold"],
        ordered=True,
    ):
        pass
    return _package_result(
        package,
        {
            "image_id": w[8],
            "detection_count": w[9],
            "max_nms": w[11],
            "max_detections": w[12],
            "raw_head_package_crc32": w[15],
            "input_package_crc32": w[16],
            "records": records.to_dict(),
            "decode_config_crc32": w[24],
            "preprocess_crc32": w[25],
            **profile,
        },
    )


def iter_detection_records(path: str | Path) -> Iterator[dict[str, Any]]:
    """Yield validated product records without retaining the product in memory."""

    parsed = parse_detection_package(path)
    section = Section(**parsed["records"])
    yield from _iter_records(
        Path(parsed["path"]),
        section,
        parsed["detection_count"],
        image_id=parsed["image_id"],
        confidence=parsed["confidence_threshold"],
        ordered=True,
    )


def iter_coco_predictions(path: str | Path) -> Iterator[dict[str, Any]]:
    for record in iter_detection_records(path):
        yield {
            "image_id": record["image_id"],
            "category_id": record["category_id"],
            "bbox": [
                record["x1"],
                record["y1"],
                record["x2"] - record["x1"],
                record["y2"] - record["y1"],
            ],
            "score": record["score"],
        }


def parse_result_package(path: str | Path) -> dict[str, Any]:
    package = read_package_header(path, MAGIC_RESULT)
    w = package.words
    run_id = w[8] | (w[9] << 32)
    if (
        run_id == 0
        or w[10] == 0
        or w[12] not in (0, 1)
        or (w[12] == 0 and w[13] != 0)
        or (w[12] == 1 and w[13] == 0)
        or w[14] == 0
        or w[15] != 0
        or w[11] > w[10] * MAX_DETECTIONS
        or any(value == 0 for value in w[22:28])
        or any(w[28:32])
    ):
        raise SdPackError("result header format/hash references are invalid")
    detections = _validate_section(
        package, w[16], w[17], w[18], "result detections", allow_empty=True
    )
    timings = _validate_section(
        package, w[19], w[20], w[21], "result timings", allow_empty=True
    )
    if _overlap(detections, timings):
        raise SdPackError("result detections and timings overlap")
    if detections.bytes != w[11] * DETECTION_RECORD_BYTES:
        raise SdPackError("result detection count and byte length differ")
    if (
        detections.offset != package.payload_offset
        or timings.offset != detections.offset + detections.bytes
        or timings.offset + timings.bytes != package.total_bytes
    ):
        raise SdPackError("result sections do not tightly cover the payload")
    return _package_result(
        package,
        {
            "run_id": run_id,
            "image_count": w[10],
            "detection_count": w[11],
            "status": "success" if w[12] == 0 else "failure",
            "error_code": w[13],
            "clock_hz": w[14],
            "detections": detections.to_dict(),
            "timings": timings.to_dict(),
            "input_package_crc32": w[22],
            "parameter_package_crc32": w[23],
            "raw_head_package_crc32": w[24],
            "detection_package_crc32": w[25],
            "software_build_crc32": w[26],
            "hardware_build_crc32": w[27],
        },
    )


def iter_result_timing_chunks(
    path: str | Path, *, chunk_bytes: int = COPY_CHUNK_BYTES
) -> Iterator[bytes]:
    """Yield the protocol-defined opaque performance section in chunks."""

    if isinstance(chunk_bytes, bool) or not isinstance(chunk_bytes, int) or chunk_bytes <= 0:
        raise ValueError("chunk_bytes must be a positive integer")
    parsed = parse_result_package(path)
    section = Section(**parsed["timings"])
    remaining = section.bytes
    with Path(parsed["path"]).open("rb") as stream:
        stream.seek(section.offset)
        while remaining:
            chunk = stream.read(min(chunk_bytes, remaining))
            if not chunk:
                raise SdPackError("short read in result timing section")
            remaining -= len(chunk)
            yield chunk


def copy_package_section(
    package_path: str | Path,
    section: Mapping[str, Any] | Section,
    destination: str | Path,
) -> dict[str, Any]:
    """Atomically extract a validated section without buffering it."""

    package = read_package_header(package_path)
    if isinstance(section, Section):
        selected = section
    elif isinstance(section, Mapping):
        selected = Section(
            _integer(section.get("offset"), "section.offset"),
            _integer(section.get("bytes"), "section.bytes"),
            _integer(section.get("crc32"), "section.crc32"),
        )
    else:
        raise TypeError("section must be a Section or mapping")
    selected = _validate_section(
        package,
        selected.offset,
        selected.bytes,
        selected.crc32,
        "selected",
        allow_empty=True,
    )
    output = Path(destination)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix=f".{output.name}.", suffix=".tmp", dir=output.parent, delete=False
        ) as target, package.path.open("rb") as source:
            temporary = Path(target.name)
            source.seek(selected.offset)
            remaining = selected.bytes
            while remaining:
                chunk = source.read(min(COPY_CHUNK_BYTES, remaining))
                if not chunk:
                    raise SdPackError("short package section read")
                target.write(chunk)
                remaining -= len(chunk)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, output)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return {
        "path": str(output.resolve()),
        "bytes": output.stat().st_size,
        "crc32": crc32_file(output),
        "sha256": sha256_file(output),
    }


def _equal_ranges(
    left_path: Path,
    left: Section,
    right_path: Path,
    right: Section,
) -> bool:
    if left.bytes != right.bytes:
        return False
    remaining = left.bytes
    with left_path.open("rb") as a, right_path.open("rb") as b:
        a.seek(left.offset)
        b.seek(right.offset)
        while remaining:
            size = min(COPY_CHUNK_BYTES, remaining)
            left_chunk = a.read(size)
            right_chunk = b.read(size)
            if len(left_chunk) != size or len(right_chunk) != size:
                raise SdPackError("short read while comparing linked sections")
            if left_chunk != right_chunk:
                return False
            remaining -= size
    return True


def validate_pipeline_chain(
    input_package: str | Path,
    parameter_package: str | Path,
    raw_head_package: str | Path,
    detection_package: str | Path,
    result_package: str | Path,
) -> dict[str, Any]:
    """Mirror ``coco80_sd_validate_pipeline`` with streaming file access."""

    input_data = parse_input_package(input_package)
    parameter_data = parse_parameter_package(parameter_package)
    raw_data = parse_raw_head_package(raw_head_package)
    detection_data = parse_detection_package(detection_package)
    result_data = parse_result_package(result_package)
    input_crc = input_data["package_crc32"]
    parameter_crc = parameter_data["package_crc32"]
    raw_crc = raw_data["package_crc32"]
    detection_crc = detection_data["package_crc32"]
    checks = (
        (raw_data["input_package_crc32"], input_crc, "raw->input"),
        (raw_data["parameter_package_crc32"], parameter_crc, "raw->parameters"),
        (detection_data["input_package_crc32"], input_crc, "detections->input"),
        (detection_data["raw_head_package_crc32"], raw_crc, "detections->raw"),
        (result_data["input_package_crc32"], input_crc, "result->input"),
        (result_data["parameter_package_crc32"], parameter_crc, "result->parameters"),
        (result_data["raw_head_package_crc32"], raw_crc, "result->raw"),
        (result_data["detection_package_crc32"], detection_crc, "result->detections"),
    )
    for actual, expected, label in checks:
        if actual != expected:
            raise SdPackError(f"CRC32 link mismatch at {label}")
    detection_section = Section(**detection_data["records"])
    result_section = Section(**result_data["detections"])
    if (
        detection_data["image_id"] != input_data["image_id"]
        or result_data["image_count"] != 1
        or result_data["detection_count"] != detection_data["detection_count"]
        or result_section.crc32 != detection_section.crc32
        or not _equal_ranges(
            Path(detection_data["path"]),
            detection_section,
            Path(result_data["path"]),
            result_section,
        )
    ):
        raise SdPackError("pipeline detection payload/image/count link mismatch")
    for record in iter_detection_records(detection_package):
        if record["x2"] > input_data["original_width"] or record["y2"] > input_data["original_height"]:
            raise SdPackError("pipeline detection lies outside the original image")
    return {
        "status": "ok",
        "image_id": input_data["image_id"],
        "run_id": result_data["run_id"],
        "detection_count": detection_data["detection_count"],
        "crc32_chain": {
            "input": input_crc,
            "parameters": parameter_crc,
            "raw_heads": raw_crc,
            "detections": detection_crc,
            "result": result_data["package_crc32"],
        },
        "sha256_chain": {
            "input": input_data["sha256"],
            "parameters": parameter_data["sha256"],
            "raw_heads": raw_data["sha256"],
            "detections": detection_data["sha256"],
            "result": result_data["sha256"],
        },
    }


# Descriptive compatibility aliases.
parse_raw_heads = parse_raw_head_package
parse_product = parse_detection_package
parse_performance_result = parse_result_package
validate_crc_chain = validate_pipeline_chain


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build and validate COCO80 SD packages")
    sub = parser.add_subparsers(dest="command", required=True)
    inspect_parser = sub.add_parser("inspect", help="validate and describe one package")
    inspect_parser.add_argument("package", type=Path)
    inputs_parser = sub.add_parser("inputs", help="build fixed-416 input packages from COCO JSON")
    inputs_parser.add_argument("--annotations", required=True, type=Path)
    inputs_parser.add_argument("--image-root", required=True, type=Path)
    inputs_parser.add_argument("--output", required=True, type=Path)
    inputs_parser.add_argument("--input-scale", required=True, type=float)
    inputs_parser.add_argument("--input-zero-point", required=True, type=int)
    inputs_parser.add_argument("--expected-count", type=int, default=5000)
    inputs_parser.add_argument(
        "--shard-bytes", type=int, default=1024 * 1024 * 1024,
        help="maximum bytes per shard (each shard remains below 4 GiB)",
    )
    inputs_parser.add_argument(
        "--individual", action="store_true",
        help="write one file per input instead of the default bare-metal shard set",
    )
    parameter_parser = sub.add_parser("parameters", help="wrap four parameter sections")
    parameter_parser.add_argument("--output", required=True, type=Path)
    parameter_parser.add_argument("--weights", required=True, type=Path)
    parameter_parser.add_argument("--biases", required=True, type=Path)
    parameter_parser.add_argument("--activation-luts", required=True, type=Path)
    parameter_parser.add_argument("--quantization", required=True, type=Path)
    parameter_parser.add_argument("--model-sha256")
    chain_parser = sub.add_parser("validate-chain", help="validate five linked packages")
    for name in ("input", "parameters", "raw-heads", "detections", "result"):
        chain_parser.add_argument(f"--{name}", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "inspect":
            common = read_package_header(args.package)
            parser_for_magic = {
                MAGIC_INPUT: parse_input_package,
                MAGIC_PARAMETERS: parse_parameter_package,
                MAGIC_RAW_HEADS: parse_raw_head_package,
                MAGIC_DETECTIONS: parse_detection_package,
                MAGIC_RESULT: parse_result_package,
            }[common.magic]
            result = parser_for_magic(args.package)
        elif args.command == "inputs":
            if args.individual:
                result = build_input_packages_from_coco(
                    args.annotations,
                    args.image_root,
                    args.output,
                    input_scale=args.input_scale,
                    input_zero_point=args.input_zero_point,
                    expected_count=args.expected_count,
                )
            else:
                result = build_input_shards_from_coco(
                    args.annotations,
                    args.image_root,
                    args.output,
                    input_scale=args.input_scale,
                    input_zero_point=args.input_zero_point,
                    expected_count=args.expected_count,
                    shard_target_bytes=args.shard_bytes,
                )
        elif args.command == "parameters":
            result = pack_parameter_package(
                args.output,
                weights=args.weights,
                biases=args.biases,
                activation_luts=args.activation_luts,
                quantization=args.quantization,
                model_sha256=args.model_sha256,
            ).to_dict()
        else:
            result = validate_pipeline_chain(
                args.input,
                args.parameters,
                args.raw_heads,
                args.detections,
                args.result,
            )
        print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))
        return 0
    except (OSError, ValueError, TypeError, SdPackError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())

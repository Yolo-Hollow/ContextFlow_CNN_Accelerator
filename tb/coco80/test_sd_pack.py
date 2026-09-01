from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

from tools.coco80.sd_pack import (
    BINDING_BYTES,
    HEADER_BYTES,
    INPUT_TENSOR_BYTES,
    MAGIC_INPUT,
    MAGIC_OUTPUT_INDEX,
    MAGIC_NODE_INDEX,
    NODE_INDEX_ENTRY,
    NODE_INDEX_HEADER,
    OUTPUT_INDEX_ENTRY,
    OUTPUT_INDEX_HEADER,
    P4_BYTES,
    P5_BYTES,
    SdPackError,
    build_input_shards,
    crc32_file,
    pack_input_image,
    pack_input_tensor,
    pack_parameter_package,
    pack_raw_heads,
    parse_input_binary_index,
    parse_input_package,
    parse_parameter_package,
    parse_raw_head_package,
    validate_input_shard_set,
    validate_board_output_index,
    validate_board_node_index,
)


def _fake_pack_input_image(source_image, destination, *, image_id, input_scale, input_zero_point):
    source = Path(source_image)
    source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
    package = pack_input_tensor(
        bytes([image_id & 0xFF]) * INPUT_TENSOR_BYTES,
        destination,
        image_id=image_id,
        original_width=416,
        original_height=416,
        input_scale=input_scale,
        input_zero_point=input_zero_point,
        letterbox_scale=1.0,
        pad_x=0,
        pad_y=0,
        source_sha256=source_sha,
    )
    return {
        "image_id": image_id,
        "source_name": source.name,
        "source_sha256": source_sha,
        "letterbox": {
            "schema": "coco80.letterbox.v1",
            "source_width": 416,
            "source_height": 416,
            "model_width": 416,
            "model_height": 416,
            "resized_width": 416,
            "resized_height": 416,
            "scale": 1.0,
            "pad_left": 0,
            "pad_top": 0,
            "pad_right": 0,
            "pad_bottom": 0,
            "fill": 114,
            "pixel_format": "RGB",
            "resample": "PIL.BILINEAR",
        },
        "package": package.to_dict(),
    }


class SdPackTests(unittest.TestCase):
    def test_input_image_is_quantized_into_reduced_range(self):
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow is unavailable")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.png"
            package = root / "input.bin"
            Image.new("RGB", (2, 2), (255, 114, 0)).save(source)
            built = pack_input_image(
                source,
                package,
                image_id=7,
                input_scale=1.0 / 127.0,
                input_zero_point=0,
            )
            payload = package.read_bytes()[HEADER_BYTES:]
            self.assertEqual((min(payload), max(payload)), (0, 127))
            self.assertEqual(built["input_quant_range"], [0, 127])
            self.assertIn(57, payload)

    def test_input_tensor_rejects_values_above_reduced_range(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(SdPackError, "reduced uint8 range"):
                pack_input_tensor(
                    bytes([128]) * INPUT_TENSOR_BYTES,
                    Path(temporary) / "input.bin",
                    image_id=1,
                    original_width=416,
                    original_height=416,
                    input_scale=1.0 / 127.0,
                    input_zero_point=0,
                    letterbox_scale=1.0,
                    pad_x=0,
                    pad_y=0,
                    source_sha256=hashlib.sha256(b"source").hexdigest(),
                )

    def test_input_header_is_exact_little_endian_and_tamper_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "input.bin"
            built = pack_input_tensor(
                bytes([114]) * INPUT_TENSOR_BYTES,
                package,
                image_id=42,
                original_width=10,
                original_height=6,
                input_scale=1.0 / 255.0,
                input_zero_point=0,
                letterbox_scale=41.6,
                pad_x=0,
                pad_y=83,
                source_sha256=hashlib.sha256(b"source").hexdigest(),
            )
            raw = package.read_bytes()
            self.assertEqual(len(raw), HEADER_BYTES + INPUT_TENSOR_BYTES)
            words = struct.unpack("<32I", raw[:HEADER_BYTES])
            self.assertEqual(words[0], MAGIC_INPUT)
            self.assertEqual(words[1:5], (1, 128, len(raw), 128))
            self.assertEqual(words[8], 42)
            self.assertEqual(parse_input_package(package)["image_id"], 42)
            self.assertEqual(built.package_crc32, crc32_file(package))

            changed = bytearray(raw)
            changed[-1] ^= 1
            package.write_bytes(changed)
            with self.assertRaisesRegex(SdPackError, "payload CRC32"):
                parse_input_package(package)

    def test_versioned_shards_binary_index_and_hash_closure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            records = []
            for image_id, size in ((3, (12, 8)), (7, (8, 12)), (11, (9, 9))):
                path = root / f"{image_id}.source"
                path.write_bytes(struct.pack("<III", image_id, *size))
                records.append((image_id, path))
            output = root / "sd"
            with patch("tools.coco80.sd_pack.pack_input_image", _fake_pack_input_image):
                manifest = build_input_shards(
                    records,
                    output,
                    input_scale=0.125,
                    input_zero_point=7,
                    expected_count=3,
                    shard_target_bytes=HEADER_BYTES + INPUT_TENSOR_BYTES,
                )
            self.assertEqual(manifest["image_count"], 3)
            self.assertEqual(manifest["shard_count"], 3)
            binary = parse_input_binary_index(output / "input_index.bin")
            self.assertEqual([row["image_id"] for row in binary["entries"]], [3, 7, 11])
            verified = validate_input_shard_set(output / "input_index.json")
            self.assertEqual(verified["status"], "ok")

            manifest_path = output / "input_index.json"
            manifest_raw = manifest_path.read_bytes()
            manifest_data = json.loads(manifest_raw)
            del manifest_data["input_quant_range"]
            manifest_path.write_text(
                json.dumps(manifest_data, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(SdPackError, "reduced uint8 range"):
                validate_input_shard_set(manifest_path)
            manifest_path.write_bytes(manifest_raw)

            shard = output / manifest["shards"][1]["path"]
            with shard.open("r+b") as stream:
                stream.seek(-1, 2)
                value = stream.read(1)
                stream.seek(-1, 2)
                stream.write(bytes([value[0] ^ 1]))
            with self.assertRaisesRegex(SdPackError, "shard 1 (CRC32|SHA256)"):
                validate_input_shard_set(output / "input_index.json")

    def test_parameter_and_raw_head_packages_bind_whole_package_crc(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            input_path = root / "input.bin"
            pack_input_tensor(
                bytes([10]) * INPUT_TENSOR_BYTES,
                input_path,
                image_id=1,
                original_width=16,
                original_height=16,
                input_scale=0.25,
                input_zero_point=3,
                letterbox_scale=26.0,
                pad_x=0,
                pad_y=0,
                source_sha256=hashlib.sha256(b"source").hexdigest(),
            )
            sections = {}
            for name, content in {
                "weights": bytes(range(64)),
                "biases": b"bias" * 8,
                "luts": bytes(range(256)) * 13,
                "quant": bytes(BINDING_BYTES),
            }.items():
                path = root / f"{name}.bin"
                path.write_bytes(content)
                sections[name] = path
            parameter_path = root / "parameters.bin"
            model_sha = hashlib.sha256(b"model").hexdigest()
            pack_parameter_package(
                parameter_path,
                weights=sections["weights"],
                biases=sections["biases"],
                activation_luts=sections["luts"],
                quantization=sections["quant"],
                model_sha256=model_sha,
            )
            parameters = parse_parameter_package(parameter_path)
            self.assertEqual(parameters["model_sha256"], model_sha)
            self.assertEqual(parameters["sections"]["weights"]["offset"], 128)

            p4 = root / "p4.bin"
            p5 = root / "p5.bin"
            p4.write_bytes(bytes([4]) * P4_BYTES)
            p5.write_bytes(bytes([5]) * P5_BYTES)
            raw_path = root / "raw.bin"
            pack_raw_heads(
                raw_path,
                p4=p4,
                p5=p5,
                p4_scale=0.125,
                p4_zero_point=11,
                p5_scale=0.25,
                p5_zero_point=12,
                input_package=input_path,
                parameter_package=parameter_path,
            )
            raw = parse_raw_head_package(raw_path)
            self.assertEqual(raw["input_package_crc32"], crc32_file(input_path))
            self.assertEqual(raw["parameter_package_crc32"], crc32_file(parameter_path))
            self.assertEqual(raw["heads"]["p4"]["bytes"], P4_BYTES)
            self.assertEqual(raw["heads"]["p5"]["bytes"], P5_BYTES)

    def test_exact_count_gate_does_not_publish_json_index(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = root / "one.source"
            image.write_bytes(b"one")
            with patch("tools.coco80.sd_pack.pack_input_image", _fake_pack_input_image):
                with self.assertRaisesRegex(SdPackError, "expected exactly 2"):
                    build_input_shards(
                        [(1, image)],
                        root / "sd",
                        input_scale=1.0,
                        input_zero_point=0,
                        expected_count=2,
                    )
            self.assertFalse((root / "sd" / "input_index.json").exists())

    def test_board_performance_output_index_is_fully_crc_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data_path = root / "timings.bin"
            index_path = root / "output_index.bin"
            data = bytes(range(64)) + bytes(reversed(range(64)))
            data_path.write_bytes(data)
            rows = b"".join(
                OUTPUT_INDEX_ENTRY.pack(
                    image_id,
                    20 + index,
                    index * 64,
                    64,
                    zlib.crc32(data[index * 64 : (index + 1) * 64]) & 0xFFFFFFFF,
                    index,
                    index + 100,
                    0,
                )
                for index, image_id in enumerate((101, 202))
            )
            words = [0] * 32
            words[:16] = [
                MAGIC_OUTPUT_INDEX,
                1,
                128,
                2,
                22,
                2,
                32,
                len(rows),
                len(data),
                zlib.crc32(data) & 0xFFFFFFFF,
                zlib.crc32(rows) & 0xFFFFFFFF,
                1,
                2,
                3,
                4,
                0,
            ]
            header = bytearray(OUTPUT_INDEX_HEADER.pack(*words))
            words[15] = zlib.crc32(header) & 0xFFFFFFFF
            index_path.write_bytes(OUTPUT_INDEX_HEADER.pack(*words) + rows)
            parsed = validate_board_output_index(index_path, data_path)
            self.assertEqual(parsed["mode"], 2)
            self.assertEqual(parsed["output_records"], 2)
            self.assertEqual(parsed["entries"][1]["record_index"], 21)
            with data_path.open("r+b") as stream:
                stream.seek(-1, 2)
                value = stream.read(1)
                stream.seek(-1, 2)
                stream.write(bytes([value[0] ^ 1]))
            with self.assertRaisesRegex(SdPackError, "data CRC32"):
                validate_board_output_index(index_path, data_path)

    def test_board_conformance_node_stream_requires_all_22_ordered_tensors(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data_path = root / "nodes.bin"
            index_path = root / "node_index.bin"
            data = bytes(range(22))
            data_path.write_bytes(data)
            rows = b"".join(
                NODE_INDEX_ENTRY.pack(77, tensor_id, tensor_id, 1,
                                      zlib.crc32(data[tensor_id:tensor_id + 1]) & 0xFFFFFFFF,
                                      tensor_id)
                for tensor_id in range(22)
            )
            words = [0] * 32
            words[:16] = [
                MAGIC_NODE_INDEX, 1, 128, 1, 22, 24, len(rows), len(data),
                zlib.crc32(data) & 0xFFFFFFFF, zlib.crc32(rows) & 0xFFFFFFFF,
                1, 2, 3, 4, 22, 0,
            ]
            words[15] = zlib.crc32(NODE_INDEX_HEADER.pack(*words)) & 0xFFFFFFFF
            index_path.write_bytes(NODE_INDEX_HEADER.pack(*words) + rows)
            parsed = validate_board_node_index(index_path, data_path)
            self.assertEqual(parsed["image_records"], 1)
            self.assertEqual(parsed["node_records"], 22)
            changed = bytearray(index_path.read_bytes())
            changed[128 + 24 + 4] = 3
            index_path.write_bytes(changed)
            with self.assertRaisesRegex(SdPackError, "entry-table CRC32"):
                validate_board_node_index(index_path, data_path)



if __name__ == "__main__":
    unittest.main()

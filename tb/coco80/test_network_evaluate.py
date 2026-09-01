from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import zlib

from PIL import Image

from tools.coco80.assets import sha256_file, write_json_atomic
from tools.coco80.network_evaluate import run_evaluation
from tools.coco80.sd_pack import (
    MAGIC_DETECTIONS, OUTPUT_INDEX_ENTRY, OUTPUT_INDEX_HEADER, P4_BYTES,
    P5_BYTES, build_input_shards, crc32_file, pack_parameter_package,
    pack_raw_heads,
)


def _f32(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def _header_crc(words: list[int]) -> bytes:
    words[15] = 0
    raw = bytearray(OUTPUT_INDEX_HEADER.pack(*words))
    words[15] = zlib.crc32(raw) & 0xFFFFFFFF
    return OUTPUT_INDEX_HEADER.pack(*words)


def _empty_detection(image_id: int, input_crc: int, raw_crc: int) -> bytes:
    words = [0] * 32
    words[:26] = [
        MAGIC_DETECTIONS, 1, 128, 128, 128, 0, 0, 0,
        image_id, 0, 64, 30000, 300, 80, 1, raw_crc, input_crc,
        128, 0, 0, _f32(0.001), _f32(0.65), 1, 1, 2, 3,
    ]
    raw = bytearray(struct.pack("<32I", *words))
    words[7] = zlib.crc32(raw) & 0xFFFFFFFF
    return struct.pack("<32I", *words)


class NetworkEvaluateTests(unittest.TestCase):
    def test_empty_product_is_exactly_equal_to_canonical(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "000000000007.jpg"
            Image.new("RGB", (8, 6), (20, 30, 40)).save(source)
            inputs = root / "inputs"
            input_manifest = build_input_shards(
                [(7, source)], inputs, input_scale=1.0 / 127.0,
                input_zero_point=0, expected_count=1,
            )
            input_crc = input_manifest["entries"][0]["package"]["package_crc32"]
            files = []
            for name, size in (
                ("weights", 13 * 64), ("biases", 13 * 64),
                ("luts", 13 * 256), ("bindings", 13 * 15 * 4),
            ):
                path = root / f"{name}.bin"; path.write_bytes(bytes(size)); files.append(path)
            parameter_path = root / "parameters.c8pa"
            parameter = pack_parameter_package(
                parameter_path, weights=files[0], biases=files[1],
                activation_luts=files[2], quantization=files[3], model_sha256="11" * 32,
            )
            quant_path = root / "quantization_manifest.json"
            layers = []
            for index in range(13):
                name = "p4_detect" if index == 11 else "p5_detect" if index == 12 else f"l{index}"
                shape = [26, 26, 255] if index == 11 else [13, 13, 255] if index == 12 else [1, 1, 1]
                layers.append({
                    "name": name, "ofm_hwc": shape,
                    "quant": {"output": {"qmin": 0, "qmax": 127, "scale": 0.25, "zero_point": 127}},
                })
            write_json_atomic(quant_path, {
                "format": "kv260-coco80-rtl-quantization", "version": 1,
                "activation_quant_range": [0, 127],
                "weight_qscheme": "per_tensor_symmetric_s8_zp0", "layers": layers,
            })
            p4 = root / "p4.bin"; p4.write_bytes(bytes(P4_BYTES))
            p5 = root / "p5.bin"; p5.write_bytes(bytes(P5_BYTES))
            raw_package = root / "one.c8rh"
            packed_raw = pack_raw_heads(
                raw_package, p4=p4, p5=p5, p4_scale=0.25, p4_zero_point=127,
                p5_scale=0.25, p5_zero_point=127, input_package=input_crc,
                parameter_package=parameter.package_crc32,
            )
            raw_dir = root / "raw"; raw_dir.mkdir()
            raw_data = raw_dir / "raw_heads.bin"; raw_data.write_bytes(raw_package.read_bytes())
            row = OUTPUT_INDEX_ENTRY.pack(
                7, 0, 0, raw_data.stat().st_size, packed_raw.package_crc32, 0, 100, 0
            )
            words = [0] * 32
            words[:17] = [
                int.from_bytes(b"C8OX", "little"), 2, 128, 0, 1, 1, 32, len(row),
                raw_data.stat().st_size, crc32_file(raw_data), zlib.crc32(row) & 0xFFFFFFFF,
                parameter.package_crc32, crc32_file(inputs / "input_index.bin"), 12, 13, 0, 0,
            ]
            (raw_dir / "output_index.bin").write_bytes(_header_crc(words) + row)

            detection = _empty_detection(7, input_crc, packed_raw.package_crc32)
            network = root / "network"; network.mkdir()
            detection_file = network / "detections.bin"; detection_file.write_bytes(detection)
            write_json_atomic(network / "results_index.json", {
                "format": "kv260-coco80-ethernet-validation.results-index", "version": 1,
                "mode": "detections-accuracy", "first_record": 0, "record_count": 1,
                "entries": [{
                    "image_id": 7, "record_index": 0, "offset": 0,
                    "bytes": len(detection), "crc32": zlib.crc32(detection) & 0xFFFFFFFF,
                    "detection_count": 0, "total_ticks": 100,
                }],
            })
            write_json_atomic(network / "summary.json", {
                "format": "kv260-coco80-ethernet-validation", "version": 1,
                "status": "PASS", "mode": "detections-accuracy",
                "first_record": 0, "record_count": 1,
                "artifacts": {"results": {
                    "path": str(detection_file), "bytes": len(detection),
                    "sha256": sha256_file(detection_file),
                }},
            })
            annotations = root / "annotations.json"; annotations.write_text("{}")
            output = root / "evaluation"
            args = argparse.Namespace(
                network_output=network, canonical_raw_output=raw_dir,
                input_index_json=inputs / "input_index.json",
                quantization_manifest=quant_path, parameter_package=parameter_path,
                annotations=annotations, output_dir=output, device="cpu",
                score_tolerance=2e-5, box_tolerance=1e-3, metric_tolerance=1e-6,
            )
            metrics = {"metrics": {"AP50_95": 0.0, "AP50": 0.0}}
            with mock.patch("tools.coco80.network_evaluate.evaluate_coco_detailed", return_value=metrics):
                summary = run_evaluation(args)
            self.assertEqual(summary["status"], "PASS")
            self.assertEqual(summary["images"], 1)
            self.assertEqual(json.loads((output / "board_predictions.json").read_text()), [])


if __name__ == "__main__":
    unittest.main()

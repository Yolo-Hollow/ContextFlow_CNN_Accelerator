from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import zlib

import numpy as np
from PIL import Image

from tools.coco80.assets import sha256_file, write_json_atomic
from tools.coco80.board_evaluate import BoardEvaluationError, run_board_evaluation
from tools.coco80.sd_pack import (
    OUTPUT_INDEX_ENTRY,
    OUTPUT_INDEX_HEADER,
    P4_BYTES,
    P5_BYTES,
    build_input_shards,
    crc32_file,
    pack_parameter_package,
    pack_raw_heads,
)


def _crc_header(words: list[int]) -> bytes:
    raw = bytearray(OUTPUT_INDEX_HEADER.pack(*words))
    raw[15 * 4 : 16 * 4] = bytes(4)
    words[15] = zlib.crc32(raw) & 0xFFFFFFFF
    return OUTPUT_INDEX_HEADER.pack(*words)


class BoardEvaluateTest(unittest.TestCase):
    def test_vitis_json_with_utf8_bom_is_accepted(self):
        from tools.coco80.board_evaluate import _load_json

        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "powershell.json"
            path.write_bytes(b"\xef\xbb\xbf{\"mode\":\"accuracy\"}\r\n")
            _target, value = _load_json(path, "PowerShell manifest")
            self.assertEqual(value, {"mode": "accuracy"})

    def test_one_record_evaluation_is_bound_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "000000000001.jpg"
            Image.new("RGB", (8, 6), (20, 40, 60)).save(source)
            inputs = root / "inputs"
            built = build_input_shards(
                [(1, source)], inputs, input_scale=1.0 / 127.0, input_zero_point=0, expected_count=1
            )
            input_manifest = json.loads((inputs / "input_index.json").read_text())
            input_crc = input_manifest["entries"][0]["package"]["package_crc32"]

            quant = root / "quantization_manifest.json"
            layers = []
            for index in range(13):
                name = "p4_detect" if index == 11 else "p5_detect" if index == 12 else f"l{index}"
                shape = [26, 26, 255] if index == 11 else [13, 13, 255] if index == 12 else [1, 1, 1]
                layers.append(
                    {
                        "name": name,
                        "ofm_hwc": shape,
                        "quant": {"output": {"qmin": 0, "qmax": 127, "scale": 0.25, "zero_point": 127}},
                    }
                )
            write_json_atomic(
                quant,
                {
                    "format": "kv260-coco80-rtl-quantization",
                    "version": 1,
                    "activation_quant_range": [0, 127],
                    "weight_qscheme": "per_tensor_symmetric_s8_zp0",
                    "layers": layers,
                },
            )
            weights = root / "weights.bin"
            biases = root / "biases.bin"
            luts = root / "luts.bin"
            bindings = root / "bindings.bin"
            weights.write_bytes(bytes(13 * 64))
            biases.write_bytes(bytes(13 * 64))
            luts.write_bytes(bytes(13 * 256))
            bindings.write_bytes(bytes(13 * 15 * 4))
            parameter_package = root / "parameters.bin"
            parameter = pack_parameter_package(
                parameter_package,
                weights=weights,
                biases=biases,
                activation_luts=luts,
                quantization=bindings,
                model_sha256="11" * 32,
            )
            p4 = root / "p4.bin"
            p5 = root / "p5.bin"
            p4.write_bytes(bytes(P4_BYTES))
            p5.write_bytes(bytes(P5_BYTES))
            raw = root / "raw_heads.bin"
            package = pack_raw_heads(
                raw,
                p4=p4,
                p5=p5,
                p4_scale=0.25,
                p4_zero_point=127,
                p5_scale=0.25,
                p5_zero_point=127,
                input_package=input_crc,
                parameter_package=parameter.package_crc32,
            )
            row = OUTPUT_INDEX_ENTRY.pack(1, 0, 0, raw.stat().st_size, package.package_crc32, 300, 123, 0)
            words = [0] * 32
            words[:17] = [
                int.from_bytes(b"C8OX", "little"), 2, 128, 0, 1, 1, 32, len(row),
                raw.stat().st_size, crc32_file(raw), zlib.crc32(row) & 0xFFFFFFFF,
                parameter.package_crc32, crc32_file(inputs / "input_index.bin"), 7, 8, 0, 0,
            ]
            index = root / "output_index.bin"
            index.write_bytes(_crc_header(words) + row)
            parameter_manifest = root / "parameter_manifest.json"
            write_json_atomic(parameter_manifest, {"test": True})
            bit = root / "test.bit"
            xsa = root / "test.xsa"
            elf = root / "test.elf"
            annotations = root / "annotations.json"
            reference = root / "reference.json"
            for path, data in ((bit, b"bit"), (xsa, b"xsa"), (elf, b"elf"), (annotations, b"{}")):
                path.write_bytes(data)
            coco = {
                "metrics": {"AP50": 0.0, "AP50_95": 0.0},
                "per_class": [
                    {"class_index": i, "category_id": i + 1, "name": str(i), "AP50": 0.0, "AP50_95": 0.0}
                    for i in range(80)
                ],
            }
            write_json_atomic(reference, {"images": 5000, "coco": coco})
            runner = root / "runner.json"
            write_json_atomic(
                runner,
                {
                    "format": "kv260-coco80-vitis-elf",
                    "version": 1,
                    "mode": "accuracy",
                    "image_limit": 1,
                    "release_eligible": False,
                    "deployment_override": True,
                    "git_sha": "22" * 20,
                    "quantization_manifest_sha256": sha256_file(quant),
                    "parameter_manifest_sha256": sha256_file(parameter_manifest),
                    "sd_parameter_package_sha256": sha256_file(parameter_package),
                    "bit_sha256": sha256_file(bit),
                    "xsa_sha256": sha256_file(xsa),
                    "elf": {"path": str(elf), "bytes": elf.stat().st_size, "sha256": sha256_file(elf)},
                },
            )
            args = argparse.Namespace(
                board_output=root,
                input_index_json=inputs / "input_index.json",
                input_index_bin=inputs / "input_index.bin",
                quant_manifest=quant,
                parameter_manifest=parameter_manifest,
                parameter_package=parameter_package,
                runner_manifest=runner,
                bit=bit,
                xsa=xsa,
                elf=elf,
                annotations=annotations,
                reference_summary=reference,
                output_dir=root / "result",
                device="cpu",
                batch_size=1,
                expected_count=1,
                metric_tolerance=0.0,
                require_clean_git=False,
            )
            with mock.patch("tools.coco80.board_evaluate.evaluate_coco_detailed", return_value=coco), mock.patch(
                "tools.coco80.board_evaluate._compare_reference",
                return_value={"pass": True, "tolerance": 0.0},
            ):
                summary = run_board_evaluation(args)
            self.assertEqual(summary["status"], "PASS")
            self.assertEqual(summary["images"], 1)
            self.assertEqual(summary["board"]["raw_heads"]["bytes"], 128 + P4_BYTES + P5_BYTES)
            self.assertEqual(json.loads((root / "result" / "predictions.json").read_text()), [])

            corrupted = bytearray(index.read_bytes())
            struct.pack_into("<I", corrupted, 13 * 4, 0)
            index.write_bytes(corrupted)
            args.output_dir = root / "must_not_exist"
            with self.assertRaisesRegex(Exception, "header is invalid"):
                run_board_evaluation(args)
            self.assertFalse(args.output_dir.exists())


if __name__ == "__main__":
    unittest.main()

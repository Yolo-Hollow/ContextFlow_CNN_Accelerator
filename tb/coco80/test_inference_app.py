from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image

from tools.coco80.assets import write_json_atomic
from tools.coco80.inference_app import (
    RUN_PATH,
    InferenceAppError,
    read_input_qparams,
    timing_to_dict,
    validate_uploaded_image,
)
from tools.coco80.net_protocol import (
    DECODE_DEMO,
    EXTENDED_TIMING,
    EXTENDED_TIMING_BYTES,
    EXTENDED_TIMING_MAGIC,
    EXTENDED_TIMING_VERSION,
    OUTPUT_DETECTIONS,
    ExtendedTiming,
)


class InferenceAppTests(unittest.TestCase):
    def test_result_route_accepts_generated_request_id(self) -> None:
        request_id = "20260817T110637_036194Z_9ef41d1689"
        match = RUN_PATH.fullmatch(f"/runs/{request_id}/visualization.jpg")
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), request_id)

    def test_image_validation_accepts_png_and_rejects_arbitrary_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "image.png"
            Image.new("RGB", (23, 17), (10, 20, 30)).save(image)
            info = validate_uploaded_image(image.read_bytes())
            self.assertEqual((info["format"], info["width"], info["height"]), ("PNG", 23, 17))
            self.assertEqual(len(info["sha256"]), 64)
        with self.assertRaises(InferenceAppError):
            validate_uploaded_image(b"not an image")

    def test_input_qparams_are_strict_reduced_u8(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "quantization_manifest.json"
            layers = [{"name": "m0", "quant": {"input": {
                "scale": 1.0 / 127.0, "zero_point": 0, "qmin": 0, "qmax": 127,
            }}}] + [{"name": f"layer{index}"} for index in range(1, 13)]
            write_json_atomic(path, {
                "format": "kv260-coco80-rtl-quantization", "layers": layers,
            })
            self.assertEqual(read_input_qparams(path)["zero_point"], 0)
            payload = json.loads(path.read_text())
            payload["layers"][0]["quant"]["input"]["qmax"] = 255
            write_json_atomic(path, payload)
            with self.assertRaises(InferenceAppError):
                read_input_qparams(path)

    def test_extended_timing_is_named_and_converted_to_milliseconds(self) -> None:
        raw = EXTENDED_TIMING.pack(
            EXTENDED_TIMING_MAGIC, EXTENDED_TIMING_VERSION, EXTENDED_TIMING_BYTES,
            7, 1, 100_000_000, OUTPUT_DETECTIONS, DECODE_DEMO,
            4_000_000, 2_500_000, 1_500_000, 300_000, 100_000, 20_000, 180_000,
            *([100_000] * 13), *([50_000] * 10), 3, 13, 0, 1234,
        )
        timing = ExtendedTiming.unpack(raw)
        result = timing_to_dict(timing)
        self.assertEqual(result["resident_ms"], 40.0)
        self.assertEqual(result["pl_ms"], 25.0)
        self.assertEqual(result["pl_layers_ms"]["p5_detect"], 1.0)
        self.assertEqual(result["a53_ops_ms"]["pool1"], 0.5)
        self.assertEqual(result["output_crc32"], "000004d2")


if __name__ == "__main__":
    unittest.main()

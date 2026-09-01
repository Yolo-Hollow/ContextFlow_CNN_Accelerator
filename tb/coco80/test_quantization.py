import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import torch

from tools.coco80.quantization import (
    TensorQParams,
    activation_lut,
    save_quant_checkpoint,
    solve_multiplier,
)


class QuantizationTest(unittest.TestCase):
    def test_multiplier_is_representable_and_precise(self):
        for value in (2.0 ** -30, 0.000123, 0.125, 0.999, 1.999):
            mult, shift, represented, error = solve_multiplier(value)
            self.assertGreaterEqual(mult, 1)
            self.assertLessEqual(mult, 65535)
            self.assertIn(shift, range(16))
            self.assertAlmostEqual(represented, mult / (2 ** (15 + shift)))
            self.assertLessEqual(error, 1.0 / (2 ** (15 + shift + 1)) + 1e-15)

    def test_identity_lut_uses_twos_complement_index(self):
        output = TensorQParams(scale=0.25, zero_point=64, qmin=0, qmax=127)
        lut = activation_lut(0.25, output, "identity")
        self.assertEqual(len(lut), 256)
        self.assertEqual(lut[0], 64)
        self.assertEqual(lut[1], 65)
        self.assertEqual(lut[255], 63)
        self.assertEqual(lut[127], 127)
        self.assertEqual(lut[128], 0)

    def test_leaky_lut(self):
        output = TensorQParams(scale=0.1, zero_point=10, qmin=0, qmax=127)
        lut = activation_lut(0.1, output, "leaky_relu_0p1")
        self.assertEqual(lut[10], 20)
        self.assertEqual(lut[246], 9)  # signed -10 -> real -1 -> leaky -0.1

    def test_checkpoint_paths_are_portable_posix_relatives(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.pt"
            calibration = root / "calibration.json"
            source.write_bytes(b"checkpoint")
            calibration.write_text("{}\n", encoding="utf-8")
            plan = {
                "format": "fixture",
                "version": 1,
                "layers": [{"name": "m0", "infer_index": 0, "bias_i32": [1]}],
            }
            output = root / "quant"
            save_quant_checkpoint(
                output,
                plan,
                {"m0": torch.tensor([[[[1]]]], dtype=torch.int8)},
                {"m0": bytes(range(256))},
                source_weights=source,
                calibration_manifest=calibration,
            )
            manifest = json.loads((output / "quantization_manifest.json").read_text())
            files = manifest["layers"][0]["files"]
            self.assertEqual(files["weight_raw_oihw_s8"]["path"], "00_m0/weight_raw_oihw_s8.bin")
            self.assertEqual(files["bias_i32"]["path"], "00_m0/bias_i32.bin")
            self.assertEqual(files["activation_lut_u8"]["path"], "00_m0/activation_lut_u8.bin")
            self.assertEqual(
                files["activation_lut_u8"]["sha256"],
                hashlib.sha256(bytes(range(256))).hexdigest(),
            )


if __name__ == "__main__":
    unittest.main()

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (
    ROOT
    / "sw"
    / "vitis_2022_2"
    / "scripts"
    / "generate_abi_v2_parameter_package.py"
)
SPEC = importlib.util.spec_from_file_location("abi_v2_pack", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
PACK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACK)


class ParameterPackageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="abi_v2_parameter_test_")
        cls.output = Path(cls.temp.name)
        cls.manifest = PACK.generate_package(ROOT / "repro" / "model", cls.output)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_release_totals_and_contexts(self):
        self.assertEqual(
            self.manifest["files"]["bias"]["payload_bytes"], 61_824
        )
        self.assertEqual(
            self.manifest["files"]["weight"]["payload_bytes"], 16_849_728
        )
        self.assertEqual(
            [layer["weight"]["packets"] for layer in self.manifest["layers"]],
            list(PACK.EXPECTED_CONTEXTS),
        )

    def test_alignment_sizes_and_hashes(self):
        for layer in self.manifest["layers"]:
            self.assertEqual(layer["bias"]["offset"] % 64, 0)
            self.assertEqual(layer["weight"]["offset"] % 64, 0)
        for kind in ("bias", "weight"):
            entry = self.manifest["files"][kind]
            payload = (self.output / entry["path"]).read_bytes()
            self.assertEqual(len(payload), entry["file_bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), entry["sha256"])
        disk_manifest = json.loads(
            (self.output / "abi_v2_parameter_manifest.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(disk_manifest, self.manifest)

    def test_cout_tail_is_zero_padded(self):
        layer = self.manifest["layers"][9]
        bias = (self.output / self.manifest["files"]["bias"]["path"]).read_bytes()
        packet = bias[layer["bias"]["offset"] : layer["bias"]["offset"] + 128]
        self.assertNotEqual(packet[: 24 * 4], bytes(24 * 4))
        self.assertEqual(packet[24 * 4 :], bytes(8 * 4))

        weight = (
            self.output / self.manifest["files"]["weight"]["path"]
        ).read_bytes()
        packet = weight[
            layer["weight"]["offset"] : layer["weight"]["offset"] + 18 * 32
        ]
        for row in range(18):
            self.assertEqual(packet[row * 32 + 24 : row * 32 + 32], bytes(8))

    def test_generated_binding_header_contains_file_hashes(self):
        header = (self.output / "accel_v2_parameter_package.h").read_text(
            encoding="ascii"
        )
        self.assertIn(self.manifest["files"]["bias"]["sha256"], header)
        self.assertIn(self.manifest["files"]["weight"]["sha256"], header)
        self.assertIn("#define ACCEL_V2_PARAMETER_LAYER_COUNT 10U", header)
        self.assertIn("accel_v2_parameter_layers[10]", header)


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from tools.coco80.ablation_representative_runner import _secondary_parameters
from tools.coco80.assets import sha256_file
from tools.coco80.net_protocol import REP_OVERRIDE_SPARSE_3X3


class RepresentativeSecondaryTests(unittest.TestCase):
    def test_network_build_defines_representative_mode_once(self) -> None:
        script = (Path(__file__).resolve().parents[2] /
                  "sw/vitis_2022_2/scripts/build_coco80_net_runner.ps1")
        text = script.read_text(encoding="utf-8-sig")
        self.assertIn("#define COCO80_NET_ABLATION_REPRESENTATIVE", text)
        self.assertNotIn("-DCOCO80_NET_ABLATION_REPRESENTATIVE=", text)

    def test_a0_stream_helper_is_not_built_for_other_variants(self) -> None:
        source = (Path(__file__).resolve().parents[2] /
                  "sw/vitis_2022_2/src/coco80_accel.c")
        text = source.read_text(encoding="utf-8-sig")
        helper = text.index("static int c8_a0_stream_geometry(")
        guard = text.rfind(
            "#if defined(COCO80_ABLATION_VARIANT_A0) && "
            "COCO80_ABLATION_VARIANT_A0 == 1", 0, helper)
        close = text.index("\n#endif", helper)
        self.assertGreaterEqual(guard, 0)
        self.assertGreater(close, helper)

    def test_native_1x1_is_repacked_as_capacity_safe_sparse_3x3(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            layer_dir = root / "09_m16"
            layer_dir.mkdir()
            bias = layer_dir / "bias_i32.bin"
            weight = layer_dir / "weight_raw_oihw_s8.bin"
            bias.write_bytes(bytes(128 * 4))
            weight.write_bytes(bytes((index * 17) & 0xFF for index in range(128 * 256)))
            manifest = root / "quantization_manifest.json"
            manifest.write_text(json.dumps({
                "layers": [{
                    "name": "m16",
                    "files": {
                        "bias_i32": {
                            "path": "09_m16/bias_i32.bin", "bytes": bias.stat().st_size,
                            "sha256": sha256_file(bias),
                        },
                        "weight_raw_oihw_s8": {
                            "path": "09_m16/weight_raw_oihw_s8.bin",
                            "bytes": weight.stat().st_size, "sha256": sha256_file(weight),
                        },
                    },
                }],
            }), encoding="utf-8")
            mode, tile_h, kernel, packed_bias, packed_weight, bias_packets, weight_packets = (
                _secondary_parameters(manifest, "m16", "sparse3x3")
            )
            self.assertEqual((mode, tile_h, kernel), (REP_OVERRIDE_SPARSE_3X3, 13, 3))
            self.assertEqual((bias_packets, len(packed_bias)), (4, 512))
            self.assertEqual((weight_packets, len(packed_weight)), (512, 512 * 576))
            # Every original coefficient occupies kernel-center index 4; the
            # eight surrounding sparse positions remain exactly zero.
            first_packet = packed_weight[:576]
            self.assertEqual(first_packet[0:32], bytes(32))
            raw = weight.read_bytes()
            self.assertEqual(
                first_packet[4 * 32:5 * 32], bytes(raw[channel * 256] for channel in range(32)))


if __name__ == "__main__":
    unittest.main()

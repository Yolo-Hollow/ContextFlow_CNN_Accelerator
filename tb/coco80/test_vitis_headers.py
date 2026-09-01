import copy
import hashlib
import json
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.coco80.hardware_plan import COCO80_HARDWARE_PLAN
from tools.coco80.parameter_package import (
    PACKAGE_MANIFEST_NAME,
    QUANTIZATION_MANIFEST_FORMAT,
    QUANTIZATION_MANIFEST_NAME,
    QUANTIZATION_MANIFEST_VERSION,
    generate_package,
)
from tools.coco80.vitis_headers import (
    TENSOR_NAMES,
    VitisHeaderError,
    build_vitis_config,
    generate_vitis_header,
    solve_a53_requant_multiplier,
)
from tools.coco80.sd_pack import pack_parameter_package_from_manifest


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class VitisHeadersTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="coco80_vitis_header_")
        cls.root = Path(cls.temporary.name)
        cls.quant_root = cls.root / "quant"
        cls.package_root = cls.root / "package"
        cls.quant_root.mkdir()
        cls.bit_sha = digest(b"unit-test release bitstream")
        cls.xsa_sha = digest(b"unit-test release xsa")
        cls.checkpoint_sha = digest(b"official checkpoint")
        cls.calibration_sha = digest(b"calibration manifest")

        output_qparams = {}
        for index, schedule in enumerate(COCO80_HARDWARE_PLAN.layers):
            output_qparams[schedule.layer.layer_id] = {
                "scale": 0.015625 * (1 + index % 4),
                "zero_point": (17 + index * 7) % 96,
                "qmin": 0,
                "qmax": 127,
            }
        input_source = {
            "m0": None,
            "m2": "m0",
            "m4": "m2",
            "m6": "m4",
            "m8": "m6",
            "m10": "m8",
            "m13": "m10",
            "m14": "m13",
            "m15": "m14",
            "m16": "m14",
            "m19": "m16",
            "p4_detect": "m19",
            "p5_detect": "m15",
        }
        input_q = {"scale": 0.0078125, "zero_point": 64, "qmin": 0, "qmax": 127}
        canonical_layers = []
        for index, schedule in enumerate(COCO80_HARDWARE_PLAN.layers):
            layer = schedule.layer
            layer_dir = cls.quant_root / f"{index:02d}_{layer.layer_id}"
            layer_dir.mkdir()
            bias_values = [(index + 1) * 100 + channel for channel in range(layer.cout)]
            bias = b"".join(struct.pack("<i", value) for value in bias_values)
            weight_bytes = layer.cout * layer.cin * layer.kernel * layer.kernel
            pattern = bytes((value + index * 19) & 0xFF for value in range(256))
            weight = (pattern * (weight_bytes // 256 + 1))[:weight_bytes]
            lut = bytes((value * 3 + index) & 0x7F for value in range(256))
            paths = {
                "bias_i32": layer_dir / "bias_i32.bin",
                "weight_raw_oihw_s8": layer_dir / "weight_raw_oihw_s8.bin",
                "activation_lut_u8": layer_dir / "activation_lut_u8.bin",
            }
            paths["bias_i32"].write_bytes(bias)
            paths["weight_raw_oihw_s8"].write_bytes(weight)
            paths["activation_lut_u8"].write_bytes(lut)
            source_name = input_source[layer.layer_id]
            layer_input_q = copy.deepcopy(
                input_q if source_name is None else output_qparams[source_name]
            )
            layer_output_q = copy.deepcopy(output_qparams[layer.layer_id])
            weight_scale = 0.00390625 * (1 + index % 3)
            multiplier = 32768
            shift = index % 4
            represented = multiplier / float(1 << (15 + shift))
            preactivation_scale = layer_input_q["scale"] * weight_scale / represented
            function = "identity" if layer.detect_index is not None else "leaky_relu_0p1"
            maximum_bias = max(abs(min(bias_values)), abs(max(bias_values)))
            entry = {
                "infer_index": index,
                "name": layer.layer_id,
                "model_index": layer.model_index,
                "source": layer.input_tensor,
                "ifm_hwc": [layer.fm_h, layer.fm_w, layer.cin],
                "ofm_hwc": [schedule.conv_h, schedule.conv_w, layer.cout],
                "kernel": layer.kernel,
                "stride": layer.stride,
                "pad": layer.pad,
                "tile_h": layer.tile_h,
                "activation": function,
                "quant": {
                    "name": layer.layer_id,
                    "input": layer_input_q,
                    "output": layer_output_q,
                    "preactivation_scale": preactivation_scale,
                    "weight_scale": weight_scale,
                    "weight_zero_point": 0,
                    "multiplier": multiplier,
                    "shift": shift,
                    "effective_scale": represented,
                    "effective_scale_error": abs(
                        represented
                        - layer_input_q["scale"] * weight_scale / preactivation_scale
                    ),
                    "activation": function,
                    "input_center_saturation_possible": False,
                    "bias_min": min(bias_values),
                    "bias_max": max(bias_values),
                    "accumulator_abs_bound": (
                        layer.cin * layer.kernel * layer.kernel * 128 * 127
                        + maximum_bias
                    ),
                },
                "weight_shape_oihw": [
                    layer.cout,
                    layer.cin,
                    layer.kernel,
                    layer.kernel,
                ],
                "bias_i32": bias_values,
                "activation_lut_sha256": digest(lut),
                "files": {},
            }
            if layer.detect_index is not None:
                entry["detect_head"] = layer.detect_index
            for name, path in paths.items():
                content = path.read_bytes()
                entry["files"][name] = {
                    "path": path.relative_to(cls.quant_root).as_posix(),
                    "bytes": len(content),
                    "sha256": digest(content),
                }
            canonical_layers.append(entry)

        cls.quant_manifest = {
            "format": QUANTIZATION_MANIFEST_FORMAT,
            "version": QUANTIZATION_MANIFEST_VERSION,
            "activation_quant_range": [0, 127],
            "weight_quant_range": [-127, 127],
            "weight_qscheme": "per_tensor_symmetric_s8_zp0",
            "activation_qscheme": "per_tensor_affine_u8_reduced_range",
            "rounding": "add_positive_half_then_arithmetic_right_shift",
            "layers": canonical_layers,
            "provenance": {
                "source_weights": "official-yolov3-tiny.pt",
                "source_weights_sha256": cls.checkpoint_sha,
                "calibration_manifest": "calibration_manifest.json",
                "calibration_manifest_sha256": cls.calibration_sha,
            },
        }
        cls.quant_path = cls.quant_root / QUANTIZATION_MANIFEST_NAME
        cls.quant_path.write_text(
            json.dumps(cls.quant_manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        generate_package(cls.quant_root, cls.package_root)
        cls.package_path = cls.package_root / PACKAGE_MANIFEST_NAME

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_config_contains_13_dispatches_edges_luts_and_exact_package_contract(self):
        config = build_vitis_config(
            self.package_path,
            self.quant_path,
            bit_sha256=self.bit_sha,
            xsa_sha256=self.xsa_sha,
        )
        self.assertEqual(len(config["layers"]), 13)
        self.assertEqual(len(config["tensor_qparams"]), len(TENSOR_NAMES))
        self.assertEqual(len(config["luts"]), 13)
        self.assertTrue(all(len(bytes.fromhex(lut)) == 256 for lut in config["luts"]))
        self.assertEqual(config["bias_package_bytes"], 64_256)
        self.assertEqual(config["weight_package_bytes"], 18_614_016)
        self.assertEqual(
            [layer["pool_stride"] for layer in config["layers"]],
            [2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        )
        by_name = {layer["name"]: layer for layer in config["layers"]}
        self.assertEqual(by_name["m19"]["tile_h"], 6)
        self.assertEqual(by_name["p4_detect"]["cout_tail"], 31)
        self.assertEqual(by_name["p5_detect"]["cout_tail"], 31)
        self.assertEqual(by_name["p4_detect"]["cout_blocks"], 8)
        self.assertEqual(by_name["p5_detect"]["cout_blocks"], 8)
        self.assertEqual(config["hashes"]["bit"], self.bit_sha)
        self.assertEqual(config["hashes"]["xsa"], self.xsa_sha)
        self.assertEqual(len(config["binding_sha256"]), 64)

    def test_m8_to_m16_route_constants_match_a53_solver_and_tensor_domains(self):
        config = build_vitis_config(
            self.package_path,
            self.quant_path,
            bit_sha256=self.bit_sha,
            xsa_sha256=self.xsa_sha,
        )
        qparams = {entry["name"]: entry for entry in config["tensor_qparams"]}
        route = config["route_m8_to_m16"]
        m8_scale = struct.unpack("<f", struct.pack("<I", qparams["m8"]["scale_bits"]))[0]
        m16_scale = struct.unpack("<f", struct.pack("<I", qparams["m16"]["scale_bits"]))[0]
        expected_mult, expected_shift = solve_a53_requant_multiplier(m8_scale / m16_scale)
        self.assertEqual(route["multiplier"], expected_mult)
        self.assertEqual(route["shift"], expected_shift)
        self.assertEqual(route["rounding"], "symmetric_nearest_ties_away_from_zero")
        self.assertEqual(qparams["m16"], {**qparams["upsample17"], "name": "m16", "index": qparams["m16"]["index"]})
        self.assertEqual(qparams["m16"]["scale_bits"], qparams["concat18"]["scale_bits"])
        self.assertEqual(qparams["m16"]["zero_point"], qparams["concat18"]["zero_point"])

    def test_header_is_freestanding_deterministic_and_reproducibly_hashed(self):
        output_a = self.root / "a" / "coco80_generated_config.h"
        output_b = self.root / "b" / "coco80_generated_config.h"
        artifact_a = generate_vitis_header(
            self.package_path,
            self.quant_path,
            output_a,
            bit_sha256=self.bit_sha,
            xsa_sha256=self.xsa_sha,
        )
        artifact_b = generate_vitis_header(
            self.package_path,
            self.quant_path,
            output_b,
            bit_sha256=self.bit_sha.upper(),
            xsa_sha256=self.xsa_sha.upper(),
        )
        content = output_a.read_bytes()
        self.assertEqual(content, output_b.read_bytes())
        self.assertEqual(artifact_a.sha256, digest(content))
        self.assertEqual(artifact_a, artifact_b.__class__(output_a, artifact_b.bytes, artifact_b.sha256, artifact_b.binding_sha256))
        self.assertNotIn(b"\\", content)
        self.assertNotIn(b"\r", content)
        text = content.decode("ascii")
        self.assertIn("#include <stdint.h>", text)
        self.assertNotIn("stdio.h", text)
        self.assertIn("COCO80_GENERATED_LAYER_COUNT 13U", text)
        self.assertIn("COCO80_WEIGHT_PACKAGE_BYTES 18614016U", text)
        self.assertIn(self.bit_sha, text)
        self.assertIn(self.xsa_sha, text)
        self.assertIn("coco80_generated_activation_luts[13][256]", text)
        self.assertIn("coco80_generated_m8_to_m16_requant", text)

    def test_generated_header_passes_c_syntax_when_compiler_is_available(self):
        compiler = shutil.which("gcc") or shutil.which("clang")
        if compiler is None:
            self.skipTest("no C compiler is installed")
        header = self.root / "compile" / "coco80_generated_config.h"
        generate_vitis_header(
            self.package_path,
            self.quant_path,
            header,
            bit_sha256=self.bit_sha,
            xsa_sha256=self.xsa_sha,
        )
        source = header.parent / "probe.c"
        source.write_text(
            '#include "coco80_generated_config.h"\n'
            "int main(void) { return (int)coco80_generated_layers[0].tile_h - 2; }\n",
            encoding="ascii",
        )
        subprocess.run(
            [compiler, "-std=c11", "-fsyntax-only", str(source)],
            check=True,
            capture_output=True,
            text=True,
        )

    def test_runtime_header_is_bound_to_exact_sd_parameter_package(self):
        package = self.root / "runtime" / "coco80_parameters.c8pa"
        package.parent.mkdir(exist_ok=True)
        pack_parameter_package_from_manifest(
            self.package_path,
            package,
            quantization=self.quant_path,
        )
        header = self.root / "runtime" / "coco80_generated_config.h"
        config = build_vitis_config(
            self.package_path,
            self.quant_path,
            bit_sha256=self.bit_sha,
            xsa_sha256=self.xsa_sha,
            sd_parameter_package=package,
        )
        self.assertIn("runtime", config)
        self.assertEqual(len(config["runtime"]["bindings"]), 13)
        generate_vitis_header(
            self.package_path,
            self.quant_path,
            header,
            bit_sha256=self.bit_sha,
            xsa_sha256=self.xsa_sha,
            sd_parameter_package=package,
        )
        text = header.read_text(encoding="ascii")
        self.assertIn("coco80_runtime_layer_bindings[13]", text)
        self.assertIn("coco80_runtime_config", text)
        compiler = shutil.which("gcc") or shutil.which("clang")
        if compiler is not None:
            source = package.parent / "runtime_probe.c"
            subprocess.run(
                [
                    compiler,
                    "-std=c11",
                    "-I",
                    str(Path("sw/vitis_2022_2/src").resolve()),
                    "-I",
                    str(package.parent),
                    str(Path("sw/vitis_2022_2/src/coco80_accel.c").resolve()),
                    str(Path("sw/vitis_2022_2/src/coco80_tensor_ops.c").resolve()),
                    str(Path("sw/vitis_2022_2/src/coco80_decode.c").resolve()),
                    str(Path("sw/vitis_2022_2/src/coco80_sd_protocol.c").resolve()),
                    str(Path("tb/test_coco80_accel_config.c").resolve()),
                    "-lm",
                    "-o",
                    str(package.parent / "runtime_probe.exe"),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            run = subprocess.run(
                [str(package.parent / "runtime_probe.exe")], capture_output=True, text=True
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_artifact_and_cross_binding_drift_fail_closed(self):
        with self.assertRaises(VitisHeaderError):
            build_vitis_config(
                self.package_path,
                self.quant_path,
                bit_sha256="0" * 64,
                xsa_sha256=self.xsa_sha,
            )

        original_quant = self.quant_path.read_text(encoding="utf-8")
        try:
            changed = copy.deepcopy(self.quant_manifest)
            changed["layers"][0]["quant"]["output"]["zero_point"] += 1
            self.quant_path.write_text(json.dumps(changed, sort_keys=True), encoding="utf-8")
            with self.assertRaises(VitisHeaderError):
                build_vitis_config(
                    self.package_path,
                    self.quant_path,
                    bit_sha256=self.bit_sha,
                    xsa_sha256=self.xsa_sha,
                )
        finally:
            self.quant_path.write_text(original_quant, encoding="utf-8")

        original_package = self.package_path.read_text(encoding="utf-8")
        try:
            changed_package = json.loads(original_package)
            changed_package["layers"][0]["weight"]["offset"] = 64
            self.package_path.write_text(
                json.dumps(changed_package, sort_keys=True), encoding="utf-8"
            )
            with self.assertRaises(VitisHeaderError):
                build_vitis_config(
                    self.package_path,
                    self.quant_path,
                    bit_sha256=self.bit_sha,
                    xsa_sha256=self.xsa_sha,
                )
        finally:
            self.package_path.write_text(original_package, encoding="utf-8")


if __name__ == "__main__":
    unittest.main()

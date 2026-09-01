import copy
import hashlib
import json
import shutil
import struct
import tempfile
import unittest
from pathlib import Path

from tools.coco80.hardware_plan import (
    BIAS_PACKET_BYTES,
    COCO80_HARDWARE_PLAN,
    COUT_TILE,
    EXPECTED_BIAS_PACKAGE_BYTES,
    EXPECTED_WEIGHT_PACKAGE_BYTES,
    PARAMETER_ALIGNMENT,
    ROWS,
    WEIGHT_PACKET_BYTES,
    get_schedule,
)
from tools.coco80.parameter_package import (
    BIAS_IMAGE_NAME,
    LAYER_MANIFEST_MAGIC,
    LAYER_MANIFEST_VERSION,
    PACKAGE_MANIFEST_NAME,
    PARAMETER_PACKAGE_MAGIC,
    PARAMETER_PACKAGE_VERSION,
    POOL_MODES,
    QUANTIZATION_MANIFEST_FORMAT,
    QUANTIZATION_MANIFEST_NAME,
    QUANTIZATION_MANIFEST_VERSION,
    ROUTE_SEMANTICS,
    WEIGHT_IMAGE_NAME,
    PackageValidationError,
    generate_package,
    load_layer_manifests,
    sha256_bytes,
    verify_package,
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class ParameterPackageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="coco80_package_")
        cls.root = Path(cls.temporary.name)
        cls.model_root = cls.root / "model"
        cls.output = cls.root / "package"
        cls.model_root.mkdir()
        cls.layer_manifests = {}
        checkpoint_sha = digest(b"unit-test COCO80 checkpoint")
        calibration_sha = digest(b"unit-test COCO80 calibration")
        export_sha = digest(b"unit-test COCO80 export")

        for index, schedule in enumerate(COCO80_HARDWARE_PLAN.layers):
            layer = schedule.layer
            layer_dir = cls.model_root / f"{index:02d}_{layer.layer_id}"
            layer_dir.mkdir()
            bias = b"".join(
                struct.pack("<i", (index + 1) * 1000 + channel)
                for channel in range(layer.cout)
            )
            weight_bytes = layer.cout * layer.cin * layer.kernel * layer.kernel
            pattern = bytes((byte + index * 17) & 0xFF for byte in range(256))
            weight = (pattern * (weight_bytes // len(pattern) + 1))[:weight_bytes]
            lut = bytes((byte + index) & 0xFF for byte in range(256))
            (layer_dir / "bias_i32.bin").write_bytes(bias)
            (layer_dir / "weight_raw_oihw_s8.bin").write_bytes(weight)
            (layer_dir / "lut256.bin").write_bytes(lut)
            manifest = {
                "magic": LAYER_MANIFEST_MAGIC,
                "version": LAYER_MANIFEST_VERSION,
                "layer_id": layer.layer_id,
                "shape": {
                    "ifm_hwc": [layer.fm_h, layer.fm_w, layer.cin],
                    "conv_ofm_hwc": [
                        schedule.conv_h,
                        schedule.conv_w,
                        layer.cout,
                    ],
                    "final_ofm_hwc": [
                        schedule.output_h,
                        schedule.output_w,
                        layer.cout,
                    ],
                },
                "conv": {
                    "kernel": layer.kernel,
                    "stride": layer.stride,
                    "pad": layer.pad,
                },
                "graph": {
                    "input_tensor": layer.input_tensor,
                    "output_tensor": layer.output_tensor,
                    "pool_mode": POOL_MODES[layer.layer_id],
                    "route_semantics": ROUTE_SEMANTICS[layer.layer_id],
                },
                "quant": {
                    "input_scale": 0.015625 * (index + 1),
                    "input_zero_point": 128,
                    "output_scale": 0.03125 * (index + 1),
                    "output_zero_point": 0,
                    "weight_scale": 0.0078125 * (index + 1),
                    "weight_zero_point": 0,
                    "weight_dtype": "int8",
                    "weight_granularity": "per_tensor",
                    "rtl_mult": 32768,
                    "rtl_shift": index % 4,
                },
                "activation": {"mode": "lut256", "lut_sha256": digest(lut)},
                "provenance": {
                    "checkpoint_sha256": checkpoint_sha,
                    "calibration_sha256": calibration_sha,
                    "export_sha256": export_sha,
                },
                "files": {
                    "bias_i32": {
                        "path": "bias_i32.bin",
                        "bytes": len(bias),
                        "sha256": digest(bias),
                    },
                    "weight_raw_oihw_s8": {
                        "path": "weight_raw_oihw_s8.bin",
                        "bytes": len(weight),
                        "sha256": digest(weight),
                    },
                    "lut_u8": {
                        "path": "lut256.bin",
                        "bytes": len(lut),
                        "sha256": digest(lut),
                    },
                },
            }
            manifest_path = layer_dir / "manifest.json"
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            cls.layer_manifests[layer.layer_id] = manifest_path

        cls.manifest = generate_package(cls.model_root, cls.output)
        cls.manifest_path = cls.output / PACKAGE_MANIFEST_NAME
        cls.bias = (cls.output / BIAS_IMAGE_NAME).read_bytes()
        cls.weight = (cls.output / WEIGHT_IMAGE_NAME).read_bytes()

        # Mirror quantization.save_quant_checkpoint: one root manifest with
        # nested qparams and 13 relative file sets.
        cls.canonical_root = cls.root / "canonical_quant"
        cls.canonical_output = cls.root / "canonical_package"
        cls.canonical_root.mkdir()
        canonical_layers = []
        for index, schedule in enumerate(COCO80_HARDWARE_PLAN.layers):
            layer = schedule.layer
            source_dir = cls.layer_manifests[layer.layer_id].parent
            layer_dir = cls.canonical_root / f"{index:02d}_{layer.layer_id}"
            layer_dir.mkdir()
            destinations = {
                "bias_i32": layer_dir / "bias_i32.bin",
                "weight_raw_oihw_s8": layer_dir / "weight_raw_oihw_s8.bin",
                "activation_lut_u8": layer_dir / "activation_lut_u8.bin",
            }
            shutil.copyfile(source_dir / "bias_i32.bin", destinations["bias_i32"])
            shutil.copyfile(
                source_dir / "weight_raw_oihw_s8.bin",
                destinations["weight_raw_oihw_s8"],
            )
            shutil.copyfile(source_dir / "lut256.bin", destinations["activation_lut_u8"])
            bias_raw = destinations["bias_i32"].read_bytes()
            bias_values = list(struct.unpack(f"<{layer.cout}i", bias_raw))
            input_scale = 0.0078125 * (index + 1)
            output_scale = 0.015625 * (index + 1)
            weight_scale = 0.00390625 * (index + 1)
            multiplier = 32768
            shift = index % 4
            represented = multiplier / float(1 << (15 + shift))
            preactivation_scale = input_scale * weight_scale / represented
            function = (
                "identity" if layer.detect_index is not None else "leaky_relu_0p1"
            )
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
                    "input": {
                        "scale": input_scale, "zero_point": 64, "qmin": 0, "qmax": 127
                    },
                    "output": {
                        "scale": output_scale, "zero_point": 32, "qmin": 0, "qmax": 127
                    },
                    "preactivation_scale": preactivation_scale,
                    "weight_scale": weight_scale,
                    "weight_zero_point": 0,
                    "multiplier": multiplier,
                    "shift": shift,
                    "effective_scale": represented,
                    "effective_scale_error": abs(
                        represented - input_scale * weight_scale / preactivation_scale
                    ),
                    "activation": function,
                    "input_center_saturation_possible": False,
                    "bias_min": min(bias_values),
                    "bias_max": max(bias_values),
                    "accumulator_abs_bound": (
                        layer.cin * layer.kernel * layer.kernel * 128 * 127
                        + max(abs(min(bias_values)), abs(max(bias_values)))
                    ),
                },
                "weight_shape_oihw": [
                    layer.cout, layer.cin, layer.kernel, layer.kernel
                ],
                "bias_i32": bias_values,
                "activation_lut_sha256": digest(
                    destinations["activation_lut_u8"].read_bytes()
                ),
                "files": {},
            }
            if layer.detect_index is not None:
                entry["detect_head"] = layer.detect_index
            for file_name, file_path in destinations.items():
                content = file_path.read_bytes()
                entry["files"][file_name] = {
                    "path": file_path.relative_to(cls.canonical_root).as_posix(),
                    "bytes": len(content),
                    "sha256": digest(content),
                }
            canonical_layers.append(entry)
        cls.canonical_source = {
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
                "source_weights_sha256": checkpoint_sha,
                "calibration_manifest": "calibration_manifest.json",
                "calibration_manifest_sha256": calibration_sha,
            },
        }
        cls.canonical_manifest_path = cls.canonical_root / QUANTIZATION_MANIFEST_NAME
        cls.canonical_manifest_path.write_text(
            json.dumps(cls.canonical_source, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        cls.canonical_manifest = generate_package(
            cls.canonical_root, cls.canonical_output
        )

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def write_bad_manifest(self, name, mutate):
        data = copy.deepcopy(self.manifest)
        mutate(data)
        path = self.output / f"bad_{name}.json"
        path.write_text(json.dumps(data, sort_keys=True), encoding="utf-8")
        return path

    def test_independent_magic_and_version_domains(self):
        self.assertNotEqual(LAYER_MANIFEST_MAGIC, PARAMETER_PACKAGE_MAGIC)
        self.assertEqual(LAYER_MANIFEST_VERSION, 1)
        self.assertEqual(PARAMETER_PACKAGE_VERSION, 1)
        self.assertEqual(self.manifest["magic"], PARAMETER_PACKAGE_MAGIC)
        self.assertEqual(self.manifest["version"], PARAMETER_PACKAGE_VERSION)

    def test_exact_abi_v2_binary_contract_and_file_hashes(self):
        self.assertEqual(len(self.bias), EXPECTED_BIAS_PACKAGE_BYTES)
        self.assertEqual(len(self.weight), EXPECTED_WEIGHT_PACKAGE_BYTES)
        self.assertEqual(len(self.bias), 64_256)
        self.assertEqual(len(self.weight), 18_614_016)
        files = self.manifest["files"]
        self.assertEqual(files["bias"]["file_bytes"], len(self.bias))
        self.assertEqual(files["weight"]["file_bytes"], len(self.weight))
        self.assertEqual(files["bias"]["sha256"], sha256_bytes(self.bias))
        self.assertEqual(files["weight"]["sha256"], sha256_bytes(self.weight))
        self.assertEqual(files["bias"]["path"], BIAS_IMAGE_NAME)
        self.assertEqual(files["weight"]["path"], WEIGHT_IMAGE_NAME)
        self.assertEqual(verify_package(self.manifest_path)["magic"], PARAMETER_PACKAGE_MAGIC)

    def test_canonical_save_quant_checkpoint_adapter_builds_exact_package(self):
        canonical_bias = (self.canonical_output / BIAS_IMAGE_NAME).read_bytes()
        canonical_weight = (self.canonical_output / WEIGHT_IMAGE_NAME).read_bytes()
        self.assertEqual(len(canonical_bias), 64_256)
        self.assertEqual(len(canonical_weight), 18_614_016)
        self.assertEqual(digest(canonical_bias), digest(self.bias))
        self.assertEqual(digest(canonical_weight), digest(self.weight))
        export_sha = digest(self.canonical_manifest_path.read_bytes())
        source_provenance = self.canonical_source["provenance"]
        for index, layer in enumerate(self.canonical_manifest["layers"]):
            with self.subTest(index=index):
                self.assertEqual(layer["provenance"]["export_sha256"], export_sha)
                self.assertEqual(
                    layer["provenance"]["checkpoint_sha256"],
                    source_provenance["source_weights_sha256"],
                )
                self.assertEqual(
                    layer["provenance"]["calibration_sha256"],
                    source_provenance["calibration_manifest_sha256"],
                )
                self.assertEqual(layer["quant"]["rtl_output_zero_point"], 0)
                self.assertIn("preactivation_scale", layer["quant"])
                self.assertEqual(
                    layer["source_files"]["lut_u8"]["sha256"],
                    layer["activation"]["lut_sha256"],
                )
        verified = verify_package(self.canonical_output / PACKAGE_MANIFEST_NAME)
        self.assertEqual(verified["files"]["weight"]["file_bytes"], 18_614_016)

    def test_canonical_adapter_rejects_nested_quant_and_provenance_drift(self):
        original = self.canonical_manifest_path.read_text(encoding="utf-8")
        cases = {
            "nested_qparams": lambda data: data["layers"][0]["quant"]["input"].update(
                qmax=255
            ),
            "multiplier": lambda data: data["layers"][0]["quant"].update(multiplier=0),
            "lut": lambda data: data["layers"][0].update(
                activation_lut_sha256="0" * 64
            ),
            "provenance": lambda data: data["provenance"].update(
                source_weights_sha256="0"
            ),
        }
        try:
            for name, mutate in cases.items():
                with self.subTest(case=name):
                    data = copy.deepcopy(self.canonical_source)
                    mutate(data)
                    self.canonical_manifest_path.write_text(
                        json.dumps(data, sort_keys=True), encoding="utf-8"
                    )
                    with self.assertRaises(PackageValidationError):
                        load_layer_manifests(self.canonical_root)
        finally:
            self.canonical_manifest_path.write_text(original, encoding="utf-8")

    def test_all_sections_are_aligned_contiguous_hash_bound_and_sized(self):
        previous = {"bias": 0, "weight": 0}
        images = {"bias": self.bias, "weight": self.weight}
        for entry, schedule in zip(
            self.manifest["layers"], COCO80_HARDWARE_PLAN.layers
        ):
            for kind, expected in (
                ("bias", schedule.bias_bytes),
                ("weight", schedule.weight_bytes),
            ):
                section = entry[kind]
                self.assertEqual(section["offset"] % PARAMETER_ALIGNMENT, 0)
                self.assertEqual(section["offset"], previous[kind])
                self.assertEqual(section["bytes"], expected)
                payload = images[kind][
                    section["offset"] : section["offset"] + section["bytes"]
                ]
                self.assertEqual(section["sha256"], digest(payload))
                previous[kind] = section["offset"] + section["bytes"]
        self.assertEqual(previous["bias"], len(self.bias))
        self.assertEqual(previous["weight"], len(self.weight))

    def test_manifest_binds_quant_lut_graph_provenance_and_schedule(self):
        self.assertEqual(len(self.manifest["layers"]), 13)
        for index, (entry, schedule) in enumerate(
            zip(self.manifest["layers"], COCO80_HARDWARE_PLAN.layers)
        ):
            with self.subTest(layer=schedule.layer.layer_id):
                quant = entry["quant"]
                self.assertEqual(
                    set(
                        (
                            "input_scale",
                            "input_zero_point",
                            "output_scale",
                            "output_zero_point",
                            "weight_scale",
                            "rtl_mult",
                            "rtl_shift",
                        )
                    ).difference(quant),
                    set(),
                )
                self.assertEqual(quant["weight_zero_point"], 0)
                self.assertEqual(quant["weight_granularity"], "per_tensor")
                self.assertEqual(entry["activation"]["mode"], "lut256")
                self.assertEqual(
                    entry["activation"]["lut_sha256"],
                    entry["source_files"]["lut_u8"]["sha256"],
                )
                self.assertIn("AXI-Lite", entry["activation"]["lut_programming"])
                self.assertEqual(
                    entry["graph"]["pool_mode"],
                    POOL_MODES[schedule.layer.layer_id],
                )
                self.assertEqual(
                    entry["graph"]["route_semantics"],
                    ROUTE_SEMANTICS[schedule.layer.layer_id],
                )
                self.assertEqual(entry["schedule"]["tile_h"], schedule.layer.tile_h)
                self.assertEqual(entry["source_files"]["lut_u8"]["bytes"], 256)
                self.assertEqual(len(entry["source_manifest_sha256"]), 64)
                expected_pool = (
                    "fused_maxpool2x2s2" if entry["layer_id"] in {"m0", "m2", "m4", "m6"}
                    else "bypass"
                )
                self.assertEqual(entry["graph"]["pool_mode"], expected_pool)
                for provenance in (
                    "checkpoint_sha256",
                    "calibration_sha256",
                    "export_sha256",
                ):
                    self.assertEqual(len(entry["provenance"][provenance]), 64)

    def test_model19_and_255_channel_head_tail_are_explicit(self):
        entries = {item["layer_id"]: item for item in self.manifest["layers"]}
        self.assertEqual(entries["m19"]["schedule"]["tile_h"], 6)
        for layer_id in ("p4_detect", "p5_detect"):
            entry = entries[layer_id]
            self.assertEqual(entry["schedule"]["cout_total"], 255)
            self.assertEqual(entry["schedule"]["cout_blocks"], 8)
            self.assertEqual(entry["schedule"]["cout_tail_channels"], 31)

    def test_detector_cout_tail_and_k_tail_are_zero_padded_per_tile(self):
        entries = {item["layer_id"]: item for item in self.manifest["layers"]}
        for layer_id in ("p4_detect", "p5_detect"):
            schedule = get_schedule(layer_id)
            entry = entries[layer_id]
            bias_tile_bytes = schedule.cout_blocks * BIAS_PACKET_BYTES
            weight_block_bytes = schedule.k_passes * WEIGHT_PACKET_BYTES
            weight_tile_bytes = schedule.cout_blocks * weight_block_bytes
            for tile in range(schedule.tile_count):
                bias_tail = (
                    entry["bias"]["offset"]
                    + tile * bias_tile_bytes
                    + 7 * BIAS_PACKET_BYTES
                    + 31 * 4
                )
                self.assertEqual(self.bias[bias_tail : bias_tail + 4], bytes(4))
                final_block = (
                    entry["weight"]["offset"]
                    + tile * weight_tile_bytes
                    + 7 * weight_block_bytes
                )
                for k_pass in range(schedule.k_passes):
                    packet = final_block + k_pass * WEIGHT_PACKET_BYTES
                    for row in range(ROWS):
                        self.assertEqual(
                            self.weight[packet + row * COUT_TILE + 31], 0
                        )
            last_pass = schedule.k_passes - 1
            valid_rows = schedule.k_total - last_pass * ROWS
            first_block_last_packet = (
                entry["weight"]["offset"] + last_pass * WEIGHT_PACKET_BYTES
            )
            for row in range(valid_rows, ROWS):
                start = first_block_last_packet + row * COUT_TILE
                self.assertEqual(self.weight[start : start + COUT_TILE], bytes(COUT_TILE))

    def test_input_fixture_lut_file_is_strictly_size_and_hash_checked(self):
        path = self.layer_manifests["m0"]
        layer_dir = path.parent
        lut_path = layer_dir / "lut256.bin"
        original = lut_path.read_bytes()
        try:
            lut_path.write_bytes(original[:-1])
            with self.assertRaisesRegex(PackageValidationError, "255 bytes"):
                load_layer_manifests(self.model_root)
        finally:
            lut_path.write_bytes(original)

    def test_package_wrong_magic_plan_graph_quant_and_section_hash_fail_closed(self):
        cases = {
            "magic": lambda data: data.update(magic="wrong"),
            "plan": lambda data: data["hardware_plan"].update(version=999),
            "graph": lambda data: data["layers"][0]["graph"].update(
                route_semantics="wrong"
            ),
            "quant": lambda data: data["layers"][0]["quant"].update(
                weight_granularity="per_channel"
            ),
            "section_hash": lambda data: data["layers"][0]["weight"].update(
                sha256="0" * 64
            ),
        }
        for name, mutate in cases.items():
            with self.subTest(case=name):
                path = self.write_bad_manifest(name, mutate)
                with self.assertRaises(PackageValidationError):
                    verify_package(path)

    def test_package_metadata_drift_fails_closed(self):
        cases = {
            "input_tensor": lambda data: data["layers"][0]["graph"].update(
                input_tensor="wrong"
            ),
            "lut_binding": lambda data: data["layers"][0]["source_files"][
                "lut_u8"
            ].update(sha256="0" * 64),
            "window": lambda data: data["files"]["weight"].update(window_bytes=1),
            "packet": lambda data: data["packet_bytes"].update(weight=1),
        }
        for name, mutate in cases.items():
            with self.subTest(case=name):
                path = self.write_bad_manifest(name, mutate)
                with self.assertRaises(PackageValidationError):
                    verify_package(path)


if __name__ == "__main__":
    unittest.main()

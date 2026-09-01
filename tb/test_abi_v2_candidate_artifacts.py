import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_DIR = ROOT / "sw" / "vitis_2022_2" / "scripts"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ARTIFACTS = load_module(
    "abi_v2_candidate_artifacts",
    SCRIPT_DIR / "abi_v2_candidate_artifacts.py",
)
PACK = load_module(
    "abi_v2_parameter_package",
    SCRIPT_DIR / "generate_abi_v2_parameter_package.py",
)


class CandidateArtifactTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parameter_temp = tempfile.TemporaryDirectory(
            prefix="abi_v2_candidate_parameters_"
        )
        cls.parameter_dir = Path(cls.parameter_temp.name)
        PACK.generate_package(ROOT / "repro" / "model", cls.parameter_dir)

    @classmethod
    def tearDownClass(cls):
        cls.parameter_temp.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="abi_v2_candidate_test_")
        self.root = Path(self.temp.name)
        self.workspace = self.root / "build_vitis_2022_2_abi_v2_candidate"
        self.manifest = self.workspace / "abi_v2_candidate_manifest.json"
        self.xsa = self.root / "candidate.xsa"
        self.bit = self.root / "candidate.bit"
        self.metadata = self.root / "build_profile.txt"
        self.hardware_sha_manifest = self.root / "system_artifacts.sha256"
        self.xsa.write_bytes(b"xsa-v2-release")
        self.bit.write_bytes(b"bit-v2-release")
        self.hardware_sha_manifest.write_text(
            f"{ARTIFACTS.sha256_file(self.bit)}  {self.bit.name}\n"
            f"{ARTIFACTS.sha256_file(self.xsa)}  {self.xsa.name}\n",
            encoding="utf-8",
        )
        self.metadata.write_text(
            "\n".join(
                (
                    "profile=abi_v2_release",
                    "vivado_version=2022.2",
                    "rows=18",
                    "cols=16",
                    "cout_tile=32",
                    "enable_packed_hwc_ofm=1",
                    "enable_layer_tile_sequencer=1",
                    "enable_layer_long_hwc_ifm=1",
                    "enable_tagged_context=1",
                    "enable_column_psum=0",
                    "git_sha=" + "a" * 40,
                    "git_dirty=0",
                    "",
                )
            ),
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp.cleanup()

    def bind(self):
        return ARTIFACTS.bind_inputs(
            self.manifest,
            self.workspace,
            self.xsa,
            self.bit,
            self.metadata,
            self.hardware_sha_manifest,
            self.parameter_dir / "abi_v2_parameter_manifest.json",
        )

    def make_elf(self, name=ARTIFACTS.CANDIDATE_ELF_NAME):
        path = (
            self.workspace
            / "conv_accel_abi_v2_candidate"
            / "manual_build"
            / name
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"candidate-elf")
        return path

    def test_build_and_run_phase_bind_every_artifact(self):
        self.bind()
        build = ARTIFACTS.verify_manifest(
            self.manifest,
            "build",
            self.workspace,
            self.xsa,
            self.bit,
        )
        self.assertEqual(build["state"], "inputs_bound")
        self.assertTrue(build["release_eligible"])
        self.assertTrue(build["hardware"]["release_eligible"])
        self.assertEqual(build["runtime"]["long_stream_runtime_ready"], 0)
        self.assertEqual(build["runtime"]["clock_hz"], 100_000_000)
        with self.assertRaises(ARTIFACTS.CandidateArtifactError):
            ARTIFACTS.verify_manifest(self.manifest, "run")

        elf = self.make_elf()
        complete = ARTIFACTS.finalize_manifest(
            self.manifest,
            elf,
            {"git_sha": "a" * 40, "git_dirty": 0},
        )
        self.assertEqual(complete["state"], "complete")
        ARTIFACTS.verify_manifest(
            self.manifest,
            "run",
            self.workspace,
            self.xsa,
            self.bit,
            elf,
        )
        for section, names in (
            ("hardware", ("xsa", "bitstream")),
            ("parameters", ("bias", "weight")),
            ("software", ("elf",)),
        ):
            for name in names:
                self.assertRegex(
                    complete[section][name]["sha256"], r"^[0-9a-f]{64}$"
                )

    def test_changed_hash_is_rejected(self):
        self.bind()
        changed = bytearray(self.bit.read_bytes())
        changed[-1] ^= 1
        self.bit.write_bytes(changed)
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "SHA256 mismatch"
        ):
            ARTIFACTS.verify_manifest(self.manifest, "build")

    def test_changed_xsa_hash_is_rejected_in_build_phase(self):
        self.bind()
        changed = bytearray(self.xsa.read_bytes())
        changed[-1] ^= 1
        self.xsa.write_bytes(changed)
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "XSA SHA256 mismatch"
        ):
            ARTIFACTS.verify_manifest(self.manifest, "build")

    def test_changed_elf_hash_is_rejected_in_run_phase(self):
        self.bind()
        elf = self.make_elf()
        provenance = {"git_sha": "b" * 40, "git_dirty": 0}
        ARTIFACTS.finalize_manifest(self.manifest, elf, provenance)
        changed = bytearray(elf.read_bytes())
        changed[-1] ^= 1
        elf.write_bytes(changed)
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "candidate ELF SHA256 mismatch"
        ):
            ARTIFACTS.verify_manifest(
                self.manifest,
                "run",
                expected_software_provenance=provenance,
            )

    def test_wrong_abi_is_rejected(self):
        self.bind()
        value = json.loads(self.manifest.read_text(encoding="utf-8"))
        value["runtime"]["abi_version"] = 1
        self.manifest.write_text(json.dumps(value), encoding="utf-8")
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "identity mismatch"
        ):
            ARTIFACTS.verify_manifest(self.manifest, "build")

    def test_generated_parameter_header_is_hash_bound(self):
        self.bind()
        value = json.loads(self.manifest.read_text(encoding="utf-8"))
        self.assertIn("binding_header", value["parameters"])

    def test_parameter_layer_layout_and_header_tampering_are_rejected(self):
        package = self.root / "parameter_copy"
        shutil.copytree(self.parameter_dir, package)
        parameter_manifest = package / "abi_v2_parameter_manifest.json"
        value = json.loads(parameter_manifest.read_text(encoding="utf-8"))
        value["layers"][7]["weight"]["packets"] += 1
        parameter_manifest.write_text(json.dumps(value), encoding="utf-8")
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "size/packet mismatch"
        ):
            ARTIFACTS.validate_parameter_manifest(parameter_manifest)

        shutil.rmtree(package)
        shutil.copytree(self.parameter_dir, package)
        header = package / "accel_v2_parameter_package.h"
        header.write_text(
            header.read_text(encoding="ascii").replace(
                "{0U, 26624U, 0U, 239616U, 208U, 416U}",
                "{64U, 26624U, 0U, 239616U, 208U, 416U}",
            ),
            encoding="ascii",
        )
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "layer table"
        ):
            ARTIFACTS.validate_parameter_manifest(parameter_manifest)

    def test_candidate_manifest_must_reside_in_bound_workspace(self):
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "directly in its bound workspace"
        ):
            ARTIFACTS.bind_inputs(
                self.root / "relocated_candidate_manifest.json",
                self.workspace,
                self.xsa,
                self.bit,
                self.metadata,
                self.hardware_sha_manifest,
                self.parameter_dir / "abi_v2_parameter_manifest.json",
            )

    def test_selected_parameter_directory_must_match_bound_manifest(self):
        self.bind()
        other_package = self.root / "other_parameter_package"
        shutil.copytree(self.parameter_dir, other_package)
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError,
            "parameter-package selection mismatch",
        ):
            ARTIFACTS.verify_manifest(
                self.manifest,
                "build",
                expected_parameter_manifest=(
                    other_package / "abi_v2_parameter_manifest.json"
                ),
            )

    def test_selected_parameter_payloads_must_match_bound_files(self):
        self.bind()
        wrong_bias = self.root / "wrong_bias.bin"
        wrong_bias.write_bytes(b"wrong")
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "bias package selection mismatch"
        ):
            ARTIFACTS.verify_manifest(
                self.manifest,
                "build",
                expected_bias=wrong_bias,
            )

    def test_legacy_or_dirty_hardware_is_rejected(self):
        for replacement in (
            "profile=legacy_r18c8_debug",
            "git_dirty=1",
            "cols=8",
        ):
            original = self.metadata.read_text(encoding="utf-8")
            if replacement.startswith("profile"):
                changed = original.replace("profile=abi_v2_release", replacement)
            elif replacement.startswith("git_dirty"):
                changed = original.replace("git_dirty=0", replacement)
            else:
                changed = original.replace("cols=16", replacement)
            self.metadata.write_text(changed, encoding="utf-8")
            with self.assertRaises(ARTIFACTS.CandidateArtifactError):
                self.bind()
            self.metadata.write_text(original, encoding="utf-8")

    def test_wrong_workspace_selection_and_elf_name_are_rejected(self):
        self.bind()
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "workspace mismatch"
        ):
            ARTIFACTS.verify_manifest(
                self.manifest,
                "build",
                self.root / "another_abi_v2_candidate",
            )
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "must be named"
        ):
            ARTIFACTS.finalize_manifest(
                self.manifest,
                self.make_elf("conv_accel_r18_c8_smoke.elf"),
                {"git_sha": "a" * 40, "git_dirty": 0},
            )

    def test_hardware_and_software_clean_git_shas_are_recorded_independently(self):
        self.bind()
        value = ARTIFACTS.finalize_manifest(
            self.manifest,
            self.make_elf(),
            {"git_sha": "b" * 40, "git_dirty": 0},
        )
        self.assertEqual(value["hardware"]["git_sha"], "a" * 40)
        self.assertEqual(value["software"]["git_sha"], "b" * 40)
        self.assertEqual(value["software"]["long_stream_runtime_enabled"], 1)
        self.assertEqual(value["software"]["stream_cfg"], 0xBF)
        self.assertFalse(value["software"]["performance_mode"])
        self.assertEqual(value["software"]["benchmark_runs"], 0)
        self.assertEqual(value["software"]["clock_hz"], 100_000_000)

    def test_200mhz_metadata_manifest_and_elf_clock_are_bound(self):
        text = self.metadata.read_text(encoding="utf-8")
        self.metadata.write_text(
            text.replace("profile=abi_v2_release", "profile=abi_v2_release_200")
            + "pl_clock_mhz=200\n"
            + "clock_hz=200000000\n"
            + "weight_dma_mm2s_burst=64\n",
            encoding="utf-8",
        )
        value = self.bind()
        self.assertEqual(value["hardware"]["profile"], "abi_v2_release_200")
        self.assertEqual(value["runtime"]["clock_hz"], 200_000_000)
        self.assertTrue(value["release_eligible"])
        complete = ARTIFACTS.finalize_manifest(
            self.manifest,
            self.make_elf(),
            {"git_sha": "b" * 40, "git_dirty": 0},
            clock_hz=200_000_000,
        )
        self.assertEqual(complete["software"]["clock_hz"], 200_000_000)
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "does not match manifest clock"
        ):
            ARTIFACTS.finalize_manifest(
                self.manifest,
                self.make_elf(),
                {"git_sha": "b" * 40, "git_dirty": 0},
                clock_hz=100_000_000,
            )

    def test_125mhz_sweep_allows_only_functional_or_dev30_performance(self):
        text = self.metadata.read_text(encoding="utf-8")
        self.metadata.write_text(
            text.replace(
                "profile=abi_v2_release",
                "profile=abi_v2_frequency_sweep_125",
            )
            + "pl_clock_mhz=125\n"
            + "clock_hz=125000000\n"
            + "weight_dma_mm2s_burst=64\n"
            + "source_profile=abi_v2_release_200\n"
            + "development_frequency_sweep=1\n"
            + "place_min_wns=0.08\n"
            + "min_wns=0.0\n",
            encoding="utf-8",
        )
        value = self.bind()
        self.assertEqual(
            value["hardware"]["profile"], "abi_v2_frequency_sweep_125"
        )
        self.assertEqual(value["runtime"]["clock_hz"], 125_000_000)
        self.assertFalse(value["release_eligible"])
        self.assertFalse(value["hardware"]["release_eligible"])
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "one warm-up plus 30"
        ):
            ARTIFACTS.finalize_manifest(
                self.manifest,
                self.make_elf(),
                {"git_sha": "b" * 40, "git_dirty": 0},
                performance_mode=True,
                benchmark_runs=100,
                clock_hz=125_000_000,
            )
        complete = ARTIFACTS.finalize_manifest(
            self.manifest,
            self.make_elf(),
            {"git_sha": "b" * 40, "git_dirty": 0},
            clock_hz=125_000_000,
        )
        self.assertEqual(complete["software"]["run_mode"], "functional")
        self.assertFalse(complete["software"]["performance_mode"])
        ARTIFACTS.verify_manifest(
            self.manifest,
            "run",
            expected_clock_hz=125_000_000,
        )
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "no soak"
        ):
            ARTIFACTS.finalize_manifest(
                self.manifest,
                self.make_elf(),
                {"git_sha": "b" * 40, "git_dirty": 0},
                performance_mode=True,
                clock_hz=125_000_000,
                soak_seconds=600,
                soak_temp_limit_millic=85_000,
            )
        performance = ARTIFACTS.finalize_manifest(
            self.manifest,
            self.make_elf(),
            {"git_sha": "b" * 40, "git_dirty": 0},
            performance_mode=True,
            benchmark_runs=30,
            clock_hz=125_000_000,
        )
        self.assertEqual(performance["software"]["run_mode"], "benchmark")
        self.assertTrue(performance["software"]["performance_mode"])
        self.assertEqual(performance["software"]["benchmark_runs"], 30)
        self.assertFalse(performance["release_eligible"])
        ARTIFACTS.verify_manifest(
            self.manifest,
            "run",
            expected_clock_hz=125_000_000,
        )

    def test_125mhz_sweep_requires_explicit_development_metadata(self):
        text = self.metadata.read_text(encoding="utf-8")
        self.metadata.write_text(
            text.replace(
                "profile=abi_v2_release",
                "profile=abi_v2_frequency_sweep_125",
            )
            + "pl_clock_mhz=125\n"
            + "clock_hz=125000000\n"
            + "weight_dma_mm2s_burst=64\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError,
            "development_frequency_sweep",
        ):
            self.bind()

    def test_125mhz_sweep_locks_full_system_wns_gates(self):
        text = self.metadata.read_text(encoding="utf-8")
        valid = (
            text.replace(
                "profile=abi_v2_release",
                "profile=abi_v2_frequency_sweep_125",
            )
            + "pl_clock_mhz=125\n"
            + "clock_hz=125000000\n"
            + "weight_dma_mm2s_burst=64\n"
            + "source_profile=abi_v2_release_200\n"
            + "development_frequency_sweep=1\n"
            + "place_min_wns=0.08\n"
            + "min_wns=0.0\n"
        )
        for key, valid_value, bad_values in (
            ("place_min_wns", "0.08", ("0.079", "0.081")),
            ("min_wns", "0.0", ("-0.001", "0.001")),
        ):
            with self.subTest(key=key, mutation="missing"):
                self.metadata.write_text(
                    valid.replace(f"{key}={valid_value}\n", ""),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(
                    ARTIFACTS.CandidateArtifactError, key
                ):
                    self.bind()
            for bad_value in bad_values:
                with self.subTest(key=key, value=bad_value):
                    self.metadata.write_text(
                        valid.replace(
                            f"{key}={valid_value}\n",
                            f"{key}={bad_value}\n",
                        ),
                        encoding="utf-8",
                    )
                    with self.assertRaisesRegex(
                        ARTIFACTS.CandidateArtifactError, key
                    ):
                        self.bind()

    def test_release_eligibility_tampering_is_rejected(self):
        self.bind()
        value = json.loads(self.manifest.read_text(encoding="utf-8"))
        value["release_eligible"] = False
        self.manifest.write_text(json.dumps(value), encoding="utf-8")
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "release eligibility mismatch"
        ):
            ARTIFACTS.verify_manifest(self.manifest, "build")

    def test_pre_clock_contract_100mhz_complete_manifest_is_compatible(self):
        self.bind()
        ARTIFACTS.finalize_manifest(
            self.manifest,
            self.make_elf(),
            {"git_sha": "b" * 40, "git_dirty": 0},
        )
        value = json.loads(self.manifest.read_text(encoding="utf-8"))
        value["runtime"].pop("clock_hz")
        value["hardware"].pop("clock_hz")
        value["software"].pop("clock_hz")
        self.manifest.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        verified = ARTIFACTS.verify_manifest(
            self.manifest, "run", expected_clock_hz=100_000_000
        )
        self.assertEqual(ARTIFACTS.manifest_clock_hz(verified), 100_000_000)

    def test_software_git_sha_format_and_provenance_are_verified(self):
        self.bind()
        elf = self.make_elf()
        provenance = {"git_sha": "b" * 40, "git_dirty": 0}
        ARTIFACTS.finalize_manifest(self.manifest, elf, provenance)

        value = json.loads(self.manifest.read_text(encoding="utf-8"))
        value["software"]["git_sha"] = "b" * 39
        self.manifest.write_text(json.dumps(value), encoding="utf-8")
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "invalid Git SHA"
        ):
            ARTIFACTS.verify_manifest(self.manifest, "run")

        value["software"]["git_sha"] = "b" * 40
        self.manifest.write_text(json.dumps(value), encoding="utf-8")
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError,
            "software Git provenance mismatch",
        ):
            ARTIFACTS.verify_manifest(
                self.manifest,
                "run",
                expected_software_provenance={
                    "git_sha": "c" * 40,
                    "git_dirty": 0,
                },
            )

    def test_performance_candidate_requires_full_release_stream_cfg(self):
        self.bind()
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "STREAM_CFG=0xBF"
        ):
            ARTIFACTS.finalize_manifest(
                self.manifest,
                self.make_elf(),
                {"git_sha": "b" * 40, "git_dirty": 0},
                stream_cfg=0x2B,
                performance_mode=True,
            )
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "warm-up plus 30"
        ):
            ARTIFACTS.finalize_manifest(
                self.manifest,
                self.make_elf(),
                {"git_sha": "b" * 40, "git_dirty": 0},
                stream_cfg=0xBF,
                performance_mode=True,
            )
        value = ARTIFACTS.finalize_manifest(
            self.manifest,
            self.make_elf(),
            {"git_sha": "b" * 40, "git_dirty": 0},
            stream_cfg=0xBF,
            performance_mode=True,
            benchmark_runs=30,
        )
        self.assertEqual(value["software"]["stream_cfg"], 0xBF)
        self.assertTrue(value["software"]["performance_mode"])
        self.assertEqual(value["software"]["benchmark_runs"], 30)

    def test_tampered_software_runtime_identity_is_rejected(self):
        self.bind()
        ARTIFACTS.finalize_manifest(
            self.manifest,
            self.make_elf(),
            {"git_sha": "b" * 40, "git_dirty": 0},
        )
        value = json.loads(self.manifest.read_text(encoding="utf-8"))
        value["software"]["stream_cfg"] = 0x43
        self.manifest.write_text(json.dumps(value), encoding="utf-8")
        with self.assertRaisesRegex(
            ARTIFACTS.CandidateArtifactError, "invalid STREAM_CFG"
        ):
            ARTIFACTS.verify_manifest(self.manifest, "run")

    def test_formal_100_run_performance_manifest_is_supported(self):
        self.bind()
        value = ARTIFACTS.finalize_manifest(
            self.manifest,
            self.make_elf(),
            {"git_sha": "b" * 40, "git_dirty": 0},
            stream_cfg=0xBF,
            performance_mode=True,
            benchmark_runs=100,
        )
        self.assertTrue(value["software"]["performance_mode"])
        self.assertEqual(value["software"]["benchmark_runs"], 100)
        ARTIFACTS.verify_manifest(self.manifest, "run")

    def test_independent_soak_manifest_binds_duration_temperature_and_mode(self):
        self.bind()
        value = ARTIFACTS.finalize_manifest(
            self.manifest,
            self.make_elf(),
            {"git_sha": "b" * 40, "git_dirty": 0},
            stream_cfg=0xBF,
            performance_mode=True,
            benchmark_runs=0,
            soak_seconds=600,
            soak_temp_limit_millic=85_000,
        )
        software = value["software"]
        self.assertEqual(software["run_mode"], "soak")
        self.assertEqual(software["soak_seconds"], 600)
        self.assertEqual(software["soak_temp_limit_millic"], 85_000)
        self.assertEqual(software["benchmark_runs"], 0)
        self.assertTrue(software["performance_mode"])
        ARTIFACTS.verify_manifest(self.manifest, "run")

    def test_soak_manifest_rejects_short_duration_and_wrong_temperature(self):
        self.bind()
        for seconds, temp, message in (
            (599, 85_000, "at least 600 seconds"),
            (600, 85_001, "85000 mC"),
        ):
            with self.subTest(seconds=seconds, temp=temp):
                with self.assertRaisesRegex(
                    ARTIFACTS.CandidateArtifactError, message
                ):
                    ARTIFACTS.finalize_manifest(
                        self.manifest,
                        self.make_elf(),
                        {"git_sha": "b" * 40, "git_dirty": 0},
                        stream_cfg=0xBF,
                        performance_mode=True,
                        benchmark_runs=0,
                        soak_seconds=seconds,
                        soak_temp_limit_millic=temp,
                    )

    @unittest.skipUnless(shutil.which("tclsh"), "tclsh is unavailable")
    def test_tcl_build_and_download_check_only_interfaces(self):
        self.bind()
        powershell = shutil.which("powershell")
        if powershell is not None:
            mixed_build = subprocess.run(
                [
                    powershell,
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(SCRIPT_DIR / "manual_build_accel_smoke.ps1"),
                    "-Mode",
                    "conv0_conv9_batch_chain",
                    "-RuntimeAbiVersion",
                    "2",
                    "-WorkspacePath",
                    str(self.root / "build_vitis_2022_2"),
                    "-ParameterPackageDir",
                    str(self.parameter_dir),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(mixed_build.returncode, 0)
            self.assertIn(
                "isolated workspace", mixed_build.stdout + mixed_build.stderr
            )
            external_repro = subprocess.run(
                [
                    powershell,
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(SCRIPT_DIR / "manual_build_accel_smoke.ps1"),
                    "-Mode",
                    "conv0_conv9_batch_chain",
                    "-RuntimeAbiVersion",
                    "2",
                    "-ReproRoot",
                    str(self.root / "external_repro"),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(external_repro.returncode, 0)
            self.assertIn(
                "repository repro directory",
                external_repro.stdout + external_repro.stderr,
            )
            build_check = subprocess.run(
                [
                    powershell,
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(SCRIPT_DIR / "build_abi_v2_candidate.ps1"),
                    "-Workspace",
                    str(self.workspace),
                    "-Xsa",
                    str(self.xsa),
                    "-BitFile",
                    str(self.bit),
                    "-HardwareMetadata",
                    str(self.metadata),
                    "-HardwareShaManifest",
                    str(self.hardware_sha_manifest),
                    "-ParameterPackageDir",
                    str(self.parameter_dir),
                    "-CheckOnly",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                build_check.returncode,
                0,
                build_check.stdout + build_check.stderr,
            )
            self.assertIn("build inputs are bound and verified", build_check.stdout)
            soak_args = [*build_check.args, "-Soak"]
            soak_workspace = self.root / "build_vitis_2022_2_abi_v2_candidate_soak"
            soak_args[soak_args.index("-Workspace") + 1] = str(soak_workspace)
            soak_check = subprocess.run(
                soak_args,
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                soak_check.returncode,
                0,
                soak_check.stdout + soak_check.stderr,
            )
            self.assertIn("RunMode: soak", soak_check.stdout)
            self.assertIn("SoakSeconds: 600", soak_check.stdout)
        create = subprocess.run(
            [
                shutil.which("tclsh"),
                str(SCRIPT_DIR / "create_abi_v2_candidate_project.tcl"),
                "-workspace",
                str(self.workspace),
                "-xsa",
                str(self.xsa),
                "-manifest",
                str(self.manifest),
                "-check_only",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(create.returncode, 0, create.stdout + create.stderr)
        self.assertIn("PASS: ABI v2 candidate project configuration", create.stdout)

        elf = self.make_elf()
        ARTIFACTS.finalize_manifest(
            self.manifest,
            elf,
            {"git_sha": "b" * 40, "git_dirty": 0},
        )
        download = subprocess.run(
            [
                shutil.which("tclsh"),
                str(SCRIPT_DIR / "download_run_accel_smoke.tcl"),
                "-abi_version",
                "2",
                "-workspace",
                str(self.workspace),
                "-platform_name",
                "conv_accel_abi_v2_candidate_platform",
                "-artifact_manifest",
                str(self.manifest),
                "-bit_file",
                str(self.bit),
                "-elf",
                str(elf),
                "-bias_file",
                str(self.parameter_dir / "abi_v2_bias_cout32.bin"),
                "-weight_file",
                str(self.parameter_dir / "abi_v2_weight_cout32.bin"),
                "-check_only",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(download.returncode, 0, download.stdout + download.stderr)
        self.assertIn("download artifact selection verified", download.stdout)

        for bypass_switch in ("-fast", "-skip_bit"):
            bypass = subprocess.run(
                [
                    shutil.which("tclsh"),
                    str(SCRIPT_DIR / "download_run_accel_smoke.tcl"),
                    "-abi_version",
                    "2",
                    "-workspace",
                    str(self.workspace),
                    "-platform_name",
                    "conv_accel_abi_v2_candidate_platform",
                    "-artifact_manifest",
                    str(self.manifest),
                    "-bit_file",
                    str(self.bit),
                    "-elf",
                    str(elf),
                    "-bias_file",
                    str(self.parameter_dir / "abi_v2_bias_cout32.bin"),
                    "-weight_file",
                    str(self.parameter_dir / "abi_v2_weight_cout32.bin"),
                    bypass_switch,
                    "-check_only",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(bypass.returncode, 0)
            self.assertIn(
                "programming the verified bitstream",
                bypass.stdout + bypass.stderr,
            )

        (self.workspace / "conv_accel_abi_v2_candidate_platform").mkdir()
        (self.workspace / "conv_accel_abi_v2_candidate").mkdir(exist_ok=True)
        (self.workspace / ".abi_v2_candidate_workspace").write_text(
            "profile=abi_v2_candidate\n"
            "abi_version=2\n"
            "vitis_version=2022.2\n"
            f"xsa_sha256={'0' * 64}\n",
            encoding="ascii",
        )
        stale_workspace = subprocess.run(
            [
                shutil.which("tclsh"),
                str(SCRIPT_DIR / "create_abi_v2_candidate_project.tcl"),
                "-workspace",
                str(self.workspace),
                "-xsa",
                str(self.xsa),
                "-manifest",
                str(self.manifest),
                "-check_only",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(stale_workspace.returncode, 0)
        self.assertIn(
            "workspace marker mismatch",
            stale_workspace.stdout + stale_workspace.stderr,
        )


if __name__ == "__main__":
    unittest.main()

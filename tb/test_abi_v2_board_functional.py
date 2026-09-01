import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "demo" / "abi_v2_board_functional.py"
SPEC = importlib.util.spec_from_file_location("abi_v2_board_functional", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
FUNCTIONAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FUNCTIONAL)


class BoardFunctionalTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="abi_v2_board_functional_")
        self.root = Path(self.temp.name)
        self.log = self.root / "board.log"
        self.manifest = self.root / "abi_v2_candidate_manifest.json"
        self.manifest.write_text(
            json.dumps(
                {
                    "state": "complete",
                    "candidate_profile": "abi_v2_candidate",
                    "release_eligible": False,
                    "hardware": {
                        "profile": "abi_v2_frequency_sweep_125",
                        "clock_hz": 125_000_000,
                        "release_eligible": False,
                        "git_dirty": 0,
                    },
                    "runtime": {
                        "abi_version": 2,
                        "rows": 18,
                        "cols": 16,
                        "cout_tile": 32,
                        "clock_hz": 125_000_000,
                    },
                    "software": {
                        "long_stream_runtime_enabled": 1,
                        "stream_cfg": 0xBF,
                        "performance_mode": False,
                        "benchmark_runs": 0,
                        "clock_hz": 125_000_000,
                        "run_mode": "functional",
                        "soak_seconds": 0,
                        "soak_temp_limit_millic": 0,
                        "git_dirty": 0,
                    },
                },
                indent=2,
            ),
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def valid_log(clock_hz: int = 125_000_000) -> str:
        busy_cycles = 4_700_000
        total_us = 120_000
        pl_busy_us = (busy_cycles * 1_000_000 + clock_hz - 1) // clock_hz
        unhidden_us = total_us - pl_busy_us
        lines = [
            f"{layer} full compare={size} bytes"
            for layer, size in FUNCTIONAL.EXPECTED_OFM_COMPARES
        ]
        lines.extend(
            (
                f"ABI_V2_TOTAL busy={busy_cycles} feeder=100 "
                "context_psum_gap=200 drain_ofm=300 bias_weight=400 "
                "unclassified=0 contexts=29253 compute_fire=3889197 "
                "ifm_bytes=2249728 ofm_bytes=1734616 ofm_beats=216827 "
                "dma_bias=10 dma_weight=10 dma_ifm=10 dma_ofm=10 errors=0",
                f"ABI_V2_TIMING mode=functional clock_hz={clock_hz} "
                f"total_us={total_us} pl_busy_us={pl_busy_us} "
                f"unhidden_us={unhidden_us} "
                "final_cache_us=100 ifm_pack_us=0 ofm_parse_us=0",
                "PASS: ABI v2 ten-layer four-DMA dispatch complete",
            )
        )
        return "\n".join(lines) + "\n"

    def write_log(self, text: str | None = None) -> None:
        self.log.write_text(text or self.valid_log(), encoding="utf-8")

    def set_release_200_manifest(self, stream_cfg: int) -> None:
        value = json.loads(self.manifest.read_text(encoding="utf-8"))
        value["release_eligible"] = True
        value["hardware"].update(
            {
                "profile": "abi_v2_release_200",
                "clock_hz": 200_000_000,
                "release_eligible": True,
            }
        )
        value["runtime"]["clock_hz"] = 200_000_000
        value["software"]["clock_hz"] = 200_000_000
        value["software"]["stream_cfg"] = stream_cfg
        self.manifest.write_text(json.dumps(value), encoding="utf-8")

    def test_one_functional_run_passes_without_latency_gate(self):
        self.write_log()
        result = FUNCTIONAL.validate_functional(self.log, self.manifest)
        self.assertEqual(result["status"], "DEVELOPMENT_FUNCTIONAL_PASS")
        self.assertFalse(result["release_eligible"])
        self.assertFalse(result["performance_signoff"])
        self.assertFalse(result["timing_gate_applied"])
        self.assertEqual(result["timing"]["total_us"], 120_000)
        self.assertEqual(len(result["ofm_golden_compares"]), 10)

    def test_release_200_staged_configs_pass_and_are_identified(self):
        for stream_cfg in FUNCTIONAL.STAGED_STREAM_CONFIGS:
            with self.subTest(stream_cfg=hex(stream_cfg)):
                self.set_release_200_manifest(stream_cfg)
                self.write_log(self.valid_log(200_000_000))
                result = FUNCTIONAL.validate_functional(
                    self.log,
                    self.manifest,
                    expected_clock_hz=200_000_000,
                    expected_stream_cfg=stream_cfg,
                )
                self.assertEqual(result["status"], "RELEASE_FUNCTIONAL_STAGE_PASS")
                self.assertTrue(result["release_eligible"])
                self.assertEqual(result["stream_cfg"], stream_cfg)
                self.assertEqual(result["final_stream_cfg"], stream_cfg == 0xBF)
                self.assertFalse(result["performance_signoff"])

    def test_release_200_wrong_stage_or_manifest_identity_is_rejected(self):
        self.set_release_200_manifest(0x2B)
        self.write_log(self.valid_log(200_000_000))
        with self.assertRaisesRegex(FUNCTIONAL.FunctionalError, "STREAM_CFG"):
            FUNCTIONAL.validate_functional(
                self.log,
                self.manifest,
                expected_clock_hz=200_000_000,
                expected_stream_cfg=0x2F,
            )

        value = json.loads(self.manifest.read_text(encoding="utf-8"))
        value["hardware"]["profile"] = "abi_v2_frequency_sweep_125"
        self.manifest.write_text(json.dumps(value), encoding="utf-8")
        with self.assertRaisesRegex(FUNCTIONAL.FunctionalError, "identity"):
            FUNCTIONAL.validate_functional(
                self.log,
                self.manifest,
                expected_clock_hz=200_000_000,
                expected_stream_cfg=0x2B,
            )

    def test_missing_or_wrong_ofm_compare_is_rejected(self):
        text = self.valid_log().replace(
            "conv8 full compare=86528 bytes\n", "", 1
        )
        self.write_log(text)
        with self.assertRaisesRegex(FUNCTIONAL.FunctionalError, "OFM golden"):
            FUNCTIONAL.validate_functional(self.log, self.manifest)

        text = self.valid_log().replace(
            "conv9_detect_native1x1 full compare=4056 bytes",
            "conv9_detect_native1x1 full compare=4055 bytes",
        )
        self.write_log(text)
        with self.assertRaisesRegex(FUNCTIONAL.FunctionalError, "OFM golden"):
            FUNCTIONAL.validate_functional(self.log, self.manifest)

    def test_fail_or_benchmark_marker_is_rejected(self):
        self.write_log("FAIL: ABI v2 dispatch\n" + self.valid_log())
        with self.assertRaisesRegex(FUNCTIONAL.FunctionalError, "target reported"):
            FUNCTIONAL.validate_functional(self.log, self.manifest)

        self.write_log("ABI_V2_RUN_BEGIN index=0 warmup=1\n" + self.valid_log())
        with self.assertRaisesRegex(FUNCTIONAL.FunctionalError, "forbidden"):
            FUNCTIONAL.validate_functional(self.log, self.manifest)

    def test_clock_and_exact_counter_mismatch_are_rejected(self):
        self.write_log(
            self.valid_log().replace("clock_hz=125000000", "clock_hz=200000000")
        )
        with self.assertRaisesRegex(FUNCTIONAL.FunctionalError, "clock_hz"):
            FUNCTIONAL.validate_functional(self.log, self.manifest)

        self.write_log(
            self.valid_log().replace("compute_fire=3889197", "compute_fire=1")
        )
        with self.assertRaisesRegex(FUNCTIONAL.FunctionalError, "compute_fire"):
            FUNCTIONAL.validate_functional(self.log, self.manifest)

    def test_timing_decomposition_is_checked_but_not_thresholded(self):
        self.write_log(
            self.valid_log().replace("pl_busy_us=37600", "pl_busy_us=37599")
        )
        with self.assertRaisesRegex(FUNCTIONAL.FunctionalError, "decomposition"):
            FUNCTIONAL.validate_functional(self.log, self.manifest)

    def test_release_eligible_or_performance_manifest_is_rejected(self):
        value = json.loads(self.manifest.read_text(encoding="utf-8"))
        value["release_eligible"] = True
        self.manifest.write_text(json.dumps(value), encoding="utf-8")
        self.write_log()
        with self.assertRaisesRegex(FUNCTIONAL.FunctionalError, "identity"):
            FUNCTIONAL.validate_functional(self.log, self.manifest)

        value["release_eligible"] = False
        value["software"]["performance_mode"] = True
        self.manifest.write_text(json.dumps(value), encoding="utf-8")
        with self.assertRaisesRegex(FUNCTIONAL.FunctionalError, "identity"):
            FUNCTIONAL.validate_functional(self.log, self.manifest)


if __name__ == "__main__":
    unittest.main()

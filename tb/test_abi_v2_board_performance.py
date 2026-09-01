import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "demo" / "abi_v2_board_performance.py"
SPEC = importlib.util.spec_from_file_location("abi_v2_board_performance", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
PERFORMANCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PERFORMANCE)


def total_line(busy=4_627_284, **overrides):
    fields = {
        "busy": busy,
        "feeder": 443_891,
        "context_psum_gap": 32_528,
        "drain_ofm": 40_343,
        "bias_weight": 41_391,
        "unclassified": 1_736,
        "contexts": 29_253,
        "compute_fire": 3_889_197,
        "ifm_bytes": 2_249_728,
        "ofm_bytes": 1_734_616,
        "ofm_beats": 216_827,
        "dma_bias": 10,
        "dma_weight": 10,
        "dma_ifm": 10,
        "dma_ofm": 10,
        "errors": 0,
    }
    fields.update(overrides)
    return "ABI_V2_TOTAL " + " ".join(
        f"{key}={value}" for key, value in fields.items()
    )


def timing_line(total_us, pl_busy_us=37_019, **overrides):
    fields = {
        "mode": "performance",
        "clock_hz": 125_000_000,
        "total_us": total_us,
        "pl_busy_us": pl_busy_us,
        "unhidden_us": total_us - pl_busy_us,
        "final_cache_us": 0,
        "ifm_pack_us": 0,
        "ofm_parse_us": 0,
    }
    fields.update(overrides)
    return "ABI_V2_TIMING " + " ".join(
        f"{key}={value}" for key, value in fields.items()
    )


class BoardPerformanceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="abi_v2_board_perf125_")
        self.root = Path(self.temp.name)
        self.log = self.root / "board.log"
        self.manifest = self.root / "abi_v2_candidate_manifest.json"
        self.write_manifest()

    def tearDown(self):
        self.temp.cleanup()

    def write_manifest(self, **software_overrides):
        software = {
            "clock_hz": 125_000_000,
            "long_stream_runtime_enabled": 1,
            "stream_cfg": 0xBF,
            "performance_mode": True,
            "benchmark_runs": 30,
            "run_mode": "benchmark",
            "soak_seconds": 0,
            "soak_temp_limit_millic": 0,
        }
        software.update(software_overrides)
        self.manifest.write_text(
            json.dumps(
                {
                    "state": "complete",
                    "release_eligible": False,
                    "hardware": {
                        "profile": "abi_v2_frequency_sweep_125",
                        "clock_hz": 125_000_000,
                        "release_eligible": False,
                    },
                    "runtime": {"clock_hz": 125_000_000},
                    "software": software,
                }
            ),
            encoding="utf-8",
        )

    def write_records(
        self, totals, busy=4_627_284, pl_busy_us=37_019,
        total_overrides=None, timing_overrides=None,
    ):
        lines = []
        for index, value in enumerate(totals):
            lines.extend(
                [
                    f"ABI_V2_RUN_BEGIN index={index} warmup={int(index == 0)}",
                    total_line(busy=busy, **(total_overrides or {})),
                    timing_line(
                        value, pl_busy_us=pl_busy_us,
                        **(timing_overrides or {}),
                    ),
                    "PASS: ABI v2 ten-layer four-DMA dispatch complete",
                    f"ABI_V2_RUN_END index={index} warmup={int(index == 0)}",
                ]
            )
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_valid_measurement_reports_stats_without_claiming_signoff(self):
        self.write_records([39_100] + list(range(39_120, 39_150)))
        result = PERFORMANCE.validate_performance_measurement(
            self.log, self.manifest
        )
        self.assertEqual(result["status"], "DEVELOPMENT_PERFORMANCE_MEASURED")
        self.assertFalse(result["release_eligible"])
        self.assertFalse(result["performance_signoff"])
        self.assertFalse(result["timing_gate_applied"])
        self.assertEqual(result["warmup_record_count"], 1)
        self.assertEqual(result["timed_run_count"], 30)
        self.assertEqual(result["timing"]["total"]["p95_rank"], 29)
        self.assertEqual(result["timing"]["total"]["p95_us"], 39_148)
        self.assertEqual(result["timing"]["total"]["maximum_us"], 39_149)
        self.assertFalse(result["target_30ms"]["met"])
        self.assertEqual(result["exact_totals"], PERFORMANCE.signoff.EXACT_TOTALS)
        self.assertEqual(
            result["log"]["sha256"], PERFORMANCE.signoff.sha256_file(self.log)
        )

    def test_30ms_observation_is_exclusive_but_not_a_parser_failure(self):
        self.write_records(
            [29_999] * 31, busy=3_500_000, pl_busy_us=28_000
        )
        result = PERFORMANCE.validate_performance_measurement(
            self.log, self.manifest
        )
        self.assertTrue(result["target_30ms"]["met"])

        self.write_records(
            [30_000] * 31, busy=3_500_000, pl_busy_us=28_000
        )
        result = PERFORMANCE.validate_performance_measurement(
            self.log, self.manifest
        )
        self.assertFalse(result["target_30ms"]["met"])

    def test_manifest_must_be_non_release_dev30_performance(self):
        self.write_records([39_130] * 31)
        for field, value in (
            ("performance_mode", False),
            ("benchmark_runs", 0),
            ("run_mode", "functional"),
            ("soak_seconds", 600),
        ):
            with self.subTest(field=field):
                self.write_manifest(**{field: value})
                with self.assertRaisesRegex(
                    PERFORMANCE.PerformanceMeasurementError,
                    "not a non-release 125 MHz performance candidate",
                ):
                    PERFORMANCE.validate_performance_measurement(
                        self.log, self.manifest
                    )

    def test_wrong_count_failure_compare_and_counter_mismatch_are_rejected(self):
        self.write_records([39_130] * 30)
        with self.assertRaisesRegex(
            PERFORMANCE.PerformanceMeasurementError, "one warm-up plus 30"
        ):
            PERFORMANCE.validate_performance_measurement(self.log, self.manifest)

        self.write_records([39_130] * 31)
        with self.log.open("a", encoding="utf-8") as stream:
            stream.write("FAIL: injected\n")
        with self.assertRaisesRegex(
            PERFORMANCE.PerformanceMeasurementError, "target reported failure"
        ):
            PERFORMANCE.validate_performance_measurement(self.log, self.manifest)

        self.write_records([39_130] * 31)
        with self.log.open("a", encoding="utf-8") as stream:
            stream.write("conv0_pool full compare=692224 bytes\n")
        with self.assertRaisesRegex(
            PERFORMANCE.PerformanceMeasurementError, "golden comparisons"
        ):
            PERFORMANCE.validate_performance_measurement(self.log, self.manifest)

        self.write_records(
            [39_130] * 31, total_overrides={"compute_fire": 1}
        )
        with self.assertRaisesRegex(
            PERFORMANCE.PerformanceMeasurementError, "compute_fire"
        ):
            PERFORMANCE.validate_performance_measurement(self.log, self.manifest)

    def test_timing_mode_clock_pack_and_decomposition_are_rejected(self):
        for overrides, message in (
            ({"mode": "functional"}, "not a performance-mode"),
            ({"clock_hz": 100_000_000}, "clock_hz"),
            ({"ifm_pack_us": 1}, "IFM pack/OFM parse"),
            ({"unhidden_us": 1}, "decomposition"),
        ):
            with self.subTest(overrides=overrides):
                self.write_records(
                    [39_130] * 31, timing_overrides=overrides
                )
                with self.assertRaisesRegex(
                    PERFORMANCE.PerformanceMeasurementError, message
                ):
                    PERFORMANCE.validate_performance_measurement(
                        self.log, self.manifest
                    )


if __name__ == "__main__":
    unittest.main()

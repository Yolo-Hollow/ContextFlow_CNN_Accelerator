import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "demo" / "abi_v2_board_signoff.py"
SPEC = importlib.util.spec_from_file_location("abi_v2_board_signoff", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SIGNOFF = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNOFF)


def total_line(**overrides):
    fields = {
        "busy": 6_000_000,
        "feeder": 1_500_000,
        "context_psum_gap": 250_000,
        "drain_ofm": 500_000,
        "bias_weight": 150_000,
        "unclassified": 9_000,
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
    return "ABI_V2_TOTAL " + " ".join(f"{key}={value}" for key, value in fields.items())


def timing_line(total_us, **overrides):
    fields = {
        "mode": "performance",
        "clock_hz": 100_000_000,
        "total_us": total_us,
        "pl_busy_us": 60_000,
        "unhidden_us": total_us - 60_000,
        "final_cache_us": 20,
        "ifm_pack_us": 0,
        "ofm_parse_us": 0,
    }
    fields.update(overrides)
    return "ABI_V2_TIMING " + " ".join(
        f"{key}={value}" for key, value in fields.items()
    )


class BoardSignoffTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="abi_v2_board_signoff_")
        self.log = Path(self.temp.name) / "board.log"

    def tearDown(self):
        self.temp.cleanup()

    def record_lines(
        self, index, value, total_override=None, timing_override=None
    ):
        return [
            f"ABI_V2_RUN_BEGIN index={index} warmup={int(index == 0)}",
            total_line(**(total_override or {})),
            timing_line(value, **(timing_override or {})),
            "PASS: ABI v2 ten-layer four-DMA dispatch complete",
            f"ABI_V2_RUN_END index={index} warmup={int(index == 0)}",
        ]

    def write_records(
        self, samples, total_override=None, timing_override=None
    ):
        lines = []
        for index, value in enumerate(samples):
            lines.extend(
                self.record_lines(
                    index, value, total_override, timing_override
                )
            )
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_nearest_rank_p95_uses_sorted_sample_29(self):
        samples = [69_999] + [70_000 + value for value in range(1, 31)]
        self.write_records(samples)
        result = SIGNOFF.validate_signoff([self.log])
        self.assertEqual(result["warmup_record_count"], 1)
        self.assertEqual(result["timed_run_count"], 30)
        self.assertEqual(result["validated_record_count"], 31)
        self.assertEqual(result["exact_totals"], SIGNOFF.EXACT_TOTALS)
        self.assertEqual(result["p95_rank"], 29)
        self.assertEqual(result["p95_us"], 70_029)
        self.assertEqual(result["maximum_us"], 70_030)

    def test_wrong_sample_count_is_rejected(self):
        self.write_records([80_000] * 30)
        with self.assertRaisesRegex(SIGNOFF.SignoffError, "one warm-up plus 30"):
            SIGNOFF.validate_signoff([self.log])

    def test_hardware_metric_violation_is_rejected(self):
        self.write_records([80_000] * 31, {"compute_fire": 1})
        with self.assertRaisesRegex(SIGNOFF.SignoffError, "compute_fire"):
            SIGNOFF.validate_signoff([self.log])

    def test_p95_above_90000_us_is_rejected(self):
        self.write_records([70_000] + [80_000] * 28 + [90_001, 95_000])
        with self.assertRaisesRegex(SIGNOFF.SignoffError, "p95=90001"):
            SIGNOFF.validate_signoff([self.log])

    def test_maximum_at_100000_us_is_rejected(self):
        self.write_records([70_000] + [80_000] * 29 + [100_000])
        with self.assertRaisesRegex(SIGNOFF.SignoffError, "maximum=100000"):
            SIGNOFF.validate_signoff([self.log])

    def test_50000_exclusive_wall_and_p95_boundaries(self):
        self.write_records(
            [49_999] * 31,
            total_override={"busy": 4_000_000},
            timing_override={"pl_busy_us": 40_000, "unhidden_us": 9_999},
        )
        result = SIGNOFF.validate_signoff(
            [self.log], max_us_exclusive=50_000,
            p95_us_exclusive=50_000,
        )
        self.assertEqual(result["maximum_us"], 49_999)
        self.assertEqual(result["gates"]["max_us_exclusive"], 50_000)

        self.write_records(
            [50_000] * 31,
            total_override={"busy": 4_000_000},
            timing_override={"pl_busy_us": 40_000, "unhidden_us": 10_000},
        )
        with self.assertRaisesRegex(SIGNOFF.SignoffError, "p95=50000"):
            SIGNOFF.validate_signoff(
                [self.log], max_us_exclusive=60_000,
                p95_us_exclusive=50_000,
            )
        with self.assertRaisesRegex(SIGNOFF.SignoffError, "maximum=50000"):
            SIGNOFF.validate_signoff(
                [self.log], max_us_exclusive=50_000,
                p95_us_exclusive=60_000,
            )

    def test_busy_cycles_and_200mhz_conversion_are_explicit(self):
        self.write_records(
            [29_000] * 31,
            total_override={"busy": 5_400_000},
            timing_override={
                "clock_hz": 200_000_000,
                "pl_busy_us": 27_000,
                "unhidden_us": 2_000,
            },
        )
        result = SIGNOFF.validate_signoff(
            [self.log], max_us_exclusive=30_000,
            p95_us_exclusive=30_000, max_busy_cycles=5_400_000,
            max_busy_us=30_000, max_unhidden_us=2_500,
            expected_clock_hz=200_000_000,
        )
        self.assertEqual(result["clock_hz"], 200_000_000)
        self.assertEqual(result["warmup_record_count"], 1)
        self.assertEqual(result["validated_record_count"], 31)
        self.assertEqual(
            result["gates"]["max_busy_cycles_inclusive"], 5_400_000
        )

        self.write_records(
            [29_001] * 31,
            total_override={"busy": 5_400_001},
            timing_override={
                "clock_hz": 200_000_000,
                "pl_busy_us": 27_001,
                "unhidden_us": 2_000,
            },
        )
        with self.assertRaisesRegex(SIGNOFF.SignoffError, "busy=5400001"):
            SIGNOFF.validate_signoff(
                [self.log], max_busy_cycles=5_400_000,
                expected_clock_hz=200_000_000,
            )

    def test_timed_pack_or_parse_is_rejected(self):
        for field in ("ifm_pack_us", "ofm_parse_us"):
            with self.subTest(field=field):
                self.write_records(
                    [80_000] * 31, timing_override={field: 1}
                )
                with self.assertRaisesRegex(
                    SIGNOFF.SignoffError, "timed IFM pack/OFM parse"
                ):
                    SIGNOFF.validate_signoff([self.log])

    def test_each_dma_count_mismatch_is_rejected(self):
        for field in ("dma_bias", "dma_weight", "dma_ifm", "dma_ofm"):
            with self.subTest(field=field):
                self.write_records([80_000] * 31, {field: 9})
                with self.assertRaisesRegex(SIGNOFF.SignoffError, field):
                    SIGNOFF.validate_signoff([self.log])

    def test_missing_begin_marker_is_rejected(self):
        lines = self.record_lines(0, 80_000)[1:]
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(SIGNOFF.SignoffError, "unexpected ABI_V2_TOTAL"):
            SIGNOFF.parse_logs([self.log])

    def test_missing_end_marker_is_rejected(self):
        lines = self.record_lines(0, 80_000)[:-1]
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(SIGNOFF.SignoffError, "incomplete result record"):
            SIGNOFF.parse_logs([self.log])

    def test_result_record_order_is_enforced(self):
        lines = self.record_lines(0, 80_000)
        lines[1], lines[2] = lines[2], lines[1]
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(SIGNOFF.SignoffError, "unexpected ABI_V2_TIMING"):
            SIGNOFF.parse_logs([self.log])

    def test_begin_end_marker_pair_mismatch_is_rejected(self):
        lines = self.record_lines(0, 80_000)
        lines[-1] = "ABI_V2_RUN_END index=1 warmup=1"
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(SIGNOFF.SignoffError, "marker pair mismatch"):
            SIGNOFF.parse_logs([self.log])

    def test_nearest_rank_helper_uses_rank_29_for_thirty_samples(self):
        rank, value = SIGNOFF.nearest_rank_p95(
            list(reversed(range(1, 31)))
        )
        self.assertEqual((rank, value), (29, 29))


if __name__ == "__main__":
    unittest.main()

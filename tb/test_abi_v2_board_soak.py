import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "demo" / "abi_v2_board_soak.py"
SPEC = importlib.util.spec_from_file_location("abi_v2_board_soak", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SOAK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOAK)


class BoardSoakTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="abi_v2_board_soak_")
        self.log = Path(self.temp.name) / "soak.log"

    def tearDown(self):
        self.temp.cleanup()

    def write_valid(self, **end_overrides):
        lines = [
            "ABI_V2_SOAK_BEGIN min_seconds=600 progress_seconds=10 "
            "temp_limit_millic=85000 temp_min_millic=-40000 "
            "clock_hz=200000000 sensor=ps_onchip"
        ]
        for index in range(1, 61):
            lines.append(
                "ABI_V2_SOAK_PROGRESS "
                f"elapsed_ms={index * 10000} runs={index * 300} "
                f"temp_millic={55000 + index} "
                f"max_temp_millic={60000 + index} thermal_warnings=0"
            )
        end = {
            "elapsed_ms": 600000,
            "runs": 18000,
            "verified_runs": 18000,
            "max_temp_millic": 60060,
            "thermal_warnings": 0,
            "dma_errors": 0,
            "counter_errors": 0,
            "timeouts": 0,
            "clock_hz": 200000000,
        }
        end.update(end_overrides)
        lines.append(
            "ABI_V2_SOAK_END " +
            " ".join(f"{key}={value}" for key, value in end.items())
        )
        lines.append("PASS: ABI v2 soak complete")
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_valid_ten_minute_contract_is_hash_bound(self):
        self.write_valid()
        result = SOAK.validate_soak(self.log)
        self.assertEqual(result["elapsed_ms"], 600000)
        self.assertEqual(result["runs"], 18000)
        self.assertEqual(result["verified_runs"], 18000)
        self.assertEqual(result["progress_record_count"], 60)
        self.assertEqual(result["max_temp_millic"], 60060)
        self.assertEqual(result["log"]["sha256"], SOAK.sha256_file(self.log))

    def test_strict_85c_boundary_is_rejected(self):
        self.write_valid(max_temp_millic=85000)
        lines = self.log.read_text(encoding="utf-8").splitlines()
        lines[-3] = lines[-3].replace(
            "max_temp_millic=60060", "max_temp_millic=85000"
        )
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(SOAK.SoakError, "must be <85000"):
            SOAK.validate_soak(self.log)

    def test_invalid_low_sysmon_sample_is_rejected(self):
        self.write_valid()
        lines = self.log.read_text(encoding="utf-8").splitlines()
        lines[1] = lines[1].replace("temp_millic=55001", "temp_millic=-40001")
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(SOAK.SoakError, "invalid SysMon sample"):
            SOAK.validate_soak(self.log)

    def test_duration_and_progress_gap_are_fail_closed(self):
        self.write_valid(elapsed_ms=599999)
        with self.assertRaisesRegex(SOAK.SoakError, "expected at least 600000"):
            SOAK.validate_soak(self.log)

        self.write_valid()
        lines = self.log.read_text(encoding="utf-8").splitlines()
        del lines[1]
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(SOAK.SoakError, "gap=20000"):
            SOAK.validate_soak(self.log)

    def test_counter_dma_timeout_and_warning_summaries_must_be_zero(self):
        for key in (
            "thermal_warnings", "dma_errors", "counter_errors", "timeouts"
        ):
            with self.subTest(key=key):
                self.write_valid(**{key: 1})
                with self.assertRaisesRegex(SOAK.SoakError, key):
                    SOAK.validate_soak(self.log)

    def test_verified_run_count_and_target_failure_are_rejected(self):
        self.write_valid(verified_runs=17999)
        with self.assertRaisesRegex(SOAK.SoakError, "exact-counter"):
            SOAK.validate_soak(self.log)

        self.write_valid()
        self.log.write_text(
            self.log.read_text(encoding="utf-8") +
            "FAIL: ABI v2 soak dispatch run=18001 rc=-109\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(SOAK.SoakError, "target reported failure"):
            SOAK.validate_soak(self.log)

    def test_missing_completion_record_is_rejected(self):
        self.write_valid()
        lines = self.log.read_text(encoding="utf-8").splitlines()[:-1]
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(SOAK.SoakError, "incomplete soak record"):
            SOAK.validate_soak(self.log)

    def test_finite_benchmark_records_cannot_masquerade_as_soak(self):
        self.write_valid()
        self.log.write_text(
            "ABI_V2_TOTAL contexts=29253 errors=0\n" +
            self.log.read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(SOAK.SoakError, "finite benchmark record"):
            SOAK.validate_soak(self.log)


if __name__ == "__main__":
    unittest.main()

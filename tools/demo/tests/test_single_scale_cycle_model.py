import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


DEMO_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(DEMO_DIR))

import single_scale_cycle_model as cycle_model  # noqa: E402


TARGET_LAYER_FIRE = [
    346_112,
    346_112,
    346_112,
    346_112,
    346_112,
    346_112,
    1_384_448,
    77_064,
    346_112,
    4_901,
]

LEGACY_LAYER_FIRE = [
    346_112,
    692_224,
    692_224,
    692_224,
    692_224,
    692_224,
    2_768_896,
    154_128,
    692_224,
    9_802,
]


def passing_metrics(model):
    return {
        "compute_fire_cycles": model["totals"]["compute_fire_cycles"],
        "pl_busy_cycles": 7_000_000,
        "feeder_unhidden_cycles": 2_000_000,
        "context_psum_gap_cycles": 300_000,
        "drain_ofm_post_cycles": 600_000,
        "bias_weight_wait_cycles": 200_000,
        "unclassified_cycles": 10_000,
        "prefetch_miss_count": 0,
        "ifm_underflow_count": 0,
        "psum_underflow_count": 0,
        "fifo_drop_count": 0,
        "epoch_mismatch_count": 0,
        "context_full_stall_cycles": 0,
        "ifm_pack_us": 500,
        "ofm_parse_us": 500,
        "ifm_dma_starts": 10,
        "ofm_dma_starts": 10,
        "ifm_bytes": 2_249_728,
        "ofm_bytes": 1_734_616,
        "ofm_beats": 216_827,
        "layers": {
            layer["layer"]: {"busy_cycles": layer["pl_busy_budget_cycles"]}
            for layer in model["layers"]
        },
    }


class CycleModelTests(unittest.TestCase):
    def test_target_18x16_exact_compute_fire(self):
        model = cycle_model.build_model(
            cycle_model.ArrayConfig(rows=18, cols=16, cout_tile=32)
        )

        self.assertEqual(
            [layer["compute_fire_cycles"] for layer in model["layers"]],
            TARGET_LAYER_FIRE,
        )
        self.assertEqual(model["totals"]["compute_fire_cycles"], 3_889_197)
        self.assertAlmostEqual(model["totals"]["compute_fire_ms"], 38.89197)

    def test_legacy_18x8_exact_compute_fire(self):
        model = cycle_model.build_model(
            cycle_model.ArrayConfig(rows=18, cols=8, cout_tile=16)
        )

        self.assertEqual(
            [layer["compute_fire_cycles"] for layer in model["layers"]],
            LEGACY_LAYER_FIRE,
        )
        self.assertEqual(model["totals"]["compute_fire_cycles"], 7_432_282)

    def test_hwc_traffic_and_axis_beats_are_exact(self):
        model = cycle_model.build_model()
        totals = model["totals"]

        self.assertEqual(totals["ifm_bytes"], 2_249_728)
        self.assertEqual(totals["ifm_beats"], 281_216)
        self.assertEqual(totals["ofm_bytes"], 1_734_616)
        self.assertEqual(totals["ofm_beats"], 216_827)
        self.assertEqual(totals["axis_bytes"], 3_984_344)
        self.assertEqual(totals["axis_beats"], 498_043)
        self.assertAlmostEqual(totals["ideal_axis_ms_at_one_beat_per_cycle"], 4.98043)

    def test_byte_bram_materializer_service_is_exact(self):
        model = cycle_model.build_model()
        totals = model["totals"]

        self.assertEqual(totals["materializer_store_bytes_per_cycle"], 4)
        self.assertEqual(totals["materialized_entries"], 1_096_134)
        self.assertEqual(totals["materializer_store_cycles"], 562_432)
        self.assertEqual(totals["materializer_entry_cycles"], 1_154_270)
        self.assertEqual(totals["materializer_serial_cycles"], 1_716_702)
        self.assertAlmostEqual(totals["materializer_serial_ms"], 17.16702)

        conv0 = model["layers"][0]
        self.assertEqual(conv0["materialized_entries"], 346_112)
        self.assertEqual(conv0["materializer_serial_cycles"], 475_904)

        conv7 = model["layers"][7]
        self.assertEqual(conv7["materialized_entries"], 9_633)
        self.assertEqual(conv7["materializer_entry_cycles"], 48_165)

    def test_target_budget_has_only_803_cycles_slack(self):
        target = cycle_model.build_model()
        legacy = cycle_model.build_model(cycle_model.ArrayConfig(rows=18, cols=8))

        self.assertEqual(target["acceptance_budget"]["allocated_cycles"], 6_999_197)
        self.assertEqual(target["acceptance_budget"]["slack_cycles"], 803)
        self.assertTrue(target["acceptance_budget"]["feasible"])
        self.assertLess(legacy["acceptance_budget"]["slack_cycles"], 0)
        self.assertFalse(legacy["acceptance_budget"]["feasible"])

    def test_rows_cols_and_cout_tile_are_independent_parameters(self):
        config = cycle_model.ArrayConfig(rows=9, cols=8, cout_tile=8)
        model = cycle_model.build_model(config)
        conv9 = model["layers"][-1]

        self.assertEqual(conv9["k_passes"], 57)
        self.assertEqual(conv9["cout_blocks"], 3)
        self.assertEqual(conv9["compute_fire_cycles"], 169 * 57 * 3)

    def test_invalid_array_config_is_rejected(self):
        with self.assertRaises(ValueError):
            cycle_model.ArrayConfig(rows=0, cols=16)
        with self.assertRaises(ValueError):
            cycle_model.ArrayConfig(rows=18, cols=8, cout_tile=17)


class AcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.model = cycle_model.build_model()

    def test_all_hard_gates_pass_at_the_locked_limits(self):
        result = cycle_model.evaluate_acceptance(passing_metrics(self.model), self.model)

        self.assertTrue(result["passed"])
        self.assertEqual(result["failed_checks"], [])

    def test_alias_layer_names_are_accepted(self):
        metrics = passing_metrics(self.model)
        metrics["layers"] = {
            f"conv{layer['index']}": layer["pl_busy_budget_cycles"]
            for layer in self.model["layers"]
        }

        result = cycle_model.evaluate_acceptance(metrics, self.model)

        self.assertTrue(result["passed"])

    def test_missing_counters_fail_closed(self):
        result = cycle_model.evaluate_acceptance({}, self.model)

        self.assertFalse(result["passed"])
        failed_names = {check["name"] for check in result["failed_checks"]}
        self.assertIn("compute_fire_cycles", failed_names)
        self.assertIn("conv0_pool.busy_cycles", failed_names)
        self.assertIn("ofm_beats", failed_names)

    def test_regressions_report_each_failed_gate(self):
        metrics = passing_metrics(self.model)
        metrics["compute_fire_cycles"] += 1
        metrics["fifo_drop_count"] = 1
        metrics["ifm_bytes"] = 2_500_001
        metrics["layers"]["conv6"]["busy_cycles"] += 1
        metrics["pl_busy_cycles"] += 1

        result = cycle_model.evaluate_acceptance(metrics, self.model)
        failed_names = {check["name"] for check in result["failed_checks"]}

        self.assertFalse(result["passed"])
        self.assertIn("compute_fire_cycles", failed_names)
        self.assertIn("fifo_drop_count", failed_names)
        self.assertIn("ifm_bytes_limit", failed_names)
        self.assertIn("conv6.busy_cycles", failed_names)
        self.assertIn("pl_busy_cycles", failed_names)


class CommandLineTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, str(DEMO_DIR / "single_scale_cycle_model.py"), *args],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_json_model_command(self):
        completed = self.run_cli("--json")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["model"]["totals"]["compute_fire_cycles"], 3_889_197)
        self.assertEqual(payload["model"]["totals"]["ofm_beats"], 216_827)

    def test_metrics_command_exit_status(self):
        good = passing_metrics(cycle_model.build_model())
        with tempfile.TemporaryDirectory() as temp_dir:
            metrics_path = Path(temp_dir) / "metrics.json"
            metrics_path.write_text(json.dumps(good), encoding="utf-8")
            passed = self.run_cli("--metrics-json", str(metrics_path))

            good["epoch_mismatch_count"] = 1
            metrics_path.write_text(json.dumps(good), encoding="utf-8")
            failed = self.run_cli("--metrics-json", str(metrics_path))

        self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
        self.assertIn("ACCEPTANCE PASS", passed.stdout)
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        self.assertIn("epoch_mismatch_count", failed.stdout)


if __name__ == "__main__":
    unittest.main()

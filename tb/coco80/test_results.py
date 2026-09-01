from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from tools.coco80.results import (
    ACCURACY_LEVELS,
    REQUIRED_BINDINGS,
    AccuracyGate,
    ResultArchiveError,
    compare_accuracy_levels,
    create_run_directory,
    seal_run,
    verify_run_archive,
)


def _levels(values):
    return {
        name: {"metrics": {"AP50_95": ap, "AP50": ap50}}
        for name, (ap, ap50) in zip(ACCURACY_LEVELS, values)
    }


def _gates(drop=1.0):
    return {
        name: AccuracyGate(
            min_map50_95=0.1,
            min_map50=0.2,
            max_drop_map50_95_points=None if index == 0 else drop,
            max_drop_map50_points=None if index == 0 else drop,
        )
        for index, name in enumerate(ACCURACY_LEVELS)
    }


class ResultsTests(unittest.TestCase):
    def test_five_level_map_and_delta_gate(self):
        passing = _levels(
            [(0.176, 0.348), (0.175, 0.347), (0.170, 0.342), (0.169, 0.341), (0.168, 0.340)]
        )
        report = compare_accuracy_levels(passing, _gates(drop=0.6))
        self.assertTrue(report["passed"])
        self.assertAlmostEqual(
            report["levels"][2]["delta_from_previous"]["map50_95_points"], -0.5
        )

        failing = dict(passing)
        failing["board_416"] = {"metrics": {"mAP50_95": 0.150, "mAP50": 0.320}}
        report = compare_accuracy_levels(failing, _gates(drop=0.6))
        self.assertFalse(report["passed"])
        self.assertTrue(any("board_416" in failure for failure in report["failures"]))

    def test_archive_requires_release_identity_and_closes_hash_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sources = root / "sources"
            sources.mkdir()
            bindings = {}
            for role in REQUIRED_BINDINGS:
                path = sources / f"{role}.bin"
                path.write_bytes((role + "\n").encode())
                bindings[role] = path
            extra = sources / "board-result.bin"
            extra.write_bytes(b"result payload")
            run = create_run_directory(root / "runs", 0x1234)
            sealed = seal_run(
                run,
                bindings=bindings,
                artifacts={"board_result": extra},
                accuracy_levels=_levels(
                    [(0.176, 0.348), (0.175, 0.347), (0.170, 0.342), (0.169, 0.341), (0.168, 0.340)]
                ),
                accuracy_gates=_gates(drop=1.0),
                metadata={"image_count": 5000},
            )
            self.assertEqual(sealed["status"], "sealed")
            verified = verify_run_archive(run)
            self.assertTrue(verified["accuracy_validated"])
            manifest = json.loads((run / "manifest" / "run.json").read_text())
            self.assertEqual(set(manifest["bindings"]), set(REQUIRED_BINDINGS))

            undeclared = run / "logs" / "late.log"
            undeclared.write_text("not sealed", encoding="utf-8")
            with self.assertRaisesRegex(ResultArchiveError, "hash closure"):
                verify_run_archive(run)

    def test_archive_tamper_and_missing_binding_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bindings = {}
            for role in REQUIRED_BINDINGS:
                path = root / f"{role}.dat"
                path.write_bytes(role.encode())
                bindings[role] = path
            run = create_run_directory(root / "runs", "run-A")
            missing = dict(bindings)
            missing.pop("xsa")
            with self.assertRaisesRegex(ResultArchiveError, "bindings must be exactly"):
                seal_run(run, bindings=missing)
            seal_run(run, bindings=bindings)
            archived_bit = next((run / "bindings" / "bit").iterdir())
            archived_bit.write_bytes(b"tampered")
            with self.assertRaisesRegex(ResultArchiveError, "(size|CRC32|SHA256) mismatch"):
                verify_run_archive(run)


if __name__ == "__main__":
    unittest.main()

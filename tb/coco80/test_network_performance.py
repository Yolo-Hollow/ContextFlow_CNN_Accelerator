from __future__ import annotations

import argparse
from pathlib import Path
import tempfile
import unittest

from tools.coco80.assets import write_json_atomic
from tools.coco80.net_protocol import (
    DECODE_DEMO, EXTENDED_TIMING, EXTENDED_TIMING_BYTES,
    EXTENDED_TIMING_MAGIC, EXTENDED_TIMING_VERSION, OUTPUT_TIMING,
)
from tools.coco80.network_performance import PerformanceError, run_performance


def _record(image: int, sequence: int, output_crc: int) -> bytes:
    return EXTENDED_TIMING.pack(
        EXTENDED_TIMING_MAGIC, EXTENDED_TIMING_VERSION, EXTENDED_TIMING_BYTES,
        image, sequence, 200_000_000, OUTPUT_TIMING, DECODE_DEMO,
        1000, 700, 250, 100, 30, 20, 50,
        *([10] * 13), *([5] * 10), 2, 13, 0, output_crc,
    )


class NetworkPerformanceTests(unittest.TestCase):
    def test_three_runs_are_aggregated_and_crc_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runs = []
            for run in range(3):
                directory = root / f"run{run}"; directory.mkdir(); runs.append(directory)
                (directory / "extended_timing.bin").write_bytes(
                    b"".join(_record(index + 1, index + 1, 100 + index) for index in range(3))
                )
                write_json_atomic(directory / "summary.json", {
                    "format": "kv260-coco80-ethernet-validation", "version": 1,
                    "status": "PASS", "mode": "timing-demo", "binding_sha256": "11" * 32,
                    "first_record": 0, "record_count": 3, "warmup_records": 1,
                    "chunks": [
                        {"first_record": 0, "record_count": 1, "host_wall_seconds": 0.1},
                        {"first_record": 1, "record_count": 2, "host_wall_seconds": 0.2},
                    ],
                })
            args = argparse.Namespace(
                run_dir=runs, output_dir=root / "summary", expected_runs=3,
                warmup=1, expected_timed=2,
            )
            summary = run_performance(args)
            self.assertEqual(summary["timed_total"], 6)
            self.assertAlmostEqual(summary["pipeline"]["combined_fps"], 10.0)
            self.assertEqual(summary["determinism"]["output_crc_mismatches"], 0)

            damaged = bytearray((runs[2] / "extended_timing.bin").read_bytes())
            last_record = 2 * EXTENDED_TIMING_BYTES
            damaged[last_record + 284:last_record + 288] = (999).to_bytes(4, "little")
            (runs[2] / "extended_timing.bin").write_bytes(damaged)
            args.output_dir = root / "must-not-exist"
            with self.assertRaisesRegex(PerformanceError, "nondeterministic"):
                run_performance(args)


if __name__ == "__main__":
    unittest.main()

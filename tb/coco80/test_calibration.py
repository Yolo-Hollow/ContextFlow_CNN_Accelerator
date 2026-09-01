import json
import tempfile
import unittest
from pathlib import Path

from tools.coco80.calibration import area_bucket, stratified_select


class CalibrationTest(unittest.TestCase):
    def test_area_buckets(self):
        self.assertEqual(area_bucket(0), "small")
        self.assertEqual(area_bucket(32 * 32), "medium")
        self.assertEqual(area_bucket(96 * 96), "large")

    def test_selection_is_deterministic_disjoint_and_covers(self):
        coverage = {}
        image_ids = []
        image_id = 1
        for class_index in range(80):
            for size in ("small", "medium", "large"):
                for _copy in range(3):
                    coverage[image_id] = {(class_index, size)}
                    image_ids.append(image_id)
                    image_id += 1
        for _ in range(80):
            coverage[image_id] = {(0, "small"), (79, "large")}
            image_ids.append(image_id)
            image_id += 1
        first = stratified_select(image_ids, coverage, 240, 20260814)
        second = stratified_select(image_ids, coverage, 240, 20260814)
        self.assertEqual(first, second)
        represented = set().union(*(coverage[x] for x in first))
        self.assertEqual(len(represented), 240)
        holdout = stratified_select(image_ids, coverage, 240, 7, excluded=set(first))
        self.assertFalse(set(first) & set(holdout))


if __name__ == "__main__":
    unittest.main()

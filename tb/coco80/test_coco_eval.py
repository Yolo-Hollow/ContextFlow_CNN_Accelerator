import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

import numpy as np

from tools.coco80.coco_eval import (
    CocoEvalDependencyError,
    CocoEvaluationError,
    coco_result_from_xyxy,
    evaluate_coco,
    validate_coco_results,
)
from tools.coco80.common import (
    COCO80_TO_COCO91,
    coco80_to_coco91,
    coco80_to_coco91_class,
    coco91_to_coco80,
)
from tools.coco80.schemas import (
    ACCURACY_DECODE_CONFIG,
    DEMO_DECODE_CONFIG,
    DecodeConfig,
    SchemaError,
    decode_config_for_profile,
)


class FakeCOCO:
    last_results = None

    def __init__(self, annotation_file=None):
        self.annotation_file = annotation_file
        self.dataset = {
            "images": [{"id": 7}, {"id": 3}],
            "categories": [{"id": 1}],
            "annotations": [],
        }
        self.index_created = False

    def loadRes(self, results):
        FakeCOCO.last_results = results
        return {"results": results}

    def createIndex(self):
        self.index_created = True


class FakeCOCOeval:
    last = None

    def __init__(self, ground_truth, detections, kind):
        self.ground_truth = ground_truth
        self.detections = detections
        self.kind = kind
        self.params = SimpleNamespace(
            maxDets=[1, 10, 100],
            imgIds=[7, 3],
            areaRngLbl=["all", "small", "medium", "large"],
            iouThrs=np.arange(0.50, 0.96, 0.05),
        )
        self.stats = [index / 10.0 for index in range(12)]
        self.eval = {}
        self.calls = []
        FakeCOCOeval.last = self

    def evaluate(self):
        self.calls.append("evaluate")

    def accumulate(self):
        self.calls.append("accumulate")
        precision = np.full((10, 2, 1, 4, 3), -1.0, dtype=np.float64)
        recall = np.full((10, 1, 4, 3), -1.0, dtype=np.float64)
        # The requested high-maxDet axis is deliberately distinct from the
        # fake summarize() stats to prove the wrapper reads accumulated data.
        precision[:, :, :, 0, 2] = 0.42
        precision[0, :, :, 0, 2] = 0.51
        precision[5, :, :, 0, 2] = 0.76
        precision[:, :, :, 1, 2] = 0.11
        precision[:, :, :, 2, 2] = 0.22
        precision[:, :, :, 3, 2] = 0.33
        recall[:, :, 0, 0] = 0.61
        recall[:, :, 0, 1] = 0.71
        recall[:, :, 0, 2] = 0.81
        recall[:, :, 1, 2] = 0.62
        recall[:, :, 2, 2] = 0.72
        recall[:, :, 3, 2] = 0.82
        self.eval = {"precision": precision, "recall": recall}

    def summarize(self):
        self.calls.append("summarize")


class CocoMappingAndSchemaTest(unittest.TestCase):
    def test_dense_to_sparse_mapping_is_the_official_80_entry_table(self):
        self.assertEqual(len(COCO80_TO_COCO91), 80)
        self.assertEqual(coco80_to_coco91(0), 1)
        self.assertEqual(coco80_to_coco91(11), 13)
        self.assertEqual(coco80_to_coco91(79), 90)
        self.assertEqual(coco91_to_coco80(90), 79)
        mutable_copy = coco80_to_coco91_class()
        self.assertEqual(tuple(mutable_copy), COCO80_TO_COCO91)
        mutable_copy[0] = 999
        self.assertEqual(COCO80_TO_COCO91[0], 1)
        with self.assertRaises(ValueError):
            coco80_to_coco91(80)
        with self.assertRaises(ValueError):
            coco91_to_coco80(12)

    def test_accuracy_and_demo_configs_are_distinct_strict_schemas(self):
        accuracy = decode_config_for_profile("accuracy")
        demo = decode_config_for_profile("demo")
        self.assertIs(accuracy, ACCURACY_DECODE_CONFIG)
        self.assertIs(demo, DEMO_DECODE_CONFIG)
        self.assertEqual((accuracy.confidence_threshold, accuracy.iou_threshold), (0.001, 0.65))
        self.assertEqual((demo.confidence_threshold, demo.iou_threshold), (0.25, 0.45))
        self.assertTrue(accuracy.multi_label)
        self.assertFalse(demo.multi_label)
        self.assertEqual(DecodeConfig.from_dict(accuracy.to_dict()), accuracy)

        malformed = accuracy.to_dict()
        malformed["unexpected"] = True
        with self.assertRaises(SchemaError):
            DecodeConfig.from_dict(malformed)
        with self.assertRaises(SchemaError):
            decode_config_for_profile("benchmark-ish")

    def test_xyxy_conversion_maps_class_and_preserves_float_precision(self):
        result = coco_result_from_xyxy(42, 11, (10.5, 20.0, 30.75, 50.5), 0.75)
        self.assertEqual(result["image_id"], 42)
        self.assertEqual(result["category_id"], 13)
        self.assertEqual(result["bbox"], [10.5, 20.0, 20.25, 30.5])
        self.assertEqual(result["score"], 0.75)


class CocoEvaluationWrapperTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="coco80_eval_")
        self.root = Path(self.temp.name)
        self.annotations = self.root / "instances_val2017.json"
        self.annotations.write_text(
            json.dumps({"images": [], "categories": [], "annotations": []}),
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_wrapper_passes_image_ids_limits_and_returns_named_metrics(self):
        prediction = coco_result_from_xyxy(7, 0, (1, 2, 11, 22), 0.9)
        with mock.patch(
            "tools.coco80.coco_eval._load_pycocotools",
            return_value=(FakeCOCO, FakeCOCOeval),
        ):
            summary = evaluate_coco(
                self.annotations,
                [prediction],
                image_ids=[5, 2, 5],
                max_detections=(1, 10, 300),
                quiet=True,
            )

        self.assertEqual(FakeCOCO.last_results, [prediction])
        self.assertEqual(FakeCOCOeval.last.kind, "bbox")
        self.assertEqual(FakeCOCOeval.last.params.imgIds, [2, 5])
        self.assertEqual(FakeCOCOeval.last.params.maxDets, [1, 10, 300])
        self.assertEqual(FakeCOCOeval.last.calls, ["evaluate", "accumulate", "summarize"])
        self.assertAlmostEqual(summary.metrics["AP"], 0.463)
        self.assertAlmostEqual(summary.metrics["AP50"], 0.51)
        self.assertAlmostEqual(summary.metrics["AP75"], 0.76)
        self.assertAlmostEqual(summary.metrics["AR_max_det_limit"], 0.81)
        self.assertEqual(summary.image_ids, (2, 5))

    def test_invalid_results_are_rejected_before_backend_import(self):
        with self.assertRaisesRegex(CocoEvaluationError, "official COCO80"):
            validate_coco_results(
                [{"image_id": 1, "category_id": 12, "bbox": [0, 0, 1, 1], "score": 0.5}]
            )
        with self.assertRaisesRegex(CocoEvaluationError, "positive area"):
            validate_coco_results(
                [{"image_id": 1, "category_id": 1, "bbox": [0, 0, 0, 1], "score": 0.5}]
            )

    def test_missing_pycocotools_has_an_actionable_error(self):
        with mock.patch(
            "tools.coco80.coco_eval._load_pycocotools",
            side_effect=CocoEvalDependencyError("install pycocotools"),
        ):
            with self.assertRaisesRegex(CocoEvalDependencyError, "install pycocotools"):
                evaluate_coco(self.annotations, [], quiet=True)


if __name__ == "__main__":
    unittest.main()

from types import SimpleNamespace
import unittest

import numpy as np

from tools.coco80.evaluate import metrics_from_coco_evaluator


class CocoMetricTensorTest(unittest.TestCase):
    def test_metrics_select_explicit_maxdet_300_axes(self):
        precision = np.full((2, 3, 1, 4, 3), -1.0, dtype=np.float64)
        recall = np.full((2, 1, 4, 3), -1.0, dtype=np.float64)
        precision[:, :, :, 0, 2] = np.array([0.2, 0.4])[:, None, None]
        precision[0, :, :, 1, 2] = 0.1
        precision[1, :, :, 1, 2] = 0.3
        precision[:, :, :, 2, 2] = 0.5
        precision[:, :, :, 3, 2] = 0.7
        recall[:, :, 0, 0] = 0.11
        recall[:, :, 0, 1] = 0.22
        recall[:, :, 0, 2] = 0.33
        recall[:, :, 1, 2] = 0.44
        recall[:, :, 2, 2] = 0.55
        recall[:, :, 3, 2] = 0.66
        evaluator = SimpleNamespace(
            eval={"precision": precision, "recall": recall},
            params=SimpleNamespace(
                areaRngLbl=["all", "small", "medium", "large"],
                maxDets=[1, 10, 300],
                iouThrs=np.array([0.50, 0.75]),
            ),
        )
        metrics = metrics_from_coco_evaluator(evaluator)
        self.assertAlmostEqual(metrics["AP50_95"], 0.3)
        self.assertAlmostEqual(metrics["AP50"], 0.2)
        self.assertAlmostEqual(metrics["AP75"], 0.4)
        self.assertAlmostEqual(metrics["AP_small"], 0.2)
        self.assertAlmostEqual(metrics["AP_medium"], 0.5)
        self.assertAlmostEqual(metrics["AP_large"], 0.7)
        self.assertAlmostEqual(metrics["AR_1"], 0.11)
        self.assertAlmostEqual(metrics["AR_10"], 0.22)
        self.assertAlmostEqual(metrics["AR_300"], 0.33)
        self.assertAlmostEqual(metrics["AR_small"], 0.44)
        self.assertAlmostEqual(metrics["AR_medium"], 0.55)
        self.assertAlmostEqual(metrics["AR_large"], 0.66)


if __name__ == "__main__":
    unittest.main()

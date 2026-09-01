import unittest
from unittest import mock
from pathlib import Path
import tempfile

import torch

from tools.coco80.qat import (
    GRADIENT_ACCUMULATION,
    _build_targets_v95_torch24,
    _save_conv_checkpoint_atomic,
    accuracy_budget_met,
    cosine_lr,
    enable_fused_conv_gradients,
)


class QatGateTest(unittest.TestCase):
    def test_budget_and_schedule(self):
        fp = {"coco":{"metrics":{"AP50_95":0.20,"AP50":0.40}}}
        good = {"coco":{"metrics":{"AP50_95":0.1901,"AP50":0.3801}}}
        bad = {"coco":{"metrics":{"AP50_95":0.189,"AP50":0.38}}}
        self.assertTrue(accuracy_budget_met(fp, good))
        self.assertFalse(accuracy_budget_met(fp, bad))
        self.assertEqual(GRADIENT_ACCUMULATION, 8)
        self.assertGreater(cosine_lr(0), cosine_lr(19))

    def test_v95_target_builder_uses_integer_grid_clamp_bounds(self):
        class LossContract:
            na = 3
            nl = 2
            hyp = {"anchor_t": 4.0}
            anchors = (
                torch.tensor([[0.625, 0.875], [1.4375, 1.6875], [2.3125, 3.625]]),
                torch.tensor([[2.53125, 2.5625], [4.21875, 5.28125], [10.75, 9.96875]]),
            )

        predictions = [
            torch.zeros((1, 3, 26, 26, 85)),
            torch.zeros((1, 3, 13, 13, 85)),
        ]
        targets = torch.tensor([[0.0, 7.0, 1.0, 1.0, 0.1, 0.1]])
        tcls, _tbox, indices, _anchors = _build_targets_v95_torch24(
            LossContract(), predictions, targets
        )
        self.assertEqual(len(tcls), 2)
        self.assertEqual(len(indices), 2)
        for layer, (_batch, _anchor, grid_y, grid_x) in enumerate(indices):
            self.assertEqual(grid_y.dtype, torch.int64)
            self.assertEqual(grid_x.dtype, torch.int64)
            self.assertLessEqual(int(grid_y.max()), predictions[layer].shape[2] - 1)
            self.assertLessEqual(int(grid_x.max()), predictions[layer].shape[3] - 1)

    def test_frozen_checkpoint_conv_tensors_are_explicitly_trainable(self):
        convolutions = {
            f"layer_{index}": torch.nn.Conv2d(1, 1, 1, bias=True)
            for index in range(13)
        }
        for convolution in convolutions.values():
            convolution.requires_grad_(False)
        with mock.patch("tools.coco80.qat.conv_modules", return_value=convolutions):
            self.assertEqual(enable_fused_conv_gradients(torch.nn.Module()), 26)
        self.assertTrue(
            all(
                parameter.requires_grad
                for convolution in convolutions.values()
                for parameter in convolution.parameters()
            )
        )

    def test_best_epoch_checkpoint_is_atomically_persisted(self):
        with tempfile.TemporaryDirectory(prefix="coco80_qat_checkpoint_") as directory:
            path = Path(directory) / "best.pt"
            state = {"m0": {"weight": torch.tensor([1.0]), "bias": None}}
            _save_conv_checkpoint_atomic(path, 3, state)
            payload = torch.load(path, map_location="cpu", weights_only=False)
            self.assertEqual(payload["epoch"], 3)
            self.assertEqual(payload["format"], "kv260-coco80-qat-conv-state")
            self.assertEqual(payload["state"]["m0"]["weight"].item(), 1.0)
            self.assertFalse(path.with_suffix(".pt.tmp").exists())


if __name__ == "__main__":
    unittest.main()

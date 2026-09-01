import unittest

import torch

from tools.coco80.ptq_runner import requant_affine_u8, signed_round_shift, solve_affine_multiplier
from tools.coco80.quantization import TensorQParams


class PtqRunnerTest(unittest.TestCase):
    def test_rtl_positive_half_rounding(self):
        values = torch.tensor([-9, -8, -7, -1, 0, 1, 7, 8, 9], dtype=torch.int64)
        self.assertEqual(signed_round_shift(values, 3).tolist(), [-1,-1,-1,0,0,0,1,1,1])

    def test_affine_requant_is_fixed_point_and_saturating(self):
        source_q = TensorQParams(0.125, 15, 0, 127)
        target_q = TensorQParams(0.0625, 7, 0, 127)
        multiplier, shift = solve_affine_multiplier(2.0)
        source = torch.tensor([0, 14, 15, 16, 127], dtype=torch.uint8)
        result = requant_affine_u8(source, source_q, target_q, multiplier, shift)
        self.assertEqual(result.tolist(), [0, 5, 7, 9, 127])


if __name__ == "__main__":
    unittest.main()

import unittest

import torch

from tools.coco80.postprocess import (
    COCO80_TO_91, NmsConfig, decode_heads, decode_quantized_heads_u8,
    detections_to_coco, non_max_suppression,
)


class PostprocessTest(unittest.TestCase):
    def test_decode_shape_and_zero_logits(self):
        p4 = torch.zeros((1,255,26,26))
        p5 = torch.zeros((1,255,13,13))
        decoded = decode_heads(p4,p5)
        self.assertEqual(tuple(decoded.shape), (1,2535,85))
        self.assertTrue(torch.all(decoded[...,4:] == 0.5))
        self.assertEqual(decoded[0,0,:4].tolist(), [8.0,8.0,10.0,14.0])

    def test_multilabel_and_class_aware_nms(self):
        prediction = torch.zeros((1,2,85))
        prediction[0,:,0:4] = torch.tensor([[100,100,50,50],[100,100,50,50]])
        prediction[0,:,4] = 1.0
        prediction[0,0,5] = 0.9
        prediction[0,0,6] = 0.8
        prediction[0,1,5] = 0.7
        output = non_max_suppression(prediction, NmsConfig(0.1,0.5,True,100,100))[0]
        self.assertEqual(output.shape[0], 2)  # class0 duplicate suppressed; class1 retained
        self.assertEqual(output[:,5].to(torch.int64).tolist(), [0,1])

    def test_equal_scores_use_source_index_as_stable_tie_break(self):
        prediction = torch.zeros((1,2535,85), dtype=torch.float32)
        for source, center_x in ((1192,100.0),(337,300.0)):
            prediction[0,source,:4] = torch.tensor([center_x,100.0,20.0,20.0])
            prediction[0,source,4] = 0.5
            prediction[0,source,5 + 73] = 0.5
        output = non_max_suppression(
            prediction, NmsConfig(0.1,0.5,True,30000,300)
        )[0]
        self.assertEqual(output[:,6].tolist(), [337.0,1192.0])

    def test_quantized_decode_reuses_one_lut_value_for_equal_codes(self):
        p4 = torch.zeros((1,255,26,26), dtype=torch.uint8)
        p5 = torch.zeros((1,255,13,13), dtype=torch.uint8)
        for source in (337,1192):
            anchor, remainder = divmod(source, 26 * 26)
            y, x = divmod(remainder, 26)
            p4[0,anchor * 85 + 4,y,x] = 67
            p4[0,anchor * 85 + 5 + 73,y,x] = 98
        decoded = decode_quantized_heads_u8(
            p4,p5,p4_scale=0.0313485,p4_zero_point=66,
            p5_scale=0.1,p5_zero_point=128,
        )
        score337 = decoded[0,337,4] * decoded[0,337,5 + 73]
        score1192 = decoded[0,1192,4] * decoded[0,1192,5 + 73]
        self.assertEqual(score337.item(), score1192.item())

    def test_restore_and_category_mapping(self):
        det = torch.tensor([[58.0,48.0,258.0,148.0,0.75,0.0,2.0]])
        result = detections_to_coco(
            det,image_id=7,original_width=400,original_height=200,
            scale=0.5,pad_left=8,pad_top=48,
        )
        self.assertEqual(result[0]["category_id"], COCO80_TO_91[0])
        self.assertEqual(result[0]["bbox"], [100.0,0.0,300.0,200.0])

    def test_clipped_zero_area_boxes_are_not_emitted(self):
        det = torch.tensor([
            [-20.0, 10.0, -1.0, 30.0, 0.75, 0.0, 2.0],
            [10.0, 10.0, 20.0, 20.0, 0.80, 1.0, 3.0],
        ])
        result = detections_to_coco(
            det, image_id=7, original_width=100, original_height=100,
            scale=1.0, pad_left=0, pad_top=0,
        )
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["bbox"], [10.0, 10.0, 10.0, 10.0])


if __name__ == "__main__":
    unittest.main()

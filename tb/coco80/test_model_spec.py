import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ModelSpecTest(unittest.TestCase):
    def test_complete_safe_graph(self):
        spec = json.loads((ROOT / "tools/coco80/model_spec.json").read_text())
        layers = spec["conv_layers"]
        self.assertEqual(len(layers), 13)
        self.assertEqual([x["tile_h"] for x in layers], [2,4,8,8,13,13,8,13,13,13,6,13,13])
        self.assertEqual(layers[10]["name"], "m19")
        self.assertLessEqual(layers[10]["tile_h"], 6)
        self.assertEqual(layers[11]["ofm_hwc"], [26,26,255])
        self.assertEqual(layers[12]["ofm_hwc"], [13,13,255])
        self.assertEqual(sum(h[0] * h[1] * 3 for h in (x["shape_hwc"] for x in spec["heads"])), 2535)

    def test_special_pool_and_concat_contract(self):
        spec = json.loads((ROOT / "tools/coco80/model_spec.json").read_text())
        ops = {x["name"]: x for x in spec["tensor_ops"]}
        self.assertEqual(ops["pool12"]["pads"], [0,1,0,1])
        self.assertEqual(ops["pool12"]["pad_value"], "source_zero_point")
        self.assertEqual(ops["concat18"]["channel_order"], ["upsample17", "m8"])
        self.assertEqual(ops["concat18"]["shape_hwc"], [26,26,384])


if __name__ == "__main__":
    unittest.main()

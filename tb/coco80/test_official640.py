from pathlib import Path
import unittest

from tools.coco80.official640 import install_upstream_numpy_compat, upstream_options


class Official640AdapterTest(unittest.TestCase):
    def test_upstream_cli_surface_is_complete_and_accuracy_locked(self):
        options = upstream_options(Path("result"), device="0", batch_size=16)
        expected = {
            "weights", "data", "batch_size", "img_size", "conf_thres",
            "iou_thres", "task", "device", "single_cls", "augment",
            "verbose", "save_txt", "save_hybrid", "save_conf", "save_json",
            "project", "name", "exist_ok",
        }
        self.assertEqual(set(vars(options)), expected)
        self.assertEqual(options.img_size, 640)
        self.assertEqual(options.conf_thres, 0.001)
        self.assertEqual(options.iou_thres, 0.65)
        self.assertFalse(options.single_cls)
        self.assertTrue(options.save_json)

    def test_numpy2_compatibility_does_not_modify_upstream_source(self):
        import numpy as np

        result = install_upstream_numpy_compat()
        self.assertIs(np.int, int)
        self.assertEqual(result["semantic_target"], "builtin int")


if __name__ == "__main__":
    unittest.main()

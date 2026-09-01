import json
import tempfile
import unittest
from pathlib import Path

from PIL import Image

from tools.coco80.dataset import CocoFixed416Dataset, collate_fixed416


class DatasetTest(unittest.TestCase):
    def test_fixed_loader_uses_annotation_identity(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            Image.new("RGB", (100,50), (1,2,3)).save(root / "x.jpg")
            annotation = root / "instances.json"
            annotation.write_text(json.dumps({"images":[{"id":9,"file_name":"x.jpg","width":100,"height":50}]}))
            dataset = CocoFixed416Dataset(annotation, root)
            sample = dataset[0]
            self.assertEqual(sample["image_id"], 9)
            self.assertEqual(tuple(sample["image_u8"].shape), (3,416,416))
            batch = collate_fixed416([sample])
            self.assertEqual(tuple(batch["image_float"].shape), (1,3,416,416))


if __name__ == "__main__":
    unittest.main()

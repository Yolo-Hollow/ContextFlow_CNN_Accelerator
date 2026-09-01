from __future__ import annotations

import argparse
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image

from tools.coco80.visualize import VisualizationError, render


class VisualizeTests(unittest.TestCase):
    def test_renders_selected_image_and_seals_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.jpg"
            output = root / "rendered.jpg"
            predictions = root / "predictions.json"
            Image.new("RGB", (100, 80), (40, 50, 60)).save(source)
            predictions.write_text(json.dumps([
                {"image_id": 7, "category_id": 1, "bbox": [10, 12, 20, 30], "score": 0.9},
                {"image_id": 7, "category_id": 3, "bbox": [1, 2, 3, 4], "score": 0.1},
                {"image_id": 8, "category_id": 1, "bbox": [0, 0, 5, 5], "score": 0.99},
            ]), encoding="utf-8")
            result = render(argparse.Namespace(
                predictions=predictions, image_id=7, image=source,
                annotations=None, image_root=None, output=output,
                confidence=0.25, max_boxes=300, title="board", overwrite=False,
            ))
            self.assertEqual(result["detections_drawn"], 1)
            self.assertTrue(output.is_file())
            self.assertEqual(json.loads((root / "rendered.jpg.json").read_text())["image_id"], 7)

    def test_rejects_invalid_category_and_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.jpg"; Image.new("RGB", (8, 8)).save(source)
            predictions = root / "predictions.json"
            predictions.write_text(json.dumps([
                {"image_id": 7, "category_id": 12, "bbox": [0, 0, 1, 1], "score": 0.9}
            ]), encoding="utf-8")
            args = argparse.Namespace(
                predictions=predictions, image_id=7, image=source,
                annotations=None, image_root=None, output=root / "out.jpg",
                confidence=0.25, max_boxes=300, title="", overwrite=False,
            )
            with self.assertRaises(VisualizationError):
                render(args)


if __name__ == "__main__":
    unittest.main()

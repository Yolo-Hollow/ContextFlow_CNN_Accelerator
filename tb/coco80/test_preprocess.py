import unittest

try:
    from PIL import Image
except ImportError:  # pragma: no cover - lets dependency-free host suites skip cleanly
    Image = None

from tools.coco80.preprocess import (
    FILL_VALUE,
    MODEL_SIZE,
    inverse_letterbox_xyxy,
    letterbox_416,
)
from tools.coco80.schemas import LetterboxMetadata


@unittest.skipUnless(Image is not None, "Pillow is not installed")
class FixedLetterboxTest(unittest.TestCase):
    def test_wide_image_is_centered_with_fill_114(self):
        source = Image.new("RGB", (4, 2), (10, 20, 30))
        output, metadata = letterbox_416(source)

        self.assertEqual(output.mode, "RGB")
        self.assertEqual(output.size, (MODEL_SIZE, MODEL_SIZE))
        self.assertEqual((metadata.resized_width, metadata.resized_height), (416, 208))
        self.assertEqual(
            (metadata.pad_left, metadata.pad_top, metadata.pad_right, metadata.pad_bottom),
            (0, 104, 0, 104),
        )
        self.assertEqual(output.getpixel((0, 103)), (FILL_VALUE,) * 3)
        self.assertEqual(output.getpixel((0, 104)), (10, 20, 30))
        self.assertEqual(output.getpixel((415, 311)), (10, 20, 30))
        self.assertEqual(output.getpixel((0, 312)), (FILL_VALUE,) * 3)

    def test_odd_padding_remainder_goes_to_bottom(self):
        source = Image.new("RGB", (3, 2), (1, 2, 3))
        _, metadata = letterbox_416(source)
        self.assertEqual((metadata.resized_width, metadata.resized_height), (416, 277))
        self.assertEqual((metadata.pad_top, metadata.pad_bottom), (69, 70))

    def test_resize_is_pil_bilinear_and_input_is_converted_to_rgb(self):
        source = Image.new("L", (2, 1))
        source.putdata([0, 255])
        output, metadata = letterbox_416(source)

        bilinear = Image.Resampling.BILINEAR
        expected_resized = source.convert("RGB").resize((416, 208), bilinear)
        expected = Image.new("RGB", (416, 416), (114, 114, 114))
        expected.paste(expected_resized, (0, 104))
        self.assertEqual(output.tobytes(), expected.tobytes())
        self.assertGreater(output.getpixel((207, 200))[0], 0)
        self.assertLess(output.getpixel((207, 200))[0], 255)
        self.assertEqual(metadata.pixel_format, "RGB")
        self.assertEqual(metadata.resample, "PIL.BILINEAR")

    def test_metadata_round_trip_and_inverse_box(self):
        _, metadata = letterbox_416(Image.new("RGB", (832, 416), "white"))
        restored = LetterboxMetadata.from_dict(metadata.to_dict())
        self.assertEqual(restored, metadata)
        self.assertEqual(
            inverse_letterbox_xyxy((0, 104, 416, 312), metadata),
            (0.0, 0.0, 832.0, 416.0),
        )
        self.assertEqual(
            inverse_letterbox_xyxy((-20, -20, 500, 500), metadata),
            (0.0, 0.0, 832.0, 416.0),
        )

    def test_non_pil_input_is_rejected(self):
        with self.assertRaises(TypeError):
            letterbox_416(object())


if __name__ == "__main__":
    unittest.main()

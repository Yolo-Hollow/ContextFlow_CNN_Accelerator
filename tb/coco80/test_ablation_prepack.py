from __future__ import annotations

import unittest

from tools.coco80.ablation_prepack import pack_legacy_ifm


class AblationPrepackTests(unittest.TestCase):
    def test_3x3_line_stream_repeats_per_cout_block_and_keeps_halo(self) -> None:
        raw = bytes(range(3 * 2 * 4))
        packed, tiles = pack_legacy_ifm(
            raw, height=3, width=2, channels=4, output_channels=33,
            kernel=3, pad=1, tile_h=2, input_zero_point=0,
        )
        # Two K passes, two output blocks.  The first tile reads all three
        # physical rows; the tail tile reads rows one and two.
        self.assertEqual([item["bytes"] for item in tiles], [192, 128])
        self.assertEqual(len(packed), 320)
        first_block = packed[:96]
        self.assertEqual(packed[96:192], first_block)
        # K-pass zero selects channels 0/1 in the low bytes of each line word.
        self.assertEqual(first_block[:8], bytes((0, 1, 0, 0, 0, 0, 0, 0)))
        self.assertEqual(first_block[8:16], bytes((4, 5, 0, 0, 0, 0, 0, 0)))

    def test_native_1x1_emits_three_beats_and_zero_point_padding(self) -> None:
        raw = bytes((1, 2, 3, 4, 5))
        packed, tiles = pack_legacy_ifm(
            raw, height=1, width=1, channels=5, output_channels=33,
            kernel=1, pad=0, tile_h=1, input_zero_point=7,
        )
        self.assertEqual(len(packed), 48)
        self.assertEqual(tiles[0]["packets"], 2)
        self.assertEqual(packed[:24], bytes((1, 2, 3, 4, 5)) + bytes((7,)) * 19)
        self.assertEqual(packed[24:], packed[:24])


if __name__ == "__main__":
    unittest.main()

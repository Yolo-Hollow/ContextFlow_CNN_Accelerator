import unittest

from tools.coco80.rtl_semantics import (
    RequantParams,
    RtlSemanticError,
    U8RequantParams,
    apply_activation_lut,
    center_u8_to_s8,
    clamp_s8,
    maxpool2d_u8,
    maxpool2x2_stride1_pad_right_bottom_u8,
    maxpool2x2_stride2_u8,
    nearest_upsample_u8,
    requantize_and_lut,
    requantize_psum,
    requantize_u8_tensor,
    rtl_round_shift,
    s8_to_u8,
    symmetric_round_shift,
    u8_to_s8,
    upsample_requant_concat_u8,
)


class RtlSemanticsTest(unittest.TestCase):
    def test_rtl_positive_half_rounding_including_negative_ties(self):
        self.assertEqual(
            [rtl_round_shift(value, 1) for value in (-5, -4, -3, -2, -1, 0, 1, 2, 3)],
            [-2, -2, -1, -1, 0, 0, 1, 1, 2],
        )
        self.assertEqual(rtl_round_shift(-17, 4), -1)
        self.assertEqual(rtl_round_shift(-8, 4), 0)
        with self.assertRaises(RtlSemanticError):
            rtl_round_shift(1, 0)

    def test_ps_symmetric_rounding_is_distinct_for_negative_ties(self):
        self.assertEqual(
            [
                symmetric_round_shift(value, 1)
                for value in (-5, -4, -3, -2, -1, 0, 1, 2, 3)
            ],
            [-3, -2, -2, -1, -1, 0, 1, 1, 2],
        )
        self.assertNotEqual(rtl_round_shift(-1, 1), symmetric_round_shift(-1, 1))

    def test_s8_twos_complement_and_ifm_center_saturation(self):
        self.assertEqual(clamp_s8(-999), -128)
        self.assertEqual(clamp_s8(999), 127)
        self.assertEqual(s8_to_u8(-128), 128)
        self.assertEqual(s8_to_u8(-1), 255)
        self.assertEqual(u8_to_s8(128), -128)
        self.assertEqual(u8_to_s8(255), -1)
        self.assertEqual(
            center_u8_to_s8([0, 1, 127, 128, 255], 128),
            (-128, -127, -1, 0, 127),
        )
        self.assertEqual(center_u8_to_s8([0, 127, 255], 255), (-128, -128, 0))

    def test_requant_q15_shift_zero_clamp_and_negative_rounding(self):
        half = RequantParams(mult=16_384, shift=0, output_zero_point=0)
        self.assertEqual(
            [requantize_psum(value, half.mult, half.shift, 0) for value in (-3, -1, 0, 1, 3)],
            [-1, 0, 0, 1, 2],
        )
        identity = RequantParams(mult=32_768, shift=0, output_zero_point=0)
        self.assertEqual(requantize_psum(200, 32_768, 0, 0), 127)
        self.assertEqual(requantize_psum(-200, 32_768, 0, 0), -128)
        self.assertEqual(requantize_psum(17, identity.mult, identity.shift, 3), 20)
        # RTL treats the 8-bit zero point as positive, then clamps signed s8.
        self.assertEqual(requantize_psum(0, 32_768, 0, 128), 127)
        with self.assertRaises(RtlSemanticError):
            RequantParams(mult=0, shift=0, output_zero_point=0)
        with self.assertRaises(RtlSemanticError):
            RequantParams(mult=1, shift=16, output_zero_point=0)

    def test_signed_requant_byte_is_reinterpreted_as_lut_address(self):
        identity_lut = bytes(range(256))
        self.assertEqual(
            apply_activation_lut([-128, -1, 0, 127], identity_lut),
            bytes([128, 255, 0, 127]),
        )
        reversed_lut = bytes(reversed(range(256)))
        params = RequantParams(mult=32_768, shift=0, output_zero_point=0)
        self.assertEqual(
            requantize_and_lut([-128, -1, 0, 127], params, reversed_lut),
            bytes([127, 0, 255, 128]),
        )
        with self.assertRaisesRegex(RtlSemanticError, "256"):
            apply_activation_lut([0], bytes(255))

    def test_ps_pool_hwc_channel_order(self):
        tensor = bytes(
            [
                1, 10,
                4, 5,
                3, 12,
                2, 7,
            ]
        )
        self.assertEqual(maxpool2x2_stride2_u8(tensor, 2, 2, 2), bytes([4, 12]))
        pooled, out_h, out_w = maxpool2d_u8(tensor, 2, 2, 2)
        self.assertEqual((pooled, out_h, out_w), (bytes([4, 12]), 1, 1))

    def test_special_stride_one_pool_uses_source_zero_point_padding(self):
        tensor = bytes([1, 2, 3, 4])
        self.assertEqual(
            maxpool2x2_stride1_pad_right_bottom_u8(
                tensor, 2, 2, 1, pad_value=0
            ),
            bytes([4, 4, 4, 4]),
        )
        self.assertEqual(
            maxpool2x2_stride1_pad_right_bottom_u8(
                tensor, 2, 2, 1, pad_value=9
            ),
            bytes([4, 9, 9, 9]),
        )

    def test_nearest_upsample_repeats_complete_hwc_pixels(self):
        source = bytes([1, 10, 2, 20])  # 1x2x2 HWC
        result, height, width = nearest_upsample_u8(source, 1, 2, 2, factor=2)
        self.assertEqual((height, width), (2, 4))
        self.assertEqual(
            result,
            bytes(
                [
                    1, 10, 1, 10, 2, 20, 2, 20,
                    1, 10, 1, 10, 2, 20, 2, 20,
                ]
            ),
        )

    def test_ps_route_requant_is_uint8_and_concat_order_is_upsample_then_skip(self):
        identity = U8RequantParams(
            input_zero_point=128,
            mult=256,
            shift=8,
            output_zero_point=128,
        )
        self.assertEqual(
            requantize_u8_tensor([0, 128, 255], identity), bytes([0, 128, 255])
        )
        half = U8RequantParams(128, 128, 8, 128)
        self.assertEqual(
            requantize_u8_tensor([126, 127, 128, 129, 130], half),
            bytes([127, 127, 128, 129, 129]),
        )
        skip = bytes([1, 2, 3, 4, 5, 6, 7, 8])  # 2x2x2
        raw_identity = U8RequantParams(0, 256, 8, 0)
        result, h, w, c = upsample_requant_concat_u8(
            bytes([11]),
            1,
            1,
            1,
            skip,
            2,
            2,
            2,
            raw_identity,
        )
        self.assertEqual((h, w, c), (2, 2, 3))
        self.assertEqual(
            result,
            bytes([11, 1, 2, 11, 3, 4, 11, 5, 6, 11, 7, 8]),
        )

    def test_shape_and_byte_errors_fail_closed(self):
        with self.assertRaises(RtlSemanticError):
            maxpool2x2_stride2_u8(bytes(3), 2, 2, 1)
        with self.assertRaises(RtlSemanticError):
            nearest_upsample_u8([256], 1, 1, 1)
        with self.assertRaisesRegex(RtlSemanticError, "skip H/W"):
            upsample_requant_concat_u8(
                [1], 1, 1, 1, [2], 1, 1, 1, U8RequantParams(0, 256, 8, 0)
            )


if __name__ == "__main__":
    unittest.main()

import unittest
from dataclasses import replace

from tools.coco80.hardware_plan import (
    COCO80_CONV_LAYERS,
    COCO80_HARDWARE_PLAN,
    DMA_SIMPLE_MAX_LENGTH,
    EXPECTED_BIAS_PACKAGE_BYTES,
    EXPECTED_WEIGHT_PACKAGE_BYTES,
    HARDWARE_PLAN_MAGIC,
    HARDWARE_PLAN_VERSION,
    PARAMETER_ALIGNMENT,
    PlanValidationError,
    SAFE_TILE_HEIGHTS,
    build_hardware_plan,
    get_schedule,
    schedule_layer,
)


class HardwarePlanTest(unittest.TestCase):
    def test_release_identity_order_and_fixed_safe_tiles(self):
        plan = COCO80_HARDWARE_PLAN
        self.assertEqual(plan.magic, HARDWARE_PLAN_MAGIC)
        self.assertEqual(plan.version, HARDWARE_PLAN_VERSION)
        self.assertEqual(len(plan.layers), 13)
        self.assertEqual(
            [item.layer.tile_h for item in plan.layers],
            [2, 4, 8, 8, 13, 13, 8, 13, 13, 13, 6, 13, 13],
        )
        self.assertEqual(
            dict(SAFE_TILE_HEIGHTS),
            {item.layer.layer_id: item.layer.tile_h for item in plan.layers},
        )
        self.assertEqual(len(plan.sha256()), 64)
        self.assertEqual(plan.sha256(), COCO80_HARDWARE_PLAN.sha256())

    def test_exact_parameter_window_contract(self):
        summary = COCO80_HARDWARE_PLAN.summary
        self.assertEqual(summary.total_bias_bytes, EXPECTED_BIAS_PACKAGE_BYTES)
        self.assertEqual(summary.total_weight_bytes, EXPECTED_WEIGHT_PACKAGE_BYTES)
        self.assertEqual(summary.total_bias_bytes, 64_256)
        self.assertEqual(summary.total_weight_bytes, 18_614_016)
        self.assertLessEqual(
            summary.total_bias_bytes, COCO80_HARDWARE_PLAN.limits.bias_window_bytes
        )
        self.assertLessEqual(
            summary.total_weight_bytes,
            COCO80_HARDWARE_PLAN.limits.weight_window_bytes,
        )

    def test_every_layer_fits_all_r5_capacity_and_dma_limits(self):
        limits = COCO80_HARDWARE_PLAN.limits
        for item in COCO80_HARDWARE_PLAN.layers:
            with self.subTest(layer=item.layer.layer_id):
                self.assertLessEqual(item.max_tile_pixels, limits.psum_depth)
                self.assertLessEqual(
                    item.materialized_entries, limits.materialized_depth
                )
                self.assertLessEqual(
                    item.packed_reorder_entries, limits.packed_reorder_depth
                )
                self.assertLessEqual(item.line_words, limits.line_bank_depth)
                self.assertLessEqual(item.k_total, limits.max_k_total)
                self.assertLessEqual(item.k_passes, limits.max_passes)
                for transfer in (
                    item.ifm_bytes,
                    item.ofm_bytes,
                    item.bias_bytes,
                    item.weight_bytes,
                ):
                    self.assertGreater(transfer, 0)
                    self.assertLess(transfer, DMA_SIMPLE_MAX_LENGTH)
                self.assertEqual(item.bias_bytes % PARAMETER_ALIGNMENT, 0)
                self.assertEqual(item.weight_bytes % PARAMETER_ALIGNMENT, 0)

    def test_early_unbranched_pools_are_fused_and_route_pools_remain_on_a53(self):
        expected_outputs = [
            "pool1", "pool3", "pool5", "pool7", "m8", "m10", "m13",
            "m14", "m15", "m16", "m19", "p4_detect", "p5_detect",
        ]
        self.assertEqual(
            [item.layer.output_tensor for item in COCO80_HARDWARE_PLAN.layers],
            expected_outputs,
        )
        for index, item in enumerate(COCO80_HARDWARE_PLAN.layers):
            with self.subTest(layer=item.layer.layer_id):
                expected_stride = 2 if index < 4 else 0
                self.assertEqual(item.layer.pool_stride, expected_stride)
                expected_shape = (
                    (item.conv_h // 2, item.conv_w // 2)
                    if expected_stride
                    else (item.conv_h, item.conv_w)
                )
                self.assertEqual((item.output_h, item.output_w), expected_shape)

    def test_model19_six_rows_is_last_safe_fixed_choice(self):
        item = get_schedule("m19")
        self.assertEqual(item.layer.tile_h, 6)
        self.assertEqual(item.materialized_entries, 29_952)
        unsafe = replace(item.layer, tile_h=7)
        with self.assertRaisesRegex(
            PlanValidationError, "materialized cache capacity exceeded"
        ):
            schedule_layer(unsafe)

    def test_both_coco80_detector_heads_use_255_tail31(self):
        p4 = get_schedule("p4_detect")
        p5 = get_schedule("p5_detect")
        self.assertEqual(
            (p4.layer.cout, p4.cout_blocks, p4.cout_tail_channels),
            (255, 8, 31),
        )
        self.assertEqual(
            (p5.layer.cout, p5.cout_blocks, p5.cout_tail_channels),
            (255, 8, 31),
        )
        self.assertEqual(p4.ofm_bytes, 26 * 26 * 255)
        self.assertEqual(p5.ofm_bytes, 13 * 13 * 255)

    def test_release_builder_fails_closed_on_table_or_limit_drift(self):
        changed = list(COCO80_CONV_LAYERS)
        changed[0] = replace(changed[0], tile_h=4)
        with self.assertRaisesRegex(PlanValidationError, "release layer table changed"):
            build_hardware_plan(changed)
        experimental = build_hardware_plan(
            COCO80_CONV_LAYERS, enforce_release_contract=False
        )
        self.assertEqual(len(experimental.layers), 13)

    def test_invalid_geometry_and_duplicate_ids_fail_closed(self):
        with self.assertRaises(PlanValidationError):
            schedule_layer(replace(COCO80_CONV_LAYERS[0], tile_h=3))
        duplicate = list(COCO80_CONV_LAYERS)
        duplicate[-1] = replace(duplicate[-1], layer_id=duplicate[-2].layer_id)
        with self.assertRaisesRegex(PlanValidationError, "duplicate"):
            build_hardware_plan(duplicate, enforce_release_contract=False)


if __name__ == "__main__":
    unittest.main()

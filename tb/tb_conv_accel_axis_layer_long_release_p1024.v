`define TB_LAYER_LONG_TWO_TILE_MODULE tb_conv_accel_axis_layer_long_release_p1024
`define TB_LAYER_LONG_CIN_TOTAL 19
`define TB_LAYER_LONG_COUT_TOTAL 9
`define TB_LAYER_LONG_FM_H 64
`define TB_LAYER_LONG_FM_W 32
`define TB_LAYER_LONG_KERNEL_1X1 1
`define TB_LAYER_LONG_CONV_STRIDE 1
`define TB_LAYER_LONG_CONV_PAD 0
`define TB_LAYER_LONG_TILE_H_MAX 32

// Two 32x32 tiles hit the full 1024-pixel materialized/PSUM bank boundary.
// Cin=19 adds a partial-PSUM pass plus a one-row K tail while remaining within
// the release raw-HWC and materialized-cache capacities.
`include "tb_conv_accel_axis_layer_long_two_tile_e2e.v"

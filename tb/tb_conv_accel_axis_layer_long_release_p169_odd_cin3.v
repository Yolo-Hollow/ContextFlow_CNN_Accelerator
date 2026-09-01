`define TB_LAYER_LONG_TWO_TILE_MODULE tb_conv_accel_axis_layer_long_release_p169_odd_cin3
`define TB_LAYER_LONG_CIN_TOTAL 3
`define TB_LAYER_LONG_COUT_TOTAL 9
`define TB_LAYER_LONG_FM_H 26
`define TB_LAYER_LONG_FM_W 13
`define TB_LAYER_LONG_KERNEL_1X1 0
`define TB_LAYER_LONG_CONV_STRIDE 1
`define TB_LAYER_LONG_CONV_PAD 1
`define TB_LAYER_LONG_TILE_H_MAX 13

// Two 13x13 tiles exercise the exact 169-pixel boundary.  The 3x3/Cin=3
// geometry gives K=27, an odd-Cin materialization case and a 9-row K tail.
`include "tb_conv_accel_axis_layer_long_two_tile_e2e.v"

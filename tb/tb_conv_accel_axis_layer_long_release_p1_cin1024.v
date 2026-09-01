`define TB_LAYER_LONG_TWO_TILE_MODULE tb_conv_accel_axis_layer_long_release_p1_cin1024
`define TB_LAYER_LONG_CIN_TOTAL 1024
`define TB_LAYER_LONG_COUT_TOTAL 9
`define TB_LAYER_LONG_FM_H 2
`define TB_LAYER_LONG_FM_W 1
`define TB_LAYER_LONG_KERNEL_1X1 1
`define TB_LAYER_LONG_CONV_STRIDE 1
`define TB_LAYER_LONG_CONV_PAD 0
`define TB_LAYER_LONG_TILE_H_MAX 1

// Two one-pixel tiles exercise the exact one-pixel materializer boundary.
// Cin=1024 also covers the 1x1 K-tail (57 passes, 16 valid rows in the last
// pass).  Cout=9 is deliberately large enough for tile 0 to emit a packed
// beat before tile 1, so the active-datapath reset stress remains reachable.
`include "tb_conv_accel_axis_layer_long_two_tile_e2e.v"

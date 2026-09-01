`define TB_LAYER_LONG_TWO_TILE_MODULE tb_conv_accel_axis_layer_long_release_p936
`define TB_LAYER_LONG_CIN_TOTAL 19
`define TB_LAYER_LONG_COUT_TOTAL 9
`define TB_LAYER_LONG_FM_H 48
`define TB_LAYER_LONG_FM_W 39
`define TB_LAYER_LONG_KERNEL_1X1 1
`define TB_LAYER_LONG_CONV_STRIDE 1
`define TB_LAYER_LONG_CONV_PAD 0
`define TB_LAYER_LONG_TILE_H_MAX 24

// Two 24x39 tiles exercise the 936-pixel boundary used by the release cache.
// Cin=19 forces a partial-PSUM handoff into a one-row K tail, so the active
// reset stress also covers simultaneous context/FIFO/PSUM ownership.
`include "tb_conv_accel_axis_layer_long_two_tile_e2e.v"

`timescale 1ns / 1ps

`define TB_CONV_ACCEL_CORE_MODULE tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_tile4
`define TB_CONV_ACCEL_CORE_USE_AXI_LITE
`define TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
`define TB_CONV_ACCEL_CORE_USE_EXTERNAL_GOLDEN
`define TB_CONV_ACCEL_CORE_CENTER_EXTERNAL_IFM
`define TB_CONV_ACCEL_CORE_INPUT_ZP 8'd36
`define TB_CONV_ACCEL_CORE_ROWS 18
`define TB_CONV_ACCEL_CORE_COLS 16
`define TB_CONV_ACCEL_CORE_IFM_BANKS 2
`define TB_CONV_ACCEL_CORE_CIN 64
`define TB_CONV_ACCEL_CORE_FM_W 52
`define TB_CONV_ACCEL_CORE_FM_H 52
`define TB_CONV_ACCEL_CORE_OFM_W 52
`define TB_CONV_ACCEL_CORE_OFM_H 52
`define TB_CONV_ACCEL_CORE_COUT_TOTAL 128
`define TB_CONV_ACCEL_CORE_PAD 1
`define TB_CONV_ACCEL_CORE_STRIDE 1
`define TB_CONV_ACCEL_CORE_TILE_OY_BASE 0
`define TB_CONV_ACCEL_CORE_TILE_OFM_H 4
`define TB_CONV_ACCEL_CORE_TILE_PIXEL_BASE 0
`define TB_CONV_ACCEL_CORE_TILE_COUNT 1
`define TB_CONV_ACCEL_CORE_IFM_D 256
`define TB_CONV_ACCEL_CORE_IFM_AW 8
`define TB_CONV_ACCEL_CORE_PSUM_D 256
`define TB_CONV_ACCEL_CORE_PSUM_AW 8
`define TB_CONV_ACCEL_CORE_PSUM_BUF_AW 12
`define TB_CONV_ACCEL_CORE_PSUM_BUF_DEPTH 4096
`define TB_CONV_ACCEL_CORE_OFM_ADDR_W 24
`define TB_CONV_ACCEL_CORE_OFM_FIFO_DEPTH 128
`define TB_CONV_ACCEL_CORE_OFM_FIFO_AW 7
`define TB_CONV_ACCEL_CORE_QUANT_MULT 16'd18055
`define TB_CONV_ACCEL_CORE_QUANT_SHIFT 4'd7
`define TB_CONV_ACCEL_CORE_QUANT_ZP 8'd75
`define TB_CONV_ACCEL_CORE_ACT_MODE 2
`define TB_CONV_ACCEL_CORE_IFM_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_layer06_rtl/xsim_mem/ifm_u8_hwc.mem"
`define TB_CONV_ACCEL_CORE_WEIGHT_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_layer06_rtl/xsim_mem/weight_kco_s8.mem"
`define TB_CONV_ACCEL_CORE_BIAS_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_layer06_rtl/xsim_mem/bias_i32.mem"
`define TB_CONV_ACCEL_CORE_ACT_LUT_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_layer06_rtl/xsim_mem/activation_lut_u8.mem"
`define TB_CONV_ACCEL_CORE_GOLDEN_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_layer06_rtl/xsim_mem/golden_ofm_u8_hwc.mem"
`define TB_CONV_ACCEL_CORE_TIMEOUT 12000000

`include "tb_conv_accel_core_realistic_small.v"

`timescale 1ns / 1ps

`define TB_CONV_ACCEL_CORE_MODULE tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c8_b2_ext
`define TB_CONV_ACCEL_CORE_USE_AXI_LITE
`define TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
`define TB_CONV_ACCEL_CORE_USE_EXTERNAL_GOLDEN
`define TB_CONV_ACCEL_CORE_CENTER_EXTERNAL_IFM
`define TB_CONV_ACCEL_CORE_INPUT_ZP 8'd0
`define TB_CONV_ACCEL_CORE_ROWS 18
`define TB_CONV_ACCEL_CORE_COLS 8
`define TB_CONV_ACCEL_CORE_IFM_BANKS 2
`define TB_CONV_ACCEL_CORE_CIN 3
`define TB_CONV_ACCEL_CORE_FM_W 16
`define TB_CONV_ACCEL_CORE_FM_H 8
`define TB_CONV_ACCEL_CORE_OFM_W 16
`define TB_CONV_ACCEL_CORE_OFM_H 8
`define TB_CONV_ACCEL_CORE_COUT_TOTAL 16
`define TB_CONV_ACCEL_CORE_PAD 1
`define TB_CONV_ACCEL_CORE_STRIDE 1
`define TB_CONV_ACCEL_CORE_TILE_OY_BASE 0
`define TB_CONV_ACCEL_CORE_TILE_OFM_H 8
`define TB_CONV_ACCEL_CORE_TILE_PIXEL_BASE 0
`define TB_CONV_ACCEL_CORE_TILE_COUNT 1
`define TB_CONV_ACCEL_CORE_POOL_ENABLE 1
`define TB_CONV_ACCEL_CORE_POOL_STRIDE 2
`define TB_CONV_ACCEL_CORE_IFM_D 128
`define TB_CONV_ACCEL_CORE_IFM_AW 7
`define TB_CONV_ACCEL_CORE_PSUM_D 128
`define TB_CONV_ACCEL_CORE_PSUM_AW 7
`define TB_CONV_ACCEL_CORE_PSUM_BUF_AW 7
`define TB_CONV_ACCEL_CORE_PSUM_BUF_DEPTH 128
`define TB_CONV_ACCEL_CORE_OFM_ADDR_W 16
`define TB_CONV_ACCEL_CORE_OFM_FIFO_DEPTH 32
`define TB_CONV_ACCEL_CORE_OFM_FIFO_AW 5
`define TB_CONV_ACCEL_CORE_QUANT_MULT 16'd18898
`define TB_CONV_ACCEL_CORE_QUANT_SHIFT 4'd9
`define TB_CONV_ACCEL_CORE_QUANT_ZP 8'd69
`define TB_CONV_ACCEL_CORE_ACT_MODE 2
`define TB_CONV_ACCEL_CORE_IFM_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_conv0_crop16x8_pool/xsim_mem/ifm_u8_hwc.mem"
`define TB_CONV_ACCEL_CORE_WEIGHT_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_conv0_crop16x8_pool/xsim_mem/weight_kco_s8.mem"
`define TB_CONV_ACCEL_CORE_BIAS_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_conv0_crop16x8_pool/xsim_mem/bias_i32.mem"
`define TB_CONV_ACCEL_CORE_ACT_LUT_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_conv0_crop16x8_pool/xsim_mem/activation_lut_u8.mem"
`define TB_CONV_ACCEL_CORE_GOLDEN_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_conv0_crop16x8_pool/xsim_mem/golden_pool2x2s2_u8_hwc.mem"
`define TB_CONV_ACCEL_CORE_TIMEOUT 800000

`include "tb_conv_accel_core_realistic_small.v"

`timescale 1ns / 1ps

`define TB_CONV_ACCEL_CORE_MODULE tb_conv_accel_core_axi_lite_axis_stream_conv7_native1x1_ext_tile0
`define TB_CONV_ACCEL_CORE_USE_AXI_LITE
`define TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
`define TB_CONV_ACCEL_CORE_BATCH_STREAM
`define TB_CONV_ACCEL_CORE_KERNEL_1X1 1
`define TB_CONV_ACCEL_CORE_USE_EXTERNAL_GOLDEN
`define TB_CONV_ACCEL_CORE_CENTER_EXTERNAL_IFM
`define TB_CONV_ACCEL_CORE_CHECK_VECTOR_IFM
`define TB_CONV_ACCEL_CORE_ROWS 18
`define TB_CONV_ACCEL_CORE_COLS 8
`define TB_CONV_ACCEL_CORE_IFM_BANKS 2
`define TB_CONV_ACCEL_CORE_CIN 1024
`define TB_CONV_ACCEL_CORE_FM_W 13
`define TB_CONV_ACCEL_CORE_FM_H 13
`define TB_CONV_ACCEL_CORE_OFM_W 13
`define TB_CONV_ACCEL_CORE_OFM_H 13
`define TB_CONV_ACCEL_CORE_COUT_TOTAL 256
`define TB_CONV_ACCEL_CORE_PAD 0
`define TB_CONV_ACCEL_CORE_STRIDE 1
`define TB_CONV_ACCEL_CORE_INPUT_ZP 8'd21
`define TB_CONV_ACCEL_CORE_TILE_OY_BASE 0
`define TB_CONV_ACCEL_CORE_TILE_OFM_H 4
`define TB_CONV_ACCEL_CORE_TILE_PIXEL_BASE 0
`define TB_CONV_ACCEL_CORE_TILE_COUNT 1
`define TB_CONV_ACCEL_CORE_IFM_D 64
`define TB_CONV_ACCEL_CORE_IFM_AW 6
`define TB_CONV_ACCEL_CORE_PSUM_D 128
`define TB_CONV_ACCEL_CORE_PSUM_AW 7
`define TB_CONV_ACCEL_CORE_PSUM_BUF_AW 6
`define TB_CONV_ACCEL_CORE_PSUM_BUF_DEPTH 64
`define TB_CONV_ACCEL_CORE_OFM_ADDR_W 16
`define TB_CONV_ACCEL_CORE_OFM_FIFO_DEPTH 64
`define TB_CONV_ACCEL_CORE_OFM_FIFO_AW 6
`define TB_CONV_ACCEL_CORE_QUANT_MULT 16'd28217
`define TB_CONV_ACCEL_CORE_QUANT_SHIFT 4'd7
`define TB_CONV_ACCEL_CORE_QUANT_ZP 8'd69
`define TB_CONV_ACCEL_CORE_ACT_MODE 2
`define TB_CONV_ACCEL_CORE_IFM_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_chain_conv0_conv7_rtl/07_head_conv7_1x1/xsim_mem/ifm_u8_hwc.mem"
`define TB_CONV_ACCEL_CORE_WEIGHT_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_chain_conv0_conv7_rtl/07_head_conv7_1x1/xsim_mem/weight_kco_s8.mem"
`define TB_CONV_ACCEL_CORE_BIAS_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_chain_conv0_conv7_rtl/07_head_conv7_1x1/xsim_mem/bias_i32.mem"
`define TB_CONV_ACCEL_CORE_ACT_LUT_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_chain_conv0_conv7_rtl/07_head_conv7_1x1/xsim_mem/activation_lut_u8.mem"
`define TB_CONV_ACCEL_CORE_GOLDEN_MEM "D:/MPSoC/python_prj/rtl_golden/facemask_chain_conv0_conv7_rtl/07_head_conv7_1x1/xsim_mem/golden_ofm_u8_hwc.mem"
`define TB_CONV_ACCEL_CORE_TIMEOUT 20000000

`include "tb_conv_accel_core_realistic_small.v"

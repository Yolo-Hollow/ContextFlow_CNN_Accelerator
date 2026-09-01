`timescale 1ns / 1ps
`define TB_CONV_LAYER_TOP_MODULE tb_conv_layer_top_stream_tagged
`define TB_CONV_LAYER_ENABLE_TAGGED_CONTEXT 1
// Exercise three K_TILE passes so both partial-PSUM banks are read back.
`define TB_CONV_LAYER_CIN 9
// The legacy five-bank line feeder only materializes CIN<=5.  Use the atomic
// vector ingress so all 81 K positions in this three-pass test are driven.
`define TB_CONV_LAYER_RAW_VECTOR_MODE 1'b1
`include "tb_conv_layer_top_stream.v"

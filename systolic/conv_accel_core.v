`timescale 1ns / 1ps
// Register-configured wrapper around conv_layer_top_stream.
//
// This is not an AXI-Lite slave yet. It exposes a small local config bus that
// can later be wrapped by AXI-Lite without changing the compute datapath.
module conv_accel_core #(
    parameter ROWS = 32,
    parameter COLS = 32,
    parameter IFM_W = 8,
    parameter WEIGHT_W = 8,
    parameter PSUM_W = 32,
    parameter IFM_FIFO_DEPTH = 256,
    parameter IFM_FIFO_AW = 8,
    parameter WGT_FIFO_DEPTH = 64,
    parameter WGT_FIFO_AW = 6,
    parameter PSUM_FIFO_DEPTH = 256,
    parameter PSUM_FIFO_AW = 8,
    parameter FM_W_MAX = 416,
    parameter FM_H_MAX = 416,
    parameter K_TILE = 32,
    parameter COUT_TILE = 64,
    parameter WGT_TILE_AW = 11,
    parameter PSUM_BUF_AW = 10,
    parameter PSUM_BUF_DEPTH = 1024,
    parameter MULT_W = 16,
    parameter SHIFT_W = 4,
    parameter ZP_W = 8,
    parameter OFM_ADDR_W = 24,
    parameter OFM_FIFO_DEPTH = 32,
    parameter OFM_FIFO_AW = 5
) (
    input  clk,
    input  rst,

    input         cfg_wr_en,
    input  [5:0]  cfg_addr,
    input  [31:0] cfg_wdata,
    input         cfg_rd_en,
    output [31:0] cfg_rdata,

    output bias_load_req,
    input  bias_load_done,
    output [10:0] current_cout_base,
    output [10:0] current_pass_base_k,

    input  [5:0]        bias_wr_addr,
    input  [PSUM_W-1:0] bias_wr_data,
    input               bias_wr_en,

    output weight_load_req,
    input  weight_tile_ready,
    input  wgt_tile_wr_en,
    input  [WGT_TILE_AW-1:0] wgt_tile_wr_addr,
    input  [WEIGHT_W-1:0]    wgt_tile_wr_data,

    output feeder_fill_req,
    output [8:0] feeder_fill_fy,
    input  [4:0] dma_bank_wr_en,
    input  [8:0] dma_wr_x,
    input  [9:0] dma_wr_fy,
    input  [7:0] dma_wr_data [0:4],
    input        dma_line_advance,

    input  [COLS*2*MULT_W-1:0]  quant_mult_flat,
    input  [COLS*2*SHIFT_W-1:0] quant_shift_flat,
    input  [COLS*2*ZP_W-1:0]    quant_zp_flat,

    output                      ofm_mem_wr_en,
    output [OFM_ADDR_W-1:0]     ofm_mem_wr_addr,
    output [7:0]                ofm_mem_wr_data,
    output                      ofm_packet_full
);
    wire start_pulse;
    wire layer_busy;
    wire layer_done;
    wire [8:0] fm_h;
    wire [8:0] fm_w;
    wire [8:0] ofm_h;
    wire [8:0] ofm_w;
    wire [1:0] conv_stride;
    wire [1:0] conv_pad;
    wire [10:0] k_total;
    wire [10:0] cout_total;
    wire [15:0] num_pixels;

    layer_config_regs u_cfg (
        .clk(clk), .rst(rst),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_rd_en(cfg_rd_en), .cfg_rdata(cfg_rdata),
        .layer_busy(layer_busy), .layer_done(layer_done), .start_pulse(start_pulse),
        .fm_h(fm_h), .fm_w(fm_w), .ofm_h(ofm_h), .ofm_w(ofm_w),
        .conv_stride(conv_stride), .conv_pad(conv_pad),
        .k_total(k_total), .cout_total(cout_total), .num_pixels(num_pixels)
    );

    conv_layer_top_stream #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WEIGHT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_FIFO_DEPTH), .IFM_FIFO_AW(IFM_FIFO_AW),
        .WGT_FIFO_DEPTH(WGT_FIFO_DEPTH), .WGT_FIFO_AW(WGT_FIFO_AW),
        .PSUM_FIFO_DEPTH(PSUM_FIFO_DEPTH), .PSUM_FIFO_AW(PSUM_FIFO_AW),
        .FM_W_MAX(FM_W_MAX), .FM_H_MAX(FM_H_MAX),
        .K_TILE(K_TILE), .COUT_TILE(COUT_TILE),
        .WGT_TILE_AW(WGT_TILE_AW), .PSUM_BUF_AW(PSUM_BUF_AW), .PSUM_BUF_DEPTH(PSUM_BUF_DEPTH),
        .MULT_W(MULT_W), .SHIFT_W(SHIFT_W), .ZP_W(ZP_W),
        .OFM_ADDR_W(OFM_ADDR_W), .OFM_FIFO_DEPTH(OFM_FIFO_DEPTH), .OFM_FIFO_AW(OFM_FIFO_AW)
    ) u_layer (
        .clk(clk), .rst(rst), .start(start_pulse), .busy(layer_busy), .done(layer_done),
        .fm_h(fm_h), .fm_w(fm_w), .ofm_h(ofm_h), .ofm_w(ofm_w),
        .conv_stride(conv_stride), .conv_pad(conv_pad),
        .k_total(k_total), .cout_total(cout_total), .num_pixels(num_pixels),
        .bias_load_req(bias_load_req), .bias_load_done(bias_load_done),
        .current_cout_base(current_cout_base), .current_pass_base_k(current_pass_base_k),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .weight_load_req(weight_load_req), .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en), .wgt_tile_wr_addr(wgt_tile_wr_addr),
        .wgt_tile_wr_data(wgt_tile_wr_data),
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .final_valid(), .final_addr(), .final_data(), .final_cout_base(), .final_channel_valid(),
        .quant_mult_flat(quant_mult_flat), .quant_shift_flat(quant_shift_flat), .quant_zp_flat(quant_zp_flat),
        .ofm_valid(), .ofm_addr(), .ofm_cout_base(), .ofm_channel_valid(), .ofm_data(),
        .ofm_mem_wr_en(ofm_mem_wr_en), .ofm_mem_wr_addr(ofm_mem_wr_addr),
        .ofm_mem_wr_data(ofm_mem_wr_data), .ofm_packet_full(ofm_packet_full)
    );
endmodule

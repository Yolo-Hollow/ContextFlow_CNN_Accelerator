`timescale 1ns / 1ps

// AXI-Lite configured conv core with stream-style bias/weight load ports.
//
// This is still not the final DMA top. It only replaces the direct
// bias_wr/wgt_tile_wr pins with narrow ready/valid streams so the PS/DMA
// service contract can be verified independently from the compute datapath.
`ifndef SYSTOLIC_TAIL_CYCLES_CONFIG
`define SYSTOLIC_TAIL_CYCLES_CONFIG 0
`endif

module conv_accel_core_axi_lite_stream #(
    parameter ROWS = 32,
    parameter COLS = 32,
    parameter IFM_W = 8,
    parameter WEIGHT_W = 8,
    parameter PSUM_W = 32,
    parameter IFM_FIFO_DEPTH = 1024,
    parameter IFM_FIFO_AW = 10,
    parameter WGT_FIFO_DEPTH = 64,
    parameter WGT_FIFO_AW = 6,
    parameter PSUM_FIFO_DEPTH = 1024,
    parameter PSUM_FIFO_AW = 10,
    parameter FM_W_MAX = 416,
    parameter FM_H_MAX = 416,
    parameter K_TILE = 32,
    parameter COUT_TILE = 64,
    parameter IFM_BANKS = 5,
    parameter WGT_TILE_AW = 11,
    parameter PSUM_BUF_AW = 10,
    parameter PSUM_BUF_DEPTH = 1024,
    parameter MULT_W = 16,
    parameter SHIFT_W = 4,
    parameter ZP_W = 8,
    parameter OFM_ADDR_W = 24,
    parameter OFM_FIFO_DEPTH = 32,
    parameter OFM_FIFO_AW = 5,
    parameter TAIL_CYCLES_CONFIG = `SYSTOLIC_TAIL_CYCLES_CONFIG
) (
    input  clk,
    input  rst,

    input  [8:0]  s_axi_awaddr,
    input         s_axi_awvalid,
    output        s_axi_awready,
    input  [31:0] s_axi_wdata,
    input  [3:0]  s_axi_wstrb,
    input         s_axi_wvalid,
    output        s_axi_wready,
    output [1:0]  s_axi_bresp,
    output        s_axi_bvalid,
    input         s_axi_bready,
    input  [8:0]  s_axi_araddr,
    input         s_axi_arvalid,
    output        s_axi_arready,
    output [31:0] s_axi_rdata,
    output [1:0]  s_axi_rresp,
    output        s_axi_rvalid,
    input         s_axi_rready,

    output bias_load_req,
    output weight_load_req,
    output [10:0] current_cout_base,
    output [13:0] current_pass_base_k,
    output [13:0] current_feeder_pass_base_k,
    output [7:0]  configured_input_zero_point,

    output              bias_s_ready,
    input               bias_s_valid,
    input  [PSUM_W-1:0] bias_s_data,

    output               weight_s_ready,
    input                weight_s_valid,
    input  [WEIGHT_W-1:0] weight_s_data,

    output feeder_fill_req,
    output [8:0] feeder_fill_fy,
    input  [IFM_BANKS-1:0] dma_bank_wr_en,
    input  [8:0] dma_wr_x,
    input  [9:0] dma_wr_fy,
    input  [7:0] dma_wr_data [0:IFM_BANKS-1],
    input        dma_line_advance,

    input         quant_wr_en,
    input  [5:0]  quant_wr_addr,
    input  [31:0] quant_wr_data,
    input  [5:0]  quant_rd_addr,
    output [31:0] quant_rd_data,
    input         act_lut_wr_en,
    input  [7:0]  act_lut_wr_addr,
    input  [7:0]  act_lut_wr_data,

    output                      ofm_mem_wr_en,
    input                       ofm_mem_wr_ready,
    output [OFM_ADDR_W-1:0]     ofm_mem_wr_addr,
    output [7:0]                ofm_mem_wr_data,
    output                      ofm_packet_full
);
    wire bias_load_done;
    wire bias_wr_en;
    wire [5:0] bias_wr_addr;
    wire [PSUM_W-1:0] bias_wr_data;
    wire weight_tile_ready;
    wire wgt_tile_wr_en;
    wire [WGT_TILE_AW-1:0] wgt_tile_wr_addr;
    wire [WEIGHT_W-1:0] wgt_tile_wr_data;
    wire [10:0] unused_configured_cout_total;
    wire [15:0] unused_configured_num_pixels;
    wire [8:0] unused_configured_ofm_w;
    wire unused_configured_pool_enable;
    wire [1:0] unused_configured_pool_stride;
    wire [31:0] unused_configured_expected_bytes;

    bias_weight_stream_loader #(
        .ROWS(ROWS), .COLS(COLS), .PSUM_W(PSUM_W), .WEIGHT_W(WEIGHT_W),
        .BIAS_ADDR_W(6), .WGT_ADDR_W(WGT_TILE_AW)
    ) u_bw_loader (
        .clk(clk), .rst(rst),
        .bias_load_req(bias_load_req), .bias_s_ready(bias_s_ready),
        .bias_s_valid(bias_s_valid), .bias_s_data(bias_s_data),
        .bias_load_done(bias_load_done),
        .bias_wr_en(bias_wr_en), .bias_wr_addr(bias_wr_addr),
        .bias_wr_data(bias_wr_data),
        .weight_load_req(weight_load_req), .weight_s_ready(weight_s_ready),
        .weight_s_valid(weight_s_valid), .weight_s_data(weight_s_data),
        .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en), .wgt_tile_wr_addr(wgt_tile_wr_addr),
        .wgt_tile_wr_data(wgt_tile_wr_data)
    );

    conv_accel_core_axi_lite #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WEIGHT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_FIFO_DEPTH), .IFM_FIFO_AW(IFM_FIFO_AW),
        .WGT_FIFO_DEPTH(WGT_FIFO_DEPTH), .WGT_FIFO_AW(WGT_FIFO_AW),
        .PSUM_FIFO_DEPTH(PSUM_FIFO_DEPTH), .PSUM_FIFO_AW(PSUM_FIFO_AW),
        .FM_W_MAX(FM_W_MAX), .FM_H_MAX(FM_H_MAX),
        .K_TILE(K_TILE), .COUT_TILE(COUT_TILE), .IFM_BANKS(IFM_BANKS),
        .WGT_TILE_AW(WGT_TILE_AW), .PSUM_BUF_AW(PSUM_BUF_AW), .PSUM_BUF_DEPTH(PSUM_BUF_DEPTH),
        .MULT_W(MULT_W), .SHIFT_W(SHIFT_W), .ZP_W(ZP_W),
        .OFM_ADDR_W(OFM_ADDR_W), .OFM_FIFO_DEPTH(OFM_FIFO_DEPTH), .OFM_FIFO_AW(OFM_FIFO_AW),
        .TAIL_CYCLES_CONFIG(TAIL_CYCLES_CONFIG)
    ) u_core (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .bias_load_req(bias_load_req), .bias_load_done(bias_load_done),
        .current_cout_base(current_cout_base), .current_pass_base_k(current_pass_base_k),
        .current_feeder_pass_base_k(current_feeder_pass_base_k),
        .configured_cout_total(unused_configured_cout_total),
        .configured_num_pixels(unused_configured_num_pixels),
        .configured_input_zero_point(configured_input_zero_point),
        .configured_ofm_w(unused_configured_ofm_w),
        .configured_pool_enable(unused_configured_pool_enable),
        .configured_pool_stride(unused_configured_pool_stride),
        .configured_expected_bytes(unused_configured_expected_bytes),
        .debug_expected_bytes(32'd0), .debug_core_wr_count(32'd0),
        .debug_axis_wr_count(32'd0), .debug_tlast_count(32'd0),
        .debug_last_tlast_index(32'd0),
        .raw_hwc_load_active_cycles(32'd0),
        .raw_hwc_load_unpack_cycles(32'd0),
        .raw_hwc_replay_active_cycles(32'd0),
        .raw_hwc_replay_wait_ready_cycles(32'd0),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .weight_load_req(weight_load_req), .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en), .wgt_tile_wr_addr(wgt_tile_wr_addr),
        .wgt_tile_wr_data(wgt_tile_wr_data),
        .wgt_tile_wr8_en(1'b0), .wgt_tile_wr8_addr({WGT_TILE_AW{1'b0}}),
        .wgt_tile_wr8_data({(WEIGHT_W*8){1'b0}}), .wgt_tile_wr8_keep(8'd0),
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .quant_wr_en(quant_wr_en), .quant_wr_addr(quant_wr_addr), .quant_wr_data(quant_wr_data),
        .quant_rd_addr(quant_rd_addr), .quant_rd_data(quant_rd_data),
        .act_lut_wr_en(act_lut_wr_en), .act_lut_wr_addr(act_lut_wr_addr),
        .act_lut_wr_data(act_lut_wr_data),
        .ofm_mem_wr_en(ofm_mem_wr_en), .ofm_mem_wr_ready(ofm_mem_wr_ready),
        .ofm_mem_wr_addr(ofm_mem_wr_addr),
        .ofm_mem_wr_data(ofm_mem_wr_data), .ofm_packet_full(ofm_packet_full)
    );
endmodule

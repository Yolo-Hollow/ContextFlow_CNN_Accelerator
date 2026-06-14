`timescale 1ns / 1ps

// AXI-Lite configured conv core with stream-style bias/weight/IFM-line ports.
//
// This wrapper is the current "DMA-facing" simulation top:
//   - AXI-Lite config path
//   - bias stream
//   - weight tile stream
//   - IFM line fill stream
// OFM is exposed both as raw byte-write signals and as a backpressure-capable
// byte stream carrying {addr,data}. A later AXI DMA wrapper can pack this stream
// into wider memory beats.
`ifndef SYSTOLIC_TAIL_CYCLES_CONFIG
`define SYSTOLIC_TAIL_CYCLES_CONFIG 0
`endif

module conv_accel_core_axi_lite_full_stream #(
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
    output feeder_fill_req,
    output [8:0] feeder_fill_fy,
    output [10:0] current_cout_base,
    output [13:0] current_pass_base_k,

    output              bias_s_ready,
    input               bias_s_valid,
    input  [PSUM_W-1:0] bias_s_data,

    output                weight_s_ready,
    input                 weight_s_valid,
    input  [WEIGHT_W-1:0] weight_s_data,

    input  [8:0] ifm_line_words,
    output       ifm_line_s_ready,
    input        ifm_line_s_valid,
    input  [7:0] ifm_line_s_data [0:IFM_BANKS-1],

    input         quant_wr_en,
    input  [5:0]  quant_wr_addr,
    input  [31:0] quant_wr_data,
    input  [5:0]  quant_rd_addr,
    output [31:0] quant_rd_data,
    input         act_lut_wr_en,
    input  [7:0]  act_lut_wr_addr,
    input  [7:0]  act_lut_wr_data,

    output                      ofm_mem_wr_en,
    output [OFM_ADDR_W-1:0]     ofm_mem_wr_addr,
    output [7:0]                ofm_mem_wr_data,
    output                      ofm_m_valid,
    input                       ofm_m_ready,
    output [OFM_ADDR_W-1:0]     ofm_m_addr,
    output [7:0]                ofm_m_data,
    output                      ofm_packet_full
);
    wire [IFM_BANKS-1:0] dma_bank_wr_en;
    wire [8:0] dma_wr_x;
    wire [9:0] dma_wr_fy;
    wire [7:0] dma_wr_data [0:IFM_BANKS-1];
    wire dma_line_advance;
    wire core_ofm_wr_en;
    wire core_ofm_wr_ready;
    wire [OFM_ADDR_W-1:0] core_ofm_wr_addr;
    wire [7:0] core_ofm_wr_data;
    wire ofm_stream_full;
    wire ofm_stream_almost_full;
    wire [7:0] configured_input_zero_point;
    wire [13:0] unused_current_feeder_pass_base_k;

    assign ofm_mem_wr_en = ofm_m_valid && ofm_m_ready;
    assign ofm_mem_wr_addr = ofm_m_addr;
    assign ofm_mem_wr_data = ofm_m_data;

    ifm_line_stream_loader #(.AW(9), .BANKS(IFM_BANKS)) u_ifm_loader (
        .clk(clk), .rst(rst),
        .fm_w(ifm_line_words), .fill_req(feeder_fill_req), .fill_fy(feeder_fill_fy),
        .input_zero_point(configured_input_zero_point),
        .line_s_ready(ifm_line_s_ready), .line_s_valid(ifm_line_s_valid),
        .line_s_data(ifm_line_s_data),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x),
        .dma_wr_fy(dma_wr_fy), .dma_wr_data(dma_wr_data),
        .dma_line_advance(dma_line_advance)
    );

    conv_accel_core_axi_lite_stream #(
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
        .bias_load_req(bias_load_req), .weight_load_req(weight_load_req),
        .current_cout_base(current_cout_base), .current_pass_base_k(current_pass_base_k),
        .current_feeder_pass_base_k(unused_current_feeder_pass_base_k),
        .configured_input_zero_point(configured_input_zero_point),
        .bias_s_ready(bias_s_ready), .bias_s_valid(bias_s_valid), .bias_s_data(bias_s_data),
        .weight_s_ready(weight_s_ready), .weight_s_valid(weight_s_valid), .weight_s_data(weight_s_data),
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .quant_wr_en(quant_wr_en), .quant_wr_addr(quant_wr_addr), .quant_wr_data(quant_wr_data),
        .quant_rd_addr(quant_rd_addr), .quant_rd_data(quant_rd_data),
        .act_lut_wr_en(act_lut_wr_en), .act_lut_wr_addr(act_lut_wr_addr),
        .act_lut_wr_data(act_lut_wr_data),
        .ofm_mem_wr_en(core_ofm_wr_en), .ofm_mem_wr_ready(core_ofm_wr_ready),
        .ofm_mem_wr_addr(core_ofm_wr_addr),
        .ofm_mem_wr_data(core_ofm_wr_data), .ofm_packet_full(ofm_packet_full)
    );

    ofm_byte_stream_fifo #(
        .ADDR_W(OFM_ADDR_W), .DEPTH(OFM_FIFO_DEPTH), .AW(OFM_FIFO_AW)
    ) u_ofm_stream_fifo (
        .clk(clk), .rst(rst),
        .wr_en(core_ofm_wr_en), .wr_ready(core_ofm_wr_ready),
        .wr_addr(core_ofm_wr_addr), .wr_data(core_ofm_wr_data),
        .m_valid(ofm_m_valid), .m_ready(ofm_m_ready),
        .m_addr(ofm_m_addr), .m_data(ofm_m_data),
        .full(ofm_stream_full), .almost_full(ofm_stream_almost_full)
    );
endmodule

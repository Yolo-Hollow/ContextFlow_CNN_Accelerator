`timescale 1ns / 1ps
// Register-configured wrapper around conv_layer_top_stream.
//
// This is not an AXI-Lite slave yet. It exposes a small local config bus that
// can later be wrapped by AXI-Lite without changing the compute datapath.
//
// Extra config-bus register map owned by this wrapper:
//   0x20 QUANT_ADDR: [5:0]=quant lane address
//   0x21 QUANT_DATA: [15:0]=mult, [19:16]=shift, [31:24]=zp
//   0x22 LUT_ADDR:   [7:0]=activation LUT address
//   0x23 LUT_DATA:   [7:0]=activation LUT data
//
// The legacy direct quant/LUT programming ports remain available for unit
// tests and non-AXI wrappers. AXI-Lite system tops program through 0x20..0x23.
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
    parameter IFM_BANKS = 5,
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
    output [10:0] configured_cout_total,
    output [15:0] configured_num_pixels,
    output [7:0]  configured_input_zero_point,
    output [8:0]  configured_ofm_w,
    output        configured_pool_enable,
    output [1:0]  configured_pool_stride,
    input  [31:0] debug_expected_bytes,
    input  [31:0] debug_core_wr_count,
    input  [31:0] debug_axis_wr_count,
    input  [31:0] debug_tlast_count,
    input  [31:0] debug_last_tlast_index,

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
    wire start_pulse;
    wire layer_busy;
    wire layer_done;
    wire [31:0] layer_cfg_rdata;
    wire [8:0] fm_h;
    wire [8:0] fm_w;
    wire [8:0] ofm_h;
    wire [8:0] ofm_w;
    wire [1:0] conv_stride;
    wire [1:0] conv_pad;
    wire [1:0] activation_mode;
    wire [10:0] k_total;
    wire [10:0] cout_total;
    wire [15:0] num_pixels;
    wire [8:0] tile_oy_base;
    wire [8:0] tile_ofm_h;
    wire [23:0] tile_pixel_base;
    wire [7:0] input_zero_point;
    wire pool_enable;
    wire [1:0] pool_stride;
    wire [OFM_ADDR_W-1:0] tile_pixel_base_ext = tile_pixel_base[OFM_ADDR_W-1:0];
    wire [COLS*2*MULT_W-1:0] quant_mult_flat;
    wire [COLS*2*SHIFT_W-1:0] quant_shift_flat;
    wire [COLS*2*ZP_W-1:0] quant_zp_flat;
    reg [5:0] cfg_quant_addr;
    reg [7:0] cfg_lut_addr;
    reg [31:0] quant_shadow [0:COLS*2-1];
    reg [7:0] lut_shadow [0:255];
    wire cfg_quant_wr_en = cfg_wr_en && (cfg_addr == 6'h21);
    wire cfg_lut_wr_en = cfg_wr_en && (cfg_addr == 6'h23);
    wire merged_quant_wr_en = cfg_quant_wr_en || quant_wr_en;
    wire [5:0] merged_quant_wr_addr = cfg_quant_wr_en ? cfg_quant_addr : quant_wr_addr;
    wire [31:0] merged_quant_wr_data = cfg_quant_wr_en ? cfg_wdata : quant_wr_data;
    wire [31:0] quant_rd_data_int;
    wire merged_act_lut_wr_en = cfg_lut_wr_en || act_lut_wr_en;
    wire [7:0] merged_act_lut_wr_addr = cfg_lut_wr_en ? cfg_lut_addr : act_lut_wr_addr;
    wire [7:0] merged_act_lut_wr_data = cfg_lut_wr_en ? cfg_wdata[7:0] : act_lut_wr_data;

    integer lut_i;

    assign configured_cout_total = cout_total;
    assign configured_num_pixels = num_pixels;
    assign configured_input_zero_point = input_zero_point;
    assign configured_ofm_w = ofm_w;
    assign configured_pool_enable = pool_enable;
    assign configured_pool_stride = pool_stride;
    assign quant_rd_data = quant_rd_data_int;
    assign cfg_rdata = (cfg_addr == 6'h20) ? {26'd0, cfg_quant_addr} :
                       (cfg_addr == 6'h21) ? quant_shadow[cfg_quant_addr] :
                       (cfg_addr == 6'h22) ? {24'd0, cfg_lut_addr} :
                       (cfg_addr == 6'h23) ? {24'd0, lut_shadow[cfg_lut_addr]} :
                       layer_cfg_rdata;

    always @(posedge clk) begin
        if (rst) begin
            cfg_quant_addr <= 6'd0;
            cfg_lut_addr <= 8'd0;
            for (lut_i = 0; lut_i < COLS*2; lut_i = lut_i + 1)
                quant_shadow[lut_i] <= {8'd0, 4'd0, {SHIFT_W{1'b0}}, {{(MULT_W-1){1'b0}}, 1'b1}};
            for (lut_i = 0; lut_i < 256; lut_i = lut_i + 1)
                lut_shadow[lut_i] <= lut_i[7:0];
        end else begin
            if (cfg_wr_en && cfg_addr == 6'h20)
                cfg_quant_addr <= cfg_wdata[5:0];
            if (cfg_wr_en && cfg_addr == 6'h22)
                cfg_lut_addr <= cfg_wdata[7:0];
            if (merged_quant_wr_en)
                quant_shadow[merged_quant_wr_addr] <= merged_quant_wr_data;
            if (merged_act_lut_wr_en)
                lut_shadow[merged_act_lut_wr_addr] <= merged_act_lut_wr_data;
        end
    end

    layer_config_regs u_cfg (
        .clk(clk), .rst(rst),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_rd_en(cfg_rd_en), .cfg_rdata(layer_cfg_rdata),
        .layer_busy(layer_busy), .layer_done(layer_done),
        .dbg_expected_bytes(debug_expected_bytes),
        .dbg_core_wr_count(debug_core_wr_count),
        .dbg_axis_wr_count(debug_axis_wr_count),
        .dbg_tlast_count(debug_tlast_count),
        .dbg_last_tlast_index(debug_last_tlast_index),
        .start_pulse(start_pulse),
        .fm_h(fm_h), .fm_w(fm_w), .ofm_h(ofm_h), .ofm_w(ofm_w),
        .conv_stride(conv_stride), .conv_pad(conv_pad),
        .activation_mode(activation_mode),
        .k_total(k_total), .cout_total(cout_total), .num_pixels(num_pixels),
        .tile_oy_base(tile_oy_base), .tile_ofm_h(tile_ofm_h),
        .tile_pixel_base(tile_pixel_base),
        .input_zero_point(input_zero_point),
        .pool_enable(pool_enable), .pool_stride(pool_stride)
    );

    quant_param_regs #(
        .COUT_TILE(COLS*2), .MULT_W(MULT_W), .SHIFT_W(SHIFT_W), .ZP_W(ZP_W), .ADDR_W(6)
    ) u_quant (
        .clk(clk), .rst(rst),
        .wr_en(merged_quant_wr_en), .wr_addr(merged_quant_wr_addr), .wr_data(merged_quant_wr_data),
        .rd_addr(quant_rd_addr), .rd_data(quant_rd_data_int),
        .mult_flat(quant_mult_flat), .shift_flat(quant_shift_flat), .zp_flat(quant_zp_flat)
    );

    conv_layer_top_stream #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WEIGHT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_FIFO_DEPTH), .IFM_FIFO_AW(IFM_FIFO_AW),
        .WGT_FIFO_DEPTH(WGT_FIFO_DEPTH), .WGT_FIFO_AW(WGT_FIFO_AW),
        .PSUM_FIFO_DEPTH(PSUM_FIFO_DEPTH), .PSUM_FIFO_AW(PSUM_FIFO_AW),
        .FM_W_MAX(FM_W_MAX), .FM_H_MAX(FM_H_MAX),
        .K_TILE(K_TILE), .COUT_TILE(COUT_TILE), .IFM_BANKS(IFM_BANKS),
        .WGT_TILE_AW(WGT_TILE_AW), .PSUM_BUF_AW(PSUM_BUF_AW), .PSUM_BUF_DEPTH(PSUM_BUF_DEPTH),
        .MULT_W(MULT_W), .SHIFT_W(SHIFT_W), .ZP_W(ZP_W),
        .OFM_ADDR_W(OFM_ADDR_W), .OFM_FIFO_DEPTH(OFM_FIFO_DEPTH), .OFM_FIFO_AW(OFM_FIFO_AW)
    ) u_layer (
        .clk(clk), .rst(rst), .start(start_pulse), .busy(layer_busy), .done(layer_done),
        .fm_h(fm_h), .fm_w(fm_w), .ofm_h(ofm_h), .ofm_w(ofm_w),
        .conv_stride(conv_stride), .conv_pad(conv_pad),
        .k_total(k_total), .cout_total(cout_total), .num_pixels(num_pixels),
        .tile_oy_base(tile_oy_base), .tile_ofm_h(tile_ofm_h),
        .tile_pixel_base(tile_pixel_base_ext),
        .pool_enable(pool_enable), .pool_stride(pool_stride),
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
        .activation_mode(activation_mode), .act_lut_wr_en(merged_act_lut_wr_en),
        .act_lut_wr_addr(merged_act_lut_wr_addr), .act_lut_wr_data(merged_act_lut_wr_data),
        .ofm_valid(), .ofm_addr(), .ofm_cout_base(), .ofm_channel_valid(), .ofm_data(),
        .ofm_mem_wr_en(ofm_mem_wr_en), .ofm_mem_wr_ready(ofm_mem_wr_ready),
        .ofm_mem_wr_addr(ofm_mem_wr_addr),
        .ofm_mem_wr_data(ofm_mem_wr_data), .ofm_packet_full(ofm_packet_full)
    );
endmodule

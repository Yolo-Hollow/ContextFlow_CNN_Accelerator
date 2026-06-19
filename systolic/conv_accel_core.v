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
`ifndef SYSTOLIC_TAIL_CYCLES_CONFIG
`define SYSTOLIC_TAIL_CYCLES_CONFIG 0
`endif

module conv_accel_core #(
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
    parameter TAIL_CYCLES_CONFIG = `SYSTOLIC_TAIL_CYCLES_CONFIG,
    parameter [15:0] RAW_HWC_COMPUTE_START_LEVEL = 16'd0
) (
    input  clk,
    input  rst,

    input         cfg_wr_en,
    input  [6:0]  cfg_addr,
    input  [31:0] cfg_wdata,
    input         cfg_rd_en,
    output [31:0] cfg_rdata,

    output bias_load_req,
    input  bias_load_done,
    output [10:0] current_cout_base,
    output [13:0] current_pass_base_k,
    output [13:0] current_feeder_pass_base_k,
    output [10:0] configured_cout_total,
    output [13:0] configured_k_total,
    output [15:0] configured_num_pixels,
    output [7:0]  configured_input_zero_point,
    output [8:0]  configured_fm_h,
    output [8:0]  configured_fm_w,
    output [8:0]  configured_ofm_w,
    output [8:0]  configured_tile_oy_base,
    output [8:0]  configured_tile_ofm_h,
    output [1:0]  configured_conv_stride,
    output [1:0]  configured_conv_pad,
    output        configured_kernel_1x1,
    output        configured_pool_enable,
    output [1:0]  configured_pool_stride,
    output [31:0] configured_expected_bytes,
    output        configured_stream_batch_mode,
    output        configured_stream_raw_hwc_mode,
    output [31:0] configured_stream_bias_packets,
    output [31:0] configured_stream_weight_packets,
    output [31:0] configured_stream_ifm_packets,
    output        configured_stream_reset,
    input  [31:0] debug_expected_bytes,
    input  [31:0] debug_core_wr_count,
    input  [31:0] debug_axis_wr_count,
    input  [31:0] debug_tlast_count,
    input  [31:0] debug_last_tlast_index,
    input  [31:0] stream_bias_completed,
    input  [31:0] stream_weight_completed,
    input  [31:0] stream_ifm_completed,
    input  [31:0] vector_completed_packets,
    input  [31:0] vector_completed_pixels,
    input  [31:0] vector_accepted_beats,
    input  [31:0] vector_fifo_stall_cycles,
    input  [31:0] raw_hwc_load_active_cycles,
    input  [31:0] raw_hwc_load_unpack_cycles,
    input  [31:0] raw_hwc_replay_active_cycles,
    input  [31:0] raw_hwc_replay_wait_ready_cycles,
    output        configured_config_error,

    input  [5:0]        bias_wr_addr,
    input  [PSUM_W-1:0] bias_wr_data,
    input               bias_wr_en,

    output weight_load_req,
    input  weight_tile_ready,
    input  wgt_tile_wr_en,
    input  [WGT_TILE_AW-1:0] wgt_tile_wr_addr,
    input  [WEIGHT_W-1:0]    wgt_tile_wr_data,
    input                    wgt_tile_wr8_en,
    input  [WGT_TILE_AW-1:0] wgt_tile_wr8_addr,
    input  [WEIGHT_W*8-1:0]  wgt_tile_wr8_data,
    input  [7:0]             wgt_tile_wr8_keep,

    output feeder_fill_req,
    output [8:0] feeder_fill_fy,
    input  [IFM_BANKS-1:0] dma_bank_wr_en,
    input  [8:0] dma_wr_x,
    input  [9:0] dma_wr_fy,
    input  [7:0] dma_wr_data [0:IFM_BANKS-1],
    input        dma_line_advance,
    input  [ROWS*IFM_W-1:0] vector_ifm_data,
    input                    vector_ifm_valid,
    output                   vector_ifm_ready,
    input                    vector_packet_done,

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
    wire layer_compute_fire;
    wire perf_stage_bias;
    wire perf_stage_weight;
    wire perf_stage_feeder;
    wire perf_stage_compute;
    wire perf_stage_drain;
    wire perf_stage_ofm_post;
    wire perf_feed_fill_wait;
    wire perf_feed_push;
    wire perf_feed_fifo_stall;
    wire perf_feed_win_not_ready;
    wire perf_comp_wload;
    wire perf_comp_active;
    wire perf_comp_ifm_stall;
    wire perf_comp_tail;
    wire [31:0] perf_tail_cycles_configured;
    wire perf_drain_fifo_empty_wait;
    wire perf_drain_fifo_empty_sticky;
    wire perf_drain_read_fire;
    wire perf_drain_packet_fire;
    wire perf_drain_ready_stall;
    wire perf_drain_internal_full_wait;
    wire perf_prefetch_start;
    wire perf_prefetch_weight_done;
    wire perf_prefetch_feed_done;
    wire perf_prefetch_hit;
    wire perf_prefetch_miss;
    wire perf_prefetch_stall;
    wire perf_psumovl_start;
    wire perf_psumovl_hit;
    wire perf_psumovl_wait_psum;
    wire perf_psumovl_underflow;
    wire perf_collect_packet_fire;
    wire perf_collect_partial_write;
    wire perf_collect_final_write;
    wire perf_collect_context_push;
    wire perf_collect_context_pop;
    wire perf_collect_context_full_stall;
    wire perf_collect_column_empty_wait;
    wire [31:0] perf_pass_count;
    wire [31:0] perf_pass_start_to_first_fire;
    wire [31:0] perf_pass_first_to_last_fire;
    wire [31:0] perf_pass_last_fire_to_done;
    wire [31:0] perf_pass_collect_first_wait;
    wire [31:0] perf_pass_collect_column_empty;
    wire [31:0] perf_pass_replay_active_during_compute;
    wire [31:0] perf_pass_compute_idle_in_stage;
    wire [31:0] pass_trace_weight_done;
    wire [31:0] pass_trace_feed_start;
    wire [31:0] pass_trace_feed_ready;
    wire [31:0] pass_trace_feed_done;
    wire [31:0] pass_trace_compute_start;
    wire [31:0] pass_trace_first_fire;
    wire [31:0] pass_trace_last_fire;
    wire [31:0] pass_trace_compute_done;
    wire [31:0] pass_trace_collect_first;
    wire [31:0] pass_trace_collect_last;
    wire [31:0] pass_trace_pass_done;
    wire pass_trace_valid;
    wire [31:0] col_trace_first_wr;
    wire [31:0] col_trace_last_wr;
    wire [31:0] col_trace_wr_count;
    wire [31:0] col_trace_empty_wait;
    wire [31:0] col_trace_missing_mask_or;
    wire [31:0] col_trace_missing_mask_first;
    wire [31:0] col_trace_missing_mask_last;
    wire col_trace_valid;
    wire pass_trace_enable;
    wire [7:0] pass_trace_cout_block;
    wire [15:0] pass_trace_k_pass;
    wire [4:0] col_trace_selected_col;
    wire [31:0] layer_cfg_rdata;
    wire [8:0] fm_h;
    wire [8:0] fm_w;
    wire [8:0] ofm_h;
    wire [8:0] ofm_w;
    wire [1:0] conv_stride;
    wire [1:0] conv_pad;
    wire kernel_1x1;
    wire [1:0] activation_mode;
    wire [13:0] k_total;
    wire [10:0] cout_total;
    wire [15:0] num_pixels;
    wire [8:0] tile_oy_base;
    wire [8:0] tile_ofm_h;
    wire [23:0] tile_pixel_base;
    wire [7:0] input_zero_point;
    wire pool_enable;
    wire [1:0] pool_stride;
    wire [31:0] expected_bytes;
    wire stream_batch_mode;
    wire stream_raw_hwc_mode;
    wire early_drain_enable;
    wire pass_prefetch_enable;
    wire psum_stream_overlap_enable;
    wire continuous_psum_enable;
    wire column_psum_enable;
    wire during_compute_prefetch_enable;
    wire [31:0] stream_bias_packets;
    wire [31:0] stream_weight_packets;
    wire [31:0] stream_ifm_packets;
    wire [15:0] tail_cycles_config;
    wire [15:0] raw_hwc_compute_start_level;
    wire config_error;
    reg [31:0] raw_hwc_replay_active_cycles_q;
    wire raw_hwc_replay_active_event =
        raw_hwc_replay_active_cycles != raw_hwc_replay_active_cycles_q;
    wire [OFM_ADDR_W-1:0] tile_pixel_base_ext = tile_pixel_base[OFM_ADDR_W-1:0];
    wire [COLS*2*MULT_W-1:0] quant_mult_flat;
    wire [COLS*2*SHIFT_W-1:0] quant_shift_flat;
    wire [COLS*2*ZP_W-1:0] quant_zp_flat;
    reg [5:0] cfg_quant_addr;
    reg [7:0] cfg_lut_addr;
    reg [31:0] quant_shadow [0:COLS*2-1];
    reg [7:0] lut_shadow [0:255];
    wire cfg_quant_wr_en = cfg_wr_en && (cfg_addr == 7'h21);
    wire cfg_lut_wr_en = cfg_wr_en && (cfg_addr == 7'h23);
    wire merged_quant_wr_en = cfg_quant_wr_en || quant_wr_en;
    wire [5:0] merged_quant_wr_addr = cfg_quant_wr_en ? cfg_quant_addr : quant_wr_addr;
    wire [31:0] merged_quant_wr_data = cfg_quant_wr_en ? cfg_wdata : quant_wr_data;
    wire [31:0] quant_rd_data_int;
    wire merged_act_lut_wr_en = cfg_lut_wr_en || act_lut_wr_en;
    wire [7:0] merged_act_lut_wr_addr = cfg_lut_wr_en ? cfg_lut_addr : act_lut_wr_addr;
    wire [7:0] merged_act_lut_wr_data = cfg_lut_wr_en ? cfg_wdata[7:0] : act_lut_wr_data;

    integer lut_i;

    always @(posedge clk) begin
        if (rst)
            raw_hwc_replay_active_cycles_q <= 32'd0;
        else
            raw_hwc_replay_active_cycles_q <= raw_hwc_replay_active_cycles;
    end

    assign configured_cout_total = cout_total;
    assign configured_k_total = k_total;
    assign configured_num_pixels = num_pixels;
    assign configured_input_zero_point = input_zero_point;
    assign configured_fm_h = fm_h;
    assign configured_fm_w = fm_w;
    assign configured_ofm_w = ofm_w;
    assign configured_tile_oy_base = tile_oy_base;
    assign configured_tile_ofm_h = tile_ofm_h;
    assign configured_conv_stride = conv_stride;
    assign configured_conv_pad = conv_pad;
    assign configured_kernel_1x1 = kernel_1x1;
    assign configured_pool_enable = pool_enable;
    assign configured_pool_stride = pool_stride;
    assign configured_expected_bytes = expected_bytes;
    assign configured_stream_batch_mode = stream_batch_mode;
    assign configured_stream_raw_hwc_mode = stream_raw_hwc_mode;
    assign configured_stream_bias_packets = stream_bias_packets;
    assign configured_stream_weight_packets = stream_weight_packets;
    assign configured_stream_ifm_packets = stream_ifm_packets;
    assign configured_stream_reset = start_pulse;
    assign configured_config_error = config_error;
    assign quant_rd_data = quant_rd_data_int;
    assign cfg_rdata = (cfg_addr == 7'h20) ? {26'd0, cfg_quant_addr} :
                       (cfg_addr == 7'h21) ? quant_shadow[cfg_quant_addr] :
                       (cfg_addr == 7'h22) ? {24'd0, cfg_lut_addr} :
                       (cfg_addr == 7'h23) ? {24'd0, lut_shadow[cfg_lut_addr]} :
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
            if (cfg_wr_en && cfg_addr == 7'h20)
                cfg_quant_addr <= cfg_wdata[5:0];
            if (cfg_wr_en && cfg_addr == 7'h22)
                cfg_lut_addr <= cfg_wdata[7:0];
            if (merged_quant_wr_en)
                quant_shadow[merged_quant_wr_addr] <= merged_quant_wr_data;
            if (merged_act_lut_wr_en)
                lut_shadow[merged_act_lut_wr_addr] <= merged_act_lut_wr_data;
        end
    end

    layer_config_regs #(
        .IFM_FIFO_DEPTH(IFM_FIFO_DEPTH),
        .RAW_HWC_COMPUTE_START_LEVEL(RAW_HWC_COMPUTE_START_LEVEL)
    ) u_cfg (
        .clk(clk), .rst(rst),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_rd_en(cfg_rd_en), .cfg_rdata(layer_cfg_rdata),
        .layer_busy(layer_busy), .layer_done(layer_done),
        .dbg_expected_bytes(debug_expected_bytes),
        .dbg_core_wr_count(debug_core_wr_count),
        .dbg_axis_wr_count(debug_axis_wr_count),
        .dbg_tlast_count(debug_tlast_count),
        .dbg_last_tlast_index(debug_last_tlast_index),
        .perf_wait_bias(bias_load_req),
        .perf_wait_weight(weight_load_req),
        .perf_wait_ifm(feeder_fill_req),
        .perf_wait_ofm(ofm_packet_full),
        .perf_compute_fire(layer_compute_fire),
        .perf_stage_bias(perf_stage_bias),
        .perf_stage_weight(perf_stage_weight),
        .perf_stage_feeder(perf_stage_feeder),
        .perf_stage_compute(perf_stage_compute),
        .perf_stage_drain(perf_stage_drain),
        .perf_stage_ofm_post(perf_stage_ofm_post),
        .perf_feed_fill_wait(perf_feed_fill_wait),
        .perf_feed_push(perf_feed_push),
        .perf_feed_fifo_stall(perf_feed_fifo_stall),
        .perf_feed_win_not_ready(perf_feed_win_not_ready),
        .perf_comp_wload(perf_comp_wload),
        .perf_comp_active(perf_comp_active),
        .perf_comp_ifm_stall(perf_comp_ifm_stall),
        .perf_comp_tail(perf_comp_tail),
        .perf_tail_cycles_configured(perf_tail_cycles_configured),
        .perf_drain_fifo_empty_wait(perf_drain_fifo_empty_wait),
        .perf_drain_fifo_empty_sticky(perf_drain_fifo_empty_sticky),
        .perf_drain_read_fire(perf_drain_read_fire),
        .perf_drain_packet_fire(perf_drain_packet_fire),
        .perf_drain_ready_stall(perf_drain_ready_stall),
        .perf_drain_internal_full_wait(perf_drain_internal_full_wait),
        .perf_prefetch_start(perf_prefetch_start),
        .perf_prefetch_weight_done(perf_prefetch_weight_done),
        .perf_prefetch_feed_done(perf_prefetch_feed_done),
        .perf_prefetch_hit(perf_prefetch_hit),
        .perf_prefetch_miss(perf_prefetch_miss),
        .perf_prefetch_stall(perf_prefetch_stall),
        .perf_psumovl_start(perf_psumovl_start),
        .perf_psumovl_hit(perf_psumovl_hit),
        .perf_psumovl_wait_psum(perf_psumovl_wait_psum),
        .perf_psumovl_underflow(perf_psumovl_underflow),
        .perf_collect_packet_fire(perf_collect_packet_fire),
        .perf_collect_partial_write(perf_collect_partial_write),
        .perf_collect_final_write(perf_collect_final_write),
        .perf_collect_context_push(perf_collect_context_push),
        .perf_collect_context_pop(perf_collect_context_pop),
        .perf_collect_context_full_stall(perf_collect_context_full_stall),
        .perf_collect_column_empty_wait(perf_collect_column_empty_wait),
        .perf_pass_count(perf_pass_count),
        .perf_pass_start_to_first_fire(perf_pass_start_to_first_fire),
        .perf_pass_first_to_last_fire(perf_pass_first_to_last_fire),
        .perf_pass_last_fire_to_done(perf_pass_last_fire_to_done),
        .perf_pass_collect_first_wait(perf_pass_collect_first_wait),
        .perf_pass_collect_column_empty(perf_pass_collect_column_empty),
        .perf_pass_replay_active_during_compute(perf_pass_replay_active_during_compute),
        .perf_pass_compute_idle_in_stage(perf_pass_compute_idle_in_stage),
        .pass_trace_weight_done(pass_trace_weight_done),
        .pass_trace_feed_start(pass_trace_feed_start),
        .pass_trace_feed_ready(pass_trace_feed_ready),
        .pass_trace_feed_done(pass_trace_feed_done),
        .pass_trace_compute_start(pass_trace_compute_start),
        .pass_trace_first_fire(pass_trace_first_fire),
        .pass_trace_last_fire(pass_trace_last_fire),
        .pass_trace_compute_done(pass_trace_compute_done),
        .pass_trace_collect_first(pass_trace_collect_first),
        .pass_trace_collect_last(pass_trace_collect_last),
        .pass_trace_pass_done(pass_trace_pass_done),
        .pass_trace_valid(pass_trace_valid),
        .col_trace_first_wr(col_trace_first_wr),
        .col_trace_last_wr(col_trace_last_wr),
        .col_trace_wr_count(col_trace_wr_count),
        .col_trace_empty_wait(col_trace_empty_wait),
        .col_trace_missing_mask_or(col_trace_missing_mask_or),
        .col_trace_missing_mask_first(col_trace_missing_mask_first),
        .col_trace_missing_mask_last(col_trace_missing_mask_last),
        .col_trace_valid(col_trace_valid),
        .stream_bias_completed(stream_bias_completed),
        .stream_weight_completed(stream_weight_completed),
        .stream_ifm_completed(stream_ifm_completed),
        .vector_completed_packets(vector_completed_packets),
        .vector_completed_pixels(vector_completed_pixels),
        .vector_accepted_beats(vector_accepted_beats),
        .vector_fifo_stall_cycles(vector_fifo_stall_cycles),
        .raw_hwc_load_active_cycles(raw_hwc_load_active_cycles),
        .raw_hwc_load_unpack_cycles(raw_hwc_load_unpack_cycles),
        .raw_hwc_replay_active_cycles(raw_hwc_replay_active_cycles),
        .raw_hwc_replay_wait_ready_cycles(raw_hwc_replay_wait_ready_cycles),
        .start_pulse(start_pulse),
        .fm_h(fm_h), .fm_w(fm_w), .ofm_h(ofm_h), .ofm_w(ofm_w),
        .conv_stride(conv_stride), .conv_pad(conv_pad), .kernel_1x1(kernel_1x1),
        .activation_mode(activation_mode),
        .k_total(k_total), .cout_total(cout_total), .num_pixels(num_pixels),
        .tile_oy_base(tile_oy_base), .tile_ofm_h(tile_ofm_h),
        .tile_pixel_base(tile_pixel_base),
        .input_zero_point(input_zero_point),
        .pool_enable(pool_enable), .pool_stride(pool_stride),
        .expected_bytes(expected_bytes),
        .stream_batch_mode(stream_batch_mode),
        .stream_raw_hwc_mode(stream_raw_hwc_mode),
        .early_drain_enable(early_drain_enable),
        .pass_prefetch_enable(pass_prefetch_enable),
        .psum_stream_overlap_enable(psum_stream_overlap_enable),
        .continuous_psum_enable(continuous_psum_enable),
        .column_psum_enable(column_psum_enable),
        .during_compute_prefetch_enable(during_compute_prefetch_enable),
        .stream_bias_packets(stream_bias_packets),
        .stream_weight_packets(stream_weight_packets),
        .stream_ifm_packets(stream_ifm_packets),
        .tail_cycles_config(tail_cycles_config),
        .raw_hwc_compute_start_level(raw_hwc_compute_start_level),
        .pass_trace_enable(pass_trace_enable),
        .pass_trace_cout_block(pass_trace_cout_block),
        .pass_trace_k_pass(pass_trace_k_pass),
        .col_trace_selected_col(col_trace_selected_col),
        .config_error(config_error)
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
        .OFM_ADDR_W(OFM_ADDR_W), .OFM_FIFO_DEPTH(OFM_FIFO_DEPTH), .OFM_FIFO_AW(OFM_FIFO_AW),
        .TAIL_CYCLES_CONFIG(TAIL_CYCLES_CONFIG)
    ) u_layer (
        .clk(clk), .rst(rst), .start(start_pulse), .busy(layer_busy), .done(layer_done),
        .perf_compute_fire(layer_compute_fire),
        .perf_stage_bias(perf_stage_bias),
        .perf_stage_weight(perf_stage_weight),
        .perf_stage_feeder(perf_stage_feeder),
        .perf_stage_compute(perf_stage_compute),
        .perf_stage_drain(perf_stage_drain),
        .perf_stage_ofm_post(perf_stage_ofm_post),
        .perf_feed_fill_wait(perf_feed_fill_wait),
        .perf_feed_push(perf_feed_push),
        .perf_feed_fifo_stall(perf_feed_fifo_stall),
        .perf_feed_win_not_ready(perf_feed_win_not_ready),
        .perf_comp_wload(perf_comp_wload),
        .perf_comp_active(perf_comp_active),
        .perf_comp_ifm_stall(perf_comp_ifm_stall),
        .perf_comp_tail(perf_comp_tail),
        .perf_tail_cycles_configured(perf_tail_cycles_configured),
        .perf_drain_fifo_empty_wait(perf_drain_fifo_empty_wait),
        .perf_drain_fifo_empty_sticky(perf_drain_fifo_empty_sticky),
        .perf_drain_read_fire(perf_drain_read_fire),
        .perf_drain_packet_fire(perf_drain_packet_fire),
        .perf_drain_ready_stall(perf_drain_ready_stall),
        .perf_drain_internal_full_wait(perf_drain_internal_full_wait),
        .perf_prefetch_start(perf_prefetch_start),
        .perf_prefetch_weight_done(perf_prefetch_weight_done),
        .perf_prefetch_feed_done(perf_prefetch_feed_done),
        .perf_prefetch_hit(perf_prefetch_hit),
        .perf_prefetch_miss(perf_prefetch_miss),
        .perf_prefetch_stall(perf_prefetch_stall),
        .perf_psumovl_start(perf_psumovl_start),
        .perf_psumovl_hit(perf_psumovl_hit),
        .perf_psumovl_wait_psum(perf_psumovl_wait_psum),
        .perf_psumovl_underflow(perf_psumovl_underflow),
        .perf_collect_packet_fire(perf_collect_packet_fire),
        .perf_collect_partial_write(perf_collect_partial_write),
        .perf_collect_final_write(perf_collect_final_write),
        .perf_collect_context_push(perf_collect_context_push),
        .perf_collect_context_pop(perf_collect_context_pop),
        .perf_collect_context_full_stall(perf_collect_context_full_stall),
        .perf_collect_column_empty_wait(perf_collect_column_empty_wait),
        .perf_pass_count(perf_pass_count),
        .perf_pass_start_to_first_fire(perf_pass_start_to_first_fire),
        .perf_pass_first_to_last_fire(perf_pass_first_to_last_fire),
        .perf_pass_last_fire_to_done(perf_pass_last_fire_to_done),
        .perf_pass_collect_first_wait(perf_pass_collect_first_wait),
        .perf_pass_collect_column_empty(perf_pass_collect_column_empty),
        .perf_pass_replay_active_during_compute(perf_pass_replay_active_during_compute),
        .perf_pass_compute_idle_in_stage(perf_pass_compute_idle_in_stage),
        .pass_trace_weight_done(pass_trace_weight_done),
        .pass_trace_feed_start(pass_trace_feed_start),
        .pass_trace_feed_ready(pass_trace_feed_ready),
        .pass_trace_feed_done(pass_trace_feed_done),
        .pass_trace_compute_start(pass_trace_compute_start),
        .pass_trace_first_fire(pass_trace_first_fire),
        .pass_trace_last_fire(pass_trace_last_fire),
        .pass_trace_compute_done(pass_trace_compute_done),
        .pass_trace_collect_first(pass_trace_collect_first),
        .pass_trace_collect_last(pass_trace_collect_last),
        .pass_trace_pass_done(pass_trace_pass_done),
        .pass_trace_valid(pass_trace_valid),
        .col_trace_first_wr(col_trace_first_wr),
        .col_trace_last_wr(col_trace_last_wr),
        .col_trace_wr_count(col_trace_wr_count),
        .col_trace_empty_wait(col_trace_empty_wait),
        .col_trace_missing_mask_or(col_trace_missing_mask_or),
        .col_trace_missing_mask_first(col_trace_missing_mask_first),
        .col_trace_missing_mask_last(col_trace_missing_mask_last),
        .col_trace_valid(col_trace_valid),
        .fm_h(fm_h), .fm_w(fm_w), .ofm_h(ofm_h), .ofm_w(ofm_w),
        .conv_stride(conv_stride), .conv_pad(conv_pad), .kernel_1x1(kernel_1x1),
        .stream_raw_hwc_mode(stream_raw_hwc_mode),
        .k_total(k_total), .cout_total(cout_total), .num_pixels(num_pixels),
        .tail_cycles_config(tail_cycles_config),
        .raw_hwc_compute_start_level(raw_hwc_compute_start_level),
        .early_drain_enable(early_drain_enable),
        .pass_prefetch_enable(pass_prefetch_enable),
        .psum_stream_overlap_enable(psum_stream_overlap_enable),
        .continuous_psum_enable(continuous_psum_enable),
        .column_psum_enable(column_psum_enable),
        .during_compute_prefetch_enable(during_compute_prefetch_enable),
        .pass_trace_enable(pass_trace_enable),
        .pass_trace_cout_block(pass_trace_cout_block),
        .pass_trace_k_pass(pass_trace_k_pass),
        .col_trace_selected_col(col_trace_selected_col),
        .raw_replay_active(raw_hwc_replay_active_event),
        .tile_oy_base(tile_oy_base), .tile_ofm_h(tile_ofm_h),
        .tile_pixel_base(tile_pixel_base_ext),
        .pool_enable(pool_enable), .pool_stride(pool_stride),
        .bias_load_req(bias_load_req), .bias_load_done(bias_load_done),
        .current_cout_base(current_cout_base), .current_pass_base_k(current_pass_base_k),
        .current_feeder_pass_base_k(current_feeder_pass_base_k),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .weight_load_req(weight_load_req), .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en), .wgt_tile_wr_addr(wgt_tile_wr_addr),
        .wgt_tile_wr_data(wgt_tile_wr_data),
        .wgt_tile_wr8_en(wgt_tile_wr8_en), .wgt_tile_wr8_addr(wgt_tile_wr8_addr),
        .wgt_tile_wr8_data(wgt_tile_wr8_data), .wgt_tile_wr8_keep(wgt_tile_wr8_keep),
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .vector_ifm_data(vector_ifm_data), .vector_ifm_valid(vector_ifm_valid),
        .vector_ifm_ready(vector_ifm_ready), .vector_packet_done(vector_packet_done),
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

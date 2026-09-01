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
    parameter integer CLOCK_HZ = 100000000,
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
    parameter [15:0] RAW_HWC_COMPUTE_START_LEVEL = 16'd0,
    parameter ENABLE_COLUMN_PSUM = 0,
    parameter ENABLE_PACKED_HWC_OFM = 0,
    parameter ENABLE_LAYER_TILE_SEQUENCER = 0,
    parameter ENABLE_LAYER_LONG_HWC_IFM = 0,
    parameter ENABLE_TAGGED_CONTEXT = 0,
    parameter ENABLE_WEIGHT_PRELOAD = 0,
    parameter ENABLE_FAST_CONTEXT_HANDOFF = 0,
    parameter IFM_EPOCH_USE_URAM = 0,
    parameter ENABLE_DETAILED_TRACE = 1,
    parameter MATERIALIZED_CACHE_DEPTH = 32768,
    parameter integer LAYER_LONG_LINE_BANK_DEPTH = 2048,
    parameter PACKED_OFM_BUFFER_DEPTH = 4096
) (
    input  clk,
    input  rst,
    input  tile_start_ready,
    input  tile_retire_ready,

    input         cfg_wr_en,
    input  [7:0]  cfg_addr,
    input  [31:0] cfg_wdata,
    input         cfg_rd_en,
    output [31:0] cfg_rdata,

    output bias_load_req,
    input  bias_load_done,
    output [10:0] current_cout_base,
    output [13:0] current_pass_base_k,
    output [13:0] current_feeder_pass_base_k,
    output [15:0] current_feeder_k_pass,
    output [10:0] configured_cout_total,
    output [13:0] configured_k_total,
    output [15:0] configured_num_pixels,
    output [7:0]  configured_input_zero_point,
    output [8:0]  configured_fm_h,
    output [8:0]  configured_fm_w,
    output [8:0]  configured_ofm_h,
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
    output        configured_datapath_reset,
    output        configured_layer_last,
    output [8:0]  configured_tile_h_max,
    output [31:0] configured_ifm_total_bytes,
    output [31:0] configured_ofm_total_bytes,
    output [13:0] validated_long_cin,
    output [15:0] validated_long_pass_count,
    output [15:0] validated_long_final_pass,
    output [ROWS-1:0] validated_long_final_lane_mask,
    output [31:0] validated_long_layer_pixels,
    output [31:0] validated_long_tile_pixels,
    output [31:0] validated_long_tile_output_pixels,
    output [15:0] validated_long_cout_blocks,
    output        active_tile_start,
    output        active_tile_last,
    output [8:0]  active_tile_oy_base,
    output [8:0]  active_tile_ofm_h,
    output [15:0] active_tile_num_pixels,
    output [15:0] active_tile_output_pixels,
    output [23:0] active_tile_output_pixel_base,
    output [15:0] active_tile_index,
    output        active_tile_done,
    input  [31:0] debug_expected_bytes,
    input  [31:0] debug_core_wr_count,
    input  [31:0] debug_axis_wr_count,
    input  [31:0] debug_tlast_count,
    input  [31:0] debug_last_tlast_index,
    input  [31:0] debug_packed_ofm_axis_byte_count,
    input  [31:0] debug_packed_ofm_axis_stall_cycles,
    input         debug_packed_ofm_protocol_error,
    input  [31:0] external_datapath_error_status,
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
    output                      ofm_packet_full,

    output                      packed_ofm_packet_valid,
    input                       packed_ofm_packet_ready,
    output [PSUM_BUF_AW-1:0]    packed_ofm_packet_pixel,
    output [10:0]               packed_ofm_packet_cout_base,
    output [COLS*2-1:0]         packed_ofm_packet_channel_valid,
    output [COLS*2*8-1:0]       packed_ofm_packet_data,
    input                       packed_ofm_busy
);
    wire start_pulse;
    wire datapath_reset_active;
    wire datapath_rst = rst || datapath_reset_active;
    wire layer_busy;
    wire layer_done;
    wire tile_engine_busy;
    wire tile_engine_done;
    reg tile_retire_pending;
    wire tile_retire_ready_effective =
        (ENABLE_LAYER_LONG_HWC_IFM != 0) ? tile_retire_ready : 1'b1;
    wire tile_retire_fire =
        (tile_engine_done || tile_retire_pending) &&
        tile_retire_ready_effective;
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
    wire [31:0] datapath_error_status;
    wire [31:0] tile_engine_datapath_error_status;
    wire [31:0] context_alloc_count;
    wire [31:0] context_input_issued_count;
    wire [31:0] context_array_retired_count;
    wire [31:0] context_collector_done_count;
    wire [31:0] context_gap_cycles;
    wire [31:0] context_ifm_ownership_stall_cycles;
    wire [31:0] context_weight_ownership_stall_cycles;
    wire [31:0] context_psum_credit_stall_cycles;
    wire [31:0] context_epoch_mismatch_count;
    wire [31:0] context_mismatch_count;
    // The aggregate mismatch counter is telemetry only.  Register it at the
    // configuration boundary so the frontend's event/count cone cannot run
    // directly into the wide AXI-Lite readback mux.  Software observes the
    // same monotonic value with a one-clock diagnostic latency.
    reg [31:0] context_mismatch_count_readback_q;
    wire [31:0] context_ifm_underflow_count;
    wire [31:0] context_psum_underflow_count;
    wire [31:0] context_fifo_drop_count;
    wire [31:0] context_bank_overwrite_count;
    wire [31:0] context_full_stall_cycles;
    wire [31:0] compute_pipe_compute_gap_count;
    wire [31:0] compute_pipe_preload_commit_count;
    wire [31:0] compute_pipe_preload_hit_count;
    wire [31:0] compute_pipe_preload_miss_count;
    wire [31:0] compute_pipe_eligible_handoff_count;
    wire [31:0] compute_pipe_next_cycle_hit_count;
    wire [31:0] compute_pipe_extra_gap_count;
    wire [31:0] compute_pipe_wait_bank_retire_count;
    wire [31:0] compute_pipe_wait_weight_count;
    wire [31:0] compute_pipe_wait_ifm_count;
    wire [31:0] compute_pipe_wait_psum_count;
    wire [31:0] compute_pipe_wait_collector_output_count;
    wire [31:0] compute_pipe_wait_control_count;
    wire [31:0] compute_pipe_protocol_error_count;
    // Keep the ABI-v2 telemetry deterministic in legacy builds.  Several
    // non-AXIS wrappers intentionally omit these packed-only debug pins.
    wire [31:0] packed_ofm_axis_byte_count_visible =
        (ENABLE_PACKED_HWC_OFM != 0) ?
        debug_packed_ofm_axis_byte_count : 32'd0;
    wire [31:0] packed_ofm_axis_stall_cycles_visible =
        (ENABLE_PACKED_HWC_OFM != 0) ?
        debug_packed_ofm_axis_stall_cycles : 32'd0;
    wire packed_ofm_protocol_error_visible =
        (ENABLE_PACKED_HWC_OFM != 0) ?
        debug_packed_ofm_protocol_error : 1'b0;
    wire [31:0] external_datapath_error_status_visible =
        (ENABLE_LAYER_LONG_HWC_IFM != 0) ?
        external_datapath_error_status : 32'd0;
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
    wire [COLS*2*MULT_W-1:0] quant_mult_flat;
    wire [COLS*2*SHIFT_W-1:0] quant_shift_flat;
    wire [COLS*2*ZP_W-1:0] quant_zp_flat;
    reg [5:0] cfg_quant_addr;
    reg [7:0] cfg_lut_addr;
    wire cfg_quant_wr_en = cfg_wr_en && (cfg_addr == 7'h21);
    wire cfg_lut_wr_en = cfg_wr_en && (cfg_addr == 7'h23);
    wire merged_quant_wr_en = cfg_quant_wr_en || quant_wr_en;
    wire [5:0] merged_quant_wr_addr = cfg_quant_wr_en ? cfg_quant_addr : quant_wr_addr;
    wire [31:0] merged_quant_wr_data = cfg_quant_wr_en ? cfg_wdata : quant_wr_data;
    wire [31:0] quant_rd_data_int;
    wire [MULT_W-1:0] cfg_quant_mult =
        quant_mult_flat[cfg_quant_addr*MULT_W +: MULT_W];
    wire [SHIFT_W-1:0] cfg_quant_shift =
        quant_shift_flat[cfg_quant_addr*SHIFT_W +: SHIFT_W];
    wire [ZP_W-1:0] cfg_quant_zp =
        quant_zp_flat[cfg_quant_addr*ZP_W +: ZP_W];
    wire [31:0] cfg_quant_rd_data = {
        cfg_quant_zp, 4'd0, cfg_quant_shift, cfg_quant_mult
    };
    wire merged_act_lut_wr_en = cfg_lut_wr_en || act_lut_wr_en;
    wire [7:0] merged_act_lut_wr_addr = cfg_lut_wr_en ? cfg_lut_addr : act_lut_wr_addr;
    wire [7:0] merged_act_lut_wr_data = cfg_lut_wr_en ? cfg_wdata[7:0] : act_lut_wr_data;
    wire [7:0] actual_act_lut_rd_data;

    // The compute engine reports a one-cycle done pulse.  A layer-long cache
    // release may take arbitrarily many cycles, so retain the retirement
    // request until its owner-scoreboard handshake completes.  Legacy builds
    // use a constant-ready path and preserve same-cycle completion.
    always @(posedge clk) begin
        if (datapath_rst) begin
            tile_retire_pending <= 1'b0;
        end else if (tile_retire_fire) begin
            tile_retire_pending <= 1'b0;
        end else if (tile_engine_done) begin
            tile_retire_pending <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (datapath_rst)
            raw_hwc_replay_active_cycles_q <= 32'd0;
        else
            raw_hwc_replay_active_cycles_q <= raw_hwc_replay_active_cycles;
    end

    always @(posedge clk) begin
        if (datapath_rst)
            context_mismatch_count_readback_q <= 32'd0;
        else
            context_mismatch_count_readback_q <= context_mismatch_count;
    end

    assign configured_cout_total = cout_total;
    assign configured_k_total = k_total;
    assign configured_num_pixels = num_pixels;
    assign configured_input_zero_point = input_zero_point;
    assign configured_fm_h = fm_h;
    assign configured_fm_w = fm_w;
    assign configured_ofm_h = ofm_h;
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
    assign configured_datapath_reset = datapath_reset_active;
    wire sequenced_layer_busy;
    wire sequenced_layer_done;
    wire sequenced_tile_start;
    wire sequenced_tile_last;
    wire [8:0] sequenced_tile_oy_base;
    wire [8:0] sequenced_tile_ofm_h;
    wire [15:0] sequenced_tile_num_pixels;
    wire [15:0] sequenced_tile_output_pixels;
    wire [23:0] sequenced_tile_output_pixel_base;
    wire [15:0] sequenced_tile_index;
    wire [OFM_ADDR_W-1:0] sequenced_tile_pixel_base_ext =
        sequenced_tile_output_pixel_base[OFM_ADDR_W-1:0];
    wire sequencer_config_error;
    wire sequencer_protocol_error;
    wire [8:0] legacy_tile_h =
        (tile_ofm_h != 9'd0) ? tile_ofm_h : ofm_h;
    wire [17:0] legacy_pool_pixels_math =
        legacy_tile_h[8:1] * ofm_w[8:1];
    wire [15:0] legacy_tile_output_pixels =
        pool_enable && (pool_stride == 2'd2) ?
        legacy_pool_pixels_math[15:0] : num_pixels;

    generate
        if (ENABLE_LAYER_TILE_SEQUENCER != 0) begin : g_layer_tiles
            wire [31:0] tile_start_count_unused;
            wire [31:0] tile_done_count_unused;

            layer_tile_sequencer #(
                .MAX_TILE_PIXELS(PSUM_BUF_DEPTH),
                .COUT_TILE(COLS*2),
                .MAX_PACKED_ENTRIES(4096),
                .CFG_PREVALIDATED(ENABLE_LAYER_LONG_HWC_IFM != 0)
            ) u_tile_sequencer (
                .clk(clk), .rst(datapath_rst), .layer_start(start_pulse),
                .cfg_ofm_h(ofm_h), .cfg_ofm_w(ofm_w),
                .cfg_tile_h_max(configured_tile_h_max),
                .cfg_cout_total(cout_total),
                .cfg_pool_enable(pool_enable),
                .cfg_pool_stride(pool_stride),
                .cfg_prevalidated_tile_h(configured_tile_h_max),
                .cfg_prevalidated_tile_pixels(
                    validated_long_tile_pixels[15:0]),
                .cfg_prevalidated_tile_output_pixels(
                    validated_long_tile_output_pixels[15:0]),
                .cfg_prevalidated_cout_blocks(
                    validated_long_cout_blocks),
                .layer_busy(sequenced_layer_busy),
                .layer_done(sequenced_layer_done),
                .tile_start(sequenced_tile_start),
                .tile_start_ready(tile_start_ready),
                .tile_done(tile_retire_fire),
                .tile_oy_base(sequenced_tile_oy_base),
                .tile_ofm_h(sequenced_tile_ofm_h),
                .tile_num_pixels(sequenced_tile_num_pixels),
                .tile_output_pixels(sequenced_tile_output_pixels),
                .tile_output_pixel_base(
                    sequenced_tile_output_pixel_base),
                .tile_last(sequenced_tile_last),
                .tile_index(sequenced_tile_index),
                .config_error(sequencer_config_error),
                .protocol_error(sequencer_protocol_error),
                .tile_start_count(tile_start_count_unused),
                .tile_done_count(tile_done_count_unused)
            );
        end else begin : g_single_tile_legacy
            assign sequenced_layer_busy = tile_engine_busy;
            assign sequenced_layer_done = tile_retire_fire;
            assign sequenced_tile_start = start_pulse;
            assign sequenced_tile_last = configured_layer_last;
            assign sequenced_tile_oy_base = tile_oy_base;
            assign sequenced_tile_ofm_h = legacy_tile_h;
            assign sequenced_tile_num_pixels = num_pixels;
            assign sequenced_tile_output_pixels =
                legacy_tile_output_pixels;
            assign sequenced_tile_output_pixel_base = tile_pixel_base;
            assign sequenced_tile_index = 16'd0;
            assign sequencer_config_error = 1'b0;
            assign sequencer_protocol_error = 1'b0;
        end
    endgenerate

    assign layer_busy = sequenced_layer_busy;
    assign layer_done = sequenced_layer_done;
    assign active_tile_start = sequenced_tile_start;
    assign active_tile_last = sequenced_tile_last;
    assign active_tile_oy_base = sequenced_tile_oy_base;
    assign active_tile_ofm_h = sequenced_tile_ofm_h;
    assign active_tile_num_pixels = sequenced_tile_num_pixels;
    assign active_tile_output_pixels = sequenced_tile_output_pixels;
    assign active_tile_output_pixel_base =
        sequenced_tile_output_pixel_base;
    assign active_tile_index = sequenced_tile_index;
    assign active_tile_done = tile_engine_done;
    assign configured_config_error = config_error ||
                                     sequencer_config_error ||
                                     sequencer_protocol_error;
    assign datapath_error_status = tile_engine_datapath_error_status |
        {2'b00, sequencer_protocol_error, sequencer_config_error, 28'd0} |
        external_datapath_error_status_visible;
    assign quant_rd_data = quant_rd_data_int;
    assign cfg_rdata = (cfg_addr == 7'h20) ? {26'd0, cfg_quant_addr} :
                       (cfg_addr == 7'h21) ? cfg_quant_rd_data :
                       (cfg_addr == 7'h22) ? {24'd0, cfg_lut_addr} :
                       (cfg_addr == 7'h23) ? {24'd0, actual_act_lut_rd_data} :
                       layer_cfg_rdata;

    always @(posedge clk) begin
        if (rst) begin
            cfg_quant_addr <= 6'd0;
            cfg_lut_addr <= 8'd0;
        end else begin
            if (cfg_wr_en && cfg_addr == 7'h20)
                cfg_quant_addr <= cfg_wdata[5:0];
            if (cfg_wr_en && cfg_addr == 7'h22)
                cfg_lut_addr <= cfg_wdata[7:0];
        end
    end

    // Keep the new telemetry truthful while the optimized datapath event
    // interface is being integrated.  The compute-stage gap has an existing,
    // exact cycle-level definition.  The remaining events require explicit
    // pulses from the weight-preload/context-handoff path; they intentionally
    // read as zero until those signals cross the conv_layer_top_stream
    // boundary.  Do not infer them from cumulative context counters or alias
    // the older experimental prefetch telemetry, because that would make the
    // ABI counters look valid while measuring a different mechanism.
    compute_pipe_telemetry u_compute_pipe_telemetry (
        .clk(clk),
        .rst(rst),
        .soft_reset(datapath_reset_active),
        .compute_gap_pulse(perf_stage_compute && !layer_compute_fire),
        // TODO: replace the explicit zeros with dedicated event pulses from
        // the inactive-weight preload and fast-context handoff datapath.
        .preload_commit_pulse(1'b0),
        .preload_hit_pulse(1'b0),
        .preload_miss_pulse(1'b0),
        .eligible_handoff_pulse(1'b0),
        .next_cycle_hit_pulse(1'b0),
        .extra_gap_pulse(1'b0),
        .wait_reason_pulse(6'b000000),
        .protocol_error_pulse(1'b0),
        .compute_gap_count(compute_pipe_compute_gap_count),
        .preload_commit_count(compute_pipe_preload_commit_count),
        .preload_hit_count(compute_pipe_preload_hit_count),
        .preload_miss_count(compute_pipe_preload_miss_count),
        .eligible_handoff_count(compute_pipe_eligible_handoff_count),
        .next_cycle_hit_count(compute_pipe_next_cycle_hit_count),
        .extra_gap_count(compute_pipe_extra_gap_count),
        .wait_bank_retire_count(compute_pipe_wait_bank_retire_count),
        .wait_weight_count(compute_pipe_wait_weight_count),
        .wait_ifm_count(compute_pipe_wait_ifm_count),
        .wait_psum_count(compute_pipe_wait_psum_count),
        .wait_collector_output_count(
            compute_pipe_wait_collector_output_count),
        .wait_control_count(compute_pipe_wait_control_count),
        .protocol_error_count(compute_pipe_protocol_error_count)
    );

    layer_config_regs #(
        .CLOCK_HZ(CLOCK_HZ),
        .IFM_FIFO_DEPTH(IFM_FIFO_DEPTH),
        .RAW_HWC_COMPUTE_START_LEVEL(RAW_HWC_COMPUTE_START_LEVEL),
        .ENABLE_COLUMN_PSUM(ENABLE_COLUMN_PSUM),
        .ROWS(ROWS), .COLS(COLS), .COUT_TILE(COLS*2),
        .FM_W_MAX(FM_W_MAX),
        .FM_H_MAX(FM_H_MAX),
        .PSUM_BUF_DEPTH(PSUM_BUF_DEPTH),
        .MATERIALIZED_CACHE_DEPTH(MATERIALIZED_CACHE_DEPTH),
        .LAYER_LONG_LINE_BANK_DEPTH(LAYER_LONG_LINE_BANK_DEPTH),
        .PACKED_OFM_BUFFER_DEPTH(PACKED_OFM_BUFFER_DEPTH),
        .ENABLE_PACKED_HWC_OFM(ENABLE_PACKED_HWC_OFM),
        .ENABLE_LAYER_TILE_SEQUENCER(ENABLE_LAYER_TILE_SEQUENCER),
        .ENABLE_LAYER_LONG_HWC_IFM(ENABLE_LAYER_LONG_HWC_IFM),
        .ENABLE_TAGGED_CONTEXT(ENABLE_TAGGED_CONTEXT),
        .ENABLE_DETAILED_TRACE(ENABLE_DETAILED_TRACE),
        // Base feature flags describe the external HWC/packed/layer-long
        // interfaces.  layer_config_regs derives the authoritative context
        // flag directly from ENABLE_TAGGED_CONTEXT so it cannot be advertised
        // by stale caller-supplied metadata.
        .ABI_FEATURE_FLAGS(
            ((ENABLE_PACKED_HWC_OFM != 0) ? 8'h02 : 8'h00) |
            (((ENABLE_LAYER_LONG_HWC_IFM != 0) &&
              (ENABLE_LAYER_TILE_SEQUENCER != 0)) ? 8'h05 : 8'h00))
    ) u_cfg (
        .clk(clk), .rst(rst),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_rd_en(cfg_rd_en), .cfg_rdata(layer_cfg_rdata),
        .layer_busy(layer_busy), .layer_done(layer_done),
        .external_config_error(sequencer_config_error),
        .configured_layer_last(configured_layer_last),
        .configured_tile_h_max(configured_tile_h_max),
        .configured_ifm_total_bytes(configured_ifm_total_bytes),
        .configured_ofm_total_bytes(configured_ofm_total_bytes),
        .validated_long_cin(validated_long_cin),
        .validated_long_pass_count(validated_long_pass_count),
        .validated_long_final_pass(validated_long_final_pass),
        .validated_long_final_lane_mask(
            validated_long_final_lane_mask),
        .validated_long_layer_pixels(validated_long_layer_pixels),
        .validated_long_tile_pixels(validated_long_tile_pixels),
        .validated_long_tile_output_pixels(
            validated_long_tile_output_pixels),
        .validated_long_cout_blocks(validated_long_cout_blocks),
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
        .packed_ofm_axis_byte_count(packed_ofm_axis_byte_count_visible),
        .packed_ofm_axis_stall_cycles(packed_ofm_axis_stall_cycles_visible),
        .packed_ofm_protocol_error(packed_ofm_protocol_error_visible),
        .datapath_error_status(datapath_error_status),
        .context_alloc_count(context_alloc_count),
        .context_input_issued_count(context_input_issued_count),
        .context_array_retired_count(context_array_retired_count),
        .context_collector_done_count(context_collector_done_count),
        .context_gap_cycles(context_gap_cycles),
        .context_ifm_ownership_stall_cycles(context_ifm_ownership_stall_cycles),
        .context_weight_ownership_stall_cycles(context_weight_ownership_stall_cycles),
        .context_psum_credit_stall_cycles(context_psum_credit_stall_cycles),
        .context_epoch_mismatch_count(context_epoch_mismatch_count),
        .context_mismatch_count(context_mismatch_count_readback_q),
        .context_ifm_underflow_count(context_ifm_underflow_count),
        .context_psum_underflow_count(context_psum_underflow_count),
        .context_fifo_drop_count(context_fifo_drop_count),
        .context_bank_overwrite_count(context_bank_overwrite_count),
        .context_full_stall_cycles(context_full_stall_cycles),
        .compute_pipe_compute_gap_count(compute_pipe_compute_gap_count),
        .compute_pipe_preload_commit_count(
            compute_pipe_preload_commit_count),
        .compute_pipe_preload_hit_count(compute_pipe_preload_hit_count),
        .compute_pipe_preload_miss_count(compute_pipe_preload_miss_count),
        .compute_pipe_eligible_handoff_count(
            compute_pipe_eligible_handoff_count),
        .compute_pipe_next_cycle_hit_count(
            compute_pipe_next_cycle_hit_count),
        .compute_pipe_extra_gap_count(compute_pipe_extra_gap_count),
        .compute_pipe_wait_bank_retire_count(
            compute_pipe_wait_bank_retire_count),
        .compute_pipe_wait_weight_count(compute_pipe_wait_weight_count),
        .compute_pipe_wait_ifm_count(compute_pipe_wait_ifm_count),
        .compute_pipe_wait_psum_count(compute_pipe_wait_psum_count),
        .compute_pipe_wait_collector_output_count(
            compute_pipe_wait_collector_output_count),
        .compute_pipe_wait_control_count(compute_pipe_wait_control_count),
        .compute_pipe_protocol_error_count(
            compute_pipe_protocol_error_count),
        .start_pulse(start_pulse),
        .datapath_reset_active(datapath_reset_active),
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
        .TAIL_CYCLES_CONFIG(TAIL_CYCLES_CONFIG),
        .ENABLE_COLUMN_PSUM(ENABLE_COLUMN_PSUM),
        .ENABLE_PACKED_HWC_OFM(ENABLE_PACKED_HWC_OFM),
        .ENABLE_VECTOR_ONLY_IFM(ENABLE_LAYER_LONG_HWC_IFM),
        .ENABLE_TAGGED_CONTEXT(ENABLE_TAGGED_CONTEXT),
        .ENABLE_WEIGHT_PRELOAD(ENABLE_WEIGHT_PRELOAD),
        .ENABLE_FAST_CONTEXT_HANDOFF(ENABLE_FAST_CONTEXT_HANDOFF),
        .IFM_EPOCH_USE_URAM(IFM_EPOCH_USE_URAM),
        .ENABLE_DETAILED_TRACE(ENABLE_DETAILED_TRACE)
    ) u_layer (
        .clk(clk), .rst(datapath_rst), .start(sequenced_tile_start),
        .busy(tile_engine_busy), .done(tile_engine_done),
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
        .k_total(k_total), .cout_total(cout_total),
        .num_pixels(sequenced_tile_num_pixels),
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
        .tile_oy_base(sequenced_tile_oy_base),
        .tile_ofm_h(sequenced_tile_ofm_h),
        .tile_pixel_base(sequenced_tile_pixel_base_ext),
        .pool_enable(pool_enable), .pool_stride(pool_stride),
        .bias_load_req(bias_load_req), .bias_load_done(bias_load_done),
        .current_cout_base(current_cout_base), .current_pass_base_k(current_pass_base_k),
        .current_feeder_pass_base_k(current_feeder_pass_base_k),
        .current_feeder_k_pass(current_feeder_k_pass),
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
        .act_lut_rd_addr(cfg_lut_addr), .act_lut_rd_data(actual_act_lut_rd_data),
        .ofm_valid(), .ofm_addr(), .ofm_cout_base(), .ofm_channel_valid(), .ofm_data(),
        .ofm_mem_wr_en(ofm_mem_wr_en), .ofm_mem_wr_ready(ofm_mem_wr_ready),
        .ofm_mem_wr_addr(ofm_mem_wr_addr),
        .ofm_mem_wr_data(ofm_mem_wr_data), .ofm_packet_full(ofm_packet_full),
        .packed_ofm_packet_valid(packed_ofm_packet_valid),
        .packed_ofm_packet_ready(packed_ofm_packet_ready),
        .packed_ofm_packet_pixel(packed_ofm_packet_pixel),
        .packed_ofm_packet_cout_base(packed_ofm_packet_cout_base),
        .packed_ofm_packet_channel_valid(packed_ofm_packet_channel_valid),
        .packed_ofm_packet_data(packed_ofm_packet_data),
        .packed_ofm_busy(packed_ofm_busy),
        .datapath_error_status(tile_engine_datapath_error_status),
        .context_alloc_count(context_alloc_count),
        .context_input_issued_count(context_input_issued_count),
        .context_array_retired_count(context_array_retired_count),
        .context_collector_done_count(context_collector_done_count),
        .context_gap_cycles(context_gap_cycles),
        .ifm_ownership_stall_cycles(context_ifm_ownership_stall_cycles),
        .weight_ownership_stall_cycles(context_weight_ownership_stall_cycles),
        .psum_credit_stall_cycles(context_psum_credit_stall_cycles),
        .context_epoch_mismatch_count(context_epoch_mismatch_count),
        .context_mismatch_count(context_mismatch_count),
        .context_ifm_underflow_count(context_ifm_underflow_count),
        .context_psum_underflow_count(context_psum_underflow_count),
        .context_fifo_drop_count(context_fifo_drop_count),
        .context_bank_overwrite_count(context_bank_overwrite_count),
        .context_full_stall_cycles(context_full_stall_cycles)
    );
endmodule

`timescale 1ns / 1ps

// Composes the raw-HWC rolling-window materializer with the epoch-tagged
// wide-vector replay cache.  The interface is intentionally feeder-shaped so
// it can replace the legacy byte/scatter raw cache once the layer-long
// scheduler owns a 32-bit pixel count.
module axis_hwc_materialized_replay #(
    parameter integer ROWS = 18,
    parameter integer AXIS_W = 64,
    parameter integer KEEP_W = AXIS_W / 8,
    parameter integer MAX_FM_W = 416,
    parameter integer MAX_CHANNELS = 1024,
    parameter integer LINE_BANK_DEPTH = 320,
    parameter integer MAX_PASSES = 512,
    parameter integer EPOCH_W = 8,
    parameter integer CACHE_AW = 18,
    parameter integer CACHE_DEPTH = (1 << CACHE_AW)
) (
    input  wire                         clk,
    input  wire                         rst,

    input  wire                         cfg_start,
    input  wire [15:0]                  cfg_fm_h,
    input  wire [15:0]                  cfg_fm_w,
    input  wire [13:0]                  cfg_cin,
    input  wire [15:0]                  cfg_ofm_h,
    input  wire [15:0]                  cfg_ofm_w,
    input  wire                         cfg_kernel_1x1,
    input  wire [1:0]                   cfg_stride,
    input  wire [1:0]                   cfg_pad,
    input  wire [7:0]                   cfg_input_zero_point,
    input  wire [EPOCH_W-1:0]           cfg_epoch,

    output wire                         s_axis_tready,
    input  wire                         s_axis_tvalid,
    input  wire [AXIS_W-1:0]            s_axis_tdata,
    input  wire [KEEP_W-1:0]            s_axis_tkeep,
    input  wire                         s_axis_tlast,

    input  wire                         fill_req,
    input  wire [15:0]                  pass_base_k,
    input  wire [31:0]                  fill_pixel_base,
    input  wire [31:0]                  fill_num_pixels,
    output wire [ROWS*8-1:0]            vector_data,
    output wire [ROWS-1:0]              vector_lane_valid,
    output wire                         vector_valid,
    input  wire                         vector_ready,
    output wire                         packet_done,

    output wire [MAX_PASSES-1:0]        pass_ready_bitmap,
    output wire [EPOCH_W-1:0]           pass_ready_epoch,
    output wire                         materializer_busy,
    output wire                         replay_active,
    output wire                         input_done,
    output wire                         materialize_done,

    output wire                         materializer_config_error,
    output wire                         tkeep_error,
    output wire                         tlast_error,
    output wire                         materializer_overflow_error,
    output wire                         bank_collision_error,
    output wire                         row_overwrite_error,
    output wire                         materializer_protocol_error,
    output wire                         cache_config_error,
    output wire                         cache_underflow_error,
    output wire                         cache_overflow_error,
    output wire                         cache_context_mismatch_error,

    output wire [31:0]                  accepted_axis_beats,
    output wire [31:0]                  accepted_axis_bytes,
    output wire [31:0]                  emitted_entries,
    output wire [31:0]                  accepted_cache_entries,
    output wire [31:0]                  completed_replay_packets,
    output wire [31:0]                  completed_replay_pixels,
    output wire [31:0]                  underflow_count,
    output wire [31:0]                  overflow_count,
    output wire [31:0]                  context_mismatch_count,
    output wire [31:0]                  axis_stall_cycles,
    output wire [31:0]                  materializer_entry_stall_cycles,
    output wire [31:0]                  materialize_cycles,
    output wire [31:0]                  pass_wait_stall_cycles,
    output wire [31:0]                  replay_backpressure_stall_cycles,
    output wire [31:0]                  cache_entry_stall_cycles
);
    wire entry_valid;
    wire entry_ready;
    wire [ROWS*8-1:0] entry_data;
    wire [ROWS-1:0] entry_lane_valid;
    wire [31:0] entry_pixel;
    wire [15:0] entry_k_pass;
    wire [EPOCH_W-1:0] entry_epoch;
    wire entry_last;
    wire cache_configured;
    wire [15:0] active_replay_pass_unused;
    wire [31:0] cfg_num_pixels = cfg_ofm_h * cfg_ofm_w;
    wire [15:0] cfg_k_total = cfg_kernel_1x1 ? cfg_cin :
                              (cfg_cin * 9);

    axis_hwc_window_materializer #(
        .ROWS(ROWS),
        .AXIS_W(AXIS_W),
        .KEEP_W(KEEP_W),
        .MAX_FM_W(MAX_FM_W),
        .MAX_CHANNELS(MAX_CHANNELS),
        .LINE_BANK_DEPTH(LINE_BANK_DEPTH),
        .MAX_PASSES(MAX_PASSES),
        .EPOCH_W(EPOCH_W)
    ) u_materializer (
        .clk(clk),
        .rst(rst),
        .cfg_start(cfg_start),
        .cfg_fm_h(cfg_fm_h),
        .cfg_fm_w(cfg_fm_w),
        .cfg_cin(cfg_cin),
        .cfg_ofm_h(cfg_ofm_h),
        .cfg_ofm_w(cfg_ofm_w),
        .cfg_kernel_1x1(cfg_kernel_1x1),
        .cfg_stride(cfg_stride),
        .cfg_pad(cfg_pad),
        .cfg_input_zero_point(cfg_input_zero_point),
        .cfg_epoch(cfg_epoch),
        .s_axis_tready(s_axis_tready),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .m_entry_valid(entry_valid),
        .m_entry_ready(entry_ready),
        .m_entry_data(entry_data),
        .m_entry_lane_valid(entry_lane_valid),
        .m_entry_pixel(entry_pixel),
        .m_entry_k_pass(entry_k_pass),
        .m_entry_epoch(entry_epoch),
        .m_entry_last(entry_last),
        .pass_ready_bitmap(pass_ready_bitmap),
        .pass_ready_epoch(pass_ready_epoch),
        .busy(materializer_busy),
        .input_done(input_done),
        .done(materialize_done),
        .config_error(materializer_config_error),
        .tkeep_error(tkeep_error),
        .tlast_error(tlast_error),
        .overflow_error(materializer_overflow_error),
        .bank_collision_error(bank_collision_error),
        .row_overwrite_error(row_overwrite_error),
        .protocol_error(materializer_protocol_error),
        .accepted_beats(accepted_axis_beats),
        .accepted_bytes(accepted_axis_bytes),
        .emitted_entries(emitted_entries),
        .axis_stall_cycles(axis_stall_cycles),
        .entry_stall_cycles(materializer_entry_stall_cycles),
        .materialize_cycles(materialize_cycles)
    );

    hwc_materialized_vector_cache #(
        .ROWS(ROWS),
        .EPOCH_W(EPOCH_W),
        .PASS_W(16),
        .PIXEL_W(32),
        .MAX_PASSES(MAX_PASSES),
        .CACHE_AW(CACHE_AW),
        .CACHE_DEPTH(CACHE_DEPTH)
    ) u_replay_cache (
        .clk(clk),
        .rst(rst),
        .cfg_start(cfg_start),
        .cfg_epoch(cfg_epoch),
        .cfg_num_pixels(cfg_num_pixels),
        .cfg_k_total(cfg_k_total),
        .entry_valid(entry_valid),
        .entry_ready(entry_ready),
        .entry_data(entry_data),
        .entry_lane_valid(entry_lane_valid),
        .entry_pixel(entry_pixel),
        .entry_k_pass(entry_k_pass),
        .entry_epoch(entry_epoch),
        .entry_last(entry_last),
        .pass_ready_bitmap(pass_ready_bitmap),
        .pass_ready_epoch(pass_ready_epoch),
        .fill_req(fill_req),
        .pass_base_k(pass_base_k),
        .fill_pixel_base(fill_pixel_base),
        .fill_num_pixels(fill_num_pixels),
        .vector_data(vector_data),
        .vector_lane_valid(vector_lane_valid),
        .vector_valid(vector_valid),
        .vector_ready(vector_ready),
        .packet_done(packet_done),
        .configured(cache_configured),
        .replay_active(replay_active),
        .active_replay_pass(active_replay_pass_unused),
        .config_error(cache_config_error),
        .underflow_error(cache_underflow_error),
        .overflow_error(cache_overflow_error),
        .context_mismatch_error(cache_context_mismatch_error),
        .accepted_entries(accepted_cache_entries),
        .completed_packets(completed_replay_packets),
        .completed_pixels(completed_replay_pixels),
        .underflow_count(underflow_count),
        .overflow_count(overflow_count),
        .context_mismatch_count(context_mismatch_count),
        .pass_wait_stall_cycles(pass_wait_stall_cycles),
        .vector_backpressure_stall_cycles(
            replay_backpressure_stall_cycles),
        .entry_backpressure_stall_cycles(cache_entry_stall_cycles)
    );
endmodule

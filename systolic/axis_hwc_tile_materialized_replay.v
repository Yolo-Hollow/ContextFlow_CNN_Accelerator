`timescale 1ns / 1ps

// Layer-long raw-HWC input path with a tile-local, two-bank replay cache.
//
// The materializer consumes exactly one dense HWC AXIS transfer per layer and
// emits one ROWS-wide K vector per cycle.  The cache owns complete spatial
// tiles and permits the feeder to replay every K pass for every COUT block
// without returning to DDR.  A tile bank is reusable only after the compute
// engine explicitly releases the matching {epoch,tile_index} context.
module axis_hwc_tile_materialized_replay #(
    parameter integer ROWS = 18,
    parameter integer AXIS_W = 64,
    parameter integer KEEP_W = AXIS_W / 8,
    parameter integer MAX_FM_W = 416,
    parameter integer MAX_CHANNELS = 1024,
    parameter integer LINE_BANK_DEPTH = 2048,
    parameter integer MAX_PASSES = 512,
    parameter integer EPOCH_W = 8,
    parameter integer TILE_W = 16,
    parameter integer PIXEL_W = 32,
    parameter integer CACHE_AW = 15,
    parameter integer CACHE_DEPTH = (1 << CACHE_AW),
    parameter integer CACHE_CFG_PREVALIDATED = 0,
    parameter integer MATERIALIZER_CFG_PREVALIDATED = 0
) (
    input  wire                         clk,
    input  wire                         rst,

    input  wire                         cfg_start,
    input  wire [15:0]                  cfg_fm_h,
    input  wire [15:0]                  cfg_fm_w,
    input  wire [13:0]                  cfg_cin,
    input  wire [15:0]                  cfg_ofm_h,
    input  wire [15:0]                  cfg_ofm_w,
    input  wire [15:0]                  cfg_tile_h_max,
    input  wire [15:0]                  cfg_k_total,
    input  wire [PIXEL_W-1:0]           cfg_prevalidated_layer_pixels,
    input  wire [PIXEL_W-1:0]           cfg_prevalidated_tile_pixels,
    input  wire [15:0]                  cfg_prevalidated_pass_count,
    input  wire [15:0]                  cfg_prevalidated_final_pass,
    input  wire [ROWS-1:0]              cfg_prevalidated_final_lane_mask,
    input  wire [31:0]                  cfg_ifm_total_bytes,
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
    output wire                         fill_req_ready,
    output wire                         fill_req_accept,
    input  wire [15:0]                  pass_base_k,
    input  wire [15:0]                  fill_k_pass,
    input  wire [TILE_W-1:0]            fill_tile_index,
    input  wire [PIXEL_W-1:0]           fill_pixel_base,
    input  wire [PIXEL_W-1:0]           fill_num_pixels,
    output wire                         fill_req_pending,

    output wire [ROWS*8-1:0]            vector_data,
    output wire [ROWS-1:0]              vector_lane_valid,
    output wire                         vector_valid,
    input  wire                         vector_ready,
    output wire                         vector_last,
    output wire                         packet_done,

    input  wire                         release_valid,
    output wire                         release_ready,
    input  wire [EPOCH_W-1:0]           release_epoch,
    input  wire [TILE_W-1:0]            release_tile_index,

    output wire                         materializer_busy,
    output wire                         materializer_input_done,
    output wire                         materialize_done,
    output wire                         replay_active,
    output wire [TILE_W-1:0]            active_replay_tile,
    output wire [15:0]                  active_replay_pass,

    output wire                         materializer_config_error,
    output wire                         tkeep_error,
    output wire                         tlast_error,
    output wire                         materializer_overflow_error,
    output wire                         bank_collision_error,
    output wire                         row_overwrite_error,
    output wire                         materializer_protocol_error,
    output wire [4:0]                   cache_error_status,

    output wire [31:0]                  accepted_axis_beats,
    output wire [31:0]                  accepted_axis_bytes,
    output wire [31:0]                  emitted_entries,
    output wire [31:0]                  stored_entries,
    output wire [31:0]                  completed_replay_packets,
    output wire [31:0]                  completed_replay_pixels,
    output wire [31:0]                  axis_stall_cycles,
    output wire [31:0]                  materializer_entry_stall_cycles,
    output wire [31:0]                  materialize_cycles,
    output wire [31:0]                  ownership_stall_cycles,
    output wire [31:0]                  context_gap_cycles,
    output wire [31:0]                  replay_backpressure_stall_cycles,
    output wire [31:0]                  release_stall_cycles
);
    wire entry_valid;
    wire entry_ready;
    wire [ROWS*8-1:0] entry_data;
    wire [ROWS-1:0] entry_lane_valid;
    wire [31:0] entry_pixel;
    wire [15:0] entry_k_pass;
    wire [EPOCH_W-1:0] entry_epoch;
    wire entry_last;
    wire [MAX_PASSES-1:0] materializer_pass_ready_unused;
    wire [EPOCH_W-1:0] pass_ready_epoch_unused;
    wire materializer_done;
    wire cache_materialize_done;
    wire cache_configured_unused;
    wire cache_materialize_active_unused;
    wire cache_bank0_owned;
    wire cache_bank1_owned;
    wire [MAX_PASSES-1:0] bank0_pass_ready_unused;
    wire [MAX_PASSES-1:0] bank1_pass_ready_unused;
    wire cache_config_error;
    wire cache_order_error;
    wire cache_tag_error;
    wire cache_ownership_error;
    wire cache_overflow_error;
    wire [31:0] accepted_entries_unused;
    wire [31:0] order_error_count_unused;
    wire [31:0] tag_error_count_unused;
    wire [31:0] ownership_error_count_unused;

    wire [15:0] effective_tile_h_max =
        (cfg_tile_h_max == 16'd0) ? cfg_ofm_h : cfg_tile_h_max;

    // The cache now publishes completion with the registered physical write,
    // one cycle after the materializer's final-entry handshake.  Remember the
    // earlier pulse until both halves of the transaction have retired.
    reg materializer_done_seen_q;
    wire joined_materialize_done = cache_materialize_done &&
        (materializer_done_seen_q || materializer_done);
    wire cache_context_idle = !cache_bank0_owned && !cache_bank1_owned &&
        !replay_active && !fill_req_pending;

    assign materialize_done = joined_materialize_done;

    always @(posedge clk) begin
        if (rst) begin
            materializer_done_seen_q <= 1'b0;
        end else if (joined_materialize_done) begin
            materializer_done_seen_q <= 1'b0;
        end else if (materializer_done) begin
            materializer_done_seen_q <= 1'b1;
        end else if (cfg_start && cache_context_idle) begin
            // Clear only for an idle/new context.  A rejected busy cfg_start
            // must not erase a final-entry completion waiting for cache commit.
            materializer_done_seen_q <= 1'b0;
        end
    end

    axis_hwc_window_materializer_byte_bram #(
        .ROWS(ROWS),
        .AXIS_W(AXIS_W),
        .KEEP_W(KEEP_W),
        .MAX_FM_W(MAX_FM_W),
        .MAX_CHANNELS(MAX_CHANNELS),
        .LINE_BANK_DEPTH(LINE_BANK_DEPTH),
        .MAX_PASSES(MAX_PASSES),
        .EPOCH_W(EPOCH_W),
        .CFG_PREVALIDATED(MATERIALIZER_CFG_PREVALIDATED),
        // The tile ping-pong cache owns the release pass-ready bitmap.  Do
        // not duplicate a second 512-bit materializer bitmap that is unused
        // by this integration path.
        .ENABLE_PASS_READY_BITMAP(0)
    ) u_materializer (
        .clk(clk), .rst(rst),
        .cfg_start(cfg_start),
        .cfg_fm_h(cfg_fm_h), .cfg_fm_w(cfg_fm_w),
        .cfg_cin(cfg_cin),
        .cfg_ofm_h(cfg_ofm_h), .cfg_ofm_w(cfg_ofm_w),
        .cfg_kernel_1x1(cfg_kernel_1x1),
        .cfg_stride(cfg_stride), .cfg_pad(cfg_pad),
        .cfg_input_zero_point(cfg_input_zero_point),
        .cfg_epoch(cfg_epoch),
        .cfg_expected_bytes(cfg_ifm_total_bytes),
        .cfg_prevalidated_pass_count(cfg_prevalidated_pass_count),
        .s_axis_tready(s_axis_tready),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .m_entry_valid(entry_valid), .m_entry_ready(entry_ready),
        .m_entry_data(entry_data),
        .m_entry_lane_valid(entry_lane_valid),
        .m_entry_pixel(entry_pixel),
        .m_entry_k_pass(entry_k_pass),
        .m_entry_epoch(entry_epoch), .m_entry_last(entry_last),
        .pass_ready_bitmap(materializer_pass_ready_unused),
        .pass_ready_epoch(pass_ready_epoch_unused),
        .busy(materializer_busy),
        .input_done(materializer_input_done),
        .done(materializer_done),
        .config_error(materializer_config_error),
        .tkeep_error(tkeep_error), .tlast_error(tlast_error),
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

    hwc_materialized_tile_pingpong_cache #(
        .ROWS(ROWS), .EPOCH_W(EPOCH_W), .TILE_W(TILE_W),
        .PASS_W(16), .PIXEL_W(PIXEL_W),
        .MAX_PASSES(MAX_PASSES),
        .BANK_AW(CACHE_AW), .BANK_DEPTH(CACHE_DEPTH),
        .CFG_PREVALIDATED(CACHE_CFG_PREVALIDATED),
        .ENABLE_PASS_READY_BITMAP(0)
    ) u_tile_cache (
        .clk(clk), .rst(rst),
        .cfg_start(cfg_start), .cfg_epoch(cfg_epoch),
        .cfg_ofm_w(cfg_ofm_w), .cfg_ofm_h(cfg_ofm_h),
        .cfg_tile_h_max(effective_tile_h_max),
        .cfg_k_total(cfg_k_total),
        .cfg_prevalidated_layer_pixels(
            cfg_prevalidated_layer_pixels),
        .cfg_prevalidated_tile_pixels(cfg_prevalidated_tile_pixels),
        .cfg_prevalidated_pass_count(cfg_prevalidated_pass_count),
        .cfg_prevalidated_final_pass(cfg_prevalidated_final_pass),
        .cfg_prevalidated_final_lane_mask(
            cfg_prevalidated_final_lane_mask),
        .entry_valid(entry_valid), .entry_ready(entry_ready),
        .entry_data(entry_data),
        .entry_lane_valid(entry_lane_valid),
        .entry_pixel(entry_pixel), .entry_k_pass(entry_k_pass),
        .entry_epoch(entry_epoch), .entry_last(entry_last),
        .fill_req(fill_req), .fill_req_ready(fill_req_ready),
        .fill_req_accept(fill_req_accept),
        .pass_base_k(pass_base_k),
        .fill_k_pass(fill_k_pass),
        .fill_tile_index(fill_tile_index),
        .fill_pixel_base(fill_pixel_base),
        .fill_num_pixels(fill_num_pixels),
        .fill_req_pending(fill_req_pending),
        .vector_data(vector_data),
        .vector_lane_valid(vector_lane_valid),
        .vector_valid(vector_valid), .vector_ready(vector_ready),
        .vector_last(vector_last), .packet_done(packet_done),
        .release_valid(release_valid), .release_ready(release_ready),
        .release_epoch(release_epoch),
        .release_tile_index(release_tile_index),
        .configured(cache_configured_unused),
        .materialize_active(cache_materialize_active_unused),
        .materialize_done(cache_materialize_done),
        .replay_active(replay_active),
        .active_replay_tile(active_replay_tile),
        .active_replay_pass(active_replay_pass),
        .bank0_owned(cache_bank0_owned), .bank0_fill_complete(), .bank0_epoch(),
        .bank0_tile_index(), .bank0_pixel_base(), .bank0_pixel_count(),
        .bank0_pass_ready_bitmap(bank0_pass_ready_unused),
        .bank1_owned(cache_bank1_owned), .bank1_fill_complete(), .bank1_epoch(),
        .bank1_tile_index(), .bank1_pixel_base(), .bank1_pixel_count(),
        .bank1_pass_ready_bitmap(bank1_pass_ready_unused),
        .config_error(cache_config_error),
        .order_error(cache_order_error), .tag_error(cache_tag_error),
        .ownership_error(cache_ownership_error),
        .overflow_error(cache_overflow_error),
        .error_status(cache_error_status),
        .accepted_entries(accepted_entries_unused),
        .stored_entries(stored_entries),
        .completed_packets(completed_replay_packets),
        .completed_pixels(completed_replay_pixels),
        .order_error_count(order_error_count_unused),
        .tag_error_count(tag_error_count_unused),
        .ownership_error_count(ownership_error_count_unused),
        .ownership_stall_cycles(ownership_stall_cycles),
        .context_gap_cycles(context_gap_cycles),
        .vector_backpressure_stall_cycles(
            replay_backpressure_stall_cycles),
        .release_stall_cycles(release_stall_cycles)
    );
endmodule

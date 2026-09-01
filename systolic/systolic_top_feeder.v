`timescale 1ns / 1ps

// Wrapper that connects window_feeder to systolic_top through the manual IFM
// FIFO fill path. The compute core is intentionally kept unchanged while the
// feeder path is validated.
`ifndef SYSTOLIC_TAIL_CYCLES_CONFIG
`define SYSTOLIC_TAIL_CYCLES_CONFIG 0
`endif

module systolic_top_feeder #(
    parameter ROWS = 32, parameter COLS = 32,
    parameter IFM_W = 8, parameter WEIGHT_W = 8, parameter PSUM_W = 32,
    parameter IFM_FIFO_DEPTH = 1024, parameter IFM_FIFO_AW = 10,
    parameter WGT_FIFO_DEPTH = 64,  parameter WGT_FIFO_AW = 6,
    parameter PSUM_FIFO_DEPTH = 1024, parameter PSUM_FIFO_AW = 10,
    parameter FM_W_MAX = 416,
    parameter FM_H_MAX = 416,
    parameter IFM_BANKS = 5,
    parameter TAIL_CYCLES_CONFIG = `SYSTOLIC_TAIL_CYCLES_CONFIG,
    parameter ENABLE_COLUMN_PSUM = 0,
    parameter ENABLE_TAGGED_CONTEXT = 0,
    parameter ENABLE_WEIGHT_PRELOAD = 0,
    parameter ENABLE_FAST_CONTEXT_HANDOFF = 0,
    parameter EPOCH_W = 8,
    // Formal layer-long raw-HWC builds feed only complete ROWS-wide vectors.
    // Compile the line-buffer feeder out instead of retaining a dead runtime
    // mux and five large legacy window banks.
    parameter ENABLE_VECTOR_ONLY_IFM = 0,
    // Explicit build-profile choice for the two tagged IFM epoch banks.
    // Debug and unprofiled builds keep the historical BRAM implementation.
    parameter IFM_EPOCH_USE_URAM = 0
) (
    input  clk,
    input  rst,

    input  feeder_start,
    output feeder_start_ready,
    output feeder_done,
    output feeder_busy,
    output feeder_fill_req,
    output [8:0] feeder_fill_fy,
    input  kernel_1x1,
    input  raw_hwc_mode,

    input  compute_start,
    input  [15:0] num_pixels,
    input  [15:0] tail_cycles_config,
    input         tagged_context_start_ready,
    input         tagged_context_admission_ready,
    input  [15:0] raw_hwc_compute_start_level,
    output feeder_compute_ready,
    output compute_done,
    output compute_fire_out,
    output compute_context_start,
    output compute_context_bank,
    output [EPOCH_W-1:0] compute_context_epoch,
    output perf_feed_push,
    output perf_feed_fifo_stall,
    output perf_feed_win_not_ready,
    output perf_comp_wload,
    output perf_comp_active,
    output perf_comp_ifm_stall,
    output perf_comp_tail,
    output [31:0] perf_tail_cycles_configured,

    input  [8:0] fm_h,
    input  [8:0] fm_w,
    input  [8:0] ofm_h,
    input  [8:0] ofm_w,
    input  [8:0] tile_oy_base,
    input  [8:0] tile_ofm_h,
    input  [1:0] conv_stride,
    input  [1:0] conv_pad,
    input  [13:0] pass_base_k,

    input  [IFM_BANKS-1:0] dma_bank_wr_en,
    input  [8:0] dma_wr_x,
    input  [9:0] dma_wr_fy,
    input  [7:0] dma_wr_data [0:IFM_BANKS-1],
    input        dma_line_advance,
    input  [ROWS*IFM_W-1:0] vector_ifm_data,
    input                    vector_ifm_valid,
    output                   vector_ifm_ready,
    input                    vector_packet_done,

    input  [5:0]                bias_wr_addr,
    input  [PSUM_W-1:0]         bias_wr_data,
    input                       bias_wr_en,
    input                       is_first_pass,
    input  [COLS*2*PSUM_W-1:0]  psum_top_ext,
    input                       use_ext_psum,
    input  [COLS*2*PSUM_W-1:0]  psum_stream_data,
    input                       psum_stream_valid,
    input                       psum_stream_compute_ready,
    input                       use_psum_stream,
    input  [COLS*2*PSUM_W-1:0]  psum_column_stream_data,
    input  [COLS-1:0]           psum_column_stream_valid,
    input                       use_column_psum_stream,

    input  [ROWS-1:0]            wgt_fifo_wr_en,
    input  [ROWS*WEIGHT_W*2-1:0] wgt_fifo_wr_data,
    input                        weight_tile_complete,
    output                       weight_tile_complete_ready,
    output [ROWS-1:0]            wgt_fifo_full,

    input  [31:0]              psum_fifo_rd_en,
    output [COLS*PSUM_W*2-1:0] psum_fifo_rd_data,
    output [COLS*(EPOCH_W+2)-1:0] psum_fifo_rd_tag,
    output [31:0]              psum_fifo_empty,
    output [31:0]              psum_fifo_wr_en_dbg,

    output [ROWS-1:0] ifm_fifo_full,

    input                       collector_done_valid,
    input  [EPOCH_W-1:0]       collector_done_epoch,
    output [31:0]              tagged_datapath_error_status,
    output [31:0]              context_alloc_count,
    output [31:0]              context_input_issued_count,
    output [31:0]              context_array_retired_count,
    output [31:0]              context_collector_done_count,
    output [31:0]              context_gap_cycles,
    output [31:0]              ifm_ownership_stall_cycles,
    output [31:0]              weight_ownership_stall_cycles,
    output [31:0]              psum_credit_stall_cycles,
    output [31:0]              context_epoch_mismatch_count,
    output [31:0]              context_mismatch_count,
    output [31:0]              context_ifm_underflow_count,
    output [31:0]              context_psum_underflow_count,
    output [31:0]              context_fifo_drop_count,
    output [31:0]              context_bank_overwrite_count,
    output [31:0]              context_full_stall_cycles
);
    wire [ROWS*IFM_W-1:0] feeder_ifm_data;
    wire feeder_ifm_valid;
    wire feeder_window_ready;
    wire [8:0] feeder_oy, feeder_ox;
    wire line_feeder_done;
    wire line_feeder_busy;
    wire line_fill_req;
    wire [8:0] line_fill_fy;
    wire line_feed_push;
    wire line_feed_fifo_stall;
    wire line_feed_win_not_ready;
    reg vector_fill_req;
    reg vector_feeder_done;
    reg [15:0] vector_push_count;
    wire context_feeder_start_ready;
    wire vector_mode = (ENABLE_VECTOR_ONLY_IFM != 0) ? 1'b1 :
                       (kernel_1x1 || raw_hwc_mode);
    wire [15:0] vector_start_level =
        (raw_hwc_compute_start_level > num_pixels) ? num_pixels :
        raw_hwc_compute_start_level;
    wire vector_push_fire = vector_ifm_valid && vector_ifm_ready;
    wire raw_overlap_enabled = raw_hwc_mode && (vector_start_level != 16'd0);
    // The tagged frontend can reserve a second epoch bank while the current
    // vector replay is still draining, but the vector producer itself has one
    // active request slot.  Advertise that capacity explicitly so a scheduler
    // request cannot allocate a context whose replay request was never kept.
    // Keep one real low cycle after packet_done: the materialized cache uses
    // fill_req deassertion to re-arm its next request detector.
    assign feeder_start_ready = context_feeder_start_ready &&
        (!vector_mode || !vector_fill_req);
    wire feeder_start_accept = feeder_start && feeder_start_ready;

    assign feeder_done = vector_mode ? vector_feeder_done : line_feeder_done;
    assign feeder_compute_ready =
        raw_overlap_enabled && vector_fill_req &&
        ((vector_push_count >= vector_start_level) ||
         (vector_push_fire && (vector_push_count + 16'd1 >= vector_start_level)));
    assign feeder_busy = vector_mode ? vector_fill_req : line_feeder_busy;
    assign feeder_fill_req = vector_mode ? vector_fill_req : line_fill_req;
    assign feeder_fill_fy = vector_mode ? 9'd0 : line_fill_fy;
    assign perf_feed_push = vector_mode ?
        (vector_ifm_valid && vector_ifm_ready) : line_feed_push;
    assign perf_feed_fifo_stall = vector_mode ?
        (vector_fill_req && vector_ifm_valid && !vector_ifm_ready) :
        line_feed_fifo_stall;
    assign perf_feed_win_not_ready = vector_mode ? 1'b0 : line_feed_win_not_ready;

    always @(posedge clk) begin
        if (rst) begin
            vector_fill_req <= 1'b0;
            vector_feeder_done <= 1'b0;
            vector_push_count <= 16'd0;
        end else begin
            vector_feeder_done <= 1'b0;
            if (vector_mode && vector_fill_req && vector_packet_done)
                vector_feeder_done <= 1'b1;

            if (vector_mode && feeder_start_accept) begin
                // New start wins over an old packet_done on the same edge.
                vector_fill_req <= 1'b1;
                vector_push_count <= 16'd0;
            end else if (vector_mode && vector_fill_req &&
                         vector_packet_done) begin
                vector_fill_req <= 1'b0;
            end else if (vector_mode && vector_fill_req &&
                         vector_push_fire &&
                         vector_push_count != 16'hffff) begin
                vector_push_count <= vector_push_count + 16'd1;
            end
            if (!vector_mode) begin
                vector_fill_req <= 1'b0;
                vector_push_count <= 16'd0;
            end
        end
    end

    generate
        if (ENABLE_VECTOR_ONLY_IFM == 0) begin : g_legacy_window_feeder
            window_feeder #(
                .FM_W(FM_W_MAX), .FM_H(FM_H_MAX), .AW(9),
                .ROWS(ROWS), .BANKS(IFM_BANKS)
            ) u_feeder (
                .clk(clk),
                .rst(rst),
                .start(feeder_start_accept && !vector_mode),
                .fm_h(fm_h),
                .fm_w(fm_w),
                .ofm_h(ofm_h),
                .ofm_w(ofm_w),
                .tile_oy_base(tile_oy_base),
                .tile_ofm_h(tile_ofm_h),
                .stride(conv_stride),
                .pad(conv_pad),
                .pass_base_k(pass_base_k),
                .fill_req(line_fill_req),
                .fill_fy(line_fill_fy),
                .dma_bank_wr_en(dma_bank_wr_en),
                .dma_wr_x(dma_wr_x),
                .dma_wr_fy(dma_wr_fy),
                .dma_wr_data(dma_wr_data),
                .dma_line_advance(dma_line_advance),
                .ifm_fifo_full_any(|ifm_fifo_full),
                .ifm_data(feeder_ifm_data),
                .ifm_valid(feeder_ifm_valid),
                .cur_oy(feeder_oy),
                .cur_ox(feeder_ox),
                .window_ready(feeder_window_ready),
                .perf_feed_push(line_feed_push),
                .perf_feed_fifo_stall(line_feed_fifo_stall),
                .perf_feed_win_not_ready(line_feed_win_not_ready),
                .busy(line_feeder_busy),
                .done(line_feeder_done)
            );
        end else begin : g_no_legacy_window_feeder
            assign feeder_ifm_data = {ROWS*IFM_W{1'b0}};
            assign feeder_ifm_valid = 1'b0;
            assign feeder_window_ready = 1'b0;
            assign feeder_oy = 9'd0;
            assign feeder_ox = 9'd0;
            assign line_feeder_done = 1'b0;
            assign line_feeder_busy = 1'b0;
            assign line_fill_req = 1'b0;
            assign line_fill_fy = 9'd0;
            assign line_feed_push = 1'b0;
            assign line_feed_fifo_stall = 1'b0;
            assign line_feed_win_not_ready = 1'b0;
        end
    endgenerate

    wire [ROWS-1:0] ifm_fifo_full_legacy;
    wire [7:0] unused_dma_wr_data [0:4];
    assign unused_dma_wr_data[0] = 8'd0;
    assign unused_dma_wr_data[1] = 8'd0;
    assign unused_dma_wr_data[2] = 8'd0;
    assign unused_dma_wr_data[3] = 8'd0;
    assign unused_dma_wr_data[4] = 8'd0;

    generate
        if (ENABLE_TAGGED_CONTEXT != 0) begin : g_tagged_context_core
            wire frontend_vector_ready;
            wire [ROWS*IFM_W-1:0] tagged_stream_data;
            wire tagged_stream_valid;
            wire tagged_stream_ready;
            wire tagged_stream_bank;
            wire [EPOCH_W-1:0] tagged_stream_epoch;
            wire tagged_stream_last;
            wire [1:0] tagged_bank_allocated;
            wire [1:0] tagged_bank_committed;
            wire [EPOCH_W-1:0] tagged_bank0_epoch;
            wire [EPOCH_W-1:0] tagged_bank1_epoch;
            wire [15:0] tagged_bank0_available;
            wire [15:0] tagged_bank1_available;
            wire tagged_reader_active;
            wire tagged_array_retired_done;
            wire tagged_array_retired_bank;
            wire [EPOCH_W-1:0] tagged_array_retired_epoch;
            wire frontend_error_epoch;
            wire frontend_error_overflow;
            wire frontend_error_protocol;
            wire frontend_error_context_drop;
            wire frontend_error_retire;
            wire frontend_error_collector;
            wire [31:0] epoch_conflict_stall_cycles;
            wire [31:0] frontend_context_mismatch_count;
            wire [31:0] core_epoch_mismatch_count;
            wire [31:0] core_context_mismatch_count;
            wire core_fatal_error;
            wire [31:0] core_tagged_error_status;
            wire context_alloc_valid;
            wire context_alloc_bank;
            wire [EPOCH_W-1:0] context_alloc_epoch;
            wire [15:0] context_alloc_expected;
            wire weight_context_alloc_ready;
            wire tagged_core_start_ready;
            wire tagged_frontend_start_ready;

            assign context_feeder_start_ready =
                tagged_frontend_start_ready;

            assign vector_ifm_ready = vector_mode && frontend_vector_ready;
            assign ifm_fifo_full = {ROWS{!frontend_vector_ready}};
            assign ifm_fifo_full_legacy = {ROWS{1'b0}};

            ifm_context_epoch_frontend #(
                .DATA_W(ROWS*IFM_W),
                .DEPTH(IFM_FIFO_DEPTH),
                .AW(IFM_FIFO_AW),
                .EPOCH_W(EPOCH_W),
                .USE_URAM(IFM_EPOCH_USE_URAM)
            ) u_context_frontend (
                .clk(clk),
                .rst(rst),
                .feeder_start(feeder_start_accept),
                .context_expected(num_pixels),
                .feeder_start_ready(tagged_frontend_start_ready),
                .context_alloc_sideband_ready(weight_context_alloc_ready),
                .vector_data(vector_mode ? vector_ifm_data : feeder_ifm_data),
                .vector_valid(vector_mode ?
                    (vector_ifm_valid && vector_fill_req) : feeder_ifm_valid),
                .vector_ready(frontend_vector_ready),
                .vector_packet_done(vector_mode ?
                    vector_packet_done : line_feeder_done),
                .compute_start(compute_start),
                .core_ready(tagged_core_start_ready &&
                            tagged_context_start_ready),
                .core_start(compute_context_start),
                .core_context_bank(compute_context_bank),
                .core_context_epoch(compute_context_epoch),
                .core_context_expected(),
                .context_alloc_valid(context_alloc_valid),
                .context_alloc_bank(context_alloc_bank),
                .context_alloc_epoch(context_alloc_epoch),
                .context_alloc_expected(context_alloc_expected),
                .stream_data(tagged_stream_data),
                .stream_valid(tagged_stream_valid),
                .stream_ready(tagged_stream_ready),
                .stream_bank(tagged_stream_bank),
                .stream_epoch(tagged_stream_epoch),
                .stream_last(tagged_stream_last),
                .array_retired_valid(tagged_array_retired_done),
                .array_retired_bank(tagged_array_retired_bank),
                .array_retired_epoch(tagged_array_retired_epoch),
                .collector_done_valid(collector_done_valid),
                .collector_done_epoch(collector_done_epoch),
                .bank_allocated(tagged_bank_allocated),
                .bank_committed(tagged_bank_committed),
                .bank0_epoch(tagged_bank0_epoch),
                .bank1_epoch(tagged_bank1_epoch),
                .bank0_available(tagged_bank0_available),
                .bank1_available(tagged_bank1_available),
                .reader_active(tagged_reader_active),
                .context_alloc_count(context_alloc_count),
                .input_issued_count(context_input_issued_count),
                .array_retired_count(context_array_retired_count),
                .collector_done_count(context_collector_done_count),
                .bank_ownership_stall_cycles(ifm_ownership_stall_cycles),
                .context_gap_cycles(context_gap_cycles),
                .epoch_conflict_stall_cycles(epoch_conflict_stall_cycles),
                .context_full_stall_cycles(context_full_stall_cycles),
                .context_mismatch_count(frontend_context_mismatch_count),
                .error_epoch(frontend_error_epoch),
                .error_overflow(frontend_error_overflow),
                .error_vector_protocol(frontend_error_protocol),
                .error_context_drop(frontend_error_context_drop),
                .error_retire_mismatch(frontend_error_retire),
                .error_collector_epoch(frontend_error_collector)
            );

            systolic_top_tagged #(
                .ROWS(ROWS), .COLS(COLS),
                .IFM_W(IFM_W), .WEIGHT_W(WEIGHT_W), .PSUM_W(PSUM_W),
                .EPOCH_W(EPOCH_W),
                .WGT_FIFO_DEPTH(WGT_FIFO_DEPTH),
                .WGT_FIFO_AW(WGT_FIFO_AW),
                .PSUM_FIFO_DEPTH(PSUM_FIFO_DEPTH),
                .PSUM_FIFO_AW(PSUM_FIFO_AW),
                .TAIL_CYCLES_CONFIG(TAIL_CYCLES_CONFIG),
                .ENABLE_COLUMN_PSUM(ENABLE_COLUMN_PSUM),
                .ENABLE_WEIGHT_PRELOAD(ENABLE_WEIGHT_PRELOAD),
                .ENABLE_FAST_CONTEXT_HANDOFF(ENABLE_FAST_CONTEXT_HANDOFF)
            ) u_core (
                .clk(clk), .rst(rst),
                .start(compute_context_start),
                .num_pixels(num_pixels),
                .tail_cycles_config(tail_cycles_config),
                .context_admission_ready(tagged_context_admission_ready),
                .context_bank(compute_context_bank),
                .context_epoch(compute_context_epoch),
                .start_ready(tagged_core_start_ready),
                .done(compute_done),
                .compute_fire_out(compute_fire_out),
                .input_issued_done(),
                .array_retired_done(tagged_array_retired_done),
                .array_retired_bank(tagged_array_retired_bank),
                .array_retired_epoch(tagged_array_retired_epoch),
                .perf_comp_wload(perf_comp_wload),
                .perf_comp_active(perf_comp_active),
                .perf_comp_ifm_stall(perf_comp_ifm_stall),
                .perf_comp_tail(perf_comp_tail),
                .perf_tail_cycles_configured(perf_tail_cycles_configured),
                .ifm_vector_data(tagged_stream_data),
                .ifm_vector_valid(tagged_stream_valid),
                .ifm_vector_ready(tagged_stream_ready),
                .ifm_vector_bank(tagged_stream_bank),
                .ifm_vector_epoch(tagged_stream_epoch),
                .ifm_vector_last(tagged_stream_last),
                .bias_wr_addr(bias_wr_addr),
                .bias_wr_data(bias_wr_data),
                .bias_wr_en(bias_wr_en),
                .is_first_pass(is_first_pass),
                .psum_top_ext(psum_top_ext),
                .use_ext_psum(use_ext_psum),
                .psum_stream_data(psum_stream_data),
                .psum_stream_valid(psum_stream_valid),
                .psum_stream_compute_ready(psum_stream_compute_ready),
                .use_psum_stream(use_psum_stream),
                .psum_column_stream_data(psum_column_stream_data),
                .psum_column_stream_valid(psum_column_stream_valid),
                .use_column_psum_stream(use_column_psum_stream),
                .wgt_fifo_wr_en(wgt_fifo_wr_en),
                .wgt_fifo_wr_data(wgt_fifo_wr_data),
                .weight_tile_complete(weight_tile_complete),
                .weight_tile_complete_ready(weight_tile_complete_ready),
                .weight_context_alloc_valid(context_alloc_valid),
                .weight_context_alloc_bank(context_alloc_bank),
                .weight_context_alloc_epoch(context_alloc_epoch),
                .weight_context_alloc_ready(weight_context_alloc_ready),
                .wgt_fifo_full(wgt_fifo_full),
                .psum_fifo_rd_en(psum_fifo_rd_en),
                .psum_fifo_rd_data(psum_fifo_rd_data),
                .psum_fifo_rd_tag(psum_fifo_rd_tag),
                .psum_fifo_empty(psum_fifo_empty),
                .psum_fifo_wr_en_dbg(psum_fifo_wr_en_dbg),
                .psum_credit_stall_cycles(psum_credit_stall_cycles),
                .weight_ownership_stall_cycles(weight_ownership_stall_cycles),
                .epoch_mismatch_count(core_epoch_mismatch_count),
                .context_mismatch_count(core_context_mismatch_count),
                .ifm_underflow_count(context_ifm_underflow_count),
                .psum_underflow_count(context_psum_underflow_count),
                .fifo_drop_count(context_fifo_drop_count),
                .tagged_error_status(core_tagged_error_status),
                .fatal_error(core_fatal_error)
            );

            assign context_epoch_mismatch_count =
                epoch_conflict_stall_cycles + core_epoch_mismatch_count;
            assign context_mismatch_count =
                frontend_context_mismatch_count + core_context_mismatch_count;
            assign context_bank_overwrite_count = 32'd0;
            assign tagged_datapath_error_status = core_tagged_error_status |
                (frontend_error_epoch ? (32'h1 << 19) : 32'd0) |
                (frontend_error_overflow ? (32'h1 << 20) : 32'd0) |
                (frontend_error_protocol ? (32'h1 << 21) : 32'd0) |
                (frontend_error_context_drop ? (32'h1 << 25) : 32'd0) |
                (frontend_error_retire ? (32'h1 << 27) : 32'd0) |
                (frontend_error_collector ? (32'h1 << 24) : 32'd0);
        end else begin : g_legacy_context_core
            assign weight_tile_complete_ready = 1'b1;
            assign context_feeder_start_ready = 1'b1;
            assign ifm_fifo_full = ifm_fifo_full_legacy;
            assign vector_ifm_ready = vector_mode && !(|ifm_fifo_full_legacy);
            assign compute_context_start = compute_start;
            assign compute_context_bank = 1'b0;
            assign compute_context_epoch = {EPOCH_W{1'b0}};
            assign psum_fifo_rd_tag = {COLS*(EPOCH_W+2){1'b0}};
            assign tagged_datapath_error_status = 32'd0;
            assign context_alloc_count = 32'd0;
            assign context_input_issued_count = 32'd0;
            assign context_array_retired_count = 32'd0;
            assign context_collector_done_count = 32'd0;
            assign context_gap_cycles = 32'd0;
            assign ifm_ownership_stall_cycles = 32'd0;
            assign weight_ownership_stall_cycles = 32'd0;
            assign psum_credit_stall_cycles = 32'd0;
            assign context_epoch_mismatch_count = 32'd0;
            assign context_mismatch_count = 32'd0;
            assign context_ifm_underflow_count = 32'd0;
            assign context_psum_underflow_count = 32'd0;
            assign context_fifo_drop_count = 32'd0;
            assign context_bank_overwrite_count = 32'd0;
            assign context_full_stall_cycles = 32'd0;

            systolic_top #(
                .ROWS(ROWS), .COLS(COLS),
                .IFM_W(IFM_W), .WEIGHT_W(WEIGHT_W), .PSUM_W(PSUM_W),
                .IFM_FIFO_DEPTH(IFM_FIFO_DEPTH), .IFM_FIFO_AW(IFM_FIFO_AW),
                .WGT_FIFO_DEPTH(WGT_FIFO_DEPTH), .WGT_FIFO_AW(WGT_FIFO_AW),
                .PSUM_FIFO_DEPTH(PSUM_FIFO_DEPTH), .PSUM_FIFO_AW(PSUM_FIFO_AW),
                .TAIL_CYCLES_CONFIG(TAIL_CYCLES_CONFIG),
                .USE_DMA_IFM(0),
                .ENABLE_COLUMN_PSUM(ENABLE_COLUMN_PSUM)
            ) u_core (
                .clk(clk),
                .rst(rst),
                .start(compute_start),
                .num_pixels(num_pixels),
                .tail_cycles_config(tail_cycles_config),
                .hold_compute_count_on_stall(vector_mode),
                .done(compute_done),
                .compute_fire_out(compute_fire_out),
                .perf_comp_wload(perf_comp_wload),
                .perf_comp_active(perf_comp_active),
                .perf_comp_ifm_stall(perf_comp_ifm_stall),
                .perf_comp_tail(perf_comp_tail),
                .perf_tail_cycles_configured(perf_tail_cycles_configured),
                .ifm_fifo_wr_en(vector_mode ?
                    {ROWS{vector_ifm_valid && vector_ifm_ready}} :
                    {ROWS{feeder_ifm_valid}}),
                .ifm_fifo_wr_data(vector_mode ? vector_ifm_data : feeder_ifm_data),
                .ifm_fifo_full_legacy(ifm_fifo_full_legacy),
                .dma_bank_wr_en(5'd0),
                .dma_wr_x(9'd0),
                .dma_wr_fy(10'd0),
                .dma_wr_data(unused_dma_wr_data),
                .dma_line_advance(1'b0),
                .fm_h(fm_h),
                .fm_w(fm_w),
                .conv_stride(conv_stride),
                .conv_pad(conv_pad),
                .pass_base_k(pass_base_k),
                .oy(9'd0),
                .ox(9'd0),
                .ifm_fifo_full(),
                .bias_wr_addr(bias_wr_addr),
                .bias_wr_data(bias_wr_data),
                .bias_wr_en(bias_wr_en),
                .is_first_pass(is_first_pass),
                .psum_top_ext(psum_top_ext),
                .use_ext_psum(use_ext_psum),
                .psum_stream_data(psum_stream_data),
                .psum_stream_valid(psum_stream_valid),
                .psum_stream_compute_ready(psum_stream_compute_ready),
                .use_psum_stream(use_psum_stream),
                .psum_column_stream_data(psum_column_stream_data),
                .psum_column_stream_valid(psum_column_stream_valid),
                .use_column_psum_stream(use_column_psum_stream),
                .wgt_fifo_wr_en(wgt_fifo_wr_en),
                .wgt_fifo_wr_data(wgt_fifo_wr_data),
                .wgt_fifo_full(wgt_fifo_full),
                .psum_fifo_rd_en(psum_fifo_rd_en),
                .psum_fifo_rd_data(psum_fifo_rd_data),
                .psum_fifo_empty(psum_fifo_empty),
                .psum_fifo_wr_en_dbg(psum_fifo_wr_en_dbg)
            );
        end
    endgenerate
endmodule

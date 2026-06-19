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
    parameter TAIL_CYCLES_CONFIG = `SYSTOLIC_TAIL_CYCLES_CONFIG
) (
    input  clk,
    input  rst,

    input  feeder_start,
    output feeder_done,
    output feeder_busy,
    output feeder_fill_req,
    output [8:0] feeder_fill_fy,
    input  kernel_1x1,
    input  raw_hwc_mode,

    input  compute_start,
    input  [15:0] num_pixels,
    input  [15:0] tail_cycles_config,
    input  [15:0] raw_hwc_compute_start_level,
    output feeder_compute_ready,
    output compute_done,
    output compute_fire_out,
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
    output [ROWS-1:0]            wgt_fifo_full,

    input  [31:0]              psum_fifo_rd_en,
    output [COLS*PSUM_W*2-1:0] psum_fifo_rd_data,
    output [31:0]              psum_fifo_empty,
    output [31:0]              psum_fifo_wr_en_dbg,

    output [ROWS-1:0] ifm_fifo_full
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
    wire vector_mode = kernel_1x1 || raw_hwc_mode;
    wire [15:0] vector_start_level =
        (raw_hwc_compute_start_level > num_pixels) ? num_pixels :
        raw_hwc_compute_start_level;
    wire vector_push_fire = vector_ifm_valid && vector_ifm_ready;
    wire raw_overlap_enabled = raw_hwc_mode && (vector_start_level != 16'd0);

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
            if (vector_mode && feeder_start) begin
                vector_fill_req <= 1'b1;
                vector_push_count <= 16'd0;
            end
            if (vector_mode && vector_fill_req && vector_push_fire &&
                vector_push_count != 16'hffff)
                vector_push_count <= vector_push_count + 16'd1;
            if (vector_mode && vector_fill_req && vector_packet_done) begin
                vector_fill_req <= 1'b0;
                vector_feeder_done <= 1'b1;
            end
            if (!vector_mode) begin
                vector_fill_req <= 1'b0;
                vector_push_count <= 16'd0;
            end
        end
    end

    window_feeder #(.FM_W(FM_W_MAX), .FM_H(FM_H_MAX), .AW(9), .ROWS(ROWS), .BANKS(IFM_BANKS)) u_feeder (
        .clk(clk),
        .rst(rst),
        .start(feeder_start && !vector_mode),
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

    wire [ROWS-1:0] ifm_fifo_full_legacy;
    assign ifm_fifo_full = ifm_fifo_full_legacy;
    assign vector_ifm_ready = vector_mode && !(|ifm_fifo_full_legacy);
    wire [7:0] unused_dma_wr_data [0:4];
    assign unused_dma_wr_data[0] = 8'd0;
    assign unused_dma_wr_data[1] = 8'd0;
    assign unused_dma_wr_data[2] = 8'd0;
    assign unused_dma_wr_data[3] = 8'd0;
    assign unused_dma_wr_data[4] = 8'd0;

    systolic_top #(
        .ROWS(ROWS), .COLS(COLS),
        .IFM_W(IFM_W), .WEIGHT_W(WEIGHT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_FIFO_DEPTH), .IFM_FIFO_AW(IFM_FIFO_AW),
        .WGT_FIFO_DEPTH(WGT_FIFO_DEPTH), .WGT_FIFO_AW(WGT_FIFO_AW),
        .PSUM_FIFO_DEPTH(PSUM_FIFO_DEPTH), .PSUM_FIFO_AW(PSUM_FIFO_AW),
        .TAIL_CYCLES_CONFIG(TAIL_CYCLES_CONFIG),
        .USE_DMA_IFM(0)
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
endmodule

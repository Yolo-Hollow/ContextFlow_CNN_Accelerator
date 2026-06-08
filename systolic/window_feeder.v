`timescale 1ns / 1ps

// Line-buffer backed window feeder.
// It owns oy/ox traversal and emits one 32-lane IFM window whenever the
// requested rows are present and downstream IFM FIFOs can accept a beat.
module window_feeder #(
    parameter FM_W = 416,
    parameter FM_H = 416,
    parameter AW   = 9,
    parameter ROWS = 32,
    parameter BANKS = 5
) (
    input  clk,
    input  rst,
    input  start,

    input  [AW-1:0] fm_h,
    input  [AW-1:0] fm_w,
    input  [AW-1:0] ofm_h,
    input  [AW-1:0] ofm_w,
    input  [AW-1:0] tile_oy_base,
    input  [AW-1:0] tile_ofm_h,
    input  [1:0]    stride,
    input  [1:0]    pad,
    input  [13:0]   pass_base_k,

    // Row fill request to an external DMA/source.
    output          fill_req,
    output [AW-1:0] fill_fy,

    // Row write path from the external source into the internal line buffer.
    input  [BANKS-1:0] dma_bank_wr_en,
    input  [AW-1:0] dma_wr_x,
    input  [AW:0]   dma_wr_fy,
    input  [7:0]    dma_wr_data [0:BANKS-1],
    input           dma_line_advance,

    // Downstream IFM FIFO backpressure.
    input           ifm_fifo_full_any,
    output [ROWS*8-1:0] ifm_data,
    output          ifm_valid,

    output [AW-1:0] cur_oy,
    output [AW-1:0] cur_ox,
    output          window_ready,
    output          perf_feed_push,
    output          perf_feed_fifo_stall,
    output          perf_feed_win_not_ready,
    output          busy,
    output          done
);
    wire [7:0] lb_rd [0:BANKS-1][0:2][0:2];
    wire [AW:0] line_fy [0:2];
    wire line_valid [0:2];
    wire [1:0] line_wr_ptr;

    wire signed [AW+1:0] rd_fx0_s = $signed({1'b0, cur_ox}) *
                                    $signed({{AW{1'b0}}, stride}) -
                                    $signed({{AW{1'b0}}, pad});
    wire signed [AW+1:0] rd_fx1_s = rd_fx0_s + 1;
    wire signed [AW+1:0] rd_fx2_s = rd_fx0_s + 2;
    wire [AW-1:0] rd_x0 = ((rd_fx0_s < 0) || (rd_fx0_s >= $signed({1'b0, fm_w}))) ?
                          {AW{1'b0}} : rd_fx0_s[AW-1:0];
    wire [AW-1:0] rd_x1 = ((rd_fx1_s < 0) || (rd_fx1_s >= $signed({1'b0, fm_w}))) ?
                          {AW{1'b0}} : rd_fx1_s[AW-1:0];
    wire [AW-1:0] rd_x2 = ((rd_fx2_s < 0) || (rd_fx2_s >= $signed({1'b0, fm_w}))) ?
                          {AW{1'b0}} : rd_fx2_s[AW-1:0];

    line_buffer_5bank #(.FM_W(FM_W), .AW(AW), .BANKS(BANKS)) u_linebuf (
        .clk(clk), .rst(rst),
        .bank_wr_en(dma_bank_wr_en),
        .wr_x(dma_wr_x),
        .wr_data(dma_wr_data),
        .line_advance(dma_line_advance),
        .wr_fy(dma_wr_fy),
        .rd_x0(rd_x0), .rd_x1(rd_x1), .rd_x2(rd_x2),
        .rd_data(lb_rd),
        .line_fy_out(line_fy),
        .line_valid_out(line_valid),
        .wr_ptr_out(line_wr_ptr)
    );

    wire [ROWS*8-1:0] window_data;
    wire window_ifm_valid;
    window_extract #(.FM_W(FM_W), .FM_H(FM_H), .AW(AW), .ROWS(ROWS), .BANKS(BANKS)) u_window (
        .fm_h(fm_h),
        .fm_w(fm_w),
        .stride(stride),
        .pad(pad),
        .oy(cur_oy),
        .ox(cur_ox),
        .pass_base_k(pass_base_k),
        .lb_data(lb_rd),
        .line_fy(line_fy),
        .line_valid(line_valid),
        .lb_valid(1'b1),
        .ifm_data(window_data),
        .ifm_valid(window_ifm_valid),
        .window_ready(window_ready)
    );

    wire row_start;
    wire row_done;
    wire [AW-1:0] row_oy;

    line_stream_ctrl #(.AW(AW)) u_line_ctrl (
        .clk(clk),
        .rst(rst),
        .start(start),
        .fm_h(fm_h),
        .ofm_h(ofm_h),
        .start_oy(tile_oy_base),
        .tile_ofm_h(tile_ofm_h),
        .stride(stride),
        .pad(pad),
        .fill_done(dma_line_advance),
        .compute_done(row_done),
        .fill_req(fill_req),
        .fill_fy(fill_fy),
        .compute_start(row_start),
        .compute_oy(row_oy),
        .busy(busy),
        .done(done)
    );

    wire row_active;
    wire ifm_push;
    wire row_fifo_stall;
    wire row_window_not_ready;
    window_stream_ctrl #(.AW(AW)) u_window_ctrl (
        .clk(clk),
        .rst(rst),
        .start(row_start),
        .start_oy(row_oy),
        .ofm_w(ofm_w),
        .window_ready(window_ready),
        .ifm_fifo_full_any(ifm_fifo_full_any),
        .active(row_active),
        .oy(cur_oy),
        .ox(cur_ox),
        .ifm_push(ifm_push),
        .fifo_stall(row_fifo_stall),
        .window_not_ready(row_window_not_ready),
        .row_done(row_done)
    );

    assign ifm_data = window_data;
    assign ifm_valid = ifm_push && window_ifm_valid;
    assign perf_feed_push = ifm_valid;
    assign perf_feed_fifo_stall = row_fifo_stall;
    assign perf_feed_win_not_ready = row_window_not_ready;
endmodule

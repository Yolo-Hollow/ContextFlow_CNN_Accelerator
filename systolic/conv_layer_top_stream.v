`timescale 1ns / 1ps
// Small integrated layer top for the current stream architecture.
//
// This module still exposes simple "fill" handshakes for bias/weight/IFM data,
// so a testbench or later DMA engine can provide data. Internally it connects:
// scheduler -> weight loader -> feeder/core -> psum stream/drain -> ping-pong.
module conv_layer_top_stream #(
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
    input  start,
    output busy,
    output reg done,

    input  [8:0] fm_h,
    input  [8:0] fm_w,
    input  [8:0] ofm_h,
    input  [8:0] ofm_w,
    input  [1:0] conv_stride,
    input  [1:0] conv_pad,
    input  [10:0] k_total,
    input  [10:0] cout_total,
    input  [15:0] num_pixels,
    input  [8:0] tile_oy_base,
    input  [8:0] tile_ofm_h,
    input  [OFM_ADDR_W-1:0] tile_pixel_base,
    input  pool_enable,
    input  [1:0] pool_stride,

    output bias_load_req,
    input  bias_load_done,
    output [10:0] current_cout_base,
    output [10:0] current_pass_base_k,

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

    output final_valid,
    output [PSUM_BUF_AW-1:0] final_addr,
    output [COLS*2*PSUM_W-1:0] final_data,
    output [10:0] final_cout_base,
    output [COLS*2-1:0] final_channel_valid,

    input  [COLS*2*MULT_W-1:0]  quant_mult_flat,
    input  [COLS*2*SHIFT_W-1:0] quant_shift_flat,
    input  [COLS*2*ZP_W-1:0]    quant_zp_flat,
    input  [1:0]                 activation_mode,
    input                        act_lut_wr_en,
    input  [7:0]                 act_lut_wr_addr,
    input  [7:0]                 act_lut_wr_data,
    output                      ofm_valid,
    output [PSUM_BUF_AW-1:0]    ofm_addr,
    output [10:0]               ofm_cout_base,
    output [COLS*2-1:0]         ofm_channel_valid,
    output [COLS*2*8-1:0]       ofm_data,

    output                      ofm_mem_wr_en,
    input                       ofm_mem_wr_ready,
    output [OFM_ADDR_W-1:0]     ofm_mem_wr_addr,
    output [7:0]                ofm_mem_wr_data,
    output                      ofm_packet_full
);
    wire [10:0] sched_pass_base_k;
    wire [10:0] sched_cout_base;
    wire [10:0] sched_cout_valid;
    wire [15:0] sched_num_pixels;
    wire sched_first_pass;
    wire sched_final_pass;
    wire sched_use_ext_psum;
    wire sched_use_psum_stream;
    wire sched_bias_start;
    wire sched_weight_start;
    wire sched_feeder_start;
    wire sched_compute_start;
    wire sched_drain_start;
    wire sched_busy;
    wire sched_done;
    reg  sched_weight_done;
    wire feeder_done;
    wire compute_done;
    wire drain_done;
    wire drain_packet_ready;
    wire drain_packet_valid;
    wire [PSUM_BUF_AW-1:0] drain_packet_addr;
    wire [COLS*2*PSUM_W-1:0] drain_packet_data;
    wire drain_packet_is_final;
    wire final_fifo_ready;
    wire final_fifo_valid;
    wire [PSUM_BUF_AW-1:0] final_fifo_addr;
    wire [10:0] final_fifo_cout_base;
    wire [COLS*2-1:0] final_fifo_channel_valid;
    wire [COLS*2*PSUM_W-1:0] final_fifo_data;
    wire final_fifo_full;
    wire rq_fifo_ready;
    wire rq_fifo_valid;
    wire [PSUM_BUF_AW-1:0] rq_fifo_addr;
    wire [10:0] rq_fifo_cout_base;
    wire [COLS*2-1:0] rq_fifo_channel_valid;
    wire [COLS*2*8-1:0] rq_fifo_data;
    wire rq_fifo_full;
    wire rq_in_ready;
    wire act_in_ready;

    assign current_cout_base = sched_cout_base;
    assign current_pass_base_k = sched_pass_base_k;
    reg bias_req_r;
    assign bias_load_req = bias_req_r;
    wire ofm_wb_busy;
    wire ofm_post_busy;
    reg done_pending;
    reg [3:0] done_drain_cnt;
    assign busy = sched_busy || done_pending || ofm_post_busy;

    layer_scheduler_stream #(.K_TILE(K_TILE), .COUT_TILE(COUT_TILE)) u_sched (
        .clk(clk), .rst(rst), .start(start), .busy(sched_busy), .done(sched_done),
        .k_total(k_total), .cout_total(cout_total), .num_pixels(num_pixels),
        .pass_base_k(sched_pass_base_k), .cout_base(sched_cout_base),
        .cout_valid(sched_cout_valid),
        .num_pixels_out(sched_num_pixels),
        .is_first_pass(sched_first_pass), .is_final_pass(sched_final_pass),
        .use_ext_psum(sched_use_ext_psum), .use_psum_stream(sched_use_psum_stream),
        .psum_wr_bank(), .psum_rd_bank(),
        .bias_load_start(sched_bias_start), .bias_load_done(bias_load_done),
        .weight_load_start(sched_weight_start), .weight_load_done(sched_weight_done),
        .feeder_start(sched_feeder_start), .feeder_done(feeder_done),
        .compute_start(sched_compute_start), .compute_done(compute_done),
        .psum_drain_start(sched_drain_start), .psum_drain_done(drain_done)
    );

    always @(posedge clk) begin
        if (rst) begin
            done <= 1'b0;
            done_pending <= 1'b0;
            done_drain_cnt <= 4'd0;
        end else begin
            done <= 1'b0;
            if (sched_done) begin
                done_pending <= 1'b1;
                done_drain_cnt <= 4'd4;
            end else if (done_pending) begin
                if (done_drain_cnt != 4'd0) begin
                    done_drain_cnt <= done_drain_cnt - 4'd1;
                end else if (!ofm_post_busy && !ofm_valid) begin
                    done_pending <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

    reg weight_req_r;
    reg wgt_loader_start;
    wire wgt_loader_done;
    wire [ROWS-1:0] wgt_fifo_full;
    wire [ROWS-1:0] wgt_fifo_wr_en;
    wire [ROWS*WEIGHT_W*2-1:0] wgt_fifo_wr_data;
    assign weight_load_req = weight_req_r;

    always @(posedge clk) begin
        if (rst) begin
            bias_req_r <= 1'b0;
            weight_req_r <= 1'b0;
            wgt_loader_start <= 1'b0;
            sched_weight_done <= 1'b0;
        end else begin
            wgt_loader_start <= 1'b0;
            sched_weight_done <= 1'b0;
            if (sched_bias_start)
                bias_req_r <= 1'b1;
            if (bias_req_r && bias_load_done)
                bias_req_r <= 1'b0;
            if (sched_weight_start)
                weight_req_r <= 1'b1;
            if (weight_req_r && weight_tile_ready) begin
                weight_req_r <= 1'b0;
                wgt_loader_start <= 1'b1;
            end
            if (wgt_loader_done)
                sched_weight_done <= 1'b1;
        end
    end

    weight_tile_loader #(
        .ROWS(ROWS), .COLS(COLS), .WEIGHT_W(WEIGHT_W), .ADDR_W(WGT_TILE_AW)
    ) u_weight_loader (
        .clk(clk), .rst(rst),
        .tile_wr_en(wgt_tile_wr_en), .tile_wr_addr(wgt_tile_wr_addr), .tile_wr_data(wgt_tile_wr_data),
        .start(wgt_loader_start), .busy(), .done(wgt_loader_done),
        .wgt_fifo_full(wgt_fifo_full),
        .wgt_fifo_wr_en(wgt_fifo_wr_en),
        .wgt_fifo_wr_data(wgt_fifo_wr_data)
    );

    reg [PSUM_W-1:0] bias_col0;
    reg [PSUM_W-1:0] partial_col0;
    always @(posedge clk) begin
        if (rst) begin
            bias_col0 <= {PSUM_W{1'b0}};
            partial_col0 <= {PSUM_W{1'b0}};
        end else begin
            if (bias_wr_en && bias_wr_addr == 6'd0)
                bias_col0 <= bias_wr_data;
            if (drain_packet_valid && !drain_packet_is_final && drain_packet_addr == {PSUM_BUF_AW{1'b0}})
                partial_col0 <= drain_packet_data[PSUM_W-1:0];
        end
    end

    wire [COLS*2*PSUM_W-1:0] psum_stream_data;
    wire psum_stream_valid;
    wire compute_fire;
    wire [31:0] psum_fifo_rd_en;
    wire [COLS*PSUM_W*2-1:0] psum_fifo_rd_data;
    wire [31:0] psum_fifo_empty;
    wire [ROWS-1:0] ifm_fifo_full;

    wire pp_wr_en = drain_packet_valid && !drain_packet_is_final;
    wire [PSUM_BUF_AW-1:0] pp_wr_addr = drain_packet_addr;
    wire [COLS*2*PSUM_W-1:0] pp_wr_data = drain_packet_data;
    wire pp_rd_en;
    wire pp_rd_bank;
    wire [PSUM_BUF_AW-1:0] pp_rd_addr;
    wire [COLS*2*PSUM_W-1:0] pp_rd_data;
    wire pp_rd_valid;

    psum_pingpong_buffer #(
        .DATA_W(COLS*2*PSUM_W), .DEPTH(PSUM_BUF_DEPTH), .AW(PSUM_BUF_AW)
    ) u_pp (
        .clk(clk), .rst(rst),
        .wr_en(pp_wr_en), .wr_bank(1'b0), .wr_addr(pp_wr_addr), .wr_data(pp_wr_data),
        .rd_en(pp_rd_en), .rd_bank(pp_rd_bank), .rd_addr(pp_rd_addr),
        .rd_data(pp_rd_data), .rd_valid(pp_rd_valid)
    );

    psum_stream_feeder #(.DATA_W(COLS*2*PSUM_W), .AW(PSUM_BUF_AW)) u_psum_stream (
        .clk(clk), .rst(rst), .start(sched_compute_start), .compute_fire(compute_fire),
        .is_first_pass(sched_first_pass), .use_ext_psum(sched_use_ext_psum),
        .bias_data({COLS*2*PSUM_W{1'b0}}),
        .rd_bank(1'b0), .rd_en(pp_rd_en), .rd_bank_out(pp_rd_bank), .rd_addr(pp_rd_addr),
        .rd_data(pp_rd_data), .rd_valid(pp_rd_valid),
        .psum_top_data(psum_stream_data), .psum_top_valid(psum_stream_valid),
        .pixel_addr()
    );

    systolic_top_feeder #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WEIGHT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_FIFO_DEPTH), .IFM_FIFO_AW(IFM_FIFO_AW),
        .WGT_FIFO_DEPTH(WGT_FIFO_DEPTH), .WGT_FIFO_AW(WGT_FIFO_AW),
        .PSUM_FIFO_DEPTH(PSUM_FIFO_DEPTH), .PSUM_FIFO_AW(PSUM_FIFO_AW),
        .FM_W_MAX(FM_W_MAX), .FM_H_MAX(FM_H_MAX), .IFM_BANKS(IFM_BANKS)
    ) u_top (
        .clk(clk), .rst(rst),
        .feeder_start(sched_feeder_start), .feeder_done(feeder_done), .feeder_busy(),
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .compute_start(sched_compute_start), .num_pixels(sched_num_pixels),
        .compute_done(compute_done), .compute_fire_out(compute_fire),
        .fm_h(fm_h), .fm_w(fm_w), .ofm_h(ofm_h), .ofm_w(ofm_w),
        .tile_oy_base(tile_oy_base), .tile_ofm_h(tile_ofm_h),
        .conv_stride(conv_stride), .conv_pad(conv_pad), .pass_base_k(sched_pass_base_k),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .is_first_pass(sched_first_pass), .psum_top_ext({COLS*2*PSUM_W{1'b0}}),
        .use_ext_psum(sched_use_ext_psum),
        .psum_stream_data(psum_stream_data), .psum_stream_valid(psum_stream_valid),
        .use_psum_stream(sched_use_psum_stream),
        .wgt_fifo_wr_en(wgt_fifo_wr_en), .wgt_fifo_wr_data(wgt_fifo_wr_data),
        .wgt_fifo_full(wgt_fifo_full),
        .psum_fifo_rd_en(psum_fifo_rd_en), .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_empty(psum_fifo_empty), .ifm_fifo_full(ifm_fifo_full)
    );

    wire [PSUM_W-1:0] drain_baseline = sched_use_ext_psum ? partial_col0 : bias_col0;

    psum_drain_writer #(.COLS(COLS), .PSUM_W(PSUM_W), .AW(PSUM_BUF_AW)) u_drain (
        .clk(clk), .rst(rst), .start(sched_drain_start), .busy(), .done(drain_done),
        .num_pixels(sched_num_pixels), .baseline_col0(drain_baseline),
        .is_final_pass(sched_final_pass),
        .psum_fifo_rd_en(psum_fifo_rd_en), .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_empty(psum_fifo_empty),
        .packet_valid(drain_packet_valid), .packet_ready(drain_packet_ready),
        .packet_addr(drain_packet_addr),
        .packet_data(drain_packet_data), .packet_is_final(drain_packet_is_final)
    );

    assign final_valid = drain_packet_valid && drain_packet_is_final;
    assign final_addr = drain_packet_addr;
    assign final_data = drain_packet_data;
    assign final_cout_base = sched_cout_base;
    genvar vc;
    generate
        for (vc = 0; vc < COLS*2; vc = vc + 1) begin : final_mask_gen
            assign final_channel_valid[vc] = (vc < sched_cout_valid);
        end
    endgenerate

    assign drain_packet_ready = !drain_packet_is_final || final_fifo_ready;

    psum_packet_fifo #(
        .DATA_W(COLS*2*PSUM_W), .MASK_W(COLS*2), .ADDR_W(PSUM_BUF_AW),
        .DEPTH(OFM_FIFO_DEPTH), .AW(OFM_FIFO_AW)
    ) u_final_packet_fifo (
        .clk(clk), .rst(rst),
        .in_valid(final_valid), .in_ready(final_fifo_ready),
        .in_addr(final_addr), .in_cout_base(final_cout_base),
        .in_channel_valid(final_channel_valid), .in_data(final_data),
        .out_valid(final_fifo_valid), .out_ready(rq_in_ready),
        .out_addr(final_fifo_addr), .out_cout_base(final_fifo_cout_base),
        .out_channel_valid(final_fifo_channel_valid), .out_data(final_fifo_data),
        .full(final_fifo_full)
    );

    ofm_requant_writer #(
        .COLS(COLS), .PSUM_W(PSUM_W), .MULT_W(MULT_W), .SHIFT_W(SHIFT_W),
        .ZP_W(ZP_W), .ADDR_W(PSUM_BUF_AW)
    ) u_ofm_requant (
        .clk(clk), .rst(rst),
        .packet_valid(final_fifo_valid),
        .packet_ready(rq_in_ready),
        .packet_addr(final_fifo_addr),
        .packet_cout_base(final_fifo_cout_base), .packet_channel_valid(final_fifo_channel_valid),
        .packet_data(final_fifo_data),
        .mult_flat(quant_mult_flat), .shift_flat(quant_shift_flat), .zp_flat(quant_zp_flat),
        .ofm_ready(rq_fifo_ready),
        .ofm_valid(ofm_valid), .ofm_addr(ofm_addr),
        .ofm_cout_base(ofm_cout_base), .ofm_channel_valid(ofm_channel_valid),
        .ofm_data(ofm_data)
    );

    wire act_valid;
    wire [PSUM_BUF_AW-1:0] act_addr;
    wire [10:0] act_cout_base;
    wire [COLS*2-1:0] act_channel_valid;
    wire [COLS*2*8-1:0] act_data;
    wire act_fifo_ready;
    wire act_fifo_valid;
    wire [PSUM_BUF_AW-1:0] act_fifo_addr;
    wire [10:0] act_fifo_cout_base;
    wire [COLS*2-1:0] act_fifo_channel_valid;
    wire [COLS*2*8-1:0] act_fifo_data;
    wire act_fifo_full;
    wire pool_valid;
    wire pool_in_ready;
    wire [PSUM_BUF_AW-1:0] pool_addr;
    wire [10:0] pool_cout_base;
    wire [COLS*2-1:0] pool_channel_valid;
    wire [COLS*2*8-1:0] pool_data;
    assign ofm_post_busy = ofm_wb_busy || act_fifo_valid || act_fifo_full ||
                           rq_fifo_valid || rq_fifo_full || final_fifo_valid || final_fifo_full ||
                           ofm_valid || act_valid || pool_valid;

    ofm_packet_fifo #(
        .COUT_TILE(COLS*2), .ADDR_W(PSUM_BUF_AW),
        .DEPTH(OFM_FIFO_DEPTH), .AW(OFM_FIFO_AW)
    ) u_rq_packet_fifo (
        .clk(clk), .rst(rst),
        .in_valid(ofm_valid), .in_ready(rq_fifo_ready),
        .in_addr(ofm_addr), .in_cout_base(ofm_cout_base),
        .in_channel_valid(ofm_channel_valid), .in_data(ofm_data),
        .out_valid(rq_fifo_valid), .out_ready(act_in_ready),
        .out_addr(rq_fifo_addr), .out_cout_base(rq_fifo_cout_base),
        .out_channel_valid(rq_fifo_channel_valid), .out_data(rq_fifo_data),
        .full(rq_fifo_full), .almost_full()
    );

    ofm_activation #(.COUT_TILE(COLS*2), .ADDR_W(PSUM_BUF_AW)) u_activation (
        .clk(clk), .rst(rst), .mode(activation_mode),
        .in_valid(rq_fifo_valid), .in_ready(act_in_ready),
        .in_addr(rq_fifo_addr), .in_cout_base(rq_fifo_cout_base),
        .in_channel_valid(rq_fifo_channel_valid), .in_data(rq_fifo_data),
        .lut_wr_en(act_lut_wr_en), .lut_wr_addr(act_lut_wr_addr), .lut_wr_data(act_lut_wr_data),
        .out_valid(act_valid), .out_ready(pool_in_ready),
        .out_addr(act_addr), .out_cout_base(act_cout_base),
        .out_channel_valid(act_channel_valid), .out_data(act_data)
    );

    ofm_pooling #(
        .COUT_TILE(COLS*2), .ADDR_W(PSUM_BUF_AW), .OFM_W_MAX(FM_W_MAX)
    ) u_pooling (
        .clk(clk), .rst(rst),
        .pool_enable(pool_enable), .pool_stride(pool_stride),
        .conv_ofm_w(ofm_w),
        .in_valid(act_valid), .in_ready(pool_in_ready),
        .in_addr(act_addr), .in_cout_base(act_cout_base),
        .in_channel_valid(act_channel_valid), .in_data(act_data),
        .out_valid(pool_valid), .out_ready(act_fifo_ready),
        .out_addr(pool_addr), .out_cout_base(pool_cout_base),
        .out_channel_valid(pool_channel_valid), .out_data(pool_data)
    );

    ofm_packet_fifo #(
        .COUT_TILE(COLS*2), .ADDR_W(PSUM_BUF_AW),
        .DEPTH(OFM_FIFO_DEPTH), .AW(OFM_FIFO_AW)
    ) u_ofm_packet_fifo (
        .clk(clk), .rst(rst),
        .in_valid(pool_valid), .in_ready(act_fifo_ready),
        .in_addr(pool_addr), .in_cout_base(pool_cout_base),
        .in_channel_valid(pool_channel_valid), .in_data(pool_data),
        .out_valid(act_fifo_valid), .out_ready(!ofm_packet_full),
        .out_addr(act_fifo_addr), .out_cout_base(act_fifo_cout_base),
        .out_channel_valid(act_fifo_channel_valid), .out_data(act_fifo_data),
        .full(act_fifo_full), .almost_full()
    );

    ofm_writeback #(
        .COUT_TILE(COLS*2), .PIXEL_AW(PSUM_BUF_AW), .ADDR_W(OFM_ADDR_W),
        .FIFO_DEPTH(OFM_FIFO_DEPTH), .FIFO_AW(OFM_FIFO_AW)
    ) u_ofm_writeback (
        .clk(clk), .rst(rst),
        .packet_valid(act_fifo_valid), .packet_pixel(act_fifo_addr),
        .packet_cout_base(act_fifo_cout_base),
        .packet_channel_valid(act_fifo_channel_valid), .packet_data(act_fifo_data),
        .packet_full(ofm_packet_full), .cout_total(cout_total), .pixel_base(tile_pixel_base),
        .wr_en(ofm_mem_wr_en), .wr_ready(ofm_mem_wr_ready),
        .wr_addr(ofm_mem_wr_addr), .wr_data(ofm_mem_wr_data),
        .busy(ofm_wb_busy)
    );
endmodule

`timescale 1ns / 1ps
// Small integrated layer top for the current stream architecture.
//
// This module still exposes simple "fill" handshakes for bias/weight/IFM data,
// so a testbench or later DMA engine can provide data. Internally it connects:
// scheduler -> weight loader -> feeder/core -> psum stream/drain -> ping-pong.
`ifndef SYSTOLIC_TAIL_CYCLES_CONFIG
`define SYSTOLIC_TAIL_CYCLES_CONFIG 0
`endif

module conv_layer_top_stream #(
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
    input  start,
    output busy,
    output reg done,
    output perf_compute_fire,
    output perf_stage_bias,
    output perf_stage_weight,
    output perf_stage_feeder,
    output perf_stage_compute,
    output perf_stage_drain,
    output perf_stage_ofm_post,
    output perf_feed_fill_wait,
    output perf_feed_push,
    output perf_feed_fifo_stall,
    output perf_feed_win_not_ready,
    output perf_comp_wload,
    output perf_comp_active,
    output perf_comp_ifm_stall,
    output perf_comp_tail,
    output [31:0] perf_tail_cycles_configured,
    output perf_drain_fifo_empty_wait,
    output perf_drain_fifo_empty_sticky,
    output perf_drain_read_fire,
    output perf_drain_packet_fire,
    output perf_drain_ready_stall,
    output perf_drain_internal_full_wait,
    output perf_prefetch_start,
    output perf_prefetch_weight_done,
    output perf_prefetch_feed_done,
    output perf_prefetch_hit,
    output perf_prefetch_miss,
    output perf_prefetch_stall,
    output perf_psumovl_start,
    output perf_psumovl_hit,
    output perf_psumovl_wait_psum,
    output perf_psumovl_underflow,
    output perf_collect_packet_fire,
    output perf_collect_partial_write,
    output perf_collect_final_write,
    output perf_collect_context_push,
    output perf_collect_context_pop,
    output perf_collect_context_full_stall,
    output perf_collect_column_empty_wait,
    output [31:0] perf_pass_count,
    output [31:0] perf_pass_start_to_first_fire,
    output [31:0] perf_pass_first_to_last_fire,
    output [31:0] perf_pass_last_fire_to_done,
    output [31:0] perf_pass_collect_first_wait,
    output [31:0] perf_pass_collect_column_empty,
    output [31:0] perf_pass_replay_active_during_compute,
    output [31:0] perf_pass_compute_idle_in_stage,
    output [31:0] pass_trace_weight_done,
    output [31:0] pass_trace_feed_start,
    output [31:0] pass_trace_feed_ready,
    output [31:0] pass_trace_feed_done,
    output [31:0] pass_trace_compute_start,
    output [31:0] pass_trace_first_fire,
    output [31:0] pass_trace_last_fire,
    output [31:0] pass_trace_compute_done,
    output [31:0] pass_trace_collect_first,
    output [31:0] pass_trace_collect_last,
    output [31:0] pass_trace_pass_done,
    output        pass_trace_valid,
    output [31:0] col_trace_first_wr,
    output [31:0] col_trace_last_wr,
    output [31:0] col_trace_wr_count,
    output [31:0] col_trace_empty_wait,
    output [31:0] col_trace_missing_mask_or,
    output [31:0] col_trace_missing_mask_first,
    output [31:0] col_trace_missing_mask_last,
    output        col_trace_valid,

    input  [8:0] fm_h,
    input  [8:0] fm_w,
    input  [8:0] ofm_h,
    input  [8:0] ofm_w,
    input  [1:0] conv_stride,
    input  [1:0] conv_pad,
    input        kernel_1x1,
    input        stream_raw_hwc_mode,
    input  [13:0] k_total,
    input  [10:0] cout_total,
    input  [15:0] num_pixels,
    input  [15:0] tail_cycles_config,
    input  [15:0] raw_hwc_compute_start_level,
    input         early_drain_enable,
    input         pass_prefetch_enable,
    input         psum_stream_overlap_enable,
    input         continuous_psum_enable,
    input         column_psum_enable,
    input         during_compute_prefetch_enable,
    input         pass_trace_enable,
    input  [7:0]  pass_trace_cout_block,
    input  [15:0] pass_trace_k_pass,
    input  [4:0]  col_trace_selected_col,
    input         raw_replay_active,
    input  [8:0] tile_oy_base,
    input  [8:0] tile_ofm_h,
    input  [OFM_ADDR_W-1:0] tile_pixel_base,
    input  pool_enable,
    input  [1:0] pool_stride,

    output bias_load_req,
    input  bias_load_done,
    output [10:0] current_cout_base,
    output [13:0] current_pass_base_k,
    output [13:0] current_feeder_pass_base_k,

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
    wire [13:0] sched_pass_base_k;
    wire [10:0] sched_cout_base;
    wire [10:0] sched_cout_valid;
    wire [15:0] sched_num_pixels;
    wire sched_first_pass;
    wire sched_final_pass;
    wire sched_use_ext_psum;
    wire sched_use_psum_stream;
    wire sched_psum_wr_bank;
    wire sched_psum_rd_bank;
    wire sched_bias_start;
    wire sched_weight_start;
    wire sched_feeder_start;
    wire sched_compute_start;
    wire sched_drain_start;
    wire [13:0] sched_feeder_pass_base_k;
    wire sched_busy;
    wire sched_done;
    reg  sched_weight_done;
    wire feeder_done;
    wire feeder_compute_ready;
    wire feeder_overlap_mode = stream_raw_hwc_mode && (raw_hwc_compute_start_level != 16'd0);
    wire compute_done;
    wire compute_fire;
    wire drain_done;
    wire [31:0] psum_fifo_rd_en;
    wire [31:0] legacy_psum_fifo_rd_en;
    wire [31:0] collector_psum_fifo_rd_en;
    wire [COLS*PSUM_W*2-1:0] psum_fifo_rd_data;
    wire [31:0] psum_fifo_empty;
    wire [31:0] psum_fifo_wr_en_dbg;
    wire [31:0] psum_col_mask = (32'h1 << COLS) - 1;
    wire psum_drain_data_ready = ((psum_fifo_empty & psum_col_mask) == 32'd0);
    wire drain_packet_ready;
    wire drain_packet_valid;
    wire [PSUM_BUF_AW-1:0] drain_packet_addr;
    wire [COLS*2*PSUM_W-1:0] drain_packet_data;
    wire drain_packet_is_final;
    wire drain_packet_wr_bank;
    wire [10:0] drain_packet_cout_base;
    wire [10:0] drain_packet_cout_valid;
    wire drain_packet_fire;
    wire legacy_drain_packet_valid;
    wire [PSUM_BUF_AW-1:0] legacy_drain_packet_addr;
    wire [COLS*2*PSUM_W-1:0] legacy_drain_packet_data;
    wire legacy_drain_packet_is_final;
    wire legacy_drain_packet_fire;
    wire drain_read_fire;
    wire drain_ready_stall;
    wire drain_internal_full_wait;
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
    wire collector_ctx_ready;
    wire collector_context_start;
    wire collector_context_done;
    wire collector_partial_done;
    wire collector_final_done;
    wire collector_context_active;
    wire collector_context_wr_bank;
    wire collector_context_is_final;
    wire collector_trace_context_active;
    wire collector_trace_context_done;
    wire collector_packet_valid;
    wire [PSUM_BUF_AW-1:0] collector_packet_addr;
    wire [COLS*2*PSUM_W-1:0] collector_packet_data;
    wire collector_packet_is_final;
    wire collector_packet_wr_bank;
    wire [10:0] collector_packet_cout_base;
    wire [10:0] collector_packet_cout_valid;
    wire collector_packet_ready =
        !collector_packet_is_final || final_fifo_ready;
    wire column_psum_active = continuous_psum_enable && column_psum_enable;
    wire column_ctx_ready;
    wire column_context_start;
    wire column_context_done;
    wire column_partial_done;
    wire column_context_active;
    wire column_context_idle;
    wire column_context_wr_bank;
    wire column_trace_context_active;
    wire column_trace_context_done;
    wire column_perf_context_push;
    wire column_perf_context_pop;
    wire column_perf_context_full_stall;
    wire column_perf_empty_wait;
    wire [31:0] column_psum_fifo_rd_en;
    wire [COLS-1:0] column_wr_en;
    wire column_wr_bank;
    wire [COLS*PSUM_BUF_AW-1:0] column_wr_addr_flat;
    wire [COLS*2*PSUM_W-1:0] column_wr_data_flat;
    wire [COLS-1:0] column_rd_en;
    wire column_rd_bank;
    wire [COLS*PSUM_BUF_AW-1:0] column_rd_addr_flat;
    wire [COLS*2*PSUM_W-1:0] column_rd_data_flat;
    wire [COLS-1:0] column_rd_valid;
    wire [COLS*2*PSUM_W-1:0] column_psum_stream_data;
    wire [COLS-1:0] column_psum_stream_valid;
    wire column_psum_compute_ready;
    wire column_psum_underflow;
    wire column_psum_wait;
    wire [COLS*(PSUM_BUF_AW+1)-1:0] column_available_count_flat;
    wire [COLS-1:0] column_credit0_nonzero;
    wire [COLS-1:0] column_credit1_nonzero;
    reg [PSUM_BUF_AW:0] psum_available_count0;
    reg [PSUM_BUF_AW:0] psum_available_count1;
    reg active_drain_wr_bank;
    reg [PSUM_BUF_AW:0] active_drain_num_pixels;
    reg [PSUM_BUF_AW:0] column_available_count0 [0:COLS-1];
    reg [PSUM_BUF_AW:0] column_available_count1 [0:COLS-1];
    wire trace_pass_start;

    assign current_cout_base = sched_cout_base;
    assign current_pass_base_k = sched_pass_base_k;
    assign current_feeder_pass_base_k = sched_feeder_pass_base_k;
    reg bias_req_r;
    assign bias_load_req = bias_req_r;
    wire ofm_wb_busy;
    wire ofm_post_busy;
    reg done_pending;
    reg [3:0] done_drain_cnt;
    assign busy = sched_busy || done_pending || ofm_post_busy;
    assign perf_stage_ofm_post = done_pending || (!sched_busy && ofm_post_busy);
    assign perf_feed_fill_wait = feeder_fill_req;

    layer_scheduler_stream #(.K_TILE(K_TILE), .COUT_TILE(COUT_TILE)) u_sched (
        .clk(clk), .rst(rst), .start(start), .busy(sched_busy), .done(sched_done),
        .k_total(k_total), .cout_total(cout_total), .num_pixels(num_pixels),
        .pass_base_k(sched_pass_base_k), .cout_base(sched_cout_base),
        .cout_valid(sched_cout_valid),
        .num_pixels_out(sched_num_pixels),
        .is_first_pass(sched_first_pass), .is_final_pass(sched_final_pass),
        .use_ext_psum(sched_use_ext_psum), .use_psum_stream(sched_use_psum_stream),
        .psum_wr_bank(sched_psum_wr_bank), .psum_rd_bank(sched_psum_rd_bank),
        .bias_load_start(sched_bias_start), .bias_load_done(bias_load_done),
        .weight_load_start(sched_weight_start), .weight_load_done(sched_weight_done),
        .feeder_start(sched_feeder_start), .feeder_done(feeder_done),
        .feeder_compute_ready(feeder_compute_ready),
        .feeder_overlap_mode(feeder_overlap_mode),
        .raw_hwc_mode(stream_raw_hwc_mode),
        .early_drain_enable(early_drain_enable),
        .pass_prefetch_enable(pass_prefetch_enable),
        .during_compute_prefetch_enable(during_compute_prefetch_enable),
        .psum_stream_overlap_enable(psum_stream_overlap_enable),
        .continuous_psum_enable(continuous_psum_enable),
        .collector_ctx_ready(column_psum_active ?
                             (sched_final_pass ?
                                (collector_ctx_ready && column_context_idle) :
                                column_ctx_ready) :
                             collector_ctx_ready),
        .collector_partial_credit(column_psum_active ?
            (sched_psum_wr_bank ?
                (&column_credit1_nonzero) : (&column_credit0_nonzero)) :
            (sched_psum_wr_bank ? (psum_available_count1 != 0) :
                                  (psum_available_count0 != 0))),
        .collector_context_active(column_context_active || collector_context_active),
        .collector_context_wr_bank(column_context_active ?
                                   column_context_wr_bank : collector_context_wr_bank),
        .collector_context_is_final(column_context_active ? 1'b0 :
                                    collector_context_is_final),
        .collector_final_done(collector_final_done),
        .psum_drain_data_ready(psum_drain_data_ready),
        .psum_drain_packet_fire(drain_packet_fire),
        .compute_fire(compute_fire),
        .compute_start(sched_compute_start), .compute_done(compute_done),
        .psum_drain_start(sched_drain_start), .psum_drain_done(drain_done),
        .feeder_pass_base_k(sched_feeder_pass_base_k),
        .perf_prefetch_start(perf_prefetch_start),
        .perf_prefetch_weight_done(perf_prefetch_weight_done),
        .perf_prefetch_feed_done(perf_prefetch_feed_done),
        .perf_prefetch_hit(perf_prefetch_hit),
        .perf_prefetch_miss(perf_prefetch_miss),
        .perf_prefetch_stall(perf_prefetch_stall),
        .perf_psumovl_start(perf_psumovl_start),
        .perf_psumovl_hit(perf_psumovl_hit),
        .perf_psumovl_wait_psum(perf_psumovl_wait_psum),
        .perf_stage_bias(perf_stage_bias),
        .perf_stage_weight(perf_stage_weight),
        .perf_stage_feeder(perf_stage_feeder),
        .perf_stage_compute(perf_stage_compute),
        .perf_stage_drain(perf_stage_drain)
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
    reg weight_start_pending;
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
            weight_start_pending <= 1'b0;
            wgt_loader_start <= 1'b0;
            sched_weight_done <= 1'b0;
        end else begin
            wgt_loader_start <= 1'b0;
            sched_weight_done <= 1'b0;
            if (sched_bias_start)
                bias_req_r <= 1'b1;
            if (bias_req_r && bias_load_done)
                bias_req_r <= 1'b0;

            if (sched_weight_start) begin
                if (weight_req_r && weight_tile_ready)
                    weight_start_pending <= 1'b1;
                else
                    weight_req_r <= 1'b1;
            end
            if (weight_req_r && weight_tile_ready) begin
                weight_req_r <= 1'b0;
                wgt_loader_start <= 1'b1;
            end else if (!weight_req_r && weight_start_pending) begin
                weight_req_r <= 1'b1;
                weight_start_pending <= 1'b0;
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
        .tile_wr8_en(wgt_tile_wr8_en), .tile_wr8_addr(wgt_tile_wr8_addr),
        .tile_wr8_data(wgt_tile_wr8_data), .tile_wr8_keep(wgt_tile_wr8_keep),
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
            if (drain_packet_fire && !drain_packet_is_final &&
                drain_packet_addr == {PSUM_BUF_AW{1'b0}})
                partial_col0 <= drain_packet_data[PSUM_W-1:0];
        end
    end

    wire [COLS*2*PSUM_W-1:0] psum_stream_data;
    wire psum_stream_valid;
    wire psum_stream_compute_ready;
    wire psum_stream_underflow;
    wire psum_stream_wait;
    assign perf_compute_fire = compute_fire;
    wire [ROWS-1:0] ifm_fifo_full;

    assign psum_fifo_rd_en = column_psum_active ?
        (collector_psum_fifo_rd_en | column_psum_fifo_rd_en) :
        (continuous_psum_enable ? collector_psum_fifo_rd_en : legacy_psum_fifo_rd_en);

    assign drain_packet_valid = continuous_psum_enable ?
        collector_packet_valid : legacy_drain_packet_valid;
    assign drain_packet_addr = continuous_psum_enable ?
        collector_packet_addr : legacy_drain_packet_addr;
    assign drain_packet_data = continuous_psum_enable ?
        collector_packet_data : legacy_drain_packet_data;
    assign drain_packet_is_final = continuous_psum_enable ?
        collector_packet_is_final : legacy_drain_packet_is_final;
    assign drain_packet_wr_bank = continuous_psum_enable ?
        collector_packet_wr_bank : active_drain_wr_bank;
    assign drain_packet_cout_base = continuous_psum_enable ?
        collector_packet_cout_base : sched_cout_base;
    assign drain_packet_cout_valid = continuous_psum_enable ?
        collector_packet_cout_valid : sched_cout_valid;
    assign drain_packet_fire = drain_packet_valid && drain_packet_ready;
    assign legacy_drain_packet_fire =
        legacy_drain_packet_valid && drain_packet_ready;

    wire pp_wr_en = drain_packet_fire && !drain_packet_is_final && !column_psum_active;
    wire pp_wr_bank = drain_packet_wr_bank;
    wire [PSUM_BUF_AW-1:0] pp_wr_addr = drain_packet_addr;
    wire [COLS*2*PSUM_W-1:0] pp_wr_data = drain_packet_data;
    wire pp_rd_en;
    wire pp_rd_bank;
    wire [PSUM_BUF_AW-1:0] pp_rd_addr;
    wire [COLS*2*PSUM_W-1:0] pp_rd_data;
    wire pp_rd_valid;
    wire [PSUM_BUF_AW:0] psum_stream_available_count =
        sched_psum_rd_bank ? psum_available_count1 : psum_available_count0;
    wire [PSUM_BUF_AW:0] sched_num_pixels_ext =
        {1'b0, sched_num_pixels[PSUM_BUF_AW-1:0]};
    wire [PSUM_BUF_AW:0] psum_count_max =
        {1'b1, {PSUM_BUF_AW{1'b0}}};

    assign perf_psumovl_underflow =
        column_psum_active ? column_psum_underflow : psum_stream_underflow;

    genvar cc;
    generate
        for (cc = 0; cc < COLS; cc = cc + 1) begin : column_credit_flags
            assign column_credit0_nonzero[cc] = (column_available_count0[cc] != 0);
            assign column_credit1_nonzero[cc] = (column_available_count1[cc] != 0);
        end
    endgenerate

    integer col_i;
    always @(posedge clk) begin
        if (rst) begin
            active_drain_wr_bank <= 1'b0;
            active_drain_num_pixels <= {(PSUM_BUF_AW+1){1'b0}};
            psum_available_count0 <= {(PSUM_BUF_AW+1){1'b0}};
            psum_available_count1 <= {(PSUM_BUF_AW+1){1'b0}};
            for (col_i = 0; col_i < COLS; col_i = col_i + 1) begin
                column_available_count0[col_i] <= {(PSUM_BUF_AW+1){1'b0}};
                column_available_count1[col_i] <= {(PSUM_BUF_AW+1){1'b0}};
            end
        end else begin
            if (!continuous_psum_enable && sched_drain_start) begin
                active_drain_wr_bank <= sched_psum_wr_bank;
                active_drain_num_pixels <= sched_num_pixels_ext;
            end
            if (!continuous_psum_enable &&
                sched_drain_start && !sched_final_pass) begin
                if (sched_psum_wr_bank)
                    psum_available_count1 <= {(PSUM_BUF_AW+1){1'b0}};
                else
                    psum_available_count0 <= {(PSUM_BUF_AW+1){1'b0}};
            end
            if (continuous_psum_enable &&
                sched_compute_start && !sched_final_pass) begin
                if (sched_psum_wr_bank) begin
                    psum_available_count1 <= {(PSUM_BUF_AW+1){1'b0}};
                    for (col_i = 0; col_i < COLS; col_i = col_i + 1)
                        column_available_count1[col_i] <= {(PSUM_BUF_AW+1){1'b0}};
                end else begin
                    psum_available_count0 <= {(PSUM_BUF_AW+1){1'b0}};
                    for (col_i = 0; col_i < COLS; col_i = col_i + 1)
                        column_available_count0[col_i] <= {(PSUM_BUF_AW+1){1'b0}};
                end
            end
            if (pp_wr_en) begin
                if (drain_packet_wr_bank) begin
                    if (continuous_psum_enable &&
                        drain_packet_addr == {PSUM_BUF_AW{1'b0}})
                        psum_available_count1 <= {{PSUM_BUF_AW{1'b0}}, 1'b1};
                    else if (continuous_psum_enable) begin
                        if (psum_available_count1 < psum_count_max)
                            psum_available_count1 <= psum_available_count1 + 1'b1;
                    end else if (psum_available_count1 < active_drain_num_pixels)
                        psum_available_count1 <= psum_available_count1 + 1'b1;
                end else begin
                    if (continuous_psum_enable &&
                        drain_packet_addr == {PSUM_BUF_AW{1'b0}})
                        psum_available_count0 <= {{PSUM_BUF_AW{1'b0}}, 1'b1};
                    else if (continuous_psum_enable) begin
                        if (psum_available_count0 < psum_count_max)
                            psum_available_count0 <= psum_available_count0 + 1'b1;
                    end else if (psum_available_count0 < active_drain_num_pixels)
                        psum_available_count0 <= psum_available_count0 + 1'b1;
                end
            end
            if (column_psum_active) begin
                for (col_i = 0; col_i < COLS; col_i = col_i + 1) begin
                    if (column_wr_en[col_i]) begin
                        if (column_wr_bank) begin
                            if (column_available_count1[col_i] < psum_count_max)
                                column_available_count1[col_i] <=
                                    column_available_count1[col_i] + 1'b1;
                        end else begin
                            if (column_available_count0[col_i] < psum_count_max)
                                column_available_count0[col_i] <=
                                    column_available_count0[col_i] + 1'b1;
                        end
                    end
                end
            end
        end
    end

    psum_pingpong_buffer #(
        .DATA_W(COLS*2*PSUM_W), .DEPTH(PSUM_BUF_DEPTH), .AW(PSUM_BUF_AW)
    ) u_pp (
        .clk(clk), .rst(rst),
        .wr_en(pp_wr_en), .wr_bank(pp_wr_bank), .wr_addr(pp_wr_addr), .wr_data(pp_wr_data),
        .rd_en(pp_rd_en), .rd_bank(pp_rd_bank), .rd_addr(pp_rd_addr),
        .rd_data(pp_rd_data), .rd_valid(pp_rd_valid)
    );

    psum_stream_feeder #(.DATA_W(COLS*2*PSUM_W), .AW(PSUM_BUF_AW)) u_psum_stream (
        .clk(clk), .rst(rst), .start(sched_compute_start), .compute_fire(compute_fire),
        .is_first_pass(sched_first_pass), .use_ext_psum(sched_use_ext_psum),
        .bias_data({COLS*2*PSUM_W{1'b0}}),
        .rd_bank(sched_psum_rd_bank),
        .overlap_guard_enable(psum_stream_overlap_enable),
        .available_count(psum_stream_available_count),
        .rd_en(pp_rd_en), .rd_bank_out(pp_rd_bank), .rd_addr(pp_rd_addr),
        .rd_data(pp_rd_data), .rd_valid(pp_rd_valid),
        .psum_top_data(psum_stream_data), .psum_top_valid(psum_stream_valid),
        .psum_compute_ready(psum_stream_compute_ready),
        .psum_underflow(psum_stream_underflow),
        .psum_wait(psum_stream_wait),
        .pixel_addr()
    );

    psum_column_pingpong_buffer #(
        .COLS(COLS), .DATA_W(PSUM_W*2),
        .DEPTH(PSUM_BUF_DEPTH), .AW(PSUM_BUF_AW)
    ) u_column_pp (
        .clk(clk), .rst(rst),
        .wr_en(column_wr_en), .wr_bank(column_wr_bank),
        .wr_addr_flat(column_wr_addr_flat),
        .wr_data_flat(column_wr_data_flat),
        .rd_en(column_rd_en), .rd_bank(column_rd_bank),
        .rd_addr_flat(column_rd_addr_flat),
        .rd_data_flat(column_rd_data_flat),
        .rd_valid(column_rd_valid)
    );

    genvar ac;
    generate
        for (ac = 0; ac < COLS; ac = ac + 1) begin : column_avail_pack
            assign column_available_count_flat[(ac+1)*(PSUM_BUF_AW+1)-1 -: (PSUM_BUF_AW+1)] =
                sched_psum_rd_bank ? column_available_count1[ac] :
                                      column_available_count0[ac];
        end
    endgenerate

    psum_column_stream_feeder #(
        .COLS(COLS), .DATA_W(PSUM_W*2), .AW(PSUM_BUF_AW), .COL_DELAY(4)
    ) u_column_psum_stream (
        .clk(clk), .rst(rst),
        .start(sched_compute_start), .compute_fire(compute_fire),
        .use_ext_psum(column_psum_active && sched_use_ext_psum),
        .rd_bank(sched_psum_rd_bank),
        .overlap_guard_enable(psum_stream_overlap_enable),
        .available_count_flat(column_available_count_flat),
        .rd_en(column_rd_en), .rd_bank_out(column_rd_bank),
        .rd_addr_flat(column_rd_addr_flat),
        .rd_data_flat(column_rd_data_flat), .rd_valid(column_rd_valid),
        .psum_top_data_flat(column_psum_stream_data),
        .psum_top_valid(column_psum_stream_valid),
        .psum_compute_ready(column_psum_compute_ready),
        .psum_underflow(column_psum_underflow),
        .psum_wait(column_psum_wait),
        .pixel_addr()
    );

    systolic_top_feeder #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WEIGHT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_FIFO_DEPTH), .IFM_FIFO_AW(IFM_FIFO_AW),
        .WGT_FIFO_DEPTH(WGT_FIFO_DEPTH), .WGT_FIFO_AW(WGT_FIFO_AW),
        .PSUM_FIFO_DEPTH(PSUM_FIFO_DEPTH), .PSUM_FIFO_AW(PSUM_FIFO_AW),
        .FM_W_MAX(FM_W_MAX), .FM_H_MAX(FM_H_MAX), .IFM_BANKS(IFM_BANKS),
        .TAIL_CYCLES_CONFIG(TAIL_CYCLES_CONFIG)
    ) u_top (
        .clk(clk), .rst(rst),
        .feeder_start(sched_feeder_start), .feeder_done(feeder_done), .feeder_busy(),
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .kernel_1x1(kernel_1x1),
        .raw_hwc_mode(stream_raw_hwc_mode),
        .compute_start(sched_compute_start), .num_pixels(sched_num_pixels),
        .tail_cycles_config(tail_cycles_config),
        .raw_hwc_compute_start_level(raw_hwc_compute_start_level),
        .feeder_compute_ready(feeder_compute_ready),
        .compute_done(compute_done), .compute_fire_out(compute_fire),
        .perf_feed_push(perf_feed_push),
        .perf_feed_fifo_stall(perf_feed_fifo_stall),
        .perf_feed_win_not_ready(perf_feed_win_not_ready),
        .perf_comp_wload(perf_comp_wload),
        .perf_comp_active(perf_comp_active),
        .perf_comp_ifm_stall(perf_comp_ifm_stall),
        .perf_comp_tail(perf_comp_tail),
        .perf_tail_cycles_configured(perf_tail_cycles_configured),
        .fm_h(fm_h), .fm_w(fm_w), .ofm_h(ofm_h), .ofm_w(ofm_w),
        .tile_oy_base(tile_oy_base), .tile_ofm_h(tile_ofm_h),
        .conv_stride(conv_stride), .conv_pad(conv_pad), .pass_base_k(sched_pass_base_k),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .vector_ifm_data(vector_ifm_data), .vector_ifm_valid(vector_ifm_valid),
        .vector_ifm_ready(vector_ifm_ready), .vector_packet_done(vector_packet_done),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .is_first_pass(sched_first_pass), .psum_top_ext({COLS*2*PSUM_W{1'b0}}),
        .use_ext_psum(sched_use_ext_psum),
        .psum_stream_data(psum_stream_data), .psum_stream_valid(psum_stream_valid),
        .psum_stream_compute_ready(column_psum_active && sched_use_ext_psum ?
                                   column_psum_compute_ready : psum_stream_compute_ready),
        .use_psum_stream(sched_use_psum_stream),
        .psum_column_stream_data(column_psum_stream_data),
        .psum_column_stream_valid(column_psum_stream_valid),
        .use_column_psum_stream(column_psum_active && sched_use_ext_psum),
        .wgt_fifo_wr_en(wgt_fifo_wr_en), .wgt_fifo_wr_data(wgt_fifo_wr_data),
        .wgt_fifo_full(wgt_fifo_full),
        .psum_fifo_rd_en(psum_fifo_rd_en), .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_empty(psum_fifo_empty),
        .psum_fifo_wr_en_dbg(psum_fifo_wr_en_dbg),
        .ifm_fifo_full(ifm_fifo_full)
    );

    wire [PSUM_W-1:0] drain_baseline = sched_use_ext_psum ? partial_col0 : bias_col0;

    psum_drain_writer #(.COLS(COLS), .PSUM_W(PSUM_W), .AW(PSUM_BUF_AW)) u_drain (
        .clk(clk), .rst(rst),
        .start(sched_drain_start && !continuous_psum_enable),
        .busy(), .done(drain_done),
        .num_pixels(sched_num_pixels), .baseline_col0(drain_baseline),
        .is_final_pass(sched_final_pass),
        .psum_fifo_rd_en(legacy_psum_fifo_rd_en),
        .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_empty(psum_fifo_empty),
        .packet_valid(legacy_drain_packet_valid),
        .packet_ready(drain_packet_ready),
        .packet_addr(legacy_drain_packet_addr),
        .packet_data(legacy_drain_packet_data),
        .packet_is_final(legacy_drain_packet_is_final),
        .fifo_empty_wait(perf_drain_fifo_empty_wait),
        .fifo_empty_wait_sticky(perf_drain_fifo_empty_sticky),
        .drain_read_fire(drain_read_fire),
        .drain_packet_fire(),
        .drain_ready_stall(drain_ready_stall),
        .drain_internal_full_wait(drain_internal_full_wait)
    );

    assign perf_drain_read_fire = drain_read_fire;
    assign perf_drain_packet_fire = legacy_drain_packet_fire;
    assign perf_drain_ready_stall = drain_ready_stall;
    assign perf_drain_internal_full_wait = drain_internal_full_wait;

    psum_output_collector #(
        .COLS(COLS), .PSUM_W(PSUM_W), .ADDR_W(PSUM_BUF_AW),
        .CTX_DEPTH(4), .CTX_AW(2)
    ) u_collector (
        .clk(clk), .rst(rst), .enable(continuous_psum_enable),
        .ctx_valid(sched_compute_start && continuous_psum_enable &&
                   (!column_psum_active || sched_final_pass)),
        .ctx_ready(collector_ctx_ready),
        .ctx_num_pixels(sched_num_pixels),
        .ctx_is_final(sched_final_pass),
        .ctx_wr_bank(sched_psum_wr_bank),
        .ctx_cout_base(sched_cout_base),
        .ctx_cout_valid(sched_cout_valid),
        .ctx_trace_match(trace_pass_start),
        .psum_fifo_rd_en(collector_psum_fifo_rd_en),
        .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_empty(psum_fifo_empty),
        .packet_valid(collector_packet_valid),
        .packet_ready(collector_packet_ready),
        .packet_addr(collector_packet_addr),
        .packet_data(collector_packet_data),
        .packet_is_final(collector_packet_is_final),
        .packet_wr_bank(collector_packet_wr_bank),
        .packet_cout_base(collector_packet_cout_base),
        .packet_cout_valid(collector_packet_cout_valid),
        .context_start(collector_context_start),
        .context_done(collector_context_done),
        .partial_done(collector_partial_done),
        .final_done(collector_final_done),
        .context_active(collector_context_active),
        .context_wr_bank(collector_context_wr_bank),
        .context_is_final(collector_context_is_final),
        .trace_context_active(collector_trace_context_active),
        .trace_context_done(collector_trace_context_done),
        .perf_context_push(perf_collect_context_push),
        .perf_context_pop(perf_collect_context_pop),
        .perf_context_full_stall(perf_collect_context_full_stall),
        .perf_column_empty_wait(perf_collect_column_empty_wait)
    );

    psum_column_output_collector #(
        .COLS(COLS), .PSUM_W(PSUM_W), .ADDR_W(PSUM_BUF_AW),
        .CTX_DEPTH(4), .CTX_AW(2)
    ) u_column_collector (
        .clk(clk), .rst(rst), .enable(column_psum_active),
        .ctx_valid(sched_compute_start && column_psum_active && !sched_final_pass),
        .ctx_ready(column_ctx_ready),
        .ctx_num_pixels(sched_num_pixels),
        .ctx_wr_bank(sched_psum_wr_bank),
        .ctx_trace_match(trace_pass_start),
        .psum_fifo_rd_en(column_psum_fifo_rd_en),
        .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_empty(psum_fifo_empty),
        .col_wr_en(column_wr_en),
        .col_wr_bank(column_wr_bank),
        .col_wr_addr_flat(column_wr_addr_flat),
        .col_wr_data_flat(column_wr_data_flat),
        .context_start(column_context_start),
        .context_done(column_context_done),
        .partial_done(column_partial_done),
        .context_active(column_context_active),
        .context_idle(column_context_idle),
        .context_wr_bank(column_context_wr_bank),
        .trace_context_active(column_trace_context_active),
        .trace_context_done(column_trace_context_done),
        .perf_context_push(column_perf_context_push),
        .perf_context_pop(column_perf_context_pop),
        .perf_context_full_stall(column_perf_context_full_stall),
        .perf_column_empty_wait(column_perf_empty_wait)
    );

    assign perf_collect_packet_fire =
        continuous_psum_enable && (drain_packet_fire || (|column_wr_en));
    assign perf_collect_partial_write =
        continuous_psum_enable &&
        ((drain_packet_fire && !drain_packet_is_final) || (|column_wr_en));
    assign perf_collect_final_write =
        continuous_psum_enable && drain_packet_fire && drain_packet_is_final;

    pass_timeline_monitor #(
        .K_TILE(K_TILE), .COUT_TILE(COUT_TILE)
    ) u_pass_timeline (
        .clk(clk), .rst(rst),
        .layer_start(start), .layer_busy(busy),
        .trace_enable(pass_trace_enable),
        .trace_cout_block(pass_trace_cout_block),
        .trace_k_pass(pass_trace_k_pass),
        .cout_base(sched_cout_base),
        .pass_base_k(sched_pass_base_k),
        .weight_done(wgt_loader_done),
        .feed_start(sched_feeder_start),
        .feed_ready(feeder_compute_ready),
        .feed_done(feeder_done),
        .compute_start(sched_compute_start),
        .compute_fire(compute_fire),
        .compute_done(compute_done),
        .collector_packet_fire(continuous_psum_enable &&
                               (drain_packet_fire || (|column_wr_en))),
        .collector_context_done(continuous_psum_enable ?
                                (collector_context_done || column_context_done) : drain_done),
        .collector_column_empty_wait(perf_collect_column_empty_wait || column_perf_empty_wait),
        .raw_replay_active(raw_replay_active),
        .stage_compute(perf_stage_compute),
        .pass_count(perf_pass_count),
        .start_to_first_fire(perf_pass_start_to_first_fire),
        .first_to_last_fire(perf_pass_first_to_last_fire),
        .last_fire_to_done(perf_pass_last_fire_to_done),
        .collect_first_wait(perf_pass_collect_first_wait),
        .collect_column_empty(perf_pass_collect_column_empty),
        .replay_active_during_compute(perf_pass_replay_active_during_compute),
        .compute_idle_in_stage(perf_pass_compute_idle_in_stage),
        .trace_weight_done(pass_trace_weight_done),
        .trace_feed_start(pass_trace_feed_start),
        .trace_feed_ready(pass_trace_feed_ready),
        .trace_feed_done(pass_trace_feed_done),
        .trace_compute_start(pass_trace_compute_start),
        .trace_first_fire(pass_trace_first_fire),
        .trace_last_fire(pass_trace_last_fire),
        .trace_compute_done(pass_trace_compute_done),
        .trace_collect_first(pass_trace_collect_first),
        .trace_collect_last(pass_trace_collect_last),
        .trace_pass_done(pass_trace_pass_done),
        .trace_pass_start(trace_pass_start),
        .trace_valid(pass_trace_valid)
    );

    coltrace_monitor #(.COLS(COLS)) u_coltrace (
        .clk(clk), .rst(rst),
        .layer_start(start), .layer_busy(busy),
        .trace_enable(pass_trace_enable),
        .trace_pass_start(trace_pass_start),
        .trace_num_pixels(sched_num_pixels),
        .psum_fifo_wr_en(psum_fifo_wr_en_dbg),
        .collector_trace_active(collector_trace_context_active || column_trace_context_active),
        .collector_trace_done(collector_trace_context_done || column_trace_context_done),
        .collector_read_wait(perf_collect_column_empty_wait || column_perf_empty_wait),
        .collector_missing_mask(psum_fifo_empty & psum_col_mask),
        .selected_col(col_trace_selected_col),
        .selected_first_wr(col_trace_first_wr),
        .selected_last_wr(col_trace_last_wr),
        .selected_wr_count(col_trace_wr_count),
        .selected_empty_wait(col_trace_empty_wait),
        .missing_mask_or(col_trace_missing_mask_or),
        .missing_mask_first(col_trace_missing_mask_first),
        .missing_mask_last(col_trace_missing_mask_last),
        .trace_valid(col_trace_valid)
    );

    assign final_valid = drain_packet_valid && drain_packet_is_final;
    assign final_addr = drain_packet_addr;
    assign final_data = drain_packet_data;
    assign final_cout_base = drain_packet_cout_base;
    genvar vc;
    generate
        for (vc = 0; vc < COLS*2; vc = vc + 1) begin : final_mask_gen
            assign final_channel_valid[vc] = (vc < drain_packet_cout_valid);
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

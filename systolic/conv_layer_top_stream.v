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
    parameter TAIL_CYCLES_CONFIG = `SYSTOLIC_TAIL_CYCLES_CONFIG,
    // The column-granular PSUM experiment is intentionally absent from
    // release builds.  Opting in elaborates its collector/RAM/streamer path.
    parameter ENABLE_COLUMN_PSUM = 0,
    // Release AXIS builds bypass the legacy byte/address writeback and expose
    // one complete post-pool COUT packet to a tile-local HWC reorder buffer.
    parameter ENABLE_PACKED_HWC_OFM = 0,
    parameter ENABLE_VECTOR_ONLY_IFM = 0,
    // Reserved build switches for the tagged-context rollout.  They are
    // propagated here now so release/debug profiles share one hierarchy.
    parameter ENABLE_TAGGED_CONTEXT = 0,
    parameter ENABLE_WEIGHT_PRELOAD = 0,
    parameter ENABLE_FAST_CONTEXT_HANDOFF = 0,
    parameter IFM_EPOCH_USE_URAM = 0,
    parameter ENABLE_DETAILED_TRACE = 1
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
    output [15:0] current_feeder_k_pass,

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
    input  [7:0]                 act_lut_rd_addr,
    output [7:0]                 act_lut_rd_data,
    output                      ofm_valid,
    output [PSUM_BUF_AW-1:0]    ofm_addr,
    output [10:0]               ofm_cout_base,
    output [COLS*2-1:0]         ofm_channel_valid,
    output [COLS*2*8-1:0]       ofm_data,

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
    input                       packed_ofm_busy,

    output [31:0]               datapath_error_status,
    output [31:0]               context_alloc_count,
    output [31:0]               context_input_issued_count,
    output [31:0]               context_array_retired_count,
    output [31:0]               context_collector_done_count,
    output [31:0]               context_gap_cycles,
    output [31:0]               ifm_ownership_stall_cycles,
    output [31:0]               weight_ownership_stall_cycles,
    output [31:0]               psum_credit_stall_cycles,
    output [31:0]               context_epoch_mismatch_count,
    output [31:0]               context_mismatch_count,
    output [31:0]               context_ifm_underflow_count,
    output [31:0]               context_psum_underflow_count,
    output [31:0]               context_fifo_drop_count,
    output [31:0]               context_bank_overwrite_count,
    output [31:0]               context_full_stall_cycles
);
    // The legacy column-PSUM collector does not carry epoch/context identity.
    // It is therefore structurally incompatible with the tagged release path.
    initial begin
        if ((ENABLE_TAGGED_CONTEXT != 0) && (ENABLE_COLUMN_PSUM != 0))
            $error("ENABLE_TAGGED_CONTEXT and ENABLE_COLUMN_PSUM cannot be enabled together");
        if ((ENABLE_WEIGHT_PRELOAD != 0) &&
            (ENABLE_TAGGED_CONTEXT == 0))
            $error("ENABLE_WEIGHT_PRELOAD requires ENABLE_TAGGED_CONTEXT");
        if ((ENABLE_FAST_CONTEXT_HANDOFF != 0) &&
            (ENABLE_WEIGHT_PRELOAD == 0))
            $error("ENABLE_FAST_CONTEXT_HANDOFF requires ENABLE_WEIGHT_PRELOAD");
        if ((ENABLE_WEIGHT_PRELOAD != 0) &&
            (ENABLE_FAST_CONTEXT_HANDOFF != 0) &&
            (K_TILE != ROWS))
            $error("release weight staging requires K_TILE == ROWS");
    end

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
    wire [15:0] sched_feeder_k_pass;
    wire sched_busy;
    wire sched_done;
    reg  sched_weight_done;
    wire feeder_done;
    wire feeder_start_ready;
    wire feeder_start_ready_raw;
    wire feeder_compute_ready;
    wire feeder_overlap_mode = stream_raw_hwc_mode && (raw_hwc_compute_start_level != 16'd0);
    wire compute_done;
    wire compute_fire;
    wire compute_context_start;
    wire compute_context_bank;
    wire [7:0] compute_context_epoch;
    wire drain_done;
    wire [31:0] psum_fifo_rd_en;
    wire [31:0] legacy_psum_fifo_rd_en;
    wire [31:0] collector_psum_fifo_rd_en;
    wire [COLS*PSUM_W*2-1:0] psum_fifo_rd_data;
    wire [COLS*10-1:0] psum_fifo_rd_tag;
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
    wire [7:0] collector_context_done_epoch;
    wire collector_partial_done;
    wire collector_final_done;
    wire collector_context_active;
    wire collector_context_wr_bank;
    wire collector_context_is_final;
    wire [7:0] collector_context_epoch;
    wire collector_context_ifm_bank;
    wire [15:0] collector_context_id;
    wire [7:0] collector_context_parent_epoch;
    wire [15:0] collector_context_parent_context_id;
    wire collector_context_first;
    wire collector_context_done_ifm_bank;
    wire [15:0] collector_context_done_context_id;
    wire [7:0] collector_context_done_parent_epoch;
    wire [15:0] collector_context_done_parent_context_id;
    wire collector_context_done_first;
    wire collector_context_done_final;
    wire collector_context_done_wr_bank;
    wire collector_tag_mismatch_sticky;
    wire [31:0] collector_tag_mismatch_count;
    wire collector_fail_stop;
    wire collector_trace_context_active;
    wire collector_trace_context_done;
    wire collector_packet_valid;
    wire [PSUM_BUF_AW-1:0] collector_packet_addr;
    wire [COLS*2*PSUM_W-1:0] collector_packet_data;
    wire collector_packet_is_final;
    wire collector_packet_wr_bank;
    wire [10:0] collector_packet_cout_base;
    wire [10:0] collector_packet_cout_valid;
    wire [7:0] collector_packet_epoch;
    wire collector_packet_ifm_bank;
    wire [15:0] collector_packet_context_id;
    wire [7:0] collector_packet_parent_epoch;
    wire [15:0] collector_packet_parent_context_id;
    wire collector_packet_first;
    wire partial_psum_write_ready;
    wire legacy_partial_psum_write_ready;
    wire collector_packet_ready;
    wire legacy_drain_packet_ready;
    wire column_psum_active = (ENABLE_COLUMN_PSUM != 0) &&
                              continuous_psum_enable && column_psum_enable;
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
    reg active_drain_is_final;
    reg [PSUM_BUF_AW:0] active_drain_num_pixels;
    reg [PSUM_BUF_AW:0] column_available_count0 [0:COLS-1];
    reg [PSUM_BUF_AW:0] column_available_count1 [0:COLS-1];
    wire trace_pass_start;
    wire [31:0] tagged_datapath_error_status;
    wire [31:0] frontend_psum_credit_stall_cycles;
    wire [31:0] frontend_context_epoch_mismatch_count;
    wire [31:0] frontend_context_mismatch_count;
    wire [31:0] frontend_context_psum_underflow_count;
    wire [31:0] frontend_context_fifo_drop_count;
    wire [31:0] frontend_context_bank_overwrite_count;
    wire [31:0] frontend_context_full_stall_cycles;
    wire context_desc_push_ready;
    wire context_desc_pop_valid;
    wire [7:0] context_desc_epoch;
    wire context_desc_ifm_bank;
    wire [OFM_ADDR_W-1:0] context_desc_tile;
    wire [10:0] context_desc_cout_base;
    wire [10:0] context_desc_cout_valid;
    wire [13:0] context_desc_k_pass;
    wire [15:0] context_desc_num_pixels;
    wire context_desc_first;
    wire context_desc_final;
    wire context_desc_psum_rd_bank;
    wire context_desc_psum_wr_bank;
    wire [7:0] context_desc_parent_epoch;
    wire [15:0] context_desc_parent_context;
    wire [15:0] context_desc_context_id;
    wire context_desc_empty;
    wire context_desc_full;
    wire [2:0] context_desc_level;
    wire context_desc_overflow_sticky;
    wire [31:0] context_desc_overflow_count;
    wire context_desc_underflow_sticky;
    wire [31:0] context_desc_underflow_count;
    wire prepared_push_ready;
    wire prepared_pop_valid;
    wire [OFM_ADDR_W-1:0] prepared_tile;
    wire [10:0] prepared_cout_base;
    wire [10:0] prepared_cout_valid;
    wire [13:0] prepared_k_pass;
    wire [15:0] prepared_num_pixels;
    wire prepared_first;
    wire prepared_final;
    wire prepared_psum_rd_bank;
    wire prepared_psum_wr_bank;
    wire prepared_empty;
    wire prepared_full;
    wire prepared_overflow_sticky;
    wire prepared_underflow_sticky;
    wire [31:0] prepared_overflow_count;
    wire [31:0] prepared_underflow_count;
    reg [15:0] next_context_id_q;
    reg issue_context_active_q;
    // In a fast handoff the new context is admitted on the old context's
    // final compute_fire, while the controller's registered done pulse is
    // observed one clock later.  Remember that replacement so the old done
    // cannot clear the new issue descriptor and disable its PSUM feeder.
    reg issue_handoff_done_guard_q;
    reg [7:0] issue_context_epoch_q;
    reg [15:0] issue_context_id_q;
    reg issue_psum_rd_bank_q;
    reg issue_psum_wr_bank_q;
    // Ownership is a monotonic permit for one resident issue descriptor:
    // allocation can make it true, while a legal release cannot revoke it
    // before that context's final input has issued.  Registering the selected
    // result here keeps the PSUM-bank mux out of the fast-handoff ready loop.
    (* KEEP = "TRUE" *) reg issue_psum_owner_permit_q;
    reg [15:0] issue_num_pixels_q;
    reg issue_first_q;
    reg issue_final_q;
    reg [7:0] issue_parent_epoch_q;
    reg [15:0] issue_parent_context_q;
    reg chain_parent_valid_q;
    reg chain_parent_bank_q;
    reg [7:0] chain_parent_epoch_q;
    reg [15:0] chain_parent_context_q;
    reg context_lineage_error_q;
    reg [31:0] context_lineage_error_count_q;
    wire tagged_context_start_ready;
    wire context_admit_fire;
    wire accepted_compute_context_start;
    wire issue_fast_handoff_event =
        (ENABLE_TAGGED_CONTEXT != 0) && context_admit_fire &&
        issue_context_active_q && compute_fire;
    wire context_lifecycle_done = continuous_psum_enable ?
        (collector_context_done || column_context_done) : drain_done;
    wire [7:0] context_lifecycle_done_epoch = collector_context_done ?
        collector_context_done_epoch : context_desc_epoch;
    wire context_lifecycle_done_ifm_bank = collector_context_done ?
        collector_context_done_ifm_bank : context_desc_ifm_bank;
    wire [15:0] context_lifecycle_done_context_id = collector_context_done ?
        collector_context_done_context_id : context_desc_context_id;
    wire [7:0] context_lifecycle_done_parent_epoch = collector_context_done ?
        collector_context_done_parent_epoch : context_desc_parent_epoch;
    wire [15:0] context_lifecycle_done_parent_context =
        collector_context_done ? collector_context_done_parent_context_id :
                                 context_desc_parent_context;
    wire context_lifecycle_done_first = collector_context_done ?
        collector_context_done_first : context_desc_first;
    wire context_lifecycle_done_final = collector_context_done ?
        collector_context_done_final : context_desc_final;
    wire context_lifecycle_done_wr_bank = collector_context_done ?
        collector_context_done_wr_bank : context_desc_psum_wr_bank;
    wire context_done_descriptor_match = context_desc_pop_valid &&
        (context_lifecycle_done_epoch == context_desc_epoch) &&
        (context_lifecycle_done_ifm_bank == context_desc_ifm_bank) &&
        (context_lifecycle_done_context_id == context_desc_context_id) &&
        (context_lifecycle_done_parent_epoch == context_desc_parent_epoch) &&
        (context_lifecycle_done_parent_context ==
            context_desc_parent_context) &&
        (context_lifecycle_done_first == context_desc_first) &&
        (context_lifecycle_done_final == context_desc_final) &&
        (context_lifecycle_done_wr_bank == context_desc_psum_wr_bank);
    wire context_desc_push_valid = context_admit_fire;
    wire context_desc_pop_ready = (ENABLE_TAGGED_CONTEXT != 0) &&
        context_lifecycle_done && context_done_descriptor_match;
    wire context_done_descriptor_mismatch =
        (ENABLE_TAGGED_CONTEXT != 0) && context_lifecycle_done &&
        !context_done_descriptor_match;
    wire collector_packet_descriptor_match = context_desc_pop_valid &&
        (collector_packet_epoch == context_desc_epoch) &&
        (collector_packet_ifm_bank == context_desc_ifm_bank) &&
        (collector_packet_context_id == context_desc_context_id) &&
        (collector_packet_parent_epoch == context_desc_parent_epoch) &&
        (collector_packet_parent_context_id ==
            context_desc_parent_context) &&
        (collector_packet_first == context_desc_first) &&
        (collector_packet_is_final == context_desc_final) &&
        (collector_packet_wr_bank == context_desc_psum_wr_bank);
    wire collector_packet_descriptor_mismatch =
        (ENABLE_TAGGED_CONTEXT != 0) && continuous_psum_enable &&
        collector_packet_valid && !collector_packet_descriptor_match;

    assign current_cout_base = sched_cout_base;
    assign current_pass_base_k = sched_pass_base_k;
    assign current_feeder_pass_base_k = sched_feeder_pass_base_k;
    assign current_feeder_k_pass = sched_feeder_k_pass;
    reg bias_req_r;
    assign bias_load_req = bias_req_r;
    wire ofm_wb_busy;
    wire ofm_post_busy;
    reg done_pending;
    reg [3:0] done_drain_cnt;
    assign busy = sched_busy || done_pending || ofm_post_busy;
    assign perf_stage_ofm_post = done_pending || (!sched_busy && ofm_post_busy);
    assign perf_feed_fill_wait = feeder_fill_req;

    // Capture the descriptor when its feeder allocation is issued, not when
    // the scheduler later exposes a live next-pass state.  This queue is the
    // metadata twin of the two-bank IFM frontend and lets an early compute
    // request remain pending through the current context's final fire.
    wire prepared_push_valid = (ENABLE_TAGGED_CONTEXT != 0) &&
        sched_feeder_start;
    wire [13:0] prepared_push_k_pass = sched_feeder_pass_base_k;
    wire prepared_push_first = prepared_push_k_pass == 14'd0;
    wire [14:0] prepared_push_next_k =
        {1'b0, prepared_push_k_pass} + K_TILE;
    wire prepared_push_final =
        prepared_push_next_k >= {1'b0, k_total};
    // feeder_k_pass is the descriptor being allocated, whereas pass_bank is
    // still the currently executing context during an early prefetch.  The
    // partial-PSUM banks alternate with the K-pass index, so deriving the
    // prepared bank from the captured feeder index avoids sampling the old
    // scheduler bank on a same-edge prefetch pulse.
    wire prepared_push_wr_bank = sched_feeder_k_pass[0];
    wire prepared_push_rd_bank = ~prepared_push_wr_bank;
    assign feeder_start_ready = feeder_start_ready_raw &&
        ((ENABLE_TAGGED_CONTEXT == 0) || prepared_push_ready);

    context_lifecycle_queue #(
        .DEPTH(2), .AW(1), .EPOCH_W(8), .TILE_W(OFM_ADDR_W),
        .COUT_W(11), .K_PASS_W(14), .PIXEL_W(16), .CONTEXT_W(16)
    ) u_prepared_context_queue (
        .clk(clk), .rst(rst),
        .push_valid(prepared_push_valid),
        .push_ready(prepared_push_ready),
        .push_epoch(8'd0), .push_ifm_bank(1'b0),
        .push_tile(tile_pixel_base),
        .push_cout_base(sched_cout_base),
        .push_cout_valid(sched_cout_valid),
        .push_k_pass(prepared_push_k_pass),
        .push_num_pixels(sched_num_pixels),
        .push_first(prepared_push_first),
        .push_final(prepared_push_final),
        .push_psum_rd_bank(prepared_push_rd_bank),
        .push_psum_wr_bank(prepared_push_wr_bank),
        .push_parent_epoch(8'd0), .push_parent_context(16'd0),
        .push_context_id(16'd0),
        .pop_valid(prepared_pop_valid),
        .pop_ready(context_admit_fire),
        .pop_epoch(), .pop_ifm_bank(),
        .pop_tile(prepared_tile),
        .pop_cout_base(prepared_cout_base),
        .pop_cout_valid(prepared_cout_valid),
        .pop_k_pass(prepared_k_pass),
        .pop_num_pixels(prepared_num_pixels),
        .pop_first(prepared_first),
        .pop_final(prepared_final),
        .pop_psum_rd_bank(prepared_psum_rd_bank),
        .pop_psum_wr_bank(prepared_psum_wr_bank),
        .pop_parent_epoch(), .pop_parent_context(), .pop_context_id(),
        .empty(prepared_empty), .full(prepared_full), .level(),
        .push_count(), .pop_count(),
        .overflow_sticky(prepared_overflow_sticky),
        .overflow_count(prepared_overflow_count),
        .underflow_sticky(prepared_underflow_sticky),
        .underflow_count(prepared_underflow_count)
    );

    wire [OFM_ADDR_W-1:0] start_desc_tile =
        (ENABLE_TAGGED_CONTEXT != 0) ? prepared_tile : tile_pixel_base;
    wire [10:0] start_desc_cout_base =
        (ENABLE_TAGGED_CONTEXT != 0) ? prepared_cout_base : sched_cout_base;
    wire [10:0] start_desc_cout_valid =
        (ENABLE_TAGGED_CONTEXT != 0) ? prepared_cout_valid : sched_cout_valid;
    wire [13:0] start_desc_k_pass =
        (ENABLE_TAGGED_CONTEXT != 0) ? prepared_k_pass : sched_pass_base_k;
    wire [15:0] start_desc_num_pixels =
        (ENABLE_TAGGED_CONTEXT != 0) ? prepared_num_pixels : sched_num_pixels;
    wire start_desc_first = (ENABLE_TAGGED_CONTEXT != 0) ?
        prepared_first : sched_first_pass;
    wire start_desc_final = (ENABLE_TAGGED_CONTEXT != 0) ?
        prepared_final : sched_final_pass;
    wire start_desc_psum_rd_bank = (ENABLE_TAGGED_CONTEXT != 0) ?
        prepared_psum_rd_bank : sched_psum_rd_bank;
    wire start_desc_psum_wr_bank = (ENABLE_TAGGED_CONTEXT != 0) ?
        prepared_psum_wr_bank : sched_psum_wr_bank;
    wire [7:0] context_start_parent_epoch = start_desc_first ?
        8'd0 : chain_parent_epoch_q;
    wire [15:0] context_start_parent_context = start_desc_first ?
        16'd0 : chain_parent_context_q;

    context_lifecycle_queue #(
        .DEPTH(4), .AW(2), .EPOCH_W(8), .TILE_W(OFM_ADDR_W),
        .COUT_W(11), .K_PASS_W(14), .PIXEL_W(16),
        .CONTEXT_W(16), .REGISTERED_HEAD(1)
    ) u_context_desc_queue (
        .clk(clk), .rst(rst),
        .push_valid(context_desc_push_valid),
        .push_ready(context_desc_push_ready),
        .push_epoch(compute_context_epoch),
        .push_ifm_bank(compute_context_bank),
        .push_tile(prepared_tile),
        .push_cout_base(prepared_cout_base),
        .push_cout_valid(prepared_cout_valid),
        .push_k_pass(prepared_k_pass),
        .push_num_pixels(prepared_num_pixels),
        .push_first(prepared_first),
        .push_final(prepared_final),
        .push_psum_rd_bank(prepared_psum_rd_bank),
        .push_psum_wr_bank(prepared_psum_wr_bank),
        .push_parent_epoch(context_start_parent_epoch),
        .push_parent_context(context_start_parent_context),
        .push_context_id(next_context_id_q),
        .pop_valid(context_desc_pop_valid),
        .pop_ready(context_desc_pop_ready),
        .pop_epoch(context_desc_epoch),
        .pop_ifm_bank(context_desc_ifm_bank),
        .pop_tile(context_desc_tile),
        .pop_cout_base(context_desc_cout_base),
        .pop_cout_valid(context_desc_cout_valid),
        .pop_k_pass(context_desc_k_pass),
        .pop_num_pixels(context_desc_num_pixels),
        .pop_first(context_desc_first),
        .pop_final(context_desc_final),
        .pop_psum_rd_bank(context_desc_psum_rd_bank),
        .pop_psum_wr_bank(context_desc_psum_wr_bank),
        .pop_parent_epoch(context_desc_parent_epoch),
        .pop_parent_context(context_desc_parent_context),
        .pop_context_id(context_desc_context_id),
        .empty(context_desc_empty), .full(context_desc_full),
        .level(context_desc_level), .push_count(), .pop_count(),
        .overflow_sticky(context_desc_overflow_sticky),
        .overflow_count(context_desc_overflow_count),
        .underflow_sticky(context_desc_underflow_sticky),
        .underflow_count(context_desc_underflow_count)
    );

    always @(posedge clk) begin
        if (rst) begin
            next_context_id_q <= 16'd1;
            issue_context_active_q <= 1'b0;
            issue_handoff_done_guard_q <= 1'b0;
            issue_context_epoch_q <= 8'd0;
            issue_context_id_q <= 16'd0;
            issue_psum_rd_bank_q <= 1'b0;
            issue_psum_wr_bank_q <= 1'b0;
            issue_num_pixels_q <= 16'd0;
            issue_first_q <= 1'b0;
            issue_final_q <= 1'b0;
            issue_parent_epoch_q <= 8'd0;
            issue_parent_context_q <= 16'd0;
            chain_parent_valid_q <= 1'b0;
            chain_parent_bank_q <= 1'b0;
            chain_parent_epoch_q <= 8'd0;
            chain_parent_context_q <= 16'd0;
            context_lineage_error_q <= 1'b0;
            context_lineage_error_count_q <= 32'd0;
        end else begin
            // One-cycle identity token: a same-edge final-fire replacement
            // produces the old controller completion on the following cycle.
            // Recompute this every edge so back-to-back one-pixel handoffs
            // consume the prior token while creating the next one.
            issue_handoff_done_guard_q <= issue_fast_handoff_event;
            if ((ENABLE_TAGGED_CONTEXT != 0) &&
                context_admit_fire) begin
                issue_context_active_q <= 1'b1;
                issue_context_epoch_q <= compute_context_epoch;
                issue_context_id_q <= next_context_id_q;
                issue_psum_rd_bank_q <= prepared_psum_rd_bank;
                issue_psum_wr_bank_q <= prepared_psum_wr_bank;
                issue_num_pixels_q <= prepared_num_pixels;
                issue_first_q <= prepared_first;
                issue_final_q <= prepared_final;
                issue_parent_epoch_q <= context_start_parent_epoch;
                issue_parent_context_q <= context_start_parent_context;
                next_context_id_q <= next_context_id_q + 1'b1;

                if (prepared_first) begin
                    // A prepared descriptor derives first/ext semantics from
                    // its captured K base, so no live scheduler bit is
                    // sampled across a same-edge handoff.
                end else if (!chain_parent_valid_q ||
                             (prepared_psum_rd_bank !=
                               chain_parent_bank_q)) begin
                    context_lineage_error_q <= 1'b1;
                    context_lineage_error_count_q <=
                        context_lineage_error_count_q + 1'b1;
                end

                if (!prepared_final) begin
                    chain_parent_valid_q <= 1'b1;
                    chain_parent_bank_q <= prepared_psum_wr_bank;
                    chain_parent_epoch_q <= compute_context_epoch;
                    chain_parent_context_q <= next_context_id_q;
                end else begin
                    chain_parent_valid_q <= 1'b0;
                end
            end else if ((ENABLE_TAGGED_CONTEXT != 0) && compute_done) begin
                if (!issue_handoff_done_guard_q)
                    issue_context_active_q <= 1'b0;
            end

            // The PSUM feeder also consumes this descriptor in legacy mode.
            // Leaving it at reset aliases every non-first pass to bank 0: a
            // two-pass layer works by accident, while pass 1 is omitted once
            // a third pass alternates the feedback read to bank 1.
            if (ENABLE_TAGGED_CONTEXT == 0) begin
                if (compute_context_start) begin
                    issue_context_active_q <= 1'b1;
                    issue_psum_rd_bank_q <= sched_psum_rd_bank;
                    issue_psum_wr_bank_q <= sched_psum_wr_bank;
                    issue_num_pixels_q <= sched_num_pixels;
                    issue_first_q <= sched_first_pass;
                    issue_final_q <= sched_final_pass;
                end else if (compute_done) begin
                    issue_context_active_q <= 1'b0;
                end
            end

            if (context_done_descriptor_mismatch ||
                collector_packet_descriptor_mismatch) begin
                context_lineage_error_q <= 1'b1;
                context_lineage_error_count_q <=
                    context_lineage_error_count_q + 1'b1;
            end
        end
    end

    layer_scheduler_stream #(
        .K_TILE(K_TILE), .COUT_TILE(COUT_TILE),
        .ENABLE_FAST_CONTEXT_HANDOFF(ENABLE_FAST_CONTEXT_HANDOFF)
    ) u_sched (
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
        .feeder_start(sched_feeder_start),
        .feeder_start_ready(feeder_start_ready),
        .feeder_done(feeder_done),
        .feeder_compute_ready(feeder_compute_ready),
        .feeder_overlap_mode(feeder_overlap_mode),
        .raw_hwc_mode(stream_raw_hwc_mode),
        .early_drain_enable(early_drain_enable),
        .pass_prefetch_enable(pass_prefetch_enable),
        .during_compute_prefetch_enable(during_compute_prefetch_enable),
        .psum_stream_overlap_enable(psum_stream_overlap_enable),
        .continuous_psum_enable(continuous_psum_enable),
        .collector_ctx_ready(
            ((ENABLE_TAGGED_CONTEXT == 0) || tagged_context_start_ready) &&
            (column_psum_active ?
                (sched_final_pass ?
                    (collector_ctx_ready && column_context_idle) :
                    column_ctx_ready) : collector_ctx_ready)),
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
        .compute_start(sched_compute_start),
        .compute_start_accepted(accepted_compute_context_start),
        .compute_done(compute_done),
        .psum_drain_start(sched_drain_start), .psum_drain_done(drain_done),
        .feeder_pass_base_k(sched_feeder_pass_base_k),
        .feeder_k_pass(sched_feeder_k_pass),
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
    wire weight_tile_complete_ready;
    reg weight_tile_complete_pending_q;
    wire weight_tile_complete_valid =
        weight_tile_complete_pending_q || wgt_loader_done;
    wire weight_tile_complete_fire =
        weight_tile_complete_valid && weight_tile_complete_ready;
    localparam USE_WEIGHT_PINGPONG =
        (ENABLE_WEIGHT_PRELOAD != 0) &&
        (ENABLE_FAST_CONTEXT_HANDOFF != 0);
    reg weight_ingress_more_q;
    reg [13:0] weight_ingress_k_q;
    reg [10:0] weight_ingress_cout_q;
    reg weight_format_pending_q;
    wire weight_stage_write_ready;
    wire weight_stage_commit_ready;
    wire weight_stage_consume_ready;
    wire weight_stage_commit = USE_WEIGHT_PINGPONG &&
        weight_req_r && weight_tile_ready;
    wire weight_stage_consume = USE_WEIGHT_PINGPONG &&
        weight_format_pending_q;
    wire weight_stage_consume_fire = weight_stage_consume &&
        weight_stage_consume_ready;
    wire weight_ingress_last_k =
        ({1'b0, weight_ingress_k_q} + ROWS >= {1'b0, k_total});
    wire weight_ingress_last_cout =
        ({1'b0, weight_ingress_cout_q} + COUT_TILE >=
         {1'b0, cout_total});
    wire weight_stage_fatal;
    wire weight_stage_commit_overflow;
    wire weight_stage_consume_underflow;
    wire weight_stage_write_no_slot;
    wire weight_stage_protocol_error;
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
            weight_ingress_more_q <= 1'b0;
            weight_ingress_k_q <= 14'd0;
            weight_ingress_cout_q <= 11'd0;
            weight_format_pending_q <= 1'b0;
            weight_tile_complete_pending_q <= 1'b0;
        end else begin
            wgt_loader_start <= 1'b0;
            sched_weight_done <= 1'b0;
            if (weight_tile_complete_fire)
                weight_tile_complete_pending_q <= 1'b0;
            else if (wgt_loader_done)
                weight_tile_complete_pending_q <= 1'b1;
            if (start)
                weight_tile_complete_pending_q <= 1'b0;
            if (sched_bias_start)
                bias_req_r <= 1'b1;
            if (bias_req_r && bias_load_done)
                bias_req_r <= 1'b0;

            if (USE_WEIGHT_PINGPONG) begin
                // The packed AXIS stream is deterministic within one spatial
                // tile: K-pass is the inner loop and COUT block is the outer
                // loop.  Keep up to two raw tiles staged independently of the
                // scheduler's formatter demand.  This overlaps the 72-beat
                // ingress of tile N+1 with the column transpose/preload of N.
                if (start) begin
                    weight_req_r <= 1'b0;
                    weight_ingress_more_q <=
                        (k_total != 14'd0) && (cout_total != 11'd0);
                    weight_ingress_k_q <= 14'd0;
                    weight_ingress_cout_q <= 11'd0;
                    weight_format_pending_q <= 1'b0;
                end else begin
                    if (weight_req_r) begin
                        if (weight_tile_ready) begin
                            weight_req_r <= 1'b0;
                            if (weight_ingress_last_k) begin
                                weight_ingress_k_q <= 14'd0;
                                if (weight_ingress_last_cout) begin
                                    weight_ingress_more_q <= 1'b0;
                                end else begin
                                    weight_ingress_cout_q <=
                                        weight_ingress_cout_q + COUT_TILE;
                                end
                            end else begin
                                weight_ingress_k_q <=
                                    weight_ingress_k_q + ROWS;
                            end
                        end
                    end else if (weight_ingress_more_q &&
                                 weight_stage_write_ready &&
                                 !weight_stage_fatal) begin
                        // Holding this request high for the whole packet keeps
                        // the external loader's pulse-only tile_ready lossless.
                        weight_req_r <= 1'b1;
                    end

                    case ({sched_weight_start,
                           weight_stage_consume_fire})
                        2'b10: weight_format_pending_q <= 1'b1;
                        2'b01: weight_format_pending_q <= 1'b0;
                        // A replacement request on the same edge preserves a
                        // single pending demand without dropping either tile.
                        2'b11: weight_format_pending_q <= 1'b1;
                        default: weight_format_pending_q <=
                            weight_format_pending_q;
                    endcase
                end
                weight_start_pending <= 1'b0;
                if (weight_tile_complete_fire)
                    sched_weight_done <= 1'b1;
            end else begin
                weight_ingress_more_q <= 1'b0;
                weight_ingress_k_q <= 14'd0;
                weight_ingress_cout_q <= 11'd0;
                weight_format_pending_q <= 1'b0;
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
                if (weight_tile_complete_fire)
                    sched_weight_done <= 1'b1;
            end
        end
    end

    generate
        if (USE_WEIGHT_PINGPONG) begin : g_weight_tile_pingpong
            weight_tile_pingpong_loader #(
                .ROWS(ROWS), .COLS(COLS), .WEIGHT_W(WEIGHT_W),
                .ADDR_W(WGT_TILE_AW)
            ) u_weight_loader (
                .clk(clk), .rst(rst), .soft_reset(start),
                .tile_wr_en(wgt_tile_wr_en),
                .tile_wr_addr(wgt_tile_wr_addr),
                .tile_wr_data(wgt_tile_wr_data),
                .tile_wr8_en(wgt_tile_wr8_en),
                .tile_wr8_addr(wgt_tile_wr8_addr),
                .tile_wr8_data(wgt_tile_wr8_data),
                .tile_wr8_keep(wgt_tile_wr8_keep),
                .write_ready(weight_stage_write_ready),
                .commit_valid(weight_stage_commit),
                .commit_ready(weight_stage_commit_ready),
                .consume_valid(weight_stage_consume),
                .consume_ready(weight_stage_consume_ready),
                .row_fifo_full(wgt_fifo_full),
                .row_fifo_wr_en(wgt_fifo_wr_en),
                .row_fifo_wr_data(wgt_fifo_wr_data),
                .done(wgt_loader_done), .format_busy(),
                .committed_level(), .bank_busy(),
                .sticky_commit_overflow(weight_stage_commit_overflow),
                .sticky_consume_underflow(weight_stage_consume_underflow),
                .sticky_write_no_slot(weight_stage_write_no_slot),
                .sticky_protocol_error(weight_stage_protocol_error),
                .fatal_error(weight_stage_fatal)
            );
        end else begin : g_weight_tile_legacy
            assign weight_stage_write_ready = 1'b1;
            assign weight_stage_commit_ready = 1'b1;
            assign weight_stage_consume_ready = 1'b1;
            assign weight_stage_fatal = 1'b0;
            assign weight_stage_commit_overflow = 1'b0;
            assign weight_stage_consume_underflow = 1'b0;
            assign weight_stage_write_no_slot = 1'b0;
            assign weight_stage_protocol_error = 1'b0;
            weight_tile_loader #(
                .ROWS(ROWS), .COLS(COLS), .WEIGHT_W(WEIGHT_W),
                .ADDR_W(WGT_TILE_AW)
            ) u_weight_loader (
                .clk(clk), .rst(rst),
                .tile_wr_en(wgt_tile_wr_en),
                .tile_wr_addr(wgt_tile_wr_addr),
                .tile_wr_data(wgt_tile_wr_data),
                .tile_wr8_en(wgt_tile_wr8_en),
                .tile_wr8_addr(wgt_tile_wr8_addr),
                .tile_wr8_data(wgt_tile_wr8_data),
                .tile_wr8_keep(wgt_tile_wr8_keep),
                .start(wgt_loader_start), .busy(), .done(wgt_loader_done),
                .wgt_fifo_full(wgt_fifo_full),
                .wgt_fifo_wr_en(wgt_fifo_wr_en),
                .wgt_fifo_wr_data(wgt_fifo_wr_data)
            );
        end
    endgenerate

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
    wire psum_stream_compute_ready_base;
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
        legacy_drain_packet_valid && legacy_drain_packet_ready;

    wire pp_wr_en = drain_packet_fire && !drain_packet_is_final && !column_psum_active;
    wire pp_wr_bank = drain_packet_wr_bank;
    wire [PSUM_BUF_AW-1:0] pp_wr_addr = drain_packet_addr;
    wire [COLS*2*PSUM_W-1:0] pp_wr_data = drain_packet_data;
    wire pp_rd_en_request;
    wire pp_rd_en;
    wire pp_rd_bank;
    wire [PSUM_BUF_AW-1:0] pp_rd_addr;
    wire [COLS*2*PSUM_W-1:0] pp_rd_data;
    wire pp_rd_valid;
    wire psum_score_alloc_ready;
    wire psum_score_wr_ready;
    wire psum_score_commit_ready;
    wire psum_score_rd_ready;
    // Per-bank registered credit tokens presented to the high-fanout
    // compute-ready cone.  The owner scoreboard's exact combinational ready
    // still qualifies the physical RAM request below, but its counters no
    // longer feed every compute CE in the array.
    (* KEEP = "TRUE" *) reg [1:0] psum_score_rd_credit_q;
    wire psum_score_return_ready;
    wire psum_score_release_ready;
    wire [1:0] psum_score_bank_allocated;
    wire [7:0] psum_score_bank0_epoch;
    wire [7:0] psum_score_bank1_epoch;
    wire [15:0] psum_score_bank0_context;
    wire [15:0] psum_score_bank1_context;
    wire [PSUM_BUF_AW:0] psum_score_credit0;
    wire [PSUM_BUF_AW:0] psum_score_credit1;
    wire [PSUM_BUF_AW:0] psum_score_outstanding0;
    wire [PSUM_BUF_AW:0] psum_score_outstanding1;
    wire [31:0] psum_score_ownership_stalls;
    wire [31:0] psum_score_underflow_count;
    wire [31:0] psum_score_overwrite_count;
    wire [31:0] psum_score_epoch_mismatch_count;
    wire [31:0] psum_score_context_mismatch_count;
    wire [31:0] psum_score_conflict_count;
    wire psum_score_error_underflow;
    wire psum_score_error_overwrite;
    wire psum_score_error_epoch;
    wire psum_score_error_context;
    wire psum_score_error_conflict;
    wire psum_score_fail_stop;
    localparam PSUM_ALLOC_EVENT_W = 1 + 8 + 16 + PSUM_BUF_AW + 1;
    localparam PSUM_OWNER_EVENT_W = 1 + 8 + 16;
    wire psum_alloc_event_in_valid;
    wire psum_alloc_event_in_ready;
    wire [PSUM_ALLOC_EVENT_W-1:0] psum_alloc_event_in_data;
    wire psum_alloc_event_out_valid;
    wire [PSUM_ALLOC_EVENT_W-1:0] psum_alloc_event_out_data;
    wire psum_alloc_event_overflow;
    wire psum_alloc_event_overflow_sticky;
    wire psum_commit_event_in_valid;
    wire psum_commit_event_in_ready;
    wire [PSUM_OWNER_EVENT_W-1:0] psum_commit_event_in_data;
    wire psum_commit_event_out_valid;
    wire [PSUM_OWNER_EVENT_W-1:0] psum_commit_event_out_data;
    wire psum_commit_event_overflow;
    wire psum_commit_event_overflow_sticky;
    wire psum_release_event_in_valid;
    wire psum_release_event_in_ready;
    wire [PSUM_OWNER_EVENT_W-1:0] psum_release_event_in_data;
    wire psum_release_event_out_valid;
    wire [PSUM_OWNER_EVENT_W-1:0] psum_release_event_out_data;
    wire psum_release_event_overflow;
    wire psum_release_event_overflow_sticky;
    wire psum_score_alloc_bank;
    wire [7:0] psum_score_alloc_epoch;
    wire [15:0] psum_score_alloc_context;
    wire [PSUM_BUF_AW:0] psum_score_alloc_expected;
    wire psum_score_commit_bank;
    wire [7:0] psum_score_commit_epoch;
    wire [15:0] psum_score_commit_context;
    wire psum_score_release_bank;
    wire [7:0] psum_score_release_epoch;
    wire [15:0] psum_score_release_context;
    reg psum_score_return_bank_q;
    reg [7:0] psum_score_return_epoch_q;
    reg [15:0] psum_score_return_context_q;
    reg psum_score_return_last_q;
    reg [31:0] psum_score_credit_stall_cycles;
    wire [PSUM_BUF_AW:0] pp_committed_count0;
    wire [PSUM_BUF_AW:0] pp_committed_count1;
    wire pp_error_underflow;
    wire pp_error_overwrite;
    wire pp_error_bank_conflict;
    wire pp_clear_request = !start_desc_final &&
        ((!continuous_psum_enable && sched_drain_start) ||
         (continuous_psum_enable && accepted_compute_context_start));
    wire pp_clear_bank = (ENABLE_TAGGED_CONTEXT != 0) ?
        psum_score_alloc_bank : sched_psum_wr_bank;
    wire [PSUM_BUF_AW:0] psum_stream_available_count =
        issue_psum_rd_bank_q ? psum_available_count1 :
                               psum_available_count0;
    // Preserve the explicit 1024-pixel value when AW=10.  Truncating to AW
    // address bits aliases a full bank to zero and permanently blocks alloc.
    wire [PSUM_BUF_AW:0] sched_num_pixels_ext =
        start_desc_num_pixels[PSUM_BUF_AW:0];
    wire [PSUM_BUF_AW:0] psum_count_max =
        {1'b1, {PSUM_BUF_AW{1'b0}}};

    assign psum_alloc_event_in_valid = context_admit_fire &&
        !start_desc_final;
    assign psum_alloc_event_in_data = {
        start_desc_psum_wr_bank, compute_context_epoch, next_context_id_q,
        sched_num_pixels_ext
    };
    assign {
        psum_score_alloc_bank, psum_score_alloc_epoch,
        psum_score_alloc_context, psum_score_alloc_expected
    } = psum_alloc_event_out_data;
    wire psum_score_alloc_valid = (ENABLE_TAGGED_CONTEXT != 0) &&
        psum_alloc_event_out_valid;
    wire psum_score_alloc_fire = psum_score_alloc_valid &&
        psum_score_alloc_ready;
    wire pp_clear_valid = (ENABLE_TAGGED_CONTEXT != 0) ?
        psum_score_alloc_fire : pp_clear_request;
    wire [7:0] psum_score_rd_epoch = issue_parent_epoch_q;
    wire [15:0] psum_score_rd_context = issue_parent_context_q;
    wire psum_score_ext_mode = issue_context_active_q && !issue_first_q;
    wire psum_score_rd_last =
        pp_rd_addr == issue_num_pixels_q[PSUM_BUF_AW-1:0] - 1'b1;
    // Every externally credited partial-PSUM write must be the same physical
    // RAM handshake.  In particular, the last packet cannot enter the owner
    // scoreboard while its matching commit-event FIFO is backpressured.
    wire psum_score_wr_side_ready = context_desc_pop_valid &&
        (!continuous_psum_enable || collector_packet_descriptor_match) &&
        (!continuous_psum_enable || !collector_packet_valid ||
         collector_packet_is_final ||
         (collector_packet_addr !=
             context_desc_num_pixels[PSUM_BUF_AW-1:0] - 1'b1) ||
         psum_commit_event_in_ready);
    wire psum_score_wr_valid = (ENABLE_TAGGED_CONTEXT != 0) &&
        drain_packet_valid && !drain_packet_is_final &&
        !column_psum_active && psum_score_wr_side_ready;
    wire [7:0] psum_score_wr_epoch = continuous_psum_enable ?
        collector_packet_epoch : context_desc_epoch;
    wire [15:0] psum_score_wr_context = continuous_psum_enable ?
        collector_packet_context_id : context_desc_context_id;
    assign {
        psum_score_commit_bank, psum_score_commit_epoch,
        psum_score_commit_context
    } = psum_commit_event_out_data;
    wire psum_score_commit_valid = (ENABLE_TAGGED_CONTEXT != 0) &&
        psum_commit_event_out_valid;
    wire psum_score_commit_fire = psum_score_commit_valid &&
        psum_score_commit_ready;
    wire psum_score_rd_valid = (ENABLE_TAGGED_CONTEXT != 0) &&
        pp_rd_en_request &&
        (!psum_score_rd_last || psum_release_event_in_ready);
    wire psum_score_rd_fire = psum_score_rd_valid &&
        psum_score_rd_ready;
    wire psum_score_wr_fire = psum_score_wr_valid && psum_score_wr_ready;
    wire psum_score_rd_credit = psum_score_rd_credit_q[pp_rd_bank];
    wire psum_score_return_valid = (ENABLE_TAGGED_CONTEXT != 0) &&
        pp_rd_valid;
    wire psum_score_return_fire = psum_score_return_valid &&
        psum_score_return_ready;
    assign {
        psum_score_release_bank, psum_score_release_epoch,
        psum_score_release_context
    } = psum_release_event_out_data;
    wire psum_score_release_valid = (ENABLE_TAGGED_CONTEXT != 0) &&
        psum_release_event_out_valid;
    wire psum_score_release_fire = psum_score_release_valid &&
        psum_score_release_ready;
    // Use the retiring collector/drain descriptor here.  The scheduler may
    // already expose the next pass by the time collector_done arrives, so its
    // live final-pass bit is not a safe ownership qualifier.
    wire psum_score_writer_done_event = continuous_psum_enable ?
        collector_partial_done : (drain_done && !active_drain_is_final);
    wire psum_score_writer_done_bank = continuous_psum_enable ?
        collector_context_done_wr_bank : context_desc_psum_wr_bank;
    wire [7:0] psum_score_writer_done_epoch = continuous_psum_enable ?
        collector_context_done_epoch : context_desc_epoch;
    wire [15:0] psum_score_writer_done_context = continuous_psum_enable ?
        collector_context_done_context_id : context_desc_context_id;
    assign psum_commit_event_in_valid = (ENABLE_TAGGED_CONTEXT != 0) &&
        psum_score_writer_done_event;
    assign psum_commit_event_in_data = {
        psum_score_writer_done_bank, psum_score_writer_done_epoch,
        psum_score_writer_done_context
    };
    assign psum_release_event_in_valid = (ENABLE_TAGGED_CONTEXT != 0) &&
        psum_score_return_fire && psum_score_return_last_q;
    assign psum_release_event_in_data = {
        psum_score_return_bank_q, psum_score_return_epoch_q,
        psum_score_return_context_q
    };
    wire psum_score_active_wr_bank_owned =
        psum_score_bank_allocated[issue_psum_wr_bank_q] &&
        ((issue_psum_wr_bank_q ? psum_score_bank1_epoch :
                               psum_score_bank0_epoch) ==
            issue_context_epoch_q) &&
        ((issue_psum_wr_bank_q ? psum_score_bank1_context :
                               psum_score_bank0_context) ==
            issue_context_id_q);
    wire psum_score_active_rd_parent_owned = issue_first_q ||
        (psum_score_bank_allocated[issue_psum_rd_bank_q] &&
         ((issue_psum_rd_bank_q ? psum_score_bank1_epoch :
                                  psum_score_bank0_epoch) ==
            issue_parent_epoch_q) &&
         ((issue_psum_rd_bank_q ? psum_score_bank1_context :
                                  psum_score_bank0_context) ==
            issue_parent_context_q));

    // An allocation handshake changes allocated/owner state on this edge.
    // Include that exact transition when filling the permit so the registered
    // cut has the same first-ready cycle as the original combinational cone.
    wire psum_score_alloc_matches_active_rd = psum_score_alloc_fire &&
        (psum_score_alloc_bank == issue_psum_rd_bank_q) &&
        (psum_score_alloc_epoch == issue_parent_epoch_q) &&
        (psum_score_alloc_context == issue_parent_context_q);
    wire psum_score_alloc_matches_active_wr = psum_score_alloc_fire &&
        (psum_score_alloc_bank == issue_psum_wr_bank_q) &&
        (psum_score_alloc_epoch == issue_context_epoch_q) &&
        (psum_score_alloc_context == issue_context_id_q);
    wire issue_psum_owner_permit_next =
        (psum_score_active_rd_parent_owned ||
         psum_score_alloc_matches_active_rd) &&
        (issue_final_q || psum_score_active_wr_bank_owned ||
         psum_score_alloc_matches_active_wr);

    // Compute the permit for a descriptor accepted on this edge.  This is
    // needed by both idle starts and zero-gap fast handoffs; the old permit
    // continues to qualify the retiring context until the edge itself.
    wire psum_score_start_rd_parent_owned = prepared_first ||
        (psum_score_bank_allocated[prepared_psum_rd_bank] &&
         ((prepared_psum_rd_bank ? psum_score_bank1_epoch :
                                   psum_score_bank0_epoch) ==
            context_start_parent_epoch) &&
         ((prepared_psum_rd_bank ? psum_score_bank1_context :
                                   psum_score_bank0_context) ==
            context_start_parent_context));
    wire psum_score_start_wr_bank_owned = prepared_final ||
        (psum_score_bank_allocated[prepared_psum_wr_bank] &&
         ((prepared_psum_wr_bank ? psum_score_bank1_epoch :
                                   psum_score_bank0_epoch) ==
            compute_context_epoch) &&
         ((prepared_psum_wr_bank ? psum_score_bank1_context :
                                   psum_score_bank0_context) ==
            next_context_id_q));
    wire psum_score_alloc_matches_start_rd = psum_score_alloc_fire &&
        (psum_score_alloc_bank == prepared_psum_rd_bank) &&
        (psum_score_alloc_epoch == context_start_parent_epoch) &&
        (psum_score_alloc_context == context_start_parent_context);
    wire psum_score_alloc_matches_start_wr = psum_score_alloc_fire &&
        (psum_score_alloc_bank == prepared_psum_wr_bank) &&
        (psum_score_alloc_epoch == compute_context_epoch) &&
        (psum_score_alloc_context == next_context_id_q);
    wire start_psum_owner_permit_next =
        (psum_score_start_rd_parent_owned ||
         psum_score_alloc_matches_start_rd) &&
        (psum_score_start_wr_bank_owned ||
         psum_score_alloc_matches_start_wr);

    always @(posedge clk) begin
        if (rst) begin
            issue_psum_owner_permit_q <= 1'b0;
        end else if ((ENABLE_TAGGED_CONTEXT != 0) &&
                     context_admit_fire) begin
            issue_psum_owner_permit_q <= start_psum_owner_permit_next;
        end else if ((ENABLE_TAGGED_CONTEXT != 0) && compute_done &&
                     !issue_handoff_done_guard_q) begin
            issue_psum_owner_permit_q <= 1'b0;
        end else if ((ENABLE_TAGGED_CONTEXT != 0) &&
                     issue_context_active_q &&
                     !issue_psum_owner_permit_q) begin
            issue_psum_owner_permit_q <= issue_psum_owner_permit_next;
        end
    end

    wire tagged_context_admission_ready =
        (ENABLE_TAGGED_CONTEXT == 0) ||
        (!psum_score_fail_stop && !context_lineage_error_q &&
         !collector_fail_stop &&
         !context_desc_overflow_sticky &&
         !context_desc_underflow_sticky &&
         !psum_alloc_event_overflow_sticky &&
         !psum_commit_event_overflow_sticky &&
         !psum_release_event_overflow_sticky &&
         issue_psum_owner_permit_q);

    assign tagged_context_start_ready =
        (ENABLE_TAGGED_CONTEXT == 0) ||
        (prepared_pop_valid && !prepared_overflow_sticky &&
         !prepared_underflow_sticky &&
         !psum_score_fail_stop && !context_lineage_error_q &&
         !collector_fail_stop && !context_desc_overflow_sticky &&
         !context_desc_underflow_sticky &&
         !psum_alloc_event_overflow_sticky &&
         !psum_commit_event_overflow_sticky &&
         !psum_release_event_overflow_sticky && context_desc_push_ready &&
         (!continuous_psum_enable || collector_ctx_ready) &&
         (start_desc_final || psum_alloc_event_in_ready));
    assign context_admit_fire = (ENABLE_TAGGED_CONTEXT != 0) &&
        compute_context_start && tagged_context_start_ready;
    assign accepted_compute_context_start = (ENABLE_TAGGED_CONTEXT != 0) ?
        context_admit_fire : compute_context_start;

    assign partial_psum_write_ready = (ENABLE_TAGGED_CONTEXT == 0) ||
        (psum_score_wr_side_ready && psum_score_wr_ready);
    // In legacy mode psum_score_wr_side_ready simplifies exactly to the
    // descriptor-presence check below.  Express that mode locally so the
    // continuous collector's multi-field descriptor comparison cannot feed
    // the legacy drain read-enable cone in timing analysis.
    assign legacy_partial_psum_write_ready =
        (ENABLE_TAGGED_CONTEXT == 0) ||
        (context_desc_pop_valid && psum_score_wr_ready);
    assign collector_packet_ready =
        ((ENABLE_TAGGED_CONTEXT == 0) ||
         collector_packet_descriptor_match) &&
        (collector_packet_is_final ? final_fifo_ready :
                                     partial_psum_write_ready);
    assign legacy_drain_packet_ready = legacy_drain_packet_is_final ?
        final_fifo_ready : legacy_partial_psum_write_ready;
    assign drain_packet_ready = continuous_psum_enable ?
        collector_packet_ready : legacy_drain_packet_ready;
    assign psum_stream_compute_ready = psum_stream_compute_ready_base &&
        ((ENABLE_TAGGED_CONTEXT == 0) || !psum_score_ext_mode ||
         (psum_score_rd_credit &&
          (!psum_score_rd_last || psum_release_event_in_ready)));
    assign pp_rd_en = pp_rd_en_request &&
        ((ENABLE_TAGGED_CONTEXT == 0) ||
         (psum_score_rd_valid && psum_score_rd_ready));

    assign psum_credit_stall_cycles =
        frontend_psum_credit_stall_cycles + psum_score_credit_stall_cycles;
    assign context_epoch_mismatch_count =
        frontend_context_epoch_mismatch_count +
        psum_score_epoch_mismatch_count;
    assign context_mismatch_count =
        frontend_context_mismatch_count +
        psum_score_context_mismatch_count +
        context_lineage_error_count_q +
        context_desc_underflow_count +
        prepared_underflow_count +
        collector_tag_mismatch_count;
    assign context_psum_underflow_count =
        frontend_context_psum_underflow_count + psum_score_underflow_count;
    assign context_bank_overwrite_count =
        frontend_context_bank_overwrite_count + psum_score_overwrite_count;
    wire [31:0] context_fifo_drop_count_comb =
        frontend_context_fifo_drop_count + context_desc_overflow_count +
        prepared_overflow_count +
        {31'd0, psum_alloc_event_overflow_sticky} +
        {31'd0, psum_commit_event_overflow_sticky} +
        {31'd0, psum_release_event_overflow_sticky};
    // This is software telemetry only.  Register the completed sum at the
    // layer boundary so the distributed FIFO diagnostics and their carry
    // chain do not continue through the large AXI read-data mux.  Datapath
    // fail-stop controls still consume the original sticky flags directly.
    reg [31:0] context_fifo_drop_count_readback_q;
    always @(posedge clk) begin
        if (rst)
            context_fifo_drop_count_readback_q <= 32'd0;
        else
            context_fifo_drop_count_readback_q <=
                context_fifo_drop_count_comb;
    end
    assign context_fifo_drop_count = context_fifo_drop_count_readback_q;
    assign context_full_stall_cycles =
        frontend_context_full_stall_cycles;

    assign perf_psumovl_underflow = pp_error_underflow ||
        (column_psum_active ? column_psum_underflow : psum_stream_underflow);
    assign datapath_error_status =
        {29'd0, pp_error_bank_conflict, pp_error_overwrite,
         pp_error_underflow} |
        tagged_datapath_error_status |
        (collector_tag_mismatch_sticky ? (32'h1 << 30) : 32'd0) |
        (psum_score_error_underflow ? (32'h1 << 0) : 32'd0) |
        (psum_score_error_overwrite ? (32'h1 << 1) : 32'd0) |
        (psum_score_error_conflict ? (32'h1 << 2) : 32'd0) |
        ((context_lineage_error_q || context_desc_underflow_sticky ||
          prepared_underflow_sticky) ?
            (32'h1 << 24) : 32'd0) |
        ((context_desc_overflow_sticky ||
          prepared_overflow_sticky ||
          psum_alloc_event_overflow_sticky ||
          psum_commit_event_overflow_sticky ||
          psum_release_event_overflow_sticky ||
          weight_stage_fatal) ?
            (32'h1 << 25) : 32'd0) |
        ((psum_score_error_epoch || psum_score_error_context) ?
            (32'h1 << 30) : 32'd0);

    always @(posedge clk) begin
        if (rst) begin
            active_drain_wr_bank <= 1'b0;
            active_drain_is_final <= 1'b0;
            active_drain_num_pixels <= {(PSUM_BUF_AW+1){1'b0}};
            psum_available_count0 <= {(PSUM_BUF_AW+1){1'b0}};
            psum_available_count1 <= {(PSUM_BUF_AW+1){1'b0}};
        end else begin
            if (!continuous_psum_enable && sched_drain_start) begin
                active_drain_wr_bank <= sched_psum_wr_bank;
                active_drain_is_final <= sched_final_pass;
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
                accepted_compute_context_start && !start_desc_final) begin
                if (start_desc_psum_wr_bank) begin
                    psum_available_count1 <= {(PSUM_BUF_AW+1){1'b0}};
                end else begin
                    psum_available_count0 <= {(PSUM_BUF_AW+1){1'b0}};
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
        end
    end

    psum_pingpong_buffer #(
        .DATA_W(COLS*2*PSUM_W), .DEPTH(PSUM_BUF_DEPTH), .AW(PSUM_BUF_AW),
        .EXTERNAL_CREDIT_GUARD(ENABLE_TAGGED_CONTEXT)
    ) u_pp (
        .clk(clk), .rst(rst),
        .clear_valid(pp_clear_valid), .clear_bank(pp_clear_bank),
        .wr_en(pp_wr_en), .wr_bank(pp_wr_bank), .wr_addr(pp_wr_addr), .wr_data(pp_wr_data),
        .rd_en(pp_rd_en), .rd_bank(pp_rd_bank), .rd_addr(pp_rd_addr),
        .rd_data(pp_rd_data), .rd_valid(pp_rd_valid),
        .committed_count0(pp_committed_count0),
        .committed_count1(pp_committed_count1),
        .error_underflow(pp_error_underflow),
        .error_overwrite(pp_error_overwrite),
        .error_bank_conflict(pp_error_bank_conflict)
    );

    context_event_fifo #(
        .WIDTH(PSUM_ALLOC_EVENT_W), .DEPTH(4), .AW(2)
    ) u_psum_alloc_events (
        .clk(clk), .rst(rst),
        .in_valid(psum_alloc_event_in_valid),
        .in_ready(psum_alloc_event_in_ready),
        .in_data(psum_alloc_event_in_data),
        .out_valid(psum_alloc_event_out_valid),
        .out_ready(psum_score_alloc_ready),
        .out_data(psum_alloc_event_out_data),
        .empty(), .full(), .level(),
        .overflow_attempt(psum_alloc_event_overflow),
        .overflow_sticky(psum_alloc_event_overflow_sticky)
    );

    context_event_fifo #(
        .WIDTH(PSUM_OWNER_EVENT_W), .DEPTH(4), .AW(2),
        .REGISTERED_HEAD(1)
    ) u_psum_commit_events (
        .clk(clk), .rst(rst),
        .in_valid(psum_commit_event_in_valid),
        .in_ready(psum_commit_event_in_ready),
        .in_data(psum_commit_event_in_data),
        .out_valid(psum_commit_event_out_valid),
        .out_ready(psum_score_commit_ready),
        .out_data(psum_commit_event_out_data),
        .empty(), .full(), .level(),
        .overflow_attempt(psum_commit_event_overflow),
        .overflow_sticky(psum_commit_event_overflow_sticky)
    );

    context_event_fifo #(
        .WIDTH(PSUM_OWNER_EVENT_W), .DEPTH(4), .AW(2)
    ) u_psum_release_events (
        .clk(clk), .rst(rst),
        .in_valid(psum_release_event_in_valid),
        .in_ready(psum_release_event_in_ready),
        .in_data(psum_release_event_in_data),
        .out_valid(psum_release_event_out_valid),
        .out_ready(psum_score_release_ready),
        .out_data(psum_release_event_out_data),
        .empty(), .full(), .level(),
        .overflow_attempt(psum_release_event_overflow),
        .overflow_sticky(psum_release_event_overflow_sticky)
    );

    psum_bank_owner_scoreboard #(
        .DEPTH(PSUM_BUF_DEPTH),
        .AW(PSUM_BUF_AW),
        .EPOCH_W(8),
        .CONTEXT_W(16)
    ) u_psum_owner (
        .clk(clk), .rst(rst),
        .alloc_valid(psum_score_alloc_valid),
        .alloc_bank(psum_score_alloc_bank),
        .alloc_epoch(psum_score_alloc_epoch),
        .alloc_context(psum_score_alloc_context),
        .alloc_expected(psum_score_alloc_expected),
        .alloc_ready(psum_score_alloc_ready),
        .wr_valid(psum_score_wr_valid),
        .wr_bank(drain_packet_wr_bank),
        .wr_epoch(psum_score_wr_epoch),
        .wr_context(psum_score_wr_context),
        .wr_addr(drain_packet_addr),
        .wr_ready(psum_score_wr_ready),
        .commit_valid(psum_score_commit_valid),
        .commit_bank(psum_score_commit_bank),
        .commit_epoch(psum_score_commit_epoch),
        .commit_context(psum_score_commit_context),
        .commit_ready(psum_score_commit_ready),
        .rd_req_valid(psum_score_rd_valid),
        .rd_req_bank(pp_rd_bank),
        .rd_req_epoch(psum_score_rd_epoch),
        .rd_req_context(psum_score_rd_context),
        .rd_req_addr(pp_rd_addr),
        .rd_req_last(psum_score_rd_last),
        .rd_req_ready(psum_score_rd_ready),
        .rd_return_valid(psum_score_return_valid),
        .rd_return_bank(psum_score_return_bank_q),
        .rd_return_epoch(psum_score_return_epoch_q),
        .rd_return_context(psum_score_return_context_q),
        .rd_return_last(psum_score_return_last_q),
        .rd_return_ready(psum_score_return_ready),
        .release_valid(psum_score_release_valid),
        .release_bank(psum_score_release_bank),
        .release_epoch(psum_score_release_epoch),
        .release_context(psum_score_release_context),
        .release_ready(psum_score_release_ready),
        .bank_allocated(psum_score_bank_allocated),
        .bank_writer_done(), .bank_reader_done(), .bank_reusable(),
        .bank0_owner_epoch(psum_score_bank0_epoch),
        .bank1_owner_epoch(psum_score_bank1_epoch),
        .bank0_owner_context(psum_score_bank0_context),
        .bank1_owner_context(psum_score_bank1_context),
        .bank0_committed_credits(psum_score_credit0),
        .bank1_committed_credits(psum_score_credit1),
        .bank0_outstanding(psum_score_outstanding0),
        .bank1_outstanding(psum_score_outstanding1),
        .alloc_count(), .commit_count(), .release_count(),
        .ownership_stall_cycles(psum_score_ownership_stalls),
        .underflow_count(psum_score_underflow_count),
        .overwrite_count(psum_score_overwrite_count),
        .epoch_mismatch_count(psum_score_epoch_mismatch_count),
        .context_mismatch_count(psum_score_context_mismatch_count),
        .same_address_conflict_count(psum_score_conflict_count),
        .error_underflow(psum_score_error_underflow),
        .error_overwrite(psum_score_error_overwrite),
        .error_epoch_mismatch(psum_score_error_epoch),
        .error_context_mismatch(psum_score_error_context),
        .error_same_address_conflict(psum_score_error_conflict),
        .fail_stop(psum_score_fail_stop)
    );

    always @(posedge clk) begin
        if (rst) begin
            psum_score_return_bank_q <= 1'b0;
            psum_score_return_epoch_q <= 8'd0;
            psum_score_return_context_q <= 16'd0;
            psum_score_return_last_q <= 1'b0;
            psum_score_rd_credit_q <= 2'b00;
            psum_score_credit_stall_cycles <= 32'd0;
        end else begin
            // Mirror the exact next committed-credit nonzero state using only
            // registered tokens.  A simultaneous write/read leaves a token
            // available; a read of the last existing credit clears it.  The
            // tokens are maintained before a context starts, so normal and
            // fast handoffs do not need a permit-fill bubble.
            if ((psum_score_alloc_fire && !psum_score_alloc_bank) ||
                (psum_score_release_fire && !psum_score_release_bank)) begin
                psum_score_rd_credit_q[0] <= 1'b0;
            end else begin
                case ({psum_score_wr_fire && !drain_packet_wr_bank,
                       psum_score_rd_fire && !pp_rd_bank})
                    2'b10: psum_score_rd_credit_q[0] <= 1'b1;
                    2'b01: psum_score_rd_credit_q[0] <=
                        psum_score_credit0 > 1;
                    2'b11: psum_score_rd_credit_q[0] <=
                        psum_score_credit0 != 0;
                    default: psum_score_rd_credit_q[0] <=
                        psum_score_credit0 != 0;
                endcase
            end
            if ((psum_score_alloc_fire && psum_score_alloc_bank) ||
                (psum_score_release_fire && psum_score_release_bank)) begin
                psum_score_rd_credit_q[1] <= 1'b0;
            end else begin
                case ({psum_score_wr_fire && drain_packet_wr_bank,
                       psum_score_rd_fire && pp_rd_bank})
                    2'b10: psum_score_rd_credit_q[1] <= 1'b1;
                    2'b01: psum_score_rd_credit_q[1] <=
                        psum_score_credit1 > 1;
                    2'b11: psum_score_rd_credit_q[1] <=
                        psum_score_credit1 != 0;
                    default: psum_score_rd_credit_q[1] <=
                        psum_score_credit1 != 0;
                endcase
            end

            if (psum_score_rd_fire) begin
                psum_score_return_bank_q <= pp_rd_bank;
                psum_score_return_epoch_q <= psum_score_rd_epoch;
                psum_score_return_context_q <= psum_score_rd_context;
                psum_score_return_last_q <= psum_score_rd_last;
            end

            if ((ENABLE_TAGGED_CONTEXT != 0) &&
                ((psum_score_wr_valid && !psum_score_wr_ready) ||
                 (perf_stage_compute && psum_score_ext_mode &&
                  !psum_score_rd_ready) ||
                 (psum_score_alloc_valid && !psum_score_alloc_ready) ||
                 (psum_score_commit_valid && !psum_score_commit_ready) ||
                 (psum_score_release_valid && !psum_score_release_ready))) begin
                psum_score_credit_stall_cycles <=
                    psum_score_credit_stall_cycles + 1'b1;
            end
        end
    end

    psum_stream_feeder #(.DATA_W(COLS*2*PSUM_W), .AW(PSUM_BUF_AW)) u_psum_stream (
        .clk(clk), .rst(rst), .start(accepted_compute_context_start),
        .compute_fire(compute_fire),
        .is_first_pass(issue_first_q), .use_ext_psum(!issue_first_q),
        .bias_data({COLS*2*PSUM_W{1'b0}}),
        .rd_bank(issue_psum_rd_bank_q),
        // In tagged mode the owner scoreboard is the single source of
        // per-address committed credit.  Leaving the legacy availability
        // counter in this guard would rebuild a second count-to-compute-CE
        // path in parallel with the registered owner permission.
        .overlap_guard_enable(psum_stream_overlap_enable &&
                              (ENABLE_TAGGED_CONTEXT == 0)),
        .available_count(psum_stream_available_count),
        .rd_en(pp_rd_en_request), .rd_bank_out(pp_rd_bank), .rd_addr(pp_rd_addr),
        .rd_data(pp_rd_data), .rd_valid(pp_rd_valid),
        .psum_top_data(psum_stream_data), .psum_top_valid(psum_stream_valid),
        .psum_compute_ready(psum_stream_compute_ready_base),
        .psum_underflow(psum_stream_underflow),
        .psum_wait(psum_stream_wait),
        .pixel_addr()
    );

    genvar ac;
    generate
        if (ENABLE_COLUMN_PSUM != 0) begin : g_column_psum_storage
            integer col_i;

            for (ac = 0; ac < COLS; ac = ac + 1) begin : g_credit_pack
                assign column_credit0_nonzero[ac] =
                    (column_available_count0[ac] != 0);
                assign column_credit1_nonzero[ac] =
                    (column_available_count1[ac] != 0);
                assign column_available_count_flat[
                    (ac+1)*(PSUM_BUF_AW+1)-1 -: (PSUM_BUF_AW+1)] =
                    sched_psum_rd_bank ? column_available_count1[ac] :
                                          column_available_count0[ac];
            end

            always @(posedge clk) begin
                if (rst) begin
                    for (col_i = 0; col_i < COLS; col_i = col_i + 1) begin
                        column_available_count0[col_i] <=
                            {(PSUM_BUF_AW+1){1'b0}};
                        column_available_count1[col_i] <=
                            {(PSUM_BUF_AW+1){1'b0}};
                    end
                end else begin
                    if (continuous_psum_enable &&
                        accepted_compute_context_start &&
                        !sched_final_pass) begin
                        for (col_i = 0; col_i < COLS; col_i = col_i + 1) begin
                            if (sched_psum_wr_bank)
                                column_available_count1[col_i] <=
                                    {(PSUM_BUF_AW+1){1'b0}};
                            else
                                column_available_count0[col_i] <=
                                    {(PSUM_BUF_AW+1){1'b0}};
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

            psum_column_stream_feeder #(
                .COLS(COLS), .DATA_W(PSUM_W*2),
                .AW(PSUM_BUF_AW), .COL_DELAY(4)
            ) u_column_psum_stream (
                .clk(clk), .rst(rst),
                .start(accepted_compute_context_start),
                .compute_fire(compute_fire),
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
        end else begin : g_no_column_psum_storage
            assign column_credit0_nonzero = {COLS{1'b0}};
            assign column_credit1_nonzero = {COLS{1'b0}};
            assign column_available_count_flat =
                {COLS*(PSUM_BUF_AW+1){1'b0}};
            assign column_rd_en = {COLS{1'b0}};
            assign column_rd_bank = 1'b0;
            assign column_rd_addr_flat = {COLS*PSUM_BUF_AW{1'b0}};
            assign column_rd_data_flat = {COLS*2*PSUM_W{1'b0}};
            assign column_rd_valid = {COLS{1'b0}};
            assign column_psum_stream_data = {COLS*2*PSUM_W{1'b0}};
            assign column_psum_stream_valid = {COLS{1'b0}};
            assign column_psum_compute_ready = 1'b0;
            assign column_psum_underflow = 1'b0;
            assign column_psum_wait = 1'b0;
        end
    endgenerate

    systolic_top_feeder #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WEIGHT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_FIFO_DEPTH), .IFM_FIFO_AW(IFM_FIFO_AW),
        .WGT_FIFO_DEPTH(WGT_FIFO_DEPTH), .WGT_FIFO_AW(WGT_FIFO_AW),
        .PSUM_FIFO_DEPTH(PSUM_FIFO_DEPTH), .PSUM_FIFO_AW(PSUM_FIFO_AW),
        .FM_W_MAX(FM_W_MAX), .FM_H_MAX(FM_H_MAX), .IFM_BANKS(IFM_BANKS),
        .TAIL_CYCLES_CONFIG(TAIL_CYCLES_CONFIG),
        .ENABLE_COLUMN_PSUM(ENABLE_COLUMN_PSUM),
        .ENABLE_TAGGED_CONTEXT(ENABLE_TAGGED_CONTEXT),
        .ENABLE_WEIGHT_PRELOAD(ENABLE_WEIGHT_PRELOAD),
        .ENABLE_FAST_CONTEXT_HANDOFF(ENABLE_FAST_CONTEXT_HANDOFF),
        .IFM_EPOCH_USE_URAM(IFM_EPOCH_USE_URAM),
        .ENABLE_VECTOR_ONLY_IFM(ENABLE_VECTOR_ONLY_IFM)
    ) u_top (
        .clk(clk), .rst(rst),
        .feeder_start(sched_feeder_start),
        .feeder_start_ready(feeder_start_ready_raw),
        .feeder_done(feeder_done), .feeder_busy(),
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .kernel_1x1(kernel_1x1),
        .raw_hwc_mode(stream_raw_hwc_mode),
        // These values are sampled at feeder_start, which is also the
        // prepared-queue push edge.  The queue is not fall-through, so use
        // the scheduler's feeder descriptor rather than its current head.
        .compute_start(sched_compute_start), .num_pixels(sched_num_pixels),
        .tail_cycles_config(tail_cycles_config),
        .tagged_context_start_ready(tagged_context_start_ready),
        .tagged_context_admission_ready(tagged_context_admission_ready),
        .raw_hwc_compute_start_level(raw_hwc_compute_start_level),
        .feeder_compute_ready(feeder_compute_ready),
        .compute_done(compute_done), .compute_fire_out(compute_fire),
        .compute_context_start(compute_context_start),
        .compute_context_bank(compute_context_bank),
        .compute_context_epoch(compute_context_epoch),
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
        .conv_stride(conv_stride), .conv_pad(conv_pad),
        .pass_base_k(sched_feeder_pass_base_k),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .vector_ifm_data(vector_ifm_data), .vector_ifm_valid(vector_ifm_valid),
        .vector_ifm_ready(vector_ifm_ready), .vector_packet_done(vector_packet_done),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .is_first_pass(start_desc_first),
        .psum_top_ext({COLS*2*PSUM_W{1'b0}}),
        .use_ext_psum(!start_desc_first),
        .psum_stream_data(psum_stream_data), .psum_stream_valid(psum_stream_valid),
        .psum_stream_compute_ready(column_psum_active && sched_use_ext_psum ?
                                   column_psum_compute_ready : psum_stream_compute_ready),
        .use_psum_stream(!start_desc_first),
        .psum_column_stream_data(column_psum_stream_data),
        .psum_column_stream_valid(column_psum_stream_valid),
        .use_column_psum_stream(column_psum_active && sched_use_ext_psum),
        .wgt_fifo_wr_en(wgt_fifo_wr_en), .wgt_fifo_wr_data(wgt_fifo_wr_data),
        .weight_tile_complete(weight_tile_complete_valid),
        .weight_tile_complete_ready(weight_tile_complete_ready),
        .wgt_fifo_full(wgt_fifo_full),
        .psum_fifo_rd_en(psum_fifo_rd_en), .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_rd_tag(psum_fifo_rd_tag),
        .psum_fifo_empty(psum_fifo_empty),
        .psum_fifo_wr_en_dbg(psum_fifo_wr_en_dbg),
        .ifm_fifo_full(ifm_fifo_full),
        .collector_done_valid(context_lifecycle_done),
        .collector_done_epoch(context_lifecycle_done_epoch),
        .tagged_datapath_error_status(tagged_datapath_error_status),
        .context_alloc_count(context_alloc_count),
        .context_input_issued_count(context_input_issued_count),
        .context_array_retired_count(context_array_retired_count),
        .context_collector_done_count(context_collector_done_count),
        .context_gap_cycles(context_gap_cycles),
        .ifm_ownership_stall_cycles(ifm_ownership_stall_cycles),
        .weight_ownership_stall_cycles(weight_ownership_stall_cycles),
        .psum_credit_stall_cycles(frontend_psum_credit_stall_cycles),
        .context_epoch_mismatch_count(frontend_context_epoch_mismatch_count),
        .context_mismatch_count(frontend_context_mismatch_count),
        .context_ifm_underflow_count(context_ifm_underflow_count),
        .context_psum_underflow_count(frontend_context_psum_underflow_count),
        .context_fifo_drop_count(frontend_context_fifo_drop_count),
        .context_bank_overwrite_count(frontend_context_bank_overwrite_count),
        .context_full_stall_cycles(frontend_context_full_stall_cycles)
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
        .packet_ready(legacy_drain_packet_ready),
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
        .CTX_DEPTH(4), .CTX_AW(2),
        .EPOCH_W(8), .TAG_W(10),
        .ENABLE_TAG_CHECK(ENABLE_TAGGED_CONTEXT)
    ) u_collector (
        .clk(clk), .rst(rst), .enable(continuous_psum_enable),
        .ctx_valid(accepted_compute_context_start && continuous_psum_enable &&
                   (!column_psum_active || start_desc_final)),
        .ctx_ready(collector_ctx_ready),
        .ctx_num_pixels(start_desc_num_pixels),
        .ctx_is_final(start_desc_final),
        .ctx_wr_bank(start_desc_psum_wr_bank),
        .ctx_cout_base(start_desc_cout_base),
        .ctx_cout_valid(start_desc_cout_valid),
        .ctx_trace_match(trace_pass_start),
        .ctx_epoch(compute_context_epoch),
        .ctx_ifm_bank(compute_context_bank),
        .ctx_context_id(next_context_id_q),
        .ctx_parent_epoch(context_start_parent_epoch),
        .ctx_parent_context_id(context_start_parent_context),
        .ctx_first(start_desc_first),
        .psum_fifo_rd_en(collector_psum_fifo_rd_en),
        .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_rd_tag(psum_fifo_rd_tag),
        .psum_fifo_empty(psum_fifo_empty),
        .packet_valid(collector_packet_valid),
        .packet_ready(collector_packet_ready),
        .packet_addr(collector_packet_addr),
        .packet_data(collector_packet_data),
        .packet_is_final(collector_packet_is_final),
        .packet_wr_bank(collector_packet_wr_bank),
        .packet_cout_base(collector_packet_cout_base),
        .packet_cout_valid(collector_packet_cout_valid),
        .packet_epoch(collector_packet_epoch),
        .packet_ifm_bank(collector_packet_ifm_bank),
        .packet_context_id(collector_packet_context_id),
        .packet_parent_epoch(collector_packet_parent_epoch),
        .packet_parent_context_id(collector_packet_parent_context_id),
        .packet_first(collector_packet_first),
        .context_start(collector_context_start),
        .context_done(collector_context_done),
        .partial_done(collector_partial_done),
        .final_done(collector_final_done),
        .context_active(collector_context_active),
        .context_wr_bank(collector_context_wr_bank),
        .context_is_final(collector_context_is_final),
        .context_epoch(collector_context_epoch),
        .context_ifm_bank(collector_context_ifm_bank),
        .context_id(collector_context_id),
        .context_parent_epoch(collector_context_parent_epoch),
        .context_parent_context_id(collector_context_parent_context_id),
        .context_first(collector_context_first),
        .context_done_epoch(collector_context_done_epoch),
        .context_done_ifm_bank(collector_context_done_ifm_bank),
        .context_done_context_id(collector_context_done_context_id),
        .context_done_parent_epoch(collector_context_done_parent_epoch),
        .context_done_parent_context_id(
            collector_context_done_parent_context_id),
        .context_done_first(collector_context_done_first),
        .context_done_final(collector_context_done_final),
        .context_done_wr_bank(collector_context_done_wr_bank),
        .trace_context_active(collector_trace_context_active),
        .trace_context_done(collector_trace_context_done),
        .perf_context_push(perf_collect_context_push),
        .perf_context_pop(perf_collect_context_pop),
        .perf_context_full_stall(perf_collect_context_full_stall),
        .perf_column_empty_wait(perf_collect_column_empty_wait),
        .tag_mismatch_sticky(collector_tag_mismatch_sticky),
        .tag_mismatch_count(collector_tag_mismatch_count),
        .fail_stop(collector_fail_stop)
    );

    generate
        if (ENABLE_COLUMN_PSUM != 0) begin : g_column_psum_collector
            psum_column_output_collector #(
                .COLS(COLS), .PSUM_W(PSUM_W), .ADDR_W(PSUM_BUF_AW),
                .CTX_DEPTH(4), .CTX_AW(2)
            ) u_column_collector (
                .clk(clk), .rst(rst), .enable(column_psum_active),
                .ctx_valid(accepted_compute_context_start && column_psum_active &&
                           !start_desc_final),
                .ctx_ready(column_ctx_ready),
                .ctx_num_pixels(start_desc_num_pixels),
                .ctx_wr_bank(start_desc_psum_wr_bank),
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
        end else begin : g_no_column_psum_collector
            assign column_ctx_ready = 1'b0;
            assign column_context_start = 1'b0;
            assign column_context_done = 1'b0;
            assign column_partial_done = 1'b0;
            assign column_context_active = 1'b0;
            assign column_context_idle = 1'b1;
            assign column_context_wr_bank = 1'b0;
            assign column_trace_context_active = 1'b0;
            assign column_trace_context_done = 1'b0;
            assign column_perf_context_push = 1'b0;
            assign column_perf_context_pop = 1'b0;
            assign column_perf_context_full_stall = 1'b0;
            assign column_perf_empty_wait = 1'b0;
            assign column_psum_fifo_rd_en = 32'd0;
            assign column_wr_en = {COLS{1'b0}};
            assign column_wr_bank = 1'b0;
            assign column_wr_addr_flat = {COLS*PSUM_BUF_AW{1'b0}};
            assign column_wr_data_flat = {COLS*2*PSUM_W{1'b0}};
        end
    endgenerate

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
        .cout_base(start_desc_cout_base),
        .pass_base_k(start_desc_k_pass),
        .weight_done(weight_tile_complete_fire),
        .feed_start(sched_feeder_start),
        .feed_ready(feeder_compute_ready),
        .feed_done(feeder_done),
        .compute_start(accepted_compute_context_start),
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

    // Do not propagate the downstream requant/activation/OFM ready chain back
    // into collector retirement.  Waiting one cycle when the final FIFO is
    // full preserves ordinary ready/valid semantics and makes this FIFO the
    // registered credit boundary for context completion.
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
    wire act_addr_zero;
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
    assign ofm_post_busy = ofm_wb_busy ||
                           ((ENABLE_PACKED_HWC_OFM != 0) && packed_ofm_busy) ||
                           act_fifo_valid || act_fifo_full ||
                           rq_fifo_valid || rq_fifo_full || final_fifo_valid || final_fifo_full ||
                           ofm_valid || act_valid || pool_valid;

    assign packed_ofm_packet_valid =
        (ENABLE_PACKED_HWC_OFM != 0) && act_fifo_valid;
    assign packed_ofm_packet_pixel = act_fifo_addr;
    assign packed_ofm_packet_cout_base = act_fifo_cout_base;
    assign packed_ofm_packet_channel_valid = act_fifo_channel_valid;
    assign packed_ofm_packet_data = act_fifo_data;

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
        .lut_rd_addr(act_lut_rd_addr), .lut_rd_data(act_lut_rd_data),
        .out_valid(act_valid), .out_ready(pool_in_ready),
        .out_addr(act_addr), .out_addr_zero(act_addr_zero),
        .out_cout_base(act_cout_base),
        .out_channel_valid(act_channel_valid), .out_data(act_data)
    );

    ofm_pooling #(
        .COUT_TILE(COLS*2), .ADDR_W(PSUM_BUF_AW), .OFM_W_MAX(FM_W_MAX)
    ) u_pooling (
        .clk(clk), .rst(rst),
        .pool_enable(pool_enable), .pool_stride(pool_stride),
        .conv_ofm_w(ofm_w),
        .in_valid(act_valid), .in_ready(pool_in_ready),
        .in_addr(act_addr), .in_addr_zero(act_addr_zero),
        .in_cout_base(act_cout_base),
        .in_channel_valid(act_channel_valid), .in_data(act_data),
        .out_valid(pool_valid), .out_ready(act_fifo_ready),
        .out_addr(pool_addr), .out_cout_base(pool_cout_base),
        .out_channel_valid(pool_channel_valid), .out_data(pool_data)
    );

    ofm_packet_fifo #(
        .COUT_TILE(COLS*2), .ADDR_W(PSUM_BUF_AW),
        .DEPTH(OFM_FIFO_DEPTH), .AW(OFM_FIFO_AW),
        .CONSERVATIVE_FULL_CREDIT(1)
    ) u_ofm_packet_fifo (
        .clk(clk), .rst(rst),
        .in_valid(pool_valid), .in_ready(act_fifo_ready),
        .in_addr(pool_addr), .in_cout_base(pool_cout_base),
        .in_channel_valid(pool_channel_valid), .in_data(pool_data),
        .out_valid(act_fifo_valid),
        .out_ready((ENABLE_PACKED_HWC_OFM != 0) ?
                   packed_ofm_packet_ready : !ofm_packet_full),
        .out_addr(act_fifo_addr), .out_cout_base(act_fifo_cout_base),
        .out_channel_valid(act_fifo_channel_valid), .out_data(act_fifo_data),
        .full(act_fifo_full), .almost_full()
    );

    generate
        if (ENABLE_PACKED_HWC_OFM != 0) begin : g_packed_hwc_ofm
            // The packed sink owns packet backpressure.  Keep all legacy byte
            // address pins quiescent so this path is statically removed.
            assign ofm_packet_full =
                act_fifo_valid && !packed_ofm_packet_ready;
            assign ofm_mem_wr_en = 1'b0;
            assign ofm_mem_wr_addr = {OFM_ADDR_W{1'b0}};
            assign ofm_mem_wr_data = 8'd0;
            assign ofm_wb_busy = 1'b0;
        end else begin : g_legacy_byte_ofm
            ofm_writeback #(
                .COUT_TILE(COLS*2), .PIXEL_AW(PSUM_BUF_AW),
                .ADDR_W(OFM_ADDR_W), .FIFO_DEPTH(OFM_FIFO_DEPTH),
                .FIFO_AW(OFM_FIFO_AW)
            ) u_ofm_writeback (
                .clk(clk), .rst(rst),
                .packet_valid(act_fifo_valid), .packet_pixel(act_fifo_addr),
                .packet_cout_base(act_fifo_cout_base),
                .packet_channel_valid(act_fifo_channel_valid),
                .packet_data(act_fifo_data),
                .packet_full(ofm_packet_full), .cout_total(cout_total),
                .pixel_base(tile_pixel_base),
                .wr_en(ofm_mem_wr_en), .wr_ready(ofm_mem_wr_ready),
                .wr_addr(ofm_mem_wr_addr), .wr_data(ofm_mem_wr_data),
                .busy(ofm_wb_busy)
            );
        end
    endgenerate
endmodule

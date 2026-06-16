`timescale 1ns / 1ps
// Simple local configuration register bank for one convolution layer.
//
// Register map:
//   0x00 CTRL/STATUS: write bit0=start pulse, bit1=clear status;
//                     read bit0=busy, bit1=done_sticky, bit2=config_error
//   0x01 FM_SIZE:     [8:0]=fm_h,   [24:16]=fm_w
//   0x02 OFM_SIZE:    [8:0]=ofm_h,  [24:16]=ofm_w
//   0x03 CONV:        [1:0]=stride, [9:8]=pad, bit16=native 1x1 vector mode
//   0x04 K_TOTAL:     [13:0]=k_total
//   0x05 COUT_TOTAL:  [10:0]=cout_total
//   0x06 NUM_PIXELS:  [15:0]=num_pixels
//   0x07 ACT_CFG:     [1:0]=activation_mode, 0=bypass, 1=ReLU, 2=Leaky LUT
//   0x08 TILE_ROWS:   [8:0]=tile_oy_base, [24:16]=tile_ofm_h, 0 tile_ofm_h means full ofm_h
//   0x09 PIXEL_BASE:  [23:0]=tile_pixel_base
//   0x0a DBG_EXPECTED: expected OFM AXIS packets for the current tile
//   0x0b DBG_CORE_WR:  OFM packets accepted from core writeback
//   0x0c DBG_AXIS_WR:  OFM AXIS packets accepted by the downstream sink
//   0x0d DBG_TLASTS:   OFM AXIS TLAST handshake count
//   0x0e DBG_LAST_END: packet count at the most recent TLAST handshake
//   0x0f IFM_ZP:       [7:0]=input_zero_point for uint8-to-sint8 IFM centering
//   0x10 POOL_CFG:     bit0=pool_enable, [3:2]=pool_stride, 0/bypass by default
//   0x11 EXPECTED_BYTES: expected OFM byte-stream payload bytes for TLAST/debug
//   0x12 PERF_BUSY:     layer_busy cycles for the current tile
//   0x13 PERF_WAIT_ANY: busy cycles stalled on any external service request
//   0x14 PERF_WAIT_BIAS: busy cycles with bias_load_req asserted
//   0x15 PERF_WAIT_WEIGHT: busy cycles with weight_load_req asserted
//   0x16 PERF_WAIT_IFM: busy cycles with feeder_fill_req asserted
//   0x17 PERF_WAIT_OFM: busy cycles with OFM backpressure asserted
//   0x18 PERF_COMPUTE:  cycles where the systolic array accepts a pixel
//   0x19 STREAM_CFG:     bit0 enables one-DMA-per-tile batch streams,
//                        bit1 enables experimental raw-HWC IFM tile cache,
//                        bit2 enables experimental early PSUM drain,
//                        bit3 enables experimental next-pass prefetch,
//                        bit4 enables experimental partial-PSUM overlap,
//                        bit5 enables experimental continuous PSUM collector,
//                        bit6 enables experimental column-level partial PSUM
//   0x1a BIAS_PACKETS:   expected bias packets for the current tile
//   0x1b WEIGHT_PACKETS: expected weight packets for the current tile
//   0x1c IFM_PACKETS:    expected IFM line packets for the current tile
//   0x1d BIAS_DONE:      completed bias packets for the current tile
//   0x1e WEIGHT_DONE:    completed weight packets for the current tile
//   0x1f IFM_DONE:       completed IFM line packets for the current tile
//   0x24 VECTOR_PACKETS: completed native 1x1 vector packets
//   0x25 VECTOR_PIXELS:  completed native 1x1 pixel vectors
//   0x26 VECTOR_BEATS:   accepted native 1x1 AXIS beats
//   0x27 VECTOR_STALLS:  native 1x1 cycles stalled by full IFM FIFOs
//   0x28 STAGE_BIAS:     scheduler cycles in bias-load phase
//   0x29 STAGE_WEIGHT:   scheduler cycles in weight-load phase
//   0x2a STAGE_FEEDER:   scheduler cycles in IFM feeder phase
//   0x2b STAGE_COMPUTE:  scheduler cycles in compute phase
//   0x2c STAGE_DRAIN:    scheduler cycles in PSUM drain phase
//   0x2d STAGE_OFM_POST: post-scheduler OFM pipeline drain cycles
//   0x2e FEED_FILL_WAIT: feeder cycles waiting for external IFM/vector fill
//   0x2f FEED_PUSH:      feeder cycles that push IFM data into the core FIFOs
//   0x30 FEED_FIFO_STALL: feeder cycles stalled by full IFM FIFOs
//   0x31 FEED_WIN_NOT_READY: 3x3 feeder cycles waiting for window readiness
//   0x32 COMP_WLOAD:     core weight-load cycles inside compute stage
//   0x33 COMP_ACTIVE:    core active compute cycles inside compute stage
//   0x34 COMP_FIRE:      core cycles that accept one output pixel
//   0x35 COMP_IFM_STALL: core active cycles stalled by empty IFM FIFO
//   0x36 COMP_TAIL:      core systolic tail cycles inside compute stage
//   0x37 SUBPERF_VERSION: fixed sub-stage counter map version
//   0x38 TAIL_CONFIG:    [15:0]=configured systolic tail cycles per compute pass,
//                        [31:16]=raw-HWC compute start FIFO level
//   0x39 TAIL_ELAPSED:   alias of COMP_TAIL for tail-sweep scripts
//   0x3a DRAIN_EMPTY_WAIT: PSUM drain cycles waiting for FIFO data
//   0x3b DRAIN_EMPTY_STICKY: sticky flag for any PSUM drain FIFO wait
//   0x3c RAW_LOAD_ACTIVE: raw-HWC cache loading cycles
//   0x3d RAW_LOAD_UNPACK: raw-HWC cache beat-unpack cycles
//   0x3e RAW_REPLAY_ACTIVE: raw-HWC cache replay active cycles
//   0x3f RAW_REPLAY_WAIT_READY: raw-HWC replay cycles stalled by IFM FIFO ready
//   0x40 DRAIN_READ_FIRE: PSUM drain FIFO read handshakes
//   0x41 DRAIN_PACKET_FIRE: packets accepted by drain downstream
//   0x42 DRAIN_READY_STALL: drain cycles stalled by downstream backpressure
//   0x43 DRAIN_INTERNAL_FULL: drain cycles blocked by its output/skid registers
//   0x44 DRAINPERF_VERSION: fixed drain sub-stage counter map version
//   0x45 PREFETCH_START: next-pass prefetch starts
//   0x46 PREFETCH_WEIGHT_DONE: prefetched weight tile completions
//   0x47 PREFETCH_FEED_DONE: prefetched IFM replay completions
//   0x48 PREFETCH_HIT: next pass skipped weight/feed using prefetched data
//   0x49 PREFETCH_MISS: current pass completed before prefetch was ready
//   0x4a PREFETCH_STALL: cycles waiting for incomplete prefetch
//   0x4b PREFETCHPERF_VERSION: fixed prefetch counter map version
//   0x4c PSUMOVL_START: partial-PSUM overlap starts
//   0x4d PSUMOVL_HIT: overlap starts that reached next compute
//   0x4e PSUMOVL_WAIT_PSUM: cycles waiting for partial-PSUM lead
//   0x4f PSUMOVL_UNDERFLOW: illegal partial-PSUM read attempts
//   0x50 PSUMOVL_VERSION: fixed partial-PSUM overlap counter map version
//   0x51 COLLECT_PACKET_FIRE: continuous collector packets accepted downstream
//   0x52 COLLECT_PARTIAL_WRITE: continuous collector partial packets written to PSUM RAM
//   0x53 COLLECT_FINAL_WRITE: continuous collector final packets sent toward OFM
//   0x54 COLLECT_CONTEXT_PUSH: pass contexts accepted by collector
//   0x55 COLLECT_CONTEXT_POP: pass contexts started by collector
//   0x56 COLLECT_CONTEXT_FULL_STALL: cycles compute start waited for context space
//   0x57 COLLECT_COLUMN_EMPTY_WAIT: collector cycles waiting for any column FIFO
//   0x58 COLLECTPERF_VERSION: fixed continuous collector counter map version
//   0x59 PASSTRACE_SELECT: bit31=enable, [23:16]=cout block, [15:0]=K pass
//   0x5a PASS_COUNT: compute pass count observed by timeline monitor
//   0x5b PASS_START_TO_FIRST: sum compute_start -> first compute_fire cycles
//   0x5c PASS_FIRST_TO_LAST: sum first compute_fire -> last compute_fire cycles
//   0x5d PASS_LAST_TO_DONE: sum last compute_fire -> compute_done cycles
//   0x5e PASS_COLLECT_FIRST_WAIT: sum compute_start -> first collector packet
//   0x5f PASS_COLLECT_COLUMN_EMPTY: collector column-empty wait cycles
//   0x60 PASS_REPLAY_DURING_COMPUTE: raw replay active while pass compute is active
//   0x61 PASS_COMPUTE_IDLE_STAGE: stage-compute cycles without compute_fire
//   0x62..0x6c PASSTRACE timestamps for selected pass
//   0x6d PASSPERF_VERSION: bit31=trace_valid, [30:0]=version
//   0x6e COLTRACE_CTRL: read bit31=valid, [4:0]=selected column
//   0x6f COLTRACE_FIRST_WR: selected column first PSUM FIFO write timestamp
//   0x70 COLTRACE_LAST_WR: selected column last PSUM FIFO write timestamp
//   0x71 COLTRACE_WR_COUNT: selected column writes captured for selected pass
//   0x72 COLTRACE_EMPTY_WAIT: cycles selected column blocked collector reads
//   0x73 COLTRACE_MISSING_OR: OR of missing-column masks during collector waits
//   0x74 COLTRACE_MISSING_FIRST: first missing-column mask
//   0x75 COLTRACE_MISSING_LAST: most recent missing-column mask
//   0x76 COLTRACE_VERSION: fixed column-trace register map version
module layer_config_regs #(
    parameter IFM_FIFO_DEPTH = 1024,
    parameter [15:0] RAW_HWC_COMPUTE_START_LEVEL = 16'd0
) (
    input  clk,
    input  rst,

    input         cfg_wr_en,
    input  [6:0]  cfg_addr,
    input  [31:0] cfg_wdata,
    input         cfg_rd_en,
    output reg [31:0] cfg_rdata,

    input  layer_busy,
    input  layer_done,
    input  [31:0] dbg_expected_bytes,
    input  [31:0] dbg_core_wr_count,
    input  [31:0] dbg_axis_wr_count,
    input  [31:0] dbg_tlast_count,
    input  [31:0] dbg_last_tlast_index,
    input         perf_wait_bias,
    input         perf_wait_weight,
    input         perf_wait_ifm,
    input         perf_wait_ofm,
    input         perf_compute_fire,
    input         perf_stage_bias,
    input         perf_stage_weight,
    input         perf_stage_feeder,
    input         perf_stage_compute,
    input         perf_stage_drain,
    input         perf_stage_ofm_post,
    input         perf_feed_fill_wait,
    input         perf_feed_push,
    input         perf_feed_fifo_stall,
    input         perf_feed_win_not_ready,
    input         perf_comp_wload,
    input         perf_comp_active,
    input         perf_comp_ifm_stall,
    input         perf_comp_tail,
    input  [31:0] perf_tail_cycles_configured,
    input         perf_drain_fifo_empty_wait,
    input         perf_drain_fifo_empty_sticky,
    input         perf_drain_read_fire,
    input         perf_drain_packet_fire,
    input         perf_drain_ready_stall,
    input         perf_drain_internal_full_wait,
    input         perf_prefetch_start,
    input         perf_prefetch_weight_done,
    input         perf_prefetch_feed_done,
    input         perf_prefetch_hit,
    input         perf_prefetch_miss,
    input         perf_prefetch_stall,
    input         perf_psumovl_start,
    input         perf_psumovl_hit,
    input         perf_psumovl_wait_psum,
    input         perf_psumovl_underflow,
    input         perf_collect_packet_fire,
    input         perf_collect_partial_write,
    input         perf_collect_final_write,
    input         perf_collect_context_push,
    input         perf_collect_context_pop,
    input         perf_collect_context_full_stall,
    input         perf_collect_column_empty_wait,
    input  [31:0] perf_pass_count,
    input  [31:0] perf_pass_start_to_first_fire,
    input  [31:0] perf_pass_first_to_last_fire,
    input  [31:0] perf_pass_last_fire_to_done,
    input  [31:0] perf_pass_collect_first_wait,
    input  [31:0] perf_pass_collect_column_empty,
    input  [31:0] perf_pass_replay_active_during_compute,
    input  [31:0] perf_pass_compute_idle_in_stage,
    input  [31:0] pass_trace_weight_done,
    input  [31:0] pass_trace_feed_start,
    input  [31:0] pass_trace_feed_ready,
    input  [31:0] pass_trace_feed_done,
    input  [31:0] pass_trace_compute_start,
    input  [31:0] pass_trace_first_fire,
    input  [31:0] pass_trace_last_fire,
    input  [31:0] pass_trace_compute_done,
    input  [31:0] pass_trace_collect_first,
    input  [31:0] pass_trace_collect_last,
    input  [31:0] pass_trace_pass_done,
    input         pass_trace_valid,
    input  [31:0] col_trace_first_wr,
    input  [31:0] col_trace_last_wr,
    input  [31:0] col_trace_wr_count,
    input  [31:0] col_trace_empty_wait,
    input  [31:0] col_trace_missing_mask_or,
    input  [31:0] col_trace_missing_mask_first,
    input  [31:0] col_trace_missing_mask_last,
    input         col_trace_valid,
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
    output reg start_pulse,

    output reg [8:0]  fm_h,
    output reg [8:0]  fm_w,
    output reg [8:0]  ofm_h,
    output reg [8:0]  ofm_w,
    output reg [1:0]  conv_stride,
    output reg [1:0]  conv_pad,
    output reg        kernel_1x1,
    output reg [1:0]  activation_mode,
    output reg [13:0] k_total,
    output reg [10:0] cout_total,
    output reg [15:0] num_pixels,
    output reg [8:0]  tile_oy_base,
    output reg [8:0]  tile_ofm_h,
    output reg [23:0] tile_pixel_base,
    output reg [7:0]  input_zero_point,
    output reg        pool_enable,
    output reg [1:0]  pool_stride,
    output reg [31:0] expected_bytes,
    output reg        stream_batch_mode,
    output reg        stream_raw_hwc_mode,
    output reg        early_drain_enable,
    output reg        pass_prefetch_enable,
    output reg        psum_stream_overlap_enable,
    output reg        continuous_psum_enable,
    output reg        column_psum_enable,
    output reg        during_compute_prefetch_enable,
    output reg [31:0] stream_bias_packets,
    output reg [31:0] stream_weight_packets,
    output reg [31:0] stream_ifm_packets,
    output reg [15:0] tail_cycles_config,
    output reg [15:0] raw_hwc_compute_start_level,
    output reg        pass_trace_enable,
    output reg [7:0]  pass_trace_cout_block,
    output reg [15:0] pass_trace_k_pass,
    output reg [4:0]  col_trace_selected_col,
    output reg        config_error
);
    reg done_sticky;
    reg [31:0] perf_busy_cycles;
    reg [31:0] perf_wait_any_cycles;
    reg [31:0] perf_wait_bias_cycles;
    reg [31:0] perf_wait_weight_cycles;
    reg [31:0] perf_wait_ifm_cycles;
    reg [31:0] perf_wait_ofm_cycles;
    reg [31:0] perf_compute_cycles;
    reg [31:0] perf_stage_bias_cycles;
    reg [31:0] perf_stage_weight_cycles;
    reg [31:0] perf_stage_feeder_cycles;
    reg [31:0] perf_stage_compute_cycles;
    reg [31:0] perf_stage_drain_cycles;
    reg [31:0] perf_stage_ofm_post_cycles;
    reg [31:0] perf_feed_fill_wait_cycles;
    reg [31:0] perf_feed_push_cycles;
    reg [31:0] perf_feed_fifo_stall_cycles;
    reg [31:0] perf_feed_win_not_ready_cycles;
    reg [31:0] perf_comp_wload_cycles;
    reg [31:0] perf_comp_active_cycles;
    reg [31:0] perf_comp_ifm_stall_cycles;
    reg [31:0] perf_comp_tail_cycles;
    reg [31:0] perf_drain_fifo_empty_wait_cycles;
    reg        perf_drain_fifo_empty_sticky_latched;
    reg [31:0] perf_drain_read_fire_cycles;
    reg [31:0] perf_drain_packet_fire_cycles;
    reg [31:0] perf_drain_ready_stall_cycles;
    reg [31:0] perf_drain_internal_full_cycles;
    reg [31:0] perf_prefetch_start_cycles;
    reg [31:0] perf_prefetch_weight_done_cycles;
    reg [31:0] perf_prefetch_feed_done_cycles;
    reg [31:0] perf_prefetch_hit_cycles;
    reg [31:0] perf_prefetch_miss_cycles;
    reg [31:0] perf_prefetch_stall_cycles;
    reg [31:0] perf_psumovl_start_cycles;
    reg [31:0] perf_psumovl_hit_cycles;
    reg [31:0] perf_psumovl_wait_psum_cycles;
    reg [31:0] perf_psumovl_underflow_cycles;
    reg [31:0] perf_collect_packet_fire_cycles;
    reg [31:0] perf_collect_partial_write_cycles;
    reg [31:0] perf_collect_final_write_cycles;
    reg [31:0] perf_collect_context_push_cycles;
    reg [31:0] perf_collect_context_pop_cycles;
    reg [31:0] perf_collect_context_full_stall_cycles;
    reg [31:0] perf_collect_column_empty_wait_cycles;
    wire cfg_idle = !layer_busy;
    wire perf_wait_any = perf_wait_bias || perf_wait_weight ||
                         perf_wait_ifm || perf_wait_ofm;
    wire invalid_1x1_config =
        kernel_1x1 &&
        (!stream_batch_mode || conv_stride != 2'd1 || conv_pad != 2'd0 ||
         num_pixels > IFM_FIFO_DEPTH);

    always @(posedge clk) begin
        if (rst) begin
            start_pulse <= 1'b0;
            done_sticky <= 1'b0;
            fm_h <= 9'd0;
            fm_w <= 9'd0;
            ofm_h <= 9'd0;
            ofm_w <= 9'd0;
            conv_stride <= 2'd1;
            conv_pad <= 2'd0;
            kernel_1x1 <= 1'b0;
            activation_mode <= 2'd0;
            k_total <= 14'd0;
            cout_total <= 11'd0;
            num_pixels <= 16'd0;
            tile_oy_base <= 9'd0;
            tile_ofm_h <= 9'd0;
            tile_pixel_base <= 24'd0;
            input_zero_point <= 8'd0;
            pool_enable <= 1'b0;
            pool_stride <= 2'd0;
            expected_bytes <= 32'd0;
            stream_batch_mode <= 1'b0;
            stream_raw_hwc_mode <= 1'b0;
            early_drain_enable <= 1'b0;
            pass_prefetch_enable <= 1'b0;
            psum_stream_overlap_enable <= 1'b0;
            continuous_psum_enable <= 1'b0;
            column_psum_enable <= 1'b0;
            during_compute_prefetch_enable <= 1'b0;
            stream_bias_packets <= 32'd0;
            stream_weight_packets <= 32'd0;
            stream_ifm_packets <= 32'd0;
            tail_cycles_config <= 16'd0;
            raw_hwc_compute_start_level <= RAW_HWC_COMPUTE_START_LEVEL;
            pass_trace_enable <= 1'b0;
            pass_trace_cout_block <= 8'd0;
            pass_trace_k_pass <= 16'd0;
            col_trace_selected_col <= 5'd0;
            config_error <= 1'b0;
            perf_busy_cycles <= 32'd0;
            perf_wait_any_cycles <= 32'd0;
            perf_wait_bias_cycles <= 32'd0;
            perf_wait_weight_cycles <= 32'd0;
            perf_wait_ifm_cycles <= 32'd0;
            perf_wait_ofm_cycles <= 32'd0;
            perf_compute_cycles <= 32'd0;
            perf_stage_bias_cycles <= 32'd0;
            perf_stage_weight_cycles <= 32'd0;
            perf_stage_feeder_cycles <= 32'd0;
            perf_stage_compute_cycles <= 32'd0;
            perf_stage_drain_cycles <= 32'd0;
            perf_stage_ofm_post_cycles <= 32'd0;
            perf_feed_fill_wait_cycles <= 32'd0;
            perf_feed_push_cycles <= 32'd0;
            perf_feed_fifo_stall_cycles <= 32'd0;
            perf_feed_win_not_ready_cycles <= 32'd0;
            perf_comp_wload_cycles <= 32'd0;
            perf_comp_active_cycles <= 32'd0;
            perf_comp_ifm_stall_cycles <= 32'd0;
            perf_comp_tail_cycles <= 32'd0;
            perf_drain_fifo_empty_wait_cycles <= 32'd0;
            perf_drain_fifo_empty_sticky_latched <= 1'b0;
            perf_drain_read_fire_cycles <= 32'd0;
            perf_drain_packet_fire_cycles <= 32'd0;
            perf_drain_ready_stall_cycles <= 32'd0;
            perf_drain_internal_full_cycles <= 32'd0;
            perf_prefetch_start_cycles <= 32'd0;
            perf_prefetch_weight_done_cycles <= 32'd0;
            perf_prefetch_feed_done_cycles <= 32'd0;
            perf_prefetch_hit_cycles <= 32'd0;
            perf_prefetch_miss_cycles <= 32'd0;
            perf_prefetch_stall_cycles <= 32'd0;
            perf_psumovl_start_cycles <= 32'd0;
            perf_psumovl_hit_cycles <= 32'd0;
            perf_psumovl_wait_psum_cycles <= 32'd0;
            perf_psumovl_underflow_cycles <= 32'd0;
            perf_collect_packet_fire_cycles <= 32'd0;
            perf_collect_partial_write_cycles <= 32'd0;
            perf_collect_final_write_cycles <= 32'd0;
            perf_collect_context_push_cycles <= 32'd0;
            perf_collect_context_pop_cycles <= 32'd0;
            perf_collect_context_full_stall_cycles <= 32'd0;
            perf_collect_column_empty_wait_cycles <= 32'd0;
        end else begin
            start_pulse <= 1'b0;
            if (layer_done)
                done_sticky <= 1'b1;

            if (layer_busy) begin
                perf_busy_cycles <= perf_busy_cycles + 1'b1;
                if (perf_wait_any)
                    perf_wait_any_cycles <= perf_wait_any_cycles + 1'b1;
                if (perf_wait_bias)
                    perf_wait_bias_cycles <= perf_wait_bias_cycles + 1'b1;
                if (perf_wait_weight)
                    perf_wait_weight_cycles <= perf_wait_weight_cycles + 1'b1;
                if (perf_wait_ifm)
                    perf_wait_ifm_cycles <= perf_wait_ifm_cycles + 1'b1;
                if (perf_wait_ofm)
                    perf_wait_ofm_cycles <= perf_wait_ofm_cycles + 1'b1;
                if (perf_compute_fire)
                    perf_compute_cycles <= perf_compute_cycles + 1'b1;
                if (perf_stage_bias)
                    perf_stage_bias_cycles <= perf_stage_bias_cycles + 1'b1;
                if (perf_stage_weight)
                    perf_stage_weight_cycles <= perf_stage_weight_cycles + 1'b1;
                if (perf_stage_feeder)
                    perf_stage_feeder_cycles <= perf_stage_feeder_cycles + 1'b1;
                if (perf_stage_compute)
                    perf_stage_compute_cycles <= perf_stage_compute_cycles + 1'b1;
                if (perf_stage_drain)
                    perf_stage_drain_cycles <= perf_stage_drain_cycles + 1'b1;
                if (perf_stage_ofm_post)
                    perf_stage_ofm_post_cycles <= perf_stage_ofm_post_cycles + 1'b1;
                if (perf_feed_fill_wait)
                    perf_feed_fill_wait_cycles <= perf_feed_fill_wait_cycles + 1'b1;
                if (perf_feed_push)
                    perf_feed_push_cycles <= perf_feed_push_cycles + 1'b1;
                if (perf_feed_fifo_stall)
                    perf_feed_fifo_stall_cycles <= perf_feed_fifo_stall_cycles + 1'b1;
                if (perf_feed_win_not_ready)
                    perf_feed_win_not_ready_cycles <= perf_feed_win_not_ready_cycles + 1'b1;
                if (perf_comp_wload)
                    perf_comp_wload_cycles <= perf_comp_wload_cycles + 1'b1;
                if (perf_comp_active)
                    perf_comp_active_cycles <= perf_comp_active_cycles + 1'b1;
                if (perf_comp_ifm_stall)
                    perf_comp_ifm_stall_cycles <= perf_comp_ifm_stall_cycles + 1'b1;
                if (perf_comp_tail)
                    perf_comp_tail_cycles <= perf_comp_tail_cycles + 1'b1;
                if (perf_drain_fifo_empty_wait)
                    perf_drain_fifo_empty_wait_cycles <= perf_drain_fifo_empty_wait_cycles + 1'b1;
                if (perf_drain_fifo_empty_sticky)
                    perf_drain_fifo_empty_sticky_latched <= 1'b1;
                if (perf_drain_read_fire)
                    perf_drain_read_fire_cycles <= perf_drain_read_fire_cycles + 1'b1;
                if (perf_drain_packet_fire)
                    perf_drain_packet_fire_cycles <= perf_drain_packet_fire_cycles + 1'b1;
                if (perf_drain_ready_stall)
                    perf_drain_ready_stall_cycles <= perf_drain_ready_stall_cycles + 1'b1;
                if (perf_drain_internal_full_wait)
                    perf_drain_internal_full_cycles <= perf_drain_internal_full_cycles + 1'b1;
                if (perf_prefetch_start)
                    perf_prefetch_start_cycles <= perf_prefetch_start_cycles + 1'b1;
                if (perf_prefetch_weight_done)
                    perf_prefetch_weight_done_cycles <= perf_prefetch_weight_done_cycles + 1'b1;
                if (perf_prefetch_feed_done)
                    perf_prefetch_feed_done_cycles <= perf_prefetch_feed_done_cycles + 1'b1;
                if (perf_prefetch_hit)
                    perf_prefetch_hit_cycles <= perf_prefetch_hit_cycles + 1'b1;
                if (perf_prefetch_miss)
                    perf_prefetch_miss_cycles <= perf_prefetch_miss_cycles + 1'b1;
                if (perf_prefetch_stall)
                    perf_prefetch_stall_cycles <= perf_prefetch_stall_cycles + 1'b1;
                if (perf_psumovl_start)
                    perf_psumovl_start_cycles <= perf_psumovl_start_cycles + 1'b1;
                if (perf_psumovl_hit)
                    perf_psumovl_hit_cycles <= perf_psumovl_hit_cycles + 1'b1;
                if (perf_psumovl_wait_psum)
                    perf_psumovl_wait_psum_cycles <= perf_psumovl_wait_psum_cycles + 1'b1;
                if (perf_psumovl_underflow)
                    perf_psumovl_underflow_cycles <= perf_psumovl_underflow_cycles + 1'b1;
                if (perf_collect_packet_fire)
                    perf_collect_packet_fire_cycles <= perf_collect_packet_fire_cycles + 1'b1;
                if (perf_collect_partial_write)
                    perf_collect_partial_write_cycles <= perf_collect_partial_write_cycles + 1'b1;
                if (perf_collect_final_write)
                    perf_collect_final_write_cycles <= perf_collect_final_write_cycles + 1'b1;
                if (perf_collect_context_push)
                    perf_collect_context_push_cycles <= perf_collect_context_push_cycles + 1'b1;
                if (perf_collect_context_pop)
                    perf_collect_context_pop_cycles <= perf_collect_context_pop_cycles + 1'b1;
                if (perf_collect_context_full_stall)
                    perf_collect_context_full_stall_cycles <= perf_collect_context_full_stall_cycles + 1'b1;
                if (perf_collect_column_empty_wait)
                    perf_collect_column_empty_wait_cycles <= perf_collect_column_empty_wait_cycles + 1'b1;
            end

            if (cfg_wr_en) begin
                case (cfg_addr)
                    7'h00: begin
                        if (cfg_wdata[0] && cfg_idle) begin
                            done_sticky <= 1'b0;
                            config_error <= invalid_1x1_config;
                            if (!invalid_1x1_config) begin
                                start_pulse <= 1'b1;
                                perf_busy_cycles <= 32'd0;
                                perf_wait_any_cycles <= 32'd0;
                                perf_wait_bias_cycles <= 32'd0;
                                perf_wait_weight_cycles <= 32'd0;
                                perf_wait_ifm_cycles <= 32'd0;
                                perf_wait_ofm_cycles <= 32'd0;
                                perf_compute_cycles <= 32'd0;
                                perf_stage_bias_cycles <= 32'd0;
                                perf_stage_weight_cycles <= 32'd0;
                                perf_stage_feeder_cycles <= 32'd0;
                                perf_stage_compute_cycles <= 32'd0;
                                perf_stage_drain_cycles <= 32'd0;
                                perf_stage_ofm_post_cycles <= 32'd0;
                                perf_feed_fill_wait_cycles <= 32'd0;
                                perf_feed_push_cycles <= 32'd0;
                                perf_feed_fifo_stall_cycles <= 32'd0;
                                perf_feed_win_not_ready_cycles <= 32'd0;
                                perf_comp_wload_cycles <= 32'd0;
                                perf_comp_active_cycles <= 32'd0;
                                perf_comp_ifm_stall_cycles <= 32'd0;
                                perf_comp_tail_cycles <= 32'd0;
                                perf_drain_fifo_empty_wait_cycles <= 32'd0;
                                perf_drain_fifo_empty_sticky_latched <= 1'b0;
                                perf_drain_read_fire_cycles <= 32'd0;
                                perf_drain_packet_fire_cycles <= 32'd0;
                                perf_drain_ready_stall_cycles <= 32'd0;
                                perf_drain_internal_full_cycles <= 32'd0;
                                perf_prefetch_start_cycles <= 32'd0;
                                perf_prefetch_weight_done_cycles <= 32'd0;
                                perf_prefetch_feed_done_cycles <= 32'd0;
                                perf_prefetch_hit_cycles <= 32'd0;
                                perf_prefetch_miss_cycles <= 32'd0;
                                perf_prefetch_stall_cycles <= 32'd0;
                                perf_psumovl_start_cycles <= 32'd0;
                                perf_psumovl_hit_cycles <= 32'd0;
                                perf_psumovl_wait_psum_cycles <= 32'd0;
                                perf_psumovl_underflow_cycles <= 32'd0;
                                perf_collect_packet_fire_cycles <= 32'd0;
                                perf_collect_partial_write_cycles <= 32'd0;
                                perf_collect_final_write_cycles <= 32'd0;
                                perf_collect_context_push_cycles <= 32'd0;
                                perf_collect_context_pop_cycles <= 32'd0;
                                perf_collect_context_full_stall_cycles <= 32'd0;
                                perf_collect_column_empty_wait_cycles <= 32'd0;
                            end
                        end
                        if (cfg_wdata[1]) begin
                            done_sticky <= 1'b0;
                            config_error <= 1'b0;
                            perf_drain_fifo_empty_sticky_latched <= 1'b0;
                        end
                    end
                    7'h01: begin
                        if (cfg_idle) begin
                            fm_h <= cfg_wdata[8:0];
                            fm_w <= cfg_wdata[24:16];
                        end
                    end
                    7'h02: begin
                        if (cfg_idle) begin
                            ofm_h <= cfg_wdata[8:0];
                            ofm_w <= cfg_wdata[24:16];
                        end
                    end
                    7'h03: begin
                        if (cfg_idle) begin
                            conv_stride <= cfg_wdata[1:0];
                            conv_pad <= cfg_wdata[9:8];
                            kernel_1x1 <= cfg_wdata[16];
                        end
                    end
                    7'h04: if (cfg_idle) k_total <= cfg_wdata[13:0];
                    7'h05: if (cfg_idle) cout_total <= cfg_wdata[10:0];
                    7'h06: if (cfg_idle) num_pixels <= cfg_wdata[15:0];
                    7'h07: if (cfg_idle) activation_mode <= cfg_wdata[1:0];
                    7'h08: begin
                        if (cfg_idle) begin
                            tile_oy_base <= cfg_wdata[8:0];
                            tile_ofm_h <= cfg_wdata[24:16];
                        end
                    end
                    7'h09: if (cfg_idle) tile_pixel_base <= cfg_wdata[23:0];
                    7'h0f: if (cfg_idle) input_zero_point <= cfg_wdata[7:0];
                    7'h10: begin
                        if (cfg_idle) begin
                            pool_enable <= cfg_wdata[0];
                            pool_stride <= cfg_wdata[3:2];
                        end
                    end
                    7'h11: if (cfg_idle) expected_bytes <= cfg_wdata;
                    7'h19: begin
                        if (cfg_idle) begin
                            stream_batch_mode <= cfg_wdata[0];
                            stream_raw_hwc_mode <= cfg_wdata[1];
                            early_drain_enable <= cfg_wdata[2];
                            pass_prefetch_enable <= cfg_wdata[3];
                            psum_stream_overlap_enable <= cfg_wdata[4];
                            continuous_psum_enable <= cfg_wdata[5];
                            column_psum_enable <= cfg_wdata[6];
                            during_compute_prefetch_enable <= cfg_wdata[7];
                        end
                    end
                    7'h1a: if (cfg_idle) stream_bias_packets <= cfg_wdata;
                    7'h1b: if (cfg_idle) stream_weight_packets <= cfg_wdata;
                    7'h1c: if (cfg_idle) stream_ifm_packets <= cfg_wdata;
                    7'h38: if (cfg_idle) begin
                        tail_cycles_config <= cfg_wdata[15:0];
                        raw_hwc_compute_start_level <= cfg_wdata[31:16];
                    end
                    7'h59: if (cfg_idle) begin
                        pass_trace_enable <= cfg_wdata[31];
                        pass_trace_cout_block <= cfg_wdata[23:16];
                        pass_trace_k_pass <= cfg_wdata[15:0];
                    end
                    7'h6e: if (cfg_idle)
                        col_trace_selected_col <= cfg_wdata[4:0];
                    default: begin end
                endcase
            end
        end
    end

    always @(*) begin
        case (cfg_addr)
            7'h00: cfg_rdata = {29'd0, config_error, done_sticky, layer_busy};
            7'h01: cfg_rdata = {7'd0, fm_w, 7'd0, fm_h};
            7'h02: cfg_rdata = {7'd0, ofm_w, 7'd0, ofm_h};
            7'h03: cfg_rdata = {15'd0, kernel_1x1, 6'd0, conv_pad, 6'd0, conv_stride};
            7'h04: cfg_rdata = {18'd0, k_total};
            7'h05: cfg_rdata = {21'd0, cout_total};
            7'h06: cfg_rdata = {16'd0, num_pixels};
            7'h07: cfg_rdata = {30'd0, activation_mode};
            7'h08: cfg_rdata = {7'd0, tile_ofm_h, 7'd0, tile_oy_base};
            7'h09: cfg_rdata = {8'd0, tile_pixel_base};
            7'h0a: cfg_rdata = dbg_expected_bytes;
            7'h0b: cfg_rdata = dbg_core_wr_count;
            7'h0c: cfg_rdata = dbg_axis_wr_count;
            7'h0d: cfg_rdata = dbg_tlast_count;
            7'h0e: cfg_rdata = dbg_last_tlast_index;
            7'h0f: cfg_rdata = {24'd0, input_zero_point};
            7'h10: cfg_rdata = {28'd0, pool_stride, 1'b0, pool_enable};
            7'h11: cfg_rdata = expected_bytes;
            7'h12: cfg_rdata = perf_busy_cycles;
            7'h13: cfg_rdata = perf_wait_any_cycles;
            7'h14: cfg_rdata = perf_wait_bias_cycles;
            7'h15: cfg_rdata = perf_wait_weight_cycles;
            7'h16: cfg_rdata = perf_wait_ifm_cycles;
            7'h17: cfg_rdata = perf_wait_ofm_cycles;
            7'h18: cfg_rdata = perf_compute_cycles;
            7'h19: cfg_rdata = {24'd0, during_compute_prefetch_enable,
                                column_psum_enable,
                                continuous_psum_enable,
                                psum_stream_overlap_enable,
                                pass_prefetch_enable, early_drain_enable,
                                stream_raw_hwc_mode, stream_batch_mode};
            7'h1a: cfg_rdata = stream_bias_packets;
            7'h1b: cfg_rdata = stream_weight_packets;
            7'h1c: cfg_rdata = stream_ifm_packets;
            7'h1d: cfg_rdata = stream_bias_completed;
            7'h1e: cfg_rdata = stream_weight_completed;
            7'h1f: cfg_rdata = stream_ifm_completed;
            7'h24: cfg_rdata = vector_completed_packets;
            7'h25: cfg_rdata = vector_completed_pixels;
            7'h26: cfg_rdata = vector_accepted_beats;
            7'h27: cfg_rdata = vector_fifo_stall_cycles;
            7'h28: cfg_rdata = perf_stage_bias_cycles;
            7'h29: cfg_rdata = perf_stage_weight_cycles;
            7'h2a: cfg_rdata = perf_stage_feeder_cycles;
            7'h2b: cfg_rdata = perf_stage_compute_cycles;
            7'h2c: cfg_rdata = perf_stage_drain_cycles;
            7'h2d: cfg_rdata = perf_stage_ofm_post_cycles;
            7'h2e: cfg_rdata = perf_feed_fill_wait_cycles;
            7'h2f: cfg_rdata = perf_feed_push_cycles;
            7'h30: cfg_rdata = perf_feed_fifo_stall_cycles;
            7'h31: cfg_rdata = perf_feed_win_not_ready_cycles;
            7'h32: cfg_rdata = perf_comp_wload_cycles;
            7'h33: cfg_rdata = perf_comp_active_cycles;
            7'h34: cfg_rdata = perf_compute_cycles;
            7'h35: cfg_rdata = perf_comp_ifm_stall_cycles;
            7'h36: cfg_rdata = perf_comp_tail_cycles;
            7'h37: cfg_rdata = 32'd2;
            7'h38: cfg_rdata = {raw_hwc_compute_start_level, perf_tail_cycles_configured[15:0]};
            7'h39: cfg_rdata = perf_comp_tail_cycles;
            7'h3a: cfg_rdata = perf_drain_fifo_empty_wait_cycles;
            7'h3b: cfg_rdata = {31'd0, perf_drain_fifo_empty_sticky_latched};
            7'h3c: cfg_rdata = raw_hwc_load_active_cycles;
            7'h3d: cfg_rdata = raw_hwc_load_unpack_cycles;
            7'h3e: cfg_rdata = raw_hwc_replay_active_cycles;
            7'h3f: cfg_rdata = raw_hwc_replay_wait_ready_cycles;
            7'h40: cfg_rdata = perf_drain_read_fire_cycles;
            7'h41: cfg_rdata = perf_drain_packet_fire_cycles;
            7'h42: cfg_rdata = perf_drain_ready_stall_cycles;
            7'h43: cfg_rdata = perf_drain_internal_full_cycles;
            7'h44: cfg_rdata = 32'd1;
            7'h45: cfg_rdata = perf_prefetch_start_cycles;
            7'h46: cfg_rdata = perf_prefetch_weight_done_cycles;
            7'h47: cfg_rdata = perf_prefetch_feed_done_cycles;
            7'h48: cfg_rdata = perf_prefetch_hit_cycles;
            7'h49: cfg_rdata = perf_prefetch_miss_cycles;
            7'h4a: cfg_rdata = perf_prefetch_stall_cycles;
            7'h4b: cfg_rdata = 32'd1;
            7'h4c: cfg_rdata = perf_psumovl_start_cycles;
            7'h4d: cfg_rdata = perf_psumovl_hit_cycles;
            7'h4e: cfg_rdata = perf_psumovl_wait_psum_cycles;
            7'h4f: cfg_rdata = perf_psumovl_underflow_cycles;
            7'h50: cfg_rdata = 32'd1;
            7'h51: cfg_rdata = perf_collect_packet_fire_cycles;
            7'h52: cfg_rdata = perf_collect_partial_write_cycles;
            7'h53: cfg_rdata = perf_collect_final_write_cycles;
            7'h54: cfg_rdata = perf_collect_context_push_cycles;
            7'h55: cfg_rdata = perf_collect_context_pop_cycles;
            7'h56: cfg_rdata = perf_collect_context_full_stall_cycles;
            7'h57: cfg_rdata = perf_collect_column_empty_wait_cycles;
            7'h58: cfg_rdata = 32'd1;
            7'h59: cfg_rdata = {pass_trace_enable, 7'd0,
                                pass_trace_cout_block, pass_trace_k_pass};
            7'h5a: cfg_rdata = perf_pass_count;
            7'h5b: cfg_rdata = perf_pass_start_to_first_fire;
            7'h5c: cfg_rdata = perf_pass_first_to_last_fire;
            7'h5d: cfg_rdata = perf_pass_last_fire_to_done;
            7'h5e: cfg_rdata = perf_pass_collect_first_wait;
            7'h5f: cfg_rdata = perf_pass_collect_column_empty;
            7'h60: cfg_rdata = perf_pass_replay_active_during_compute;
            7'h61: cfg_rdata = perf_pass_compute_idle_in_stage;
            7'h62: cfg_rdata = pass_trace_weight_done;
            7'h63: cfg_rdata = pass_trace_feed_start;
            7'h64: cfg_rdata = pass_trace_feed_ready;
            7'h65: cfg_rdata = pass_trace_feed_done;
            7'h66: cfg_rdata = pass_trace_compute_start;
            7'h67: cfg_rdata = pass_trace_first_fire;
            7'h68: cfg_rdata = pass_trace_last_fire;
            7'h69: cfg_rdata = pass_trace_compute_done;
            7'h6a: cfg_rdata = pass_trace_collect_first;
            7'h6b: cfg_rdata = pass_trace_collect_last;
            7'h6c: cfg_rdata = pass_trace_pass_done;
            7'h6d: cfg_rdata = {pass_trace_valid, 31'd1};
            7'h6e: cfg_rdata = {col_trace_valid, 26'd0,
                                col_trace_selected_col};
            7'h6f: cfg_rdata = col_trace_first_wr;
            7'h70: cfg_rdata = col_trace_last_wr;
            7'h71: cfg_rdata = col_trace_wr_count;
            7'h72: cfg_rdata = col_trace_empty_wait;
            7'h73: cfg_rdata = col_trace_missing_mask_or;
            7'h74: cfg_rdata = col_trace_missing_mask_first;
            7'h75: cfg_rdata = col_trace_missing_mask_last;
            7'h76: cfg_rdata = 32'd1;
            default: cfg_rdata = 32'd0;
        endcase
    end
endmodule

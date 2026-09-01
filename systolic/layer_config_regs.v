`timescale 1ns / 1ps
// Simple local configuration register bank for one convolution layer.
//
// Register map:
//   0x00 CTRL/STATUS: write bit0=start pulse, bit1=clear status,
//                     bit2=request four-cycle datapath reset;
//                     read bit0=busy, bit1=done_sticky, bit2=config_error,
//                     bit3=datapath reset active
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
//                             only when ENABLE_COLUMN_PSUM is compiled in;
//                             otherwise writes are rejected and read back as 0
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
//   0x77 ABI_VERSION: fixed accelerator ABI version (2)
//   0x78 CAPABILITY: [7:0]=ROWS, [15:8]=COLS,
//                    [23:16]=COUT_TILE, [31:24]=feature flags
//   0x79 PERF_UNCLASSIFIED: busy cycles not owned by any scheduler stage
//   0x7a LAYER_DESC: bit31=layer_last, [8:0]=tile_h_max
//   0x7b IFM_TOTAL_BYTES: full layer input payload bytes
//   0x7c OFM_TOTAL_BYTES: full layer output payload bytes
//   0x7d PACKED_OFM_BYTES: packed HWC AXIS payload-byte handshakes
//   0x7e PACKED_OFM_STALL: packed HWC AXIS TVALID&&!TREADY cycles
//                         PACKED_OFM_VALID cycles are DBG_AXIS_WR + this value
//   0x7f DATAPATH_ERRORS: sticky error bitmap from epoch/PSUM/context datapaths;
//                         bit31 also reports packed-HWC OFM protocol errors
//   0x80 CONTEXT_VERSION: fixed tagged-context telemetry map version
//   0x81 CONTEXT_ALLOC: allocated context count
//   0x82 CONTEXT_INPUT_ISSUED: contexts whose final input vector fired
//   0x83 CONTEXT_ARRAY_RETIRED: contexts whose final array result retired
//   0x84 CONTEXT_COLLECTOR_DONE: contexts fully consumed by the collector
//   0x85 CONTEXT_GAP: cycles between otherwise runnable contexts
//   0x86 CONTEXT_IFM_OWNER_STALL: IFM bank ownership stall cycles
//   0x87 CONTEXT_WEIGHT_OWNER_STALL: weight bank ownership stall cycles
//   0x88 CONTEXT_PSUM_CREDIT_STALL: committed/output credit stall cycles
//   0x89 CONTEXT_EPOCH_MISMATCH: epoch mismatch event count
//   0x8a CONTEXT_MISMATCH: descriptor/tag mismatch event count
//   0x8b CONTEXT_IFM_UNDERFLOW: IFM vector underflow event count
//   0x8c CONTEXT_PSUM_UNDERFLOW: partial-PSUM underflow event count
//   0x8d CONTEXT_FIFO_DROP: rejected/dropped FIFO entry count
//   0x8e CONTEXT_BANK_OVERWRITE: live bank overwrite event count
//   0x8f CONTEXT_FULL_STALL: cycles waiting for a free context slot
//   0x90 DATAPATH_RESET_COUNT: accepted software datapath reset requests
//   0x91 COMPUTE_PIPE_VERSION: fixed compute-pipeline telemetry map version (1)
//   0x92 COMPUTE_GAP: compute-stage cycles without compute_fire
//   0x93 PRELOAD_COMMIT: completed inactive-bank weight preloads
//   0x94 PRELOAD_HIT: context starts that hit a prepared weight bank
//   0x95 PRELOAD_MISS: context requests blocked by an unprepared weight bank
//   0x96 HANDOFF_ELIGIBLE: contexts eligible for a next-cycle handoff
//   0x97 HANDOFF_NEXT_HIT: eligible handoffs that fire on the next cycle
//   0x98 HANDOFF_EXTRA_GAP: additional cycles after an eligible handoff
//   0x99 WAIT_BANK_RETIRE: gap cycles waiting for array-bank retirement
//   0x9a WAIT_WEIGHT: gap cycles waiting for weight ownership/preload
//   0x9b WAIT_IFM: gap cycles waiting for an IFM context
//   0x9c WAIT_PSUM: gap cycles waiting for committed partial-PSUM credit
//   0x9d WAIT_COLLECTOR_OUTPUT: gap cycles waiting for collector/output credit
//   0x9e WAIT_CONTROL: gap cycles waiting for scheduler/controller admission
//   0x9f COMPUTE_PIPE_PROTOCOL: telemetry protocol error event count
// AXI-Lite byte offsets for 0x91..0x9f are 0x244..0x27c.
//   0xa0 CLOCK_HZ: build-time accelerator clock frequency in hertz
// AXI-Lite byte offset for 0xa0 is 0x280.
module layer_config_regs #(
    parameter integer CLOCK_HZ = 100000000,
    parameter IFM_FIFO_DEPTH = 1024,
    parameter [15:0] RAW_HWC_COMPUTE_START_LEVEL = 16'd0,
    // Release builds omit the costly per-column PSUM datapath.  Experimental
    // builds must opt in explicitly and retain the existing register ABI.
    parameter ENABLE_COLUMN_PSUM = 0,
    parameter ROWS = 32,
    parameter COLS = 32,
    parameter COUT_TILE = COLS*2,
    parameter FM_W_MAX = 416,
    parameter FM_H_MAX = 416,
    parameter PSUM_BUF_DEPTH = 1024,
    parameter MATERIALIZED_CACHE_DEPTH = 32768,
    parameter integer LAYER_LONG_LINE_BANK_DEPTH = 2048,
    parameter PACKED_OFM_BUFFER_DEPTH = 4096,
    parameter ENABLE_PACKED_HWC_OFM = 0,
    parameter ENABLE_LAYER_TILE_SEQUENCER = 0,
    parameter ENABLE_LAYER_LONG_HWC_IFM = 0,
    parameter ENABLE_TAGGED_CONTEXT = 0,
    parameter ENABLE_DETAILED_TRACE = 1,
    parameter [7:0] ABI_FEATURE_FLAGS = 8'd0
) (
    input  clk,
    input  rst,

    input         cfg_wr_en,
    input  [7:0]  cfg_addr,
    input  [31:0] cfg_wdata,
    input         cfg_rd_en,
    output reg [31:0] cfg_rdata,

    input  layer_busy,
    input  layer_done,
    input  external_config_error,
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
    input  [31:0] packed_ofm_axis_byte_count,
    input  [31:0] packed_ofm_axis_stall_cycles,
    input         packed_ofm_protocol_error,
    input  [31:0] datapath_error_status,
    input  [31:0] context_alloc_count,
    input  [31:0] context_input_issued_count,
    input  [31:0] context_array_retired_count,
    input  [31:0] context_collector_done_count,
    input  [31:0] context_gap_cycles,
    input  [31:0] context_ifm_ownership_stall_cycles,
    input  [31:0] context_weight_ownership_stall_cycles,
    input  [31:0] context_psum_credit_stall_cycles,
    input  [31:0] context_epoch_mismatch_count,
    input  [31:0] context_mismatch_count,
    input  [31:0] context_ifm_underflow_count,
    input  [31:0] context_psum_underflow_count,
    input  [31:0] context_fifo_drop_count,
    input  [31:0] context_bank_overwrite_count,
    input  [31:0] context_full_stall_cycles,
    input  [31:0] compute_pipe_compute_gap_count,
    input  [31:0] compute_pipe_preload_commit_count,
    input  [31:0] compute_pipe_preload_hit_count,
    input  [31:0] compute_pipe_preload_miss_count,
    input  [31:0] compute_pipe_eligible_handoff_count,
    input  [31:0] compute_pipe_next_cycle_hit_count,
    input  [31:0] compute_pipe_extra_gap_count,
    input  [31:0] compute_pipe_wait_bank_retire_count,
    input  [31:0] compute_pipe_wait_weight_count,
    input  [31:0] compute_pipe_wait_ifm_count,
    input  [31:0] compute_pipe_wait_psum_count,
    input  [31:0] compute_pipe_wait_collector_output_count,
    input  [31:0] compute_pipe_wait_control_count,
    input  [31:0] compute_pipe_protocol_error_count,
    output reg start_pulse,
    output wire datapath_reset_active,

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
    output reg        configured_layer_last,
    output wire [8:0] configured_tile_h_max,
    output wire [31:0] configured_ifm_total_bytes,
    output wire [31:0] configured_ofm_total_bytes,
    output reg [13:0] validated_long_cin,
    output reg [15:0] validated_long_pass_count,
    output reg [15:0] validated_long_final_pass,
    output reg [ROWS-1:0] validated_long_final_lane_mask,
    output reg [31:0] validated_long_layer_pixels,
    output reg [31:0] validated_long_tile_pixels,
    output reg [31:0] validated_long_tile_output_pixels,
    output reg [15:0] validated_long_cout_blocks,
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
    reg [31:0] perf_unclassified_cycles;
    reg [2:0]  datapath_reset_cycles_remaining;
    reg [31:0] datapath_reset_count;
    reg [8:0]  tile_h_max;
    reg [31:0] ifm_total_bytes;
    reg [31:0] ofm_total_bytes;
    assign configured_tile_h_max = tile_h_max;
    assign configured_ifm_total_bytes = ifm_total_bytes;
    assign configured_ofm_total_bytes = ofm_total_bytes;
    // ABI feature bit 3 is authoritative: a cache epoch alone is not a tagged
    // mesh context.  It can only be advertised by the explicit build switch.
    localparam [7:0] ABI_FEATURE_FLAGS_VISIBLE = {
        ABI_FEATURE_FLAGS[7:4],
        (ENABLE_TAGGED_CONTEXT != 0),
        ABI_FEATURE_FLAGS[2:0]
    };
    // Layer-long validation includes two levels of geometry/capacity products
    // (pixels followed by bytes/entries).  Keep the transaction explicit:
    // descriptor capture -> geometry math -> capacity math -> atomic commit.
    // Descriptor writes remain locked until the committed result is consumed,
    // and no multiplier feeds either the wide reject reduction or start_pulse.
    reg start_validate_precheck_pending;
    reg start_validate_quotient_pending;
    reg start_validate_product_pending;
    reg start_validate_commit_pending;
    reg start_validate_pending;
    reg start_validate_invalid;
    reg start_validate_basic_invalid_q;
    reg start_validate_geometry_invalid_q;
    reg start_validate_channel_invalid_q;
    reg start_validate_line_invalid_q;
    reg start_validate_tile_invalid_q;
    reg start_validate_materialized_invalid_q;
    reg start_validate_stream_invalid_q;
    reg start_validate_ifm_bytes_invalid_q;
    reg start_validate_ofm_bytes_invalid_q;
    reg start_validate_pool_invalid_q;
    reg start_validate_packed_invalid_q;

    // Transactional descriptor snapshot.  These data registers deliberately
    // have no reset requirement: their corresponding pending bit is the only
    // validity state, reducing reset fanout and preventing partial updates.
    reg [8:0]  start_validate_fm_h_q;
    reg [8:0]  start_validate_fm_w_q;
    reg [8:0]  start_validate_ofm_h_q;
    reg [8:0]  start_validate_ofm_w_q;
    reg [1:0]  start_validate_conv_stride_q;
    reg [1:0]  start_validate_conv_pad_q;
    reg        start_validate_kernel_1x1_q;
    reg [13:0] start_validate_k_total_q;
    reg [10:0] start_validate_cout_total_q;
    reg [15:0] start_validate_num_pixels_q;
    reg        start_validate_pool_enable_q;
    reg [1:0]  start_validate_pool_stride_q;
    reg        start_validate_stream_batch_mode_q;
    reg        start_validate_stream_raw_hwc_mode_q;
    reg [31:0] start_validate_stream_bias_packets_q;
    reg [31:0] start_validate_stream_weight_packets_q;
    reg [31:0] start_validate_stream_ifm_packets_q;
    reg [8:0]  start_validate_tile_h_max_q;
    reg [31:0] start_validate_ifm_total_bytes_q;
    reg [31:0] start_validate_ofm_total_bytes_q;
    reg [31:0] start_validate_expected_bytes_q;

    // First registered math level.
    reg [13:0] start_math_cin_q;
    reg [15:0] start_math_pass_count_q;
    reg [15:0] start_math_cin_word_groups_q;
    reg [15:0] start_math_x_groups_q;
    reg [31:0] start_math_ifm_pixels_q;
    reg [31:0] start_math_tile_pixels_q;
    reg [31:0] start_math_layer_pixels_q;
    reg [31:0] start_math_output_pixels_q;
    reg [31:0] start_math_tile_output_pixels_q;
    reg [15:0] start_math_cout_blocks_q;
    reg [25:0] start_math_k_recip_product_q;

    // Second registered math level.  Capacity comparisons consume only these
    // registers, never a pixels->bytes/entries multiplier cascade.
    reg [31:0] start_math_line_words_q;
    reg [47:0] start_math_ifm_bytes_q;
    reg [47:0] start_math_tile_entries_q;
    reg [47:0] start_math_ofm_bytes_q;
    reg [47:0] start_math_tile_packed_entries_q;
    reg [15:0] start_math_final_pass_q;
    reg [ROWS-1:0] start_math_final_lane_mask_q;

    wire cfg_idle = !layer_busy && !start_validate_precheck_pending &&
                    !start_validate_quotient_pending &&
                    !start_validate_product_pending &&
                    !start_validate_commit_pending &&
                    !start_validate_pending && !start_pulse &&
                    !datapath_reset_active;
    wire datapath_reset_request = cfg_wr_en && (cfg_addr == 8'h00) &&
                                  cfg_wdata[2];
    wire datapath_reset_accept = datapath_reset_request &&
                                 !datapath_reset_active;
    assign datapath_reset_active =
        (datapath_reset_cycles_remaining != 3'd0);
    wire perf_wait_any = perf_wait_bias || perf_wait_weight ||
                         perf_wait_ifm || perf_wait_ofm;
    wire perf_stage_classified = perf_stage_bias || perf_stage_weight ||
                                 perf_stage_feeder || perf_stage_compute ||
                                 perf_stage_drain || perf_stage_ofm_post;
    wire invalid_1x1_config =
        kernel_1x1 &&
        (!stream_batch_mode || conv_stride != 2'd1 || conv_pad != 2'd0 ||
         num_pixels > IFM_FIFO_DEPTH);

    // Reject an invalid v2 layer descriptor before start_pulse reaches any
    // stateful datapath.  In particular, a materializer/cache configuration
    // error after cfg_start would leave a bank owned until global reset.  All
    // divisors below are elaboration constants; output geometry for runtime
    // stride 1/2 is expressed with an add or shift, so this guard does not
    // infer a general divider.
    localparam integer LONG_MAX_CHANNELS = 1024;
    localparam integer LONG_MAX_PASSES = 512;
    // Packed row-store words contain two adjacent x positions and four
    // channel residues: addr=(channel>>2)*ceil(fm_w/2)+(x>>1).
    localparam integer LONG_CHANNEL_BANKS = 4;
    localparam integer LONG_X_PACK = 2;

    wire [10:0] start_math_kernel_extent =
        start_validate_kernel_1x1_q ? 11'd1 : 11'd3;
    wire [10:0] start_math_padded_h = {2'd0, start_validate_fm_h_q} +
        ({9'd0, start_validate_conv_pad_q} << 1);
    wire [10:0] start_math_padded_w = {2'd0, start_validate_fm_w_q} +
        ({9'd0, start_validate_conv_pad_q} << 1);
    wire start_math_extent_underflow =
        (start_math_padded_h < start_math_kernel_extent) ||
        (start_math_padded_w < start_math_kernel_extent);
    wire [10:0] start_math_extent_h =
        start_math_padded_h - start_math_kernel_extent;
    wire [10:0] start_math_extent_w =
        start_math_padded_w - start_math_kernel_extent;
    wire [10:0] start_math_expected_ofm_h =
        (start_validate_conv_stride_q == 2'd1) ?
        (start_math_extent_h + 1'b1) :
        ((start_math_extent_h >> 1) + 1'b1);
    wire [10:0] start_math_expected_ofm_w =
        (start_validate_conv_stride_q == 2'd1) ?
        (start_math_extent_w + 1'b1) :
        ((start_math_extent_w >> 1) + 1'b1);
    // For every 14-bit unsigned n, floor(n/9)=(n*3641)>>15 and
    // floor(n/18)=(n*3641)>>16.  Register the reciprocal product before
    // quotient/remainder checks so no synthesized divider remains on a
    // configuration path.
    wire [25:0] start_math_k_recip_product =
        {12'd0, start_validate_k_total_q} * 26'd3641;
    wire [13:0] start_quotient_div9 =
        {3'd0, start_math_k_recip_product_q[25:15]};
    wire [15:0] start_quotient_div18_floor =
        {6'd0, start_math_k_recip_product_q[25:16]};
    wire [15:0] start_quotient_div18_base =
        (start_quotient_div18_floor << 4) +
        (start_quotient_div18_floor << 1);
    wire [15:0] start_quotient_pass_count =
        start_quotient_div18_floor +
        ({2'd0, start_validate_k_total_q} !=
         start_quotient_div18_base);
    wire [13:0] start_quotient_cin =
        start_validate_kernel_1x1_q ? start_validate_k_total_q :
        start_quotient_div9;
    wire [15:0] start_quotient_cin_times9 =
        ({2'd0, start_quotient_div9} << 3) +
        {2'd0, start_quotient_div9};
    wire [15:0] start_quotient_cin_word_groups =
        (start_quotient_cin + LONG_CHANNEL_BANKS - 1) /
        LONG_CHANNEL_BANKS;
    wire [15:0] start_quotient_x_groups =
        (start_validate_fm_w_q + LONG_X_PACK - 1) / LONG_X_PACK;
    wire [31:0] start_math_ifm_pixels =
        {23'd0, start_validate_fm_h_q} *
        {23'd0, start_validate_fm_w_q};
    wire [31:0] start_math_tile_pixels =
        {23'd0, start_validate_tile_h_max_q} *
        {23'd0, start_validate_ofm_w_q};
    wire [31:0] start_math_layer_pixels =
        {23'd0, start_validate_ofm_h_q} *
        {23'd0, start_validate_ofm_w_q};
    wire [15:0] start_math_output_h = start_validate_pool_enable_q ?
        {7'd0, start_validate_ofm_h_q[8:1]} :
        {7'd0, start_validate_ofm_h_q};
    wire [15:0] start_math_output_w = start_validate_pool_enable_q ?
        {7'd0, start_validate_ofm_w_q[8:1]} :
        {7'd0, start_validate_ofm_w_q};
    wire [31:0] start_math_output_pixels =
        {16'd0, start_math_output_h} * {16'd0, start_math_output_w};
    wire [31:0] start_math_tile_output_pixels =
        start_validate_pool_enable_q ?
        ({24'd0, start_validate_tile_h_max_q[8:1]} *
         {24'd0, start_validate_ofm_w_q[8:1]}) :
        start_math_tile_pixels;
    wire [15:0] start_math_cout_blocks =
        (start_validate_cout_total_q + COUT_TILE - 1) / COUT_TILE;

    wire start_math_invalid_1x1 = start_validate_kernel_1x1_q &&
        (!start_validate_stream_batch_mode_q ||
         (start_validate_conv_stride_q != 2'd1) ||
         (start_validate_conv_pad_q != 2'd0) ||
         (start_validate_num_pixels_q > IFM_FIFO_DEPTH));
    wire start_math_invalid_basic =
        (ROWS != 18) || !start_validate_stream_batch_mode_q ||
        (start_validate_fm_h_q == 0) ||
        (start_validate_fm_w_q == 0) ||
        (start_validate_fm_h_q > FM_H_MAX) ||
        (start_validate_fm_w_q > FM_W_MAX) ||
        (start_validate_ofm_h_q == 0) ||
        (start_validate_ofm_w_q == 0) ||
        (start_validate_cout_total_q == 0) ||
        (start_validate_cout_total_q > LONG_MAX_CHANNELS) ||
        (start_validate_k_total_q == 0) ||
        (start_validate_tile_h_max_q == 0) ||
        (start_validate_tile_h_max_q > start_validate_ofm_h_q) ||
        ((ENABLE_LAYER_TILE_SEQUENCER == 0) &&
         (start_validate_tile_h_max_q != start_validate_ofm_h_q)) ||
        ((start_validate_conv_stride_q != 2'd1) &&
         (start_validate_conv_stride_q != 2'd2));
    wire start_math_invalid_geometry = start_math_extent_underflow ||
        (start_validate_ofm_h_q != start_math_expected_ofm_h[8:0]) ||
        (start_validate_ofm_w_q != start_math_expected_ofm_w[8:0]);
    wire start_quotient_invalid_channel =
        (!start_validate_kernel_1x1_q &&
         ({2'd0, start_validate_k_total_q} !=
          start_quotient_cin_times9)) ||
        (start_quotient_cin < 3) ||
        (start_quotient_cin > LONG_MAX_CHANNELS) ||
        (start_quotient_pass_count == 0) ||
        (start_quotient_pass_count > LONG_MAX_PASSES);
    wire start_math_invalid_stream =
        (start_validate_stream_ifm_packets_q != 32'd1) ||
        (start_validate_stream_bias_packets_q == 32'd0) ||
        (start_validate_stream_weight_packets_q == 32'd0);
    wire start_math_invalid_pool = start_validate_pool_enable_q &&
        ((start_validate_pool_stride_q != 2'd2) ||
         start_validate_ofm_h_q[0] || start_validate_ofm_w_q[0] ||
         start_validate_tile_h_max_q[0]);

    wire [31:0] start_capacity_line_words =
        start_math_cin_word_groups_q * start_math_x_groups_q;
    wire [47:0] start_capacity_ifm_bytes =
        {16'd0, start_math_ifm_pixels_q} * {34'd0, start_math_cin_q};
    wire [47:0] start_capacity_tile_entries =
        {16'd0, start_math_tile_pixels_q} *
        {32'd0, start_math_pass_count_q};
    wire [47:0] start_capacity_ofm_bytes =
        {16'd0, start_math_output_pixels_q} *
        {37'd0, start_validate_cout_total_q};
    wire [47:0] start_capacity_tile_packed_entries =
        {16'd0, start_math_tile_output_pixels_q} *
        {32'd0, start_math_cout_blocks_q};
    wire [15:0] start_capacity_final_pass =
        (start_math_pass_count_q == 0) ? 16'd0 :
        start_math_pass_count_q - 1'b1;
    wire [15:0] start_capacity_final_pass_base = (ROWS == 18) ?
        ((start_capacity_final_pass << 4) +
         (start_capacity_final_pass << 1)) :
        (start_capacity_final_pass * ROWS);
    wire [15:0] start_capacity_final_lane_count =
        (start_math_pass_count_q == 0) ? 16'd0 :
        ({2'd0, start_validate_k_total_q} -
         start_capacity_final_pass_base);
    reg [ROWS-1:0] start_capacity_final_lane_mask;
    integer start_lane_i;
    always @* begin
        start_capacity_final_lane_mask = {ROWS{1'b0}};
        for (start_lane_i = 0; start_lane_i < ROWS;
             start_lane_i = start_lane_i + 1)
            if (start_lane_i < start_capacity_final_lane_count)
                start_capacity_final_lane_mask[start_lane_i] = 1'b1;
    end

    wire start_commit_invalid_line =
        (start_math_line_words_q > LAYER_LONG_LINE_BANK_DEPTH);
    wire start_commit_invalid_tile =
        (start_math_tile_pixels_q == 0) ||
        (start_math_tile_pixels_q > PSUM_BUF_DEPTH) ||
        (start_validate_num_pixels_q != start_math_tile_pixels_q[15:0]);
    wire start_commit_invalid_materialized =
        (start_math_tile_entries_q > MATERIALIZED_CACHE_DEPTH);
    wire start_commit_invalid_ifm_bytes =
        (start_validate_ifm_total_bytes_q !=
         start_math_ifm_bytes_q[31:0]);
    wire start_commit_invalid_ofm_bytes =
        (start_validate_ofm_total_bytes_q !=
         start_math_ofm_bytes_q[31:0]) ||
        (start_validate_expected_bytes_q !=
         start_math_ofm_bytes_q[31:0]);
    wire start_commit_invalid_packed =
        ((ENABLE_PACKED_HWC_OFM != 0) ||
         (ENABLE_LAYER_TILE_SEQUENCER != 0)) &&
        (start_math_tile_packed_entries_q > PACKED_OFM_BUFFER_DEPTH);
    wire invalid_start_config = invalid_1x1_config ||
                                ((ENABLE_LAYER_LONG_HWC_IFM != 0) &&
                                 !stream_raw_hwc_mode);
    wire start_request = cfg_wr_en && (cfg_addr == 8'h00) &&
                         cfg_wdata[0] && !cfg_wdata[2] && cfg_idle;
    // Preserve the legacy zero-latency start when the layer-long path is not
    // elaborated.  Formal layer-long builds fan out only the captured bit.
    wire validated_start_raw = (ENABLE_LAYER_LONG_HWC_IFM != 0) ?
        (start_validate_pending && !start_validate_invalid) :
        (start_request && !invalid_start_config);
    wire rejected_start_raw = (ENABLE_LAYER_LONG_HWC_IFM != 0) ?
        (start_validate_pending && start_validate_invalid) :
        (start_request && invalid_start_config);
    // A reset request always wins, including over a descriptor validation
    // result that happens to mature in the same cycle.
    wire validated_start = validated_start_raw &&
                           !datapath_reset_request &&
                           !datapath_reset_active;
    wire rejected_start = rejected_start_raw &&
                          !datapath_reset_request &&
                          !datapath_reset_active;

    // Keep the control plane alive while resetting only the dynamic
    // datapath.  Loading four here produces four complete active clock
    // intervals after the accepting AXI-Lite write.  Requests while active
    // are ignored, so the cumulative count represents accepted commands.
    always @(posedge clk) begin
        if (rst) begin
            datapath_reset_cycles_remaining <= 3'd0;
            datapath_reset_count <= 32'd0;
        end else begin
            if (datapath_reset_accept) begin
                datapath_reset_cycles_remaining <= 3'd4;
                datapath_reset_count <= datapath_reset_count + 1'b1;
            end else if (datapath_reset_active) begin
                datapath_reset_cycles_remaining <=
                    datapath_reset_cycles_remaining - 1'b1;
            end
        end
    end

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
            configured_layer_last <= 1'b0;
            tile_h_max <= 9'd0;
            ifm_total_bytes <= 32'd0;
            ofm_total_bytes <= 32'd0;
            validated_long_cin <= 14'd0;
            validated_long_pass_count <= 16'd0;
            validated_long_final_pass <= 16'd0;
            validated_long_final_lane_mask <= {ROWS{1'b0}};
            validated_long_layer_pixels <= 32'd0;
            validated_long_tile_pixels <= 32'd0;
            validated_long_tile_output_pixels <= 32'd0;
            validated_long_cout_blocks <= 16'd0;
            config_error <= 1'b0;
            start_validate_precheck_pending <= 1'b0;
            start_validate_quotient_pending <= 1'b0;
            start_validate_product_pending <= 1'b0;
            start_validate_commit_pending <= 1'b0;
            start_validate_pending <= 1'b0;
            start_validate_invalid <= 1'b0;
            start_validate_basic_invalid_q <= 1'b0;
            start_validate_geometry_invalid_q <= 1'b0;
            start_validate_channel_invalid_q <= 1'b0;
            start_validate_line_invalid_q <= 1'b0;
            start_validate_tile_invalid_q <= 1'b0;
            start_validate_materialized_invalid_q <= 1'b0;
            start_validate_stream_invalid_q <= 1'b0;
            start_validate_ifm_bytes_invalid_q <= 1'b0;
            start_validate_ofm_bytes_invalid_q <= 1'b0;
            start_validate_pool_invalid_q <= 1'b0;
            start_validate_packed_invalid_q <= 1'b0;
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
            perf_unclassified_cycles <= 32'd0;
        end else begin
            start_pulse <= 1'b0;
            if ((ENABLE_LAYER_LONG_HWC_IFM != 0) &&
                start_validate_pending)
                start_validate_pending <= 1'b0;
            if ((ENABLE_LAYER_LONG_HWC_IFM != 0) &&
                start_validate_precheck_pending) begin
                start_validate_precheck_pending <= 1'b0;
                start_validate_quotient_pending <= 1'b1;
                start_validate_basic_invalid_q <=
                    start_math_invalid_1x1 ||
                    !start_validate_stream_raw_hwc_mode_q ||
                    start_math_invalid_basic;
                start_validate_geometry_invalid_q <=
                    start_math_invalid_geometry;
                start_validate_stream_invalid_q <=
                    start_math_invalid_stream;
                start_validate_pool_invalid_q <=
                    start_math_invalid_pool;
                start_math_k_recip_product_q <=
                    start_math_k_recip_product;
                start_math_ifm_pixels_q <= start_math_ifm_pixels;
                start_math_tile_pixels_q <= start_math_tile_pixels;
                start_math_layer_pixels_q <= start_math_layer_pixels;
                start_math_output_pixels_q <= start_math_output_pixels;
                start_math_tile_output_pixels_q <=
                    start_math_tile_output_pixels;
                start_math_cout_blocks_q <= start_math_cout_blocks;
            end
            if ((ENABLE_LAYER_LONG_HWC_IFM != 0) &&
                start_validate_quotient_pending) begin
                start_validate_quotient_pending <= 1'b0;
                start_validate_product_pending <= 1'b1;
                start_validate_channel_invalid_q <=
                    start_quotient_invalid_channel;
                start_math_cin_q <= start_quotient_cin;
                start_math_pass_count_q <= start_quotient_pass_count;
                start_math_cin_word_groups_q <=
                    start_quotient_cin_word_groups;
                start_math_x_groups_q <= start_quotient_x_groups;
            end
            if ((ENABLE_LAYER_LONG_HWC_IFM != 0) &&
                start_validate_product_pending) begin
                start_validate_product_pending <= 1'b0;
                start_validate_commit_pending <= 1'b1;
                start_math_line_words_q <= start_capacity_line_words;
                start_math_ifm_bytes_q <= start_capacity_ifm_bytes;
                start_math_tile_entries_q <= start_capacity_tile_entries;
                start_math_ofm_bytes_q <= start_capacity_ofm_bytes;
                start_math_tile_packed_entries_q <=
                    start_capacity_tile_packed_entries;
                start_math_final_pass_q <= start_capacity_final_pass;
                start_math_final_lane_mask_q <=
                    start_capacity_final_lane_mask;
            end
            if ((ENABLE_LAYER_LONG_HWC_IFM != 0) &&
                start_validate_commit_pending) begin
                start_validate_commit_pending <= 1'b0;
                start_validate_pending <= 1'b1;
                start_validate_line_invalid_q <=
                    start_commit_invalid_line;
                start_validate_tile_invalid_q <=
                    start_commit_invalid_tile;
                start_validate_materialized_invalid_q <=
                    start_commit_invalid_materialized;
                start_validate_ifm_bytes_invalid_q <=
                    start_commit_invalid_ifm_bytes;
                start_validate_ofm_bytes_invalid_q <=
                    start_commit_invalid_ofm_bytes;
                start_validate_packed_invalid_q <=
                    start_commit_invalid_packed;
                start_validate_invalid <=
                    start_validate_basic_invalid_q ||
                    start_validate_geometry_invalid_q ||
                    start_validate_channel_invalid_q ||
                    start_commit_invalid_line ||
                    start_commit_invalid_tile ||
                    start_commit_invalid_materialized ||
                    start_validate_stream_invalid_q ||
                    start_commit_invalid_ifm_bytes ||
                    start_commit_invalid_ofm_bytes ||
                    start_validate_pool_invalid_q ||
                    start_commit_invalid_packed;
                // All consumer-visible derived fields change together with
                // the committed validation decision.  A rejected descriptor
                // can update this diagnostic snapshot, but cannot emit start.
                validated_long_cin <= start_math_cin_q;
                validated_long_pass_count <= start_math_pass_count_q;
                validated_long_final_pass <= start_math_final_pass_q;
                validated_long_final_lane_mask <=
                    start_math_final_lane_mask_q;
                validated_long_layer_pixels <= start_math_layer_pixels_q;
                validated_long_tile_pixels <= start_math_tile_pixels_q;
                validated_long_tile_output_pixels <=
                    start_math_tile_output_pixels_q;
                validated_long_cout_blocks <= start_math_cout_blocks_q;
            end
            if (layer_done)
                done_sticky <= 1'b1;
            if (external_config_error) begin
                config_error <= 1'b1;
                done_sticky <= 1'b1;
            end

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
                if (!perf_stage_classified)
                    perf_unclassified_cycles <= perf_unclassified_cycles + 1'b1;
            end

            if (cfg_wr_en) begin
                case (cfg_addr)
                    7'h00: begin
                        if (start_request &&
                            (ENABLE_LAYER_LONG_HWC_IFM != 0)) begin
                            done_sticky <= 1'b0;
                            config_error <= 1'b0;
                            // Capture one immutable descriptor transaction.
                            // cfg_idle remains low through the following math
                            // and commit stages, so later AXI writes cannot
                            // mix fields from two descriptors.
                            start_validate_fm_h_q <= fm_h;
                            start_validate_fm_w_q <= fm_w;
                            start_validate_ofm_h_q <= ofm_h;
                            start_validate_ofm_w_q <= ofm_w;
                            start_validate_conv_stride_q <= conv_stride;
                            start_validate_conv_pad_q <= conv_pad;
                            start_validate_kernel_1x1_q <= kernel_1x1;
                            start_validate_k_total_q <= k_total;
                            start_validate_cout_total_q <= cout_total;
                            start_validate_num_pixels_q <= num_pixels;
                            start_validate_pool_enable_q <= pool_enable;
                            start_validate_pool_stride_q <= pool_stride;
                            start_validate_stream_batch_mode_q <=
                                stream_batch_mode;
                            start_validate_stream_raw_hwc_mode_q <=
                                stream_raw_hwc_mode;
                            start_validate_stream_bias_packets_q <=
                                stream_bias_packets;
                            start_validate_stream_weight_packets_q <=
                                stream_weight_packets;
                            start_validate_stream_ifm_packets_q <=
                                stream_ifm_packets;
                            start_validate_tile_h_max_q <= tile_h_max;
                            start_validate_ifm_total_bytes_q <=
                                ifm_total_bytes;
                            start_validate_ofm_total_bytes_q <=
                                ofm_total_bytes;
                            start_validate_expected_bytes_q <= expected_bytes;
                            start_validate_precheck_pending <= 1'b1;
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
                            if (ENABLE_COLUMN_PSUM != 0)
                                column_psum_enable <= cfg_wdata[6];
                            else begin
                                // Sanitize an unsupported request so the layer
                                // always runs through the full-packet PSUM path.
                                column_psum_enable <= 1'b0;
                                if (cfg_wdata[6])
                                    config_error <= 1'b1;
                            end
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
                        if (ENABLE_DETAILED_TRACE != 0) begin
                            pass_trace_enable <= cfg_wdata[31];
                            pass_trace_cout_block <= cfg_wdata[23:16];
                            pass_trace_k_pass <= cfg_wdata[15:0];
                        end else begin
                            pass_trace_enable <= 1'b0;
                            pass_trace_cout_block <= 8'd0;
                            pass_trace_k_pass <= 16'd0;
                        end
                    end
                    7'h6e: if (cfg_idle) begin
                        if (ENABLE_DETAILED_TRACE != 0)
                            col_trace_selected_col <= cfg_wdata[4:0];
                        else
                            col_trace_selected_col <= 5'd0;
                    end
                    7'h7a: if (cfg_idle) begin
                        configured_layer_last <= cfg_wdata[31];
                        tile_h_max <= cfg_wdata[8:0];
                    end
                    7'h7b: if (cfg_idle)
                        ifm_total_bytes <= cfg_wdata;
                    7'h7c: if (cfg_idle)
                        ofm_total_bytes <= cfg_wdata;
                    default: begin end
                endcase
            end

            if (rejected_start) begin
                config_error <= 1'b1;
                done_sticky <= 1'b1;
            end

            if (validated_start) begin
                start_pulse <= 1'b1;
                done_sticky <= 1'b0;
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
                perf_unclassified_cycles <= 32'd0;
            end

            // Dynamic control/status belongs to the resettable datapath,
            // whereas layer geometry, stream descriptors, quantization and
            // capability registers deliberately survive software recovery.
            // Put this override last so reset wins over start, done and error
            // events that arrive on the same edge.
            if (datapath_reset_request || datapath_reset_active) begin
                start_pulse <= 1'b0;
                done_sticky <= 1'b0;
                config_error <= 1'b0;
                start_validate_precheck_pending <= 1'b0;
                start_validate_quotient_pending <= 1'b0;
                start_validate_product_pending <= 1'b0;
                start_validate_commit_pending <= 1'b0;
                start_validate_pending <= 1'b0;
                start_validate_invalid <= 1'b0;
                start_validate_basic_invalid_q <= 1'b0;
                start_validate_geometry_invalid_q <= 1'b0;
                start_validate_channel_invalid_q <= 1'b0;
                start_validate_line_invalid_q <= 1'b0;
                start_validate_tile_invalid_q <= 1'b0;
                start_validate_materialized_invalid_q <= 1'b0;
                start_validate_stream_invalid_q <= 1'b0;
                start_validate_ifm_bytes_invalid_q <= 1'b0;
                start_validate_ofm_bytes_invalid_q <= 1'b0;
                start_validate_pool_invalid_q <= 1'b0;
                start_validate_packed_invalid_q <= 1'b0;
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
                perf_unclassified_cycles <= 32'd0;
            end
        end
    end

    always @(*) begin
        case (cfg_addr)
            8'h00: cfg_rdata = {28'd0, datapath_reset_active,
                                config_error, done_sticky, layer_busy};
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
            7'h59: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ?
                {pass_trace_enable, 7'd0,
                 pass_trace_cout_block, pass_trace_k_pass} : 32'd0;
            7'h5a: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? perf_pass_count : 32'd0;
            7'h5b: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? perf_pass_start_to_first_fire : 32'd0;
            7'h5c: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? perf_pass_first_to_last_fire : 32'd0;
            7'h5d: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? perf_pass_last_fire_to_done : 32'd0;
            7'h5e: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? perf_pass_collect_first_wait : 32'd0;
            7'h5f: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? perf_pass_collect_column_empty : 32'd0;
            7'h60: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? perf_pass_replay_active_during_compute : 32'd0;
            7'h61: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? perf_pass_compute_idle_in_stage : 32'd0;
            7'h62: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? pass_trace_weight_done : 32'd0;
            7'h63: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? pass_trace_feed_start : 32'd0;
            7'h64: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? pass_trace_feed_ready : 32'd0;
            7'h65: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? pass_trace_feed_done : 32'd0;
            7'h66: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? pass_trace_compute_start : 32'd0;
            7'h67: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? pass_trace_first_fire : 32'd0;
            7'h68: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? pass_trace_last_fire : 32'd0;
            7'h69: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? pass_trace_compute_done : 32'd0;
            7'h6a: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? pass_trace_collect_first : 32'd0;
            7'h6b: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? pass_trace_collect_last : 32'd0;
            7'h6c: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? pass_trace_pass_done : 32'd0;
            7'h6d: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ?
                {pass_trace_valid, 31'd1} : 32'd0;
            7'h6e: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ?
                {col_trace_valid, 26'd0, col_trace_selected_col} : 32'd0;
            7'h6f: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? col_trace_first_wr : 32'd0;
            7'h70: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? col_trace_last_wr : 32'd0;
            7'h71: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? col_trace_wr_count : 32'd0;
            7'h72: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? col_trace_empty_wait : 32'd0;
            7'h73: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? col_trace_missing_mask_or : 32'd0;
            7'h74: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? col_trace_missing_mask_first : 32'd0;
            7'h75: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? col_trace_missing_mask_last : 32'd0;
            7'h76: cfg_rdata = (ENABLE_DETAILED_TRACE != 0) ? 32'd1 : 32'd0;
            7'h77: cfg_rdata = 32'd2;
            7'h78: cfg_rdata = {ABI_FEATURE_FLAGS_VISIBLE, COUT_TILE[7:0],
                                 COLS[7:0], ROWS[7:0]};
            7'h79: cfg_rdata = perf_unclassified_cycles;
            7'h7a: cfg_rdata = {configured_layer_last, 22'd0, tile_h_max};
            7'h7b: cfg_rdata = ifm_total_bytes;
            7'h7c: cfg_rdata = ofm_total_bytes;
            7'h7d: cfg_rdata = packed_ofm_axis_byte_count;
            7'h7e: cfg_rdata = packed_ofm_axis_stall_cycles;
            7'h7f: cfg_rdata = datapath_error_status |
                                 {packed_ofm_protocol_error, 31'd0};
            8'h80: cfg_rdata = 32'd2;
            8'h81: cfg_rdata = context_alloc_count;
            8'h82: cfg_rdata = context_input_issued_count;
            8'h83: cfg_rdata = context_array_retired_count;
            8'h84: cfg_rdata = context_collector_done_count;
            8'h85: cfg_rdata = context_gap_cycles;
            8'h86: cfg_rdata = context_ifm_ownership_stall_cycles;
            8'h87: cfg_rdata = context_weight_ownership_stall_cycles;
            8'h88: cfg_rdata = context_psum_credit_stall_cycles;
            8'h89: cfg_rdata = context_epoch_mismatch_count;
            8'h8a: cfg_rdata = context_mismatch_count;
            8'h8b: cfg_rdata = context_ifm_underflow_count;
            8'h8c: cfg_rdata = context_psum_underflow_count;
            8'h8d: cfg_rdata = context_fifo_drop_count;
            8'h8e: cfg_rdata = context_bank_overwrite_count;
            8'h8f: cfg_rdata = context_full_stall_cycles;
            8'h90: cfg_rdata = datapath_reset_count;
            8'h91: cfg_rdata = 32'd1;
            8'h92: cfg_rdata = compute_pipe_compute_gap_count;
            8'h93: cfg_rdata = compute_pipe_preload_commit_count;
            8'h94: cfg_rdata = compute_pipe_preload_hit_count;
            8'h95: cfg_rdata = compute_pipe_preload_miss_count;
            8'h96: cfg_rdata = compute_pipe_eligible_handoff_count;
            8'h97: cfg_rdata = compute_pipe_next_cycle_hit_count;
            8'h98: cfg_rdata = compute_pipe_extra_gap_count;
            8'h99: cfg_rdata = compute_pipe_wait_bank_retire_count;
            8'h9a: cfg_rdata = compute_pipe_wait_weight_count;
            8'h9b: cfg_rdata = compute_pipe_wait_ifm_count;
            8'h9c: cfg_rdata = compute_pipe_wait_psum_count;
            8'h9d: cfg_rdata = compute_pipe_wait_collector_output_count;
            8'h9e: cfg_rdata = compute_pipe_wait_control_count;
            8'h9f: cfg_rdata = compute_pipe_protocol_error_count;
            8'ha0: cfg_rdata = CLOCK_HZ;
            default: cfg_rdata = 32'd0;
        endcase
    end
endmodule

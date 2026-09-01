`timescale 1ns / 1ps

// One bank of the tile-local materialized-window cache.  The two ports are
// independent: the materializer may fill one bank while the feeder replays
// the other.  Context ownership is deliberately bank-level: the parent only
// enables reads after strict-order fill and a same-epoch per-pass ready bit.
// This avoids a large per-entry tag RAM at the formal 32768-entry depth.
module hwc_materialized_tile_cache_ram #(
    parameter integer ROWS = 18,
    parameter integer BANK_AW = 11,
    parameter integer BANK_DEPTH = (1 << BANK_AW)
) (
    input  wire                         clk,
    input  wire                         wr_en,
    input  wire [BANK_AW-1:0]           wr_addr,
    input  wire [ROWS*8-1:0]            wr_data,
    input  wire                         rd_en,
    input  wire [BANK_AW-1:0]           rd_addr,
    input  wire                         rd_capture,
    output reg  [ROWS*8-1:0]            rd_data
);
    (* ram_style = "ultra" *) reg [ROWS*8-1:0] data_mem
        [0:BANK_DEPTH-1];
    // Keep the synchronous UltraRAM return local to the bank, then cross a
    // second, explicit fabric-register boundary before the parent bank mux.
    // The payload registers are intentionally unreset: rd_capture and the
    // parent's valid metadata make every stale value unreachable.
    reg [ROWS*8-1:0] ram_rd_data_q;
    always @(posedge clk) begin
        if (wr_en)
            data_mem[wr_addr] <= wr_data;

        if (rd_en)
            ram_rd_data_q <= data_mem[rd_addr];

        if (rd_capture)
            rd_data <= ram_rd_data_q;
    end
endmodule

// Two-bank, tile-local cache for axis_hwc_window_materializer output.
//
// The materializer presents layer-global pixel tags in row/pass/x order.  A
// tile comprises at most cfg_tile_h_max complete output rows and is stored as
//
//     local_address = local_pixel * pass_count + k_pass.
//
// Only this maximum tile footprint is checked against BANK_DEPTH; the layer
// itself may contain any number of tiles.  A completed tile remains owned by
// its bank until an explicit release handshake.  Consequently tile N can be
// replayed repeatedly (for multiple COUT blocks) while tile N+1 is written to
// the other bank, without exposing either bank to premature reuse.
//
// fill_req is edge-armed and captured into an internal pending context.  It
// may remain asserted while the requested tile/pass is still being filled.
// The synchronous read return, bank-local fabric output registers, and parent
// elastic output slot sustain one vector per cycle and keep all output fields
// stable under random backpressure.
// Stale RAM is suppressed without per-entry tags: allocation clears every
// pass-ready bit, entry tags/order are checked before state advances, and a
// read is exposed only while the captured bank owner still matches
// {epoch,tile,range,pass}.
module hwc_materialized_tile_pingpong_cache #(
    parameter integer ROWS = 18,
    parameter integer EPOCH_W = 8,
    parameter integer TILE_W = 16,
    parameter integer PASS_W = 16,
    parameter integer PIXEL_W = 32,
    parameter integer MAX_PASSES = 512,
    parameter integer BANK_AW = 11,
    parameter integer BANK_DEPTH = (1 << BANK_AW),
    // Formal accelerator builds accept cfg_start only after the authoritative
    // layer descriptor validator has checked the same geometry and capacity
    // limits.  Standalone users retain the local fail-closed validator.
    parameter integer CFG_PREVALIDATED = 0,
    // Release integration consumes the narrow ready-count comparison and
    // leaves these wide compatibility readbacks unconnected.
    parameter integer ENABLE_PASS_READY_BITMAP = 1
) (
    input  wire                         clk,
    input  wire                         rst,

    input  wire                         cfg_start,
    input  wire [EPOCH_W-1:0]           cfg_epoch,
    input  wire [15:0]                  cfg_ofm_w,
    input  wire [15:0]                  cfg_ofm_h,
    input  wire [15:0]                  cfg_tile_h_max,
    input  wire [15:0]                  cfg_k_total,
    input  wire [PIXEL_W-1:0]           cfg_prevalidated_layer_pixels,
    input  wire [PIXEL_W-1:0]           cfg_prevalidated_tile_pixels,
    input  wire [PASS_W-1:0]            cfg_prevalidated_pass_count,
    input  wire [PASS_W-1:0]            cfg_prevalidated_final_pass,
    input  wire [ROWS-1:0]              cfg_prevalidated_final_lane_mask,

    input  wire                         entry_valid,
    output wire                         entry_ready,
    input  wire [ROWS*8-1:0]            entry_data,
    input  wire [ROWS-1:0]              entry_lane_valid,
    input  wire [PIXEL_W-1:0]           entry_pixel,
    input  wire [PASS_W-1:0]            entry_k_pass,
    input  wire [EPOCH_W-1:0]           entry_epoch,
    input  wire                         entry_last,

    input  wire                         fill_req,
    output wire                         fill_req_ready,
    output reg                          fill_req_accept,
    input  wire [15:0]                  pass_base_k,
    input  wire [PASS_W-1:0]            fill_k_pass,
    input  wire [TILE_W-1:0]            fill_tile_index,
    input  wire [PIXEL_W-1:0]           fill_pixel_base,
    input  wire [PIXEL_W-1:0]           fill_num_pixels,
    output wire                         fill_req_pending,

    output wire [ROWS*8-1:0]            vector_data,
    output wire [ROWS-1:0]              vector_lane_valid,
    output wire                         vector_valid,
    input  wire                         vector_ready,
    output wire                         vector_last,
    output reg                          packet_done,

    input  wire                         release_valid,
    output wire                         release_ready,
    input  wire [EPOCH_W-1:0]           release_epoch,
    input  wire [TILE_W-1:0]            release_tile_index,

    output wire                         configured,
    output wire                         materialize_active,
    output reg                          materialize_done,
    output wire                         replay_active,
    output wire [TILE_W-1:0]            active_replay_tile,
    output wire [PASS_W-1:0]            active_replay_pass,

    output wire                         bank0_owned,
    output wire                         bank0_fill_complete,
    output wire [EPOCH_W-1:0]           bank0_epoch,
    output wire [TILE_W-1:0]            bank0_tile_index,
    output wire [PIXEL_W-1:0]           bank0_pixel_base,
    output wire [PIXEL_W-1:0]           bank0_pixel_count,
    output wire [MAX_PASSES-1:0]        bank0_pass_ready_bitmap,
    output wire                         bank1_owned,
    output wire                         bank1_fill_complete,
    output wire [EPOCH_W-1:0]           bank1_epoch,
    output wire [TILE_W-1:0]            bank1_tile_index,
    output wire [PIXEL_W-1:0]           bank1_pixel_base,
    output wire [PIXEL_W-1:0]           bank1_pixel_count,
    output wire [MAX_PASSES-1:0]        bank1_pass_ready_bitmap,

    output reg                          config_error,
    output reg                          order_error,
    output reg                          tag_error,
    output reg                          ownership_error,
    output reg                          overflow_error,
    output wire [4:0]                   error_status,
    output reg  [31:0]                  accepted_entries,
    output reg  [31:0]                  stored_entries,
    output reg  [31:0]                  completed_packets,
    output reg  [31:0]                  completed_pixels,
    output reg  [31:0]                  order_error_count,
    output reg  [31:0]                  tag_error_count,
    output reg  [31:0]                  ownership_error_count,
    output reg  [31:0]                  ownership_stall_cycles,
    output reg  [31:0]                  context_gap_cycles,
    output reg  [31:0]                  vector_backpressure_stall_cycles,
    output reg  [31:0]                  release_stall_cycles
);
    localparam integer CFG_PASS_MATH_W = 17;
    // Materializer commits become ready in strict ascending pass order.  A
    // count therefore carries exactly the same information as the former
    // MAX_PASSES-bit prefix bitmap, including the all-passes-ready value.
    localparam integer READY_COUNT_W = $clog2(MAX_PASSES + 1);
    // A legal tile occupies at most BANK_DEPTH entries and therefore contains
    // at most BANK_DEPTH pixels.  Keep tile-local counts and addresses at the
    // bank-derived width; layer-global pixel bases remain PIXEL_W wide.
    localparam integer COUNT_W = BANK_AW + 1;
    localparam [1:0] REQ_IDLE = 2'd0;
    localparam [1:0] REQ_WAIT = 2'd1;
    localparam [1:0] REQ_ADDR = 2'd2;

    initial begin
        if (PIXEL_W < COUNT_W)
            $error("PIXEL_W must cover BANK_DEPTH count width");
        if (BANK_DEPTH > (1 << BANK_AW))
            $error("BANK_DEPTH exceeds BANK_AW address space");
        if (MAX_PASSES > (1 << PASS_W))
            $error("PASS_W cannot represent MAX_PASSES");
    end

    reg configured_q;
    reg cfg_commit_pending_q;
    reg cfg_accept_legal_q;
    reg [EPOCH_W-1:0] cfg_epoch_q;
    reg [15:0] cfg_ofm_w_q;
    reg [15:0] cfg_ofm_h_q;
    reg [15:0] cfg_tile_h_max_q;
    reg [15:0] cfg_k_total_q;
    reg [PIXEL_W-1:0] cfg_layer_pixels_q;
    reg [COUNT_W-1:0] cfg_tile_pixels_q;
    reg [PASS_W-1:0] cfg_pass_count_q;
    reg [PASS_W-1:0] cfg_final_pass_q;
    reg [ROWS-1:0] cfg_final_lane_mask_q;
    reg [15:0] cfg_first_tile_rows_q;
    reg [COUNT_W-1:0] cfg_first_tile_count_q;
    reg cfg_overflow_q;
    reg [EPOCH_W-1:0] epoch_q;
    reg [15:0] ofm_w_q;
    reg [15:0] ofm_h_q;
    reg [15:0] tile_h_max_q;
    reg [15:0] k_total_q;
    reg [PIXEL_W-1:0] layer_pixels_q;
    reg [COUNT_W-1:0] tile_pixels_q;
    reg [PASS_W-1:0] pass_count_q;
    reg [PASS_W-1:0] final_pass_q;
    reg [ROWS-1:0] final_lane_mask_q;
    reg all_tiles_allocated_q;

    reg [1:0] bank_owned_q;
    reg [1:0] bank_filling_q;
    reg [1:0] bank_complete_q;
    reg [EPOCH_W-1:0] bank_epoch_q [0:1];
    reg [TILE_W-1:0] bank_tile_q [0:1];
    reg [PIXEL_W-1:0] bank_base_q [0:1];
    reg [COUNT_W-1:0] bank_count_q [0:1];
    reg [READY_COUNT_W-1:0] bank_ready_count_q [0:1];

    reg fill_bank_valid_q;
    reg fill_bank_q;
    // Tile allocation decides once whether the active fill owns the final
    // layer pixel.  Keep that decision beside the fill context so the write
    // commit path does not rebuild it from wide bank-base/count metadata.
    reg fill_tile_is_layer_last_q;
    reg [15:0] fill_tile_rows_q;
    reg [15:0] fill_row_q;
    reg [PASS_W-1:0] fill_pass_q;
    reg [15:0] fill_x_q;
    // Strict row/pass/x ordering lets the write-side pixel and BRAM address
    // advance by recurrence.  Keeping both the current value and row base
    // removes two cascaded runtime multipliers from the one-entry-per-cycle
    // URAM write-enable path.
    reg [PIXEL_W-1:0] fill_expected_pixel_q;
    reg [PIXEL_W-1:0] fill_row_base_pixel_q;
    reg [COUNT_W-1:0] fill_entry_addr_q;
    reg [COUNT_W-1:0] fill_row_base_addr_q;
    reg [TILE_W-1:0] next_tile_q;
    reg [15:0] next_tile_row_base_q;
    reg [PIXEL_W-1:0] next_tile_base_q;
    // Half-open end of the registered next-owner descriptor.  Carrying the
    // end explicitly lets request membership compare only registered fields;
    // allocator remaining/count arithmetic never reaches request control.
    reg [PIXEL_W-1:0] next_tile_end_q;

    // The logical fill cursor advances when an entry is accepted.  Physical
    // RAM writes and all externally visible completion state retire from this
    // registered bundle one cycle later.  Only valid is reset; stale payload
    // is unreachable and keeping the wide data register unreset preserves
    // the intended URAM-facing register boundary.
    reg wr_commit_valid_q;
    reg wr_commit_bank_q;
    reg [BANK_AW-1:0] wr_commit_addr_q;
    reg [ROWS*8-1:0] wr_commit_data_q;
    reg [PASS_W-1:0] wr_commit_ready_count_q;
    reg wr_commit_finishes_pass_q;
    reg wr_commit_finishes_tile_q;
    reg wr_commit_finishes_layer_q;

    reg req_armed_q;
    reg req_pending_q;
    reg [1:0] req_state_q;
    reg req_contract_ok_q;
    // Future-owner membership is classified once in WAIT, after any allocator
    // advance on the request-accept edge has published its registered next
    // descriptor.  An already-owned request can still leave WAIT immediately.
    reg req_future_known_q;
    reg req_future_match_q;
    reg [TILE_W-1:0] req_tile_q;
    reg [PASS_W-1:0] req_pass_q;
    reg [PIXEL_W-1:0] req_base_q;
    reg [PIXEL_W-1:0] req_end_q;
    reg req_bank_q;
    reg [COUNT_W-1:0] req_local_pixel_q;

    reg replay_active_q;
    reg replay_bank_q;
    reg [TILE_W-1:0] replay_tile_q;
    reg [PASS_W-1:0] replay_pass_q;
    reg [PIXEL_W-1:0] replay_end_q;
    reg [PIXEL_W-1:0] issue_pixel_q;
    reg [BANK_AW-1:0] issue_addr_q;

    // One registered read-command slot separates replay range/cursor
    // arithmetic from the UltraRAM enable pins.  REQ_ADDR preloads the first
    // command; each accepted command can be replaced on the same edge, so
    // the existing first-read timing and one-vector-per-clock steady state
    // are preserved.
    reg rd_cmd_valid_q;
    reg rd_cmd_bank_q;
    reg [BANK_AW-1:0] rd_cmd_addr_q;
    reg [EPOCH_W-1:0] rd_cmd_epoch_q;
    reg [TILE_W-1:0] rd_cmd_tile_q;
    reg [PASS_W-1:0] rd_cmd_pass_q;
    reg [PIXEL_W-1:0] rd_cmd_pixel_q;
    reg [ROWS-1:0] rd_cmd_lane_valid_q;
    reg rd_cmd_last_q;

    reg rd_valid_q;
    reg rd_bank_q;
    reg [EPOCH_W-1:0] rd_expected_epoch_q;
    reg [TILE_W-1:0] rd_expected_tile_q;
    reg [PASS_W-1:0] rd_expected_pass_q;
    reg [PIXEL_W-1:0] rd_expected_pixel_q;
    reg [ROWS-1:0] rd_lane_valid_q;
    reg rd_last_q;

    // The return metadata slot is independent of the externally visible
    // elastic slot.  Wide payload stays bank-local and crosses into the
    // corresponding fabric output register only on rd_to_out.
    reg out_valid_q;
    reg out_bank_q;
    reg [EPOCH_W-1:0] out_expected_epoch_q;
    reg [TILE_W-1:0] out_expected_tile_q;
    reg [PASS_W-1:0] out_expected_pass_q;
    reg [PIXEL_W-1:0] out_expected_pixel_q;
    reg [ROWS-1:0] out_lane_valid_q;
    reg out_last_q;
    reg out_context_match_q;
    reg release_reported_q;

    wire [CFG_PASS_MATH_W-1:0] cfg_pass_count_math =
        (cfg_k_total + ROWS - 1) / ROWS;
    wire [31:0] cfg_layer_pixels_math = cfg_ofm_w * cfg_ofm_h;
    wire [31:0] cfg_tile_pixels_math = cfg_ofm_w * cfg_tile_h_max;
    wire [47:0] cfg_max_tile_entries_math =
        cfg_tile_pixels_math * cfg_pass_count_math;
    // A TILE_W-bit index can name exactly 2**TILE_W tiles.  Express the
    // representability check as a multiply so a runtime tile-height divider
    // is not inferred.
    wire [32:0] cfg_tile_row_capacity_math =
        cfg_tile_h_max * (33'd1 << TILE_W);
    wire cfg_legal = (cfg_ofm_w != 0) && (cfg_ofm_h != 0) &&
        (cfg_tile_h_max != 0) && (cfg_k_total != 0) &&
        (cfg_pass_count_math != 0) &&
        (cfg_pass_count_math <= MAX_PASSES) &&
        (cfg_ofm_h <= cfg_tile_row_capacity_math) &&
        (cfg_max_tile_entries_math <= BANK_DEPTH);
    wire cfg_accept_legal = (CFG_PREVALIDATED != 0) ? 1'b1 : cfg_legal;
    wire [CFG_PASS_MATH_W-1:0] cfg_prior_pass_math =
        (ROWS == 18) ? (((cfg_pass_count_math - 1'b1) << 4) +
                        ((cfg_pass_count_math - 1'b1) << 1)) :
                       ((cfg_pass_count_math - 1'b1) * ROWS);
    (* use_dsp = "no" *)
    wire [CFG_PASS_MATH_W-1:0] cfg_final_lane_count_math =
        (cfg_pass_count_math == 0) ? {CFG_PASS_MATH_W{1'b0}} :
        cfg_k_total - cfg_prior_pass_math;
    reg [ROWS-1:0] cfg_final_lane_mask_math;
    integer cfg_lane_i;
    always @* begin
        cfg_final_lane_mask_math = {ROWS{1'b0}};
        for (cfg_lane_i = 0; cfg_lane_i < ROWS;
             cfg_lane_i = cfg_lane_i + 1)
            if (cfg_lane_i < cfg_final_lane_count_math)
                cfg_final_lane_mask_math[cfg_lane_i] = 1'b1;
    end
    wire [15:0] cfg_first_tile_rows_math =
        (cfg_ofm_h > cfg_tile_h_max) ? cfg_tile_h_max : cfg_ofm_h;
    wire [PIXEL_W-1:0] cfg_first_tile_count_full =
        (cfg_layer_pixels_math > cfg_tile_pixels_math) ?
        cfg_tile_pixels_math[PIXEL_W-1:0] :
        cfg_layer_pixels_math[PIXEL_W-1:0];
    wire [COUNT_W-1:0] cfg_first_tile_count_math =
        cfg_first_tile_count_full[COUNT_W-1:0];
    wire [PIXEL_W-1:0] cfg_selected_layer_pixels =
        (CFG_PREVALIDATED != 0) ? cfg_prevalidated_layer_pixels :
        cfg_layer_pixels_math[PIXEL_W-1:0];
    wire [COUNT_W-1:0] cfg_selected_tile_pixels =
        (CFG_PREVALIDATED != 0) ?
        cfg_prevalidated_tile_pixels[COUNT_W-1:0] :
        cfg_tile_pixels_math[COUNT_W-1:0];
    wire [PASS_W-1:0] cfg_selected_pass_count =
        (CFG_PREVALIDATED != 0) ? cfg_prevalidated_pass_count :
        cfg_pass_count_math[PASS_W-1:0];
    wire [PASS_W-1:0] cfg_selected_final_pass =
        (CFG_PREVALIDATED != 0) ? cfg_prevalidated_final_pass :
        cfg_pass_count_math[PASS_W-1:0] - 1'b1;
    wire [ROWS-1:0] cfg_selected_final_lane_mask =
        (CFG_PREVALIDATED != 0) ? cfg_prevalidated_final_lane_mask :
        cfg_final_lane_mask_math;
    wire [15:0] cfg_selected_first_tile_rows =
        (CFG_PREVALIDATED != 0) ? cfg_tile_h_max :
        cfg_first_tile_rows_math;
    wire [COUNT_W-1:0] cfg_selected_first_tile_count =
        (CFG_PREVALIDATED != 0) ?
        cfg_prevalidated_tile_pixels[COUNT_W-1:0] :
        cfg_first_tile_count_math;

    // Tile allocation is strictly ascending.  Carry the next row and
    // half-open pixel range explicitly instead of rebuilding them from the
    // tile index.  The end advances by one bounded tile per allocation.
    wire [PIXEL_W-1:0] next_tile_rows_remaining_math =
        {{(PIXEL_W-16){1'b0}}, ofm_h_q} -
        {{(PIXEL_W-16){1'b0}}, next_tile_row_base_q};
    wire [15:0] next_tile_rows_math =
        (next_tile_rows_remaining_math > tile_h_max_q) ?
        tile_h_max_q : next_tile_rows_remaining_math[15:0];
    wire [PIXEL_W-1:0] tile_pixels_ext =
        {{(PIXEL_W-COUNT_W){1'b0}}, tile_pixels_q};
    wire [PIXEL_W-1:0] next_tile_count_full =
        next_tile_end_q - next_tile_base_q;
    wire [COUNT_W-1:0] next_tile_count_math =
        next_tile_count_full[COUNT_W-1:0];
    wire next_tile_exists =
        (next_tile_row_base_q < ofm_h_q) &&
        (next_tile_base_q < next_tile_end_q);
    wire [PIXEL_W:0] following_tile_end_sum =
        {1'b0, next_tile_end_q} + {1'b0, tile_pixels_ext};
    wire [PIXEL_W-1:0] following_tile_end_math =
        (following_tile_end_sum > {1'b0, layer_pixels_q}) ?
        layer_pixels_q : following_tile_end_sum[PIXEL_W-1:0];
    wire [PIXEL_W-1:0] cfg_first_tile_count_ext =
        {{(PIXEL_W-COUNT_W){1'b0}}, cfg_first_tile_count_q};
    wire [PIXEL_W-1:0] cfg_tile_pixels_ext =
        {{(PIXEL_W-COUNT_W){1'b0}}, cfg_tile_pixels_q};
    wire [PIXEL_W:0] cfg_next_tile_end_sum =
        {1'b0, cfg_first_tile_count_ext} + {1'b0, cfg_tile_pixels_ext};
    wire [PIXEL_W-1:0] cfg_next_tile_end_math =
        (cfg_next_tile_end_sum > {1'b0, cfg_layer_pixels_q}) ?
        cfg_layer_pixels_q : cfg_next_tile_end_sum[PIXEL_W-1:0];

    wire [PIXEL_W-1:0] expected_global_pixel = fill_expected_pixel_q;
    wire expected_layer_last =
        fill_tile_is_layer_last_q &&
        (fill_row_q + 1'b1 == fill_tile_rows_q) &&
        (fill_pass_q + 1'b1 == pass_count_q) &&
        (fill_x_q + 1'b1 == ofm_w_q);
    wire entry_epoch_ok = (entry_epoch == epoch_q);
    wire [ROWS-1:0] expected_entry_lane_valid =
        (fill_pass_q == final_pass_q) ? final_lane_mask_q : {ROWS{1'b1}};
    wire [ROWS-1:0] issue_lane_valid =
        (replay_pass_q == final_pass_q) ?
        final_lane_mask_q : {ROWS{1'b1}};
    wire entry_order_ok = (entry_pixel == expected_global_pixel) &&
        (entry_k_pass == fill_pass_q);
    wire entry_lane_tag_ok =
        (entry_lane_valid == expected_entry_lane_valid);
    wire entry_addr_ok = (fill_entry_addr_q < BANK_DEPTH);
    wire entry_fire = entry_valid && entry_ready;
    wire entry_write_accept = entry_fire && entry_epoch_ok && entry_order_ok &&
        entry_lane_tag_ok && (entry_last == expected_layer_last) &&
        entry_addr_ok;
    wire entry_finishes_pass = entry_write_accept &&
        (fill_row_q + 1'b1 == fill_tile_rows_q) &&
        (fill_x_q + 1'b1 == ofm_w_q);
    wire entry_finishes_tile = entry_finishes_pass &&
        (fill_pass_q + 1'b1 == pass_count_q);

    wire [PIXEL_W:0] req_input_end_math =
        {1'b0, fill_pixel_base} + {1'b0, fill_num_pixels};
    // The release scheduler carries the pass index alongside pass_base_k.
    // Consume that explicit index in the prevalidated path so no runtime
    // divider/modulo remains in the cache request fanout.  Standalone/debug
    // users retain the fail-closed legacy derivation and alignment check.
    wire [PASS_W-1:0] req_input_pass_math;
    wire req_input_pass_aligned;
    localparam integer REQ_PASS_BASE_W =
        ((PASS_W + $clog2(ROWS)) > 16) ?
        (PASS_W + $clog2(ROWS)) : 16;
    generate
        if (CFG_PREVALIDATED != 0) begin : g_explicit_fill_pass
            wire [REQ_PASS_BASE_W-1:0] fill_k_pass_ext =
                {{(REQ_PASS_BASE_W-PASS_W){1'b0}}, fill_k_pass};
            wire [REQ_PASS_BASE_W-1:0] pass_base_k_ext =
                {{(REQ_PASS_BASE_W-16){1'b0}}, pass_base_k};
            wire [REQ_PASS_BASE_W-1:0] fill_pass_base_math;
            if (ROWS == 18) begin : g_rows18_fill_base
                assign fill_pass_base_math =
                    (fill_k_pass_ext << 4) + (fill_k_pass_ext << 1);
            end else begin : g_generic_fill_base
                assign fill_pass_base_math = fill_k_pass_ext * ROWS;
            end
            assign req_input_pass_math = fill_k_pass;
            assign req_input_pass_aligned =
                (fill_pass_base_math == pass_base_k_ext);
        end else begin : g_derived_fill_pass
            assign req_input_pass_math = pass_base_k / ROWS;
            assign req_input_pass_aligned = ((pass_base_k % ROWS) == 0);
        end
    endgenerate
    // Request acceptance captures payload unconditionally.  Static contract
    // checks are reduced to one registered bit; ownership and address work is
    // performed from captured state in the following WAIT/ADDR phases.
    wire req_input_static_valid = configured_q &&
        req_input_pass_aligned &&
        (req_input_pass_math < pass_count_q) &&
        (req_input_pass_math < MAX_PASSES) &&
        (fill_num_pixels != 0) &&
        (fill_pixel_base < layer_pixels_q) &&
        (req_input_end_math <= {1'b0, layer_pixels_q});

    wire req_b0_match = bank_owned_q[0] &&
        (bank_epoch_q[0] == epoch_q) && (bank_tile_q[0] == req_tile_q) &&
        (req_base_q >= bank_base_q[0]) &&
        (req_end_q <= bank_base_q[0] +
            {{(PIXEL_W-COUNT_W){1'b0}}, bank_count_q[0]});
    wire req_b1_match = bank_owned_q[1] &&
        (bank_epoch_q[1] == epoch_q) && (bank_tile_q[1] == req_tile_q) &&
        (req_base_q >= bank_base_q[1]) &&
        (req_end_q <= bank_base_q[1] +
            {{(PIXEL_W-COUNT_W){1'b0}}, bank_count_q[1]});
    // Preserve the original one-future-owner behavior while the allocator is
    // waiting for a free bank.  Classification happens in the first WAIT
    // cycle, so a request accepted beside an allocation sees the post-edge
    // next descriptor without rebuilding that descriptor on the accept edge.
    wire next_alloc_fire = configured_q && !fill_bank_valid_q &&
        !all_tiles_allocated_q && next_tile_exists &&
        (!bank_owned_q[0] || !bank_owned_q[1]) &&
        !cfg_start && !cfg_commit_pending_q;
    wire req_bank_found = req_b0_match || req_b1_match;
    wire req_bank_select = req_b1_match;
    wire req_future_descriptor_match = next_tile_exists &&
        (req_tile_q == next_tile_q) &&
        (req_base_q >= next_tile_base_q) &&
        (req_end_q <= next_tile_end_q);
    wire req_future_classify = (req_state_q == REQ_WAIT) &&
        req_contract_ok_q && !req_bank_found && !req_future_known_q;
    wire req_next_match = req_future_known_q && req_future_match_q;
    wire [READY_COUNT_W-1:0] req_selected_ready_count = req_bank_select ?
        bank_ready_count_q[1] : bank_ready_count_q[0];
    wire req_selected_pass_ready = (req_pass_q < MAX_PASSES) &&
        (req_pass_q < req_selected_ready_count);
    wire [PIXEL_W-1:0] req_selected_bank_base = req_bank_select ?
        bank_base_q[1] : bank_base_q[0];
    wire [PIXEL_W-1:0] req_selected_local_pixel_full =
        req_base_q - req_selected_bank_base;
    wire req_wait_capture = (req_state_q == REQ_WAIT) &&
        req_contract_ok_q && req_bank_found && req_selected_pass_ready &&
        !replay_active_q && !rd_valid_q && !out_valid_q;
    wire req_wait_invalid = (req_state_q == REQ_WAIT) &&
        (!req_contract_ok_q ||
         (!req_bank_found && req_future_known_q && !req_next_match));
    wire [COUNT_W+PASS_W-1:0] req_start_addr_math =
        req_local_pixel_q * pass_count_q + req_pass_q;

    wire out_pop = out_valid_q && vector_ready;
    wire out_credit = !out_valid_q || vector_ready;
    wire rd_to_out = rd_valid_q && out_credit;
    wire rd_credit = !rd_valid_q || rd_to_out;
    wire rd_issue = rd_cmd_valid_q && rd_credit;
    wire vector_fire = out_pop;

    wire [ROWS*8-1:0] ram0_rd_data;
    wire [ROWS*8-1:0] ram1_rd_data;

    wire [ROWS*8-1:0] selected_out_data = out_bank_q ?
        ram1_rd_data : ram0_rd_data;
    wire rd_owner_match = rd_bank_q ?
        (bank_owned_q[1] &&
         (bank_epoch_q[1] == rd_expected_epoch_q) &&
         (bank_tile_q[1] == rd_expected_tile_q) &&
         (rd_expected_pixel_q >= bank_base_q[1]) &&
         (rd_expected_pixel_q < bank_base_q[1] +
          {{(PIXEL_W-COUNT_W){1'b0}}, bank_count_q[1]})) :
        (bank_owned_q[0] &&
         (bank_epoch_q[0] == rd_expected_epoch_q) &&
         (bank_tile_q[0] == rd_expected_tile_q) &&
         (rd_expected_pixel_q >= bank_base_q[0]) &&
         (rd_expected_pixel_q < bank_base_q[0] +
          {{(PIXEL_W-COUNT_W){1'b0}}, bank_count_q[0]}));
    wire [READY_COUNT_W-1:0] rd_ready_count = rd_bank_q ?
        bank_ready_count_q[1] : bank_ready_count_q[0];
    wire rd_pass_is_ready = (rd_expected_pass_q < MAX_PASSES) &&
        (rd_expected_pass_q < rd_ready_count);
    wire out_context_match = out_context_match_q;

    wire release_b0_match = bank_owned_q[0] &&
        (bank_epoch_q[0] == release_epoch) &&
        (bank_tile_q[0] == release_tile_index);
    wire release_b1_match = bank_owned_q[1] &&
        (bank_epoch_q[1] == release_epoch) &&
        (bank_tile_q[1] == release_tile_index);
    wire req_blocks_b0_release =
        ((req_state_q == REQ_WAIT) && req_b0_match) ||
        ((req_state_q == REQ_ADDR) && !req_bank_q);
    wire req_blocks_b1_release =
        ((req_state_q == REQ_WAIT) && req_b1_match) ||
        ((req_state_q == REQ_ADDR) && req_bank_q);
    wire release_b0_safe = release_b0_match && bank_complete_q[0] &&
        !bank_filling_q[0] &&
        !(replay_active_q && !replay_bank_q) &&
        !(rd_cmd_valid_q && !rd_cmd_bank_q) &&
        !(rd_valid_q && !rd_bank_q) &&
        !(out_valid_q && !out_bank_q) &&
        !req_blocks_b0_release && !(fill_req && fill_req_ready);
    wire release_b1_safe = release_b1_match && bank_complete_q[1] &&
        !bank_filling_q[1] &&
        !(replay_active_q && replay_bank_q) &&
        !(rd_cmd_valid_q && rd_cmd_bank_q) &&
        !(rd_valid_q && rd_bank_q) &&
        !(out_valid_q && out_bank_q) &&
        !req_blocks_b1_release && !(fill_req && fill_req_ready);
    wire release_fire = release_valid && release_ready;
    wire cfg_ownership_busy = configured_q &&
        ((bank_owned_q != 2'b00) || replay_active_q || rd_cmd_valid_q ||
         rd_valid_q || out_valid_q || req_pending_q || wr_commit_valid_q);

    wire read_write_collision = wr_commit_valid_q && rd_issue &&
        (wr_commit_bank_q == rd_cmd_bank_q) &&
        (wr_commit_addr_q == rd_cmd_addr_q);

    assign configured = configured_q;
    assign materialize_active = configured_q &&
        (fill_bank_valid_q ||
         wr_commit_valid_q ||
         (!all_tiles_allocated_q && next_tile_exists));
    assign replay_active = replay_active_q;
    assign active_replay_tile = replay_tile_q;
    assign active_replay_pass = replay_pass_q;
    assign entry_ready = configured_q && fill_bank_valid_q && !cfg_start &&
        !cfg_commit_pending_q;
    assign fill_req_ready = configured_q && req_armed_q &&
        (req_state_q == REQ_IDLE) &&
        !replay_active_q && !rd_cmd_valid_q && !rd_valid_q && !out_valid_q && !cfg_start &&
        !cfg_commit_pending_q;
    assign fill_req_pending = req_pending_q;
    assign vector_valid = out_valid_q;
    assign vector_data = out_context_match ? selected_out_data :
        {ROWS*8{1'b0}};
    assign vector_lane_valid = out_context_match ? out_lane_valid_q :
        {ROWS{1'b0}};
    assign vector_last = out_valid_q && out_last_q;
    assign release_ready = configured_q && !cfg_start &&
        !cfg_commit_pending_q &&
        (release_b0_safe || release_b1_safe);

    assign bank0_owned = bank_owned_q[0];
    assign bank0_fill_complete = bank_complete_q[0];
    assign bank0_epoch = bank_epoch_q[0];
    assign bank0_tile_index = bank_tile_q[0];
    assign bank0_pixel_base = bank_base_q[0];
    assign bank0_pixel_count =
        {{(PIXEL_W-COUNT_W){1'b0}}, bank_count_q[0]};
    assign bank1_owned = bank_owned_q[1];
    assign bank1_fill_complete = bank_complete_q[1];
    assign bank1_epoch = bank_epoch_q[1];
    assign bank1_tile_index = bank_tile_q[1];
    assign bank1_pixel_base = bank_base_q[1];
    assign bank1_pixel_count =
        {{(PIXEL_W-COUNT_W){1'b0}}, bank_count_q[1]};
    // Preserve the diagnostic bitmap ABI.  Formal integration leaves these
    // ports unused, so synthesis trims this compatibility decode; replay
    // readiness itself is now a narrow compare rather than a dynamic select.
    genvar ready_bit_i;
    generate
        for (ready_bit_i = 0; ready_bit_i < MAX_PASSES;
             ready_bit_i = ready_bit_i + 1) begin : gen_ready_bitmap_compat
            localparam [READY_COUNT_W-1:0] READY_INDEX = ready_bit_i;
            assign bank0_pass_ready_bitmap[ready_bit_i] =
                (ENABLE_PASS_READY_BITMAP != 0) &&
                (READY_INDEX < bank_ready_count_q[0]);
            assign bank1_pass_ready_bitmap[ready_bit_i] =
                (ENABLE_PASS_READY_BITMAP != 0) &&
                (READY_INDEX < bank_ready_count_q[1]);
        end
    endgenerate
    assign error_status = {overflow_error, ownership_error, tag_error,
                           order_error, config_error};

    hwc_materialized_tile_cache_ram #(
        .ROWS(ROWS), .BANK_AW(BANK_AW),
        .BANK_DEPTH(BANK_DEPTH)
    ) u_bank0 (
        .clk(clk),
        .wr_en(wr_commit_valid_q && !wr_commit_bank_q),
        .wr_addr(wr_commit_addr_q),
        .wr_data(wr_commit_data_q),
        .rd_en(rd_issue && !rd_cmd_bank_q), .rd_addr(rd_cmd_addr_q),
        .rd_capture(rd_to_out && !rd_bank_q),
        .rd_data(ram0_rd_data)
    );

    hwc_materialized_tile_cache_ram #(
        .ROWS(ROWS), .BANK_AW(BANK_AW),
        .BANK_DEPTH(BANK_DEPTH)
    ) u_bank1 (
        .clk(clk),
        .wr_en(wr_commit_valid_q && wr_commit_bank_q),
        .wr_addr(wr_commit_addr_q),
        .wr_data(wr_commit_data_q),
        .rd_en(rd_issue && rd_cmd_bank_q), .rd_addr(rd_cmd_addr_q),
        .rd_capture(rd_to_out && rd_bank_q),
        .rd_data(ram1_rd_data)
    );

    always @(posedge clk) begin
        if (rst) begin
            configured_q <= 1'b0;
            cfg_commit_pending_q <= 1'b0;
            cfg_accept_legal_q <= 1'b0;
            cfg_epoch_q <= {EPOCH_W{1'b0}};
            cfg_ofm_w_q <= 16'd0;
            cfg_ofm_h_q <= 16'd0;
            cfg_tile_h_max_q <= 16'd0;
            cfg_k_total_q <= 16'd0;
            cfg_layer_pixels_q <= {PIXEL_W{1'b0}};
            cfg_tile_pixels_q <= {COUNT_W{1'b0}};
            cfg_pass_count_q <= {PASS_W{1'b0}};
            cfg_final_pass_q <= {PASS_W{1'b0}};
            cfg_final_lane_mask_q <= {ROWS{1'b0}};
            cfg_first_tile_rows_q <= 16'd0;
            cfg_first_tile_count_q <= {COUNT_W{1'b0}};
            cfg_overflow_q <= 1'b0;
            epoch_q <= {EPOCH_W{1'b0}};
            ofm_w_q <= 16'd0;
            ofm_h_q <= 16'd0;
            tile_h_max_q <= 16'd0;
            k_total_q <= 16'd0;
            layer_pixels_q <= {PIXEL_W{1'b0}};
            tile_pixels_q <= {COUNT_W{1'b0}};
            pass_count_q <= {PASS_W{1'b0}};
            final_pass_q <= {PASS_W{1'b0}};
            final_lane_mask_q <= {ROWS{1'b0}};
            all_tiles_allocated_q <= 1'b0;
            bank_owned_q <= 2'b00;
            bank_filling_q <= 2'b00;
            bank_complete_q <= 2'b00;
            bank_epoch_q[0] <= {EPOCH_W{1'b0}};
            bank_epoch_q[1] <= {EPOCH_W{1'b0}};
            bank_tile_q[0] <= {TILE_W{1'b0}};
            bank_tile_q[1] <= {TILE_W{1'b0}};
            bank_base_q[0] <= {PIXEL_W{1'b0}};
            bank_base_q[1] <= {PIXEL_W{1'b0}};
            bank_count_q[0] <= {COUNT_W{1'b0}};
            bank_count_q[1] <= {COUNT_W{1'b0}};
            bank_ready_count_q[0] <= {READY_COUNT_W{1'b0}};
            bank_ready_count_q[1] <= {READY_COUNT_W{1'b0}};
            fill_bank_valid_q <= 1'b0;
            fill_bank_q <= 1'b0;
            fill_tile_is_layer_last_q <= 1'b0;
            fill_tile_rows_q <= 16'd0;
            fill_row_q <= 16'd0;
            fill_pass_q <= {PASS_W{1'b0}};
            fill_x_q <= 16'd0;
            fill_expected_pixel_q <= {PIXEL_W{1'b0}};
            fill_row_base_pixel_q <= {PIXEL_W{1'b0}};
            fill_entry_addr_q <= {COUNT_W{1'b0}};
            fill_row_base_addr_q <= {COUNT_W{1'b0}};
            next_tile_q <= {TILE_W{1'b0}};
            next_tile_row_base_q <= 16'd0;
            next_tile_base_q <= {PIXEL_W{1'b0}};
            next_tile_end_q <= {PIXEL_W{1'b0}};
            wr_commit_valid_q <= 1'b0;
            req_armed_q <= 1'b1;
            req_pending_q <= 1'b0;
            req_state_q <= REQ_IDLE;
            req_contract_ok_q <= 1'b0;
            req_future_known_q <= 1'b0;
            req_future_match_q <= 1'b0;
            req_tile_q <= {TILE_W{1'b0}};
            req_pass_q <= {PASS_W{1'b0}};
            req_base_q <= {PIXEL_W{1'b0}};
            req_end_q <= {PIXEL_W{1'b0}};
            req_bank_q <= 1'b0;
            req_local_pixel_q <= {COUNT_W{1'b0}};
            replay_active_q <= 1'b0;
            replay_bank_q <= 1'b0;
            replay_tile_q <= {TILE_W{1'b0}};
            replay_pass_q <= {PASS_W{1'b0}};
            replay_end_q <= {PIXEL_W{1'b0}};
            issue_pixel_q <= {PIXEL_W{1'b0}};
            issue_addr_q <= {BANK_AW{1'b0}};
            rd_cmd_valid_q <= 1'b0;
            rd_cmd_bank_q <= 1'b0;
            rd_cmd_addr_q <= {BANK_AW{1'b0}};
            rd_cmd_epoch_q <= {EPOCH_W{1'b0}};
            rd_cmd_tile_q <= {TILE_W{1'b0}};
            rd_cmd_pass_q <= {PASS_W{1'b0}};
            rd_cmd_pixel_q <= {PIXEL_W{1'b0}};
            rd_cmd_lane_valid_q <= {ROWS{1'b0}};
            rd_cmd_last_q <= 1'b0;
            rd_valid_q <= 1'b0;
            rd_bank_q <= 1'b0;
            rd_expected_epoch_q <= {EPOCH_W{1'b0}};
            rd_expected_tile_q <= {TILE_W{1'b0}};
            rd_expected_pass_q <= {PASS_W{1'b0}};
            rd_expected_pixel_q <= {PIXEL_W{1'b0}};
            rd_lane_valid_q <= {ROWS{1'b0}};
            rd_last_q <= 1'b0;
            out_valid_q <= 1'b0;
            out_bank_q <= 1'b0;
            out_expected_epoch_q <= {EPOCH_W{1'b0}};
            out_expected_tile_q <= {TILE_W{1'b0}};
            out_expected_pass_q <= {PASS_W{1'b0}};
            out_expected_pixel_q <= {PIXEL_W{1'b0}};
            out_lane_valid_q <= {ROWS{1'b0}};
            out_last_q <= 1'b0;
            out_context_match_q <= 1'b0;
            release_reported_q <= 1'b0;
            fill_req_accept <= 1'b0;
            packet_done <= 1'b0;
            materialize_done <= 1'b0;
            config_error <= 1'b0;
            order_error <= 1'b0;
            tag_error <= 1'b0;
            ownership_error <= 1'b0;
            overflow_error <= 1'b0;
            accepted_entries <= 32'd0;
            stored_entries <= 32'd0;
            completed_packets <= 32'd0;
            completed_pixels <= 32'd0;
            order_error_count <= 32'd0;
            tag_error_count <= 32'd0;
            ownership_error_count <= 32'd0;
            ownership_stall_cycles <= 32'd0;
            context_gap_cycles <= 32'd0;
            vector_backpressure_stall_cycles <= 32'd0;
            release_stall_cycles <= 32'd0;
        end else begin
            fill_req_accept <= 1'b0;
            packet_done <= 1'b0;
            materialize_done <= 1'b0;
            // The old bundle, if any, retires below.  A new accepted entry in
            // the ordinary operating branch replaces valid in the same edge.
            wr_commit_valid_q <= 1'b0;
            // Payload capture is deliberately unconditional outside reset.
            // Deep tag/order checks control only the narrow valid bit, never
            // the 144-bit data register or RAM write-data register enables.
            wr_commit_bank_q <= fill_bank_q;
            wr_commit_addr_q <= fill_entry_addr_q[BANK_AW-1:0];
            wr_commit_data_q <= entry_data;
            wr_commit_ready_count_q <= fill_pass_q + 1'b1;
            wr_commit_finishes_pass_q <= entry_finishes_pass;
            wr_commit_finishes_tile_q <= entry_finishes_tile;
            wr_commit_finishes_layer_q <=
                entry_finishes_tile && entry_last;

            if (!fill_req)
                req_armed_q <= 1'b1;
            if (!release_valid)
                release_reported_q <= 1'b0;

            if (vector_valid && !vector_ready)
                vector_backpressure_stall_cycles <=
                    vector_backpressure_stall_cycles + 1'b1;
            if (release_valid && !release_ready)
                release_stall_cycles <= release_stall_cycles + 1'b1;
            if ((entry_valid && !entry_ready) ||
                ((req_state_q == REQ_WAIT) && !req_bank_found))
                ownership_stall_cycles <= ownership_stall_cycles + 1'b1;
            if ((req_state_q == REQ_WAIT) && !req_wait_capture)
                context_gap_cycles <= context_gap_cycles + 1'b1;

            // Physical write retirement is independent of cfg_start.  A busy
            // cfg request is rejected, but it must never suppress a RAM write
            // that was already accepted on the preceding cycle.
            if (wr_commit_valid_q) begin
                stored_entries <= stored_entries + 1'b1;
                if (wr_commit_finishes_pass_q)
                    bank_ready_count_q[wr_commit_bank_q] <=
                        wr_commit_ready_count_q;
                if (wr_commit_finishes_tile_q) begin
                    bank_filling_q[wr_commit_bank_q] <= 1'b0;
                    bank_complete_q[wr_commit_bank_q] <= 1'b1;
                end
                if (wr_commit_finishes_layer_q) begin
                    materialize_done <= 1'b1;
                    all_tiles_allocated_q <= 1'b1;
                end
            end

            // Return/output retirement is also independent of cfg_start.  A
            // busy configuration pulse is rejected below, but it must not
            // consume an externally visible vector handshake without moving
            // the elastic slots, nor may it desynchronize RAM payload from
            // the corresponding return metadata.
            if (rd_issue) begin
                rd_valid_q <= 1'b1;
                rd_bank_q <= rd_cmd_bank_q;
                rd_expected_epoch_q <= rd_cmd_epoch_q;
                rd_expected_tile_q <= rd_cmd_tile_q;
                rd_expected_pass_q <= rd_cmd_pass_q;
                rd_expected_pixel_q <= rd_cmd_pixel_q;
                rd_lane_valid_q <= rd_cmd_lane_valid_q;
                rd_last_q <= rd_cmd_last_q;
            end else if (rd_to_out) begin
                rd_valid_q <= 1'b0;
            end

            // A command accepted by the RAM may be replaced immediately by
            // the next replay address.  Range comparison only reaches this
            // narrow command register; physical RAM EN is driven solely from
            // the registered valid plus registered elastic-slot credit.
            if (rd_issue) begin
                if (issue_pixel_q < replay_end_q) begin
                    rd_cmd_valid_q <= 1'b1;
                    rd_cmd_bank_q <= replay_bank_q;
                    rd_cmd_addr_q <= issue_addr_q;
                    rd_cmd_epoch_q <= epoch_q;
                    rd_cmd_tile_q <= replay_tile_q;
                    rd_cmd_pass_q <= replay_pass_q;
                    rd_cmd_pixel_q <= issue_pixel_q;
                    rd_cmd_lane_valid_q <= issue_lane_valid;
                    rd_cmd_last_q <=
                        (issue_pixel_q + 1'b1 == replay_end_q);
                    issue_pixel_q <= issue_pixel_q + 1'b1;
                    issue_addr_q <= issue_addr_q + pass_count_q;
                end else begin
                    rd_cmd_valid_q <= 1'b0;
                end
            end

            if (rd_to_out) begin
                out_valid_q <= 1'b1;
                out_bank_q <= rd_bank_q;
                out_expected_epoch_q <= rd_expected_epoch_q;
                out_expected_tile_q <= rd_expected_tile_q;
                out_expected_pass_q <= rd_expected_pass_q;
                out_expected_pixel_q <= rd_expected_pixel_q;
                out_lane_valid_q <= rd_lane_valid_q;
                out_last_q <= rd_last_q;
                out_context_match_q <= rd_owner_match &&
                    rd_pass_is_ready;
            end else if (out_pop) begin
                out_valid_q <= 1'b0;
            end

            if (vector_fire) begin
                completed_pixels <= completed_pixels + 1'b1;
                if (!out_context_match) begin
                    tag_error <= 1'b1;
                    tag_error_count <= tag_error_count + 1'b1;
                end
                if (vector_last) begin
                    replay_active_q <= 1'b0;
                    packet_done <= 1'b1;
                    completed_packets <= completed_packets + 1'b1;
                end
            end

            if (read_write_collision) begin
                ownership_error <= 1'b1;
                ownership_error_count <= ownership_error_count + 1'b1;
            end

            if (cfg_start) begin
                if (cfg_ownership_busy || cfg_commit_pending_q) begin
                    // A new epoch is not an implicit release.  Keep all
                    // current ownership intact and fail the request closed.
                    ownership_error <= 1'b1;
                    ownership_error_count <=
                        ownership_error_count + 1'b1;
                end else begin
                    // First stage: capture every derived product/count.  The
                    // ordinary cache, allocator, and ownership registers are
                    // updated together on the following commit cycle.
                    configured_q <= 1'b0;
                    cfg_commit_pending_q <= 1'b1;
                    cfg_accept_legal_q <= cfg_accept_legal;
                    cfg_epoch_q <= cfg_epoch;
                    cfg_ofm_w_q <= cfg_ofm_w;
                    cfg_ofm_h_q <= cfg_ofm_h;
                    cfg_tile_h_max_q <= cfg_tile_h_max;
                    cfg_k_total_q <= cfg_k_total;
                    cfg_layer_pixels_q <= cfg_selected_layer_pixels;
                    cfg_tile_pixels_q <= cfg_selected_tile_pixels;
                    cfg_pass_count_q <= cfg_selected_pass_count;
                    cfg_final_pass_q <= cfg_selected_final_pass;
                    cfg_final_lane_mask_q <=
                        cfg_selected_final_lane_mask;
                    cfg_first_tile_rows_q <=
                        cfg_selected_first_tile_rows;
                    cfg_first_tile_count_q <=
                        cfg_selected_first_tile_count;
                    cfg_overflow_q <= (CFG_PREVALIDATED != 0) ? 1'b0 :
                        (cfg_max_tile_entries_math > BANK_DEPTH);
                end
            end else if (cfg_commit_pending_q) begin
                // Second stage: publish one atomic configuration snapshot.
                cfg_commit_pending_q <= 1'b0;
                configured_q <= cfg_accept_legal_q;
                epoch_q <= cfg_epoch_q;
                ofm_w_q <= cfg_ofm_w_q;
                ofm_h_q <= cfg_ofm_h_q;
                tile_h_max_q <= cfg_tile_h_max_q;
                k_total_q <= cfg_k_total_q;
                layer_pixels_q <= cfg_layer_pixels_q;
                tile_pixels_q <= cfg_tile_pixels_q;
                pass_count_q <= cfg_pass_count_q;
                final_pass_q <= cfg_final_pass_q;
                final_lane_mask_q <= cfg_final_lane_mask_q;
                all_tiles_allocated_q <= 1'b0;
                bank_owned_q <= cfg_accept_legal_q ? 2'b01 : 2'b00;
                bank_filling_q <= cfg_accept_legal_q ? 2'b01 : 2'b00;
                bank_complete_q <= 2'b00;
                bank_epoch_q[0] <= cfg_epoch_q;
                bank_epoch_q[1] <= {EPOCH_W{1'b0}};
                bank_tile_q[0] <= {TILE_W{1'b0}};
                bank_tile_q[1] <= {TILE_W{1'b0}};
                bank_base_q[0] <= {PIXEL_W{1'b0}};
                bank_base_q[1] <= {PIXEL_W{1'b0}};
                bank_count_q[0] <= cfg_first_tile_count_q;
                bank_count_q[1] <= {COUNT_W{1'b0}};
                bank_ready_count_q[0] <= {READY_COUNT_W{1'b0}};
                bank_ready_count_q[1] <= {READY_COUNT_W{1'b0}};
                fill_bank_valid_q <= cfg_accept_legal_q;
                fill_bank_q <= 1'b0;
                fill_tile_is_layer_last_q <=
                    ({{(PIXEL_W-COUNT_W){1'b0}},
                       cfg_first_tile_count_q} == cfg_layer_pixels_q);
                fill_tile_rows_q <= cfg_first_tile_rows_q;
                fill_row_q <= 16'd0;
                fill_pass_q <= {PASS_W{1'b0}};
                fill_x_q <= 16'd0;
                fill_expected_pixel_q <= {PIXEL_W{1'b0}};
                fill_row_base_pixel_q <= {PIXEL_W{1'b0}};
                fill_entry_addr_q <= {COUNT_W{1'b0}};
                fill_row_base_addr_q <= {COUNT_W{1'b0}};
                next_tile_q <= {{(TILE_W-1){1'b0}}, 1'b1};
                next_tile_row_base_q <= cfg_first_tile_rows_q;
                next_tile_base_q <= cfg_first_tile_count_ext;
                next_tile_end_q <= cfg_next_tile_end_math;
                req_armed_q <= !fill_req;
                req_pending_q <= 1'b0;
                req_state_q <= REQ_IDLE;
                req_contract_ok_q <= 1'b0;
                req_future_known_q <= 1'b0;
                req_future_match_q <= 1'b0;
                replay_active_q <= 1'b0;
                rd_cmd_valid_q <= 1'b0;
                rd_valid_q <= 1'b0;
                out_valid_q <= 1'b0;
                release_reported_q <= 1'b0;
                config_error <= !cfg_accept_legal_q;
                order_error <= 1'b0;
                tag_error <= 1'b0;
                ownership_error <= 1'b0;
                overflow_error <= cfg_overflow_q;
                accepted_entries <= 32'd0;
                stored_entries <= 32'd0;
                completed_packets <= 32'd0;
                completed_pixels <= 32'd0;
                order_error_count <= 32'd0;
                tag_error_count <= 32'd0;
                ownership_error_count <= 32'd0;
                ownership_stall_cycles <= 32'd0;
                context_gap_cycles <= 32'd0;
                vector_backpressure_stall_cycles <= 32'd0;
                release_stall_cycles <= 32'd0;
            end else begin
                // Allocate only an explicitly free bank.  A bank released in
                // this cycle becomes visible to the allocator next cycle.
                if (configured_q && !fill_bank_valid_q &&
                    !all_tiles_allocated_q && next_tile_exists) begin
                    if (!bank_owned_q[0]) begin
                        fill_bank_valid_q <= 1'b1;
                        fill_bank_q <= 1'b0;
                        fill_tile_is_layer_last_q <=
                            (next_tile_end_q == layer_pixels_q);
                        fill_tile_rows_q <= next_tile_rows_math;
                        fill_row_q <= 16'd0;
                        fill_pass_q <= {PASS_W{1'b0}};
                        fill_x_q <= 16'd0;
                        fill_expected_pixel_q <=
                            next_tile_base_q;
                        fill_row_base_pixel_q <=
                            next_tile_base_q;
                        fill_entry_addr_q <= {COUNT_W{1'b0}};
                        fill_row_base_addr_q <= {COUNT_W{1'b0}};
                        bank_owned_q[0] <= 1'b1;
                        bank_filling_q[0] <= 1'b1;
                        bank_complete_q[0] <= 1'b0;
                        bank_epoch_q[0] <= epoch_q;
                        bank_tile_q[0] <= next_tile_q;
                        bank_base_q[0] <= next_tile_base_q;
                        bank_count_q[0] <= next_tile_count_math;
                        bank_ready_count_q[0] <= {READY_COUNT_W{1'b0}};
                        next_tile_q <= next_tile_q + 1'b1;
                        next_tile_row_base_q <=
                            next_tile_row_base_q + next_tile_rows_math;
                        next_tile_base_q <= next_tile_end_q;
                        next_tile_end_q <= following_tile_end_math;
                    end else if (!bank_owned_q[1]) begin
                        fill_bank_valid_q <= 1'b1;
                        fill_bank_q <= 1'b1;
                        fill_tile_is_layer_last_q <=
                            (next_tile_end_q == layer_pixels_q);
                        fill_tile_rows_q <= next_tile_rows_math;
                        fill_row_q <= 16'd0;
                        fill_pass_q <= {PASS_W{1'b0}};
                        fill_x_q <= 16'd0;
                        fill_expected_pixel_q <=
                            next_tile_base_q;
                        fill_row_base_pixel_q <=
                            next_tile_base_q;
                        fill_entry_addr_q <= {COUNT_W{1'b0}};
                        fill_row_base_addr_q <= {COUNT_W{1'b0}};
                        bank_owned_q[1] <= 1'b1;
                        bank_filling_q[1] <= 1'b1;
                        bank_complete_q[1] <= 1'b0;
                        bank_epoch_q[1] <= epoch_q;
                        bank_tile_q[1] <= next_tile_q;
                        bank_base_q[1] <= next_tile_base_q;
                        bank_count_q[1] <= next_tile_count_math;
                        bank_ready_count_q[1] <= {READY_COUNT_W{1'b0}};
                        next_tile_q <= next_tile_q + 1'b1;
                        next_tile_row_base_q <=
                            next_tile_row_base_q + next_tile_rows_math;
                        next_tile_base_q <= next_tile_end_q;
                        next_tile_end_q <= following_tile_end_math;
                    end
                end

                if (entry_fire) begin
                    accepted_entries <= accepted_entries + 1'b1;
                    if (!entry_epoch_ok) begin
                        tag_error <= 1'b1;
                        tag_error_count <= tag_error_count + 1'b1;
                    end
                    if (!entry_order_ok || !entry_lane_tag_ok ||
                        (entry_last != expected_layer_last)) begin
                        order_error <= 1'b1;
                        order_error_count <= order_error_count + 1'b1;
                    end
                    if (!entry_addr_ok) begin
                        overflow_error <= 1'b1;
                    end
                end

                if (entry_write_accept) begin
                    wr_commit_valid_q <= 1'b1;
                    // Reserve the final slot immediately.  This prevents an
                    // N+1 entry from being accepted while the final bundle is
                    // waiting for its physical RAM-write edge.
                    if (entry_finishes_tile) begin
                        fill_bank_valid_q <= 1'b0;
                    end else if (fill_x_q + 1'b1 == ofm_w_q) begin
                        fill_x_q <= 16'd0;
                        if (fill_pass_q + 1'b1 == pass_count_q) begin
                            fill_pass_q <= {PASS_W{1'b0}};
                            fill_row_q <= fill_row_q + 1'b1;
                            fill_expected_pixel_q <=
                                fill_expected_pixel_q + 1'b1;
                            fill_row_base_pixel_q <=
                                fill_expected_pixel_q + 1'b1;
                            fill_entry_addr_q <=
                                fill_entry_addr_q + 1'b1;
                            fill_row_base_addr_q <=
                                fill_entry_addr_q + 1'b1;
                        end else begin
                            fill_pass_q <= fill_pass_q + 1'b1;
                            fill_expected_pixel_q <=
                                fill_row_base_pixel_q;
                            fill_entry_addr_q <= fill_row_base_addr_q +
                                fill_pass_q + 1'b1;
                        end
                    end else begin
                        fill_x_q <= fill_x_q + 1'b1;
                        fill_expected_pixel_q <=
                            fill_expected_pixel_q + 1'b1;
                        fill_entry_addr_q <=
                            fill_entry_addr_q + pass_count_q;
                    end
                end

                if (fill_req && fill_req_ready) begin
                    fill_req_accept <= 1'b1;
                    req_armed_q <= 1'b0;
                    req_pending_q <= 1'b1;
                    req_state_q <= REQ_WAIT;
                    req_contract_ok_q <= req_input_static_valid;
                    req_future_known_q <= 1'b0;
                    req_future_match_q <= 1'b0;
                    req_tile_q <= fill_tile_index;
                    req_pass_q <= req_input_pass_math;
                    req_base_q <= fill_pixel_base;
                    req_end_q <= req_input_end_math[PIXEL_W-1:0];
                end

                if (req_future_classify) begin
                    req_future_known_q <= 1'b1;
                    req_future_match_q <= req_future_descriptor_match;
                end

                if (req_wait_invalid) begin
                    req_pending_q <= 1'b0;
                    req_state_q <= REQ_IDLE;
                    // Preserve the legacy request-contract diagnostic: bad
                    // geometry, range, or owner is one order error.
                    order_error <= 1'b1;
                    order_error_count <= order_error_count + 1'b1;
                end

                if (req_wait_capture) begin
                    req_bank_q <= req_bank_select;
                    req_local_pixel_q <=
                        req_selected_local_pixel_full[COUNT_W-1:0];
                    req_state_q <= REQ_ADDR;
                end

                if (req_state_q == REQ_ADDR) begin
                    req_pending_q <= 1'b0;
                    req_state_q <= REQ_IDLE;
                    replay_active_q <= 1'b1;
                    replay_bank_q <= req_bank_q;
                    replay_tile_q <= req_tile_q;
                    replay_pass_q <= req_pass_q;
                    replay_end_q <= req_end_q;
                    // Preload the first command on the same edge that
                    // publishes replay_active.  The following edge therefore
                    // issues the first URAM read exactly as before.
                    rd_cmd_valid_q <= 1'b1;
                    rd_cmd_bank_q <= req_bank_q;
                    rd_cmd_addr_q <=
                        req_start_addr_math[BANK_AW-1:0];
                    rd_cmd_epoch_q <= epoch_q;
                    rd_cmd_tile_q <= req_tile_q;
                    rd_cmd_pass_q <= req_pass_q;
                    rd_cmd_pixel_q <= req_base_q;
                    rd_cmd_lane_valid_q <=
                        (req_pass_q == final_pass_q) ?
                        final_lane_mask_q : {ROWS{1'b1}};
                    rd_cmd_last_q <=
                        (req_base_q + 1'b1 == req_end_q);
                    issue_pixel_q <= req_base_q + 1'b1;
                    issue_addr_q <=
                        req_start_addr_math[BANK_AW-1:0] + pass_count_q;
                end

                if (release_valid && !release_ready &&
                    (release_epoch != epoch_q) && !release_reported_q) begin
                    ownership_error <= 1'b1;
                    ownership_error_count <= ownership_error_count + 1'b1;
                    release_reported_q <= 1'b1;
                end

                if (release_fire) begin
                    release_reported_q <= 1'b0;
                    if (release_b0_safe) begin
                        bank_owned_q[0] <= 1'b0;
                        bank_complete_q[0] <= 1'b0;
                        bank_ready_count_q[0] <= {READY_COUNT_W{1'b0}};
                    end else begin
                        bank_owned_q[1] <= 1'b0;
                        bank_complete_q[1] <= 1'b0;
                        bank_ready_count_q[1] <= {READY_COUNT_W{1'b0}};
                    end
                end
            end
        end
    end
endmodule

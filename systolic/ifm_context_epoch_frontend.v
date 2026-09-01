`timescale 1ns / 1ps

// Converts the existing feeder/compute pulses into held, lossless lifecycle
// handshakes for the two-bank atomic IFM vector buffer.
//
// A context is allocated when its feeder starts, queued for compute as soon as
// the allocation succeeds, and may be selected before the packet is committed
// so producer/consumer overlap remains possible.  Storage is released only by
// an explicit tagged array-retirement event.  Context epochs are independent
// from the materialized-cache layer epoch and increment across layer starts.
module ifm_context_epoch_frontend #(
    parameter DATA_W = 144,
    parameter DEPTH = 1024,
    parameter AW = 10,
    parameter EPOCH_W = 8,
    parameter CTX_DEPTH = 2,
    parameter CTX_AW = 1,
    parameter COLLECTOR_SLOTS = 4,
    // Direct frontend/debug tests retain BRAM by default.  The formal tagged
    // hierarchy explicitly enables UltraRAM for its 144x1024 banks.
    parameter USE_URAM = 0
) (
    input  wire                         clk,
    input  wire                         rst,

    input  wire                         feeder_start,
    input  wire [15:0]                  context_expected,
    output wire                         feeder_start_ready,
    // Atomic sideband reservation for resources that share the IFM bank
    // lifecycle (the release weight preloader).  Allocation is not exposed
    // to either owner until both are ready on the same edge.
    input  wire                         context_alloc_sideband_ready,

    input  wire [DATA_W-1:0]            vector_data,
    input  wire                         vector_valid,
    output wire                         vector_ready,
    input  wire                         vector_packet_done,

    input  wire                         compute_start,
    input  wire                         core_ready,
    output wire                         core_start,
    output wire                         core_context_bank,
    output wire [EPOCH_W-1:0]           core_context_epoch,
    output wire [15:0]                  core_context_expected,

    // Stable allocation event shared with the inactive-weight preloader.
    // The epoch is emitted only after conflict resolution and the vector bank
    // has accepted the allocation, so downstream ownership never binds to a
    // speculative feeder_start epoch.
    output wire                         context_alloc_valid,
    output wire                         context_alloc_bank,
    output wire [EPOCH_W-1:0]           context_alloc_epoch,
    output wire [15:0]                  context_alloc_expected,

    output wire [DATA_W-1:0]            stream_data,
    output wire                         stream_valid,
    input  wire                         stream_ready,
    output wire                         stream_bank,
    output wire [EPOCH_W-1:0]           stream_epoch,
    output wire                         stream_last,

    input  wire                         array_retired_valid,
    input  wire                         array_retired_bank,
    input  wire [EPOCH_W-1:0]           array_retired_epoch,

    input  wire                         collector_done_valid,
    input  wire [EPOCH_W-1:0]           collector_done_epoch,

    output wire [1:0]                   bank_allocated,
    output wire [1:0]                   bank_committed,
    output wire [EPOCH_W-1:0]           bank0_epoch,
    output wire [EPOCH_W-1:0]           bank1_epoch,
    output wire [15:0]                  bank0_available,
    output wire [15:0]                  bank1_available,
    output wire                         reader_active,

    output wire [31:0]                  context_alloc_count,
    output reg  [31:0]                  input_issued_count,
    output reg  [31:0]                  array_retired_count,
    output reg  [31:0]                  collector_done_count,
    output wire [31:0]                  bank_ownership_stall_cycles,
    output wire [31:0]                  context_gap_cycles,
    output reg  [31:0]                  epoch_conflict_stall_cycles,
    output reg  [31:0]                  context_full_stall_cycles,
    output reg  [31:0]                  context_mismatch_count,

    output wire                         error_epoch,
    output wire                         error_overflow,
    output wire                         error_vector_protocol,
    output reg                          error_context_drop,
    output reg                          error_retire_mismatch,
    output reg                          error_collector_epoch
);
    localparam DESC_W = EPOCH_W + 1 + 16;

    wire buffer_alloc_ready;
    wire buffer_commit_ready;
    wire buffer_select_ready;
    wire buffer_release_ready;
    wire buffer_vector_ready;
    wire buffer_error_epoch;
    wire buffer_error_overflow;
    wire buffer_error_protocol;
    wire [15:0] bank0_produced;
    wire [15:0] bank1_produced;
    wire [15:0] bank0_consumed;
    wire [15:0] bank1_consumed;
    wire unused_reader_bank;
    wire unused_reader_context_done;
    wire [31:0] unused_release_count;

    reg preferred_bank_q;
    reg [EPOCH_W-1:0] next_epoch_q;
    reg alloc_pending_q;
    reg alloc_bank_q;
    reg [EPOCH_W-1:0] alloc_epoch_q;
    reg [15:0] alloc_expected_q;
    reg fill_active_q;
    reg fill_bank_q;
    reg [EPOCH_W-1:0] fill_epoch_q;
    reg [15:0] fill_expected_q;
    reg commit_pending_q;
    reg commit_bank_q;
    reg [EPOCH_W-1:0] commit_epoch_q;

    reg [DESC_W-1:0] context_mem [0:CTX_DEPTH-1];
    reg [CTX_AW-1:0] context_wr_ptr_q;
    reg [CTX_AW-1:0] context_rd_ptr_q;
    reg [CTX_AW:0] context_count_q;
    wire context_empty = context_count_q == 0;
    wire context_full = context_count_q == CTX_DEPTH;
    wire [DESC_W-1:0] context_head = context_mem[context_rd_ptr_q];
    wire [EPOCH_W-1:0] head_epoch = context_head[DESC_W-1:17];
    wire head_bank = context_head[16];
    wire [15:0] head_expected = context_head[15:0];

    reg compute_request_pending_q;
    reg release_pending_q;
    reg release_bank_q;
    reg [EPOCH_W-1:0] release_epoch_q;

    reg [COLLECTOR_SLOTS-1:0] collector_live_q;
    reg [EPOCH_W-1:0] collector_epoch_q [0:COLLECTOR_SLOTS-1];
    integer live_idx;
    integer free_idx;
    reg collector_epoch_live;
    reg collector_done_match;
    reg collector_slot_found;
    reg [$clog2(COLLECTOR_SLOTS)-1:0] collector_free_slot;

    always @(*) begin
        collector_epoch_live = 1'b0;
        collector_done_match = 1'b0;
        collector_slot_found = 1'b0;
        collector_free_slot = {$clog2(COLLECTOR_SLOTS){1'b0}};
        for (live_idx = 0; live_idx < COLLECTOR_SLOTS; live_idx = live_idx + 1) begin
            if (collector_live_q[live_idx] &&
                (collector_epoch_q[live_idx] == alloc_epoch_q))
                collector_epoch_live = 1'b1;
            if (collector_live_q[live_idx] && collector_done_valid &&
                (collector_epoch_q[live_idx] == collector_done_epoch))
                collector_done_match = 1'b1;
        end
        for (free_idx = COLLECTOR_SLOTS-1; free_idx >= 0; free_idx = free_idx - 1) begin
            if (!collector_live_q[free_idx]) begin
                collector_slot_found = 1'b1;
                collector_free_slot = free_idx[$clog2(COLLECTOR_SLOTS)-1:0];
            end
        end
    end

    wire allocated_epoch_conflict =
        (bank_allocated[0] && (bank0_epoch == alloc_epoch_q)) ||
        (bank_allocated[1] && (bank1_epoch == alloc_epoch_q));
    wire release_epoch_conflict = release_pending_q &&
        (release_epoch_q == alloc_epoch_q);
    wire alloc_epoch_conflict = collector_epoch_live ||
        allocated_epoch_conflict || release_epoch_conflict;

    assign feeder_start_ready = !alloc_pending_q && !context_full;
    wire alloc_valid = alloc_pending_q && !fill_active_q &&
        !alloc_epoch_conflict && context_alloc_sideband_ready;
    wire alloc_fire = alloc_valid && buffer_alloc_ready;

    wire vector_fire = vector_valid && vector_ready;
    assign vector_ready = fill_active_q && buffer_vector_ready;

    wire commit_valid = commit_pending_q;
    wire commit_fire = commit_valid && buffer_commit_ready;
    wire select_valid = compute_request_pending_q && !context_empty &&
        collector_slot_found && core_ready;
    wire select_fire = select_valid && buffer_select_ready;
    wire release_valid = release_pending_q;
    wire release_fire = release_valid && buffer_release_ready;

    // This is the single atomic context-admission handshake.  The buffer
    // reader is selected, the mesh observes start, the request descriptor is
    // retired, and a collector-live slot is allocated on the same edge.
    // Keeping core_start combinational with select_fire avoids the former
    // one-cycle pulse delay, during which downstream queue readiness could
    // change after it had already been sampled.
    assign core_start = select_fire;
    assign core_context_bank = head_bank;
    assign core_context_epoch = head_epoch;
    assign core_context_expected = head_expected;
    assign context_alloc_valid = alloc_fire;
    assign context_alloc_bank = alloc_bank_q;
    assign context_alloc_epoch = alloc_epoch_q;
    assign context_alloc_expected = alloc_expected_q;

    // Legal held-valid requests remain asserted until their corresponding
    // ready signal is observed by the epoch buffer.
    ifm_vector_epoch_buffer #(
        .DATA_W(DATA_W),
        .DEPTH(DEPTH),
        .AW(AW),
        .EPOCH_W(EPOCH_W),
        .USE_URAM(USE_URAM)
    ) u_epoch_buffer (
        .clk(clk),
        .rst(rst),
        .alloc_valid(alloc_valid),
        .alloc_bank(alloc_bank_q),
        .alloc_epoch(alloc_epoch_q),
        .alloc_expected(alloc_expected_q),
        .alloc_ready(buffer_alloc_ready),
        .wr_valid(vector_valid && fill_active_q),
        .wr_bank(fill_bank_q),
        .wr_epoch(fill_epoch_q),
        .wr_data(vector_data),
        .wr_ready(buffer_vector_ready),
        .commit_valid(commit_valid),
        .commit_bank(commit_bank_q),
        .commit_epoch(commit_epoch_q),
        .commit_ready(buffer_commit_ready),
        .select_valid(select_valid),
        .select_bank(head_bank),
        .select_epoch(head_epoch),
        .select_ready(buffer_select_ready),
        .rd_data(stream_data),
        .rd_bank(stream_bank),
        .rd_epoch(stream_epoch),
        .rd_valid(stream_valid),
        .rd_last(stream_last),
        .rd_ready(stream_ready),
        .release_valid(release_valid),
        .release_bank(release_bank_q),
        .release_epoch(release_epoch_q),
        .release_ready(buffer_release_ready),
        .bank_allocated(bank_allocated),
        .bank_committed(bank_committed),
        .bank0_epoch(bank0_epoch),
        .bank1_epoch(bank1_epoch),
        .bank0_produced(bank0_produced),
        .bank1_produced(bank1_produced),
        .bank0_consumed(bank0_consumed),
        .bank1_consumed(bank1_consumed),
        .bank0_available(bank0_available),
        .bank1_available(bank1_available),
        .reader_active(reader_active),
        .reader_bank(unused_reader_bank),
        .reader_context_done(unused_reader_context_done),
        .epoch_alloc_count(context_alloc_count),
        .bank_release_count(unused_release_count),
        .bank_ownership_stall_cycles(bank_ownership_stall_cycles),
        .context_gap_cycles(context_gap_cycles),
        .error_epoch(buffer_error_epoch),
        .error_overflow(buffer_error_overflow),
        .error_protocol(buffer_error_protocol)
    );

    assign error_epoch = buffer_error_epoch || error_collector_epoch;
    assign error_overflow = buffer_error_overflow || error_context_drop;
    assign error_vector_protocol = buffer_error_protocol ||
        error_retire_mismatch;

    wire final_vector_now = vector_packet_done && fill_active_q;
    wire [15:0] fill_produced_now = fill_bank_q ?
        bank1_produced : bank0_produced;
    wire packet_count_matches =
        (fill_produced_now + (vector_fire ? 16'd1 : 16'd0)) ==
        fill_expected_q;

    integer reset_idx;
    always @(posedge clk) begin
        if (rst) begin
            preferred_bank_q <= 1'b0;
            next_epoch_q <= {{(EPOCH_W-1){1'b0}}, 1'b1};
            alloc_pending_q <= 1'b0;
            alloc_bank_q <= 1'b0;
            alloc_epoch_q <= {EPOCH_W{1'b0}};
            alloc_expected_q <= 16'd0;
            fill_active_q <= 1'b0;
            fill_bank_q <= 1'b0;
            fill_epoch_q <= {EPOCH_W{1'b0}};
            fill_expected_q <= 16'd0;
            commit_pending_q <= 1'b0;
            commit_bank_q <= 1'b0;
            commit_epoch_q <= {EPOCH_W{1'b0}};
            context_wr_ptr_q <= {CTX_AW{1'b0}};
            context_rd_ptr_q <= {CTX_AW{1'b0}};
            context_count_q <= {(CTX_AW+1){1'b0}};
            compute_request_pending_q <= 1'b0;
            release_pending_q <= 1'b0;
            release_bank_q <= 1'b0;
            release_epoch_q <= {EPOCH_W{1'b0}};
            collector_live_q <= {COLLECTOR_SLOTS{1'b0}};
            for (reset_idx = 0; reset_idx < COLLECTOR_SLOTS; reset_idx = reset_idx + 1)
                collector_epoch_q[reset_idx] <= {EPOCH_W{1'b0}};
            input_issued_count <= 32'd0;
            array_retired_count <= 32'd0;
            collector_done_count <= 32'd0;
            epoch_conflict_stall_cycles <= 32'd0;
            context_full_stall_cycles <= 32'd0;
            context_mismatch_count <= 32'd0;
            error_context_drop <= 1'b0;
            error_retire_mismatch <= 1'b0;
            error_collector_epoch <= 1'b0;
        end else begin
            if (feeder_start) begin
                if (feeder_start_ready) begin
                    alloc_pending_q <= 1'b1;
                    if (!bank_allocated[preferred_bank_q])
                        alloc_bank_q <= preferred_bank_q;
                    else if (!bank_allocated[~preferred_bank_q])
                        alloc_bank_q <= ~preferred_bank_q;
                    else
                        // Both banks are live: wait on the oldest preferred
                        // bank instead of accidentally targeting the newer
                        // context, which retires later.
                        alloc_bank_q <= preferred_bank_q;
                    alloc_epoch_q <= next_epoch_q;
                    alloc_expected_q <= context_expected;
                end else begin
                    error_context_drop <= 1'b1;
                    context_full_stall_cycles <=
                        context_full_stall_cycles + 1'b1;
                end
            end

            if (alloc_pending_q && alloc_epoch_conflict) begin
                alloc_epoch_q <= alloc_epoch_q + 1'b1;
                epoch_conflict_stall_cycles <=
                    epoch_conflict_stall_cycles + 1'b1;
            end

            if (alloc_fire) begin
                alloc_pending_q <= 1'b0;
                fill_active_q <= 1'b1;
                fill_bank_q <= alloc_bank_q;
                fill_epoch_q <= alloc_epoch_q;
                fill_expected_q <= alloc_expected_q;
                preferred_bank_q <= ~alloc_bank_q;
                next_epoch_q <= alloc_epoch_q + 1'b1;
                context_mem[context_wr_ptr_q] <= {
                    alloc_epoch_q, alloc_bank_q, alloc_expected_q
                };
                context_wr_ptr_q <= context_wr_ptr_q + 1'b1;
            end

            if (vector_packet_done) begin
                if (fill_active_q) begin
                    fill_active_q <= 1'b0;
                    commit_pending_q <= 1'b1;
                    commit_bank_q <= fill_bank_q;
                    commit_epoch_q <= fill_epoch_q;
                    if (!packet_count_matches) begin
                        error_context_drop <= 1'b1;
                        context_mismatch_count <=
                            context_mismatch_count + 1'b1;
                    end
                end else begin
                    error_context_drop <= 1'b1;
                    context_mismatch_count <=
                        context_mismatch_count + 1'b1;
                end
            end

            if (commit_fire)
                commit_pending_q <= 1'b0;

            if (compute_start) begin
                if (!compute_request_pending_q)
                    compute_request_pending_q <= 1'b1;
                else begin
                    error_context_drop <= 1'b1;
                    context_full_stall_cycles <=
                        context_full_stall_cycles + 1'b1;
                end
            end

            if (select_fire) begin
                compute_request_pending_q <= 1'b0;
                context_rd_ptr_q <= context_rd_ptr_q + 1'b1;
                collector_live_q[collector_free_slot] <= 1'b1;
                collector_epoch_q[collector_free_slot] <= head_epoch;
            end

            case ({alloc_fire, select_fire})
                2'b10: context_count_q <= context_count_q + 1'b1;
                2'b01: context_count_q <= context_count_q - 1'b1;
                default: context_count_q <= context_count_q;
            endcase

            if (stream_valid && stream_ready && stream_last)
                input_issued_count <= input_issued_count + 1'b1;

            if (array_retired_valid) begin
                array_retired_count <= array_retired_count + 1'b1;
                // A new retirement may replace an old release on the exact
                // cycle the old bank handshake completes.
                if (!release_pending_q || release_fire) begin
                    release_pending_q <= 1'b1;
                    release_bank_q <= array_retired_bank;
                    release_epoch_q <= array_retired_epoch;
                end else begin
                    error_retire_mismatch <= 1'b1;
                    context_mismatch_count <=
                        context_mismatch_count + 1'b1;
                end
            end
            if (release_fire && !array_retired_valid)
                release_pending_q <= 1'b0;

            if (collector_done_valid) begin
                collector_done_count <= collector_done_count + 1'b1;
                if (!collector_done_match) begin
                    error_collector_epoch <= 1'b1;
                    context_mismatch_count <=
                        context_mismatch_count + 1'b1;
                end
                for (live_idx = 0; live_idx < COLLECTOR_SLOTS; live_idx = live_idx + 1) begin
                    if (collector_live_q[live_idx] &&
                        (collector_epoch_q[live_idx] == collector_done_epoch))
                        collector_live_q[live_idx] <= 1'b0;
                end
            end
        end
    end
endmodule

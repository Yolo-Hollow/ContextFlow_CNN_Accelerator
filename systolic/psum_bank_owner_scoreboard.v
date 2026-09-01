`timescale 1ns / 1ps

// Ownership and committed-credit scoreboard for the two partial-PSUM banks.
//
// This block intentionally contains no data RAM.  A write handshake means the
// corresponding RAM address has completed and is therefore committed for a
// later read.  A read-request handshake consumes that address credit; the
// matching read-return retires one outstanding RAM response.  The bank remains
// owned until both sides of the context have finished:
//
//   alloc -> per-address writes -> commit (writer collector_done)
//         -> per-address read request/return -> release
//
// A producer may write one address while the consumer reads a different
// address in the same bank.  Same-bank/same-address access is fail-stop because
// the inferred dual-port RAM read-during-write value is device-mode dependent.
// All channels use valid/ready.  Holding a valid request while ready is low is
// legal and a single malformed held request is counted only once.
module psum_bank_owner_scoreboard #(
    parameter DEPTH = 1024,
    parameter AW = 10,
    parameter EPOCH_W = 8,
    parameter CONTEXT_W = 16
) (
    input  wire                     clk,
    input  wire                     rst,

    input  wire                     alloc_valid,
    input  wire                     alloc_bank,
    input  wire [EPOCH_W-1:0]       alloc_epoch,
    input  wire [CONTEXT_W-1:0]     alloc_context,
    input  wire [AW:0]              alloc_expected,
    output wire                     alloc_ready,

    // Each accepted write creates exactly one committed address credit.
    input  wire                     wr_valid,
    input  wire                     wr_bank,
    input  wire [EPOCH_W-1:0]       wr_epoch,
    input  wire [CONTEXT_W-1:0]     wr_context,
    input  wire [AW-1:0]            wr_addr,
    output wire                     wr_ready,

    // commit is the writer's collector_done event.  It is backpressured until
    // every expected address has been committed.
    input  wire                     commit_valid,
    input  wire                     commit_bank,
    input  wire [EPOCH_W-1:0]       commit_epoch,
    input  wire [CONTEXT_W-1:0]     commit_context,
    output wire                     commit_ready,

    // A read request consumes a committed credit.  rd_req_last is checked
    // against the expected address count but does not control correctness.
    input  wire                     rd_req_valid,
    input  wire                     rd_req_bank,
    input  wire [EPOCH_W-1:0]       rd_req_epoch,
    input  wire [CONTEXT_W-1:0]     rd_req_context,
    input  wire [AW-1:0]            rd_req_addr,
    input  wire                     rd_req_last,
    output wire                     rd_req_ready,

    // The RAM/array return carries the owner tag and last marker.  Returns are
    // ordered, so only a per-bank outstanding count is required here.
    input  wire                     rd_return_valid,
    input  wire                     rd_return_bank,
    input  wire [EPOCH_W-1:0]       rd_return_epoch,
    input  wire [CONTEXT_W-1:0]     rd_return_context,
    input  wire                     rd_return_last,
    output wire                     rd_return_ready,

    input  wire                     release_valid,
    input  wire                     release_bank,
    input  wire [EPOCH_W-1:0]       release_epoch,
    input  wire [CONTEXT_W-1:0]     release_context,
    output wire                     release_ready,

    output wire [1:0]               bank_allocated,
    output wire [1:0]               bank_writer_done,
    output wire [1:0]               bank_reader_done,
    output wire [1:0]               bank_reusable,
    output wire [EPOCH_W-1:0]       bank0_owner_epoch,
    output wire [EPOCH_W-1:0]       bank1_owner_epoch,
    output wire [CONTEXT_W-1:0]     bank0_owner_context,
    output wire [CONTEXT_W-1:0]     bank1_owner_context,
    output wire [AW:0]              bank0_committed_credits,
    output wire [AW:0]              bank1_committed_credits,
    output wire [AW:0]              bank0_outstanding,
    output wire [AW:0]              bank1_outstanding,

    output reg  [31:0]              alloc_count,
    output reg  [31:0]              commit_count,
    output reg  [31:0]              release_count,
    output reg  [31:0]              ownership_stall_cycles,
    output reg  [31:0]              underflow_count,
    output reg  [31:0]              overwrite_count,
    output reg  [31:0]              epoch_mismatch_count,
    output reg  [31:0]              context_mismatch_count,
    output reg  [31:0]              same_address_conflict_count,

    output reg                      error_underflow,
    output reg                      error_overwrite,
    output reg                      error_epoch_mismatch,
    output reg                      error_context_mismatch,
    output reg                      error_same_address_conflict,
    output wire                     fail_stop
);
    initial begin
        if (DEPTH < 1)
            $error("psum_bank_owner_scoreboard DEPTH must be positive");
        if (DEPTH > (1 << AW))
            $error("psum_bank_owner_scoreboard DEPTH exceeds address width");
    end

    reg [1:0] allocated_q;
    reg [1:0] writer_done_q;
    reg [1:0] reader_done_q;
    reg [EPOCH_W-1:0] epoch0_q;
    reg [EPOCH_W-1:0] epoch1_q;
    reg [CONTEXT_W-1:0] context0_q;
    reg [CONTEXT_W-1:0] context1_q;
    reg [AW:0] expected0_q;
    reg [AW:0] expected1_q;
    reg [AW:0] written_count0_q;
    reg [AW:0] written_count1_q;
    reg [AW:0] rd_issue_count0_q;
    reg [AW:0] rd_issue_count1_q;
    reg [AW:0] rd_return_count0_q;
    reg [AW:0] rd_return_count1_q;

    // Partial-PSUM packets are produced and consumed in monotonically
    // increasing pixel-address order.  Keeping the three high-watermarks per
    // bank makes that contract explicit and avoids four DEPTH-bit ownership
    // vectors (4096 resettable FFs at the release depth).
    wire [AW:0] committed_count0 = written_count0_q - rd_issue_count0_q;
    wire [AW:0] committed_count1 = written_count1_q - rd_issue_count1_q;
    wire [AW:0] outstanding0 = rd_issue_count0_q - rd_return_count0_q;
    wire [AW:0] outstanding1 = rd_issue_count1_q - rd_return_count1_q;

    wire wr_addr_valid = ({1'b0, wr_addr} < DEPTH);

    wire [EPOCH_W-1:0] wr_owner_epoch = wr_bank ? epoch1_q : epoch0_q;
    wire [CONTEXT_W-1:0] wr_owner_context =
        wr_bank ? context1_q : context0_q;
    wire wr_allocated = allocated_q[wr_bank];
    wire wr_epoch_ok = wr_allocated && (wr_epoch == wr_owner_epoch);
    wire wr_context_ok = wr_allocated && (wr_context == wr_owner_context);
    wire wr_identity_ok = wr_epoch_ok && wr_context_ok;
    wire [AW:0] wr_written = wr_bank ? written_count1_q : written_count0_q;
    wire [AW:0] wr_expected = wr_bank ? expected1_q : expected0_q;
    wire wr_addr_in_order = ({1'b0, wr_addr} == wr_written);

    wire [EPOCH_W-1:0] commit_owner_epoch =
        commit_bank ? epoch1_q : epoch0_q;
    wire [CONTEXT_W-1:0] commit_owner_context =
        commit_bank ? context1_q : context0_q;
    wire [AW:0] commit_expected =
        commit_bank ? expected1_q : expected0_q;
    wire [AW:0] commit_written =
        commit_bank ? written_count1_q : written_count0_q;
    wire commit_allocated = allocated_q[commit_bank];
    wire commit_epoch_ok = commit_allocated &&
        (commit_epoch == commit_owner_epoch);
    wire commit_context_ok = commit_allocated &&
        (commit_context == commit_owner_context);
    wire commit_identity_ok = commit_epoch_ok && commit_context_ok;

    // Build the read-ready decision independently at two constant-bank
    // boundaries.  This keeps the bank select out of the identity, address,
    // ordering, credit, expected-count, and fail-stop cones; rd_req_bank only
    // selects between the two complete results below.  KEEP protects those
    // timing boundaries without constraining the state elements or their
    // placement.
    wire rd_bank0_epoch_ok = allocated_q[0] &&
        (rd_req_epoch == epoch0_q);
    wire rd_bank1_epoch_ok = allocated_q[1] &&
        (rd_req_epoch == epoch1_q);
    wire rd_bank0_context_ok = allocated_q[0] &&
        (rd_req_context == context0_q);
    wire rd_bank1_context_ok = allocated_q[1] &&
        (rd_req_context == context1_q);
    wire rd_bank0_identity_ok = rd_bank0_epoch_ok && rd_bank0_context_ok;
    wire rd_bank1_identity_ok = rd_bank1_epoch_ok && rd_bank1_context_ok;
    wire rd_bank0_addr_valid = ({1'b0, rd_req_addr} < DEPTH);
    wire rd_bank1_addr_valid = ({1'b0, rd_req_addr} < DEPTH);
    wire rd_bank0_addr_in_order =
        ({1'b0, rd_req_addr} == rd_issue_count0_q);
    wire rd_bank1_addr_in_order =
        ({1'b0, rd_req_addr} == rd_issue_count1_q);
    wire rd_bank0_has_credit = rd_issue_count0_q < written_count0_q;
    wire rd_bank1_has_credit = rd_issue_count1_q < written_count1_q;
    wire rd_bank0_expected_ok = rd_issue_count0_q < expected0_q;
    wire rd_bank1_expected_ok = rd_issue_count1_q < expected1_q;
    wire rd_bank0_fail_stop_ok = !fail_stop;
    wire rd_bank1_fail_stop_ok = !fail_stop;

    (* KEEP = "TRUE" *) wire rd_bank0_ready;
    (* KEEP = "TRUE" *) wire rd_bank1_ready;
    assign rd_bank0_ready = rd_bank0_fail_stop_ok &&
        rd_bank0_identity_ok && rd_bank0_addr_valid &&
        rd_bank0_addr_in_order && rd_bank0_has_credit &&
        rd_bank0_expected_ok;
    assign rd_bank1_ready = rd_bank1_fail_stop_ok &&
        rd_bank1_identity_ok && rd_bank1_addr_valid &&
        rd_bank1_addr_in_order && rd_bank1_has_credit &&
        rd_bank1_expected_ok;

    // Selected aliases are retained for diagnostics and last-marker checking;
    // they are deliberately not used to form rd_req_ready.
    wire [AW:0] rd_expected = rd_req_bank ? expected1_q : expected0_q;
    wire [AW:0] rd_issued =
        rd_req_bank ? rd_issue_count1_q : rd_issue_count0_q;
    wire rd_epoch_ok = rd_req_bank ?
        rd_bank1_epoch_ok : rd_bank0_epoch_ok;
    wire rd_context_ok = rd_req_bank ?
        rd_bank1_context_ok : rd_bank0_context_ok;
    wire rd_identity_ok = rd_req_bank ?
        rd_bank1_identity_ok : rd_bank0_identity_ok;
    wire rd_addr_valid = rd_req_bank ?
        rd_bank1_addr_valid : rd_bank0_addr_valid;
    wire rd_addr_in_order = rd_req_bank ?
        rd_bank1_addr_in_order : rd_bank0_addr_in_order;
    wire rd_has_credit = rd_req_bank ?
        rd_bank1_has_credit : rd_bank0_has_credit;
    wire rd_should_be_last = (rd_issued + 1'b1 == rd_expected);

    wire [EPOCH_W-1:0] return_owner_epoch =
        rd_return_bank ? epoch1_q : epoch0_q;
    wire [CONTEXT_W-1:0] return_owner_context =
        rd_return_bank ? context1_q : context0_q;
    wire [AW:0] return_expected =
        rd_return_bank ? expected1_q : expected0_q;
    wire [AW:0] returned_count =
        rd_return_bank ? rd_return_count1_q : rd_return_count0_q;
    wire [AW:0] return_outstanding =
        rd_return_bank ? outstanding1 : outstanding0;
    wire return_allocated = allocated_q[rd_return_bank];
    wire return_epoch_ok = return_allocated &&
        (rd_return_epoch == return_owner_epoch);
    wire return_context_ok = return_allocated &&
        (rd_return_context == return_owner_context);
    wire return_identity_ok = return_epoch_ok && return_context_ok;
    wire return_should_be_last =
        (returned_count + 1'b1 == return_expected);

    wire [EPOCH_W-1:0] release_owner_epoch =
        release_bank ? epoch1_q : epoch0_q;
    wire [CONTEXT_W-1:0] release_owner_context =
        release_bank ? context1_q : context0_q;
    wire release_allocated = allocated_q[release_bank];
    wire release_epoch_ok = release_allocated &&
        (release_epoch == release_owner_epoch);
    wire release_context_ok = release_allocated &&
        (release_context == release_owner_context);
    wire release_identity_ok = release_epoch_ok && release_context_ok;

    // Keep same-address intent as a fail-stop diagnostic, but do not use the
    // cross-channel comparison to qualify either channel's legal handshake.
    // For one bank, a legal write has wr_addr == written_count while a legal
    // read has rd_req_addr == rd_issue_count < written_count.  Therefore two
    // legal simultaneous accesses satisfy rd_req_addr < wr_addr and cannot
    // collide.  If the intent addresses are equal, at least one side is
    // malformed and that side's own ready predicate prevents a physical RAM
    // access; the other legal side is allowed to make progress on this edge.
    wire same_address_conflict = wr_valid && rd_req_valid &&
        wr_identity_ok && rd_identity_ok && wr_addr_valid && rd_addr_valid &&
        (wr_bank == rd_req_bank) && (wr_addr == rd_req_addr);

    assign alloc_ready = !fail_stop && !allocated_q[alloc_bank] &&
        (alloc_expected != 0) && (alloc_expected <= DEPTH);
    assign wr_ready = !fail_stop && wr_identity_ok && wr_addr_valid &&
        wr_addr_in_order && (wr_written < wr_expected) &&
        !writer_done_q[wr_bank];
    assign commit_ready = !fail_stop && commit_identity_ok &&
        !writer_done_q[commit_bank] && (commit_written == commit_expected);
    assign rd_req_ready = rd_req_bank ? rd_bank1_ready : rd_bank0_ready;
    assign rd_return_ready = !fail_stop && return_identity_ok &&
        (return_outstanding != 0) &&
        (returned_count < return_expected);
    assign release_ready = !fail_stop && release_identity_ok &&
        writer_done_q[release_bank] && reader_done_q[release_bank] &&
        ((release_bank ? outstanding1 : outstanding0) == 0);

    wire alloc_fire = alloc_valid && alloc_ready;
    wire wr_fire = wr_valid && wr_ready;
    wire commit_fire = commit_valid && commit_ready;
    wire rd_fire = rd_req_valid && rd_req_ready;
    wire return_fire = rd_return_valid && rd_return_ready;
    wire release_fire = release_valid && release_ready;

    wire [4:0] epoch_fault_mask = {
        release_valid && !release_epoch_ok,
        rd_return_valid && !return_epoch_ok,
        rd_req_valid && !rd_epoch_ok,
        commit_valid && !commit_epoch_ok,
        wr_valid && !wr_epoch_ok
    };
    wire [6:0] context_fault_mask = {
        return_fire && (rd_return_last != return_should_be_last),
        rd_fire && (rd_req_last != rd_should_be_last),
        release_valid && !release_context_ok,
        rd_return_valid && !return_context_ok,
        rd_req_valid && !rd_context_ok,
        commit_valid && !commit_context_ok,
        wr_valid && !wr_context_ok
    };
    wire [1:0] underflow_fault_mask = {
        rd_return_valid && return_identity_ok &&
            ((return_outstanding == 0) ||
             (returned_count >= return_expected)),
        rd_req_valid && rd_identity_ok &&
            (!rd_addr_valid || !rd_addr_in_order || !rd_has_credit ||
             (rd_issued >= rd_expected)) && !same_address_conflict
    };
    wire overwrite_fault = wr_valid && wr_identity_ok &&
        (!wr_addr_valid || !wr_addr_in_order ||
         (wr_written >= wr_expected) || writer_done_q[wr_bank]) &&
        !same_address_conflict;

    reg [4:0] epoch_fault_active_q;
    reg [6:0] context_fault_active_q;
    reg [1:0] underflow_fault_active_q;
    reg overwrite_fault_active_q;
    reg collision_fault_active_q;

    function [2:0] popcount5;
        input [4:0] value;
        integer i;
        begin
            popcount5 = 0;
            for (i = 0; i < 5; i = i + 1)
                popcount5 = popcount5 + value[i];
        end
    endfunction

    function [2:0] popcount7;
        input [6:0] value;
        integer i;
        begin
            popcount7 = 0;
            for (i = 0; i < 7; i = i + 1)
                popcount7 = popcount7 + value[i];
        end
    endfunction

    function [1:0] popcount2;
        input [1:0] value;
        begin
            popcount2 = value[0] + value[1];
        end
    endfunction

    assign bank_allocated = allocated_q;
    assign bank_writer_done = writer_done_q;
    assign bank_reader_done = reader_done_q;
    assign bank_reusable[0] = allocated_q[0] && writer_done_q[0] &&
        reader_done_q[0] && (outstanding0 == 0);
    assign bank_reusable[1] = allocated_q[1] && writer_done_q[1] &&
        reader_done_q[1] && (outstanding1 == 0);
    assign bank0_owner_epoch = epoch0_q;
    assign bank1_owner_epoch = epoch1_q;
    assign bank0_owner_context = context0_q;
    assign bank1_owner_context = context1_q;
    assign bank0_committed_credits = committed_count0;
    assign bank1_committed_credits = committed_count1;
    assign bank0_outstanding = outstanding0;
    assign bank1_outstanding = outstanding1;
    assign fail_stop = error_underflow || error_overwrite ||
        error_epoch_mismatch || error_context_mismatch ||
        error_same_address_conflict;

    always @(posedge clk) begin
        if (rst) begin
            allocated_q <= 2'b00;
            writer_done_q <= 2'b00;
            reader_done_q <= 2'b00;
            epoch0_q <= {EPOCH_W{1'b0}};
            epoch1_q <= {EPOCH_W{1'b0}};
            context0_q <= {CONTEXT_W{1'b0}};
            context1_q <= {CONTEXT_W{1'b0}};
            expected0_q <= {(AW+1){1'b0}};
            expected1_q <= {(AW+1){1'b0}};
            written_count0_q <= {(AW+1){1'b0}};
            written_count1_q <= {(AW+1){1'b0}};
            rd_issue_count0_q <= {(AW+1){1'b0}};
            rd_issue_count1_q <= {(AW+1){1'b0}};
            rd_return_count0_q <= {(AW+1){1'b0}};
            rd_return_count1_q <= {(AW+1){1'b0}};
            alloc_count <= 32'd0;
            commit_count <= 32'd0;
            release_count <= 32'd0;
            ownership_stall_cycles <= 32'd0;
            underflow_count <= 32'd0;
            overwrite_count <= 32'd0;
            epoch_mismatch_count <= 32'd0;
            context_mismatch_count <= 32'd0;
            same_address_conflict_count <= 32'd0;
            error_underflow <= 1'b0;
            error_overwrite <= 1'b0;
            error_epoch_mismatch <= 1'b0;
            error_context_mismatch <= 1'b0;
            error_same_address_conflict <= 1'b0;
            epoch_fault_active_q <= 5'd0;
            context_fault_active_q <= 7'd0;
            underflow_fault_active_q <= 2'd0;
            overwrite_fault_active_q <= 1'b0;
            collision_fault_active_q <= 1'b0;
        end else begin
            epoch_fault_active_q <= epoch_fault_mask;
            context_fault_active_q <= context_fault_mask;
            underflow_fault_active_q <= underflow_fault_mask;
            overwrite_fault_active_q <= overwrite_fault;
            collision_fault_active_q <= same_address_conflict;

            if (|epoch_fault_mask) begin
                error_epoch_mismatch <= 1'b1;
                epoch_mismatch_count <= epoch_mismatch_count +
                    popcount5(epoch_fault_mask & ~epoch_fault_active_q);
            end
            if (|context_fault_mask) begin
                error_context_mismatch <= 1'b1;
                context_mismatch_count <= context_mismatch_count +
                    popcount7(context_fault_mask & ~context_fault_active_q);
            end
            if (|underflow_fault_mask) begin
                error_underflow <= 1'b1;
                underflow_count <= underflow_count +
                    popcount2(underflow_fault_mask &
                              ~underflow_fault_active_q);
            end
            if (overwrite_fault) begin
                error_overwrite <= 1'b1;
                if (!overwrite_fault_active_q)
                    overwrite_count <= overwrite_count + 1'b1;
            end
            if (same_address_conflict) begin
                error_same_address_conflict <= 1'b1;
                if (!collision_fault_active_q)
                    same_address_conflict_count <=
                        same_address_conflict_count + 1'b1;
            end

            if (alloc_valid && !alloc_ready && allocated_q[alloc_bank])
                ownership_stall_cycles <= ownership_stall_cycles + 1'b1;

            if (alloc_fire) begin
                alloc_count <= alloc_count + 1'b1;
                allocated_q[alloc_bank] <= 1'b1;
                writer_done_q[alloc_bank] <= 1'b0;
                reader_done_q[alloc_bank] <= 1'b0;
                if (alloc_bank) begin
                    epoch1_q <= alloc_epoch;
                    context1_q <= alloc_context;
                    expected1_q <= alloc_expected;
                    written_count1_q <= {(AW+1){1'b0}};
                    rd_issue_count1_q <= {(AW+1){1'b0}};
                    rd_return_count1_q <= {(AW+1){1'b0}};
                end else begin
                    epoch0_q <= alloc_epoch;
                    context0_q <= alloc_context;
                    expected0_q <= alloc_expected;
                    written_count0_q <= {(AW+1){1'b0}};
                    rd_issue_count0_q <= {(AW+1){1'b0}};
                    rd_return_count0_q <= {(AW+1){1'b0}};
                end
            end

            if (wr_fire) begin
                if (wr_bank) begin
                    written_count1_q <= written_count1_q + 1'b1;
                end else begin
                    written_count0_q <= written_count0_q + 1'b1;
                end
            end

            if (commit_fire) begin
                writer_done_q[commit_bank] <= 1'b1;
                commit_count <= commit_count + 1'b1;
            end

            if (rd_fire) begin
                if (rd_req_bank) begin
                    rd_issue_count1_q <= rd_issue_count1_q + 1'b1;
                end else begin
                    rd_issue_count0_q <= rd_issue_count0_q + 1'b1;
                end
            end

            if (return_fire) begin
                if (rd_return_bank)
                    rd_return_count1_q <= rd_return_count1_q + 1'b1;
                else
                    rd_return_count0_q <= rd_return_count0_q + 1'b1;
                if (rd_return_last && return_should_be_last)
                    reader_done_q[rd_return_bank] <= 1'b1;
            end

            if (release_fire) begin
                release_count <= release_count + 1'b1;
                allocated_q[release_bank] <= 1'b0;
                writer_done_q[release_bank] <= 1'b0;
                reader_done_q[release_bank] <= 1'b0;
                if (release_bank) begin
                    written_count1_q <= {(AW+1){1'b0}};
                    rd_issue_count1_q <= {(AW+1){1'b0}};
                    rd_return_count1_q <= {(AW+1){1'b0}};
                end else begin
                    written_count0_q <= {(AW+1){1'b0}};
                    rd_issue_count0_q <= {(AW+1){1'b0}};
                    rd_return_count0_q <= {(AW+1){1'b0}};
                end
            end
        end
    end
endmodule

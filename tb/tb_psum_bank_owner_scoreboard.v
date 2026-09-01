`timescale 1ns / 1ps

module tb_psum_bank_owner_scoreboard;
    localparam DEPTH = 8;
    localparam AW = 3;
    localparam EPOCH_W = 8;
    localparam CONTEXT_W = 12;

    reg clk = 1'b0;
    reg rst = 1'b1;

    reg alloc_valid = 1'b0;
    reg alloc_bank = 1'b0;
    reg [EPOCH_W-1:0] alloc_epoch = 0;
    reg [CONTEXT_W-1:0] alloc_context = 0;
    reg [AW:0] alloc_expected = 0;
    wire alloc_ready;

    reg wr_valid = 1'b0;
    reg wr_bank = 1'b0;
    reg [EPOCH_W-1:0] wr_epoch = 0;
    reg [CONTEXT_W-1:0] wr_context = 0;
    reg [AW-1:0] wr_addr = 0;
    wire wr_ready;

    reg commit_valid = 1'b0;
    reg commit_bank = 1'b0;
    reg [EPOCH_W-1:0] commit_epoch = 0;
    reg [CONTEXT_W-1:0] commit_context = 0;
    wire commit_ready;

    reg rd_req_valid = 1'b0;
    reg rd_req_bank = 1'b0;
    reg [EPOCH_W-1:0] rd_req_epoch = 0;
    reg [CONTEXT_W-1:0] rd_req_context = 0;
    reg [AW-1:0] rd_req_addr = 0;
    reg rd_req_last = 1'b0;
    wire rd_req_ready;

    reg rd_return_valid = 1'b0;
    reg rd_return_bank = 1'b0;
    reg [EPOCH_W-1:0] rd_return_epoch = 0;
    reg [CONTEXT_W-1:0] rd_return_context = 0;
    reg rd_return_last = 1'b0;
    wire rd_return_ready;

    reg release_valid = 1'b0;
    reg release_bank = 1'b0;
    reg [EPOCH_W-1:0] release_epoch = 0;
    reg [CONTEXT_W-1:0] release_context = 0;
    wire release_ready;

    wire [1:0] bank_allocated;
    wire [1:0] bank_writer_done;
    wire [1:0] bank_reader_done;
    wire [1:0] bank_reusable;
    wire [EPOCH_W-1:0] bank0_owner_epoch;
    wire [EPOCH_W-1:0] bank1_owner_epoch;
    wire [CONTEXT_W-1:0] bank0_owner_context;
    wire [CONTEXT_W-1:0] bank1_owner_context;
    wire [AW:0] bank0_committed_credits;
    wire [AW:0] bank1_committed_credits;
    wire [AW:0] bank0_outstanding;
    wire [AW:0] bank1_outstanding;

    wire [31:0] alloc_count;
    wire [31:0] commit_count;
    wire [31:0] release_count;
    wire [31:0] ownership_stall_cycles;
    wire [31:0] underflow_count;
    wire [31:0] overwrite_count;
    wire [31:0] epoch_mismatch_count;
    wire [31:0] context_mismatch_count;
    wire [31:0] same_address_conflict_count;
    wire error_underflow;
    wire error_overwrite;
    wire error_epoch_mismatch;
    wire error_context_mismatch;
    wire error_same_address_conflict;
    wire fail_stop;
    wire physical_wr_en = wr_valid && wr_ready;
    wire physical_rd_en = rd_req_valid && rd_req_ready;

    psum_bank_owner_scoreboard #(
        .DEPTH(DEPTH), .AW(AW), .EPOCH_W(EPOCH_W),
        .CONTEXT_W(CONTEXT_W)
    ) dut (
        .clk(clk), .rst(rst),
        .alloc_valid(alloc_valid), .alloc_bank(alloc_bank),
        .alloc_epoch(alloc_epoch), .alloc_context(alloc_context),
        .alloc_expected(alloc_expected), .alloc_ready(alloc_ready),
        .wr_valid(wr_valid), .wr_bank(wr_bank), .wr_epoch(wr_epoch),
        .wr_context(wr_context), .wr_addr(wr_addr), .wr_ready(wr_ready),
        .commit_valid(commit_valid), .commit_bank(commit_bank),
        .commit_epoch(commit_epoch), .commit_context(commit_context),
        .commit_ready(commit_ready),
        .rd_req_valid(rd_req_valid), .rd_req_bank(rd_req_bank),
        .rd_req_epoch(rd_req_epoch), .rd_req_context(rd_req_context),
        .rd_req_addr(rd_req_addr), .rd_req_last(rd_req_last),
        .rd_req_ready(rd_req_ready),
        .rd_return_valid(rd_return_valid),
        .rd_return_bank(rd_return_bank),
        .rd_return_epoch(rd_return_epoch),
        .rd_return_context(rd_return_context),
        .rd_return_last(rd_return_last),
        .rd_return_ready(rd_return_ready),
        .release_valid(release_valid), .release_bank(release_bank),
        .release_epoch(release_epoch), .release_context(release_context),
        .release_ready(release_ready),
        .bank_allocated(bank_allocated),
        .bank_writer_done(bank_writer_done),
        .bank_reader_done(bank_reader_done),
        .bank_reusable(bank_reusable),
        .bank0_owner_epoch(bank0_owner_epoch),
        .bank1_owner_epoch(bank1_owner_epoch),
        .bank0_owner_context(bank0_owner_context),
        .bank1_owner_context(bank1_owner_context),
        .bank0_committed_credits(bank0_committed_credits),
        .bank1_committed_credits(bank1_committed_credits),
        .bank0_outstanding(bank0_outstanding),
        .bank1_outstanding(bank1_outstanding),
        .alloc_count(alloc_count), .commit_count(commit_count),
        .release_count(release_count),
        .ownership_stall_cycles(ownership_stall_cycles),
        .underflow_count(underflow_count),
        .overwrite_count(overwrite_count),
        .epoch_mismatch_count(epoch_mismatch_count),
        .context_mismatch_count(context_mismatch_count),
        .same_address_conflict_count(same_address_conflict_count),
        .error_underflow(error_underflow),
        .error_overwrite(error_overwrite),
        .error_epoch_mismatch(error_epoch_mismatch),
        .error_context_mismatch(error_context_mismatch),
        .error_same_address_conflict(error_same_address_conflict),
        .fail_stop(fail_stop)
    );

    // Cycle-exact oracle for the pre-cut read-ready equation.  It deliberately
    // selects every bank-owned state term first, matching the original RTL,
    // so the randomized comparisons below are independent of the new
    // constant-bank implementation structure.
    wire [EPOCH_W-1:0] old_rd_owner_epoch = rd_req_bank ?
        dut.epoch1_q : dut.epoch0_q;
    wire [CONTEXT_W-1:0] old_rd_owner_context = rd_req_bank ?
        dut.context1_q : dut.context0_q;
    wire [AW:0] old_rd_expected = rd_req_bank ?
        dut.expected1_q : dut.expected0_q;
    wire [AW:0] old_rd_issued = rd_req_bank ?
        dut.rd_issue_count1_q : dut.rd_issue_count0_q;
    wire [AW:0] old_rd_written = rd_req_bank ?
        dut.written_count1_q : dut.written_count0_q;
    wire old_rd_allocated = dut.allocated_q[rd_req_bank];
    wire old_rd_epoch_ok = old_rd_allocated &&
        (rd_req_epoch == old_rd_owner_epoch);
    wire old_rd_context_ok = old_rd_allocated &&
        (rd_req_context == old_rd_owner_context);
    wire old_rd_identity_ok = old_rd_epoch_ok && old_rd_context_ok;
    wire old_rd_addr_valid = ({1'b0, rd_req_addr} < DEPTH);
    wire old_rd_addr_in_order =
        ({1'b0, rd_req_addr} == old_rd_issued);
    wire old_rd_has_credit = old_rd_issued < old_rd_written;
    wire old_rd_ready_oracle = !fail_stop && old_rd_identity_ok &&
        old_rd_addr_valid && old_rd_addr_in_order && old_rd_has_credit &&
        (old_rd_issued < old_rd_expected);

    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;
    integer old_oracle_compare_count = 0;
    integer old_oracle_bank0_count = 0;
    integer old_oracle_bank1_count = 0;
    integer old_oracle_ready_count = 0;
    integer old_oracle_stall_count = 0;
    integer same_bank0_simultaneous_count = 0;
    integer same_bank1_simultaneous_count = 0;
    integer cross_bank_simultaneous_count = 0;
    integer random_seed;
    integer random_value;
    integer random_cycle;

    task check;
        input condition;
        input [8*96-1:0] message;
        begin
            if (condition)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task compare_old_ready_oracle;
        input [8*96-1:0] message;
        begin
            old_oracle_compare_count = old_oracle_compare_count + 1;
            if (rd_req_bank)
                old_oracle_bank1_count = old_oracle_bank1_count + 1;
            else
                old_oracle_bank0_count = old_oracle_bank0_count + 1;
            if (old_rd_ready_oracle)
                old_oracle_ready_count = old_oracle_ready_count + 1;
            else
                old_oracle_stall_count = old_oracle_stall_count + 1;
            check(rd_req_ready === old_rd_ready_oracle, message);
        end
    endtask

    task record_simultaneous_coverage;
        begin
            if (wr_valid && wr_ready && rd_req_valid && rd_req_ready) begin
                if (wr_bank != rd_req_bank)
                    cross_bank_simultaneous_count =
                        cross_bank_simultaneous_count + 1;
                else if (wr_bank)
                    same_bank1_simultaneous_count =
                        same_bank1_simultaneous_count + 1;
                else
                    same_bank0_simultaneous_count =
                        same_bank0_simultaneous_count + 1;
            end
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk);
            rst = 1'b1;
            alloc_valid = 1'b0;
            wr_valid = 1'b0;
            commit_valid = 1'b0;
            rd_req_valid = 1'b0;
            rd_return_valid = 1'b0;
            release_valid = 1'b0;
            repeat (3) @(negedge clk);
            rst = 1'b0;
            @(negedge clk);
        end
    endtask

    task allocate;
        input bank;
        input [EPOCH_W-1:0] epoch;
        input [CONTEXT_W-1:0] context_id;
        input [AW:0] expected;
        begin
            alloc_bank = bank;
            alloc_epoch = epoch;
            alloc_context = context_id;
            alloc_expected = expected;
            alloc_valid = 1'b1;
            #1;
            check(alloc_ready, "allocation ready");
            @(negedge clk);
            alloc_valid = 1'b0;
        end
    endtask

    task write_addr;
        input bank;
        input [EPOCH_W-1:0] epoch;
        input [CONTEXT_W-1:0] context_id;
        input [AW-1:0] addr;
        begin
            wr_bank = bank;
            wr_epoch = epoch;
            wr_context = context_id;
            wr_addr = addr;
            wr_valid = 1'b1;
            #1;
            check(wr_ready, "write creates committed credit");
            @(negedge clk);
            wr_valid = 1'b0;
        end
    endtask

    task commit_owner;
        input bank;
        input [EPOCH_W-1:0] epoch;
        input [CONTEXT_W-1:0] context_id;
        begin
            commit_bank = bank;
            commit_epoch = epoch;
            commit_context = context_id;
            commit_valid = 1'b1;
            #1;
            check(commit_ready, "writer collector_done commits owner");
            @(negedge clk);
            commit_valid = 1'b0;
        end
    endtask

    task read_addr;
        input bank;
        input [EPOCH_W-1:0] epoch;
        input [CONTEXT_W-1:0] context_id;
        input [AW-1:0] addr;
        input last;
        begin
            rd_req_bank = bank;
            rd_req_epoch = epoch;
            rd_req_context = context_id;
            rd_req_addr = addr;
            rd_req_last = last;
            rd_req_valid = 1'b1;
            #1;
            check(rd_req_ready, "read consumes committed credit");
            @(negedge clk);
            rd_req_valid = 1'b0;
        end
    endtask

    task return_word;
        input bank;
        input [EPOCH_W-1:0] epoch;
        input [CONTEXT_W-1:0] context_id;
        input last;
        begin
            rd_return_bank = bank;
            rd_return_epoch = epoch;
            rd_return_context = context_id;
            rd_return_last = last;
            rd_return_valid = 1'b1;
            #1;
            check(rd_return_ready, "read return retires outstanding credit");
            @(negedge clk);
            rd_return_valid = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        // Normal ping-pong ownership: both banks may be live concurrently.
        allocate(1'b0, 8'h11, 12'h101, 4'd3);
        allocate(1'b1, 8'h22, 12'h202, 4'd1);
        check(bank_allocated == 2'b11, "both ping-pong banks allocated");
        check(bank0_owner_epoch == 8'h11 &&
              bank0_owner_context == 12'h101,
              "bank0 owner tags observable");
        check(bank1_owner_epoch == 8'h22 &&
              bank1_owner_context == 12'h202,
              "bank1 owner tags observable");

        // A correctly tagged early release is ordinary valid/ready
        // backpressure.  Holding it must not create a protocol error.
        release_bank = 1'b0;
        release_epoch = 8'h11;
        release_context = 12'h101;
        release_valid = 1'b1;
        repeat (3) begin
            #1;
            check(!release_ready, "early release remains backpressured");
            @(negedge clk);
        end
        release_valid = 1'b0;
        check(!fail_stop, "held-valid early release is legal");

        write_addr(1'b0, 8'h11, 12'h101, 3'd0);

        // Same bank, different address: one write and one read request are
        // both accepted in the same cycle.
        wr_bank = 1'b0;
        wr_epoch = 8'h11;
        wr_context = 12'h101;
        wr_addr = 3'd1;
        wr_valid = 1'b1;
        rd_req_bank = 1'b0;
        rd_req_epoch = 8'h11;
        rd_req_context = 12'h101;
        rd_req_addr = 3'd0;
        rd_req_last = 1'b0;
        rd_req_valid = 1'b1;
        #1;
        check(wr_ready && rd_req_ready,
              "same-bank different-address read/write accepted");
        check(physical_wr_en && physical_rd_en && rd_req_addr < wr_addr,
              "legal simultaneous read address precedes write address");
        @(negedge clk);
        wr_valid = 1'b0;
        rd_req_valid = 1'b0;
        check(bank0_committed_credits == 1,
              "simultaneous read/write preserves credit total");
        check(bank0_outstanding == 1,
              "read request reserves one return");

        // A second different-address read/write overlaps the first return.
        wr_addr = 3'd2;
        wr_valid = 1'b1;
        rd_req_addr = 3'd1;
        rd_req_last = 1'b0;
        rd_req_valid = 1'b1;
        rd_return_bank = 1'b0;
        rd_return_epoch = 8'h11;
        rd_return_context = 12'h101;
        rd_return_last = 1'b0;
        rd_return_valid = 1'b1;
        #1;
        check(wr_ready && rd_req_ready && rd_return_ready,
              "write, next read, and prior return overlap");
        @(negedge clk);
        wr_valid = 1'b0;
        rd_req_valid = 1'b0;
        rd_return_valid = 1'b0;
        check(bank0_committed_credits == 1 && bank0_outstanding == 1,
              "overlap balances committed and outstanding counts");

        commit_owner(1'b0, 8'h11, 12'h101);
        check(bank_writer_done[0], "writer completion recorded");
        read_addr(1'b0, 8'h11, 12'h101, 3'd2, 1'b1);
        return_word(1'b0, 8'h11, 12'h101, 1'b0);

        // Hold release before the last RAM response.  It becomes ready only
        // after the correctly tagged last return has retired.
        release_bank = 1'b0;
        release_epoch = 8'h11;
        release_context = 12'h101;
        release_valid = 1'b1;
        #1;
        check(!release_ready && bank0_outstanding == 1,
              "release waits for final read return");
        rd_return_bank = 1'b0;
        rd_return_epoch = 8'h11;
        rd_return_context = 12'h101;
        rd_return_last = 1'b1;
        rd_return_valid = 1'b1;
        #1;
        check(rd_return_ready, "final return accepted while release held");
        @(negedge clk);
        rd_return_valid = 1'b0;
        #1;
        check(release_ready && bank_reader_done[0] && bank_reusable[0],
              "last return makes bank reusable");
        @(negedge clk);
        release_valid = 1'b0;
        check(!bank_allocated[0], "release frees bank0 owner");

        // Finish bank1 and verify ordinary ping-pong reuse.
        write_addr(1'b1, 8'h22, 12'h202, 3'd0);
        commit_owner(1'b1, 8'h22, 12'h202);
        read_addr(1'b1, 8'h22, 12'h202, 3'd0, 1'b1);
        return_word(1'b1, 8'h22, 12'h202, 1'b1);
        release_bank = 1'b1;
        release_epoch = 8'h22;
        release_context = 12'h202;
        release_valid = 1'b1;
        #1;
        check(release_ready, "bank1 release ready after complete return");
        @(negedge clk);
        release_valid = 1'b0;
        check(bank_allocated == 2'b00, "both bank owners released");
        check(alloc_count == 2 && commit_count == 2 && release_count == 2,
              "owner lifecycle counters exact");
        check(!fail_stop, "normal ping-pong sequence has no errors");

        // Exercise the structural ready cut with both banks live.  Every
        // sampled decision is compared against the pre-cut selected-state
        // oracle above, including credit boundaries and same-edge traffic.
        reset_dut();
        allocate(1'b0, 8'h51, 12'h501, DEPTH);
        allocate(1'b1, 8'h52, 12'h502, DEPTH);

        // Neither bank has a committed credit yet.  A write performed on the
        // upcoming edge must not make that credit visible combinationally.
        rd_req_valid = 1'b0;
        rd_req_bank = 1'b0;
        rd_req_epoch = 8'h51;
        rd_req_context = 12'h501;
        rd_req_addr = 0;
        rd_req_last = 1'b0;
        #1;
        compare_old_ready_oracle("bank0 empty-credit boundary matches old oracle");
        check(!rd_req_ready, "bank0 empty-credit boundary stalls");
        rd_req_bank = 1'b1;
        rd_req_epoch = 8'h52;
        rd_req_context = 12'h502;
        #1;
        compare_old_ready_oracle("bank1 empty-credit boundary matches old oracle");
        check(!rd_req_ready, "bank1 empty-credit boundary stalls");

        write_addr(1'b0, 8'h51, 12'h501, 0);
        write_addr(1'b1, 8'h52, 12'h502, 0);

        // Bank0 accepts a read of its prior credit while writing the next
        // address on the same edge.
        wr_valid = 1'b1;
        wr_bank = 1'b0;
        wr_epoch = 8'h51;
        wr_context = 12'h501;
        wr_addr = 1;
        rd_req_valid = 1'b1;
        rd_req_bank = 1'b0;
        rd_req_epoch = 8'h51;
        rd_req_context = 12'h501;
        rd_req_addr = 0;
        rd_req_last = 1'b0;
        #1;
        compare_old_ready_oracle("bank0 same-edge read/write matches old oracle");
        check(wr_ready && rd_req_ready,
              "bank0 prior credit overlaps next write");
        record_simultaneous_coverage();
        @(negedge clk);
        wr_valid = 1'b0;
        rd_req_valid = 1'b0;

        // Cross-bank traffic exercises the final rd_req_bank select while the
        // unselected bank is independently changing its write state.
        wr_valid = 1'b1;
        wr_bank = 1'b0;
        wr_epoch = 8'h51;
        wr_context = 12'h501;
        wr_addr = 2;
        rd_req_valid = 1'b1;
        rd_req_bank = 1'b1;
        rd_req_epoch = 8'h52;
        rd_req_context = 12'h502;
        rd_req_addr = 0;
        rd_req_last = 1'b0;
        #1;
        compare_old_ready_oracle("cross-bank same-edge traffic matches old oracle");
        check(wr_ready && rd_req_ready,
              "bank0 write overlaps bank1 read");
        record_simultaneous_coverage();
        @(negedge clk);
        wr_valid = 1'b0;
        rd_req_valid = 1'b0;

        // Bank1's next write is not a same-cycle bypass.  Keep rd_req_valid
        // low so this ordinary backpressure observation cannot raise the
        // same-address fail-stop diagnostic.
        wr_valid = 1'b1;
        wr_bank = 1'b1;
        wr_epoch = 8'h52;
        wr_context = 12'h502;
        wr_addr = 1;
        rd_req_valid = 1'b0;
        rd_req_bank = 1'b1;
        rd_req_epoch = 8'h52;
        rd_req_context = 12'h502;
        rd_req_addr = 1;
        rd_req_last = 1'b0;
        #1;
        compare_old_ready_oracle("same-cycle new credit matches old oracle");
        check(wr_ready && !rd_req_ready,
              "new write credit is unavailable until the next cycle");
        @(negedge clk);
        wr_valid = 1'b0;

        // On the following edge bank1 may consume that credit while its next
        // address is written, mirroring the bank0 boundary above.
        wr_valid = 1'b1;
        wr_bank = 1'b1;
        wr_epoch = 8'h52;
        wr_context = 12'h502;
        wr_addr = 2;
        rd_req_valid = 1'b1;
        rd_req_bank = 1'b1;
        rd_req_epoch = 8'h52;
        rd_req_context = 12'h502;
        rd_req_addr = 1;
        rd_req_last = 1'b0;
        #1;
        compare_old_ready_oracle("bank1 same-edge read/write matches old oracle");
        check(wr_ready && rd_req_ready,
              "bank1 prior credit overlaps next write");
        record_simultaneous_coverage();
        @(negedge clk);
        wr_valid = 1'b0;
        rd_req_valid = 1'b0;

        // Randomly interleave legal writes, read requests, and returns across
        // both banks.  Requests are derived from pre-edge DUT state, so any
        // asserted valid is legal while the ready oracle still sees a broad
        // mix of selected banks and changing high-watermarks.
        random_seed = 32'h5a17c0de;
        for (random_cycle = 0; random_cycle < 128;
             random_cycle = random_cycle + 1) begin
            random_value = $random(random_seed);

            wr_bank = random_value[0];
            if (wr_bank && dut.written_count1_q >= DEPTH &&
                dut.written_count0_q < DEPTH)
                wr_bank = 1'b0;
            else if (!wr_bank && dut.written_count0_q >= DEPTH &&
                     dut.written_count1_q < DEPTH)
                wr_bank = 1'b1;
            wr_valid = random_value[2] &&
                ((wr_bank && dut.written_count1_q < DEPTH) ||
                 (!wr_bank && dut.written_count0_q < DEPTH));
            wr_epoch = wr_bank ? 8'h52 : 8'h51;
            wr_context = wr_bank ? 12'h502 : 12'h501;
            wr_addr = wr_bank ? dut.written_count1_q[AW-1:0] :
                                dut.written_count0_q[AW-1:0];

            rd_req_bank = random_value[3];
            if (rd_req_bank &&
                !(dut.rd_issue_count1_q < dut.written_count1_q) &&
                (dut.rd_issue_count0_q < dut.written_count0_q))
                rd_req_bank = 1'b0;
            else if (!rd_req_bank &&
                     !(dut.rd_issue_count0_q < dut.written_count0_q) &&
                     (dut.rd_issue_count1_q < dut.written_count1_q))
                rd_req_bank = 1'b1;
            rd_req_valid = random_value[5] &&
                ((rd_req_bank &&
                  dut.rd_issue_count1_q < dut.written_count1_q &&
                  dut.rd_issue_count1_q < DEPTH) ||
                 (!rd_req_bank &&
                  dut.rd_issue_count0_q < dut.written_count0_q &&
                  dut.rd_issue_count0_q < DEPTH));
            rd_req_epoch = rd_req_bank ? 8'h52 : 8'h51;
            rd_req_context = rd_req_bank ? 12'h502 : 12'h501;
            rd_req_addr = rd_req_bank ?
                dut.rd_issue_count1_q[AW-1:0] :
                dut.rd_issue_count0_q[AW-1:0];
            rd_req_last = rd_req_bank ?
                (dut.rd_issue_count1_q + 1'b1 == DEPTH) :
                (dut.rd_issue_count0_q + 1'b1 == DEPTH);

            rd_return_bank = random_value[6];
            if (rd_return_bank &&
                !(dut.rd_return_count1_q < dut.rd_issue_count1_q) &&
                (dut.rd_return_count0_q < dut.rd_issue_count0_q))
                rd_return_bank = 1'b0;
            else if (!rd_return_bank &&
                     !(dut.rd_return_count0_q < dut.rd_issue_count0_q) &&
                     (dut.rd_return_count1_q < dut.rd_issue_count1_q))
                rd_return_bank = 1'b1;
            rd_return_valid = random_value[8] &&
                ((rd_return_bank &&
                  dut.rd_return_count1_q < dut.rd_issue_count1_q) ||
                 (!rd_return_bank &&
                  dut.rd_return_count0_q < dut.rd_issue_count0_q));
            rd_return_epoch = rd_return_bank ? 8'h52 : 8'h51;
            rd_return_context = rd_return_bank ? 12'h502 : 12'h501;
            rd_return_last = rd_return_bank ?
                (dut.rd_return_count1_q + 1'b1 == DEPTH) :
                (dut.rd_return_count0_q + 1'b1 == DEPTH);

            #1;
            compare_old_ready_oracle("random two-bank ready matches old oracle");
            if (wr_valid)
                check(wr_ready, "random legal write is ready");
            if (rd_req_valid)
                check(rd_req_ready, "random credited read is ready");
            if (rd_return_valid)
                check(rd_return_ready, "random outstanding return is ready");
            record_simultaneous_coverage();
            @(negedge clk);
        end
        wr_valid = 1'b0;
        rd_req_valid = 1'b0;
        rd_return_valid = 1'b0;

        // Deterministically drain any work left by the random phase, then
        // prove that both owner lifecycles still complete without an error.
        while (dut.written_count0_q < DEPTH)
            write_addr(1'b0, 8'h51, 12'h501,
                       dut.written_count0_q[AW-1:0]);
        while (dut.written_count1_q < DEPTH)
            write_addr(1'b1, 8'h52, 12'h502,
                       dut.written_count1_q[AW-1:0]);
        commit_owner(1'b0, 8'h51, 12'h501);
        commit_owner(1'b1, 8'h52, 12'h502);
        while (dut.rd_issue_count0_q < DEPTH)
            read_addr(1'b0, 8'h51, 12'h501,
                      dut.rd_issue_count0_q[AW-1:0],
                      (dut.rd_issue_count0_q + 1'b1 == DEPTH));
        while (dut.rd_issue_count1_q < DEPTH)
            read_addr(1'b1, 8'h52, 12'h502,
                      dut.rd_issue_count1_q[AW-1:0],
                      (dut.rd_issue_count1_q + 1'b1 == DEPTH));
        while (dut.rd_return_count0_q < DEPTH)
            return_word(1'b0, 8'h51, 12'h501,
                        (dut.rd_return_count0_q + 1'b1 == DEPTH));
        while (dut.rd_return_count1_q < DEPTH)
            return_word(1'b1, 8'h52, 12'h502,
                        (dut.rd_return_count1_q + 1'b1 == DEPTH));

        release_bank = 1'b0;
        release_epoch = 8'h51;
        release_context = 12'h501;
        release_valid = 1'b1;
        #1;
        check(release_ready, "random phase bank0 release ready");
        @(negedge clk);
        release_valid = 1'b0;
        release_bank = 1'b1;
        release_epoch = 8'h52;
        release_context = 12'h502;
        release_valid = 1'b1;
        #1;
        check(release_ready, "random phase bank1 release ready");
        @(negedge clk);
        release_valid = 1'b0;

        check(!fail_stop && bank_allocated == 2'b00,
              "random two-bank lifecycle completes without fail-stop");
        check(old_oracle_compare_count >= 134 &&
              old_oracle_bank0_count != 0 && old_oracle_bank1_count != 0 &&
              old_oracle_ready_count != 0 && old_oracle_stall_count != 0,
              "old ready oracle covers both banks and ready/stall outcomes");
        check(same_bank0_simultaneous_count != 0 &&
              same_bank1_simultaneous_count != 0 &&
              cross_bank_simultaneous_count != 0,
              "same-edge coverage includes both same-bank and cross-bank traffic");
        $display("PASS: old-ready oracle compares=%0d bank0/bank1=%0d/%0d ready/stall=%0d/%0d simultaneous b0/b1/cross=%0d/%0d/%0d",
                 old_oracle_compare_count,
                 old_oracle_bank0_count, old_oracle_bank1_count,
                 old_oracle_ready_count, old_oracle_stall_count,
                 same_bank0_simultaneous_count,
                 same_bank1_simultaneous_count,
                 cross_bank_simultaneous_count);

        // Error scenarios use a clean sticky/counter baseline.
        reset_dut();
        allocate(1'b0, 8'h31, 12'h303, 4'd2);
        write_addr(1'b0, 8'h31, 12'h303, 3'd0);

        // Duplicate write is held for several cycles: one overwrite event,
        // no repeated count while valid remains asserted.
        wr_bank = 1'b0;
        wr_epoch = 8'h31;
        wr_context = 12'h303;
        wr_addr = 3'd0;
        wr_valid = 1'b1;
        repeat (3) begin
            #1;
            check(!wr_ready, "duplicate committed address backpressured");
            @(negedge clk);
        end
        wr_valid = 1'b0;
        check(error_overwrite && overwrite_count == 1,
              "held overwrite raises one sticky/count event");

        // Reading an address before it owns a credit is an underflow.  The
        // held request is likewise counted once.
        rd_req_bank = 1'b0;
        rd_req_epoch = 8'h31;
        rd_req_context = 12'h303;
        rd_req_addr = 3'd1;
        rd_req_last = 1'b0;
        rd_req_valid = 1'b1;
        repeat (3) begin
            #1;
            check(!rd_req_ready, "uncommitted read backpressured");
            @(negedge clk);
        end
        rd_req_valid = 1'b0;
        check(error_underflow && underflow_count == 1,
              "held underflow raises one sticky/count event");

        // The release scoreboard intentionally accepts only the sequential
        // collector/feeder address contract.  A gap write and a non-prefix
        // read are fail-stop errors rather than sparse-address credits.
        reset_dut();
        allocate(1'b0, 8'h32, 12'h304, 4'd2);
        wr_bank = 1'b0;
        wr_epoch = 8'h32;
        wr_context = 12'h304;
        wr_addr = 3'd1;
        wr_valid = 1'b1;
        #1;
        check(!wr_ready, "out-of-order write is rejected");
        @(negedge clk);
        wr_valid = 1'b0;
        check(error_overwrite && overwrite_count == 1,
              "out-of-order write uses overwrite fail-stop telemetry");

        reset_dut();
        allocate(1'b0, 8'h33, 12'h305, 4'd2);
        write_addr(1'b0, 8'h33, 12'h305, 3'd0);
        rd_req_bank = 1'b0;
        rd_req_epoch = 8'h33;
        rd_req_context = 12'h305;
        rd_req_addr = 3'd1;
        rd_req_last = 1'b0;
        rd_req_valid = 1'b1;
        #1;
        check(!rd_req_ready, "out-of-order read is rejected");
        @(negedge clk);
        rd_req_valid = 1'b0;
        check(error_underflow && underflow_count == 1,
              "out-of-order read uses underflow fail-stop telemetry");

        // A same-address read intent at the next unwritten address is
        // malformed: no read credit exists.  It must not suppress the legal
        // write, and only the write side may reach the physical RAM interface.
        reset_dut();
        allocate(1'b0, 8'h34, 12'h306, 4'd2);
        wr_valid = 1'b1;
        wr_bank = 1'b0;
        wr_epoch = 8'h34;
        wr_context = 12'h306;
        wr_addr = 3'd0;
        rd_req_valid = 1'b1;
        rd_req_bank = 1'b0;
        rd_req_epoch = 8'h34;
        rd_req_context = 12'h306;
        rd_req_addr = 3'd0;
        rd_req_last = 1'b0;
        #1;
        check(dut.same_address_conflict && wr_ready && !rd_req_ready,
              "malformed same-address read does not block legal write");
        check(physical_wr_en && !physical_rd_en,
              "same-address malformed read never becomes a physical read");
        @(negedge clk);
        check(bank0_committed_credits == 1 && bank0_outstanding == 0,
              "only legal write advances same-address intent state");
        check(error_same_address_conflict && fail_stop &&
              same_address_conflict_count == 1,
              "same-address intent remains sticky fail-stop diagnostic");
        check(!error_underflow && !error_overwrite &&
              !error_epoch_mismatch && !error_context_mismatch,
              "same-address intent raises no unrelated diagnostics");
        repeat (3) @(negedge clk);
        check(same_address_conflict_count == 1 &&
              bank0_committed_credits == 1 && bank0_outstanding == 0,
              "held same-address intent is counted once and cannot refire");
        wr_valid = 1'b0;
        rd_req_valid = 1'b0;
        @(negedge clk);
        check(error_same_address_conflict && fail_stop &&
              same_address_conflict_count == 1,
              "collision diagnostic remains sticky after intent drops");

        reset_dut();
        check(!error_same_address_conflict && !fail_stop &&
              same_address_conflict_count == 0 &&
              bank0_committed_credits == 0 && bank0_outstanding == 0,
              "reset clears collision sticky count and handshake state");

        // The inverse malformed pair remains safe: a duplicate write cannot
        // fire while the already-credited read does.  The intent is still
        // reported once as a same-address fail-stop violation.
        allocate(1'b0, 8'h31, 12'h303, 4'd2);
        write_addr(1'b0, 8'h31, 12'h303, 3'd0);
        wr_valid = 1'b1;
        wr_bank = 1'b0;
        wr_epoch = 8'h31;
        wr_context = 12'h303;
        wr_addr = 3'd0;
        rd_req_valid = 1'b1;
        rd_req_bank = 1'b0;
        rd_req_epoch = 8'h31;
        rd_req_context = 12'h303;
        rd_req_addr = 3'd0;
        #1;
        check(!wr_ready && rd_req_ready,
              "duplicate same-address write cannot block legal read");
        @(negedge clk);
        wr_valid = 1'b0;
        rd_req_valid = 1'b0;
        check(error_same_address_conflict &&
              same_address_conflict_count == 1,
              "same-address collision is sticky fail-stop");

        // Epoch and context ownership checks are independent.
        reset_dut();
        allocate(1'b0, 8'h31, 12'h303, 4'd2);
        wr_addr = 3'd1;
        wr_epoch = 8'h30;
        wr_context = 12'h303;
        wr_valid = 1'b1;
        #1;
        check(!wr_ready, "wrong epoch rejected");
        @(negedge clk);
        wr_valid = 1'b0;
        rd_req_epoch = 8'h31;
        rd_req_context = 12'h302;
        rd_req_addr = 3'd0;
        rd_req_valid = 1'b1;
        #1;
        check(!rd_req_ready, "wrong context rejected");
        @(negedge clk);
        rd_req_valid = 1'b0;
        check(error_epoch_mismatch && epoch_mismatch_count == 1,
              "epoch mismatch sticky and counted");
        check(error_context_mismatch && context_mismatch_count == 1,
              "context mismatch sticky and counted");
        check(fail_stop, "any scoreboard error asserts fail-stop");

        $display("=== tb_psum_bank_owner_scoreboard: %0d pass, %0d fail ===",
                 pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        repeat (1000) @(negedge clk);
        $display("[FAIL] timeout alloc=%b writer=%b reader=%b credits=%0d/%0d outstanding=%0d/%0d",
                 bank_allocated, bank_writer_done, bank_reader_done,
                 bank0_committed_credits, bank1_committed_credits,
                 bank0_outstanding, bank1_outstanding);
        $fatal(1);
    end
endmodule

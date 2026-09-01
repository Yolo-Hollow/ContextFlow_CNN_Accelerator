`timescale 1ns / 1ps

`ifndef TB_IFM_EPOCH_USE_URAM
`define TB_IFM_EPOCH_USE_URAM 0
`endif

module tb_ifm_vector_epoch_buffer;
    localparam DATA_W = 32;
    localparam DEPTH = 8;
    localparam AW = 3;
    localparam EPOCH_W = 4;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg alloc_valid = 1'b0;
    reg alloc_bank = 1'b0;
    reg [EPOCH_W-1:0] alloc_epoch = 0;
    reg [15:0] alloc_expected = 0;
    wire alloc_ready;
    reg wr_valid = 1'b0;
    reg wr_bank = 1'b0;
    reg [EPOCH_W-1:0] wr_epoch = 0;
    reg [DATA_W-1:0] wr_data = 0;
    wire wr_ready;
    reg commit_valid = 1'b0;
    reg commit_bank = 1'b0;
    reg [EPOCH_W-1:0] commit_epoch = 0;
    reg select_valid = 1'b0;
    reg select_bank = 1'b0;
    reg [EPOCH_W-1:0] select_epoch = 0;
    wire select_ready;
    wire commit_ready;
    wire [DATA_W-1:0] rd_data;
    wire rd_bank;
    wire [EPOCH_W-1:0] rd_epoch;
    wire rd_valid;
    wire rd_last;
    reg rd_ready = 1'b0;
    reg release_valid = 1'b0;
    reg release_bank = 1'b0;
    reg [EPOCH_W-1:0] release_epoch = 0;
    wire release_ready;
    wire [1:0] bank_allocated;
    wire [1:0] bank_committed;
    wire [15:0] bank0_produced;
    wire [15:0] bank1_produced;
    wire [15:0] bank0_consumed;
    wire [15:0] bank1_consumed;
    wire [15:0] bank0_available;
    wire [15:0] bank1_available;
    wire reader_active;
    wire reader_bank;
    wire reader_context_done;
    wire [31:0] epoch_alloc_count;
    wire [31:0] bank_release_count;
    wire [31:0] bank_ownership_stall_cycles;
    wire [31:0] context_gap_cycles;
    wire error_epoch;
    wire error_overflow;
    wire error_protocol;

    ifm_vector_epoch_buffer #(
        .DATA_W(DATA_W), .DEPTH(DEPTH), .AW(AW), .EPOCH_W(EPOCH_W),
        .USE_URAM(`TB_IFM_EPOCH_USE_URAM)
    ) dut (
        .clk(clk), .rst(rst),
        .alloc_valid(alloc_valid), .alloc_bank(alloc_bank),
        .alloc_epoch(alloc_epoch), .alloc_expected(alloc_expected),
        .alloc_ready(alloc_ready),
        .wr_valid(wr_valid), .wr_bank(wr_bank), .wr_epoch(wr_epoch),
        .wr_data(wr_data), .wr_ready(wr_ready),
        .commit_valid(commit_valid), .commit_bank(commit_bank),
        .commit_epoch(commit_epoch), .commit_ready(commit_ready),
        .select_valid(select_valid), .select_bank(select_bank),
        .select_epoch(select_epoch), .select_ready(select_ready),
        .rd_data(rd_data), .rd_bank(rd_bank), .rd_epoch(rd_epoch),
        .rd_valid(rd_valid),
        .rd_last(rd_last), .rd_ready(rd_ready),
        .release_valid(release_valid), .release_bank(release_bank),
        .release_epoch(release_epoch), .release_ready(release_ready),
        .bank_allocated(bank_allocated), .bank_committed(bank_committed),
        .bank0_produced(bank0_produced), .bank1_produced(bank1_produced),
        .bank0_consumed(bank0_consumed), .bank1_consumed(bank1_consumed),
        .bank0_available(bank0_available), .bank1_available(bank1_available),
        .reader_active(reader_active), .reader_bank(reader_bank),
        .reader_context_done(reader_context_done),
        .epoch_alloc_count(epoch_alloc_count),
        .bank_release_count(bank_release_count),
        .bank_ownership_stall_cycles(bank_ownership_stall_cycles),
        .context_gap_cycles(context_gap_cycles),
        .error_epoch(error_epoch), .error_overflow(error_overflow),
        .error_protocol(error_protocol)
    );

    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;
    integer seen = 0;
    reg scoreboard_enable = 1'b1;
    reg [31:0] expected_data [0:7];

    task check;
        input cond;
        input [255:0] message;
        begin
            if (cond)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task allocate_bank;
        input bank;
        input [EPOCH_W-1:0] epoch;
        input [15:0] count;
        begin
            @(negedge clk);
            alloc_bank = bank;
            alloc_epoch = epoch;
            alloc_expected = count;
            alloc_valid = 1'b1;
            #1;
            check(alloc_ready, "bank allocation accepted");
            @(negedge clk);
            alloc_valid = 1'b0;
        end
    endtask

    task write_word;
        input bank;
        input [EPOCH_W-1:0] epoch;
        input [31:0] data;
        begin
            @(negedge clk);
            wr_bank = bank;
            wr_epoch = epoch;
            wr_data = data;
            wr_valid = 1'b1;
            #1;
            check(wr_ready, "vector write accepted");
            @(negedge clk);
            wr_valid = 1'b0;
        end
    endtask

    task select_reader;
        input bank;
        input [EPOCH_W-1:0] epoch;
        begin
            @(negedge clk);
            select_bank = bank;
            select_epoch = epoch;
            select_valid = 1'b1;
            #1;
            check(select_ready, "reader selection accepted");
            @(negedge clk);
            select_valid = 1'b0;
        end
    endtask

    task switch_reader_on_final;
        input bank;
        input [EPOCH_W-1:0] epoch;
        begin
            // Catch the old context's registered final vector before its next
            // rising-edge transfer, then prove that a stalled final vector
            // blocks the switch and the actual final handshake enables it.
            wait(rd_valid && rd_last);
            @(negedge clk);
            rd_ready = 1'b0;
            select_bank = bank;
            select_epoch = epoch;
            select_valid = 1'b1;
            #1;
            check(!select_ready,
                  "reader switch waits for the final vector handshake");
            rd_ready = 1'b1;
            #1;
            check(select_ready,
                  "next reader selected on the final vector handshake");
            @(posedge clk);
            @(negedge clk);
            select_valid = 1'b0;
            check(reader_context_done,
                  "reader context-done pulse marks the handoff");
            check(reader_active && reader_bank == bank,
                  "reader handoff preserves the newly selected context");
        end
    endtask

    task commit_bank_task;
        input bank;
        input [EPOCH_W-1:0] epoch;
        begin
            @(negedge clk);
            commit_bank = bank;
            commit_epoch = epoch;
            commit_valid = 1'b1;
            #1;
            check(commit_ready, "complete bank commit accepted");
            @(negedge clk);
            commit_valid = 1'b0;
        end
    endtask

    task release_bank_task;
        input bank;
        input [EPOCH_W-1:0] epoch;
        begin
            @(negedge clk);
            release_bank = bank;
            release_epoch = epoch;
            release_valid = 1'b1;
            #1;
            check(release_ready, "completed bank release accepted");
            @(negedge clk);
            release_valid = 1'b0;
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk);
            alloc_valid = 1'b0;
            wr_valid = 1'b0;
            commit_valid = 1'b0;
            select_valid = 1'b0;
            release_valid = 1'b0;
            rd_ready = 1'b0;
            rst = 1'b1;
            repeat (2) @(negedge clk);
            rst = 1'b0;
            @(negedge clk);
            check(bank_allocated == 2'b00,
                  "reset clears both bank ownership records");
            check(!reader_active && !rd_valid,
                  "reset clears reader and registered output");
            check(dut.lookahead_pending_q == 2'b00 &&
                  dut.lookahead_valid_q == 2'b00,
                  "reset clears pending and valid lookahead state");
        end
    endtask

    always @(posedge clk) begin
        if (scoreboard_enable && rd_valid && rd_ready) begin
            check(rd_data == expected_data[seen], "read preserves atomic vector order");
            if (seen < 4)
                check(rd_epoch == 4'h3, "bank0 read epoch matches");
            else
                check(rd_epoch == 4'h7, "bank1 read epoch matches");
            check(rd_bank == (seen >= 4), "read carries its atomic bank tag");
            if (seen == 3 || seen == 6)
                check(rd_last, "last marker matches context boundary");
            else
                check(!rd_last, "non-final vector is not marked last");
            seen = seen + 1;
        end
    end

    initial begin
        expected_data[0] = 32'h1000_0000;
        expected_data[1] = 32'h1000_0001;
        expected_data[2] = 32'h1000_0002;
        expected_data[3] = 32'h1000_0003;
        expected_data[4] = 32'h2000_0000;
        expected_data[5] = 32'h2000_0001;
        expected_data[6] = 32'h2000_0002;

        repeat (4) @(negedge clk);
        rst = 1'b0;

        allocate_bank(1'b0, 4'h3, 16'd4);
        write_word(1'b0, 4'h3, expected_data[0]);
        write_word(1'b0, 4'h3, expected_data[1]);
        select_reader(1'b0, 4'h3);

        // Fill the inactive bank while bank0 is being consumed.
        allocate_bank(1'b1, 4'h7, 16'd3);
        rd_ready = 1'b1;
        write_word(1'b1, 4'h7, expected_data[4]);
        write_word(1'b0, 4'h3, expected_data[2]);
        rd_ready = 1'b0;
        write_word(1'b1, 4'h7, expected_data[5]);
        write_word(1'b0, 4'h3, expected_data[3]);
        commit_bank_task(1'b0, 4'h3);
        write_word(1'b1, 4'h7, expected_data[6]);
        commit_bank_task(1'b1, 4'h7);

        // Backpressure must hold the current output stable.
        repeat (2) @(negedge clk);
        if (rd_valid) begin
            wr_data = rd_data;
            repeat (3) begin
                @(negedge clk);
                check(rd_valid && rd_data == wr_data, "read data stable under backpressure");
            end
        end
        rd_ready = 1'b1;
        // Select the next context on bank0's final pop, before releasing
        // bank0.  In the integrated array release remains delayed until the
        // old context's tail retires.
        switch_reader_on_final(1'b1, 4'h7);
        check(bank0_consumed == 16'd4,
              "old context consumption completed at reader handoff");
        check(bank_allocated[0],
              "old bank remains owned while the next context is selected");
        release_bank_task(1'b0, 4'h3);
        check(!bank_allocated[0],
              "old bank becomes free only after independent release");
        wait(bank1_consumed == 16'd3);
        @(negedge clk);
        release_bank_task(1'b1, 4'h7);
        check(!bank_allocated[1], "bank1 becomes free after release");
        check(seen == 7, "all vectors consumed");
        check(!error_epoch, "no epoch error on valid sequence");
        check(!error_overflow, "no overflow on valid sequence");
        check(!error_protocol, "no protocol error on valid sequence");
        check(epoch_alloc_count == 32'd2, "epoch allocations counted");
        check(bank_release_count == 32'd2, "bank releases counted");
        check(context_gap_cycles != 32'd0,
              "producer context gaps are observable");

        // A stale epoch write is rejected and diagnosed.
        allocate_bank(1'b0, 4'h9, 16'd1);
        @(negedge clk);
        wr_bank = 1'b0;
        wr_epoch = 4'h8;
        wr_data = 32'hdead_beef;
        wr_valid = 1'b1;
        #1;
        check(!wr_ready, "stale epoch write is not accepted");
        @(negedge clk);
        wr_valid = 1'b0;
        check(error_epoch, "stale epoch raises sticky error");

        // Reallocating an owned bank is rejected and counted separately from
        // ordinary producer/consumer backpressure.
        @(negedge clk);
        alloc_bank = 1'b0;
        alloc_epoch = 4'ha;
        alloc_expected = 16'd1;
        alloc_valid = 1'b1;
        #1;
        check(!alloc_ready, "owned bank cannot be reallocated");
        @(negedge clk);
        alloc_valid = 1'b0;
        check(bank_ownership_stall_cycles == 32'd1,
              "bank ownership stall counted");
        check(!error_overflow,
              "held allocation valid is backpressure, not overflow");

        // A release request may be held before retirement; it must become
        // ready later without being diagnosed as a protocol failure.
        @(negedge clk);
        release_bank = 1'b0;
        release_epoch = 4'h9;
        release_valid = 1'b1;
        #1;
        check(!release_ready, "early release request is backpressured");
        repeat (2) @(negedge clk);
        release_valid = 1'b0;

        // The remaining checks directly inspect each transfer.  Disable the
        // original seven-vector scoreboard before resetting the DUT for the
        // focused lookahead/fast-handoff cases.
        scoreboard_enable = 1'b0;

        // The registered per-bank write credit must accept the terminal beat,
        // close before an N+1 beat can handshake, and remain independent
        // across the two banks.  Keep valid asserted for one extra edge so the
        // rejected transfer also exercises the legacy overflow diagnostic.
        reset_dut();
        allocate_bank(1'b0, 4'ha, 16'd1);
        allocate_bank(1'b1, 4'hb, 16'd2);
        @(negedge clk);
        wr_bank = 1'b0;
        wr_epoch = 4'ha;
        wr_data = 32'haaaa_0000;
        wr_valid = 1'b1;
        #1;
        check(wr_ready && dut.write_open_q == 2'b11,
              "expected-one terminal beat retains write credit");
        @(posedge clk);
        #1;
        check(bank0_produced == 16'd1 && !wr_ready &&
              dut.write_open_q == 2'b10,
              "expected-one terminal beat accepts then closes only bank0");

        wr_data = 32'haaaa_0001;
        @(posedge clk);
        #1;
        check(bank0_produced == 16'd1 && !wr_ready,
              "N+1 beat is backpressured without changing produced count");
        check(error_overflow,
              "held N+1 beat preserves the overflow fail-stop diagnostic");
        @(negedge clk);
        wr_valid = 1'b0;

        write_word(1'b1, 4'hb, 32'hbbbb_0000);
        check(bank0_produced == 16'd1 && bank1_produced == 16'd1 &&
              dut.write_open_q == 2'b10,
              "bank1 write credit advances independently of closed bank0");
        write_word(1'b1, 4'hb, 32'hbbbb_0001);
        check(bank0_produced == 16'd1 && bank1_produced == 16'd2 &&
              dut.write_open_q == 2'b00,
              "bank1 terminal beat closes without perturbing bank0");

        // Fully retire bank0, then reuse it while bank1 remains allocated.
        // Reallocation must reopen credit from the new epoch and reset only
        // the selected bank's produced counter.
        commit_bank_task(1'b0, 4'ha);
        wait(dut.lookahead_valid_q[0]);
        rd_ready = 1'b1;
        select_reader(1'b0, 4'ha);
        @(posedge clk);
        #1;
        check(bank0_consumed == 16'd1 && !rd_valid,
              "expected-one bank retires exactly once before release");
        release_bank_task(1'b0, 4'ha);
        allocate_bank(1'b0, 4'hc, 16'd2);
        check(bank0_produced == 16'd0 && bank1_produced == 16'd2 &&
              dut.write_open_q == 2'b01,
              "release/reallocate reopens only the selected bank");
        write_word(1'b0, 4'hc, 32'hcccc_0000);
        check(bank0_produced == 16'd1 && dut.write_open_q[0],
              "reallocated bank accepts its new epoch without a bubble");

        // Both inactive banks have entry zero prefetched.  Select bank0,
        // consume it without a bubble, and select bank1 on exactly the edge
        // that pops bank0's final word.  Bank1 entry zero must be visible
        // immediately after that edge, so its transfer occurs on the very
        // next rising edge.  Address one must follow with rd_valid still high.
        reset_dut();
        allocate_bank(1'b0, 4'h1, 16'd2);
        write_word(1'b0, 4'h1, 32'h1111_0000);
        write_word(1'b0, 4'h1, 32'h1111_0001);
        commit_bank_task(1'b0, 4'h1);
        allocate_bank(1'b1, 4'h2, 16'd2);
        write_word(1'b1, 4'h2, 32'h2222_0000);
        write_word(1'b1, 4'h2, 32'h2222_0001);
        commit_bank_task(1'b1, 4'h2);
        wait(dut.lookahead_valid_q == 2'b11);

        rd_ready = 1'b1;
        select_reader(1'b0, 4'h1);
        check(rd_valid && rd_data == 32'h1111_0000 && !rd_last,
              "lookahead supplies old context entry zero");
        @(posedge clk);
        #1;
        check(rd_valid && rd_data == 32'h1111_0001 && rd_last,
              "old context address one follows entry zero without a gap");

        @(negedge clk);
        select_bank = 1'b1;
        select_epoch = 4'h2;
        select_valid = 1'b1;
        #1;
        check(select_ready,
              "new context selection is ready on old final pop edge");
        @(posedge clk);
        #1;
        check(reader_context_done,
              "old final pop marks context done during atomic handoff");
        check(rd_valid && rd_bank && rd_epoch == 4'h2 &&
              rd_data == 32'h2222_0000 && !rd_last,
              "new first word is valid immediately after old final pop");
        check(bank0_consumed == 16'd2 && bank1_consumed == 16'd0,
              "handoff edge consumes only the old final word");
        @(negedge clk);
        select_valid = 1'b0;
        @(posedge clk);
        #1;
        check(rd_valid && rd_bank && rd_epoch == 4'h2 &&
              rd_data == 32'h2222_0001 && rd_last,
              "new address one follows its lookahead first word without a gap");
        check(bank1_consumed == 16'd1,
              "new first word transfers on the next rising edge");
        @(posedge clk);
        #1;
        check(!rd_valid && reader_context_done && bank1_consumed == 16'd2,
              "new two-word context retires on consecutive transfers");
        release_bank_task(1'b0, 4'h1);
        release_bank_task(1'b1, 4'h2);
        check(!error_epoch && !error_overflow && !error_protocol,
              "zero-gap handoff completes without sticky errors");

        // expected=1 is a special last-marker case.  Its prefetched first
        // word must remain stable for arbitrary output backpressure.
        reset_dut();
        allocate_bank(1'b0, 4'h3, 16'd1);
        write_word(1'b0, 4'h3, 32'h3333_0000);
        commit_bank_task(1'b0, 4'h3);
        wait(dut.lookahead_valid_q[0]);
        rd_ready = 1'b0;
        select_reader(1'b0, 4'h3);
        check(rd_valid && rd_last && rd_data == 32'h3333_0000,
              "expected-one lookahead is valid and marked last");
        repeat (3) begin
            @(negedge clk);
            check(rd_valid && rd_last && rd_bank == 1'b0 &&
                  rd_epoch == 4'h3 && rd_data == 32'h3333_0000,
                  "first lookahead word remains stable under backpressure");
        end
        rd_ready = 1'b1;
        @(posedge clk);
        #1;
        check(!rd_valid && reader_context_done && bank0_consumed == 16'd1,
              "expected-one word pops exactly once");
        release_bank_task(1'b0, 4'h3);
        check(!error_epoch && !error_overflow && !error_protocol,
              "expected-one backpressure case has no sticky errors");

        // Reset first while a synchronous lookahead return is pending, then
        // again while a completed lookahead is valid.  Reallocation must not
        // expose either pre-reset word.
        reset_dut();
        allocate_bank(1'b1, 4'h4, 16'd2);
        write_word(1'b1, 4'h4, 32'h4444_0000);
        wait(dut.lookahead_pending_q[1]);
        check(!dut.lookahead_valid_q[1],
              "lookahead pending state is observable before RAM return");
        reset_dut();
        allocate_bank(1'b1, 4'h5, 16'd1);
        write_word(1'b1, 4'h5, 32'h5555_0000);
        commit_bank_task(1'b1, 4'h5);
        wait(dut.lookahead_valid_q[1]);
        check(dut.lookahead_valid_q[1] && !dut.lookahead_pending_q[1],
              "completed lookahead is valid before reset");
        reset_dut();
        allocate_bank(1'b1, 4'h6, 16'd1);
        write_word(1'b1, 4'h6, 32'h6666_0000);
        commit_bank_task(1'b1, 4'h6);
        wait(dut.lookahead_valid_q[1]);
        rd_ready = 1'b0;
        select_reader(1'b1, 4'h6);
        check(rd_valid && rd_data == 32'h6666_0000 && rd_epoch == 4'h6,
              "post-reset reallocation cannot hit stale lookahead data");
        rd_ready = 1'b1;
        @(posedge clk);
        #1;
        release_bank_task(1'b1, 4'h6);

        // A release while a lookahead is valid is necessarily premature and
        // must be backpressured.  After ordinary consume/release/reallocate,
        // a stale epoch selection must neither consume nor expose the new
        // lookahead; the correct epoch must still hit it afterwards.
        reset_dut();
        allocate_bank(1'b0, 4'h7, 16'd1);
        write_word(1'b0, 4'h7, 32'h7777_0000);
        commit_bank_task(1'b0, 4'h7);
        wait(dut.lookahead_valid_q[0]);
        @(negedge clk);
        release_bank = 1'b0;
        release_epoch = 4'h7;
        release_valid = 1'b1;
        #1;
        check(!release_ready,
              "release cannot discard a valid unconsumed lookahead");
        @(negedge clk);
        release_valid = 1'b0;
        check(dut.lookahead_valid_q[0] && bank_allocated[0],
              "premature release preserves lookahead and ownership");
        rd_ready = 1'b0;
        select_reader(1'b0, 4'h7);
        check(rd_valid && rd_data == 32'h7777_0000,
              "preserved lookahead remains selectable after early release");
        rd_ready = 1'b1;
        @(posedge clk);
        #1;
        release_bank_task(1'b0, 4'h7);

        allocate_bank(1'b0, 4'h8, 16'd1);
        write_word(1'b0, 4'h8, 32'h8888_0000);
        commit_bank_task(1'b0, 4'h8);
        wait(dut.lookahead_valid_q[0]);
        @(negedge clk);
        select_bank = 1'b0;
        select_epoch = 4'h7;
        select_valid = 1'b1;
        #1;
        check(!select_ready,
              "stale epoch cannot select a reallocated bank");
        @(posedge clk);
        #1;
        check(!rd_valid && !reader_active && bank0_consumed == 16'd0 &&
              dut.lookahead_valid_q[0],
              "wrong epoch does not consume or expose lookahead data");
        @(negedge clk);
        select_valid = 1'b0;
        check(error_epoch,
              "wrong epoch selection raises the sticky epoch error");
        rd_ready = 1'b0;
        select_reader(1'b0, 4'h8);
        check(rd_valid && rd_last && rd_epoch == 4'h8 &&
              rd_data == 32'h8888_0000,
              "correct epoch still hits lookahead after stale select rejection");
        rd_ready = 1'b1;
        @(posedge clk);
        #1;
        release_bank_task(1'b0, 4'h8);

        $display("=== tb_ifm_vector_epoch_buffer: %0d pass, %0d fail ===",
                 pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        repeat (1000) @(negedge clk);
        $display("[FAIL] timeout seen=%0d alloc=%b committed=%b", seen,
                 bank_allocated, bank_committed);
        $fatal(1);
    end
endmodule

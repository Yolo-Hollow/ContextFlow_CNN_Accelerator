`timescale 1ns / 1ps

module tb_ifm_context_epoch_frontend;
    localparam DATA_W = 16;
    localparam DEPTH = 8;
    localparam AW = 3;
    localparam EPOCH_W = 2;
    localparam CTX_DEPTH = 2;
    localparam CTX_AW = 1;
    localparam COLLECTOR_SLOTS = 4;

    reg clk = 1'b0;
    reg rst = 1'b1;

    reg feeder_start = 1'b0;
    reg [15:0] context_expected = 16'd0;
    wire feeder_start_ready;

    reg [DATA_W-1:0] vector_data = {DATA_W{1'b0}};
    reg vector_valid = 1'b0;
    wire vector_ready;
    reg vector_packet_done = 1'b0;

    reg compute_start = 1'b0;
    wire core_start;
    wire core_context_bank;
    wire [EPOCH_W-1:0] core_context_epoch;
    wire [15:0] core_context_expected;

    wire [DATA_W-1:0] stream_data;
    wire stream_valid;
    reg stream_ready = 1'b0;
    wire stream_bank;
    wire [EPOCH_W-1:0] stream_epoch;
    wire stream_last;

    reg array_retired_valid = 1'b0;
    reg array_retired_bank = 1'b0;
    reg [EPOCH_W-1:0] array_retired_epoch = {EPOCH_W{1'b0}};

    reg collector_done_valid = 1'b0;
    reg [EPOCH_W-1:0] collector_done_epoch = {EPOCH_W{1'b0}};

    wire [1:0] bank_allocated;
    wire [1:0] bank_committed;
    wire [EPOCH_W-1:0] bank0_epoch;
    wire [EPOCH_W-1:0] bank1_epoch;
    wire [15:0] bank0_available;
    wire [15:0] bank1_available;
    wire reader_active;
    wire [31:0] context_alloc_count;
    wire [31:0] input_issued_count;
    wire [31:0] array_retired_count;
    wire [31:0] collector_done_count;
    wire [31:0] bank_ownership_stall_cycles;
    wire [31:0] context_gap_cycles;
    wire [31:0] epoch_conflict_stall_cycles;
    wire [31:0] context_full_stall_cycles;
    wire [31:0] context_mismatch_count;
    wire error_epoch;
    wire error_overflow;
    wire error_vector_protocol;
    wire error_context_drop;
    wire error_retire_mismatch;
    wire error_collector_epoch;

    ifm_context_epoch_frontend #(
        .DATA_W(DATA_W),
        .DEPTH(DEPTH),
        .AW(AW),
        .EPOCH_W(EPOCH_W),
        .CTX_DEPTH(CTX_DEPTH),
        .CTX_AW(CTX_AW),
        .COLLECTOR_SLOTS(COLLECTOR_SLOTS)
    ) dut (
        .clk(clk),
        .rst(rst),
        .feeder_start(feeder_start),
        .context_expected(context_expected),
        .feeder_start_ready(feeder_start_ready),
        .context_alloc_sideband_ready(1'b1),
        .vector_data(vector_data),
        .vector_valid(vector_valid),
        .vector_ready(vector_ready),
        .vector_packet_done(vector_packet_done),
        .compute_start(compute_start),
        .core_ready(1'b1),
        .core_start(core_start),
        .core_context_bank(core_context_bank),
        .core_context_epoch(core_context_epoch),
        .core_context_expected(core_context_expected),
        .stream_data(stream_data),
        .stream_valid(stream_valid),
        .stream_ready(stream_ready),
        .stream_bank(stream_bank),
        .stream_epoch(stream_epoch),
        .stream_last(stream_last),
        .array_retired_valid(array_retired_valid),
        .array_retired_bank(array_retired_bank),
        .array_retired_epoch(array_retired_epoch),
        .collector_done_valid(collector_done_valid),
        .collector_done_epoch(collector_done_epoch),
        .bank_allocated(bank_allocated),
        .bank_committed(bank_committed),
        .bank0_epoch(bank0_epoch),
        .bank1_epoch(bank1_epoch),
        .bank0_available(bank0_available),
        .bank1_available(bank1_available),
        .reader_active(reader_active),
        .context_alloc_count(context_alloc_count),
        .input_issued_count(input_issued_count),
        .array_retired_count(array_retired_count),
        .collector_done_count(collector_done_count),
        .bank_ownership_stall_cycles(bank_ownership_stall_cycles),
        .context_gap_cycles(context_gap_cycles),
        .epoch_conflict_stall_cycles(epoch_conflict_stall_cycles),
        .context_full_stall_cycles(context_full_stall_cycles),
        .context_mismatch_count(context_mismatch_count),
        .error_epoch(error_epoch),
        .error_overflow(error_overflow),
        .error_vector_protocol(error_vector_protocol),
        .error_context_drop(error_context_drop),
        .error_retire_mismatch(error_retire_mismatch),
        .error_collector_epoch(error_collector_epoch)
    );

    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;
    integer stream_seen = 0;
    integer core_seen = 0;
    reg [DATA_W-1:0] expected_stream_data [0:7];
    reg [EPOCH_W-1:0] expected_stream_epoch [0:7];
    reg expected_stream_bank [0:7];
    reg expected_stream_last [0:7];
    reg [EPOCH_W-1:0] expected_core_epoch [0:4];
    reg expected_core_bank [0:4];
    reg [15:0] expected_core_count [0:4];

    task check;
        input cond;
        input [511:0] message;
        begin
            if (cond)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task pulse_feeder;
        input [15:0] count;
        begin
            @(negedge clk);
            context_expected = count;
            feeder_start = 1'b1;
            #1;
            check(feeder_start_ready,
                  "one-cycle feeder start is accepted at its source boundary");
            @(negedge clk);
            feeder_start = 1'b0;
        end
    endtask

    task pulse_compute;
        begin
            @(negedge clk);
            compute_start = 1'b1;
            @(negedge clk);
            compute_start = 1'b0;
        end
    endtask

    task send_vector;
        input [DATA_W-1:0] data;
        input is_last;
        begin
            while (!vector_ready)
                @(negedge clk);
            vector_data = data;
            vector_valid = 1'b1;
            vector_packet_done = is_last;
            #1;
            check(vector_ready, "vector is accepted atomically");
            @(negedge clk);
            vector_valid = 1'b0;
            vector_packet_done = 1'b0;
        end
    endtask

    task retire_context;
        input bank;
        input [EPOCH_W-1:0] epoch;
        begin
            @(negedge clk);
            array_retired_bank = bank;
            array_retired_epoch = epoch;
            array_retired_valid = 1'b1;
            @(negedge clk);
            array_retired_valid = 1'b0;
        end
    endtask

    task finish_collector;
        input [EPOCH_W-1:0] epoch;
        begin
            @(negedge clk);
            collector_done_epoch = epoch;
            collector_done_valid = 1'b1;
            @(negedge clk);
            collector_done_valid = 1'b0;
        end
    endtask

    task wait_alloc_count;
        input integer target;
        integer watchdog;
        begin
            watchdog = 0;
            while ((context_alloc_count != target) && (watchdog < 100)) begin
                watchdog = watchdog + 1;
                @(negedge clk);
            end
            check(context_alloc_count == target,
                  "captured feeder pulse eventually allocates a context bank");
        end
    endtask

    task wait_core_count;
        input integer target;
        integer watchdog;
        begin
            watchdog = 0;
            while ((core_seen != target) && (watchdog < 100)) begin
                watchdog = watchdog + 1;
                @(negedge clk);
            end
            check(core_seen == target,
                  "captured compute pulse eventually selects its context");
        end
    endtask

    task wait_stream_count;
        input integer target;
        integer watchdog;
        begin
            watchdog = 0;
            while ((stream_seen != target) && (watchdog < 100)) begin
                watchdog = watchdog + 1;
                @(negedge clk);
            end
            check(stream_seen == target,
                  "expected stream vectors leave under ready/valid control");
        end
    endtask

    task wait_bank_free;
        input bank;
        integer watchdog;
        begin
            watchdog = 0;
            while (bank_allocated[bank] && (watchdog < 100)) begin
                watchdog = watchdog + 1;
                @(negedge clk);
            end
            check(!bank_allocated[bank],
                  "array retirement eventually releases the tagged bank");
        end
    endtask

    // Handshake scoreboards are sampled at the active clock edge.  Testbench
    // stimulus changes only at falling edges, avoiding scheduling races.
    always @(posedge clk) begin
        if (!rst && stream_valid && stream_ready) begin
            if (stream_seen < 8) begin
                check(stream_data == expected_stream_data[stream_seen],
                      "stream data preserves context and vector order");
                check(stream_epoch == expected_stream_epoch[stream_seen],
                      "stream carries the selected context epoch");
                check(stream_bank == expected_stream_bank[stream_seen],
                      "stream carries the selected context bank");
                check(stream_last == expected_stream_last[stream_seen],
                      "stream last marks exactly the input-issued boundary");
            end else begin
                check(1'b0, "unexpected extra stream vector");
            end
            stream_seen = stream_seen + 1;
        end
    end

    always @(negedge clk) begin
        if (!rst && core_start) begin
            if (core_seen < 5) begin
                check(core_context_epoch == expected_core_epoch[core_seen],
                      "core start carries the expected epoch");
                check(core_context_bank == expected_core_bank[core_seen],
                      "core start carries the expected bank");
                check(core_context_expected == expected_core_count[core_seen],
                      "core start carries the expected vector count");
            end else begin
                check(1'b0, "unexpected extra core start");
            end
            core_seen = core_seen + 1;
        end
    end

    integer alloc_before;
    reg [DATA_W-1:0] held_data;
    reg [EPOCH_W-1:0] held_epoch;
    reg held_bank;
    reg held_last;
    initial begin
        expected_stream_data[0] = 16'ha001;
        expected_stream_data[1] = 16'ha002;
        expected_stream_data[2] = 16'ha003;
        expected_stream_data[3] = 16'hb001;
        expected_stream_data[4] = 16'hb002;
        expected_stream_data[5] = 16'hc001;
        expected_stream_data[6] = 16'hd001;
        expected_stream_data[7] = 16'he001;

        expected_stream_epoch[0] = 2'd1;
        expected_stream_epoch[1] = 2'd1;
        expected_stream_epoch[2] = 2'd1;
        expected_stream_epoch[3] = 2'd2;
        expected_stream_epoch[4] = 2'd2;
        expected_stream_epoch[5] = 2'd3;
        expected_stream_epoch[6] = 2'd0;
        expected_stream_epoch[7] = 2'd2;

        expected_stream_bank[0] = 1'b0;
        expected_stream_bank[1] = 1'b0;
        expected_stream_bank[2] = 1'b0;
        expected_stream_bank[3] = 1'b1;
        expected_stream_bank[4] = 1'b1;
        expected_stream_bank[5] = 1'b0;
        expected_stream_bank[6] = 1'b1;
        expected_stream_bank[7] = 1'b0;

        expected_stream_last[0] = 1'b0;
        expected_stream_last[1] = 1'b0;
        expected_stream_last[2] = 1'b1;
        expected_stream_last[3] = 1'b0;
        expected_stream_last[4] = 1'b1;
        expected_stream_last[5] = 1'b1;
        expected_stream_last[6] = 1'b1;
        expected_stream_last[7] = 1'b1;

        expected_core_epoch[0] = 2'd1;
        expected_core_epoch[1] = 2'd2;
        expected_core_epoch[2] = 2'd3;
        expected_core_epoch[3] = 2'd0;
        // Epoch 1 remains collector-live after wrap, so the allocator skips
        // it and safely reuses epoch 2.
        expected_core_epoch[4] = 2'd2;

        expected_core_bank[0] = 1'b0;
        expected_core_bank[1] = 1'b1;
        expected_core_bank[2] = 1'b0;
        expected_core_bank[3] = 1'b1;
        expected_core_bank[4] = 1'b0;

        expected_core_count[0] = 16'd3;
        expected_core_count[1] = 16'd2;
        expected_core_count[2] = 16'd1;
        expected_core_count[3] = 16'd1;
        expected_core_count[4] = 16'd1;

        repeat (4) @(negedge clk);
        rst = 1'b0;

        // The compute request precedes allocation and is only one clock wide.
        // It must remain pending until the context can be selected.
        pulse_compute();
        pulse_feeder(16'd3);
        wait_alloc_count(1);
        wait_core_count(1);
        check(bank_allocated == 2'b01 && bank0_epoch == 2'd1,
              "first context owns bank0 at epoch 1");

        stream_ready = 1'b0;
        send_vector(16'ha001, 1'b0);
        send_vector(16'ha002, 1'b0);
        wait(stream_valid);
        @(negedge clk);
        held_data = stream_data;
        held_epoch = stream_epoch;
        held_bank = stream_bank;
        held_last = stream_last;
        repeat (3) begin
            @(negedge clk);
            check(stream_valid && stream_data == held_data &&
                  stream_epoch == held_epoch && stream_bank == held_bank &&
                  stream_last == held_last,
                  "stream payload and tag stay stable under backpressure");
        end

        // Capture both one-cycle starts while bank0 is still filling/reading.
        // Allocation waits for the packet boundary; selection waits for the
        // final vector handshake from context A.
        pulse_feeder(16'd2);
        pulse_compute();
        alloc_before = context_alloc_count;
        repeat (2) @(negedge clk);
        check(context_alloc_count == alloc_before,
              "second feeder pulse is held while the first fill is active");
        check(core_seen == 1,
              "second compute pulse is held while the first reader is active");

        send_vector(16'ha003, 1'b1);
        wait_alloc_count(2);
        check(bank_allocated == 2'b11 && bank1_epoch == 2'd2,
              "second context allocates the inactive bank at epoch 2");
        send_vector(16'hb001, 1'b0);
        send_vector(16'hb002, 1'b1);
        wait(bank_committed == 2'b11);
        check(core_seen == 1,
              "pending compute cannot select bank1 before bank0 final pop");

        stream_ready = 1'b1;
        wait_stream_count(1);
        @(negedge clk);
        stream_ready = 1'b0;
        wait(stream_valid);
        held_data = stream_data;
        held_epoch = stream_epoch;
        held_bank = stream_bank;
        held_last = stream_last;
        repeat (2) begin
            @(negedge clk);
            check(stream_valid && stream_data == held_data &&
                  stream_epoch == held_epoch && stream_bank == held_bank &&
                  stream_last == held_last,
                  "read-side stall holds the next vector without duplication");
        end
        stream_ready = 1'b1;
        wait_stream_count(3);
        wait_core_count(2);
        check(input_issued_count == 32'd1,
              "context A last handshake increments input-issued exactly once");
        check(bank_allocated[0],
              "fully issued bank0 remains owned before array retirement");
        repeat (2) @(negedge clk);
        check(bank_allocated[0],
              "time alone cannot release a bank before array retirement");

        retire_context(1'b0, 2'd1);
        wait_bank_free(1'b0);
        // Keep epoch 1 collector-live across the epoch wrap.

        wait_stream_count(5);
        check(input_issued_count == 32'd2,
              "context B last handshake increments input-issued exactly once");
        check(bank_allocated[1],
              "bank1 remains owned after issue and before retirement");
        retire_context(1'b1, 2'd2);
        wait_bank_free(1'b1);
        finish_collector(2'd2);

        // Context C reuses bank0 and advances to epoch 3.
        pulse_compute();
        pulse_feeder(16'd1);
        wait_alloc_count(3);
        wait_core_count(3);
        check(bank_allocated[0] && bank0_epoch == 2'd3,
              "retired bank0 is safely reused by epoch 3");
        send_vector(16'hc001, 1'b1);
        wait_stream_count(6);
        retire_context(1'b0, 2'd3);
        wait_bank_free(1'b0);
        finish_collector(2'd3);

        // Context D reuses bank1 after the two-bit epoch wraps to zero.
        pulse_compute();
        pulse_feeder(16'd1);
        wait_alloc_count(4);
        wait_core_count(4);
        check(bank_allocated[1] && bank1_epoch == 2'd0,
              "epoch counter wraps without resetting bank ownership");
        send_vector(16'hd001, 1'b1);
        wait_stream_count(7);
        retire_context(1'b1, 2'd0);
        wait_bank_free(1'b1);
        finish_collector(2'd0);

        // The next candidate is epoch 1, but collector A is deliberately
        // still live.  Allocation must advance to epoch 2, not alias epoch 1.
        pulse_compute();
        pulse_feeder(16'd1);
        wait_alloc_count(5);
        wait_core_count(5);
        check(epoch_conflict_stall_cycles != 32'd0,
              "allocator observes and skips a live collector epoch on wrap");
        check(bank_allocated[0] && bank0_epoch == 2'd2,
              "post-wrap context uses the first conflict-free epoch");
        send_vector(16'he001, 1'b1);
        wait_stream_count(8);
        retire_context(1'b0, 2'd2);
        wait_bank_free(1'b0);
        finish_collector(2'd2);
        finish_collector(2'd1);

        repeat (2) @(negedge clk);
        check(input_issued_count == 32'd5,
              "all five input-issued boundaries are counted");
        check(array_retired_count == 32'd5,
              "all five tagged array retirements are counted");
        check(collector_done_count == 32'd5,
              "out-of-order but valid collector epochs are all counted");
        check(context_alloc_count == 32'd5,
              "all feeder short pulses allocate exactly one context");
        check(context_mismatch_count == 32'd0,
              "valid lifecycle has no context mismatch");
        check(!error_epoch && !error_overflow && !error_vector_protocol &&
              !error_context_drop && !error_retire_mismatch &&
              !error_collector_epoch,
              "valid dual-bank lifecycle leaves every sticky error clear");

        // A completion for a non-live epoch must be diagnosed, proving that
        // collector_done is checked by epoch rather than treated as a pulse.
        finish_collector(2'd3);
        check(error_collector_epoch && error_epoch,
              "non-live collector epoch raises the sticky epoch error");
        check(context_mismatch_count == 32'd1,
              "non-live collector epoch increments mismatch telemetry");

        $display("=== tb_ifm_context_epoch_frontend: %0d pass, %0d fail ===",
                 pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        repeat (2000) @(negedge clk);
        $display("[FAIL] timeout alloc=%0d core=%0d stream=%0d banks=%b",
                 context_alloc_count, core_seen, stream_seen, bank_allocated);
        $fatal(1);
    end
endmodule

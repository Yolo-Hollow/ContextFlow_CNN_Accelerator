`timescale 1ns / 1ps

module tb_context_event_fifo;
    localparam WIDTH = 24;
    localparam DEPTH = 4;
    localparam AW = 2;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg in_valid = 1'b0;
    wire in_ready;
    reg [WIDTH-1:0] in_data = {WIDTH{1'b0}};
    wire out_valid;
    reg out_ready = 1'b0;
    wire [WIDTH-1:0] out_data;
    wire empty;
    wire full;
    wire [AW:0] level;
    wire overflow_attempt;
    wire overflow_sticky;
    wire legacy_in_ready;
    wire legacy_out_valid;
    wire [WIDTH-1:0] legacy_out_data;
    wire legacy_empty;
    wire legacy_full;
    wire [AW:0] legacy_level;
    wire legacy_overflow_attempt;
    wire legacy_overflow_sticky;

    context_event_fifo #(
        .WIDTH(WIDTH),
        .DEPTH(DEPTH),
        .AW(AW),
        .REGISTERED_HEAD(1)
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_data(in_data),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_data(out_data),
        .empty(empty),
        .full(full),
        .level(level),
        .overflow_attempt(overflow_attempt),
        .overflow_sticky(overflow_sticky)
    );

    // Run the default legacy mode in lockstep.  Every directed and random
    // transaction below must remain cycle-for-cycle equivalent.
    context_event_fifo #(
        .WIDTH(WIDTH),
        .DEPTH(DEPTH),
        .AW(AW)
    ) dut_legacy (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in_ready(legacy_in_ready),
        .in_data(in_data),
        .out_valid(legacy_out_valid),
        .out_ready(out_ready),
        .out_data(legacy_out_data),
        .empty(legacy_empty),
        .full(legacy_full),
        .level(legacy_level),
        .overflow_attempt(legacy_overflow_attempt),
        .overflow_sticky(legacy_overflow_sticky)
    );

    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;
    integer i;
    integer produced;
    integer consumed;
    integer cycles;
    reg [15:0] lfsr;
    reg push_fire_sample;
    reg pop_fire_sample;

    always @(negedge clk) begin
        #2;
        if (!rst &&
            ({in_ready, out_valid, out_data, empty, full, level,
              overflow_attempt, overflow_sticky} !==
             {legacy_in_ready, legacy_out_valid, legacy_out_data,
              legacy_empty, legacy_full, legacy_level,
              legacy_overflow_attempt, legacy_overflow_sticky})) begin
            fail_count = fail_count + 1;
            $display("[FAIL] registered/default FIFO modes diverged");
        end
    end

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

    function [WIDTH-1:0] event_value;
        input integer index;
        begin
            event_value = 24'h510000 + index;
        end
    endfunction

    task reset_dut;
        begin
            @(negedge clk);
            rst = 1'b1;
            in_valid = 1'b0;
            out_ready = 1'b0;
            repeat (3) @(negedge clk);
            rst = 1'b0;
            @(negedge clk);
        end
    endtask

    task push_one;
        input integer index;
        begin
            @(negedge clk);
            in_data = event_value(index);
            in_valid = 1'b1;
            #1;
            check(in_ready, "ordinary push is accepted");
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task pop_one;
        input integer index;
        begin
            @(negedge clk);
            out_ready = 1'b1;
            #1;
            check(out_valid, "ordinary pop is available");
            check(out_data == event_value(index), "event FIFO order is preserved");
            @(negedge clk);
            out_ready = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        check(empty && !full && level == 0, "synchronous reset leaves FIFO empty");
        check(in_ready && !out_valid && out_data == 0,
              "empty FIFO has ready input and invalid zero output");
        check(!overflow_sticky && !overflow_attempt,
              "overflow diagnostics reset clear");

        // Fill the queue, then hold a fifth event across full backpressure.
        for (i = 0; i < DEPTH; i = i + 1)
            push_one(i);
        check(full && level == DEPTH && !in_ready,
              "full FIFO deasserts input ready");
        check(out_valid && out_data == event_value(0),
              "full FIFO keeps the oldest event at its head");

        @(negedge clk);
        in_data = event_value(4);
        in_valid = 1'b1;
        out_ready = 1'b0;
        #1;
        check(overflow_attempt && !in_ready,
              "submission against full FIFO raises overflow attempt");
        @(posedge clk);
        #1;
        check(overflow_sticky, "overflow attempt sets sticky diagnostic");

        // Full remains not-ready even if the head is accepted that cycle.
        // Keeping valid asserted allows the producer to retry on the next
        // cycle, proving the standard handshake does not lose the event.
        @(negedge clk);
        out_ready = 1'b1;
        #1;
        check(out_valid && out_data == event_value(0),
              "full-queue pop observes original head");
        check(!in_ready && overflow_attempt,
              "full queue does not accept an unreserved same-cycle push");
        @(posedge clk);
        #1;
        check(level == DEPTH-1 && in_ready,
              "pop from full queue creates space on following cycle");
        check(out_data == event_value(1), "head advances after full-queue pop");
        out_ready = 1'b0;
        @(posedge clk);
        #1;
        check(full && level == DEPTH,
              "held input event is accepted when ready returns");
        @(negedge clk);
        in_valid = 1'b0;

        pop_one(1);
        pop_one(2);
        pop_one(3);
        pop_one(4);
        check(empty && level == 0, "held full-queue event drains without loss");

        // Reset clears sticky state.  First replace the sole resident word in
        // one cycle; the registered head must bypass the same-edge RAM write.
        reset_dut();
        check(!overflow_sticky, "reset clears overflow sticky");
        push_one(8);
        @(negedge clk);
        in_valid = 1'b1;
        in_data = event_value(9);
        out_ready = 1'b1;
        #1;
        check(in_ready && out_valid && out_data == event_value(8),
              "count-one exchange returns the original head");
        @(posedge clk);
        #1;
        check(level == 1 && out_valid && out_data == event_value(9),
              "count-one exchange installs its replacement without a bubble");
        @(negedge clk);
        in_valid = 1'b0;
        out_ready = 1'b0;
        pop_one(9);
        check(empty, "count-one replacement drains exactly once");

        // Exercise simultaneous push/pop at count greater than one and
        // confirm occupancy and ordering are unchanged.  This takes the
        // explicit next-head RAM prefetch branch in registered mode.
        reset_dut();
        push_one(10);
        push_one(11);
        @(negedge clk);
        in_valid = 1'b1;
        in_data = event_value(12);
        out_ready = 1'b1;
        #1;
        check(in_ready && out_valid, "non-full FIFO permits simultaneous push and pop");
        check(out_data == event_value(10), "simultaneous exchange returns old head");
        @(posedge clk);
        #1;
        check(level == 2 && out_data == event_value(11),
              "simultaneous exchange preserves occupancy and advances head");
        @(negedge clk);
        in_valid = 1'b0;
        out_ready = 1'b0;
        pop_one(11);
        pop_one(12);
        check(empty, "simultaneous exchange drains in order");

        // Random compliant producer/consumer backpressure over several wraps.
        reset_dut();
        produced = 0;
        consumed = 0;
        cycles = 0;
        lfsr = 16'h5a3c;
        while ((consumed < 96) && (cycles < 4000)) begin
            @(negedge clk);
            in_valid = 1'b0;
            out_ready = 1'b0;
            if ((produced < 96) && in_ready && (lfsr[0] || lfsr[3])) begin
                in_valid = 1'b1;
                in_data = event_value(100 + produced);
            end
            if (out_valid && (lfsr[1] || lfsr[5]))
                out_ready = 1'b1;
            #1;
            push_fire_sample = in_valid && in_ready;
            pop_fire_sample = out_valid && out_ready;
            if (pop_fire_sample)
                check(out_data == event_value(100 + consumed),
                      "random backpressure preserves exact event order");
            lfsr = {lfsr[14:0],
                    lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            @(posedge clk);
            #1;
            if (push_fire_sample)
                produced = produced + 1;
            if (pop_fire_sample)
                consumed = consumed + 1;
            cycles = cycles + 1;
        end
        @(negedge clk);
        in_valid = 1'b0;
        out_ready = 1'b0;
        check(produced == 96 && consumed == 96,
              "random phase transfers every event exactly once");
        check(empty && level == 0, "random phase finishes empty");
        check(!overflow_sticky,
              "compliant random producer never attempts overflow");

        $display("=== tb_context_event_fifo: %0d pass, %0d fail ===",
                 pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        repeat (10000) @(negedge clk);
        $display("[FAIL] timeout level=%0d produced=%0d consumed=%0d",
                 level, produced, consumed);
        $fatal(1);
    end
endmodule

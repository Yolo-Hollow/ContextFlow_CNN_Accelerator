`timescale 1ns / 1ps

module tb_compute_pipe_telemetry;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg soft_reset = 1'b0;

    reg compute_gap_pulse = 1'b0;
    reg preload_commit_pulse = 1'b0;
    reg preload_hit_pulse = 1'b0;
    reg preload_miss_pulse = 1'b0;
    reg eligible_handoff_pulse = 1'b0;
    reg next_cycle_hit_pulse = 1'b0;
    reg extra_gap_pulse = 1'b0;
    reg [5:0] wait_reason_pulse = 6'b000000;
    reg protocol_error_pulse = 1'b0;

    wire [31:0] compute_gap_count;
    wire [31:0] preload_commit_count;
    wire [31:0] preload_hit_count;
    wire [31:0] preload_miss_count;
    wire [31:0] eligible_handoff_count;
    wire [31:0] next_cycle_hit_count;
    wire [31:0] extra_gap_count;
    wire [31:0] wait_bank_retire_count;
    wire [31:0] wait_weight_count;
    wire [31:0] wait_ifm_count;
    wire [31:0] wait_psum_count;
    wire [31:0] wait_collector_output_count;
    wire [31:0] wait_control_count;
    wire [31:0] protocol_error_count;

    integer pass_count = 0;
    integer fail_count = 0;
    integer reason_index;

    always #5 clk = ~clk;

    compute_pipe_telemetry dut (
        .clk(clk),
        .rst(rst),
        .soft_reset(soft_reset),
        .compute_gap_pulse(compute_gap_pulse),
        .preload_commit_pulse(preload_commit_pulse),
        .preload_hit_pulse(preload_hit_pulse),
        .preload_miss_pulse(preload_miss_pulse),
        .eligible_handoff_pulse(eligible_handoff_pulse),
        .next_cycle_hit_pulse(next_cycle_hit_pulse),
        .extra_gap_pulse(extra_gap_pulse),
        .wait_reason_pulse(wait_reason_pulse),
        .protocol_error_pulse(protocol_error_pulse),
        .compute_gap_count(compute_gap_count),
        .preload_commit_count(preload_commit_count),
        .preload_hit_count(preload_hit_count),
        .preload_miss_count(preload_miss_count),
        .eligible_handoff_count(eligible_handoff_count),
        .next_cycle_hit_count(next_cycle_hit_count),
        .extra_gap_count(extra_gap_count),
        .wait_bank_retire_count(wait_bank_retire_count),
        .wait_weight_count(wait_weight_count),
        .wait_ifm_count(wait_ifm_count),
        .wait_psum_count(wait_psum_count),
        .wait_collector_output_count(wait_collector_output_count),
        .wait_control_count(wait_control_count),
        .protocol_error_count(protocol_error_count)
    );

    task check;
        input condition;
        input [511:0] message;
        begin
            if (condition)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task clear_event_inputs;
        begin
            compute_gap_pulse = 1'b0;
            preload_commit_pulse = 1'b0;
            preload_hit_pulse = 1'b0;
            preload_miss_pulse = 1'b0;
            eligible_handoff_pulse = 1'b0;
            next_cycle_hit_pulse = 1'b0;
            extra_gap_pulse = 1'b0;
            wait_reason_pulse = 6'b000000;
            protocol_error_pulse = 1'b0;
        end
    endtask

    task advance_event;
        begin
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_event_inputs();
        end
    endtask

    task check_all_zero;
        begin
            check(compute_gap_count == 0, "compute gap reset");
            check(preload_commit_count == 0, "preload commit reset");
            check(preload_hit_count == 0, "preload hit reset");
            check(preload_miss_count == 0, "preload miss reset");
            check(eligible_handoff_count == 0,
                  "eligible handoff reset");
            check(next_cycle_hit_count == 0, "next-cycle hit reset");
            check(extra_gap_count == 0, "extra gap reset");
            check(wait_bank_retire_count == 0, "bank-retire wait reset");
            check(wait_weight_count == 0, "weight wait reset");
            check(wait_ifm_count == 0, "IFM wait reset");
            check(wait_psum_count == 0, "PSUM wait reset");
            check(wait_collector_output_count == 0,
                  "collector/output wait reset");
            check(wait_control_count == 0, "control wait reset");
            check(protocol_error_count == 0, "protocol error reset");
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        check_all_zero();

        // Independent event counters may all advance in the same cycle.
        compute_gap_pulse = 1'b1;
        preload_commit_pulse = 1'b1;
        preload_hit_pulse = 1'b1;
        preload_miss_pulse = 1'b1;
        eligible_handoff_pulse = 1'b1;
        next_cycle_hit_pulse = 1'b1;
        extra_gap_pulse = 1'b1;
        wait_reason_pulse = 6'b000001;
        advance_event();
        check(compute_gap_count == 1, "compute-gap pulse counted");
        check(preload_commit_count == 1, "preload commit counted");
        check(preload_hit_count == 1, "preload hit counted");
        check(preload_miss_count == 1, "preload miss counted");
        check(eligible_handoff_count == 1, "eligible handoff counted");
        check(next_cycle_hit_count == 1, "next-cycle hit counted");
        check(extra_gap_count == 1, "extra-gap pulse counted");
        check(wait_bank_retire_count == 1,
              "bank-retire one-hot reason counted");

        // Exercise every one-hot wait-reason bit exactly once.
        for (reason_index = 1; reason_index < 6;
             reason_index = reason_index + 1) begin
            wait_reason_pulse = 6'b000001 << reason_index;
            advance_event();
        end
        check(wait_bank_retire_count == 1, "wait reason bit 0 isolated");
        check(wait_weight_count == 1, "wait reason bit 1 isolated");
        check(wait_ifm_count == 1, "wait reason bit 2 isolated");
        check(wait_psum_count == 1, "wait reason bit 3 isolated");
        check(wait_collector_output_count == 1,
              "wait reason bit 4 isolated");
        check(wait_control_count == 1, "wait reason bit 5 isolated");
        check(protocol_error_count == 0,
              "legal one-hot waits do not report protocol errors");

        // A multi-bit reason is rejected instead of double counting.
        wait_reason_pulse = 6'b001010;
        advance_event();
        check(wait_weight_count == 1 && wait_psum_count == 1,
              "invalid wait reason has no wait-counter side effect");
        check(protocol_error_count == 1,
              "invalid wait reason increments protocol error");

        // Two simultaneous protocol-error sources count one event cycle.
        wait_reason_pulse = 6'b110000;
        protocol_error_pulse = 1'b1;
        advance_event();
        check(wait_collector_output_count == 1 &&
              wait_control_count == 1,
              "invalid combined reason remains rejected");
        check(protocol_error_count == 2,
              "coincident protocol sources count once");

        protocol_error_pulse = 1'b1;
        advance_event();
        check(protocol_error_count == 3,
              "explicit protocol error pulse counted");

        // soft_reset wins over every event pulse.
        soft_reset = 1'b1;
        compute_gap_pulse = 1'b1;
        preload_commit_pulse = 1'b1;
        preload_hit_pulse = 1'b1;
        preload_miss_pulse = 1'b1;
        eligible_handoff_pulse = 1'b1;
        next_cycle_hit_pulse = 1'b1;
        extra_gap_pulse = 1'b1;
        wait_reason_pulse = 6'b111111;
        protocol_error_pulse = 1'b1;
        @(posedge clk);
        #1;
        check_all_zero();
        @(negedge clk);
        soft_reset = 1'b0;
        clear_event_inputs();

        compute_gap_pulse = 1'b1;
        wait_reason_pulse = 6'b000100;
        advance_event();
        check(compute_gap_count == 1 && wait_ifm_count == 1,
              "counting resumes after soft reset");

        // Deposit all-ones in three real 32-bit counters to verify natural
        // modulo-2^32 behavior without simulating four billion cycles.
        dut.compute_gap_count = 32'hffff_ffff;
        dut.wait_ifm_count = 32'hffff_ffff;
        dut.protocol_error_count = 32'hffff_ffff;
        compute_gap_pulse = 1'b1;
        wait_reason_pulse = 6'b000100;
        protocol_error_pulse = 1'b1;
        advance_event();
        check(compute_gap_count == 0, "compute-gap counter wraps at 32 bits");
        check(wait_ifm_count == 0, "wait counter wraps at 32 bits");
        check(protocol_error_count == 0,
              "protocol-error counter wraps at 32 bits");

        // Hard reset has highest priority and also ignores coincident events.
        rst = 1'b1;
        compute_gap_pulse = 1'b1;
        preload_commit_pulse = 1'b1;
        wait_reason_pulse = 6'b000010;
        protocol_error_pulse = 1'b1;
        @(posedge clk);
        #1;
        check_all_zero();
        @(negedge clk);
        rst = 1'b0;
        clear_event_inputs();

        preload_miss_pulse = 1'b1;
        advance_event();
        check(preload_miss_count == 1,
              "counting resumes after hard reset");

        $display("=== tb_compute_pipe_telemetry: %0d pass, %0d fail ===",
                 pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "timeout");
    end

endmodule

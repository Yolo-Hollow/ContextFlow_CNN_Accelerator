`timescale 1ns / 1ps

// Focused scheduler-only verification for the continuous tagged K-pass
// handoff.  It covers both acknowledgement orderings required by the real
// frontend: acceptance on the old context's completion edge, and completion
// several cycles before acceptance.
module tb_layer_scheduler_fast_context_handoff;
    localparam K_TILE = 18;
    localparam COUT_TILE = 16;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;
    reg bias_load_done = 1'b0;
    reg weight_load_done = 1'b0;
    reg feeder_done = 1'b0;
    reg feeder_compute_ready = 1'b0;
    reg compute_fire = 1'b0;
    reg compute_start_accepted = 1'b0;
    reg compute_done = 1'b0;
    reg collector_final_done = 1'b0;
    reg collector_context_active = 1'b0;
    reg collector_context_wr_bank = 1'b0;

    wire busy;
    wire done;
    wire [13:0] pass_base_k;
    wire [10:0] cout_base;
    wire [10:0] cout_valid;
    wire [15:0] num_pixels_out;
    wire is_first_pass;
    wire is_final_pass;
    wire use_ext_psum;
    wire use_psum_stream;
    wire psum_wr_bank;
    wire psum_rd_bank;
    wire bias_load_start;
    wire weight_load_start;
    wire feeder_start;
    wire compute_start;
    wire [13:0] feeder_pass_base_k;
    wire [15:0] feeder_k_pass;
    wire perf_prefetch_start;
    wire perf_prefetch_hit;

    integer fail = 0;
    integer cycle_count = 0;
    integer compute_start_count = 0;
    integer prefetch_start_count = 0;
    integer prefetch_hit_count = 0;
    integer comp_start_state_cycles = 0;
    integer prefetch_commit_state_cycles = 0;
    integer first_accept_cycle = -1;
    integer first_handoff_cycle = -1;
    integer first_new_fire_cycle = -1;
    integer second_done_cycle = -1;
    integer second_handoff_cycle = -1;
    reg compute_start_d = 1'b0;

    layer_scheduler_stream #(
        .K_TILE(K_TILE),
        .COUT_TILE(COUT_TILE),
        .ENABLE_FAST_CONTEXT_HANDOFF(1)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done),
        .k_total(14'd54), .cout_total(11'd16), .num_pixels(16'd52),
        .pass_base_k(pass_base_k), .cout_base(cout_base),
        .cout_valid(cout_valid), .num_pixels_out(num_pixels_out),
        .is_first_pass(is_first_pass), .is_final_pass(is_final_pass),
        .use_ext_psum(use_ext_psum), .use_psum_stream(use_psum_stream),
        .psum_wr_bank(psum_wr_bank), .psum_rd_bank(psum_rd_bank),
        .bias_load_start(bias_load_start), .bias_load_done(bias_load_done),
        .weight_load_start(weight_load_start),
        .weight_load_done(weight_load_done),
        .feeder_start(feeder_start), .feeder_start_ready(1'b1),
        .feeder_done(feeder_done),
        .feeder_compute_ready(feeder_compute_ready),
        .feeder_overlap_mode(1'b1),
        .raw_hwc_mode(1'b1),
        .early_drain_enable(1'b1),
        .pass_prefetch_enable(1'b1),
        .during_compute_prefetch_enable(1'b1),
        .psum_stream_overlap_enable(1'b1),
        .continuous_psum_enable(1'b1),
        .collector_ctx_ready(1'b1),
        .collector_partial_credit(1'b1),
        .collector_context_active(collector_context_active),
        .collector_context_wr_bank(collector_context_wr_bank),
        .collector_context_is_final(1'b0),
        .collector_final_done(collector_final_done),
        .psum_drain_data_ready(1'b1),
        .psum_drain_packet_fire(1'b0),
        .compute_fire(compute_fire),
        .compute_start(compute_start),
        .compute_start_accepted(compute_start_accepted),
        .compute_done(compute_done),
        .psum_drain_start(), .psum_drain_done(1'b0),
        .feeder_pass_base_k(feeder_pass_base_k),
        .feeder_k_pass(feeder_k_pass),
        .perf_prefetch_start(perf_prefetch_start),
        .perf_prefetch_weight_done(), .perf_prefetch_feed_done(),
        .perf_prefetch_hit(perf_prefetch_hit), .perf_prefetch_miss(),
        .perf_prefetch_stall(),
        .perf_psumovl_start(), .perf_psumovl_hit(),
        .perf_psumovl_wait_psum(),
        .perf_stage_bias(), .perf_stage_weight(), .perf_stage_feeder(),
        .perf_stage_compute(), .perf_stage_drain()
    );

    always #5 clk = ~clk;

    // The focused test does not model payloads.  Each loader accepts a start
    // and returns completion at the following rising edge.
    always @(negedge clk) begin
        bias_load_done = bias_load_start;
        weight_load_done = weight_load_start;
        feeder_done = feeder_start;
        feeder_compute_ready = feeder_start;
    end

    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            compute_start_count <= 0;
            prefetch_start_count <= 0;
            prefetch_hit_count <= 0;
            comp_start_state_cycles <= 0;
            prefetch_commit_state_cycles <= 0;
            compute_start_d <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (compute_start) begin
                compute_start_count <= compute_start_count + 1;
                if (compute_start_d) begin
                    $display("[FAIL] compute_start was not a one-cycle request");
                    fail = fail + 1;
                end
            end
            compute_start_d <= compute_start;
            if (perf_prefetch_start)
                prefetch_start_count <= prefetch_start_count + 1;
            if (perf_prefetch_hit)
                prefetch_hit_count <= prefetch_hit_count + 1;
            if (dut.state == dut.ST_COMP_START)
                comp_start_state_cycles <= comp_start_state_cycles + 1;
            if (dut.state == dut.ST_PREFETCH_COMMIT)
                prefetch_commit_state_cycles <=
                    prefetch_commit_state_cycles + 1;
        end
    end

    task check_value;
        input integer got;
        input integer expected;
        input [255:0] label;
        begin
            if (got !== expected) begin
                $display("[FAIL] %0s got=%0d expected=%0d",
                         label, got, expected);
                fail = fail + 1;
            end
        end
    endtask

    task pulse_fire;
        begin
            @(negedge clk);
            compute_fire = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            compute_fire = 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // Initial context uses the legacy COMP_START pulse.
        wait(compute_start === 1'b1);
        check_value(pass_base_k, 0, "initial request pass");
        pulse_fire();

        // Pass 0 -> 1: the real controller accepts the next context on the
        // old context's final-fire edge.  Its registered old-done pulse then
        // shares the following edge with the first new compute_fire.
        wait(prefetch_start_count == 1);
        check_value(feeder_pass_base_k, 18, "first prefetch base");
        check_value(feeder_k_pass, 1, "first prefetch index");
        wait(dut.prefetch_weight_done && dut.prefetch_feed_done);
        @(negedge clk);
        compute_fire = 1'b1;
        compute_start_accepted = 1'b1;
        // Acceptance has already installed the new collector descriptor.  It
        // therefore appears active on next_wr_bank at the scheduler edge;
        // acceptance, rather than a post-admission safety recheck, must drive
        // the transition.
        collector_context_active = 1'b1;
        collector_context_wr_bank = 1'b1;
        @(posedge clk);
        #1;
        first_accept_cycle = cycle_count;
        check_value(pass_base_k, 0, "final-fire edge holds old pass");
        check_value(dut.fast_handoff_accepted, 1,
                    "final-fire edge latches acceptance");
        @(negedge clk);
        compute_start_accepted = 1'b0;
        compute_done = 1'b1;
        // compute_fire remains high for the adjacent new-context fire.
        @(posedge clk);
        #1;
        first_handoff_cycle = cycle_count;
        check_value(pass_base_k, 18, "registered-done handoff pass");
        check_value(dut.state, dut.ST_COMP_WAIT,
                    "registered-done handoff state");
        check_value(dut.fast_handoff_armed, 0,
                    "registered-done armed clear");
        check_value(dut.compute_started_seen, 1,
                    "handoff preserves first new fire");
        first_new_fire_cycle = cycle_count;
        @(negedge clk);
        compute_done = 1'b0;
        compute_fire = 1'b0;
        check_value(first_handoff_cycle - first_accept_cycle, 1,
                    "old final to registered done gap");
        check_value(first_new_fire_cycle, first_handoff_cycle,
                    "new fire shares old done edge");

        // Pass 1 -> 2: old completion arrives first.  The scheduler must keep
        // the old descriptor and remain in COMP_WAIT until acceptance.
        wait(prefetch_start_count == 2);
        check_value(feeder_pass_base_k, 36, "second prefetch base");
        check_value(feeder_k_pass, 2, "second prefetch index");
        wait(dut.prefetch_weight_done && dut.prefetch_feed_done);
        @(negedge clk);
        compute_done = 1'b1;
        @(posedge clk);
        #1;
        second_done_cycle = cycle_count;
        @(negedge clk);
        compute_done = 1'b0;
        repeat (3) begin
            @(posedge clk);
            #1;
            check_value(pass_base_k, 18, "delayed accept holds pass");
            check_value(dut.state, dut.ST_COMP_WAIT,
                        "delayed accept holds state");
        end
        @(negedge clk);
        compute_start_accepted = 1'b1;
        collector_context_wr_bank = 1'b0;
        @(posedge clk);
        #1;
        second_handoff_cycle = cycle_count;
        check_value(pass_base_k, 36, "delayed accept handoff pass");
        check_value(dut.compute_done_seen, 0,
                    "delayed accept clears old done");
        @(negedge clk);
        compute_start_accepted = 1'b0;
        if (second_handoff_cycle - second_done_cycle < 3) begin
            $display("[FAIL] delayed acknowledgement did not exercise wait");
            fail = fail + 1;
        end

        compute_fire = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        compute_fire = 1'b0;

        // The final K-pass is deliberately not armed; normal final collector
        // retirement ends the layer.
        repeat (2) @(negedge clk);
        compute_done = 1'b1;
        collector_final_done = 1'b1;
        @(negedge clk);
        compute_done = 1'b0;
        collector_final_done = 1'b0;
        wait(done === 1'b1);
        @(negedge clk);

        check_value(compute_start_count, 3, "single request per context");
        check_value(prefetch_start_count, 2, "prefetch request count");
        check_value(prefetch_hit_count, 2, "fast handoff hit count");
        check_value(comp_start_state_cycles, 1,
                    "only initial COMP_START visit");
        check_value(prefetch_commit_state_cycles, 0,
                    "no PREFETCH_COMMIT visits");
        check_value(busy, 0, "busy clears");

        $display("=== tb_layer_scheduler_fast_context_handoff: %0d fail ===",
                 fail);
        if (fail != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        repeat (300) @(negedge clk);
        $display("[FAIL] timeout state=%0d pass=%0d starts=%0d prefetch=%0d",
                 dut.state, pass_base_k, compute_start_count,
                 prefetch_start_count);
        $fatal(1);
    end
endmodule

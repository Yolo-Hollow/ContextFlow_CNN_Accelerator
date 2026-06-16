`timescale 1ns / 1ps

module tb_layer_scheduler_psum_overlap;
    localparam K_TILE = 4;
    localparam COUT_TILE = 4;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;
    wire busy;
    wire done;
    wire [13:0] pass_base_k;
    wire [13:0] feeder_pass_base_k;
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
    wire psum_drain_start;
    wire perf_prefetch_start;
    wire perf_prefetch_hit;
    wire perf_psumovl_start;
    wire perf_psumovl_hit;
    wire perf_psumovl_wait_psum;

    reg bias_load_done = 1'b0;
    reg weight_load_done = 1'b0;
    reg feeder_done = 1'b0;
    reg feeder_compute_ready = 1'b0;
    reg psum_drain_data_ready = 1'b0;
    reg psum_drain_packet_fire = 1'b0;
    reg compute_fire = 1'b0;
    reg compute_done = 1'b0;
    reg psum_drain_done = 1'b0;

    integer fail = 0;
    integer compute_start_count = 0;
    integer psumovl_start_count = 0;
    integer psumovl_hit_count = 0;
    integer first_drain_done_seen = 0;
    integer second_compute_before_first_drain_done = 0;
    integer drain_done_during_transition_seen = 0;
    integer weight_delay = 0;
    integer feeder_delay = 0;
    integer compute_delay = 0;
    integer drain_delay = 0;
    integer drain_start_count = 0;
    integer transition_drain_active = 0;

    layer_scheduler_stream #(
        .K_TILE(K_TILE),
        .COUT_TILE(COUT_TILE)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done),
        // Runtime Conv5/6/8 spatial tiles contain 13 pixels. Keep this test
        // at the real tile size so an unreachable fixed warmup cannot pass.
        .k_total(14'd12), .cout_total(11'd4), .num_pixels(16'd13),
        .pass_base_k(pass_base_k), .cout_base(cout_base),
        .cout_valid(cout_valid), .num_pixels_out(num_pixels_out),
        .is_first_pass(is_first_pass), .is_final_pass(is_final_pass),
        .use_ext_psum(use_ext_psum), .use_psum_stream(use_psum_stream),
        .psum_wr_bank(psum_wr_bank), .psum_rd_bank(psum_rd_bank),
        .bias_load_start(bias_load_start), .bias_load_done(bias_load_done),
        .weight_load_start(weight_load_start), .weight_load_done(weight_load_done),
        .feeder_start(feeder_start), .feeder_done(feeder_done),
        .feeder_compute_ready(feeder_compute_ready),
        .feeder_overlap_mode(1'b1),
        .raw_hwc_mode(1'b1),
        .early_drain_enable(1'b1),
        .pass_prefetch_enable(1'b1),
        .during_compute_prefetch_enable(1'b0),
        .psum_stream_overlap_enable(1'b1),
        .continuous_psum_enable(1'b0),
        .collector_ctx_ready(1'b1),
        .collector_partial_credit(1'b0),
        .collector_context_active(1'b0),
        .collector_context_wr_bank(1'b0),
        .collector_context_is_final(1'b0),
        .collector_final_done(1'b0),
        .psum_drain_data_ready(psum_drain_data_ready),
        .psum_drain_packet_fire(psum_drain_packet_fire),
        .compute_fire(compute_fire),
        .compute_start(compute_start), .compute_done(compute_done),
        .psum_drain_start(psum_drain_start), .psum_drain_done(psum_drain_done),
        .feeder_pass_base_k(feeder_pass_base_k),
        .perf_prefetch_start(perf_prefetch_start),
        .perf_prefetch_weight_done(), .perf_prefetch_feed_done(),
        .perf_prefetch_hit(perf_prefetch_hit), .perf_prefetch_miss(),
        .perf_prefetch_stall(),
        .perf_psumovl_start(perf_psumovl_start),
        .perf_psumovl_hit(perf_psumovl_hit),
        .perf_psumovl_wait_psum(perf_psumovl_wait_psum),
        .perf_stage_bias(), .perf_stage_weight(), .perf_stage_feeder(),
        .perf_stage_compute(), .perf_stage_drain()
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rst) begin
            compute_start_count <= 0;
            psumovl_start_count <= 0;
            psumovl_hit_count <= 0;
        end else begin
            if (compute_start) begin
                compute_start_count <= compute_start_count + 1;
                if (compute_start_count == 1 && !first_drain_done_seen)
                    second_compute_before_first_drain_done <= 1;
            end
            if (psum_drain_done && compute_start_count == 1)
                first_drain_done_seen <= 1;
            if (psum_drain_done &&
                (dut.state == dut.ST_PREFETCH_COMMIT ||
                 dut.state == dut.ST_COMP_START))
                drain_done_during_transition_seen <= 1;
            if (perf_psumovl_start)
                psumovl_start_count <= psumovl_start_count + 1;
            if (perf_psumovl_hit)
                psumovl_hit_count <= psumovl_hit_count + 1;
        end
    end

    always @(negedge clk) begin
        bias_load_done = 1'b0;
        weight_load_done = 1'b0;
        feeder_done = 1'b0;
        feeder_compute_ready = 1'b0;
        compute_fire = 1'b0;
        compute_done = 1'b0;
        psum_drain_done = 1'b0;
        psum_drain_packet_fire = 1'b0;
        psum_drain_data_ready = 1'b0;

        if (bias_load_start)
            bias_load_done = 1'b1;

        if (weight_load_start)
            weight_delay = 3;
        if (weight_delay > 0) begin
            weight_delay = weight_delay - 1;
            if (weight_delay == 0)
                weight_load_done = 1'b1;
        end

        if (feeder_start)
            feeder_delay = 5;
        if (feeder_delay > 0) begin
            feeder_delay = feeder_delay - 1;
            if (feeder_delay == 3)
                feeder_compute_ready = 1'b1;
            if (feeder_delay == 0)
                feeder_done = 1'b1;
        end

        if (compute_start)
            compute_delay = 10;
        if (compute_delay > 0) begin
            compute_delay = compute_delay - 1;
            compute_fire = 1'b1;
            psum_drain_data_ready = 1'b1;
            if (compute_delay == 0)
                compute_done = 1'b1;
        end

        if (psum_drain_start) begin
            drain_start_count = drain_start_count + 1;
            if (drain_start_count == 2)
                transition_drain_active = 1;
            else
                drain_delay = 100;
        end
        if (transition_drain_active) begin
            psum_drain_packet_fire = 1'b1;
            if (dut.state == dut.ST_PREFETCH_COMMIT) begin
                psum_drain_done = 1'b1;
                transition_drain_active = 0;
            end
        end else if (drain_delay > 0) begin
            drain_delay = drain_delay - 1;
            psum_drain_packet_fire = 1'b1;
            if (drain_delay == 0)
                psum_drain_done = 1'b1;
        end
    end

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait(done);
        @(negedge clk);
        if (!second_compute_before_first_drain_done) begin
            $display("[FAIL] second compute did not overlap first drain");
            fail = fail + 1;
        end
        if (psumovl_start_count == 0 || psumovl_hit_count == 0) begin
            $display("[FAIL] psum overlap counters start=%0d hit=%0d",
                     psumovl_start_count, psumovl_hit_count);
            fail = fail + 1;
        end
        if (!drain_done_during_transition_seen) begin
            $display("[FAIL] did not exercise drain-done transition pulse");
            fail = fail + 1;
        end

        $display("=== tb_layer_scheduler_psum_overlap: %0d fail ===", fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (1000) @(negedge clk);
        $display("[FAIL] timeout busy=%0d done=%0d pass=%0d state=%0d",
                 busy, done, pass_base_k, dut.state);
        $fatal(1);
    end
endmodule

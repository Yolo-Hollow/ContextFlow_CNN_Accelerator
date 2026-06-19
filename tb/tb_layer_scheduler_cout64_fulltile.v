`timescale 1ns / 1ps

module tb_layer_scheduler_cout64_fulltile;
    localparam K_TILE = 32;
    localparam COUT_TILE = 64;
    localparam K_TOTAL = 144;
    localparam COUT_TOTAL = 64;
    localparam NUM_PIXELS = 16;
    localparam K_PASSES = 5;

    reg clk, rst, start;
    wire busy, done;
    wire [10:0] pass_base_k, cout_base, cout_valid;
    wire [15:0] num_pixels_out;
    wire is_first_pass, is_final_pass, use_ext_psum, use_psum_stream;
    wire psum_wr_bank, psum_rd_bank;
    wire bias_load_start, weight_load_start, feeder_start, compute_start, psum_drain_start;
    reg bias_load_done, weight_load_done, feeder_done, compute_done, psum_drain_done;

    layer_scheduler_stream #(.K_TILE(K_TILE), .COUT_TILE(COUT_TILE)) dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done),
        .k_total(K_TOTAL[10:0]), .cout_total(COUT_TOTAL[10:0]), .num_pixels(NUM_PIXELS[15:0]),
        .pass_base_k(pass_base_k), .cout_base(cout_base), .cout_valid(cout_valid),
        .num_pixels_out(num_pixels_out),
        .is_first_pass(is_first_pass), .is_final_pass(is_final_pass),
        .use_ext_psum(use_ext_psum), .use_psum_stream(use_psum_stream),
        .psum_wr_bank(psum_wr_bank), .psum_rd_bank(psum_rd_bank),
        .bias_load_start(bias_load_start), .bias_load_done(bias_load_done),
        .weight_load_start(weight_load_start), .weight_load_done(weight_load_done),
        .feeder_start(feeder_start), .feeder_done(feeder_done),
        .feeder_compute_ready(1'b0), .feeder_overlap_mode(1'b0),
        .raw_hwc_mode(1'b0),
        .early_drain_enable(1'b0), .psum_drain_data_ready(1'b0),
        .psum_drain_packet_fire(1'b0),
        .pass_prefetch_enable(1'b0),
        .during_compute_prefetch_enable(1'b0),
        .psum_stream_overlap_enable(1'b0),
        .continuous_psum_enable(1'b0),
        .collector_ctx_ready(1'b1),
        .collector_partial_credit(1'b0),
        .collector_context_active(1'b0),
        .collector_context_wr_bank(1'b0),
        .collector_context_is_final(1'b0),
        .collector_final_done(1'b0),
        .compute_fire(1'b0),
        .compute_start(compute_start), .compute_done(compute_done),
        .psum_drain_start(psum_drain_start), .psum_drain_done(psum_drain_done),
        .feeder_pass_base_k(),
        .perf_prefetch_start(), .perf_prefetch_weight_done(),
        .perf_prefetch_feed_done(), .perf_prefetch_hit(),
        .perf_prefetch_miss(), .perf_prefetch_stall(),
        .perf_psumovl_start(), .perf_psumovl_hit(), .perf_psumovl_wait_psum(),
        .perf_stage_bias(), .perf_stage_weight(), .perf_stage_feeder(),
        .perf_stage_compute(), .perf_stage_drain()
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer bias_count, weight_count, feeder_count, compute_count, drain_count;
    integer bias_delay, weight_delay, feeder_delay, compute_delay, drain_delay;
    integer exp_k [0:K_PASSES-1];
    integer exp_first [0:K_PASSES-1];
    integer exp_final [0:K_PASSES-1];

    task check_equal;
        input integer got;
        input integer exp;
        input [127:0] name;
        begin
            if (got !== exp) begin
                $display("[FAIL] %0s got=%0d exp=%0d", name, got, exp);
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    initial begin
        forever begin
            @(posedge clk);
            if (bias_load_start) begin
                check_equal(cout_base, 0, "bias cout");
                check_equal(cout_valid, 64, "bias cout valid");
                bias_count = bias_count + 1;
                bias_delay = 1;
            end
            if (weight_load_start) begin
                check_equal(cout_base, 0, "weight cout");
                check_equal(cout_valid, 64, "weight cout valid");
                check_equal(pass_base_k, exp_k[weight_count], "weight k");
                check_equal(is_first_pass, exp_first[weight_count], "weight first");
                check_equal(is_final_pass, exp_final[weight_count], "weight final");
                check_equal(use_ext_psum, !exp_first[weight_count], "weight ext");
                check_equal(use_psum_stream, !exp_first[weight_count], "weight stream");
                weight_count = weight_count + 1;
                weight_delay = 2;
            end
            if (feeder_start) begin
                check_equal(cout_base, 0, "feeder cout");
                check_equal(pass_base_k, exp_k[feeder_count], "feeder k");
                feeder_count = feeder_count + 1;
                feeder_delay = 2;
            end
            if (compute_start) begin
                check_equal(cout_base, 0, "compute cout");
                check_equal(pass_base_k, exp_k[compute_count], "compute k");
                check_equal(num_pixels_out, NUM_PIXELS, "num pixels");
                compute_count = compute_count + 1;
                compute_delay = 3;
            end
            if (psum_drain_start) begin
                check_equal(cout_base, 0, "drain cout");
                check_equal(pass_base_k, exp_k[drain_count], "drain k");
                check_equal(is_final_pass, exp_final[drain_count], "drain final");
                drain_count = drain_count + 1;
                drain_delay = 1;
            end
        end
    end

    always @(negedge clk) begin
        bias_load_done = 1'b0;
        weight_load_done = 1'b0;
        feeder_done = 1'b0;
        compute_done = 1'b0;
        psum_drain_done = 1'b0;

        if (bias_delay > 0) begin
            bias_delay = bias_delay - 1;
            if (bias_delay == 0) bias_load_done = 1'b1;
        end
        if (weight_delay > 0) begin
            weight_delay = weight_delay - 1;
            if (weight_delay == 0) weight_load_done = 1'b1;
        end
        if (feeder_delay > 0) begin
            feeder_delay = feeder_delay - 1;
            if (feeder_delay == 0) feeder_done = 1'b1;
        end
        if (compute_delay > 0) begin
            compute_delay = compute_delay - 1;
            if (compute_delay == 0) compute_done = 1'b1;
        end
        if (drain_delay > 0) begin
            drain_delay = drain_delay - 1;
            if (drain_delay == 0) psum_drain_done = 1'b1;
        end
    end

    initial begin
        clk = 0;
        rst = 1;
        start = 0;
        bias_load_done = 0;
        weight_load_done = 0;
        feeder_done = 0;
        compute_done = 0;
        psum_drain_done = 0;
        pass = 0;
        fail = 0;
        bias_count = 0;
        weight_count = 0;
        feeder_count = 0;
        compute_count = 0;
        drain_count = 0;
        bias_delay = 0;
        weight_delay = 0;
        feeder_delay = 0;
        compute_delay = 0;
        drain_delay = 0;

        exp_k[0] = 0;   exp_first[0] = 1; exp_final[0] = 0;
        exp_k[1] = 32;  exp_first[1] = 0; exp_final[1] = 0;
        exp_k[2] = 64;  exp_first[2] = 0; exp_final[2] = 0;
        exp_k[3] = 96;  exp_first[3] = 0; exp_final[3] = 0;
        exp_k[4] = 128; exp_first[4] = 0; exp_final[4] = 1;

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        wait(done);
        @(negedge clk);

        check_equal(bias_count, 1, "bias count");
        check_equal(weight_count, K_PASSES, "weight count");
        check_equal(feeder_count, K_PASSES, "feeder count");
        check_equal(compute_count, K_PASSES, "compute count");
        check_equal(drain_count, K_PASSES, "drain count");
        check_equal(cout_base, 0, "final cout base");
        check_equal(busy, 0, "busy clear");

        $display("=== tb_layer_scheduler_cout64_fulltile: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (800) @(negedge clk);
        $display("[FAIL] timeout bias=%0d weight=%0d feeder=%0d compute=%0d drain=%0d cout=%0d k=%0d",
            bias_count, weight_count, feeder_count, compute_count, drain_count, cout_base, pass_base_k);
        $fatal(1);
    end
endmodule

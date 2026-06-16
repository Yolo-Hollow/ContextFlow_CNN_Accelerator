`timescale 1ns / 1ps

module tb_layer_scheduler_overlap;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;
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
    wire psum_drain_start;
    reg bias_load_done = 1'b0;
    reg weight_load_done = 1'b0;
    reg feeder_done = 1'b0;
    reg feeder_compute_ready = 1'b0;
    reg compute_done = 1'b0;
    reg psum_drain_done = 1'b0;

    integer fail = 0;
    integer compute_before_feeder_done = 0;
    integer drain_before_feeder_done = 0;
    integer cycle_count = 0;
    reg feeder_done_seen = 1'b0;

    layer_scheduler_stream #(
        .K_TILE(18),
        .COUT_TILE(16)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done),
        .k_total(14'd18), .cout_total(11'd16), .num_pixels(16'd169),
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
        .raw_hwc_mode(1'b0),
        .early_drain_enable(1'b0),
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
        .psum_drain_data_ready(1'b0),
        .psum_drain_packet_fire(1'b0),
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

    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            feeder_done_seen <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (feeder_done)
                feeder_done_seen <= 1'b1;
            if (compute_start && !feeder_done)
                compute_before_feeder_done <= 1;
            if (psum_drain_start && !feeder_done_seen)
                drain_before_feeder_done <= 1;
        end
    end

    initial begin
        run_overlap_case(0);
        run_overlap_case(1);

        $display("=== tb_layer_scheduler_overlap: %0d fail ===", fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    task run_overlap_case;
        input feeder_done_before_compute;
        begin
        rst = 1'b1;
        start = 1'b0;
        bias_load_done = 1'b0;
        weight_load_done = 1'b0;
        feeder_done = 1'b0;
        feeder_compute_ready = 1'b0;
        compute_done = 1'b0;
        psum_drain_done = 1'b0;
        compute_before_feeder_done = 0;
        drain_before_feeder_done = 0;
        feeder_done_seen = 1'b0;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait(bias_load_start);
        @(negedge clk);
        bias_load_done = 1'b1;
        @(negedge clk);
        bias_load_done = 1'b0;

        wait(weight_load_start);
        @(negedge clk);
        weight_load_done = 1'b1;
        @(negedge clk);
        weight_load_done = 1'b0;

        wait(feeder_start);
        repeat (2) @(negedge clk);
        feeder_compute_ready = 1'b1;

        wait(compute_start);
        @(negedge clk);
        feeder_compute_ready = 1'b0;

        if (feeder_done_before_compute) begin
            repeat (1) @(negedge clk);
            feeder_done = 1'b1;
            @(negedge clk);
            feeder_done = 1'b0;
            repeat (3) @(negedge clk);
            compute_done = 1'b1;
            @(negedge clk);
            compute_done = 1'b0;
        end else begin
            repeat (2) @(negedge clk);
            compute_done = 1'b1;
            @(negedge clk);
            compute_done = 1'b0;

            repeat (3) @(negedge clk);
            feeder_done = 1'b1;
            @(negedge clk);
            feeder_done = 1'b0;
        end

        wait(psum_drain_start);
        @(negedge clk);
        psum_drain_done = 1'b1;
        @(negedge clk);
        psum_drain_done = 1'b0;

        wait(done);
        @(negedge clk);

        if (!compute_before_feeder_done) begin
            $display("[FAIL] compute did not start before feeder_done");
            fail = fail + 1;
        end
        if (drain_before_feeder_done) begin
            $display("[FAIL] drain started before feeder_done");
            fail = fail + 1;
        end
        if (pass_base_k !== 14'd0 || cout_base !== 11'd0 || cout_valid !== 11'd16 ||
            num_pixels_out !== 16'd169 || !is_first_pass || !is_final_pass ||
            use_ext_psum || use_psum_stream) begin
            $display("[FAIL] scheduler outputs changed unexpectedly");
            fail = fail + 1;
        end

        $display("[INFO] overlap case feeder_done_before_compute=%0d passed", feeder_done_before_compute);
        end
    endtask

    initial begin
        repeat (400) @(negedge clk);
        $display("[FAIL] timeout cycle=%0d busy=%0d done=%0d compute_before_done=%0d drain_before_done=%0d",
            cycle_count, busy, done, compute_before_feeder_done, drain_before_feeder_done);
        $fatal(1);
    end
endmodule

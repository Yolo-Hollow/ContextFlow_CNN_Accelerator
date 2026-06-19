`timescale 1ns / 1ps

module tb_layer_scheduler_k9216;
    localparam K_TILE = 18;
    localparam COUT_TILE = 16;
    localparam K_TOTAL = 9216;
    localparam COUT_TOTAL = 16;
    localparam EXPECTED_PASSES = K_TOTAL / K_TILE;

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
    reg compute_done = 1'b0;
    reg psum_drain_done = 1'b0;

    integer failures = 0;
    integer weight_count = 0;
    integer final_count = 0;

    layer_scheduler_stream #(
        .K_TILE(K_TILE),
        .COUT_TILE(COUT_TILE)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .busy(busy),
        .done(done),
        .k_total(K_TOTAL[13:0]),
        .cout_total(COUT_TOTAL[10:0]),
        .num_pixels(16'd169),
        .pass_base_k(pass_base_k),
        .cout_base(cout_base),
        .cout_valid(cout_valid),
        .num_pixels_out(num_pixels_out),
        .is_first_pass(is_first_pass),
        .is_final_pass(is_final_pass),
        .use_ext_psum(use_ext_psum),
        .use_psum_stream(use_psum_stream),
        .psum_wr_bank(psum_wr_bank),
        .psum_rd_bank(psum_rd_bank),
        .bias_load_start(bias_load_start),
        .bias_load_done(bias_load_done),
        .weight_load_start(weight_load_start),
        .weight_load_done(weight_load_done),
        .feeder_start(feeder_start),
        .feeder_done(feeder_done),
        .feeder_compute_ready(1'b0),
        .feeder_overlap_mode(1'b0),
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
        .compute_start(compute_start),
        .compute_done(compute_done),
        .psum_drain_start(psum_drain_start),
        .psum_drain_done(psum_drain_done),
        .feeder_pass_base_k(),
        .perf_prefetch_start(), .perf_prefetch_weight_done(),
        .perf_prefetch_feed_done(), .perf_prefetch_hit(),
        .perf_prefetch_miss(), .perf_prefetch_stall(),
        .perf_psumovl_start(), .perf_psumovl_hit(), .perf_psumovl_wait_psum(),
        .perf_stage_bias(), .perf_stage_weight(), .perf_stage_feeder(),
        .perf_stage_compute(), .perf_stage_drain()
    );

    always #5 clk = ~clk;

    always @(negedge clk) begin
        bias_load_done <= bias_load_start;
        weight_load_done <= weight_load_start;
        feeder_done <= feeder_start;
        compute_done <= compute_start;
        psum_drain_done <= psum_drain_start;
    end

    always @(posedge clk) begin
        if (weight_load_start) begin
            if (pass_base_k !== weight_count * K_TILE) begin
                $display("[FAIL] pass %0d base=%0d expected=%0d",
                    weight_count, pass_base_k, weight_count * K_TILE);
                failures = failures + 1;
            end
            if (is_first_pass !== (weight_count == 0)) begin
                $display("[FAIL] first flag at pass %0d", weight_count);
                failures = failures + 1;
            end
            if (is_final_pass !== (weight_count == EXPECTED_PASSES - 1)) begin
                $display("[FAIL] final flag at pass %0d", weight_count);
                failures = failures + 1;
            end
            if (is_final_pass)
                final_count = final_count + 1;
            weight_count = weight_count + 1;
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

        if (weight_count != EXPECTED_PASSES) begin
            $display("[FAIL] weight_count=%0d expected=%0d", weight_count, EXPECTED_PASSES);
            failures = failures + 1;
        end
        if (final_count != 1) begin
            $display("[FAIL] final_count=%0d expected=1", final_count);
            failures = failures + 1;
        end

        $display("=== tb_layer_scheduler_k9216: passes=%0d failures=%0d ===",
            weight_count, failures);
        if (failures != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        repeat (10000) @(negedge clk);
        $fatal(1, "[FAIL] timeout pass_count=%0d", weight_count);
    end
endmodule

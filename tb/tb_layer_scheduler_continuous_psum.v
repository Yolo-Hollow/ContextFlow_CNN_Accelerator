`timescale 1ns / 1ps

module tb_layer_scheduler_continuous_psum;
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

    reg bias_load_done = 1'b0;
    reg weight_load_done = 1'b0;
    reg feeder_done = 1'b0;
    reg feeder_compute_ready = 1'b0;
    reg compute_done = 1'b0;
    reg collector_partial_credit = 1'b0;
    reg collector_context_active = 1'b0;
    reg collector_context_wr_bank = 1'b0;
    reg collector_context_is_final = 1'b0;
    reg collector_final_done = 1'b0;

    integer fail = 0;
    integer compute_start_count = 0;
    integer drain_start_count = 0;
    integer prefetch_start_count = 0;
    integer prefetch_hit_count = 0;
    integer psumovl_hit_count = 0;
    integer weight_delay = 0;
    integer feeder_delay = 0;
    integer compute_delay = 0;
    integer final_done_delay = 0;

    layer_scheduler_stream #(
        .K_TILE(K_TILE),
        .COUT_TILE(COUT_TILE)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done),
        .k_total(14'd8), .cout_total(11'd4), .num_pixels(16'd5),
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
        .continuous_psum_enable(1'b1),
        .collector_ctx_ready(1'b1),
        .collector_partial_credit(collector_partial_credit),
        .collector_context_active(collector_context_active),
        .collector_context_wr_bank(collector_context_wr_bank),
        .collector_context_is_final(collector_context_is_final),
        .collector_final_done(collector_final_done),
        .psum_drain_data_ready(1'b1),
        .psum_drain_packet_fire(1'b0),
        .compute_fire(1'b0),
        .compute_start(compute_start), .compute_done(compute_done),
        .psum_drain_start(psum_drain_start), .psum_drain_done(1'b0),
        .feeder_pass_base_k(feeder_pass_base_k),
        .perf_prefetch_start(perf_prefetch_start),
        .perf_prefetch_weight_done(), .perf_prefetch_feed_done(),
        .perf_prefetch_hit(perf_prefetch_hit), .perf_prefetch_miss(),
        .perf_prefetch_stall(),
        .perf_psumovl_start(perf_psumovl_start),
        .perf_psumovl_hit(perf_psumovl_hit),
        .perf_psumovl_wait_psum(),
        .perf_stage_bias(), .perf_stage_weight(), .perf_stage_feeder(),
        .perf_stage_compute(), .perf_stage_drain()
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rst) begin
            compute_start_count <= 0;
            drain_start_count <= 0;
            prefetch_start_count <= 0;
            prefetch_hit_count <= 0;
            psumovl_hit_count <= 0;
        end else begin
            if (compute_start)
                compute_start_count <= compute_start_count + 1;
            if (psum_drain_start)
                drain_start_count <= drain_start_count + 1;
            if (perf_prefetch_start)
                prefetch_start_count <= prefetch_start_count + 1;
            if (perf_prefetch_hit)
                prefetch_hit_count <= prefetch_hit_count + 1;
            if (perf_psumovl_hit)
                psumovl_hit_count <= psumovl_hit_count + 1;
        end
    end

    always @(negedge clk) begin
        bias_load_done <= bias_load_start;
        if (weight_load_start)
            weight_delay <= 1;
        if (weight_delay != 0) begin
            weight_delay <= weight_delay - 1;
            weight_load_done <= (weight_delay == 1);
        end else begin
            weight_load_done <= 1'b0;
        end

        if (feeder_start) begin
            feeder_delay <= 1;
            feeder_compute_ready <= 1'b1;
        end
        if (feeder_delay != 0) begin
            feeder_delay <= feeder_delay - 1;
            feeder_done <= (feeder_delay == 1);
        end else begin
            feeder_done <= 1'b0;
            feeder_compute_ready <= 1'b0;
        end

        if (compute_start)
            compute_delay <= 2;
        if (compute_delay != 0) begin
            compute_delay <= compute_delay - 1;
            compute_done <= (compute_delay == 1);
            if (compute_delay == 1 && !is_final_pass)
                collector_partial_credit <= 1'b1;
            if (compute_delay == 1 && is_final_pass)
                final_done_delay <= 2;
        end else begin
            compute_done <= 1'b0;
        end

        if (final_done_delay != 0) begin
            final_done_delay <= final_done_delay - 1;
            collector_final_done <= (final_done_delay == 1);
        end else begin
            collector_final_done <= 1'b0;
        end
    end

    task expect_equal;
        input integer got;
        input integer exp;
        input [127:0] name;
        begin
            if (got !== exp) begin
                $display("[FAIL] %0s got=%0d exp=%0d", name, got, exp);
                fail = fail + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait(done);
        @(negedge clk);

        expect_equal(done, 1, "done");
        expect_equal(compute_start_count, 2, "compute starts");
        expect_equal(drain_start_count, 0, "legacy drain starts");
        expect_equal(prefetch_start_count, 1, "prefetch starts");
        expect_equal(prefetch_hit_count, 1, "prefetch hits");
        expect_equal(psumovl_hit_count, 1, "psum overlap hits");
        if (pass_base_k !== 14'd4) begin
            $display("[FAIL] final pass_base_k got=%0d", pass_base_k);
            fail = fail + 1;
        end

        $display("=== tb_layer_scheduler_continuous_psum: %0d fail ===", fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (300) @(negedge clk);
        $display("[FAIL] timeout done=%0d state=%0d pass=%0d compute_count=%0d",
            done, dut.state, pass_base_k, compute_start_count);
        $fatal(1);
    end
endmodule

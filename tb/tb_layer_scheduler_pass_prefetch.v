`timescale 1ns / 1ps

`ifndef TB_DURING_COMPUTE_PREFETCH
`define TB_DURING_COMPUTE_PREFETCH 0
`endif
`ifndef TB_LAYER_SCHEDULER_PASS_PREFETCH_MODULE
`define TB_LAYER_SCHEDULER_PASS_PREFETCH_MODULE tb_layer_scheduler_pass_prefetch
`endif

module `TB_LAYER_SCHEDULER_PASS_PREFETCH_MODULE;
    localparam K_TILE = 18;
    localparam COUT_TILE = 16;
    localparam DURING_COMPUTE_PREFETCH = `TB_DURING_COMPUTE_PREFETCH;
    localparam COMPUTE_DELAY_CYCLES = DURING_COMPUTE_PREFETCH ? 20 : 8;

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
    wire perf_prefetch_weight_done;
    wire perf_prefetch_feed_done;
    wire perf_prefetch_hit;
    wire perf_prefetch_miss;
    wire perf_prefetch_stall;
    reg bias_load_done = 1'b0;
    reg weight_load_done = 1'b0;
    reg feeder_done = 1'b0;
    reg feeder_compute_ready = 1'b0;
    reg compute_fire = 1'b0;
    reg compute_done = 1'b0;
    reg psum_drain_done = 1'b0;
    reg psum_drain_data_ready = 1'b0;

    integer fail = 0;
    integer weight_start_count = 0;
    integer feeder_start_count = 0;
    integer compute_start_count = 0;
    integer drain_start_count = 0;
    integer prefetch_start_count = 0;
    integer prefetch_before_compute_done_count = 0;
    integer prefetch_hit_count = 0;
    integer prefetch_miss_count = 0;
    integer weight_delay = 0;
    integer feeder_delay = 0;
    integer compute_delay = 0;
    integer drain_delay = 0;
    integer compute_fire_delay = 0;
    integer psum_ready_delay = 0;
    reg compute_done_seen_for_pass = 1'b0;

    layer_scheduler_stream #(
        .K_TILE(K_TILE),
        .COUT_TILE(COUT_TILE)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done),
        .k_total(14'd54), .cout_total(11'd16), .num_pixels(16'd52),
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
        .during_compute_prefetch_enable(DURING_COMPUTE_PREFETCH != 0),
        .psum_stream_overlap_enable(1'b0),
        .continuous_psum_enable(1'b0),
        .collector_ctx_ready(1'b1),
        .collector_partial_credit(1'b0),
        .collector_context_active(1'b0),
        .collector_context_wr_bank(1'b0),
        .collector_context_is_final(1'b0),
        .collector_final_done(1'b0),
        .psum_drain_data_ready(psum_drain_data_ready),
        .psum_drain_packet_fire(1'b0),
        .compute_fire(compute_fire),
        .compute_start(compute_start), .compute_done(compute_done),
        .psum_drain_start(psum_drain_start), .psum_drain_done(psum_drain_done),
        .feeder_pass_base_k(feeder_pass_base_k),
        .perf_prefetch_start(perf_prefetch_start),
        .perf_prefetch_weight_done(perf_prefetch_weight_done),
        .perf_prefetch_feed_done(perf_prefetch_feed_done),
        .perf_prefetch_hit(perf_prefetch_hit),
        .perf_prefetch_miss(perf_prefetch_miss),
        .perf_prefetch_stall(perf_prefetch_stall),
        .perf_psumovl_start(), .perf_psumovl_hit(), .perf_psumovl_wait_psum(),
        .perf_stage_bias(), .perf_stage_weight(), .perf_stage_feeder(),
        .perf_stage_compute(), .perf_stage_drain()
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rst) begin
            weight_start_count <= 0;
            feeder_start_count <= 0;
            compute_start_count <= 0;
            drain_start_count <= 0;
            prefetch_start_count <= 0;
            prefetch_hit_count <= 0;
            prefetch_miss_count <= 0;
            prefetch_before_compute_done_count <= 0;
            compute_done_seen_for_pass <= 1'b0;
        end else begin
            if (weight_load_start)
                weight_start_count <= weight_start_count + 1;
            if (feeder_start)
                feeder_start_count <= feeder_start_count + 1;
            if (compute_start) begin
                compute_done_seen_for_pass <= 1'b0;
                if (pass_base_k !== compute_start_count * K_TILE) begin
                    $display("[FAIL] compute[%0d] pass_base=%0d",
                             compute_start_count, pass_base_k);
                    fail = fail + 1;
                end
                compute_start_count <= compute_start_count + 1;
            end
            if (psum_drain_start)
                drain_start_count <= drain_start_count + 1;
            if (perf_prefetch_start) begin
                if (!compute_done_seen_for_pass)
                    prefetch_before_compute_done_count <=
                        prefetch_before_compute_done_count + 1;
                if (pass_base_k !== (prefetch_start_count * K_TILE) ||
                    feeder_pass_base_k !== ((prefetch_start_count + 1) * K_TILE)) begin
                    $display("[FAIL] prefetch[%0d] exec=%0d feeder=%0d",
                             prefetch_start_count, pass_base_k,
                             feeder_pass_base_k);
                    fail = fail + 1;
                end
                prefetch_start_count <= prefetch_start_count + 1;
            end
            if (perf_prefetch_hit)
                prefetch_hit_count <= prefetch_hit_count + 1;
            if (perf_prefetch_miss)
                prefetch_miss_count <= prefetch_miss_count + 1;
            if (compute_done)
                compute_done_seen_for_pass <= 1'b1;
        end
    end

    always @(negedge clk) begin
        bias_load_done = 1'b0;
        weight_load_done = 1'b0;
        feeder_done = 1'b0;
        feeder_compute_ready = 1'b0;
        compute_done = 1'b0;
        psum_drain_done = 1'b0;
        compute_fire = 1'b0;
        psum_drain_data_ready = 1'b0;

        if (bias_load_start)
            bias_load_done = 1'b1;

        if (weight_load_start)
            weight_delay = 2;
        if (weight_delay > 0) begin
            weight_delay = weight_delay - 1;
            if (weight_delay == 0)
                weight_load_done = 1'b1;
        end

        if (feeder_start)
            feeder_delay = 6;
        if (feeder_delay > 0) begin
            feeder_delay = feeder_delay - 1;
            if (feeder_delay == 4)
                feeder_compute_ready = 1'b1;
            if (feeder_delay == 0)
                feeder_done = 1'b1;
        end

        if (compute_start) begin
            compute_delay = COMPUTE_DELAY_CYCLES;
            compute_fire_delay = 1;
            psum_ready_delay = 2;
        end
        if (compute_fire_delay > 0) begin
            compute_fire_delay = compute_fire_delay - 1;
            compute_fire = 1'b1;
        end
        if (psum_ready_delay > 0) begin
            psum_ready_delay = psum_ready_delay - 1;
            if (psum_ready_delay == 0)
                psum_drain_data_ready = 1'b1;
        end
        if (compute_delay > 0) begin
            compute_delay = compute_delay - 1;
            if (compute_delay == 0)
                compute_done = 1'b1;
        end

        if (psum_drain_start)
            drain_delay = 3;
        if (drain_delay > 0) begin
            drain_delay = drain_delay - 1;
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
        if (weight_start_count !== 3 || feeder_start_count !== 3 ||
            compute_start_count !== 3 || drain_start_count !== 3) begin
            $display("[FAIL] counts w=%0d f=%0d c=%0d d=%0d",
                     weight_start_count, feeder_start_count,
                     compute_start_count, drain_start_count);
            fail = fail + 1;
        end
        if (prefetch_start_count !== 2 || prefetch_hit_count !== 2 ||
            (DURING_COMPUTE_PREFETCH ? (prefetch_miss_count !== 0) :
                                       (prefetch_miss_count !== 2))) begin
            $display("[FAIL] prefetch counts start=%0d hit=%0d miss=%0d",
                     prefetch_start_count, prefetch_hit_count,
                     prefetch_miss_count);
            fail = fail + 1;
        end
        if (DURING_COMPUTE_PREFETCH &&
            prefetch_before_compute_done_count !== 2) begin
            $display("[FAIL] expected during-compute prefetches, got %0d",
                     prefetch_before_compute_done_count);
            fail = fail + 1;
        end

        $display("=== tb_layer_scheduler_pass_prefetch: %0d fail ===", fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (500) @(negedge clk);
        $display("[FAIL] timeout busy=%0d done=%0d pass=%0d state=%0d",
                 busy, done, pass_base_k, dut.state);
        $fatal(1);
    end
endmodule

`timescale 1ns / 1ps

module tb_pass_timeline_monitor;
    reg clk, rst;
    reg layer_start, layer_busy;
    reg trace_enable;
    reg [7:0] trace_cout_block;
    reg [15:0] trace_k_pass;
    reg [10:0] cout_base;
    reg [13:0] pass_base_k;
    reg weight_done, feed_start, feed_ready, feed_done;
    reg compute_start, compute_fire, compute_done;
    reg collector_packet_fire, collector_context_done;
    reg collector_column_empty_wait, raw_replay_active, stage_compute;

    wire [31:0] pass_count;
    wire [31:0] start_to_first_fire;
    wire [31:0] first_to_last_fire;
    wire [31:0] last_fire_to_done;
    wire [31:0] collect_first_wait;
    wire [31:0] collect_column_empty;
    wire [31:0] replay_active_during_compute;
    wire [31:0] compute_idle_in_stage;
    wire [31:0] trace_weight_done;
    wire [31:0] trace_feed_start;
    wire [31:0] trace_feed_ready;
    wire [31:0] trace_feed_done;
    wire [31:0] trace_compute_start;
    wire [31:0] trace_first_fire;
    wire [31:0] trace_last_fire;
    wire [31:0] trace_compute_done;
    wire [31:0] trace_collect_first;
    wire [31:0] trace_collect_last;
    wire [31:0] trace_pass_done;
    wire trace_pass_start;
    wire trace_valid;

    pass_timeline_monitor #(.K_TILE(18), .COUT_TILE(16)) dut (
        .clk(clk), .rst(rst),
        .layer_start(layer_start), .layer_busy(layer_busy),
        .trace_enable(trace_enable),
        .trace_cout_block(trace_cout_block),
        .trace_k_pass(trace_k_pass),
        .cout_base(cout_base),
        .pass_base_k(pass_base_k),
        .weight_done(weight_done),
        .feed_start(feed_start),
        .feed_ready(feed_ready),
        .feed_done(feed_done),
        .compute_start(compute_start),
        .compute_fire(compute_fire),
        .compute_done(compute_done),
        .collector_packet_fire(collector_packet_fire),
        .collector_context_done(collector_context_done),
        .collector_column_empty_wait(collector_column_empty_wait),
        .raw_replay_active(raw_replay_active),
        .stage_compute(stage_compute),
        .pass_count(pass_count),
        .start_to_first_fire(start_to_first_fire),
        .first_to_last_fire(first_to_last_fire),
        .last_fire_to_done(last_fire_to_done),
        .collect_first_wait(collect_first_wait),
        .collect_column_empty(collect_column_empty),
        .replay_active_during_compute(replay_active_during_compute),
        .compute_idle_in_stage(compute_idle_in_stage),
        .trace_weight_done(trace_weight_done),
        .trace_feed_start(trace_feed_start),
        .trace_feed_ready(trace_feed_ready),
        .trace_feed_done(trace_feed_done),
        .trace_compute_start(trace_compute_start),
        .trace_first_fire(trace_first_fire),
        .trace_last_fire(trace_last_fire),
        .trace_compute_done(trace_compute_done),
        .trace_collect_first(trace_collect_first),
        .trace_collect_last(trace_collect_last),
        .trace_pass_done(trace_pass_done),
        .trace_pass_start(trace_pass_start),
        .trace_valid(trace_valid)
    );

    always #5 clk = ~clk;

    integer pass, fail;

    task tick;
        begin
            @(negedge clk);
            weight_done = 0;
            feed_start = 0;
            feed_ready = 0;
            feed_done = 0;
            compute_start = 0;
            compute_fire = 0;
            compute_done = 0;
            collector_packet_fire = 0;
            collector_context_done = 0;
            collector_column_empty_wait = 0;
            raw_replay_active = 0;
            stage_compute = 0;
        end
    endtask

    task check;
        input [31:0] got;
        input [31:0] exp;
        input [127:0] name;
        begin
            if (got !== exp) begin
                $display("[FAIL] %0s got=%0d exp=%0d", name, got, exp);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        layer_start = 0;
        layer_busy = 0;
        trace_enable = 1;
        trace_cout_block = 8'd1;
        trace_k_pass = 16'd2;
        cout_base = 11'd16;
        pass_base_k = 14'd36;
        weight_done = 0;
        feed_start = 0;
        feed_ready = 0;
        feed_done = 0;
        compute_start = 0;
        compute_fire = 0;
        compute_done = 0;
        collector_packet_fire = 0;
        collector_context_done = 0;
        collector_column_empty_wait = 0;
        raw_replay_active = 0;
        stage_compute = 0;
        pass = 0;
        fail = 0;

        repeat (3) @(negedge clk);
        rst = 0;
        layer_start = 1;
        layer_busy = 1;
        tick();
        layer_start = 0;

        weight_done = 1; tick();       // trace cycle 0
        feed_start = 1; tick();        // trace cycle 1
        feed_ready = 1; tick();        // trace cycle 2
        feed_done = 1; tick();         // trace cycle 3
        compute_start = 1;
        #1;
        check({31'd0, trace_pass_start}, 1, "trace start pulse");
        tick();                        // trace cycle 4

        stage_compute = 1; raw_replay_active = 1; tick(); // cycle 6 idle
        stage_compute = 1; raw_replay_active = 1; tick(); // cycle 7 idle
        stage_compute = 1; compute_fire = 1; raw_replay_active = 1; tick(); // first fire trace cycle 7
        stage_compute = 1; compute_fire = 1; collector_packet_fire = 1; tick(); // collect first trace cycle 8
        stage_compute = 1; compute_fire = 1; collector_packet_fire = 1; tick(); // cycle 10
        stage_compute = 1; compute_fire = 1; collector_packet_fire = 1; tick(); // last fire trace cycle 10
        stage_compute = 1; collector_column_empty_wait = 1; tick(); // cycle 12 idle
        stage_compute = 1; compute_done = 1; tick(); // done trace cycle 12
        collector_context_done = 1; tick(); // pass done trace cycle 13

        check(pass_count, 1, "pass count");
        check(start_to_first_fire, 3, "start to first fire");
        check(first_to_last_fire, 3, "first to last fire");
        check(last_fire_to_done, 2, "last fire to done");
        check(collect_first_wait, 4, "collect first wait");
        check(collect_column_empty, 1, "collect column empty");
        check(replay_active_during_compute, 3, "replay during compute");
        check(compute_idle_in_stage, 4, "compute idle in stage");
        check(trace_weight_done, 0, "trace weight done");
        check(trace_feed_start, 1, "trace feed start");
        check(trace_feed_ready, 2, "trace feed ready");
        check(trace_feed_done, 3, "trace feed done");
        check(trace_compute_start, 4, "trace compute start");
        check(trace_first_fire, 7, "trace first fire");
        check(trace_last_fire, 10, "trace last fire");
        check(trace_compute_done, 12, "trace compute done");
        check(trace_collect_first, 8, "trace collect first");
        check(trace_collect_last, 10, "trace collect last");
        check(trace_pass_done, 13, "trace pass done");
        check({31'd0, trace_valid}, 1, "trace valid");

        layer_start = 1;
        tick();
        layer_start = 0;
        check(pass_count, 0, "start clears pass count");
        check(trace_valid, 0, "start clears trace valid");

        $display("=== tb_pass_timeline_monitor: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

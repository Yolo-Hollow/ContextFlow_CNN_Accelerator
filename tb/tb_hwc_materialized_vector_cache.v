`timescale 1ns / 1ps

module tb_hwc_materialized_vector_cache;
    localparam integer ROWS = 18;
    localparam integer MAX_PASSES = 4;
    localparam integer CACHE_AW = 5;
    localparam integer CACHE_DEPTH = 32;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg cfg_start = 1'b0;
    reg [7:0] cfg_epoch = 8'd0;
    reg [31:0] cfg_num_pixels = 32'd0;
    reg [15:0] cfg_k_total = 16'd0;

    reg entry_valid = 1'b0;
    wire entry_ready;
    reg [ROWS*8-1:0] entry_data = {ROWS*8{1'b0}};
    reg [ROWS-1:0] entry_lane_valid = {ROWS{1'b0}};
    reg [31:0] entry_pixel = 32'd0;
    reg [15:0] entry_k_pass = 16'd0;
    reg [7:0] entry_epoch = 8'd0;
    reg entry_last = 1'b0;

    reg [MAX_PASSES-1:0] pass_ready_bitmap = {MAX_PASSES{1'b0}};
    reg [7:0] pass_ready_epoch = 8'd0;
    reg fill_req = 1'b0;
    reg [15:0] pass_base_k = 16'd0;
    reg [31:0] fill_pixel_base = 32'd0;
    reg [31:0] fill_num_pixels = 32'd0;
    wire [ROWS*8-1:0] vector_data;
    wire [ROWS-1:0] vector_lane_valid;
    wire vector_valid;
    reg vector_ready = 1'b0;
    wire packet_done;

    wire configured;
    wire replay_active;
    wire [15:0] active_replay_pass;
    wire config_error;
    wire underflow_error;
    wire overflow_error;
    wire context_mismatch_error;
    wire [31:0] accepted_entries;
    wire [31:0] completed_packets;
    wire [31:0] completed_pixels;
    wire [31:0] underflow_count;
    wire [31:0] overflow_count;
    wire [31:0] context_mismatch_count;
    wire [31:0] pass_wait_stall_cycles;
    wire [31:0] vector_backpressure_stall_cycles;
    wire [31:0] entry_backpressure_stall_cycles;

    integer checks = 0;
    integer failures = 0;
    integer expected_pass = 0;
    integer expected_pixel = 0;
    integer expected_end_pixel = 0;
    integer packet_pulses = 0;
    reg check_vectors = 1'b0;
    reg expect_zero_vectors = 1'b0;
    reg random_ready_enable = 1'b0;

    hwc_materialized_vector_cache #(
        .ROWS(ROWS),
        .EPOCH_W(8),
        .PASS_W(16),
        .PIXEL_W(32),
        .MAX_PASSES(MAX_PASSES),
        .CACHE_AW(CACHE_AW),
        .CACHE_DEPTH(CACHE_DEPTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .cfg_start(cfg_start),
        .cfg_epoch(cfg_epoch),
        .cfg_num_pixels(cfg_num_pixels),
        .cfg_k_total(cfg_k_total),
        .entry_valid(entry_valid),
        .entry_ready(entry_ready),
        .entry_data(entry_data),
        .entry_lane_valid(entry_lane_valid),
        .entry_pixel(entry_pixel),
        .entry_k_pass(entry_k_pass),
        .entry_epoch(entry_epoch),
        .entry_last(entry_last),
        .pass_ready_bitmap(pass_ready_bitmap),
        .pass_ready_epoch(pass_ready_epoch),
        .fill_req(fill_req),
        .pass_base_k(pass_base_k),
        .fill_pixel_base(fill_pixel_base),
        .fill_num_pixels(fill_num_pixels),
        .vector_data(vector_data),
        .vector_lane_valid(vector_lane_valid),
        .vector_valid(vector_valid),
        .vector_ready(vector_ready),
        .packet_done(packet_done),
        .configured(configured),
        .replay_active(replay_active),
        .active_replay_pass(active_replay_pass),
        .config_error(config_error),
        .underflow_error(underflow_error),
        .overflow_error(overflow_error),
        .context_mismatch_error(context_mismatch_error),
        .accepted_entries(accepted_entries),
        .completed_packets(completed_packets),
        .completed_pixels(completed_pixels),
        .underflow_count(underflow_count),
        .overflow_count(overflow_count),
        .context_mismatch_count(context_mismatch_count),
        .pass_wait_stall_cycles(pass_wait_stall_cycles),
        .vector_backpressure_stall_cycles(
            vector_backpressure_stall_cycles),
        .entry_backpressure_stall_cycles(
            entry_backpressure_stall_cycles)
    );

    function [ROWS*8-1:0] make_vector;
        input integer pass_idx;
        input integer pixel_idx;
        integer lane;
        begin
            make_vector = {ROWS*8{1'b0}};
            for (lane = 0; lane < ROWS; lane = lane + 1)
                make_vector[lane*8 +: 8] =
                    (pass_idx * 61 + pixel_idx * 19 + lane) & 8'hff;
        end
    endfunction

    task check;
        input condition;
        input [8*96-1:0] label;
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $display("[FAIL] %0s", label);
            end
        end
    endtask

    task start_context;
        input [7:0] epoch;
        input [31:0] pixels;
        input [15:0] k_total;
        begin
            @(negedge clk);
            cfg_epoch = epoch;
            cfg_num_pixels = pixels;
            cfg_k_total = k_total;
            cfg_start = 1'b1;
            @(negedge clk);
            cfg_start = 1'b0;
        end
    endtask

    task push_entry;
        input integer pass_idx;
        input integer pixel_idx;
        input [7:0] epoch;
        input is_last;
        begin
            @(negedge clk);
            entry_data = make_vector(pass_idx, pixel_idx);
            entry_lane_valid = (pass_idx == 2) ? 18'h0000f :
                                                 {ROWS{1'b1}};
            entry_pixel = pixel_idx;
            entry_k_pass = pass_idx;
            entry_epoch = epoch;
            entry_last = is_last;
            entry_valid = 1'b1;
            while (!entry_ready)
                @(negedge clk);
            @(negedge clk);
            entry_valid = 1'b0;
            entry_last = 1'b0;
        end
    endtask

    task begin_replay;
        input integer pass_idx;
        input zero_mode;
        begin
            expected_pass = pass_idx;
            expected_pixel = 0;
            expected_end_pixel = cfg_num_pixels;
            fill_pixel_base = 0;
            fill_num_pixels = cfg_num_pixels;
            expect_zero_vectors = zero_mode;
            check_vectors = 1'b1;
            @(negedge clk);
            pass_base_k = pass_idx * ROWS;
            fill_req = 1'b1;
        end
    endtask

    task begin_range_replay;
        input integer pass_idx;
        input integer pixel_base;
        input integer pixel_count;
        begin
            expected_pass = pass_idx;
            expected_pixel = pixel_base;
            expected_end_pixel = pixel_base + pixel_count;
            expect_zero_vectors = 1'b0;
            check_vectors = 1'b1;
            @(negedge clk);
            pass_base_k = pass_idx * ROWS;
            fill_pixel_base = pixel_base;
            fill_num_pixels = pixel_count;
            fill_req = 1'b1;
        end
    endtask

    task finish_replay;
        integer previous_packets;
        begin
            previous_packets = packet_pulses;
            while (packet_pulses == previous_packets)
                @(negedge clk);
            fill_req = 1'b0;
            check_vectors = 1'b0;
            expect_zero_vectors = 1'b0;
            @(negedge clk);
        end
    endtask

    always @(negedge clk) begin
        if (random_ready_enable)
            vector_ready <= (($random & 32'h3) != 0);
    end

    always @(posedge clk) begin
        if (!rst && vector_valid && vector_ready && check_vectors) begin
            if (expect_zero_vectors) begin
                check(vector_data === {ROWS*8{1'b0}},
                      "stale epoch data is suppressed");
                check(vector_lane_valid === {ROWS{1'b0}},
                      "stale epoch lane-valid is suppressed");
            end else begin
                check(vector_data === make_vector(expected_pass,
                                                  expected_pixel),
                      "replayed vector data");
                if (expected_pass == 2)
                    check(vector_lane_valid === 18'h0000f,
                          "tail pass lane-valid");
                else
                    check(vector_lane_valid === {ROWS{1'b1}},
                          "full pass lane-valid");
            end
            expected_pixel = expected_pixel + 1;
        end

        if (!rst && packet_done) begin
            packet_pulses = packet_pulses + 1;
            check(expected_pixel == expected_end_pixel,
                  "packet_done follows final accepted vector");
        end
    end

    integer pass_idx;
    integer pixel_idx;
    integer context_before;
    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;

        start_context(8'h11, 32'd5, 16'd40); // three 18-lane passes
        check(configured && !config_error, "legal context configures cache");

        for (pass_idx = 0; pass_idx < 3; pass_idx = pass_idx + 1)
            for (pixel_idx = 0; pixel_idx < 5; pixel_idx = pixel_idx + 1)
                push_entry(pass_idx, pixel_idx, 8'h11,
                           (pass_idx == 2) && (pixel_idx == 4));
        check(accepted_entries == 15, "all atomic entries accepted");

        // A feeder request is deliberately issued before pass-ready.  It
        // remains held and starts automatically after the bitmap catches up.
        pass_ready_epoch = 8'h11;
        begin_replay(0, 1'b0);
        repeat (4) @(negedge clk);
        check(underflow_error && (underflow_count == 1),
              "early pass request records one underflow");
        pass_ready_bitmap[0] = 1'b1;
        random_ready_enable = 1'b1;
        finish_replay();
        check(expected_pixel == 5, "pass0 replays every pixel");

        // The same materialized pass can be replayed for another COUT block.
        begin_replay(0, 1'b0);
        finish_replay();
        check(expected_pixel == 5, "pass0 supports lossless replay");

        begin_range_replay(0, 2, 2);
        finish_replay();
        check(expected_pixel == 4,
              "tile-range replay starts and stops at requested pixels");

        // Epoch readiness is checked separately from the bitmap.  A held
        // request waits until both describe the active ownership context.
        pass_ready_bitmap[1] = 1'b1;
        pass_ready_epoch = 8'h33;
        context_before = context_mismatch_count;
        begin_replay(1, 1'b0);
        repeat (3) @(negedge clk);
        check(context_mismatch_count == context_before + 1,
              "pass-ready epoch mismatch recorded once");
        pass_ready_epoch = 8'h11;
        finish_replay();
        check(expected_pixel == 5, "held epoch-wait request resumes");

        // Invalid writer contexts are consumed (so the materializer cannot
        // deadlock) but are never committed into the cache.
        context_before = context_mismatch_count;
        push_entry(0, 0, 8'h55, 1'b0);
        check(context_mismatch_count == context_before + 1,
              "entry epoch mismatch rejected");
        push_entry(0, 5, 8'h11, 1'b0);
        check(overflow_error && (overflow_count == 1),
              "out-of-range pixel rejected");

        pass_ready_bitmap[2] = 1'b1;
        random_ready_enable = 1'b0;
        @(posedge clk);
        vector_ready = 1'b0;
        begin_replay(2, 1'b0);
        wait(vector_valid);
        repeat (4) @(negedge clk);
        vector_ready = 1'b1;
        random_ready_enable = 1'b1;
        finish_replay();
        check(vector_backpressure_stall_cycles >= 3,
              "vector backpressure cycles counted");
        check(pass_wait_stall_cycles >= 7,
              "pass/epoch wait cycles counted");
        check(completed_packets == 5, "five valid replays completed");
        check(completed_pixels == 22, "valid replay pixels counted");

        // Start a new epoch without clearing RAM, falsely advertise pass0 as
        // ready, and prove that old tags cannot leak stale vectors.
        fill_req = 1'b0;
        random_ready_enable = 1'b0;
        // Let the negedge random-ready driver observe the disable before
        // forcing ready high.  Otherwise its final nonblocking assignment
        // can win this timestep and leave the replay permanently stalled.
        @(negedge clk);
        vector_ready = 1'b1;
        pass_ready_bitmap = {MAX_PASSES{1'b0}};
        start_context(8'h22, 32'd5, 16'd40);
        pass_ready_epoch = 8'h22;
        pass_ready_bitmap[0] = 1'b1;
        begin_replay(0, 1'b1);
        finish_replay();
        check(context_mismatch_error && (context_mismatch_count == 5),
              "every stale RAM tag is detected");
        check(completed_packets == 1 && completed_pixels == 5,
              "mismatch replay terminates without deadlock");

        // Capacity errors fail at configuration time rather than truncating
        // address bits and corrupting another pass.
        start_context(8'h23, 32'd12, 16'd55); // 12 pixels * 4 passes > 32
        check(!configured && config_error && overflow_error &&
              (overflow_count == 1),
              "oversized context fails closed");

        if (failures == 0)
            $display("[PASS] tb_hwc_materialized_vector_cache checks=%0d",
                     checks);
        else
            $display("[FAIL] tb_hwc_materialized_vector_cache failures=%0d checks=%0d",
                     failures, checks);
        $finish;
    end

    initial begin
        #200000;
        $display("[FAIL] tb_hwc_materialized_vector_cache timeout fill=%0b armed=%0b active=%0b rd_valid=%0b issue_pixel=%0d end_pixel=%0d expected=%0d packets=%0d pass=%0d base=%0d count=%0d",
                 fill_req, dut.req_armed_q, replay_active,
                 dut.rd_valid_q, dut.issue_pixel_q,
                 dut.replay_end_pixel_q, expected_pixel, packet_pulses,
                 pass_base_k, fill_pixel_base, fill_num_pixels);
        $finish;
    end
endmodule

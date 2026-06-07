`timescale 1ns / 1ps

module tb_axis_ifm_vector_loader;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg stream_reset = 1'b0;
    reg fill_req = 1'b0;
    reg valid = 1'b0;
    reg [63:0] data = 64'd0;
    reg [7:0] keep = 8'hff;
    reg last = 1'b0;
    reg ready = 1'b1;
    wire axis_ready;
    wire [143:0] vector_data;
    wire vector_valid;
    wire packet_done;
    wire keep_error;
    wire last_error;
    wire [31:0] packets;
    wire [31:0] pixels;
    wire [31:0] beats;
    wire [31:0] stalls;

    integer pass = 0;
    integer fail = 0;
    integer vector_count = 0;
    reg [143:0] captured [0:3];

    always #5 clk = ~clk;

    task check;
        input cond;
        input [255:0] msg;
        begin
            if (cond) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("[FAIL] %0s", msg);
            end
        end
    endtask

    task send_beat;
        input [63:0] value;
        input beat_last;
        begin
            @(negedge clk);
            data = value;
            last = beat_last;
            valid = 1'b1;
            wait(axis_ready);
            @(negedge clk);
            valid = 1'b0;
            last = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (vector_valid && ready) begin
            captured[vector_count] = vector_data;
            vector_count = vector_count + 1;
        end
    end

    axis_ifm_vector_loader dut (
        .clk(clk), .rst(rst), .stream_reset(stream_reset),
        .batch_mode(1'b1), .expected_packets(32'd2),
        .num_pixels(16'd2), .input_zero_point(8'd10),
        .fill_req(fill_req), .s_axis_tready(axis_ready),
        .s_axis_tvalid(valid), .s_axis_tdata(data),
        .s_axis_tkeep(keep), .s_axis_tlast(last),
        .vector_data(vector_data), .vector_valid(vector_valid),
        .vector_ready(ready), .packet_done(packet_done),
        .tkeep_error(keep_error), .tlast_error(last_error),
        .completed_packets(packets), .completed_pixels(pixels),
        .accepted_beats(beats), .fifo_stall_cycles(stalls)
    );

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        stream_reset = 1'b1;
        @(negedge clk);
        stream_reset = 1'b0;

        fill_req = 1'b1;
        send_beat(64'h11100f0e0d0c0b0a, 1'b0);
        send_beat(64'h1918171615141312, 1'b0);
        ready = 1'b0;
        send_beat(64'hffffffffffff1b1a, 1'b0);
        repeat (3) @(negedge clk);
        check(vector_valid, "vector held under FIFO backpressure");
        check(!axis_ready, "AXIS paused while vector pending");
        ready = 1'b1;

        send_beat(64'h21201f1e1d1c1b1a, 1'b0);
        send_beat(64'h2928272625242322, 1'b0);
        send_beat(64'h0000000000002b2a, 1'b0);
        wait(packets == 1);
        repeat (2) @(negedge clk);
        check(fill_req && !axis_ready, "held-high request does not rearm");
        fill_req = 1'b0;
        repeat (2) @(negedge clk);

        fill_req = 1'b1;
        send_beat(64'h0908070605040302, 1'b0);
        send_beat(64'h11100f0e0d0c0b0a, 1'b0);
        send_beat(64'h0000000000001312, 1'b0);
        send_beat(64'h89888786858483ff, 1'b0);
        send_beat(64'h81808f8e8d8c8b8a, 1'b0);
        send_beat(64'h0000000000007f7e, 1'b1);
        wait(packets == 2);
        repeat (3) @(negedge clk);

        check(vector_count == 4, "four vectors written");
        check(pixels == 4, "pixel counter");
        check(beats == 12, "beat counter");
        check(stalls >= 3, "FIFO stall counter");
        check(!keep_error, "TKEEP clean");
        check(!last_error, "TLAST only on final stream beat");
        check(captured[0][7:0] == 8'd0, "zero point centers lane 0");
        check(captured[0][15:8] == 8'd1, "lane 1 centered");
        check(captured[0][143:136] == 8'd17, "lane 17 assembled");
        check(captured[2][7:0] == 8'hf8, "negative centered value");
        check(captured[3][7:0] == 8'h7f, "positive saturation");

        $display("=== %m: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (1000) @(negedge clk);
        $fatal(1, "timeout packets=%0d pixels=%0d beats=%0d", packets, pixels, beats);
    end
endmodule

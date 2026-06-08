`timescale 1ns / 1ps

module tb_axis_hwc_tile_cache;
    localparam ROWS = 18;
    localparam AXIS_W = 64;
    localparam KEEP_W = 8;
    localparam CACHE_AW = 6;

    reg clk, rst;
    reg stream_reset;
    reg [31:0] expected_packets;
    reg [15:0] num_pixels;
    reg [13:0] k_total;
    reg [13:0] pass_base_k;
    reg [7:0] input_zero_point;
    reg fill_req;
    wire s_axis_tready;
    reg s_axis_tvalid;
    reg [AXIS_W-1:0] s_axis_tdata;
    reg [KEEP_W-1:0] s_axis_tkeep;
    reg s_axis_tlast;
    wire [ROWS*8-1:0] vector_data;
    wire vector_valid;
    reg vector_ready;
    wire packet_done;
    wire tkeep_error, tlast_error, overflow_error;
    wire [31:0] completed_packets;
    wire [31:0] completed_pixels;
    wire [31:0] accepted_beats;
    wire [31:0] fifo_stall_cycles;

    integer pass, fail;
    integer pixel, lane, ch;
    integer byte_index;

    axis_hwc_tile_cache #(
        .ROWS(ROWS),
        .AXIS_W(AXIS_W),
        .KEEP_W(KEEP_W),
        .CACHE_AW(CACHE_AW)
    ) dut (
        .clk(clk),
        .rst(rst),
        .stream_reset(stream_reset),
        .expected_packets(expected_packets),
        .num_pixels(num_pixels),
        .k_total(k_total),
        .pass_base_k(pass_base_k),
        .input_zero_point(input_zero_point),
        .fill_req(fill_req),
        .s_axis_tready(s_axis_tready),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .vector_data(vector_data),
        .vector_valid(vector_valid),
        .vector_ready(vector_ready),
        .packet_done(packet_done),
        .tkeep_error(tkeep_error),
        .tlast_error(tlast_error),
        .overflow_error(overflow_error),
        .completed_packets(completed_packets),
        .completed_pixels(completed_pixels),
        .accepted_beats(accepted_beats),
        .fifo_stall_cycles(fifo_stall_cycles)
    );

    always #5 clk = ~clk;

    function [7:0] raw_byte;
        input integer idx;
        begin
            raw_byte = input_zero_point + idx[7:0];
        end
    endfunction

    task send_beat;
        input [63:0] data;
        input [7:0] keep;
        input last;
        begin
            @(negedge clk);
            s_axis_tdata = data;
            s_axis_tkeep = keep;
            s_axis_tlast = last;
            s_axis_tvalid = 1'b1;
            wait(s_axis_tready);
            @(posedge clk);
            @(negedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tdata = 64'd0;
            s_axis_tkeep = 8'd0;
            s_axis_tlast = 1'b0;
        end
    endtask

    task send_tile;
        integer i;
        integer b;
        reg [63:0] word;
        reg [7:0] keep;
        begin
            i = 0;
            while (i < 60) begin
                word = 64'd0;
                keep = 8'd0;
                for (b = 0; b < 8; b = b + 1) begin
                    if (i + b < 60) begin
                        word[b*8 +: 8] = raw_byte(i + b);
                        keep[b] = 1'b1;
                    end
                end
                send_beat(word, keep, i + 8 >= 60);
                i = i + 8;
            end
        end
    endtask

    task check_vector;
        input integer exp_pixel;
        input integer base_ch;
        reg [ROWS*8-1:0] sample_data;
        begin
            wait(vector_valid);
            @(negedge clk);
            sample_data = vector_data;
            vector_ready = 1'b1;
            @(posedge clk);
            for (lane = 0; lane < ROWS; lane = lane + 1) begin
                ch = base_ch + lane;
                if (ch < k_total) begin
                    if (sample_data[lane*8 +: 8] !==
                        ((exp_pixel * k_total + ch) & 8'hff)) begin
                        $display("[FAIL] pixel=%0d lane=%0d ch=%0d got=%0d exp=%0d",
                            exp_pixel, lane, ch,
                            $signed(sample_data[lane*8 +: 8]),
                            ((exp_pixel * k_total + ch) & 8'hff));
                        fail = fail + 1;
                    end else pass = pass + 1;
                end else begin
                    if (sample_data[lane*8 +: 8] !== 8'd0) begin
                        $display("[FAIL] tail lane=%0d got=%0d exp=0",
                            lane, $signed(sample_data[lane*8 +: 8]));
                        fail = fail + 1;
                    end else pass = pass + 1;
                end
            end
            @(negedge clk);
            vector_ready = 1'b0;
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        stream_reset = 0;
        expected_packets = 32'd1;
        num_pixels = 16'd3;
        k_total = 14'd20;
        pass_base_k = 14'd0;
        input_zero_point = 8'd10;
        fill_req = 0;
        s_axis_tvalid = 0;
        s_axis_tdata = 64'd0;
        s_axis_tkeep = 8'd0;
        s_axis_tlast = 0;
        vector_ready = 0;
        pass = 0;
        fail = 0;

        repeat (4) @(negedge clk);
        rst = 0;
        @(negedge clk);
        stream_reset = 1'b1;
        @(negedge clk);
        stream_reset = 1'b0;

        send_tile();
        repeat (10) @(negedge clk);

        if (completed_packets !== 32'd1) begin
            $display("[FAIL] completed_packets got=%0d exp=1", completed_packets);
            fail = fail + 1;
        end else pass = pass + 1;
        if (accepted_beats !== 32'd8) begin
            $display("[FAIL] accepted_beats got=%0d exp=8", accepted_beats);
            fail = fail + 1;
        end else pass = pass + 1;
        if (tkeep_error || tlast_error || overflow_error) begin
            $display("[FAIL] errors tkeep=%b tlast=%b overflow=%b",
                tkeep_error, tlast_error, overflow_error);
            fail = fail + 1;
        end else pass = pass + 1;

        pass_base_k = 14'd0;
        fill_req = 1'b1;
        check_vector(0, 0);
        check_vector(1, 0);
        check_vector(2, 0);
        wait(packet_done);
        @(negedge clk);
        fill_req = 1'b0;

        repeat (3) @(negedge clk);
        pass_base_k = 14'd18;
        fill_req = 1'b1;
        check_vector(0, 18);
        check_vector(1, 18);
        check_vector(2, 18);
        wait(packet_done);
        @(negedge clk);
        fill_req = 1'b0;

        if (completed_pixels !== 32'd6) begin
            $display("[FAIL] completed_pixels got=%0d exp=6", completed_pixels);
            fail = fail + 1;
        end else pass = pass + 1;

        $display("=== tb_axis_hwc_tile_cache: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (5000) @(negedge clk);
        $display("[FAIL] timeout");
        $fatal(1);
    end
endmodule

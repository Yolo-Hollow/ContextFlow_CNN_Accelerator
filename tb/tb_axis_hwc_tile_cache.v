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
    reg [8:0] fm_h;
    reg [8:0] fm_w;
    reg [8:0] ofm_w;
    reg [8:0] tile_oy_base;
    reg [8:0] tile_ofm_h;
    reg [1:0] conv_stride;
    reg [1:0] conv_pad;
    reg kernel_1x1;
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
    wire [31:0] replay_active_cycles;

    integer pass, fail;
    integer pixel, lane, ch;
    integer byte_index;
    integer oy, ox, gk, ker, ky, kx, fy, fx;

    axis_hwc_tile_cache #(
        .ROWS(ROWS),
        .AXIS_W(AXIS_W),
        .KEEP_W(KEEP_W),
        .CACHE_AW(CACHE_AW),
        .CACHE_DEPTH(64),
        .CACHE_STRIPES(4),
        .CACHE_USE_URAM(1)
    ) dut (
        .clk(clk),
        .rst(rst),
        .stream_reset(stream_reset),
        .expected_packets(expected_packets),
        .num_pixels(num_pixels),
        .fm_h(fm_h),
        .fm_w(fm_w),
        .ofm_w(ofm_w),
        .tile_oy_base(tile_oy_base),
        .tile_ofm_h(tile_ofm_h),
        .conv_stride(conv_stride),
        .conv_pad(conv_pad),
        .kernel_1x1(kernel_1x1),
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
        .fifo_stall_cycles(fifo_stall_cycles),
        .replay_active_cycles(replay_active_cycles)
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

    function [7:0] raw3_centered;
        input integer y;
        input integer x;
        input integer c;
        begin
            raw3_centered = ((y * 16 + x * 4 + c) & 8'hff);
        end
    endfunction

    task send_tile3x3;
        integer y;
        integer x;
        integer c;
        integer i;
        integer b;
        reg [63:0] word;
        reg [7:0] keep;
        begin
            i = 0;
            word = 64'd0;
            keep = 8'd0;
            for (y = 0; y < 3; y = y + 1) begin
                for (x = 0; x < 4; x = x + 1) begin
                    for (c = 0; c < 4; c = c + 1) begin
                        word[(i % 8)*8 +: 8] =
                            input_zero_point + raw3_centered(y, x, c);
                        keep[i % 8] = 1'b1;
                        i = i + 1;
                        if ((i % 8) == 0 || i == 48) begin
                            send_beat(word, keep, i == 48);
                            word = 64'd0;
                            keep = 8'd0;
                        end
                    end
                end
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

    task check_vector3x3;
        input integer exp_pixel;
        input integer base_k;
        reg [ROWS*8-1:0] sample_data;
        reg [7:0] exp;
        begin
            wait(vector_valid);
            @(negedge clk);
            sample_data = vector_data;
            vector_ready = 1'b1;
            @(posedge clk);
            oy = exp_pixel / 2;
            ox = exp_pixel % 2;
            for (lane = 0; lane < ROWS; lane = lane + 1) begin
                gk = base_k + lane;
                ch = gk / 9;
                ker = gk % 9;
                ky = ker / 3;
                kx = ker % 3;
                fy = oy + ky - 1;
                fx = ox + kx - 1;
                if (gk >= k_total || fy < 0 || fy >= 4 || fx < 0 || fx >= 4)
                    exp = 8'd0;
                else
                    exp = raw3_centered(fy, fx, ch);
                if (sample_data[lane*8 +: 8] !== exp) begin
                    $display("[FAIL] 3x3 pixel=%0d lane=%0d gk=%0d ch=%0d ky=%0d kx=%0d fy=%0d fx=%0d got=%0d exp=%0d",
                        exp_pixel, lane, gk, ch, ky, kx, fy, fx,
                        $signed(sample_data[lane*8 +: 8]), $signed(exp));
                    fail = fail + 1;
                end else pass = pass + 1;
            end
            @(negedge clk);
            vector_ready = 1'b0;
        end
    endtask

    task check_fast_replay;
        reg [31:0] replay_before;
        reg [31:0] replay_delta;
        integer fire_count;
        begin
            replay_before = replay_active_cycles;
            fire_count = 0;
            vector_ready = 1'b1;
            fill_req = 1'b1;
            while (!packet_done) begin
                @(posedge clk);
                if (vector_valid && vector_ready)
                    fire_count = fire_count + 1;
            end
            replay_delta = replay_active_cycles - replay_before;
            @(negedge clk);
            vector_ready = 1'b0;
            fill_req = 1'b0;
            if (fire_count !== num_pixels) begin
                $display("[FAIL] fast replay fire_count got=%0d exp=%0d",
                    fire_count, num_pixels);
                fail = fail + 1;
            end else pass = pass + 1;
            if (replay_delta > num_pixels + 2) begin
                $display("[FAIL] fast replay active cycles got=%0d exp<=%0d",
                    replay_delta, num_pixels + 2);
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        stream_reset = 0;
        expected_packets = 32'd1;
        num_pixels = 16'd3;
        fm_h = 9'd1;
        fm_w = 9'd3;
        ofm_w = 9'd3;
        tile_oy_base = 9'd0;
        tile_ofm_h = 9'd1;
        conv_stride = 2'd1;
        conv_pad = 2'd0;
        kernel_1x1 = 1'b1;
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

        repeat (3) @(negedge clk);
        pass_base_k = 14'd0;
        check_fast_replay();

        num_pixels = 16'd4;
        fm_h = 9'd4;
        fm_w = 9'd4;
        ofm_w = 9'd2;
        tile_oy_base = 9'd0;
        tile_ofm_h = 9'd2;
        conv_stride = 2'd1;
        conv_pad = 2'd1;
        kernel_1x1 = 1'b0;
        k_total = 14'd36;
        pass_base_k = 14'd0;
        input_zero_point = 8'd20;
        @(negedge clk);
        stream_reset = 1'b1;
        @(negedge clk);
        stream_reset = 1'b0;

        send_tile3x3();
        wait(completed_packets == 32'd1);
        @(negedge clk);

        if (completed_packets !== 32'd1) begin
            $display("[FAIL] 3x3 completed_packets got=%0d exp=1", completed_packets);
            fail = fail + 1;
        end else pass = pass + 1;
        if (accepted_beats !== 32'd6) begin
            $display("[FAIL] 3x3 accepted_beats got=%0d exp=6", accepted_beats);
            fail = fail + 1;
        end else pass = pass + 1;
        if (tkeep_error || tlast_error || overflow_error) begin
            $display("[FAIL] 3x3 errors tkeep=%b tlast=%b overflow=%b",
                tkeep_error, tlast_error, overflow_error);
            fail = fail + 1;
        end else pass = pass + 1;

        fill_req = 1'b1;
        check_vector3x3(0, 0);
        check_vector3x3(1, 0);
        check_vector3x3(2, 0);
        check_vector3x3(3, 0);
        wait(packet_done);
        @(negedge clk);
        fill_req = 1'b0;

        repeat (3) @(negedge clk);
        pass_base_k = 14'd18;
        fill_req = 1'b1;
        check_vector3x3(0, 18);
        check_vector3x3(1, 18);
        check_vector3x3(2, 18);
        check_vector3x3(3, 18);
        wait(packet_done);
        @(negedge clk);
        fill_req = 1'b0;

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

`timescale 1ns / 1ps

module tb_ifm_line_stream_loader;
    localparam AW = 9;
    localparam FM_W = 7;

    reg clk;
    reg rst;
    reg [AW-1:0] fm_w;
    reg fill_req;
    reg [AW-1:0] fill_fy;
    reg [7:0] input_zero_point;
    wire line_s_ready;
    reg line_s_valid;
    reg [7:0] line_s_data [0:4];
    wire [4:0] dma_bank_wr_en;
    wire [AW-1:0] dma_wr_x;
    wire [AW:0] dma_wr_fy;
    wire [7:0] dma_wr_data [0:4];
    wire dma_line_advance;

    integer pass;
    integer fail;
    integer beat_seen;
    integer advance_seen;
    integer b;
    reg use_custom_expected;
    reg [7:0] custom_expected [0:4];
    reg [AW:0] expected_fy;

    ifm_line_stream_loader #(.AW(AW)) dut (
        .clk(clk), .rst(rst),
        .fm_w(fm_w), .fill_req(fill_req), .fill_fy(fill_fy),
        .input_zero_point(input_zero_point),
        .line_s_ready(line_s_ready), .line_s_valid(line_s_valid),
        .line_s_data(line_s_data),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x),
        .dma_wr_fy(dma_wr_fy), .dma_wr_data(dma_wr_data),
        .dma_line_advance(dma_line_advance)
    );

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

    function [7:0] center_ifm_byte_tb;
        input [7:0] raw_u8;
        input [7:0] zero_point;
        reg signed [9:0] centered;
        begin
            centered = $signed({2'b00, raw_u8}) - $signed({2'b00, zero_point});
            if (centered > 10'sd127)
                center_ifm_byte_tb = 8'h7f;
            else if (centered < -10'sd128)
                center_ifm_byte_tb = 8'h80;
            else
                center_ifm_byte_tb = centered[7:0];
        end
    endfunction

    task drive_line_beat;
        input integer x;
        begin
            @(negedge clk);
            line_s_valid = 1'b1;
            for (b = 0; b < 5; b = b + 1)
                line_s_data[b] = 8'h20 + x*5 + b;
            wait(line_s_ready);
            @(negedge clk);
            line_s_valid = 1'b0;
            for (b = 0; b < 5; b = b + 1)
                line_s_data[b] = 8'd0;
        end
    endtask

    task drive_custom_beat;
        input [7:0] d0;
        input [7:0] d1;
        input [7:0] d2;
        input [7:0] d3;
        input [7:0] d4;
        begin
            @(negedge clk);
            line_s_valid = 1'b1;
            line_s_data[0] = d0;
            line_s_data[1] = d1;
            line_s_data[2] = d2;
            line_s_data[3] = d3;
            line_s_data[4] = d4;
            wait(line_s_ready);
            @(negedge clk);
            line_s_valid = 1'b0;
            for (b = 0; b < 5; b = b + 1)
                line_s_data[b] = 8'd0;
        end
    endtask

    always @(posedge clk) begin
        if (!rst && |dma_bank_wr_en) begin
            check(dma_bank_wr_en == 5'b11111, "all IFM banks written per beat");
            check(dma_wr_x == beat_seen[AW-1:0], "IFM x write order");
            check(dma_wr_fy == expected_fy, "IFM fy latched");
            for (b = 0; b < 5; b = b + 1) begin
                if (use_custom_expected)
                    check(dma_wr_data[b] == custom_expected[b], "IFM centered custom byte");
                else
                    check(dma_wr_data[b] == center_ifm_byte_tb(8'h20 + beat_seen*5 + b, input_zero_point),
                          "IFM bank data order");
            end
            beat_seen = beat_seen + 1;
        end
        if (!rst && dma_line_advance)
            advance_seen = advance_seen + 1;
    end

    integer x;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
        fm_w = FM_W[AW-1:0];
        fill_req = 1'b0;
        fill_fy = 9'd5;
        input_zero_point = 8'd0;
        line_s_valid = 1'b0;
        for (b = 0; b < 5; b = b + 1)
            line_s_data[b] = 8'd0;
        pass = 0;
        fail = 0;
        beat_seen = 0;
        advance_seen = 0;
        use_custom_expected = 1'b0;
        expected_fy = 10'd5;
        for (b = 0; b < 5; b = b + 1)
            custom_expected[b] = 8'd0;

        repeat (4) @(negedge clk);
        rst = 1'b0;
        check(!line_s_ready, "line ready low before request");

        @(negedge clk);
        fill_req = 1'b1;
        @(negedge clk);
        fill_req = 1'b0;
        check(line_s_ready, "line ready asserted after request");

        drive_line_beat(0);
        repeat (3) @(negedge clk);
        for (x = 1; x < FM_W; x = x + 1)
            drive_line_beat(x);

        @(negedge clk);
        check(beat_seen == FM_W, "all IFM line beats written");
        check(advance_seen == 1, "line advance pulse count");
        check(!line_s_ready, "line ready low after complete row");

        repeat (3) @(negedge clk);
        fm_w = {{(AW-1){1'b0}}, 1'b1};
        fill_fy = 9'd6;
        expected_fy = 10'd6;
        input_zero_point = 8'd36;
        use_custom_expected = 1'b1;
        custom_expected[0] = 8'h00; // 36 - 36
        custom_expected[1] = 8'hf2; // 22 - 36 = -14
        custom_expected[2] = 8'h32; // 86 - 36 = 50
        custom_expected[3] = 8'h7f; // 255 - 36 saturates high
        custom_expected[4] = 8'h7f; // 220 - 36 saturates high
        beat_seen = 0;
        advance_seen = 0;
        @(negedge clk);
        fill_req = 1'b1;
        @(negedge clk);
        fill_req = 1'b0;
        drive_custom_beat(8'd36, 8'd22, 8'd86, 8'd255, 8'd220);
        @(negedge clk);
        check(beat_seen == 1, "zp36 custom row beat count");
        check(advance_seen == 1, "zp36 custom row advance count");

        repeat (3) @(negedge clk);
        fill_fy = 9'd7;
        expected_fy = 10'd7;
        input_zero_point = 8'd200;
        custom_expected[0] = 8'h80; // 0 - 200 saturates low
        custom_expected[1] = 8'h00; // 200 - 200
        custom_expected[2] = 8'h37; // 255 - 200 = 55
        custom_expected[3] = 8'h80; // 72 - 200 = -128
        custom_expected[4] = 8'h81; // 73 - 200 = -127
        beat_seen = 0;
        advance_seen = 0;
        @(negedge clk);
        fill_req = 1'b1;
        @(negedge clk);
        fill_req = 1'b0;
        drive_custom_beat(8'd0, 8'd200, 8'd255, 8'd72, 8'd73);
        @(negedge clk);
        check(beat_seen == 1, "zp200 custom row beat count");
        check(advance_seen == 1, "zp200 custom row advance count");

        $display("=== %m: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

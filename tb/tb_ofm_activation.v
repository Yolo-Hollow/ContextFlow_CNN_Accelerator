`timescale 1ns / 1ps

module tb_ofm_activation;
    localparam COUT_TILE = 8;
    localparam ADDR_W = 4;

    reg clk, rst;
    reg [1:0] mode;
    reg in_valid;
    reg [ADDR_W-1:0] in_addr;
    reg [10:0] in_cout_base;
    reg [COUT_TILE-1:0] in_channel_valid;
    reg [COUT_TILE*8-1:0] in_data;
    reg lut_wr_en;
    reg [7:0] lut_wr_addr, lut_wr_data;
    wire out_valid;
    wire [ADDR_W-1:0] out_addr;
    wire [10:0] out_cout_base;
    wire [COUT_TILE-1:0] out_channel_valid;
    wire [COUT_TILE*8-1:0] out_data;

    ofm_activation #(.COUT_TILE(COUT_TILE), .ADDR_W(ADDR_W)) dut (
        .clk(clk), .rst(rst), .mode(mode),
        .in_valid(in_valid), .in_addr(in_addr), .in_cout_base(in_cout_base),
        .in_channel_valid(in_channel_valid), .in_data(in_data),
        .lut_wr_en(lut_wr_en), .lut_wr_addr(lut_wr_addr), .lut_wr_data(lut_wr_data),
        .out_valid(out_valid), .out_addr(out_addr), .out_cout_base(out_cout_base),
        .out_channel_valid(out_channel_valid), .out_data(out_data)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer i;

    task load_lut_identity_plus_one;
        integer a;
        begin
            for (a = 0; a < 256; a = a + 1) begin
                @(negedge clk);
                lut_wr_en = 1'b1;
                lut_wr_addr = a[7:0];
                lut_wr_data = a[7:0] + 8'd1;
            end
            @(negedge clk);
            lut_wr_en = 1'b0;
        end
    endtask

    task feed_packet;
        input [1:0] mode_i;
        integer lane;
        begin
            @(negedge clk);
            mode = mode_i;
            in_valid = 1'b1;
            in_addr = 4'd3;
            in_cout_base = 11'd8;
            in_channel_valid = 8'b1010_1011;
            for (lane = 0; lane < COUT_TILE; lane = lane + 1)
                in_data[lane*8 +: 8] = (lane[0]) ? (8'hf0 + lane[7:0]) : (8'd10 + lane[7:0]);
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task check_common;
        begin
            if (out_valid !== 1'b1) begin
                $display("[FAIL] valid");
                fail = fail + 1;
            end else pass = pass + 1;
            if (out_addr !== 4'd3 || out_cout_base !== 11'd8 || out_channel_valid !== 8'b1010_1011) begin
                $display("[FAIL] metadata addr=%0d cout=%0d mask=%b", out_addr, out_cout_base, out_channel_valid);
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    task check_mode;
        input [1:0] mode_i;
        reg [7:0] exp;
        begin
            feed_packet(mode_i);
            wait(out_valid);
            #1;
            check_common();
            for (i = 0; i < COUT_TILE; i = i + 1) begin
                if (mode_i == 2'd0)
                    exp = in_data[i*8 +: 8];
                else if (mode_i == 2'd1)
                    exp = ($signed(in_data[i*8 +: 8]) < 0) ? 8'd0 : in_data[i*8 +: 8];
                else
                    exp = in_data[i*8 +: 8] + 8'd1;
                if (out_data[i*8 +: 8] !== exp) begin
                    $display("[FAIL] mode%0d lane%0d got=%0d exp=%0d", mode_i, i, out_data[i*8 +: 8], exp);
                    fail = fail + 1;
                end else pass = pass + 1;
            end
            @(negedge clk);
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        mode = 0;
        in_valid = 0;
        in_addr = 0;
        in_cout_base = 0;
        in_channel_valid = 0;
        in_data = 0;
        lut_wr_en = 0;
        lut_wr_addr = 0;
        lut_wr_data = 0;
        pass = 0;
        fail = 0;

        repeat (3) @(negedge clk);
        rst = 0;
        load_lut_identity_plus_one();
        check_mode(2'd0);
        check_mode(2'd1);
        check_mode(2'd2);

        $display("=== tb_ofm_activation: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

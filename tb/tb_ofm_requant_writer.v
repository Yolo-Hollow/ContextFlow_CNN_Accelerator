`timescale 1ns / 1ps

module tb_ofm_requant_writer;
    localparam COLS = 4;
    localparam PSUM_W = 32;
    localparam MULT_W = 16;
    localparam SHIFT_W = 4;
    localparam ZP_W = 8;
    localparam ADDR_W = 4;

    reg clk, rst;
    reg packet_valid;
    reg [ADDR_W-1:0] packet_addr;
    reg [10:0] packet_cout_base;
    reg [COLS*2*PSUM_W-1:0] packet_data;
    reg [COLS*2*MULT_W-1:0] mult_flat;
    reg [COLS*2*SHIFT_W-1:0] shift_flat;
    reg [COLS*2*ZP_W-1:0] zp_flat;
    wire ofm_valid;
    wire [ADDR_W-1:0] ofm_addr;
    wire [10:0] ofm_cout_base;
    wire [COLS*2*8-1:0] ofm_data;

    ofm_requant_writer #(
        .COLS(COLS), .PSUM_W(PSUM_W), .MULT_W(MULT_W), .SHIFT_W(SHIFT_W),
        .ZP_W(ZP_W), .ADDR_W(ADDR_W)
    ) dut (
        .clk(clk), .rst(rst),
        .packet_valid(packet_valid), .packet_addr(packet_addr),
        .packet_cout_base(packet_cout_base), .packet_data(packet_data),
        .mult_flat(mult_flat), .shift_flat(shift_flat), .zp_flat(zp_flat),
        .ofm_valid(ofm_valid), .ofm_addr(ofm_addr),
        .ofm_cout_base(ofm_cout_base), .ofm_data(ofm_data)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer i;

    function [7:0] golden;
        input signed [PSUM_W-1:0] p;
        input [MULT_W-1:0] m;
        input [SHIFT_W-1:0] sh;
        input [ZP_W-1:0] zp;
        reg signed [63:0] v;
        reg signed [63:0] rnd;
        begin
            v = p * $signed({1'b0, m});
            rnd = (sh > 0) ? (1 <<< (sh - 1)) : 0;
            v = (v + rnd) >>> sh;
            v = v + $signed({1'b0, zp});
            if (v > 127) golden = 8'd127;
            else if (v < -128) golden = 8'd128;
            else golden = v[7:0];
        end
    endfunction

    task check_byte;
        input integer lane;
        reg [7:0] got;
        reg [7:0] exp;
        begin
            got = ofm_data[lane*8 +: 8];
            exp = golden(packet_data[lane*PSUM_W +: PSUM_W],
                         mult_flat[lane*MULT_W +: MULT_W],
                         shift_flat[lane*SHIFT_W +: SHIFT_W],
                         zp_flat[lane*ZP_W +: ZP_W]);
            if (got !== exp) begin
                $display("[FAIL] lane%0d got=%0d exp=%0d", lane, got, exp);
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        packet_valid = 0;
        packet_addr = 0;
        packet_cout_base = 0;
        packet_data = 0;
        mult_flat = 0;
        shift_flat = 0;
        zp_flat = 0;
        pass = 0;
        fail = 0;

        for (i = 0; i < COLS*2; i = i + 1) begin
            packet_data[i*PSUM_W +: PSUM_W] = (i[0] ? -32'sd200 : 32'sd100) + i*32'sd17;
            mult_flat[i*MULT_W +: MULT_W] = 16'd64 + i;
            shift_flat[i*SHIFT_W +: SHIFT_W] = 4'd6;
            zp_flat[i*ZP_W +: ZP_W] = 8'd3 + i;
        end

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        packet_addr = 4'd7;
        packet_cout_base = 11'd8;
        packet_valid = 1'b1;
        @(negedge clk);
        packet_valid = 1'b0;

        wait(ofm_valid);
        #1;
        if (ofm_addr !== 4'd7) begin
            $display("[FAIL] addr got=%0d", ofm_addr);
            fail = fail + 1;
        end else pass = pass + 1;
        if (ofm_cout_base !== 11'd8) begin
            $display("[FAIL] cout_base got=%0d", ofm_cout_base);
            fail = fail + 1;
        end else pass = pass + 1;
        for (i = 0; i < COLS*2; i = i + 1)
            check_byte(i);

        @(posedge clk);
        #1;
        if (ofm_valid !== 1'b0) begin
            $display("[FAIL] valid did not clear");
            fail = fail + 1;
        end else pass = pass + 1;

        $display("=== tb_ofm_requant_writer: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (200) @(negedge clk);
        $display("[FAIL] timeout valid=%0d", ofm_valid);
        $fatal(1);
    end
endmodule

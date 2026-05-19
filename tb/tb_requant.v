// Testbench: requant — verify multiply + shift + zp + clamp pipeline
`timescale 1ns / 1ps

module tb_requant;
    localparam PSUM_W = 24, MULT_W = 16, SHIFT_W = 4, ZP_W = 8;

    reg clk, rst;
    reg [MULT_W-1:0] mult0, mult1;
    reg [SHIFT_W-1:0] shift0, shift1;
    reg [ZP_W-1:0] zp0, zp1;
    reg signed [PSUM_W-1:0] psuma, psumb;
    reg valid;
    wire signed [7:0] ofm_a, ofm_b;
    wire valid_out;

    requant u_req (
        .clk(clk), .rst(rst),
        .mult0(mult0), .mult1(mult1),
        .shift0(shift0), .shift1(shift1),
        .zp_out0(zp0), .zp_out1(zp1),
        .psuma_in(psuma), .psumb_in(psumb),
        .valid_in(valid),
        .ofm_a(ofm_a), .ofm_b(ofm_b),
        .valid_out(valid_out)
    );

    always #5 clk = ~clk;

    integer pass, fail;

    // Golden model
    function [7:0] golden;
        input signed [PSUM_W-1:0] psum;
        input [MULT_W-1:0] mult;
        input [SHIFT_W-1:0] shift;
        input [ZP_W-1:0] zp;
        reg signed [63:0] prod;
        begin
            prod = psum * $signed({1'b0, mult});
            prod = prod >>> shift;
            prod = prod + $signed({1'b0, zp});
            if (prod > 127)       golden = 8'd127;
            else if (prod < -128)  golden = 8'd128;
            else                  golden = prod[7:0];
        end
    endfunction

    initial begin
        clk=0; rst=1; pass=0; fail=0;
        mult0=0; mult1=0; shift0=0; shift1=0; zp0=0; zp1=0;
        psuma=0; psumb=0; valid=0;

        repeat(3) @(negedge clk); rst=0; @(negedge clk); @(negedge clk);

        // ==== Test 1: identity (mult=1<<8, shift=8, zp=0) → psum/256 clamped to INT8
        $display("=== Test 1: identity-like ===");
        mult0=256; mult1=256; shift0=8; shift1=8; zp0=0; zp1=0;
        psuma=128; psumb=-128; valid=1; @(negedge clk);
        psuma=256; psumb=-256; valid=1; @(negedge clk);
        valid=0; @(negedge clk); @(negedge clk);

        if (ofm_a !== golden(128, 256, 8, 0)) begin
            $display("[FAIL] Test1a: got %0d exp %0d", ofm_a, golden(128,256,8,0)); fail=fail+1;
        end else pass=pass+1;
        if (ofm_b !== golden(-128, 256, 8, 0)) begin
            $display("[FAIL] Test1b: got %0d exp %0d", ofm_b, golden(-128,256,8,0)); fail=fail+1;
        end else pass=pass+1;

        // ==== Test 2: typical quant params (mult=12345, shift=12, zp=50)
        $display("=== Test 2: typical quant ===");
        @(negedge clk);
        mult0=12345; mult1=23456; shift0=12; shift1=14; zp0=50; zp1=100;
        psuma=528; psumb=11440; valid=1; @(negedge clk);
        valid=0; @(negedge clk); @(negedge clk);

        if (ofm_a !== golden(528, 12345, 12, 50)) begin
            $display("[FAIL] Test2a: got %0d exp %0d", ofm_a, golden(528,12345,12,50)); fail=fail+1;
        end else pass=pass+1;
        if (ofm_b !== golden(11440, 23456, 14, 100)) begin
            $display("[FAIL] Test2b: got %0d exp %0d", ofm_b, golden(11440,23456,14,100)); fail=fail+1;
        end else pass=pass+1;

        // ==== Test 3: saturation ====
        $display("=== Test 3: saturation ===");
        @(negedge clk);
        mult0=10000; shift0=0; zp0=0;  // large output → clamp
        psuma=24'd500000; psumb=-24'd500000; valid=1; @(negedge clk);
        valid=0; @(negedge clk); @(negedge clk);

        if (ofm_a !== 127) begin $display("[FAIL] Test3a: got %0d exp 127", ofm_a); fail=fail+1; end else pass=pass+1;
        if (ofm_b !== 8'd128) begin $display("[FAIL] Test3b: got %0d exp -128", ofm_b); fail=fail+1; end else pass=pass+1;

        // ==== Test 4: valid propagation ====
        $display("=== Test 4: valid pipeline ===");
        @(negedge clk);
        if (valid_out !== 0) begin $display("[FAIL] valid_out should be 0"); fail=fail+1; end else pass=pass+1;

        // ==== Result ====
        $display("=== %0d pass, %0d fail ===", pass, fail);
        $finish;
    end
endmodule

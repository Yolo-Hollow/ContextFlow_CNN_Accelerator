// requant testbench — single-beat, saturation, valid chain
`timescale 1ns / 1ps
module tb_requant;
    localparam PSUM_W=32, MULT_W=16, SHIFT_W=4, ZP_W=8;
    reg clk,rst,ce; reg [MULT_W-1:0] m0,m1; reg [SHIFT_W-1:0] s0,s1; reg [ZP_W-1:0] z0,z1;
    reg signed [PSUM_W-1:0] pa,pb; reg v;
    wire signed [7:0] oa,ob; wire vo;
    requant #(.PSUM_W(PSUM_W), .MULT_W(MULT_W), .SHIFT_W(SHIFT_W), .ZP_W(ZP_W))
    u(.clk(clk),.rst(rst),.mult0(m0),.mult1(m1),.shift0(s0),.shift1(s1),
              .zp_out0(z0),.zp_out1(z1),.psuma_in(pa),.psumb_in(pb),.valid_in(v),
              .ce(ce),
              .ofm_a(oa),.ofm_b(ob),.valid_out(vo));
    always #5 clk=~clk;
    integer pass,fail;

    function [7:0] g;
        input signed [PSUM_W-1:0] p; input [MULT_W-1:0] m; input [SHIFT_W-1:0] sf; input [ZP_W-1:0] zp;
        reg signed [63:0] r; reg signed [63:0] rnd;
        integer effective_shift;
        begin
            effective_shift = sf + 15;
            r = p * $signed({1'b0,m});
            rnd = 64'sd1 <<< (effective_shift - 1);
            r = (r + rnd) >>> effective_shift;
            r = r + $signed({1'b0,zp});
            if(r>127)g=127; else if(r<-128)g=8'd128; else g=r[7:0];
        end
    endfunction

    task feed_check;
        input signed [PSUM_W-1:0] ea, eb;
        begin
            v=1; pa=ea; pb=eb; @(negedge clk); v=0;
            repeat(3) @(negedge clk);
            if(oa!==g(ea,m0,s0,z0))begin $display("[FAIL] a in=%0d out=%0d exp=%0d",ea,oa,g(ea,m0,s0,z0)); fail=fail+1; end else pass=pass+1;
            if(ob!==g(eb,m1,s1,z1))begin $display("[FAIL] b in=%0d out=%0d exp=%0d",eb,ob,g(eb,m1,s1,z1)); fail=fail+1; end else pass=pass+1;
        end
    endtask

    initial begin
        clk=0; rst=1; ce=1; pass=0; fail=0; m0=0;m1=0;s0=0;s1=0;z0=0;z1=0;pa=0;pb=0;v=0;
        repeat(3)@(negedge clk); rst=0; @(negedge clk); @(negedge clk);

        m0=12345; m1=23456; s0=12; s1=14; z0=50; z1=100;

        $display("=== single beats ===");
        feed_check(-50000, -100000);   // negative
        feed_check(     0,       0);   // zero
        feed_check( 50000,  100000);   // positive
        feed_check(250000,  500000);   // larger positive

        $display("=== layer06 scale example ===");
        m0=18055; m1=18055; s0=7; s1=7; z0=75; z1=75;
        feed_check(-1510, 581);  // effective shift = 22

        $display("=== saturation ===");
        m0=32767; m1=32767; s0=0; s1=0; z0=0; z1=0;
        feed_check(       -29,        32);  // identity-scale negative / positive
        feed_check( 500000000, -500000000);  // clamp to 127 / -128

        $display("=== valid chain ===");
        if(vo!==0)begin $display("[FAIL] v0"); fail=fail+1; end else pass=pass+1;
        v=1; pa=100; pb=200; @(negedge clk); v=0;
        @(negedge clk); if(vo!==1)begin $display("[FAIL] v1 %0d",vo); fail=fail+1; end else pass=pass+1;
        @(negedge clk); if(vo!==0)begin $display("[FAIL] v2 %0d",vo); fail=fail+1; end else pass=pass+1;
        @(negedge clk); if(vo!==0)begin $display("[FAIL] v3 %0d",vo); fail=fail+1; end else pass=pass+1;

        $display("=== %0d pass, %0d fail ===", pass, fail); $finish;
    end
endmodule

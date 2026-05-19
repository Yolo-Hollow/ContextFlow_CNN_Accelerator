// Testbench: leaky_lut — load LUT, verify readback + LeakyReLU behavior
`timescale 1ns / 1ps
module tb_leaky_lut;
    reg clk, wr_en;
    reg [7:0] wr_addr, wr_data, data_in;
    wire [7:0] data_out;

    leaky_lut u(.clk(clk), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
                .data_in(data_in), .data_out(data_out));
    always #5 clk=~clk;

    integer pass,fail,i;

    // Software golden: LeakyReLU INT8, slope=0.1, zero_point=zp
    function [7:0] golden;
        input [7:0] x; input [7:0] zp;
        integer diff;
        begin
            if (x >= zp)      golden = x;
            else begin
                diff = x - zp;  // negative
                diff = diff * 0.1;  // ~0.1x slope, truncates toward zero
                golden = zp + diff;
            end
        end
    endfunction

    initial begin
        clk=0; pass=0; fail=0; wr_en=0; data_in=0;

        // Load LUT: golden values for zp=50
        $display("=== Load LUT (zp=50, slope=0.1) ===");
        wr_en=1;
        for (i=0; i<256; i=i+1) begin
            wr_addr=i[7:0]; wr_data=golden(i[7:0], 50); @(negedge clk);
        end
        wr_en=0;

        // Verify all 256 entries by reading back through data_in→data_out
        $display("=== Verify 256 entries ===");
        for (i=0; i<256; i=i+1) begin
            data_in = i[7:0];
            #1;  // let combinational read settle
            if (data_out !== golden(i[7:0], 50)) begin
                $display("[FAIL] in=%0d out=%0d exp=%0d", i, data_out, golden(i[7:0], 50));
                fail=fail+1;
            end else pass=pass+1;
        end

        // Test specific corner cases
        $display("=== Corner cases ===");
        // in > zp: identity
        data_in=100; #1;
        if (data_out !== 100) begin $display("[FAIL] in=100"); fail=fail+1; end else pass=pass+1;
        // in == zp: identity
        data_in=50; #1;
        if (data_out !== 50) begin $display("[FAIL] in=50"); fail=fail+1; end else pass=pass+1;
        // in < zp: leaky
        data_in=0; #1;
        if (data_out !== golden(0, 50)) begin $display("[FAIL] in=0"); fail=fail+1; end else pass=pass+1;
        data_in=49; #1;
        if (data_out !== golden(49, 50)) begin $display("[FAIL] in=49"); fail=fail+1; end else pass=pass+1;

        $display("=== %0d pass, %0d fail ===", pass, fail); $finish;
    end
endmodule

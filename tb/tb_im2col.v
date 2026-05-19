// im2col_addr_gen testbench
`timescale 1ns / 1ps
module tb_im2col;
    reg clk,rst,start;
    reg [11:0] npix;
    wire done,rd_en;
    wire [11:0] rd_addr;

    im2col_addr_gen u(.clk(clk),.rst(rst),.num_pixels(npix),.start(start),
                      .done(done),.rd_en(rd_en),.rd_addr(rd_addr));
    always #5 clk=~clk;
    integer pass,fail,i;

    initial begin
        clk=0; rst=1; pass=0; fail=0; start=0; npix=0;
        repeat(3)@(negedge clk); rst=0; @(negedge clk); @(negedge clk);

        // Test: 64 pixels
        $display("=== 64 pixels ===");
        npix=64; @(negedge clk); start=1; @(negedge clk); start=0;
        // rd_addr=0 is valid starting from posedge after start=1.
        // First check at this negedge: rd_addr should be 0
        if(rd_addr !== 0) begin $display("[FAIL] start addr=%0d",rd_addr); fail=fail+1; end else pass=pass+1;
        for(i=1; i<64; i=i+1) begin
            @(negedge clk);
            if(rd_addr !== i) begin $display("[FAIL] addr=%0d exp=%0d",rd_addr,i); fail=fail+1; end else pass=pass+1;
        end
        @(negedge clk);
        if(done!==1) begin $display("[FAIL] done=%0d",done); fail=fail+1; end else pass=pass+1;
        if(rd_en!==0) begin $display("[FAIL] rd_en after done"); fail=fail+1; end else pass=pass+1;

        $display("=== %0d pass, %0d fail ===", pass, fail); $finish;
    end
endmodule

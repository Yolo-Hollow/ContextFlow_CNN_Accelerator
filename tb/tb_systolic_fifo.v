// Testbench: systolic_fifo with overflow/underflow protection tests
`timescale 1ns / 1ps

module tb_systolic_fifo;
    localparam WIDTH = 8, DEPTH = 8, AW = 3;

    reg clk, rst, wr_en, rd_en;
    reg [WIDTH-1:0] data_in;
    wire [WIDTH-1:0] data_out;
    wire empty, full;

    systolic_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH), .AW(AW))
    u_fifo (.clk(clk),.rst(rst),.wr_en(wr_en),.rd_en(rd_en),
            .data_in(data_in),.data_out(data_out),.empty(empty),.full(full));
    always #5 clk=~clk;

    integer pass, fail, ii;
    reg [7:0] xp;

    task chk_flag;
        input e_e, e_f;
        begin
            if(empty!==e_e) begin $display("  empty FAIL: got %0d exp %0d",empty,e_e); fail=fail+1; end else pass=pass+1;
            if(full !==e_f) begin $display("  full  FAIL: got %0d exp %0d",full, e_f); fail=fail+1; end else pass=pass+1;
        end
    endtask
    task chk_data;
        input [WIDTH-1:0] e_d;
        begin
            if(data_out!==e_d) begin $display("  data  FAIL: got %0d exp %0d",data_out,e_d); fail=fail+1; end else pass=pass+1;
        end
    endtask

    initial begin
        clk=0; rst=1; pass=0; fail=0; wr_en=0; rd_en=0; data_in=0;
        repeat(3) @(negedge clk); rst=0; @(negedge clk); @(negedge clk);

        // TEST 1: after reset, data_out=0 (now has reset), empty=1
        $display("=== TEST 1: Reset state ===");
        chk_data(8'd0);
        chk_flag(1'b1, 1'b0);

        // TEST 2: write 1, read 1
        $display("=== TEST 2: Single write+read ===");
        wr_en=1; data_in=42; #1; @(negedge clk);
        wr_en=0;            #1; @(negedge clk); chk_flag(1'b0, 1'b0);
        rd_en=1;            #1; @(negedge clk); chk_data(42);
        rd_en=0;            #1; @(negedge clk); chk_flag(1'b1, 1'b0);

        // TEST 3: fill 8, read 8
        $display("=== TEST 3: Fill+read 8 ===");
        rst=1; repeat(2) @(negedge clk); rst=0; @(negedge clk); @(negedge clk);
        chk_data(8'd0); chk_flag(1'b1, 1'b0);
        wr_en=1;
        for(ii=0; ii<8; ii=ii+1) begin data_in=ii[7:0]; #1; @(negedge clk); end
        wr_en=0; #1; @(negedge clk); chk_flag(1'b0, 1'b1);
        // Verify full protection: write when full should be ignored
        wr_en=1; data_in=99; #1; @(negedge clk);
        wr_en=0; #1; @(negedge clk); chk_flag(1'b0, 1'b1);
        $display("  (overflow protection: write ignored when full)");
        rd_en=1;
        for(ii=0; ii<8; ii=ii+1) begin #1; @(negedge clk); xp=ii[7:0]; chk_data(xp); end
        rd_en=0; #1; @(negedge clk); chk_flag(1'b1, 1'b0);

        // TEST 4: underflow protection — read when empty
        $display("=== TEST 4: Underflow protection ===");
        rd_en=1; #1; @(negedge clk);
        // When empty, rden_int=0 → rptr stays, data_out keeps last valid value (7 from Test 3)
        chk_flag(1'b1, 1'b0);  // still empty, rptr didn't advance
        rd_en=0; #1; @(negedge clk);
        $display("  (underflow protection: read ignored when empty, rptr didn't advance)");

        // TEST 5: simultaneous r/w
        $display("=== TEST 5: Simultaneous w/r ===");
        rst=1; repeat(2) @(negedge clk); rst=0; @(negedge clk); @(negedge clk);
        wr_en=1; rd_en=1;
        for(ii=10; ii<17; ii=ii+1) begin
            data_in=ii[7:0]; #1; @(negedge clk);
            // First cycle: data was empty (0), new write i=10 goes in
            // Output: data_out is from read of mem before this cycle's write
            // In simultaneous r/w mode: read gets data from same cycle (pass-through)
            // Actually: rden_int=0 when empty (wptr==rptr), so first read is ignored
        end
        wr_en=0; rd_en=0;

        // TEST 6: wrap-around
        $display("=== TEST 6: Wrap-around ===");
        rst=1; repeat(2) @(negedge clk); rst=0; @(negedge clk); @(negedge clk);
        chk_data(8'd0);
        wr_en=1;
        for(ii=0; ii<6; ii=ii+1) begin data_in=ii+20; #1; @(negedge clk); end
        wr_en=0; #1; @(negedge clk); chk_flag(1'b0, 1'b0);
        rd_en=1;
        for(ii=0; ii<3; ii=ii+1) begin #1; @(negedge clk); xp=ii+20; chk_data(xp); end
        rd_en=0;
        wr_en=1;
        for(ii=0; ii<5; ii=ii+1) begin data_in=ii+30; #1; @(negedge clk); end
        wr_en=0; #1; @(negedge clk); chk_flag(1'b0, 1'b1);
        rd_en=1;
        for(ii=3; ii<6; ii=ii+1) begin #1; @(negedge clk); xp=ii+20; chk_data(xp); end
        for(ii=0; ii<5; ii=ii+1) begin #1; @(negedge clk); xp=ii+30; chk_data(xp); end
        rd_en=0; #1; @(negedge clk); chk_flag(1'b1, 1'b0);

        $display("==========================================");
        $display("  FIFO TB: %0d checks, %0d pass, %0d fail", pass+fail, pass, fail);
        if(fail>0) $display("*** FAILURES DETECTED ***");
        else       $display("*** ALL GOOD ***");
        $finish;
    end
endmodule

// Top-level testbench with valid-based architecture
// Pre-fill IFM/Weight FIFOs, start compute, verify PSUM FIFO contents
`timescale 1ns / 1ps

module tb_systolic_top;
    localparam ROWS = 32, COLS = 32;
    localparam IFM_W = 8, WGT_W = 8, PSUM_W = 24;
    localparam IFM_D = 64, IFM_AW = 6, WGT_D = 64, WGT_AW = 6, PSUM_D = 256, PSUM_AW = 8;
    // IFM_D=64: exactly 8x8 output pixels for our test convolution

    reg clk, rst, start;
    wire done;

    reg  [31:0]               ifm_wr_en;  reg  [ROWS*IFM_W-1:0]   ifm_wr_data;
    wire [31:0]               ifm_full;
    reg  [31:0]               wgt_wr_en;  reg  [ROWS*WGT_W*2-1:0] wgt_wr_data;
    wire [31:0]               wgt_full;
    reg  [31:0]               psum_rd_en;
    wire [COLS*PSUM_W*2-1:0]  psum_rd_data;
    wire [31:0]               psum_empty;

    systolic_top #(.ROWS(ROWS),.COLS(COLS), .IFM_FIFO_DEPTH(IFM_D), .IFM_FIFO_AW(IFM_AW)) u_top (
        .clk(clk),.rst(rst),.start(start),.done(done),
        .ifm_fifo_wr_en(ifm_wr_en),.ifm_fifo_wr_data(ifm_wr_data),.ifm_fifo_full(ifm_full),
        .wgt_fifo_wr_en(wgt_wr_en),.wgt_fifo_wr_data(wgt_wr_data),.wgt_fifo_full(wgt_full),
        .psum_fifo_rd_en(psum_rd_en),.psum_fifo_rd_data(psum_rd_data),.psum_fifo_empty(psum_empty)
    );

    always #5 clk = ~clk;

    integer ii, rr, cc, pass, fail;
    reg [7:0] w0b, w1b; reg [511:0] wtmp;
    reg check_now;  genvar c;  // declared before use

    initial begin
        clk=0; rst=1; start=0; pass=0; fail=0;
        ifm_wr_en=0; ifm_wr_data=0; wgt_wr_en=0; wgt_wr_data=0; psum_rd_en=0;

        repeat(3) @(negedge clk); rst=0; repeat(2) @(negedge clk);

        // ---- 1: Fill Weight FIFOs (32 entries, column 0..31) ----
        $display("=== 1: Fill Weight FIFOs ===");
        for (cc=0; cc<32; cc=cc+1) begin
            wtmp=0;
            for (rr=0; rr<32; rr=rr+1) begin
                w0b=cc+1; w1b=rr+1;
                // Verilog {a,b}: a→upper [15:8], b→lower [7:0]
                // PE: pe_w0=lower, pe_w1=upper → {w1b,w0b} so pe_w0=col-wt, pe_w1=row-wt
                wtmp = wtmp | ({w1b,w0b} << (rr*16));
            end
            wgt_wr_data=wtmp; wgt_wr_en={32{1'b1}}; @(negedge clk);
        end
        wgt_wr_en=0;

        // ---- 2: Fill IFM FIFOs (200 entries, all = 1) ----
        $display("=== 2: Fill IFM FIFOs ===");
        ifm_wr_data = {ROWS{8'd1}}; ifm_wr_en = {32{1'b1}};
        for (ii=0; ii<64; ii=ii+1) @(negedge clk);
        ifm_wr_en=0;

        // ---- 3: Start compute ----
        $display("=== 3: Start ===");
        @(negedge clk); start=1; @(negedge clk); start=0;

        // ---- 4: Wait for pipeline fill + stable output ----
        $display("=== 4: Wait for pipeline... ===");
        // Pipeline fill: ~32*5=160 cycles, +64 pixels, + drain ~130
        repeat (350) @(negedge clk);

        // ---- 5: Skip pipeline-fill entries, then read valid data ----
        $display("=== 5: Skip first 155 (pipe fill partial sums), read valid ===");
        psum_rd_en = {32{1'b1}};
        for (ii=0; ii<155; ii=ii+1) @(negedge clk);
        psum_rd_en = 0; @(negedge clk);
        // Now read one valid entry from each FIFO
        for (cc=0; cc<32; cc=cc+1) begin
            psum_rd_en = (1'b1 << cc); @(negedge clk);
            psum_rd_en = 0;            @(negedge clk);
        end

        // ---- 6: Verify ----
        $display("=== 6: Verify ===");
        check_now = 1; repeat (5) @(negedge clk);
        $display("%0d pass, %0d fail", pass, fail);
        $finish;
    end

    generate
        for (c = 0; c < 32; c = c + 1) begin : chk
            // Extract column c's 48-bit PSUM FIFO read data
            wire [PSUM_W*2-1:0] raw = psum_rd_data[(c+1)*PSUM_W*2-1 : c*PSUM_W*2];
            // RTL packs {psumb, psuma} in 48b → lo=psuma, hi=psumb
            wire [PSUM_W-1:0]   lo  = raw[PSUM_W-1:0];
            wire [PSUM_W-1:0]   hi  = raw[PSUM_W*2-1:PSUM_W];
            // psuma = row-weight * ifm = 528, psumb = col-weight * ifm = 32*(c+1)
            // w0=c+1(col-wt)→psuma varies, w1=r+1(row-wt)→psumb=528 constant
            wire [PSUM_W-1:0]   exp_lo = 32 * (c + 1);
            wire [PSUM_W-1:0]   exp_hi = 528;

            always @(posedge clk) begin
                if (check_now) begin
                    if (lo !== exp_lo) $display("[FAIL] col%0d psuma=%0d exp=%0d", c, lo, exp_lo);
                    else                $display("[ OK ] col%0d psuma=%0d", c, lo);
                    if (hi !== exp_hi) $display("[FAIL] col%0d psumb=%0d exp=%0d", c, hi, exp_hi);
                    else                $display("[ OK ] col%0d psumb=%0d", c, hi);
                end
            end
        end
    endgenerate
endmodule

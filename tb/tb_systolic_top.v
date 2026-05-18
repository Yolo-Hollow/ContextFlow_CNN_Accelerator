// Top-level testbench — verify ALL 64 output pixels per column
// IFM[pixel][r] = pixel+1, WGT: PE(r,c).w0=c+1, PE(r,c).w1=r+1
`timescale 1ns / 1ps

module tb_systolic_top;
    localparam ROWS = 32, COLS = 32;
    localparam IFM_W = 8, WGT_W = 8, PSUM_W = 24;
    localparam IFM_D = 64, IFM_AW = 6, WGT_D = 64, WGT_AW = 6, PSUM_D = 256, PSUM_AW = 8;

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

    integer ii, rr, cc, pp, pass, fail, pixel_cnt;
    reg [7:0] w0b, w1b; reg [511:0] wtmp;
    genvar c;

    reg [31:0] col_rd;  // which column is being read now

    initial begin
        clk=0; rst=1; start=0; pass=0; fail=0;
        ifm_wr_en=0; ifm_wr_data=0; wgt_wr_en=0; wgt_wr_data=0; psum_rd_en=0;
        col_rd=0;

        repeat(3) @(negedge clk); rst=0; repeat(2) @(negedge clk);

        // ---- 1: Fill Weight FIFOs ----
        $display("=== 1: Fill Weight FIFOs ===");
        for (cc=0; cc<32; cc=cc+1) begin
            wtmp=0;
            for (rr=0; rr<32; rr=rr+1) begin
                w0b=cc+1; w1b=rr+1;
                wtmp = wtmp | ({w1b,w0b} << (rr*16));
            end
            wgt_wr_data=wtmp; wgt_wr_en={32{1'b1}}; @(negedge clk);
        end
        wgt_wr_en=0;

        // ---- 2: Fill IFM FIFOs (64 pixels, ifm[pixel][r] = pixel+1) ----
        $display("=== 2: Fill IFM FIFOs (ifm[p]=p+1) ===");
        for (pp=0; pp<64; pp=pp+1) begin
            ifm_wr_data = 256'd0;
            for (rr=0; rr<32; rr=rr+1) begin
                w0b = pp + 1;
                ifm_wr_data = ifm_wr_data | ({w0b} << (rr*8));
            end
            ifm_wr_en = {32{1'b1}}; @(negedge clk);
        end
        ifm_wr_en = 0;

        // ---- 3: Start compute ----
        $display("=== 3: Start ===");
        @(negedge clk); start=1; @(negedge clk); start=0;

        // ---- 4: Wait for pipeline ----
        repeat (350) @(negedge clk);

        // ---- 5: Drain all entries from each PSUM FIFO, check via generate ----
        $display("=== 5: Drain & verify all 64 pixels per column ===");
        for (cc=0; cc<32; cc=cc+1) begin
            col_rd = cc;
            // Read all 64 entries (FIFO goes empty after last valid entry)
            for (pp=0; pp<64; pp=pp+1) begin  // 1 garbage + 63 valid (pipeline tail loss)
                psum_rd_en = (1'b1 << cc); @(negedge clk);
                psum_rd_en = 0;            @(negedge clk);
            end
        end
        col_rd = 32;  // done reading

        // Let checker finish
        repeat (3) @(negedge clk);
        $display("=== Result: %0d pass, %0d fail ===", pass, fail);
        $finish;
    end

    // Generate-block checker: triggered when its column is being read
    generate
        for (c = 0; c < 32; c = c + 1) begin : chk
            wire [PSUM_W*2-1:0] raw = psum_rd_data[(c+1)*PSUM_W*2-1 : c*PSUM_W*2];
            wire [PSUM_W-1:0]   lo  = raw[PSUM_W-1:0];
            wire [PSUM_W-1:0]   hi  = raw[PSUM_W*2-1:PSUM_W];

            reg [7:0] pix;  // pixel counter, increments on each read of this column
            always @(posedge clk) begin
                if (rst) pix <= 0;
                else if (col_rd == c && psum_rd_en[c]) pix <= pix + 1;
                else if (col_rd != c) pix <= 0;
            end

            reg [7:0] pix_d;  // delayed pixel to align with FIFO read latency
            always @(posedge clk) pix_d <= pix;

            // First FIFO entry is garbage (timing artifact), skip it.
            // pix_d=2 → pixel 0, pix_d=3 → pixel 1, ...
            wire [PSUM_W-1:0] exp_lo = (pix_d >= 2) ? (pix_d - 1) * 32 * (c + 1) : 0;
            wire [PSUM_W-1:0] exp_hi = (pix_d >= 2) ? (pix_d - 1) * 528 : 0;

            reg check_me, check_me_d;
            always @(posedge clk) begin
                if (rst) {check_me_d, check_me} <= 0;
                else     {check_me_d, check_me} <= {check_me, (col_rd == c) && psum_rd_en[c]};
            end

            always @(posedge clk) begin
                if (check_me_d) begin
                    if (lo !== exp_lo) begin
                        $display("[FAIL] col%0d pix%0d psuma=%0d exp=%0d", c, pix_d, lo, exp_lo);
                    end else begin
                        $display("[ OK ] col%0d pix%0d psuma=%0d", c, pix_d, lo);
                    end
                    if (hi !== exp_hi) begin
                        $display("[FAIL] col%0d pix%0d psumb=%0d exp=%0d", c, pix_d, hi, exp_hi);
                    end else begin
                        $display("[ OK ] col%0d pix%0d psumb=%0d", c, pix_d, hi);
                    end
                end
            end
        end
    endgenerate
endmodule

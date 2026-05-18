// Top-level testbench: full integration — 9x9x8 IFM, 2x2x8x64 kernel, stride=1
// All IFM=1, PE(r,c).w0=c+1, PE(r,c).w1=r+1
// Expect: psuma[c] = 32*(c+1), psumb[c] = 528
`timescale 1ns / 1ps

module tb_systolic_top;
    localparam ROWS = 32, COLS = 32;
    localparam IFM_W = 8, WGT_W = 8, PSUM_W = 24;
    localparam IFM_RAM_AW = 12, WGT_RAM_AW = 7, PSUM_RAM_AW = 5;
    localparam CLK = 10;

    reg clk, rst, start;
    wire done;
    wire ifm_rd_en, wgt_rd_en, psum_wr_en, psum_rd_en;
    wire [IFM_RAM_AW-1:0]  ifm_rd_addr;
    wire [WGT_RAM_AW-1:0]  wgt_rd_addr;
    wire [PSUM_RAM_AW-1:0] psum_wr_addr, psum_rd_addr;
    reg  [ROWS*IFM_W-1:0]   ifm_rd_data;
    reg  [ROWS*WGT_W*2-1:0] wgt_rd_data;
    wire [PSUM_W*2-1:0]     psum_wr_data;
    reg  [PSUM_W-1:0]       psum_rd_data;

    systolic_top #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WGT_W), .PSUM_W(PSUM_W),
        .IFM_RAM_AW(IFM_RAM_AW), .WGT_RAM_AW(WGT_RAM_AW), .PSUM_RAM_AW(PSUM_RAM_AW)
    ) u_top (
        .clk(clk), .rst(rst), .start(start), .done(done),
        .ifm_ram_rd_en(ifm_rd_en), .ifm_ram_rd_addr(ifm_rd_addr), .ifm_ram_rd_data(ifm_rd_data),
        .wgt_ram_rd_en(wgt_rd_en), .wgt_ram_rd_addr(wgt_rd_addr), .wgt_ram_rd_data(wgt_rd_data),
        .psum_ram_wr_en(psum_wr_en), .psum_ram_wr_addr(psum_wr_addr),
        .psum_ram_wr_data(psum_wr_data),
        .psum_ram_rd_en(psum_rd_en), .psum_ram_rd_addr(psum_rd_addr),
        .psum_ram_rd_data(psum_rd_data)
    );

    always #(CLK/2) clk = ~clk;

    // ================================================================
    // IFM RAM model — 4096 x 256-bit
    // ================================================================
    reg [ROWS*IFM_W-1:0] ifm_mem [0:4095];
    always @(posedge clk) begin
        if (ifm_rd_en) ifm_rd_data <= ifm_mem[ifm_rd_addr];
    end

    // ================================================================
    // Weight RAM model — 128 x 512-bit
    // ================================================================
    reg [ROWS*WGT_W*2-1:0] wgt_mem [0:127];
    always @(posedge clk) begin
        if (wgt_rd_en) wgt_rd_data <= wgt_mem[wgt_rd_addr];
    end

    // ================================================================
    // PSUM RAM model — 32 x 48-bit (capture writes)
    // ================================================================
    reg [PSUM_W*2-1:0] psum_mem [0:31];
    always @(posedge clk) begin
        if (psum_wr_en) psum_mem[psum_wr_addr] <= psum_wr_data;
    end
    always @(posedge clk) begin
        if (psum_rd_en) psum_rd_data <= psum_mem[psum_rd_addr][PSUM_W-1:0];
    end

    // ================================================================
    // Pre-fill RAMs
    // ================================================================
    integer r, c;
    reg [511:0] wgt_tmp;
    reg [7:0] w0_byte, w1_byte;

    task prefill_rams;
        begin
            // IFM: all pixels = 1 (fill entire RAM to avoid X reads)
            for (r = 0; r < 4096; r = r + 1)
                ifm_mem[r] = {ROWS{8'd1}};

            // WGT: 32 columns, PE(r,c).w0=c+1, PE(r,c).w1=r+1
            for (c = 0; c < 32; c = c + 1) begin
                wgt_tmp = 512'd0;
                for (r = 0; r < 32; r = r + 1) begin
                    w0_byte = c + 1; w1_byte = r + 1;
                    wgt_tmp = wgt_tmp | ({w0_byte, w1_byte} << (r * 16));
                end
                wgt_mem[c] = wgt_tmp[511:0];
            end
        end
    endtask

    // ================================================================
    // Test
    // ================================================================
    integer pass, fail, ii;
    reg signed [PSUM_W-1:0] exp_a, exp_b, got_a, got_b;

    initial begin
        clk = 0; rst = 1; start = 0; pass = 0; fail = 0;
        ifm_rd_data = 0; wgt_rd_data = 0; psum_rd_data = 0;

        prefill_rams;

        repeat (5) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        // ---- Launch ----
        $display("=== Launching systolic_top ===");
        @(negedge clk); start = 1;

        // Wait for compute to complete (pipeline fill + 64 pixels + drain = ~500)
        // Keep start high for 800 cycles then release
        repeat (800) @(negedge clk);
        start = 0;

        // Monitor psum_wr_en and done signals
        $display("  [%0t] waiting for done... psum_wr_en=%0d done=%0d", $time, psum_wr_en, done);
        repeat (100) @(negedge clk);
        $display("  [%0t] after wait: psum_wr_en=%0d done=%0d", $time, psum_wr_en, done);

        // Also check: did PSUM RAM get any writes?
        $display("  psum_mem[0]=%0d psum_mem[1]=%0d", psum_mem[0], psum_mem[1]);
        repeat (1000) @(negedge clk);
        $display("  [%0t] done=%0d — setting start=0", $time, done);
        start = 0;

        // Wait for DONE + PSUM drain
        repeat (200) @(negedge clk);
        $display("  [%0t] after drain: done=%0d", $time, done);

        // ---- Verify PSUM RAM ----
        $display("=== Verifying PSUM RAM ===");
        for (c = 0; c < 32; c = c + 1) begin
            // RTL packs {psumb, psuma} in 48-bit word: upper=psumb, lower=psuma
            // After PE swap: psumb = w0*ifm col-weight, psuma = w1*ifm row-weight
            got_b = psum_mem[c][PSUM_W*2-1:PSUM_W];  // upper = psumb
            got_a = psum_mem[c][PSUM_W-1:0];         // lower = psuma
            exp_a = 528;
            exp_b = 32 * (c + 1);

            if (got_a !== exp_a) begin
                $display("[FAIL] col%0d psuma=%0d expected=%0d", c, got_a, exp_a);
                fail = fail + 1;
            end else pass = pass + 1;

            if (got_b !== exp_b) begin
                $display("[FAIL] col%0d psumb=%0d expected=%0d", c, got_b, exp_b);
                fail = fail + 1;
            end else pass = pass + 1;
        end

        $display("==========================================");
        $display("  Top TB: %0d checks, %0d pass, %0d fail", pass+fail, pass, fail);
        if (fail > 0) $display("*** FAILURES DETECTED ***");
        else          $display("*** ALL GOOD ***");
        $display("==========================================");
        $finish;
    end
endmodule

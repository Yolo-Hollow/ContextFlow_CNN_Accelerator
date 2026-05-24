// Testbench for systolic_pe
// Verifies: weight load, ifm passthrough (4-cycle), psum chain (5-cycle), DSP accuracy
`timescale 1ns / 1ps

module tb_systolic_pe;
    localparam IFM_W  = 8;
    localparam WGT_W  = 8;
    localparam PSUM_W = 32;

    reg clk, rst;
    reg w_load;
    reg signed [WGT_W-1:0] w0_in, w1_in;
    reg signed [IFM_W-1:0]  ifm_in;
    wire signed [IFM_W-1:0] ifm_out;
    reg valid_in_h, valid_in_va, valid_in_vb;
    wire valid_out_h, valid_out_va, valid_out_vb;
    reg signed [PSUM_W-1:0] psuma_in, psumb_in;
    wire signed [PSUM_W-1:0] psuma_out, psumb_out;

    systolic_pe #(.IFM_W(IFM_W), .WEIGHT_W(WGT_W), .PSUM_W(PSUM_W))
    u_pe (
        .clk(clk), .rst(rst),
        .w_load(w_load), .w0_in(w0_in), .w1_in(w1_in),
        .ifm_in(ifm_in), .valid_in_h(valid_in_h),
        .ifm_out(ifm_out), .valid_out_h(valid_out_h),
        .psuma_in(psuma_in), .valid_in_va(valid_in_va),
        .psuma_out(psuma_out), .valid_out_va(valid_out_va),
        .psumb_in(psumb_in), .valid_in_vb(valid_in_vb),
        .psumb_out(psumb_out), .valid_out_vb(valid_out_vb)
    );

    always #5 clk = ~clk;  // 100 MHz

    // Input history pipelines — mirror PE depth
    reg signed [IFM_W-1:0]  ifm_hist  [0:15];
    reg signed [PSUM_W-1:0] psuma_hist [0:15];
    reg signed [PSUM_W-1:0] psumb_hist [0:15];
    reg signed [WGT_W-1:0]  w0_ref, w1_ref;
    integer h;
    always @(posedge clk) begin
        if (!rst) begin
            for (h = 15; h > 0; h = h - 1) begin
                ifm_hist[h]   <= ifm_hist[h-1];
                psuma_hist[h] <= psuma_hist[h-1];
                psumb_hist[h] <= psumb_hist[h-1];
            end
            ifm_hist[0]   <= ifm_in;
            psuma_hist[0] <= psuma_in;
            psumb_hist[0] <= psumb_in;
            if (w_load) begin
                w0_ref <= w0_in;
                w1_ref <= w1_in;
            end
        end
    end

    // Check outputs against golden model at negedge
    integer pass, fail;
    integer pipeline_fill_cnt;
    reg checking;

    wire signed [15:0] prod_a_ref = w0_ref * ifm_hist[4];
    wire signed [15:0] prod_b_ref = w1_ref * ifm_hist[4];
    wire signed [PSUM_W-1:0] exp_psuma = psuma_hist[4] + {{PSUM_W-16{prod_a_ref[15]}}, prod_a_ref};
    wire signed [PSUM_W-1:0] exp_psumb = psumb_hist[4] + {{PSUM_W-16{prod_b_ref[15]}}, prod_b_ref};

    always @(negedge clk) begin
        if (!rst) begin
            if (pipeline_fill_cnt < 8) pipeline_fill_cnt <= pipeline_fill_cnt + 1;
            else checking <= 1'b1;
        end

        if (checking) begin
            if (ifm_out !== ifm_hist[3]) begin
                $display("[FAIL] ifm_out=%0d expected=%0d (hist[3])", ifm_out, ifm_hist[3]);
                fail = fail + 1;
            end else pass = pass + 1;

            if (psuma_out !== exp_psuma) begin
                $display("[FAIL] psuma=%0d expected=%0d (%0d + %0d*%0d)",
                    psuma_out, exp_psuma, psuma_hist[4], w0_ref, ifm_hist[4]);
                fail = fail + 1;
            end else pass = pass + 1;

            if (psumb_out !== exp_psumb) begin
                $display("[FAIL] psumb=%0d expected=%0d (%0d + %0d*%0d)",
                    psumb_out, exp_psumb, psumb_hist[4], w1_ref, ifm_hist[4]);
                fail = fail + 1;
            end else pass = pass + 1;
        end
    end

    // ---- Stimulus ----
    integer test_cycle;
    initial begin
        clk = 0; rst = 1;
        w_load = 0; w0_in = 0; w1_in = 0;
        valid_in_h = 1'b1; valid_in_va = 1'b1; valid_in_vb = 1'b1;
        ifm_in = 0; psuma_in = 0; psumb_in = 0;
        checking = 0; pipeline_fill_cnt = 0; pass = 0; fail = 0;
        test_cycle = 0;

        // ---- Reset ----
        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ==== Weight load: w0=3, w1=5 ====
        $display("=== Weight load: w0=3, w1=5 ===");
        w_load = 1; w0_in = 3; w1_in = 5;
        @(negedge clk);
        w_load = 0;

        // ==== Stream 1: basic multiply (ifm=2,4,6, psum=100,200,300) ====
        $display("=== Stream 1: ifm=2,4,6 with psum=100,200,300 ===");
        ifm_in = 2;  psuma_in = 100; psumb_in = 200; @(negedge clk);
        ifm_in = 4;  psuma_in = 200; psumb_in = 300; @(negedge clk);
        ifm_in = 6;  psuma_in = 300; psumb_in = 400; @(negedge clk);
        ifm_in = 0;  psuma_in = 0;   psumb_in = 0;   @(negedge clk);

        // ==== Stream 2: negative values ====
        $display("=== Stream 2: negative ifm = -3, -7, -1 ===");
        ifm_in = -3; psuma_in = 10; psumb_in = 20; @(negedge clk);
        ifm_in = -7; psuma_in = 20; psumb_in = 30; @(negedge clk);
        ifm_in = -1; psuma_in = 30; psumb_in = 40; @(negedge clk);
        ifm_in = 0;  psuma_in = 0;  psumb_in = 0;  @(negedge clk);

        // ==== Stream 3: max INT8 corner ====
        $display("=== Stream 3: corner ifm=127, -128 ===");
        psuma_in = 8000000; psumb_in = -8000000;
        ifm_in = 127;  @(negedge clk);
        ifm_in = -128; @(negedge clk);
        ifm_in = 0; psuma_in = 0; psumb_in = 0; @(negedge clk);

        // Drain corner-case data from pipeline before changing weights
        repeat (8) @(negedge clk);

        // ==== Change weights: w0=0, w1=0 ====
        $display("=== Weight change: w0=0, w1=0 ===");
        checking = 0; pipeline_fill_cnt = 0;  // re-wait after transition
        w_load = 1; w0_in = 0; w1_in = 0; @(negedge clk); w_load = 0;

        // ==== Stream 4: zero-weight passthrough ====
        $display("=== Stream 4: ifm=50, -99 with zero weights ===");
        ifm_in = 50;  psuma_in = 500; psumb_in = -500; @(negedge clk);
        ifm_in = -99; psuma_in = 300; psumb_in = -300; @(negedge clk);
        ifm_in = 0;   psuma_in = 0;   psumb_in = 0;    @(negedge clk);

        // ---- Drain pipeline & finish ----
        $display("=== Draining pipeline ===");
        repeat (10) @(negedge clk);
        checking = 0;

        $display("==========================================");
        $display("  PE Testbench: %0d checks, %0d pass, %0d fail", pass+fail, pass, fail);
        if (fail > 0) $display("*** FAILURES DETECTED ***");
        else          $display("*** ALL GOOD ***");
        $display("==========================================");
        $finish;
    end
endmodule

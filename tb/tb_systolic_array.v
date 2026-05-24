// Testbench: systolic_array_32x32 — SystemVerilog (xvlog -sv)
// Avoids LHS variable part-selects; uses shift+concat for packed vector assignment
`timescale 1ns / 1ps

module tb_systolic_array;
    localparam ROWS = 32;
    localparam COLS = 32;
    localparam IFM_W  = 8;
    localparam WGT_W  = 8;
    localparam PSUM_W = 32;

    reg clk, rst;
    reg w_load;
    reg [4:0] w_col;
    reg [ROWS*WGT_W*2-1:0] w_row_data;
    reg [ROWS*IFM_W-1:0]   ifm_in_raw;
    wire [ROWS*IFM_W-1:0]   ifm_in_skewed;
    reg [COLS*2*PSUM_W-1:0] psum_top;
    reg [ROWS-1:0] valid_h_left_raw;
    wire [ROWS-1:0] valid_h_left;
    wire [COLS*2-1:0] valid_v_top;
    wire [COLS*2-1:0] valid_v_bot;
    wire [COLS*2*PSUM_W-1:0] psum_bot;

    integer pass, fail, cycle;
    integer rr, cc, ii;
    reg [511:0] w_tmp;    // temp for building w_row_data
    reg [255:0] ifm_tmp;  // temp for building ifm_in_raw
    reg [7:0]   w0_byte, w1_byte;

    // ---- IFM vertical skew chain (5 cycles/row) ----
    genvar r;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : skew_gen
            if (r == 0) begin : r0
                assign ifm_in_skewed[IFM_W-1:0] = ifm_in_raw[IFM_W-1:0];
            end else begin : rN
                com_shift_reg #(.DEPTH(r*5), .WIDTH(IFM_W)) u_skew (
                    .clk(clk),
                    .si (ifm_in_raw[r*IFM_W +: IFM_W]),
                    .so (ifm_in_skewed[r*IFM_W +: IFM_W])
                );
                com_shift_reg #(.DEPTH(r*5), .WIDTH(1)) u_vskew (
                    .clk(clk),
                    .si (valid_h_left_raw[r]),
                    .so (valid_h_left[r])
                );
            end
        end
    endgenerate
    assign valid_h_left[0] = valid_h_left_raw[0];
    assign valid_v_top = {COLS*2{1'b1}};

    // ---- DUT ----
    systolic_array_32x32 #(.ROWS(ROWS), .COLS(COLS), .PSUM_W(PSUM_W))
    u_array (
        .clk(clk), .rst(rst),
        .w_load(w_load), .w_col(w_col),
        .w_row_data(w_row_data),
        .ifm_in_flat(ifm_in_skewed),
        .valid_h_left(valid_h_left),
        .psum_top_flat(psum_top),
        .valid_v_top(valid_v_top),
        .psum_bot_flat(psum_bot),
        .valid_v_bot(valid_v_bot)
    );

    always #5 clk = ~clk;

    // ---- Helpers ----
    function [PSUM_W-1:0] psuma;
        input [4:0] col;
        begin psuma = psum_bot[col*2*PSUM_W +: PSUM_W]; end
    endfunction
    function [PSUM_W-1:0] psumb;
        input [4:0] col;
        begin psumb = psum_bot[(col*2+1)*PSUM_W +: PSUM_W]; end
    endfunction

    task check_col;
        input [4:0] col;
        input signed [PSUM_W-1:0] exp_a, exp_b;
        begin
            if (psuma(col) !== exp_a) begin
                $display("[%0d] FAIL col%0d psuma=%0d expected=%0d", cycle, col, psuma(col), exp_a);
                fail = fail + 1;
            end else pass = pass + 1;
            if (psumb(col) !== exp_b) begin
                $display("[%0d] FAIL col%0d psumb=%0d expected=%0d", cycle, col, psumb(col), exp_b);
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    task set_ifm;
        input signed [IFM_W-1:0] val;
        begin
            ifm_in_raw = {ROWS{val}};  // replicate 32 times
            valid_h_left_raw = {ROWS{1'b1}};
        end
    endtask

    task set_ifm_ch;
        input [4:0] ch;
        input signed [IFM_W-1:0] val;
        begin
            case (ch)
                5'd0:  ifm_in_raw[7:0]    = val;
                5'd1:  ifm_in_raw[15:8]   = val;
                5'd2:  ifm_in_raw[23:16]  = val;
                5'd3:  ifm_in_raw[31:24]  = val;
                5'd31: ifm_in_raw[255:248] = val;
                default: $display("set_ifm_ch: ch=%0d not supported", ch);
            endcase
        end
    endtask

    // ---- Main test ----
    initial begin
        clk = 0; rst = 1; pass = 0; fail = 0;
        w_load = 0; w_col = 0; w_row_data = 0;
        ifm_in_raw = 0; psum_top = 0;

        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 1: PE(r,c).w0=c+1, PE(r,c).w1=r+1
        // All ifm=1 → psuma=32*(c+1), psumb=528
        // ============================================================
        $display("=== TEST 1: All ifm=1, pattern weights ===");
        w_load = 1;
        for (cc = 0; cc < COLS; cc = cc + 1) begin
            w_col = cc[4:0];
            w_tmp = 0;
            for (rr = 0; rr < ROWS; rr = rr + 1) begin
                w0_byte = cc + 1; w1_byte = rr + 1;
                w_tmp = w_tmp | ({w1_byte, w0_byte} << (rr * 16));
            end
            w_row_data = w_tmp;
            @(negedge clk);
        end
        w_load = 0;

        set_ifm(1);
        repeat (500) @(negedge clk);

        for (cc = 0; cc < COLS; cc = cc + 1)
            check_col(cc[4:0], 32*(cc+1), 528);

        // ============================================================
        // TEST 2: Row 0 only, ifm[0]=5
        // psuma[c]=5*(c+1), psumb[c]=5
        // ============================================================
        $display("=== TEST 2: Row 0 only, ifm[0]=5 ===");
        set_ifm(0);
        valid_h_left_raw = 0;
        set_ifm_ch(0, 5);
        valid_h_left_raw[0] = 1'b1;
        repeat (500) @(negedge clk);

        for (cc = 0; cc < COLS; cc = cc + 1)
            check_col(cc[4:0], 5*(cc+1), 5);

        // ============================================================
        // TEST 3: Rows 0+1 active, ifm[0]=2, ifm[1]=3
        // psuma=5*(c+1), psumb=2*1+3*2=8
        // ============================================================
        $display("=== TEST 3: Rows 0+1, ifm[0]=2, ifm[1]=3 ===");
        set_ifm(0);
        valid_h_left_raw = 0;
        set_ifm_ch(0, 2);
        set_ifm_ch(1, 3);
        valid_h_left_raw[0] = 1'b1;
        valid_h_left_raw[1] = 1'b1;
        repeat (500) @(negedge clk);

        for (cc = 0; cc < COLS; cc = cc + 1)
            check_col(cc[4:0], 5*(cc+1), 8);

        // ============================================================
        // TEST 4: Negative values, ifm[0]=-1
        // ============================================================
        $display("=== TEST 4: Negative ifm[0]=-1 ===");
        set_ifm(0);
        valid_h_left_raw = 0;
        set_ifm_ch(0, -1);
        valid_h_left_raw[0] = 1'b1;
        repeat (500) @(negedge clk);

        for (cc = 0; cc < COLS; cc = cc + 1)
            check_col(cc[4:0], -1*(cc+1), -1);

        // ============================================================
        // TEST 5: Reload uniform weights w0=1, w1=2
        // ifm[0]=10 → psuma=10, psumb=20
        // ============================================================
        $display("=== TEST 5: Uniform weights w0=1, w1=2 ===");
        w_load = 1;
        for (cc = 0; cc < COLS; cc = cc + 1) begin
            w_col = cc[4:0];
            w_tmp = 0;
            for (rr = 0; rr < ROWS; rr = rr + 1) begin
                w_tmp = w_tmp | ({ 8'd2, 8'd1 } << (rr * 16));
            end
            w_row_data = w_tmp;
            @(negedge clk);
        end
        w_load = 0;

        set_ifm(0);
        valid_h_left_raw = 0;
        set_ifm_ch(0, 10);
        valid_h_left_raw[0] = 1'b1;
        repeat (500) @(negedge clk);

        for (cc = 0; cc < COLS; cc = cc + 1)
            check_col(cc[4:0], 10, 20);

        // ---- Report ----
        $display("==========================================");
        $display("  Array TB: %0d checks, %0d pass, %0d fail", pass+fail, pass, fail);
        if (fail > 0) $display("*** FAILURES DETECTED ***");
        else          $display("*** ALL GOOD ***");
        $display("==========================================");
        $finish;
    end
endmodule

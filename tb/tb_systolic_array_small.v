`timescale 1ns / 1ps

module tb_systolic_array_small;
    localparam ROWS = 4;
    localparam COLS = 4;
    localparam IFM_W = 8;
    localparam WGT_W = 8;
    localparam PSUM_W = 32;

    reg clk, rst;
    reg w_load;
    reg [4:0] w_col;
    reg [ROWS*WGT_W*2-1:0] w_row_data;
    reg [ROWS*IFM_W-1:0] ifm_raw;
    wire [ROWS*IFM_W-1:0] ifm_skewed;
    reg [ROWS-1:0] valid_raw;
    wire [ROWS-1:0] valid_skewed;
    reg [COLS*2*PSUM_W-1:0] psum_top;
    wire [COLS*2*PSUM_W-1:0] psum_bot;
    wire [COLS*2-1:0] valid_v_bot;

    wire [COLS*2-1:0] valid_v_top = {COLS*2{1'b1}};

    genvar gr;
    generate
        for (gr = 0; gr < ROWS; gr = gr + 1) begin : skew
            if (gr == 0) begin : no_skew
                assign ifm_skewed[IFM_W-1:0] = ifm_raw[IFM_W-1:0];
                assign valid_skewed[0] = valid_raw[0];
            end else begin : yes_skew
                com_shift_reg #(.DEPTH(gr*5), .WIDTH(IFM_W)) u_ifm (
                    .clk(clk), .rst(rst), .si(ifm_raw[gr*IFM_W +: IFM_W]),
                    .so(ifm_skewed[gr*IFM_W +: IFM_W])
                );
                com_shift_reg #(.DEPTH(gr*5), .WIDTH(1)) u_valid (
                    .clk(clk), .rst(rst), .si(valid_raw[gr]), .so(valid_skewed[gr])
                );
            end
        end
    endgenerate

    systolic_array_32x32 #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WGT_W), .PSUM_W(PSUM_W)
    ) dut (
        .clk(clk), .rst(rst),
        .w_load(w_load), .w_col(w_col), .w_row_data(w_row_data),
        .ifm_in_flat(ifm_skewed), .valid_h_left(valid_skewed),
        .psum_top_flat(psum_top), .valid_v_top(valid_v_top),
        .psum_bot_flat(psum_bot), .valid_v_bot(valid_v_bot)
    );

    always #5 clk = ~clk;

    integer pass, fail, r, c;
    reg signed [7:0] ifm_vec [0:ROWS-1];
    reg signed [7:0] w0 [0:ROWS-1][0:COLS-1];
    reg signed [7:0] w1 [0:ROWS-1][0:COLS-1];
    reg signed [PSUM_W-1:0] bias0 [0:COLS-1];
    reg signed [PSUM_W-1:0] bias1 [0:COLS-1];
    reg signed [PSUM_W-1:0] exp0, exp1;

    task load_weights;
        reg [ROWS*WGT_W*2-1:0] tmp;
        begin
            w_load = 1'b1;
            for (c = 0; c < COLS; c = c + 1) begin
                tmp = 0;
                for (r = 0; r < ROWS; r = r + 1) begin
                    tmp[r*16 +: 8] = w0[r][c];
                    tmp[r*16+8 +: 8] = w1[r][c];
                end
                w_col = c[4:0];
                w_row_data = tmp;
                @(negedge clk);
            end
            w_load = 1'b0;
            w_col = 0;
        end
    endtask

    task drive_vector;
        begin
            for (r = 0; r < ROWS; r = r + 1)
                ifm_raw[r*IFM_W +: IFM_W] = ifm_vec[r];
            valid_raw = {ROWS{1'b1}};
        end
    endtask

    task check_outputs;
        begin
            for (c = 0; c < COLS; c = c + 1) begin
                exp0 = bias0[c];
                exp1 = bias1[c];
                for (r = 0; r < ROWS; r = r + 1) begin
                    exp0 = exp0 + ifm_vec[r] * w0[r][c];
                    exp1 = exp1 + ifm_vec[r] * w1[r][c];
                end
                if (psum_bot[(2*c)*PSUM_W +: PSUM_W] !== exp0) begin
                    $display("[FAIL] col%0d a got=%0d exp=%0d", c, psum_bot[(2*c)*PSUM_W +: PSUM_W], exp0);
                    fail = fail + 1;
                end else pass = pass + 1;
                if (psum_bot[(2*c+1)*PSUM_W +: PSUM_W] !== exp1) begin
                    $display("[FAIL] col%0d b got=%0d exp=%0d", c, psum_bot[(2*c+1)*PSUM_W +: PSUM_W], exp1);
                    fail = fail + 1;
                end else pass = pass + 1;
            end
        end
    endtask

    initial begin
        clk = 0; rst = 1; pass = 0; fail = 0;
        w_load = 0; w_col = 0; w_row_data = 0; ifm_raw = 0; valid_raw = 0; psum_top = 0;
        repeat (3) @(negedge clk); rst = 0; repeat (2) @(negedge clk);

        for (r = 0; r < ROWS; r = r + 1) begin
            ifm_vec[r] = r - 1;
            for (c = 0; c < COLS; c = c + 1) begin
                w0[r][c] = c + 1;
                w1[r][c] = r + 2;
            end
        end
        for (c = 0; c < COLS; c = c + 1) begin
            bias0[c] = 100 + c;
            bias1[c] = -50 - c;
            psum_top[(2*c)*PSUM_W +: PSUM_W] = bias0[c];
            psum_top[(2*c+1)*PSUM_W +: PSUM_W] = bias1[c];
        end

        load_weights();
        drive_vector();
        repeat (120) @(negedge clk);
        check_outputs();

        valid_raw = 0;
        repeat (10) @(negedge clk);
        $display("=== tb_systolic_array_small: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

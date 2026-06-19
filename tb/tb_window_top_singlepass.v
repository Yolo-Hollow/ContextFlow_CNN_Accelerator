`timescale 1ns / 1ps

module tb_window_top_singlepass;
    localparam ROWS = 32;
    localparam COLS = 4;
    localparam IFM_W = 8;
    localparam WGT_W = 8;
    localparam PSUM_W = 32;
    localparam IFM_D = 16;
    localparam IFM_AW = 4;
    localparam WGT_D = 64;
    localparam WGT_AW = 6;
    localparam PSUM_D = 16;
    localparam PSUM_AW = 4;
    localparam FM_W = 5;
    localparam FM_H = 5;
    localparam [31:0] COL_MASK = (32'h1 << COLS) - 1;
    localparam [31:0] ROW_MASK = (32'h1 << ROWS) - 1;

    reg clk, rst, start;
    reg [15:0] num_pixels;
    wire done;

    reg [31:0] ifm_fifo_wr_en;
    reg [ROWS*IFM_W-1:0] ifm_fifo_wr_data;
    wire [31:0] ifm_fifo_full_legacy;
    reg [4:0] dma_bank_wr_en;
    reg [8:0] dma_wr_x, fm_h, fm_w, oy, ox;
    reg [9:0] dma_wr_fy;
    reg [7:0] dma_wr_data [0:4];
    reg dma_line_advance;
    reg [1:0] conv_stride, conv_pad;
    reg [10:0] pass_base_k;
    wire [31:0] ifm_fifo_full;

    reg [5:0] bias_wr_addr;
    reg [PSUM_W-1:0] bias_wr_data;
    reg bias_wr_en, is_first_pass, use_ext_psum;
    reg [COLS*2*PSUM_W-1:0] psum_top_ext;
    reg [31:0] wgt_fifo_wr_en;
    reg [ROWS*WGT_W*2-1:0] wgt_fifo_wr_data;
    wire [31:0] wgt_fifo_full;
    reg [31:0] psum_fifo_rd_en;
    wire [COLS*PSUM_W*2-1:0] psum_fifo_rd_data;
    wire [31:0] psum_fifo_empty;

    systolic_top #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WGT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_D), .IFM_FIFO_AW(IFM_AW),
        .WGT_FIFO_DEPTH(WGT_D), .WGT_FIFO_AW(WGT_AW),
        .PSUM_FIFO_DEPTH(PSUM_D), .PSUM_FIFO_AW(PSUM_AW),
        .USE_DMA_IFM(1)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .tail_cycles_config(16'd0),
        .hold_compute_count_on_stall(1'b0),
        .num_pixels(num_pixels), .done(done),
        .ifm_fifo_wr_en(ifm_fifo_wr_en), .ifm_fifo_wr_data(ifm_fifo_wr_data),
        .ifm_fifo_full_legacy(ifm_fifo_full_legacy),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .fm_h(fm_h), .fm_w(fm_w), .conv_stride(conv_stride), .conv_pad(conv_pad),
        .pass_base_k(pass_base_k), .oy(oy), .ox(ox), .ifm_fifo_full(ifm_fifo_full),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .is_first_pass(is_first_pass), .psum_top_ext(psum_top_ext), .use_ext_psum(use_ext_psum),
        .psum_stream_data({COLS*2*PSUM_W{1'b0}}), .psum_stream_valid(1'b0), .psum_stream_compute_ready(1'b1), .use_psum_stream(1'b0),
        .wgt_fifo_wr_en(wgt_fifo_wr_en), .wgt_fifo_wr_data(wgt_fifo_wr_data),
        .wgt_fifo_full(wgt_fifo_full),
        .psum_fifo_rd_en(psum_fifo_rd_en), .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_empty(psum_fifo_empty)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer b, y, x, r, c, lane, ch, ker, ky, kx;
    reg signed [7:0] feat [0:4][0:FM_H-1][0:FM_W-1];
    reg signed [7:0] lane_ifm [0:ROWS-1];
    reg signed [7:0] w0 [0:ROWS-1][0:COLS-1];
    reg signed [7:0] w1 [0:ROWS-1][0:COLS-1];
    reg signed [PSUM_W-1:0] bias0 [0:COLS-1];
    reg signed [PSUM_W-1:0] bias1 [0:COLS-1];
    reg signed [PSUM_W-1:0] exp0 [0:COLS-1];
    reg signed [PSUM_W-1:0] exp1 [0:COLS-1];
    reg signed [PSUM_W-1:0] got0, got1;
    reg [ROWS*WGT_W*2-1:0] wtmp;
    reg [COLS*PSUM_W*2-1:0] got_packed;

    task load_linebuf_rows_0_to_2;
        begin
            dma_bank_wr_en = 5'b11111;
            for (y = 0; y < 3; y = y + 1) begin
                dma_wr_fy = y[9:0];
                for (x = 0; x < FM_W; x = x + 1) begin
                    dma_wr_x = x[8:0];
                    for (b = 0; b < 5; b = b + 1)
                        dma_wr_data[b] = feat[b][y][x];
                    @(negedge clk);
                end
                dma_line_advance = 1'b1;
                @(negedge clk);
                dma_line_advance = 1'b0;
            end
            dma_bank_wr_en = 0;
        end
    endtask

    task load_bias;
        integer ch_i;
        begin
            bias_wr_en = 1'b1;
            for (ch_i = 0; ch_i < COLS*2; ch_i = ch_i + 1) begin
                bias_wr_addr = ch_i[5:0];
                if (ch_i[0] == 1'b0) bias_wr_data = bias0[ch_i >> 1];
                else bias_wr_data = bias1[ch_i >> 1];
                @(negedge clk);
            end
            bias_wr_en = 1'b0;
        end
    endtask

    task load_weights;
        begin
            for (c = 0; c < COLS; c = c + 1) begin
                wtmp = 0;
                for (r = 0; r < ROWS; r = r + 1) begin
                    wtmp[r*16 +: 8] = w0[r][c];
                    wtmp[r*16+8 +: 8] = w1[r][c];
                end
                wgt_fifo_wr_data = wtmp;
                wgt_fifo_wr_en = ROW_MASK;
                @(negedge clk);
            end
            wgt_fifo_wr_en = 0;
        end
    endtask

    task launch_and_wait;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            wait (done === 1'b1);
            @(negedge clk);
        end
    endtask

    task read_non_bias_result;
        output [COLS*PSUM_W*2-1:0] pkt;
        integer n;
        begin
            pkt = 0;
            for (n = 0; n < 8; n = n + 1) begin
                psum_fifo_rd_en = COL_MASK;
                @(negedge clk);
                psum_fifo_rd_en = 0;
                @(negedge clk);
                if (psum_fifo_rd_data[PSUM_W-1:0] !== bias0[0])
                    pkt = psum_fifo_rd_data;
            end
        end
    endtask

    initial begin
        clk = 0; rst = 1; start = 0; num_pixels = 16'd3;
        pass = 0; fail = 0;
        ifm_fifo_wr_en = 0; ifm_fifo_wr_data = 0;
        dma_bank_wr_en = 0; dma_wr_x = 0; dma_wr_fy = 0; dma_line_advance = 0;
        fm_h = FM_H; fm_w = FM_W; oy = 0; ox = 0;
        conv_stride = 1; conv_pad = 0; pass_base_k = 0;
        bias_wr_addr = 0; bias_wr_data = 0; bias_wr_en = 0;
        is_first_pass = 1'b1; use_ext_psum = 1'b0; psum_top_ext = 0;
        wgt_fifo_wr_en = 0; wgt_fifo_wr_data = 0; psum_fifo_rd_en = 0;
        for (b = 0; b < 5; b = b + 1) dma_wr_data[b] = 0;

        for (b = 0; b < 5; b = b + 1)
            for (y = 0; y < FM_H; y = y + 1)
                for (x = 0; x < FM_W; x = x + 1)
                    feat[b][y][x] = b*20 + y*5 + x - 30;

        for (r = 0; r < ROWS; r = r + 1) begin
            ch = (r / 9) % 5;
            ker = r % 9;
            ky = ker / 3;
            kx = ker % 3;
            lane_ifm[r] = feat[ch][ky][kx];
            for (c = 0; c < COLS; c = c + 1) begin
                w0[r][c] = (r + c) % 9 - 4;
                w1[r][c] = (r*2 + c) % 11 - 5;
            end
        end

        for (c = 0; c < COLS; c = c + 1) begin
            bias0[c] = 17 + c;
            bias1[c] = -23 - c;
            exp0[c] = bias0[c];
            exp1[c] = bias1[c];
            for (lane = 0; lane < ROWS; lane = lane + 1) begin
                exp0[c] = exp0[c] + lane_ifm[lane] * w0[lane][c];
                exp1[c] = exp1[c] + lane_ifm[lane] * w1[lane][c];
            end
        end

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        load_linebuf_rows_0_to_2();
        load_bias();
        load_weights();
        launch_and_wait();
        read_non_bias_result(got_packed);

        for (c = 0; c < COLS; c = c + 1) begin
            got0 = got_packed[(2*c)*PSUM_W +: PSUM_W];
            got1 = got_packed[(2*c+1)*PSUM_W +: PSUM_W];
            if (got0 !== exp0[c]) begin
                $display("[FAIL] col%0d a got=%0d exp=%0d", c, got0, exp0[c]);
                fail = fail + 1;
            end else pass = pass + 1;
            if (got1 !== exp1[c]) begin
                $display("[FAIL] col%0d b got=%0d exp=%0d", c, got1, exp1[c]);
                fail = fail + 1;
            end else pass = pass + 1;
        end

        $display("=== tb_window_top_singlepass: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

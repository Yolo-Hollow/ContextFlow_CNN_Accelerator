`timescale 1ns / 1ps

module tb_systolic_top_feeder_singlepass;
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
    localparam OFM_W = 3;
    localparam OFM_H = 3;
    localparam [31:0] COL_MASK = (32'h1 << COLS) - 1;
    localparam [31:0] ROW_MASK = (32'h1 << ROWS) - 1;

    reg clk, rst, feeder_start, compute_start;
    wire feeder_done, feeder_busy, compute_done;
    wire feeder_fill_req;
    wire [8:0] feeder_fill_fy;
    reg [4:0] dma_bank_wr_en;
    reg [8:0] dma_wr_x;
    reg [9:0] dma_wr_fy;
    reg [7:0] dma_wr_data [0:4];
    reg [5:0] bias_wr_addr;
    reg [PSUM_W-1:0] bias_wr_data;
    reg bias_wr_en;
    reg [31:0] wgt_fifo_wr_en;
    reg [ROWS*WGT_W*2-1:0] wgt_fifo_wr_data;
    wire [31:0] wgt_fifo_full;
    reg [31:0] psum_fifo_rd_en;
    wire [COLS*PSUM_W*2-1:0] psum_fifo_rd_data;
    wire [31:0] psum_fifo_empty;
    wire [31:0] ifm_fifo_full;
    reg dma_line_advance;

    systolic_top_feeder #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WGT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_D), .IFM_FIFO_AW(IFM_AW),
        .WGT_FIFO_DEPTH(WGT_D), .WGT_FIFO_AW(WGT_AW),
        .PSUM_FIFO_DEPTH(PSUM_D), .PSUM_FIFO_AW(PSUM_AW),
        .FM_W_MAX(FM_W), .FM_H_MAX(FM_H)
    ) dut (
        .clk(clk), .rst(rst),
        .feeder_start(feeder_start), .feeder_done(feeder_done), .feeder_busy(feeder_busy),
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .kernel_1x1(1'b0), .raw_hwc_mode(1'b0),
        .compute_start(compute_start), .tail_cycles_config(16'd0),
        .raw_hwc_compute_start_level(16'd0), .feeder_compute_ready(),
        .num_pixels(16'd9), .compute_done(compute_done),
        .fm_h(9'd5), .fm_w(9'd5), .ofm_h(9'd3), .ofm_w(9'd3),
        .tile_oy_base(9'd0), .tile_ofm_h(9'd0),
        .conv_stride(2'd1), .conv_pad(2'd0), .pass_base_k(11'd0),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .is_first_pass(1'b1), .psum_top_ext({COLS*2*PSUM_W{1'b0}}), .use_ext_psum(1'b0),
        .psum_stream_data({COLS*2*PSUM_W{1'b0}}), .psum_stream_valid(1'b0), .psum_stream_compute_ready(1'b1), .use_psum_stream(1'b0),
        .wgt_fifo_wr_en(wgt_fifo_wr_en), .wgt_fifo_wr_data(wgt_fifo_wr_data),
        .wgt_fifo_full(wgt_fifo_full),
        .psum_fifo_rd_en(psum_fifo_rd_en), .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_empty(psum_fifo_empty), .ifm_fifo_full(ifm_fifo_full)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer b, y, x, r, c, lane, ch, ker, ky, kx, ch_i, n;
    reg signed [7:0] feat [0:4][0:FM_H-1][0:FM_W-1];
    reg signed [7:0] w0 [0:ROWS-1][0:COLS-1];
    reg signed [7:0] w1 [0:ROWS-1][0:COLS-1];
    reg signed [PSUM_W-1:0] bias0 [0:COLS-1];
    reg signed [PSUM_W-1:0] bias1 [0:COLS-1];
    reg signed [PSUM_W-1:0] exp0 [0:OFM_H-1][0:OFM_W-1][0:COLS-1];
    reg signed [PSUM_W-1:0] exp1 [0:OFM_H-1][0:OFM_W-1][0:COLS-1];
    reg signed [PSUM_W-1:0] got0, got1;
    reg [ROWS*WGT_W*2-1:0] wtmp;
    reg [COLS*PSUM_W*2-1:0] got_packed [0:OFM_H*OFM_W-1];
    integer out_count;

    task write_row;
        input integer row_y;
        begin
            @(negedge clk);
            dma_bank_wr_en = 5'b11111;
            dma_wr_fy = row_y[9:0];
            for (x = 0; x < FM_W; x = x + 1) begin
                dma_wr_x = x[8:0];
                for (b = 0; b < 5; b = b + 1)
                    dma_wr_data[b] = feat[b][row_y][x];
                @(negedge clk);
            end
            dma_line_advance = 1'b1;
            @(negedge clk);
            dma_line_advance = 1'b0;
            dma_bank_wr_en = 5'b00000;
            @(negedge clk);
        end
    endtask

    task load_bias;
        begin
            bias_wr_en = 1'b1;
            for (ch_i = 0; ch_i < COLS*2; ch_i = ch_i + 1) begin
                bias_wr_addr = ch_i[5:0];
                bias_wr_data = ch_i[0] ? bias1[ch_i >> 1] : bias0[ch_i >> 1];
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

    task read_non_bias_results;
        begin
            out_count = 0;
            for (n = 0; n < 128 && out_count < OFM_H*OFM_W; n = n + 1) begin
                wait ((psum_fifo_empty & COL_MASK) == 0);
                psum_fifo_rd_en = COL_MASK;
                @(negedge clk);
                psum_fifo_rd_en = 0;
                @(negedge clk);
                if (psum_fifo_rd_data[PSUM_W-1:0] !== bias0[0] && out_count < OFM_H*OFM_W) begin
                    got_packed[out_count] = psum_fifo_rd_data;
                    out_count = out_count + 1;
                end
            end
        end
    endtask

    initial begin
        @(negedge rst);
        forever begin
            wait(feeder_fill_req);
            write_row(feeder_fill_fy);
            @(posedge clk);
            #1;
        end
    end

    initial begin
        clk = 0;
        rst = 1;
        feeder_start = 0;
        compute_start = 0;
        dma_bank_wr_en = 0;
        dma_wr_x = 0;
        dma_wr_fy = 0;
        dma_line_advance = 0;
        bias_wr_addr = 0;
        bias_wr_data = 0;
        bias_wr_en = 0;
        wgt_fifo_wr_en = 0;
        wgt_fifo_wr_data = 0;
        psum_fifo_rd_en = 0;
        pass = 0;
        fail = 0;
        for (b = 0; b < 5; b = b + 1) dma_wr_data[b] = 0;

        for (b = 0; b < 5; b = b + 1)
            for (y = 0; y < FM_H; y = y + 1)
                for (x = 0; x < FM_W; x = x + 1)
                    feat[b][y][x] = b*20 + y*5 + x - 30;

        for (r = 0; r < ROWS; r = r + 1) begin
            for (c = 0; c < COLS; c = c + 1) begin
                w0[r][c] = (r + c) % 9 - 4;
                w1[r][c] = (r*2 + c) % 11 - 5;
            end
        end

        for (c = 0; c < COLS; c = c + 1) begin
            bias0[c] = 17 + c;
            bias1[c] = -23 - c;
            for (y = 0; y < OFM_H; y = y + 1) begin
                for (x = 0; x < OFM_W; x = x + 1) begin
                    exp0[y][x][c] = bias0[c];
                    exp1[y][x][c] = bias1[c];
                    for (lane = 0; lane < ROWS; lane = lane + 1) begin
                        ch = (lane / 9) % 5;
                        ker = lane % 9;
                        ky = ker / 3;
                        kx = ker % 3;
                        exp0[y][x][c] = exp0[y][x][c] + feat[ch][y + ky][x + kx] * w0[lane][c];
                        exp1[y][x][c] = exp1[y][x][c] + feat[ch][y + ky][x + kx] * w1[lane][c];
                    end
                end
            end
        end

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        load_bias();
        load_weights();

        feeder_start = 1'b1;
        @(negedge clk);
        feeder_start = 1'b0;
        wait(feeder_done);
        @(negedge clk);

        compute_start = 1'b1;
        @(negedge clk);
        compute_start = 1'b0;
        wait(compute_done);
        @(negedge clk);
        read_non_bias_results();

        if (out_count != OFM_H*OFM_W) begin
            $display("[FAIL] output count got=%0d exp=%0d", out_count, OFM_H*OFM_W);
            fail = fail + 1;
        end else pass = pass + 1;

        for (y = 0; y < OFM_H; y = y + 1) begin
            for (x = 0; x < OFM_W; x = x + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    got0 = got_packed[y*OFM_W+x][(2*c)*PSUM_W +: PSUM_W];
                    got1 = got_packed[y*OFM_W+x][(2*c+1)*PSUM_W +: PSUM_W];
                    if (got0 !== exp0[y][x][c]) begin
                        $display("[FAIL] pixel(%0d,%0d) col%0d a got=%0d exp=%0d",
                            y, x, c, got0, exp0[y][x][c]);
                        fail = fail + 1;
                    end else pass = pass + 1;
                    if (got1 !== exp1[y][x][c]) begin
                        $display("[FAIL] pixel(%0d,%0d) col%0d b got=%0d exp=%0d",
                            y, x, c, got1, exp1[y][x][c]);
                        fail = fail + 1;
                    end else pass = pass + 1;
                end
            end
        end

        $display("=== tb_systolic_top_feeder_singlepass: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (1200) @(negedge clk);
        $display("[FAIL] timeout feeder_done=%0d compute_done=%0d out_count=%0d empty=%h",
            feeder_done, compute_done, out_count, psum_fifo_empty);
        $fatal(1);
    end
endmodule

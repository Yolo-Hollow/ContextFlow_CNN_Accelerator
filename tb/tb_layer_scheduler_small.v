`timescale 1ns / 1ps

module tb_layer_scheduler_small;
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
    localparam CIN = 5;
    localparam K_TOTAL = CIN * 3 * 3;
    localparam COUT = COLS * 2;
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
    integer b, y, x, py, px, r, c, co, k, ch, ky, kx, lane, ch_i, n;
    reg signed [7:0] feat [0:CIN-1][0:FM_H-1][0:FM_W-1];
    reg signed [7:0] weight [0:K_TOTAL-1][0:COUT-1];
    reg signed [PSUM_W-1:0] bias [0:COUT-1];
    reg signed [PSUM_W-1:0] golden [0:OFM_H-1][0:OFM_W-1][0:COUT-1];
    reg [COLS*PSUM_W*2-1:0] partial [0:OFM_H-1][0:OFM_W-1];
    reg [COLS*PSUM_W*2-1:0] final_packed;
    reg [ROWS*WGT_W*2-1:0] wtmp;
    reg signed [PSUM_W-1:0] got0, got1;

    task clear_inputs;
        begin
            start = 0;
            ifm_fifo_wr_en = 0;
            ifm_fifo_wr_data = 0;
            dma_bank_wr_en = 0;
            dma_wr_x = 0;
            dma_wr_fy = 0;
            dma_line_advance = 0;
            bias_wr_en = 0;
            bias_wr_addr = 0;
            bias_wr_data = 0;
            wgt_fifo_wr_en = 0;
            wgt_fifo_wr_data = 0;
            psum_fifo_rd_en = 0;
            for (b = 0; b < 5; b = b + 1) dma_wr_data[b] = 0;
        end
    endtask

    task reset_dut;
        begin
            rst = 1;
            clear_inputs();
            repeat (3) @(negedge clk);
            rst = 0;
            repeat (2) @(negedge clk);
        end
    endtask

    task load_linebuf_rows;
        input integer base_y;
        integer ly, lx;
        begin
            dma_bank_wr_en = 5'b11111;
            for (ly = base_y; ly < base_y + 3; ly = ly + 1) begin
                dma_wr_fy = ly[9:0];
                for (lx = 0; lx < FM_W; lx = lx + 1) begin
                    dma_wr_x = lx[8:0];
                    for (b = 0; b < 5; b = b + 1)
                        dma_wr_data[b] = feat[b][ly][lx];
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
        begin
            bias_wr_en = 1'b1;
            for (ch_i = 0; ch_i < COUT; ch_i = ch_i + 1) begin
                bias_wr_addr = ch_i[5:0];
                bias_wr_data = bias[ch_i];
                @(negedge clk);
            end
            bias_wr_en = 1'b0;
        end
    endtask

    task load_weights_tile;
        input integer k_base;
        integer gk;
        begin
            for (c = 0; c < COLS; c = c + 1) begin
                wtmp = 0;
                for (r = 0; r < ROWS; r = r + 1) begin
                    gk = k_base + r;
                    if (gk < K_TOTAL) begin
                        wtmp[r*16 +: 8] = weight[gk][2*c];
                        wtmp[r*16+8 +: 8] = weight[gk][2*c+1];
                    end else begin
                        wtmp[r*16 +: 8] = 8'd0;
                        wtmp[r*16+8 +: 8] = 8'd0;
                    end
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

    task read_result;
        input [PSUM_W-1:0] baseline_col0;
        output [COLS*PSUM_W*2-1:0] pkt;
        begin
            pkt = 0;
            for (n = 0; n < 8; n = n + 1) begin
                psum_fifo_rd_en = COL_MASK;
                @(negedge clk);
                psum_fifo_rd_en = 0;
                @(negedge clk);
                if (psum_fifo_rd_data[PSUM_W-1:0] !== baseline_col0)
                    pkt = psum_fifo_rd_data;
            end
        end
    endtask

    task run_tile_for_pixel;
        input integer py;
        input integer px;
        input integer k_base;
        input integer first_pass;
        input [COLS*PSUM_W*2-1:0] ext_psum;
        output [COLS*PSUM_W*2-1:0] out_psum;
        reg [PSUM_W-1:0] baseline;
        begin
            reset_dut();
            oy = py[8:0];
            ox = px[8:0];
            pass_base_k = k_base[10:0];
            is_first_pass = first_pass;
            use_ext_psum = !first_pass;
            psum_top_ext = ext_psum;
            load_linebuf_rows(py);
            load_bias();
            load_weights_tile(k_base);
            launch_and_wait();
            baseline = first_pass ? bias[0] : ext_psum[PSUM_W-1:0];
            read_result(baseline, out_psum);
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        pass = 0;
        fail = 0;
        num_pixels = 16'd3;
        fm_h = FM_H;
        fm_w = FM_W;
        conv_stride = 1;
        conv_pad = 0;
        is_first_pass = 1;
        use_ext_psum = 0;
        psum_top_ext = 0;
        clear_inputs();

        for (ch = 0; ch < CIN; ch = ch + 1)
            for (y = 0; y < FM_H; y = y + 1)
                for (x = 0; x < FM_W; x = x + 1)
                    feat[ch][y][x] = ch*13 + y*3 + x - 25;

        for (k = 0; k < K_TOTAL; k = k + 1)
            for (co = 0; co < COUT; co = co + 1)
                weight[k][co] = (k*5 + co*3) % 17 - 8;

        for (co = 0; co < COUT; co = co + 1)
            bias[co] = co*7 - 19;

        for (y = 0; y < OFM_H; y = y + 1) begin
            for (x = 0; x < OFM_W; x = x + 1) begin
                for (co = 0; co < COUT; co = co + 1) begin
                    golden[y][x][co] = bias[co];
                    for (ch = 0; ch < CIN; ch = ch + 1) begin
                        for (ky = 0; ky < 3; ky = ky + 1) begin
                            for (kx = 0; kx < 3; kx = kx + 1) begin
                                k = ch*9 + ky*3 + kx;
                                golden[y][x][co] = golden[y][x][co] + feat[ch][y+ky][x+kx] * weight[k][co];
                            end
                        end
                    end
                end
            end
        end

        for (py = 0; py < OFM_H; py = py + 1) begin
            for (px = 0; px < OFM_W; px = px + 1) begin
                run_tile_for_pixel(py, px, 0, 1, 0, partial[py][px]);
                run_tile_for_pixel(py, px, 32, 0, partial[py][px], final_packed);
                for (c = 0; c < COLS; c = c + 1) begin
                    got0 = final_packed[(2*c)*PSUM_W +: PSUM_W];
                    got1 = final_packed[(2*c+1)*PSUM_W +: PSUM_W];
                    if (got0 !== golden[py][px][2*c]) begin
                        $display("[FAIL] pixel(%0d,%0d) cout%0d got=%0d exp=%0d", py, px, 2*c, got0, golden[py][px][2*c]);
                        fail = fail + 1;
                    end else pass = pass + 1;
                    if (got1 !== golden[py][px][2*c+1]) begin
                        $display("[FAIL] pixel(%0d,%0d) cout%0d got=%0d exp=%0d", py, px, 2*c+1, got1, golden[py][px][2*c+1]);
                        fail = fail + 1;
                    end else pass = pass + 1;
                end
            end
        end

        $display("=== tb_layer_scheduler_small: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

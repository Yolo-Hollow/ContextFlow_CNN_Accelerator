`timescale 1ns / 1ps

module tb_systolic_top_multipass;
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
    localparam [31:0] COL_MASK = (32'h1 << COLS) - 1;
    localparam [31:0] ROW_MASK = (32'h1 << ROWS) - 1;

    reg clk, rst, start;
    reg [15:0] num_pixels;
    wire done;

    reg [31:0] ifm_wr_en;
    reg [ROWS*IFM_W-1:0] ifm_wr_data;
    wire [31:0] ifm_full;
    reg [31:0] wgt_wr_en;
    reg [ROWS*WGT_W*2-1:0] wgt_wr_data;
    wire [31:0] wgt_full;
    reg [31:0] psum_rd_en;
    wire [COLS*PSUM_W*2-1:0] psum_rd_data;
    wire [31:0] psum_empty;

    reg [5:0] bias_addr;
    reg [PSUM_W-1:0] bias_data;
    reg bias_en, is_first, use_ext;
    reg [COLS*2*PSUM_W-1:0] psum_top_ext;

    // Unused DMA/window ports in manual IFM mode.
    reg [4:0] dma_bank_wr_en;
    reg [8:0] dma_wr_x, fm_h, fm_w, oy, ox;
    reg [9:0] dma_wr_fy;
    reg [7:0] dma_wr_data [0:4];
    reg dma_line_advance;
    reg [1:0] conv_stride, conv_pad;
    reg [10:0] pass_base_k;
    wire [31:0] ifm_fifo_full_dma;

    systolic_top #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WGT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_D), .IFM_FIFO_AW(IFM_AW),
        .WGT_FIFO_DEPTH(WGT_D), .WGT_FIFO_AW(WGT_AW),
        .PSUM_FIFO_DEPTH(PSUM_D), .PSUM_FIFO_AW(PSUM_AW),
        .USE_DMA_IFM(0)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .tail_cycles_config(16'd0),
        .hold_compute_count_on_stall(1'b0),
        .num_pixels(num_pixels), .done(done),
        .ifm_fifo_wr_en(ifm_wr_en), .ifm_fifo_wr_data(ifm_wr_data),
        .ifm_fifo_full_legacy(ifm_full),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .fm_h(fm_h), .fm_w(fm_w), .conv_stride(conv_stride), .conv_pad(conv_pad),
        .pass_base_k(pass_base_k), .oy(oy), .ox(ox), .ifm_fifo_full(ifm_fifo_full_dma),
        .bias_wr_addr(bias_addr), .bias_wr_data(bias_data), .bias_wr_en(bias_en),
        .is_first_pass(is_first), .psum_top_ext(psum_top_ext), .use_ext_psum(use_ext),
        .psum_stream_data({COLS*2*PSUM_W{1'b0}}), .psum_stream_valid(1'b0), .psum_stream_compute_ready(1'b1), .use_psum_stream(1'b0),
        .wgt_fifo_wr_en(wgt_wr_en), .wgt_fifo_wr_data(wgt_wr_data), .wgt_fifo_full(wgt_full),
        .psum_fifo_rd_en(psum_rd_en), .psum_fifo_rd_data(psum_rd_data), .psum_fifo_empty(psum_empty)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer i, r, c, lane, ch;
    reg signed [7:0] ifm_tile0 [0:ROWS-1];
    reg signed [7:0] ifm_tile1 [0:ROWS-1];
    reg signed [7:0] w0_tile0 [0:ROWS-1][0:COLS-1];
    reg signed [7:0] w1_tile0 [0:ROWS-1][0:COLS-1];
    reg signed [7:0] w0_tile1 [0:ROWS-1][0:COLS-1];
    reg signed [7:0] w1_tile1 [0:ROWS-1][0:COLS-1];
    reg signed [PSUM_W-1:0] bias0 [0:COLS-1];
    reg signed [PSUM_W-1:0] bias1 [0:COLS-1];
    reg signed [PSUM_W-1:0] partial0 [0:COLS-1];
    reg signed [PSUM_W-1:0] partial1 [0:COLS-1];
    reg signed [PSUM_W-1:0] final0 [0:COLS-1];
    reg signed [PSUM_W-1:0] final1 [0:COLS-1];
    reg signed [PSUM_W-1:0] got0, got1;
    reg [ROWS*WGT_W*2-1:0] wtmp;
    reg [ROWS*IFM_W-1:0] itmp;

    task reset_dut;
        begin
            rst = 1'b1;
            start = 1'b0;
            ifm_wr_en = 0;
            ifm_wr_data = 0;
            wgt_wr_en = 0;
            wgt_wr_data = 0;
            psum_rd_en = 0;
            bias_en = 0;
            repeat (3) @(negedge clk);
            rst = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    task load_bias;
        input integer zero_bias;
        begin
            bias_en = 1'b1;
            for (ch = 0; ch < 64; ch = ch + 1) begin
                bias_addr = ch[5:0];
                if (zero_bias) bias_data = 0;
                else if (ch[0] == 1'b0) bias_data = bias0[ch >> 1];
                else bias_data = bias1[ch >> 1];
                @(negedge clk);
            end
            bias_en = 1'b0;
        end
    endtask

    task load_weights;
        input integer tile_id;
        begin
            for (c = 0; c < COLS; c = c + 1) begin
                wtmp = 0;
                for (r = 0; r < ROWS; r = r + 1) begin
                    if (tile_id == 0) begin
                        wtmp[r*16 +: 8] = w0_tile0[r][c];
                        wtmp[r*16+8 +: 8] = w1_tile0[r][c];
                    end else begin
                        wtmp[r*16 +: 8] = w0_tile1[r][c];
                        wtmp[r*16+8 +: 8] = w1_tile1[r][c];
                    end
                end
                wgt_wr_data = wtmp;
                wgt_wr_en = ROW_MASK;
                @(negedge clk);
            end
            wgt_wr_en = 0;
        end
    endtask

    task load_ifm_pixel;
        input integer tile_id;
        begin
            ifm_wr_data = 0;
            ifm_wr_en = ROW_MASK;
            @(negedge clk);
            itmp = 0;
            for (r = 0; r < ROWS; r = r + 1) begin
                if (tile_id == 0) itmp[r*8 +: 8] = ifm_tile0[r];
                else itmp[r*8 +: 8] = ifm_tile1[r];
            end
            ifm_wr_data = itmp;
            ifm_wr_en = ROW_MASK;
            @(negedge clk);
            ifm_wr_data = 0;
            ifm_wr_en = ROW_MASK;
            @(negedge clk);
            ifm_wr_en = 0;
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

    task read_pixel0_all_cols;
        input [PSUM_W-1:0] baseline_col0;
        output [COLS*PSUM_W*2-1:0] pkt;
        integer n;
        begin
            // Current top has no bounded done/valid-count signal yet. Drain a
            // small fixed window and keep the last FIFO output value.
            pkt = 0;
            for (n = 0; n < 8; n = n + 1) begin
                psum_rd_en = COL_MASK;
                @(negedge clk);
                psum_rd_en = 0;
                @(negedge clk);
                if (psum_rd_data[PSUM_W-1:0] !== baseline_col0)
                    pkt = psum_rd_data;
            end
        end
    endtask

    task pack_ext_from_partial;
        input [COLS*PSUM_W*2-1:0] pkt;
        begin
            psum_top_ext = pkt;
        end
    endtask

    reg [COLS*PSUM_W*2-1:0] pass0_packed;
    reg [COLS*PSUM_W*2-1:0] pass1_packed;

    initial begin
        clk = 0;
        pass = 0;
        fail = 0;
        num_pixels = 16'd3;
        dma_bank_wr_en = 0; dma_wr_x = 0; dma_wr_fy = 0; dma_line_advance = 0;
        for (i = 0; i < 5; i = i + 1) dma_wr_data[i] = 0;
        fm_h = 1; fm_w = 1; oy = 0; ox = 0; conv_stride = 1; conv_pad = 0; pass_base_k = 0;
        is_first = 1; use_ext = 0; psum_top_ext = 0;

        for (r = 0; r < ROWS; r = r + 1) begin
            ifm_tile0[r] = (r % 9) - 4;
            ifm_tile1[r] = (r % 7) - 3;
            for (c = 0; c < COLS; c = c + 1) begin
                w0_tile0[r][c] = (r + c) % 11 - 5;
                w1_tile0[r][c] = (r * 2 + c) % 13 - 6;
                w0_tile1[r][c] = (r * 3 + c) % 7 - 3;
                w1_tile1[r][c] = (r + c * 2) % 9 - 4;
            end
        end

        for (c = 0; c < COLS; c = c + 1) begin
            bias0[c] = 100 + c;
            bias1[c] = -80 - c;
            partial0[c] = bias0[c];
            partial1[c] = bias1[c];
            for (lane = 0; lane < ROWS; lane = lane + 1) begin
                partial0[c] = partial0[c] + ifm_tile0[lane] * w0_tile0[lane][c];
                partial1[c] = partial1[c] + ifm_tile0[lane] * w1_tile0[lane][c];
            end
            final0[c] = partial0[c];
            final1[c] = partial1[c];
            for (lane = 0; lane < ROWS; lane = lane + 1) begin
                final0[c] = final0[c] + ifm_tile1[lane] * w0_tile1[lane][c];
                final1[c] = final1[c] + ifm_tile1[lane] * w1_tile1[lane][c];
            end
        end

        reset_dut();
        is_first = 1'b1;
        use_ext = 1'b0;
        load_bias(0);
        load_weights(0);
        load_ifm_pixel(0);
        launch_and_wait();
        read_pixel0_all_cols(bias0[0], pass0_packed);

        for (c = 0; c < COLS; c = c + 1) begin
            got0 = pass0_packed[(2*c)*PSUM_W +: PSUM_W];
            got1 = pass0_packed[(2*c+1)*PSUM_W +: PSUM_W];
            if (got0 !== partial0[c]) begin
                $display("[FAIL] pass0 col%0d a got=%0d exp=%0d", c, got0, partial0[c]);
                fail = fail + 1;
            end else pass = pass + 1;
            if (got1 !== partial1[c]) begin
                $display("[FAIL] pass0 col%0d b got=%0d exp=%0d", c, got1, partial1[c]);
                fail = fail + 1;
            end else pass = pass + 1;
        end

        reset_dut();
        is_first = 1'b0;
        use_ext = 1'b1;
        pack_ext_from_partial(pass0_packed);
        load_bias(1);
        load_weights(1);
        load_ifm_pixel(1);
        launch_and_wait();
        read_pixel0_all_cols(partial0[0], pass1_packed);

        for (c = 0; c < COLS; c = c + 1) begin
            got0 = pass1_packed[(2*c)*PSUM_W +: PSUM_W];
            got1 = pass1_packed[(2*c+1)*PSUM_W +: PSUM_W];
            if (got0 !== final0[c]) begin
                $display("[FAIL] pass1 col%0d a got=%0d exp=%0d", c, got0, final0[c]);
                fail = fail + 1;
            end else pass = pass + 1;
            if (got1 !== final1[c]) begin
                $display("[FAIL] pass1 col%0d b got=%0d exp=%0d", c, got1, final1[c]);
                fail = fail + 1;
            end else pass = pass + 1;
        end

        $display("=== tb_systolic_top_multipass: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

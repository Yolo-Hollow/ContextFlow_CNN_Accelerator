`timescale 1ns / 1ps

module tb_systolic_top_feeder_cout_blocks;
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
    localparam PIXELS = OFM_W * OFM_H;
    localparam CIN = 3;
    localparam K_TOTAL = CIN * 3 * 3;
    localparam COUT_TILE = COLS * 2;
    localparam COUT_TOTAL = COUT_TILE * 2;
    localparam WGT_TILE_AW = 11;
    localparam [31:0] COL_MASK = (32'h1 << COLS) - 1;

    reg clk, rst, feeder_start, compute_start;
    wire feeder_done, feeder_busy, compute_done, compute_fire;
    wire feeder_fill_req;
    wire [8:0] feeder_fill_fy;
    reg [4:0] dma_bank_wr_en;
    reg [8:0] dma_wr_x;
    reg [9:0] dma_wr_fy;
    reg [7:0] dma_wr_data [0:4];
    reg dma_line_advance;
    reg [10:0] pass_base_k;
    reg [5:0] bias_wr_addr;
    reg [PSUM_W-1:0] bias_wr_data;
    reg bias_wr_en, is_first_pass, use_ext_psum, use_psum_stream;
    reg [COLS*2*PSUM_W-1:0] psum_top_ext;
    wire [31:0] wgt_fifo_wr_en;
    wire [ROWS*WGT_W*2-1:0] wgt_fifo_wr_data;
    wire [31:0] wgt_fifo_full;
    reg wgt_tile_wr_en, wgt_loader_start;
    reg [WGT_TILE_AW-1:0] wgt_tile_wr_addr;
    reg [WGT_W-1:0] wgt_tile_wr_data;
    wire wgt_loader_busy, wgt_loader_done;
    reg [31:0] psum_fifo_rd_en;
    wire [COLS*PSUM_W*2-1:0] psum_fifo_rd_data;
    wire [31:0] psum_fifo_empty;
    wire [31:0] ifm_fifo_full;

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
        .compute_fire_out(compute_fire),
        .fm_h(9'd5), .fm_w(9'd5), .ofm_h(9'd3), .ofm_w(9'd3),
        .tile_oy_base(9'd0), .tile_ofm_h(9'd0),
        .conv_stride(2'd1), .conv_pad(2'd0), .pass_base_k(pass_base_k),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .is_first_pass(is_first_pass), .psum_top_ext(psum_top_ext), .use_ext_psum(use_ext_psum),
        .psum_stream_data({COLS*2*PSUM_W{1'b0}}), .psum_stream_valid(1'b0), .psum_stream_compute_ready(1'b1),
        .use_psum_stream(use_psum_stream),
        .wgt_fifo_wr_en(wgt_fifo_wr_en), .wgt_fifo_wr_data(wgt_fifo_wr_data),
        .wgt_fifo_full(wgt_fifo_full),
        .psum_fifo_rd_en(psum_fifo_rd_en), .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_empty(psum_fifo_empty), .ifm_fifo_full(ifm_fifo_full)
    );

    weight_tile_loader #(
        .ROWS(ROWS), .COLS(COLS), .WEIGHT_W(WGT_W), .ADDR_W(WGT_TILE_AW)
    ) u_weight_loader (
        .clk(clk), .rst(rst),
        .tile_wr_en(wgt_tile_wr_en), .tile_wr_addr(wgt_tile_wr_addr), .tile_wr_data(wgt_tile_wr_data),
        .tile_wr8_en(1'b0), .tile_wr8_addr({WGT_TILE_AW{1'b0}}),
        .tile_wr8_data(64'd0), .tile_wr8_keep(8'd0),
        .start(wgt_loader_start), .busy(wgt_loader_busy), .done(wgt_loader_done),
        .wgt_fifo_full(wgt_fifo_full),
        .wgt_fifo_wr_en(wgt_fifo_wr_en),
        .wgt_fifo_wr_data(wgt_fifo_wr_data)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer b, y, x, r, c, co, k, ch, ker, ky, kx, idx, block_base, ch_i;
    reg signed [7:0] feat [0:CIN-1][0:FM_H-1][0:FM_W-1];
    reg signed [7:0] weight [0:K_TOTAL-1][0:COUT_TOTAL-1];
    reg signed [PSUM_W-1:0] bias [0:COUT_TOTAL-1];
    reg signed [PSUM_W-1:0] golden [0:PIXELS-1][0:COUT_TOTAL-1];
    reg [COLS*2*PSUM_W-1:0] result_pkt [0:PIXELS-1];
    integer out_count;
    reg signed [PSUM_W-1:0] got0, got1;

    task clear_inputs;
        begin
            feeder_start = 0;
            compute_start = 0;
            dma_bank_wr_en = 0;
            dma_wr_x = 0;
            dma_wr_fy = 0;
            dma_line_advance = 0;
            bias_wr_addr = 0;
            bias_wr_data = 0;
            bias_wr_en = 0;
            wgt_tile_wr_en = 0;
            wgt_tile_wr_addr = 0;
            wgt_tile_wr_data = 0;
            wgt_loader_start = 0;
            psum_fifo_rd_en = 0;
            pass_base_k = 0;
            is_first_pass = 1'b1;
            use_ext_psum = 1'b0;
            use_psum_stream = 1'b0;
            psum_top_ext = 0;
            for (b = 0; b < 5; b = b + 1) dma_wr_data[b] = 0;
        end
    endtask

    task write_row;
        input integer row_y;
        begin
            @(negedge clk);
            dma_bank_wr_en = 5'b11111;
            dma_wr_fy = row_y[9:0];
            for (x = 0; x < FM_W; x = x + 1) begin
                dma_wr_x = x[8:0];
                for (b = 0; b < 5; b = b + 1)
                    dma_wr_data[b] = (b < CIN) ? feat[b][row_y][x] : 8'd0;
                @(negedge clk);
            end
            dma_line_advance = 1'b1;
            @(negedge clk);
            dma_line_advance = 1'b0;
            dma_bank_wr_en = 5'b00000;
            @(negedge clk);
        end
    endtask

    task load_bias_block;
        input integer co_base;
        begin
            bias_wr_en = 1'b1;
            for (ch_i = 0; ch_i < COUT_TILE; ch_i = ch_i + 1) begin
                bias_wr_addr = ch_i[5:0];
                bias_wr_data = bias[co_base + ch_i];
                @(negedge clk);
            end
            bias_wr_en = 1'b0;
        end
    endtask

    task load_weights_block;
        input integer co_base;
        integer gk;
        begin
            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COUT_TILE; c = c + 1) begin
                    gk = r;
                    @(negedge clk);
                    wgt_tile_wr_en = 1'b1;
                    wgt_tile_wr_addr = r*COUT_TILE + c;
                    wgt_tile_wr_data = (gk < K_TOTAL) ? weight[gk][co_base + c] : 8'd0;
                end
            end
            @(negedge clk);
            wgt_tile_wr_en = 1'b0;

            wgt_loader_start = 1'b1;
            @(negedge clk);
            wgt_loader_start = 1'b0;
            wait(wgt_loader_done);
            @(negedge clk);
        end
    endtask

    task run_feeder_and_compute;
        begin
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
        end
    endtask

    task read_results;
        input [PSUM_W-1:0] baseline_col0;
        integer guard;
        begin
            out_count = 0;
            guard = 0;
            while (out_count < PIXELS && guard < 256) begin
                wait ((psum_fifo_empty & COL_MASK) == 0);
                psum_fifo_rd_en = COL_MASK;
                @(negedge clk);
                psum_fifo_rd_en = 0;
                @(negedge clk);
                if (psum_fifo_rd_data[PSUM_W-1:0] !== baseline_col0) begin
                    result_pkt[out_count] = psum_fifo_rd_data;
                    out_count = out_count + 1;
                end
                guard = guard + 1;
            end
            if (out_count != PIXELS) begin
                $display("[FAIL] result count got=%0d exp=%0d", out_count, PIXELS);
                fail = fail + 1;
            end
        end
    endtask

    task check_block;
        input integer co_base;
        begin
            for (idx = 0; idx < PIXELS; idx = idx + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    got0 = result_pkt[idx][(2*c)*PSUM_W +: PSUM_W];
                    got1 = result_pkt[idx][(2*c+1)*PSUM_W +: PSUM_W];
                    if (got0 !== golden[idx][co_base + 2*c]) begin
                        $display("[FAIL] block%0d pixel%0d cout%0d got=%0d exp=%0d",
                            co_base / COUT_TILE, idx, co_base + 2*c, got0, golden[idx][co_base + 2*c]);
                        fail = fail + 1;
                    end else pass = pass + 1;
                    if (got1 !== golden[idx][co_base + 2*c + 1]) begin
                        $display("[FAIL] block%0d pixel%0d cout%0d got=%0d exp=%0d",
                            co_base / COUT_TILE, idx, co_base + 2*c + 1, got1, golden[idx][co_base + 2*c + 1]);
                        fail = fail + 1;
                    end else pass = pass + 1;
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
        pass = 0;
        fail = 0;
        clear_inputs();

        for (ch = 0; ch < CIN; ch = ch + 1)
            for (y = 0; y < FM_H; y = y + 1)
                for (x = 0; x < FM_W; x = x + 1)
                    feat[ch][y][x] = ch*9 + y*5 + x - 31;

        for (k = 0; k < K_TOTAL; k = k + 1)
            for (co = 0; co < COUT_TOTAL; co = co + 1)
                weight[k][co] = (k*7 + co*5) % 19 - 9;

        for (co = 0; co < COUT_TOTAL; co = co + 1) begin
            bias[co] = co*11 - 37;
            for (idx = 0; idx < PIXELS; idx = idx + 1) begin
                y = idx / OFM_W;
                x = idx % OFM_W;
                golden[idx][co] = bias[co];
                for (k = 0; k < K_TOTAL; k = k + 1) begin
                    ch = k / 9;
                    ker = k % 9;
                    ky = ker / 3;
                    kx = ker % 3;
                    golden[idx][co] = golden[idx][co] + feat[ch][y+ky][x+kx] * weight[k][co];
                end
            end
        end

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        for (block_base = 0; block_base < COUT_TOTAL; block_base = block_base + COUT_TILE) begin
            pass_base_k = 11'd0;
            is_first_pass = 1'b1;
            use_ext_psum = 1'b0;
            use_psum_stream = 1'b0;
            load_bias_block(block_base);
            load_weights_block(block_base);
            run_feeder_and_compute();
            read_results(bias[block_base]);
            check_block(block_base);
        end

        $display("=== tb_systolic_top_feeder_cout_blocks: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (2500) @(negedge clk);
        $display("[FAIL] timeout feeder_done=%0d compute_done=%0d out_count=%0d empty=%h",
            feeder_done, compute_done, out_count, psum_fifo_empty);
        $fatal(1);
    end
endmodule

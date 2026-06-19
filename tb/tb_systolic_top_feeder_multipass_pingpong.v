`timescale 1ns / 1ps

module tb_systolic_top_feeder_multipass_pingpong;
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
    localparam CIN = 5;
    localparam K_TOTAL = CIN * 3 * 3;
    localparam COUT = COLS * 2;
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
    reg dma_line_advance;
    reg [10:0] pass_base_k;
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
        .num_pixels(16'd1), .compute_done(compute_done),
        .fm_h(9'd5), .fm_w(9'd5), .ofm_h(9'd1), .ofm_w(9'd1),
        .tile_oy_base(9'd0), .tile_ofm_h(9'd0),
        .conv_stride(2'd1), .conv_pad(2'd0), .pass_base_k(pass_base_k),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .is_first_pass(is_first_pass), .psum_top_ext(psum_top_ext), .use_ext_psum(use_ext_psum),
        .psum_stream_data({COLS*2*PSUM_W{1'b0}}), .psum_stream_valid(1'b0), .psum_stream_compute_ready(1'b1), .use_psum_stream(1'b0),
        .wgt_fifo_wr_en(wgt_fifo_wr_en), .wgt_fifo_wr_data(wgt_fifo_wr_data),
        .wgt_fifo_full(wgt_fifo_full),
        .psum_fifo_rd_en(psum_fifo_rd_en), .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_empty(psum_fifo_empty), .ifm_fifo_full(ifm_fifo_full)
    );

    reg pp_wr_en, pp_wr_bank, pp_rd_en, pp_rd_bank;
    reg [3:0] pp_wr_addr, pp_rd_addr;
    reg [COLS*2*PSUM_W-1:0] pp_wr_data;
    wire [COLS*2*PSUM_W-1:0] pp_rd_data;
    wire pp_rd_valid;

    psum_pingpong_buffer #(
        .DATA_W(COLS*2*PSUM_W), .DEPTH(1), .AW(4)
    ) u_pp (
        .clk(clk), .rst(rst),
        .wr_en(pp_wr_en), .wr_bank(pp_wr_bank), .wr_addr(pp_wr_addr), .wr_data(pp_wr_data),
        .rd_en(pp_rd_en), .rd_bank(pp_rd_bank), .rd_addr(pp_rd_addr),
        .rd_data(pp_rd_data), .rd_valid(pp_rd_valid)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer b, y, x, r, c, co, k, lane, ch, ker, ky, kx, ch_i, n;
    reg signed [7:0] feat [0:CIN-1][0:FM_H-1][0:FM_W-1];
    reg signed [7:0] weight [0:K_TOTAL-1][0:COUT-1];
    reg signed [PSUM_W-1:0] bias [0:COUT-1];
    reg signed [PSUM_W-1:0] golden_partial [0:COUT-1];
    reg signed [PSUM_W-1:0] golden_final [0:COUT-1];
    reg [ROWS*WGT_W*2-1:0] wtmp;
    reg [COLS*2*PSUM_W-1:0] pass0_pkt, final_pkt;
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
            wgt_fifo_wr_en = 0;
            wgt_fifo_wr_data = 0;
            psum_fifo_rd_en = 0;
            pp_wr_en = 0;
            pp_wr_bank = 0;
            pp_wr_addr = 0;
            pp_wr_data = 0;
            pp_rd_en = 0;
            pp_rd_bank = 0;
            pp_rd_addr = 0;
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

    task read_non_bias_result;
        input [PSUM_W-1:0] baseline_col0;
        output [COLS*2*PSUM_W-1:0] pkt;
        integer found;
        begin
            pkt = 0;
            found = 0;
            for (n = 0; n < 64 && found == 0; n = n + 1) begin
                wait ((psum_fifo_empty & COL_MASK) == 0);
                psum_fifo_rd_en = COL_MASK;
                @(negedge clk);
                psum_fifo_rd_en = 0;
                @(negedge clk);
                if (psum_fifo_rd_data[PSUM_W-1:0] !== baseline_col0) begin
                    pkt = psum_fifo_rd_data;
                    found = 1;
                end
            end
            if (found == 0) begin
                $display("[FAIL] no non-baseline psum result found");
                fail = fail + 1;
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
        pass_base_k = 0;
        is_first_pass = 1'b1;
        use_ext_psum = 1'b0;
        psum_top_ext = 0;
        clear_inputs();

        for (ch = 0; ch < CIN; ch = ch + 1)
            for (y = 0; y < FM_H; y = y + 1)
                for (x = 0; x < FM_W; x = x + 1)
                    feat[ch][y][x] = ch*13 + y*3 + x - 25;

        for (k = 0; k < K_TOTAL; k = k + 1)
            for (co = 0; co < COUT; co = co + 1)
                weight[k][co] = (k*5 + co*3) % 17 - 8;

        for (co = 0; co < COUT; co = co + 1) begin
            bias[co] = co*7 - 19;
            golden_partial[co] = bias[co];
            golden_final[co] = bias[co];
            for (k = 0; k < K_TOTAL; k = k + 1) begin
                ch = k / 9;
                ker = k % 9;
                ky = ker / 3;
                kx = ker % 3;
                if (k < 32)
                    golden_partial[co] = golden_partial[co] + feat[ch][ky][kx] * weight[k][co];
                golden_final[co] = golden_final[co] + feat[ch][ky][kx] * weight[k][co];
            end
        end

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        load_bias();

        pass_base_k = 11'd0;
        is_first_pass = 1'b1;
        use_ext_psum = 1'b0;
        psum_top_ext = 0;
        load_weights_tile(0);
        run_feeder_and_compute();
        read_non_bias_result(bias[0], pass0_pkt);

        pp_wr_en = 1'b1;
        pp_wr_bank = 1'b0;
        pp_wr_addr = 4'd0;
        pp_wr_data = pass0_pkt;
        @(negedge clk);
        pp_wr_en = 1'b0;

        for (c = 0; c < COLS; c = c + 1) begin
            got0 = pass0_pkt[(2*c)*PSUM_W +: PSUM_W];
            got1 = pass0_pkt[(2*c+1)*PSUM_W +: PSUM_W];
            if (got0 !== golden_partial[2*c]) begin
                $display("[FAIL] pass0 cout%0d got=%0d exp=%0d", 2*c, got0, golden_partial[2*c]);
                fail = fail + 1;
            end else pass = pass + 1;
            if (got1 !== golden_partial[2*c+1]) begin
                $display("[FAIL] pass0 cout%0d got=%0d exp=%0d", 2*c+1, got1, golden_partial[2*c+1]);
                fail = fail + 1;
            end else pass = pass + 1;
        end

        pp_rd_en = 1'b1;
        pp_rd_bank = 1'b0;
        pp_rd_addr = 4'd0;
        @(negedge clk);
        pp_rd_en = 1'b0;
        if (pp_rd_valid !== 1'b1 || pp_rd_data !== pass0_pkt) begin
            $display("[FAIL] pingpong readback mismatch");
            fail = fail + 1;
        end else begin
            pass = pass + 1;
        end
        psum_top_ext = pp_rd_data;

        pass_base_k = 11'd32;
        is_first_pass = 1'b0;
        use_ext_psum = 1'b1;
        load_weights_tile(32);
        run_feeder_and_compute();
        read_non_bias_result(pass0_pkt[PSUM_W-1:0], final_pkt);

        for (c = 0; c < COLS; c = c + 1) begin
            got0 = final_pkt[(2*c)*PSUM_W +: PSUM_W];
            got1 = final_pkt[(2*c+1)*PSUM_W +: PSUM_W];
            if (got0 !== golden_final[2*c]) begin
                $display("[FAIL] final cout%0d got=%0d exp=%0d", 2*c, got0, golden_final[2*c]);
                fail = fail + 1;
            end else pass = pass + 1;
            if (got1 !== golden_final[2*c+1]) begin
                $display("[FAIL] final cout%0d got=%0d exp=%0d", 2*c+1, got1, golden_final[2*c+1]);
                fail = fail + 1;
            end else pass = pass + 1;
        end

        $display("=== tb_systolic_top_feeder_multipass_pingpong: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (2000) @(negedge clk);
        $display("[FAIL] timeout feeder_done=%0d compute_done=%0d", feeder_done, compute_done);
        $fatal(1);
    end
endmodule

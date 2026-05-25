`timescale 1ns / 1ps

module tb_window_feeder;
    localparam FM_W = 5;
    localparam FM_H = 5;
    localparam AW = 3;

    reg clk, rst, start;
    reg [AW-1:0] fm_h, fm_w, ofm_h, ofm_w;
    reg [1:0] stride, pad;
    reg [10:0] pass_base_k;
    wire fill_req;
    wire [AW-1:0] fill_fy;
    reg [4:0] dma_bank_wr_en;
    reg [AW-1:0] dma_wr_x;
    reg [AW:0] dma_wr_fy;
    reg [7:0] dma_wr_data [0:4];
    reg dma_line_advance;
    reg ifm_fifo_full_any;
    wire [255:0] ifm_data;
    wire ifm_valid, window_ready, busy, done;
    wire [AW-1:0] cur_oy, cur_ox;

    window_feeder #(.FM_W(FM_W), .FM_H(FM_H), .AW(AW)) dut (
        .clk(clk), .rst(rst), .start(start),
        .fm_h(fm_h), .fm_w(fm_w), .ofm_h(ofm_h), .ofm_w(ofm_w),
        .tile_oy_base({AW{1'b0}}), .tile_ofm_h({AW{1'b0}}),
        .stride(stride), .pad(pad), .pass_base_k(pass_base_k),
        .fill_req(fill_req), .fill_fy(fill_fy),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x),
        .dma_wr_fy(dma_wr_fy), .dma_wr_data(dma_wr_data),
        .dma_line_advance(dma_line_advance),
        .ifm_fifo_full_any(ifm_fifo_full_any),
        .ifm_data(ifm_data), .ifm_valid(ifm_valid),
        .cur_oy(cur_oy), .cur_ox(cur_ox),
        .window_ready(window_ready), .busy(busy), .done(done)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer b, x, lane, ch, ker, ky, kx;
    integer push_count;
    integer exp_oy, exp_ox, exp_val;
    reg [7:0] feat [0:4][0:FM_H-1][0:FM_W-1];

    task write_row;
        input integer fy;
        begin
            @(negedge clk);
            dma_wr_fy = fy[AW:0];
            dma_bank_wr_en = 5'b11111;
            for (x = 0; x < FM_W; x = x + 1) begin
                dma_wr_x = x[AW-1:0];
                for (b = 0; b < 5; b = b + 1)
                    dma_wr_data[b] = feat[b][fy][x];
                @(negedge clk);
            end
            dma_line_advance = 1'b1;
            @(negedge clk);
            dma_line_advance = 1'b0;
            dma_bank_wr_en = 5'b00000;
            @(negedge clk);
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        start = 0;
        fm_h = FM_H;
        fm_w = FM_W;
        ofm_h = 3;
        ofm_w = 3;
        stride = 1;
        pad = 0;
        pass_base_k = 0;
        dma_bank_wr_en = 0;
        dma_wr_x = 0;
        dma_wr_fy = 0;
        dma_line_advance = 0;
        ifm_fifo_full_any = 0;
        pass = 0;
        fail = 0;
        push_count = 0;
        for (b = 0; b < 5; b = b + 1) begin
            dma_wr_data[b] = 0;
            for (x = 0; x < FM_W; x = x + 1) begin
                feat[b][0][x] = b*40 + x;
                feat[b][1][x] = b*40 + 8 + x;
                feat[b][2][x] = b*40 + 16 + x;
                feat[b][3][x] = b*40 + 24 + x;
                feat[b][4][x] = b*40 + 32 + x;
            end
        end

        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
    end

    initial begin
        @(negedge rst);
        forever begin
            wait(fill_req);
            write_row(fill_fy);
            @(posedge clk);
            #1;
        end
    end

    initial begin
        @(negedge rst);
        wait(ifm_valid && cur_oy == 0 && cur_ox == 1);
        ifm_fifo_full_any = 1'b1;
        repeat (3) @(negedge clk);
        if (cur_oy !== 0 || cur_ox !== 1 || ifm_valid !== 1'b0) begin
            $display("[FAIL] backpressure hold oy=%0d ox=%0d valid=%0d", cur_oy, cur_ox, ifm_valid);
            fail = fail + 1;
        end else begin
            pass = pass + 1;
        end
        ifm_fifo_full_any = 1'b0;
    end

    always @(posedge clk) begin
        if (ifm_valid) begin
            exp_oy = push_count / 3;
            exp_ox = push_count % 3;
            if (cur_oy !== exp_oy[AW-1:0] || cur_ox !== exp_ox[AW-1:0]) begin
                $display("[FAIL] push%0d coord got=(%0d,%0d) exp=(%0d,%0d)",
                    push_count, cur_oy, cur_ox, exp_oy, exp_ox);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
            for (lane = 0; lane < 32; lane = lane + 1) begin
                ch = lane / 9;
                ker = lane % 9;
                ky = ker / 3;
                kx = ker % 3;
                if (ch < 5) begin
                    exp_val = feat[ch][exp_oy + ky][exp_ox + kx];
                    if (ifm_data[lane*8 +: 8] !== exp_val[7:0]) begin
                        $display("[FAIL] push%0d lane%0d got=%0d exp=%0d",
                            push_count, lane, ifm_data[lane*8 +: 8], exp_val);
                        fail = fail + 1;
                    end else begin
                        pass = pass + 1;
                    end
                end
            end
            push_count = push_count + 1;
        end
    end

    initial begin
        wait(done);
        @(negedge clk);
        if (push_count != 9) begin
            $display("[FAIL] push count got=%0d exp=9", push_count);
            fail = fail + 1;
        end else begin
            pass = pass + 1;
        end
        if (busy !== 1'b0) begin
            $display("[FAIL] busy should drop at done");
            fail = fail + 1;
        end else begin
            pass = pass + 1;
        end
        $display("=== tb_window_feeder: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (400) @(negedge clk);
        $display("[FAIL] timeout push_count=%0d fill_req=%0d fill_fy=%0d busy=%0d done=%0d oy=%0d ox=%0d ready=%0d",
            push_count, fill_req, fill_fy, busy, done, cur_oy, cur_ox, window_ready);
        $fatal(1);
    end
endmodule

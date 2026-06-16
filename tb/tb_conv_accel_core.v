`timescale 1ns / 1ps

module tb_conv_accel_core;
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
    localparam CIN = 5;
    localparam K_TOTAL = CIN * 3 * 3;
    localparam COUT_TILE = COLS * 2;
    localparam COUT_TOTAL = COUT_TILE + 2;
    localparam WGT_TILE_AW = 11;
    localparam PSUM_A = 4;

    reg clk, rst;
    reg cfg_wr_en, cfg_rd_en;
    reg [6:0] cfg_addr;
    reg [31:0] cfg_wdata;
    wire [31:0] cfg_rdata;
    wire bias_load_req, weight_load_req;
    reg bias_load_done, weight_tile_ready;
    wire [10:0] current_cout_base;
    wire [13:0] current_pass_base_k;
    reg [5:0] bias_wr_addr;
    reg [PSUM_W-1:0] bias_wr_data;
    reg bias_wr_en;
    reg wgt_tile_wr_en;
    reg [WGT_TILE_AW-1:0] wgt_tile_wr_addr;
    reg [WGT_W-1:0] wgt_tile_wr_data;
    wire feeder_fill_req;
    wire [8:0] feeder_fill_fy;
    reg [4:0] dma_bank_wr_en;
    reg [8:0] dma_wr_x;
    reg [9:0] dma_wr_fy;
    reg [7:0] dma_wr_data [0:4];
    reg dma_line_advance;
    reg quant_wr_en;
    reg [5:0] quant_wr_addr;
    reg [31:0] quant_wr_data;
    reg [5:0] quant_rd_addr;
    wire [31:0] quant_rd_data;
    reg act_lut_wr_en;
    reg [7:0] act_lut_wr_addr, act_lut_wr_data;
    wire ofm_mem_wr_en;
    wire [15:0] ofm_mem_wr_addr;
    wire [7:0] ofm_mem_wr_data;
    wire ofm_packet_full;

    conv_accel_core #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WGT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_D), .IFM_FIFO_AW(IFM_AW),
        .WGT_FIFO_DEPTH(WGT_D), .WGT_FIFO_AW(WGT_AW),
        .PSUM_FIFO_DEPTH(PSUM_D), .PSUM_FIFO_AW(PSUM_AW),
        .FM_W_MAX(FM_W), .FM_H_MAX(FM_H),
        .K_TILE(32), .COUT_TILE(COUT_TILE),
        .WGT_TILE_AW(WGT_TILE_AW), .PSUM_BUF_AW(PSUM_A), .PSUM_BUF_DEPTH(PIXELS),
        .OFM_ADDR_W(16)
    ) dut (
        .clk(clk), .rst(rst),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_rd_en(cfg_rd_en), .cfg_rdata(cfg_rdata),
        .bias_load_req(bias_load_req), .bias_load_done(bias_load_done),
        .current_cout_base(current_cout_base), .current_pass_base_k(current_pass_base_k),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .weight_load_req(weight_load_req), .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en), .wgt_tile_wr_addr(wgt_tile_wr_addr), .wgt_tile_wr_data(wgt_tile_wr_data),
        .wgt_tile_wr8_en(1'b0), .wgt_tile_wr8_addr({WGT_TILE_AW{1'b0}}),
        .wgt_tile_wr8_data(64'd0), .wgt_tile_wr8_keep(8'd0),
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .raw_hwc_load_active_cycles(32'd0),
        .raw_hwc_load_unpack_cycles(32'd0),
        .raw_hwc_replay_active_cycles(32'd0),
        .raw_hwc_replay_wait_ready_cycles(32'd0),
        .quant_wr_en(quant_wr_en), .quant_wr_addr(quant_wr_addr), .quant_wr_data(quant_wr_data),
        .quant_rd_addr(quant_rd_addr), .quant_rd_data(quant_rd_data),
        .act_lut_wr_en(act_lut_wr_en),
        .act_lut_wr_addr(act_lut_wr_addr), .act_lut_wr_data(act_lut_wr_data),
        .ofm_mem_wr_en(ofm_mem_wr_en), .ofm_mem_wr_ready(1'b1),
        .ofm_mem_wr_addr(ofm_mem_wr_addr),
        .ofm_mem_wr_data(ofm_mem_wr_data), .ofm_packet_full(ofm_packet_full)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer b, y, x, kk, cc, co, k, ch, ker, ky, kx, idx;
    integer ofm_mem_wr_count;
    reg signed [7:0] feat [0:CIN-1][0:FM_H-1][0:FM_W-1];
    reg signed [7:0] weight [0:K_TOTAL-1][0:COUT_TOTAL-1];
    reg signed [PSUM_W-1:0] bias [0:COUT_TOTAL-1];
    reg signed [PSUM_W-1:0] golden [0:PIXELS-1][0:COUT_TOTAL-1];
    reg [7:0] ofm_mem [0:PIXELS*COUT_TOTAL-1];

    function [7:0] clamp8;
        input signed [PSUM_W-1:0] v;
        begin
            if (v > 127) clamp8 = 8'd127;
            else if (v < -128) clamp8 = 8'd128;
            else clamp8 = v[7:0];
        end
    endfunction

    function [7:0] relu8;
        input [7:0] v;
        begin
            relu8 = ($signed(v) < 0) ? 8'd0 : v;
        end
    endfunction

    task cfg_write;
        input [6:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            cfg_addr = addr;
            cfg_wdata = data;
            cfg_wr_en = 1'b1;
            @(negedge clk);
            cfg_wr_en = 1'b0;
        end
    endtask

    task clear_inputs;
        begin
            cfg_wr_en = 0;
            cfg_rd_en = 0;
            cfg_addr = 0;
            cfg_wdata = 0;
            bias_load_done = 0;
            weight_tile_ready = 0;
            bias_wr_addr = 0;
            bias_wr_data = 0;
            bias_wr_en = 0;
            wgt_tile_wr_en = 0;
            wgt_tile_wr_addr = 0;
            wgt_tile_wr_data = 0;
            dma_bank_wr_en = 0;
            dma_wr_x = 0;
            dma_wr_fy = 0;
            dma_line_advance = 0;
            for (b = 0; b < 5; b = b + 1) dma_wr_data[b] = 0;
            quant_wr_en = 0;
            quant_wr_addr = 0;
            quant_wr_data = 0;
            quant_rd_addr = 0;
            act_lut_wr_en = 1'b0;
            act_lut_wr_addr = 8'd0;
            act_lut_wr_data = 8'd0;
        end
    endtask

    task quant_write;
        input integer lane;
        input [15:0] mult;
        input [3:0] shift;
        input [7:0] zp;
        begin
            @(negedge clk);
            quant_wr_addr = lane[5:0];
            quant_wr_data = {zp, 4'd0, shift, mult};
            quant_wr_en = 1'b1;
            @(negedge clk);
            quant_wr_en = 1'b0;
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
        end
    endtask

    task service_bias;
        integer i;
        integer base;
        begin
            base = current_cout_base;
            for (i = 0; i < COUT_TILE; i = i + 1) begin
                @(negedge clk);
                bias_wr_en = 1'b1;
                bias_wr_addr = i[5:0];
                bias_wr_data = (base + i < COUT_TOTAL) ? bias[base + i] : {PSUM_W{1'b0}};
            end
            @(negedge clk);
            bias_wr_en = 1'b0;
            bias_load_done = 1'b1;
            @(negedge clk);
            bias_load_done = 1'b0;
        end
    endtask

    task service_weight;
        integer co_base;
        integer k_base;
        integer gk;
        begin
            co_base = current_cout_base;
            k_base = current_pass_base_k;
            for (kk = 0; kk < ROWS; kk = kk + 1) begin
                for (cc = 0; cc < COUT_TILE; cc = cc + 1) begin
                    gk = k_base + kk;
                    @(negedge clk);
                    wgt_tile_wr_en = 1'b1;
                    wgt_tile_wr_addr = kk*COUT_TILE + cc;
                    wgt_tile_wr_data = ((gk < K_TOTAL) && (co_base + cc < COUT_TOTAL)) ?
                                       weight[gk][co_base + cc] : 8'd0;
                end
            end
            @(negedge clk);
            wgt_tile_wr_en = 1'b0;
            weight_tile_ready = 1'b1;
            @(negedge clk);
            weight_tile_ready = 1'b0;
        end
    endtask

    initial begin
        @(negedge rst);
        forever begin
            wait(bias_load_req);
            service_bias();
            wait(!bias_load_req);
        end
    end

    initial begin
        @(negedge rst);
        forever begin
            wait(weight_load_req);
            service_weight();
            wait(!weight_load_req);
        end
    end

    initial begin
        @(negedge rst);
        forever begin
            wait(feeder_fill_req);
            write_row(feeder_fill_fy);
            @(posedge clk);
            #1;
        end
    end

    always @(negedge clk) begin
        if (!rst && ofm_mem_wr_en) begin
            ofm_mem[ofm_mem_wr_addr] <= ofm_mem_wr_data;
            ofm_mem_wr_count <= ofm_mem_wr_count + 1;
        end
    end

    initial begin
        clk = 0;
        rst = 1;
        pass = 0;
        fail = 0;
        ofm_mem_wr_count = 0;
        clear_inputs();
        for (idx = 0; idx < PIXELS*COUT_TOTAL; idx = idx + 1)
            ofm_mem[idx] = 8'hxx;

        for (ch = 0; ch < CIN; ch = ch + 1)
            for (y = 0; y < FM_H; y = y + 1)
                for (x = 0; x < FM_W; x = x + 1)
                    feat[ch][y][x] = ch*13 + y*3 + x - 25;

        for (k = 0; k < K_TOTAL; k = k + 1)
            for (co = 0; co < COUT_TOTAL; co = co + 1)
                weight[k][co] = (k*5 + co*3) % 17 - 8;

        for (co = 0; co < COUT_TOTAL; co = co + 1) begin
            bias[co] = co*7 - 19;
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
        for (co = 0; co < COUT_TILE; co = co + 1)
            quant_write(co, 16'd32768, 4'd0, 8'd0);
        quant_rd_addr = 6'd7;
        #1;
        if (quant_rd_data !== {8'd0, 4'd0, 4'd0, 16'd32768}) begin
            $display("[FAIL] quant rd got=%h", quant_rd_data);
            fail = fail + 1;
        end else pass = pass + 1;

        cfg_write(6'h01, {7'd0, 9'd5, 7'd0, 9'd5});
        cfg_write(6'h02, {7'd0, 9'd3, 7'd0, 9'd3});
        cfg_write(6'h03, {22'd0, 2'd0, 6'd0, 2'd1});
        cfg_write(6'h04, K_TOTAL);
        cfg_write(6'h05, COUT_TOTAL);
        cfg_write(6'h06, PIXELS);
        cfg_write(6'h07, 32'd1);
        cfg_write(6'h00, 32'd1);

        cfg_addr = 6'h00;
        wait(cfg_rdata[1] == 1'b1);
        repeat (2) @(negedge clk);

        if (ofm_mem_wr_count != PIXELS*COUT_TOTAL) begin
            $display("[FAIL] ofm writes got=%0d exp=%0d", ofm_mem_wr_count, PIXELS*COUT_TOTAL);
            fail = fail + 1;
        end else pass = pass + 1;

        for (idx = 0; idx < PIXELS; idx = idx + 1) begin
            for (co = 0; co < COUT_TOTAL; co = co + 1) begin
                if (ofm_mem[idx*COUT_TOTAL + co] !== relu8(clamp8(golden[idx][co]))) begin
                    $display("[FAIL] ofm pixel%0d cout%0d got=%0d exp=%0d",
                        idx, co, ofm_mem[idx*COUT_TOTAL + co], relu8(clamp8(golden[idx][co])));
                    fail = fail + 1;
                end else pass = pass + 1;
            end
        end

        cfg_write(6'h00, 32'd2);
        cfg_addr = 6'h00;
        #1;
        if (cfg_rdata[1] !== 1'b0) begin
            $display("[FAIL] done sticky did not clear");
            fail = fail + 1;
        end else pass = pass + 1;

        $display("=== tb_conv_accel_core: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (16000) @(negedge clk);
        $display("[FAIL] timeout status=%b ofm_wr=%0d", cfg_rdata[1:0], ofm_mem_wr_count);
        $fatal(1);
    end
endmodule

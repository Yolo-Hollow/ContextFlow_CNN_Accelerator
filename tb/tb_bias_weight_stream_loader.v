`timescale 1ns / 1ps

module tb_bias_weight_stream_loader;
    localparam ROWS = 4;
    localparam COLS = 3;
    localparam COUT_TILE = COLS * 2;
    localparam TILE_WORDS = ROWS * COUT_TILE;
    localparam PSUM_W = 32;
    localparam WEIGHT_W = 8;
    localparam BIAS_AW = 3;
    localparam WGT_AW = 5;

    reg clk;
    reg rst;

    reg bias_load_req;
    wire bias_s_ready;
    reg bias_s_valid;
    reg [PSUM_W-1:0] bias_s_data;
    wire bias_load_done;
    wire bias_wr_en;
    wire [BIAS_AW-1:0] bias_wr_addr;
    wire [PSUM_W-1:0] bias_wr_data;

    reg weight_load_req;
    wire weight_s_ready;
    reg weight_s_valid;
    reg [WEIGHT_W-1:0] weight_s_data;
    wire weight_tile_ready;
    wire wgt_tile_wr_en;
    wire [WGT_AW-1:0] wgt_tile_wr_addr;
    wire [WEIGHT_W-1:0] wgt_tile_wr_data;

    integer pass;
    integer fail;
    integer bias_seen;
    integer weight_seen;
    integer bias_done_seen;
    integer weight_ready_seen;

    bias_weight_stream_loader #(
        .ROWS(ROWS), .COLS(COLS), .PSUM_W(PSUM_W), .WEIGHT_W(WEIGHT_W),
        .BIAS_ADDR_W(BIAS_AW), .WGT_ADDR_W(WGT_AW)
    ) dut (
        .clk(clk), .rst(rst),
        .bias_load_req(bias_load_req), .bias_s_ready(bias_s_ready),
        .bias_s_valid(bias_s_valid), .bias_s_data(bias_s_data),
        .bias_load_done(bias_load_done),
        .bias_wr_en(bias_wr_en), .bias_wr_addr(bias_wr_addr),
        .bias_wr_data(bias_wr_data),
        .weight_load_req(weight_load_req), .weight_s_ready(weight_s_ready),
        .weight_s_valid(weight_s_valid), .weight_s_data(weight_s_data),
        .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en), .wgt_tile_wr_addr(wgt_tile_wr_addr),
        .wgt_tile_wr_data(wgt_tile_wr_data)
    );

    always #5 clk = ~clk;

    task check;
        input cond;
        input [255:0] msg;
        begin
            if (cond) begin
                pass = pass + 1;
            end else begin
                fail = fail + 1;
                $display("[FAIL] %0s", msg);
            end
        end
    endtask

    task send_bias_word;
        input integer idx;
        begin
            @(negedge clk);
            bias_s_valid = 1'b1;
            bias_s_data = 32'h1000_0000 + idx;
            wait(bias_s_ready);
            @(negedge clk);
            bias_s_valid = 1'b0;
            bias_s_data = 32'd0;
        end
    endtask

    task send_weight_word;
        input integer idx;
        begin
            @(negedge clk);
            weight_s_valid = 1'b1;
            weight_s_data = idx[7:0] ^ 8'h5a;
            wait(weight_s_ready);
            @(negedge clk);
            weight_s_valid = 1'b0;
            weight_s_data = 8'd0;
        end
    endtask

    always @(posedge clk) begin
        if (!rst && bias_wr_en) begin
            check(bias_wr_addr == bias_seen[BIAS_AW-1:0], "bias write address order");
            check(bias_wr_data == 32'h1000_0000 + bias_seen, "bias write data order");
            bias_seen = bias_seen + 1;
        end
        if (!rst && wgt_tile_wr_en) begin
            check(wgt_tile_wr_addr == weight_seen[WGT_AW-1:0], "weight write address order");
            check(wgt_tile_wr_data == (weight_seen[7:0] ^ 8'h5a), "weight write data order");
            weight_seen = weight_seen + 1;
        end
        if (!rst && bias_load_done)
            bias_done_seen = bias_done_seen + 1;
        if (!rst && weight_tile_ready)
            weight_ready_seen = weight_ready_seen + 1;
    end

    integer i;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
        bias_load_req = 1'b0;
        bias_s_valid = 1'b0;
        bias_s_data = 32'd0;
        weight_load_req = 1'b0;
        weight_s_valid = 1'b0;
        weight_s_data = 8'd0;
        pass = 0;
        fail = 0;
        bias_seen = 0;
        weight_seen = 0;
        bias_done_seen = 0;
        weight_ready_seen = 0;

        repeat (4) @(negedge clk);
        rst = 1'b0;

        check(!bias_s_ready, "bias ready low before request");
        check(!weight_s_ready, "weight ready low before request");

        @(negedge clk);
        bias_load_req = 1'b1;
        @(negedge clk);
        bias_load_req = 1'b0;
        check(bias_s_ready, "bias ready asserted after request");

        send_bias_word(0);
        repeat (2) @(negedge clk);
        for (i = 1; i < COUT_TILE; i = i + 1)
            send_bias_word(i);
        @(negedge clk);
        check(bias_seen == COUT_TILE, "all bias words written");
        check(bias_done_seen == 1, "bias load done pulse count");
        @(negedge clk);
        check(!bias_s_ready, "bias ready low after load");

        @(negedge clk);
        weight_load_req = 1'b1;
        @(negedge clk);
        weight_load_req = 1'b0;
        check(weight_s_ready, "weight ready asserted after request");

        for (i = 0; i < TILE_WORDS; i = i + 1) begin
            if ((i % 5) == 2)
                repeat (2) @(negedge clk);
            send_weight_word(i);
        end
        @(negedge clk);
        check(weight_seen == TILE_WORDS, "all weight words written");
        check(weight_ready_seen == 1, "weight tile ready pulse count");
        @(negedge clk);
        check(!weight_s_ready, "weight ready low after load");

        $display("=== %m: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

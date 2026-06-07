`timescale 1ns / 1ps

module tb_axis_bias_weight_loader;
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
    reg stream_reset;
    reg batch_mode;
    reg [31:0] bias_expected_packets;
    reg [31:0] weight_expected_packets;

    reg bias_load_req;
    wire bias_tready;
    reg bias_tvalid;
    reg [63:0] bias_tdata;
    reg [7:0] bias_tkeep;
    reg bias_tlast;
    wire bias_load_done;
    wire bias_wr_en;
    wire [BIAS_AW-1:0] bias_wr_addr;
    wire [PSUM_W-1:0] bias_wr_data;

    reg weight_load_req;
    wire weight_tready;
    reg weight_tvalid;
    reg [63:0] weight_tdata;
    reg [7:0] weight_tkeep;
    reg weight_tlast;
    wire weight_tile_ready;
    wire wgt_tile_wr_en;
    wire [WGT_AW-1:0] wgt_tile_wr_addr;
    wire [WEIGHT_W-1:0] wgt_tile_wr_data;
    wire wgt_tile_wr8_en;
    wire [WGT_AW-1:0] wgt_tile_wr8_addr;
    wire [WEIGHT_W*8-1:0] wgt_tile_wr8_data;
    wire [7:0] wgt_tile_wr8_keep;

    wire bias_tkeep_error;
    wire bias_tlast_error;
    wire weight_tkeep_error;
    wire weight_tlast_error;
    wire [31:0] bias_completed_packets;
    wire [31:0] weight_completed_packets;

    integer pass;
    integer fail;
    integer bias_seen;
    integer weight_seen;
    integer bias_done_seen;
    integer weight_ready_seen;

    axis_bias_weight_loader #(
        .ROWS(ROWS),
        .COLS(COLS),
        .PSUM_W(PSUM_W),
        .WEIGHT_W(WEIGHT_W),
        .BIAS_ADDR_W(BIAS_AW),
        .WGT_ADDR_W(WGT_AW)
    ) dut (
        .clk(clk),
        .rst(rst),
        .stream_reset(stream_reset),
        .batch_mode(batch_mode),
        .bias_expected_packets(bias_expected_packets),
        .weight_expected_packets(weight_expected_packets),
        .bias_load_req(bias_load_req),
        .bias_s_axis_tready(bias_tready),
        .bias_s_axis_tvalid(bias_tvalid),
        .bias_s_axis_tdata(bias_tdata),
        .bias_s_axis_tkeep(bias_tkeep),
        .bias_s_axis_tlast(bias_tlast),
        .bias_load_done(bias_load_done),
        .bias_wr_en(bias_wr_en),
        .bias_wr_addr(bias_wr_addr),
        .bias_wr_data(bias_wr_data),
        .weight_load_req(weight_load_req),
        .weight_s_axis_tready(weight_tready),
        .weight_s_axis_tvalid(weight_tvalid),
        .weight_s_axis_tdata(weight_tdata),
        .weight_s_axis_tkeep(weight_tkeep),
        .weight_s_axis_tlast(weight_tlast),
        .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en),
        .wgt_tile_wr_addr(wgt_tile_wr_addr),
        .wgt_tile_wr_data(wgt_tile_wr_data),
        .wgt_tile_wr8_en(wgt_tile_wr8_en),
        .wgt_tile_wr8_addr(wgt_tile_wr8_addr),
        .wgt_tile_wr8_data(wgt_tile_wr8_data),
        .wgt_tile_wr8_keep(wgt_tile_wr8_keep),
        .bias_tkeep_error(bias_tkeep_error),
        .bias_tlast_error(bias_tlast_error),
        .weight_tkeep_error(weight_tkeep_error),
        .weight_tlast_error(weight_tlast_error),
        .bias_completed_packets(bias_completed_packets),
        .weight_completed_packets(weight_completed_packets)
    );

    always #5 clk = ~clk;

    task check;
        input cond;
        input [255:0] msg;
        begin
            if (cond) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("[FAIL] %0s", msg);
            end
        end
    endtask

    task send_bias_beat;
        input integer beat;
        input last;
        begin
            @(negedge clk);
            bias_tvalid = 1'b1;
            bias_tdata = 64'd0;
            bias_tdata[31:0] = 32'h1000_0000 + beat*2;
            bias_tdata[63:32] = 32'h1000_0000 + beat*2 + 1;
            bias_tkeep = 8'hff;
            bias_tlast = last;
            wait(bias_tready);
            @(posedge clk);
            @(negedge clk);
            bias_tvalid = 1'b0;
            bias_tdata = 64'd0;
            bias_tkeep = 8'd0;
            bias_tlast = 1'b0;
        end
    endtask

    task send_weight_beat;
        input integer beat;
        input last;
        integer n;
        begin
            @(negedge clk);
            weight_tvalid = 1'b1;
            weight_tdata = 64'd0;
            for (n = 0; n < 8; n = n + 1)
                weight_tdata[n*8 +: 8] = ((beat*8 + n) & 8'hff) ^ 8'h5a;
            weight_tkeep = 8'hff;
            weight_tlast = last;
            wait(weight_tready);
            @(posedge clk);
            @(negedge clk);
            weight_tvalid = 1'b0;
            weight_tdata = 64'd0;
            weight_tkeep = 8'd0;
            weight_tlast = 1'b0;
        end
    endtask

    integer weight_lane_check;
    always @(posedge clk) begin
        #1;
        if (!rst && bias_wr_en) begin
            check(bias_wr_addr == bias_seen[BIAS_AW-1:0], "AXIS bias address order");
            check(bias_wr_data == 32'h1000_0000 + bias_seen, "AXIS bias data order");
            bias_seen = bias_seen + 1;
        end
        if (!rst && wgt_tile_wr_en)
            check(1'b0, "AXIS weight narrow write should be idle");
        if (!rst && wgt_tile_wr8_en) begin
            check(wgt_tile_wr8_addr == weight_seen[WGT_AW-1:0], "AXIS packed weight base address order");
            check(wgt_tile_wr8_keep == 8'hff, "AXIS packed weight keep");
            for (weight_lane_check = 0; weight_lane_check < 8; weight_lane_check = weight_lane_check + 1) begin
                check(wgt_tile_wr8_data[weight_lane_check*8 +: 8] ==
                      (((weight_seen + weight_lane_check) & 8'hff) ^ 8'h5a),
                      "AXIS packed weight data order");
            end
            weight_seen = weight_seen + 8;
        end
        if (!rst && bias_load_done)
            bias_done_seen = bias_done_seen + 1;
        if (!rst && weight_tile_ready)
            weight_ready_seen = weight_ready_seen + 1;
    end

    integer i;
    integer timeout_count;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
        stream_reset = 1'b0;
        batch_mode = 1'b0;
        bias_expected_packets = 32'd0;
        weight_expected_packets = 32'd0;
        bias_load_req = 1'b0;
        bias_tvalid = 1'b0;
        bias_tdata = 64'd0;
        bias_tkeep = 8'd0;
        bias_tlast = 1'b0;
        weight_load_req = 1'b0;
        weight_tvalid = 1'b0;
        weight_tdata = 64'd0;
        weight_tkeep = 8'd0;
        weight_tlast = 1'b0;
        pass = 0;
        fail = 0;
        bias_seen = 0;
        weight_seen = 0;
        bias_done_seen = 0;
        weight_ready_seen = 0;

        repeat (4) @(negedge clk);
        rst = 1'b0;
        check(!bias_tready, "AXIS bias ready low before request");
        check(!weight_tready, "AXIS weight ready low before request");

        @(negedge clk);
        bias_load_req = 1'b1;
        @(negedge clk);
        bias_load_req = 1'b0;
        check(bias_tready, "AXIS bias ready asserted after request");

        for (i = 0; i < COUT_TILE / 2; i = i + 1) begin
            if (i == 1)
                repeat (2) @(negedge clk);
            send_bias_beat(i, i == (COUT_TILE / 2 - 1));
        end
        timeout_count = 0;
        while (bias_seen != COUT_TILE && timeout_count < 200) begin
            @(negedge clk);
            timeout_count = timeout_count + 1;
        end
        repeat (2) @(negedge clk);
        check(bias_seen == COUT_TILE, "all AXIS bias words written");
        check(bias_done_seen == 1, "AXIS bias done pulse count");
        check(!bias_tkeep_error, "AXIS bias TKEEP clean");
        check(!bias_tlast_error, "AXIS bias TLAST clean");

        @(negedge clk);
        weight_load_req = 1'b1;
        @(negedge clk);
        weight_load_req = 1'b0;
        check(weight_tready, "AXIS weight ready asserted after request");

        for (i = 0; i < TILE_WORDS / 8; i = i + 1) begin
            if (i == 1)
                repeat (2) @(negedge clk);
            send_weight_beat(i, i == (TILE_WORDS / 8 - 1));
        end
        timeout_count = 0;
        while (weight_seen != TILE_WORDS && timeout_count < 400) begin
            @(negedge clk);
            timeout_count = timeout_count + 1;
        end
        repeat (2) @(negedge clk);
        check(weight_seen == TILE_WORDS, "all AXIS weight words written");
        check(weight_ready_seen == 1, "AXIS weight ready pulse count");
        check(!weight_tkeep_error, "AXIS weight TKEEP clean");
        check(!weight_tlast_error, "AXIS weight TLAST clean");
        check(bias_completed_packets == 1, "legacy bias packet count");
        check(weight_completed_packets == 1, "legacy weight packet count");

        $display("=== %m: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

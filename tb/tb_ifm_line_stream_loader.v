`timescale 1ns / 1ps

module tb_ifm_line_stream_loader;
    localparam AW = 9;
    localparam FM_W = 7;

    reg clk;
    reg rst;
    reg [AW-1:0] fm_w;
    reg fill_req;
    reg [AW-1:0] fill_fy;
    wire line_s_ready;
    reg line_s_valid;
    reg [7:0] line_s_data [0:4];
    wire [4:0] dma_bank_wr_en;
    wire [AW-1:0] dma_wr_x;
    wire [AW:0] dma_wr_fy;
    wire [7:0] dma_wr_data [0:4];
    wire dma_line_advance;

    integer pass;
    integer fail;
    integer beat_seen;
    integer advance_seen;
    integer b;

    ifm_line_stream_loader #(.AW(AW)) dut (
        .clk(clk), .rst(rst),
        .fm_w(fm_w), .fill_req(fill_req), .fill_fy(fill_fy),
        .line_s_ready(line_s_ready), .line_s_valid(line_s_valid),
        .line_s_data(line_s_data),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x),
        .dma_wr_fy(dma_wr_fy), .dma_wr_data(dma_wr_data),
        .dma_line_advance(dma_line_advance)
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

    task drive_line_beat;
        input integer x;
        begin
            @(negedge clk);
            line_s_valid = 1'b1;
            for (b = 0; b < 5; b = b + 1)
                line_s_data[b] = 8'h20 + x*5 + b;
            wait(line_s_ready);
            @(negedge clk);
            line_s_valid = 1'b0;
            for (b = 0; b < 5; b = b + 1)
                line_s_data[b] = 8'd0;
        end
    endtask

    always @(posedge clk) begin
        if (!rst && |dma_bank_wr_en) begin
            check(dma_bank_wr_en == 5'b11111, "all IFM banks written per beat");
            check(dma_wr_x == beat_seen[AW-1:0], "IFM x write order");
            check(dma_wr_fy == 10'd5, "IFM fy latched");
            for (b = 0; b < 5; b = b + 1)
                check(dma_wr_data[b] == (8'h20 + beat_seen*5 + b), "IFM bank data order");
            beat_seen = beat_seen + 1;
        end
        if (!rst && dma_line_advance)
            advance_seen = advance_seen + 1;
    end

    integer x;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
        fm_w = FM_W[AW-1:0];
        fill_req = 1'b0;
        fill_fy = 9'd5;
        line_s_valid = 1'b0;
        for (b = 0; b < 5; b = b + 1)
            line_s_data[b] = 8'd0;
        pass = 0;
        fail = 0;
        beat_seen = 0;
        advance_seen = 0;

        repeat (4) @(negedge clk);
        rst = 1'b0;
        check(!line_s_ready, "line ready low before request");

        @(negedge clk);
        fill_req = 1'b1;
        @(negedge clk);
        fill_req = 1'b0;
        check(line_s_ready, "line ready asserted after request");

        drive_line_beat(0);
        repeat (3) @(negedge clk);
        for (x = 1; x < FM_W; x = x + 1)
            drive_line_beat(x);

        @(negedge clk);
        check(beat_seen == FM_W, "all IFM line beats written");
        check(advance_seen == 1, "line advance pulse count");
        check(!line_s_ready, "line ready low after complete row");

        $display("=== %m: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

`timescale 1ns / 1ps

module tb_axis_ifm_line_loader;
    localparam AW = 9;
    localparam FM_W = 6;

    reg clk;
    reg rst;
    reg [AW-1:0] fm_w;
    reg fill_req;
    reg [AW-1:0] fill_fy;
    wire s_axis_tready;
    reg s_axis_tvalid;
    reg [63:0] s_axis_tdata;
    reg [7:0] s_axis_tkeep;
    reg s_axis_tlast;
    wire [4:0] dma_bank_wr_en;
    wire [AW-1:0] dma_wr_x;
    wire [AW:0] dma_wr_fy;
    wire [7:0] dma_wr_data [0:4];
    wire dma_line_advance;
    wire tkeep_error;
    wire tlast_error;

    integer pass;
    integer fail;
    integer beat_seen;
    integer advance_seen;
    integer b;

    axis_ifm_line_loader #(.AW(AW)) dut (
        .clk(clk),
        .rst(rst),
        .fm_w(fm_w),
        .fill_req(fill_req),
        .fill_fy(fill_fy),
        .s_axis_tready(s_axis_tready),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .dma_bank_wr_en(dma_bank_wr_en),
        .dma_wr_x(dma_wr_x),
        .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data),
        .dma_line_advance(dma_line_advance),
        .tkeep_error(tkeep_error),
        .tlast_error(tlast_error)
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

    function [63:0] pack_line_word;
        input integer x;
        begin
            pack_line_word = 64'd0;
            pack_line_word[7:0] = (8'h40 + x*5 + 0) & 8'hff;
            pack_line_word[15:8] = (8'h40 + x*5 + 1) & 8'hff;
            pack_line_word[23:16] = (8'h40 + x*5 + 2) & 8'hff;
            pack_line_word[31:24] = (8'h40 + x*5 + 3) & 8'hff;
            pack_line_word[39:32] = (8'h40 + x*5 + 4) & 8'hff;
        end
    endfunction

    task send_axis_word;
        input integer x;
        input last;
        input [7:0] keep;
        begin
            @(negedge clk);
            s_axis_tvalid = 1'b1;
            s_axis_tdata = pack_line_word(x);
            s_axis_tkeep = keep;
            s_axis_tlast = last;
            wait(s_axis_tready);
            @(negedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tdata = 64'd0;
            s_axis_tkeep = 8'd0;
            s_axis_tlast = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (!rst && |dma_bank_wr_en) begin
            check(dma_bank_wr_en == 5'b11111, "all banks written from AXIS beat");
            check(dma_wr_x == beat_seen[AW-1:0], "AXIS x write order");
            check(dma_wr_fy == 10'd3, "AXIS fy latched");
            for (b = 0; b < 5; b = b + 1)
                check(dma_wr_data[b] == (8'h40 + beat_seen*5 + b), "AXIS bank byte order");
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
        fill_fy = 9'd3;
        s_axis_tvalid = 1'b0;
        s_axis_tdata = 64'd0;
        s_axis_tkeep = 8'd0;
        s_axis_tlast = 1'b0;
        pass = 0;
        fail = 0;
        beat_seen = 0;
        advance_seen = 0;

        repeat (4) @(negedge clk);
        rst = 1'b0;
        check(!s_axis_tready, "AXIS ready low before request");

        @(negedge clk);
        fill_req = 1'b1;
        @(negedge clk);
        fill_req = 1'b0;
        check(s_axis_tready, "AXIS ready asserted after request");

        send_axis_word(0, 1'b0, 8'h1f);
        repeat (2) @(negedge clk);
        for (x = 1; x < FM_W; x = x + 1)
            send_axis_word(x, x == FM_W - 1, 8'h1f);

        @(negedge clk);
        check(beat_seen == FM_W, "all AXIS IFM beats written");
        check(advance_seen == 1, "AXIS line advance pulse count");
        check(!s_axis_tready, "AXIS ready low after row");
        check(!tkeep_error, "no TKEEP error on legal row");
        check(!tlast_error, "no TLAST error on legal row");

        $display("=== %m: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

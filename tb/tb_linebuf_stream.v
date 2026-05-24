`timescale 1ns / 1ps

module tb_linebuf_stream;
    localparam FM_W = 5;
    localparam FM_H = 5;
    localparam AW = 3;

    reg clk, rst;
    reg [4:0] bank_wr_en;
    reg [AW-1:0] wr_x;
    reg [7:0] wr_data [0:4];
    reg line_advance;
    reg [AW:0] wr_fy;
    reg [AW-1:0] rd_x0, rd_x1, rd_x2;
    wire [7:0] rd_data [0:4][0:2][0:2];
    wire [AW:0] line_fy [0:2];
    wire line_valid [0:2];
    wire [1:0] wr_ptr;

    line_buffer_5bank #(.FM_W(FM_W), .AW(AW)) u_lb (
        .clk(clk), .rst(rst),
        .bank_wr_en(bank_wr_en), .wr_x(wr_x), .wr_data(wr_data),
        .line_advance(line_advance), .wr_fy(wr_fy),
        .rd_x0(rd_x0), .rd_x1(rd_x1), .rd_x2(rd_x2),
        .rd_data(rd_data), .line_fy_out(line_fy),
        .line_valid_out(line_valid), .wr_ptr_out(wr_ptr)
    );

    reg [1:0] stride, pad;
    reg [AW-1:0] fm_h, fm_w;
    reg [AW-1:0] oy, ox;
    reg [10:0] base;
    wire [255:0] ifm_data;
    wire ifm_valid, window_ready;

    window_extract #(.FM_W(FM_W), .FM_H(FM_H), .AW(AW)) u_we (
        .fm_h(fm_h), .fm_w(fm_w),
        .stride(stride), .pad(pad), .oy(oy), .ox(ox), .pass_base_k(base),
        .lb_data(rd_data), .line_fy(line_fy), .line_valid(line_valid),
        .lb_valid(1'b1), .ifm_data(ifm_data), .ifm_valid(ifm_valid),
        .window_ready(window_ready)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer i, b;

    task write_row;
        input integer fy;
        begin
            bank_wr_en = 5'b11111;
            wr_fy = fy[AW:0];
            for (i = 0; i < FM_W; i = i + 1) begin
                wr_x = i[AW-1:0];
                for (b = 0; b < 5; b = b + 1)
                    wr_data[b] = b*40 + fy*8 + i;
                @(negedge clk);
            end
            line_advance = 1'b1;
            @(negedge clk);
            line_advance = 1'b0;
            bank_wr_en = 0;
            @(negedge clk);
        end
    endtask

    task check_window;
        input integer cy;
        input integer cx;
        integer lane, ch, ker, ky, kx, exp;
        begin
            oy = cy[AW-1:0];
            ox = cx[AW-1:0];
            rd_x0 = cx;
            rd_x1 = cx + 1;
            rd_x2 = cx + 2;
            #1;
            if (window_ready !== 1'b1 || ifm_valid !== 1'b1) begin
                $display("[FAIL] window (%0d,%0d) not ready valid=%0d ready=%0d", cy, cx, ifm_valid, window_ready);
                fail = fail + 1;
            end else pass = pass + 1;
            for (lane = 0; lane < 32; lane = lane + 1) begin
                ch = lane / 9;
                ker = lane % 9;
                ky = ker / 3;
                kx = ker % 3;
                if (ch < 5) begin
                    exp = ch*40 + (cy + ky)*8 + (cx + kx);
                    if (ifm_data[lane*8 +: 8] !== exp[7:0]) begin
                        $display("[FAIL] window(%0d,%0d) lane%0d got=%0d exp=%0d",
                            cy, cx, lane, ifm_data[lane*8 +: 8], exp);
                        fail = fail + 1;
                    end else pass = pass + 1;
                end
            end
        end
    endtask

    initial begin
        clk = 0; rst = 1; pass = 0; fail = 0;
        bank_wr_en = 0; wr_x = 0; line_advance = 0; wr_fy = 0;
        rd_x0 = 0; rd_x1 = 1; rd_x2 = 2;
        stride = 1; pad = 0; fm_h = FM_H; fm_w = FM_W; oy = 0; ox = 0; base = 0;
        for (b = 0; b < 5; b = b + 1) wr_data[b] = 0;

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        write_row(0);
        write_row(1);
        write_row(2);
        check_window(0, 0);

        write_row(3);
        check_window(1, 0);

        write_row(4);
        check_window(2, 0);

        $display("=== tb_linebuf_stream: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

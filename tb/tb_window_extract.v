`timescale 1ns / 1ps

module tb_window_extract;
    localparam AW = 9;
    reg [AW-1:0] fm_h, fm_w;
    reg [1:0] stride, pad;
    reg [AW-1:0] oy, ox;
    reg [13:0] pass_base_k;
    reg [7:0] lb_data [0:4][0:2][0:2];
    reg [AW:0] line_fy [0:2];
    reg line_valid [0:2];
    reg lb_valid;
    wire [255:0] ifm_data;
    wire ifm_valid;
    wire window_ready;

    window_extract #(.FM_W(416), .FM_H(416), .AW(AW)) dut (
        .fm_h(fm_h), .fm_w(fm_w), .stride(stride), .pad(pad),
        .oy(oy), .ox(ox), .pass_base_k(pass_base_k),
        .lb_data(lb_data), .line_fy(line_fy), .line_valid(line_valid), .lb_valid(lb_valid),
        .ifm_data(ifm_data), .ifm_valid(ifm_valid), .window_ready(window_ready)
    );

    integer pass, fail;
    integer b, l, kx, r;

    function [7:0] exp_lane;
        input integer row;
        integer global_k, ch, ker, ky_i, kx_i, bank_i, fy_i, fx_i, li;
        begin
            global_k = pass_base_k + row;
            ch = global_k / 9;
            ker = global_k % 9;
            ky_i = ker / 3;
            kx_i = ker % 3;
            bank_i = ch % 5;
            fy_i = oy * stride + ky_i - pad;
            fx_i = ox * stride + kx_i - pad;
            li = -1;
            if (line_fy[0] == fy_i) li = 0;
            else if (line_fy[1] == fy_i) li = 1;
            else if (line_fy[2] == fy_i) li = 2;

            if (fy_i < 0 || fy_i >= fm_h || fx_i < 0 || fx_i >= fm_w || li < 0)
                exp_lane = 8'd0;
            else
                exp_lane = lb_data[bank_i][li][kx_i];
        end
    endfunction

    task check_case;
        input [AW-1:0] cy, cx;
        input [1:0] cs, cp;
        input [13:0] base;
        begin
            oy = cy; ox = cx; stride = cs; pad = cp; pass_base_k = base;
            #1;
            if (ifm_valid !== (lb_valid && window_ready)) begin
                $display("[FAIL] valid=%0d exp=%0d", ifm_valid, lb_valid && window_ready);
                fail = fail + 1;
            end else pass = pass + 1;
            for (r = 0; r < 32; r = r + 1) begin
                if (ifm_data[r*8 +: 8] !== exp_lane(r)) begin
                    $display("[FAIL] case oy=%0d ox=%0d stride=%0d pad=%0d base=%0d lane%0d got=%0d exp=%0d",
                        cy, cx, cs, cp, base, r, ifm_data[r*8 +: 8], exp_lane(r));
                    fail = fail + 1;
                end else pass = pass + 1;
            end
        end
    endtask

    initial begin
        pass = 0; fail = 0;
        fm_h = 5; fm_w = 5; lb_valid = 1'b1;
        line_fy[0] = 0; line_fy[1] = 1; line_fy[2] = 2;
        line_valid[0] = 1; line_valid[1] = 1; line_valid[2] = 1;
        for (b = 0; b < 5; b = b + 1)
            for (l = 0; l < 3; l = l + 1)
                for (kx = 0; kx < 3; kx = kx + 1)
                    lb_data[b][l][kx] = b*40 + line_fy[l]*8 + kx;

        check_case(0, 0, 1, 1, 0);   // top-left 3x3 with padding
        check_case(1, 1, 1, 1, 0);   // centered 3x3 with padding
        check_case(0, 0, 2, 0, 0);   // stride 2, no padding
        check_case(1, 1, 1, 0, 4);   // 1x1-style center lane base

        lb_valid = 1'b0;
        check_case(0, 0, 1, 1, 0);

        $display("=== tb_window_extract: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

`timescale 1ns / 1ps

// 3x3 window to unfolded IFM lanes.
module window_extract #(
    parameter FM_W = 416,
    parameter FM_H = 416,
    parameter AW = 9,
    parameter ROWS = 32,
    parameter BANKS = 5
) (
    input  [AW-1:0] fm_h, fm_w,
    input  [1:0]  stride, pad,
    input  [AW-1:0] oy, ox,
    input  [13:0] pass_base_k,
    input  [7:0]  lb_data [0:BANKS-1][0:2][0:2],
    input  [AW:0] line_fy [0:2],
    input         line_valid [0:2],
    input         lb_valid,
    output [ROWS*8-1:0] ifm_data,
    output         ifm_valid,
    output         window_ready
);
    wire signed [AW+1:0] fy0 = $signed({1'b0, oy}) * $signed({{AW{1'b0}}, stride})
                              - $signed({{AW{1'b0}}, pad});
    wire signed [AW+1:0] fy1 = fy0 + 1;
    wire signed [AW+1:0] fy2 = fy0 + 2;

    wire need_fy0 = (fy0 >= 0 && fy0 < $signed({1'b0, fm_h}));
    wire need_fy1 = (fy1 >= 0 && fy1 < $signed({1'b0, fm_h}));
    wire need_fy2 = (fy2 >= 0 && fy2 < $signed({1'b0, fm_h}));
    wire have_fy0 = !need_fy0 ||
                    ((line_valid[0] && line_fy[0] == fy0[AW:0]) ||
                     (line_valid[1] && line_fy[1] == fy0[AW:0]) ||
                     (line_valid[2] && line_fy[2] == fy0[AW:0]));
    wire have_fy1 = !need_fy1 ||
                    ((line_valid[0] && line_fy[0] == fy1[AW:0]) ||
                     (line_valid[1] && line_fy[1] == fy1[AW:0]) ||
                     (line_valid[2] && line_fy[2] == fy1[AW:0]));
    wire have_fy2 = !need_fy2 ||
                    ((line_valid[0] && line_fy[0] == fy2[AW:0]) ||
                     (line_valid[1] && line_fy[1] == fy2[AW:0]) ||
                     (line_valid[2] && line_fy[2] == fy2[AW:0]));

    assign window_ready = have_fy0 && have_fy1 && have_fy2;
    assign ifm_valid = lb_valid && window_ready;

    genvar r;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : row_logic
            wire [13:0] global_k = pass_base_k + r;
            wire [13:0] ch   = global_k / 14'd9;
            wire [3:0]  ker  = global_k % 14'd9;
            wire [1:0]  ky   = ker / 3;
            wire [1:0]  kx   = ker % 3;
            wire [2:0]  bank = ch % BANKS;

            wire signed [AW+1:0] fy = $signed({1'b0, oy}) * $signed({{AW{1'b0}}, stride})
                                     + $signed({{AW{1'b0}}, ky})
                                     - $signed({{AW{1'b0}}, pad});
            wire signed [AW+1:0] fx = $signed({1'b0, ox}) * $signed({{AW{1'b0}}, stride})
                                     + $signed({{AW{1'b0}}, kx})
                                     - $signed({{AW{1'b0}}, pad});

            wire [1:0] line_idx = (line_valid[0] && line_fy[0] == fy[AW:0]) ? 2'd0 :
                                  (line_valid[1] && line_fy[1] == fy[AW:0]) ? 2'd1 :
                                  (line_valid[2] && line_fy[2] == fy[AW:0]) ? 2'd2 : 2'd0;

            wire in_bounds = (fy >= 0 && fy < $signed({1'b0, fm_h}) &&
                              fx >= 0 && fx < $signed({1'b0, fm_w}));
            wire fy_match  = ((line_valid[0] && line_fy[0] == fy[AW:0]) ||
                              (line_valid[1] && line_fy[1] == fy[AW:0]) ||
                              (line_valid[2] && line_fy[2] == fy[AW:0]));
            wire valid_row = in_bounds && fy_match;

            wire [7:0] row_val = valid_row ? lb_data[bank][line_idx][kx] : 8'd0;
            assign ifm_data[(r+1)*8-1 : r*8] = row_val;
        end
    endgenerate
endmodule

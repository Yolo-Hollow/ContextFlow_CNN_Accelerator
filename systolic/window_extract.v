`timescale 1ns / 1ps
// 3x3 sliding window → 32 IFM values per cycle
// lb_data: [bank][line][kx] from line_buffer_5bank (3-port)
// pass_base_k → row → (ch,ker) → (bank, fy_line, kx) → IFM row value
module window_extract #(
    parameter FM_W = 416, FM_H = 416, AW = 9
) (
    input  [1:0]  stride, pad,
    input  [AW-1:0] oy, ox,
    input  [10:0] pass_base_k,
    input  [7:0]  lb_data [0:4][0:2][0:2],  // [bank][line][kx]
    input  [AW:0] line_fy [0:2],            // physical line → IFM row
    input         lb_valid,
    output reg [255:0] ifm_data,
    output reg         ifm_valid
);
    integer row;
    integer ch, ker, ky, kx, bank, fy, fx, line_idx;

    always @(*) begin
        ifm_valid = lb_valid;
        ifm_data  = 256'd0;

        for (row = 0; row < 32; row = row + 1) begin
            ch   = (pass_base_k + row) / 9;
            ker  = (pass_base_k + row) % 9;
            ky   = ker / 3;
            kx   = ker % 3;
            bank = ch % 5;

            fy = oy * stride + ky - pad;
            fx = ox * stride + kx - pad;

            // Map fy to physical line via lookup
            line_idx = (line_fy[0] == fy) ? 0 :
                       (line_fy[1] == fy) ? 1 :
                       (line_fy[2] == fy) ? 2 : 0;

            if (fy >= 0 && fy < FM_H && fx >= 0 && fx < FM_W &&
                (line_fy[0] == fy || line_fy[1] == fy || line_fy[2] == fy))
                ifm_data[row*8 +: 8] = lb_data[bank][line_idx][kx];
            else
                ifm_data[row*8 +: 8] = 8'd0;
        end
    end
endmodule

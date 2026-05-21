`timescale 1ns / 1ps
// Window extractor: 3×3 sliding window → 32 IFM values per cycle
// Takes line buffer output (5 banks × 3 lines × 3 kernel cols = 45 values)
// Produces 256-bit IFM FIFO write data (32 × 8-bit)
module window_extract #(
    parameter FM_W = 416, FM_H = 416,
    parameter AW = 9
) (
    // Layer config
    input  [1:0] stride, pad,
    input  [1:0] k_h, k_w,
    // Output pixel position
    input  [AW-1:0] oy, ox,
    // Pass control: which kernel positions to process
    input  [10:0] pass_base_k,
    // Line buffer data: [bank][line][kx] — 5×3×3 = 45 values
    input  [7:0]  lb_data [0:4][0:2][0:2],
    input         lb_valid,
    // IFM FIFO output
    output reg [255:0] ifm_data,
    output reg         ifm_valid
);
    // Kernel position to IFM row mapping
    // 3×3 kernel: 9 positions per channel, 32 rows = up to 3.5 channels/pass
    integer row, ch, ker, ky, kx, bank, fy, fx;
    reg [7:0] val;

    always @(*) begin
        ifm_valid = lb_valid;
        ifm_data = 256'd0;

        for (row = 0; row < 32; row = row + 1) begin
            ch  = (pass_base_k + row) / 9;         // 0..3 per pass
            ker = (pass_base_k + row) % 9;         // 0..8
            ky  = ker / 3;                          // 0..2
            kx  = ker % 3;                          // 0..2
            bank = ch % 5;

            fy = oy * stride + ky - pad;
            fx = ox * stride + kx - pad;

            if (fy >= 0 && fy < FM_H && fx >= 0 && fx < FM_W)
                val = lb_data[bank][fy % 3][kx];
            else
                val = 8'd0;  // padding

            ifm_data[(row+1)*8-1 -: 8] = val;
        end
    end
endmodule

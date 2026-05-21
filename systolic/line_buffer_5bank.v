`timescale 1ns / 1ps
// 5-bank × 3-line streaming line buffer for 3×3 convolution
// DMA writes 5 banks simultaneously at same x position (different channels)
// Window reads 5 banks × 3 lines each = 15 values per read
module line_buffer_5bank #(
    parameter FM_W = 416,      // max feature map width
    parameter AW   = 9         // clog2(FM_W)
) (
    input  clk, rst,
    // DMA write interface (40-bit: 5 banks × 8-bit per cycle)
    input  [4:0]  bank_wr_en,        // per-bank write enable
    input  [AW-1:0] wr_x,             // x position (column address)
    input  [7:0]  wr_data [0:4],     // data per bank (5 × 8-bit)
    input         line_advance,       // pulse: advance to next row (wr_ptr++)
    // Window read interface (5 banks × 24-bit = 3 lines × 8-bit per bank)
    input  [AW-1:0] rd_x,             // x position to read
    output [7:0] rd_data [0:4][0:2]  // [bank][line] = 5×3 = 15 values
);
    // Per-bank: 3 lines × BRAM (512×8 or FM_W×8)
    // wr_ptr: which physical line gets written by DMA
    reg [1:0] wr_ptr;  // 0,1,2 rotating

    always @(posedge clk) begin
        if (rst)           wr_ptr <= 2'd0;
        else if (line_advance) wr_ptr <= (wr_ptr + 1) % 3;
    end

    genvar b, l;
    generate
        for (b = 0; b < 5; b = b + 1) begin : bank
            for (l = 0; l < 3; l = l + 1) begin : line
                // Simple reg-based line buffer (BRAM18 in real implementation)
                reg [7:0] line_mem [0:FM_W-1];
                integer i;

                // Write: only when this line is the active write target
                wire this_line_wr = (wr_ptr == l[1:0]);
                always @(posedge clk) begin
                    if (bank_wr_en[b] && this_line_wr)
                        line_mem[wr_x] <= wr_data[b];
                end

                // Read: combinational (BRAM read in real implementation)
                assign rd_data[b][l] = line_mem[rd_x];
            end
        end
    endgenerate
endmodule

`timescale 1ns / 1ps
// 5-bank x 3-line line buffer for 3x3 convolution
// 3 BRAM copies per line for 3 concurrent read ports (kx=0,1,2 → fx)
// DMA writes all 3 copies simultaneously
module line_buffer_5bank #(
    parameter FM_W = 416, AW = 9
) (
    input  clk, rst,
    input  [4:0]      bank_wr_en,
    input  [AW-1:0]   wr_x,
    input  [7:0]      wr_data [0:4],
    input             line_advance,
    input  [AW:0]     wr_fy,              // IFM row being written
    // 3 read ports for 3 kernel columns
    input  [AW-1:0]   rd_x0, rd_x1, rd_x2,
    output [7:0]      rd_data [0:4][0:2][0:2],  // [bank][line][kx]
    output [AW:0]     line_fy_out [0:2]          // physical line → IFM row map
);
    reg [1:0]  wr_ptr;
    reg [AW:0] line_fy [0:2];   // line_fy[phys_line] = IFM row stored there
    reg [AW:0] prev_fy;          // previous wr_fy, to detect change

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 2'd0; prev_fy <= -1;
            line_fy[0] <= -1; line_fy[1] <= -1; line_fy[2] <= -1;
        end else begin
            // Update line_fy every cycle: current line has wr_fy
            line_fy[wr_ptr] <= wr_fy;
            if (line_advance)
                wr_ptr <= (wr_ptr + 1) % 3;
        end
    end

    assign line_fy_out[0] = line_fy[0];
    assign line_fy_out[1] = line_fy[1];
    assign line_fy_out[2] = line_fy[2];

    genvar b, l;
    generate
        for (b = 0; b < 5; b = b + 1) begin : bank
            for (l = 0; l < 3; l = l + 1) begin : line
                reg [7:0] m0 [0:FM_W-1];
                reg [7:0] m1 [0:FM_W-1];
                reg [7:0] m2 [0:FM_W-1];
                wire we = bank_wr_en[b] && (wr_ptr == l[1:0]);
                always @(posedge clk) if (we) begin
                    m0[wr_x] <= wr_data[b];
                    m1[wr_x] <= wr_data[b];
                    m2[wr_x] <= wr_data[b];
                end
                assign rd_data[b][l][0] = m0[rd_x0];
                assign rd_data[b][l][1] = m1[rd_x1];
                assign rd_data[b][l][2] = m2[rd_x2];
            end
        end
    endgenerate
endmodule

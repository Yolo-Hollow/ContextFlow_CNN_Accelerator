`timescale 1ns / 1ps

// Parameterized bank x 3-line line buffer for 3x3 convolution.
// Each physical line has three read copies so kx=0/1/2 can be read in parallel.
module line_buffer_5bank #(
    parameter FM_W = 416,
    parameter AW = 9,
    parameter BANKS = 5
) (
    input  clk, rst,
    input  [BANKS-1:0] bank_wr_en,
    input  [AW-1:0]   wr_x,
    input  [7:0]      wr_data [0:BANKS-1],
    input             line_advance,
    input  [AW:0]     wr_fy,
    input  [AW-1:0]   rd_x0, rd_x1, rd_x2,
    output [7:0]      rd_data [0:BANKS-1][0:2][0:2],
    output [AW:0]     line_fy_out [0:2],
    output            line_valid_out [0:2],
    output [1:0]      wr_ptr_out
);
    reg [1:0]  wr_ptr;
    reg [AW:0] line_fy [0:2];
    reg        line_valid [0:2];
    integer li;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 2'd0;
            line_fy[0] <= {AW+1{1'b1}};
            line_fy[1] <= {AW+1{1'b1}};
            line_fy[2] <= {AW+1{1'b1}};
            line_valid[0] <= 1'b0;
            line_valid[1] <= 1'b0;
            line_valid[2] <= 1'b0;
        end else begin
            if (|bank_wr_en) begin
                for (li = 0; li < 3; li = li + 1) begin
                    if (line_fy[li] == wr_fy)
                        line_valid[li] <= 1'b0;
                end
                line_fy[wr_ptr] <= wr_fy;
                line_valid[wr_ptr] <= 1'b0;
            end
            if (line_advance) begin
                for (li = 0; li < 3; li = li + 1) begin
                    if ((li[1:0] != wr_ptr) && (line_fy[li] == wr_fy))
                        line_valid[li] <= 1'b0;
                end
                line_fy[wr_ptr] <= wr_fy;
                line_valid[wr_ptr] <= 1'b1;
                wr_ptr <= (wr_ptr == 2'd2) ? 2'd0 : wr_ptr + 2'd1;
            end
        end
    end

    assign line_fy_out[0] = line_fy[0];
    assign line_fy_out[1] = line_fy[1];
    assign line_fy_out[2] = line_fy[2];
    assign line_valid_out[0] = line_valid[0];
    assign line_valid_out[1] = line_valid[1];
    assign line_valid_out[2] = line_valid[2];
    assign wr_ptr_out = wr_ptr;

    genvar b, l;
    generate
        for (b = 0; b < BANKS; b = b + 1) begin : bank
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

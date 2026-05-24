`timescale 1ns / 1ps

// Two-bank PSUM storage for K-tile feedback.
// The scheduler chooses which bank to read and which bank to write.
module psum_pingpong_buffer #(
    parameter DATA_W = 256,
    parameter DEPTH  = 16,
    parameter AW     = 4
) (
    input  clk,
    input  rst,

    input              wr_en,
    input              wr_bank,
    input  [AW-1:0]    wr_addr,
    input  [DATA_W-1:0] wr_data,

    input              rd_en,
    input              rd_bank,
    input  [AW-1:0]    rd_addr,
    output reg [DATA_W-1:0] rd_data,
    output reg         rd_valid
);
    reg [DATA_W-1:0] bank0 [0:DEPTH-1];
    reg [DATA_W-1:0] bank1 [0:DEPTH-1];

    always @(posedge clk) begin
        if (wr_en) begin
            if (wr_bank) bank1[wr_addr] <= wr_data;
            else         bank0[wr_addr] <= wr_data;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            rd_data <= {DATA_W{1'b0}};
            rd_valid <= 1'b0;
        end else begin
            rd_valid <= rd_en;
            if (rd_en) begin
                rd_data <= rd_bank ? bank1[rd_addr] : bank0[rd_addr];
            end
        end
    end
endmodule

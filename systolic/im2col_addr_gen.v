`timescale 1ns / 1ps
// IFM address generator — produces sequential addresses for im2col-reorganized data
// Assumes IFM RAM is pre-filled with im2col layout by HLS preprocess / offline Python
// one entry = one output pixel = 32 IFM values packed as 256-bit
module im2col_addr_gen #(
    parameter AW = 12,         // address width (supports up to 4096 pixels)
    parameter PIXEL_W = 12     // max output pixels per tile
) (
    input  clk, rst,
    input  [PIXEL_W-1:0] num_pixels,  // ofm_h * ofm_w (e.g. 64 for 8x8)
    input  start,
    output reg done,
    output reg rd_en,
    output reg [AW-1:0] rd_addr
);
    localparam IDLE=0, RUN=1, DONE_S=2;
    reg [1:0] state;
    reg [PIXEL_W-1:0] count;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE; count <= 0; rd_en <= 0; rd_addr <= 0; done <= 0;
        end else case (state)
            IDLE: begin
                done <= 0; count <= 0;
                if (start) begin
                    rd_en <= 1; rd_addr <= 0; state <= RUN;
                end
            end
            RUN: begin
                if (count < num_pixels - 1) begin
                    count <= count + 1;
                    rd_addr <= rd_addr + 1;
                end else begin
                    rd_en <= 0; done <= 1; state <= DONE_S;
                end
            end
            DONE_S: begin
                done <= 0;
                if (!start) state <= IDLE;
            end
        endcase
    end
endmodule

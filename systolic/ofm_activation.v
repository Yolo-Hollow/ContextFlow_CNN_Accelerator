`timescale 1ns / 1ps
// Packet-level INT8 activation.
// mode:
//   0: bypass
//   1: ReLU signed INT8 clamp negative to 0
//   2: Leaky LUT, using unsigned byte lookup
module ofm_activation #(
    parameter COUT_TILE = 64,
    parameter ADDR_W = 10
) (
    input  clk,
    input  rst,
    input  [1:0] mode,

    input                       in_valid,
    output                      in_ready,
    input  [ADDR_W-1:0]         in_addr,
    input  [10:0]               in_cout_base,
    input  [COUT_TILE-1:0]      in_channel_valid,
    input  [COUT_TILE*8-1:0]    in_data,

    input        lut_wr_en,
    input  [7:0] lut_wr_addr,
    input  [7:0] lut_wr_data,

    output reg                  out_valid,
    input                       out_ready,
    output reg [ADDR_W-1:0]     out_addr,
    output reg [10:0]           out_cout_base,
    output reg [COUT_TILE-1:0]  out_channel_valid,
    output reg [COUT_TILE*8-1:0] out_data
);
    wire can_advance = !out_valid || out_ready;
    assign in_ready = can_advance;

    genvar lane;
    generate
        for (lane = 0; lane < COUT_TILE; lane = lane + 1) begin : lut_gen
            wire [7:0] lut_out;
            wire signed [7:0] in_lane_signed = in_data[lane*8 +: 8];
            leaky_lut u_lut (
                .clk(clk),
                .wr_en(lut_wr_en),
                .wr_addr(lut_wr_addr),
                .wr_data(lut_wr_data),
                .data_in(in_data[lane*8 +: 8]),
                .data_out(lut_out)
            );

            always @(posedge clk) begin
                if (rst) begin
                    out_data[lane*8 +: 8] <= 8'd0;
                end else if (can_advance && in_valid) begin
                    if (mode == 2'd2)
                        out_data[lane*8 +: 8] <= lut_out;
                    else if (mode == 2'd1 && in_lane_signed < 0)
                        out_data[lane*8 +: 8] <= 8'd0;
                    else
                        out_data[lane*8 +: 8] <= in_data[lane*8 +: 8];
                end
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            out_addr <= {ADDR_W{1'b0}};
            out_cout_base <= 11'd0;
            out_channel_valid <= {COUT_TILE{1'b0}};
        end else if (can_advance) begin
            out_valid <= in_valid;
            if (in_valid) begin
                out_addr <= in_addr;
                out_cout_base <= in_cout_base;
                out_channel_valid <= in_channel_valid;
            end
        end
    end
endmodule

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
    output [COUT_TILE*8-1:0]    out_data
);
    reg [COUT_TILE*8-1:0] bypass_relu_data;
    reg [COUT_TILE*8-1:0] leaky_data_r;
    reg [1:0] mode_r;
    reg [ADDR_W-1:0] addr_r;
    reg [10:0] cout_base_r;
    reg [COUT_TILE-1:0] mask_r;
    reg valid_r;
    wire can_advance = !out_valid || out_ready;
    assign in_ready = can_advance;

    genvar lane;
    generate
        for (lane = 0; lane < COUT_TILE; lane = lane + 1) begin : lut_gen
            wire [7:0] lut_out;
            leaky_lut u_lut (
                .clk(clk),
                .wr_en(lut_wr_en),
                .wr_addr(lut_wr_addr),
                .wr_data(lut_wr_data),
                .data_in(in_data[lane*8 +: 8]),
                .data_out(lut_out)
            );
            assign out_data[lane*8 +: 8] =
                (mode_r == 2'd2) ? leaky_data_r[lane*8 +: 8] : bypass_relu_data[lane*8 +: 8];

            always @(posedge clk) begin
                if (!rst && can_advance && in_valid)
                    leaky_data_r[lane*8 +: 8] <= lut_out;
            end
        end
    endgenerate

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            out_addr <= {ADDR_W{1'b0}};
            out_cout_base <= 11'd0;
            out_channel_valid <= {COUT_TILE{1'b0}};
            bypass_relu_data <= {COUT_TILE*8{1'b0}};
            mode_r <= 2'd0;
            addr_r <= {ADDR_W{1'b0}};
            cout_base_r <= 11'd0;
            mask_r <= {COUT_TILE{1'b0}};
            valid_r <= 1'b0;
        end else if (can_advance) begin
            valid_r <= in_valid;
            if (in_valid) begin
                mode_r <= mode;
                addr_r <= in_addr;
                cout_base_r <= in_cout_base;
                mask_r <= in_channel_valid;
                for (i = 0; i < COUT_TILE; i = i + 1) begin
                    if (mode == 2'd1 && $signed(in_data[i*8 +: 8]) < 0)
                        bypass_relu_data[i*8 +: 8] <= 8'd0;
                    else
                        bypass_relu_data[i*8 +: 8] <= in_data[i*8 +: 8];
                end
            end

            out_valid <= valid_r;
            out_addr <= addr_r;
            out_cout_base <= cout_base_r;
            out_channel_valid <= mask_r;
        end
    end
endmodule

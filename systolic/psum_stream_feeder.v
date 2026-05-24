`timescale 1ns / 1ps

// Converts per-pixel compute_fire events into aligned psum_top stream data.
// For first K tile, bias is delayed one cycle to align with IFM FIFO data.
// For later K tiles, compute_fire issues a ping-pong read and forwards the
// one-cycle-later rd_data/rd_valid.
module psum_stream_feeder #(
    parameter DATA_W = 256,
    parameter AW     = 4
) (
    input  clk,
    input  rst,
    input  start,
    input  compute_fire,

    input  is_first_pass,
    input  use_ext_psum,
    input  [DATA_W-1:0] bias_data,

    input  rd_bank,
    output rd_en,
    output rd_bank_out,
    output [AW-1:0] rd_addr,
    input  [DATA_W-1:0] rd_data,
    input  rd_valid,

    output [DATA_W-1:0] psum_top_data,
    output psum_top_valid,
    output reg [AW-1:0] pixel_addr
);
    reg compute_fire_d;
    reg [DATA_W-1:0] bias_data_d;
    wire ext_mode = use_ext_psum && !is_first_pass;

    assign rd_en = compute_fire && ext_mode;
    assign rd_bank_out = rd_bank;
    assign rd_addr = pixel_addr;
    assign psum_top_data = ext_mode ? rd_data : bias_data_d;
    assign psum_top_valid = ext_mode ? rd_valid : compute_fire_d;

    always @(posedge clk) begin
        if (rst) begin
            pixel_addr <= {AW{1'b0}};
        end else if (start) begin
            pixel_addr <= {AW{1'b0}};
        end else if (compute_fire) begin
            pixel_addr <= pixel_addr + {{(AW-1){1'b0}}, 1'b1};
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            compute_fire_d <= 1'b0;
            bias_data_d <= {DATA_W{1'b0}};
        end else begin
            compute_fire_d <= compute_fire;
            bias_data_d <= bias_data;
        end
    end
endmodule

`timescale 1ns / 1ps
// LeakyReLU lookup table: 256×8-bit distributed RAM, combinational read
// Pre-computed by Python quant flow: out = (in >= zp) ? in : zp + round((in-zp)*0.1)
module leaky_lut (
    input  clk,
    // Write port (load once per layer)
    input        wr_en,
    input  [7:0] wr_addr, wr_data,
    // Read port (combinational)
    input  [7:0] data_in,
    output [7:0] data_out
);
    reg [7:0] lut [0:255];

    always @(posedge clk) begin
        if (wr_en) lut[wr_addr] <= wr_data;
    end

    assign data_out = lut[data_in];
endmodule

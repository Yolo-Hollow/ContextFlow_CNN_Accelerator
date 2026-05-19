`timescale 1ns / 1ps
// INT8 requantization: 24-bit psum → INT8 OFM
// Pipeline: multiply (1 cycle) → shift + zp + clamp (1 cycle) = 2 cycles
module requant #(
    parameter PSUM_W = 24,
    parameter MULT_W = 16,
    parameter SHIFT_W = 4,
    parameter ZP_W    = 8
) (
    input  clk, rst,
    // per-channel config
    input  [MULT_W-1:0]  mult0, mult1,
    input  [SHIFT_W-1:0] shift0, shift1,
    input  [ZP_W-1:0]    zp_out0, zp_out1,
    // streaming I/O
    input  signed [PSUM_W-1:0] psuma_in, psumb_in,
    input                      valid_in,
    output signed [7:0]        ofm_a, ofm_b,
    output                     valid_out
);
    // ---- Stage 1: multiply ----
    // psum (24b signed) × mult (16b unsigned) → 40b signed product
    // In hardware: DSP48E2 does signed(24b) × unsigned(16b) natively
    wire signed [PSUM_W:0] psuma_s = {psuma_in[PSUM_W-1], psuma_in};
    wire signed [PSUM_W:0] psumb_s = {psumb_in[PSUM_W-1], psumb_in};
    wire signed [PSUM_W+MULT_W:0] prod_a = psuma_s * $signed({1'b0, mult0});
    wire signed [PSUM_W+MULT_W:0] prod_b = psumb_s * $signed({1'b0, mult1});

    reg signed [PSUM_W+MULT_W:0] prod_a_r, prod_b_r;
    reg valid_r1;
    always @(posedge clk) begin
        if (rst) begin
            prod_a_r <= 0; prod_b_r <= 0; valid_r1 <= 0;
        end else begin
            prod_a_r <= prod_a;
            prod_b_r <= prod_b;
            valid_r1 <= valid_in;
        end
    end

    // ---- Stage 2: shift + zp + clamp ----
    // (prod >> shift) + zp, then clamp to INT8 [-128, 127]
    wire signed [39:0] shifted_a = prod_a_r >>> shift0;
    wire signed [39:0] shifted_b = prod_b_r >>> shift1;
    wire signed [39:0] result_a = shifted_a + $signed({1'b0, zp_out0});
    wire signed [39:0] result_b = shifted_b + $signed({1'b0, zp_out1});

    // Clamp to INT8
    function [7:0] clamp_int8;
        input signed [39:0] val;
        begin
            if (val > 127)       clamp_int8 = 8'd127;
            else if (val < -128)  clamp_int8 = 8'd128;  // -128 in signed 8-bit
            else                  clamp_int8 = val[7:0];
        end
    endfunction

    reg signed [7:0] ofm_a_r, ofm_b_r;
    reg valid_r2;
    always @(posedge clk) begin
        if (rst) begin
            ofm_a_r <= 0; ofm_b_r <= 0; valid_r2 <= 0;
        end else begin
            ofm_a_r <= clamp_int8(result_a);
            ofm_b_r <= clamp_int8(result_b);
            valid_r2 <= valid_r1;
        end
    end

    assign ofm_a    = ofm_a_r;
    assign ofm_b    = ofm_b_r;
    assign valid_out = valid_r2;
endmodule

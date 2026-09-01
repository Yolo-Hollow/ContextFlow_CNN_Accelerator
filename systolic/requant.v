`timescale 1ns / 1ps
// INT8 requantization: PSUM -> INT8 OFM, 3-cycle elastic pipeline.
//
// Every stage shares ce.  A downstream stall therefore freezes data,
// per-packet quantization parameters and valid state together while still
// allowing one result per clock when ce remains asserted.
module requant #(
    parameter PSUM_W = 32, MULT_W = 16, SHIFT_W = 4, ZP_W = 8
) (
    input  clk, rst,
    input  [MULT_W-1:0]  mult0, mult1,
    input  [SHIFT_W-1:0] shift0, shift1,
    input  [ZP_W-1:0]    zp_out0, zp_out1,
    input  signed [PSUM_W-1:0] psuma_in, psumb_in,
    input                      valid_in,
    input                      ce,
    output signed [7:0]        ofm_a, ofm_b,
    output                     valid_out
);
    localparam PROD_W = PSUM_W + MULT_W + 1;
    localparam [SHIFT_W:0] MULT_FRAC_BITS = 5'd15;

    // Sign-extend to full width BEFORE multiply. Using a signed wire
    // assignment naturally sign-extends (no $signed hack needed).
    wire signed [PROD_W:0] se_a = psuma_in;
    wire signed [PROD_W:0] se_b = psumb_in;
    wire signed [MULT_W:0] ms0  = $signed({1'b0, mult0});
    wire signed [MULT_W:0] ms1  = $signed({1'b0, mult1});

    // ---- Stage 1: multiply and capture the matching quant parameters ----
    reg signed [PROD_W:0] prod0_r, prod1_r;
    reg [SHIFT_W:0] effective_shift0_r1, effective_shift1_r1;
    reg [ZP_W-1:0] zp_out0_r1, zp_out1_r1;
    reg valid_r1;
    always @(posedge clk) begin
        if (rst) begin
            prod0_r <= 0;
            prod1_r <= 0;
            effective_shift0_r1 <= 0;
            effective_shift1_r1 <= 0;
            zp_out0_r1 <= 0;
            zp_out1_r1 <= 0;
            valid_r1 <= 0;
        end else if (ce) begin
            prod0_r <= se_a * ms0;
            prod1_r <= se_b * ms1;
            effective_shift0_r1 <= {1'b0, shift0} + MULT_FRAC_BITS;
            effective_shift1_r1 <= {1'b0, shift1} + MULT_FRAC_BITS;
            zp_out0_r1 <= zp_out0;
            zp_out1_r1 <= zp_out1;
            valid_r1 <= valid_in;
        end
    end

    // ---- Stage 2: rounding add ----
    // Software stores mult = round(base * 2^15), so the actual right shift
    // is the configured frexp shift plus 15 fractional multiplier bits.
    wire signed [PROD_W:0] round_one = {{PROD_W{1'b0}}, 1'b1};
    wire signed [PROD_W:0] round0_r1 =
        round_one <<< (effective_shift0_r1 - 1'b1);
    wire signed [PROD_W:0] round1_r1 =
        round_one <<< (effective_shift1_r1 - 1'b1);

    reg signed [PROD_W:0] rounded0_r, rounded1_r;
    reg [SHIFT_W:0] effective_shift0_r2, effective_shift1_r2;
    reg [ZP_W-1:0] zp_out0_r2, zp_out1_r2;
    reg valid_r2;
    always @(posedge clk) begin
        if (rst) begin
            rounded0_r <= 0;
            rounded1_r <= 0;
            effective_shift0_r2 <= 0;
            effective_shift1_r2 <= 0;
            zp_out0_r2 <= 0;
            zp_out1_r2 <= 0;
            valid_r2 <= 0;
        end else if (ce) begin
            if (valid_r1) begin
                rounded0_r <= prod0_r + round0_r1;
                rounded1_r <= prod1_r + round1_r1;
                effective_shift0_r2 <= effective_shift0_r1;
                effective_shift1_r2 <= effective_shift1_r1;
                zp_out0_r2 <= zp_out0_r1;
                zp_out1_r2 <= zp_out1_r1;
            end
            valid_r2 <= valid_r1;
        end
    end

    // ---- Stage 3: shift + zero point + clamp ----
    reg signed [7:0] ofm_a_r, ofm_b_r;
    reg valid_r3;
    always @(posedge clk) begin
        if (rst) begin
            ofm_a_r <= 0;
            ofm_b_r <= 0;
            valid_r3 <= 0;
        end else if (ce) begin
            if (valid_r2) begin
                ofm_a_r <= clamp8(
                    (rounded0_r >>> effective_shift0_r2) +
                    $signed({1'b0, zp_out0_r2}));
                ofm_b_r <= clamp8(
                    (rounded1_r >>> effective_shift1_r2) +
                    $signed({1'b0, zp_out1_r2}));
            end
            valid_r3 <= valid_r2;
        end
    end

    // Clamp to signed 8-bit [-128, 127]
    function signed [7:0] clamp8;
        input signed [PROD_W:0] v;
        if (v > 127)       clamp8 = 8'sd127;
        else if (v < -128)  clamp8 = -8'sd128;
        else                clamp8 = v[7:0];
    endfunction

    assign ofm_a    = ofm_a_r;
    assign ofm_b    = ofm_b_r;
    assign valid_out = valid_r3;
endmodule

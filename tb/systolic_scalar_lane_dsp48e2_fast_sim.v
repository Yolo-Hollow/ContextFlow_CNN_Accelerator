`timescale 1ns / 1ps

// XSIM-only behavioral equivalent of one scalar DSP48E2 PCIN/PCOUT cascade.
// This file is deliberately absent from the canonical synthesizable manifest;
// an OOC or BD build that accidentally defines CONV_ACCEL_FAST_XSIM_DSP must
// therefore fail elaboration instead of replacing the primitive hierarchy.
//
// The model keeps the primitive chain's MREG, row-zero CREG, and PREG timing:
//
//   m_q[r]     <= signed(ifm[r]) * signed(weight[r])
//   pcout_q[0] <= m_q[0] + seed_q
//   pcout_q[r] <= m_q[r] + pcout_q[r-1]
//
// Arithmetic is 48-bit at every hop and the external result retains the low
// 32 bits, preserving modulo-2^32 PSUM behavior.
module systolic_scalar_lane_dsp48e2_fast_sim #(
    parameter integer ROWS     = 18,
    parameter integer IFM_W    = 8,
    parameter integer WEIGHT_W = 8,
    parameter integer PSUM_W   = 32
) (
    input  wire                             clk,
    input  wire [ROWS*IFM_W-1:0]            ifm_rows_aligned_flat,
    input  wire [ROWS*WEIGHT_W-1:0]         weight_rows_aligned_flat,
    input  wire signed [PSUM_W-1:0]         seed_psum,
    output wire signed [PSUM_W-1:0]         result
);
    reg signed [47:0] m_q [0:ROWS-1];
    reg signed [47:0] pcout_q [0:ROWS-1];
    reg signed [47:0] seed_q;
    integer row;
    reg signed [15:0] product_value;

    always @(posedge clk) begin
        seed_q <= {{(48-PSUM_W){seed_psum[PSUM_W-1]}}, seed_psum};
        for (row = 0; row < ROWS; row = row + 1) begin
            product_value =
                $signed(ifm_rows_aligned_flat[row*IFM_W +: IFM_W]) *
                $signed(weight_rows_aligned_flat[
                    row*WEIGHT_W +: WEIGHT_W]);
            m_q[row] <= {{32{product_value[15]}}, product_value};
        end
        pcout_q[0] <= m_q[0] + seed_q;
        for (row = 1; row < ROWS; row = row + 1)
            pcout_q[row] <= m_q[row] + pcout_q[row-1];
    end

    assign result = pcout_q[ROWS-1][PSUM_W-1:0];
endmodule

`timescale 1ns / 1ps

// Pure arithmetic lane for one output channel.  The enclosing array owns the
// shared token wave, weight-bank selection, validity and tag pipelines.
// Therefore row r must already receive the IFM byte and selected weight for
// the token that was accepted r clocks after row zero's copy.
//
// For ROWS=18 the exact data-path latency is ROWS+1 = 19 sampled clocks: two
// clocks in row zero (MREG + PREG), followed by one PREG clock for each later
// PCIN/PCOUT stage.  The output appears on the 19th sampling edge, whose edge
// index is input_edge+18.  Low-32-bit output preserves modulo-2^32 PSUM math.
module systolic_scalar_lane_dsp48e2 #(
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
    initial begin
        if (ROWS < 1)
            $error("systolic_scalar_lane_dsp48e2 requires ROWS >= 1");
        if (IFM_W != 8 || WEIGHT_W != 8)
            $error("systolic_scalar_lane_dsp48e2 requires signed int8 operands");
        if (PSUM_W != 32)
            $error("systolic_scalar_lane_dsp48e2 requires a 32-bit PSUM");
    end

    wire signed [47:0] seed_48 =
        {{(48-PSUM_W){seed_psum[PSUM_W-1]}}, seed_psum};
    wire [ROWS*48-1:0] stage_p_flat;
    wire [ROWS*48-1:0] stage_pcout_flat;

    genvar row;
    generate
        for (row = 0; row < ROWS; row = row + 1) begin : row_stage
            wire signed [IFM_W-1:0] row_ifm =
                ifm_rows_aligned_flat[(row+1)*IFM_W-1:row*IFM_W];
            wire signed [WEIGHT_W-1:0] row_weight =
                weight_rows_aligned_flat[(row+1)*WEIGHT_W-1:row*WEIGHT_W];
            wire signed [47:0] row_pcin = (row == 0) ? 48'sd0 :
                stage_pcout_flat[row*48-1:(row-1)*48];
            // Only row zero selects C in OPMODE.  Tie every other C port off
            // explicitly so implementation cannot preserve a 48-bit dynamic
            // seed net across all 576 DSPs merely because the primitive port
            // is present in the source hierarchy.
            wire signed [47:0] row_seed =
                (row == 0) ? seed_48 : 48'sd0;

            dsp48e2_scalar_mac_stage #(
                .FIRST_STAGE(row == 0)
            ) u_mac_stage (
                .clk(clk),
                .ifm_in(row_ifm),
                .weight_in(row_weight),
                .seed_in(row_seed),
                .pcin(row_pcin),
                .p_out(stage_p_flat[(row+1)*48-1:row*48]),
                .pcout(stage_pcout_flat[(row+1)*48-1:row*48])
            );
        end
    endgenerate

    assign result = stage_p_flat[ROWS*48-1:(ROWS-1)*48];
endmodule

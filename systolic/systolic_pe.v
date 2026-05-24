`timescale 1ns / 1ps
// PE: dual-weight stationary + valid propagation (horizontal + vertical)
// valid_in_h: valid from left (accompanies ifm_in)
// valid_out_h: valid to right (accompanies ifm_out), 4-cycle delay
// valid_in_v: valid from above (accompanies psum_in), 5-cycle delay
// valid_out_v: valid to below (accompanies psum_out)
module systolic_pe #(
    parameter IFM_W    = 8,
    parameter WEIGHT_W = 8,
    parameter PSUM_W   = 32,
    parameter PROD_W   = 16
) (
    input  clk, rst,
    input  w_load,
    input  signed [WEIGHT_W-1:0] w0_in, w1_in,
    // IFM + horizontal valid (left → right)
    input  signed [IFM_W-1:0]  ifm_in,
    input                      valid_in_h,
    output signed [IFM_W-1:0]  ifm_out,
    output                     valid_out_h,
    // PSUM + vertical valid (top → bottom), channel A
    input  signed [PSUM_W-1:0] psuma_in,
    input                      valid_in_va,
    output signed [PSUM_W-1:0] psuma_out,
    output                     valid_out_va,
    // PSUM + vertical valid (top → bottom), channel B
    input  signed [PSUM_W-1:0] psumb_in,
    input                      valid_in_vb,
    output signed [PSUM_W-1:0] psumb_out,
    output                     valid_out_vb
);
    localparam SEXT_W = PSUM_W - PROD_W;

    // ---- Weight registers (stationary) ----
    reg signed [WEIGHT_W-1:0] w0_reg, w1_reg;
    always @(posedge clk) begin
        if (rst) begin w0_reg <= {WEIGHT_W{1'b0}}; w1_reg <= {WEIGHT_W{1'b0}}; end
        else if (w_load) begin w0_reg <= w0_in; w1_reg <= w1_in; end
    end

    // ---- IFM + horizontal valid (4-cycle pipeline) ----
    reg signed [IFM_W-1:0] ifm_r0, ifm_r1, ifm_r2, ifm_r3;
    reg valid_h_r0, valid_h_r1, valid_h_r2, valid_h_r3;
    always @(posedge clk) begin
        if (rst) begin
            ifm_r0 <= {IFM_W{1'b0}}; ifm_r1 <= {IFM_W{1'b0}}; ifm_r2 <= {IFM_W{1'b0}}; ifm_r3 <= {IFM_W{1'b0}};
            valid_h_r0 <= 0; valid_h_r1 <= 0; valid_h_r2 <= 0; valid_h_r3 <= 0;
        end else begin
            ifm_r0 <= ifm_in;   ifm_r1 <= ifm_r0;   ifm_r2 <= ifm_r1;   ifm_r3 <= ifm_r2;
            valid_h_r0 <= valid_in_h; valid_h_r1 <= valid_h_r0; valid_h_r2 <= valid_h_r1; valid_h_r3 <= valid_h_r2;
        end
    end
    assign ifm_out     = ifm_r3;
    assign valid_out_h = valid_h_r3;

    // ---- DSP: a=w0, b=w1, c=ifm → ac=w0*ifm, bc=w1*ifm (4-cycle) ----
    wire signed [PROD_W-1:0] prod_a, prod_b;
    cal_mult_int8_x2 u_dsp (
        .clk(clk), .a(w0_reg), .b(w1_reg), .c(ifm_in), .ac(prod_a), .bc(prod_b)
    );

    // ---- PSUM + vertical valid (4-cycle align + 1-cycle accumulate) ----
    reg signed [PSUM_W-1:0] psuma_r0, psuma_r1, psuma_r2, psuma_r3;
    reg signed [PSUM_W-1:0] psumb_r0, psumb_r1, psumb_r2, psumb_r3;
    reg valid_va_r0, valid_va_r1, valid_va_r2, valid_va_r3;
    reg valid_vb_r0, valid_vb_r1, valid_vb_r2, valid_vb_r3;
    always @(posedge clk) begin
        if (rst) begin
            psuma_r0 <= {PSUM_W{1'b0}}; psuma_r1 <= {PSUM_W{1'b0}}; psuma_r2 <= {PSUM_W{1'b0}}; psuma_r3 <= {PSUM_W{1'b0}};
            psumb_r0 <= {PSUM_W{1'b0}}; psumb_r1 <= {PSUM_W{1'b0}}; psumb_r2 <= {PSUM_W{1'b0}}; psumb_r3 <= {PSUM_W{1'b0}};
            valid_va_r0 <= 0; valid_va_r1 <= 0; valid_va_r2 <= 0; valid_va_r3 <= 0;
            valid_vb_r0 <= 0; valid_vb_r1 <= 0; valid_vb_r2 <= 0; valid_vb_r3 <= 0;
        end else begin
            psuma_r0 <= psuma_in;  psuma_r1 <= psuma_r0;  psuma_r2 <= psuma_r1;  psuma_r3 <= psuma_r2;
            psumb_r0 <= psumb_in;  psumb_r1 <= psumb_r0;  psumb_r2 <= psumb_r1;  psumb_r3 <= psumb_r2;
            valid_va_r0 <= valid_in_va; valid_va_r1 <= valid_va_r0; valid_va_r2 <= valid_va_r1; valid_va_r3 <= valid_va_r2;
            valid_vb_r0 <= valid_in_vb; valid_vb_r1 <= valid_vb_r0; valid_vb_r2 <= valid_vb_r1; valid_vb_r3 <= valid_vb_r2;
        end
    end

    // psum valid = (IFM valid, aligned) AND (psuma valid from above)
    wire psuma_valid_aligned = valid_h_r3 && valid_va_r3;
    wire psumb_valid_aligned = valid_h_r3 && valid_vb_r3;

    // Accumulate: only when valid
    wire signed [PSUM_W-1:0] psuma_add = psuma_valid_aligned ?
        (psuma_r3 + {{SEXT_W{prod_a[PROD_W-1]}}, prod_a}) : psuma_r3;
    wire signed [PSUM_W-1:0] psumb_add = psumb_valid_aligned ?
        (psumb_r3 + {{SEXT_W{prod_b[PROD_W-1]}}, prod_b}) : psumb_r3;

    reg signed [PSUM_W-1:0] psuma_out_reg, psumb_out_reg;
    reg valid_va_out_reg, valid_vb_out_reg;
    always @(posedge clk) begin
        if (rst) begin
            psuma_out_reg <= {PSUM_W{1'b0}}; psumb_out_reg <= {PSUM_W{1'b0}};
            valid_va_out_reg <= 0; valid_vb_out_reg <= 0;
        end else begin
            psuma_out_reg <= psuma_add;
            psumb_out_reg <= psumb_add;
            valid_va_out_reg <= psuma_valid_aligned;
            valid_vb_out_reg <= psumb_valid_aligned;
        end
    end
    assign psuma_out    = psuma_out_reg;
    assign psumb_out    = psumb_out_reg;
    assign valid_out_va = valid_va_out_reg;
    assign valid_out_vb = valid_vb_out_reg;
endmodule

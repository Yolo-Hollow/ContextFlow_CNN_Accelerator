`timescale 1ns / 1ps
// PE: dual-weight stationary, 4-cycle IFM passthrough, 5-cycle psum path
// Uses cal_mult_int8_x2 for 2 INT8 MACs per DSP48E (w0*ifm, w1*ifm)
// PSUM_W >= PROD_W + $clog2(max_ifm_channels) to avoid overflow
module systolic_pe #(
    parameter IFM_W    = 8,
    parameter WEIGHT_W = 8,
    parameter PSUM_W   = 24,
    parameter PROD_W   = 16
) (
    input  clk, rst,
    input  w_load,
    input  signed [WEIGHT_W-1:0] w0_in, w1_in,
    input  signed [IFM_W-1:0]    ifm_in,
    output signed [IFM_W-1:0]    ifm_out,
    input  signed [PSUM_W-1:0]   psuma_in, psumb_in,
    output signed [PSUM_W-1:0]   psuma_out, psumb_out
);
    localparam SEXT_W = PSUM_W - PROD_W;

    // weight registers (stationary)
    reg signed [WEIGHT_W-1:0] w0_reg, w1_reg;
    always @(posedge clk) begin
        if (rst) begin
            w0_reg <= {WEIGHT_W{1'b0}};
            w1_reg <= {WEIGHT_W{1'b0}};
        end else if (w_load) begin
            w0_reg <= w0_in;
            w1_reg <= w1_in;
        end
    end

    // IFM 4-cycle shift register
    reg signed [IFM_W-1:0] ifm_r0, ifm_r1, ifm_r2, ifm_r3;
    always @(posedge clk) begin
        if (rst) begin
            ifm_r0 <= {IFM_W{1'b0}};
            ifm_r1 <= {IFM_W{1'b0}};
            ifm_r2 <= {IFM_W{1'b0}};
            ifm_r3 <= {IFM_W{1'b0}};
        end else begin
            ifm_r0 <= ifm_in;
            ifm_r1 <= ifm_r0;
            ifm_r2 <= ifm_r1;
            ifm_r3 <= ifm_r2;
        end
    end
    assign ifm_out = ifm_r3;

    // DSP: a=w0, b=w1, c=ifm → ac=w0*ifm, bc=w1*ifm (4-cycle pipeline)
    wire signed [PROD_W-1:0] prod_a, prod_b;
    cal_mult_int8_x2 u_dsp (
        .clk (clk),
        .a   (w0_reg),
        .b   (w1_reg),
        .c   (ifm_in),
        .ac  (prod_a),
        .bc  (prod_b)
    );

    // psum 4-cycle alignment FIFO
    reg signed [PSUM_W-1:0] psuma_r0, psuma_r1, psuma_r2, psuma_r3;
    reg signed [PSUM_W-1:0] psumb_r0, psumb_r1, psumb_r2, psumb_r3;
    always @(posedge clk) begin
        if (rst) begin
            psuma_r0 <= {PSUM_W{1'b0}}; psuma_r1 <= {PSUM_W{1'b0}};
            psuma_r2 <= {PSUM_W{1'b0}}; psuma_r3 <= {PSUM_W{1'b0}};
            psumb_r0 <= {PSUM_W{1'b0}}; psumb_r1 <= {PSUM_W{1'b0}};
            psumb_r2 <= {PSUM_W{1'b0}}; psumb_r3 <= {PSUM_W{1'b0}};
        end else begin
            psuma_r0 <= psuma_in;  psuma_r1 <= psuma_r0;
            psuma_r2 <= psuma_r1;  psuma_r3 <= psuma_r2;
            psumb_r0 <= psumb_in;  psumb_r1 <= psumb_r0;
            psumb_r2 <= psumb_r1;  psumb_r3 <= psumb_r2;
        end
    end

    // accumulate: psum + sign-extended product
    wire signed [PSUM_W-1:0] psuma_add = psuma_r3 + {{SEXT_W{prod_a[PROD_W-1]}}, prod_a};
    wire signed [PSUM_W-1:0] psumb_add = psumb_r3 + {{SEXT_W{prod_b[PROD_W-1]}}, prod_b};

    reg signed [PSUM_W-1:0] psuma_out_reg, psumb_out_reg;
    always @(posedge clk) begin
        if (rst) begin
            psuma_out_reg <= {PSUM_W{1'b0}};
            psumb_out_reg <= {PSUM_W{1'b0}};
        end else begin
            psuma_out_reg <= psuma_add;
            psumb_out_reg <= psumb_add;
        end
    end
    assign psuma_out = psuma_out_reg;
    assign psumb_out = psumb_out_reg;
endmodule

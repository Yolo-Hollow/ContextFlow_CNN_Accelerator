`timescale 1ns / 1ps

// Fixed-latency systolic PE with two lightweight stationary-weight banks.
//
// Every horizontal IFM token and vertical PSUM token carries the same compact
// mesh-local context tag:
//
//   {weight_bank, context_last}
//
// The tag follows the exact data pipeline.  A vertical result is only marked
// valid when the horizontal and vertical tags match.  Weight-bank epoch
// ownership is checked once at context admission and the full epoch is
// restored after the mesh in systolic_top_tagged.  The PE therefore contains
// only the second weight pair and the bank mux.  There is deliberately no
// local FIFO or ready chain.
module systolic_pe_tagged #(
    parameter IFM_W    = 8,
    parameter WEIGHT_W = 8,
    parameter PSUM_W   = 32,
    parameter PROD_W   = 16,
    parameter EPOCH_W  = 8,
    parameter TAG_W    = 2
) (
    input  wire                         clk,
    input  wire                         rst,

    input  wire                         w_load,
    input  wire                         w_bank,
    input  wire signed [WEIGHT_W-1:0]   w0_in,
    input  wire signed [WEIGHT_W-1:0]   w1_in,

    input  wire signed [IFM_W-1:0]      ifm_in,
    input  wire                         valid_in_h,
    input  wire [TAG_W-1:0]             tag_in_h,
    output wire signed [IFM_W-1:0]      ifm_out,
    output wire                         valid_out_h,
    output wire [TAG_W-1:0]             tag_out_h,

    input  wire signed [PSUM_W-1:0]     psuma_in,
    input  wire                         valid_in_va,
    input  wire signed [PSUM_W-1:0]     psumb_in,
    input  wire                         valid_in_vb,
    input  wire [TAG_W-1:0]             tag_in_v,
    output wire signed [PSUM_W-1:0]     psuma_out,
    output wire                         valid_out_va,
    output wire signed [PSUM_W-1:0]     psumb_out,
    output wire                         valid_out_vb,
    output wire [TAG_W-1:0]             tag_out_v,

    output wire                         tag_mismatch_event,
    output wire                         weight_write_collision_event
);
    localparam SEXT_W = PSUM_W - PROD_W;
    localparam TAG_LAST_BIT = 0;
    localparam TAG_BANK_BIT = 1;

    initial begin
        if (TAG_W != 2)
            $error("systolic_pe_tagged requires the 2-bit {bank,last} mesh tag");
    end

    reg signed [WEIGHT_W-1:0] w0_bank0_q;
    reg signed [WEIGHT_W-1:0] w1_bank0_q;
    reg signed [WEIGHT_W-1:0] w0_bank1_q;
    reg signed [WEIGHT_W-1:0] w1_bank1_q;

    // Weight contents are don't-care until the top-level ownership scoreboard
    // commits a fully loaded bank.  Leaving the payload unreset removes reset
    // from every PE weight register without weakening admission safety.
    always @(posedge clk) begin
        if (w_load) begin
            if (w_bank) begin
                w0_bank1_q <= w0_in;
                w1_bank1_q <= w1_in;
            end else begin
                w0_bank0_q <= w0_in;
                w1_bank0_q <= w1_in;
            end
        end
    end

    wire token_weight_bank = tag_in_h[TAG_BANK_BIT];
    wire signed [WEIGHT_W-1:0] selected_w0 = token_weight_bank ?
        w0_bank1_q : w0_bank0_q;
    wire signed [WEIGHT_W-1:0] selected_w1 = token_weight_bank ?
        w1_bank1_q : w1_bank0_q;

    assign weight_write_collision_event = w_load && valid_in_h &&
        (w_bank == token_weight_bank);

    // IFM/tag valid: two cycles, matching cal_mult_int8_x2_2cycle.
    (* shreg_extract = "no" *)
    reg signed [IFM_W-1:0] ifm_r0, ifm_r1;
    (* shreg_extract = "no" *)
    reg valid_h_r0, valid_h_r1;
    // Tags have no reset and are observed only when valid_h_r1 is asserted.
    // The two-deep tag chain fits in the same CLB FF budget as the payload.
    // Keeping it in FFs avoids consuming one SRL/CLBM lane per tag bit.
    (* shreg_extract = "no" *)
    reg [TAG_W-1:0] tag_h_r0, tag_h_r1;

    // Payload and tag values are masked by the valid pipeline.  Reset only
    // the validity state so active datapath reset still flushes every token,
    // while the wide mesh payload avoids a high-fanout synchronous reset.
    always @(posedge clk) begin
        ifm_r0 <= ifm_in;
        ifm_r1 <= ifm_r0;
        tag_h_r0 <= tag_in_h;
        tag_h_r1 <= tag_h_r0;
    end

    always @(posedge clk) begin
        if (rst) begin
            valid_h_r0 <= 1'b0;
            valid_h_r1 <= 1'b0;
        end else begin
            valid_h_r0 <= valid_in_h;
            valid_h_r1 <= valid_h_r0;
        end
    end

    assign ifm_out = ifm_r1;
    assign valid_out_h = valid_h_r1;
    assign tag_out_h = tag_h_r1;

    wire signed [PROD_W-1:0] prod_a;
    wire signed [PROD_W-1:0] prod_b;
    cal_mult_int8_x2_2cycle u_dsp (
        .clk(clk),
        .a(selected_w0),
        .b(selected_w1),
        .c(ifm_in),
        .ac(prod_a),
        .bc(prod_b)
    );

    // Vertical data/tag alignment: two cycles plus the registered accumulate.
    (* shreg_extract = "no" *)
    reg signed [PSUM_W-1:0] psuma_r0, psuma_r1;
    (* shreg_extract = "no" *)
    reg signed [PSUM_W-1:0] psumb_r0, psumb_r1;
    (* shreg_extract = "no" *)
    reg valid_va_r0, valid_va_r1;
    (* shreg_extract = "no" *)
    reg valid_vb_r0, valid_vb_r1;
    // As on the horizontal path, validity reset flushes the pipeline.  The
    // tag contents deliberately remain reset-free so Vivado can infer SRLs.
    (* shreg_extract = "no" *)
    reg [TAG_W-1:0] tag_v_r0, tag_v_r1;

    always @(posedge clk) begin
        psuma_r0 <= psuma_in;
        psuma_r1 <= psuma_r0;
        psumb_r0 <= psumb_in;
        psumb_r1 <= psumb_r0;
        tag_v_r0 <= tag_in_v;
        tag_v_r1 <= tag_v_r0;
    end

    always @(posedge clk) begin
        if (rst) begin
            valid_va_r0 <= 1'b0;
            valid_va_r1 <= 1'b0;
            valid_vb_r0 <= 1'b0;
            valid_vb_r1 <= 1'b0;
        end else begin
            valid_va_r0 <= valid_in_va;
            valid_va_r1 <= valid_va_r0;
            valid_vb_r0 <= valid_in_vb;
            valid_vb_r1 <= valid_vb_r0;
        end
    end

    wire vertical_valid_aligned = valid_va_r1 || valid_vb_r1;
    wire tags_match_aligned = tag_h_r1 == tag_v_r1;
    assign tag_mismatch_event = valid_h_r1 && vertical_valid_aligned &&
        !tags_match_aligned;

    wire psuma_valid_aligned = valid_h_r1 && valid_va_r1 &&
        tags_match_aligned;
    wire psumb_valid_aligned = valid_h_r1 && valid_vb_r1 &&
        tags_match_aligned;
    wire signed [PSUM_W-1:0] psuma_add = psuma_valid_aligned ?
        (psuma_r1 + {{SEXT_W{prod_a[PROD_W-1]}}, prod_a}) : psuma_r1;
    wire signed [PSUM_W-1:0] psumb_add = psumb_valid_aligned ?
        (psumb_r1 + {{SEXT_W{prod_b[PROD_W-1]}}, prod_b}) : psumb_r1;

    reg signed [PSUM_W-1:0] psuma_out_q;
    reg signed [PSUM_W-1:0] psumb_out_q;
    reg valid_va_out_q;
    reg valid_vb_out_q;
    (* shreg_extract = "no" *)
    reg [TAG_W-1:0] tag_v_out_q;
    always @(posedge clk) begin
        psuma_out_q <= psuma_add;
        psumb_out_q <= psumb_add;
        tag_v_out_q <= tag_v_r1;
    end

    always @(posedge clk) begin
        if (rst) begin
            valid_va_out_q <= 1'b0;
            valid_vb_out_q <= 1'b0;
        end else begin
            valid_va_out_q <= psuma_valid_aligned;
            valid_vb_out_q <= psumb_valid_aligned;
        end
    end

    assign psuma_out = psuma_out_q;
    assign psumb_out = psumb_out_q;
    assign valid_out_va = valid_va_out_q;
    assign valid_out_vb = valid_vb_out_q;
    assign tag_out_v = tag_v_out_q;

    // Referencing this bit documents the compact mesh layout and prevents
    // accidental reinterpretation during maintenance.
    wire unused_tag_last = tag_in_h[TAG_LAST_BIT];
endmodule

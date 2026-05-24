`timescale 1ns / 1ps
// 32x32 weight-stationary systolic array with valid propagation
module systolic_array_32x32 #(
    parameter ROWS = 32, parameter COLS = 32,
    parameter IFM_W = 8, parameter WEIGHT_W = 8, parameter PSUM_W = 32
) (
    input  clk, rst,
    input  w_load, input [4:0] w_col,
    input  [ROWS * WEIGHT_W * 2 - 1 : 0] w_row_data,

    // IFM + horizontal valid (left edge per row)
    input  [ROWS * IFM_W - 1 : 0] ifm_in_flat,
    input  [ROWS-1:0]             valid_h_left,    // valid_in_h for col-0 of each row

    // PSUM + vertical valid (top edge per column)
    input  [COLS * 2 * PSUM_W - 1 : 0] psum_top_flat,
    input  [COLS*2-1:0]                valid_v_top,   // valid_in_v for each slot

    // PSUM outputs + valid
    output [COLS * 2 * PSUM_W - 1 : 0] psum_bot_flat,
    output [COLS*2-1:0]                valid_v_bot     // psuma_valid at bottom of each column
);
    genvar r, c;

    // Flat packed wires for PE mesh
    wire [(ROWS * COLS) * IFM_W  - 1 : 0] ifm_h_o;
    wire [(ROWS * COLS) * PSUM_W - 1 : 0] psuma_o, psumb_o;
    wire [(ROWS * COLS) - 1 : 0]           valid_h_o;   // horizontal valid outputs
    wire [(ROWS * COLS) - 1 : 0]           valid_va_o, valid_vb_o;  // vertical valid outputs

    generate
        for (r = 0; r < ROWS; r = r + 1) begin : row_blk
            for (c = 0; c < COLS; c = c + 1) begin : col_blk
                wire [IFM_W-1:0]  ifm_pe_in, ifm_pe_out;
                wire               vh_in,     vh_out;
                wire [PSUM_W-1:0] psuma_pe_in, psumb_pe_in, psuma_pe_out, psumb_pe_out;
                wire               vva_in, vvb_in, vva_out, vvb_out;

                // ---- IFM source ----
                if (c == 0) begin : ifm_src
                    assign ifm_pe_in = ifm_in_flat[(r+1)*IFM_W-1 : r*IFM_W];
                    assign vh_in     = valid_h_left[r];
                end else begin : ifm_chain
                    assign ifm_pe_in = ifm_h_o[(r*COLS + c)*IFM_W - 1 : (r*COLS + c - 1)*IFM_W];
                    assign vh_in     = valid_h_o[r*COLS + c - 1];
                end
                assign ifm_h_o[(r*COLS + c + 1)*IFM_W - 1 : (r*COLS + c)*IFM_W] = ifm_pe_out;
                assign valid_h_o[r*COLS + c] = vh_out;

                // ---- PSUM source ----
                if (r == 0) begin : psum_src
                    assign psuma_pe_in = psum_top_flat[(2*c+1)*PSUM_W-1 : 2*c*PSUM_W];
                    assign psumb_pe_in = psum_top_flat[(2*c+2)*PSUM_W-1 : (2*c+1)*PSUM_W];
                    assign vva_in = valid_v_top[2*c];
                    assign vvb_in = valid_v_top[2*c+1];
                end else begin : psum_chain
                    assign psuma_pe_in = psuma_o[((r-1)*COLS + c + 1)*PSUM_W-1 : ((r-1)*COLS + c)*PSUM_W];
                    assign psumb_pe_in = psumb_o[((r-1)*COLS + c + 1)*PSUM_W-1 : ((r-1)*COLS + c)*PSUM_W];
                    assign vva_in = valid_va_o[(r-1)*COLS + c];
                    assign vvb_in = valid_vb_o[(r-1)*COLS + c];
                end
                assign psuma_o[(r*COLS + c + 1)*PSUM_W-1 : (r*COLS + c)*PSUM_W] = psuma_pe_out;
                assign psumb_o[(r*COLS + c + 1)*PSUM_W-1 : (r*COLS + c)*PSUM_W] = psumb_pe_out;
                assign valid_va_o[r*COLS + c] = vva_out;
                assign valid_vb_o[r*COLS + c] = vvb_out;

                // ---- Weight ----
                wire signed [WEIGHT_W-1:0] pe_w0 = w_row_data[(r*2+1)*WEIGHT_W-1 : r*2*WEIGHT_W];
                wire signed [WEIGHT_W-1:0] pe_w1 = w_row_data[(r*2+2)*WEIGHT_W-1 : (r*2+1)*WEIGHT_W];
                wire pe_ld = w_load && (w_col == c[4:0]);

                systolic_pe u_pe (
                    .clk(clk), .rst(rst), .w_load(pe_ld), .w0_in(pe_w0), .w1_in(pe_w1),
                    .ifm_in(ifm_pe_in), .valid_in_h(vh_in),
                    .ifm_out(ifm_pe_out), .valid_out_h(vh_out),
                    .psuma_in(psuma_pe_in), .valid_in_va(vva_in),
                    .psuma_out(psuma_pe_out), .valid_out_va(vva_out),
                    .psumb_in(psumb_pe_in), .valid_in_vb(vvb_in),
                    .psumb_out(psumb_pe_out), .valid_out_vb(vvb_out)
                );
            end
        end
    endgenerate

    // PSUM bottom outputs
    generate
        for (c = 0; c < COLS; c = c + 1) begin : psum_bot_blk
            assign psum_bot_flat[(2*c+1)*PSUM_W-1 : 2*c*PSUM_W]
                = psuma_o[((ROWS-1)*COLS + c + 1)*PSUM_W-1 : ((ROWS-1)*COLS + c)*PSUM_W];
            assign psum_bot_flat[(2*c+2)*PSUM_W-1 : (2*c+1)*PSUM_W]
                = psumb_o[((ROWS-1)*COLS + c + 1)*PSUM_W-1 : ((ROWS-1)*COLS + c)*PSUM_W];
            assign valid_v_bot[2*c]   = valid_va_o[(ROWS-1)*COLS + c];
            assign valid_v_bot[2*c+1] = valid_vb_o[(ROWS-1)*COLS + c];
        end
    endgenerate
endmodule

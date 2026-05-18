`timescale 1ns / 1ps
// 32x32 weight-stationary systolic array — Verilog-2001 compatible
// Weight loading: 1 col/cycle (all 32 rows in parallel), 32 cycles full load
// Uses 512-bit w_row_data: 32 rows x 16 bits (w1,w0 packed)
module systolic_array_32x32 #(
    parameter ROWS = 32,
    parameter COLS = 32,
    parameter IFM_W  = 8,
    parameter WEIGHT_W = 8,
    parameter PSUM_W = 24
) (
    input  clk, rst,
    input  w_load,
    input  [4:0]  w_col,                       // column being loaded (0-31)
    input  [ROWS * WEIGHT_W * 2 - 1 : 0] w_row_data,  // 32 rows x 16-bit

    input  [ROWS * IFM_W       - 1 : 0] ifm_in_flat,
    input  [COLS * 2 * PSUM_W  - 1 : 0] psum_top_flat,
    output [COLS * 2 * PSUM_W  - 1 : 0] psum_bot_flat
);
    genvar r, c;

    wire [(ROWS * COLS) * IFM_W     - 1 : 0] ifm_h_o;
    wire [(ROWS * COLS) * PSUM_W    - 1 : 0] psuma_o;
    wire [(ROWS * COLS) * PSUM_W    - 1 : 0] psumb_o;

    generate
        for (r = 0; r < ROWS; r = r + 1) begin : row_blk
            for (c = 0; c < COLS; c = c + 1) begin : col_blk
                wire [IFM_W-1:0]  ifm_pe_in,  ifm_pe_out;
                wire [PSUM_W-1:0] psuma_pe_in, psumb_pe_in, psuma_pe_out, psumb_pe_out;

                // --- IFM source (vertical skew handled by external FIFO stagger) ---
                if (c == 0) begin : ifm_src
                    assign ifm_pe_in = ifm_in_flat[(r+1)*IFM_W - 1 : r*IFM_W];
                end else begin : ifm_chain
                    assign ifm_pe_in = ifm_h_o[(r*COLS + c)*IFM_W - 1 : (r*COLS + c - 1)*IFM_W];
                end
                assign ifm_h_o[(r*COLS + c + 1)*IFM_W - 1 : (r*COLS + c)*IFM_W] = ifm_pe_out;

                // --- Psum source ---
                if (r == 0) begin : psum_src
                    assign psuma_pe_in = psum_top_flat[(2*c+1)*PSUM_W - 1 : 2*c*PSUM_W];
                    assign psumb_pe_in = psum_top_flat[(2*c+2)*PSUM_W - 1 : (2*c+1)*PSUM_W];
                end else begin : psum_chain
                    assign psuma_pe_in = psuma_o[((r-1)*COLS + c + 1)*PSUM_W - 1 : ((r-1)*COLS + c)*PSUM_W];
                    assign psumb_pe_in = psumb_o[((r-1)*COLS + c + 1)*PSUM_W - 1 : ((r-1)*COLS + c)*PSUM_W];
                end
                assign psuma_o[(r*COLS + c + 1)*PSUM_W - 1 : (r*COLS + c)*PSUM_W] = psuma_pe_out;
                assign psumb_o[(r*COLS + c + 1)*PSUM_W - 1 : (r*COLS + c)*PSUM_W] = psumb_pe_out;

                // --- Weight: slice from row data ---
                wire signed [WEIGHT_W-1:0] pe_w0 = w_row_data[(r*2+1)*WEIGHT_W - 1 : r*2*WEIGHT_W];
                wire signed [WEIGHT_W-1:0] pe_w1 = w_row_data[(r*2+2)*WEIGHT_W - 1 : (r*2+1)*WEIGHT_W];
                wire pe_ld = w_load && (w_col == c[4:0]);

                systolic_pe u_pe (
                    .clk(clk), .rst(rst),
                    .w_load(pe_ld), .w0_in(pe_w0), .w1_in(pe_w1),
                    .ifm_in(ifm_pe_in), .ifm_out(ifm_pe_out),
                    .psuma_in(psuma_pe_in), .psumb_in(psumb_pe_in),
                    .psuma_out(psuma_pe_out), .psumb_out(psumb_pe_out)
                );
            end
        end
    endgenerate

    generate
        for (c = 0; c < COLS; c = c + 1) begin : psum_bot_blk
            assign psum_bot_flat[(2*c+1)*PSUM_W - 1 : 2*c*PSUM_W]
                = psuma_o[((ROWS-1)*COLS + c + 1)*PSUM_W - 1 : ((ROWS-1)*COLS + c)*PSUM_W];
            assign psum_bot_flat[(2*c+2)*PSUM_W - 1 : (2*c+1)*PSUM_W]
                = psumb_o[((ROWS-1)*COLS + c + 1)*PSUM_W - 1 : ((ROWS-1)*COLS + c)*PSUM_W];
        end
    endgenerate
endmodule

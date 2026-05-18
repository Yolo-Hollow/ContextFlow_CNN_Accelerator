`timescale 1ns / 1ps
// Top module: IFM FIFOs + Weight FIFOs + Array + PSUM FIFOs
// No storage scheduler — FIFO fill/drain handled externally
// Valid-based control: compute_start → stagger → valid through array → PSUM wr_en
module systolic_top #(
    parameter ROWS = 32, parameter COLS = 32,
    parameter IFM_W = 8, parameter WEIGHT_W = 8, parameter PSUM_W = 24,
    parameter IFM_FIFO_DEPTH = 256, parameter IFM_FIFO_AW = 8,
    parameter WGT_FIFO_DEPTH = 64,  parameter WGT_FIFO_AW = 6,
    parameter PSUM_FIFO_DEPTH = 256, parameter PSUM_FIFO_AW = 8
) (
    input  clk, rst,
    input  start,           // pulse: begin weight load → compute
    output done,            // high during COMPUTE (informational)

    // ---- IFM FIFO write ports (fill externally) ----
    input  [31:0]               ifm_fifo_wr_en,
    input  [ROWS*IFM_W-1:0]     ifm_fifo_wr_data,
    output [31:0]               ifm_fifo_full,

    // ---- Weight FIFO write ports (fill externally) ----
    input  [31:0]               wgt_fifo_wr_en,
    input  [ROWS*WEIGHT_W*2-1:0] wgt_fifo_wr_data,
    output [31:0]               wgt_fifo_full,

    // ---- PSUM FIFO read ports (drain externally) ----
    input  [31:0]               psum_fifo_rd_en,
    output [COLS*PSUM_W*2-1:0]  psum_fifo_rd_data,
    output [31:0]               psum_fifo_empty
);
    // ---- Control ----
    wire ctrl_w_load, ctrl_compute_start;
    wire [4:0] ctrl_w_col;
    wire compute_active;

    systolic_ctrl #(.ROWS(ROWS), .COLS(COLS)) u_ctrl (
        .clk(clk), .rst(rst), .start(start),
        .w_load(ctrl_w_load), .w_col(ctrl_w_col),
        .compute_active(compute_active),
        .compute_start_pulse(ctrl_compute_start)
    );
    assign done = compute_active;

    // ---- Weight FIFOs (32 × 16-bit) ----
    wire [ROWS*WEIGHT_W*2-1:0] wgt_fifo_rd_data;
    wire [31:0] wgt_fifo_empty;
    genvar r;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : wgt_fifo_gen
            systolic_fifo #(.WIDTH(WEIGHT_W*2), .DEPTH(WGT_FIFO_DEPTH), .AW(WGT_FIFO_AW))
            u_wgt_fifo (.clk(clk), .rst(rst),
                .wr_en(wgt_fifo_wr_en[r]), .rd_en(ctrl_w_load),
                .data_in(wgt_fifo_wr_data[(r+1)*WEIGHT_W*2-1 : r*WEIGHT_W*2]),
                .data_out(wgt_fifo_rd_data[(r+1)*WEIGHT_W*2-1 : r*WEIGHT_W*2]),
                .empty(wgt_fifo_empty[r]), .full(wgt_fifo_full[r]));
        end
    endgenerate

    // ---- IFM FIFOs (32 × 8-bit) + stagger chain ----
    wire [ROWS*IFM_W-1:0] ifm_fifo_rd_data;
    wire [31:0] ifm_fifo_empty;

    // Stagger: compute_active delayed by r*5 cycles per row
    // Row r starts reading IFM 5*r cycles after compute_active goes high
    wire [ROWS-1:0] ifm_rd_stagger;
    wire            compute_active_level = compute_active;  // rename for clarity
    assign ifm_rd_stagger[0] = compute_active_level;
    generate
        for (r = 1; r < ROWS; r = r + 1) begin : stagger_gen
            com_shift_reg #(.DEPTH(r*5), .WIDTH(1)) u_stag (
                .clk(clk), .si(compute_active_level), .so(ifm_rd_stagger[r]));
        end
    endgenerate

    // IFM FIFO rd_en = stagger AND not empty
    wire [31:0] ifm_fifo_rd_en;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : ifm_fifo_gen
            assign ifm_fifo_rd_en[r] = ifm_rd_stagger[r] && !ifm_fifo_empty[r];

            systolic_fifo #(.WIDTH(IFM_W), .DEPTH(IFM_FIFO_DEPTH), .AW(IFM_FIFO_AW))
            u_ifm_fifo (.clk(clk), .rst(rst),
                .wr_en(ifm_fifo_wr_en[r]), .rd_en(ifm_fifo_rd_en[r]),
                .data_in(ifm_fifo_wr_data[(r+1)*IFM_W-1 : r*IFM_W]),
                .data_out(ifm_fifo_rd_data[(r+1)*IFM_W-1 : r*IFM_W]),
                .empty(ifm_fifo_empty[r]), .full(ifm_fifo_full[r]));
        end
    endgenerate

    // ---- Systolic array ----
    wire [COLS*2*PSUM_W-1:0] psum_bot;
    wire [COLS*2-1:0]        valid_v_bot;

    // Top-row valid: always 1 for first pass (psum_top=0 is "always valid")
    wire [COLS*2-1:0] valid_v_top = {COLS*2{1'b1}};
    // Left-edge horizontal valid: IFM FIFO rd_en (data being read is valid)
    wire [ROWS-1:0]   valid_h_left = ifm_fifo_rd_en;

    systolic_array_32x32 #(.ROWS(ROWS), .COLS(COLS)) u_array (
        .clk(clk), .rst(rst),
        .w_load(ctrl_w_load), .w_col(ctrl_w_col),
        .w_row_data(wgt_fifo_rd_data),
        .ifm_in_flat(ifm_fifo_rd_data),
        .valid_h_left(valid_h_left),
        .psum_top_flat({COLS*2*PSUM_W{1'b0}}),
        .valid_v_top(valid_v_top),
        .psum_bot_flat(psum_bot),
        .valid_v_bot(valid_v_bot)
    );

    // ---- PSUM FIFOs (32 × 48-bit) ----
    // Write enable: column c produces valid psuma output
    wire [31:0] psum_fifo_wr_en;
    generate
        for (r = 0; r < COLS; r = r + 1) begin : psum_fifo_gen
            assign psum_fifo_wr_en[r] = valid_v_bot[2*r];  // psuma valid for column r

            systolic_fifo #(.WIDTH(PSUM_W*2), .DEPTH(PSUM_FIFO_DEPTH), .AW(PSUM_FIFO_AW))
            u_psum_fifo (.clk(clk), .rst(rst),
                .wr_en(psum_fifo_wr_en[r]), .rd_en(psum_fifo_rd_en[r]),
                .data_in(psum_bot[(r*2+2)*PSUM_W-1 : r*2*PSUM_W]),
                .data_out(psum_fifo_rd_data[(r+1)*PSUM_W*2-1 : r*PSUM_W*2]),
                .empty(psum_fifo_empty[r]), .full());
        end
    endgenerate
endmodule

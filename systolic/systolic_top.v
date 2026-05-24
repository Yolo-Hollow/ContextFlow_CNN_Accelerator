`timescale 1ns / 1ps
// Top module: IFM FIFOs + Weight FIFOs + Array + PSUM FIFOs
// No storage scheduler — FIFO fill/drain handled externally
// Valid-based control: compute_start → stagger → valid through array → PSUM wr_en
module systolic_top #(
    parameter ROWS = 32, parameter COLS = 32,
    parameter IFM_W = 8, parameter WEIGHT_W = 8, parameter PSUM_W = 32,
    parameter IFM_FIFO_DEPTH = 256, parameter IFM_FIFO_AW = 8,
    parameter WGT_FIFO_DEPTH = 64,  parameter WGT_FIFO_AW = 6,
    parameter PSUM_FIFO_DEPTH = 256, parameter PSUM_FIFO_AW = 8,
    parameter USE_DMA_IFM = 1   // 1: DMA line buffer, 0: manual IFM FIFO fill
) (
    input  clk, rst,
    input  start,
    output done,

    // ---- Manual IFM FIFO fill (USE_DMA_IFM=0) ----
    input  [31:0]               ifm_fifo_wr_en,
    input  [ROWS*IFM_W-1:0]     ifm_fifo_wr_data,
    output [31:0]               ifm_fifo_full_legacy,

    // ---- DMA / line buffer interface (USE_DMA_IFM=1) ----
    input  [4:0]    dma_bank_wr_en,
    input  [8:0]    dma_wr_x,
    input  [9:0]    dma_wr_fy,
    input  [7:0]    dma_wr_data [0:4],
    input           dma_line_advance,
    input  [8:0]    fm_h, fm_w,
    input  [1:0]    conv_stride, conv_pad,
    input  [10:0]   pass_base_k,
    input  [8:0]    oy, ox,
    output [31:0]   ifm_fifo_full,

    // ---- Bias buffer write port (64 entries × 24-bit, loaded once per layer) ----
    input  [5:0]                bias_wr_addr,
    input  [PSUM_W-1:0]         bias_wr_data,
    input                       bias_wr_en,
    input                       is_first_pass,   // 1: bias → psum_top; 0: external or 0
    input  [COLS*2*PSUM_W-1:0]  psum_top_ext,    // external psum_top (multi-pass feedback)
    input                       use_ext_psum,     // 1: use psum_top_ext; 0: use internal

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
    wire ctrl_w_load, ctrl_compute_start, ctrl_pre_write;
    wire [4:0] ctrl_w_col;
    wire compute_active;

    systolic_ctrl #(.ROWS(ROWS), .COLS(COLS)) u_ctrl (
        .clk(clk), .rst(rst), .start(start),
        .w_load(ctrl_w_load), .w_col(ctrl_w_col),
        .compute_active(compute_active),
        .compute_start_pulse(ctrl_compute_start),
        .pre_write(ctrl_pre_write)
    );
    assign done = compute_active;

    // ---- Weight FIFOs (32 × 16-bit) ----
    // rd_en = start||ctrl_w_load: pre-reads 1 cycle before weight load
    wire wgt_fifo_rd = ctrl_w_load || start;
    wire [ROWS*WEIGHT_W*2-1:0] wgt_fifo_rd_data;
    wire [31:0] wgt_fifo_empty;
    genvar r;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : wgt_fifo_gen
            systolic_fifo #(.WIDTH(WEIGHT_W*2), .DEPTH(WGT_FIFO_DEPTH), .AW(WGT_FIFO_AW))
            u_wgt_fifo (.clk(clk), .rst(rst),
                .wr_en(wgt_fifo_wr_en[r]), .rd_en(wgt_fifo_rd),
                .data_in(wgt_fifo_wr_data[(r+1)*WEIGHT_W*2-1 : r*WEIGHT_W*2]),
                .data_out(wgt_fifo_rd_data[(r+1)*WEIGHT_W*2-1 : r*WEIGHT_W*2]),
                .empty(wgt_fifo_empty[r]), .full(wgt_fifo_full[r]));
        end
    endgenerate

    // ---- Line buffer (5 bank × 3 line × 3 port) ----
    wire [7:0]  lb_rd [0:4][0:2][0:2];       // [bank][line][kx]
    wire [9:0]  line_fy [0:2];
    wire signed [10:0] rd_fx0_s = $signed({1'b0, ox}) * $signed({9'd0, conv_stride}) -
                                  $signed({9'd0, conv_pad});
    wire signed [10:0] rd_fx1_s = rd_fx0_s + 11'sd1;
    wire signed [10:0] rd_fx2_s = rd_fx0_s + 11'sd2;
    wire [8:0] rd_x0 = ((rd_fx0_s < 0) || (rd_fx0_s >= $signed({1'b0, fm_w}))) ? 9'd0 : rd_fx0_s[8:0];
    wire [8:0] rd_x1 = ((rd_fx1_s < 0) || (rd_fx1_s >= $signed({1'b0, fm_w}))) ? 9'd0 : rd_fx1_s[8:0];
    wire [8:0] rd_x2 = ((rd_fx2_s < 0) || (rd_fx2_s >= $signed({1'b0, fm_w}))) ? 9'd0 : rd_fx2_s[8:0];
    line_buffer_5bank #(.FM_W(416), .AW(9)) u_linebuf (
        .clk(clk), .rst(rst),
        .bank_wr_en(dma_bank_wr_en), .wr_x(dma_wr_x),
        .wr_data(dma_wr_data), .line_advance(dma_line_advance), .wr_fy(dma_wr_fy),
        .rd_x0(rd_x0), .rd_x1(rd_x1), .rd_x2(rd_x2),
        .rd_data(lb_rd), .line_fy_out(line_fy)
    );

    // ---- Window extractor → IFM FIFO write ----
    wire [255:0] we_ifm_data;
    wire         we_ifm_valid;
    window_extract #(.FM_W(416), .FM_H(416), .AW(9)) u_we (
        .fm_h(fm_h), .fm_w(fm_w), .stride(conv_stride), .pad(conv_pad), .oy(oy), .ox(ox),
        .pass_base_k(pass_base_k), .lb_data(lb_rd), .line_fy(line_fy),
        .lb_valid(compute_active || ctrl_pre_write),
        .ifm_data(we_ifm_data), .ifm_valid(we_ifm_valid)
    );

    // ---- IFM FIFOs (32 × 8-bit) + stagger chain ----
    wire [ROWS*IFM_W-1:0] ifm_fifo_rd_data;
    wire [31:0] ifm_fifo_empty;

    wire [ROWS-1:0] ifm_rd_stagger;
    assign ifm_rd_stagger[0] = compute_active;
    generate
        for (r = 1; r < ROWS; r = r + 1) begin : stagger_gen
            com_shift_reg #(.DEPTH(r*5), .WIDTH(1)) u_stag (
                .clk(clk), .rst(rst), .si(compute_active), .so(ifm_rd_stagger[r]));
        end
    endgenerate

    wire [31:0] ifm_fifo_rd_en;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : ifm_fifo_gen
            assign ifm_fifo_rd_en[r] = ifm_rd_stagger[r] && !ifm_fifo_empty[r];

            systolic_fifo #(.WIDTH(IFM_W), .DEPTH(IFM_FIFO_DEPTH), .AW(IFM_FIFO_AW))
            u_ifm_fifo (.clk(clk), .rst(rst),
                .wr_en(USE_DMA_IFM ? we_ifm_valid : ifm_fifo_wr_en[r]),
                .rd_en(ifm_fifo_rd_en[r]),
                .data_in(USE_DMA_IFM ? we_ifm_data[(r+1)*IFM_W-1 : r*IFM_W]
                                     : ifm_fifo_wr_data[(r+1)*IFM_W-1 : r*IFM_W]),
                .data_out(ifm_fifo_rd_data[(r+1)*IFM_W-1 : r*IFM_W]),
                .empty(ifm_fifo_empty[r]), .full(ifm_full_int[r]));
        end
    endgenerate

    // ---- Bias buffer (64 × 24-bit, 1 entry per OFM channel) ----
    reg [PSUM_W-1:0] bias_buf [0:63];
    always @(posedge clk) begin
        if (bias_wr_en) bias_buf[bias_wr_addr] <= bias_wr_data;
    end

    // ---- PSUM top: bias (first pass), external (multi-pass), or 0 ----
    wire [COLS*2*PSUM_W-1:0] psum_top_int;
    genvar i;
    generate
        for (i = 0; i < COLS*2; i = i + 1) begin : bias_mux
            assign psum_top_int[(i+1)*PSUM_W-1 : i*PSUM_W] =
                is_first_pass ? bias_buf[i] : {PSUM_W{1'b0}};
        end
    endgenerate
    wire [COLS*2*PSUM_W-1:0] psum_top_init = use_ext_psum ? psum_top_ext : psum_top_int;

    // Route IFM full to correct port
    wire [31:0] ifm_full_int;
    assign ifm_fifo_full = USE_DMA_IFM ? ifm_full_int : 32'd0;
    assign ifm_fifo_full_legacy = USE_DMA_IFM ? 32'd0 : ifm_full_int;

    // ---- Systolic array ----
    wire [COLS*2*PSUM_W-1:0] psum_bot;
    wire [COLS*2-1:0]        valid_v_bot;

    // Top-row valid: always 1 (bias or partial sum are always valid)
    wire [COLS*2-1:0] valid_v_top = {COLS*2{1'b1}};
    // Left-edge horizontal valid: IFM FIFO rd_en (data being read is valid)
    wire [ROWS-1:0]   valid_h_left = ifm_fifo_rd_en;

    // Register w_col to align with FIFO read latency (1 cycle)
    // w_load stays unregistered — PE loads on the cycle where w_load=1 AND w_col matches
    reg [4:0] w_col_r;
    always @(posedge clk) w_col_r <= ctrl_w_col;

    systolic_array_32x32 #(.ROWS(ROWS), .COLS(COLS)) u_array (
        .clk(clk), .rst(rst),
        .w_load(ctrl_w_load), .w_col(w_col_r),
        .w_row_data(wgt_fifo_rd_data),
        .ifm_in_flat(ifm_fifo_rd_data),
        .valid_h_left(valid_h_left),
        .psum_top_flat(psum_top_init),
        .valid_v_top(valid_v_top),
        .psum_bot_flat(psum_bot),
        .valid_v_bot(valid_v_bot)
    );

    // ---- PSUM FIFOs (32 × 48-bit) ----
    wire [31:0] psum_fifo_wr_en;
    generate
        for (r = 0; r < COLS; r = r + 1) begin : psum_fifo_gen
            assign psum_fifo_wr_en[r] = valid_v_bot[2*r];

            systolic_fifo #(.WIDTH(PSUM_W*2), .DEPTH(PSUM_FIFO_DEPTH), .AW(PSUM_FIFO_AW))
            u_psum_fifo (.clk(clk), .rst(rst),
                .wr_en(psum_fifo_wr_en[r]), .rd_en(psum_fifo_rd_en[r]),
                .data_in(psum_bot[(r*2+2)*PSUM_W-1 : r*2*PSUM_W]),
                .data_out(psum_fifo_rd_data[(r+1)*PSUM_W*2-1 : r*PSUM_W*2]),
                .empty(psum_fifo_empty[r]), .full());
        end
    endgenerate
endmodule

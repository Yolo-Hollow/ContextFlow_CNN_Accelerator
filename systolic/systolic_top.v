`timescale 1ns / 1ps
// Top module: IFM FIFOs + Weight FIFOs + Array + PSUM FIFOs
// No storage scheduler — FIFO fill/drain handled externally
// Valid-based control: compute_start → stagger → valid through array → PSUM wr_en
`ifndef SYSTOLIC_TAIL_CYCLES_CONFIG
`define SYSTOLIC_TAIL_CYCLES_CONFIG 0
`endif

module systolic_top #(
    parameter ROWS = 32, parameter COLS = 32,
    parameter IFM_W = 8, parameter WEIGHT_W = 8, parameter PSUM_W = 32,
    parameter IFM_FIFO_DEPTH = 1024, parameter IFM_FIFO_AW = 10,
    parameter WGT_FIFO_DEPTH = 64,  parameter WGT_FIFO_AW = 6,
    parameter PSUM_FIFO_DEPTH = 1024, parameter PSUM_FIFO_AW = 10,
    parameter TAIL_CYCLES_CONFIG = `SYSTOLIC_TAIL_CYCLES_CONFIG,
    parameter USE_DMA_IFM = 1   // 1: DMA line buffer, 0: manual IFM FIFO fill
) (
    input  clk, rst,
    input  start,
    input  [15:0] num_pixels,
    input  [15:0] tail_cycles_config,
    input  hold_compute_count_on_stall,
    output done,
    output compute_fire_out,
    output perf_comp_wload,
    output perf_comp_active,
    output perf_comp_ifm_stall,
    output perf_comp_tail,
    output [31:0] perf_tail_cycles_configured,

    // ---- Manual IFM FIFO fill (USE_DMA_IFM=0) ----
    input  [ROWS-1:0]           ifm_fifo_wr_en,
    input  [ROWS*IFM_W-1:0]     ifm_fifo_wr_data,
    output [ROWS-1:0]           ifm_fifo_full_legacy,

    // ---- DMA / line buffer interface (USE_DMA_IFM=1) ----
    input  [4:0]    dma_bank_wr_en,
    input  [8:0]    dma_wr_x,
    input  [9:0]    dma_wr_fy,
    input  [7:0]    dma_wr_data [0:4],
    input           dma_line_advance,
    input  [8:0]    fm_h, fm_w,
    input  [1:0]    conv_stride, conv_pad,
    input  [13:0]   pass_base_k,
    input  [8:0]    oy, ox,
    output [31:0]   ifm_fifo_full,

    // ---- Bias buffer write port (64 entries × 24-bit, loaded once per layer) ----
    input  [5:0]                bias_wr_addr,
    input  [PSUM_W-1:0]         bias_wr_data,
    input                       bias_wr_en,
    input                       is_first_pass,   // 1: bias → psum_top; 0: external or 0
    input  [COLS*2*PSUM_W-1:0]  psum_top_ext,    // external psum_top (multi-pass feedback)
    input                       use_ext_psum,     // 1: use psum_top_ext; 0: use internal
    input  [COLS*2*PSUM_W-1:0]  psum_stream_data,
    input                       psum_stream_valid,
    input                       psum_stream_compute_ready,
    input                       use_psum_stream,
    input  [COLS*2*PSUM_W-1:0]  psum_column_stream_data,
    input  [COLS-1:0]           psum_column_stream_valid,
    input                       use_column_psum_stream,

    // ---- Weight FIFO write ports (fill externally) ----
    input  [ROWS-1:0]           wgt_fifo_wr_en,
    input  [ROWS*WEIGHT_W*2-1:0] wgt_fifo_wr_data,
    output [ROWS-1:0]           wgt_fifo_full,

    // ---- PSUM FIFO read ports (drain externally) ----
    input  [31:0]               psum_fifo_rd_en,
    output [COLS*PSUM_W*2-1:0]  psum_fifo_rd_data,
    output [31:0]               psum_fifo_empty,
    output [31:0]               psum_fifo_wr_en_dbg
);
    // ---- Control ----
    wire ctrl_w_load, ctrl_compute_start, ctrl_pre_write;
    wire [4:0] ctrl_w_col;
    wire compute_active;
    wire compute_fire;
    wire perf_comp_ifm_stall_ctrl;
    wire perf_comp_ifm_underflow;
    wire [ROWS*IFM_W-1:0] ifm_fifo_rd_data;
    wire [31:0] ifm_fifo_empty;
    wire compute_ready = !ifm_fifo_empty[0] &&
                         (!use_psum_stream || psum_stream_compute_ready);
    assign compute_fire_out = compute_fire;

    systolic_ctrl #(
        .ROWS(ROWS),
        .COLS(COLS),
        .TAIL_CYCLES_CONFIG(TAIL_CYCLES_CONFIG)
    ) u_ctrl (
        .clk(clk), .rst(rst), .start(start), .num_pixels(num_pixels),
        .tail_cycles_config(tail_cycles_config),
        .compute_ready(compute_ready),
        .hold_compute_count_on_stall(hold_compute_count_on_stall),
        .done(done),
        .w_load(ctrl_w_load), .w_col(ctrl_w_col),
        .compute_active(compute_active),
        .compute_fire(compute_fire),
        .compute_start_pulse(ctrl_compute_start),
        .pre_write(ctrl_pre_write),
        .perf_comp_wload(perf_comp_wload),
        .perf_comp_active(perf_comp_active),
        .perf_comp_ifm_stall(perf_comp_ifm_stall_ctrl),
        .perf_comp_tail(perf_comp_tail),
        .tail_cycles_configured(perf_tail_cycles_configured)
    );
    assign perf_comp_ifm_stall = perf_comp_ifm_stall_ctrl || perf_comp_ifm_underflow;

    // ---- Weight FIFOs (32 × 16-bit) ----
    // Pre-read column 0 on start, then read exactly COLS-1 more packets while
    // loading. A fixed budget avoids both under-reading and consuming the
    // first packet of a prefetched next pass.
    reg [5:0] wgt_reads_left;
    wire wgt_fifo_rd = start || (ctrl_w_load && (wgt_reads_left != 6'd0));
    wire [ROWS*WEIGHT_W*2-1:0] wgt_fifo_rd_data;
    wire [ROWS-1:0] wgt_fifo_empty;
    always @(posedge clk) begin
        if (rst)
            wgt_reads_left <= 6'd0;
        else if (start)
            wgt_reads_left <= COLS - 1;
        else if (ctrl_w_load && (wgt_reads_left != 6'd0))
            wgt_reads_left <= wgt_reads_left - 1'b1;
    end
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
    wire        line_valid [0:2];
    wire [1:0]  line_wr_ptr;
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
        .rd_data(lb_rd), .line_fy_out(line_fy),
        .line_valid_out(line_valid), .wr_ptr_out(line_wr_ptr)
    );

    // ---- Window extractor → IFM FIFO write ----
    wire [255:0] we_ifm_data;
    wire         we_ifm_valid;
    wire         we_window_ready;
    window_extract #(.FM_W(416), .FM_H(416), .AW(9)) u_we (
        .fm_h(fm_h), .fm_w(fm_w), .stride(conv_stride), .pad(conv_pad), .oy(oy), .ox(ox),
        .pass_base_k(pass_base_k), .lb_data(lb_rd), .line_fy(line_fy), .line_valid(line_valid),
        .lb_valid(compute_active || ctrl_pre_write),
        .ifm_data(we_ifm_data), .ifm_valid(we_ifm_valid), .window_ready(we_window_ready)
    );

    // ---- IFM FIFOs (32 × 8-bit) + stagger chain ----
    wire [ROWS-1:0] ifm_rd_stagger;
    assign ifm_rd_stagger[0] = compute_fire;
    generate
        for (r = 1; r < ROWS; r = r + 1) begin : stagger_gen
            com_shift_reg #(.DEPTH(r*5), .WIDTH(1)) u_stag (
                .clk(clk), .rst(rst), .si(compute_fire), .so(ifm_rd_stagger[r]));
        end
    endgenerate

    wire [ROWS-1:0] ifm_full_active;
    wire [ROWS-1:0] ifm_fifo_empty_active;
    wire [ROWS-1:0] ifm_fifo_rd_en_active;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : ifm_fifo_gen
            assign ifm_fifo_rd_en_active[r] = ifm_rd_stagger[r] && !ifm_fifo_empty_active[r];

            systolic_fifo #(.WIDTH(IFM_W), .DEPTH(IFM_FIFO_DEPTH), .AW(IFM_FIFO_AW))
            u_ifm_fifo (.clk(clk), .rst(rst),
                .wr_en(USE_DMA_IFM ? we_ifm_valid : ifm_fifo_wr_en[r]),
                .rd_en(ifm_fifo_rd_en_active[r]),
                .data_in(USE_DMA_IFM ? we_ifm_data[(r+1)*IFM_W-1 : r*IFM_W]
                                     : ifm_fifo_wr_data[(r+1)*IFM_W-1 : r*IFM_W]),
                .data_out(ifm_fifo_rd_data[(r+1)*IFM_W-1 : r*IFM_W]),
                .empty(ifm_fifo_empty_active[r]), .full(ifm_full_active[r]));
        end
    endgenerate
    assign perf_comp_ifm_underflow = |(ifm_rd_stagger & ifm_fifo_empty_active);

    reg [ROWS-1:0] ifm_fifo_rd_valid;
    always @(posedge clk) begin
        if (rst) ifm_fifo_rd_valid <= {ROWS{1'b0}};
        else     ifm_fifo_rd_valid <= ifm_fifo_rd_en_active;
    end

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
    wire [COLS*2*PSUM_W-1:0] psum_top_static = use_ext_psum ? psum_top_ext : psum_top_int;
    wire [COLS*2*PSUM_W-1:0] psum_stream_skewed;
    wire [COLS*2-1:0]        psum_stream_valid_skewed;
    genvar pc;
    generate
        for (pc = 0; pc < COLS; pc = pc + 1) begin : psum_stream_skew
            wire [PSUM_W*2-1:0] col_psum_in = psum_stream_data[(pc+1)*PSUM_W*2-1 : pc*PSUM_W*2];
            wire [PSUM_W*2-1:0] col_psum_out;
            wire col_valid_out;
            com_shift_reg #(.DEPTH(pc*4), .WIDTH(PSUM_W*2)) u_psum_col_data (
                .clk(clk), .rst(rst), .si(col_psum_in), .so(col_psum_out));
            com_shift_reg #(.DEPTH(pc*4), .WIDTH(1)) u_psum_col_valid (
                .clk(clk), .rst(rst), .si(psum_stream_valid), .so(col_valid_out));
            assign psum_stream_skewed[(pc+1)*PSUM_W*2-1 : pc*PSUM_W*2] = col_psum_out;
            assign psum_stream_valid_skewed[2*pc] = col_valid_out;
            assign psum_stream_valid_skewed[2*pc+1] = col_valid_out;
        end
    endgenerate
    wire [COLS*2*PSUM_W-1:0] psum_top_init =
        use_column_psum_stream ? psum_column_stream_data :
        (use_psum_stream ? psum_stream_skewed : psum_top_static);

    // Route IFM full to correct port
    assign ifm_fifo_empty = {{(32-ROWS){1'b0}}, ifm_fifo_empty_active};
    assign ifm_fifo_full = USE_DMA_IFM ? {{(32-ROWS){1'b0}}, ifm_full_active} : 32'd0;
    assign ifm_fifo_full_legacy = USE_DMA_IFM ? {ROWS{1'b0}} : ifm_full_active;

    // ---- Systolic array ----
    wire [COLS*2*PSUM_W-1:0] psum_bot;
    wire [COLS*2-1:0]        valid_v_bot;

    // Top-row valid: always 1 (bias or partial sum are always valid)
    wire [COLS*2-1:0] column_stream_valid_expanded;
    generate
        for (pc = 0; pc < COLS; pc = pc + 1) begin : column_stream_valid_expand
            assign column_stream_valid_expanded[2*pc] = psum_column_stream_valid[pc];
            assign column_stream_valid_expanded[2*pc+1] = psum_column_stream_valid[pc];
        end
    endgenerate
    wire [COLS*2-1:0] valid_v_top =
        use_column_psum_stream ? column_stream_valid_expanded :
        (use_psum_stream ? psum_stream_valid_skewed : {COLS*2{1'b1}});
    // Left-edge horizontal valid: IFM FIFO rd_en (data being read is valid)
    wire [ROWS-1:0]   valid_h_left = ifm_fifo_rd_valid;

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
    assign psum_fifo_wr_en_dbg = psum_fifo_wr_en;
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

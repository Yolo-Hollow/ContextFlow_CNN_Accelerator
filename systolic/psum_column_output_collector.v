`timescale 1ns / 1ps

// Collects non-final partial PSUMs by column.
//
// Contexts are accepted in compute-start order. For each context, every output
// column FIFO is drained independently and written to column-granular
// ping-pong storage. The collector only emits completion events; final OFM
// packets remain handled by psum_output_collector.
module psum_column_output_collector #(
    parameter COLS = 8,
    parameter PSUM_W = 32,
    parameter ADDR_W = 10,
    parameter CTX_DEPTH = 4,
    parameter CTX_AW = 2
) (
    input  clk,
    input  rst,
    input  enable,

    input         ctx_valid,
    output        ctx_ready,
    input  [15:0] ctx_num_pixels,
    input         ctx_wr_bank,
    input         ctx_trace_match,

    output [31:0] psum_fifo_rd_en,
    input  [COLS*PSUM_W*2-1:0] psum_fifo_rd_data,
    input  [31:0] psum_fifo_empty,

    output [COLS-1:0]             col_wr_en,
    output                        col_wr_bank,
    output [COLS*ADDR_W-1:0]      col_wr_addr_flat,
    output [COLS*PSUM_W*2-1:0]    col_wr_data_flat,

    output reg context_start,
    output reg context_done,
    output reg partial_done,
    output        context_active,
    output        context_idle,
    output        context_wr_bank,
    output        trace_context_active,
    output reg    trace_context_done,
    output reg    perf_context_push,
    output reg    perf_context_pop,
    output        perf_context_full_stall,
    output        perf_column_empty_wait
);
    localparam DATA_W = PSUM_W * 2;
    localparam CTX_W = 16 + 1 + 1;
    localparam [31:0] COL_MASK = (32'h1 << COLS) - 1;

    reg [CTX_W-1:0] ctx_mem [0:CTX_DEPTH-1];
    reg [CTX_AW:0] ctx_wptr;
    reg [CTX_AW:0] ctx_rptr;
    wire ctx_empty = (ctx_wptr == ctx_rptr);
    wire ctx_full =
        (ctx_wptr[CTX_AW] != ctx_rptr[CTX_AW]) &&
        (ctx_wptr[CTX_AW-1:0] == ctx_rptr[CTX_AW-1:0]);
    wire ctx_push = enable && ctx_valid && ctx_ready;
    assign ctx_ready = enable && !ctx_full;
    assign perf_context_full_stall = enable && ctx_valid && ctx_full;

    reg active;
    reg [15:0] active_num_pixels;
    reg active_wr_bank;
    reg active_trace_match;

    reg [15:0] rd_count [0:COLS-1];
    reg [15:0] wr_count [0:COLS-1];
    reg [COLS-1:0] rd_pending;
    reg [ADDR_W-1:0] pending_addr [0:COLS-1];

    wire [15:0] pixels_to_collect =
        (active_num_pixels == 16'd0) ? 16'd1 : active_num_pixels;

    wire [COLS-1:0] col_empty = psum_fifo_empty[COLS-1:0];
    wire [COLS-1:0] read_needed;
    wire [COLS-1:0] issue_read;
    wire [COLS-1:0] completed_cols;

    genvar c;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : col_logic
            assign read_needed[c] = enable && active &&
                                    (rd_count[c] < pixels_to_collect);
            assign issue_read[c] = read_needed[c] && !col_empty[c] &&
                                   !rd_pending[c];
            assign completed_cols[c] = (wr_count[c] >= pixels_to_collect);
            assign col_wr_en[c] = rd_pending[c];
            assign col_wr_addr_flat[(c+1)*ADDR_W-1 -: ADDR_W] =
                pending_addr[c];
            assign col_wr_data_flat[(c+1)*DATA_W-1 -: DATA_W] =
                psum_fifo_rd_data[(c+1)*DATA_W-1 -: DATA_W];
        end
    endgenerate

    assign psum_fifo_rd_en = {{(32-COLS){1'b0}}, issue_read};
    assign col_wr_bank = active_wr_bank;
    assign context_active = active;
    assign context_idle = !active && ctx_empty && (rd_pending == {COLS{1'b0}});
    assign context_wr_bank = active_wr_bank;
    assign trace_context_active = active && active_trace_match;
    assign perf_column_empty_wait = enable && active &&
                                    (|(read_needed & col_empty));

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            ctx_wptr <= {(CTX_AW+1){1'b0}};
        end else if (ctx_push) begin
            ctx_mem[ctx_wptr[CTX_AW-1:0]] <= {
                ctx_num_pixels, ctx_wr_bank, ctx_trace_match
            };
            ctx_wptr <= ctx_wptr + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            ctx_rptr <= {(CTX_AW+1){1'b0}};
            active <= 1'b0;
            active_num_pixels <= 16'd0;
            active_wr_bank <= 1'b0;
            active_trace_match <= 1'b0;
            context_start <= 1'b0;
            context_done <= 1'b0;
            partial_done <= 1'b0;
            trace_context_done <= 1'b0;
            perf_context_push <= 1'b0;
            perf_context_pop <= 1'b0;
            rd_pending <= {COLS{1'b0}};
            for (i = 0; i < COLS; i = i + 1) begin
                rd_count[i] <= 16'd0;
                wr_count[i] <= 16'd0;
                pending_addr[i] <= {ADDR_W{1'b0}};
            end
        end else begin
            context_start <= 1'b0;
            context_done <= 1'b0;
            partial_done <= 1'b0;
            trace_context_done <= 1'b0;
            perf_context_push <= ctx_push;
            perf_context_pop <= 1'b0;

            if (!enable) begin
                active <= 1'b0;
                rd_pending <= {COLS{1'b0}};
                for (i = 0; i < COLS; i = i + 1) begin
                    rd_count[i] <= 16'd0;
                    wr_count[i] <= 16'd0;
                end
            end else begin
                for (i = 0; i < COLS; i = i + 1) begin
                    if (rd_pending[i]) begin
                        rd_pending[i] <= 1'b0;
                        if (wr_count[i] != 16'hffff)
                            wr_count[i] <= wr_count[i] + 1'b1;
                    end
                    if (issue_read[i]) begin
                        pending_addr[i] <= rd_count[i][ADDR_W-1:0];
                        rd_count[i] <= rd_count[i] + 1'b1;
                        rd_pending[i] <= 1'b1;
                    end
                end

                if (!active && !ctx_empty) begin
                    {
                        active_num_pixels, active_wr_bank, active_trace_match
                    } <= ctx_mem[ctx_rptr[CTX_AW-1:0]];
                    ctx_rptr <= ctx_rptr + 1'b1;
                    active <= 1'b1;
                    context_start <= 1'b1;
                    perf_context_pop <= 1'b1;
                    rd_pending <= {COLS{1'b0}};
                    for (i = 0; i < COLS; i = i + 1) begin
                        rd_count[i] <= 16'd0;
                        wr_count[i] <= 16'd0;
                        pending_addr[i] <= {ADDR_W{1'b0}};
                    end
                end else if (active && (&completed_cols) &&
                             (rd_pending == {COLS{1'b0}})) begin
                    active <= 1'b0;
                    context_done <= 1'b1;
                    partial_done <= 1'b1;
                    trace_context_done <= active_trace_match;
                end
            end
        end
    end
endmodule

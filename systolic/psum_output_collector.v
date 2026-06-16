`timescale 1ns / 1ps

// Continuously drains aligned systolic-column FIFOs using queued pass context.
// Non-final packets are written to partial-PSUM storage; final packets use the
// ready/valid output and retain their context until accepted.
module psum_output_collector #(
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
    input         ctx_is_final,
    input         ctx_wr_bank,
    input  [10:0] ctx_cout_base,
    input  [10:0] ctx_cout_valid,
    input         ctx_trace_match,

    output [31:0] psum_fifo_rd_en,
    input  [COLS*PSUM_W*2-1:0] psum_fifo_rd_data,
    input  [31:0] psum_fifo_empty,

    output reg                         packet_valid,
    input                              packet_ready,
    output reg [ADDR_W-1:0]            packet_addr,
    output reg [COLS*PSUM_W*2-1:0]     packet_data,
    output reg                         packet_is_final,
    output reg                         packet_wr_bank,
    output reg [10:0]                  packet_cout_base,
    output reg [10:0]                  packet_cout_valid,

    output reg context_start,
    output reg context_done,
    output reg partial_done,
    output reg final_done,
    output        context_active,
    output        context_wr_bank,
    output        context_is_final,
    output        trace_context_active,
    output reg    trace_context_done,
    output reg perf_context_push,
    output reg perf_context_pop,
    output     perf_context_full_stall,
    output     perf_column_empty_wait
);
    localparam DATA_W = COLS*PSUM_W*2;
    localparam [31:0] COL_MASK = (32'h1 << COLS) - 1;
    localparam CTX_W = 16 + 1 + 1 + 11 + 11 + 1;

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
    reg active_is_final;
    reg active_wr_bank;
    reg [10:0] active_cout_base;
    reg [10:0] active_cout_valid;
    reg active_trace_match;
    reg [15:0] rd_count;
    reg [15:0] out_count;
    reg [ADDR_W-1:0] pending_addr;
    reg read_pending;
    reg hold_valid;
    reg [ADDR_W-1:0] hold_addr;
    reg [DATA_W-1:0] hold_data;

    wire [15:0] pixels_to_collect =
        (active_num_pixels == 16'd0) ? 16'd1 : active_num_pixels;
    wire columns_ready = ((psum_fifo_empty & COL_MASK) == 32'd0);
    wire packet_pop = packet_valid && packet_ready;
    wire [1:0] stored_count = {1'b0, packet_valid} + {1'b0, hold_valid};
    wire [1:0] stored_after_pop = stored_count - {1'b0, packet_pop};
    wire [1:0] stored_after_return = stored_after_pop + {1'b0, read_pending};
    wire can_accept_future_return = (stored_after_return < 2'd2);
    wire read_needed = enable && active && (rd_count < pixels_to_collect);
    wire issue_read = read_needed && columns_ready && can_accept_future_return;
    wire completing_packet =
        packet_pop && (out_count == pixels_to_collect - 16'd1);

    assign psum_fifo_rd_en = issue_read ? COL_MASK : 32'd0;
    assign perf_column_empty_wait = read_needed && !columns_ready;
    assign context_active = active;
    assign context_wr_bank = active_wr_bank;
    assign context_is_final = active_is_final;
    assign trace_context_active = active && active_trace_match;

    always @(posedge clk) begin
        if (rst) begin
            ctx_wptr <= {(CTX_AW+1){1'b0}};
        end else if (ctx_push) begin
            ctx_mem[ctx_wptr[CTX_AW-1:0]] <= {
                ctx_num_pixels, ctx_is_final, ctx_wr_bank,
                ctx_cout_base, ctx_cout_valid, ctx_trace_match
            };
            ctx_wptr <= ctx_wptr + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            ctx_rptr <= {(CTX_AW+1){1'b0}};
            active <= 1'b0;
            active_num_pixels <= 16'd0;
            active_is_final <= 1'b0;
            active_wr_bank <= 1'b0;
            active_cout_base <= 11'd0;
            active_cout_valid <= 11'd0;
            active_trace_match <= 1'b0;
            rd_count <= 16'd0;
            out_count <= 16'd0;
            pending_addr <= {ADDR_W{1'b0}};
            read_pending <= 1'b0;
            hold_valid <= 1'b0;
            packet_valid <= 1'b0;
            packet_addr <= {ADDR_W{1'b0}};
            packet_data <= {DATA_W{1'b0}};
            packet_is_final <= 1'b0;
            packet_wr_bank <= 1'b0;
            packet_cout_base <= 11'd0;
            packet_cout_valid <= 11'd0;
            context_start <= 1'b0;
            context_done <= 1'b0;
            partial_done <= 1'b0;
            final_done <= 1'b0;
            perf_context_push <= 1'b0;
            perf_context_pop <= 1'b0;
            trace_context_done <= 1'b0;
        end else begin
            context_start <= 1'b0;
            context_done <= 1'b0;
            partial_done <= 1'b0;
            final_done <= 1'b0;
            perf_context_push <= ctx_push;
            perf_context_pop <= 1'b0;
            trace_context_done <= 1'b0;

            if (!enable) begin
                active <= 1'b0;
                packet_valid <= 1'b0;
                hold_valid <= 1'b0;
                read_pending <= 1'b0;
                rd_count <= 16'd0;
                out_count <= 16'd0;
            end else begin
                if (!active && !ctx_empty) begin
                    {
                        active_num_pixels, active_is_final, active_wr_bank,
                        active_cout_base, active_cout_valid, active_trace_match
                    } <= ctx_mem[ctx_rptr[CTX_AW-1:0]];
                    ctx_rptr <= ctx_rptr + 1'b1;
                    active <= 1'b1;
                    rd_count <= 16'd0;
                    out_count <= 16'd0;
                    packet_valid <= 1'b0;
                    hold_valid <= 1'b0;
                    read_pending <= 1'b0;
                    context_start <= 1'b1;
                    perf_context_pop <= 1'b1;
                end else if (active) begin
                    if (completing_packet) begin
                        active <= 1'b0;
                        active_trace_match <= 1'b0;
                        packet_valid <= 1'b0;
                        hold_valid <= 1'b0;
                        read_pending <= 1'b0;
                        context_done <= 1'b1;
                        trace_context_done <= active_trace_match;
                        partial_done <= !active_is_final;
                        final_done <= active_is_final;
                    end else begin
                        if (packet_pop)
                            out_count <= out_count + 1'b1;

                        if (packet_pop || !packet_valid) begin
                            if (hold_valid) begin
                                packet_valid <= 1'b1;
                                packet_addr <= hold_addr;
                                packet_data <= hold_data;
                                hold_valid <= read_pending;
                                if (read_pending) begin
                                    hold_addr <= pending_addr;
                                    hold_data <= psum_fifo_rd_data;
                                end
                            end else if (read_pending) begin
                                packet_valid <= 1'b1;
                                packet_addr <= pending_addr;
                                packet_data <= psum_fifo_rd_data;
                            end else begin
                                packet_valid <= 1'b0;
                            end
                        end else if (read_pending) begin
                            hold_valid <= 1'b1;
                            hold_addr <= pending_addr;
                            hold_data <= psum_fifo_rd_data;
                        end

                        if (issue_read) begin
                            pending_addr <= rd_count[ADDR_W-1:0];
                            rd_count <= rd_count + 1'b1;
                        end
                        read_pending <= issue_read;
                    end
                end
            end

            packet_is_final <= active_is_final;
            packet_wr_bank <= active_wr_bank;
            packet_cout_base <= active_cout_base;
            packet_cout_valid <= active_cout_valid;
        end
    end
endmodule

`timescale 1ns / 1ps

// Continuously drains aligned systolic-column FIFOs using queued pass context.
// Non-final packets are written to partial-PSUM storage; final packets use the
// ready/valid output and retain their context until accepted.
module psum_output_collector #(
    parameter COLS = 8,
    parameter PSUM_W = 32,
    parameter ADDR_W = 10,
    parameter CTX_DEPTH = 4,
    parameter CTX_AW = 2,
    parameter EPOCH_W = 8,
    parameter CONTEXT_W = 16,
    parameter TAG_W = EPOCH_W + 2,
    parameter ENABLE_TAG_CHECK = 0
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
    input  [EPOCH_W-1:0] ctx_epoch,
    input         ctx_ifm_bank,
    input  [CONTEXT_W-1:0] ctx_context_id,
    input  [EPOCH_W-1:0] ctx_parent_epoch,
    input  [CONTEXT_W-1:0] ctx_parent_context_id,
    input         ctx_first,

    output [31:0] psum_fifo_rd_en,
    input  [COLS*PSUM_W*2-1:0] psum_fifo_rd_data,
    input  [COLS*TAG_W-1:0] psum_fifo_rd_tag,
    input  [31:0] psum_fifo_empty,

    output wire                        packet_valid,
    input                              packet_ready,
    output wire [ADDR_W-1:0]           packet_addr,
    output wire [COLS*PSUM_W*2-1:0]    packet_data,
    output reg                         packet_is_final,
    output reg                         packet_wr_bank,
    output reg [10:0]                  packet_cout_base,
    output reg [10:0]                  packet_cout_valid,
    output reg [EPOCH_W-1:0]           packet_epoch,
    output reg                         packet_ifm_bank,
    output reg [CONTEXT_W-1:0]         packet_context_id,
    output reg [EPOCH_W-1:0]           packet_parent_epoch,
    output reg [CONTEXT_W-1:0]         packet_parent_context_id,
    output reg                         packet_first,

    output reg context_start,
    output reg context_done,
    output reg partial_done,
    output reg final_done,
    output        context_active,
    output        context_wr_bank,
    output        context_is_final,
    output [EPOCH_W-1:0] context_epoch,
    output        context_ifm_bank,
    output [CONTEXT_W-1:0] context_id,
    output [EPOCH_W-1:0] context_parent_epoch,
    output [CONTEXT_W-1:0] context_parent_context_id,
    output        context_first,
    output reg [EPOCH_W-1:0] context_done_epoch,
    output reg    context_done_ifm_bank,
    output reg [CONTEXT_W-1:0] context_done_context_id,
    output reg [EPOCH_W-1:0] context_done_parent_epoch,
    output reg [CONTEXT_W-1:0] context_done_parent_context_id,
    output reg    context_done_first,
    output reg    context_done_final,
    output reg    context_done_wr_bank,
    output        trace_context_active,
    output reg    trace_context_done,
    output reg perf_context_push,
    output reg perf_context_pop,
    output     perf_context_full_stall,
    output     perf_column_empty_wait,
    output reg tag_mismatch_sticky,
    output reg [31:0] tag_mismatch_count,
    output     fail_stop
);
    localparam DATA_W = COLS*PSUM_W*2;
    localparam [31:0] COL_MASK = (32'h1 << COLS) - 1;
    localparam CTX_W = 16 + 1 + 1 + 11 + 11 + 1 + EPOCH_W + 1 +
        CONTEXT_W + EPOCH_W + CONTEXT_W + 1;

    reg [CTX_W-1:0] ctx_mem [0:CTX_DEPTH-1];
    reg [CTX_AW:0] ctx_wptr;
    reg [CTX_AW:0] ctx_rptr;
    wire ctx_empty = (ctx_wptr == ctx_rptr);
    wire ctx_full =
        (ctx_wptr[CTX_AW] != ctx_rptr[CTX_AW]) &&
        (ctx_wptr[CTX_AW-1:0] == ctx_rptr[CTX_AW-1:0]);
    wire ctx_push = enable && ctx_valid && ctx_ready;
    assign ctx_ready = enable && !ctx_full && !tag_mismatch_sticky;
    assign perf_context_full_stall = enable && ctx_valid && ctx_full;

    reg active;
    reg [15:0] active_num_pixels;
    reg active_is_final;
    reg active_wr_bank;
    reg [10:0] active_cout_base;
    reg [10:0] active_cout_valid;
    reg active_trace_match;
    reg [EPOCH_W-1:0] active_epoch;
    reg active_ifm_bank;
    reg [CONTEXT_W-1:0] active_context_id;
    reg [EPOCH_W-1:0] active_parent_epoch;
    reg [CONTEXT_W-1:0] active_parent_context_id;
    reg active_first;
    reg [15:0] rd_count;
    reg [15:0] out_count;
    reg return_valid_q;
    reg [ADDR_W-1:0] return_addr_q;
    // Two validated packet slots sit behind the one-cycle FIFO return slot.
    // The pointers and occupancy are the only state used to reserve new read
    // responses; downstream ready never feeds the read-enable cone.
    reg [1:0] packet_count_q;
    reg packet_rd_ptr_q;
    reg packet_wr_ptr_q;
    // Delay only the diagnostic counter update.  The fail-stop controls below
    // still react on the bad return edge, while the registered event keeps the
    // wide tag compare out of the counter increment cone.
    reg bad_tag_event_q;
    reg [ADDR_W-1:0] packet_addr_q [0:1];
    reg [DATA_W-1:0] packet_data_q [0:1];
    // Register only the narrow queue-head address.  The wide packet payload
    // remains in the original two-slot RAM and keeps its existing read path.
    reg [ADDR_W-1:0] packet_head_addr_q;
    wire packet_rd_ptr_next = packet_rd_ptr_q + 1'b1;

    wire [15:0] pixels_to_collect =
        (active_num_pixels == 16'd0) ? 16'd1 : active_num_pixels;
    wire columns_ready = ((psum_fifo_empty & COL_MASK) == 32'd0);
    wire packet_pop = packet_valid && packet_ready;
    wire [TAG_W-1:0] return_tag0 = psum_fifo_rd_tag[TAG_W-1:0];
    wire expected_return_last =
        return_addr_q == pixels_to_collect - 16'd1;
    wire [TAG_W-1:0] expected_return_tag = {
        active_epoch, active_ifm_bank, expected_return_last
    };
    wire [COLS-1:0] return_column_tag_match;
    genvar tag_col;
    generate
        for (tag_col = 0; tag_col < COLS; tag_col = tag_col + 1) begin : tag_check
            assign return_column_tag_match[tag_col] =
                psum_fifo_rd_tag[(tag_col+1)*TAG_W-1:tag_col*TAG_W] ==
                return_tag0;
        end
    endgenerate
    wire return_tag_ok = (ENABLE_TAG_CHECK == 0) ||
        ((&return_column_tag_match) && (return_tag0 == expected_return_tag));
    wire bad_tag_return = enable && active && return_valid_q &&
        !tag_mismatch_sticky && !return_tag_ok;
    // A return advances whenever registered queue occupancy says that a slot
    // is free.  The payload write and write pointer are intentionally
    // independent of tag_ok; the tag result only controls the narrow
    // queue-valid/count state.  A bad word therefore cannot retire, while its
    // tag compare never enters a RAM-enable or pointer/payload CE cone.
    wire packet_queue_has_space = (packet_count_q < 2);
    wire return_advance = return_valid_q && packet_queue_has_space;
    wire packet_queue_push = return_advance && return_tag_ok;
    assign packet_valid = (packet_count_q != 0) && !tag_mismatch_sticky;
    assign packet_addr = packet_head_addr_q;
    assign packet_data = packet_data_q[packet_rd_ptr_q];

    // The return slot can accept a new synchronous-FIFO response when it is
    // empty or when its resident response advances into registered free queue
    // space.  Deliberately do not anticipate packet_pop here.  Thus a truly
    // full three-word elastic pipeline takes one conservative recovery cycle,
    // but issue_read has no packet_ready/collision combinational dependency.
    wire return_slot_released = !return_valid_q || packet_queue_has_space;
    wire read_needed = enable && active && !tag_mismatch_sticky &&
        (rd_count < pixels_to_collect);
    wire issue_read = read_needed && columns_ready && return_slot_released;
    wire completing_packet =
        packet_pop && (out_count == pixels_to_collect - 16'd1);

    assign psum_fifo_rd_en = issue_read ? COL_MASK : 32'd0;
    assign perf_column_empty_wait = read_needed && !columns_ready;
    assign context_active = active;
    assign context_wr_bank = active_wr_bank;
    assign context_is_final = active_is_final;
    assign context_epoch = active_epoch;
    assign context_ifm_bank = active_ifm_bank;
    assign context_id = active_context_id;
    assign context_parent_epoch = active_parent_epoch;
    assign context_parent_context_id = active_parent_context_id;
    assign context_first = active_first;
    assign trace_context_active = active && active_trace_match;
    assign fail_stop = tag_mismatch_sticky;

    always @(posedge clk) begin
        if (rst) begin
            ctx_wptr <= {(CTX_AW+1){1'b0}};
        end else if (ctx_push) begin
            ctx_mem[ctx_wptr[CTX_AW-1:0]] <= {
                ctx_num_pixels, ctx_is_final, ctx_wr_bank,
                ctx_cout_base, ctx_cout_valid, ctx_trace_match,
                ctx_epoch, ctx_ifm_bank, ctx_context_id,
                ctx_parent_epoch, ctx_parent_context_id, ctx_first
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
            active_epoch <= {EPOCH_W{1'b0}};
            active_ifm_bank <= 1'b0;
            active_context_id <= {CONTEXT_W{1'b0}};
            active_parent_epoch <= {EPOCH_W{1'b0}};
            active_parent_context_id <= {CONTEXT_W{1'b0}};
            active_first <= 1'b0;
            rd_count <= 16'd0;
            out_count <= 16'd0;
            return_valid_q <= 1'b0;
            return_addr_q <= {ADDR_W{1'b0}};
            packet_count_q <= 2'd0;
            packet_rd_ptr_q <= 1'b0;
            packet_wr_ptr_q <= 1'b0;
            packet_head_addr_q <= {ADDR_W{1'b0}};
            bad_tag_event_q <= 1'b0;
            // packet_addr_q/packet_data_q are payload-only.  Empty occupancy
            // masks their contents after reset, so the RAMs need no reset
            // cone; packet_head_addr_q provides a deterministic zero address.
            packet_is_final <= 1'b0;
            packet_wr_bank <= 1'b0;
            packet_cout_base <= 11'd0;
            packet_cout_valid <= 11'd0;
            packet_epoch <= {EPOCH_W{1'b0}};
            packet_ifm_bank <= 1'b0;
            packet_context_id <= {CONTEXT_W{1'b0}};
            packet_parent_epoch <= {EPOCH_W{1'b0}};
            packet_parent_context_id <= {CONTEXT_W{1'b0}};
            packet_first <= 1'b0;
            context_start <= 1'b0;
            context_done <= 1'b0;
            partial_done <= 1'b0;
            final_done <= 1'b0;
            perf_context_push <= 1'b0;
            perf_context_pop <= 1'b0;
            trace_context_done <= 1'b0;
            context_done_epoch <= {EPOCH_W{1'b0}};
            context_done_ifm_bank <= 1'b0;
            context_done_context_id <= {CONTEXT_W{1'b0}};
            context_done_parent_epoch <= {EPOCH_W{1'b0}};
            context_done_parent_context_id <= {CONTEXT_W{1'b0}};
            context_done_first <= 1'b0;
            context_done_final <= 1'b0;
            context_done_wr_bank <= 1'b0;
            tag_mismatch_sticky <= 1'b0;
            tag_mismatch_count <= 32'd0;
        end else begin
            context_start <= 1'b0;
            context_done <= 1'b0;
            partial_done <= 1'b0;
            final_done <= 1'b0;
            perf_context_push <= ctx_push;
            perf_context_pop <= 1'b0;
            trace_context_done <= 1'b0;
            bad_tag_event_q <= bad_tag_return;

            // Payload storage advances from the registered return slot and
            // registered queue occupancy only.  Keep this write enable out of
            // the descriptor-match/completing-packet branch below; a legal
            // final pop cannot coincide with an additional return, and any
            // fault-induced coincidence is immediately masked by the queue
            // occupancy clear.
            if (return_advance) begin
                packet_addr_q[packet_wr_ptr_q] <= return_addr_q;
                packet_data_q[packet_wr_ptr_q] <= psum_fifo_rd_data;
            end

            if (bad_tag_event_q)
                tag_mismatch_count <= tag_mismatch_count + 1'b1;

            if (!enable) begin
                // Disable abandons the active elastic pipeline, matching the
                // legacy single-slot behavior.  It deliberately does not
                // recover a sticky tag error; only rst starts a new lifetime.
                active <= 1'b0;
                return_valid_q <= 1'b0;
                packet_count_q <= 2'd0;
                packet_rd_ptr_q <= 1'b0;
                packet_wr_ptr_q <= 1'b0;
                packet_head_addr_q <= {ADDR_W{1'b0}};
                rd_count <= 16'd0;
                out_count <= 16'd0;
            end else begin
                if (!active && !ctx_empty) begin
                    {
                        active_num_pixels, active_is_final, active_wr_bank,
                        active_cout_base, active_cout_valid, active_trace_match,
                        active_epoch, active_ifm_bank, active_context_id,
                        active_parent_epoch, active_parent_context_id,
                        active_first
                    } <= ctx_mem[ctx_rptr[CTX_AW-1:0]];
                    ctx_rptr <= ctx_rptr + 1'b1;
                    active <= 1'b1;
                    rd_count <= 16'd0;
                    out_count <= 16'd0;
                    return_valid_q <= 1'b0;
                    packet_count_q <= 2'd0;
                    packet_rd_ptr_q <= 1'b0;
                    packet_wr_ptr_q <= 1'b0;
                    packet_head_addr_q <= {ADDR_W{1'b0}};
                    context_start <= 1'b1;
                    perf_context_pop <= 1'b1;
                end else if (active) begin
                    if (completing_packet) begin
                        active <= 1'b0;
                        active_trace_match <= 1'b0;
                        return_valid_q <= 1'b0;
                        packet_count_q <= 2'd0;
                        packet_rd_ptr_q <= 1'b0;
                        packet_wr_ptr_q <= 1'b0;
                        packet_head_addr_q <= {ADDR_W{1'b0}};
                        context_done <= 1'b1;
                        context_done_epoch <= active_epoch;
                        context_done_ifm_bank <= active_ifm_bank;
                        context_done_context_id <= active_context_id;
                        context_done_parent_epoch <= active_parent_epoch;
                        context_done_parent_context_id <=
                            active_parent_context_id;
                        context_done_first <= active_first;
                        context_done_final <= active_is_final;
                        context_done_wr_bank <= active_wr_bank;
                        trace_context_done <= active_trace_match;
                        partial_done <= !active_is_final;
                        final_done <= active_is_final;
                    end else begin
                        if (packet_pop) begin
                            if (packet_count_q > 1) begin
                                // The successor is already resident.  Read
                                // it explicitly before advancing rd_ptr.
                                packet_head_addr_q <=
                                    packet_addr_q[packet_rd_ptr_next];
                            end else if (packet_queue_push) begin
                                // A one-entry queue is replaced on this edge;
                                // bypass the simultaneous RAM write.
                                packet_head_addr_q <= return_addr_q;
                            end else begin
                                packet_head_addr_q <= {ADDR_W{1'b0}};
                            end
                        end else if (packet_queue_push &&
                                     (packet_count_q == 0)) begin
                            // Empty-to-nonempty transition: expose the return
                            // address immediately after the accepting edge.
                            packet_head_addr_q <= return_addr_q;
                        end

                        if (packet_pop) begin
                            out_count <= out_count + 1'b1;
                            packet_rd_ptr_q <= packet_rd_ptr_q + 1'b1;
                        end

                        if (return_advance) begin
                            packet_wr_ptr_q <= packet_wr_ptr_q + 1'b1;
                        end

                        case ({packet_queue_push, packet_pop})
                            2'b10: packet_count_q <= packet_count_q + 1'b1;
                            2'b01: packet_count_q <= packet_count_q - 1'b1;
                            default: packet_count_q <= packet_count_q;
                        endcase

                        if (return_slot_released) begin
                            return_valid_q <= issue_read;
                        end
                        if (issue_read) begin
                            return_addr_q <= rd_count[ADDR_W-1:0];
                            rd_count <= rd_count + 1'b1;
                        end
                    end
                end
            end

            if (bad_tag_return) begin
                tag_mismatch_sticky <= 1'b1;
                // The FIFO return cannot be replayed.  Suppress all buffered
                // packets and stop accepting/reading contexts until reset so
                // no data can retire under an uncertain descriptor identity.
                // Occupancy invalidates the queue; neither pointer needs
                // realignment here.  A same-edge push/pop may advance its
                // owning pointer, and reset is the only recovery mechanism.
                return_valid_q <= 1'b0;
                packet_count_q <= 2'd0;
                packet_head_addr_q <= {ADDR_W{1'b0}};
            end

            packet_is_final <= active_is_final;
            packet_wr_bank <= active_wr_bank;
            packet_cout_base <= active_cout_base;
            packet_cout_valid <= active_cout_valid;
            packet_epoch <= active_epoch;
            packet_ifm_bank <= active_ifm_bank;
            packet_context_id <= active_context_id;
            packet_parent_epoch <= active_parent_epoch;
            packet_parent_context_id <= active_parent_context_id;
            packet_first <= active_first;
        end
    end
endmodule

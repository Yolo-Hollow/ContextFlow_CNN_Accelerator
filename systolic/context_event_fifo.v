`timescale 1ns / 1ps

// Small, reusable event queue for context-side state changes such as PSUM
// alloc/commit/release.  Events use a conventional valid/ready contract: an
// input event must remain stable until in_valid && in_ready.  A full queue
// deasserts in_ready even when the head is popped in the same cycle; this
// makes a full-queue submission visible as an overflow attempt and avoids
// silently accepting an unreserved pulse.
//
// The queue is registered (not fall-through).  Simultaneous push/pop is
// supported whenever the queue is not full, preserving both occupancy and
// FIFO order.  overflow_attempt is a per-cycle indication; overflow_sticky
// remains set until synchronous reset so the caller can enter fail-stop if a
// producer violates the handshake.
module context_event_fifo #(
    parameter WIDTH = 32,
    parameter DEPTH = 4,
    parameter AW = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    // Preserve the legacy asynchronous head by default.  Timing-sensitive
    // consumers may select a registered head without changing the queue
    // handshake or occupancy behavior.
    parameter REGISTERED_HEAD = 0
) (
    input  wire                 clk,
    input  wire                 rst,

    input  wire                 in_valid,
    output wire                 in_ready,
    input  wire [WIDTH-1:0]     in_data,

    output wire                 out_valid,
    input  wire                 out_ready,
    output wire [WIDTH-1:0]     out_data,

    output wire                 empty,
    output wire                 full,
    output wire [AW:0]          level,
    output wire                 overflow_attempt,
    output reg                  overflow_sticky
);
    initial begin
        if (WIDTH < 1)
            $error("context_event_fifo WIDTH must be positive");
        if (DEPTH < 1)
            $error("context_event_fifo DEPTH must be positive");
        if (DEPTH > (1 << AW))
            $error("context_event_fifo DEPTH exceeds address width");
        if ((REGISTERED_HEAD != 0) && (REGISTERED_HEAD != 1))
            $error("context_event_fifo REGISTERED_HEAD must be 0 or 1");
    end

    (* ram_style = "distributed" *)
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW-1:0] wr_ptr_q;
    reg [AW-1:0] rd_ptr_q;
    reg [AW:0] count_q;

    assign empty = (count_q == 0);
    assign full = (count_q == DEPTH);
    assign level = count_q;

    assign in_ready = !full;
    assign out_valid = !empty;
    assign overflow_attempt = in_valid && !in_ready;

    wire push_fire = in_valid && in_ready;
    wire pop_fire = out_valid && out_ready;

    function [AW-1:0] ptr_next;
        input [AW-1:0] ptr;
        begin
            if (ptr == DEPTH - 1)
                ptr_next = {AW{1'b0}};
            else
                ptr_next = ptr + 1'b1;
        end
    endfunction

    // Keep the RAM subscript explicit.  Besides making the prefetch case
    // obvious to synthesis, this avoids the XSIM 2022.2 issue seen with a
    // function call used directly as an unpacked-memory index.
    wire [AW-1:0] rd_ptr_next = ptr_next(rd_ptr_q);

    generate
        if (REGISTERED_HEAD == 0) begin : gen_async_head
            assign out_data = out_valid ? mem[rd_ptr_q] : {WIDTH{1'b0}};
        end else begin : gen_registered_head
            reg [WIDTH-1:0] head_q;

            assign out_data = out_valid ? head_q : {WIDTH{1'b0}};

            always @(posedge clk) begin
                if (rst) begin
                    head_q <= {WIDTH{1'b0}};
                end else if (push_fire && empty) begin
                    // The first word becomes visible immediately after the
                    // accepting edge; do not wait for a RAM read cycle.
                    head_q <= in_data;
                end else if (push_fire && pop_fire && (count_q == 1)) begin
                    // The sole resident word is replaced at the next read
                    // pointer.  Bypass the same-edge RAM write explicitly.
                    head_q <= in_data;
                end else if (pop_fire && (count_q > 1)) begin
                    // There is already a valid successor in RAM.  Prefetch it
                    // while advancing the read pointer so throughput is
                    // unchanged and no output bubble is introduced.
                    head_q <= mem[rd_ptr_next];
                end
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr_q <= {AW{1'b0}};
            rd_ptr_q <= {AW{1'b0}};
            count_q <= {(AW+1){1'b0}};
            overflow_sticky <= 1'b0;
        end else begin
            if (overflow_attempt)
                overflow_sticky <= 1'b1;

            if (push_fire) begin
                mem[wr_ptr_q] <= in_data;
                wr_ptr_q <= ptr_next(wr_ptr_q);
            end
            if (pop_fire)
                rd_ptr_q <= ptr_next(rd_ptr_q);

            case ({push_fire, pop_fire})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end
endmodule

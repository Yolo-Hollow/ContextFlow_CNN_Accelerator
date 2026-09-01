`timescale 1ns / 1ps

// Small synthesizable descriptor queue used between context allocation,
// issue, array retirement, and collection.  The complete descriptor is moved
// atomically; consumers must not reconstruct any field from live scheduler
// signals after the push handshake.
//
// The queue uses standard valid/ready handshakes.  When full, a pop in the
// same cycle makes push_ready high so the head can be replaced without a
// bubble or descriptor loss.  When empty this is deliberately not a
// fall-through queue: a pushed descriptor becomes pop_valid on the next cycle.
//
// overflow/underflow are diagnostic unavailable-request episodes.  A valid
// held against a full queue, or ready held against an empty queue, is never
// dropped and increments the corresponding count only once until the request
// becomes available or is withdrawn.
module context_lifecycle_queue #(
    parameter DEPTH = 4,
    parameter AW = 2,
    parameter EPOCH_W = 8,
    parameter TILE_W = 16,
    parameter COUT_W = 11,
    parameter K_PASS_W = 14,
    parameter PIXEL_W = 16,
    parameter CONTEXT_W = 16,
    parameter REGISTERED_HEAD = 0
) (
    input  wire                     clk,
    input  wire                     rst,

    input  wire                     push_valid,
    output wire                     push_ready,
    input  wire [EPOCH_W-1:0]       push_epoch,
    input  wire                     push_ifm_bank,
    input  wire [TILE_W-1:0]        push_tile,
    input  wire [COUT_W-1:0]        push_cout_base,
    input  wire [COUT_W-1:0]        push_cout_valid,
    input  wire [K_PASS_W-1:0]      push_k_pass,
    input  wire [PIXEL_W-1:0]       push_num_pixels,
    input  wire                     push_first,
    input  wire                     push_final,
    input  wire                     push_psum_rd_bank,
    input  wire                     push_psum_wr_bank,
    input  wire [EPOCH_W-1:0]       push_parent_epoch,
    input  wire [CONTEXT_W-1:0]     push_parent_context,
    input  wire [CONTEXT_W-1:0]     push_context_id,

    output wire                     pop_valid,
    input  wire                     pop_ready,
    output wire [EPOCH_W-1:0]       pop_epoch,
    output wire                     pop_ifm_bank,
    output wire [TILE_W-1:0]        pop_tile,
    output wire [COUT_W-1:0]        pop_cout_base,
    output wire [COUT_W-1:0]        pop_cout_valid,
    output wire [K_PASS_W-1:0]      pop_k_pass,
    output wire [PIXEL_W-1:0]       pop_num_pixels,
    output wire                     pop_first,
    output wire                     pop_final,
    output wire                     pop_psum_rd_bank,
    output wire                     pop_psum_wr_bank,
    output wire [EPOCH_W-1:0]       pop_parent_epoch,
    output wire [CONTEXT_W-1:0]     pop_parent_context,
    output wire [CONTEXT_W-1:0]     pop_context_id,

    output wire                     empty,
    output wire                     full,
    output wire [AW:0]              level,
    output reg  [31:0]              push_count,
    output reg  [31:0]              pop_count,
    output reg                      overflow_sticky,
    output reg  [31:0]              overflow_count,
    output reg                      underflow_sticky,
    output reg  [31:0]              underflow_count
);
    localparam DESC_W = EPOCH_W + 1 + TILE_W + COUT_W + COUT_W +
        K_PASS_W + PIXEL_W + 1 + 1 + 1 + 1 + EPOCH_W +
        CONTEXT_W + CONTEXT_W;

    initial begin
        if (DEPTH < 1)
            $error("context_lifecycle_queue DEPTH must be positive");
        if (DEPTH > (1 << AW))
            $error("context_lifecycle_queue DEPTH exceeds address width");
    end

    (* ram_style = "distributed" *)
    reg [DESC_W-1:0] desc_mem [0:DEPTH-1];
    reg [AW-1:0] wr_ptr_q;
    reg [AW-1:0] rd_ptr_q;
    reg [AW:0] count_q;
    reg [DESC_W-1:0] head_desc_q;
    reg head_valid_q;
    reg overflow_episode_q;
    reg underflow_episode_q;

    wire [DESC_W-1:0] push_desc = {
        push_epoch,
        push_ifm_bank,
        push_tile,
        push_cout_base,
        push_cout_valid,
        push_k_pass,
        push_num_pixels,
        push_first,
        push_final,
        push_psum_rd_bank,
        push_psum_wr_bank,
        push_parent_epoch,
        push_parent_context,
        push_context_id
    };

    assign empty = (count_q == 0);
    assign full = (count_q == DEPTH);
    assign level = count_q;
    assign pop_valid = (REGISTERED_HEAD != 0) ? head_valid_q : !empty;

    // A full queue accepts a replacement exactly when its current head is
    // also accepted.  Since full implies pop_valid, pop_ready is sufficient.
    assign push_ready = !full || pop_ready;

    wire push_fire = push_valid && push_ready;
    wire pop_fire = pop_valid && pop_ready;
    wire overflow_attempt = push_valid && !push_ready;
    wire underflow_attempt = pop_ready && !pop_valid;

    wire [DESC_W-1:0] pop_desc = pop_valid ?
        ((REGISTERED_HEAD != 0) ? head_desc_q : desc_mem[rd_ptr_q]) :
        {DESC_W{1'b0}};
    assign {
        pop_epoch,
        pop_ifm_bank,
        pop_tile,
        pop_cout_base,
        pop_cout_valid,
        pop_k_pass,
        pop_num_pixels,
        pop_first,
        pop_final,
        pop_psum_rd_bank,
        pop_psum_wr_bank,
        pop_parent_epoch,
        pop_parent_context,
        pop_context_id
    } = pop_desc;

    function [AW-1:0] ptr_next;
        input [AW-1:0] ptr;
        begin
            if (ptr == DEPTH - 1)
                ptr_next = {AW{1'b0}};
            else
                ptr_next = ptr + 1'b1;
        end
    endfunction

    // Keep the registered-head prefetch address/data explicit so simulation
    // and synthesis see one asynchronous RAM read feeding the head register,
    // independent of the write- and read-pointer updates on the same edge.
    wire [AW-1:0] wr_ptr_next = ptr_next(wr_ptr_q);
    wire [AW-1:0] rd_ptr_next = ptr_next(rd_ptr_q);
    wire [DESC_W-1:0] registered_next_head_desc = desc_mem[rd_ptr_next];

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr_q <= {AW{1'b0}};
            rd_ptr_q <= {AW{1'b0}};
            count_q <= {(AW+1){1'b0}};
            head_valid_q <= 1'b0;
            push_count <= 32'd0;
            pop_count <= 32'd0;
            overflow_sticky <= 1'b0;
            overflow_count <= 32'd0;
            underflow_sticky <= 1'b0;
            underflow_count <= 32'd0;
            overflow_episode_q <= 1'b0;
            underflow_episode_q <= 1'b0;
        end else begin
            overflow_episode_q <= overflow_attempt;
            underflow_episode_q <= underflow_attempt;

            if (overflow_attempt) begin
                overflow_sticky <= 1'b1;
                if (!overflow_episode_q)
                    overflow_count <= overflow_count + 1'b1;
            end
            if (underflow_attempt) begin
                underflow_sticky <= 1'b1;
                if (!underflow_episode_q)
                    underflow_count <= underflow_count + 1'b1;
            end

            if (push_fire) begin
                desc_mem[wr_ptr_q] <= push_desc;
                wr_ptr_q <= wr_ptr_next;
                push_count <= push_count + 1'b1;
            end
            if (pop_fire) begin
                rd_ptr_q <= rd_ptr_next;
                pop_count <= pop_count + 1'b1;
            end

            // Optional timing cut for consumers of a wide descriptor.  The
            // RAM still holds every accepted entry so pointer and occupancy
            // behavior remain identical to the asynchronous-head mode.  A
            // single-entry replacement must bypass the RAM because the new
            // tail write and the next-head capture happen on the same edge.
            if (REGISTERED_HEAD != 0) begin
                if (pop_fire) begin
                    if (count_q > 1)
                        head_desc_q <= registered_next_head_desc;
                    else if (push_fire)
                        head_desc_q <= push_desc;
                end else if (push_fire && (count_q == 0)) begin
                    head_desc_q <= push_desc;
                end

                case ({push_fire, pop_fire})
                    2'b10: head_valid_q <= 1'b1;
                    2'b01: head_valid_q <= (count_q > 1);
                    2'b11: head_valid_q <= 1'b1;
                    default: head_valid_q <= head_valid_q;
                endcase
            end

            case ({push_fire, pop_fire})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end
endmodule

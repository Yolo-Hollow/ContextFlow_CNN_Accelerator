`timescale 1ns / 1ps

// Background loader for the two stationary-weight banks used by the tagged
// systolic array.  Allocation descriptors and complete-tile credits are
// accepted independently and paired in order.  A tile credit promises that
// every synchronous row FIFO contains COLS words for the corresponding
// descriptor.  The FIFOs share one read enable and return one 16-bit output-
// channel pair per row on the following cycle.
//
// Bank lifecycle (exported through bank*_state):
//   EMPTY -> RESERVED -> LOADING -> READY -> ACTIVE -> RETIRING -> EMPTY
//
// start_valid and retire_valid are event inputs, not requests that may be
// held while waiting.  A start must name a READY bank and matching epoch; a
// retire must name an ACTIVE bank and matching epoch.  Violations fail closed
// and remain sticky until rst or soft_reset.
module weight_context_preloader #(
    parameter integer ROWS = 18,
    parameter integer COLS = 16,
    parameter integer EPOCH_W = 8
) (
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         soft_reset,

    input  wire                         alloc_valid,
    output wire                         alloc_ready,
    input  wire                         alloc_bank,
    input  wire [EPOCH_W-1:0]           alloc_epoch,

    input  wire                         weight_tile_credit_valid,
    output wire                         weight_tile_credit_ready,
    output wire [1:0]                   weight_credit_level,

    input  wire [ROWS-1:0]              row_fifo_empty,
    output wire                         row_fifo_rd_en,
    input  wire [ROWS*16-1:0]           row_fifo_rd_data,

    output wire                         array_w_load,
    output wire [4:0]                   array_w_col,
    output wire                         array_w_bank,
    output wire [ROWS*16-1:0]           array_w_row_data,

    input  wire                         start_valid,
    output wire                         start_ready,
    output wire                         start_fire,
    input  wire                         start_bank,
    input  wire [EPOCH_W-1:0]           start_epoch,

    input  wire                         retire_valid,
    output wire                         retire_match,
    input  wire                         retire_bank,
    input  wire [EPOCH_W-1:0]           retire_epoch,

    output wire [1:0]                   bank_ready,
    output wire [1:0]                   bank_active,
    output wire [1:0]                   bank_epoch_valid,
    output wire [EPOCH_W-1:0]           bank0_epoch,
    output wire [EPOCH_W-1:0]           bank1_epoch,
    output wire [2:0]                   bank0_state,
    output wire [2:0]                   bank1_state,
    output wire                         preload_busy,

    output wire                         fatal_error,
    output wire                         sticky_protocol_error,
    output wire                         sticky_owner_error,
    output wire                         sticky_epoch_error,

    output reg  [31:0]                  alloc_count,
    output reg  [31:0]                  tile_credit_accept_count,
    output reg  [31:0]                  preload_commit_count,
    output reg  [31:0]                  array_write_count,
    output reg  [31:0]                  start_match_count,
    output reg  [31:0]                  start_miss_count,
    output reg  [31:0]                  retire_match_count,
    output reg  [31:0]                  protocol_error_count,
    output reg  [31:0]                  owner_error_count,
    output reg  [31:0]                  epoch_error_count
);
    localparam [2:0] BANK_EMPTY     = 3'd0;
    localparam [2:0] BANK_RESERVED  = 3'd1;
    localparam [2:0] BANK_LOADING   = 3'd2;
    localparam [2:0] BANK_READY     = 3'd3;
    localparam [2:0] BANK_ACTIVE    = 3'd4;
    localparam [2:0] BANK_RETIRING  = 3'd5;

    initial begin
        if (ROWS < 1)
            $error("weight_context_preloader requires ROWS >= 1");
        if ((COLS < 1) || (COLS > 32))
            $error("weight_context_preloader requires 1 <= COLS <= 32");
        if (EPOCH_W < 1)
            $error("weight_context_preloader requires EPOCH_W >= 1");
    end

    reg [2:0] bank0_state_q;
    reg [2:0] bank1_state_q;
    reg [EPOCH_W-1:0] bank0_epoch_q;
    reg [EPOCH_W-1:0] bank1_epoch_q;
    reg bank0_epoch_valid_q;
    reg bank1_epoch_valid_q;

    // Two-entry allocation descriptor queue.  Credits are a separate
    // two-entry counter because the tile loader may finish before or after
    // context allocation; ordering binds the next credit to the queue head.
    reg desc_bank_q [0:1];
    reg [EPOCH_W-1:0] desc_epoch_q [0:1];
    reg desc_wr_ptr_q;
    reg desc_rd_ptr_q;
    reg [1:0] desc_count_q;
    reg [1:0] credit_count_q;

    reg loading_q;
    reg loading_bank_q;
    reg [4:0] issue_col_q;
    reg reads_done_q;
    reg read_pending_q;
    reg read_bank_q;
    reg [4:0] read_col_q;

    reg sticky_protocol_error_q;
    reg sticky_owner_error_q;
    reg sticky_epoch_error_q;

    wire any_error = sticky_protocol_error_q |
        sticky_owner_error_q | sticky_epoch_error_q;
    wire reset_active = rst | soft_reset;
    wire preload_commit_event;

    wire [2:0] alloc_target_state = alloc_bank ?
        bank1_state_q : bank0_state_q;
    wire alloc_other_epoch_valid = alloc_bank ?
        bank0_epoch_valid_q : bank1_epoch_valid_q;
    wire [EPOCH_W-1:0] alloc_other_epoch = alloc_bank ?
        bank0_epoch_q : bank1_epoch_q;
    wire alloc_epoch_conflict = alloc_other_epoch_valid &&
        (alloc_other_epoch == alloc_epoch);
    wire alloc_queue_space = desc_count_q < 2;
    wire alloc_base_ready = alloc_queue_space &&
        (alloc_target_state == BANK_EMPTY) && !any_error && !reset_active;
    wire alloc_epoch_error_event = alloc_valid && alloc_base_ready &&
        alloc_epoch_conflict;
    assign alloc_ready = alloc_base_ready && !alloc_epoch_conflict;
    wire alloc_fire = alloc_valid && alloc_ready;

    // Standard ready/valid credit input.  A completing preload consumes one
    // credit on this edge, so a held valid may refill the full queue
    // atomically.  valid while !ready is legal backpressure, not overflow.
    assign weight_tile_credit_ready =
        ((credit_count_q < 2) || preload_commit_event) &&
        !any_error && !reset_active;
    wire credit_fire = weight_tile_credit_valid &&
        weight_tile_credit_ready;
    assign weight_credit_level = credit_count_q;

    wire head_bank = desc_bank_q[desc_rd_ptr_q];
    wire [EPOCH_W-1:0] head_epoch = desc_epoch_q[desc_rd_ptr_q];
    wire [2:0] head_state = head_bank ? bank1_state_q : bank0_state_q;
    wire head_epoch_valid = head_bank ?
        bank1_epoch_valid_q : bank0_epoch_valid_q;
    wire [EPOCH_W-1:0] head_bank_epoch = head_bank ?
        bank1_epoch_q : bank0_epoch_q;
    wire have_load_pair = !loading_q && (desc_count_q != 0) &&
        (credit_count_q != 0);
    wire all_rows_nonempty = ~(|row_fifo_empty);
    wire head_descriptor_match = (head_state == BANK_RESERVED) &&
        head_epoch_valid && (head_bank_epoch == head_epoch);
    wire begin_load = have_load_pair && head_descriptor_match &&
        all_rows_nonempty && !any_error && !reset_active;
    wire descriptor_protocol_error_event = have_load_pair &&
        !head_descriptor_match && !any_error && !reset_active;
    wire row_protocol_error_event =
        ((have_load_pair && head_descriptor_match) ||
         (loading_q && !reads_done_q)) &&
        !all_rows_nonempty && !any_error && !reset_active;

    assign row_fifo_rd_en = loading_q && !reads_done_q &&
        all_rows_nonempty && !any_error && !reset_active;
    assign array_w_load = read_pending_q && !any_error && !reset_active;
    assign array_w_col = read_col_q;
    assign array_w_bank = read_bank_q;
    assign array_w_row_data = row_fifo_rd_data;
    assign preload_commit_event = array_w_load &&
        (array_w_col == COLS - 1);

    wire [2:0] start_target_state = start_bank ?
        bank1_state_q : bank0_state_q;
    wire start_target_epoch_valid = start_bank ?
        bank1_epoch_valid_q : bank0_epoch_valid_q;
    wire [EPOCH_W-1:0] start_target_epoch = start_bank ?
        bank1_epoch_q : bank0_epoch_q;
    wire start_owner_match = start_target_state == BANK_READY;
    wire start_epoch_match = start_target_epoch_valid &&
        (start_target_epoch == start_epoch);
    assign start_ready = !any_error && !reset_active &&
        start_owner_match && start_epoch_match;
    assign start_fire = start_valid && start_ready;
    wire start_owner_error_event = start_valid && !any_error &&
        !reset_active && !start_owner_match;
    wire start_epoch_error_event = start_valid && !any_error &&
        !reset_active && start_owner_match && !start_epoch_match;

    wire [2:0] retire_target_state = retire_bank ?
        bank1_state_q : bank0_state_q;
    wire retire_target_epoch_valid = retire_bank ?
        bank1_epoch_valid_q : bank0_epoch_valid_q;
    wire [EPOCH_W-1:0] retire_target_epoch = retire_bank ?
        bank1_epoch_q : bank0_epoch_q;
    wire retire_owner_match = retire_target_state == BANK_ACTIVE;
    wire retire_epoch_matches = retire_target_epoch_valid &&
        (retire_target_epoch == retire_epoch);
    assign retire_match = retire_valid && !any_error && !reset_active &&
        retire_owner_match && retire_epoch_matches;
    wire retire_owner_error_event = retire_valid && !any_error &&
        !reset_active && !retire_owner_match;
    wire retire_epoch_error_event = retire_valid && !any_error &&
        !reset_active && retire_owner_match && !retire_epoch_matches;

    assign bank_ready = {
        bank1_state_q == BANK_READY,
        bank0_state_q == BANK_READY
    };
    assign bank_active = {
        bank1_state_q == BANK_ACTIVE,
        bank0_state_q == BANK_ACTIVE
    };
    assign bank_epoch_valid = {
        bank1_epoch_valid_q,
        bank0_epoch_valid_q
    };
    assign bank0_epoch = bank0_epoch_q;
    assign bank1_epoch = bank1_epoch_q;
    assign bank0_state = bank0_state_q;
    assign bank1_state = bank1_state_q;
    assign preload_busy = loading_q || (desc_count_q != 0) ||
        (credit_count_q != 0);
    assign sticky_protocol_error = sticky_protocol_error_q;
    assign sticky_owner_error = sticky_owner_error_q;
    assign sticky_epoch_error = sticky_epoch_error_q;
    assign fatal_error = any_error;

    always @(posedge clk) begin
        if (reset_active) begin
            bank0_state_q <= BANK_EMPTY;
            bank1_state_q <= BANK_EMPTY;
            bank0_epoch_q <= {EPOCH_W{1'b0}};
            bank1_epoch_q <= {EPOCH_W{1'b0}};
            bank0_epoch_valid_q <= 1'b0;
            bank1_epoch_valid_q <= 1'b0;
            desc_bank_q[0] <= 1'b0;
            desc_bank_q[1] <= 1'b0;
            desc_epoch_q[0] <= {EPOCH_W{1'b0}};
            desc_epoch_q[1] <= {EPOCH_W{1'b0}};
            desc_wr_ptr_q <= 1'b0;
            desc_rd_ptr_q <= 1'b0;
            desc_count_q <= 2'd0;
            credit_count_q <= 2'd0;
            loading_q <= 1'b0;
            loading_bank_q <= 1'b0;
            issue_col_q <= 5'd0;
            reads_done_q <= 1'b0;
            read_pending_q <= 1'b0;
            read_bank_q <= 1'b0;
            read_col_q <= 5'd0;
            sticky_protocol_error_q <= 1'b0;
            sticky_owner_error_q <= 1'b0;
            sticky_epoch_error_q <= 1'b0;
            alloc_count <= 32'd0;
            tile_credit_accept_count <= 32'd0;
            preload_commit_count <= 32'd0;
            array_write_count <= 32'd0;
            start_match_count <= 32'd0;
            start_miss_count <= 32'd0;
            retire_match_count <= 32'd0;
            protocol_error_count <= 32'd0;
            owner_error_count <= 32'd0;
            epoch_error_count <= 32'd0;
        end else begin
            // RETIRING is an explicit one-cycle reuse fence.
            if (bank0_state_q == BANK_RETIRING) begin
                bank0_state_q <= BANK_EMPTY;
                bank0_epoch_valid_q <= 1'b0;
            end
            if (bank1_state_q == BANK_RETIRING) begin
                bank1_state_q <= BANK_EMPTY;
                bank1_epoch_valid_q <= 1'b0;
            end

            read_pending_q <= row_fifo_rd_en;
            if (row_fifo_rd_en) begin
                read_bank_q <= loading_bank_q;
                read_col_q <= issue_col_q;
                if (issue_col_q == COLS - 1)
                    reads_done_q <= 1'b1;
                else
                    issue_col_q <= issue_col_q + 1'b1;
            end

            if (begin_load) begin
                loading_q <= 1'b1;
                loading_bank_q <= head_bank;
                issue_col_q <= 5'd0;
                reads_done_q <= 1'b0;
                if (head_bank)
                    bank1_state_q <= BANK_LOADING;
                else
                    bank0_state_q <= BANK_LOADING;
            end

            if (alloc_fire) begin
                desc_bank_q[desc_wr_ptr_q] <= alloc_bank;
                desc_epoch_q[desc_wr_ptr_q] <= alloc_epoch;
                desc_wr_ptr_q <= desc_wr_ptr_q + 1'b1;
                if (alloc_bank) begin
                    bank1_state_q <= BANK_RESERVED;
                    bank1_epoch_q <= alloc_epoch;
                    bank1_epoch_valid_q <= 1'b1;
                end else begin
                    bank0_state_q <= BANK_RESERVED;
                    bank0_epoch_q <= alloc_epoch;
                    bank0_epoch_valid_q <= 1'b1;
                end
                alloc_count <= alloc_count + 1'b1;
            end

            if (credit_fire)
                tile_credit_accept_count <=
                    tile_credit_accept_count + 1'b1;

            if (array_w_load)
                array_write_count <= array_write_count + 1'b1;

            if (preload_commit_event) begin
                loading_q <= 1'b0;
                reads_done_q <= 1'b0;
                desc_rd_ptr_q <= desc_rd_ptr_q + 1'b1;
                if (loading_bank_q)
                    bank1_state_q <= BANK_READY;
                else
                    bank0_state_q <= BANK_READY;
                preload_commit_count <= preload_commit_count + 1'b1;
            end

            case ({alloc_fire, preload_commit_event})
                2'b10: desc_count_q <= desc_count_q + 1'b1;
                2'b01: desc_count_q <= desc_count_q - 1'b1;
                default: desc_count_q <= desc_count_q;
            endcase
            case ({credit_fire, preload_commit_event})
                2'b10: credit_count_q <= credit_count_q + 1'b1;
                2'b01: credit_count_q <= credit_count_q - 1'b1;
                default: credit_count_q <= credit_count_q;
            endcase

            if (start_fire) begin
                if (start_bank)
                    bank1_state_q <= BANK_ACTIVE;
                else
                    bank0_state_q <= BANK_ACTIVE;
                start_match_count <= start_match_count + 1'b1;
            end

            if (retire_match) begin
                if (retire_bank)
                    bank1_state_q <= BANK_RETIRING;
                else
                    bank0_state_q <= BANK_RETIRING;
                retire_match_count <= retire_match_count + 1'b1;
            end

            if (descriptor_protocol_error_event ||
                row_protocol_error_event) begin
                sticky_protocol_error_q <= 1'b1;
                protocol_error_count <= protocol_error_count + 1'b1;
            end
            if (start_owner_error_event || retire_owner_error_event) begin
                sticky_owner_error_q <= 1'b1;
                owner_error_count <= owner_error_count + 1'b1;
            end
            if (alloc_epoch_error_event || start_epoch_error_event ||
                retire_epoch_error_event) begin
                sticky_epoch_error_q <= 1'b1;
                epoch_error_count <= epoch_error_count + 1'b1;
            end
            if (start_owner_error_event || start_epoch_error_event)
                start_miss_count <= start_miss_count + 1'b1;
        end
    end
endmodule

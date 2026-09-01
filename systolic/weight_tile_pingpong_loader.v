`timescale 1ns / 1ps

// Two-bank packed weight staging buffer.
//
// One bank may accept the next row-major packed tile while the other bank is
// transposed into the existing per-row FIFOs.  commit_valid closes the current
// write bank and queues it in packet order.  consume_valid is a standard
// held-valid request: waiting for a committed tile is legal and does not raise
// an underflow.  A consume transfers exactly COLS row-pairs and pulses done.
module weight_tile_pingpong_loader #(
    parameter integer ROWS = 18,
    parameter integer COLS = 16,
    parameter integer WEIGHT_W = 8,
    parameter integer ADDR_W = 11
) (
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         soft_reset,

    input  wire                         tile_wr_en,
    input  wire [ADDR_W-1:0]            tile_wr_addr,
    input  wire [WEIGHT_W-1:0]          tile_wr_data,
    input  wire                         tile_wr8_en,
    input  wire [ADDR_W-1:0]            tile_wr8_addr,
    input  wire [WEIGHT_W*8-1:0]        tile_wr8_data,
    input  wire [7:0]                   tile_wr8_keep,
    output wire                         write_ready,

    input  wire                         commit_valid,
    output wire                         commit_ready,
    input  wire                         consume_valid,
    output wire                         consume_ready,

    input  wire [ROWS-1:0]              row_fifo_full,
    output wire [ROWS-1:0]              row_fifo_wr_en,
    output wire [ROWS*WEIGHT_W*2-1:0]   row_fifo_wr_data,
    output reg                          done,
    output wire                         format_busy,

    output wire [1:0]                   committed_level,
    output wire [1:0]                   bank_busy,
    output reg                          sticky_commit_overflow,
    output reg                          sticky_consume_underflow,
    output reg                          sticky_write_no_slot,
    output reg                          sticky_protocol_error,
    output wire                         fatal_error
);
    localparam integer COUT_TILE = COLS * 2;
    localparam integer TILE_WORDS = ROWS * COUT_TILE;
    localparam integer BANK_DEPTH = (TILE_WORDS + 7) / 8;

    initial begin
        if (ROWS < 1)
            $error("weight_tile_pingpong_loader requires ROWS >= 1");
        if ((COLS < 1) || (COLS > 32))
            $error("weight_tile_pingpong_loader requires 1 <= COLS <= 32");
        if (WEIGHT_W < 1)
            $error("weight_tile_pingpong_loader requires WEIGHT_W >= 1");
    end

    // Eight byte-interleaved stripes per staging bank preserve the formatter's
    // ROWS-way asynchronous read while accepting one packed AXIS beat/clock.
    reg [WEIGHT_W-1:0] bank0_s0 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank0_s1 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank0_s2 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank0_s3 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank0_s4 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank0_s5 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank0_s6 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank0_s7 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank1_s0 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank1_s1 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank1_s2 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank1_s3 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank1_s4 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank1_s5 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank1_s6 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] bank1_s7 [0:BANK_DEPTH-1];

    reg fill_valid_q;
    reg fill_bank_q;
    reg fill_touched_q;
    reg [1:0] occupied_q;

    reg committed_bank_q [0:1];
    reg committed_wr_ptr_q;
    reg committed_rd_ptr_q;
    reg [1:0] committed_count_q;

    reg format_busy_q;
    reg format_bank_q;
    reg [4:0] format_col_q;

    wire reset_active = rst | soft_reset;
    assign fatal_error = sticky_commit_overflow |
        sticky_consume_underflow | sticky_write_no_slot |
        sticky_protocol_error;
    assign write_ready = fill_valid_q && !fatal_error && !reset_active;
    assign commit_ready = fill_valid_q && (committed_count_q < 2) &&
        !fatal_error && !reset_active;
    assign consume_ready = !format_busy_q &&
        (committed_count_q != 0) && !fatal_error && !reset_active;
    wire commit_fire = commit_valid && commit_ready;
    wire consume_fire = consume_valid && consume_ready;

    wire formatter_stall = |row_fifo_full;
    wire formatter_fire = format_busy_q && !formatter_stall &&
        !fatal_error && !reset_active;
    wire formatter_done = formatter_fire &&
        (format_col_q == COLS - 1);
    assign row_fifo_wr_en = formatter_fire ?
        {ROWS{1'b1}} : {ROWS{1'b0}};
    assign format_busy = format_busy_q;
    assign committed_level = committed_count_q;
    assign bank_busy = occupied_q;

    function automatic [WEIGHT_W-1:0] read_tile_byte;
        input bank;
        input [ADDR_W-1:0] addr;
        begin
            case ({bank, addr[2:0]})
                4'h0: read_tile_byte = bank0_s0[addr[ADDR_W-1:3]];
                4'h1: read_tile_byte = bank0_s1[addr[ADDR_W-1:3]];
                4'h2: read_tile_byte = bank0_s2[addr[ADDR_W-1:3]];
                4'h3: read_tile_byte = bank0_s3[addr[ADDR_W-1:3]];
                4'h4: read_tile_byte = bank0_s4[addr[ADDR_W-1:3]];
                4'h5: read_tile_byte = bank0_s5[addr[ADDR_W-1:3]];
                4'h6: read_tile_byte = bank0_s6[addr[ADDR_W-1:3]];
                4'h7: read_tile_byte = bank0_s7[addr[ADDR_W-1:3]];
                4'h8: read_tile_byte = bank1_s0[addr[ADDR_W-1:3]];
                4'h9: read_tile_byte = bank1_s1[addr[ADDR_W-1:3]];
                4'ha: read_tile_byte = bank1_s2[addr[ADDR_W-1:3]];
                4'hb: read_tile_byte = bank1_s3[addr[ADDR_W-1:3]];
                4'hc: read_tile_byte = bank1_s4[addr[ADDR_W-1:3]];
                4'hd: read_tile_byte = bank1_s5[addr[ADDR_W-1:3]];
                4'he: read_tile_byte = bank1_s6[addr[ADDR_W-1:3]];
                default: read_tile_byte = bank1_s7[addr[ADDR_W-1:3]];
            endcase
        end
    endfunction

    task automatic write_scalar_byte;
        input bank;
        input [ADDR_W-1:0] addr;
        input [WEIGHT_W-1:0] data;
        begin
            case ({bank, addr[2:0]})
                4'h0: bank0_s0[addr[ADDR_W-1:3]] <= data;
                4'h1: bank0_s1[addr[ADDR_W-1:3]] <= data;
                4'h2: bank0_s2[addr[ADDR_W-1:3]] <= data;
                4'h3: bank0_s3[addr[ADDR_W-1:3]] <= data;
                4'h4: bank0_s4[addr[ADDR_W-1:3]] <= data;
                4'h5: bank0_s5[addr[ADDR_W-1:3]] <= data;
                4'h6: bank0_s6[addr[ADDR_W-1:3]] <= data;
                4'h7: bank0_s7[addr[ADDR_W-1:3]] <= data;
                4'h8: bank1_s0[addr[ADDR_W-1:3]] <= data;
                4'h9: bank1_s1[addr[ADDR_W-1:3]] <= data;
                4'ha: bank1_s2[addr[ADDR_W-1:3]] <= data;
                4'hb: bank1_s3[addr[ADDR_W-1:3]] <= data;
                4'hc: bank1_s4[addr[ADDR_W-1:3]] <= data;
                4'hd: bank1_s5[addr[ADDR_W-1:3]] <= data;
                4'he: bank1_s6[addr[ADDR_W-1:3]] <= data;
                default: bank1_s7[addr[ADDR_W-1:3]] <= data;
            endcase
        end
    endtask

    genvar row;
    generate
        for (row = 0; row < ROWS; row = row + 1) begin : row_pack
            wire [ADDR_W-1:0] addr0 =
                row*COUT_TILE + {format_col_q, 1'b0};
            wire [ADDR_W-1:0] addr1 =
                row*COUT_TILE + {format_col_q, 1'b0} + 1'b1;
            assign row_fifo_wr_data[
                row*WEIGHT_W*2 +: WEIGHT_W] =
                format_busy_q ?
                read_tile_byte(format_bank_q, addr0) :
                {WEIGHT_W{1'b0}};
            assign row_fifo_wr_data[
                row*WEIGHT_W*2 + WEIGHT_W +: WEIGHT_W] =
                format_busy_q ?
                read_tile_byte(format_bank_q, addr1) :
                {WEIGHT_W{1'b0}};
        end
    endgenerate

    integer lane;
    always @(posedge clk) begin
        if (reset_active) begin
            fill_valid_q <= 1'b1;
            fill_bank_q <= 1'b0;
            fill_touched_q <= 1'b0;
            occupied_q <= 2'b00;
            committed_wr_ptr_q <= 1'b0;
            committed_rd_ptr_q <= 1'b0;
            committed_count_q <= 2'd0;
            format_busy_q <= 1'b0;
            format_bank_q <= 1'b0;
            format_col_q <= 5'd0;
            done <= 1'b0;
            sticky_commit_overflow <= 1'b0;
            sticky_consume_underflow <= 1'b0;
            sticky_write_no_slot <= 1'b0;
            sticky_protocol_error <= 1'b0;
        end else begin
            done <= 1'b0;

            if (tile_wr_en && tile_wr8_en)
                sticky_protocol_error <= 1'b1;
            if ((tile_wr_en || tile_wr8_en) && !write_ready)
                sticky_write_no_slot <= 1'b1;
            if (commit_valid && !commit_ready)
                sticky_commit_overflow <= 1'b1;
            // consume_valid is held until ready; an empty queue is a legal
            // wait state, so sticky_consume_underflow intentionally remains 0.
            if (commit_fire &&
                !(fill_touched_q || tile_wr_en || tile_wr8_en))
                sticky_protocol_error <= 1'b1;

            if (tile_wr_en && write_ready &&
                (tile_wr_addr < TILE_WORDS)) begin
                write_scalar_byte(fill_bank_q, tile_wr_addr,
                                  tile_wr_data);
                fill_touched_q <= 1'b1;
            end
            if (tile_wr8_en && write_ready) begin
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if (tile_wr8_keep[lane] &&
                        (tile_wr8_addr + lane < TILE_WORDS))
                        write_scalar_byte(
                            fill_bank_q, tile_wr8_addr + lane,
                            tile_wr8_data[lane*WEIGHT_W +: WEIGHT_W]);
                end
                fill_touched_q <= 1'b1;
            end

            if (consume_fire) begin
                format_busy_q <= 1'b1;
                format_bank_q <=
                    committed_bank_q[committed_rd_ptr_q];
                format_col_q <= 5'd0;
                committed_rd_ptr_q <= committed_rd_ptr_q + 1'b1;
            end else if (formatter_fire) begin
                if (formatter_done) begin
                    format_busy_q <= 1'b0;
                    format_col_q <= 5'd0;
                    done <= 1'b1;
                end else begin
                    format_col_q <= format_col_q + 1'b1;
                end
            end

            if (commit_fire) begin
                committed_bank_q[committed_wr_ptr_q] <= fill_bank_q;
                committed_wr_ptr_q <= committed_wr_ptr_q + 1'b1;
                occupied_q[fill_bank_q] <= 1'b1;
                fill_touched_q <= 1'b0;
                if (!occupied_q[~fill_bank_q] ||
                    (formatter_done &&
                     (format_bank_q == ~fill_bank_q))) begin
                    fill_bank_q <= ~fill_bank_q;
                    fill_valid_q <= 1'b1;
                end else begin
                    fill_valid_q <= 1'b0;
                end
            end else if (!fill_valid_q && formatter_done) begin
                fill_bank_q <= format_bank_q;
                fill_valid_q <= 1'b1;
                fill_touched_q <= 1'b0;
            end

            if (formatter_done)
                occupied_q[format_bank_q] <= 1'b0;

            case ({commit_fire, consume_fire})
                2'b10: committed_count_q <= committed_count_q + 1'b1;
                2'b01: committed_count_q <= committed_count_q - 1'b1;
                default: committed_count_q <= committed_count_q;
            endcase
        end
    end
endmodule

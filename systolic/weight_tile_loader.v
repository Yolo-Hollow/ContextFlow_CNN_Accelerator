`timescale 1ns / 1ps
// Weight tile buffer + formatter.
//
// External writer stores a tile as:
//   mem[row * (COLS*2) + cout_lane] = W[k_base + row][cout_base + cout_lane]
//
// Loader emits COLS cycles. Cycle c writes one output-channel pair for all rows:
//   row r -> { W[r][2*c+1], W[r][2*c] }
module weight_tile_loader #(
    parameter ROWS = 32,
    parameter COLS = 32,
    parameter WEIGHT_W = 8,
    parameter ADDR_W = 11
) (
    input  clk,
    input  rst,

    input                       tile_wr_en,
    input  [ADDR_W-1:0]         tile_wr_addr,
    input  [WEIGHT_W-1:0]       tile_wr_data,

    input                       start,
    output                      busy,
    output reg                  done,

    input  [ROWS-1:0]           wgt_fifo_full,
    output [ROWS-1:0]           wgt_fifo_wr_en,
    output [ROWS*WEIGHT_W*2-1:0] wgt_fifo_wr_data
);
    localparam COUT_TILE = COLS * 2;
    localparam TILE_WORDS = ROWS * COUT_TILE;

    reg [WEIGHT_W-1:0] tile_mem [0:TILE_WORDS-1];
    reg busy_r;
    reg [4:0] col_idx;

    wire stall = |wgt_fifo_full;
    wire fire = busy_r && !stall;

    assign busy = busy_r;
    assign wgt_fifo_wr_en = fire ? {ROWS{1'b1}} : {ROWS{1'b0}};

    always @(posedge clk) begin
        if (tile_wr_en)
            tile_mem[tile_wr_addr] <= tile_wr_data;
    end

    genvar r;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : row_pack
            wire [ADDR_W-1:0] addr0 = r*COUT_TILE + (col_idx << 1);
            wire [ADDR_W-1:0] addr1 = r*COUT_TILE + (col_idx << 1) + 1'b1;
            assign wgt_fifo_wr_data[r*WEIGHT_W*2 +: WEIGHT_W] = tile_mem[addr0];
            assign wgt_fifo_wr_data[r*WEIGHT_W*2+WEIGHT_W +: WEIGHT_W] = tile_mem[addr1];
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            busy_r <= 1'b0;
            col_idx <= 5'd0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;

            if (!busy_r && start) begin
                busy_r <= 1'b1;
                col_idx <= 5'd0;
            end else if (fire) begin
                if (col_idx == COLS - 1) begin
                    busy_r <= 1'b0;
                    col_idx <= 5'd0;
                    done <= 1'b1;
                end else begin
                    col_idx <= col_idx + 5'd1;
                end
            end
        end
    end
endmodule

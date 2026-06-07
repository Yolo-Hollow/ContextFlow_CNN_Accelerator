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
    input                       tile_wr8_en,
    input  [ADDR_W-1:0]         tile_wr8_addr,
    input  [WEIGHT_W*8-1:0]     tile_wr8_data,
    input  [7:0]                tile_wr8_keep,

    input                       start,
    output                      busy,
    output reg                  done,

    input  [ROWS-1:0]           wgt_fifo_full,
    output [ROWS-1:0]           wgt_fifo_wr_en,
    output [ROWS*WEIGHT_W*2-1:0] wgt_fifo_wr_data
);
    localparam COUT_TILE = COLS * 2;
    localparam TILE_WORDS = ROWS * COUT_TILE;

    localparam BANKS = 8;
    localparam BANK_DEPTH = (TILE_WORDS + BANKS - 1) / BANKS;

    reg [WEIGHT_W-1:0] tile_bank0 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] tile_bank1 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] tile_bank2 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] tile_bank3 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] tile_bank4 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] tile_bank5 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] tile_bank6 [0:BANK_DEPTH-1];
    reg [WEIGHT_W-1:0] tile_bank7 [0:BANK_DEPTH-1];
    reg busy_r;
    reg [4:0] col_idx;

    wire stall = |wgt_fifo_full;
    wire fire = busy_r && !stall;

    assign busy = busy_r;
    assign wgt_fifo_wr_en = fire ? {ROWS{1'b1}} : {ROWS{1'b0}};

    task automatic write_tile_byte;
        input [ADDR_W-1:0] addr;
        input [WEIGHT_W-1:0] data;
        begin
            case (addr[2:0])
                3'd0: tile_bank0[addr[ADDR_W-1:3]] <= data;
                3'd1: tile_bank1[addr[ADDR_W-1:3]] <= data;
                3'd2: tile_bank2[addr[ADDR_W-1:3]] <= data;
                3'd3: tile_bank3[addr[ADDR_W-1:3]] <= data;
                3'd4: tile_bank4[addr[ADDR_W-1:3]] <= data;
                3'd5: tile_bank5[addr[ADDR_W-1:3]] <= data;
                3'd6: tile_bank6[addr[ADDR_W-1:3]] <= data;
                default: tile_bank7[addr[ADDR_W-1:3]] <= data;
            endcase
        end
    endtask

    always @(posedge clk) begin
        if (tile_wr8_en) begin
            if (tile_wr8_keep[0] && tile_wr8_addr + 0 < TILE_WORDS)
                tile_bank0[tile_wr8_addr[ADDR_W-1:3]] <= tile_wr8_data[0*WEIGHT_W +: WEIGHT_W];
            if (tile_wr8_keep[1] && tile_wr8_addr + 1 < TILE_WORDS)
                tile_bank1[tile_wr8_addr[ADDR_W-1:3]] <= tile_wr8_data[1*WEIGHT_W +: WEIGHT_W];
            if (tile_wr8_keep[2] && tile_wr8_addr + 2 < TILE_WORDS)
                tile_bank2[tile_wr8_addr[ADDR_W-1:3]] <= tile_wr8_data[2*WEIGHT_W +: WEIGHT_W];
            if (tile_wr8_keep[3] && tile_wr8_addr + 3 < TILE_WORDS)
                tile_bank3[tile_wr8_addr[ADDR_W-1:3]] <= tile_wr8_data[3*WEIGHT_W +: WEIGHT_W];
            if (tile_wr8_keep[4] && tile_wr8_addr + 4 < TILE_WORDS)
                tile_bank4[tile_wr8_addr[ADDR_W-1:3]] <= tile_wr8_data[4*WEIGHT_W +: WEIGHT_W];
            if (tile_wr8_keep[5] && tile_wr8_addr + 5 < TILE_WORDS)
                tile_bank5[tile_wr8_addr[ADDR_W-1:3]] <= tile_wr8_data[5*WEIGHT_W +: WEIGHT_W];
            if (tile_wr8_keep[6] && tile_wr8_addr + 6 < TILE_WORDS)
                tile_bank6[tile_wr8_addr[ADDR_W-1:3]] <= tile_wr8_data[6*WEIGHT_W +: WEIGHT_W];
            if (tile_wr8_keep[7] && tile_wr8_addr + 7 < TILE_WORDS)
                tile_bank7[tile_wr8_addr[ADDR_W-1:3]] <= tile_wr8_data[7*WEIGHT_W +: WEIGHT_W];
        end
        if (tile_wr_en)
            write_tile_byte(tile_wr_addr, tile_wr_data);
    end

    genvar r;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : row_pack
            wire [ADDR_W-1:0] addr0 = r*COUT_TILE + (col_idx << 1);
            wire [ADDR_W-1:0] addr1 = r*COUT_TILE + (col_idx << 1) + 1'b1;
            wire [WEIGHT_W-1:0] data0 =
                (addr0[2:0] == 3'd0) ? tile_bank0[addr0[ADDR_W-1:3]] :
                (addr0[2:0] == 3'd1) ? tile_bank1[addr0[ADDR_W-1:3]] :
                (addr0[2:0] == 3'd2) ? tile_bank2[addr0[ADDR_W-1:3]] :
                (addr0[2:0] == 3'd3) ? tile_bank3[addr0[ADDR_W-1:3]] :
                (addr0[2:0] == 3'd4) ? tile_bank4[addr0[ADDR_W-1:3]] :
                (addr0[2:0] == 3'd5) ? tile_bank5[addr0[ADDR_W-1:3]] :
                (addr0[2:0] == 3'd6) ? tile_bank6[addr0[ADDR_W-1:3]] :
                                        tile_bank7[addr0[ADDR_W-1:3]];
            wire [WEIGHT_W-1:0] data1 =
                (addr1[2:0] == 3'd0) ? tile_bank0[addr1[ADDR_W-1:3]] :
                (addr1[2:0] == 3'd1) ? tile_bank1[addr1[ADDR_W-1:3]] :
                (addr1[2:0] == 3'd2) ? tile_bank2[addr1[ADDR_W-1:3]] :
                (addr1[2:0] == 3'd3) ? tile_bank3[addr1[ADDR_W-1:3]] :
                (addr1[2:0] == 3'd4) ? tile_bank4[addr1[ADDR_W-1:3]] :
                (addr1[2:0] == 3'd5) ? tile_bank5[addr1[ADDR_W-1:3]] :
                (addr1[2:0] == 3'd6) ? tile_bank6[addr1[ADDR_W-1:3]] :
                                        tile_bank7[addr1[ADDR_W-1:3]];
            assign wgt_fifo_wr_data[r*WEIGHT_W*2 +: WEIGHT_W] = data0;
            assign wgt_fifo_wr_data[r*WEIGHT_W*2+WEIGHT_W +: WEIGHT_W] = data1;
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

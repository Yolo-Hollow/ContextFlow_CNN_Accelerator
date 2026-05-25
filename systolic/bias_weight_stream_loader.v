`timescale 1ns / 1ps

// Stream-to-core loader for one bias vector and one weight tile.
//
// Bias stream order:
//   bias[lane] for lane = 0 .. COUT_TILE-1
//
// Weight stream order matches weight_tile_loader storage:
//   weight[row * COUT_TILE + cout_lane]
//   row = 0 .. ROWS-1, cout_lane = 0 .. COUT_TILE-1
//
// This module is intentionally small and bus-agnostic. A later DMA/AXI-Stream
// wrapper can drive the *_s_valid/data inputs and use *_s_ready for backpressure.
module bias_weight_stream_loader #(
    parameter ROWS = 32,
    parameter COLS = 32,
    parameter PSUM_W = 32,
    parameter WEIGHT_W = 8,
    parameter BIAS_ADDR_W = 6,
    parameter WGT_ADDR_W = 11
) (
    input  clk,
    input  rst,

    input  bias_load_req,
    output bias_s_ready,
    input  bias_s_valid,
    input  [PSUM_W-1:0] bias_s_data,
    output reg bias_load_done,
    output reg bias_wr_en,
    output reg [BIAS_ADDR_W-1:0] bias_wr_addr,
    output reg [PSUM_W-1:0] bias_wr_data,

    input  weight_load_req,
    output weight_s_ready,
    input  weight_s_valid,
    input  [WEIGHT_W-1:0] weight_s_data,
    output reg weight_tile_ready,
    output reg wgt_tile_wr_en,
    output reg [WGT_ADDR_W-1:0] wgt_tile_wr_addr,
    output reg [WEIGHT_W-1:0] wgt_tile_wr_data
);
    localparam COUT_TILE = COLS * 2;
    localparam TILE_WORDS = ROWS * COUT_TILE;

    reg bias_busy;
    reg weight_busy;
    reg [BIAS_ADDR_W-1:0] bias_count;
    reg [WGT_ADDR_W-1:0] weight_count;

    wire bias_fire = bias_busy && bias_s_valid;
    wire weight_fire = weight_busy && weight_s_valid;

    assign bias_s_ready = bias_busy;
    assign weight_s_ready = weight_busy;

    always @(posedge clk) begin
        if (rst) begin
            bias_busy <= 1'b0;
            bias_count <= {BIAS_ADDR_W{1'b0}};
            bias_load_done <= 1'b0;
            bias_wr_en <= 1'b0;
            bias_wr_addr <= {BIAS_ADDR_W{1'b0}};
            bias_wr_data <= {PSUM_W{1'b0}};
        end else begin
            bias_load_done <= 1'b0;
            bias_wr_en <= 1'b0;

            if (!bias_busy && bias_load_req) begin
                bias_busy <= 1'b1;
                bias_count <= {BIAS_ADDR_W{1'b0}};
            end

            if (bias_fire) begin
                bias_wr_en <= 1'b1;
                bias_wr_addr <= bias_count;
                bias_wr_data <= bias_s_data;

                if (bias_count == COUT_TILE - 1) begin
                    bias_busy <= 1'b0;
                    bias_count <= {BIAS_ADDR_W{1'b0}};
                    bias_load_done <= 1'b1;
                end else begin
                    bias_count <= bias_count + 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            weight_busy <= 1'b0;
            weight_count <= {WGT_ADDR_W{1'b0}};
            weight_tile_ready <= 1'b0;
            wgt_tile_wr_en <= 1'b0;
            wgt_tile_wr_addr <= {WGT_ADDR_W{1'b0}};
            wgt_tile_wr_data <= {WEIGHT_W{1'b0}};
        end else begin
            weight_tile_ready <= 1'b0;
            wgt_tile_wr_en <= 1'b0;

            if (!weight_busy && weight_load_req) begin
                weight_busy <= 1'b1;
                weight_count <= {WGT_ADDR_W{1'b0}};
            end

            if (weight_fire) begin
                wgt_tile_wr_en <= 1'b1;
                wgt_tile_wr_addr <= weight_count;
                wgt_tile_wr_data <= weight_s_data;

                if (weight_count == TILE_WORDS - 1) begin
                    weight_busy <= 1'b0;
                    weight_count <= {WGT_ADDR_W{1'b0}};
                    weight_tile_ready <= 1'b1;
                end else begin
                    weight_count <= weight_count + 1'b1;
                end
            end
        end
    end
endmodule

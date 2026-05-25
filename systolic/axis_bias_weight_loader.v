`timescale 1ns / 1ps

// AXI-Stream packed loader for one bias vector and one weight tile.
//
// Bias stream:
//   64-bit beat = two little-endian 32-bit bias values.
//   bias[even] = TDATA[31:0], bias[odd] = TDATA[63:32].
//
// Weight stream:
//   64-bit beat = eight INT8 weights, low byte first.
//   weight[i + n] = TDATA[n*8 +: 8].
//
// TLAST is expected on the final packed beat of each load. TKEEP must match the
// valid byte count of the final beat; non-final beats require all bytes valid.
module axis_bias_weight_loader #(
    parameter ROWS = 32,
    parameter COLS = 32,
    parameter PSUM_W = 32,
    parameter WEIGHT_W = 8,
    parameter BIAS_ADDR_W = 6,
    parameter WGT_ADDR_W = 11,
    parameter AXIS_W = 64,
    parameter KEEP_W = AXIS_W / 8
) (
    input  clk,
    input  rst,

    input  bias_load_req,
    output bias_s_axis_tready,
    input  bias_s_axis_tvalid,
    input  [AXIS_W-1:0] bias_s_axis_tdata,
    input  [KEEP_W-1:0] bias_s_axis_tkeep,
    input  bias_s_axis_tlast,
    output reg bias_load_done,
    output reg bias_wr_en,
    output reg [BIAS_ADDR_W-1:0] bias_wr_addr,
    output reg [PSUM_W-1:0] bias_wr_data,

    input  weight_load_req,
    output weight_s_axis_tready,
    input  weight_s_axis_tvalid,
    input  [AXIS_W-1:0] weight_s_axis_tdata,
    input  [KEEP_W-1:0] weight_s_axis_tkeep,
    input  weight_s_axis_tlast,
    output reg weight_tile_ready,
    output reg wgt_tile_wr_en,
    output reg [WGT_ADDR_W-1:0] wgt_tile_wr_addr,
    output reg [WEIGHT_W-1:0] wgt_tile_wr_data,

    output reg bias_tkeep_error,
    output reg bias_tlast_error,
    output reg weight_tkeep_error,
    output reg weight_tlast_error
);
    localparam COUT_TILE = COLS * 2;
    localparam TILE_WORDS = ROWS * COUT_TILE;
    localparam BIAS_PER_BEAT = 2;
    localparam WGT_PER_BEAT = 8;

    reg bias_busy;
    reg bias_pending;
    reg [0:0] bias_lane;
    reg [63:0] bias_hold;
    reg [BIAS_ADDR_W-1:0] bias_count;

    reg weight_busy;
    reg weight_pending;
    reg [2:0] weight_lane;
    reg [63:0] weight_hold;
    reg [WGT_ADDR_W-1:0] weight_count;

    wire bias_fire = bias_s_axis_tvalid && bias_s_axis_tready;
    wire weight_fire = weight_s_axis_tvalid && weight_s_axis_tready;
    wire bias_last_beat = (bias_count + BIAS_PER_BEAT >= COUT_TILE);
    wire weight_last_beat = (weight_count + WGT_PER_BEAT >= TILE_WORDS);
    wire [7:0] bias_expect_keep = (bias_last_beat && (COUT_TILE[0] == 1'b1)) ? 8'h0f : 8'hff;
    wire [3:0] weight_rem = TILE_WORDS - weight_count;
    wire [7:0] weight_expect_keep =
        (weight_last_beat && weight_rem == 4'd1) ? 8'h01 :
        (weight_last_beat && weight_rem == 4'd2) ? 8'h03 :
        (weight_last_beat && weight_rem == 4'd3) ? 8'h07 :
        (weight_last_beat && weight_rem == 4'd4) ? 8'h0f :
        (weight_last_beat && weight_rem == 4'd5) ? 8'h1f :
        (weight_last_beat && weight_rem == 4'd6) ? 8'h3f :
        (weight_last_beat && weight_rem == 4'd7) ? 8'h7f : 8'hff;

    assign bias_s_axis_tready = bias_busy && !bias_pending;
    assign weight_s_axis_tready = weight_busy && !weight_pending;

    always @(posedge clk) begin
        if (rst) begin
            bias_busy <= 1'b0;
            bias_pending <= 1'b0;
            bias_lane <= 1'b0;
            bias_hold <= 64'd0;
            bias_count <= {BIAS_ADDR_W{1'b0}};
            bias_load_done <= 1'b0;
            bias_wr_en <= 1'b0;
            bias_wr_addr <= {BIAS_ADDR_W{1'b0}};
            bias_wr_data <= {PSUM_W{1'b0}};
            bias_tkeep_error <= 1'b0;
            bias_tlast_error <= 1'b0;
        end else begin
            bias_load_done <= 1'b0;
            bias_wr_en <= 1'b0;

            if (!bias_busy && bias_load_req) begin
                bias_busy <= 1'b1;
                bias_count <= {BIAS_ADDR_W{1'b0}};
            end

            if (bias_fire) begin
                bias_pending <= 1'b1;
                bias_lane <= 1'b0;
                bias_hold <= bias_s_axis_tdata;
                if (bias_s_axis_tkeep != bias_expect_keep)
                    bias_tkeep_error <= 1'b1;
                if (bias_s_axis_tlast != bias_last_beat)
                    bias_tlast_error <= 1'b1;
            end

            if (bias_pending) begin
                bias_wr_en <= 1'b1;
                bias_wr_addr <= bias_count;
                bias_wr_data <= bias_lane ? bias_hold[63:32] : bias_hold[31:0];

                if (bias_count == COUT_TILE - 1) begin
                    bias_pending <= 1'b0;
                    bias_busy <= 1'b0;
                    bias_lane <= 1'b0;
                    bias_count <= {BIAS_ADDR_W{1'b0}};
                    bias_load_done <= 1'b1;
                end else begin
                    bias_count <= bias_count + 1'b1;
                    if (bias_lane == 1'b1) begin
                        bias_pending <= 1'b0;
                        bias_lane <= 1'b0;
                    end else begin
                        bias_lane <= 1'b1;
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            weight_busy <= 1'b0;
            weight_pending <= 1'b0;
            weight_lane <= 3'd0;
            weight_hold <= 64'd0;
            weight_count <= {WGT_ADDR_W{1'b0}};
            weight_tile_ready <= 1'b0;
            wgt_tile_wr_en <= 1'b0;
            wgt_tile_wr_addr <= {WGT_ADDR_W{1'b0}};
            wgt_tile_wr_data <= {WEIGHT_W{1'b0}};
            weight_tkeep_error <= 1'b0;
            weight_tlast_error <= 1'b0;
        end else begin
            weight_tile_ready <= 1'b0;
            wgt_tile_wr_en <= 1'b0;

            if (!weight_busy && weight_load_req) begin
                weight_busy <= 1'b1;
                weight_count <= {WGT_ADDR_W{1'b0}};
            end

            if (weight_fire) begin
                weight_pending <= 1'b1;
                weight_lane <= 3'd0;
                weight_hold <= weight_s_axis_tdata;
                if (weight_s_axis_tkeep != weight_expect_keep)
                    weight_tkeep_error <= 1'b1;
                if (weight_s_axis_tlast != weight_last_beat)
                    weight_tlast_error <= 1'b1;
            end

            if (weight_pending) begin
                wgt_tile_wr_en <= 1'b1;
                wgt_tile_wr_addr <= weight_count;
                wgt_tile_wr_data <= weight_hold[weight_lane*8 +: 8];

                if (weight_count == TILE_WORDS - 1) begin
                    weight_pending <= 1'b0;
                    weight_busy <= 1'b0;
                    weight_lane <= 3'd0;
                    weight_count <= {WGT_ADDR_W{1'b0}};
                    weight_tile_ready <= 1'b1;
                end else begin
                    weight_count <= weight_count + 1'b1;
                    if (weight_lane == WGT_PER_BEAT - 1) begin
                        weight_pending <= 1'b0;
                        weight_lane <= 3'd0;
                    end else begin
                        weight_lane <= weight_lane + 1'b1;
                    end
                end
            end
        end
    end
endmodule

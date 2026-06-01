`timescale 1ns / 1ps
// Expand INT8 OFM packets into byte writes.
//
// HWC layout:
//   wr_addr = (pixel_base + pixel_idx) * cout_total + (cout_base + lane)
module ofm_writeback #(
    parameter COUT_TILE = 64,
    parameter PIXEL_AW = 10,
    parameter ADDR_W = 24,
    parameter FIFO_DEPTH = 32,
    parameter FIFO_AW = 5
) (
    input  clk,
    input  rst,

    input                       packet_valid,
    input  [PIXEL_AW-1:0]       packet_pixel,
    input  [10:0]               packet_cout_base,
    input  [COUT_TILE-1:0]      packet_channel_valid,
    input  [COUT_TILE*8-1:0]    packet_data,
    output                      packet_full,

    input  [10:0]               cout_total,
    input  [ADDR_W-1:0]         pixel_base,

    output reg                  wr_en,
    input                       wr_ready,
    output reg [ADDR_W-1:0]     wr_addr,
    output reg [7:0]            wr_data,
    output reg                  busy
);
    localparam PTR_W = FIFO_AW + 1;

    reg [PIXEL_AW-1:0] pixel_fifo [0:FIFO_DEPTH-1];
    reg [10:0] cout_fifo [0:FIFO_DEPTH-1];
    reg [COUT_TILE-1:0] mask_fifo [0:FIFO_DEPTH-1];
    reg [COUT_TILE*8-1:0] data_fifo [0:FIFO_DEPTH-1];
    reg [PTR_W-1:0] wptr, rptr;

    wire fifo_empty = (wptr == rptr);
    wire fifo_full = (wptr[PTR_W-1] != rptr[PTR_W-1]) &&
                     (wptr[FIFO_AW-1:0] == rptr[FIFO_AW-1:0]);
    assign packet_full = fifo_full;

    wire push = packet_valid && !fifo_full;

    reg [PIXEL_AW-1:0] cur_pixel;
    reg [10:0] cur_cout_base;
    reg [COUT_TILE-1:0] cur_mask;
    reg [COUT_TILE*8-1:0] cur_data;
    reg [10:0] lane_idx;
    reg active;

    integer i;
    wire at_last_lane = (lane_idx == COUT_TILE - 1);
    wire lane_valid = cur_mask[lane_idx];
    wire lane_done = !lane_valid || wr_ready;
    wire [10:0] lane_cout = cur_cout_base + lane_idx;
    wire [ADDR_W-1:0] global_pixel = pixel_base + cur_pixel;
    wire [ADDR_W-1:0] base_addr = global_pixel * cout_total;

    always @(posedge clk) begin
        if (rst) begin
            wptr <= {PTR_W{1'b0}};
        end else if (push) begin
            pixel_fifo[wptr[FIFO_AW-1:0]] <= packet_pixel;
            cout_fifo[wptr[FIFO_AW-1:0]] <= packet_cout_base;
            mask_fifo[wptr[FIFO_AW-1:0]] <= packet_channel_valid;
            data_fifo[wptr[FIFO_AW-1:0]] <= packet_data;
            wptr <= wptr + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            rptr <= {PTR_W{1'b0}};
            cur_pixel <= {PIXEL_AW{1'b0}};
            cur_cout_base <= 11'd0;
            cur_mask <= {COUT_TILE{1'b0}};
            cur_data <= {COUT_TILE*8{1'b0}};
            lane_idx <= 11'd0;
            active <= 1'b0;
            wr_en <= 1'b0;
            wr_addr <= {ADDR_W{1'b0}};
            wr_data <= 8'd0;
            busy <= 1'b0;
        end else begin
            wr_en <= 1'b0;

            if (!active && !fifo_empty) begin
                cur_pixel <= pixel_fifo[rptr[FIFO_AW-1:0]];
                cur_cout_base <= cout_fifo[rptr[FIFO_AW-1:0]];
                cur_mask <= mask_fifo[rptr[FIFO_AW-1:0]];
                cur_data <= data_fifo[rptr[FIFO_AW-1:0]];
                lane_idx <= 11'd0;
                active <= 1'b1;
                busy <= 1'b1;
                rptr <= rptr + 1'b1;
            end else if (active) begin
                if (lane_valid && wr_ready) begin
                    wr_en <= 1'b1;
                    wr_addr <= base_addr + lane_cout;
                    wr_data <= cur_data[lane_idx*8 +: 8];
                end

                if (lane_done && at_last_lane) begin
                    active <= 1'b0;
                    busy <= !fifo_empty || push;
                end else if (lane_done) begin
                    lane_idx <= lane_idx + 11'd1;
                end
            end else begin
                busy <= !fifo_empty || push;
            end
        end
    end
endmodule

`timescale 1ns / 1ps

// Optional packet-level OFM max-pooling after activation.
//
// Bypass mode forwards packets unchanged. Pool mode currently supports
// uint8 2x2 stride-2 maxpool on the post-activation packet stream. Input packet
// addresses are conv-output local pixel indices in row-major order. Output
// packet addresses are pooled local pixel indices in row-major order.
module ofm_pooling #(
    parameter COUT_TILE = 64,
    parameter ADDR_W = 10,
    parameter OFM_W_MAX = 416
) (
    input  clk,
    input  rst,

    input        pool_enable,
    input  [1:0] pool_stride,
    input  [8:0] conv_ofm_w,

    input                       in_valid,
    output                      in_ready,
    input  [ADDR_W-1:0]         in_addr,
    input  [10:0]               in_cout_base,
    input  [COUT_TILE-1:0]      in_channel_valid,
    input  [COUT_TILE*8-1:0]    in_data,

    output reg                  out_valid,
    input                       out_ready,
    output reg [ADDR_W-1:0]     out_addr,
    output reg [10:0]           out_cout_base,
    output reg [COUT_TILE-1:0]  out_channel_valid,
    output reg [COUT_TILE*8-1:0] out_data
);
    localparam [1:0] POOL_STRIDE2 = 2'd2;

    reg [COUT_TILE*8-1:0] top_row_data [0:OFM_W_MAX-1];
    reg [COUT_TILE*8-1:0] bottom_left_data;
    reg [8:0] x_cnt;
    reg [8:0] y_cnt;

    wire pool_active = pool_enable && (pool_stride == POOL_STRIDE2);
    wire can_advance = !out_valid || out_ready;
    assign in_ready = can_advance;

    wire fire = in_valid && in_ready;
    wire addr_zero = (in_addr == {ADDR_W{1'b0}});
    wire [8:0] x_cur = addr_zero ? 9'd0 : x_cnt;
    wire [8:0] y_cur = addr_zero ? 9'd0 : y_cnt;
    wire [8:0] pool_out_w = {1'b0, conv_ofm_w[8:1]};
    wire is_bottom_right = pool_active && y_cur[0] && x_cur[0];
    wire [ADDR_W-1:0] pooled_addr =
        (({ADDR_W{1'b0}} + y_cur[8:1]) * ({ADDR_W{1'b0}} + pool_out_w)) +
        ({ADDR_W{1'b0}} + x_cur[8:1]);

    integer lane;
    reg [7:0] v0, v1, v2, v3, vmax0, vmax1;
    reg [COUT_TILE*8-1:0] pooled_data;

    always @(*) begin
        pooled_data = {COUT_TILE*8{1'b0}};
        for (lane = 0; lane < COUT_TILE; lane = lane + 1) begin
            v0 = (x_cur == 9'd0) ? 8'd0 : top_row_data[x_cur - 9'd1][lane*8 +: 8];
            v1 = top_row_data[x_cur][lane*8 +: 8];
            v2 = bottom_left_data[lane*8 +: 8];
            v3 = in_data[lane*8 +: 8];
            vmax0 = (v0 > v1) ? v0 : v1;
            vmax1 = (v2 > v3) ? v2 : v3;
            pooled_data[lane*8 +: 8] = (vmax0 > vmax1) ? vmax0 : vmax1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            out_addr <= {ADDR_W{1'b0}};
            out_cout_base <= 11'd0;
            out_channel_valid <= {COUT_TILE{1'b0}};
            bottom_left_data <= {COUT_TILE*8{1'b0}};
            x_cnt <= 9'd0;
            y_cnt <= 9'd0;
        end else if (can_advance) begin
            out_valid <= 1'b0;

            if (fire) begin
                if (!pool_active) begin
                    out_valid <= 1'b1;
                    out_addr <= in_addr;
                    out_cout_base <= in_cout_base;
                    out_channel_valid <= in_channel_valid;
                    out_data <= in_data;
                end else begin
                    if (!y_cur[0])
                        top_row_data[x_cur] <= in_data;
                    else if (!x_cur[0])
                        bottom_left_data <= in_data;

                    if (is_bottom_right) begin
                        out_valid <= 1'b1;
                        out_addr <= pooled_addr;
                        out_cout_base <= in_cout_base;
                        out_channel_valid <= in_channel_valid;
                        out_data <= pooled_data;
                    end
                end

                if (conv_ofm_w <= 9'd1 || x_cur == conv_ofm_w - 9'd1) begin
                    x_cnt <= 9'd0;
                    y_cnt <= y_cur + 9'd1;
                end else begin
                    x_cnt <= x_cur + 9'd1;
                    y_cnt <= y_cur;
                end
            end
        end
    end
endmodule

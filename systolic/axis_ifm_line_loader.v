`timescale 1ns / 1ps

// AXI-Stream wrapper for IFM line filling.
//
// 64-bit stream format, one output x-position per beat:
//   TDATA[ 7: 0] = bank0
//   TDATA[15: 8] = bank1
//   TDATA[23:16] = bank2
//   TDATA[31:24] = bank3
//   TDATA[39:32] = bank4
//   TDATA[63:40] = don't care
//
// TKEEP[BANKS-1:0] must all be 1 for every accepted beat. TLAST must be asserted
// only on the final x beat of the requested row. Protocol errors are sticky
// until rst.
module axis_ifm_line_loader #(
    parameter AW = 9,
    parameter AXIS_W = 64,
    parameter KEEP_W = AXIS_W / 8,
    parameter BANKS = 5
) (
    input  clk,
    input  rst,
    input  stream_reset,
    input  batch_mode,
    input  [31:0] expected_packets,

    input  [AW-1:0] fm_w,
    input           fill_req,
    input  [AW-1:0] fill_fy,
    input  [7:0]    input_zero_point,

    output          s_axis_tready,
    input           s_axis_tvalid,
    input  [AXIS_W-1:0] s_axis_tdata,
    input  [KEEP_W-1:0] s_axis_tkeep,
    input           s_axis_tlast,

    output [BANKS-1:0] dma_bank_wr_en,
    output [AW-1:0] dma_wr_x,
    output [AW:0]   dma_wr_fy,
    output [7:0]    dma_wr_data [0:BANKS-1],
    output          dma_line_advance,

    output reg      tkeep_error,
    output reg      tlast_error,
    output reg [31:0] completed_packets
);
    reg active;
    reg req_armed;
    reg [AW-1:0] beat_count;
    wire [7:0] line_s_data [0:BANKS-1];
    wire axis_fire = s_axis_tvalid && s_axis_tready;
    wire expected_last = active && (beat_count == fm_w - 1'b1);
    wire expected_stream_last =
        !batch_mode || (completed_packets + 1'b1 == expected_packets);
    wire accepted_fill_req = fill_req && req_armed;

    genvar db;
    generate
        for (db = 0; db < BANKS; db = db + 1) begin : line_data_assign
            assign line_s_data[db] = s_axis_tdata[db*8 +: 8];
        end
    endgenerate

    ifm_line_stream_loader #(.AW(AW), .BANKS(BANKS)) u_line_loader (
        .clk(clk),
        .rst(rst),
        .fm_w(fm_w),
        .fill_req(accepted_fill_req),
        .fill_fy(fill_fy),
        .input_zero_point(input_zero_point),
        .line_s_ready(s_axis_tready),
        .line_s_valid(s_axis_tvalid),
        .line_s_data(line_s_data),
        .dma_bank_wr_en(dma_bank_wr_en),
        .dma_wr_x(dma_wr_x),
        .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data),
        .dma_line_advance(dma_line_advance)
    );

    always @(posedge clk) begin
        if (rst) begin
            active <= 1'b0;
            req_armed <= 1'b1;
            beat_count <= {AW{1'b0}};
            tkeep_error <= 1'b0;
            tlast_error <= 1'b0;
            completed_packets <= 32'd0;
        end else begin
            if (!fill_req)
                req_armed <= 1'b1;

            if (!active && accepted_fill_req && (fm_w != {AW{1'b0}})) begin
                active <= 1'b1;
                req_armed <= 1'b0;
                beat_count <= {AW{1'b0}};
            end

            if (axis_fire) begin
                if (s_axis_tkeep[BANKS-1:0] != {BANKS{1'b1}})
                    tkeep_error <= 1'b1;
                if (s_axis_tlast != (expected_last && expected_stream_last))
                    tlast_error <= 1'b1;

                if (expected_last) begin
                    active <= 1'b0;
                    beat_count <= {AW{1'b0}};
                    completed_packets <= completed_packets + 1'b1;
                end else begin
                    beat_count <= beat_count + 1'b1;
                end
            end
            if (stream_reset)
                completed_packets <= 32'd0;
        end
    end
endmodule

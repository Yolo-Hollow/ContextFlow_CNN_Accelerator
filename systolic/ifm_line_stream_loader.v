`timescale 1ns / 1ps

// Stream-to-line-buffer loader for one IFM row.
//
// Protocol:
//   - When fill_req is asserted, the loader latches fill_fy and becomes ready.
//   - The source sends fm_w beats. Each beat carries the 5 bank bytes for one x.
//   - Beat order is x = 0 .. fm_w-1.
//   - The loader writes all 5 banks for each accepted beat.
//   - After the last beat, it pulses dma_line_advance for one cycle.
//
// This module is bus-agnostic. A later DMA/AXI-Stream wrapper can map a wider
// memory beat into line_s_data[0:4] and use line_s_ready for backpressure.
module ifm_line_stream_loader #(
    parameter AW = 9,
    parameter BANKS = 5
) (
    input  clk,
    input  rst,

    input  [AW-1:0] fm_w,
    input           fill_req,
    input  [AW-1:0] fill_fy,
    input  [7:0]    input_zero_point,

    output          line_s_ready,
    input           line_s_valid,
    input  [7:0]    line_s_data [0:BANKS-1],

    output [BANKS-1:0] dma_bank_wr_en,
    output [AW-1:0] dma_wr_x,
    output [AW:0]   dma_wr_fy,
    output [7:0]    dma_wr_data [0:BANKS-1],
    output          dma_line_advance
);
    reg busy;
    reg cooldown;
    reg advance_pending;
    reg last_done_valid;
    reg [AW-1:0] last_done_fy;
    reg [AW-1:0] x_count;
    reg [AW:0] fy_latched;

    wire fire = busy && line_s_valid;
    wire last_x = (x_count == fm_w - 1'b1);

    assign line_s_ready = busy;
    assign dma_bank_wr_en = fire ? {BANKS{1'b1}} : {BANKS{1'b0}};
    assign dma_wr_x = x_count;
    assign dma_wr_fy = fy_latched;
    assign dma_line_advance = advance_pending;

    function [7:0] center_ifm_byte;
        input [7:0] raw_u8;
        input [7:0] zero_point;
        reg signed [9:0] centered;
        begin
            centered = $signed({2'b00, raw_u8}) - $signed({2'b00, zero_point});
            if (centered > 10'sd127)
                center_ifm_byte = 8'sh7f;
            else if (centered < -10'sd128)
                center_ifm_byte = 8'sh80;
            else
                center_ifm_byte = centered[7:0];
        end
    endfunction

    genvar db;
    generate
        for (db = 0; db < BANKS; db = db + 1) begin : dma_data_assign
            assign dma_wr_data[db] = center_ifm_byte(line_s_data[db], input_zero_point);
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            cooldown <= 1'b0;
            advance_pending <= 1'b0;
            last_done_valid <= 1'b0;
            last_done_fy <= {AW{1'b0}};
            x_count <= {AW{1'b0}};
            fy_latched <= {AW+1{1'b0}};
        end else begin
            if (advance_pending) begin
                advance_pending <= 1'b0;
                cooldown <= 1'b1;
                last_done_valid <= 1'b1;
                last_done_fy <= fy_latched[AW-1:0];
            end else if (cooldown) begin
                cooldown <= 1'b0;
            end
            if (!fill_req)
                last_done_valid <= 1'b0;

            if (!busy && !advance_pending && !cooldown && fill_req && (fm_w != {AW{1'b0}}) &&
                !(last_done_valid && last_done_fy == fill_fy)) begin
                busy <= 1'b1;
                x_count <= {AW{1'b0}};
                fy_latched <= {1'b0, fill_fy};
            end

            if (fire) begin
                if (last_x) begin
                    busy <= 1'b0;
                    advance_pending <= 1'b1;
                    x_count <= {AW{1'b0}};
                end else begin
                    x_count <= x_count + 1'b1;
                end
            end
        end
    end
endmodule

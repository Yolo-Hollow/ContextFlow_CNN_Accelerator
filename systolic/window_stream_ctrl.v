`timescale 1ns / 1ps

// Streams one output row worth of window positions.
// ox is held stable while the window is not ready or IFM FIFOs are full.
module window_stream_ctrl #(
    parameter AW = 9
) (
    input  clk,
    input  rst,
    input  start,
    input  [AW-1:0] start_oy,
    input  [AW-1:0] ofm_w,
    input  window_ready,
    input  ifm_fifo_full_any,
    output reg active,
    output reg [AW-1:0] oy,
    output reg [AW-1:0] ox,
    output ifm_push,
    output fifo_stall,
    output window_not_ready,
    output reg row_done
);
    wire [AW-1:0] last_ox = ofm_w - {{(AW-1){1'b0}}, 1'b1};
    wire can_push = active && window_ready && !ifm_fifo_full_any;
    assign ifm_push = can_push;
    assign fifo_stall = active && window_ready && ifm_fifo_full_any;
    assign window_not_ready = active && !window_ready;

    always @(posedge clk) begin
        if (rst) begin
            active <= 1'b0;
            oy <= {AW{1'b0}};
            ox <= {AW{1'b0}};
            row_done <= 1'b0;
        end else begin
            row_done <= 1'b0;

            if (!active) begin
                if (start) begin
                    oy <= start_oy;
                    ox <= {AW{1'b0}};
                    if (ofm_w == {AW{1'b0}}) begin
                        active <= 1'b0;
                        row_done <= 1'b1;
                    end else begin
                        active <= 1'b1;
                    end
                end
            end else if (can_push) begin
                if (ox == last_ox) begin
                    active <= 1'b0;
                    row_done <= 1'b1;
                end else begin
                    ox <= ox + {{(AW-1){1'b0}}, 1'b1};
                end
            end
        end
    end
endmodule

`timescale 1ns / 1ps

// Diagnostic-only monitor for one selected compute pass. It records per-column
// PSUM FIFO write timing and the columns missing while the collector waits.
module coltrace_monitor #(
    parameter COLS = 8
) (
    input         clk,
    input         rst,
    input         layer_start,
    input         layer_busy,
    input         trace_enable,
    input         trace_pass_start,
    input  [15:0] trace_num_pixels,
    input  [31:0] psum_fifo_wr_en,
    input         collector_trace_active,
    input         collector_trace_done,
    input         collector_read_wait,
    input  [31:0] collector_missing_mask,
    input  [4:0]  selected_col,

    output reg [31:0] selected_first_wr,
    output reg [31:0] selected_last_wr,
    output reg [31:0] selected_wr_count,
    output reg [31:0] selected_empty_wait,
    output reg [31:0] missing_mask_or,
    output reg [31:0] missing_mask_first,
    output reg [31:0] missing_mask_last,
    output reg        trace_valid
);
    reg [31:0] cycle_count;
    reg capture_writes;
    reg saw_missing;
    reg [15:0] pixels_to_trace;
    reg [31:0] first_wr [0:COLS-1];
    reg [31:0] last_wr [0:COLS-1];
    reg [31:0] wr_count [0:COLS-1];
    reg [31:0] empty_wait [0:COLS-1];
    integer c;

    always @(*) begin
        selected_first_wr = 32'd0;
        selected_last_wr = 32'd0;
        selected_wr_count = 32'd0;
        selected_empty_wait = 32'd0;
        if (selected_col < COLS) begin
            selected_first_wr = first_wr[selected_col];
            selected_last_wr = last_wr[selected_col];
            selected_wr_count = wr_count[selected_col];
            selected_empty_wait = empty_wait[selected_col];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 32'd0;
            capture_writes <= 1'b0;
            saw_missing <= 1'b0;
            pixels_to_trace <= 16'd1;
            missing_mask_or <= 32'd0;
            missing_mask_first <= 32'd0;
            missing_mask_last <= 32'd0;
            trace_valid <= 1'b0;
            for (c = 0; c < COLS; c = c + 1) begin
                first_wr[c] <= 32'd0;
                last_wr[c] <= 32'd0;
                wr_count[c] <= 32'd0;
                empty_wait[c] <= 32'd0;
            end
        end else begin
            if (layer_start) begin
                cycle_count <= 32'd0;
                capture_writes <= 1'b0;
                saw_missing <= 1'b0;
                missing_mask_or <= 32'd0;
                missing_mask_first <= 32'd0;
                missing_mask_last <= 32'd0;
                trace_valid <= 1'b0;
                for (c = 0; c < COLS; c = c + 1) begin
                    first_wr[c] <= 32'd0;
                    last_wr[c] <= 32'd0;
                    wr_count[c] <= 32'd0;
                    empty_wait[c] <= 32'd0;
                end
            end else if (layer_busy) begin
                cycle_count <= cycle_count + 1'b1;
            end

            if (trace_enable && trace_pass_start) begin
                capture_writes <= 1'b1;
                pixels_to_trace <=
                    (trace_num_pixels == 16'd0) ? 16'd1 : trace_num_pixels;
                saw_missing <= 1'b0;
                missing_mask_or <= 32'd0;
                missing_mask_first <= 32'd0;
                missing_mask_last <= 32'd0;
                trace_valid <= 1'b0;
                for (c = 0; c < COLS; c = c + 1) begin
                    first_wr[c] <= 32'd0;
                    last_wr[c] <= 32'd0;
                    wr_count[c] <= 32'd0;
                    empty_wait[c] <= 32'd0;
                end
            end else if (layer_busy && capture_writes) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    if (psum_fifo_wr_en[c] &&
                        wr_count[c] < pixels_to_trace) begin
                        if (wr_count[c] == 32'd0)
                            first_wr[c] <= cycle_count;
                        last_wr[c] <= cycle_count;
                        wr_count[c] <= wr_count[c] + 1'b1;
                    end
                end
            end

            if (layer_busy && collector_trace_active &&
                collector_read_wait) begin
                missing_mask_or <= missing_mask_or | collector_missing_mask;
                missing_mask_last <= collector_missing_mask;
                if (!saw_missing) begin
                    saw_missing <= 1'b1;
                    missing_mask_first <= collector_missing_mask;
                end
                for (c = 0; c < COLS; c = c + 1) begin
                    if (collector_missing_mask[c])
                        empty_wait[c] <= empty_wait[c] + 1'b1;
                end
            end

            if (collector_trace_done) begin
                capture_writes <= 1'b0;
                trace_valid <= 1'b1;
            end
        end
    end
endmodule

`timescale 1ns / 1ps
// Drain one spatial block from systolic_top PSUM FIFOs.
//
// Drain exactly num_pixels valid packets from the PSUM FIFOs.
// baseline_col0 is retained for interface compatibility with earlier tests.
module psum_drain_writer #(
    parameter COLS = 32,
    parameter PSUM_W = 32,
    parameter AW = 10
) (
    input  clk,
    input  rst,
    input  start,
    output reg busy,
    output reg done,

    input  [15:0] num_pixels,
    input  [PSUM_W-1:0] baseline_col0,
    input  is_final_pass,

    output [31:0] psum_fifo_rd_en,
    input  [COLS*PSUM_W*2-1:0] psum_fifo_rd_data,
    input  [31:0] psum_fifo_empty,

    output reg packet_valid,
    input  packet_ready,
    output reg [AW-1:0] packet_addr,
    output reg [COLS*PSUM_W*2-1:0] packet_data,
    output reg packet_is_final,
    output fifo_empty_wait,
    output reg fifo_empty_wait_sticky,
    output drain_read_fire,
    output drain_packet_fire,
    output drain_ready_stall,
    output drain_internal_full_wait
);
    localparam [31:0] COL_MASK = (32'h1 << COLS) - 1;

    reg [15:0] rd_count;
    reg [15:0] out_count;
    reg [AW-1:0] pending_addr;
    reg read_pending;
    reg hold_valid;
    reg [AW-1:0] hold_addr;
    reg [COLS*PSUM_W*2-1:0] hold_data;

    wire fifos_ready = ((psum_fifo_empty & COL_MASK) == 32'd0);
    wire [15:0] pixels_to_drain = (num_pixels == 16'd0) ? 16'd1 : num_pixels;
    wire packet_pop = packet_valid && packet_ready;
    wire [1:0] stored_count = {1'b0, packet_valid} + {1'b0, hold_valid};
    wire [1:0] stored_after_pop = stored_count - {1'b0, packet_pop};
    wire [1:0] stored_after_return = stored_after_pop + {1'b0, read_pending};
    wire can_accept_future_return = (stored_after_return < 2'd2);
    wire read_needed = busy && (rd_count < pixels_to_drain);
    wire want_read = read_needed && can_accept_future_return;
    wire issue_read = read_needed &&
                      fifos_ready && can_accept_future_return;

    assign psum_fifo_rd_en = issue_read ? COL_MASK : 32'd0;
    assign fifo_empty_wait = want_read && !fifos_ready;
    assign drain_read_fire = issue_read;
    assign drain_packet_fire = packet_pop;
    assign drain_ready_stall = busy && packet_valid && !packet_ready;
    assign drain_internal_full_wait = read_needed && fifos_ready && !can_accept_future_return;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            packet_valid <= 1'b0;
            packet_addr <= {AW{1'b0}};
            packet_data <= {COLS*PSUM_W*2{1'b0}};
            packet_is_final <= 1'b0;
            rd_count <= 16'd0;
            out_count <= 16'd0;
            pending_addr <= {AW{1'b0}};
            read_pending <= 1'b0;
            hold_valid <= 1'b0;
            hold_addr <= {AW{1'b0}};
            hold_data <= {COLS*PSUM_W*2{1'b0}};
            fifo_empty_wait_sticky <= 1'b0;
        end else begin
            done <= 1'b0;
            if (fifo_empty_wait)
                fifo_empty_wait_sticky <= 1'b1;

            if (!busy) begin
                packet_valid <= 1'b0;
                hold_valid <= 1'b0;
                read_pending <= 1'b0;
                rd_count <= 16'd0;
                out_count <= 16'd0;
                pending_addr <= {AW{1'b0}};
                if (start) begin
                    busy <= 1'b1;
                    packet_is_final <= is_final_pass;
                    fifo_empty_wait_sticky <= 1'b0;
                end
            end else begin
                if (packet_pop && (out_count == pixels_to_drain - 16'd1)) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    packet_valid <= 1'b0;
                    hold_valid <= 1'b0;
                    read_pending <= 1'b0;
                end else begin
                    if (packet_pop)
                        out_count <= out_count + 16'd1;

                    if (packet_pop || !packet_valid) begin
                        if (hold_valid) begin
                            packet_valid <= 1'b1;
                            packet_addr <= hold_addr;
                            packet_data <= hold_data;
                            hold_valid <= read_pending;
                            if (read_pending) begin
                                hold_addr <= pending_addr;
                                hold_data <= psum_fifo_rd_data;
                            end
                        end else if (read_pending) begin
                            packet_valid <= 1'b1;
                            packet_addr <= pending_addr;
                            packet_data <= psum_fifo_rd_data;
                        end else begin
                            packet_valid <= 1'b0;
                        end
                    end else if (read_pending) begin
                        hold_valid <= 1'b1;
                        hold_addr <= pending_addr;
                        hold_data <= psum_fifo_rd_data;
                    end

                    if (issue_read) begin
                        pending_addr <= rd_count[AW-1:0];
                        rd_count <= rd_count + 16'd1;
                    end
                    read_pending <= issue_read;
                end
            end
        end
    end
endmodule

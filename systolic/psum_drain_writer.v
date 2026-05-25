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
    output reg packet_is_final
);
    localparam ST_IDLE    = 2'd0;
    localparam ST_WAIT    = 2'd1;
    localparam ST_READ    = 2'd2;
    localparam ST_CAPTURE = 2'd3;

    localparam [31:0] COL_MASK = (32'h1 << COLS) - 1;

    reg [1:0] state;
    reg [AW-1:0] count;

    wire fifos_ready = ((psum_fifo_empty & COL_MASK) == 32'd0);
    wire [15:0] pixels_to_drain = (num_pixels == 16'd0) ? 16'd1 : num_pixels;

    assign psum_fifo_rd_en = (state == ST_READ) ? COL_MASK : 32'd0;

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            packet_valid <= 1'b0;
            packet_addr <= {AW{1'b0}};
            packet_data <= {COLS*PSUM_W*2{1'b0}};
            packet_is_final <= 1'b0;
            count <= {AW{1'b0}};
        end else begin
            done <= 1'b0;
            packet_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    count <= {AW{1'b0}};
                    if (start) begin
                        busy <= 1'b1;
                        packet_is_final <= is_final_pass;
                        state <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (fifos_ready)
                        state <= ST_READ;
                end

                ST_READ: begin
                    state <= ST_CAPTURE;
                end

                ST_CAPTURE: begin
                    packet_valid <= 1'b1;
                    packet_addr <= count;
                    packet_data <= psum_fifo_rd_data;
                    if (packet_ready) begin
                        if (count == pixels_to_drain[AW-1:0] - 1'b1) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            count <= count + 1'b1;
                            state <= ST_WAIT;
                        end
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

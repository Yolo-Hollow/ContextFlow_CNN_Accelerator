`timescale 1ns / 1ps

// Native 1x1 IFM loader for an 18-row systolic array.
//
// Each pixel is carried by three full 64-bit AXI-Stream beats:
//   beat 0: lanes 0..7
//   beat 1: lanes 8..15
//   beat 2: lanes 16..17, bytes 2..7 ignored
//
// A packet contains num_pixels vectors. In batch mode TLAST is accepted only
// on the final beat of the final expected packet.
module axis_ifm_vector_loader #(
    parameter ROWS = 18,
    parameter AXIS_W = 64,
    parameter KEEP_W = AXIS_W / 8
) (
    input  clk,
    input  rst,
    input  stream_reset,
    input  batch_mode,
    input  [31:0] expected_packets,
    input  [15:0] num_pixels,
    input  [7:0] input_zero_point,

    input  fill_req,
    output s_axis_tready,
    input  s_axis_tvalid,
    input  [AXIS_W-1:0] s_axis_tdata,
    input  [KEEP_W-1:0] s_axis_tkeep,
    input  s_axis_tlast,

    output [ROWS*8-1:0] vector_data,
    output vector_valid,
    input  vector_ready,
    output reg packet_done,

    output reg tkeep_error,
    output reg tlast_error,
    output reg [31:0] completed_packets,
    output reg [31:0] completed_pixels,
    output reg [31:0] accepted_beats,
    output reg [31:0] fifo_stall_cycles
);
    reg active;
    reg req_armed;
    reg [1:0] beat_index;
    reg [15:0] pixel_index;
    reg [143:0] raw_vector;
    reg vector_pending;
    reg pending_last_pixel;

    wire axis_fire = s_axis_tvalid && s_axis_tready;
    wire vector_fire = vector_pending && vector_ready;
    wire last_pixel = (pixel_index + 1'b1 == num_pixels);
    wire final_packet = !batch_mode ||
                        (completed_packets + 1'b1 == expected_packets);
    wire expected_tlast = (beat_index == 2'd2) && last_pixel && final_packet;

    assign s_axis_tready = active && !vector_pending;
    assign vector_valid = vector_pending;

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

    genvar lane;
    generate
        for (lane = 0; lane < ROWS; lane = lane + 1) begin : centered_lanes
            assign vector_data[lane*8 +: 8] =
                center_ifm_byte(raw_vector[lane*8 +: 8], input_zero_point);
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            active <= 1'b0;
            req_armed <= 1'b1;
            beat_index <= 2'd0;
            pixel_index <= 16'd0;
            raw_vector <= 144'd0;
            vector_pending <= 1'b0;
            pending_last_pixel <= 1'b0;
            packet_done <= 1'b0;
            tkeep_error <= 1'b0;
            tlast_error <= 1'b0;
            completed_packets <= 32'd0;
            completed_pixels <= 32'd0;
            accepted_beats <= 32'd0;
            fifo_stall_cycles <= 32'd0;
        end else begin
            packet_done <= 1'b0;

            if (!fill_req)
                req_armed <= 1'b1;

            if (!active && fill_req && req_armed && (num_pixels != 16'd0)) begin
                active <= 1'b1;
                req_armed <= 1'b0;
                beat_index <= 2'd0;
                pixel_index <= 16'd0;
            end

            if (axis_fire) begin
                accepted_beats <= accepted_beats + 1'b1;
                if (s_axis_tkeep != {KEEP_W{1'b1}})
                    tkeep_error <= 1'b1;
                if (s_axis_tlast != expected_tlast)
                    tlast_error <= 1'b1;

                case (beat_index)
                    2'd0: begin
                        raw_vector[63:0] <= s_axis_tdata;
                        beat_index <= 2'd1;
                    end
                    2'd1: begin
                        raw_vector[127:64] <= s_axis_tdata;
                        beat_index <= 2'd2;
                    end
                    default: begin
                        raw_vector[143:128] <= s_axis_tdata[15:0];
                        beat_index <= 2'd0;
                        vector_pending <= 1'b1;
                        pending_last_pixel <= last_pixel;
                    end
                endcase
            end

            if (vector_pending && !vector_ready)
                fifo_stall_cycles <= fifo_stall_cycles + 1'b1;

            if (vector_fire) begin
                vector_pending <= 1'b0;
                completed_pixels <= completed_pixels + 1'b1;
                if (pending_last_pixel) begin
                    active <= 1'b0;
                    pixel_index <= 16'd0;
                    completed_packets <= completed_packets + 1'b1;
                    packet_done <= 1'b1;
                end else begin
                    pixel_index <= pixel_index + 1'b1;
                end
            end

            if (stream_reset) begin
                completed_packets <= 32'd0;
                completed_pixels <= 32'd0;
                accepted_beats <= 32'd0;
                fifo_stall_cycles <= 32'd0;
            end
        end
    end
endmodule

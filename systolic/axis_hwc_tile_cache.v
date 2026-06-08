`timescale 1ns / 1ps

// Experimental raw-HWC IFM tile cache for native 1x1 layers.
//
// The IFM AXIS stream carries one uint8 HWC spatial tile:
//   pixel-major, then channel-major: pixel0 ch0..CIN-1, pixel1 ...
// The cache stores centered signed int8 bytes in 18 lane banks:
//   bank = channel % ROWS
//   addr = pixel * ceil(CIN / ROWS) + channel / ROWS
//
// This v1 loader intentionally unpacks one AXIS byte per cycle after each
// accepted 64-bit beat. It proves the protocol and replay path first; a later
// revision can parallelize the load side if raw-HWC mode becomes the default.
module axis_hwc_tile_cache #(
    parameter ROWS = 18,
    parameter AXIS_W = 64,
    parameter KEEP_W = AXIS_W / 8,
    parameter CACHE_AW = 12
) (
    input  clk,
    input  rst,
    input  stream_reset,
    input  [31:0] expected_packets,
    input  [15:0] num_pixels,
    input  [13:0] k_total,
    input  [13:0] pass_base_k,
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
    output reg overflow_error,
    output reg [31:0] completed_packets,
    output reg [31:0] completed_pixels,
    output reg [31:0] accepted_beats,
    output reg [31:0] fifo_stall_cycles
);
    localparam CACHE_DEPTH = (1 << CACHE_AW);

    reg [7:0] cache [0:ROWS-1][0:CACHE_DEPTH-1];

    reg load_active;
    reg tile_loaded;
    reg beat_pending;
    reg [AXIS_W-1:0] beat_data;
    reg [KEEP_W-1:0] beat_keep;
    reg beat_last;
    reg beat_last_expected;
    reg [3:0] beat_byte_idx;
    reg [3:0] beat_valid_count;

    reg [15:0] load_pixel;
    reg [13:0] load_channel;
    reg [13:0] load_chunk;
    reg [7:0] load_bank;
    reg [31:0] load_byte_count;

    reg replay_active;
    reg req_armed;
    reg [15:0] replay_pixel;

    wire axis_fire = s_axis_tvalid && s_axis_tready;
    wire vector_fire = vector_valid && vector_ready;
    wire [13:0] chunks_per_pixel = (k_total + ROWS - 1) / ROWS;
    wire [31:0] expected_bytes = num_pixels * k_total;
    wire [CACHE_AW-1:0] load_addr = (load_pixel * chunks_per_pixel) + load_chunk;
    wire current_keep = beat_keep[beat_byte_idx];
    wire last_beat_byte = (beat_byte_idx + 1'b1 == KEEP_W);
    wire replay_last_pixel = (replay_pixel + 1'b1 == num_pixels);

    assign s_axis_tready = load_active && !tile_loaded && !beat_pending;
    assign vector_valid = replay_active && tile_loaded;

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

    function [3:0] count_keep;
        input [KEEP_W-1:0] keep;
        integer i;
        begin
            count_keep = 4'd0;
            for (i = 0; i < KEEP_W; i = i + 1)
                if (keep[i])
                    count_keep = count_keep + 1'b1;
        end
    endfunction

    genvar lane;
    generate
        for (lane = 0; lane < ROWS; lane = lane + 1) begin : replay_lanes
            wire [13:0] lane_channel = pass_base_k + lane;
            wire [7:0] lane_bank = lane_channel % ROWS;
            wire [13:0] lane_chunk = lane_channel / ROWS;
            wire [CACHE_AW-1:0] lane_addr =
                (replay_pixel * chunks_per_pixel) + lane_chunk;
            assign vector_data[lane*8 +: 8] =
                (lane_channel < k_total && lane_addr < CACHE_DEPTH) ?
                cache[lane_bank][lane_addr] : 8'd0;
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            load_active <= 1'b0;
            tile_loaded <= 1'b0;
            beat_pending <= 1'b0;
            beat_data <= {AXIS_W{1'b0}};
            beat_keep <= {KEEP_W{1'b0}};
            beat_last <= 1'b0;
            beat_last_expected <= 1'b0;
            beat_byte_idx <= 4'd0;
            beat_valid_count <= 4'd0;
            load_pixel <= 16'd0;
            load_channel <= 14'd0;
            load_chunk <= 14'd0;
            load_bank <= 8'd0;
            load_byte_count <= 32'd0;
            replay_active <= 1'b0;
            req_armed <= 1'b1;
            replay_pixel <= 16'd0;
            packet_done <= 1'b0;
            tkeep_error <= 1'b0;
            tlast_error <= 1'b0;
            overflow_error <= 1'b0;
            completed_packets <= 32'd0;
            completed_pixels <= 32'd0;
            accepted_beats <= 32'd0;
            fifo_stall_cycles <= 32'd0;
        end else begin
            packet_done <= 1'b0;

            if (stream_reset) begin
                load_active <= 1'b1;
                tile_loaded <= 1'b0;
                beat_pending <= 1'b0;
                beat_byte_idx <= 4'd0;
                load_pixel <= 16'd0;
                load_channel <= 14'd0;
                load_chunk <= 14'd0;
                load_bank <= 8'd0;
                load_byte_count <= 32'd0;
                replay_active <= 1'b0;
                req_armed <= 1'b1;
                replay_pixel <= 16'd0;
                completed_packets <= 32'd0;
                completed_pixels <= 32'd0;
                accepted_beats <= 32'd0;
                fifo_stall_cycles <= 32'd0;
            end

            if (!fill_req)
                req_armed <= 1'b1;

            if (!replay_active && fill_req && req_armed && tile_loaded &&
                (num_pixels != 16'd0)) begin
                replay_active <= 1'b1;
                req_armed <= 1'b0;
                replay_pixel <= 16'd0;
            end

            if (axis_fire) begin
                accepted_beats <= accepted_beats + 1'b1;
                beat_data <= s_axis_tdata;
                beat_keep <= s_axis_tkeep;
                beat_last <= s_axis_tlast;
                beat_valid_count <= count_keep(s_axis_tkeep);
                beat_last_expected <=
                    (load_byte_count + count_keep(s_axis_tkeep) == expected_bytes);
                beat_pending <= 1'b1;
                beat_byte_idx <= 4'd0;
                if (s_axis_tkeep != {KEEP_W{1'b1}} &&
                    (load_byte_count + count_keep(s_axis_tkeep) != expected_bytes))
                    tkeep_error <= 1'b1;
                if (s_axis_tlast !=
                    (load_byte_count + count_keep(s_axis_tkeep) == expected_bytes))
                    tlast_error <= 1'b1;
            end

            if (beat_pending) begin
                if (current_keep) begin
                    if (load_addr < CACHE_DEPTH)
                        cache[load_bank][load_addr] <=
                            center_ifm_byte(beat_data[beat_byte_idx*8 +: 8],
                                            input_zero_point);
                    else
                        overflow_error <= 1'b1;

                    load_byte_count <= load_byte_count + 1'b1;
                    if (load_channel + 1'b1 == k_total) begin
                        load_channel <= 14'd0;
                        load_bank <= 8'd0;
                        load_chunk <= 14'd0;
                        load_pixel <= load_pixel + 1'b1;
                    end else begin
                        load_channel <= load_channel + 1'b1;
                        if (load_bank + 1'b1 == ROWS) begin
                            load_bank <= 8'd0;
                            load_chunk <= load_chunk + 1'b1;
                        end else begin
                            load_bank <= load_bank + 1'b1;
                        end
                    end
                end

                if (last_beat_byte) begin
                    beat_pending <= 1'b0;
                    if (beat_last) begin
                        load_active <= 1'b0;
                        if (beat_last_expected) begin
                            tile_loaded <= 1'b1;
                            completed_packets <= completed_packets + 1'b1;
                        end
                    end
                end else begin
                    beat_byte_idx <= beat_byte_idx + 1'b1;
                end
            end

            if (vector_valid && !vector_ready)
                fifo_stall_cycles <= fifo_stall_cycles + 1'b1;

            if (vector_fire) begin
                completed_pixels <= completed_pixels + 1'b1;
                if (replay_last_pixel) begin
                    replay_active <= 1'b0;
                    packet_done <= 1'b1;
                end else begin
                    replay_pixel <= replay_pixel + 1'b1;
                end
            end
        end
    end
endmodule

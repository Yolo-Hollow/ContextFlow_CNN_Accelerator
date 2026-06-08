`timescale 1ns / 1ps

// Experimental raw-HWC IFM tile cache for native 1x1 and directed 3x3 tiles.
//
// The IFM AXIS stream carries one uint8 HWC spatial tile:
//   pixel-major, then channel-major: pixel0 ch0..CIN-1, pixel1 ...
// 1x1 mode stores centered signed int8 bytes in 18 lane banks:
//   bank = channel % ROWS
//   addr = pixel * ceil(CIN / ROWS) + channel / ROWS
//
// 3x3 mode stores nine replicated kernel-position views so every output lane
// still has one private read port:
//   global_k = channel * 9 + kernel_pos
//   bank = global_k % ROWS
//   addr = pixel * ceil(K_TOTAL / ROWS) + global_k / ROWS
//
// In 3x3 mode the raw tile contains the clamped input rows needed by the
// output tile, in full-width HWC order. Padding beyond the cached rows/columns
// replays as internal signed zero.
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
    input  [8:0] fm_h,
    input  [8:0] fm_w,
    input  [8:0] ofm_w,
    input  [8:0] tile_oy_base,
    input  [8:0] tile_ofm_h,
    input  [1:0] conv_stride,
    input  [1:0] conv_pad,
    input  kernel_1x1,
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
    reg replay_valid;
    reg req_armed;
    reg [15:0] replay_pixel;
    reg replay_read_en;
    reg replay_read_pending;
    reg [15:0] replay_read_pixel;

    wire axis_fire = s_axis_tvalid && s_axis_tready;
    wire vector_fire = vector_valid && vector_ready;
    wire [13:0] raw_channels = kernel_1x1 ? k_total : ((k_total + 14'd8) / 14'd9);
    wire [13:0] cache_k_total = kernel_1x1 ? raw_channels : k_total;
    wire [13:0] chunks_per_pixel = (cache_k_total + ROWS - 1) / ROWS;
    wire signed [11:0] cache_first_y_s =
        $signed({3'd0, tile_oy_base}) * $signed({10'd0, conv_stride}) -
        $signed({10'd0, conv_pad});
    wire signed [11:0] cache_last_y_s =
        $signed({3'd0, tile_oy_base + tile_ofm_h - 1'b1}) *
        $signed({10'd0, conv_stride}) - $signed({10'd0, conv_pad}) + 12'sd2;
    wire [8:0] cache_y_base =
        kernel_1x1 ? tile_oy_base :
        ((cache_first_y_s < 0) ? 9'd0 : cache_first_y_s[8:0]);
    wire [8:0] cache_y_last =
        kernel_1x1 ? (tile_oy_base + tile_ofm_h - 1'b1) :
        ((cache_last_y_s >= $signed({3'd0, fm_h})) ? (fm_h - 1'b1) :
         cache_last_y_s[8:0]);
    wire [15:0] cache_pixels =
        kernel_1x1 ? num_pixels :
        (((cache_y_last >= cache_y_base) && (fm_w != 9'd0)) ?
         ((cache_y_last - cache_y_base + 1'b1) * fm_w) : 16'd0);
    wire [31:0] expected_bytes = cache_pixels * raw_channels;
    wire [CACHE_AW-1:0] load_addr_1x1 = (load_pixel * chunks_per_pixel) + load_chunk;
    wire current_keep = beat_keep[beat_byte_idx];
    wire last_beat_byte = (beat_byte_idx + 1'b1 == KEEP_W);
    wire replay_last_pixel = (replay_pixel + 1'b1 == num_pixels);

    assign s_axis_tready = load_active && !tile_loaded && !beat_pending;
    assign vector_valid = replay_valid;

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
        for (lane = 0; lane < ROWS; lane = lane + 1) begin : cache_banks
            localparam [4:0] LANE_ID = lane[4:0];
            (* ram_style = "block" *) reg [7:0] cache_bank [0:CACHE_DEPTH-1];
            reg [7:0] replay_lane_data;
            wire [13:0] lane_global_k = pass_base_k + lane;
            wire [13:0] lane_channel = kernel_1x1 ? lane_global_k : (lane_global_k / 14'd9);
            wire [3:0] lane_kernel_pos = kernel_1x1 ? 4'd0 : (lane_global_k % 14'd9);
            wire [1:0] lane_ky = kernel_1x1 ? 2'd0 : (lane_kernel_pos / 3);
            wire [1:0] lane_kx = kernel_1x1 ? 2'd0 : (lane_kernel_pos % 3);
            wire [13:0] lane_chunk =
                kernel_1x1 ? (lane_channel / ROWS) : (lane_global_k / ROWS);
            wire [4:0] load_bank_base = (load_channel * 14'd9) % ROWS;
            wire [4:0] load_lane_delta =
                (LANE_ID >= load_bank_base) ?
                (LANE_ID - load_bank_base) :
                (LANE_ID + ROWS - load_bank_base);
            wire load_lane_hit_3x3 = !kernel_1x1 && (load_lane_delta < 5'd9) &&
                                     (load_channel < raw_channels);
            wire [13:0] load_lane_global_k =
                (load_channel * 14'd9) + load_lane_delta[3:0];
            wire [CACHE_AW-1:0] load_addr_3x3 =
                (load_pixel * chunks_per_pixel) + (load_lane_global_k / ROWS);
            wire [8:0] replay_rel_y = (ofm_w == 9'd0) ? 9'd0 : (replay_read_pixel / ofm_w);
            wire [8:0] replay_x = (ofm_w == 9'd0) ? 9'd0 : (replay_read_pixel % ofm_w);
            wire signed [11:0] lane_fy_s =
                kernel_1x1 ? $signed({3'd0, tile_oy_base + replay_rel_y}) :
                ($signed({3'd0, tile_oy_base + replay_rel_y}) *
                 $signed({10'd0, conv_stride}) +
                 $signed({10'd0, lane_ky}) - $signed({10'd0, conv_pad}));
            wire signed [11:0] lane_fx_s =
                kernel_1x1 ? $signed({3'd0, replay_x}) :
                ($signed({3'd0, replay_x}) * $signed({10'd0, conv_stride}) +
                 $signed({10'd0, lane_kx}) - $signed({10'd0, conv_pad}));
            wire lane_in_bounds =
                (lane_global_k < k_total) &&
                (lane_channel < raw_channels) &&
                (lane_fy_s >= 0) && (lane_fy_s < $signed({3'd0, fm_h})) &&
                (lane_fx_s >= 0) && (lane_fx_s < $signed({3'd0, fm_w}));
            wire [15:0] lane_cache_pixel =
                ((lane_fy_s[8:0] - cache_y_base) * fm_w) + lane_fx_s[8:0];
            wire [CACHE_AW-1:0] lane_addr =
                (lane_cache_pixel * chunks_per_pixel) + lane_chunk;

            assign vector_data[lane*8 +: 8] = replay_lane_data;

            always @(posedge clk) begin
                if (rst || stream_reset) begin
                    replay_lane_data <= 8'd0;
                end else begin
                    if (beat_pending && current_keep) begin
                        if (kernel_1x1 &&
                            (load_bank == lane[7:0]) &&
                            (load_addr_1x1 < CACHE_DEPTH)) begin
                            cache_bank[load_addr_1x1] <=
                                center_ifm_byte(beat_data[beat_byte_idx*8 +: 8],
                                                input_zero_point);
                        end else if (load_lane_hit_3x3 &&
                                     (load_addr_3x3 < CACHE_DEPTH)) begin
                            cache_bank[load_addr_3x3] <=
                                center_ifm_byte(beat_data[beat_byte_idx*8 +: 8],
                                                input_zero_point);
                        end
                    end

                    if (replay_read_en) begin
                        replay_lane_data <=
                            (lane_in_bounds && lane_addr < CACHE_DEPTH) ?
                            cache_bank[lane_addr] : 8'd0;
                    end
                end
            end
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
            replay_valid <= 1'b0;
            req_armed <= 1'b1;
            replay_pixel <= 16'd0;
            replay_read_en <= 1'b0;
            replay_read_pending <= 1'b0;
            replay_read_pixel <= 16'd0;
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
            replay_read_en <= 1'b0;
            if (replay_read_pending) begin
                replay_valid <= 1'b1;
                replay_read_pending <= 1'b0;
            end

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
                replay_valid <= 1'b0;
                req_armed <= 1'b1;
                replay_pixel <= 16'd0;
                replay_read_pending <= 1'b0;
                replay_read_pixel <= 16'd0;
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
                replay_valid <= 1'b0;
                req_armed <= 1'b0;
                replay_pixel <= 16'd0;
                replay_read_en <= 1'b1;
                replay_read_pending <= 1'b1;
                replay_read_pixel <= 16'd0;
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
                    if ((kernel_1x1 && load_addr_1x1 >= CACHE_DEPTH) ||
                        (!kernel_1x1 &&
                         ((load_pixel * chunks_per_pixel) +
                          (((load_channel * 14'd9) + 14'd8) / ROWS)) >= CACHE_DEPTH))
                        overflow_error <= 1'b1;

                    load_byte_count <= load_byte_count + 1'b1;
                    if (load_channel + 1'b1 == raw_channels) begin
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
                    replay_valid <= 1'b0;
                    packet_done <= 1'b1;
                end else begin
                    replay_pixel <= replay_pixel + 1'b1;
                    replay_valid <= 1'b0;
                    replay_read_en <= 1'b1;
                    replay_read_pending <= 1'b1;
                    replay_read_pixel <= replay_pixel + 1'b1;
                end
            end
        end
    end
endmodule

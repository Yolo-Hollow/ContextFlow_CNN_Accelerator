`timescale 1ns / 1ps

module axis_hwc_tile_cache_slice #(
    parameter ADDR_W = 12,
    parameter DEPTH = (1 << ADDR_W),
    parameter USE_URAM = 0
) (
    input clk,
    input rst,
    input wr_en,
    input [8:0] wr_byte_en,
    input [ADDR_W-1:0] wr_addr,
    input [71:0] wr_data,
    input rd_en,
    input [ADDR_W-1:0] rd_addr,
    output reg [71:0] rd_data
);
    integer byte_idx;

    generate
        if (USE_URAM) begin : uram_storage
            (* ram_style = "ultra" *) reg [71:0] mem [0:DEPTH-1];

            always @(posedge clk) begin
                if (rst)
                    rd_data <= 72'd0;
                else if (rd_en)
                    rd_data <= mem[rd_addr];

                if (wr_en) begin
                    for (byte_idx = 0; byte_idx < 9; byte_idx = byte_idx + 1)
                        if (wr_byte_en[byte_idx])
                            mem[wr_addr][byte_idx*8 +: 8] <=
                                wr_data[byte_idx*8 +: 8];
                end
            end
        end else begin : bram_storage
            (* ram_style = "block" *) reg [71:0] mem [0:DEPTH-1];

            always @(posedge clk) begin
                if (rst)
                    rd_data <= 72'd0;
                else if (rd_en)
                    rd_data <= mem[rd_addr];

                if (wr_en) begin
                    for (byte_idx = 0; byte_idx < 9; byte_idx = byte_idx + 1)
                        if (wr_byte_en[byte_idx])
                            mem[wr_addr][byte_idx*8 +: 8] <=
                                wr_data[byte_idx*8 +: 8];
                end
            end
        end
    endgenerate
endmodule

module axis_hwc_tile_cache_bank #(
    parameter CACHE_AW = 12,
    parameter CACHE_DEPTH = (1 << CACHE_AW),
    parameter CACHE_STRIPES = 1,
    parameter USE_URAM = 0
) (
    input clk,
    input rst,
    input wr_en,
    input [8:0] wr_byte_en,
    input [CACHE_AW-1:0] wr_addr,
    input [71:0] wr_data,
    input rd_en,
    input [CACHE_AW-1:0] rd_addr,
    output [71:0] rd_data
);
    localparam STRIPE_DEPTH =
        (CACHE_DEPTH + CACHE_STRIPES - 1) / CACHE_STRIPES;

    generate
        if (CACHE_STRIPES == 4) begin : striped_storage
            wire [71:0] stripe_rd_data [0:3];
            reg [1:0] rd_stripe;

            always @(posedge clk) begin
                if (rst)
                    rd_stripe <= 2'd0;
                else if (rd_en)
                    rd_stripe <= rd_addr[1:0];
            end

            genvar stripe;
            for (stripe = 0; stripe < 4; stripe = stripe + 1) begin : stripes
                axis_hwc_tile_cache_slice #(
                    .ADDR_W(CACHE_AW),
                    .DEPTH(STRIPE_DEPTH),
                    .USE_URAM(USE_URAM)
                ) u_slice (
                    .clk(clk),
                    .rst(rst),
                    .wr_en(wr_en && (wr_addr[1:0] == stripe)),
                    .wr_byte_en(wr_byte_en),
                    .wr_addr(wr_addr >> 2),
                    .wr_data(wr_data),
                    .rd_en(rd_en && (rd_addr[1:0] == stripe)),
                    .rd_addr(rd_addr >> 2),
                    .rd_data(stripe_rd_data[stripe])
                );
            end

            assign rd_data =
                (rd_stripe == 2'd0) ? stripe_rd_data[0] :
                (rd_stripe == 2'd1) ? stripe_rd_data[1] :
                (rd_stripe == 2'd2) ? stripe_rd_data[2] :
                                      stripe_rd_data[3];
        end else begin : unstriped_storage
            axis_hwc_tile_cache_slice #(
                .ADDR_W(CACHE_AW),
                .DEPTH(CACHE_DEPTH),
                .USE_URAM(USE_URAM)
            ) u_slice (
                .clk(clk),
                .rst(rst),
                .wr_en(wr_en),
                .wr_byte_en(wr_byte_en),
                .wr_addr(wr_addr),
                .wr_data(wr_data),
                .rd_en(rd_en),
                .rd_addr(rd_addr),
                .rd_data(rd_data)
            );
        end
    endgenerate
endmodule

// Experimental raw-HWC IFM tile cache for native 1x1 and directed 3x3 tiles.
//
// The IFM AXIS stream carries one uint8 HWC spatial tile:
//   pixel-major, then channel-major: pixel0 ch0..CIN-1, pixel1 ...
// The cache uses two 72-bit groups. Each replay address returns 18 bytes.
// 1x1 mode packs 18 consecutive channels:
//   group = (channel % 18) / 9
//   byte = channel % 9
//   addr = (channel / 18) * tile_pixels + pixel
//
// 3x3 mode materializes one packed 2-channel window per output pixel:
//   group = channel % 2
//   byte = kernel_pos
//   addr = (channel / 2) * tile_pixels + output_pixel
//
// In 3x3 mode the raw tile contains the clamped input rows needed by the
// output tile, in full-width HWC order. The loader scatters each input byte
// into the output windows it contributes to. Padding replays as signed zero.
//
// This v1 loader intentionally unpacks one AXIS byte per cycle after each
// accepted 64-bit beat. It proves the protocol and replay path first; a later
// revision can parallelize the load side if raw-HWC mode becomes the default.
module axis_hwc_tile_cache #(
    parameter ROWS = 18,
    parameter AXIS_W = 64,
    parameter KEEP_W = AXIS_W / 8,
    parameter CACHE_AW = 12,
    parameter CACHE_DEPTH = (1 << CACHE_AW),
    parameter CACHE_STRIPES = 1,
    parameter CACHE_USE_URAM = 0
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
    output reg [31:0] fifo_stall_cycles,
    output reg [31:0] load_active_cycles,
    output reg [31:0] load_unpack_cycles,
    output reg [31:0] replay_active_cycles,
    output reg [31:0] replay_wait_ready_cycles
);
    reg load_active;
    reg tile_loaded;
    reg beat_pending;
    reg [AXIS_W-1:0] beat_data;
    reg [KEEP_W-1:0] beat_keep;
    reg beat_last;
    reg beat_last_expected;
    reg [3:0] beat_byte_idx;
    reg [3:0] beat_valid_count;
    reg [31:0] expected_bytes_q;

    reg [15:0] load_pixel;
    reg [13:0] load_channel;
    reg [3:0] load_kernel_pos;
    reg [8:0] load_input_y;
    reg [8:0] load_input_x;
    reg [31:0] load_byte_count;

    reg replay_active;
    reg replay_valid;
    reg req_armed;
    reg [15:0] replay_rd_pixel;
    reg [15:0] replay_out_pixel;
    reg [8:0] replay_rd_rel_y;
    reg [8:0] replay_rd_x;
    reg [8:0] replay_out_rel_y;
    reg [8:0] replay_out_x;
    reg [CACHE_AW-1:0] replay_mem_addr;
    reg [ROWS-1:0] replay_out_lane_valid;

    reg cache_wr_en_q;
    reg cache_wr_group_q;
    reg [8:0] cache_wr_byte_en_q;
    reg [CACHE_AW-1:0] cache_wr_addr_q;
    reg [71:0] cache_wr_data_q;

    wire axis_fire = s_axis_tvalid && s_axis_tready;
    wire vector_fire = vector_valid && vector_ready;
    wire [13:0] raw_channels = kernel_1x1 ? k_total : ((k_total + 14'd8) / 14'd9);
    wire [10:0] cache_first_y_scaled =
        (conv_stride == 2'd2) ? ({2'd0, tile_oy_base} << 1) :
                                {2'd0, tile_oy_base};
    wire [10:0] cache_last_y_scaled =
        (conv_stride == 2'd2) ?
        ({2'd0, tile_oy_base + tile_ofm_h - 1'b1} << 1) :
         {2'd0, tile_oy_base + tile_ofm_h - 1'b1};
    wire signed [11:0] cache_first_y_s =
        $signed({1'b0, cache_first_y_scaled}) -
        $signed({10'd0, conv_pad});
    wire signed [11:0] cache_last_y_s =
        $signed({1'b0, cache_last_y_scaled}) -
        $signed({10'd0, conv_pad}) + 12'sd2;
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
    wire current_keep = beat_keep[beat_byte_idx];
    wire last_beat_byte = (beat_byte_idx + 1'b1 == KEEP_W);
    wire replay_last_out_pixel = (replay_out_pixel + 1'b1 == num_pixels);
    wire replay_rd_done = (replay_rd_pixel == num_pixels);
    wire replay_output_fire = replay_valid && vector_ready;
    wire replay_can_issue_read =
        replay_active && !replay_rd_done &&
        (!replay_valid || vector_ready);
    wire replay_read_en = replay_can_issue_read;
    wire [15:0] replay_pixel = replay_out_pixel;
    wire source_byte_done = kernel_1x1 || (load_kernel_pos == 4'd8);

    wire [1:0] load_ky = load_kernel_pos / 3;
    wire [1:0] load_kx = load_kernel_pos % 3;
    wire signed [11:0] load_oy_num =
        $signed({3'd0, load_input_y}) + $signed({10'd0, conv_pad}) -
        $signed({10'd0, load_ky});
    wire signed [11:0] load_ox_num =
        $signed({3'd0, load_input_x}) + $signed({10'd0, conv_pad}) -
        $signed({10'd0, load_kx});
    wire signed [11:0] load_oy_s =
        (conv_stride == 2'd2) ? (load_oy_num >>> 1) : load_oy_num;
    wire signed [11:0] load_ox_s =
        (conv_stride == 2'd2) ? (load_ox_num >>> 1) : load_ox_num;
    wire [8:0] load_oy = load_oy_s[8:0];
    wire [8:0] load_ox = load_ox_s[8:0];
    wire load_oy_aligned =
        (conv_stride == 2'd1) ||
        ((conv_stride == 2'd2) && !load_oy_num[0]);
    wire load_ox_aligned =
        (conv_stride == 2'd1) ||
        ((conv_stride == 2'd2) && !load_ox_num[0]);
    wire load_scatter_valid =
        !kernel_1x1 && load_oy_aligned && load_ox_aligned &&
        (load_oy_num >= 0) && (load_ox_num >= 0) &&
        (load_oy >= tile_oy_base) &&
        (load_oy < tile_oy_base + tile_ofm_h) &&
        (load_ox < ofm_w);
    wire [15:0] load_output_pixel =
        ((load_oy - tile_oy_base) * ofm_w) + load_ox;
    wire [CACHE_AW-1:0] load_addr_1x1 =
        ((load_channel / 14'd18) * num_pixels) + load_pixel;
    wire [CACHE_AW-1:0] load_addr_3x3 =
        ((load_channel >> 1) * num_pixels) + load_output_pixel;
    wire load_group =
        kernel_1x1 ? ((load_channel % 14'd18) >= 14'd9) :
                     load_channel[0];
    wire [3:0] load_byte_slot =
        kernel_1x1 ? (load_channel % 14'd9) : load_kernel_pos;
    wire [8:0] load_byte_en = 9'b1 << load_byte_slot;
    wire [7:0] load_centered_byte =
        center_ifm_byte(beat_data[beat_byte_idx*8 +: 8], input_zero_point);
    wire [71:0] load_word_data = {9{load_centered_byte}};
    wire load_write_valid =
        beat_pending && current_keep &&
        (kernel_1x1 || load_scatter_valid);
    wire [CACHE_AW-1:0] load_write_addr =
        kernel_1x1 ? load_addr_1x1 : load_addr_3x3;
    wire [13:0] replay_chunk =
        pass_base_k / 14'd18;
    wire [ROWS-1:0] replay_start_lane_valid;
    wire [71:0] replay_group0;
    wire [71:0] replay_group1;

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
        for (lane = 0; lane < ROWS; lane = lane + 1) begin : vector_lanes
            localparam integer LANE_GROUP = lane / 9;
            localparam integer LANE_KERNEL_POS = lane % 9;
            localparam integer LANE_KY = LANE_KERNEL_POS / 3;
            localparam integer LANE_KX = LANE_KERNEL_POS % 3;
            wire [13:0] replay_start_channel_3x3 =
                (replay_chunk << 1) + LANE_GROUP;
            wire [10:0] replay_y_scaled =
                (conv_stride == 2'd2) ?
                ({2'd0, tile_oy_base + replay_out_rel_y} << 1) :
                 {2'd0, tile_oy_base + replay_out_rel_y};
            wire [10:0] replay_x_scaled =
                (conv_stride == 2'd2) ?
                ({2'd0, replay_out_x} << 1) :
                 {2'd0, replay_out_x};
            wire signed [11:0] lane_fy_s =
                kernel_1x1 ? $signed({3'd0, tile_oy_base + replay_out_rel_y}) :
                ($signed({1'b0, replay_y_scaled}) +
                 LANE_KY - $signed({10'd0, conv_pad}));
            wire signed [11:0] lane_fx_s =
                kernel_1x1 ? $signed({3'd0, replay_out_x}) :
                ($signed({1'b0, replay_x_scaled}) +
                 LANE_KX - $signed({10'd0, conv_pad}));
            wire lane_in_bounds =
                replay_out_lane_valid[lane] &&
                (lane_fy_s >= 0) && (lane_fy_s < $signed({3'd0, fm_h})) &&
                (lane_fx_s >= 0) && (lane_fx_s < $signed({3'd0, fm_w}));
            wire [7:0] packed_byte =
                (lane < 9) ?
                replay_group0[LANE_KERNEL_POS*8 +: 8] :
                replay_group1[LANE_KERNEL_POS*8 +: 8];

            assign vector_data[lane*8 +: 8] =
                lane_in_bounds ? packed_byte : 8'd0;
            assign replay_start_lane_valid[lane] =
                kernel_1x1 ?
                ((pass_base_k + lane) < k_total) :
                (replay_start_channel_3x3 < raw_channels);
        end
    endgenerate

    axis_hwc_tile_cache_bank #(
        .CACHE_AW(CACHE_AW),
        .CACHE_DEPTH(CACHE_DEPTH),
        .CACHE_STRIPES(CACHE_STRIPES),
        .USE_URAM(CACHE_USE_URAM)
    ) u_cache_group0 (
        .clk(clk),
        .rst(rst || stream_reset),
        .wr_en(cache_wr_en_q && !cache_wr_group_q),
        .wr_byte_en(cache_wr_byte_en_q),
        .wr_addr(cache_wr_addr_q),
        .wr_data(cache_wr_data_q),
        .rd_en(replay_read_en),
        .rd_addr(replay_mem_addr),
        .rd_data(replay_group0)
    );

    axis_hwc_tile_cache_bank #(
        .CACHE_AW(CACHE_AW),
        .CACHE_DEPTH(CACHE_DEPTH),
        .CACHE_STRIPES(CACHE_STRIPES),
        .USE_URAM(CACHE_USE_URAM)
    ) u_cache_group1 (
        .clk(clk),
        .rst(rst || stream_reset),
        .wr_en(cache_wr_en_q && cache_wr_group_q),
        .wr_byte_en(cache_wr_byte_en_q),
        .wr_addr(cache_wr_addr_q),
        .wr_data(cache_wr_data_q),
        .rd_en(replay_read_en),
        .rd_addr(replay_mem_addr),
        .rd_data(replay_group1)
    );

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
            expected_bytes_q <= 32'd0;
            load_pixel <= 16'd0;
            load_channel <= 14'd0;
            load_kernel_pos <= 4'd0;
            load_input_y <= 9'd0;
            load_input_x <= 9'd0;
            load_byte_count <= 32'd0;
            replay_active <= 1'b0;
            replay_valid <= 1'b0;
            req_armed <= 1'b1;
            replay_rd_pixel <= 16'd0;
            replay_out_pixel <= 16'd0;
            replay_rd_rel_y <= 9'd0;
            replay_rd_x <= 9'd0;
            replay_out_rel_y <= 9'd0;
            replay_out_x <= 9'd0;
            replay_mem_addr <= {CACHE_AW{1'b0}};
            replay_out_lane_valid <= {ROWS{1'b0}};
            cache_wr_en_q <= 1'b0;
            cache_wr_group_q <= 1'b0;
            cache_wr_byte_en_q <= 9'd0;
            cache_wr_addr_q <= {CACHE_AW{1'b0}};
            cache_wr_data_q <= 72'd0;
            packet_done <= 1'b0;
            tkeep_error <= 1'b0;
            tlast_error <= 1'b0;
            overflow_error <= 1'b0;
            completed_packets <= 32'd0;
            completed_pixels <= 32'd0;
            accepted_beats <= 32'd0;
            fifo_stall_cycles <= 32'd0;
            load_active_cycles <= 32'd0;
            load_unpack_cycles <= 32'd0;
            replay_active_cycles <= 32'd0;
            replay_wait_ready_cycles <= 32'd0;
        end else begin
            packet_done <= 1'b0;
            cache_wr_en_q <= 1'b0;
            replay_valid <= (replay_valid && !replay_output_fire) ||
                            replay_can_issue_read;

            if (stream_reset) begin
                load_active <= 1'b1;
                tile_loaded <= 1'b0;
                beat_pending <= 1'b0;
                beat_byte_idx <= 4'd0;
                expected_bytes_q <= expected_bytes;
                load_pixel <= 16'd0;
                load_channel <= 14'd0;
                load_kernel_pos <= 4'd0;
                load_input_y <= cache_y_base;
                load_input_x <= 9'd0;
                load_byte_count <= 32'd0;
                replay_active <= 1'b0;
                replay_valid <= 1'b0;
                req_armed <= 1'b1;
                replay_rd_pixel <= 16'd0;
                replay_out_pixel <= 16'd0;
                replay_rd_rel_y <= 9'd0;
                replay_rd_x <= 9'd0;
                replay_out_rel_y <= 9'd0;
                replay_out_x <= 9'd0;
                replay_mem_addr <= {CACHE_AW{1'b0}};
                replay_out_lane_valid <= {ROWS{1'b0}};
                cache_wr_en_q <= 1'b0;
                completed_packets <= 32'd0;
                completed_pixels <= 32'd0;
                accepted_beats <= 32'd0;
                fifo_stall_cycles <= 32'd0;
                load_active_cycles <= 32'd0;
                load_unpack_cycles <= 32'd0;
                replay_active_cycles <= 32'd0;
                replay_wait_ready_cycles <= 32'd0;
            end

            if (load_active && !tile_loaded)
                load_active_cycles <= load_active_cycles + 1'b1;
            if (beat_pending)
                load_unpack_cycles <= load_unpack_cycles + 1'b1;
            if (replay_active || replay_valid)
                replay_active_cycles <= replay_active_cycles + 1'b1;

            if (!fill_req)
                req_armed <= 1'b1;

            if (!replay_active && fill_req && req_armed && tile_loaded &&
                (num_pixels != 16'd0)) begin
                replay_active <= 1'b1;
                replay_valid <= 1'b0;
                req_armed <= 1'b0;
                replay_rd_pixel <= 16'd0;
                replay_out_pixel <= 16'd0;
                replay_rd_rel_y <= 9'd0;
                replay_rd_x <= 9'd0;
                replay_out_rel_y <= 9'd0;
                replay_out_x <= 9'd0;
                replay_mem_addr <= replay_chunk * num_pixels;
                replay_out_lane_valid <= {ROWS{1'b0}};
            end

            if (axis_fire) begin
                accepted_beats <= accepted_beats + 1'b1;
                beat_data <= s_axis_tdata;
                beat_keep <= s_axis_tkeep;
                beat_last <= s_axis_tlast;
                beat_valid_count <= count_keep(s_axis_tkeep);
                beat_last_expected <=
                    (load_byte_count + count_keep(s_axis_tkeep) == expected_bytes_q);
                beat_pending <= 1'b1;
                beat_byte_idx <= 4'd0;
                if (s_axis_tkeep != {KEEP_W{1'b1}} &&
                    (load_byte_count + count_keep(s_axis_tkeep) != expected_bytes_q))
                    tkeep_error <= 1'b1;
                if (s_axis_tlast !=
                    (load_byte_count + count_keep(s_axis_tkeep) == expected_bytes_q))
                    tlast_error <= 1'b1;
            end

            if (beat_pending) begin
                if (current_keep) begin
                    if (load_write_valid && load_write_addr >= CACHE_DEPTH)
                        overflow_error <= 1'b1;
                    if (load_write_valid && load_write_addr < CACHE_DEPTH) begin
                        cache_wr_en_q <= 1'b1;
                        cache_wr_group_q <= load_group;
                        cache_wr_byte_en_q <= load_byte_en;
                        cache_wr_addr_q <= load_write_addr;
                        cache_wr_data_q <= load_word_data;
                    end

                    if (source_byte_done) begin
                        load_kernel_pos <= 4'd0;
                        load_byte_count <= load_byte_count + 1'b1;
                        if (load_channel + 1'b1 == raw_channels) begin
                            load_channel <= 14'd0;
                            load_pixel <= load_pixel + 1'b1;
                            if (load_input_x + 1'b1 == fm_w) begin
                                load_input_x <= 9'd0;
                                load_input_y <= load_input_y + 1'b1;
                            end else begin
                                load_input_x <= load_input_x + 1'b1;
                            end
                        end else begin
                            load_channel <= load_channel + 1'b1;
                        end
                    end else begin
                        load_kernel_pos <= load_kernel_pos + 1'b1;
                    end
                end

                if (!current_keep || source_byte_done) begin
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
            end

            if (replay_can_issue_read) begin
                replay_out_pixel <= replay_rd_pixel;
                replay_out_rel_y <= replay_rd_rel_y;
                replay_out_x <= replay_rd_x;
                replay_out_lane_valid <= replay_start_lane_valid;
                replay_rd_pixel <= replay_rd_pixel + 1'b1;
                if (replay_rd_x + 1'b1 == ofm_w) begin
                    replay_rd_x <= 9'd0;
                    replay_rd_rel_y <= replay_rd_rel_y + 1'b1;
                end else begin
                    replay_rd_x <= replay_rd_x + 1'b1;
                end
                replay_mem_addr <= replay_mem_addr + 1'b1;
            end

            if (vector_valid && !vector_ready) begin
                fifo_stall_cycles <= fifo_stall_cycles + 1'b1;
                replay_wait_ready_cycles <= replay_wait_ready_cycles + 1'b1;
            end

            if (vector_fire) begin
                completed_pixels <= completed_pixels + 1'b1;
                if (replay_last_out_pixel) begin
                    replay_active <= 1'b0;
                    replay_valid <= 1'b0;
                    packet_done <= 1'b1;
                end
            end
        end
    end
endmodule

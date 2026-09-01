`timescale 1ns / 1ps

// Convert one layer-level start into a sequence of spatial-tile starts.
//
// Configuration is deliberately transactional.  A layer start first captures
// the descriptor, the following cycle registers the candidate geometry, and
// a final commit cycle updates every externally visible tile field together.
// tile_start is emitted only after that atomic commit.  This prevents runtime
// geometry products from directly feeding the tile engine's ordinary state
// registers and keeps every field stable while tile_start_ready is low.
module layer_tile_sequencer #(
    parameter integer MAX_TILE_PIXELS = 1024,
    parameter integer COUT_TILE = 32,
    parameter integer MAX_PACKED_ENTRIES = 4096,
    parameter integer CFG_PREVALIDATED = 0
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        layer_start,
    input  wire [8:0]  cfg_ofm_h,
    input  wire [8:0]  cfg_ofm_w,
    input  wire [8:0]  cfg_tile_h_max,
    input  wire [10:0] cfg_cout_total,
    input  wire        cfg_pool_enable,
    input  wire [1:0]  cfg_pool_stride,
    input  wire [8:0]  cfg_prevalidated_tile_h,
    input  wire [15:0] cfg_prevalidated_tile_pixels,
    input  wire [15:0] cfg_prevalidated_tile_output_pixels,
    input  wire [15:0] cfg_prevalidated_cout_blocks,

    output reg         layer_busy,
    output reg         layer_done,
    output reg         tile_start,
    input  wire        tile_start_ready,
    input  wire        tile_done,

    output reg  [8:0]  tile_oy_base,
    output reg  [8:0]  tile_ofm_h,
    output reg  [15:0] tile_num_pixels,
    // This value is committed atomically with tile_oy_base.  Preserve the
    // register boundary: otherwise synthesis can legally reconstruct the
    // value from tile_oy_base and move the downstream packed-span register
    // into the multiplier, recreating the full next-tile geometry cone.
    (* KEEP = "TRUE" *)
    output reg  [15:0] tile_output_pixels,
    output reg  [23:0] tile_output_pixel_base,
    output reg         tile_last,
    output reg  [15:0] tile_index,

    output reg         config_error,
    output reg         protocol_error,
    output reg  [31:0] tile_start_count,
    output reg  [31:0] tile_done_count
);
    reg [8:0] ofm_h_q;
    reg [8:0] ofm_w_q;
    reg [8:0] tile_h_max_q;
    reg pool_enable_q;
    reg [1:0] pool_stride_q;
    reg [10:0] cout_total_q;
    reg [8:0] prevalidated_tile_h_q;
    reg [15:0] prevalidated_tile_pixels_q;
    reg [15:0] prevalidated_tile_output_pixels_q;
    reg [15:0] prevalidated_cout_blocks_q;

    reg geometry_pending_q;
    reg geometry_first_q;
    reg commit_pending_q;
    reg tile_start_pending_q;

    reg [8:0] candidate_oy_base_q;
    reg [8:0] candidate_tile_h_q;
    reg [15:0] candidate_pixels_q;
    reg [15:0] candidate_output_pixels_q;
    reg [23:0] candidate_output_base_q;
    reg [15:0] candidate_index_q;
    reg candidate_last_q;
    reg candidate_invalid_q;
    reg [15:0] candidate_cout_blocks_q;

    wire [8:0] begin_tile_h_limit =
        (tile_h_max_q == 9'd0) ? ofm_h_q : tile_h_max_q;
    wire [8:0] begin_tile_h_local =
        (ofm_h_q > begin_tile_h_limit) ? begin_tile_h_limit : ofm_h_q;
    wire [8:0] begin_tile_h = (CFG_PREVALIDATED != 0) ?
        prevalidated_tile_h_q : begin_tile_h_local;
    wire [17:0] begin_tile_pixels_local = begin_tile_h_local * ofm_w_q;
    wire [17:0] begin_output_pixels_local = pool_enable_q ?
        (begin_tile_h_local[8:1] * ofm_w_q[8:1]) :
        begin_tile_pixels_local;
    wire [15:0] begin_tile_pixels = (CFG_PREVALIDATED != 0) ?
        prevalidated_tile_pixels_q : begin_tile_pixels_local[15:0];
    wire [15:0] begin_output_pixels = (CFG_PREVALIDATED != 0) ?
        prevalidated_tile_output_pixels_q :
        begin_output_pixels_local[15:0];
    wire [15:0] begin_cout_blocks_local =
        (cout_total_q + COUT_TILE - 1) / COUT_TILE;
    wire [15:0] begin_cout_blocks = (CFG_PREVALIDATED != 0) ?
        prevalidated_cout_blocks_q : begin_cout_blocks_local;
    wire begin_pool_stride_valid =
        !pool_enable_q || (pool_stride_q == 2'd2);
    wire begin_pool_tile_even =
        !pool_enable_q ||
        (!ofm_h_q[0] && !ofm_w_q[0] && !begin_tile_h_local[0]);
    wire begin_config_invalid_local =
        (ofm_h_q == 9'd0) || (ofm_w_q == 9'd0) ||
        (cout_total_q == 11'd0) || (begin_tile_h_limit == 9'd0) ||
        !begin_pool_stride_valid || !begin_pool_tile_even ||
        (begin_tile_pixels_local > MAX_TILE_PIXELS);

    wire [9:0] next_oy_math = tile_oy_base + tile_ofm_h;
    wire [9:0] next_remaining_math = {1'b0, ofm_h_q} - next_oy_math;
    wire [8:0] next_tile_h =
        (next_remaining_math[8:0] > tile_h_max_q) ?
        tile_h_max_q : next_remaining_math[8:0];
    wire [17:0] next_tile_pixels_math = next_tile_h * ofm_w_q;
    wire [17:0] next_output_pixels_math =
        pool_enable_q && (pool_stride_q == 2'd2) ?
        (next_tile_h[8:1] * ofm_w_q[8:1]) : next_tile_pixels_math;
    wire [31:0] candidate_packed_span =
        candidate_output_pixels_q * candidate_cout_blocks_q;
    wire candidate_commit_invalid = candidate_invalid_q ||
        ((CFG_PREVALIDATED == 0) &&
         (candidate_packed_span > MAX_PACKED_ENTRIES));

    always @(posedge clk) begin
        if (rst) begin
            layer_busy <= 1'b0;
            layer_done <= 1'b0;
            tile_start <= 1'b0;
            tile_oy_base <= 9'd0;
            tile_ofm_h <= 9'd0;
            tile_num_pixels <= 16'd0;
            tile_output_pixels <= 16'd0;
            tile_output_pixel_base <= 24'd0;
            tile_last <= 1'b0;
            tile_index <= 16'd0;
            ofm_h_q <= 9'd0;
            ofm_w_q <= 9'd0;
            tile_h_max_q <= 9'd0;
            pool_enable_q <= 1'b0;
            pool_stride_q <= 2'd0;
            cout_total_q <= 11'd0;
            prevalidated_tile_h_q <= 9'd0;
            prevalidated_tile_pixels_q <= 16'd0;
            prevalidated_tile_output_pixels_q <= 16'd0;
            prevalidated_cout_blocks_q <= 16'd0;
            geometry_pending_q <= 1'b0;
            geometry_first_q <= 1'b0;
            commit_pending_q <= 1'b0;
            tile_start_pending_q <= 1'b0;
            candidate_oy_base_q <= 9'd0;
            candidate_tile_h_q <= 9'd0;
            candidate_pixels_q <= 16'd0;
            candidate_output_pixels_q <= 16'd0;
            candidate_output_base_q <= 24'd0;
            candidate_index_q <= 16'd0;
            candidate_last_q <= 1'b0;
            candidate_invalid_q <= 1'b0;
            candidate_cout_blocks_q <= 16'd0;
            config_error <= 1'b0;
            protocol_error <= 1'b0;
            tile_start_count <= 32'd0;
            tile_done_count <= 32'd0;
        end else begin
            layer_done <= 1'b0;
            tile_start <= 1'b0;

            if (layer_start && (layer_busy || geometry_pending_q ||
                                commit_pending_q))
                protocol_error <= 1'b1;
            if (tile_done && (!layer_busy || geometry_pending_q ||
                              commit_pending_q || tile_start_pending_q))
                protocol_error <= 1'b1;

            if (layer_start && !layer_busy && !geometry_pending_q &&
                !commit_pending_q) begin
                // Capture the complete descriptor before doing any geometry
                // arithmetic.  Mark the layer busy immediately so a second
                // start cannot overwrite this transaction.
                ofm_h_q <= cfg_ofm_h;
                ofm_w_q <= cfg_ofm_w;
                tile_h_max_q <= (cfg_tile_h_max == 9'd0) ?
                    cfg_ofm_h : cfg_tile_h_max;
                pool_enable_q <= cfg_pool_enable;
                pool_stride_q <= cfg_pool_stride;
                cout_total_q <= cfg_cout_total;
                prevalidated_tile_h_q <= cfg_prevalidated_tile_h;
                prevalidated_tile_pixels_q <=
                    cfg_prevalidated_tile_pixels;
                prevalidated_tile_output_pixels_q <=
                    cfg_prevalidated_tile_output_pixels;
                prevalidated_cout_blocks_q <=
                    cfg_prevalidated_cout_blocks;
                layer_busy <= 1'b1;
                config_error <= 1'b0;
                protocol_error <= 1'b0;
                tile_start_count <= 32'd0;
                tile_done_count <= 32'd0;
                geometry_pending_q <= 1'b1;
                geometry_first_q <= 1'b1;
                tile_start_pending_q <= 1'b0;
            end else if (geometry_pending_q) begin
                geometry_pending_q <= 1'b0;
                commit_pending_q <= 1'b1;
                candidate_cout_blocks_q <= begin_cout_blocks;
                if (geometry_first_q) begin
                    candidate_oy_base_q <= 9'd0;
                    candidate_tile_h_q <= begin_tile_h;
                    candidate_pixels_q <= begin_tile_pixels;
                    candidate_output_pixels_q <= begin_output_pixels;
                    candidate_output_base_q <= 24'd0;
                    candidate_index_q <= 16'd0;
                    candidate_last_q <= (begin_tile_h >= ofm_h_q);
                    candidate_invalid_q <= (CFG_PREVALIDATED != 0) ?
                        1'b0 : begin_config_invalid_local;
                end else begin
                    candidate_oy_base_q <= next_oy_math[8:0];
                    candidate_tile_h_q <= next_tile_h;
                    candidate_pixels_q <= next_tile_pixels_math[15:0];
                    candidate_output_pixels_q <=
                        next_output_pixels_math[15:0];
                    candidate_output_base_q <=
                        tile_output_pixel_base + tile_output_pixels;
                    candidate_index_q <= tile_index + 1'b1;
                    candidate_last_q <=
                        ((next_oy_math + next_tile_h) >= ofm_h_q);
                    candidate_invalid_q <=
                        (next_tile_h == 0) ||
                        (next_tile_pixels_math > MAX_TILE_PIXELS);
                end
            end else if (commit_pending_q) begin
                commit_pending_q <= 1'b0;
                if (candidate_commit_invalid) begin
                    layer_busy <= 1'b0;
                    config_error <= 1'b1;
                    tile_start_pending_q <= 1'b0;
                end else begin
                    // All tile-visible fields change atomically here.  The
                    // start pulse is a later ready/valid transaction.
                    tile_oy_base <= candidate_oy_base_q;
                    tile_ofm_h <= candidate_tile_h_q;
                    tile_num_pixels <= candidate_pixels_q;
                    tile_output_pixels <= candidate_output_pixels_q;
                    tile_output_pixel_base <= candidate_output_base_q;
                    tile_index <= candidate_index_q;
                    tile_last <= candidate_last_q;
                    tile_start_pending_q <= 1'b1;
                end
            end else if (layer_busy && tile_start_pending_q) begin
                if (tile_start_ready) begin
                    tile_start <= 1'b1;
                    tile_start_pending_q <= 1'b0;
                    tile_start_count <= tile_start_count + 1'b1;
                end
            end else if (layer_busy && tile_done) begin
                tile_done_count <= tile_done_count + 1'b1;
                if (tile_last) begin
                    layer_busy <= 1'b0;
                    layer_done <= 1'b1;
                end else begin
                    geometry_pending_q <= 1'b1;
                    geometry_first_q <= 1'b0;
                end
            end
        end
    end
endmodule

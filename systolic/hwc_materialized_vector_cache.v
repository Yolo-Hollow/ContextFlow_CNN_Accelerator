`timescale 1ns / 1ps

// True dual-port-style storage used by hwc_materialized_vector_cache.  The
// write side stores the complete vector and its context tag atomically.  The
// read side is synchronous and can deliver one vector every cycle.
module hwc_materialized_vector_cache_ram #(
    parameter integer ROWS = 18,
    parameter integer EPOCH_W = 8,
    parameter integer PASS_W = 16,
    parameter integer PIXEL_W = 32,
    parameter integer CACHE_AW = 18,
    parameter integer CACHE_DEPTH = (1 << CACHE_AW)
) (
    input  wire                         clk,
    input  wire                         wr_en,
    input  wire [CACHE_AW-1:0]          wr_addr,
    input  wire [ROWS*8-1:0]            wr_data,
    input  wire [ROWS-1:0]              wr_lane_valid,
    input  wire [EPOCH_W-1:0]           wr_epoch,
    input  wire [PASS_W-1:0]            wr_pass,
    input  wire [PIXEL_W-1:0]           wr_pixel,
    input  wire                         rd_en,
    input  wire [CACHE_AW-1:0]          rd_addr,
    output reg  [ROWS*8-1:0]            rd_data,
    output reg  [ROWS-1:0]              rd_lane_valid,
    output reg  [EPOCH_W-1:0]           rd_epoch,
    output reg  [PASS_W-1:0]            rd_pass,
    output reg  [PIXEL_W-1:0]           rd_pixel
);
    (* ram_style = "block" *) reg [ROWS*8-1:0] data_mem
        [0:CACHE_DEPTH-1];
    (* ram_style = "block" *) reg [ROWS-1:0] lane_valid_mem
        [0:CACHE_DEPTH-1];
    (* ram_style = "block" *) reg [EPOCH_W+PASS_W+PIXEL_W-1:0] tag_mem
        [0:CACHE_DEPTH-1];

    always @(posedge clk) begin
        if (wr_en) begin
            data_mem[wr_addr] <= wr_data;
            lane_valid_mem[wr_addr] <= wr_lane_valid;
            tag_mem[wr_addr] <= {wr_epoch, wr_pass, wr_pixel};
        end

        if (rd_en) begin
            rd_data <= data_mem[rd_addr];
            rd_lane_valid <= lane_valid_mem[rd_addr];
            {rd_epoch, rd_pass, rd_pixel} <= tag_mem[rd_addr];
        end
    end
endmodule

// Wide-vector replay cache for axis_hwc_window_materializer.
//
// The materializer writes one complete ROWS-byte K vector at a time.  Each
// entry is addressed as:
//
//     address = pixel * pass_count + k_pass
//
// A feeder request supplies pass_base_k.  Once the matching pass-ready bit
// for the active epoch is visible, the cache replays the requested contiguous
// pixel range for that pass.  The start address is calculated once per feeder
// request; the read address then advances by pass_count, avoiding a multiplier
// in the replay hot path.
//
// cfg_start changes ownership to a new epoch without clearing the RAM.  Full
// {epoch,k_pass,pixel} tags make stale locations fail closed.  A tag mismatch
// is emitted as an all-zero vector and raises sticky diagnostics; stale data
// is never forwarded to the feeder.
module hwc_materialized_vector_cache #(
    parameter integer ROWS = 18,
    parameter integer EPOCH_W = 8,
    parameter integer PASS_W = 16,
    parameter integer PIXEL_W = 32,
    parameter integer MAX_PASSES = 512,
    parameter integer CACHE_AW = 18,
    parameter integer CACHE_DEPTH = (1 << CACHE_AW)
) (
    input  wire                         clk,
    input  wire                         rst,

    input  wire                         cfg_start,
    input  wire [EPOCH_W-1:0]           cfg_epoch,
    input  wire [PIXEL_W-1:0]           cfg_num_pixels,
    input  wire [15:0]                  cfg_k_total,

    input  wire                         entry_valid,
    output wire                         entry_ready,
    input  wire [ROWS*8-1:0]            entry_data,
    input  wire [ROWS-1:0]              entry_lane_valid,
    input  wire [PIXEL_W-1:0]           entry_pixel,
    input  wire [PASS_W-1:0]            entry_k_pass,
    input  wire [EPOCH_W-1:0]           entry_epoch,
    input  wire                         entry_last,

    input  wire [MAX_PASSES-1:0]        pass_ready_bitmap,
    input  wire [EPOCH_W-1:0]           pass_ready_epoch,

    input  wire                         fill_req,
    input  wire [15:0]                  pass_base_k,
    input  wire [PIXEL_W-1:0]           fill_pixel_base,
    input  wire [PIXEL_W-1:0]           fill_num_pixels,
    output wire [ROWS*8-1:0]            vector_data,
    output wire [ROWS-1:0]              vector_lane_valid,
    output wire                         vector_valid,
    input  wire                         vector_ready,
    output reg                          packet_done,

    output wire                         configured,
    output wire                         replay_active,
    output wire [PASS_W-1:0]            active_replay_pass,
    output reg                          config_error,
    output reg                          underflow_error,
    output reg                          overflow_error,
    output reg                          context_mismatch_error,
    output reg  [31:0]                  accepted_entries,
    output reg  [31:0]                  completed_packets,
    output reg  [31:0]                  completed_pixels,
    output reg  [31:0]                  underflow_count,
    output reg  [31:0]                  overflow_count,
    output reg  [31:0]                  context_mismatch_count,
    output reg  [31:0]                  pass_wait_stall_cycles,
    output reg  [31:0]                  vector_backpressure_stall_cycles,
    output reg  [31:0]                  entry_backpressure_stall_cycles
);
    localparam integer CFG_PASS_MATH_W = 17;

    reg configured_q;
    reg [EPOCH_W-1:0] epoch_q;
    reg [PIXEL_W-1:0] num_pixels_q;
    reg [PASS_W-1:0] pass_count_q;

    reg replay_active_q;
    reg [PASS_W-1:0] replay_pass_q;
    reg [PIXEL_W-1:0] issue_pixel_q;
    reg [PIXEL_W-1:0] replay_end_pixel_q;
    reg [CACHE_AW-1:0] issue_addr_q;
    reg rd_valid_q;
    reg [PIXEL_W-1:0] rd_expected_pixel_q;
    reg [PASS_W-1:0] rd_expected_pass_q;
    reg req_armed_q;
    reg wait_reported_q;

    wire [CFG_PASS_MATH_W-1:0] cfg_pass_count_math =
        (cfg_k_total + ROWS - 1) / ROWS;
    wire [PIXEL_W+CFG_PASS_MATH_W-1:0] cfg_entry_count_math =
        cfg_num_pixels * cfg_pass_count_math;

    wire [PIXEL_W+PASS_W-1:0] entry_addr_math =
        entry_pixel * pass_count_q + entry_k_pass;
    wire entry_epoch_match = (entry_epoch == epoch_q);
    wire entry_pass_valid = (entry_k_pass < pass_count_q) &&
                            (entry_k_pass < MAX_PASSES);
    wire entry_pixel_valid = (entry_pixel < num_pixels_q);
    wire entry_addr_valid =
        (entry_addr_math < CACHE_DEPTH);
    wire entry_context_valid = configured_q && entry_epoch_match &&
                               entry_pass_valid && entry_pixel_valid;
    wire entry_write_valid = entry_context_valid && entry_addr_valid;
    wire entry_fire = entry_valid && entry_ready;

    wire [PASS_W-1:0] request_pass_index = pass_base_k / ROWS;
    wire request_aligned = ((pass_base_k % ROWS) == 0);
    wire request_pass_valid = request_aligned &&
                              (request_pass_index < pass_count_q) &&
                              (request_pass_index < MAX_PASSES);
    wire request_bitmap_ready = request_pass_valid ?
        pass_ready_bitmap[request_pass_index] : 1'b0;
    wire request_epoch_match = (pass_ready_epoch == epoch_q);
    wire request_ready = configured_q && request_pass_valid &&
                         request_epoch_match && request_bitmap_ready;
    wire [PIXEL_W:0] request_end_pixel_math =
        {1'b0, fill_pixel_base} + {1'b0, fill_num_pixels};
    wire request_range_valid = (fill_num_pixels != 0) &&
        (fill_pixel_base < num_pixels_q) &&
        (request_end_pixel_math <= {1'b0, num_pixels_q});
    wire [PIXEL_W+PASS_W-1:0] request_start_addr_math =
        fill_pixel_base * pass_count_q + request_pass_index;
    wire request_start_addr_valid = request_start_addr_math < CACHE_DEPTH;
    wire request_candidate = !replay_active_q && !rd_valid_q &&
                             fill_req && req_armed_q;

    // The synchronous RAM output itself is the replay skid register.  A new
    // read may replace a consumed output in the same cycle, sustaining one
    // complete vector per clock under no backpressure.
    wire rd_issue = replay_active_q &&
                    (issue_pixel_q < replay_end_pixel_q) &&
                    (!rd_valid_q || vector_ready);
    wire [ROWS*8-1:0] ram_rd_data;
    wire [ROWS-1:0] ram_rd_lane_valid;
    wire [EPOCH_W-1:0] ram_rd_epoch;
    wire [PASS_W-1:0] ram_rd_pass;
    wire [PIXEL_W-1:0] ram_rd_pixel;
    wire rd_context_match = (ram_rd_epoch == epoch_q) &&
                            (ram_rd_pass == rd_expected_pass_q) &&
                            (ram_rd_pixel == rd_expected_pixel_q);
    wire vector_fire = vector_valid && vector_ready;
    wire read_write_collision = entry_fire && entry_write_valid &&
        rd_issue &&
        (entry_addr_math[CACHE_AW-1:0] == issue_addr_q);

    assign entry_ready = configured_q && !cfg_start;
    assign configured = configured_q;
    assign replay_active = replay_active_q;
    assign active_replay_pass = replay_pass_q;
    assign vector_valid = rd_valid_q;
    assign vector_data = rd_context_match ? ram_rd_data : {ROWS*8{1'b0}};
    assign vector_lane_valid = rd_context_match ? ram_rd_lane_valid :
                               {ROWS{1'b0}};

    hwc_materialized_vector_cache_ram #(
        .ROWS(ROWS),
        .EPOCH_W(EPOCH_W),
        .PASS_W(PASS_W),
        .PIXEL_W(PIXEL_W),
        .CACHE_AW(CACHE_AW),
        .CACHE_DEPTH(CACHE_DEPTH)
    ) u_cache_ram (
        .clk(clk),
        .wr_en(entry_fire && entry_write_valid),
        .wr_addr(entry_addr_math[CACHE_AW-1:0]),
        .wr_data(entry_data),
        .wr_lane_valid(entry_lane_valid),
        .wr_epoch(entry_epoch),
        .wr_pass(entry_k_pass),
        .wr_pixel(entry_pixel),
        .rd_en(rd_issue),
        .rd_addr(issue_addr_q),
        .rd_data(ram_rd_data),
        .rd_lane_valid(ram_rd_lane_valid),
        .rd_epoch(ram_rd_epoch),
        .rd_pass(ram_rd_pass),
        .rd_pixel(ram_rd_pixel)
    );

    always @(posedge clk) begin
        if (rst) begin
            configured_q <= 1'b0;
            epoch_q <= {EPOCH_W{1'b0}};
            num_pixels_q <= {PIXEL_W{1'b0}};
            pass_count_q <= {PASS_W{1'b0}};
            replay_active_q <= 1'b0;
            replay_pass_q <= {PASS_W{1'b0}};
            issue_pixel_q <= {PIXEL_W{1'b0}};
            replay_end_pixel_q <= {PIXEL_W{1'b0}};
            issue_addr_q <= {CACHE_AW{1'b0}};
            rd_valid_q <= 1'b0;
            rd_expected_pixel_q <= {PIXEL_W{1'b0}};
            rd_expected_pass_q <= {PASS_W{1'b0}};
            req_armed_q <= 1'b1;
            wait_reported_q <= 1'b0;
            packet_done <= 1'b0;
            config_error <= 1'b0;
            underflow_error <= 1'b0;
            overflow_error <= 1'b0;
            context_mismatch_error <= 1'b0;
            accepted_entries <= 32'd0;
            completed_packets <= 32'd0;
            completed_pixels <= 32'd0;
            underflow_count <= 32'd0;
            overflow_count <= 32'd0;
            context_mismatch_count <= 32'd0;
            pass_wait_stall_cycles <= 32'd0;
            vector_backpressure_stall_cycles <= 32'd0;
            entry_backpressure_stall_cycles <= 32'd0;
        end else begin
            packet_done <= 1'b0;

            if (!fill_req) begin
                req_armed_q <= 1'b1;
                wait_reported_q <= 1'b0;
            end

            if (entry_valid && !entry_ready)
                entry_backpressure_stall_cycles <=
                    entry_backpressure_stall_cycles + 1'b1;
            if (vector_valid && !vector_ready)
                vector_backpressure_stall_cycles <=
                    vector_backpressure_stall_cycles + 1'b1;

            if (cfg_start) begin
                if (replay_active_q || rd_valid_q) begin
                    context_mismatch_error <= 1'b1;
                    context_mismatch_count <=
                        context_mismatch_count + 1'b1;
                end else begin
                    epoch_q <= cfg_epoch;
                    num_pixels_q <= cfg_num_pixels;
                    pass_count_q <= cfg_pass_count_math[PASS_W-1:0];
                    replay_active_q <= 1'b0;
                    replay_pass_q <= {PASS_W{1'b0}};
                    issue_pixel_q <= {PIXEL_W{1'b0}};
                    replay_end_pixel_q <= {PIXEL_W{1'b0}};
                    issue_addr_q <= {CACHE_AW{1'b0}};
                    rd_valid_q <= 1'b0;
                    req_armed_q <= !fill_req;
                    wait_reported_q <= 1'b0;
                    config_error <= 1'b0;
                    underflow_error <= 1'b0;
                    overflow_error <= 1'b0;
                    context_mismatch_error <= 1'b0;
                    accepted_entries <= 32'd0;
                    completed_packets <= 32'd0;
                    completed_pixels <= 32'd0;
                    underflow_count <= 32'd0;
                    overflow_count <= 32'd0;
                    context_mismatch_count <= 32'd0;
                    pass_wait_stall_cycles <= 32'd0;
                    vector_backpressure_stall_cycles <= 32'd0;
                    entry_backpressure_stall_cycles <= 32'd0;

                    if ((cfg_num_pixels == 0) || (cfg_k_total == 0) ||
                        (cfg_pass_count_math == 0) ||
                        (cfg_pass_count_math > MAX_PASSES) ||
                        (cfg_entry_count_math > CACHE_DEPTH)) begin
                        configured_q <= 1'b0;
                        config_error <= 1'b1;
                        if (cfg_entry_count_math > CACHE_DEPTH) begin
                            overflow_error <= 1'b1;
                            overflow_count <= 32'd1;
                        end
                    end else begin
                        configured_q <= 1'b1;
                    end
                end
            end else begin
                if (entry_fire) begin
                    accepted_entries <= accepted_entries + 1'b1;

                    if (!entry_epoch_match) begin
                        context_mismatch_error <= 1'b1;
                        context_mismatch_count <=
                            context_mismatch_count + 1'b1;
                    end else if (!entry_pass_valid || !entry_pixel_valid ||
                                 !entry_addr_valid) begin
                        overflow_error <= 1'b1;
                        overflow_count <= overflow_count + 1'b1;
                    end

                    if (entry_last &&
                        ((entry_k_pass + 1'b1 != pass_count_q) ||
                         (entry_pixel + 1'b1 != num_pixels_q))) begin
                        context_mismatch_error <= 1'b1;
                        context_mismatch_count <=
                            context_mismatch_count + 1'b1;
                    end
                end

                if (request_candidate) begin
                    if (!request_pass_valid || !request_range_valid ||
                        !request_start_addr_valid) begin
                        if (!wait_reported_q) begin
                            context_mismatch_error <= 1'b1;
                            context_mismatch_count <=
                                context_mismatch_count + 1'b1;
                            wait_reported_q <= 1'b1;
                        end
                        // Alignment/range cannot become legal without a new
                        // request, so consume this request edge.
                        req_armed_q <= 1'b0;
                    end else if (!request_epoch_match) begin
                        pass_wait_stall_cycles <=
                            pass_wait_stall_cycles + 1'b1;
                        if (!wait_reported_q) begin
                            context_mismatch_error <= 1'b1;
                            context_mismatch_count <=
                                context_mismatch_count + 1'b1;
                            wait_reported_q <= 1'b1;
                        end
                    end else if (!request_bitmap_ready) begin
                        pass_wait_stall_cycles <=
                            pass_wait_stall_cycles + 1'b1;
                        if (!wait_reported_q) begin
                            underflow_error <= 1'b1;
                            underflow_count <= underflow_count + 1'b1;
                            wait_reported_q <= 1'b1;
                        end
                    end else begin
                        replay_active_q <= 1'b1;
                        replay_pass_q <= request_pass_index;
                        issue_pixel_q <= fill_pixel_base;
                        replay_end_pixel_q <=
                            request_end_pixel_math[PIXEL_W-1:0];
                        issue_addr_q <=
                            request_start_addr_math[CACHE_AW-1:0];
                        req_armed_q <= 1'b0;
                        wait_reported_q <= 1'b0;
                    end
                end

                if (rd_issue) begin
                    rd_valid_q <= 1'b1;
                    rd_expected_pixel_q <= issue_pixel_q;
                    rd_expected_pass_q <= replay_pass_q;
                    issue_pixel_q <= issue_pixel_q + 1'b1;
                    issue_addr_q <= issue_addr_q + pass_count_q;
                end else if (vector_fire) begin
                    rd_valid_q <= 1'b0;
                end

                if (vector_fire) begin
                    completed_pixels <= completed_pixels + 1'b1;
                    if (!rd_context_match) begin
                        context_mismatch_error <= 1'b1;
                        context_mismatch_count <=
                            context_mismatch_count + 1'b1;
                    end

                    if (rd_expected_pixel_q + 1'b1 ==
                        replay_end_pixel_q) begin
                        replay_active_q <= 1'b0;
                        packet_done <= 1'b1;
                        completed_packets <= completed_packets + 1'b1;
                    end
                end

                if (read_write_collision) begin
                    context_mismatch_error <= 1'b1;
                    context_mismatch_count <=
                        context_mismatch_count + 1'b1;
                end
            end
        end
    end
endmodule

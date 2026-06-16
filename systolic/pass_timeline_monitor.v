`timescale 1ns / 1ps
// Diagnostic-only pass timeline monitor.
//
// This module observes pass-level events and aggregates timing gaps. It must
// never feed back into scheduler or datapath control.
module pass_timeline_monitor #(
    parameter K_TILE = 18,
    parameter COUT_TILE = 16
) (
    input         clk,
    input         rst,
    input         layer_start,
    input         layer_busy,

    input         trace_enable,
    input  [7:0]  trace_cout_block,
    input  [15:0] trace_k_pass,
    input  [10:0] cout_base,
    input  [13:0] pass_base_k,

    input         weight_done,
    input         feed_start,
    input         feed_ready,
    input         feed_done,
    input         compute_start,
    input         compute_fire,
    input         compute_done,
    input         collector_packet_fire,
    input         collector_context_done,
    input         collector_column_empty_wait,
    input         raw_replay_active,
    input         stage_compute,

    output reg [31:0] pass_count,
    output reg [31:0] start_to_first_fire,
    output reg [31:0] first_to_last_fire,
    output reg [31:0] last_fire_to_done,
    output reg [31:0] collect_first_wait,
    output reg [31:0] collect_column_empty,
    output reg [31:0] replay_active_during_compute,
    output reg [31:0] compute_idle_in_stage,

    output reg [31:0] trace_weight_done,
    output reg [31:0] trace_feed_start,
    output reg [31:0] trace_feed_ready,
    output reg [31:0] trace_feed_done,
    output reg [31:0] trace_compute_start,
    output reg [31:0] trace_first_fire,
    output reg [31:0] trace_last_fire,
    output reg [31:0] trace_compute_done,
    output reg [31:0] trace_collect_first,
    output reg [31:0] trace_collect_last,
    output reg [31:0] trace_pass_done,
    output            trace_pass_start,
    output reg        trace_valid
);
    localparam [15:0] K_TILE_U = K_TILE;
    localparam [15:0] COUT_TILE_U = COUT_TILE;

    reg [31:0] cycle_count;
    reg [31:0] current_compute_start_cycle;
    reg [31:0] first_fire_cycle;
    reg [31:0] last_fire_cycle;
    reg [31:0] first_collect_cycle;
    reg in_pass;
    reg saw_first_fire;
    reg saw_collect_first;
    reg trace_active;
    reg trace_compute_active;
    reg [10:0] active_cout_base;
    reg [13:0] active_pass_base_k;

    wire [15:0] trace_pass_base_k =
        trace_k_pass * K_TILE_U;
    wire [15:0] trace_cout_base =
        {8'd0, trace_cout_block} * COUT_TILE_U;
    wire trace_match =
        trace_enable &&
        {5'd0, cout_base} == trace_cout_base &&
        {2'd0, pass_base_k} == trace_pass_base_k;
    wire active_trace_match =
        trace_enable &&
        {5'd0, active_cout_base} == trace_cout_base &&
        {2'd0, active_pass_base_k} == trace_pass_base_k;
    assign trace_pass_start = layer_busy && compute_start && trace_match;

    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 32'd0;
            current_compute_start_cycle <= 32'd0;
            first_fire_cycle <= 32'd0;
            last_fire_cycle <= 32'd0;
            first_collect_cycle <= 32'd0;
            in_pass <= 1'b0;
            saw_first_fire <= 1'b0;
            saw_collect_first <= 1'b0;
            trace_active <= 1'b0;
            trace_compute_active <= 1'b0;
            active_cout_base <= 11'd0;
            active_pass_base_k <= 14'd0;
            pass_count <= 32'd0;
            start_to_first_fire <= 32'd0;
            first_to_last_fire <= 32'd0;
            last_fire_to_done <= 32'd0;
            collect_first_wait <= 32'd0;
            collect_column_empty <= 32'd0;
            replay_active_during_compute <= 32'd0;
            compute_idle_in_stage <= 32'd0;
            trace_weight_done <= 32'd0;
            trace_feed_start <= 32'd0;
            trace_feed_ready <= 32'd0;
            trace_feed_done <= 32'd0;
            trace_compute_start <= 32'd0;
            trace_first_fire <= 32'd0;
            trace_last_fire <= 32'd0;
            trace_compute_done <= 32'd0;
            trace_collect_first <= 32'd0;
            trace_collect_last <= 32'd0;
            trace_pass_done <= 32'd0;
            trace_valid <= 1'b0;
        end else begin
            if (layer_start) begin
                cycle_count <= 32'd0;
                pass_count <= 32'd0;
                start_to_first_fire <= 32'd0;
                first_to_last_fire <= 32'd0;
                last_fire_to_done <= 32'd0;
                collect_first_wait <= 32'd0;
                collect_column_empty <= 32'd0;
                replay_active_during_compute <= 32'd0;
                compute_idle_in_stage <= 32'd0;
                in_pass <= 1'b0;
                saw_first_fire <= 1'b0;
                saw_collect_first <= 1'b0;
                trace_active <= 1'b0;
                trace_compute_active <= 1'b0;
                trace_weight_done <= 32'd0;
                trace_feed_start <= 32'd0;
                trace_feed_ready <= 32'd0;
                trace_feed_done <= 32'd0;
                trace_compute_start <= 32'd0;
                trace_first_fire <= 32'd0;
                trace_last_fire <= 32'd0;
                trace_compute_done <= 32'd0;
                trace_collect_first <= 32'd0;
                trace_collect_last <= 32'd0;
                trace_pass_done <= 32'd0;
                trace_valid <= 1'b0;
            end else if (layer_busy) begin
                cycle_count <= cycle_count + 1'b1;
            end

            if (layer_busy && stage_compute && !compute_fire)
                compute_idle_in_stage <= compute_idle_in_stage + 1'b1;

            if (layer_busy && in_pass && raw_replay_active)
                replay_active_during_compute <= replay_active_during_compute + 1'b1;

            if (layer_busy && collector_column_empty_wait)
                collect_column_empty <= collect_column_empty + 1'b1;

            if (layer_busy && weight_done && trace_match)
                trace_weight_done <= cycle_count;
            if (layer_busy && feed_start && trace_match)
                trace_feed_start <= cycle_count;
            if (layer_busy && feed_ready && trace_match &&
                trace_feed_ready == 32'd0)
                trace_feed_ready <= cycle_count;
            if (layer_busy && feed_done && trace_match)
                trace_feed_done <= cycle_count;

            if (layer_busy && compute_start) begin
                in_pass <= 1'b1;
                saw_first_fire <= 1'b0;
                saw_collect_first <= 1'b0;
                current_compute_start_cycle <= cycle_count;
                active_cout_base <= cout_base;
                active_pass_base_k <= pass_base_k;
                pass_count <= pass_count + 1'b1;
                if (trace_match && !trace_valid) begin
                    trace_active <= 1'b1;
                    trace_compute_active <= 1'b1;
                    trace_compute_start <= cycle_count;
                end
            end

            if (layer_busy && in_pass && compute_fire) begin
                last_fire_cycle <= cycle_count;
                if (!saw_first_fire) begin
                    saw_first_fire <= 1'b1;
                    first_fire_cycle <= cycle_count;
                    start_to_first_fire <= start_to_first_fire +
                        (cycle_count - current_compute_start_cycle);
                    if (trace_compute_active || active_trace_match)
                        trace_first_fire <= cycle_count;
                end
                if (trace_compute_active || active_trace_match)
                    trace_last_fire <= cycle_count;
            end

            if (layer_busy && in_pass && collector_packet_fire) begin
                if (!saw_collect_first) begin
                    saw_collect_first <= 1'b1;
                    first_collect_cycle <= cycle_count;
                    collect_first_wait <= collect_first_wait +
                        (cycle_count - current_compute_start_cycle);
                    if (trace_active || active_trace_match)
                        trace_collect_first <= cycle_count;
                end
                if (trace_active || active_trace_match)
                    trace_collect_last <= cycle_count;
            end

            if (layer_busy && in_pass && compute_done) begin
                if (saw_first_fire) begin
                    first_to_last_fire <= first_to_last_fire +
                        (last_fire_cycle - first_fire_cycle);
                    last_fire_to_done <= last_fire_to_done +
                        (cycle_count - last_fire_cycle);
                end
                if (trace_compute_active || active_trace_match)
                    trace_compute_done <= cycle_count;
                if (trace_compute_active)
                    trace_compute_active <= 1'b0;
            end

            if (layer_busy && in_pass && collector_context_done) begin
                in_pass <= 1'b0;
                if (trace_active || active_trace_match) begin
                    trace_pass_done <= cycle_count;
                    trace_valid <= 1'b1;
                    trace_active <= 1'b0;
                end
            end
        end
    end
endmodule

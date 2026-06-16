`timescale 1ns / 1ps
// First-pass layer scheduler for full-spatial-block execution.
//
// Traversal order:
//   for cout_base in COUT_TILE:
//     load bias block once
//     for k_base in K_TILE:
//       load weight tile
//       run window feeder
//       run systolic compute
//       drain PSUMs (partial writeback or final output)
module layer_scheduler_stream #(
    parameter K_TILE = 32,
    parameter COUT_TILE = 64
) (
    input  clk,
    input  rst,
    input  start,
    output reg busy,
    output reg done,

    input  [13:0] k_total,
    input  [10:0] cout_total,
    input  [15:0] num_pixels,

    output reg [13:0] pass_base_k,
    output reg [10:0] cout_base,
    output reg [10:0] cout_valid,
    output reg [15:0] num_pixels_out,
    output reg        is_first_pass,
    output reg        is_final_pass,
    output reg        use_ext_psum,
    output reg        use_psum_stream,
    output reg        psum_wr_bank,
    output reg        psum_rd_bank,

    output reg bias_load_start,
    input      bias_load_done,
    output reg weight_load_start,
    input      weight_load_done,
    output reg feeder_start,
    input      feeder_done,
    input      feeder_compute_ready,
    input      feeder_overlap_mode,
    input      raw_hwc_mode,
    input      early_drain_enable,
    input      pass_prefetch_enable,
    input      during_compute_prefetch_enable,
    input      psum_stream_overlap_enable,
    input      continuous_psum_enable,
    input      collector_ctx_ready,
    input      collector_partial_credit,
    input      collector_context_active,
    input      collector_context_wr_bank,
    input      collector_context_is_final,
    input      collector_final_done,
    input      psum_drain_data_ready,
    input      psum_drain_packet_fire,
    input      compute_fire,
    output reg compute_start,
    input      compute_done,
    output reg psum_drain_start,
    input      psum_drain_done,
    output reg [13:0] feeder_pass_base_k,
    output reg perf_prefetch_start,
    output reg perf_prefetch_weight_done,
    output reg perf_prefetch_feed_done,
    output reg perf_prefetch_hit,
    output reg perf_prefetch_miss,
    output     perf_prefetch_stall,
    output reg perf_psumovl_start,
    output reg perf_psumovl_hit,
    output     perf_psumovl_wait_psum,

    output     perf_stage_bias,
    output     perf_stage_weight,
    output     perf_stage_feeder,
    output     perf_stage_compute,
    output     perf_stage_drain
);
    localparam ST_IDLE        = 4'd0;
    localparam ST_BIAS_START  = 4'd1;
    localparam ST_BIAS_WAIT   = 4'd2;
    localparam ST_WGT_START   = 4'd3;
    localparam ST_WGT_WAIT    = 4'd4;
    localparam ST_FEED_START  = 4'd5;
    localparam ST_FEED_WAIT   = 4'd6;
    localparam ST_COMP_START  = 4'd7;
    localparam ST_COMP_WAIT   = 4'd8;
    localparam ST_DRAIN_START = 4'd9;
    localparam ST_DRAIN_WAIT  = 4'd10;
    localparam ST_DONE        = 4'd11;
    localparam ST_PREFETCH_WAIT = 4'd12;
    localparam ST_PREFETCH_COMMIT = 4'd13;

    reg [3:0] state;
    reg compute_done_seen;
    reg compute_started_seen;
    reg feeder_done_seen;
    reg drain_started;
    reg drain_done_seen;
    reg prefetch_started;
    reg prefetch_weight_done;
    reg prefetch_feed_done;
    reg [13:0] prefetch_pass_base_k;
    reg pass_bank;
    reg prev_drain_pending;
    reg [15:0] drain_packet_count;
    reg collector_final_done_seen;

    localparam [14:0] K_STEP_EXT = K_TILE;
    localparam [10:0] COUT_STEP = COUT_TILE;
    // The partial-PSUM reader has an exact per-pixel available-count guard.
    // One committed packet is therefore sufficient to start the next pass;
    // any later read that catches the writer is stalled by psum_stream_feeder.
    localparam [15:0] PSUM_OVERLAP_LEAD = 16'd1;
    wire [14:0] next_k = {1'b0, pass_base_k} + K_STEP_EXT;
    wire last_k = (next_k >= {1'b0, k_total});
    wire last_cout = (cout_base + COUT_STEP >= cout_total);
    wire [10:0] cout_remaining = cout_total - cout_base;
    wire prefetch_enable_current =
        pass_prefetch_enable && raw_hwc_mode && !last_k;
    wire prefetch_weight_done_now =
        prefetch_weight_done ||
        (prefetch_started && weight_load_done);
    wire prefetch_feed_done_now =
        prefetch_feed_done ||
        (prefetch_started && feeder_done);
    wire prefetch_ready_now =
        prefetch_started && prefetch_weight_done_now && prefetch_feed_done_now;
    wire prefetch_start_serial_ready =
        (compute_done_seen || compute_done) &&
        (!feeder_overlap_mode || feeder_done_seen || feeder_done);
    wire prefetch_start_during_compute_ready =
        during_compute_prefetch_enable &&
        compute_started_seen &&
        (!feeder_overlap_mode || feeder_done_seen || feeder_done);
    wire prefetch_start_now =
        busy && prefetch_enable_current && !prefetch_started &&
        (prefetch_start_serial_ready || prefetch_start_during_compute_ready);
    wire psum_overlap_enable_current =
        psum_stream_overlap_enable && prefetch_enable_current && prefetch_started;
    wire psum_overlap_ready_now =
        psum_overlap_enable_current && prefetch_ready_now && drain_started &&
        !prev_drain_pending && (drain_packet_count >= PSUM_OVERLAP_LEAD);
    wire next_wr_bank = ~pass_bank;
    wire collector_next_bank_safe =
        !continuous_psum_enable ||
        !collector_context_active ||
        collector_context_is_final ||
        (collector_context_wr_bank != next_wr_bank);

    assign perf_stage_bias =
        busy && (state == ST_BIAS_START || state == ST_BIAS_WAIT);
    assign perf_stage_weight =
        busy && (state == ST_WGT_START || state == ST_WGT_WAIT);
    assign perf_stage_feeder =
        busy && (state == ST_FEED_START || state == ST_FEED_WAIT);
    wire continuous_final_collect_wait =
        continuous_psum_enable && (state == ST_COMP_WAIT) && last_k &&
        (compute_done_seen || compute_done) &&
        !(collector_final_done_seen || collector_final_done);
    assign perf_stage_compute =
        busy && (state == ST_COMP_START ||
                 (state == ST_COMP_WAIT && !continuous_final_collect_wait));
    assign perf_stage_drain =
        busy && (state == ST_DRAIN_START || state == ST_DRAIN_WAIT ||
                 continuous_final_collect_wait);
    assign perf_prefetch_stall = busy && (state == ST_PREFETCH_WAIT);
    assign perf_psumovl_wait_psum =
        busy && psum_overlap_enable_current && prefetch_ready_now && drain_started &&
        !prev_drain_pending && (drain_packet_count < PSUM_OVERLAP_LEAD);

    always @(*) begin
        cout_valid = (cout_remaining < COUT_STEP) ? cout_remaining : COUT_STEP;
        is_first_pass = (pass_base_k == 14'd0);
        is_final_pass = last_k;
        use_ext_psum = (pass_base_k != 14'd0);
        use_psum_stream = (pass_base_k != 14'd0);
        psum_wr_bank = pass_bank;
        psum_rd_bank = ~pass_bank;
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            pass_base_k <= 14'd0;
            cout_base <= 11'd0;
            num_pixels_out <= 16'd0;
            bias_load_start <= 1'b0;
            weight_load_start <= 1'b0;
            feeder_start <= 1'b0;
            compute_start <= 1'b0;
            psum_drain_start <= 1'b0;
            feeder_pass_base_k <= 14'd0;
            compute_done_seen <= 1'b0;
            compute_started_seen <= 1'b0;
            feeder_done_seen <= 1'b0;
            drain_started <= 1'b0;
            drain_done_seen <= 1'b0;
            prefetch_started <= 1'b0;
            prefetch_weight_done <= 1'b0;
            prefetch_feed_done <= 1'b0;
            prefetch_pass_base_k <= 14'd0;
            pass_bank <= 1'b0;
            prev_drain_pending <= 1'b0;
            drain_packet_count <= 16'd0;
            collector_final_done_seen <= 1'b0;
            perf_prefetch_start <= 1'b0;
            perf_prefetch_weight_done <= 1'b0;
            perf_prefetch_feed_done <= 1'b0;
            perf_prefetch_hit <= 1'b0;
            perf_prefetch_miss <= 1'b0;
            perf_psumovl_start <= 1'b0;
            perf_psumovl_hit <= 1'b0;
        end else begin
            done <= 1'b0;
            bias_load_start <= 1'b0;
            weight_load_start <= 1'b0;
            feeder_start <= 1'b0;
            compute_start <= 1'b0;
            psum_drain_start <= 1'b0;
            perf_prefetch_start <= 1'b0;
            perf_prefetch_weight_done <= 1'b0;
            perf_prefetch_feed_done <= 1'b0;
            perf_prefetch_hit <= 1'b0;
            perf_prefetch_miss <= 1'b0;
            perf_psumovl_start <= 1'b0;
            perf_psumovl_hit <= 1'b0;

            if (drain_started && psum_drain_packet_fire &&
                drain_packet_count != 16'hffff)
                drain_packet_count <= drain_packet_count + 1'b1;

            if (prev_drain_pending && psum_drain_done)
                prev_drain_pending <= 1'b0;
            if (continuous_psum_enable && collector_final_done)
                collector_final_done_seen <= 1'b1;

            if (prefetch_started && weight_load_done &&
                !prefetch_weight_done) begin
                prefetch_weight_done <= 1'b1;
                perf_prefetch_weight_done <= 1'b1;
            end
            if (prefetch_started && feeder_done &&
                !prefetch_feed_done) begin
                prefetch_feed_done <= 1'b1;
                perf_prefetch_feed_done <= 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        pass_base_k <= 14'd0;
                        cout_base <= 11'd0;
                        num_pixels_out <= num_pixels;
                        compute_done_seen <= 1'b0;
                        compute_started_seen <= 1'b0;
                        feeder_done_seen <= 1'b0;
                        drain_started <= 1'b0;
                        drain_done_seen <= 1'b0;
                        prefetch_started <= 1'b0;
                        prefetch_weight_done <= 1'b0;
                        prefetch_feed_done <= 1'b0;
                        feeder_pass_base_k <= 14'd0;
                        pass_bank <= 1'b0;
                        prev_drain_pending <= 1'b0;
                        drain_packet_count <= 16'd0;
                        collector_final_done_seen <= 1'b0;
                        state <= ST_BIAS_START;
                    end
                end

                ST_BIAS_START: begin
                    bias_load_start <= 1'b1;
                    state <= ST_BIAS_WAIT;
                end

                ST_BIAS_WAIT: begin
                    if (bias_load_done)
                        state <= ST_WGT_START;
                end

                ST_WGT_START: begin
                    weight_load_start <= 1'b1;
                    state <= ST_WGT_WAIT;
                end

                ST_WGT_WAIT: begin
                    if (weight_load_done)
                        state <= ST_FEED_START;
                end

                ST_FEED_START: begin
                    feeder_start <= 1'b1;
                    feeder_pass_base_k <= pass_base_k;
                    feeder_done_seen <= 1'b0;
                    state <= ST_FEED_WAIT;
                end

                ST_FEED_WAIT: begin
                    if (feeder_done)
                        feeder_done_seen <= 1'b1;
                    if (feeder_done || (feeder_overlap_mode && feeder_compute_ready))
                        state <= ST_COMP_START;
                end

                ST_COMP_START: begin
                    if (!continuous_psum_enable || collector_ctx_ready) begin
                        compute_start <= 1'b1;
                        compute_done_seen <= 1'b0;
                        compute_started_seen <= 1'b0;
                        drain_started <= 1'b0;
                        drain_done_seen <= 1'b0;
                        drain_packet_count <= 16'd0;
                        collector_final_done_seen <= 1'b0;
                        prefetch_started <= 1'b0;
                        prefetch_weight_done <= 1'b0;
                        prefetch_feed_done <= 1'b0;
                        state <= ST_COMP_WAIT;
                    end
                end

                ST_COMP_WAIT: begin
                    if (compute_done)
                        compute_done_seen <= 1'b1;
                    if (compute_fire)
                        compute_started_seen <= 1'b1;
                    if (feeder_done)
                        feeder_done_seen <= 1'b1;
                    if (psum_drain_done && !prev_drain_pending)
                        drain_done_seen <= 1'b1;

                    if (prefetch_start_now) begin
                        prefetch_started <= 1'b1;
                        prefetch_weight_done <= 1'b0;
                        prefetch_feed_done <= 1'b0;
                        prefetch_pass_base_k <= next_k[13:0];
                        feeder_pass_base_k <= next_k[13:0];
                        weight_load_start <= 1'b1;
                        feeder_start <= 1'b1;
                        perf_prefetch_start <= 1'b1;
                    end

                    if (early_drain_enable && !drain_started && !prev_drain_pending &&
                        !continuous_psum_enable &&
                        compute_fire && psum_drain_data_ready) begin
                        psum_drain_start <= 1'b1;
                        drain_started <= 1'b1;
                        drain_packet_count <= 16'd0;
                    end

                    if (continuous_psum_enable) begin
                        if (!prefetch_start_now &&
                            (compute_done || compute_done_seen) &&
                            (!feeder_overlap_mode || feeder_done || feeder_done_seen)) begin
                            if (!last_k) begin
                                if (prefetch_ready_now && collector_partial_credit &&
                                    collector_next_bank_safe) begin
                                    pass_base_k <= next_k[13:0];
                                    pass_bank <= ~pass_bank;
                                    perf_prefetch_hit <= 1'b1;
                                    perf_psumovl_start <= 1'b1;
                                    perf_psumovl_hit <= 1'b1;
                                    state <= ST_PREFETCH_COMMIT;
                                end else if (!prefetch_started &&
                                             collector_next_bank_safe) begin
                                    pass_base_k <= next_k[13:0];
                                    pass_bank <= ~pass_bank;
                                    state <= ST_WGT_START;
                                end
                            end else if (collector_final_done ||
                                         collector_final_done_seen) begin
                                if (!last_cout) begin
                                    cout_base <= cout_base + COUT_STEP;
                                    pass_base_k <= 14'd0;
                                    pass_bank <= 1'b0;
                                    state <= ST_BIAS_START;
                                end else begin
                                    state <= ST_DONE;
                                end
                            end
                        end
                    end else if (!prefetch_start_now &&
                        !prev_drain_pending &&
                        (compute_done || compute_done_seen) &&
                        (!feeder_overlap_mode || feeder_done || feeder_done_seen)) begin
                        if (drain_started) begin
                            if (psum_drain_done || drain_done_seen) begin
                                if (!last_k) begin
                                    if (prefetch_ready_now) begin
                                        pass_base_k <= next_k[13:0];
                                        pass_bank <= ~pass_bank;
                                        perf_prefetch_hit <= 1'b1;
                                        state <= ST_PREFETCH_COMMIT;
                                    end else if (prefetch_started) begin
                                        perf_prefetch_miss <= 1'b1;
                                        state <= ST_PREFETCH_WAIT;
                                    end else begin
                                        pass_base_k <= next_k[13:0];
                                        pass_bank <= ~pass_bank;
                                        state <= ST_WGT_START;
                                    end
                                end else if (!last_cout) begin
                                    cout_base <= cout_base + COUT_STEP;
                                    pass_base_k <= 14'd0;
                                    pass_bank <= 1'b0;
                                    state <= ST_BIAS_START;
                                end else begin
                                    state <= ST_DONE;
                                end
                            end else begin
                                state <= ST_DRAIN_WAIT;
                            end
                        end else begin
                            state <= ST_DRAIN_START;
                        end
                    end else if (!prefetch_start_now && psum_overlap_ready_now &&
                                 (compute_done || compute_done_seen) &&
                                 (!feeder_overlap_mode || feeder_done || feeder_done_seen)) begin
                        pass_base_k <= next_k[13:0];
                        pass_bank <= ~pass_bank;
                        prev_drain_pending <= !psum_drain_done;
                        drain_started <= 1'b0;
                        drain_done_seen <= 1'b0;
                        perf_prefetch_hit <= 1'b1;
                        perf_psumovl_start <= 1'b1;
                        perf_psumovl_hit <= 1'b1;
                        state <= ST_PREFETCH_COMMIT;
                    end
                end

                ST_DRAIN_START: begin
                    psum_drain_start <= 1'b1;
                    drain_started <= 1'b1;
                    drain_packet_count <= 16'd0;
                    state <= ST_DRAIN_WAIT;
                end

                ST_DRAIN_WAIT: begin
                    if (compute_fire)
                        compute_started_seen <= 1'b1;
                    if (prefetch_start_now) begin
                        prefetch_started <= 1'b1;
                        prefetch_weight_done <= 1'b0;
                        prefetch_feed_done <= 1'b0;
                        prefetch_pass_base_k <= next_k[13:0];
                        feeder_pass_base_k <= next_k[13:0];
                        weight_load_start <= 1'b1;
                        feeder_start <= 1'b1;
                        perf_prefetch_start <= 1'b1;
                    end
                    if (!prefetch_start_now && psum_overlap_ready_now) begin
                        pass_base_k <= next_k[13:0];
                        pass_bank <= ~pass_bank;
                        prev_drain_pending <= !psum_drain_done;
                        drain_started <= 1'b0;
                        drain_done_seen <= 1'b0;
                        perf_prefetch_hit <= 1'b1;
                        perf_psumovl_start <= 1'b1;
                        perf_psumovl_hit <= 1'b1;
                        state <= ST_PREFETCH_COMMIT;
                    end else if (!prefetch_start_now && psum_drain_done) begin
                        drain_done_seen <= 1'b1;
                        if (!last_k) begin
                            if (prefetch_ready_now) begin
                                pass_base_k <= next_k[13:0];
                                pass_bank <= ~pass_bank;
                                perf_prefetch_hit <= 1'b1;
                                state <= ST_PREFETCH_COMMIT;
                            end else if (prefetch_started) begin
                                perf_prefetch_miss <= 1'b1;
                                state <= ST_PREFETCH_WAIT;
                            end else begin
                                pass_base_k <= next_k[13:0];
                                pass_bank <= ~pass_bank;
                                state <= ST_WGT_START;
                            end
                        end else if (!last_cout) begin
                            cout_base <= cout_base + COUT_STEP;
                            pass_base_k <= 14'd0;
                            pass_bank <= 1'b0;
                            state <= ST_BIAS_START;
                        end else begin
                            state <= ST_DONE;
                        end
                    end
                end

                ST_PREFETCH_WAIT: begin
                    if (prefetch_ready_now) begin
                        pass_base_k <= prefetch_pass_base_k;
                        pass_bank <= ~pass_bank;
                        perf_prefetch_hit <= 1'b1;
                        state <= ST_PREFETCH_COMMIT;
                    end
                end

                ST_PREFETCH_COMMIT: begin
                    state <= ST_COMP_START;
                end

                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

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

    input  [10:0] k_total,
    input  [10:0] cout_total,
    input  [15:0] num_pixels,

    output reg [10:0] pass_base_k,
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
    output reg compute_start,
    input      compute_done,
    output reg psum_drain_start,
    input      psum_drain_done
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

    reg [3:0] state;

    localparam [10:0] K_STEP = K_TILE;
    localparam [10:0] COUT_STEP = COUT_TILE;
    wire last_k = (pass_base_k + K_STEP >= k_total);
    wire last_cout = (cout_base + COUT_STEP >= cout_total);
    wire [10:0] cout_remaining = cout_total - cout_base;

    always @(*) begin
        cout_valid = (cout_remaining < COUT_STEP) ? cout_remaining : COUT_STEP;
        is_first_pass = (pass_base_k == 11'd0);
        is_final_pass = last_k;
        use_ext_psum = (pass_base_k != 11'd0);
        use_psum_stream = (pass_base_k != 11'd0);
        psum_rd_bank = 1'b0;
        psum_wr_bank = 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            pass_base_k <= 11'd0;
            cout_base <= 11'd0;
            num_pixels_out <= 16'd0;
            bias_load_start <= 1'b0;
            weight_load_start <= 1'b0;
            feeder_start <= 1'b0;
            compute_start <= 1'b0;
            psum_drain_start <= 1'b0;
        end else begin
            done <= 1'b0;
            bias_load_start <= 1'b0;
            weight_load_start <= 1'b0;
            feeder_start <= 1'b0;
            compute_start <= 1'b0;
            psum_drain_start <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        pass_base_k <= 11'd0;
                        cout_base <= 11'd0;
                        num_pixels_out <= num_pixels;
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
                    state <= ST_FEED_WAIT;
                end

                ST_FEED_WAIT: begin
                    if (feeder_done)
                        state <= ST_COMP_START;
                end

                ST_COMP_START: begin
                    compute_start <= 1'b1;
                    state <= ST_COMP_WAIT;
                end

                ST_COMP_WAIT: begin
                    if (compute_done)
                        state <= ST_DRAIN_START;
                end

                ST_DRAIN_START: begin
                    psum_drain_start <= 1'b1;
                    state <= ST_DRAIN_WAIT;
                end

                ST_DRAIN_WAIT: begin
                    if (psum_drain_done) begin
                        if (!last_k) begin
                            pass_base_k <= pass_base_k + K_STEP;
                            state <= ST_WGT_START;
                        end else if (!last_cout) begin
                            cout_base <= cout_base + COUT_STEP;
                            pass_base_k <= 11'd0;
                            state <= ST_BIAS_START;
                        end else begin
                            state <= ST_DONE;
                        end
                    end
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

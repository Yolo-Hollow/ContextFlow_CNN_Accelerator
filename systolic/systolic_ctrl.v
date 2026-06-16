`timescale 1ns / 1ps
// Minimal FSM: IDLE → WEIGHT_LOAD → COMPUTE
`ifndef SYSTOLIC_TAIL_CYCLES_CONFIG
`define SYSTOLIC_TAIL_CYCLES_CONFIG 0
`endif

module systolic_ctrl #(
    parameter ROWS = 32,
    parameter COLS = 32,
    parameter TAIL_CYCLES_CONFIG = `SYSTOLIC_TAIL_CYCLES_CONFIG
) (
    input  clk, rst,
    input  start,
    input  [15:0] num_pixels,
    input  [15:0] tail_cycles_config,
    input  compute_ready,
    input  hold_compute_count_on_stall,
    output reg done,
    output reg w_load,
    output reg [4:0] w_col,
    output reg compute_active,
    output compute_fire,
    output reg compute_start_pulse,   // 1-cycle pulse when COMPUTE begins
    output reg pre_write,             // 1 cycle before compute_active (FIFO pre-fill)
    output perf_comp_wload,
    output perf_comp_active,
    output perf_comp_ifm_stall,
    output perf_comp_tail,
    output [31:0] tail_cycles_configured
);
    localparam IDLE        = 2'd0;
    localparam WEIGHT_LOAD = 2'd1;
    localparam COMPUTE     = 2'd2;
    localparam DRAIN       = 2'd3;
    localparam DEFAULT_TAIL_CYCLES = ROWS*5 + COLS*4 + 16;
    localparam DEFAULT_TAIL_CYCLES_SELECTED =
        (TAIL_CYCLES_CONFIG == 0) ? DEFAULT_TAIL_CYCLES : TAIL_CYCLES_CONFIG;
    wire [15:0] tail_cycles_selected =
        (tail_cycles_config != 16'd0) ? tail_cycles_config :
                                        DEFAULT_TAIL_CYCLES_SELECTED[15:0];

    reg [1:0] state, next_state;
    reg [15:0] compute_cnt;
    reg [15:0] drain_cnt;
    wire [15:0] pixels_to_run = (num_pixels == 16'd0) ? 16'd1 : num_pixels;
    assign compute_fire = (state == COMPUTE) && compute_ready;
    assign perf_comp_wload = (state == WEIGHT_LOAD);
    assign perf_comp_active = (state == COMPUTE);
    assign perf_comp_ifm_stall = (state == COMPUTE) && !compute_ready;
    assign perf_comp_tail = (state == DRAIN);
    assign tail_cycles_configured = {16'd0, tail_cycles_selected};

    always @(posedge clk) begin
        if (rst) state <= IDLE;
        else     state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            IDLE:         if (start)            next_state = WEIGHT_LOAD;
            WEIGHT_LOAD:  if (w_col == COLS-1)  next_state = COMPUTE;
            COMPUTE:      if (compute_fire && compute_cnt == pixels_to_run - 1'b1) next_state = DRAIN;
            DRAIN:        if (drain_cnt == tail_cycles_selected - 1'b1) next_state = IDLE;
            default:                            next_state = IDLE;
        endcase
    end

    // w_col
    always @(posedge clk) begin
        if (rst)                       w_col <= 5'd0;
        else if (state == WEIGHT_LOAD) w_col <= w_col + 5'd1;
        else                           w_col <= 5'd0;
    end
    always @(posedge clk) begin
        if (rst) compute_cnt <= 16'd0;
        else if (state != COMPUTE) compute_cnt <= 16'd0;
        else if (compute_fire) compute_cnt <= compute_cnt + 16'd1;
        else if (!hold_compute_count_on_stall) compute_cnt <= 16'd0;
    end
    always @(posedge clk) begin
        if (rst) drain_cnt <= 16'd0;
        else if (state == DRAIN) drain_cnt <= drain_cnt + 16'd1;
        else drain_cnt <= 16'd0;
    end
    always @(posedge clk) begin
        if (rst) w_load <= 1'b0;
        else     w_load <= (state == WEIGHT_LOAD);
    end

    // compute_active + start pulse
    reg was_compute;
    always @(posedge clk) begin
        if (rst) begin
            compute_active <= 1'b0;
            was_compute    <= 1'b0;
        end else begin
            compute_active <= (state == COMPUTE);
            was_compute    <= (state == COMPUTE);
        end
    end
    always @(posedge clk) begin
        if (rst) done <= 1'b0;
        else     done <= (state == DRAIN) && (drain_cnt == tail_cycles_selected - 1'b1);
    end
    always @(posedge clk) begin
        if (rst) compute_start_pulse <= 1'b0;
        else     compute_start_pulse <= (state == COMPUTE) && !was_compute;
    end
    // Pre-write: 1 cycle before COMPUTE, compensates FIFO read latency
    always @(posedge clk) begin
        if (rst) pre_write <= 1'b0;
        else     pre_write <= (state == WEIGHT_LOAD) && (w_col == COLS-1);
    end
endmodule

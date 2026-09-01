`timescale 1ns / 1ps

// Tagged-context controller.  The fixed tail counter is diagnostic only;
// architectural completion is the explicit array_retired event.
module systolic_ctrl_tagged #(
    parameter ROWS = 18,
    parameter COLS = 8,
    parameter TAIL_CYCLES_CONFIG = 0,
    // Release builds preload the inactive PE weight bank before context
    // admission.  Legacy/debug builds retain the historical sixteen-cycle
    // ST_WEIGHT sequence.
    parameter ENABLE_PRELOADED_WEIGHT = 0,
    // When the next context is already prepared, its start handshake may
    // coincide with the current context's final compute_fire.  The controller
    // then reloads the pixel count and remains in ST_COMPUTE.
    parameter ENABLE_FAST_HANDOFF = 0,
    // The scalar DSP cascade accepts the atomically issued token one cycle
    // after compute_fire and produces its last-row result ROWS+1 clocks after
    // that boundary.  Completion still comes exclusively from tagged FIFO
    // retirement; this value only sizes the diagnostic watchdog margin.
    parameter ARRAY_PIPELINE_LATENCY = ROWS + 2
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [15:0]  num_pixels,
    input  wire [15:0]  tail_cycles_config,
    input  wire         compute_ready,
    input  wire         array_retired,
    output wire         start_ready,
    output reg          done,
    output reg          w_load,
    output reg  [4:0]   w_col,
    output wire         compute_active,
    output wire         compute_fire,
    output reg          input_issued_done,
    output wire         perf_comp_wload,
    output wire         perf_comp_active,
    output wire         perf_comp_ifm_stall,
    output wire         perf_comp_tail,
    output wire [31:0]  tail_cycles_configured,
    output reg          tail_watchdog_expired,
    output reg          start_while_busy_error
);
    localparam ST_IDLE = 2'd0;
    localparam ST_WEIGHT = 2'd1;
    localparam ST_COMPUTE = 2'd2;
    localparam ST_RETIRE = 2'd3;
    localparam DEFAULT_TAIL_CYCLES = ARRAY_PIPELINE_LATENCY + 16;
    localparam DEFAULT_TAIL_SELECTED =
        (TAIL_CYCLES_CONFIG == 0) ? DEFAULT_TAIL_CYCLES : TAIL_CYCLES_CONFIG;

    wire [15:0] selected_tail = (tail_cycles_config != 16'd0) ?
        tail_cycles_config : DEFAULT_TAIL_SELECTED[15:0];
    // Tagged completion is driven only by the explicit retirement event.  A
    // legacy tail-trim value (the release profile historically uses 1) may
    // still be exposed for performance experiments, but it must not turn a
    // physically unavoidable mesh flight time into a sticky datapath error.
    // Clamp only the diagnostic watchdog to the structural latency bound.
    wire [15:0] watchdog_tail =
        (selected_tail < DEFAULT_TAIL_CYCLES[15:0]) ?
        DEFAULT_TAIL_CYCLES[15:0] : selected_tail;
    wire [15:0] requested_pixels =
        (num_pixels == 16'd0) ? 16'd1 : num_pixels;

    reg [1:0] state_q;
    reg [15:0] compute_count_q;
    reg [15:0] active_pixels_q;
    reg [7:0] outstanding_retire_q;
    reg [15:0] retire_age_q;

    wire input_complete_now = compute_fire &&
        (compute_count_q == active_pixels_q - 1'b1);
    assign start_ready = (state_q == ST_IDLE) ||
        ((ENABLE_FAST_HANDOFF != 0) && (state_q == ST_COMPUTE) &&
         input_complete_now);
    assign compute_active = state_q == ST_COMPUTE;
    assign compute_fire = compute_active && compute_ready;
    assign perf_comp_wload = state_q == ST_WEIGHT;
    assign perf_comp_active = compute_active;
    assign perf_comp_ifm_stall = compute_active && !compute_ready;
    assign perf_comp_tail = outstanding_retire_q != 0;
    assign tail_cycles_configured = {16'd0, selected_tail};
    always @(posedge clk) begin
        if (rst) begin
            state_q <= ST_IDLE;
            w_load <= 1'b0;
            w_col <= 5'd0;
            compute_count_q <= 16'd0;
            active_pixels_q <= 16'd1;
            outstanding_retire_q <= 8'd0;
            retire_age_q <= 16'd0;
            done <= 1'b0;
            input_issued_done <= 1'b0;
            tail_watchdog_expired <= 1'b0;
            start_while_busy_error <= 1'b0;
        end else begin
            done <= 1'b0;
            input_issued_done <= 1'b0;
            w_load <= 1'b0;

            if (start && !start_ready)
                start_while_busy_error <= 1'b1;

            case ({input_complete_now, array_retired})
                2'b10: outstanding_retire_q <=
                    outstanding_retire_q + 1'b1;
                2'b01: if (outstanding_retire_q != 0)
                    outstanding_retire_q <=
                        outstanding_retire_q - 1'b1;
                default: outstanding_retire_q <= outstanding_retire_q;
            endcase

            if (array_retired) begin
                retire_age_q <= 16'd0;
            end else if (outstanding_retire_q != 0) begin
                if (retire_age_q != 16'hffff)
                    retire_age_q <= retire_age_q + 1'b1;
                if ((watchdog_tail != 16'd0) &&
                    (retire_age_q == watchdog_tail - 1'b1))
                    tail_watchdog_expired <= 1'b1;
            end

            case (state_q)
                ST_IDLE: begin
                    w_col <= 5'd0;
                    compute_count_q <= 16'd0;
                    if (start) begin
                        active_pixels_q <= requested_pixels;
                        if (ENABLE_PRELOADED_WEIGHT != 0)
                            state_q <= ST_COMPUTE;
                        else
                            state_q <= ST_WEIGHT;
                        if ((outstanding_retire_q == 0) ||
                            (array_retired &&
                             (outstanding_retire_q == 1)))
                            tail_watchdog_expired <= 1'b0;
                    end
                end

                ST_WEIGHT: begin
                    w_load <= 1'b1;
                    if (w_col == COLS-1) begin
                        w_col <= 5'd0;
                        state_q <= ST_COMPUTE;
                    end else begin
                        w_col <= w_col + 1'b1;
                    end
                end

                ST_COMPUTE: begin
                    if (compute_fire) begin
                        if (compute_count_q == active_pixels_q - 1'b1) begin
                            input_issued_done <= 1'b1;
                            done <= 1'b1;
                            compute_count_q <= 16'd0;
                            if ((ENABLE_FAST_HANDOFF != 0) && start) begin
                                active_pixels_q <= requested_pixels;
                                state_q <= ST_COMPUTE;
                            end else begin
                                state_q <= ST_IDLE;
                            end
                        end else begin
                            compute_count_q <= compute_count_q + 1'b1;
                        end
                    end
                end

                ST_RETIRE: begin
                    // Kept as a defensive decode value for old checkpoints;
                    // tagged retirement is tracked independently of issue.
                    state_q <= ST_IDLE;
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end
endmodule

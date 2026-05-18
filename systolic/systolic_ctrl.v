`timescale 1ns / 1ps
// Minimal FSM: IDLE → WEIGHT_LOAD → COMPUTE
module systolic_ctrl #(
    parameter ROWS = 32, parameter COLS = 32
) (
    input  clk, rst,
    input  start,
    output reg w_load,
    output reg [4:0] w_col,
    output reg compute_active,
    output reg compute_start_pulse   // 1-cycle pulse when COMPUTE begins
);
    localparam IDLE        = 2'd0;
    localparam WEIGHT_LOAD = 2'd1;
    localparam COMPUTE     = 2'd2;

    reg [1:0] state, next_state;

    always @(posedge clk) begin
        if (rst) state <= IDLE;
        else     state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            IDLE:         if (start)            next_state = WEIGHT_LOAD;
            WEIGHT_LOAD:  if (w_col == COLS-1)  next_state = COMPUTE;
            COMPUTE:                            next_state = COMPUTE;  // stays forever
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
        if (rst) compute_start_pulse <= 1'b0;
        else     compute_start_pulse <= (state == COMPUTE) && !was_compute;
    end
endmodule

// Systolic array control FSM
// IDLE → WGT_PREFILL (32 RAM reads) → WEIGHT_LOAD (32 cols) → COMPUTE → DONE
module systolic_ctrl #(
    parameter ROWS = 32,
    parameter COLS = 32
) (
    input  clk, rst,
    input  start,
    output reg wgt_prefill,      // pre-fill weight FIFOs from RAM
    output reg w_load,           // weight loading into array
    output reg [4:0] w_col,      // column index during weight load
    output reg compute_active,
    output reg done
);
    localparam IDLE          = 3'd0;
    localparam WGT_PREFILL   = 3'd1;
    localparam WEIGHT_LOAD   = 3'd2;
    localparam COMPUTE       = 3'd3;
    localparam DONE          = 3'd4;

    reg [2:0] state, next_state;
    reg [5:0] prefill_cnt;

    always @(posedge clk) begin
        if (rst) state <= IDLE;
        else     state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            IDLE:         if (start)                next_state = WGT_PREFILL;
            WGT_PREFILL:  if (prefill_cnt == 6'd32) next_state = WEIGHT_LOAD;
            WEIGHT_LOAD:  if (w_col == COLS-1)      next_state = COMPUTE;
            COMPUTE:      if (!start)               next_state = DONE;
            DONE:                                   next_state = IDLE;
            default:                                next_state = IDLE;
        endcase
    end

    // Pre-fill counter
    always @(posedge clk) begin
        if (rst)                           prefill_cnt <= 6'd0;
        else if (state == WGT_PREFILL)     prefill_cnt <= prefill_cnt + 6'd1;
        else                               prefill_cnt <= 6'd0;
    end
    always @(posedge clk) begin
        if (rst) wgt_prefill <= 1'b0;
        else     wgt_prefill <= (state == WGT_PREFILL);
    end

    // Weight load column counter
    always @(posedge clk) begin
        if (rst)                          w_col <= 5'd0;
        else if (state == WEIGHT_LOAD)    w_col <= w_col + 5'd1;
        else                              w_col <= 5'd0;
    end
    always @(posedge clk) begin
        if (rst) w_load <= 1'b0;
        else     w_load <= (state == WEIGHT_LOAD);
    end

    // Compute / done
    always @(posedge clk) begin
        if (rst) compute_active <= 1'b0;
        else     compute_active <= (state == COMPUTE);
    end
    always @(posedge clk) begin
        if (rst) done <= 1'b0;
        else     done <= (state == DONE);
    end
endmodule

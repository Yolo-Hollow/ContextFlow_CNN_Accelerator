`timescale 1ns / 1ps

// Tagged dual-weight MAC building block for a shadow-weight systolic PE.
//
// The two stationary-weight banks are independently writable.  Every accepted
// token carries the bank/epoch that owns it; the selected weights are presented
// to the packed int8x2 multiplier on the token acceptance cycle.  A bank remains
// owned until all of its accepted tokens have left the result interface.  This
// makes a write to the inactive bank legal while the active bank still has a
// tail in the multiplier/array, while preventing an early reuse of either bank.
//
// The result FIFO also provides explicit downstream backpressure.  Admission is
// credit based: at most OUTSTANDING_MAX tokens can occupy the multiplier pipeline
// plus result FIFO, so a fixed-latency multiplier completion cannot overflow.
module systolic_pe_shadow_weight #(
    parameter IFM_W           = 8,
    parameter WEIGHT_W        = 8,
    parameter PSUM_W          = 32,
    parameter PROD_W          = 16,
    parameter EPOCH_W         = 8,
    parameter OUTSTANDING_MAX = 8
) (
    input  wire                         clk,
    input  wire                         rst,

    input  wire                         weight_valid,
    output wire                         weight_ready,
    input  wire                         weight_bank,
    input  wire [EPOCH_W-1:0]           weight_epoch,
    input  wire signed [WEIGHT_W-1:0]   weight0_data,
    input  wire signed [WEIGHT_W-1:0]   weight1_data,

    input  wire                         token_valid,
    output wire                         token_ready,
    input  wire signed [IFM_W-1:0]      token_ifm,
    input  wire signed [PSUM_W-1:0]     token_psum0,
    input  wire signed [PSUM_W-1:0]     token_psum1,
    input  wire                         token_weight_bank,
    input  wire [EPOCH_W-1:0]           token_weight_epoch,

    output wire                         result_valid,
    input  wire                         result_ready,
    output wire signed [PSUM_W-1:0]     result_psum0,
    output wire signed [PSUM_W-1:0]     result_psum1,
    output wire                         result_weight_bank,
    output wire [EPOCH_W-1:0]           result_weight_epoch,

    output wire [1:0]                   bank_valid,
    output wire [15:0]                  bank0_inflight,
    output wire [15:0]                  bank1_inflight,
    output wire [15:0]                  total_outstanding,

    output reg                          ownership_error_sticky,
    output reg                          bank_tag_error_sticky,
    output reg                          epoch_error_sticky,
    output reg                          protocol_error_sticky,
    output reg  [31:0]                  blocked_weight_write_count,
    output reg  [31:0]                  bad_bank_token_count,
    output reg  [31:0]                  epoch_mismatch_count,
    output reg  [31:0]                  accepted_token_count,
    output reg  [31:0]                  retired_token_count
);
    localparam MULT_PIPE_STAGES = 4;
    localparam SEXT_W = PSUM_W - PROD_W;
    localparam FIFO_PTR_W = (OUTSTANDING_MAX <= 2) ? 1 : $clog2(OUTSTANDING_MAX);
    localparam FIFO_CNT_W = (OUTSTANDING_MAX <= 1) ? 1 : $clog2(OUTSTANDING_MAX + 1);

    reg signed [WEIGHT_W-1:0] weight0_bank0_q;
    reg signed [WEIGHT_W-1:0] weight1_bank0_q;
    reg signed [WEIGHT_W-1:0] weight0_bank1_q;
    reg signed [WEIGHT_W-1:0] weight1_bank1_q;
    reg [EPOCH_W-1:0] epoch_bank0_q;
    reg [EPOCH_W-1:0] epoch_bank1_q;
    reg [1:0] bank_valid_q;
    reg [15:0] bank0_inflight_q;
    reg [15:0] bank1_inflight_q;
    reg [15:0] total_outstanding_q;

    assign bank_valid        = bank_valid_q;
    assign bank0_inflight    = bank0_inflight_q;
    assign bank1_inflight    = bank1_inflight_q;
    assign total_outstanding = total_outstanding_q;

    wire selected_bank_idle = weight_bank ?
        (bank1_inflight_q == 16'd0) : (bank0_inflight_q == 16'd0);
    assign weight_ready = selected_bank_idle;
    wire weight_fire = weight_valid && weight_ready;

    wire token_bank_valid = token_weight_bank ? bank_valid_q[1] : bank_valid_q[0];
    wire [EPOCH_W-1:0] token_bank_epoch = token_weight_bank ?
        epoch_bank1_q : epoch_bank0_q;
    wire token_epoch_matches = token_weight_epoch == token_bank_epoch;

    // A same-bank weight write has priority.  The producer keeps the token valid
    // and retries it against the newly loaded epoch on the following cycle.
    wire same_bank_weight_fire = weight_fire &&
        (weight_bank == token_weight_bank);
    wire result_fire;
    wire admission_credit = (total_outstanding_q < OUTSTANDING_MAX) || result_fire;
    assign token_ready = token_bank_valid && token_epoch_matches &&
        admission_credit && !same_bank_weight_fire;
    wire token_fire = token_valid && token_ready;

    wire signed [WEIGHT_W-1:0] selected_weight0 = token_weight_bank ?
        weight0_bank1_q : weight0_bank0_q;
    wire signed [WEIGHT_W-1:0] selected_weight1 = token_weight_bank ?
        weight1_bank1_q : weight1_bank0_q;

    // The packed multiplier is the same one used by systolic_pe, preserving the
    // one-DSP/two-int8-product implementation.  Invalid cycles inject zeros and
    // are removed by the parallel valid pipeline.
    wire signed [PROD_W-1:0] product0;
    wire signed [PROD_W-1:0] product1;
    wire signed [WEIGHT_W-1:0] mult_weight0 = token_fire ? selected_weight0 :
        {WEIGHT_W{1'b0}};
    wire signed [WEIGHT_W-1:0] mult_weight1 = token_fire ? selected_weight1 :
        {WEIGHT_W{1'b0}};
    wire signed [IFM_W-1:0] mult_ifm = token_fire ? token_ifm :
        {IFM_W{1'b0}};

    cal_mult_int8_x2 u_tagged_mult (
        .clk (clk),
        .a   (mult_weight0),
        .b   (mult_weight1),
        .c   (mult_ifm),
        .ac  (product0),
        .bc  (product1)
    );

    reg [MULT_PIPE_STAGES-1:0] token_valid_pipe_q;
    reg signed [PSUM_W-1:0] psum0_pipe_q [0:MULT_PIPE_STAGES-1];
    reg signed [PSUM_W-1:0] psum1_pipe_q [0:MULT_PIPE_STAGES-1];
    reg bank_pipe_q [0:MULT_PIPE_STAGES-1];
    reg [EPOCH_W-1:0] epoch_pipe_q [0:MULT_PIPE_STAGES-1];

    integer pipe_idx;
    always @(posedge clk) begin
        if (rst) begin
            token_valid_pipe_q <= {MULT_PIPE_STAGES{1'b0}};
            for (pipe_idx = 0; pipe_idx < MULT_PIPE_STAGES; pipe_idx = pipe_idx + 1) begin
                psum0_pipe_q[pipe_idx] <= {PSUM_W{1'b0}};
                psum1_pipe_q[pipe_idx] <= {PSUM_W{1'b0}};
                bank_pipe_q[pipe_idx]  <= 1'b0;
                epoch_pipe_q[pipe_idx] <= {EPOCH_W{1'b0}};
            end
        end else begin
            token_valid_pipe_q[0] <= token_fire;
            psum0_pipe_q[0] <= token_psum0;
            psum1_pipe_q[0] <= token_psum1;
            bank_pipe_q[0]  <= token_weight_bank;
            epoch_pipe_q[0] <= token_weight_epoch;
            for (pipe_idx = 1; pipe_idx < MULT_PIPE_STAGES; pipe_idx = pipe_idx + 1) begin
                token_valid_pipe_q[pipe_idx] <= token_valid_pipe_q[pipe_idx-1];
                psum0_pipe_q[pipe_idx] <= psum0_pipe_q[pipe_idx-1];
                psum1_pipe_q[pipe_idx] <= psum1_pipe_q[pipe_idx-1];
                bank_pipe_q[pipe_idx]  <= bank_pipe_q[pipe_idx-1];
                epoch_pipe_q[pipe_idx] <= epoch_pipe_q[pipe_idx-1];
            end
        end
    end

    wire completion_valid = token_valid_pipe_q[MULT_PIPE_STAGES-1];
    wire signed [PSUM_W-1:0] product0_ext =
        {{SEXT_W{product0[PROD_W-1]}}, product0};
    wire signed [PSUM_W-1:0] product1_ext =
        {{SEXT_W{product1[PROD_W-1]}}, product1};
    wire signed [PSUM_W-1:0] completion_psum0 =
        psum0_pipe_q[MULT_PIPE_STAGES-1] + product0_ext;
    wire signed [PSUM_W-1:0] completion_psum1 =
        psum1_pipe_q[MULT_PIPE_STAGES-1] + product1_ext;

    reg signed [PSUM_W-1:0] result_psum0_mem [0:OUTSTANDING_MAX-1];
    reg signed [PSUM_W-1:0] result_psum1_mem [0:OUTSTANDING_MAX-1];
    reg result_bank_mem [0:OUTSTANDING_MAX-1];
    reg [EPOCH_W-1:0] result_epoch_mem [0:OUTSTANDING_MAX-1];
    reg [FIFO_PTR_W-1:0] result_wr_ptr_q;
    reg [FIFO_PTR_W-1:0] result_rd_ptr_q;
    reg [FIFO_CNT_W-1:0] result_count_q;

    assign result_valid        = result_count_q != 0;
    assign result_psum0        = result_psum0_mem[result_rd_ptr_q];
    assign result_psum1        = result_psum1_mem[result_rd_ptr_q];
    assign result_weight_bank  = result_bank_mem[result_rd_ptr_q];
    assign result_weight_epoch = result_epoch_mem[result_rd_ptr_q];
    assign result_fire         = result_valid && result_ready;

    wire result_fifo_can_accept = (result_count_q < OUTSTANDING_MAX) || result_fire;

    always @(posedge clk) begin
        if (rst) begin
            result_wr_ptr_q <= {FIFO_PTR_W{1'b0}};
            result_rd_ptr_q <= {FIFO_PTR_W{1'b0}};
            result_count_q  <= {FIFO_CNT_W{1'b0}};
        end else begin
            if (completion_valid && result_fifo_can_accept) begin
                result_psum0_mem[result_wr_ptr_q] <= completion_psum0;
                result_psum1_mem[result_wr_ptr_q] <= completion_psum1;
                result_bank_mem[result_wr_ptr_q]  <= bank_pipe_q[MULT_PIPE_STAGES-1];
                result_epoch_mem[result_wr_ptr_q] <= epoch_pipe_q[MULT_PIPE_STAGES-1];
                if (result_wr_ptr_q == OUTSTANDING_MAX-1)
                    result_wr_ptr_q <= {FIFO_PTR_W{1'b0}};
                else
                    result_wr_ptr_q <= result_wr_ptr_q + 1'b1;
            end

            if (result_fire) begin
                if (result_rd_ptr_q == OUTSTANDING_MAX-1)
                    result_rd_ptr_q <= {FIFO_PTR_W{1'b0}};
                else
                    result_rd_ptr_q <= result_rd_ptr_q + 1'b1;
            end

            case ({completion_valid && result_fifo_can_accept, result_fire})
                2'b10: result_count_q <= result_count_q + 1'b1;
                2'b01: result_count_q <= result_count_q - 1'b1;
                default: result_count_q <= result_count_q;
            endcase
        end
    end

    // Weight ownership, error telemetry, and lifetime counters.
    always @(posedge clk) begin
        if (rst) begin
            weight0_bank0_q <= {WEIGHT_W{1'b0}};
            weight1_bank0_q <= {WEIGHT_W{1'b0}};
            weight0_bank1_q <= {WEIGHT_W{1'b0}};
            weight1_bank1_q <= {WEIGHT_W{1'b0}};
            epoch_bank0_q <= {EPOCH_W{1'b0}};
            epoch_bank1_q <= {EPOCH_W{1'b0}};
            bank_valid_q <= 2'b00;
            bank0_inflight_q <= 16'd0;
            bank1_inflight_q <= 16'd0;
            total_outstanding_q <= 16'd0;
            ownership_error_sticky <= 1'b0;
            bank_tag_error_sticky <= 1'b0;
            epoch_error_sticky <= 1'b0;
            protocol_error_sticky <= 1'b0;
            blocked_weight_write_count <= 32'd0;
            bad_bank_token_count <= 32'd0;
            epoch_mismatch_count <= 32'd0;
            accepted_token_count <= 32'd0;
            retired_token_count <= 32'd0;
        end else begin
            if (weight_fire) begin
                if (weight_bank) begin
                    weight0_bank1_q <= weight0_data;
                    weight1_bank1_q <= weight1_data;
                    epoch_bank1_q <= weight_epoch;
                    bank_valid_q[1] <= 1'b1;
                end else begin
                    weight0_bank0_q <= weight0_data;
                    weight1_bank0_q <= weight1_data;
                    epoch_bank0_q <= weight_epoch;
                    bank_valid_q[0] <= 1'b1;
                end
            end

            if (weight_valid && !weight_ready) begin
                ownership_error_sticky <= 1'b1;
                blocked_weight_write_count <= blocked_weight_write_count + 1'b1;
            end

            if (token_valid && !token_bank_valid) begin
                bank_tag_error_sticky <= 1'b1;
                bad_bank_token_count <= bad_bank_token_count + 1'b1;
            end else if (token_valid && !token_epoch_matches) begin
                epoch_error_sticky <= 1'b1;
                epoch_mismatch_count <= epoch_mismatch_count + 1'b1;
            end

            if (completion_valid && !result_fifo_can_accept)
                protocol_error_sticky <= 1'b1;

            if (token_fire)
                accepted_token_count <= accepted_token_count + 1'b1;
            if (result_fire)
                retired_token_count <= retired_token_count + 1'b1;

            case ({token_fire, result_fire})
                2'b10: total_outstanding_q <= total_outstanding_q + 1'b1;
                2'b01: begin
                    if (total_outstanding_q == 0)
                        protocol_error_sticky <= 1'b1;
                    else
                        total_outstanding_q <= total_outstanding_q - 1'b1;
                end
                default: total_outstanding_q <= total_outstanding_q;
            endcase

            case ({token_fire && !token_weight_bank,
                   result_fire && !result_weight_bank})
                2'b10: bank0_inflight_q <= bank0_inflight_q + 1'b1;
                2'b01: begin
                    if (bank0_inflight_q == 0) begin
                        ownership_error_sticky <= 1'b1;
                        protocol_error_sticky <= 1'b1;
                    end else begin
                        bank0_inflight_q <= bank0_inflight_q - 1'b1;
                    end
                end
                default: bank0_inflight_q <= bank0_inflight_q;
            endcase

            case ({token_fire && token_weight_bank,
                   result_fire && result_weight_bank})
                2'b10: bank1_inflight_q <= bank1_inflight_q + 1'b1;
                2'b01: begin
                    if (bank1_inflight_q == 0) begin
                        ownership_error_sticky <= 1'b1;
                        protocol_error_sticky <= 1'b1;
                    end else begin
                        bank1_inflight_q <= bank1_inflight_q - 1'b1;
                    end
                end
                default: bank1_inflight_q <= bank1_inflight_q;
            endcase
        end
    end
endmodule

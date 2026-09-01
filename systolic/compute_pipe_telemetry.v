`timescale 1ns / 1ps

// Cumulative telemetry for the fast context handoff path.
//
// Every scalar input is a one-cycle event pulse.  wait_reason_pulse is also an
// event interface: zero means no classified wait and exactly one asserted bit
// increments the corresponding counter.  A multi-bit wait reason is rejected,
// increments protocol_error_count once, and does not increment any wait
// counter.  An explicit protocol_error_pulse and an invalid wait reason in the
// same cycle still count as one protocol-error event.
//
// Counter update priority is:
//   1. rst          - clear every counter;
//   2. soft_reset   - clear every counter and ignore event pulses;
//   3. event pulses - increment independently, with natural 32-bit wrap.
//
// wait_reason_pulse bit assignment:
//   [0] wait for an old array token to retire before bank reuse
//   [1] wait for the selected weight bank
//   [2] wait for the selected IFM/vector bank
//   [3] wait for committed partial-PSUM credit
//   [4] wait for collector or output credit
//   [5] wait for scheduler/controller admission
module compute_pipe_telemetry (
    input  wire        clk,
    input  wire        rst,
    input  wire        soft_reset,

    input  wire        compute_gap_pulse,
    input  wire        preload_commit_pulse,
    input  wire        preload_hit_pulse,
    input  wire        preload_miss_pulse,
    input  wire        eligible_handoff_pulse,
    input  wire        next_cycle_hit_pulse,
    input  wire        extra_gap_pulse,
    input  wire [5:0]  wait_reason_pulse,
    input  wire        protocol_error_pulse,

    output reg  [31:0] compute_gap_count,
    output reg  [31:0] preload_commit_count,
    output reg  [31:0] preload_hit_count,
    output reg  [31:0] preload_miss_count,
    output reg  [31:0] eligible_handoff_count,
    output reg  [31:0] next_cycle_hit_count,
    output reg  [31:0] extra_gap_count,
    output reg  [31:0] wait_bank_retire_count,
    output reg  [31:0] wait_weight_count,
    output reg  [31:0] wait_ifm_count,
    output reg  [31:0] wait_psum_count,
    output reg  [31:0] wait_collector_output_count,
    output reg  [31:0] wait_control_count,
    output reg  [31:0] protocol_error_count
);

    wire wait_reason_is_onehot =
        (wait_reason_pulse != 6'b000000) &&
        ((wait_reason_pulse & (wait_reason_pulse - 6'b000001)) ==
         6'b000000);
    wire invalid_wait_reason =
        (wait_reason_pulse != 6'b000000) && !wait_reason_is_onehot;

    always @(posedge clk) begin
        if (rst) begin
            compute_gap_count <= 32'd0;
            preload_commit_count <= 32'd0;
            preload_hit_count <= 32'd0;
            preload_miss_count <= 32'd0;
            eligible_handoff_count <= 32'd0;
            next_cycle_hit_count <= 32'd0;
            extra_gap_count <= 32'd0;
            wait_bank_retire_count <= 32'd0;
            wait_weight_count <= 32'd0;
            wait_ifm_count <= 32'd0;
            wait_psum_count <= 32'd0;
            wait_collector_output_count <= 32'd0;
            wait_control_count <= 32'd0;
            protocol_error_count <= 32'd0;
        end else if (soft_reset) begin
            compute_gap_count <= 32'd0;
            preload_commit_count <= 32'd0;
            preload_hit_count <= 32'd0;
            preload_miss_count <= 32'd0;
            eligible_handoff_count <= 32'd0;
            next_cycle_hit_count <= 32'd0;
            extra_gap_count <= 32'd0;
            wait_bank_retire_count <= 32'd0;
            wait_weight_count <= 32'd0;
            wait_ifm_count <= 32'd0;
            wait_psum_count <= 32'd0;
            wait_collector_output_count <= 32'd0;
            wait_control_count <= 32'd0;
            protocol_error_count <= 32'd0;
        end else begin
            if (compute_gap_pulse)
                compute_gap_count <= compute_gap_count + 32'd1;
            if (preload_commit_pulse)
                preload_commit_count <= preload_commit_count + 32'd1;
            if (preload_hit_pulse)
                preload_hit_count <= preload_hit_count + 32'd1;
            if (preload_miss_pulse)
                preload_miss_count <= preload_miss_count + 32'd1;
            if (eligible_handoff_pulse)
                eligible_handoff_count <= eligible_handoff_count + 32'd1;
            if (next_cycle_hit_pulse)
                next_cycle_hit_count <= next_cycle_hit_count + 32'd1;
            if (extra_gap_pulse)
                extra_gap_count <= extra_gap_count + 32'd1;

            // Invalid multi-bit values deliberately have no wait-counter side
            // effect; they are reported by protocol_error_count below.
            case (wait_reason_pulse)
                6'b000001:
                    wait_bank_retire_count <=
                        wait_bank_retire_count + 32'd1;
                6'b000010:
                    wait_weight_count <= wait_weight_count + 32'd1;
                6'b000100:
                    wait_ifm_count <= wait_ifm_count + 32'd1;
                6'b001000:
                    wait_psum_count <= wait_psum_count + 32'd1;
                6'b010000:
                    wait_collector_output_count <=
                        wait_collector_output_count + 32'd1;
                6'b100000:
                    wait_control_count <= wait_control_count + 32'd1;
                default: begin end
            endcase

            if (protocol_error_pulse || invalid_wait_reason)
                protocol_error_count <= protocol_error_count + 32'd1;
        end
    end

endmodule

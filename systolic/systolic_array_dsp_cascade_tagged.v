`timescale 1ns / 1ps

// Low-density tagged array built from independent scalar DSP48E2 cascades.
//
// There is one scalar lane per output channel.  A COLS-wide legacy array has
// two output channels per column, so this implementation instantiates
// 2*COLS lanes (32 lanes for the release 18x16 configuration).  Every lane
// receives the same atomic IFM vector; only its seed PSUM and stationary
// weights differ.  Row alignment and compact-tag control are shared once in
// this wrapper rather than replicated in all 32 arithmetic lanes.  The
// DSP PCIN/PCOUT cascade lives in systolic_scalar_lane_dsp48e2.  Consequently
// no row or column skew is required around this array.
//
// Weight-stream compatibility is intentionally kept at this boundary:
//
//   w_row_data[{row,0}] -> output lane 2*w_col
//   w_row_data[{row,1}] -> output lane 2*w_col+1
//
// Thus the scheduler and the existing COUT-pair weight packets do not change.
module systolic_array_dsp_cascade_tagged #(
    parameter ROWS     = 18,
    parameter COLS     = 16,
    parameter IFM_W    = 8,
    parameter WEIGHT_W = 8,
    parameter PSUM_W   = 32,
    parameter TAG_W    = 2,
    parameter LOCALIZE_A1_IFM_BITS = 0
) (
    input  wire                                  clk,
    input  wire                                  rst,

    input  wire                                  w_load,
    input  wire [4:0]                            w_col,
    input  wire                                  w_bank,
    input  wire [ROWS*WEIGHT_W*2-1:0]            w_row_data,

    input  wire [ROWS*IFM_W-1:0]                 ifm_vector_flat,
    input  wire [COLS*2*PSUM_W-1:0]              seed_psum_flat,
    input  wire                                  token_valid,
    input  wire [TAG_W-1:0]                      token_tag,

    output wire [COLS*2*PSUM_W-1:0]              result_psum_flat,
    output wire                                  result_valid,
    output wire [TAG_W-1:0]                      result_tag,
    output wire                                  tag_mismatch_event,
    output wire                                  weight_write_collision_event
);
    localparam integer LANES = COLS * 2;
    localparam integer LANE_LATENCY = ROWS + 1;
    localparam integer IFM_LANES_PER_LOCAL_GROUP = 8;
    localparam integer IFM_LOCAL_GROUPS =
        (LANES + IFM_LANES_PER_LOCAL_GROUP - 1) /
        IFM_LANES_PER_LOCAL_GROUP;

    initial begin
        if (ROWS < 2)
            $error("systolic_array_dsp_cascade_tagged requires ROWS >= 2");
        if ((COLS < 1) || (COLS > 32))
            $error("systolic_array_dsp_cascade_tagged requires 1 <= COLS <= 32");
        if (IFM_W != 8)
            $error("systolic_array_dsp_cascade_tagged requires 8-bit IFM");
        if (WEIGHT_W != 8)
            $error("systolic_array_dsp_cascade_tagged requires 8-bit weights");
        if (PSUM_W != 32)
            $error("systolic_array_dsp_cascade_tagged requires 32-bit PSUM");
        if (TAG_W != 2)
            $error("systolic_array_dsp_cascade_tagged requires the 2-bit {bank,last} tag");
    end

    // Row r meets cascade stage r, one cycle later than row r-1.  Sharing
    // these delay chains avoids replicating about 44k payload/control FFs
    // across the 32 release lanes.  Release builds copy five routed-critical
    // final-stage bits once per eight lanes.  Non-preloaded A1 timing builds
    // copy only the additional routed-critical bits observed in the formal
    // A1 checkpoint.  Each copy captures the same
    // penultimate value on the same edge, so latency and arithmetic remain
    // bit-exact while each routed source serves only one local lane group.
    wire [ROWS*IFM_W-1:0] ifm_rows_aligned_flat;
    wire [IFM_LOCAL_GROUPS*ROWS*IFM_W-1:0]
        ifm_rows_aligned_local_flat;
    wire [ROWS-1:0] bank_rows_aligned;
    (* shreg_extract = "no" *)
    reg [ROWS-2:0] bank_wave_q;
    integer bank_delay_idx;
    always @(posedge clk) begin
        bank_wave_q[0] <= token_tag[1];
        for (bank_delay_idx = 1; bank_delay_idx < ROWS-1;
             bank_delay_idx = bank_delay_idx + 1)
            bank_wave_q[bank_delay_idx] <=
                bank_wave_q[bank_delay_idx-1];
    end

    genvar align_row;
    genvar no_delay_group;
    genvar align_bit;
    genvar local_group;
    genvar shared_group;
    generate
        for (align_row = 0; align_row < ROWS;
             align_row = align_row + 1) begin : row_align_gen
            wire signed [IFM_W-1:0] row_ifm_input =
                ifm_vector_flat[align_row*IFM_W +: IFM_W];
            if (align_row == 0) begin : no_delay
                assign ifm_rows_aligned_flat[IFM_W-1:0] =
                    row_ifm_input;
                for (no_delay_group = 0;
                     no_delay_group < IFM_LOCAL_GROUPS;
                     no_delay_group = no_delay_group + 1) begin : group_gen
                    assign ifm_rows_aligned_local_flat[
                        no_delay_group*ROWS*IFM_W +: IFM_W] =
                        row_ifm_input;
                end
                assign bank_rows_aligned[0] = token_tag[1];
            end else begin : delayed
                (* shreg_extract = "no" *)
                reg signed [IFM_W-1:0] ifm_delay_q [0:align_row-1];
                integer delay_idx;
                always @(posedge clk) begin
                    ifm_delay_q[0] <= row_ifm_input;
                    for (delay_idx = 1; delay_idx < align_row;
                         delay_idx = delay_idx + 1) begin
                        ifm_delay_q[delay_idx] <=
                            ifm_delay_q[delay_idx-1];
                    end
                end
                assign ifm_rows_aligned_flat[
                    align_row*IFM_W +: IFM_W] =
                    ifm_delay_q[align_row-1];
                for (align_bit = 0; align_bit < IFM_W;
                     align_bit = align_bit + 1) begin : bit_localize_gen
                    if (((LOCALIZE_A1_IFM_BITS != 0) &&
                         (((align_row == 1)  && (align_bit == 4)) ||
                          ((align_row == 4)  && (align_bit == 7)) ||
                          ((align_row == 5)  && (align_bit == 7)) ||
                          ((align_row == 7)  && (align_bit == 6)) ||
                          ((align_row == 11) && (align_bit == 7)) ||
                          ((align_row == 15) && ((align_bit == 0) ||
                                                (align_bit == 2))) ||
                          ((align_row == 17) && (align_bit == 7)))) ||
                        ((align_row == 3) && (align_bit == 3)) ||
                        ((align_row == 8) && (align_bit == 7)) ||
                        ((align_row == 10) && (align_bit == 2)) ||
                        ((align_row == 14) && (align_bit == 2)) ||
                        ((align_row == 16) && (align_bit == 6))) begin : localized
                        // KEEP is deliberately scoped to the selected local
                        // copies; otherwise synthesis can merge equivalent
                        // groups back into the original high-fanout source.
                        wire [IFM_LOCAL_GROUPS-1:0] ifm_local;
                        if (align_row == 1) begin : first_delay
                            // The first delayed row has no penultimate
                            // register.  Capture its original input on the
                            // same edge as ifm_delay_q[0].
                            (* KEEP = "TRUE", SHREG_EXTRACT = "NO" *)
                            reg [IFM_LOCAL_GROUPS-1:0] ifm_local_q;
                            always @(posedge clk)
                                ifm_local_q <= {IFM_LOCAL_GROUPS{
                                    row_ifm_input[align_bit]}};
                            assign ifm_local = ifm_local_q;
                        end else begin : later_delay
                            (* KEEP = "TRUE", SHREG_EXTRACT = "NO" *)
                            reg [IFM_LOCAL_GROUPS-1:0] ifm_local_q;
                            always @(posedge clk)
                                ifm_local_q <= {IFM_LOCAL_GROUPS{
                                    ifm_delay_q[align_row-2][align_bit]}};
                            assign ifm_local = ifm_local_q;
                        end
                        for (local_group = 0;
                             local_group < IFM_LOCAL_GROUPS;
                             local_group = local_group + 1) begin : group_gen
                            assign ifm_rows_aligned_local_flat[
                                local_group*ROWS*IFM_W +
                                align_row*IFM_W + align_bit] =
                                ifm_local[local_group];
                        end
                    end else begin : shared
                        for (shared_group = 0;
                             shared_group < IFM_LOCAL_GROUPS;
                             shared_group = shared_group + 1) begin : group_gen
                            assign ifm_rows_aligned_local_flat[
                                shared_group*ROWS*IFM_W +
                                align_row*IFM_W + align_bit] =
                                ifm_delay_q[align_row-1][align_bit];
                        end
                    end
                end
                assign bank_rows_aligned[align_row] =
                    bank_wave_q[align_row-1];
            end
        end
    endgenerate

    // All scalar lanes have an identical fixed ROWS+1 latency.  One shared
    // control pipe is therefore authoritative for the entire result vector.
    (* shreg_extract = "no" *)
    reg [LANE_LATENCY-1:0] valid_pipe_q;
    (* shreg_extract = "no" *)
    reg [TAG_W-1:0] tag_pipe_q [0:LANE_LATENCY-1];
    integer valid_pipe_idx;
    integer tag_pipe_idx;
    always @(posedge clk) begin
        if (rst)
            valid_pipe_q <= {LANE_LATENCY{1'b0}};
        else begin
            valid_pipe_q[0] <= token_valid;
            for (valid_pipe_idx = 1;
                 valid_pipe_idx < LANE_LATENCY;
                 valid_pipe_idx = valid_pipe_idx + 1)
                valid_pipe_q[valid_pipe_idx] <=
                    valid_pipe_q[valid_pipe_idx-1];
        end
    end

    always @(posedge clk) begin
        tag_pipe_q[0] <= token_tag;
        for (tag_pipe_idx = 1;
             tag_pipe_idx < LANE_LATENCY;
             tag_pipe_idx = tag_pipe_idx + 1)
            tag_pipe_q[tag_pipe_idx] <=
                tag_pipe_q[tag_pipe_idx-1];
    end

    assign result_valid = valid_pipe_q[LANE_LATENCY-1];
    assign result_tag = tag_pipe_q[LANE_LATENCY-1];

    // Track accepted tokens until the common lane output boundary.  The
    // release scheduler already prevents early bank reuse; this compact
    // occupancy check keeps the array's diagnostic collision behavior useful
    // in standalone tests as well.  A write to a bank with any live token is
    // conservatively reported, including the cycle in which its last token
    // leaves the array.
    reg [15:0] bank0_tokens_q;
    reg [15:0] bank1_tokens_q;
    wire token_bank = token_tag[1];
    wire result_bank = result_tag[1];
    wire token_bank0_push = token_valid && !token_bank;
    wire token_bank1_push = token_valid && token_bank;
    wire token_bank0_pop = result_valid && !result_bank;
    wire token_bank1_pop = result_valid && result_bank;

    always @(posedge clk) begin
        if (rst) begin
            bank0_tokens_q <= 16'd0;
            bank1_tokens_q <= 16'd0;
        end else begin
            case ({token_bank0_push, token_bank0_pop})
                2'b10: bank0_tokens_q <= bank0_tokens_q + 1'b1;
                2'b01: bank0_tokens_q <= bank0_tokens_q - 1'b1;
                default: bank0_tokens_q <= bank0_tokens_q;
            endcase
            case ({token_bank1_push, token_bank1_pop})
                2'b10: bank1_tokens_q <= bank1_tokens_q + 1'b1;
                2'b01: bank1_tokens_q <= bank1_tokens_q - 1'b1;
                default: bank1_tokens_q <= bank1_tokens_q;
            endcase
        end
    end

    genvar lane_idx;
    genvar row_idx;
    generate
        for (lane_idx = 0; lane_idx < LANES;
             lane_idx = lane_idx + 1) begin : lane_gen
            localparam [4:0] PAIR_INDEX = lane_idx / 2;
            localparam integer PAIR_LANE = lane_idx % 2;
            localparam integer IFM_LOCAL_GROUP =
                lane_idx / IFM_LANES_PER_LOCAL_GROUP;
            wire [ROWS*WEIGHT_W-1:0] lane_weight_rows;
            wire [ROWS*WEIGHT_W-1:0] lane_weight_aligned_rows;
            wire lane_w_load = w_load && (w_col == PAIR_INDEX);
            reg [ROWS*WEIGHT_W-1:0] lane_weight_bank0_q;
            reg [ROWS*WEIGHT_W-1:0] lane_weight_bank1_q;

            // The input packet is row-major with two adjacent output-channel
            // weights per row.  Gather one member of every pair for this
            // scalar output lane without adding a run-time mux.
            for (row_idx = 0; row_idx < ROWS;
                 row_idx = row_idx + 1) begin : weight_row_gen
                assign lane_weight_rows[
                    row_idx*WEIGHT_W +: WEIGHT_W] = w_row_data[
                    (row_idx*2 + PAIR_LANE)*WEIGHT_W +: WEIGHT_W];
                assign lane_weight_aligned_rows[
                    row_idx*WEIGHT_W +: WEIGHT_W] =
                    bank_rows_aligned[row_idx] ?
                        lane_weight_bank1_q[
                            row_idx*WEIGHT_W +: WEIGHT_W] :
                        lane_weight_bank0_q[
                            row_idx*WEIGHT_W +: WEIGHT_W];
            end

            // Weight contents are don't-care until scheduler ownership has
            // committed a complete bank.  Omitting payload reset avoids a
            // high-fanout reset tree across all 9,216 release weight bits.
            always @(posedge clk) begin
                if (lane_w_load) begin
                    if (w_bank)
                        lane_weight_bank1_q <= lane_weight_rows;
                    else
                        lane_weight_bank0_q <= lane_weight_rows;
                end
            end

`ifdef CONV_ACCEL_FAST_XSIM_DSP
            // Explicit XSIM acceleration path.  The primitive scalar lane is
            // left untouched and remains independently instantiable for
            // differential tests.  Normal synthesis never defines this macro
            // and therefore retains the exact DSP48E2 hierarchy checked by
            // dsp_cascade_checks.tcl.
            systolic_scalar_lane_dsp48e2_fast_sim #(
`else
            systolic_scalar_lane_dsp48e2 #(
`endif
                .ROWS(ROWS),
                .IFM_W(IFM_W),
                .WEIGHT_W(WEIGHT_W),
                .PSUM_W(PSUM_W)
`ifdef CONV_ACCEL_FAST_XSIM_DSP
            ) u_lane_fast_sim (
`else
            ) u_lane (
`endif
                .clk(clk),
                .ifm_rows_aligned_flat(ifm_rows_aligned_local_flat[
                    IFM_LOCAL_GROUP*ROWS*IFM_W +: ROWS*IFM_W]),
                .weight_rows_aligned_flat(lane_weight_aligned_rows),
                .seed_psum(seed_psum_flat[
                    lane_idx*PSUM_W +: PSUM_W]),
                .result(result_psum_flat[
                    lane_idx*PSUM_W +: PSUM_W])
            );
        end
    endgenerate

    // There is one shared tag path, so arithmetic lanes cannot diverge in
    // context identity.  Seed-valid agreement is checked by the enclosing
    // tagged top before a token is admitted.
    assign tag_mismatch_event = 1'b0;
    assign weight_write_collision_event = w_load &&
        (w_bank ? ((bank1_tokens_q != 0) || token_bank1_push) :
                  ((bank0_tokens_q != 0) || token_bank0_push));
endmodule

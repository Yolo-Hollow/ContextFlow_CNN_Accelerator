`timescale 1ns / 1ps

// Layer-long uint8-HWC rolling-window materializer.
//
// The historical module name is retained for ABI/source compatibility.  The
// implementation is no longer byte-BRAM banked: four packed rolling-row
// stores replace the 64-bank address broadcast and read crossbar.  Each
// 64-bit word contains two adjacent pixels by four adjacent channels.
module axis_hwc_window_materializer_byte_bram #(
    parameter integer ROWS = 18,
    parameter integer AXIS_W = 64,
    parameter integer KEEP_W = AXIS_W / 8,
    parameter integer MAX_FM_W = 416,
    parameter integer MAX_CHANNELS = 1024,
    parameter integer LINE_BANK_DEPTH = 2048,
    parameter integer MAX_PASSES = 512,
    parameter integer EPOCH_W = 8,
    parameter integer CFG_PREVALIDATED = 0,
    parameter integer ENABLE_PASS_READY_BITMAP = 1,
    parameter integer LINE_STORE_USE_URAM = 1
) (
    input  wire                         clk,
    input  wire                         rst,

    input  wire                         cfg_start,
    input  wire [15:0]                  cfg_fm_h,
    input  wire [15:0]                  cfg_fm_w,
    input  wire [13:0]                  cfg_cin,
    input  wire [15:0]                  cfg_ofm_h,
    input  wire [15:0]                  cfg_ofm_w,
    input  wire                         cfg_kernel_1x1,
    input  wire [1:0]                   cfg_stride,
    input  wire [1:0]                   cfg_pad,
    input  wire [7:0]                   cfg_input_zero_point,
    input  wire [EPOCH_W-1:0]           cfg_epoch,
    input  wire [31:0]                  cfg_expected_bytes,
    input  wire [15:0]                  cfg_prevalidated_pass_count,

    output wire                         s_axis_tready,
    input  wire                         s_axis_tvalid,
    input  wire [AXIS_W-1:0]            s_axis_tdata,
    input  wire [KEEP_W-1:0]            s_axis_tkeep,
    input  wire                         s_axis_tlast,

    output wire                         m_entry_valid,
    input  wire                         m_entry_ready,
    output wire [ROWS*8-1:0]            m_entry_data,
    output wire [ROWS-1:0]              m_entry_lane_valid,
    output wire [31:0]                  m_entry_pixel,
    output wire [15:0]                  m_entry_k_pass,
    output wire [EPOCH_W-1:0]           m_entry_epoch,
    output wire                         m_entry_last,

    output wire [MAX_PASSES-1:0]        pass_ready_bitmap,
    output wire [EPOCH_W-1:0]           pass_ready_epoch,
    output wire                         busy,
    output reg                          input_done,
    output reg                          done,

    output reg                          config_error,
    output reg                          tkeep_error,
    output reg                          tlast_error,
    output reg                          overflow_error,
    output reg                          bank_collision_error,
    output reg                          row_overwrite_error,
    output reg                          protocol_error,
    output reg  [31:0]                  accepted_beats,
    output reg  [31:0]                  accepted_bytes,
    output reg  [31:0]                  emitted_entries,
    output reg  [31:0]                  axis_stall_cycles,
    output reg  [31:0]                  entry_stall_cycles,
    output reg  [31:0]                  materialize_cycles
);
    localparam integer ROW_BANKS = 4;
    localparam integer STORE_LANES = 4;
    localparam integer PHASE_LANES = 2;
    localparam integer RESP_DEPTH = 4;
    localparam integer RESP_AW = 2;
    localparam integer LINE_AW =
        (LINE_BANK_DEPTH <= 2) ? 1 : $clog2(LINE_BANK_DEPTH);

    initial begin
        if (ROWS != 18)
            $error("packed-row materializer requires ROWS=18");
        if (AXIS_W != 64 || KEEP_W != 8)
            $error("packed-row materializer requires 64-bit AXIS");
        if (LINE_BANK_DEPTH != (1 << LINE_AW))
            $error("LINE_BANK_DEPTH must be a power of two");
    end

    function [7:0] center_ifm_byte;
        input [7:0] raw_u8;
        input [7:0] zero_point;
        reg signed [9:0] centered;
        begin
            centered = $signed({2'b00, raw_u8}) -
                       $signed({2'b00, zero_point});
            if (centered > 10'sd127)
                center_ifm_byte = 8'h7f;
            else if (centered < -10'sd128)
                center_ifm_byte = 8'h80;
            else
                center_ifm_byte = centered[7:0];
        end
    endfunction

    function [15:0] convolution_output_dim;
        input [15:0] input_dim;
        input kernel_1x1;
        input [1:0] stride;
        input [1:0] pad;
        integer extent;
        begin
            extent = input_dim + (pad << 1) -
                     (kernel_1x1 ? 1 : 3);
            if (extent < 0 || (stride != 1 && stride != 2))
                convolution_output_dim = 16'd0;
            else if (stride == 1)
                convolution_output_dim = extent + 1;
            else
                convolution_output_dim = (extent >> 1) + 1;
        end
    endfunction

    function [16:0] stride_position;
        input [15:0] coordinate;
        input [1:0] stride;
        begin
            // Legal descriptors use stride 1 or 2.  Spell the operation as a
            // mux/shift so address control never consumes a DSP multiplier.
            stride_position = (stride == 2) ?
                {coordinate, 1'b0} : {1'b0, coordinate};
        end
    endfunction

    function [3:0] row_read_mask;
        input [15:0] output_y;
        input kernel_1x1;
        input [1:0] stride;
        input [1:0] pad;
        input [15:0] fm_h;
        integer row_k;
        integer input_y;
        reg [3:0] mask;
        begin
            mask = 4'd0;
            if (kernel_1x1) begin
                input_y = stride_position(output_y, stride) - pad;
                if (input_y >= 0 && input_y < fm_h)
                    mask[input_y & 3] = 1'b1;
            end else begin
                for (row_k = 0; row_k < 3; row_k = row_k + 1) begin
                    input_y = stride_position(output_y, stride) +
                              row_k - pad;
                    if (input_y >= 0 && input_y < fm_h)
                        mask[input_y & 3] = 1'b1;
                end
            end
            row_read_mask = mask;
        end
    endfunction

    reg busy_q;
    reg [15:0] fm_h_q;
    reg [15:0] fm_w_q;
    reg [13:0] cin_q;
    reg [15:0] ofm_h_q;
    reg [15:0] ofm_w_q;
    reg kernel_1x1_q;
    reg [1:0] stride_q;
    reg [1:0] pad_q;
    reg [7:0] input_zero_point_q;
    reg [EPOCH_W-1:0] epoch_q;
    reg [15:0] x_pairs_q;
    reg [15:0] channel_groups_q;
    reg [15:0] pass_count_q;
    reg [31:0] expected_bytes_q;
    // Logical bytes still admissible into the write pipeline.  This mirrors
    // expected_bytes_q - accepted_bytes before input closes, but keeping the
    // value registered prevents the 32-bit subtract from feeding FIFO payload
    // D pins on every accepted AXIS beat.
    reg [31:0] logical_remaining_q;

    assign busy = busy_q;
    assign pass_ready_epoch = epoch_q;
    assign m_entry_epoch = epoch_q;
    reg [MAX_PASSES-1:0] pass_ready_bitmap_q;
    assign pass_ready_bitmap = (ENABLE_PASS_READY_BITMAP != 0) ?
        pass_ready_bitmap_q : {MAX_PASSES{1'b0}};

    // ------------------------------------------------------------------
    // Raw-HWC input cursor and four-byte half-beat unpacker
    // ------------------------------------------------------------------
    reg [15:0] wr_y_q;
    reg [15:0] wr_x_q;
    reg [13:0] wr_ch_q;
    reg wr_x_odd_q;
    reg [15:0] wr_x_pair_q;
    reg [1:0] wr_ch_mod_q;
    reg [15:0] wr_ch_group_q;
    reg [LINE_AW-1:0] wr_word_addr_q;
    reg [31:0] stored_bytes_q;
    // The visible write cursor is committed only with the M3 memory write.
    // M1 advances this shadow cursor when the two-phase four-byte micro-op
    // issues, allowing M2/M3 to drain independently of visible commit state.
    reg [15:0] spec_wr_y_q;
    reg [15:0] spec_wr_x_q;
    reg [13:0] spec_wr_ch_q;
    reg spec_wr_x_odd_q;
    reg [15:0] spec_wr_x_pair_q;
    reg [1:0] spec_wr_ch_mod_q;
    reg [15:0] spec_wr_ch_group_q;
    reg [LINE_AW-1:0] spec_wr_word_addr_q;
    reg [31:0] spec_stored_bytes_q;
    // Two accepted AXIS beats are buffered independently of the four-byte
    // materializer issue path.  Only the lifetime bits/pointers are reset;
    // stale payload bits are unobservable while their valid bit is clear.
    reg [1:0] beat_fifo_valid_q;
    reg [63:0] beat_fifo_data_q [0:1];
    reg [7:0] beat_fifo_keep_q [0:1];
    reg [7:0] beat_fifo_end_q [0:1];
    reg beat_fifo_rd_ptr_q;
    reg beat_fifo_wr_ptr_q;
    reg beat_fifo_upper_q;
    reg accept_closed_q;
    // Registered four-byte source slice.  It removes the LUTRAM read mux and
    // FIFO pointer from the cursor mapper while retaining the original
    // low-half/high-half retirement semantics.  A resident source may be
    // replaced on the same edge that phase A consumes it.
    reg s0_valid_q;
    reg [31:0] s0_data_q;
    reg [3:0] s0_keep_q;
    reg [3:0] s0_end_q;
    reg s0_finishes_beat_q;
    reg s0_upper_q;
    // A four-byte half-beat can touch three packed words for odd Cin at an
    // odd-pixel boundary.  Commit the first two fragments and retain the
    // remaining byte suffix here; this is the one-entry fragment queue that
    // keeps both TDP ports bounded; the rare third fragment replays before the
    // following registered source is allowed to map.
    reg defer_valid_q;
    reg [31:0] defer_data_q;
    reg [3:0] defer_keep_q;
    reg [3:0] defer_end_q;
    reg defer_finishes_beat_q;

    // M0 is the first half of the deliberately two-phase mapper.  Phase A
    // maps bytes 0..1 and registers the midpoint cursor; phase B maps bytes
    // 2..3 and assembles the unchanged four-lane elastic M1 payload.  The
    // source and M0 never bypass each other, so the feedback cursor crosses
    // at most two byte transitions in one clock.
    reg m0_valid_q;
    reg [31:0] m0_data_q;
    reg [3:0] m0_keep_q;
    reg [3:0] m0_end_q;
    reg [15:0] m0_lane_y_q [0:PHASE_LANES-1];
    reg [15:0] m0_lane_x_q [0:PHASE_LANES-1];
    reg [13:0] m0_lane_ch_q [0:PHASE_LANES-1];
    reg [1:0] m0_lane_row_bank_q [0:PHASE_LANES-1];
    reg [LINE_AW-1:0] m0_lane_addr_q [0:PHASE_LANES-1];
    reg [2:0] m0_lane_byte_q [0:PHASE_LANES-1];
    reg [15:0] m0_mid_wr_y_q;
    reg [15:0] m0_mid_wr_x_q;
    reg [13:0] m0_mid_wr_ch_q;
    reg m0_mid_wr_x_odd_q;
    reg [15:0] m0_mid_wr_x_pair_q;
    reg [1:0] m0_mid_wr_ch_mod_q;
    reg [15:0] m0_mid_wr_ch_group_q;
    reg [LINE_AW-1:0] m0_mid_wr_word_addr_q;
    reg m0_source_finishes_beat_q;
    reg m0_source_from_defer_q;

    reg loaded_any_q;
    reg [15:0] loaded_through_y_q;
    reg [ROW_BANKS-1:0] row_valid_q;
    reg [15:0] row_tag_q [0:ROW_BANKS-1];
    // Row ownership is also shadowed at M1.  Otherwise a first byte from the
    // next rolling-row epoch could observe the old M3 tag for two clocks and
    // falsely report overwrite while the preceding row completion is still
    // in flight.
    reg [ROW_BANKS-1:0] spec_row_valid_q;
    reg [15:0] spec_row_tag_q [0:ROW_BANKS-1];
    reg row_completed_wait_q;
    reg row_start_check_pending_q;
    reg row_boundary_pending_q;
    reg row_drain_quiet_q;
    reg finish_pending_q;
    wire m1_row_event;

    // ------------------------------------------------------------------
    // Current output-row issue cursor
    // ------------------------------------------------------------------
    reg mat_active_q;
    reg [15:0] mat_oy_q;
    reg [15:0] mat_x_q;
    reg [15:0] mat_pass_q;
    reg [13:0] mat_base_ch_q;
    reg [1:0] mat_base_ch_mod_q;
    reg [LINE_AW-1:0] mat_word_base_addr_q;
    // Read addressing keeps the current clamped spatial pair and its sum
    // with the pass base registered.  mat_x_q therefore cannot traverse
    // stride/pad arithmetic and the read-port mux on its way to URAM ADDR.
    reg [LINE_AW-1:0] mat_read_first_pair_q;
    reg [LINE_AW:0] mat_read_word_addr_q;
    reg [31:0] mat_row_base_pixel_q;
    reg [15:0] next_oy_q;
    // Registered lower row bound for the M1 overwrite check.  It changes
    // only when next_oy changes, so rebuilding stride*next_oy-pad in the late
    // elastic-admission cone is unnecessary and fans that row cursor into
    // every S0/M1 payload clock enable.
    reg [15:0] m1_min_needed_y_q;
    reg all_issued_q;

    // Exact recurrence of max(0, (x * stride - pad) >> 1) for the supported
    // stride={1,2}, pad={0,1} configuration space.  It is sampled only when
    // mat_x advances; pass and row transitions explicitly restart at zero.
    wire mat_read_first_pair_inc = (stride_q == 2'd2) ?
        ((pad_q == 2'd0) || (|mat_x_q)) :
        ((pad_q == 2'd0) ? mat_x_q[0] :
         ((|mat_x_q) && !mat_x_q[0]));
    wire [LINE_AW-1:0] mat_three_next_word_base =
        mat_word_base_addr_q + x_pairs_q;
    wire [LINE_AW-1:0] mat_one_next_word_base_mod0 =
        mat_word_base_addr_q + (x_pairs_q << 2);
    wire [LINE_AW-1:0] mat_one_next_word_base_mod2 =
        mat_word_base_addr_q + (x_pairs_q << 2) + x_pairs_q;

    function output_row_ready;
        input [15:0] oy;
        input [15:0] loaded_y;
        input loaded_any;
        input all_input_done;
        integer max_fy;
        begin
            if (kernel_1x1_q)
                max_fy = stride_position(oy, stride_q) - pad_q;
            else
                max_fy = stride_position(oy, stride_q) + 2 - pad_q;
            if (max_fy < 0)
                output_row_ready = 1'b1;
            else if (max_fy >= fm_h_q)
                output_row_ready = all_input_done;
            else
                output_row_ready = loaded_any && loaded_y >= max_fy;
        end
    endfunction

    // Active rows are read through both ports.  Register the four-bit lock
    // exactly when an output row becomes active and retain it until every
    // response from that row drains.  The writer therefore sees only a local
    // bank-lock bit; output-coordinate arithmetic cannot reach URAM write
    // enable/data paths.
    reg [ROW_BANKS-1:0] active_read_rows_q;
    wire [ROW_BANKS-1:0] active_read_rows = active_read_rows_q;

    // AXIS admission consumes only registered FIFO credit.  Row overlap and
    // boundary policy are deliberately confined to the FIFO issue side so
    // neither payload nor cursor arithmetic can reach s_axis_tready.
    wire beat_fifo_empty = !(|beat_fifo_valid_q);
    wire beat_fifo_full = &beat_fifo_valid_q;
    wire beat_fifo_head_valid =
        beat_fifo_valid_q[beat_fifo_rd_ptr_q];
    wire [63:0] beat_fifo_head_data =
        beat_fifo_data_q[beat_fifo_rd_ptr_q];
    wire [7:0] beat_fifo_head_keep =
        beat_fifo_keep_q[beat_fifo_rd_ptr_q];
    wire [7:0] beat_fifo_head_end =
        beat_fifo_end_q[beat_fifo_rd_ptr_q];
    assign s_axis_tready = busy_q && !accept_closed_q && !beat_fifo_full;
    wire axis_fire = s_axis_tvalid && s_axis_tready;
    // Once a pending row check has observed a fully quiet cycle, freeze the
    // mapper stages for one clock so the following admission is atomic.  S0
    // may continue to prefetch because it owns no cursor or write bundle.
    wire drain_issue_freeze = row_start_check_pending_q &&
                              row_drain_quiet_q;
    wire phase_a_from_defer;
    wire phase_a_from_s0;
    wire phase_a_load;
    wire map_load;
    wire m1_ready_for_load;
    wire m1_issue;
    wire s0_ready_for_load = !s0_valid_q || phase_a_from_s0;
    wire source_slice_load = beat_fifo_head_valid && s0_ready_for_load;
    wire [31:0] source_slice_data = beat_fifo_upper_q ?
        beat_fifo_head_data[63:32] : beat_fifo_head_data[31:0];
    wire [3:0] source_slice_keep = beat_fifo_upper_q ?
        beat_fifo_head_keep[7:4] : beat_fifo_head_keep[3:0];
    wire [3:0] source_slice_end = beat_fifo_upper_q ?
        beat_fifo_head_end[7:4] : beat_fifo_head_end[3:0];
    wire source_slice_finishes_beat = beat_fifo_upper_q ||
                                      !(|beat_fifo_head_keep[7:4]);
    wire beat_fifo_pop = source_slice_load &&
                         source_slice_finishes_beat;

    reg [4:0] axis_keep_count_comb;
    reg [3:0] axis_clipped_count_comb;
    reg [KEEP_W-1:0] axis_clipped_keep_comb;
    reg [KEEP_W-1:0] axis_logical_end_comb;
    wire [3:0] axis_admit_limit =
        (|logical_remaining_q[31:3]) ? 4'd8 :
        {1'b0, logical_remaining_q[2:0]};
    wire axis_logical_end_in_beat =
        !(|logical_remaining_q[31:4]) &&
        logical_remaining_q[3:0] <= 4'd8;
    reg keep_prefix_comb;
    reg seen_keep_zero;
    integer keep_i;
    always @* begin
        axis_keep_count_comb = 5'd0;
        axis_clipped_count_comb = 4'd0;
        axis_clipped_keep_comb = {KEEP_W{1'b0}};
        axis_logical_end_comb = {KEEP_W{1'b0}};
        keep_prefix_comb = 1'b1;
        seen_keep_zero = 1'b0;
        for (keep_i = 0; keep_i < KEEP_W; keep_i = keep_i + 1) begin
            if (s_axis_tkeep[keep_i]) begin
                axis_keep_count_comb = axis_keep_count_comb + 1'b1;
                // Preserve raw TKEEP telemetry/error semantics above the
                // FIFO, but admit only the first remaining logical bytes to
                // the writer.  Non-prefix TKEEP is still clipped in set-bit
                // order exactly as the former lane_map_valid count guard.
                if (axis_clipped_count_comb < axis_admit_limit) begin
                    axis_clipped_keep_comb[keep_i] = 1'b1;
                    axis_clipped_count_comb =
                        axis_clipped_count_comb + 1'b1;
                    if (axis_logical_end_in_beat &&
                        axis_clipped_count_comb == axis_admit_limit)
                        axis_logical_end_comb[keep_i] = 1'b1;
                end
                if (seen_keep_zero)
                    keep_prefix_comb = 1'b0;
            end else begin
                seen_keep_zero = 1'b1;
            end
        end
    end

    wire [31:0] accepted_post_bytes =
        accepted_bytes + axis_keep_count_comb;
    // axis_keep_count_comb is at most eight.  Collapse a larger registered
    // remainder to a single high bit so protocol classification uses only a
    // small comparator and cannot recreate the old expected-minus-accepted
    // path into the FIFO keep/end payload.
    wire logical_remaining_ge16 = |logical_remaining_q[31:4];
    wire [4:0] logical_remaining_low =
        {1'b0, logical_remaining_q[3:0]};
    wire axis_beat_exact = !logical_remaining_ge16 &&
        axis_keep_count_comb == logical_remaining_low;
    wire axis_beat_short = logical_remaining_ge16 ||
        axis_keep_count_comb < logical_remaining_low;
    wire axis_beat_overlong = !logical_remaining_ge16 &&
        axis_keep_count_comb > logical_remaining_low;
    wire beat_finishes_input = axis_beat_exact;

    // ------------------------------------------------------------------
    // Two-phase dense-HWC cursor mapper.
    // ------------------------------------------------------------------
    // Payload selection must depend only on registered source lifetime.  The
    // late M1 defer decision controls M0 validity, not the wide/arithmetic M0
    // payload cone.
    wire [31:0] phase_a_data = defer_valid_q ?
        defer_data_q : s0_data_q;
    wire [3:0] phase_a_keep = defer_valid_q ?
        defer_keep_q : s0_keep_q;
    wire [3:0] phase_a_end = defer_valid_q ?
        defer_end_q : s0_end_q;
    wire phase_a_finishes_beat = defer_valid_q ?
        defer_finishes_beat_q : s0_finishes_beat_q;

    reg [15:0] phase_a_lane_y [0:PHASE_LANES-1];
    reg [15:0] phase_a_lane_x [0:PHASE_LANES-1];
    reg [13:0] phase_a_lane_ch [0:PHASE_LANES-1];
    reg [1:0] phase_a_lane_row_bank [0:PHASE_LANES-1];
    reg [LINE_AW-1:0] phase_a_lane_addr [0:PHASE_LANES-1];
    reg [2:0] phase_a_lane_byte [0:PHASE_LANES-1];
    reg [15:0] phase_a_mid_wr_y;
    reg [15:0] phase_a_mid_wr_x;
    reg [13:0] phase_a_mid_wr_ch;
    reg phase_a_mid_wr_x_odd;
    reg [15:0] phase_a_mid_wr_x_pair;
    reg [1:0] phase_a_mid_wr_ch_mod;
    reg [15:0] phase_a_mid_wr_ch_group;
    reg [LINE_AW-1:0] phase_a_mid_wr_word_addr;
    integer phase_a_i;
    integer phase_a_tmp_y;
    integer phase_a_tmp_x;
    integer phase_a_tmp_ch;
    integer phase_a_tmp_x_odd;
    integer phase_a_tmp_x_pair;
    integer phase_a_tmp_ch_mod;
    integer phase_a_tmp_ch_group;
    integer phase_a_tmp_word_addr;
    always @* begin
        phase_a_tmp_y = spec_wr_y_q;
        phase_a_tmp_x = spec_wr_x_q;
        phase_a_tmp_ch = spec_wr_ch_q;
        phase_a_tmp_x_odd = spec_wr_x_odd_q;
        phase_a_tmp_x_pair = spec_wr_x_pair_q;
        phase_a_tmp_ch_mod = spec_wr_ch_mod_q;
        phase_a_tmp_ch_group = spec_wr_ch_group_q;
        phase_a_tmp_word_addr = spec_wr_word_addr_q;
        for (phase_a_i = 0; phase_a_i < PHASE_LANES;
             phase_a_i = phase_a_i + 1) begin
            phase_a_lane_y[phase_a_i] = phase_a_tmp_y[15:0];
            phase_a_lane_x[phase_a_i] = phase_a_tmp_x[15:0];
            phase_a_lane_ch[phase_a_i] = phase_a_tmp_ch[13:0];
            phase_a_lane_row_bank[phase_a_i] = phase_a_tmp_y[1:0];
            phase_a_lane_addr[phase_a_i] =
                phase_a_tmp_word_addr[LINE_AW-1:0];
            phase_a_lane_byte[phase_a_i] = {
                phase_a_tmp_x_odd[0], phase_a_tmp_ch_mod[1:0]};
            if (phase_a_keep[phase_a_i]) begin
                if (phase_a_tmp_ch + 1 == cin_q) begin
                    phase_a_tmp_ch = 0;
                    phase_a_tmp_ch_mod = 0;
                    phase_a_tmp_ch_group = 0;
                    if (phase_a_tmp_x + 1 == fm_w_q) begin
                        phase_a_tmp_x = 0;
                        phase_a_tmp_x_odd = 0;
                        phase_a_tmp_x_pair = 0;
                        phase_a_tmp_y = phase_a_tmp_y + 1;
                    end else begin
                        phase_a_tmp_x = phase_a_tmp_x + 1;
                        if (phase_a_tmp_x_odd) begin
                            phase_a_tmp_x_odd = 0;
                            phase_a_tmp_x_pair = phase_a_tmp_x_pair + 1;
                        end else begin
                            phase_a_tmp_x_odd = 1;
                        end
                    end
                    phase_a_tmp_word_addr = phase_a_tmp_x_pair;
                end else begin
                    phase_a_tmp_ch = phase_a_tmp_ch + 1;
                    if (phase_a_tmp_ch_mod == 3) begin
                        phase_a_tmp_ch_mod = 0;
                        phase_a_tmp_ch_group = phase_a_tmp_ch_group + 1;
                        phase_a_tmp_word_addr =
                            phase_a_tmp_word_addr + x_pairs_q;
                    end else begin
                        phase_a_tmp_ch_mod = phase_a_tmp_ch_mod + 1;
                    end
                end
            end
        end
        phase_a_mid_wr_y = phase_a_tmp_y[15:0];
        phase_a_mid_wr_x = phase_a_tmp_x[15:0];
        phase_a_mid_wr_ch = phase_a_tmp_ch[13:0];
        phase_a_mid_wr_x_odd = phase_a_tmp_x_odd[0];
        phase_a_mid_wr_x_pair = phase_a_tmp_x_pair[15:0];
        phase_a_mid_wr_ch_mod = phase_a_tmp_ch_mod[1:0];
        phase_a_mid_wr_ch_group = phase_a_tmp_ch_group[15:0];
        phase_a_mid_wr_word_addr =
            phase_a_tmp_word_addr[LINE_AW-1:0];
    end

    // Phase B starts only from M0 registers and assembles the original
    // four-lane mapped payload consumed by elastic M1.
    reg [15:0] lane_y [0:STORE_LANES-1];
    reg [15:0] lane_x [0:STORE_LANES-1];
    reg [13:0] lane_ch [0:STORE_LANES-1];
    reg [1:0] lane_row_bank [0:STORE_LANES-1];
    reg [LINE_AW-1:0] lane_addr [0:STORE_LANES-1];
    reg [2:0] lane_byte [0:STORE_LANES-1];
    reg [STORE_LANES-1:0] lane_map_valid;
    reg [15:0] mapped_post_wr_y;
    reg [15:0] mapped_post_wr_x;
    reg [13:0] mapped_post_wr_ch;
    reg mapped_post_wr_x_odd;
    reg [15:0] mapped_post_wr_x_pair;
    reg [1:0] mapped_post_wr_ch_mod;
    reg [15:0] mapped_post_wr_ch_group;
    reg [LINE_AW-1:0] mapped_post_wr_word_addr;

    integer phase_b_i;
    integer phase_b_tmp_y;
    integer phase_b_tmp_x;
    integer phase_b_tmp_ch;
    integer phase_b_tmp_x_odd;
    integer phase_b_tmp_x_pair;
    integer phase_b_tmp_ch_mod;
    integer phase_b_tmp_ch_group;
    integer phase_b_tmp_word_addr;
    always @* begin
        for (phase_b_i = 0; phase_b_i < PHASE_LANES;
             phase_b_i = phase_b_i + 1) begin
            lane_y[phase_b_i] = m0_lane_y_q[phase_b_i];
            lane_x[phase_b_i] = m0_lane_x_q[phase_b_i];
            lane_ch[phase_b_i] = m0_lane_ch_q[phase_b_i];
            lane_row_bank[phase_b_i] =
                m0_lane_row_bank_q[phase_b_i];
            lane_addr[phase_b_i] = m0_lane_addr_q[phase_b_i];
            lane_byte[phase_b_i] = m0_lane_byte_q[phase_b_i];
            lane_map_valid[phase_b_i] = m0_keep_q[phase_b_i];
        end
        phase_b_tmp_y = m0_mid_wr_y_q;
        phase_b_tmp_x = m0_mid_wr_x_q;
        phase_b_tmp_ch = m0_mid_wr_ch_q;
        phase_b_tmp_x_odd = m0_mid_wr_x_odd_q;
        phase_b_tmp_x_pair = m0_mid_wr_x_pair_q;
        phase_b_tmp_ch_mod = m0_mid_wr_ch_mod_q;
        phase_b_tmp_ch_group = m0_mid_wr_ch_group_q;
        phase_b_tmp_word_addr = m0_mid_wr_word_addr_q;
        for (phase_b_i = PHASE_LANES; phase_b_i < STORE_LANES;
             phase_b_i = phase_b_i + 1) begin
            lane_y[phase_b_i] = phase_b_tmp_y[15:0];
            lane_x[phase_b_i] = phase_b_tmp_x[15:0];
            lane_ch[phase_b_i] = phase_b_tmp_ch[13:0];
            lane_row_bank[phase_b_i] = phase_b_tmp_y[1:0];
            lane_addr[phase_b_i] =
                phase_b_tmp_word_addr[LINE_AW-1:0];
            lane_byte[phase_b_i] = {
                phase_b_tmp_x_odd[0], phase_b_tmp_ch_mod[1:0]};
            lane_map_valid[phase_b_i] = m0_keep_q[phase_b_i];
            if (m0_keep_q[phase_b_i]) begin
                if (phase_b_tmp_ch + 1 == cin_q) begin
                    phase_b_tmp_ch = 0;
                    phase_b_tmp_ch_mod = 0;
                    phase_b_tmp_ch_group = 0;
                    if (phase_b_tmp_x + 1 == fm_w_q) begin
                        phase_b_tmp_x = 0;
                        phase_b_tmp_x_odd = 0;
                        phase_b_tmp_x_pair = 0;
                        phase_b_tmp_y = phase_b_tmp_y + 1;
                    end else begin
                        phase_b_tmp_x = phase_b_tmp_x + 1;
                        if (phase_b_tmp_x_odd) begin
                            phase_b_tmp_x_odd = 0;
                            phase_b_tmp_x_pair = phase_b_tmp_x_pair + 1;
                        end else begin
                            phase_b_tmp_x_odd = 1;
                        end
                    end
                    phase_b_tmp_word_addr = phase_b_tmp_x_pair;
                end else begin
                    phase_b_tmp_ch = phase_b_tmp_ch + 1;
                    if (phase_b_tmp_ch_mod == 3) begin
                        phase_b_tmp_ch_mod = 0;
                        phase_b_tmp_ch_group = phase_b_tmp_ch_group + 1;
                        phase_b_tmp_word_addr =
                            phase_b_tmp_word_addr + x_pairs_q;
                    end else begin
                        phase_b_tmp_ch_mod = phase_b_tmp_ch_mod + 1;
                    end
                end
            end
        end
        mapped_post_wr_y = phase_b_tmp_y[15:0];
        mapped_post_wr_x = phase_b_tmp_x[15:0];
        mapped_post_wr_ch = phase_b_tmp_ch[13:0];
        mapped_post_wr_x_odd = phase_b_tmp_x_odd[0];
        mapped_post_wr_x_pair = phase_b_tmp_x_pair[15:0];
        mapped_post_wr_ch_mod = phase_b_tmp_ch_mod[1:0];
        mapped_post_wr_ch_group = phase_b_tmp_ch_group[15:0];
        mapped_post_wr_word_addr =
            phase_b_tmp_word_addr[LINE_AW-1:0];
    end

    // Admission has two parts: a static description of the mapped four-byte
    // item and hazards that may change while an elastic M1 item is held.  Form
    // the small static description at the M1 entrance.  The registered copy
    // below prevents M1 payload/address arithmetic from feeding every M1
    // payload clock enable, while active reader ownership and speculative row
    // tags are still checked afresh on every resident-M1 cycle.
    wire [STORE_LANES-1:0] load_lane_addr_ok = {
        ((CFG_PREVALIDATED != 0) ||
         (lane_addr[3] < LINE_BANK_DEPTH)),
        ((CFG_PREVALIDATED != 0) ||
         (lane_addr[2] < LINE_BANK_DEPTH)),
        ((CFG_PREVALIDATED != 0) ||
         (lane_addr[1] < LINE_BANK_DEPTH)),
        ((CFG_PREVALIDATED != 0) ||
         (lane_addr[0] < LINE_BANK_DEPTH))
    };
    wire [STORE_LANES-1:0] load_lane_mem_candidate =
        lane_map_valid & load_lane_addr_ok;
    wire load_row_eq_01 = lane_row_bank[0] == lane_row_bank[1];
    wire load_row_eq_02 = lane_row_bank[0] == lane_row_bank[2];
    wire load_row_eq_03 = lane_row_bank[0] == lane_row_bank[3];
    wire load_row_eq_12 = lane_row_bank[1] == lane_row_bank[2];
    wire load_row_eq_13 = lane_row_bank[1] == lane_row_bank[3];
    wire load_row_eq_23 = lane_row_bank[2] == lane_row_bank[3];
    wire load_addr_eq_01 = lane_addr[0] == lane_addr[1];
    wire load_addr_eq_02 = lane_addr[0] == lane_addr[2];
    wire load_addr_eq_03 = lane_addr[0] == lane_addr[3];
    wire load_addr_eq_12 = lane_addr[1] == lane_addr[2];
    wire load_addr_eq_13 = lane_addr[1] == lane_addr[3];
    wire load_addr_eq_23 = lane_addr[2] == lane_addr[3];
    wire load_defer_at_lane2 = load_lane_mem_candidate[0] &&
        load_lane_mem_candidate[1] && load_lane_mem_candidate[2] &&
        load_row_eq_01 && load_row_eq_02 &&
        !load_addr_eq_01 && !load_addr_eq_02 && !load_addr_eq_12;
    wire load_lane3_third_after_01 = load_lane_mem_candidate[0] &&
        load_lane_mem_candidate[1] && load_lane_mem_candidate[3] &&
        load_row_eq_01 && load_row_eq_03 &&
        !load_addr_eq_01 && !load_addr_eq_03 && !load_addr_eq_13;
    wire load_lane3_third_after_02 = load_lane_mem_candidate[0] &&
        load_lane_mem_candidate[2] && load_lane_mem_candidate[3] &&
        load_row_eq_02 && load_row_eq_03 &&
        !load_addr_eq_02 && !load_addr_eq_03 && !load_addr_eq_23;
    wire load_lane3_third_after_12 = load_lane_mem_candidate[1] &&
        load_lane_mem_candidate[2] && load_lane_mem_candidate[3] &&
        load_row_eq_12 && load_row_eq_13 &&
        !load_addr_eq_12 && !load_addr_eq_13 && !load_addr_eq_23;
    wire load_defer_at_lane3 = !load_defer_at_lane2 &&
        (load_lane3_third_after_01 || load_lane3_third_after_02 ||
         load_lane3_third_after_12);
    wire load_defer_required = load_defer_at_lane2 ||
                               load_defer_at_lane3;
    wire [STORE_LANES-1:0] load_lane_commit_valid = {
        (lane_map_valid[3] && !load_defer_required),
        (lane_map_valid[2] && !load_defer_at_lane2),
        lane_map_valid[1],
        lane_map_valid[0]
    };
    wire [ROW_BANKS-1:0] load_lane_row_oh_0 =
        4'b0001 << lane_row_bank[0];
    wire [ROW_BANKS-1:0] load_lane_row_oh_1 =
        4'b0001 << lane_row_bank[1];
    wire [ROW_BANKS-1:0] load_lane_row_oh_2 =
        4'b0001 << lane_row_bank[2];
    wire [ROW_BANKS-1:0] load_lane_row_oh_3 =
        4'b0001 << lane_row_bank[3];
    wire [STORE_LANES-1:0] load_lane_row_start = {
        (load_lane_commit_valid[3] && lane_x[3] == 0 && lane_ch[3] == 0),
        (load_lane_commit_valid[2] && lane_x[2] == 0 && lane_ch[2] == 0),
        (load_lane_commit_valid[1] && lane_x[1] == 0 && lane_ch[1] == 0),
        (load_lane_commit_valid[0] && lane_x[0] == 0 && lane_ch[0] == 0)
    };
    wire [ROW_BANKS-1:0] load_write_row_mask =
        ({ROW_BANKS{load_lane_commit_valid[0]}} & load_lane_row_oh_0) |
        ({ROW_BANKS{load_lane_commit_valid[1]}} & load_lane_row_oh_1) |
        ({ROW_BANKS{load_lane_commit_valid[2]}} & load_lane_row_oh_2) |
        ({ROW_BANKS{load_lane_commit_valid[3]}} & load_lane_row_oh_3);
    wire [ROW_BANKS-1:0] load_row_start_mask =
        ({ROW_BANKS{load_lane_row_start[0]}} & load_lane_row_oh_0) |
        ({ROW_BANKS{load_lane_row_start[1]}} & load_lane_row_oh_1) |
        ({ROW_BANKS{load_lane_row_start[2]}} & load_lane_row_oh_2) |
        ({ROW_BANKS{load_lane_row_start[3]}} & load_lane_row_oh_3);
    // A lane completed its row exactly when the registered mapper cursor for
    // the following lane has advanced Y.  This is equivalent to repeating
    // the Cin/FmW terminal comparisons in M1, but keeps those wide compares
    // out of the compact entrance summary.
    wire [STORE_LANES-1:0] load_lane_row_complete = {
        (load_lane_commit_valid[3] &&
         mapped_post_wr_y != lane_y[3]),
        (load_lane_commit_valid[2] && lane_y[3] != lane_y[2]),
        (load_lane_commit_valid[1] && lane_y[2] != lane_y[1]),
        (load_lane_commit_valid[0] && lane_y[1] != lane_y[0])
    };
    wire [ROW_BANKS-1:0] load_commit_row_mask =
        ({ROW_BANKS{load_lane_row_complete[0]}} & load_lane_row_oh_0) |
        ({ROW_BANKS{load_lane_row_complete[1]}} & load_lane_row_oh_1) |
        ({ROW_BANKS{load_lane_row_complete[2]}} & load_lane_row_oh_2) |
        ({ROW_BANKS{load_lane_row_complete[3]}} & load_lane_row_oh_3);
    wire load_commit_row_completed = |load_lane_row_complete;
    reg [15:0] load_row_start_y [0:ROW_BANKS-1];
    integer load_admit_row;
    always @* begin
        for (load_admit_row = 0; load_admit_row < ROW_BANKS;
             load_admit_row = load_admit_row + 1) begin
            if (load_lane_row_start[3] &&
                load_lane_row_oh_3[load_admit_row])
                load_row_start_y[load_admit_row] = lane_y[3];
            else if (load_lane_row_start[2] &&
                     load_lane_row_oh_2[load_admit_row])
                load_row_start_y[load_admit_row] = lane_y[2];
            else if (load_lane_row_start[1] &&
                     load_lane_row_oh_1[load_admit_row])
                load_row_start_y[load_admit_row] = lane_y[1];
            else if (load_lane_row_start[0] &&
                     load_lane_row_oh_0[load_admit_row])
                load_row_start_y[load_admit_row] = lane_y[0];
            else
                load_row_start_y[load_admit_row] = 16'd0;
        end
    end

    // A row boundary may occur in the low half of a beat.  A registered M1 row
    // event blocks the following low half before row_boundary_pending_q is
    // committed; an upper half remains eligible and preserves beat throughput.
    wire fifo_boundary_issue_ok = s0_upper_q ||
        (!m1_row_event && !row_boundary_pending_q &&
         !row_start_check_pending_q);
    assign map_load = m0_valid_q && m1_ready_for_load &&
                      !drain_issue_freeze;

    // M1 payload registers are deliberately not reset.  m1_valid_q is the
    // sole lifetime bit, reducing reset fanout and control-set pressure.
    reg m1_valid_q;
    reg [31:0] m1_data_q;
    reg [STORE_LANES-1:0] m1_lane_valid_q;
    reg [15:0] m1_lane_y_q [0:STORE_LANES-1];
    reg [15:0] m1_lane_x_q [0:STORE_LANES-1];
    reg [13:0] m1_lane_ch_q [0:STORE_LANES-1];
    reg [1:0] m1_lane_row_bank_q [0:STORE_LANES-1];
    reg [LINE_AW-1:0] m1_lane_addr_q [0:STORE_LANES-1];
    reg [2:0] m1_lane_byte_q [0:STORE_LANES-1];
    reg [STORE_LANES-1:0] m1_end_q;
    reg [15:0] m1_post_wr_y_q;
    reg [15:0] m1_post_wr_x_q;
    reg [13:0] m1_post_wr_ch_q;
    reg m1_post_wr_x_odd_q;
    reg [15:0] m1_post_wr_x_pair_q;
    reg [1:0] m1_post_wr_ch_mod_q;
    reg [15:0] m1_post_wr_ch_group_q;
    reg [LINE_AW-1:0] m1_post_wr_word_addr_q;
    reg m1_source_finishes_beat_q;
    reg m1_source_from_defer_q;
    // Only this compact admission summary is duplicated at the M1 entrance.
    // It is lifetime-qualified by m1_valid_q and, like the payload, need not
    // be reset.  The complete write/defer plan remains the direct bounded
    // pairwise implementation below.
    reg m1_admit_defer_required_q;
    reg [ROW_BANKS-1:0] m1_admit_write_row_mask_q;
    reg [ROW_BANKS-1:0] m1_admit_row_start_mask_q;
    reg [15:0] m1_admit_row_start_y_q [0:ROW_BANKS-1];
    reg m1_admit_commit_row_completed_q;
    reg [ROW_BANKS-1:0] m1_admit_commit_row_mask_q;

    // The complete Phase-B cursor/payload is first captured in elastic M1.
    // Planning then runs from those stable registers and is consumed directly
    // by M2.  This is a retime across the existing M1 boundary, not another
    // pipeline stage: a normal M1 issue still launches the following Phase A
    // on the same edge and therefore retains the two-clock issue interval.
    //
    // Four lanes can exceed the two-fragment-per-row write budget first at
    // lane 2 or lane 3 only.  Express that bounded ordered decision with
    // pairwise row/address predicates instead of a variable-indexed serial
    // prefix walk.  Invalid and validation-failed lanes retain the historical
    // cursor-commit semantics but do not occupy a memory fragment.
    wire [STORE_LANES-1:0] m1_lane_addr_ok = {
        ((CFG_PREVALIDATED != 0) ||
         (m1_lane_addr_q[3] < LINE_BANK_DEPTH)),
        ((CFG_PREVALIDATED != 0) ||
         (m1_lane_addr_q[2] < LINE_BANK_DEPTH)),
        ((CFG_PREVALIDATED != 0) ||
         (m1_lane_addr_q[1] < LINE_BANK_DEPTH)),
        ((CFG_PREVALIDATED != 0) ||
         (m1_lane_addr_q[0] < LINE_BANK_DEPTH))
    };
    wire [STORE_LANES-1:0] m1_lane_mem_candidate =
        m1_lane_valid_q & m1_lane_addr_ok;

    wire m1_row_eq_01 = m1_lane_row_bank_q[0] ==
                        m1_lane_row_bank_q[1];
    wire m1_row_eq_02 = m1_lane_row_bank_q[0] ==
                        m1_lane_row_bank_q[2];
    wire m1_row_eq_03 = m1_lane_row_bank_q[0] ==
                        m1_lane_row_bank_q[3];
    wire m1_row_eq_12 = m1_lane_row_bank_q[1] ==
                        m1_lane_row_bank_q[2];
    wire m1_row_eq_13 = m1_lane_row_bank_q[1] ==
                        m1_lane_row_bank_q[3];
    wire m1_row_eq_23 = m1_lane_row_bank_q[2] ==
                        m1_lane_row_bank_q[3];
    wire m1_addr_eq_01 = m1_lane_addr_q[0] == m1_lane_addr_q[1];
    wire m1_addr_eq_02 = m1_lane_addr_q[0] == m1_lane_addr_q[2];
    wire m1_addr_eq_03 = m1_lane_addr_q[0] == m1_lane_addr_q[3];
    wire m1_addr_eq_12 = m1_lane_addr_q[1] == m1_lane_addr_q[2];
    wire m1_addr_eq_13 = m1_lane_addr_q[1] == m1_lane_addr_q[3];
    wire m1_addr_eq_23 = m1_lane_addr_q[2] == m1_lane_addr_q[3];

    wire m1_defer_at_lane2 = m1_lane_mem_candidate[0] &&
        m1_lane_mem_candidate[1] && m1_lane_mem_candidate[2] &&
        m1_row_eq_01 && m1_row_eq_02 &&
        !m1_addr_eq_01 && !m1_addr_eq_02 && !m1_addr_eq_12;
    wire m1_lane3_third_after_01 = m1_lane_mem_candidate[0] &&
        m1_lane_mem_candidate[1] && m1_lane_mem_candidate[3] &&
        m1_row_eq_01 && m1_row_eq_03 &&
        !m1_addr_eq_01 && !m1_addr_eq_03 && !m1_addr_eq_13;
    wire m1_lane3_third_after_02 = m1_lane_mem_candidate[0] &&
        m1_lane_mem_candidate[2] && m1_lane_mem_candidate[3] &&
        m1_row_eq_02 && m1_row_eq_03 &&
        !m1_addr_eq_02 && !m1_addr_eq_03 && !m1_addr_eq_23;
    wire m1_lane3_third_after_12 = m1_lane_mem_candidate[1] &&
        m1_lane_mem_candidate[2] && m1_lane_mem_candidate[3] &&
        m1_row_eq_12 && m1_row_eq_13 &&
        !m1_addr_eq_12 && !m1_addr_eq_13 && !m1_addr_eq_23;
    wire m1_defer_at_lane3 = !m1_defer_at_lane2 &&
        (m1_lane3_third_after_01 || m1_lane3_third_after_02 ||
         m1_lane3_third_after_12);

    reg [STORE_LANES-1:0] m1_lane_commit_valid_comb;
    reg [STORE_LANES-1:0] m1_lane_mem_write_comb;
    reg [STORE_LANES-1:0] m1_lane_port_b_comb;
    reg [ROW_BANKS-1:0] m1_lane_row_oh_comb [0:STORE_LANES-1];
    reg m1_defer_required_comb;
    reg [31:0] m1_defer_data_comb;
    reg [3:0] m1_defer_keep_comb;
    reg [3:0] m1_defer_end_comb;
    reg m1_bank_addr_overflow_comb;
    reg m1_bank_collision_comb;
    reg [15:0] m1_commit_post_wr_y_comb;
    reg [15:0] m1_commit_post_wr_x_comb;
    reg [13:0] m1_commit_post_wr_ch_comb;
    reg m1_commit_post_wr_x_odd_comb;
    reg [15:0] m1_commit_post_wr_x_pair_comb;
    reg [1:0] m1_commit_post_wr_ch_mod_comb;
    reg [15:0] m1_commit_post_wr_ch_group_comb;
    reg [LINE_AW-1:0] m1_commit_post_wr_word_addr_comb;
    reg [2:0] m1_committed_inc_comb;
    reg m1_finish_token_comb;
    reg m1_store_finishes_beat_comb;
    reg [ROW_BANKS-1:0] m1_write_row_mask_comb;
    reg [ROW_BANKS-1:0] m1_row_start_mask_comb;
    reg [15:0] m1_row_start_y_comb [0:ROW_BANKS-1];
    reg m1_commit_row_completed_comb;
    reg [15:0] m1_commit_last_completed_y_comb;
    reg [ROW_BANKS-1:0] m1_commit_row_mask_comb;
    reg [15:0] m1_commit_row_y_comb [0:ROW_BANKS-1];
    reg [STORE_LANES-1:0] m1_lane_row_start_comb;
    reg [STORE_LANES-1:0] m1_lane_row_complete_comb;
    integer m1_plan_row;
    always @* begin
        m1_lane_row_oh_comb[0] = 4'b0001 << m1_lane_row_bank_q[0];
        m1_lane_row_oh_comb[1] = 4'b0001 << m1_lane_row_bank_q[1];
        m1_lane_row_oh_comb[2] = 4'b0001 << m1_lane_row_bank_q[2];
        m1_lane_row_oh_comb[3] = 4'b0001 << m1_lane_row_bank_q[3];

        m1_defer_required_comb = m1_defer_at_lane2 || m1_defer_at_lane3;
        m1_lane_commit_valid_comb[0] = m1_lane_valid_q[0];
        m1_lane_commit_valid_comb[1] = m1_lane_valid_q[1];
        m1_lane_commit_valid_comb[2] = m1_lane_valid_q[2] &&
                                           !m1_defer_at_lane2;
        m1_lane_commit_valid_comb[3] = m1_lane_valid_q[3] &&
                                           !m1_defer_required_comb;
        m1_lane_mem_write_comb = m1_lane_commit_valid_comb &
                                 m1_lane_addr_ok;

        // Port A owns the first memory-eligible address for a row.  Any
        // committed different address uses B; the third-address predicates
        // above ensure that no other case reaches M2.
        m1_lane_port_b_comb = 4'b0000;
        m1_lane_port_b_comb[1] = m1_lane_mem_candidate[1] &&
            m1_lane_mem_candidate[0] && m1_row_eq_01 && !m1_addr_eq_01;
        m1_lane_port_b_comb[2] = m1_lane_mem_candidate[2] &&
            !m1_defer_at_lane2 &&
            ((m1_lane_mem_candidate[0] && m1_row_eq_02 &&
              !m1_addr_eq_02) ||
             ((!m1_lane_mem_candidate[0] || !m1_row_eq_02) &&
              m1_lane_mem_candidate[1] && m1_row_eq_12 &&
              !m1_addr_eq_12));
        m1_lane_port_b_comb[3] = m1_lane_mem_candidate[3] &&
            !m1_defer_required_comb &&
            ((m1_lane_mem_candidate[0] && m1_row_eq_03 &&
              !m1_addr_eq_03) ||
             ((!m1_lane_mem_candidate[0] || !m1_row_eq_03) &&
              m1_lane_mem_candidate[1] && m1_row_eq_13 &&
              !m1_addr_eq_13) ||
             ((!m1_lane_mem_candidate[0] || !m1_row_eq_03) &&
              (!m1_lane_mem_candidate[1] || !m1_row_eq_13) &&
              m1_lane_mem_candidate[2] && m1_row_eq_23 &&
              !m1_addr_eq_23));

        m1_defer_data_comb = 32'd0;
        m1_defer_keep_comb = 4'd0;
        m1_defer_end_comb = 4'd0;
        if (m1_defer_at_lane2) begin
            m1_defer_data_comb[7:0] = m1_data_q[23:16];
            m1_defer_keep_comb[0] = 1'b1;
            m1_defer_end_comb[0] = m1_end_q[2];
            if (m1_lane_valid_q[3]) begin
                m1_defer_data_comb[15:8] = m1_data_q[31:24];
                m1_defer_keep_comb[1] = 1'b1;
                m1_defer_end_comb[1] = m1_end_q[3];
            end
        end else if (m1_defer_at_lane3) begin
            m1_defer_data_comb[7:0] = m1_data_q[31:24];
            m1_defer_keep_comb[0] = 1'b1;
            m1_defer_end_comb[0] = m1_end_q[3];
        end

        m1_commit_post_wr_y_comb = m1_post_wr_y_q;
        m1_commit_post_wr_x_comb = m1_post_wr_x_q;
        m1_commit_post_wr_ch_comb = m1_post_wr_ch_q;
        m1_commit_post_wr_x_odd_comb = m1_post_wr_x_odd_q;
        m1_commit_post_wr_x_pair_comb = m1_post_wr_x_pair_q;
        m1_commit_post_wr_ch_mod_comb = m1_post_wr_ch_mod_q;
        m1_commit_post_wr_ch_group_comb = m1_post_wr_ch_group_q;
        m1_commit_post_wr_word_addr_comb = m1_post_wr_word_addr_q;
        if (m1_defer_at_lane2) begin
            m1_commit_post_wr_y_comb = m1_lane_y_q[2];
            m1_commit_post_wr_x_comb = m1_lane_x_q[2];
            m1_commit_post_wr_ch_comb = m1_lane_ch_q[2];
            m1_commit_post_wr_x_odd_comb = m1_lane_x_q[2][0];
            m1_commit_post_wr_x_pair_comb = m1_lane_x_q[2] >> 1;
            m1_commit_post_wr_ch_mod_comb = m1_lane_ch_q[2][1:0];
            m1_commit_post_wr_ch_group_comb = m1_lane_ch_q[2] >> 2;
            m1_commit_post_wr_word_addr_comb = m1_lane_addr_q[2];
        end else if (m1_defer_at_lane3) begin
            m1_commit_post_wr_y_comb = m1_lane_y_q[3];
            m1_commit_post_wr_x_comb = m1_lane_x_q[3];
            m1_commit_post_wr_ch_comb = m1_lane_ch_q[3];
            m1_commit_post_wr_x_odd_comb = m1_lane_x_q[3][0];
            m1_commit_post_wr_x_pair_comb = m1_lane_x_q[3] >> 1;
            m1_commit_post_wr_ch_mod_comb = m1_lane_ch_q[3][1:0];
            m1_commit_post_wr_ch_group_comb = m1_lane_ch_q[3] >> 2;
            m1_commit_post_wr_word_addr_comb = m1_lane_addr_q[3];
        end

        m1_committed_inc_comb =
            {2'b00, m1_lane_commit_valid_comb[0]} +
            {2'b00, m1_lane_commit_valid_comb[1]} +
            {2'b00, m1_lane_commit_valid_comb[2]} +
            {2'b00, m1_lane_commit_valid_comb[3]};
        m1_finish_token_comb =
            |(m1_end_q & m1_lane_commit_valid_comb);
        m1_store_finishes_beat_comb = m1_source_finishes_beat_q &&
                                      !m1_admit_defer_required_q;
        m1_bank_addr_overflow_comb =
            |(m1_lane_commit_valid_comb & ~m1_lane_addr_ok);
        m1_bank_collision_comb = m1_admit_defer_required_q &&
                                 m1_source_from_defer_q;

        m1_lane_row_start_comb[0] = m1_lane_commit_valid_comb[0] &&
            m1_lane_x_q[0] == 0 && m1_lane_ch_q[0] == 0;
        m1_lane_row_start_comb[1] = m1_lane_commit_valid_comb[1] &&
            m1_lane_x_q[1] == 0 && m1_lane_ch_q[1] == 0;
        m1_lane_row_start_comb[2] = m1_lane_commit_valid_comb[2] &&
            m1_lane_x_q[2] == 0 && m1_lane_ch_q[2] == 0;
        m1_lane_row_start_comb[3] = m1_lane_commit_valid_comb[3] &&
            m1_lane_x_q[3] == 0 && m1_lane_ch_q[3] == 0;
        m1_lane_row_complete_comb[0] = m1_lane_commit_valid_comb[0] &&
            (m1_lane_ch_q[0] + 1'b1 == cin_q) &&
            (m1_lane_x_q[0] + 1'b1 == fm_w_q);
        m1_lane_row_complete_comb[1] = m1_lane_commit_valid_comb[1] &&
            (m1_lane_ch_q[1] + 1'b1 == cin_q) &&
            (m1_lane_x_q[1] + 1'b1 == fm_w_q);
        m1_lane_row_complete_comb[2] = m1_lane_commit_valid_comb[2] &&
            (m1_lane_ch_q[2] + 1'b1 == cin_q) &&
            (m1_lane_x_q[2] + 1'b1 == fm_w_q);
        m1_lane_row_complete_comb[3] = m1_lane_commit_valid_comb[3] &&
            (m1_lane_ch_q[3] + 1'b1 == cin_q) &&
            (m1_lane_x_q[3] + 1'b1 == fm_w_q);

        m1_write_row_mask_comb =
            ({ROW_BANKS{m1_lane_commit_valid_comb[0]}} &
             m1_lane_row_oh_comb[0]) |
            ({ROW_BANKS{m1_lane_commit_valid_comb[1]}} &
             m1_lane_row_oh_comb[1]) |
            ({ROW_BANKS{m1_lane_commit_valid_comb[2]}} &
             m1_lane_row_oh_comb[2]) |
            ({ROW_BANKS{m1_lane_commit_valid_comb[3]}} &
             m1_lane_row_oh_comb[3]);
        m1_row_start_mask_comb =
            ({ROW_BANKS{m1_lane_row_start_comb[0]}} &
             m1_lane_row_oh_comb[0]) |
            ({ROW_BANKS{m1_lane_row_start_comb[1]}} &
             m1_lane_row_oh_comb[1]) |
            ({ROW_BANKS{m1_lane_row_start_comb[2]}} &
             m1_lane_row_oh_comb[2]) |
            ({ROW_BANKS{m1_lane_row_start_comb[3]}} &
             m1_lane_row_oh_comb[3]);
        m1_commit_row_mask_comb =
            ({ROW_BANKS{m1_lane_row_complete_comb[0]}} &
             m1_lane_row_oh_comb[0]) |
            ({ROW_BANKS{m1_lane_row_complete_comb[1]}} &
             m1_lane_row_oh_comb[1]) |
            ({ROW_BANKS{m1_lane_row_complete_comb[2]}} &
             m1_lane_row_oh_comb[2]) |
            ({ROW_BANKS{m1_lane_row_complete_comb[3]}} &
             m1_lane_row_oh_comb[3]);
        m1_commit_row_completed_comb = |m1_lane_row_complete_comb;
        if (m1_lane_row_complete_comb[3])
            m1_commit_last_completed_y_comb = m1_lane_y_q[3];
        else if (m1_lane_row_complete_comb[2])
            m1_commit_last_completed_y_comb = m1_lane_y_q[2];
        else if (m1_lane_row_complete_comb[1])
            m1_commit_last_completed_y_comb = m1_lane_y_q[1];
        else if (m1_lane_row_complete_comb[0])
            m1_commit_last_completed_y_comb = m1_lane_y_q[0];
        else
            m1_commit_last_completed_y_comb = 16'd0;

        // The old increasing-lane loop overwrote per-row Y metadata with the
        // latest lane.  Preserve that priority explicitly while evaluating
        // each row independently.
        for (m1_plan_row = 0; m1_plan_row < ROW_BANKS;
             m1_plan_row = m1_plan_row + 1) begin
            if (m1_lane_row_start_comb[3] &&
                m1_lane_row_oh_comb[3][m1_plan_row])
                m1_row_start_y_comb[m1_plan_row] = m1_lane_y_q[3];
            else if (m1_lane_row_start_comb[2] &&
                     m1_lane_row_oh_comb[2][m1_plan_row])
                m1_row_start_y_comb[m1_plan_row] = m1_lane_y_q[2];
            else if (m1_lane_row_start_comb[1] &&
                     m1_lane_row_oh_comb[1][m1_plan_row])
                m1_row_start_y_comb[m1_plan_row] = m1_lane_y_q[1];
            else if (m1_lane_row_start_comb[0] &&
                     m1_lane_row_oh_comb[0][m1_plan_row])
                m1_row_start_y_comb[m1_plan_row] = m1_lane_y_q[0];
            else
                m1_row_start_y_comb[m1_plan_row] = 16'd0;

            if (m1_lane_row_complete_comb[3] &&
                m1_lane_row_oh_comb[3][m1_plan_row])
                m1_commit_row_y_comb[m1_plan_row] = m1_lane_y_q[3];
            else if (m1_lane_row_complete_comb[2] &&
                     m1_lane_row_oh_comb[2][m1_plan_row])
                m1_commit_row_y_comb[m1_plan_row] = m1_lane_y_q[2];
            else if (m1_lane_row_complete_comb[1] &&
                     m1_lane_row_oh_comb[1][m1_plan_row])
                m1_commit_row_y_comb[m1_plan_row] = m1_lane_y_q[1];
            else if (m1_lane_row_complete_comb[0] &&
                     m1_lane_row_oh_comb[0][m1_plan_row])
                m1_commit_row_y_comb[m1_plan_row] = m1_lane_y_q[0];
            else
                m1_commit_row_y_comb[m1_plan_row] = 16'd0;
        end
    end

    reg m1_overwrite_comb;
    integer m1_dynamic_row;
    always @* begin
        m1_overwrite_comb = 1'b0;
        for (m1_dynamic_row = 0; m1_dynamic_row < ROW_BANKS;
             m1_dynamic_row = m1_dynamic_row + 1)
            if (m1_admit_row_start_mask_q[m1_dynamic_row] &&
                spec_row_valid_q[m1_dynamic_row] &&
                spec_row_tag_q[m1_dynamic_row] !=
                    m1_admit_row_start_y_q[m1_dynamic_row] &&
                spec_row_tag_q[m1_dynamic_row] >= m1_min_needed_y_q)
                m1_overwrite_comb = 1'b1;
    end

    wire m1_mapped_write_safe =
        !(|(m1_admit_write_row_mask_q & active_read_rows));
    // During the atomic row-admission cycle M1 is deliberately held.  A
    // blocked elastic item is not yet a write bundle; admitting the reader is
    // what allows its rolling-row overwrite hazard to retire.  Freezing M1
    // here prevents that held item from becoming M2 in the same cycle that
    // active_read_rows_q is replaced.
    assign m1_issue = m1_valid_q && !drain_issue_freeze &&
                      m1_mapped_write_safe && !m1_overwrite_comb;
    assign m1_ready_for_load = !m1_valid_q ||
        (m1_issue && !m1_admit_defer_required_q);
    // Phase A may start behind an existing M1 only when that M1 retires
    // normally on this edge.  In particular it must not speculate behind a
    // held item or an item whose late decode rolls the cursor back for defer.
    wire phase_a_m1_safe = !m1_valid_q ||
        (m1_issue && !m1_admit_defer_required_q);
    assign phase_a_from_defer = !m0_valid_q && phase_a_m1_safe &&
        !drain_issue_freeze && defer_valid_q;
    assign phase_a_from_s0 = !m0_valid_q && phase_a_m1_safe &&
        !drain_issue_freeze && !defer_valid_q && s0_valid_q &&
        fifo_boundary_issue_ok;
    assign phase_a_load = phase_a_from_defer || phase_a_from_s0;

    // ------------------------------------------------------------------
    // M2: create and register a complete two-port write bundle for all four
    // rows and derive row/frame metadata from the registered M1 mapping.
    // Active-row conflicts are sampled here.  Read admission waits for M2,
    // the first stage that represents an irrevocably issued write bundle;
    // an unsafe M1 remains elastic and retries against the new reader state.
    // ------------------------------------------------------------------
    reg [ROW_BANKS-1:0] m2_row_wr_a_en_comb;
    reg [ROW_BANKS-1:0] m2_row_wr_b_en_comb;
    reg [LINE_AW-1:0] m2_row_wr_a_addr_comb [0:ROW_BANKS-1];
    reg [LINE_AW-1:0] m2_row_wr_b_addr_comb [0:ROW_BANKS-1];
    reg [7:0] m2_row_wr_a_we_comb [0:ROW_BANKS-1];
    reg [7:0] m2_row_wr_b_we_comb [0:ROW_BANKS-1];
    reg [63:0] m2_row_wr_a_data_comb [0:ROW_BANKS-1];
    reg [63:0] m2_row_wr_b_data_comb [0:ROW_BANKS-1];
    reg m2_bank_collision_comb;
    reg m2_write_read_conflict_comb;
    integer m2_i;
    integer m2_row_i;
    integer m2_frag_byte;
    always @* begin
        m2_row_wr_a_en_comb = {ROW_BANKS{1'b0}};
        m2_row_wr_b_en_comb = {ROW_BANKS{1'b0}};
        m2_bank_collision_comb = 1'b0;
        m2_write_read_conflict_comb =
            |(m1_admit_write_row_mask_q & active_read_rows);
        for (m2_row_i = 0; m2_row_i < ROW_BANKS;
             m2_row_i = m2_row_i + 1) begin
            m2_row_wr_a_addr_comb[m2_row_i] = {LINE_AW{1'b0}};
            m2_row_wr_b_addr_comb[m2_row_i] = {LINE_AW{1'b0}};
            m2_row_wr_a_we_comb[m2_row_i] = 8'd0;
            m2_row_wr_b_we_comb[m2_row_i] = 8'd0;
            m2_row_wr_a_data_comb[m2_row_i] = 64'd0;
            m2_row_wr_b_data_comb[m2_row_i] = 64'd0;
        end
        for (m2_i = 0; m2_i < STORE_LANES; m2_i = m2_i + 1) begin
            m2_frag_byte = m1_lane_byte_q[m2_i];
            for (m2_row_i = 0; m2_row_i < ROW_BANKS;
                 m2_row_i = m2_row_i + 1) begin
                if (m1_lane_mem_write_comb[m2_i] &&
                    m1_lane_row_oh_comb[m2_i][m2_row_i]) begin
                    if (m1_lane_port_b_comb[m2_i]) begin
                        m2_row_wr_b_en_comb[m2_row_i] = 1'b1;
                        m2_row_wr_b_addr_comb[m2_row_i] =
                            m1_lane_addr_q[m2_i];
                        m2_row_wr_b_we_comb[m2_row_i][m2_frag_byte] = 1'b1;
                        m2_row_wr_b_data_comb[m2_row_i]
                            [m2_frag_byte*8 +: 8] = center_ifm_byte(
                                m1_data_q[m2_i*8 +: 8], input_zero_point_q);
                    end else begin
                        m2_row_wr_a_en_comb[m2_row_i] = 1'b1;
                        m2_row_wr_a_addr_comb[m2_row_i] =
                            m1_lane_addr_q[m2_i];
                        m2_row_wr_a_we_comb[m2_row_i][m2_frag_byte] = 1'b1;
                        m2_row_wr_a_data_comb[m2_row_i]
                            [m2_frag_byte*8 +: 8] = center_ifm_byte(
                                m1_data_q[m2_i*8 +: 8], input_zero_point_q);
                    end
                end
            end
        end
    end

    assign m1_row_event = m1_issue &&
                          m1_admit_commit_row_completed_q;

    // As in M1, only m2_valid_q is reset; stale bundle bits are unobservable.
    reg m2_valid_q;
    reg [ROW_BANKS-1:0] m2_row_wr_a_en_q;
    reg [ROW_BANKS-1:0] m2_row_wr_b_en_q;
    reg [LINE_AW-1:0] m2_row_wr_a_addr_q [0:ROW_BANKS-1];
    reg [LINE_AW-1:0] m2_row_wr_b_addr_q [0:ROW_BANKS-1];
    reg [7:0] m2_row_wr_a_we_q [0:ROW_BANKS-1];
    reg [7:0] m2_row_wr_b_we_q [0:ROW_BANKS-1];
    reg [63:0] m2_row_wr_a_data_q [0:ROW_BANKS-1];
    reg [63:0] m2_row_wr_b_data_q [0:ROW_BANKS-1];
    reg [31:0] m2_stored_post_bytes_q;
    reg [15:0] m2_post_wr_y_q;
    reg [15:0] m2_post_wr_x_q;
    reg [13:0] m2_post_wr_ch_q;
    reg m2_post_wr_x_odd_q;
    reg [15:0] m2_post_wr_x_pair_q;
    reg [1:0] m2_post_wr_ch_mod_q;
    reg [15:0] m2_post_wr_ch_group_q;
    reg [LINE_AW-1:0] m2_post_wr_word_addr_q;
    reg m2_store_finishes_input_q;
    reg m2_store_finishes_beat_q;
    reg m2_bank_addr_overflow_q;
    reg m2_bank_collision_q;
    reg m2_write_read_conflict_q;
    reg m2_overwrite_q;
    reg m2_commit_row_completed_q;
    reg [15:0] m2_commit_last_completed_y_q;
    reg [ROW_BANKS-1:0] m2_commit_row_mask_q;
    reg [15:0] m2_commit_row_y_q [0:ROW_BANKS-1];

    // Two-phase row admission cuts issue/mapping arithmetic out of the reader
    // control cone.  The first pending cycle may issue once; the next edge
    // raises row_drain_quiet_q unconditionally and freezes both registered
    // sources plus M1 issue.  Admission then waits only for M2, the already
    // issued bundle.  An unissued upper/defer or blocked elastic M1 may remain
    // queued and retry after the reader decision, so it cannot create a
    // circular drain/overwrite dependency.  Finish drain remains stricter:
    // every source and both pipeline stages must commit before completion.
    wire row_write_pipe_drained = row_drain_quiet_q && !m2_valid_q;
    wire finish_write_pipe_drained = !s0_valid_q && !defer_valid_q &&
                                     !m0_valid_q && !m1_valid_q &&
                                     !m2_valid_q;

    integer row_i;

    // ------------------------------------------------------------------
    // 3x3 address generation: two packed words from each of three rows.
    // ------------------------------------------------------------------
    reg [LINE_AW-1:0] three_addr_a [0:ROW_BANKS-1];
    reg [LINE_AW-1:0] three_addr_b [0:ROW_BANKS-1];
    reg [1:0] three_row_bank [0:2];
    reg [2:0] three_row_valid;
    reg [8:0] three_mem_valid;
    reg [8:0] three_use_b;
    reg [2:0] three_byte0 [0:8];
    reg [2:0] three_byte1 [0:8];
    reg [ROWS-1:0] three_lane_valid;
    reg three_read_overflow;
    reg three_row_missing;
    integer ky_i;
    integer kx_i;
    integer tap_i;
    integer fy_i;
    integer fx_i;
    integer base_fx_i;
    integer first_pair_i;
    integer addr_a_i;
    integer addr_b_i;
    integer ch0_i;
    integer ch1_i;
    integer row_bank_i;
    always @* begin
        // Both rows in a packed 3x3 read use the same spatial pair.  Broadcast
        // that raw registered address to every bank; row/tag/spatial validity
        // controls only descriptor consumption, never a live URAM ADDR pin.
        addr_a_i = mat_read_word_addr_q;
        addr_b_i = addr_a_i + 1;
        for (row_i = 0; row_i < ROW_BANKS; row_i = row_i + 1) begin
            three_addr_a[row_i] = addr_a_i[LINE_AW-1:0];
            three_addr_b[row_i] = addr_b_i[LINE_AW-1:0];
        end
        for (ky_i = 0; ky_i < 3; ky_i = ky_i + 1)
            three_row_bank[ky_i] = 2'd0;
        for (tap_i = 0; tap_i < 9; tap_i = tap_i + 1) begin
            three_byte0[tap_i] = 3'd0;
            three_byte1[tap_i] = 3'd0;
        end
        three_row_valid = 3'd0;
        three_mem_valid = 9'd0;
        three_use_b = 9'd0;
        three_lane_valid = {ROWS{1'b0}};
        three_read_overflow = 1'b0;
        three_row_missing = 1'b0;

        ch0_i = mat_base_ch_q;
        ch1_i = ch0_i + 1;
        if (ch0_i < cin_q)
            three_lane_valid[8:0] = 9'h1ff;
        if (ch1_i < cin_q)
            three_lane_valid[17:9] = 9'h1ff;
        base_fx_i = stride_position(mat_x_q, stride_q) - pad_q;
        first_pair_i = mat_read_first_pair_q;

        for (ky_i = 0; ky_i < 3; ky_i = ky_i + 1) begin
            fy_i = stride_position(mat_oy_q, stride_q) + ky_i - pad_q;
            if (fy_i >= 0 && fy_i < fm_h_q) begin
                row_bank_i = fy_i & 3;
                three_row_bank[ky_i] = row_bank_i[1:0];
                if (row_valid_q[row_bank_i] &&
                    row_tag_q[row_bank_i] == fy_i) begin
                    three_row_valid[ky_i] = 1'b1;
                    if (addr_a_i >= LINE_BANK_DEPTH)
                        three_read_overflow = 1'b1;
                    if (first_pair_i + 1 < x_pairs_q &&
                        addr_b_i >= LINE_BANK_DEPTH)
                        three_read_overflow = 1'b1;
                end else begin
                    three_row_missing = 1'b1;
                end
            end

            for (kx_i = 0; kx_i < 3; kx_i = kx_i + 1) begin
                tap_i = ky_i * 3 + kx_i;
                fx_i = base_fx_i + kx_i;
                three_byte0[tap_i] = {fx_i[0], ch0_i[1:0]};
                three_byte1[tap_i] = {fx_i[0], ch1_i[1:0]};
                if (fy_i >= 0 && fy_i < fm_h_q &&
                    fx_i >= 0 && fx_i < fm_w_q &&
                    three_row_valid[ky_i]) begin
                    three_mem_valid[tap_i] = 1'b1;
                    three_use_b[tap_i] = (fx_i >> 1) != first_pair_i;
                end
            end
        end
    end

    // Two-cycle memory-latency descriptor pipeline.
    reg three_d0_valid_q;
    reg three_d1_valid_q;
    reg [1:0] three_d0_row_bank [0:2];
    reg [1:0] three_d1_row_bank [0:2];
    reg [2:0] three_d0_row_valid;
    reg [2:0] three_d1_row_valid;
    reg [8:0] three_d0_mem_valid;
    reg [8:0] three_d1_mem_valid;
    reg [8:0] three_d0_use_b;
    reg [8:0] three_d1_use_b;
    reg [2:0] three_d0_byte0 [0:8];
    reg [2:0] three_d1_byte0 [0:8];
    reg [2:0] three_d0_byte1 [0:8];
    reg [2:0] three_d1_byte1 [0:8];
    reg [ROWS-1:0] three_d0_lane_valid;
    reg [ROWS-1:0] three_d1_lane_valid;
    reg [31:0] three_d0_pixel;
    reg [31:0] three_d1_pixel;
    reg [15:0] three_d0_pass;
    reg [15:0] three_d1_pass;
    reg [15:0] three_d0_oy;
    reg [15:0] three_d1_oy;
    reg [15:0] three_d0_x;
    reg [15:0] three_d1_x;
    reg three_d0_last;
    reg three_d1_last;

    // ------------------------------------------------------------------
    // Native 1x1 uses three groups, two aligned channel words per group.
    // Six 32-bit pixel fragments cover every 18-channel vector, including
    // base-channel mod-4 == 2 passes.
    // ------------------------------------------------------------------
    reg one_active_q;
    reg [1:0] one_issue_group_q;
    reg [1:0] one_base_mod_q;
    reg [ROWS-1:0] one_lane_valid_q;
    reg one_spatial_valid_q;
    reg [31:0] one_pixel_q;
    reg [15:0] one_pass_q;
    reg [15:0] one_oy_q;
    reg [15:0] one_x_q;
    reg one_last_q;
    reg [31:0] one_chunk_q [0:3];

    reg [LINE_AW-1:0] one_addr_a [0:ROW_BANKS-1];
    reg [LINE_AW-1:0] one_addr_b [0:ROW_BANKS-1];
    reg [1:0] one_issue_row_bank;
    reg one_issue_spatial_valid;
    reg one_issue_word_a_valid;
    reg one_issue_word_b_valid;
    reg one_issue_x_odd;
    reg one_read_overflow;
    reg one_row_missing;
    integer one_fy_i;
    integer one_fx_i;
    integer one_x_pair_i;
    integer one_base_group_i;
    integer one_group_a_i;
    integer one_group_b_i;
    integer one_group_offset_i;
    integer one_addr_i;
    integer one_raw_addr_a_i;
    integer one_raw_addr_b_i;
    integer one_lane_i;
    always @* begin
        for (row_i = 0; row_i < ROW_BANKS; row_i = row_i + 1) begin
            one_addr_a[row_i] = {LINE_AW{1'b0}};
            one_addr_b[row_i] = {LINE_AW{1'b0}};
        end
        one_issue_row_bank = 2'd0;
        one_issue_spatial_valid = 1'b0;
        one_issue_word_a_valid = 1'b0;
        one_issue_word_b_valid = 1'b0;
        one_issue_x_odd = 1'b0;
        one_read_overflow = 1'b0;
        one_row_missing = 1'b0;

        one_fy_i = stride_position(mat_oy_q, stride_q) - pad_q;
        one_fx_i = stride_position(mat_x_q, stride_q) - pad_q;
        one_x_pair_i = mat_read_first_pair_q;
        one_base_group_i = mat_base_ch_q >> 2;
        one_group_a_i = one_base_group_i + (one_issue_group_q << 1);
        one_group_b_i = one_group_a_i + 1;
        case (one_issue_group_q)
            2'd1: one_group_offset_i = x_pairs_q << 1;
            2'd2: one_group_offset_i = x_pairs_q << 2;
            default: one_group_offset_i = 0;
        endcase
        // Native 1x1 likewise reads the same two group words from every row
        // bank.  Broadcast raw addresses; validity below controls capture.
        one_raw_addr_a_i = mat_read_word_addr_q + one_group_offset_i;
        one_raw_addr_b_i = one_raw_addr_a_i + x_pairs_q;
        for (row_i = 0; row_i < ROW_BANKS; row_i = row_i + 1) begin
            one_addr_a[row_i] = one_raw_addr_a_i[LINE_AW-1:0];
            one_addr_b[row_i] = one_raw_addr_b_i[LINE_AW-1:0];
        end

        if (one_fy_i >= 0 && one_fy_i < fm_h_q &&
            one_fx_i >= 0 && one_fx_i < fm_w_q) begin
            one_issue_row_bank = one_fy_i[1:0];
            one_issue_x_odd = one_fx_i[0];
            if (row_valid_q[one_fy_i & 3] &&
                row_tag_q[one_fy_i & 3] == one_fy_i) begin
                one_issue_spatial_valid = 1'b1;
                one_addr_i = one_raw_addr_a_i;
                if (one_group_a_i < channel_groups_q &&
                    one_addr_i < LINE_BANK_DEPTH)
                    one_issue_word_a_valid = 1'b1;
                else if (one_group_a_i < channel_groups_q)
                    one_read_overflow = 1'b1;
                one_addr_i = one_raw_addr_b_i;
                if (one_group_b_i < channel_groups_q &&
                    one_addr_i < LINE_BANK_DEPTH)
                    one_issue_word_b_valid = 1'b1;
                else if (one_group_b_i < channel_groups_q)
                    one_read_overflow = 1'b1;
            end else begin
                one_row_missing = 1'b1;
            end
        end
    end

    reg one_d0_valid_q;
    reg one_d1_valid_q;
    reg [1:0] one_d0_group;
    reg [1:0] one_d1_group;
    reg [1:0] one_d0_row_bank;
    reg [1:0] one_d1_row_bank;
    reg one_d0_spatial_valid;
    reg one_d1_spatial_valid;
    reg one_d0_word_a_valid;
    reg one_d1_word_a_valid;
    reg one_d0_word_b_valid;
    reg one_d1_word_b_valid;
    reg one_d0_x_odd;
    reg one_d1_x_odd;

    // ------------------------------------------------------------------
    // Four row stores and their local port selection
    // ------------------------------------------------------------------
    reg [LINE_AW-1:0] read_addr_a [0:ROW_BANKS-1];
    reg [LINE_AW-1:0] read_addr_b [0:ROW_BANKS-1];
    wire [63:0] row_a_rdata [0:ROW_BANKS-1];
    wire [63:0] row_b_rdata [0:ROW_BANKS-1];

    // Response FIFO gives the two-cycle read pipeline enough credit to stop
    // cleanly under arbitrary downstream backpressure.
    // These slots have synchronous writes, asynchronous reads and no reset;
    // forcing distributed RAM removes almost one thousand resettable FFs.
    // Validity is carried solely by resp_count_q, so stale slot contents are
    // never observable after reset or a new descriptor.
    (* ram_style = "distributed" *)
    reg [ROWS*8-1:0] resp_data_q [0:RESP_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [ROWS-1:0] resp_lane_valid_q [0:RESP_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [31:0] resp_pixel_q [0:RESP_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [15:0] resp_pass_q [0:RESP_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [15:0] resp_oy_q [0:RESP_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [15:0] resp_x_q [0:RESP_DEPTH-1];
    (* ram_style = "distributed" *)
    reg resp_last_q [0:RESP_DEPTH-1];
    reg [RESP_AW-1:0] resp_wr_ptr_q;
    reg [RESP_AW-1:0] resp_rd_ptr_q;
    reg [2:0] resp_count_q;

    assign m_entry_valid = resp_count_q != 0;
    assign m_entry_data = resp_data_q[resp_rd_ptr_q];
    assign m_entry_lane_valid = resp_lane_valid_q[resp_rd_ptr_q];
    assign m_entry_pixel = resp_pixel_q[resp_rd_ptr_q];
    assign m_entry_k_pass = resp_pass_q[resp_rd_ptr_q];
    assign m_entry_last = resp_last_q[resp_rd_ptr_q];
    wire out_fire = m_entry_valid && m_entry_ready;

    wire [3:0] reserved_entries = resp_count_q +
        three_d0_valid_q + three_d1_valid_q + one_active_q;
    wire response_credit = reserved_entries < RESP_DEPTH || out_fire;
    wire issue_three = mat_active_q && !kernel_1x1_q && !all_issued_q &&
                       response_credit;
    wire issue_one = mat_active_q && kernel_1x1_q && !all_issued_q &&
        ((!one_active_q && response_credit) ||
         (one_active_q && one_issue_group_q < 3));

    integer read_sel_i;
    always @* begin
        for (read_sel_i = 0; read_sel_i < ROW_BANKS;
             read_sel_i = read_sel_i + 1) begin
            // URAM read ports are always enabled.  Feed them raw, registered-
            // base addresses selected only by the registered kernel mode;
            // issue and spatial/row validity remain descriptor metadata.
            if (kernel_1x1_q) begin
                read_addr_a[read_sel_i] = one_addr_a[read_sel_i];
                read_addr_b[read_sel_i] = one_addr_b[read_sel_i];
            end else begin
                read_addr_a[read_sel_i] = three_addr_a[read_sel_i];
                read_addr_b[read_sel_i] = three_addr_b[read_sel_i];
            end
        end
    end

    genvar storage_row;
    generate
        for (storage_row = 0; storage_row < ROW_BANKS;
             storage_row = storage_row + 1) begin : row_stores
            wire write_a = m2_valid_q && m2_row_wr_a_en_q[storage_row];
            wire write_b = m2_valid_q && m2_row_wr_b_en_q[storage_row];
            wire [LINE_AW-1:0] port_a_addr = write_a ?
                m2_row_wr_a_addr_q[storage_row] : read_addr_a[storage_row];
            wire [LINE_AW-1:0] port_b_addr = write_b ?
                m2_row_wr_b_addr_q[storage_row] : read_addr_b[storage_row];
            axis_hwc_window_row_store #(
                .DEPTH(LINE_BANK_DEPTH), .ADDR_W(LINE_AW),
                .USE_URAM(LINE_STORE_USE_URAM)
            ) u_store (
                .clk(clk), .rst(rst),
                .port_a_addr(port_a_addr),
                .port_a_we(write_a ? m2_row_wr_a_we_q[storage_row] : 8'd0),
                .port_a_wdata(m2_row_wr_a_data_q[storage_row]),
                .port_a_rdata(row_a_rdata[storage_row]),
                .port_b_addr(port_b_addr),
                .port_b_we(write_b ? m2_row_wr_b_we_q[storage_row] : 8'd0),
                .port_b_wdata(m2_row_wr_b_data_q[storage_row]),
                .port_b_rdata(row_b_rdata[storage_row])
            );
        end
    endgenerate

    // Assemble the registered row-cluster outputs.  Only three local 4:1
    // row selections remain; the former design had eighteen dynamic 64:1
    // byte selections plus global address fanout to 64 memories.
    reg [ROWS*8-1:0] three_response_data;
    reg [63:0] selected_word_a;
    reg [63:0] selected_word_b;
    integer resp_ky;
    integer resp_kx;
    integer resp_tap;
    always @* begin
        three_response_data = {ROWS*8{1'b0}};
        for (resp_ky = 0; resp_ky < 3; resp_ky = resp_ky + 1) begin
            selected_word_a = row_a_rdata[three_d1_row_bank[resp_ky]];
            selected_word_b = row_b_rdata[three_d1_row_bank[resp_ky]];
            for (resp_kx = 0; resp_kx < 3; resp_kx = resp_kx + 1) begin
                resp_tap = resp_ky * 3 + resp_kx;
                if (three_d1_mem_valid[resp_tap]) begin
                    if (three_d1_use_b[resp_tap]) begin
                        if (three_d1_lane_valid[resp_tap])
                            three_response_data[resp_tap*8 +: 8] =
                                selected_word_b[
                                    three_d1_byte0[resp_tap]*8 +: 8];
                        if (three_d1_lane_valid[9+resp_tap])
                            three_response_data[(9+resp_tap)*8 +: 8] =
                                selected_word_b[
                                    three_d1_byte1[resp_tap]*8 +: 8];
                    end else begin
                        if (three_d1_lane_valid[resp_tap])
                            three_response_data[resp_tap*8 +: 8] =
                                selected_word_a[
                                    three_d1_byte0[resp_tap]*8 +: 8];
                        if (three_d1_lane_valid[9+resp_tap])
                            three_response_data[(9+resp_tap)*8 +: 8] =
                                selected_word_a[
                                    three_d1_byte1[resp_tap]*8 +: 8];
                    end
                end
            end
        end
    end

    wire [63:0] one_capture_word_a =
        row_a_rdata[one_d1_row_bank];
    wire [63:0] one_capture_word_b =
        row_b_rdata[one_d1_row_bank];
    wire [31:0] one_capture_chunk_a = !one_d1_spatial_valid ||
        !one_d1_word_a_valid ? 32'd0 :
        (one_d1_x_odd ? one_capture_word_a[63:32] :
                        one_capture_word_a[31:0]);
    wire [31:0] one_capture_chunk_b = !one_d1_spatial_valid ||
        !one_d1_word_b_valid ? 32'd0 :
        (one_d1_x_odd ? one_capture_word_b[63:32] :
                        one_capture_word_b[31:0]);
    wire [191:0] one_response_unshifted = {
        one_capture_chunk_b, one_capture_chunk_a,
        one_chunk_q[3], one_chunk_q[2],
        one_chunk_q[1], one_chunk_q[0]
    };
    wire [191:0] one_response_shifted =
        one_response_unshifted >> ({6'd0, one_base_mod_q} << 3);
    reg [ROWS*8-1:0] one_response_data;
    integer one_resp_lane;
    always @* begin
        one_response_data = {ROWS*8{1'b0}};
        if (one_spatial_valid_q)
            for (one_resp_lane = 0; one_resp_lane < ROWS;
                 one_resp_lane = one_resp_lane + 1)
                if (one_lane_valid_q[one_resp_lane])
                    one_response_data[one_resp_lane*8 +: 8] =
                        one_response_shifted[one_resp_lane*8 +: 8];
    end

    wire push_three = three_d1_valid_q;
    wire push_one = one_d1_valid_q && one_d1_group == 2;
    wire resp_push = push_three || push_one;

    // ------------------------------------------------------------------
    // Configuration validation
    // ------------------------------------------------------------------
    wire [15:0] cfg_x_pairs = (cfg_fm_w + 1) >> 1;
    wire [15:0] cfg_channel_groups = (cfg_cin + 3) >> 2;
    wire [15:0] cfg_pass_count = cfg_kernel_1x1 ?
        ((cfg_cin + ROWS - 1) / ROWS) : ((cfg_cin + 1) >> 1);
    localparam integer PASS_COUNT_W = $clog2(MAX_PASSES + 1);
    initial begin
        if (MAX_PASSES < 1 || MAX_PASSES > 65535)
            $error("MAX_PASSES must fit the bounded prevalidated count port");
    end
    // The trusted descriptor is already range-checked against MAX_PASSES.
    // Preserve that structural bound when selecting it: allowing the unused
    // upper bits of a 16-bit port into pass_count_q makes downstream address
    // arithmetic synthesize for impossible pass counts and inflates the leaf
    // by roughly a thousand LUTs in the release configuration.
    wire [15:0] cfg_prevalidated_pass_count_bounded =
        {{(16-PASS_COUNT_W){1'b0}},
         cfg_prevalidated_pass_count[PASS_COUNT_W-1:0]};
    wire [15:0] cfg_selected_pass_count = (CFG_PREVALIDATED != 0) ?
        cfg_prevalidated_pass_count_bounded : cfg_pass_count;
`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst && cfg_start && !busy_q && (CFG_PREVALIDATED != 0) &&
            (cfg_prevalidated_pass_count < 1 ||
             cfg_prevalidated_pass_count > MAX_PASSES))
            $error("prevalidated pass count is outside the trusted range");
    end
`endif
    wire cfg_accept_legal;
    wire cfg_start_overflow;
    wire [31:0] cfg_effective_expected_bytes;
    generate
        if (CFG_PREVALIDATED != 0) begin : g_cfg_prevalidated
            assign cfg_accept_legal = 1'b1;
            assign cfg_start_overflow = 1'b0;
            assign cfg_effective_expected_bytes = cfg_expected_bytes;
        end else begin : g_cfg_local_validation
            wire [31:0] cfg_bank_words =
                cfg_x_pairs * cfg_channel_groups;
            wire [31:0] cfg_expected_bytes_math =
                cfg_fm_h * cfg_fm_w * cfg_cin;
            wire cfg_legal =
                cfg_fm_h != 0 && cfg_fm_w != 0 &&
                cfg_fm_w <= MAX_FM_W &&
                cfg_cin >= 3 && cfg_cin <= MAX_CHANNELS &&
                cfg_ofm_h != 0 && cfg_ofm_w != 0 &&
                (cfg_stride == 1 || cfg_stride == 2) &&
                cfg_ofm_h == convolution_output_dim(
                    cfg_fm_h, cfg_kernel_1x1, cfg_stride, cfg_pad) &&
                cfg_ofm_w == convolution_output_dim(
                    cfg_fm_w, cfg_kernel_1x1, cfg_stride, cfg_pad) &&
                cfg_bank_words <= LINE_BANK_DEPTH &&
                cfg_pass_count != 0 && cfg_pass_count <= MAX_PASSES;
            assign cfg_accept_legal = cfg_legal;
            assign cfg_start_overflow = cfg_bank_words > LINE_BANK_DEPTH;
            assign cfg_effective_expected_bytes = cfg_expected_bytes_math;
        end
    endgenerate

    integer seq_i;
    always @(posedge clk) begin
        if (rst) begin
            busy_q <= 1'b0;
            fm_h_q <= 16'd0;
            fm_w_q <= 16'd0;
            cin_q <= 14'd0;
            ofm_h_q <= 16'd0;
            ofm_w_q <= 16'd0;
            kernel_1x1_q <= 1'b0;
            stride_q <= 2'd1;
            pad_q <= 2'd0;
            input_zero_point_q <= 8'd0;
            epoch_q <= {EPOCH_W{1'b0}};
            x_pairs_q <= 16'd0;
            channel_groups_q <= 16'd0;
            pass_count_q <= 16'd0;
            expected_bytes_q <= 32'd0;
            logical_remaining_q <= 32'd0;
            wr_y_q <= 16'd0;
            wr_x_q <= 16'd0;
            wr_ch_q <= 14'd0;
            wr_x_odd_q <= 1'b0;
            wr_x_pair_q <= 16'd0;
            wr_ch_mod_q <= 2'd0;
            wr_ch_group_q <= 16'd0;
            wr_word_addr_q <= {LINE_AW{1'b0}};
            stored_bytes_q <= 32'd0;
            spec_wr_y_q <= 16'd0;
            spec_wr_x_q <= 16'd0;
            spec_wr_ch_q <= 14'd0;
            spec_wr_x_odd_q <= 1'b0;
            spec_wr_x_pair_q <= 16'd0;
            spec_wr_ch_mod_q <= 2'd0;
            spec_wr_ch_group_q <= 16'd0;
            spec_wr_word_addr_q <= {LINE_AW{1'b0}};
            spec_stored_bytes_q <= 32'd0;
            s0_valid_q <= 1'b0;
            m0_valid_q <= 1'b0;
            m1_valid_q <= 1'b0;
            m2_valid_q <= 1'b0;
            beat_fifo_valid_q <= 2'b00;
            beat_fifo_rd_ptr_q <= 1'b0;
            beat_fifo_wr_ptr_q <= 1'b0;
            beat_fifo_upper_q <= 1'b0;
            accept_closed_q <= 1'b0;
            defer_valid_q <= 1'b0;
            defer_data_q <= 32'd0;
            defer_keep_q <= 4'd0;
            defer_end_q <= 4'd0;
            defer_finishes_beat_q <= 1'b0;
            loaded_any_q <= 1'b0;
            loaded_through_y_q <= 16'd0;
            row_valid_q <= 4'd0;
            spec_row_valid_q <= 4'd0;
            for (row_i = 0; row_i < ROW_BANKS; row_i = row_i + 1) begin
                row_tag_q[row_i] <= 16'd0;
                spec_row_tag_q[row_i] <= 16'd0;
            end
            row_completed_wait_q <= 1'b0;
            row_start_check_pending_q <= 1'b0;
            row_boundary_pending_q <= 1'b0;
            row_drain_quiet_q <= 1'b0;
            finish_pending_q <= 1'b0;
            active_read_rows_q <= {ROW_BANKS{1'b0}};
            mat_active_q <= 1'b0;
            mat_oy_q <= 16'd0;
            mat_x_q <= 16'd0;
            mat_pass_q <= 16'd0;
            mat_base_ch_q <= 14'd0;
            mat_base_ch_mod_q <= 2'd0;
            mat_word_base_addr_q <= {LINE_AW{1'b0}};
            mat_read_first_pair_q <= {LINE_AW{1'b0}};
            mat_read_word_addr_q <= {(LINE_AW+1){1'b0}};
            mat_row_base_pixel_q <= 32'd0;
            next_oy_q <= 16'd0;
            m1_min_needed_y_q <= 16'd0;
            all_issued_q <= 1'b0;
            three_d0_valid_q <= 1'b0;
            three_d1_valid_q <= 1'b0;
            one_active_q <= 1'b0;
            one_issue_group_q <= 2'd0;
            one_base_mod_q <= 2'd0;
            one_lane_valid_q <= {ROWS{1'b0}};
            one_spatial_valid_q <= 1'b0;
            one_pixel_q <= 32'd0;
            one_pass_q <= 16'd0;
            one_oy_q <= 16'd0;
            one_x_q <= 16'd0;
            one_last_q <= 1'b0;
            for (seq_i = 0; seq_i < 4; seq_i = seq_i + 1)
                one_chunk_q[seq_i] <= 32'd0;
            one_d0_valid_q <= 1'b0;
            one_d1_valid_q <= 1'b0;
            resp_wr_ptr_q <= {RESP_AW{1'b0}};
            resp_rd_ptr_q <= {RESP_AW{1'b0}};
            resp_count_q <= 3'd0;
            input_done <= 1'b0;
            done <= 1'b0;
            if (ENABLE_PASS_READY_BITMAP != 0)
                pass_ready_bitmap_q <= {MAX_PASSES{1'b0}};
            config_error <= 1'b0;
            tkeep_error <= 1'b0;
            tlast_error <= 1'b0;
            overflow_error <= 1'b0;
            bank_collision_error <= 1'b0;
            row_overwrite_error <= 1'b0;
            protocol_error <= 1'b0;
            accepted_beats <= 32'd0;
            accepted_bytes <= 32'd0;
            emitted_entries <= 32'd0;
            axis_stall_cycles <= 32'd0;
            entry_stall_cycles <= 32'd0;
            materialize_cycles <= 32'd0;
        end else begin
            done <= 1'b0;
            if (!s0_valid_q || phase_a_from_s0)
                s0_valid_q <= source_slice_load;
            if (source_slice_load) begin
                s0_data_q <= source_slice_data;
                s0_keep_q <= source_slice_keep;
                s0_end_q <= source_slice_end;
                s0_finishes_beat_q <= source_slice_finishes_beat;
                s0_upper_q <= beat_fifo_upper_q;
            end
            if (phase_a_load)
                m0_valid_q <= 1'b1;
            else if (map_load)
                m0_valid_q <= 1'b0;
            // Sample an invalid M0 from registered source state regardless of
            // whether late M1 control permits it to become live this cycle.
            // phase_a_load therefore reaches only m0_valid_q; it cannot be
            // absorbed into the two-byte cursor arithmetic feeding payload D.
            if (!m0_valid_q) begin
                m0_data_q <= phase_a_data;
                m0_keep_q <= phase_a_keep;
                m0_end_q <= phase_a_end;
                for (seq_i = 0; seq_i < PHASE_LANES;
                     seq_i = seq_i + 1) begin
                    m0_lane_y_q[seq_i] <= phase_a_lane_y[seq_i];
                    m0_lane_x_q[seq_i] <= phase_a_lane_x[seq_i];
                    m0_lane_ch_q[seq_i] <= phase_a_lane_ch[seq_i];
                    m0_lane_row_bank_q[seq_i] <=
                        phase_a_lane_row_bank[seq_i];
                    m0_lane_addr_q[seq_i] <= phase_a_lane_addr[seq_i];
                    m0_lane_byte_q[seq_i] <= phase_a_lane_byte[seq_i];
                end
                m0_mid_wr_y_q <= phase_a_mid_wr_y;
                m0_mid_wr_x_q <= phase_a_mid_wr_x;
                m0_mid_wr_ch_q <= phase_a_mid_wr_ch;
                m0_mid_wr_x_odd_q <= phase_a_mid_wr_x_odd;
                m0_mid_wr_x_pair_q <= phase_a_mid_wr_x_pair;
                m0_mid_wr_ch_mod_q <= phase_a_mid_wr_ch_mod;
                m0_mid_wr_ch_group_q <= phase_a_mid_wr_ch_group;
                m0_mid_wr_word_addr_q <= phase_a_mid_wr_word_addr;
                m0_source_finishes_beat_q <= phase_a_finishes_beat;
                m0_source_from_defer_q <= defer_valid_q;
            end
            if (!m1_valid_q || m1_issue)
                m1_valid_q <= map_load;
            m2_valid_q <= m1_issue;
            if (map_load) begin
                m1_data_q <= m0_data_q;
                m1_lane_valid_q <= lane_map_valid;
                m1_end_q <= m0_end_q;
                for (seq_i = 0; seq_i < STORE_LANES;
                     seq_i = seq_i + 1) begin
                    m1_lane_y_q[seq_i] <= lane_y[seq_i];
                    m1_lane_x_q[seq_i] <= lane_x[seq_i];
                    m1_lane_ch_q[seq_i] <= lane_ch[seq_i];
                    m1_lane_row_bank_q[seq_i] <= lane_row_bank[seq_i];
                    m1_lane_addr_q[seq_i] <= lane_addr[seq_i];
                    m1_lane_byte_q[seq_i] <= lane_byte[seq_i];
                end
                m1_post_wr_y_q <= mapped_post_wr_y;
                m1_post_wr_x_q <= mapped_post_wr_x;
                m1_post_wr_ch_q <= mapped_post_wr_ch;
                m1_post_wr_x_odd_q <= mapped_post_wr_x_odd;
                m1_post_wr_x_pair_q <= mapped_post_wr_x_pair;
                m1_post_wr_ch_mod_q <= mapped_post_wr_ch_mod;
                m1_post_wr_ch_group_q <= mapped_post_wr_ch_group;
                m1_post_wr_word_addr_q <= mapped_post_wr_word_addr;
                m1_source_finishes_beat_q <= m0_source_finishes_beat_q;
                m1_source_from_defer_q <= m0_source_from_defer_q;
                m1_admit_defer_required_q <= load_defer_required;
                m1_admit_write_row_mask_q <= load_write_row_mask;
                m1_admit_row_start_mask_q <= load_row_start_mask;
                m1_admit_commit_row_completed_q <=
                    load_commit_row_completed;
                m1_admit_commit_row_mask_q <= load_commit_row_mask;
                for (seq_i = 0; seq_i < ROW_BANKS;
                     seq_i = seq_i + 1)
                    m1_admit_row_start_y_q[seq_i] <=
                        load_row_start_y[seq_i];
            end
            if (m1_issue) begin
                m2_row_wr_a_en_q <=
                    m2_row_wr_a_en_comb & ~active_read_rows;
                m2_row_wr_b_en_q <=
                    m2_row_wr_b_en_comb & ~active_read_rows;
                for (seq_i = 0; seq_i < ROW_BANKS;
                     seq_i = seq_i + 1) begin
                    m2_row_wr_a_addr_q[seq_i] <=
                        m2_row_wr_a_addr_comb[seq_i];
                    m2_row_wr_b_addr_q[seq_i] <=
                        m2_row_wr_b_addr_comb[seq_i];
                    m2_row_wr_a_we_q[seq_i] <=
                        m2_row_wr_a_we_comb[seq_i];
                    m2_row_wr_b_we_q[seq_i] <=
                        m2_row_wr_b_we_comb[seq_i];
                    m2_row_wr_a_data_q[seq_i] <=
                        m2_row_wr_a_data_comb[seq_i];
                    m2_row_wr_b_data_q[seq_i] <=
                        m2_row_wr_b_data_comb[seq_i];
                    m2_commit_row_y_q[seq_i] <=
                        m1_commit_row_y_comb[seq_i];
                end
                m2_stored_post_bytes_q <= spec_stored_bytes_q +
                                           m1_committed_inc_comb;
                m2_post_wr_y_q <= m1_commit_post_wr_y_comb;
                m2_post_wr_x_q <= m1_commit_post_wr_x_comb;
                m2_post_wr_ch_q <= m1_commit_post_wr_ch_comb;
                m2_post_wr_x_odd_q <= m1_commit_post_wr_x_odd_comb;
                m2_post_wr_x_pair_q <= m1_commit_post_wr_x_pair_comb;
                m2_post_wr_ch_mod_q <= m1_commit_post_wr_ch_mod_comb;
                m2_post_wr_ch_group_q <= m1_commit_post_wr_ch_group_comb;
                m2_post_wr_word_addr_q <=
                    m1_commit_post_wr_word_addr_comb;
                m2_store_finishes_input_q <= m1_finish_token_comb;
                m2_store_finishes_beat_q <= m1_store_finishes_beat_comb;
                m2_bank_addr_overflow_q <= m1_bank_addr_overflow_comb;
                m2_bank_collision_q <= m1_bank_collision_comb |
                                       m2_bank_collision_comb;
                m2_write_read_conflict_q <= m2_write_read_conflict_comb;
                m2_overwrite_q <= m1_overwrite_comb;
                m2_commit_row_completed_q <=
                    m1_admit_commit_row_completed_q;
                m2_commit_last_completed_y_q <=
                    m1_commit_last_completed_y_comb;
                m2_commit_row_mask_q <= m1_admit_commit_row_mask_q;
            end
            three_d1_valid_q <= three_d0_valid_q;
            three_d0_valid_q <= issue_three;
            one_d1_valid_q <= one_d0_valid_q;
            one_d0_valid_q <= issue_one;

            if (s_axis_tvalid && !s_axis_tready)
                axis_stall_cycles <= axis_stall_cycles + 1'b1;
            if (m_entry_valid && !m_entry_ready)
                entry_stall_cycles <= entry_stall_cycles + 1'b1;
            if (mat_active_q)
                materialize_cycles <= materialize_cycles + 1'b1;

            if (cfg_start && !busy_q) begin
                    busy_q <= cfg_accept_legal;
                    fm_h_q <= cfg_fm_h;
                    fm_w_q <= cfg_fm_w;
                    cin_q <= cfg_cin;
                    ofm_h_q <= cfg_ofm_h;
                    ofm_w_q <= cfg_ofm_w;
                    kernel_1x1_q <= cfg_kernel_1x1;
                    stride_q <= cfg_stride;
                    pad_q <= cfg_pad;
                    input_zero_point_q <= cfg_input_zero_point;
                    epoch_q <= cfg_epoch;
                    x_pairs_q <= cfg_x_pairs;
                    channel_groups_q <= cfg_channel_groups;
                    pass_count_q <= cfg_selected_pass_count;
                    expected_bytes_q <= cfg_effective_expected_bytes;
                    logical_remaining_q <= cfg_effective_expected_bytes;
                    wr_y_q <= 16'd0;
                    wr_x_q <= 16'd0;
                    wr_ch_q <= 14'd0;
                    wr_x_odd_q <= 1'b0;
                    wr_x_pair_q <= 16'd0;
                    wr_ch_mod_q <= 2'd0;
                    wr_ch_group_q <= 16'd0;
                    wr_word_addr_q <= {LINE_AW{1'b0}};
                    stored_bytes_q <= 32'd0;
                    spec_wr_y_q <= 16'd0;
                    spec_wr_x_q <= 16'd0;
                    spec_wr_ch_q <= 14'd0;
                    spec_wr_x_odd_q <= 1'b0;
                    spec_wr_x_pair_q <= 16'd0;
                    spec_wr_ch_mod_q <= 2'd0;
                    spec_wr_ch_group_q <= 16'd0;
                    spec_wr_word_addr_q <= {LINE_AW{1'b0}};
                    spec_stored_bytes_q <= 32'd0;
                    s0_valid_q <= 1'b0;
                    m0_valid_q <= 1'b0;
                    m1_valid_q <= 1'b0;
                    m2_valid_q <= 1'b0;
                    beat_fifo_valid_q <= 2'b00;
                    beat_fifo_rd_ptr_q <= 1'b0;
                    beat_fifo_wr_ptr_q <= 1'b0;
                    beat_fifo_upper_q <= 1'b0;
                    accept_closed_q <= 1'b0;
                    // Valid is the sole lifetime state.  Leaving invalid
                    // payload untouched keeps cfg_start off its reset cone.
                    defer_valid_q <= 1'b0;
                    loaded_any_q <= 1'b0;
                    loaded_through_y_q <= 16'd0;
                    row_valid_q <= 4'd0;
                    spec_row_valid_q <= 4'd0;
                    for (row_i = 0; row_i < ROW_BANKS;
                         row_i = row_i + 1)
                        spec_row_tag_q[row_i] <= 16'd0;
                    row_completed_wait_q <= 1'b0;
                    row_start_check_pending_q <= 1'b0;
                    row_boundary_pending_q <= 1'b0;
                    row_drain_quiet_q <= 1'b0;
                    finish_pending_q <= 1'b0;
                    active_read_rows_q <= {ROW_BANKS{1'b0}};
                    mat_active_q <= 1'b0;
                    mat_oy_q <= 16'd0;
                    mat_x_q <= 16'd0;
                    mat_pass_q <= 16'd0;
                    mat_base_ch_q <= 14'd0;
                    mat_base_ch_mod_q <= 2'd0;
                    mat_word_base_addr_q <= {LINE_AW{1'b0}};
                    mat_read_first_pair_q <= {LINE_AW{1'b0}};
                    mat_read_word_addr_q <= {(LINE_AW+1){1'b0}};
                    mat_row_base_pixel_q <= 32'd0;
                    next_oy_q <= 16'd0;
                    // output row zero always clamps to input row zero,
                    // independent of the accepted padding.
                    m1_min_needed_y_q <= 16'd0;
                    all_issued_q <= 1'b0;
                    three_d0_valid_q <= 1'b0;
                    three_d1_valid_q <= 1'b0;
                    one_active_q <= 1'b0;
                    one_issue_group_q <= 2'd0;
                    one_d0_valid_q <= 1'b0;
                    one_d1_valid_q <= 1'b0;
                    resp_wr_ptr_q <= {RESP_AW{1'b0}};
                    resp_rd_ptr_q <= {RESP_AW{1'b0}};
                    resp_count_q <= 3'd0;
                    input_done <= 1'b0;
                    if (ENABLE_PASS_READY_BITMAP != 0)
                        pass_ready_bitmap_q <= {MAX_PASSES{1'b0}};
                    config_error <= !cfg_accept_legal;
                    tkeep_error <= 1'b0;
                    tlast_error <= 1'b0;
                    overflow_error <= cfg_start_overflow;
                    bank_collision_error <= 1'b0;
                    row_overwrite_error <= 1'b0;
                    protocol_error <= 1'b0;
                    accepted_beats <= 32'd0;
                    accepted_bytes <= 32'd0;
                    emitted_entries <= 32'd0;
                    axis_stall_cycles <= 32'd0;
                    entry_stall_cycles <= 32'd0;
                    materialize_cycles <= 32'd0;
                    if (!cfg_accept_legal)
                        done <= 1'b1;
            end else begin
                // A start pulse while busy is a sticky protocol violation,
                // not a pipeline flush.  Continue the ordinary AXIS/FIFO and
                // M1/M2/M3 transitions below so every advertised handshake
                // and already-issued write still commits atomically.
                if (cfg_start && busy_q)
                    protocol_error <= 1'b1;
                if (!row_start_check_pending_q)
                    row_drain_quiet_q <= 1'b0;
                else if (!row_drain_quiet_q)
                    // The pending cycle immediately preceding this edge was
                    // the sole issue opportunity.  Freeze phase A/B and M1;
                    // any irrevocable work is represented by M2.
                    row_drain_quiet_q <= 1'b1;

                if (axis_fire) begin
                    accepted_beats <= accepted_beats + 1'b1;
                    accepted_bytes <= accepted_post_bytes;
                    if (axis_beat_short)
                        logical_remaining_q <= logical_remaining_q -
                                               axis_keep_count_comb;
                    else
                        logical_remaining_q <= 32'd0;
                    beat_fifo_data_q[beat_fifo_wr_ptr_q] <= s_axis_tdata;
                    beat_fifo_keep_q[beat_fifo_wr_ptr_q] <=
                        axis_clipped_keep_comb;
                    beat_fifo_end_q[beat_fifo_wr_ptr_q] <=
                        axis_logical_end_comb;
                    beat_fifo_valid_q[beat_fifo_wr_ptr_q] <= 1'b1;
                    beat_fifo_wr_ptr_q <= ~beat_fifo_wr_ptr_q;
                    if (!axis_beat_short)
                        accept_closed_q <= 1'b1;
                    if (!keep_prefix_comb || s_axis_tkeep == 0 ||
                        (axis_beat_short &&
                         s_axis_tkeep != {KEEP_W{1'b1}}))
                        tkeep_error <= 1'b1;
                    if (axis_beat_overlong)
                        overflow_error <= 1'b1;
                    if (s_axis_tlast != beat_finishes_input)
                        tlast_error <= 1'b1;
                end

                if (beat_fifo_pop) begin
                    beat_fifo_valid_q[beat_fifo_rd_ptr_q] <= 1'b0;
                    beat_fifo_rd_ptr_q <= ~beat_fifo_rd_ptr_q;
                    beat_fifo_upper_q <= 1'b0;
                end else if (source_slice_load) begin
                    beat_fifo_upper_q <= 1'b1;
                end

                // Loading a deferred source consumes that registered suffix.
                // A late M1 defer below has priority and installs the next
                // suffix only after refill has been prohibited for this edge.
                // Invalid payload is deliberately stale and is never read.
                if (phase_a_from_defer) begin
                    defer_valid_q <= 1'b0;
                end
                if (m1_issue && m1_admit_defer_required_q) begin
                    defer_valid_q <= 1'b1;
                    defer_data_q <= m1_defer_data_comb;
                    defer_keep_q <= m1_defer_keep_comb;
                    defer_end_q <= m1_defer_end_comb;
                    defer_finishes_beat_q <= m1_source_finishes_beat_q;
                end

                // The raw mapper speculates through all mapped bytes when M1
                // loads.  If late fragment selection finds a suffix, no refill
                // is allowed and this rollback exposes the committed-prefix
                // cursor before the deferred source is loaded next cycle.
                if (map_load) begin
                    spec_wr_y_q <= mapped_post_wr_y;
                    spec_wr_x_q <= mapped_post_wr_x;
                    spec_wr_ch_q <= mapped_post_wr_ch;
                    spec_wr_x_odd_q <= mapped_post_wr_x_odd;
                    spec_wr_x_pair_q <= mapped_post_wr_x_pair;
                    spec_wr_ch_mod_q <= mapped_post_wr_ch_mod;
                    spec_wr_ch_group_q <= mapped_post_wr_ch_group;
                    spec_wr_word_addr_q <= mapped_post_wr_word_addr;
                end
                if (m1_issue && m1_admit_defer_required_q) begin
                    spec_wr_y_q <= m1_commit_post_wr_y_comb;
                    spec_wr_x_q <= m1_commit_post_wr_x_comb;
                    spec_wr_ch_q <= m1_commit_post_wr_ch_comb;
                    spec_wr_x_odd_q <= m1_commit_post_wr_x_odd_comb;
                    spec_wr_x_pair_q <= m1_commit_post_wr_x_pair_comb;
                    spec_wr_ch_mod_q <= m1_commit_post_wr_ch_mod_comb;
                    spec_wr_ch_group_q <= m1_commit_post_wr_ch_group_comb;
                    spec_wr_word_addr_q <=
                        m1_commit_post_wr_word_addr_comb;
                end

                // Count, speculative row ownership, and finish lifetime move
                // only when the held M1 prefix passes the late row-safety
                // check.  A blocked M1 can therefore retry without duplicate
                // architectural progress.  The validated Cin>=3 contract
                // continues to make the one-cycle speculative-tag lead safe.
                if (m1_issue) begin
                    spec_stored_bytes_q <= spec_stored_bytes_q +
                                           m1_committed_inc_comb;
                    for (seq_i = 0; seq_i < ROW_BANKS;
                         seq_i = seq_i + 1)
                        if (m1_admit_commit_row_mask_q[seq_i]) begin
                            spec_row_valid_q[seq_i] <= 1'b1;
                            spec_row_tag_q[seq_i] <=
                                m1_commit_row_y_comb[seq_i];
                        end
                    if (m1_finish_token_comb)
                        finish_pending_q <= 1'b1;
                end
                if (m1_row_event)
                    row_boundary_pending_q <= 1'b1;

                // M3: the memory consumes the registered M2 write bundle on
                // this edge; commit all visible state from the same bundle.
                if (m2_valid_q) begin
                    stored_bytes_q <= m2_stored_post_bytes_q;
                    wr_y_q <= m2_post_wr_y_q;
                    wr_x_q <= m2_post_wr_x_q;
                    wr_ch_q <= m2_post_wr_ch_q;
                    wr_x_odd_q <= m2_post_wr_x_odd_q;
                    wr_x_pair_q <= m2_post_wr_x_pair_q;
                    wr_ch_mod_q <= m2_post_wr_ch_mod_q;
                    wr_ch_group_q <= m2_post_wr_ch_group_q;
                    wr_word_addr_q <= m2_post_wr_word_addr_q;
                    // accepted_post_bytes already detects an overlong AXIS
                    // stream.  lane_map_valid clips every committed prefix at
                    // expected_bytes_q, so repeating that 32-bit comparison
                    // here is both redundant and a long cursor-to-error path.
                    if (m2_bank_addr_overflow_q)
                        overflow_error <= 1'b1;
                    if (m2_bank_collision_q)
                        bank_collision_error <= 1'b1;
                    if (m2_write_read_conflict_q)
                        protocol_error <= 1'b1;
                    if (m2_overwrite_q)
                        row_overwrite_error <= 1'b1;

                    for (seq_i = 0; seq_i < ROW_BANKS;
                         seq_i = seq_i + 1)
                        if (m2_commit_row_mask_q[seq_i]) begin
                            row_valid_q[seq_i] <= 1'b1;
                            row_tag_q[seq_i] <= m2_commit_row_y_q[seq_i];
                        end
                    if (m2_commit_row_completed_q) begin
                        loaded_any_q <= 1'b1;
                        loaded_through_y_q <=
                            m2_commit_last_completed_y_q;
                    end
                    if (m2_store_finishes_input_q)
                        input_done <= 1'b1;
                    if (m2_commit_row_completed_q &&
                        !m2_store_finishes_beat_q)
                        row_completed_wait_q <= 1'b1;
                    if (m2_store_finishes_beat_q) begin
                        row_completed_wait_q <= 1'b0;
                        if (row_completed_wait_q ||
                            m2_commit_row_completed_q)
                            row_start_check_pending_q <= 1'b1;
                    end
                end

                if (input_done && beat_fifo_empty &&
                    finish_write_pipe_drained)
                    finish_pending_q <= 1'b0;

                if (row_start_check_pending_q &&
                    row_write_pipe_drained) begin
                    row_start_check_pending_q <= 1'b0;
                    row_boundary_pending_q <= 1'b0;
                    row_drain_quiet_q <= 1'b0;
                    if (!mat_active_q && output_row_ready(
                            next_oy_q, loaded_through_y_q,
                            loaded_any_q, input_done)) begin
                        mat_active_q <= 1'b1;
                        active_read_rows_q <= row_read_mask(
                            next_oy_q, kernel_1x1_q, stride_q,
                            pad_q, fm_h_q);
                        mat_oy_q <= next_oy_q;
                        mat_x_q <= 16'd0;
                        mat_pass_q <= 16'd0;
                        mat_base_ch_q <= 14'd0;
                        mat_base_ch_mod_q <= 2'd0;
                        mat_word_base_addr_q <= {LINE_AW{1'b0}};
                        mat_read_first_pair_q <= {LINE_AW{1'b0}};
                        mat_read_word_addr_q <= {(LINE_AW+1){1'b0}};
                        all_issued_q <= 1'b0;
                        one_active_q <= 1'b0;
                        one_issue_group_q <= 2'd0;
                    end
                end

                // Read-descriptor pipelines.
                if (issue_three) begin
                    for (seq_i = 0; seq_i < 3; seq_i = seq_i + 1)
                        three_d0_row_bank[seq_i] <= three_row_bank[seq_i];
                    three_d0_row_valid <= three_row_valid;
                    three_d0_mem_valid <= three_mem_valid;
                    three_d0_use_b <= three_use_b;
                    for (seq_i = 0; seq_i < 9; seq_i = seq_i + 1) begin
                        three_d0_byte0[seq_i] <= three_byte0[seq_i];
                        three_d0_byte1[seq_i] <= three_byte1[seq_i];
                    end
                    three_d0_lane_valid <= three_lane_valid;
                    three_d0_pixel <= mat_row_base_pixel_q + mat_x_q;
                    three_d0_pass <= mat_pass_q;
                    three_d0_oy <= mat_oy_q;
                    three_d0_x <= mat_x_q;
                    three_d0_last <= mat_oy_q + 1 == ofm_h_q &&
                        mat_pass_q + 1 == pass_count_q &&
                        mat_x_q + 1 == ofm_w_q;
                    if (three_read_overflow)
                        overflow_error <= 1'b1;
                    if (three_row_missing)
                        row_overwrite_error <= 1'b1;

                    if (mat_x_q + 1 != ofm_w_q) begin
                        mat_x_q <= mat_x_q + 1'b1;
                        if (mat_read_first_pair_inc) begin
                            mat_read_first_pair_q <=
                                mat_read_first_pair_q + 1'b1;
                            mat_read_word_addr_q <=
                                mat_read_word_addr_q + 1'b1;
                        end
                    end else if (mat_pass_q + 1 != pass_count_q) begin
                        mat_x_q <= 16'd0;
                        mat_pass_q <= mat_pass_q + 1'b1;
                        mat_base_ch_q <= mat_base_ch_q + 14'd2;
                        mat_read_first_pair_q <= {LINE_AW{1'b0}};
                        if (mat_base_ch_mod_q == 2'd2) begin
                            mat_base_ch_mod_q <= 2'd0;
                            mat_word_base_addr_q <= mat_three_next_word_base;
                            mat_read_word_addr_q <=
                                {1'b0, mat_three_next_word_base};
                        end else begin
                            mat_base_ch_mod_q <= 2'd2;
                            mat_read_word_addr_q <=
                                {1'b0, mat_word_base_addr_q};
                        end
                    end else begin
                        all_issued_q <= 1'b1;
                    end
                end

                if (three_d0_valid_q) begin
                    for (seq_i = 0; seq_i < 3; seq_i = seq_i + 1)
                        three_d1_row_bank[seq_i] <=
                            three_d0_row_bank[seq_i];
                    three_d1_row_valid <= three_d0_row_valid;
                    three_d1_mem_valid <= three_d0_mem_valid;
                    three_d1_use_b <= three_d0_use_b;
                    for (seq_i = 0; seq_i < 9; seq_i = seq_i + 1) begin
                        three_d1_byte0[seq_i] <= three_d0_byte0[seq_i];
                        three_d1_byte1[seq_i] <= three_d0_byte1[seq_i];
                    end
                    three_d1_lane_valid <= three_d0_lane_valid;
                    three_d1_pixel <= three_d0_pixel;
                    three_d1_pass <= three_d0_pass;
                    three_d1_oy <= three_d0_oy;
                    three_d1_x <= three_d0_x;
                    three_d1_last <= three_d0_last;
                end

                if (issue_one) begin
                    one_d0_group <= one_issue_group_q;
                    one_d0_row_bank <= one_issue_row_bank;
                    one_d0_spatial_valid <= one_issue_spatial_valid;
                    one_d0_word_a_valid <= one_issue_word_a_valid;
                    one_d0_word_b_valid <= one_issue_word_b_valid;
                    one_d0_x_odd <= one_issue_x_odd;
                    if (!one_active_q) begin
                        one_active_q <= 1'b1;
                        one_issue_group_q <= 2'd1;
                        one_base_mod_q <= mat_base_ch_q[1:0];
                        for (one_lane_i = 0; one_lane_i < ROWS;
                             one_lane_i = one_lane_i + 1)
                            one_lane_valid_q[one_lane_i] <=
                                mat_base_ch_q + one_lane_i < cin_q;
                        one_spatial_valid_q <= one_issue_spatial_valid;
                        one_pixel_q <= mat_row_base_pixel_q + mat_x_q;
                        one_pass_q <= mat_pass_q;
                        one_oy_q <= mat_oy_q;
                        one_x_q <= mat_x_q;
                        one_last_q <= mat_oy_q + 1 == ofm_h_q &&
                            mat_pass_q + 1 == pass_count_q &&
                            mat_x_q + 1 == ofm_w_q;
                    end else begin
                        one_issue_group_q <= one_issue_group_q + 1'b1;
                    end
                    if (one_read_overflow)
                        overflow_error <= 1'b1;
                    if (one_row_missing)
                        row_overwrite_error <= 1'b1;
                end
                if (one_d0_valid_q) begin
                    one_d1_group <= one_d0_group;
                    one_d1_row_bank <= one_d0_row_bank;
                    one_d1_spatial_valid <= one_d0_spatial_valid;
                    one_d1_word_a_valid <= one_d0_word_a_valid;
                    one_d1_word_b_valid <= one_d0_word_b_valid;
                    one_d1_x_odd <= one_d0_x_odd;
                end
                if (one_d1_valid_q) begin
                    if (one_d1_group == 0) begin
                        one_chunk_q[0] <= one_capture_chunk_a;
                        one_chunk_q[1] <= one_capture_chunk_b;
                    end else if (one_d1_group == 1) begin
                        one_chunk_q[2] <= one_capture_chunk_a;
                        one_chunk_q[3] <= one_capture_chunk_b;
                    end else begin
                        one_active_q <= 1'b0;
                        one_issue_group_q <= 2'd0;
                        if (mat_x_q + 1 != ofm_w_q) begin
                            mat_x_q <= mat_x_q + 1'b1;
                            if (mat_read_first_pair_inc) begin
                                mat_read_first_pair_q <=
                                    mat_read_first_pair_q + 1'b1;
                                mat_read_word_addr_q <=
                                    mat_read_word_addr_q + 1'b1;
                            end
                        end else if (mat_pass_q + 1 != pass_count_q) begin
                            mat_x_q <= 16'd0;
                            mat_pass_q <= mat_pass_q + 1'b1;
                            mat_base_ch_q <= mat_base_ch_q + ROWS;
                            mat_read_first_pair_q <= {LINE_AW{1'b0}};
                            if (mat_base_ch_mod_q == 2'd0) begin
                                mat_base_ch_mod_q <= 2'd2;
                                mat_word_base_addr_q <=
                                    mat_one_next_word_base_mod0;
                                mat_read_word_addr_q <=
                                    {1'b0, mat_one_next_word_base_mod0};
                            end else begin
                                mat_base_ch_mod_q <= 2'd0;
                                mat_word_base_addr_q <=
                                    mat_one_next_word_base_mod2;
                                mat_read_word_addr_q <=
                                    {1'b0, mat_one_next_word_base_mod2};
                            end
                        end else begin
                            // The final native-1x1 response still has to
                            // traverse the response FIFO.  Prevent the idle
                            // group sequencer from issuing it a second time.
                            all_issued_q <= 1'b1;
                        end
                    end
                end

                // Response FIFO.  The credit equation guarantees no push
                // can arrive when a full FIFO is not simultaneously popped.
                if (resp_push) begin
                    if (resp_count_q == RESP_DEPTH && !out_fire) begin
                        overflow_error <= 1'b1;
                        protocol_error <= 1'b1;
                    end else begin
                        resp_data_q[resp_wr_ptr_q] <= push_three ?
                            three_response_data : one_response_data;
                        resp_lane_valid_q[resp_wr_ptr_q] <= push_three ?
                            three_d1_lane_valid : one_lane_valid_q;
                        resp_pixel_q[resp_wr_ptr_q] <= push_three ?
                            three_d1_pixel : one_pixel_q;
                        resp_pass_q[resp_wr_ptr_q] <= push_three ?
                            three_d1_pass : one_pass_q;
                        resp_oy_q[resp_wr_ptr_q] <= push_three ?
                            three_d1_oy : one_oy_q;
                        resp_x_q[resp_wr_ptr_q] <= push_three ?
                            three_d1_x : one_x_q;
                        resp_last_q[resp_wr_ptr_q] <= push_three ?
                            three_d1_last : one_last_q;
                        resp_wr_ptr_q <= resp_wr_ptr_q + 1'b1;
                    end
                end
                if (out_fire)
                    resp_rd_ptr_q <= resp_rd_ptr_q + 1'b1;
                case ({resp_push, out_fire})
                    2'b10: if (resp_count_q != RESP_DEPTH)
                               resp_count_q <= resp_count_q + 1'b1;
                    2'b01: resp_count_q <= resp_count_q - 1'b1;
                    default: begin end
                endcase

                if (out_fire) begin
                    emitted_entries <= emitted_entries + 1'b1;
                    if (resp_oy_q[resp_rd_ptr_q] + 1 == ofm_h_q &&
                        resp_x_q[resp_rd_ptr_q] + 1 == ofm_w_q)
                        if (ENABLE_PASS_READY_BITMAP != 0)
                            pass_ready_bitmap_q[
                                resp_pass_q[resp_rd_ptr_q]] <= 1'b1;

                    if (resp_x_q[resp_rd_ptr_q] + 1 == ofm_w_q &&
                        resp_pass_q[resp_rd_ptr_q] + 1 == pass_count_q) begin
                        next_oy_q <= resp_oy_q[resp_rd_ptr_q] + 1'b1;
                        if (stride_position(
                                resp_oy_q[resp_rd_ptr_q] + 1'b1,
                                stride_q) <= pad_q)
                            m1_min_needed_y_q <= 16'd0;
                        else
                            m1_min_needed_y_q <= stride_position(
                                resp_oy_q[resp_rd_ptr_q] + 1'b1,
                                stride_q) - pad_q;
                        mat_row_base_pixel_q <=
                            mat_row_base_pixel_q + ofm_w_q;
                        mat_base_ch_q <= 14'd0;
                        mat_base_ch_mod_q <= 2'd0;
                        mat_word_base_addr_q <= {LINE_AW{1'b0}};
                        mat_read_first_pair_q <= {LINE_AW{1'b0}};
                        mat_read_word_addr_q <= {(LINE_AW+1){1'b0}};
                        all_issued_q <= 1'b0;
                        one_active_q <= 1'b0;
                        one_issue_group_q <= 2'd0;
                        if (resp_oy_q[resp_rd_ptr_q] + 1 == ofm_h_q) begin
                            mat_active_q <= 1'b0;
                            active_read_rows_q <= {ROW_BANKS{1'b0}};
                            busy_q <= 1'b0;
                            done <= 1'b1;
                        end else begin
                            mat_active_q <= 1'b0;
                            active_read_rows_q <= {ROW_BANKS{1'b0}};
                            // Always cross a registered drain barrier between
                            // output rows.  A beat accepted on this same edge
                            // is retained in the accepted-beat FIFO; the
                            // pending bit stops new-beat issue on the following
                            // cycle and the row starts after defer/M1/M2 drain.
                            if (output_row_ready(
                                    resp_oy_q[resp_rd_ptr_q] + 1'b1,
                                    loaded_through_y_q,
                                    loaded_any_q, input_done))
                                row_start_check_pending_q <= 1'b1;
                        end
                    end
                end
            end
        end
    end
endmodule

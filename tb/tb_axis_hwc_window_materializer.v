`timescale 1ns / 1ps

module tb_axis_hwc_window_materializer;
    localparam integer ROWS = 18;
    localparam integer AXIS_W = 64;
    localparam integer KEEP_W = 8;
    localparam integer MAX_FM_W = 64;
    // Keep this module-level instance wide enough to exercise the ABI-v2
    // release extreme (native 1x1 Cin=1024 => 57 ROWS=18 K passes) without
    // adding another top to the regression manifest.
    localparam integer MAX_CHANNELS = 1024;
    localparam integer MAX_PASSES = 64;
    localparam integer EPOCH_W = 8;
    localparam integer MAX_RAW_BYTES = 180000;
    localparam integer LINE_BANK_DEPTH = 2048;
    localparam integer LINE_AW = 11;

    reg clk;
    reg rst;
    reg cfg_start;
    reg [15:0] cfg_fm_h;
    reg [15:0] cfg_fm_w;
    reg [13:0] cfg_cin;
    reg [15:0] cfg_ofm_h;
    reg [15:0] cfg_ofm_w;
    reg cfg_kernel_1x1;
    reg [1:0] cfg_stride;
    reg [1:0] cfg_pad;
    reg [7:0] cfg_input_zero_point;
    reg [EPOCH_W-1:0] cfg_epoch;

    wire s_axis_tready;
    reg s_axis_tvalid;
    reg [AXIS_W-1:0] s_axis_tdata;
    reg [KEEP_W-1:0] s_axis_tkeep;
    reg s_axis_tlast;

    wire m_entry_valid;
    reg m_entry_ready;
    wire [ROWS*8-1:0] m_entry_data;
    wire [ROWS-1:0] m_entry_lane_valid;
    wire [31:0] m_entry_pixel;
    wire [15:0] m_entry_k_pass;
    wire [EPOCH_W-1:0] m_entry_epoch;
    wire m_entry_last;

    wire [MAX_PASSES-1:0] pass_ready_bitmap;
    wire [EPOCH_W-1:0] pass_ready_epoch;
    wire busy;
    wire input_done;
    wire done;
    wire config_error;
    wire tkeep_error;
    wire tlast_error;
    wire overflow_error;
    wire bank_collision_error;
    wire row_overwrite_error;
    wire protocol_error;
    wire [31:0] accepted_beats;
    wire [31:0] accepted_bytes;
    wire [31:0] emitted_entries;
    wire [31:0] axis_stall_cycles;
    wire [31:0] entry_stall_cycles;
    wire [31:0] materialize_cycles;
    wire [31:0] cfg_expected_bytes =
        cfg_fm_h * cfg_fm_w * cfg_cin;

    // A lockstep formal-path instance makes the prevalidated generate branch
    // part of the normal XSIM regression.  Valid descriptors must be
    // cycle-identical to the standalone fail-closed instance above it.
    wire pre_s_axis_tready;
    wire pre_m_entry_valid;
    wire [ROWS*8-1:0] pre_m_entry_data;
    wire [ROWS-1:0] pre_m_entry_lane_valid;
    wire [31:0] pre_m_entry_pixel;
    wire [15:0] pre_m_entry_k_pass;
    wire [EPOCH_W-1:0] pre_m_entry_epoch;
    wire pre_m_entry_last;
    wire [MAX_PASSES-1:0] pre_pass_ready_bitmap;
    wire [EPOCH_W-1:0] pre_pass_ready_epoch;
    wire pre_busy;
    wire pre_input_done;
    wire pre_done;
    wire pre_config_error;
    wire pre_tkeep_error;
    wire pre_tlast_error;
    wire pre_overflow_error;
    wire pre_bank_collision_error;
    wire pre_row_overwrite_error;
    wire pre_protocol_error;
    wire [31:0] pre_accepted_beats;
    wire [31:0] pre_accepted_bytes;
    wire [31:0] pre_emitted_entries;
    wire [31:0] pre_axis_stall_cycles;
    wire [31:0] pre_entry_stall_cycles;
    wire [31:0] pre_materialize_cycles;

    reg [7:0] raw_mem [0:MAX_RAW_BYTES-1];
    integer errors;
    integer observed_entries;
    integer case_h;
    integer case_w;
    integer case_cin;
    integer case_oh;
    integer case_ow;
    integer case_kernel;
    integer case_stride;
    integer case_pad;
    integer case_passes;
    integer case_total_bytes;
    integer case_expected_entries;
    integer case_id;
    integer timeout_cycles;
    integer random_seed;
    integer case_defer_cycles;
    integer case_rw_overlap_cycles;
    integer case_finish_drain_cycles;
    integer case_back_to_back_m1_cycles;
    integer case_input_refill_cycles;
    integer fifo_empty_seen;
    integer fifo_one_seen;
    integer fifo_full_seen;
    integer fifo_full_stall_seen;
    integer fifo_enqueue_pop_seen;
    integer fifo_row_retained_seen;
    integer fifo_defer_priority_seen;
    integer fifo_accept_closed_seen;
    integer m1_held_seen;
    integer m1_issue_refill_seen;
    integer m1_defer_no_refill_seen;
    integer s0_drain_refill_seen;
    integer phase_a_seen;
    integer phase_b_seen;
    integer m0_row_quiet_seen;
    integer case_phase_a_count;
    integer case_phase_b_count;
    integer s0_load_identity_seen;
    integer s0_to_m0_identity_seen;
    integer fifo_low_to_upper_seen;
    integer fifo_low_tail_pop_seen;
    integer fifo_upper_pop_seen;
    integer m1_nohazard_interval_seen;
    integer case_clock_count;
    integer m1_nohazard_last_cycle;
    reg m1_nohazard_chain_q;
    integer m0_row_hold_state;
    integer m0_row_hold_capture_seen;
    integer m0_row_hold_map_seen;
    integer m0_row_hold_issue_seen;
    integer m1_row_hold_watchdog;
    integer m1_row_admit_recovery_seen;
    integer m1_row_admit_recovery_watchdog;
    reg m1_row_admit_recovery_pending_q;
    reg m1_row_hazard_seen_q;
    reg m1_row_admit_reader_check_q;
    reg [31:0] m1_row_hazard_data_q;
    reg [3:0] m1_row_hazard_lane_valid_q;
    reg [3:0] m1_row_hazard_end_q;
    reg [15:0] m1_row_hazard_post_y_q;
    reg [15:0] m1_row_hazard_post_x_q;
    reg [13:0] m1_row_hazard_post_ch_q;
    reg m1_row_hazard_source_finish_q;
    reg m1_row_hazard_from_defer_q;
    reg m1_row_admit_pre_mat_active_q;
    reg [15:0] m1_row_admit_pre_mat_oy_q;
    reg [3:0] m1_row_admit_pre_active_rows_q;
    reg directed_m1_reader_hold_started_q;
    reg directed_m1_hazard_seen_q;
    reg directed_m1_payload_watch_started_q;
    reg directed_m1_payload_watch_active_q;
    integer directed_m1_reader_hold_cycles;
    integer directed_m1_hazard_count;
    integer directed_m1_issue_count;
    reg [31:0] directed_m1_data_q;
    reg [3:0] directed_m1_lane_valid_q;
    reg [3:0] directed_m1_end_q;
    reg [15:0] directed_m1_post_y_q;
    reg [15:0] directed_m1_post_x_q;
    reg [13:0] directed_m1_post_ch_q;
    reg directed_m1_source_finish_q;
    reg directed_m1_from_defer_q;
    integer busy_cfg_injected_seen;
    reg fifo_check_full_pop_recovery_q;
    reg fifo_check_accept_close_q;
    reg [63:0] case_stream_hash;
    reg [7:0] case_epoch;
    reg [7:0] case_zp;
    reg case_active;

    reg held_q;
    reg [ROWS*8-1:0] held_data_q;
    reg [ROWS-1:0] held_lane_valid_q;
    reg [31:0] held_pixel_q;
    reg [15:0] held_pass_q;
    reg [EPOCH_W-1:0] held_epoch_q;
    reg held_last_q;

    integer score_idx;
    integer score_row;
    integer score_rem;
    integer score_pass;
    integer score_x;
    integer score_lane;
    integer score_gk;
    integer score_ch;
    integer score_kp;
    integer score_ky;
    integer score_kx;
    integer score_fy;
    integer score_fx;
    integer score_raw_addr;
    integer score_ready_pass;
    reg [7:0] expected_byte;
    reg expected_lane_valid;

    // Cycle-exact oracle for the registered read-address recurrence.  It
    // reconstructs the pre-r3 stride/pad formula from mat_x/mat_oy and checks
    // every selected row-store address on every 1x1/3x3 read issue.
    integer read_oracle_base_fx;
    integer read_oracle_base_fy;
    integer read_oracle_first_pair;
    integer read_oracle_word_addr;
    integer read_oracle_row_bank;
    integer read_oracle_addr;
    integer read_oracle_group_offset;
    integer read_oracle_group_a;
    integer read_oracle_group_b;
    integer read_oracle_ky;
    integer read_oracle_bank;
    integer read_oracle_mode_index;
    integer read_oracle_addr_a [0:3];
    integer read_oracle_addr_b [0:3];
    integer read_oracle_valid_a [0:3];
    integer read_oracle_valid_b [0:3];
    integer read_oracle_raw_a;
    integer read_oracle_raw_b;
    integer read_oracle_fx;
    integer read_oracle_kx;
    integer read_oracle_tap;
    integer read_oracle_three_row_valid;
    integer read_oracle_three_mem_valid;
    integer read_oracle_three_use_b;
    integer read_oracle_one_spatial_valid;
    integer read_oracle_one_word_a_valid;
    integer read_oracle_one_word_b_valid;
    integer read_oracle_one_row_bank;
    integer read_oracle_one_x_odd;
    integer read_oracle_issues;
    integer read_oracle_mode_mask;
    integer read_oracle_row_start_seen;
    integer read_oracle_row_end_seen;
    integer read_oracle_bottom_seen;

    // Independent cycle-by-cycle shadow of the pre-retime ordered M1
    // allocator.  Keep this intentionally procedural: its serial prefix walk
    // is the oracle for the direct pairwise implementation in the DUT.
    reg [3:0] planner_oracle_commit_valid;
    reg [3:0] planner_oracle_mem_write;
    reg [3:0] planner_oracle_port_b;
    reg [3:0] planner_oracle_lane_row_oh [0:3];
    reg planner_oracle_defer_required;
    reg [31:0] planner_oracle_defer_data;
    reg [3:0] planner_oracle_defer_keep;
    reg [3:0] planner_oracle_defer_end;
    reg planner_oracle_overflow;
    reg planner_oracle_collision;
    reg [15:0] planner_oracle_post_y;
    reg [15:0] planner_oracle_post_x;
    reg [13:0] planner_oracle_post_ch;
    reg planner_oracle_post_x_odd;
    reg [15:0] planner_oracle_post_x_pair;
    reg [1:0] planner_oracle_post_ch_mod;
    reg [15:0] planner_oracle_post_ch_group;
    reg [LINE_AW-1:0] planner_oracle_post_word_addr;
    reg [2:0] planner_oracle_count;
    reg planner_oracle_finish;
    reg planner_oracle_store_finishes_beat;
    reg [3:0] planner_oracle_write_row_mask;
    reg [3:0] planner_oracle_row_start_mask;
    reg [15:0] planner_oracle_row_start_y [0:3];
    reg planner_oracle_row_completed;
    reg [15:0] planner_oracle_last_completed_y;
    reg [3:0] planner_oracle_commit_row_mask;
    reg [15:0] planner_oracle_commit_row_y [0:3];
    reg planner_oracle_overwrite;
    reg planner_oracle_write_safe;
    reg planner_oracle_issue;
    reg planner_oracle_ready;
    reg [3:0] planner_oracle_prefix_a_en;
    reg [3:0] planner_oracle_prefix_b_en;
    reg [LINE_AW-1:0] planner_oracle_prefix_a_addr [0:3];
    reg [LINE_AW-1:0] planner_oracle_prefix_b_addr [0:3];
    integer planner_oracle_i;
    integer planner_oracle_row;
    integer planner_oracle_compare_row;
    integer planner_oracle_frag_row;
    integer planner_oracle_defer_pack;
    integer planner_oracle_cursor_selected;
    integer planner_oracle_first_defer;
    integer planner_oracle_checks;
    integer planner_oracle_held_checks;
    integer planner_oracle_defer2_seen;
    integer planner_oracle_defer3_seen;

    // Pipeline-lifecycle monitor state.  These registers sample the state on
    // an active clock edge and check the committed post-edge state at the
    // following negedge, after all nonblocking assignments have settled.
    reg lifecycle_check_m3_q;
    reg [31:0] lifecycle_expected_stored_q;
    reg [15:0] lifecycle_expected_wr_y_q;
    reg [15:0] lifecycle_expected_wr_x_q;
    reg [13:0] lifecycle_expected_wr_ch_q;
    reg [31:0] lifecycle_expected_wr_word_q;
    reg lifecycle_expected_input_done_q;
    reg [3:0] lifecycle_expected_row_mask_q;
    reg [15:0] lifecycle_expected_row_y_q [0:3];
    reg lifecycle_pre_mat_active_q;
    reg [15:0] lifecycle_pre_mat_oy_q;
    reg lifecycle_pre_write_pending_q;
    reg lifecycle_finish_entered_q;
    integer lifecycle_row_i;
    reg phase_b_payload_check_q;
    reg [31:0] phase_b_expected_data_q;
    reg [3:0] phase_b_expected_keep_q;
    reg [3:0] phase_b_expected_end_q;
    reg [15:0] phase_b_expected_post_y_q;
    reg [15:0] phase_b_expected_post_x_q;
    reg [13:0] phase_b_expected_post_ch_q;
    reg phase_b_expected_finish_q;
    reg phase_b_expected_from_defer_q;

    // Deferred payload bits deliberately retain stale data once valid drops.
    // These edge-exact checks prove both consume and the next idle cfg_start
    // leave that payload untouched while defer_valid_q blocks any replay.
    reg defer_consume_stale_check_q;
    reg defer_idle_cfg_stale_check_q;
    reg defer_replace_check_q;
    reg defer_stale_available_q;
    reg [40:0] defer_consume_payload_q;
    reg [40:0] defer_idle_cfg_payload_q;
    reg [40:0] defer_replace_payload_q;
    integer defer_consume_stale_seen;
    integer defer_idle_cfg_stale_seen;
    integer defer_replace_seen;

    // Edge-exact S0/FIFO and S0-to-M0 oracles.  Expectations are sampled at
    // the active edge and checked at the following negedge after DUT NBAs.
    reg s0_load_check_q;
    reg [31:0] s0_load_expected_data_q;
    reg [3:0] s0_load_expected_keep_q;
    reg [3:0] s0_load_expected_end_q;
    reg s0_load_expected_finish_q;
    reg s0_load_expected_upper_q;
    reg s0_load_expected_rd_ptr_q;
    reg s0_load_expected_fifo_upper_q;
    reg [1:0] s0_load_retire_kind_q;
    reg s0_to_m0_check_q;
    reg [31:0] s0_to_m0_expected_data_q;
    reg [3:0] s0_to_m0_expected_keep_q;
    reg [3:0] s0_to_m0_expected_end_q;
    reg s0_to_m0_expected_finish_q;
    reg s0_to_m0_expected_upper_q;

    // A held M0 is allowed to survive the atomic row-reader admission.  This
    // oracle snapshots every M0 mapper field and the speculative cursor,
    // proves both remain stable on the admission edge, then follows that item
    // through exactly one Phase-B load and one M1 issue.
    reg m0_row_hold_edge_check_q;
    reg [31:0] m0_hold_data_q;
    reg [3:0] m0_hold_keep_q;
    reg [3:0] m0_hold_end_q;
    reg [15:0] m0_hold_lane_y_q [0:1];
    reg [15:0] m0_hold_lane_x_q [0:1];
    reg [13:0] m0_hold_lane_ch_q [0:1];
    reg [1:0] m0_hold_lane_row_bank_q [0:1];
    reg [LINE_AW-1:0] m0_hold_lane_addr_q [0:1];
    reg [2:0] m0_hold_lane_byte_q [0:1];
    reg [15:0] m0_hold_mid_wr_y_q;
    reg [15:0] m0_hold_mid_wr_x_q;
    reg [13:0] m0_hold_mid_wr_ch_q;
    reg m0_hold_mid_wr_x_odd_q;
    reg [15:0] m0_hold_mid_wr_x_pair_q;
    reg [1:0] m0_hold_mid_wr_ch_mod_q;
    reg [15:0] m0_hold_mid_wr_ch_group_q;
    reg [LINE_AW-1:0] m0_hold_mid_wr_word_addr_q;
    reg m0_hold_source_finishes_beat_q;
    reg m0_hold_source_from_defer_q;
    reg [15:0] m0_hold_spec_wr_y_q;
    reg [15:0] m0_hold_spec_wr_x_q;
    reg [13:0] m0_hold_spec_wr_ch_q;
    reg m0_hold_spec_wr_x_odd_q;
    reg [15:0] m0_hold_spec_wr_x_pair_q;
    reg [1:0] m0_hold_spec_wr_ch_mod_q;
    reg [15:0] m0_hold_spec_wr_ch_group_q;
    reg [LINE_AW-1:0] m0_hold_spec_wr_word_addr_q;
    reg [31:0] m0_hold_spec_stored_bytes_q;

    // Directed logical-end-in-defer monitor.  A shortened, test-only
    // expected-byte boundary places the logical final byte in the suffix of
    // a three-fragment Cin=5 micro-op.  The sampled expectations are checked
    // at the following negedge, after all DUT nonblocking updates settle.
    reg logical_end_defer_active;
    integer logical_end_defer_queued_seen;
    integer logical_end_defer_issued_seen;
    integer logical_end_defer_m1_seen;
    integer logical_end_defer_m2_seen;
    integer logical_end_defer_m3_seen;
    reg logical_end_check_m1_q;
    reg logical_end_expect_m1_valid_q;
    reg logical_end_expect_m1_finish_q;
    reg logical_end_check_m2_q;
    reg logical_end_expect_m2_valid_q;
    reg logical_end_expect_m2_finish_q;
    reg [31:0] logical_end_expect_m2_post_q;
    reg logical_end_check_m3_q;
    reg logical_end_expect_m3_valid_q;
    reg logical_end_expect_m3_finish_q;
    reg [31:0] logical_end_expect_m3_stored_q;
    reg [31:0] logical_end_expect_spec_q;
    reg logical_end_input_done_before_q;

    axis_hwc_window_materializer_byte_bram #(
        .ROWS(ROWS),
        .AXIS_W(AXIS_W),
        .KEEP_W(KEEP_W),
        .MAX_FM_W(MAX_FM_W),
        .MAX_CHANNELS(MAX_CHANNELS),
        .MAX_PASSES(MAX_PASSES),
        .EPOCH_W(EPOCH_W),
        .CFG_PREVALIDATED(0)
    ) dut (
        .clk(clk),
        .rst(rst),
        .cfg_start(cfg_start),
        .cfg_fm_h(cfg_fm_h),
        .cfg_fm_w(cfg_fm_w),
        .cfg_cin(cfg_cin),
        .cfg_ofm_h(cfg_ofm_h),
        .cfg_ofm_w(cfg_ofm_w),
        .cfg_kernel_1x1(cfg_kernel_1x1),
        .cfg_stride(cfg_stride),
        .cfg_pad(cfg_pad),
        .cfg_input_zero_point(cfg_input_zero_point),
        .cfg_epoch(cfg_epoch),
        .cfg_expected_bytes(cfg_expected_bytes),
        .cfg_prevalidated_pass_count(16'd0),
        .s_axis_tready(s_axis_tready),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .m_entry_valid(m_entry_valid),
        .m_entry_ready(m_entry_ready),
        .m_entry_data(m_entry_data),
        .m_entry_lane_valid(m_entry_lane_valid),
        .m_entry_pixel(m_entry_pixel),
        .m_entry_k_pass(m_entry_k_pass),
        .m_entry_epoch(m_entry_epoch),
        .m_entry_last(m_entry_last),
        .pass_ready_bitmap(pass_ready_bitmap),
        .pass_ready_epoch(pass_ready_epoch),
        .busy(busy),
        .input_done(input_done),
        .done(done),
        .config_error(config_error),
        .tkeep_error(tkeep_error),
        .tlast_error(tlast_error),
        .overflow_error(overflow_error),
        .bank_collision_error(bank_collision_error),
        .row_overwrite_error(row_overwrite_error),
        .protocol_error(protocol_error),
        .accepted_beats(accepted_beats),
        .accepted_bytes(accepted_bytes),
        .emitted_entries(emitted_entries),
        .axis_stall_cycles(axis_stall_cycles),
        .entry_stall_cycles(entry_stall_cycles),
        .materialize_cycles(materialize_cycles)
    );

    axis_hwc_window_materializer_byte_bram #(
        .ROWS(ROWS),
        .AXIS_W(AXIS_W),
        .KEEP_W(KEEP_W),
        .MAX_FM_W(MAX_FM_W),
        .MAX_CHANNELS(MAX_CHANNELS),
        .MAX_PASSES(MAX_PASSES),
        .EPOCH_W(EPOCH_W),
        .CFG_PREVALIDATED(1),
        // Differentially exercise both release primitive choices on every
        // randomized case: the primary DUT uses URAM, this mirror uses the
        // behavior-identical 16-BRAM row-store fallback.
        .LINE_STORE_USE_URAM(0)
    ) prevalidated_dut (
        .clk(clk),
        .rst(rst),
        .cfg_start(cfg_start),
        .cfg_fm_h(cfg_fm_h),
        .cfg_fm_w(cfg_fm_w),
        .cfg_cin(cfg_cin),
        .cfg_ofm_h(cfg_ofm_h),
        .cfg_ofm_w(cfg_ofm_w),
        .cfg_kernel_1x1(cfg_kernel_1x1),
        .cfg_stride(cfg_stride),
        .cfg_pad(cfg_pad),
        .cfg_input_zero_point(cfg_input_zero_point),
        .cfg_epoch(cfg_epoch),
        .cfg_expected_bytes(cfg_expected_bytes),
        .cfg_prevalidated_pass_count(cfg_kernel_1x1 ?
            ((cfg_cin + ROWS - 1) / ROWS) : ((cfg_cin + 1) >> 1)),
        .s_axis_tready(pre_s_axis_tready),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .m_entry_valid(pre_m_entry_valid),
        .m_entry_ready(m_entry_ready),
        .m_entry_data(pre_m_entry_data),
        .m_entry_lane_valid(pre_m_entry_lane_valid),
        .m_entry_pixel(pre_m_entry_pixel),
        .m_entry_k_pass(pre_m_entry_k_pass),
        .m_entry_epoch(pre_m_entry_epoch),
        .m_entry_last(pre_m_entry_last),
        .pass_ready_bitmap(pre_pass_ready_bitmap),
        .pass_ready_epoch(pre_pass_ready_epoch),
        .busy(pre_busy),
        .input_done(pre_input_done),
        .done(pre_done),
        .config_error(pre_config_error),
        .tkeep_error(pre_tkeep_error),
        .tlast_error(pre_tlast_error),
        .overflow_error(pre_overflow_error),
        .bank_collision_error(pre_bank_collision_error),
        .row_overwrite_error(pre_row_overwrite_error),
        .protocol_error(pre_protocol_error),
        .accepted_beats(pre_accepted_beats),
        .accepted_bytes(pre_accepted_bytes),
        .emitted_entries(pre_emitted_entries),
        .axis_stall_cycles(pre_axis_stall_cycles),
        .entry_stall_cycles(pre_entry_stall_cycles),
        .materialize_cycles(pre_materialize_cycles)
    );

    always #5 clk = ~clk;

    always @* begin
        planner_oracle_prefix_a_en = 4'd0;
        planner_oracle_prefix_b_en = 4'd0;
        planner_oracle_commit_valid = 4'd0;
        planner_oracle_mem_write = 4'd0;
        planner_oracle_port_b = 4'd0;
        planner_oracle_defer_required = 1'b0;
        planner_oracle_defer_data = 32'd0;
        planner_oracle_defer_keep = 4'd0;
        planner_oracle_defer_end = 4'd0;
        planner_oracle_overflow = 1'b0;
        planner_oracle_collision = 1'b0;
        planner_oracle_post_y = dut.m1_post_wr_y_q;
        planner_oracle_post_x = dut.m1_post_wr_x_q;
        planner_oracle_post_ch = dut.m1_post_wr_ch_q;
        planner_oracle_post_x_odd = dut.m1_post_wr_x_odd_q;
        planner_oracle_post_x_pair = dut.m1_post_wr_x_pair_q;
        planner_oracle_post_ch_mod = dut.m1_post_wr_ch_mod_q;
        planner_oracle_post_ch_group = dut.m1_post_wr_ch_group_q;
        planner_oracle_post_word_addr = dut.m1_post_wr_word_addr_q;
        planner_oracle_count = 3'd0;
        planner_oracle_finish = 1'b0;
        planner_oracle_store_finishes_beat = 1'b0;
        planner_oracle_write_row_mask = 4'd0;
        planner_oracle_row_start_mask = 4'd0;
        planner_oracle_row_completed = 1'b0;
        planner_oracle_last_completed_y = 16'd0;
        planner_oracle_commit_row_mask = 4'd0;
        planner_oracle_defer_pack = 0;
        planner_oracle_cursor_selected = 0;
        planner_oracle_first_defer = -1;
        for (planner_oracle_row = 0; planner_oracle_row < 4;
             planner_oracle_row = planner_oracle_row + 1) begin
            planner_oracle_prefix_a_addr[planner_oracle_row] =
                {LINE_AW{1'b0}};
            planner_oracle_prefix_b_addr[planner_oracle_row] =
                {LINE_AW{1'b0}};
            planner_oracle_row_start_y[planner_oracle_row] = 16'd0;
            planner_oracle_commit_row_y[planner_oracle_row] = 16'd0;
        end

        for (planner_oracle_i = 0; planner_oracle_i < 4;
             planner_oracle_i = planner_oracle_i + 1) begin
            planner_oracle_lane_row_oh[planner_oracle_i] =
                4'b0001 << dut.m1_lane_row_bank_q[planner_oracle_i];
            if (dut.m1_lane_valid_q[planner_oracle_i] &&
                !planner_oracle_defer_required) begin
                planner_oracle_frag_row =
                    dut.m1_lane_row_bank_q[planner_oracle_i];
                if ((dut.CFG_PREVALIDATED == 0) &&
                    dut.m1_lane_addr_q[planner_oracle_i] >=
                        LINE_BANK_DEPTH) begin
                    planner_oracle_overflow = 1'b1;
                    planner_oracle_commit_valid[planner_oracle_i] = 1'b1;
                end else if (!planner_oracle_prefix_a_en[
                                 planner_oracle_frag_row]) begin
                    planner_oracle_commit_valid[planner_oracle_i] = 1'b1;
                    planner_oracle_mem_write[planner_oracle_i] = 1'b1;
                    planner_oracle_prefix_a_en[planner_oracle_frag_row] =
                        1'b1;
                    planner_oracle_prefix_a_addr[planner_oracle_frag_row] =
                        dut.m1_lane_addr_q[planner_oracle_i];
                end else if (planner_oracle_prefix_a_addr[
                                 planner_oracle_frag_row] ==
                             dut.m1_lane_addr_q[planner_oracle_i]) begin
                    planner_oracle_commit_valid[planner_oracle_i] = 1'b1;
                    planner_oracle_mem_write[planner_oracle_i] = 1'b1;
                end else if (!planner_oracle_prefix_b_en[
                                 planner_oracle_frag_row]) begin
                    planner_oracle_commit_valid[planner_oracle_i] = 1'b1;
                    planner_oracle_mem_write[planner_oracle_i] = 1'b1;
                    planner_oracle_port_b[planner_oracle_i] = 1'b1;
                    planner_oracle_prefix_b_en[planner_oracle_frag_row] =
                        1'b1;
                    planner_oracle_prefix_b_addr[planner_oracle_frag_row] =
                        dut.m1_lane_addr_q[planner_oracle_i];
                end else if (planner_oracle_prefix_b_addr[
                                 planner_oracle_frag_row] ==
                             dut.m1_lane_addr_q[planner_oracle_i]) begin
                    planner_oracle_commit_valid[planner_oracle_i] = 1'b1;
                    planner_oracle_mem_write[planner_oracle_i] = 1'b1;
                    planner_oracle_port_b[planner_oracle_i] = 1'b1;
                end else begin
                    planner_oracle_defer_required = 1'b1;
                    planner_oracle_first_defer = planner_oracle_i;
                end
            end
        end

        for (planner_oracle_i = 0; planner_oracle_i < 4;
             planner_oracle_i = planner_oracle_i + 1) begin
            if (dut.m1_lane_valid_q[planner_oracle_i] &&
                !planner_oracle_commit_valid[planner_oracle_i]) begin
                planner_oracle_defer_data[
                    planner_oracle_defer_pack*8 +: 8] =
                    dut.m1_data_q[planner_oracle_i*8 +: 8];
                planner_oracle_defer_keep[planner_oracle_defer_pack] = 1'b1;
                planner_oracle_defer_end[planner_oracle_defer_pack] =
                    dut.m1_end_q[planner_oracle_i];
                planner_oracle_defer_pack = planner_oracle_defer_pack + 1;
                if (planner_oracle_cursor_selected == 0) begin
                    planner_oracle_post_y =
                        dut.m1_lane_y_q[planner_oracle_i];
                    planner_oracle_post_x =
                        dut.m1_lane_x_q[planner_oracle_i];
                    planner_oracle_post_ch =
                        dut.m1_lane_ch_q[planner_oracle_i];
                    planner_oracle_post_x_odd =
                        dut.m1_lane_x_q[planner_oracle_i][0];
                    planner_oracle_post_x_pair =
                        dut.m1_lane_x_q[planner_oracle_i] >> 1;
                    planner_oracle_post_ch_mod =
                        dut.m1_lane_ch_q[planner_oracle_i][1:0];
                    planner_oracle_post_ch_group =
                        dut.m1_lane_ch_q[planner_oracle_i] >> 2;
                    planner_oracle_post_word_addr =
                        dut.m1_lane_addr_q[planner_oracle_i];
                    planner_oracle_cursor_selected = 1;
                end
            end
            if (planner_oracle_commit_valid[planner_oracle_i]) begin
                planner_oracle_count = planner_oracle_count + 1'b1;
                if (dut.m1_end_q[planner_oracle_i])
                    planner_oracle_finish = 1'b1;
                planner_oracle_write_row_mask =
                    planner_oracle_write_row_mask |
                    planner_oracle_lane_row_oh[planner_oracle_i];
                if (dut.m1_lane_x_q[planner_oracle_i] == 0 &&
                    dut.m1_lane_ch_q[planner_oracle_i] == 0) begin
                    planner_oracle_row_start_mask =
                        planner_oracle_row_start_mask |
                        planner_oracle_lane_row_oh[planner_oracle_i];
                    planner_oracle_row_start_y[
                        dut.m1_lane_row_bank_q[planner_oracle_i]] =
                        dut.m1_lane_y_q[planner_oracle_i];
                end
                if ((dut.m1_lane_ch_q[planner_oracle_i] + 1'b1 ==
                        dut.cin_q) &&
                    (dut.m1_lane_x_q[planner_oracle_i] + 1'b1 ==
                        dut.fm_w_q)) begin
                    planner_oracle_row_completed = 1'b1;
                    planner_oracle_last_completed_y =
                        dut.m1_lane_y_q[planner_oracle_i];
                    planner_oracle_commit_row_mask =
                        planner_oracle_commit_row_mask |
                        planner_oracle_lane_row_oh[planner_oracle_i];
                    planner_oracle_commit_row_y[
                        dut.m1_lane_row_bank_q[planner_oracle_i]] =
                        dut.m1_lane_y_q[planner_oracle_i];
                end
            end
        end
        planner_oracle_store_finishes_beat =
            dut.m1_source_finishes_beat_q &&
            !planner_oracle_defer_required;
        planner_oracle_collision = planner_oracle_defer_required &&
                                   dut.m1_source_from_defer_q;
        planner_oracle_overwrite = 1'b0;
        for (planner_oracle_row = 0; planner_oracle_row < 4;
             planner_oracle_row = planner_oracle_row + 1)
            if (planner_oracle_row_start_mask[planner_oracle_row] &&
                dut.spec_row_valid_q[planner_oracle_row] &&
                dut.spec_row_tag_q[planner_oracle_row] !=
                    planner_oracle_row_start_y[planner_oracle_row] &&
                dut.spec_row_tag_q[planner_oracle_row] >=
                    dut.m1_min_needed_y_q)
                planner_oracle_overwrite = 1'b1;
        planner_oracle_write_safe =
            !(|(planner_oracle_write_row_mask & dut.active_read_rows));
        planner_oracle_issue = dut.m1_valid_q &&
            !dut.drain_issue_freeze && planner_oracle_write_safe &&
            !planner_oracle_overwrite;
        planner_oracle_ready = !dut.m1_valid_q ||
            (planner_oracle_issue && !planner_oracle_defer_required);
    end

    // Compare on every resident M1 cycle, including elastic hold cycles.  A
    // held item can see changing row-reader ownership, but its ordered plan
    // must remain a pure function of the stable M1 payload.
    always @(posedge clk) begin
        if (!rst && case_active && dut.m1_valid_q) begin
            planner_oracle_checks = planner_oracle_checks + 1;
            if (!dut.m1_issue)
                planner_oracle_held_checks =
                    planner_oracle_held_checks + 1;
            if (planner_oracle_first_defer == 2)
                planner_oracle_defer2_seen =
                    planner_oracle_defer2_seen + 1;
            if (planner_oracle_first_defer == 3)
                planner_oracle_defer3_seen =
                    planner_oracle_defer3_seen + 1;

            if (dut.m1_lane_commit_valid_comb !==
                    planner_oracle_commit_valid ||
                dut.m1_lane_mem_write_comb !== planner_oracle_mem_write ||
                dut.m1_lane_port_b_comb !== planner_oracle_port_b ||
                dut.m1_defer_required_comb !==
                    planner_oracle_defer_required ||
                dut.m1_defer_data_comb !== planner_oracle_defer_data ||
                dut.m1_defer_keep_comb !== planner_oracle_defer_keep ||
                dut.m1_defer_end_comb !== planner_oracle_defer_end ||
                dut.m1_bank_addr_overflow_comb !== planner_oracle_overflow ||
                dut.m1_bank_collision_comb !== planner_oracle_collision ||
                dut.m1_commit_post_wr_y_comb !== planner_oracle_post_y ||
                dut.m1_commit_post_wr_x_comb !== planner_oracle_post_x ||
                dut.m1_commit_post_wr_ch_comb !== planner_oracle_post_ch ||
                dut.m1_commit_post_wr_x_odd_comb !==
                    planner_oracle_post_x_odd ||
                dut.m1_commit_post_wr_x_pair_comb !==
                    planner_oracle_post_x_pair ||
                dut.m1_commit_post_wr_ch_mod_comb !==
                    planner_oracle_post_ch_mod ||
                dut.m1_commit_post_wr_ch_group_comb !==
                    planner_oracle_post_ch_group ||
                dut.m1_commit_post_wr_word_addr_comb !==
                    planner_oracle_post_word_addr ||
                dut.m1_committed_inc_comb !== planner_oracle_count ||
                dut.m1_finish_token_comb !== planner_oracle_finish ||
                dut.m1_store_finishes_beat_comb !==
                    planner_oracle_store_finishes_beat ||
                dut.m1_write_row_mask_comb !==
                    planner_oracle_write_row_mask ||
                dut.m1_row_start_mask_comb !==
                    planner_oracle_row_start_mask ||
                dut.m1_admit_defer_required_q !==
                    planner_oracle_defer_required ||
                dut.m1_admit_write_row_mask_q !==
                    planner_oracle_write_row_mask ||
                dut.m1_admit_row_start_mask_q !==
                    planner_oracle_row_start_mask ||
                dut.m1_admit_commit_row_completed_q !==
                    planner_oracle_row_completed ||
                dut.m1_admit_commit_row_mask_q !==
                    planner_oracle_commit_row_mask ||
                dut.m1_overwrite_comb !== planner_oracle_overwrite ||
                dut.m1_mapped_write_safe !== planner_oracle_write_safe ||
                dut.m1_issue !== planner_oracle_issue ||
                dut.m1_ready_for_load !== planner_oracle_ready ||
                dut.m1_row_event !==
                    (planner_oracle_issue && planner_oracle_row_completed) ||
                dut.m1_commit_row_completed_comb !==
                    planner_oracle_row_completed ||
                dut.m1_commit_last_completed_y_comb !==
                    planner_oracle_last_completed_y ||
                dut.m1_commit_row_mask_comb !==
                    planner_oracle_commit_row_mask) begin
                $display("PLANNER_ORACLE first_defer=%0d valid=%b row=%0d/%0d/%0d/%0d addr=%0d/%0d/%0d/%0d commit=%b/%b mem=%b/%b portB=%b/%b defer=%b/%b",
                         planner_oracle_first_defer,
                         dut.m1_lane_valid_q,
                         dut.m1_lane_row_bank_q[0],
                         dut.m1_lane_row_bank_q[1],
                         dut.m1_lane_row_bank_q[2],
                         dut.m1_lane_row_bank_q[3],
                         dut.m1_lane_addr_q[0], dut.m1_lane_addr_q[1],
                         dut.m1_lane_addr_q[2], dut.m1_lane_addr_q[3],
                         dut.m1_lane_commit_valid_comb,
                         planner_oracle_commit_valid,
                         dut.m1_lane_mem_write_comb,
                         planner_oracle_mem_write,
                         dut.m1_lane_port_b_comb,
                         planner_oracle_port_b,
                         dut.m1_defer_required_comb,
                         planner_oracle_defer_required);
                fail("direct pairwise M1 planner diverged from old ordered walk");
                $fatal(1, "M1 planner oracle divergence");
            end
            for (planner_oracle_compare_row = 0;
                 planner_oracle_compare_row < 4;
                 planner_oracle_compare_row =
                    planner_oracle_compare_row + 1) begin
                if (dut.m1_lane_row_oh_comb[planner_oracle_compare_row] !==
                        planner_oracle_lane_row_oh[
                            planner_oracle_compare_row] ||
                    dut.m1_row_start_y_comb[planner_oracle_compare_row] !==
                        planner_oracle_row_start_y[
                            planner_oracle_compare_row] ||
                    dut.m1_admit_row_start_y_q[
                        planner_oracle_compare_row] !==
                        planner_oracle_row_start_y[
                            planner_oracle_compare_row] ||
                    dut.m1_commit_row_y_comb[planner_oracle_compare_row] !==
                        planner_oracle_commit_row_y[
                            planner_oracle_compare_row]) begin
                    $display("PLANNER_ORACLE_ROW row=%0d lane_oh=%b/%b start_y=%0d/%0d commit_y=%0d/%0d",
                             planner_oracle_compare_row,
                             dut.m1_lane_row_oh_comb[
                                planner_oracle_compare_row],
                             planner_oracle_lane_row_oh[
                                planner_oracle_compare_row],
                             dut.m1_row_start_y_comb[
                                planner_oracle_compare_row],
                             planner_oracle_row_start_y[
                                planner_oracle_compare_row],
                             dut.m1_commit_row_y_comb[
                                planner_oracle_compare_row],
                             planner_oracle_commit_row_y[
                                planner_oracle_compare_row]);
                    fail("M1 planner row metadata diverged from old ordered walk");
                    $fatal(1, "M1 planner row oracle divergence");
                end
            end
        end
    end

    function [7:0] centered_byte;
        input [7:0] raw_u8;
        input [7:0] zero_point;
        integer signed centered;
        begin
            centered = raw_u8 - zero_point;
            if (centered > 127)
                centered_byte = 8'h7f;
            else if (centered < -128)
                centered_byte = 8'h80;
            else
                centered_byte = centered[7:0];
        end
    endfunction

    // Golden stream hashes are descriptor-specific and intentionally fixed.
    // Checking every functional case turns the printed hashes into a release
    // gate instead of diagnostics that can silently drift.
    function [63:0] expected_case_hash;
        input integer hash_case_id;
        begin
            case (hash_case_id)
                1: expected_case_hash = 64'h2c07ae59461d5370;
                2: expected_case_hash = 64'h9ec12155194a4fc6;
                3: expected_case_hash = 64'he9e4a1c6ff498ba5;
                4: expected_case_hash = 64'h48affd0f8f258b78;
                5: expected_case_hash = 64'h4ec50da333411dd6;
                6: expected_case_hash = 64'h338c7937a6144b6c;
                7: expected_case_hash = 64'h813ba58c13211622;
                8: expected_case_hash = 64'h0aace258dc0328df;
                9: expected_case_hash = 64'h015d1342f8c19642;
                10: expected_case_hash = 64'hdda083f576157d0b;
                11: expected_case_hash = 64'he63813ec6bb590c1;
                12: expected_case_hash = 64'h14e2ab4efd8d15ae;
                default: expected_case_hash = 64'hxxxxxxxxxxxxxxxx;
            endcase
        end
    endfunction

    function m0_hold_payload_matches;
        input unused_payload_arg;
        integer hold_lane;
        begin
            m0_hold_payload_matches = dut.m0_valid_q &&
                dut.m0_data_q === m0_hold_data_q &&
                dut.m0_keep_q === m0_hold_keep_q &&
                dut.m0_end_q === m0_hold_end_q &&
                dut.m0_mid_wr_y_q === m0_hold_mid_wr_y_q &&
                dut.m0_mid_wr_x_q === m0_hold_mid_wr_x_q &&
                dut.m0_mid_wr_ch_q === m0_hold_mid_wr_ch_q &&
                dut.m0_mid_wr_x_odd_q === m0_hold_mid_wr_x_odd_q &&
                dut.m0_mid_wr_x_pair_q === m0_hold_mid_wr_x_pair_q &&
                dut.m0_mid_wr_ch_mod_q === m0_hold_mid_wr_ch_mod_q &&
                dut.m0_mid_wr_ch_group_q ===
                    m0_hold_mid_wr_ch_group_q &&
                dut.m0_mid_wr_word_addr_q ===
                    m0_hold_mid_wr_word_addr_q &&
                dut.m0_source_finishes_beat_q ===
                    m0_hold_source_finishes_beat_q &&
                dut.m0_source_from_defer_q ===
                    m0_hold_source_from_defer_q;
            for (hold_lane = 0; hold_lane < 2;
                 hold_lane = hold_lane + 1)
                m0_hold_payload_matches = m0_hold_payload_matches &&
                    dut.m0_lane_y_q[hold_lane] ===
                        m0_hold_lane_y_q[hold_lane] &&
                    dut.m0_lane_x_q[hold_lane] ===
                        m0_hold_lane_x_q[hold_lane] &&
                    dut.m0_lane_ch_q[hold_lane] ===
                        m0_hold_lane_ch_q[hold_lane] &&
                    dut.m0_lane_row_bank_q[hold_lane] ===
                        m0_hold_lane_row_bank_q[hold_lane] &&
                    dut.m0_lane_addr_q[hold_lane] ===
                        m0_hold_lane_addr_q[hold_lane] &&
                    dut.m0_lane_byte_q[hold_lane] ===
                        m0_hold_lane_byte_q[hold_lane];
        end
    endfunction

    function m0_hold_spec_matches;
        input unused_spec_arg;
        begin
            m0_hold_spec_matches =
                dut.spec_wr_y_q === m0_hold_spec_wr_y_q &&
                dut.spec_wr_x_q === m0_hold_spec_wr_x_q &&
                dut.spec_wr_ch_q === m0_hold_spec_wr_ch_q &&
                dut.spec_wr_x_odd_q === m0_hold_spec_wr_x_odd_q &&
                dut.spec_wr_x_pair_q === m0_hold_spec_wr_x_pair_q &&
                dut.spec_wr_ch_mod_q === m0_hold_spec_wr_ch_mod_q &&
                dut.spec_wr_ch_group_q ===
                    m0_hold_spec_wr_ch_group_q &&
                dut.spec_wr_word_addr_q ===
                    m0_hold_spec_wr_word_addr_q &&
                dut.spec_stored_bytes_q === m0_hold_spec_stored_bytes_q;
        end
    endfunction

    task fail;
        input [8*160-1:0] message;
        begin
            $display("FAIL case=%0d entry=%0d: %0s",
                     case_id, observed_entries, message);
            errors = errors + 1;
        end
    endtask

    task logical_end_defer_fail;
        input [8*160-1:0] message;
        begin
            fail(message);
            $fatal(1, "logical-end-in-defer directed assertion failed");
        end
    endtask

    always @(posedge clk) begin
        if (!rst) begin
            if (s_axis_tready !== pre_s_axis_tready) begin
                fail("prevalidated input ready diverged from local validator");
                $fatal(1, "materializer lockstep ready divergence");
            end
            if ({m_entry_valid, m_entry_data, m_entry_lane_valid,
                 m_entry_pixel, m_entry_k_pass, m_entry_epoch,
                 m_entry_last, pass_ready_bitmap, pass_ready_epoch} !==
                {pre_m_entry_valid, pre_m_entry_data,
                 pre_m_entry_lane_valid, pre_m_entry_pixel,
                 pre_m_entry_k_pass, pre_m_entry_epoch,
                 pre_m_entry_last, pre_pass_ready_bitmap,
                 pre_pass_ready_epoch}) begin
                fail("prevalidated entry stream diverged from local validator");
                $fatal(1, "materializer lockstep entry divergence");
            end
            if ({busy, input_done, done, config_error, tkeep_error,
                 tlast_error, overflow_error, bank_collision_error,
                 row_overwrite_error, protocol_error} !==
                {pre_busy, pre_input_done, pre_done, pre_config_error,
                 pre_tkeep_error, pre_tlast_error, pre_overflow_error,
                 pre_bank_collision_error, pre_row_overwrite_error,
                 pre_protocol_error}) begin
                fail("prevalidated status diverged from local validator");
                $fatal(1, "materializer lockstep status divergence");
            end
            if ({accepted_beats, accepted_bytes, emitted_entries,
                 axis_stall_cycles, entry_stall_cycles,
                 materialize_cycles} !==
                {pre_accepted_beats, pre_accepted_bytes,
                 pre_emitted_entries, pre_axis_stall_cycles,
                 pre_entry_stall_cycles, pre_materialize_cycles}) begin
                fail("prevalidated counters diverged from local validator");
                $fatal(1, "materializer lockstep counter divergence");
            end
        end
    end

    // Sample every accepted FIFO half at its S0 boundary and every S0 Phase-A
    // transfer.  These checks cover simultaneous S0 drain/refill as well as
    // low-only tails and the ordinary low-to-upper beat transition.
    always @(posedge clk) begin
        if (rst) begin
            s0_load_check_q <= 1'b0;
            s0_to_m0_check_q <= 1'b0;
        end else begin
            s0_load_check_q <= case_active && dut.source_slice_load;
            if (case_active && dut.source_slice_load) begin
                s0_load_expected_data_q <= dut.source_slice_data;
                s0_load_expected_keep_q <= dut.source_slice_keep;
                s0_load_expected_end_q <= dut.source_slice_end;
                s0_load_expected_finish_q <=
                    dut.source_slice_finishes_beat;
                s0_load_expected_upper_q <= dut.beat_fifo_upper_q;
                s0_load_expected_rd_ptr_q <= dut.beat_fifo_pop ?
                    ~dut.beat_fifo_rd_ptr_q : dut.beat_fifo_rd_ptr_q;
                s0_load_expected_fifo_upper_q <=
                    dut.beat_fifo_pop ? 1'b0 : 1'b1;
                if (dut.beat_fifo_upper_q)
                    s0_load_retire_kind_q <= 2'd2;
                else if (|dut.beat_fifo_head_keep[7:4])
                    s0_load_retire_kind_q <= 2'd0;
                else
                    s0_load_retire_kind_q <= 2'd1;

                if (dut.beat_fifo_upper_q && !dut.beat_fifo_pop)
                    fail("upper half did not retire its beat at S0 load");
                if (!dut.beat_fifo_upper_q &&
                    |dut.beat_fifo_head_keep[7:4] && dut.beat_fifo_pop)
                    fail("low half popped a beat with a valid upper half");
                if (!dut.beat_fifo_upper_q &&
                    !(|dut.beat_fifo_head_keep[7:4]) &&
                    !dut.beat_fifo_pop)
                    fail("low-only tail did not retire its beat at S0 load");
            end

            s0_to_m0_check_q <= case_active && dut.phase_a_from_s0;
            if (case_active && dut.phase_a_from_s0) begin
                s0_to_m0_expected_data_q <= dut.s0_data_q;
                s0_to_m0_expected_keep_q <= dut.s0_keep_q;
                s0_to_m0_expected_end_q <= dut.s0_end_q;
                s0_to_m0_expected_finish_q <= dut.s0_finishes_beat_q;
                s0_to_m0_expected_upper_q <= dut.s0_upper_q;
            end
        end
    end

    always @(negedge clk) begin
        if (!rst && s0_load_check_q) begin
            if (!dut.s0_valid_q ||
                {dut.s0_data_q, dut.s0_keep_q, dut.s0_end_q,
                 dut.s0_finishes_beat_q, dut.s0_upper_q} !==
                {s0_load_expected_data_q, s0_load_expected_keep_q,
                 s0_load_expected_end_q, s0_load_expected_finish_q,
                 s0_load_expected_upper_q})
                fail("S0 did not capture the exact FIFO half payload");
            if (dut.beat_fifo_rd_ptr_q !== s0_load_expected_rd_ptr_q ||
                dut.beat_fifo_upper_q !==
                    s0_load_expected_fifo_upper_q)
                fail("FIFO low/upper retirement edge changed pointers");
            s0_load_identity_seen = s0_load_identity_seen + 1;
            case (s0_load_retire_kind_q)
                0: fifo_low_to_upper_seen = fifo_low_to_upper_seen + 1;
                1: fifo_low_tail_pop_seen = fifo_low_tail_pop_seen + 1;
                2: fifo_upper_pop_seen = fifo_upper_pop_seen + 1;
            endcase
        end
        if (!rst && s0_to_m0_check_q) begin
            if (!dut.m0_valid_q ||
                {dut.m0_data_q, dut.m0_keep_q, dut.m0_end_q,
                 dut.m0_source_finishes_beat_q,
                 dut.m0_source_from_defer_q} !==
                {s0_to_m0_expected_data_q, s0_to_m0_expected_keep_q,
                 s0_to_m0_expected_end_q, s0_to_m0_expected_finish_q,
                 1'b0})
                fail("Phase A did not preserve the exact S0 payload");
            if (s0_to_m0_expected_upper_q &&
                !s0_to_m0_expected_finish_q)
                fail("an upper S0 half was not marked beat-final");
            s0_to_m0_identity_seen = s0_to_m0_identity_seen + 1;
        end
    end

    // Follow no-hazard M1 refill chains.  A Phase-A launch concurrent with a
    // normal M1 issue must produce the next M1 issue exactly two clocks later;
    // row/defer/overwrite holds explicitly terminate the no-hazard sample.
    always @(posedge clk) begin
        if (rst || !case_active) begin
            m1_nohazard_chain_q = 1'b0;
            case_clock_count = 0;
        end else begin
            case_clock_count = case_clock_count + 1;
            if (dut.phase_a_load)
                case_phase_a_count = case_phase_a_count + 1;
            if (dut.map_load)
                case_phase_b_count = case_phase_b_count + 1;

            if (m1_nohazard_chain_q) begin
                if (dut.m1_issue) begin
                    if (case_clock_count - m1_nohazard_last_cycle != 2)
                        fail("no-hazard M1 issue interval was not two clocks");
                    else
                        m1_nohazard_interval_seen =
                            m1_nohazard_interval_seen + 1;
                    m1_nohazard_chain_q = 1'b0;
                end else if ((dut.m0_valid_q && !dut.map_load) ||
                             (dut.m1_valid_q && !dut.m1_issue) ||
                             dut.drain_issue_freeze ||
                             dut.row_boundary_pending_q ||
                             dut.row_start_check_pending_q ||
                             dut.defer_valid_q) begin
                    m1_nohazard_chain_q = 1'b0;
                end else if (case_clock_count -
                             m1_nohazard_last_cycle >= 2) begin
                    fail("no-hazard M1 refill disappeared before issue");
                    m1_nohazard_chain_q = 1'b0;
                end
            end
            if (dut.m1_issue && dut.phase_a_load &&
                !dut.m1_defer_required_comb && !dut.m1_row_event &&
                !dut.drain_issue_freeze) begin
                m1_nohazard_chain_q = 1'b1;
                m1_nohazard_last_cycle = case_clock_count;
            end
        end
    end

    // Capture an M0 resident during the atomic row-admission freeze.  State 1
    // holds it through admission; state 2 follows the corresponding M1 until
    // its sole issue edge.  No later source is allowed to overtake it.
    always @(posedge clk) begin : m0_row_admission_oracle
        integer hold_lane;
        if (rst || !case_active) begin
            m0_row_hold_state = 0;
            m0_row_hold_edge_check_q <= 1'b0;
        end else begin
            m0_row_hold_edge_check_q <= 1'b0;
            case (m0_row_hold_state)
                0: if (dut.drain_issue_freeze && dut.m0_valid_q) begin
                    m0_hold_data_q = dut.m0_data_q;
                    m0_hold_keep_q = dut.m0_keep_q;
                    m0_hold_end_q = dut.m0_end_q;
                    for (hold_lane = 0; hold_lane < 2;
                         hold_lane = hold_lane + 1) begin
                        m0_hold_lane_y_q[hold_lane] =
                            dut.m0_lane_y_q[hold_lane];
                        m0_hold_lane_x_q[hold_lane] =
                            dut.m0_lane_x_q[hold_lane];
                        m0_hold_lane_ch_q[hold_lane] =
                            dut.m0_lane_ch_q[hold_lane];
                        m0_hold_lane_row_bank_q[hold_lane] =
                            dut.m0_lane_row_bank_q[hold_lane];
                        m0_hold_lane_addr_q[hold_lane] =
                            dut.m0_lane_addr_q[hold_lane];
                        m0_hold_lane_byte_q[hold_lane] =
                            dut.m0_lane_byte_q[hold_lane];
                    end
                    m0_hold_mid_wr_y_q = dut.m0_mid_wr_y_q;
                    m0_hold_mid_wr_x_q = dut.m0_mid_wr_x_q;
                    m0_hold_mid_wr_ch_q = dut.m0_mid_wr_ch_q;
                    m0_hold_mid_wr_x_odd_q = dut.m0_mid_wr_x_odd_q;
                    m0_hold_mid_wr_x_pair_q = dut.m0_mid_wr_x_pair_q;
                    m0_hold_mid_wr_ch_mod_q = dut.m0_mid_wr_ch_mod_q;
                    m0_hold_mid_wr_ch_group_q =
                        dut.m0_mid_wr_ch_group_q;
                    m0_hold_mid_wr_word_addr_q =
                        dut.m0_mid_wr_word_addr_q;
                    m0_hold_source_finishes_beat_q =
                        dut.m0_source_finishes_beat_q;
                    m0_hold_source_from_defer_q =
                        dut.m0_source_from_defer_q;
                    m0_hold_spec_wr_y_q = dut.spec_wr_y_q;
                    m0_hold_spec_wr_x_q = dut.spec_wr_x_q;
                    m0_hold_spec_wr_ch_q = dut.spec_wr_ch_q;
                    m0_hold_spec_wr_x_odd_q = dut.spec_wr_x_odd_q;
                    m0_hold_spec_wr_x_pair_q = dut.spec_wr_x_pair_q;
                    m0_hold_spec_wr_ch_mod_q = dut.spec_wr_ch_mod_q;
                    m0_hold_spec_wr_ch_group_q =
                        dut.spec_wr_ch_group_q;
                    m0_hold_spec_wr_word_addr_q =
                        dut.spec_wr_word_addr_q;
                    m0_hold_spec_stored_bytes_q =
                        dut.spec_stored_bytes_q;
                    m0_row_hold_capture_seen =
                        m0_row_hold_capture_seen + 1;
                    m0_row_hold_state = 1;
                    m0_row_hold_edge_check_q <= 1'b1;
                end
                1: begin
                    if (!m0_hold_payload_matches(1'b0))
                        fail("held M0 payload changed before row admission");
                    if (!m0_hold_spec_matches(1'b0))
                        fail("speculative cursor advanced while M0 was held");
                    if (dut.map_load) begin
                        m0_row_hold_map_seen = m0_row_hold_map_seen + 1;
                        m0_row_hold_state = 2;
                    end
                end
                default: begin
                    if (!dut.m1_valid_q ||
                        dut.m1_data_q !== m0_hold_data_q ||
                        dut.m1_end_q !== m0_hold_end_q ||
                        dut.m1_source_finishes_beat_q !==
                            m0_hold_source_finishes_beat_q ||
                        dut.m1_source_from_defer_q !==
                            m0_hold_source_from_defer_q)
                        fail("row-held M0 did not remain the resident M1 item");
                    if (dut.m1_issue) begin
                        m0_row_hold_issue_seen =
                            m0_row_hold_issue_seen + 1;
                        m0_row_hold_state = 0;
                    end
                end
            endcase
        end
    end

    always @(negedge clk) begin
        if (!rst && m0_row_hold_edge_check_q) begin
            if (!m0_hold_payload_matches(1'b0))
                fail("M0 payload changed on the row-admission edge");
            if (!m0_hold_spec_matches(1'b0))
                fail("speculative cursor changed on the row-admission edge");
        end
    end

    always @(posedge clk) begin
        if (!rst && case_active &&
            (dut.issue_three || dut.issue_one)) begin
            read_oracle_issues = read_oracle_issues + 1;
            read_oracle_mode_index = (dut.kernel_1x1_q ? 4 : 0) +
                ((dut.stride_q == 2) ? 2 : 0) + dut.pad_q;
            read_oracle_mode_mask = read_oracle_mode_mask |
                                    (1 << read_oracle_mode_index);
            if (dut.mat_x_q == 0)
                read_oracle_row_start_seen =
                    read_oracle_row_start_seen + 1;
            if (dut.mat_x_q + 1 == dut.ofm_w_q)
                read_oracle_row_end_seen = read_oracle_row_end_seen + 1;
            if (dut.mat_oy_q + 1 == dut.ofm_h_q)
                read_oracle_bottom_seen = read_oracle_bottom_seen + 1;

            read_oracle_base_fx =
                ((dut.stride_q == 2) ? (dut.mat_x_q << 1) :
                                       dut.mat_x_q) - dut.pad_q;
            read_oracle_first_pair = (read_oracle_base_fx < 0) ? 0 :
                                     (read_oracle_base_fx >> 1);
            read_oracle_word_addr = dut.mat_word_base_addr_q +
                                    read_oracle_first_pair;
            if (dut.mat_read_first_pair_q !==
                    read_oracle_first_pair[LINE_AW-1:0] ||
                dut.mat_read_word_addr_q !==
                    read_oracle_word_addr[LINE_AW:0]) begin
                $display("READ_ORACLE_STATE mode=%0s stride=%0d pad=%0d oy=%0d x=%0d pass=%0d got_pair/base=%0d/%0d expected=%0d/%0d",
                         dut.kernel_1x1_q ? "1x1" : "3x3",
                         dut.stride_q, dut.pad_q, dut.mat_oy_q,
                         dut.mat_x_q, dut.mat_pass_q,
                         dut.mat_read_first_pair_q,
                         dut.mat_read_word_addr_q,
                         read_oracle_first_pair,
                         read_oracle_word_addr);
                fail("registered read-address state diverged from old formula");
                $fatal(1, "read-address recurrence divergence");
            end

            for (read_oracle_bank = 0; read_oracle_bank < 4;
                 read_oracle_bank = read_oracle_bank + 1) begin
                read_oracle_addr_a[read_oracle_bank] = 0;
                read_oracle_addr_b[read_oracle_bank] = 0;
                read_oracle_valid_a[read_oracle_bank] = 0;
                read_oracle_valid_b[read_oracle_bank] = 0;
            end
            read_oracle_three_row_valid = 0;
            read_oracle_three_mem_valid = 0;
            read_oracle_three_use_b = 0;
            read_oracle_one_spatial_valid = 0;
            read_oracle_one_word_a_valid = 0;
            read_oracle_one_word_b_valid = 0;
            read_oracle_one_row_bank = 0;
            read_oracle_one_x_odd = 0;

            read_oracle_base_fy =
                ((dut.stride_q == 2) ? (dut.mat_oy_q << 1) :
                                       dut.mat_oy_q) - dut.pad_q;
            if (dut.issue_three) begin
                read_oracle_raw_a = read_oracle_word_addr;
                read_oracle_raw_b = read_oracle_word_addr + 1;
                for (read_oracle_ky = 0; read_oracle_ky < 3;
                     read_oracle_ky = read_oracle_ky + 1) begin
                    read_oracle_addr = read_oracle_base_fy +
                                       read_oracle_ky;
                    if (read_oracle_addr >= 0 &&
                        read_oracle_addr < dut.fm_h_q) begin
                        read_oracle_row_bank = read_oracle_addr & 3;
                        if (dut.row_valid_q[read_oracle_row_bank] &&
                            dut.row_tag_q[read_oracle_row_bank] ==
                                read_oracle_addr) begin
                            read_oracle_three_row_valid =
                                read_oracle_three_row_valid |
                                (1 << read_oracle_ky);
                            if (read_oracle_word_addr < LINE_BANK_DEPTH) begin
                                read_oracle_addr_a[
                                    read_oracle_row_bank] =
                                    read_oracle_word_addr;
                                read_oracle_valid_a[
                                    read_oracle_row_bank] = 1;
                            end
                            if (read_oracle_first_pair + 1 <
                                    dut.x_pairs_q &&
                                read_oracle_word_addr + 1 <
                                    LINE_BANK_DEPTH) begin
                                read_oracle_addr_b[
                                    read_oracle_row_bank] =
                                    read_oracle_word_addr + 1;
                                read_oracle_valid_b[
                                    read_oracle_row_bank] = 1;
                            end
                            for (read_oracle_kx = 0;
                                 read_oracle_kx < 3;
                                 read_oracle_kx = read_oracle_kx + 1) begin
                                read_oracle_fx = read_oracle_base_fx +
                                                 read_oracle_kx;
                                read_oracle_tap = read_oracle_ky * 3 +
                                                  read_oracle_kx;
                                if (read_oracle_fx >= 0 &&
                                    read_oracle_fx < dut.fm_w_q) begin
                                    read_oracle_three_mem_valid =
                                        read_oracle_three_mem_valid |
                                        (1 << read_oracle_tap);
                                    if ((read_oracle_fx >> 1) !=
                                        read_oracle_first_pair)
                                        read_oracle_three_use_b =
                                            read_oracle_three_use_b |
                                            (1 << read_oracle_tap);
                                end
                            end
                        end
                    end
                end
            end else begin
                read_oracle_group_a = (dut.mat_base_ch_q >> 2) +
                                      (dut.one_issue_group_q << 1);
                read_oracle_group_b = read_oracle_group_a + 1;
                case (dut.one_issue_group_q)
                    1: read_oracle_group_offset = dut.x_pairs_q << 1;
                    2: read_oracle_group_offset = dut.x_pairs_q << 2;
                    default: read_oracle_group_offset = 0;
                endcase
                read_oracle_raw_a = read_oracle_word_addr +
                                    read_oracle_group_offset;
                read_oracle_raw_b = read_oracle_raw_a + dut.x_pairs_q;
                if (read_oracle_base_fy >= 0 &&
                    read_oracle_base_fy < dut.fm_h_q &&
                    read_oracle_base_fx >= 0 &&
                    read_oracle_base_fx < dut.fm_w_q) begin
                    read_oracle_row_bank = read_oracle_base_fy & 3;
                    read_oracle_one_row_bank = read_oracle_row_bank;
                    read_oracle_one_x_odd = read_oracle_base_fx & 1;
                    if (dut.row_valid_q[read_oracle_row_bank] &&
                        dut.row_tag_q[read_oracle_row_bank] ==
                            read_oracle_base_fy) begin
                        read_oracle_one_spatial_valid = 1;
                        read_oracle_addr = read_oracle_word_addr +
                                           read_oracle_group_offset;
                        if (read_oracle_group_a < dut.channel_groups_q &&
                            read_oracle_addr < LINE_BANK_DEPTH) begin
                            read_oracle_addr_a[read_oracle_row_bank] =
                                read_oracle_addr;
                            read_oracle_valid_a[read_oracle_row_bank] = 1;
                            read_oracle_one_word_a_valid = 1;
                        end
                        read_oracle_addr = read_oracle_word_addr +
                            read_oracle_group_offset + dut.x_pairs_q;
                        if (read_oracle_group_b < dut.channel_groups_q &&
                            read_oracle_addr < LINE_BANK_DEPTH) begin
                            read_oracle_addr_b[read_oracle_row_bank] =
                                read_oracle_addr;
                            read_oracle_valid_b[read_oracle_row_bank] = 1;
                            read_oracle_one_word_b_valid = 1;
                        end
                    end
                end
            end

            for (read_oracle_bank = 0; read_oracle_bank < 4;
                 read_oracle_bank = read_oracle_bank + 1) begin
                if (dut.read_addr_a[read_oracle_bank] !==
                        read_oracle_raw_a[LINE_AW-1:0] ||
                    dut.read_addr_b[read_oracle_bank] !==
                        read_oracle_raw_b[LINE_AW-1:0] ||
                    (read_oracle_valid_a[read_oracle_bank] &&
                     dut.read_addr_a[read_oracle_bank] !==
                        read_oracle_addr_a[
                            read_oracle_bank][LINE_AW-1:0]) ||
                    (read_oracle_valid_b[read_oracle_bank] &&
                     dut.read_addr_b[read_oracle_bank] !==
                        read_oracle_addr_b[
                            read_oracle_bank][LINE_AW-1:0])) begin
                    $display("READ_ORACLE_BANK mode=%0s stride=%0d pad=%0d oy=%0d x=%0d pass=%0d group=%0d bank=%0d valid=%0d/%0d got=%0d/%0d raw=%0d/%0d old=%0d/%0d",
                             dut.kernel_1x1_q ? "1x1" : "3x3",
                             dut.stride_q, dut.pad_q, dut.mat_oy_q,
                             dut.mat_x_q, dut.mat_pass_q,
                             dut.one_issue_group_q, read_oracle_bank,
                             read_oracle_valid_a[read_oracle_bank],
                             read_oracle_valid_b[read_oracle_bank],
                             dut.read_addr_a[read_oracle_bank],
                             dut.read_addr_b[read_oracle_bank],
                             read_oracle_raw_a,
                             read_oracle_raw_b,
                             read_oracle_addr_a[read_oracle_bank],
                             read_oracle_addr_b[read_oracle_bank]);
                    fail("broadcast read address/port select diverged from oracle");
                    $fatal(1, "read-address bank divergence");
                end
            end
            if (dut.issue_three) begin
                if (dut.three_row_valid !==
                        read_oracle_three_row_valid[2:0] ||
                    dut.three_mem_valid !==
                        read_oracle_three_mem_valid[8:0] ||
                    dut.three_use_b !== read_oracle_three_use_b[8:0]) begin
                    $display("READ_ORACLE_3X3 valid/mem/use got=%b/%b/%b expected=%b/%b/%b",
                             dut.three_row_valid, dut.three_mem_valid,
                             dut.three_use_b,
                             read_oracle_three_row_valid[2:0],
                             read_oracle_three_mem_valid[8:0],
                             read_oracle_three_use_b[8:0]);
                    fail("3x3 descriptor valid/port select diverged from oracle");
                    $fatal(1, "3x3 read descriptor divergence");
                end
            end else if ({dut.one_issue_spatial_valid,
                           dut.one_issue_word_a_valid,
                           dut.one_issue_word_b_valid,
                           dut.one_issue_row_bank,
                           dut.one_issue_x_odd} !==
                          {read_oracle_one_spatial_valid[0],
                           read_oracle_one_word_a_valid[0],
                           read_oracle_one_word_b_valid[0],
                           read_oracle_one_row_bank[1:0],
                           read_oracle_one_x_odd[0]}) begin
                $display("READ_ORACLE_1X1 spatial/A/B/bank/odd got=%b/%b/%b/%0d/%b expected=%b/%b/%b/%0d/%b",
                         dut.one_issue_spatial_valid,
                         dut.one_issue_word_a_valid,
                         dut.one_issue_word_b_valid,
                         dut.one_issue_row_bank, dut.one_issue_x_odd,
                         read_oracle_one_spatial_valid,
                         read_oracle_one_word_a_valid,
                         read_oracle_one_word_b_valid,
                         read_oracle_one_row_bank,
                         read_oracle_one_x_odd);
                fail("1x1 descriptor valid/port select diverged from oracle");
                $fatal(1, "1x1 read descriptor divergence");
            end
        end
    end

    // Focused M1/M2/M3 lifecycle checks.  Payload registers intentionally do
    // not reset, so every check is qualified solely by the sampled valid bit.
    always @(posedge clk) begin
        if (rst) begin
            lifecycle_check_m3_q <= 1'b0;
            lifecycle_pre_mat_active_q <= 1'b0;
            lifecycle_pre_mat_oy_q <= 16'd0;
            lifecycle_pre_write_pending_q <= 1'b0;
            lifecycle_finish_entered_q <= 1'b0;
            fifo_check_full_pop_recovery_q <= 1'b0;
            fifo_check_accept_close_q <= 1'b0;
            m1_row_hold_watchdog = 0;
            m1_row_admit_recovery_pending_q <= 1'b0;
            m1_row_admit_recovery_watchdog = 0;
            m1_row_hazard_seen_q <= 1'b0;
            m1_row_admit_reader_check_q <= 1'b0;
            phase_b_payload_check_q <= 1'b0;
            defer_consume_stale_check_q <= 1'b0;
            defer_idle_cfg_stale_check_q <= 1'b0;
            defer_replace_check_q <= 1'b0;
            defer_stale_available_q <= 1'b0;
        end else begin
            phase_b_payload_check_q <= case_active && dut.map_load;
            if (case_active && dut.map_load) begin
                phase_b_expected_data_q <= dut.m0_data_q;
                phase_b_expected_keep_q <= dut.lane_map_valid;
                phase_b_expected_end_q <= dut.m0_end_q;
                phase_b_expected_post_y_q <= dut.mapped_post_wr_y;
                phase_b_expected_post_x_q <= dut.mapped_post_wr_x;
                phase_b_expected_post_ch_q <= dut.mapped_post_wr_ch;
                phase_b_expected_finish_q <=
                    dut.m0_source_finishes_beat_q;
                phase_b_expected_from_defer_q <=
                    dut.m0_source_from_defer_q;
            end
            defer_consume_stale_check_q <= dut.phase_a_from_defer &&
                !(dut.m1_issue && dut.m1_defer_required_comb) &&
                ({dut.defer_data_q, dut.defer_keep_q, dut.defer_end_q,
                  dut.defer_finishes_beat_q} !== 41'd0);
            if (dut.phase_a_from_defer &&
                !(dut.m1_issue && dut.m1_defer_required_comb) &&
                ({dut.defer_data_q, dut.defer_keep_q, dut.defer_end_q,
                  dut.defer_finishes_beat_q} !== 41'd0)) begin
                defer_consume_payload_q <= {
                    dut.defer_data_q, dut.defer_keep_q, dut.defer_end_q,
                    dut.defer_finishes_beat_q
                };
                defer_stale_available_q <= 1'b1;
            end
            defer_idle_cfg_stale_check_q <= cfg_start && !dut.busy_q &&
                !dut.defer_valid_q && defer_stale_available_q;
            if (cfg_start && !dut.busy_q && !dut.defer_valid_q &&
                defer_stale_available_q)
                defer_idle_cfg_payload_q <= {
                    dut.defer_data_q, dut.defer_keep_q, dut.defer_end_q,
                    dut.defer_finishes_beat_q
                };
            defer_replace_check_q <= dut.phase_a_from_defer &&
                dut.m1_issue && dut.m1_defer_required_comb;
            if (dut.phase_a_from_defer && dut.m1_issue &&
                dut.m1_defer_required_comb)
                defer_replace_payload_q <= {
                    dut.m1_defer_data_comb, dut.m1_defer_keep_comb,
                    dut.m1_defer_end_comb,
                    dut.m1_source_finishes_beat_q
                };
            fifo_check_full_pop_recovery_q <= busy &&
                dut.beat_fifo_full && dut.beat_fifo_pop &&
                !dut.accept_closed_q;
            fifo_check_accept_close_q <= dut.axis_fire &&
                !dut.axis_beat_short;
            if (busy) begin
                case (dut.beat_fifo_valid_q)
                    2'b00: fifo_empty_seen = fifo_empty_seen + 1;
                    2'b01, 2'b10: fifo_one_seen = fifo_one_seen + 1;
                    2'b11: fifo_full_seen = fifo_full_seen + 1;
                    default: fail("accepted-beat FIFO valid state is unknown");
                endcase
                if (s_axis_tready !==
                    (dut.busy_q && !dut.accept_closed_q &&
                     !dut.beat_fifo_full))
                    fail("tready depends on more than busy/close/FIFO credit");
                if (!dut.beat_fifo_empty && !dut.beat_fifo_head_valid)
                    fail("accepted-beat FIFO head pointer selected an invalid slot");
                if (dut.beat_fifo_full && s_axis_tvalid &&
                    !s_axis_tready)
                    fifo_full_stall_seen = fifo_full_stall_seen + 1;
                if (dut.axis_fire && dut.beat_fifo_pop) begin
                    fifo_enqueue_pop_seen = fifo_enqueue_pop_seen + 1;
                    if (dut.beat_fifo_full ||
                        dut.beat_fifo_wr_ptr_q == dut.beat_fifo_rd_ptr_q)
                        fail("one-item enqueue+pop did not use distinct slots");
                end
                if ((dut.row_boundary_pending_q ||
                     dut.row_start_check_pending_q) &&
                    dut.s0_valid_q && !dut.s0_upper_q &&
                    !dut.phase_a_from_s0)
                    fifo_row_retained_seen = fifo_row_retained_seen + 1;
                if (dut.defer_valid_q) begin
                    fifo_defer_priority_seen = fifo_defer_priority_seen + 1;
                    if (dut.phase_a_from_s0)
                        fail("deferred suffix did not have issue priority");
                    if (dut.phase_a_from_defer !==
                        (!dut.m0_valid_q && dut.phase_a_m1_safe &&
                         !dut.drain_issue_freeze))
                        fail("deferred suffix phase A did not obey quiet/M0/M1 credit");
                end
                if (dut.accept_closed_q && !dut.beat_fifo_empty)
                    fifo_accept_closed_seen = fifo_accept_closed_seen + 1;
                if (dut.phase_a_from_s0 && !dut.fifo_boundary_issue_ok)
                    fail("S0 micro-op bypassed registered boundary policy");
                if (dut.phase_a_load && dut.map_load)
                    fail("two-phase mapper bypassed M0 in one cycle");
                if (dut.phase_a_load && !dut.phase_a_m1_safe)
                    fail("phase A speculated behind a held/deferred M1");
                if (dut.map_load &&
                    (!dut.m0_valid_q || dut.drain_issue_freeze))
                    fail("phase B loaded M1 without a live/unfrozen M0");
                if (dut.phase_a_load)
                    phase_a_seen = phase_a_seen + 1;
                if (dut.map_load)
                    phase_b_seen = phase_b_seen + 1;
                if (dut.phase_a_from_s0 && dut.source_slice_load)
                    s0_drain_refill_seen = s0_drain_refill_seen + 1;
                if (dut.row_start_check_pending_q &&
                    dut.row_drain_quiet_q &&
                    (dut.s0_valid_q || dut.m0_valid_q))
                    m0_row_quiet_seen = m0_row_quiet_seen + 1;
                if (dut.m1_issue &&
                    (!dut.m1_mapped_write_safe || dut.m1_overwrite_comb))
                    fail("held M1 issued without late row safety");
                if (dut.m1_valid_q && !dut.m1_issue)
                    m1_held_seen = m1_held_seen + 1;
                if (dut.m1_issue && dut.phase_a_load &&
                    !dut.m1_defer_required_comb)
                    m1_issue_refill_seen = m1_issue_refill_seen + 1;
                if (dut.m1_issue && dut.m1_defer_required_comb) begin
                    if (dut.map_load)
                        fail("deferred M1 issue illegally refilled in same cycle");
                    m1_defer_no_refill_seen =
                        m1_defer_no_refill_seen + 1;
                end
                // A row event may admit only the current beat continuation:
                // its registered upper half or an already-queued defer.  The
                // low half of the next beat remains behind the boundary gate.
                if (dut.m1_row_event && dut.phase_a_load &&
                    !(dut.phase_a_from_defer ||
                      (dut.phase_a_from_s0 && dut.s0_upper_q)))
                    fail("row event admitted a next-beat low half into M0");
                if ((dut.row_boundary_pending_q ||
                     dut.row_start_check_pending_q) &&
                    dut.phase_a_from_s0 && !dut.s0_upper_q)
                    fail("pending row boundary admitted an S0 low half");

                if (dut.m1_valid_q && !dut.m1_issue &&
                    (dut.row_boundary_pending_q ||
                     dut.row_start_check_pending_q)) begin
                    m1_row_hold_watchdog = m1_row_hold_watchdog + 1;
                    if (m1_row_hold_watchdog == 100000) begin
                        $display("M1_ROW_HOLD source_finish=%0b from_defer=%0b lane_valid=%b commit=%b banks=%0d/%0d/%0d/%0d active=%b overwrite=%0b",
                                 dut.m1_source_finishes_beat_q,
                                 dut.m1_source_from_defer_q,
                                 dut.m1_lane_valid_q,
                                 dut.m1_lane_commit_valid_comb,
                                 dut.m1_lane_row_bank_q[0],
                                 dut.m1_lane_row_bank_q[1],
                                 dut.m1_lane_row_bank_q[2],
                                 dut.m1_lane_row_bank_q[3],
                                 dut.active_read_rows_q,
                                 dut.m1_overwrite_comb);
                        fail("held M1 made no progress across row boundary");
                        $fatal(1, "elastic M1 row-boundary liveness failure");
                    end
                end else begin
                    m1_row_hold_watchdog = 0;
                end

                // Remember the exact elastic item only after it has observed
                // a real overwrite or active-row hazard.  A safe M1 held only
                // by drain_issue_freeze is not sufficient liveness coverage.
                if (!dut.m1_valid_q || dut.m1_issue) begin
                    m1_row_hazard_seen_q <= 1'b0;
                end else if (dut.row_start_check_pending_q &&
                             (dut.m1_overwrite_comb ||
                              !dut.m1_mapped_write_safe)) begin
                    if (!m1_row_hazard_seen_q) begin
                        m1_row_hazard_data_q <= dut.m1_data_q;
                        m1_row_hazard_lane_valid_q <= dut.m1_lane_valid_q;
                        m1_row_hazard_end_q <= dut.m1_end_q;
                        m1_row_hazard_post_y_q <= dut.m1_post_wr_y_q;
                        m1_row_hazard_post_x_q <= dut.m1_post_wr_x_q;
                        m1_row_hazard_post_ch_q <= dut.m1_post_wr_ch_q;
                        m1_row_hazard_source_finish_q <=
                            dut.m1_source_finishes_beat_q;
                        m1_row_hazard_from_defer_q <=
                            dut.m1_source_from_defer_q;
                    end
                    m1_row_hazard_seen_q <= 1'b1;
                end

                // A genuinely hazardous M1 is intentionally excluded from
                // the atomic row drain.  Arm the recovery proof only for the
                // same held payload; the following cycle must show that a
                // reader was actually admitted and its active mask changed.
                if (dut.row_start_check_pending_q &&
                    dut.row_write_pipe_drained && dut.m1_valid_q &&
                    !dut.m1_issue &&
                    (m1_row_hazard_seen_q || dut.m1_overwrite_comb ||
                     !dut.m1_mapped_write_safe)) begin
                    if (m1_row_hazard_seen_q &&
                        ({dut.m1_data_q, dut.m1_lane_valid_q,
                          dut.m1_end_q, dut.m1_post_wr_y_q,
                          dut.m1_post_wr_x_q, dut.m1_post_wr_ch_q,
                          dut.m1_source_finishes_beat_q,
                          dut.m1_source_from_defer_q} !==
                         {m1_row_hazard_data_q,
                          m1_row_hazard_lane_valid_q,
                          m1_row_hazard_end_q,
                          m1_row_hazard_post_y_q,
                          m1_row_hazard_post_x_q,
                          m1_row_hazard_post_ch_q,
                          m1_row_hazard_source_finish_q,
                          m1_row_hazard_from_defer_q}))
                        fail("hazardous M1 payload changed before row admission");
                    m1_row_admit_reader_check_q <= 1'b1;
                    m1_row_admit_pre_mat_active_q <= dut.mat_active_q;
                    m1_row_admit_pre_mat_oy_q <= dut.mat_oy_q;
                    m1_row_admit_pre_active_rows_q <=
                        dut.active_read_rows_q;
                    m1_row_admit_recovery_watchdog = 0;
                end else if (m1_row_admit_reader_check_q) begin
                    m1_row_admit_reader_check_q <= 1'b0;
                    if (dut.mat_active_q &&
                        (!m1_row_admit_pre_mat_active_q ||
                         dut.mat_oy_q != m1_row_admit_pre_mat_oy_q) &&
                        dut.active_read_rows_q !=
                            m1_row_admit_pre_active_rows_q) begin
                        if ({dut.m1_data_q, dut.m1_lane_valid_q,
                             dut.m1_end_q, dut.m1_post_wr_y_q,
                             dut.m1_post_wr_x_q, dut.m1_post_wr_ch_q,
                             dut.m1_source_finishes_beat_q,
                             dut.m1_source_from_defer_q} !==
                            {m1_row_hazard_data_q,
                             m1_row_hazard_lane_valid_q,
                             m1_row_hazard_end_q,
                             m1_row_hazard_post_y_q,
                             m1_row_hazard_post_x_q,
                             m1_row_hazard_post_ch_q,
                             m1_row_hazard_source_finish_q,
                             m1_row_hazard_from_defer_q})
                            fail("hazardous M1 payload changed across reader admission");
                        if (dut.m1_issue) begin
                            m1_row_admit_recovery_seen =
                                m1_row_admit_recovery_seen + 1;
                            m1_row_admit_recovery_pending_q <= 1'b0;
                        end else begin
                            m1_row_admit_recovery_pending_q <= 1'b1;
                        end
                    end
                end else if (m1_row_admit_recovery_pending_q) begin
                    if (dut.m1_issue) begin
                        m1_row_admit_recovery_pending_q <= 1'b0;
                        m1_row_admit_recovery_seen =
                            m1_row_admit_recovery_seen + 1;
                        m1_row_admit_recovery_watchdog = 0;
                    end else begin
                        if (!dut.m1_valid_q)
                            fail("held M1 disappeared after row admission");
                        m1_row_admit_recovery_watchdog =
                            m1_row_admit_recovery_watchdog + 1;
                        if (m1_row_admit_recovery_watchdog == 100000) begin
                            $display("M1_ROW_ADMIT_STALL source_finish=%0b from_defer=%0b banks=%0d/%0d/%0d/%0d active=%b overwrite=%0b",
                                     dut.m1_source_finishes_beat_q,
                                     dut.m1_source_from_defer_q,
                                     dut.m1_lane_row_bank_q[0],
                                     dut.m1_lane_row_bank_q[1],
                                     dut.m1_lane_row_bank_q[2],
                                     dut.m1_lane_row_bank_q[3],
                                     dut.active_read_rows_q,
                                     dut.m1_overwrite_comb);
                            fail("held M1 did not recover after row admission");
                            $fatal(1, "elastic M1 row-admission recovery failure");
                        end
                    end
                end
                if (!dut.row_start_check_pending_q &&
                    !m1_row_admit_reader_check_q &&
                    !m1_row_admit_recovery_pending_q)
                    m1_row_hazard_seen_q <= 1'b0;
            end else begin
                m1_row_hazard_seen_q <= 1'b0;
                m1_row_admit_reader_check_q <= 1'b0;
                m1_row_admit_recovery_pending_q <= 1'b0;
                m1_row_admit_recovery_watchdog = 0;
            end
            // A cfg_start pulse while already busy is an error indication,
            // but it must not suppress the ordinary M3 commit check.
            lifecycle_check_m3_q <= case_active &&
                                    (!cfg_start || dut.busy_q) &&
                                    dut.m2_valid_q;
            if (case_active && (!cfg_start || dut.busy_q) &&
                dut.m2_valid_q) begin
                lifecycle_expected_stored_q <=
                    dut.m2_stored_post_bytes_q;
                lifecycle_expected_wr_y_q <= dut.m2_post_wr_y_q;
                lifecycle_expected_wr_x_q <= dut.m2_post_wr_x_q;
                lifecycle_expected_wr_ch_q <= dut.m2_post_wr_ch_q;
                lifecycle_expected_wr_word_q <=
                    dut.m2_post_wr_word_addr_q;
                lifecycle_expected_input_done_q <=
                    dut.m2_store_finishes_input_q;
                lifecycle_expected_row_mask_q <=
                    dut.m2_commit_row_mask_q;
                for (lifecycle_row_i = 0; lifecycle_row_i < 4;
                     lifecycle_row_i = lifecycle_row_i + 1)
                    lifecycle_expected_row_y_q[lifecycle_row_i] <=
                        dut.m2_commit_row_y_q[lifecycle_row_i];
            end

            lifecycle_pre_mat_active_q <= dut.mat_active_q;
            lifecycle_pre_mat_oy_q <= dut.mat_oy_q;
            // M1 is elastic and may legally remain held across an atomic row
            // admission.  Only an M1 issue or registered M2 denotes a write
            // bundle that the admission edge must not cross.
            lifecycle_pre_write_pending_q <= dut.m1_issue || dut.m2_valid_q;
            lifecycle_finish_entered_q <= case_active && dut.m1_issue &&
                                           dut.m1_finish_token_comb;

            if (case_active && dut.finish_pending_q) begin
                case_finish_drain_cycles = case_finish_drain_cycles + 1;
                if (s_axis_tready !== 1'b0)
                    fail("tready remained high while finish was pending");
            end
            if (case_active && dut.m1_issue && dut.phase_a_load)
                case_back_to_back_m1_cycles =
                    case_back_to_back_m1_cycles + 1;
            if (case_active && dut.phase_a_from_s0 &&
                dut.source_slice_load)
                case_input_refill_cycles = case_input_refill_cycles + 1;
        end
    end

    always @(negedge clk) begin
        if (!rst) begin
            if (lifecycle_check_m3_q) begin
                if (dut.stored_bytes_q !== lifecycle_expected_stored_q ||
                    dut.wr_y_q !== lifecycle_expected_wr_y_q ||
                    dut.wr_x_q !== lifecycle_expected_wr_x_q ||
                    dut.wr_ch_q !== lifecycle_expected_wr_ch_q ||
                    dut.wr_word_addr_q !== lifecycle_expected_wr_word_q)
                    fail("M3 cursor/count commit did not match M2 payload");
                if (lifecycle_expected_input_done_q && !input_done)
                    fail("M3 final bundle did not commit input_done");
                for (lifecycle_row_i = 0; lifecycle_row_i < 4;
                     lifecycle_row_i = lifecycle_row_i + 1)
                    if (lifecycle_expected_row_mask_q[lifecycle_row_i] &&
                        (!dut.row_valid_q[lifecycle_row_i] ||
                         dut.row_tag_q[lifecycle_row_i] !==
                           lifecycle_expected_row_y_q[lifecycle_row_i]))
                        fail("M3 row metadata did not match M2 payload");
            end

            if (phase_b_payload_check_q &&
                ({dut.m1_data_q, dut.m1_lane_valid_q, dut.m1_end_q,
                  dut.m1_post_wr_y_q, dut.m1_post_wr_x_q,
                  dut.m1_post_wr_ch_q, dut.m1_source_finishes_beat_q,
                  dut.m1_source_from_defer_q} !==
                 {phase_b_expected_data_q, phase_b_expected_keep_q,
                  phase_b_expected_end_q, phase_b_expected_post_y_q,
                  phase_b_expected_post_x_q, phase_b_expected_post_ch_q,
                  phase_b_expected_finish_q,
                  phase_b_expected_from_defer_q}))
                fail("phase B did not transfer the exact M0 payload into M1");

            if (defer_consume_stale_check_q) begin
                if (dut.defer_valid_q || dut.phase_a_from_defer)
                    fail("consumed deferred suffix remained replayable");
                if ({dut.defer_data_q, dut.defer_keep_q, dut.defer_end_q,
                     dut.defer_finishes_beat_q} !==
                    defer_consume_payload_q)
                    fail("deferred payload changed when its valid bit retired");
                defer_consume_stale_seen = defer_consume_stale_seen + 1;
            end

            if (defer_idle_cfg_stale_check_q) begin
                if (dut.defer_valid_q || dut.phase_a_from_defer)
                    fail("idle cfg_start made stale deferred payload replayable");
                if ({dut.defer_data_q, dut.defer_keep_q, dut.defer_end_q,
                     dut.defer_finishes_beat_q} !==
                    defer_idle_cfg_payload_q)
                    fail("idle cfg_start rewrote invalid deferred payload");
                defer_idle_cfg_stale_seen = defer_idle_cfg_stale_seen + 1;
            end

            if (defer_replace_check_q) begin
                if (!dut.defer_valid_q)
                    fail("same-edge deferred replacement lost its valid bit");
                if ({dut.defer_data_q, dut.defer_keep_q, dut.defer_end_q,
                     dut.defer_finishes_beat_q} !== defer_replace_payload_q)
                    fail("old deferred payload overwrote same-edge replacement");
                defer_replace_seen = defer_replace_seen + 1;
            end

            if (case_active && dut.mat_active_q &&
                (!lifecycle_pre_mat_active_q ||
                 dut.mat_oy_q != lifecycle_pre_mat_oy_q) &&
                lifecycle_pre_write_pending_q)
                fail("row read was admitted with a pending write bundle");

            if (lifecycle_finish_entered_q &&
                (!dut.finish_pending_q || s_axis_tready !== 1'b0))
                fail("registered M1 finish metadata did not enter drain state");
            if (fifo_check_full_pop_recovery_q &&
                (dut.beat_fifo_full || s_axis_tready !== 1'b1))
                fail("FIFO credit did not restore ready after a full-state pop");
            if (fifo_check_accept_close_q &&
                (!dut.accept_closed_q || s_axis_tready !== 1'b0))
                fail("final accepted beat did not register accept_closed");
        end
    end

    // The directed suffix test is intentionally fail-fast: a misplaced end
    // token can otherwise allow the reader to run for many cycles before a
    // visible timeout.  Every pipeline relation is sampled on the committing
    // posedge and checked after NBA settlement at the following negedge.
    always @(posedge clk) begin
        if (rst || !logical_end_defer_active) begin
            logical_end_check_m1_q <= 1'b0;
            logical_end_check_m2_q <= 1'b0;
            logical_end_check_m3_q <= 1'b0;
            logical_end_input_done_before_q <= 1'b0;
        end else begin
            logical_end_check_m1_q <= 1'b1;
            logical_end_expect_m1_valid_q <=
                (!dut.m1_valid_q || dut.m1_issue) ?
                dut.map_load : dut.m1_valid_q;

            logical_end_check_m2_q <= 1'b1;
            logical_end_expect_m2_valid_q <= dut.m1_issue;
            logical_end_expect_m2_finish_q <=
                dut.m1_issue && dut.m1_finish_token_comb;
            logical_end_expect_m2_post_q <=
                dut.spec_stored_bytes_q + dut.m1_committed_inc_comb;

            logical_end_check_m3_q <= 1'b1;
            logical_end_expect_m3_valid_q <= dut.m2_valid_q;
            logical_end_expect_m3_finish_q <=
                dut.m2_valid_q && dut.m2_store_finishes_input_q;
            logical_end_expect_m3_stored_q <=
                dut.m2_stored_post_bytes_q;
            logical_end_expect_spec_q <= dut.spec_stored_bytes_q +
                (dut.m1_issue ? dut.m1_committed_inc_comb : 3'd0);
            logical_end_input_done_before_q <= input_done;

            if (dut.m1_issue && dut.m1_defer_required_comb &&
                |(dut.m1_end_q & ~dut.m1_lane_commit_valid_comb)) begin
                logical_end_defer_queued_seen =
                    logical_end_defer_queued_seen + 1;
                if (dut.m1_end_q !== 4'b1000 ||
                    dut.m1_lane_commit_valid_comb !== 4'b0011 ||
                    dut.m1_committed_inc_comb !== 3'd2 ||
                    dut.m1_defer_keep_comb !== 4'b0011 ||
                    dut.m1_defer_end_comb !== 4'b0010 ||
                    dut.m1_finish_token_comb ||
                    !dut.m1_source_finishes_beat_q ||
                    dut.map_load || dut.m1_store_finishes_beat_comb)
                    logical_end_defer_fail(
                        "logical end was not isolated in deferred suffix");
            end

            if (dut.m1_issue && dut.m1_finish_token_comb &&
                !dut.m1_source_from_defer_q)
                logical_end_defer_fail(
                    "logical end token fired before deferred suffix replay");

            if (dut.m1_issue && dut.m1_source_from_defer_q) begin
                logical_end_defer_issued_seen =
                    logical_end_defer_issued_seen + 1;
                if (dut.m1_lane_valid_q !== 4'b0011 ||
                    dut.m1_end_q !== 4'b0010 ||
                    dut.m1_lane_commit_valid_comb !== 4'b0011 ||
                    dut.m1_committed_inc_comb !== 3'd2 ||
                    !dut.m1_finish_token_comb ||
                    dut.m1_defer_required_comb ||
                    !dut.m1_source_finishes_beat_q ||
                    !dut.m1_store_finishes_beat_comb)
                    logical_end_defer_fail(
                        "deferred suffix did not own the sole finish token");
            end

            if (dut.m1_issue && dut.m1_finish_token_comb) begin
                logical_end_defer_m1_seen = logical_end_defer_m1_seen + 1;
                if (dut.m1_committed_inc_comb !== 3'd2 ||
                    dut.spec_stored_bytes_q !== 32'd10)
                    logical_end_defer_fail(
                        "M1 finish bundle count/base was not 10 plus 2");
            end
            if (dut.m2_valid_q && dut.m2_store_finishes_input_q) begin
                logical_end_defer_m2_seen = logical_end_defer_m2_seen + 1;
                if (dut.m2_stored_post_bytes_q !== 32'd12)
                    logical_end_defer_fail(
                        "M2 finish bundle stored_post was not 12");
            end
            if (dut.m2_valid_q && dut.m2_store_finishes_input_q)
                logical_end_defer_m3_seen = logical_end_defer_m3_seen + 1;
        end
    end

    always @(negedge clk) begin
        if (!rst && logical_end_defer_active) begin
            if (logical_end_check_m1_q) begin
                if (dut.m1_valid_q !== logical_end_expect_m1_valid_q)
                    logical_end_defer_fail(
                        "elastic M1 valid transition did not match load/issue");
            end
            if (logical_end_check_m2_q) begin
                if (dut.m2_valid_q !== logical_end_expect_m2_valid_q)
                    logical_end_defer_fail(
                        "M2 valid did not match sampled M1 valid");
                if (logical_end_expect_m2_valid_q &&
                    (dut.m2_store_finishes_input_q !==
                         logical_end_expect_m2_finish_q ||
                     dut.m2_stored_post_bytes_q !==
                         logical_end_expect_m2_post_q))
                    logical_end_defer_fail(
                        "M2 finish/count payload did not match M1");
            end
            if (dut.spec_stored_bytes_q !== logical_end_expect_spec_q)
                logical_end_defer_fail(
                    "spec_stored_bytes did not advance with M1 issue");
            if (logical_end_check_m3_q &&
                logical_end_expect_m3_valid_q &&
                dut.stored_bytes_q !== logical_end_expect_m3_stored_q)
                logical_end_defer_fail(
                    "M3 visible stored count did not match M2 payload");
            if (!logical_end_input_done_before_q &&
                input_done !== logical_end_expect_m3_finish_q)
                logical_end_defer_fail(
                    "input_done changed without the corresponding M3 bundle");
            if (logical_end_input_done_before_q && !input_done)
                logical_end_defer_fail(
                    "input_done was not sticky before directed reset");
        end
    end

    // Randomized downstream backpressure.  Case 6 adds one deterministic
    // liveness excursion: once its first 3x3 reader is active, hold the sink
    // until the writer presents a genuinely unsafe/overwrite M1, then release
    // the sink so the same elastic payload must cross reader admission.
    always @(negedge clk) begin
        if (rst || !case_active) begin
            m_entry_ready <= 1'b0;
            directed_m1_reader_hold_started_q <= 1'b0;
            directed_m1_hazard_seen_q <= 1'b0;
        end else if (case_id == 6) begin
            if (!directed_m1_reader_hold_started_q) begin
                m_entry_ready <= 1'b1;
                if (dut.mat_active_q && dut.active_read_rows_q != 0) begin
                    directed_m1_reader_hold_started_q <= 1'b1;
                    m_entry_ready <= 1'b0;
                end
            end else if (!directed_m1_hazard_seen_q) begin
                m_entry_ready <= 1'b0;
                directed_m1_reader_hold_cycles =
                    directed_m1_reader_hold_cycles + 1;
                if (dut.m1_valid_q &&
                    (!dut.m1_mapped_write_safe ||
                     dut.m1_overwrite_comb)) begin
                    directed_m1_hazard_seen_q <= 1'b1;
                    directed_m1_hazard_count =
                        directed_m1_hazard_count + 1;
                    directed_m1_data_q <= dut.m1_data_q;
                    directed_m1_lane_valid_q <= dut.m1_lane_valid_q;
                    directed_m1_end_q <= dut.m1_end_q;
                    directed_m1_post_y_q <= dut.m1_post_wr_y_q;
                    directed_m1_post_x_q <= dut.m1_post_wr_x_q;
                    directed_m1_post_ch_q <= dut.m1_post_wr_ch_q;
                    directed_m1_source_finish_q <=
                        dut.m1_source_finishes_beat_q;
                    directed_m1_from_defer_q <=
                        dut.m1_source_from_defer_q;
                    m_entry_ready <= 1'b1;
                end
            end else begin
                m_entry_ready <= 1'b1;
            end
        end else begin
            directed_m1_reader_hold_started_q <= 1'b0;
            directed_m1_hazard_seen_q <= 1'b0;
            m_entry_ready <= ($urandom_range(0, 7) != 0);
        end
    end

    // The first unsafe sample above is the identity token for this directed
    // recovery.  Keep checking it at active edges until its one legal issue;
    // a payload mutation or disappearance is an immediate test failure.
    always @(posedge clk) begin
        if (rst || !case_active || case_id != 6) begin
            directed_m1_payload_watch_started_q <= 1'b0;
            directed_m1_payload_watch_active_q <= 1'b0;
        end else begin
            if (!directed_m1_payload_watch_started_q &&
                directed_m1_hazard_seen_q) begin
                directed_m1_payload_watch_started_q <= 1'b1;
                directed_m1_payload_watch_active_q <= 1'b1;
            end else if (directed_m1_payload_watch_active_q) begin
                if (!dut.m1_valid_q)
                    fail("directed unsafe M1 disappeared before recovery");
                if ({dut.m1_data_q, dut.m1_lane_valid_q, dut.m1_end_q,
                     dut.m1_post_wr_y_q, dut.m1_post_wr_x_q,
                     dut.m1_post_wr_ch_q,
                     dut.m1_source_finishes_beat_q,
                     dut.m1_source_from_defer_q} !==
                    {directed_m1_data_q, directed_m1_lane_valid_q,
                     directed_m1_end_q, directed_m1_post_y_q,
                     directed_m1_post_x_q, directed_m1_post_ch_q,
                     directed_m1_source_finish_q,
                     directed_m1_from_defer_q})
                    fail("directed unsafe M1 payload changed while held");
                if (dut.m1_issue) begin
                    directed_m1_issue_count =
                        directed_m1_issue_count + 1;
                    directed_m1_payload_watch_active_q <= 1'b0;
                end
            end
        end
    end

    // AXIS requires every output field to remain stable while stalled.
    always @(posedge clk) begin
        if (rst || !case_active) begin
            held_q <= 1'b0;
        end else begin
            if (held_q) begin
                if (!m_entry_valid ||
                    (m_entry_data !== held_data_q) ||
                    (m_entry_lane_valid !== held_lane_valid_q) ||
                    (m_entry_pixel !== held_pixel_q) ||
                    (m_entry_k_pass !== held_pass_q) ||
                    (m_entry_epoch !== held_epoch_q) ||
                    (m_entry_last !== held_last_q))
                    fail("output changed while m_entry_ready was low");
            end

            held_q <= m_entry_valid && !m_entry_ready;
            if (m_entry_valid && !m_entry_ready) begin
                held_data_q <= m_entry_data;
                held_lane_valid_q <= m_entry_lane_valid;
                held_pixel_q <= m_entry_pixel;
                held_pass_q <= m_entry_k_pass;
                held_epoch_q <= m_entry_epoch;
                held_last_q <= m_entry_last;
            end
        end
    end

    // Byte-exact scoreboard for the materialized cache-entry stream.
    always @(posedge clk) begin
        if (case_active) begin
            if (dut.defer_valid_q)
                case_defer_cycles = case_defer_cycles + 1;
            if (dut.m1_issue && dut.mat_active_q)
                case_rw_overlap_cycles = case_rw_overlap_cycles + 1;
        end
        if (case_active && m_entry_valid && m_entry_ready) begin
            case_stream_hash =
                (case_stream_hash ^ m_entry_data[63:0]) *
                64'h00000100000001b3;
            case_stream_hash =
                (case_stream_hash ^ m_entry_data[127:64]) *
                64'h00000100000001b3;
            case_stream_hash =
                (case_stream_hash ^ {48'd0, m_entry_data[143:128]}) *
                64'h00000100000001b3;
            case_stream_hash =
                (case_stream_hash ^ {14'd0, m_entry_lane_valid,
                  m_entry_pixel}) * 64'h00000100000001b3;
            case_stream_hash =
                (case_stream_hash ^ {31'd0, m_entry_last,
                  m_entry_epoch, m_entry_k_pass, m_entry_pixel[7:0]}) *
                64'h00000100000001b3;
            score_idx = observed_entries;
            score_row = score_idx / (case_passes * case_ow);
            score_rem = score_idx % (case_passes * case_ow);
            score_pass = score_rem / case_ow;
            score_x = score_rem % case_ow;

            if (m_entry_pixel !== ((score_row * case_ow) + score_x))
                fail("pixel index/order mismatch");
            if (m_entry_k_pass !== score_pass)
                fail("k-pass index/order mismatch");
            if (m_entry_epoch !== case_epoch)
                fail("entry epoch mismatch");
            if (pass_ready_epoch !== case_epoch)
                fail("ready epoch mismatch");
            if (m_entry_last !==
                (observed_entries + 1 == case_expected_entries))
                fail("entry last mismatch");

            // On the final output row, completed lower-numbered passes are
            // released while the current and higher passes remain hidden.
            for (score_ready_pass = 0;
                 score_ready_pass < case_passes;
                 score_ready_pass = score_ready_pass + 1) begin
                if ((score_row == case_oh - 1) &&
                    (score_ready_pass < score_pass)) begin
                    if (!pass_ready_bitmap[score_ready_pass])
                        fail("completed pass was not released early");
                end else if (pass_ready_bitmap[score_ready_pass]) begin
                    fail("pass-ready bit was released before completion");
                end
            end

            for (score_lane = 0; score_lane < ROWS;
                 score_lane = score_lane + 1) begin
                score_gk = score_pass * ROWS + score_lane;
                expected_lane_valid =
                    score_gk < (case_cin * (case_kernel ? 1 : 9));
                expected_byte = 8'd0;

                if (expected_lane_valid) begin
                    if (case_kernel) begin
                        score_ch = score_gk;
                        score_ky = 0;
                        score_kx = 0;
                    end else begin
                        score_ch = score_gk / 9;
                        score_kp = score_gk % 9;
                        score_ky = score_kp / 3;
                        score_kx = score_kp % 3;
                    end

                    score_fy = score_row * case_stride +
                               score_ky - case_pad;
                    score_fx = score_x * case_stride +
                               score_kx - case_pad;
                    if ((score_fy >= 0) && (score_fy < case_h) &&
                        (score_fx >= 0) && (score_fx < case_w) &&
                        (score_ch < case_cin)) begin
                        score_raw_addr =
                            ((score_fy * case_w + score_fx) * case_cin) +
                            score_ch;
                        expected_byte = centered_byte(
                            raw_mem[score_raw_addr], case_zp);
                    end
                end

                if (m_entry_lane_valid[score_lane] !== expected_lane_valid)
                    fail("lane-valid mismatch");
                if (m_entry_data[score_lane*8 +: 8] !== expected_byte) begin
                    $display("  row=%0d x=%0d pass=%0d lane=%0d got=%02x exp=%02x",
                             score_row, score_x, score_pass, score_lane,
                             m_entry_data[score_lane*8 +: 8], expected_byte);
                    fail("materialized byte mismatch");
                end
            end

            observed_entries = observed_entries + 1;
        end
    end

    task send_current_frame;
        integer pos;
        integer lane;
        integer bytes_this_beat;
        integer gap;
        reg [63:0] beat_data;
        reg [7:0] beat_keep;
        begin
            pos = 0;
            // The first case drives a continuous AXIS burst.  Since one beat
            // takes two four-byte issue clocks, this deterministically fills
            // both FIFO entries and holds a third beat stable against full
            // backpressure.  The remaining cases retain randomized gaps; the
            // second case fixes the gap at zero to cover enqueue+pop on the
            // same edge with exactly one resident beat.
            if (case_id == 1) begin
                @(negedge clk);
                while (pos < case_total_bytes) begin
                    bytes_this_beat = case_total_bytes - pos;
                    if (bytes_this_beat > KEEP_W)
                        bytes_this_beat = KEEP_W;
                    beat_data = 64'd0;
                    beat_keep = 8'd0;
                    for (lane = 0; lane < KEEP_W; lane = lane + 1) begin
                        if (lane < bytes_this_beat) begin
                            beat_data[lane*8 +: 8] = raw_mem[pos + lane];
                            beat_keep[lane] = 1'b1;
                        end
                    end
                    s_axis_tdata <= beat_data;
                    s_axis_tkeep <= beat_keep;
                    s_axis_tlast <= (pos + bytes_this_beat ==
                                     case_total_bytes);
                    s_axis_tvalid <= 1'b1;
                    @(posedge clk);
                    while (!s_axis_tready)
                        @(posedge clk);
                    pos = pos + bytes_this_beat;
                    @(negedge clk);
                end
                s_axis_tvalid <= 1'b0;
                s_axis_tdata <= 64'd0;
                s_axis_tkeep <= 8'd0;
                s_axis_tlast <= 1'b0;
            end else while (pos < case_total_bytes) begin
                gap = (case_id == 2) ? 0 : $urandom_range(0, 2);
                repeat (gap) @(negedge clk);

                bytes_this_beat = case_total_bytes - pos;
                if (bytes_this_beat > KEEP_W)
                    bytes_this_beat = KEEP_W;
                beat_data = 64'd0;
                beat_keep = 8'd0;
                for (lane = 0; lane < KEEP_W; lane = lane + 1) begin
                    if (lane < bytes_this_beat) begin
                        beat_data[lane*8 +: 8] = raw_mem[pos + lane];
                        beat_keep[lane] = 1'b1;
                    end
                end

                @(negedge clk);
                s_axis_tdata <= beat_data;
                s_axis_tkeep <= beat_keep;
                s_axis_tlast <= (pos + bytes_this_beat ==
                                 case_total_bytes);
                s_axis_tvalid <= 1'b1;

                @(posedge clk);
                while (!s_axis_tready)
                    @(posedge clk);

                @(negedge clk);
                s_axis_tvalid <= 1'b0;
                s_axis_tdata <= 64'd0;
                s_axis_tkeep <= 8'd0;
                s_axis_tlast <= 1'b0;
                pos = pos + bytes_this_beat;
            end
        end
    endtask

    task run_inflight_reset;
        input integer reset_phase;
        integer reset_wait;
        integer reset_final_frame;
        begin
            while (busy)
                @(posedge clk);
            @(negedge clk);

            // Phases 0..2 and 4 use a non-final full beat.  Phases 3 and 5
            // use a complete four-byte frame for finish-drain and M0-only
            // reset landing respectively.
            reset_final_frame = (reset_phase == 3 || reset_phase == 5);
            cfg_fm_h <= reset_final_frame ? 16'd1 : 16'd4;
            cfg_fm_w <= reset_final_frame ? 16'd1 : 16'd5;
            cfg_cin <= reset_final_frame ? 14'd4 : 14'd5;
            cfg_ofm_h <= reset_final_frame ? 16'd1 : 16'd4;
            cfg_ofm_w <= reset_final_frame ? 16'd1 : 16'd5;
            cfg_kernel_1x1 <= reset_final_frame;
            cfg_stride <= 2'd1;
            cfg_pad <= reset_final_frame ? 2'd0 : 2'd1;
            cfg_input_zero_point <= 8'd91;
            cfg_epoch <= 8'he1;
            cfg_start <= 1'b1;
            @(negedge clk);
            cfg_start <= 1'b0;
            if (!busy)
                fail("in-flight reset setup did not become busy");

            s_axis_tdata <= 64'h7766554433221100;
            s_axis_tkeep <= reset_final_frame ? 8'h0f : 8'hff;
            s_axis_tlast <= reset_final_frame;
            s_axis_tvalid <= 1'b1;
            @(posedge clk);
            while (!s_axis_tready)
                @(posedge clk);
            @(negedge clk);
            s_axis_tvalid <= 1'b0;
            s_axis_tdata <= 64'd0;
            s_axis_tkeep <= 8'd0;
            s_axis_tlast <= 1'b0;

            reset_wait = 0;
            case (reset_phase)
                0: begin
                    while (!(dut.m1_valid_q && !dut.m2_valid_q) &&
                           reset_wait < 16) begin
                        @(negedge clk);
                        reset_wait = reset_wait + 1;
                    end
                    if (!(dut.m1_valid_q && !dut.m2_valid_q))
                        fail("could not place reset in M1-only phase");
                end
                1: begin
                    while (!(dut.m2_valid_q && !dut.m1_valid_q) &&
                           reset_wait < 16) begin
                        @(negedge clk);
                        reset_wait = reset_wait + 1;
                    end
                    if (!(dut.m2_valid_q && !dut.m1_valid_q))
                        fail("could not place reset in M2 phase");
                end
                2: begin
                    while (!(dut.m2_valid_q && !dut.m1_valid_q) &&
                           reset_wait < 16) begin
                        @(negedge clk);
                        reset_wait = reset_wait + 1;
                    end
                    if (!(dut.m2_valid_q && !dut.m1_valid_q)) begin
                        fail("could not reach M3 commit edge");
                    end else begin
                        // Let the live M2 bundle commit architecturally, then
                        // reset before any later bundle can become observable.
                        @(posedge clk);
                        @(negedge clk);
                        if (dut.stored_bytes_q == 0)
                            fail("M3 edge did not commit before reset");
                    end
                end
                3: begin
                    while (!(dut.finish_pending_q && dut.m2_valid_q &&
                             !input_done) && reset_wait < 16) begin
                        @(negedge clk);
                        reset_wait = reset_wait + 1;
                    end
                    if (!(dut.finish_pending_q && dut.m2_valid_q &&
                          !input_done))
                        fail("could not reset during final bundle drain");
                end
                4: begin
                    while (!(dut.s0_valid_q && !dut.m0_valid_q &&
                             !dut.m1_valid_q && !dut.m2_valid_q) &&
                           reset_wait < 16) begin
                        @(negedge clk);
                        reset_wait = reset_wait + 1;
                    end
                    if (!(dut.s0_valid_q && !dut.m0_valid_q &&
                          !dut.m1_valid_q && !dut.m2_valid_q))
                        fail("could not place reset in S0-only phase");
                end
                default: begin
                    while (!(dut.m0_valid_q && !dut.s0_valid_q &&
                             !dut.m1_valid_q && !dut.m2_valid_q) &&
                           reset_wait < 16) begin
                        @(negedge clk);
                        reset_wait = reset_wait + 1;
                    end
                    if (!(dut.m0_valid_q && !dut.s0_valid_q &&
                          !dut.m1_valid_q && !dut.m2_valid_q))
                        fail("could not place reset in M0-only phase");
                end
            endcase

            rst <= 1'b1;
            @(posedge clk);
            @(negedge clk);
            if (busy || input_done || done || m_entry_valid ||
                accepted_beats != 0 || accepted_bytes != 0 ||
                emitted_entries != 0 || dut.s0_valid_q || dut.m0_valid_q ||
                dut.m1_valid_q || dut.m2_valid_q ||
                dut.stored_bytes_q != 0 || dut.spec_stored_bytes_q != 0 ||
                dut.beat_fifo_valid_q != 0 || dut.defer_valid_q ||
                dut.mat_active_q ||
                dut.logical_remaining_q != 0 ||
                dut.active_read_rows_q != 0 ||
                dut.finish_pending_q || dut.row_boundary_pending_q ||
                dut.row_valid_q != 0 || dut.spec_row_valid_q != 0 ||
                config_error || tkeep_error || tlast_error ||
                overflow_error || bank_collision_error ||
                row_overwrite_error || protocol_error ||
                dut.accept_closed_q)
                fail("in-flight reset did not clear architectural state");
            if (s_axis_tready !== 1'b0)
                fail("input ready remained asserted during reset idle state");

            rst <= 1'b0;
            repeat (2) @(negedge clk);
            $display("PASS: materializer in-flight reset phase=%0d flush",
                     reset_phase);
        end
    endtask

    task protocol_start_1x1;
        input integer h;
        input integer w;
        input integer cin;
        input integer epoch;
        begin
            while (busy)
                @(posedge clk);
            @(negedge clk);
            cfg_fm_h <= h;
            cfg_fm_w <= w;
            cfg_cin <= cin;
            cfg_ofm_h <= h;
            cfg_ofm_w <= w;
            cfg_kernel_1x1 <= 1'b1;
            cfg_stride <= 2'd1;
            cfg_pad <= 2'd0;
            cfg_input_zero_point <= 8'd0;
            cfg_epoch <= epoch[EPOCH_W-1:0];
            cfg_start <= 1'b1;
            @(negedge clk);
            cfg_start <= 1'b0;
            if (!busy)
                fail("protocol-test descriptor did not start");
        end
    endtask

    task protocol_send_beat;
        input [63:0] beat_data;
        input [7:0] beat_keep;
        input beat_last;
        integer ready_wait;
        begin
            @(negedge clk);
            s_axis_tdata <= beat_data;
            s_axis_tkeep <= beat_keep;
            s_axis_tlast <= beat_last;
            s_axis_tvalid <= 1'b1;
            ready_wait = 0;
            @(posedge clk);
            while (!s_axis_tready && ready_wait < 128) begin
                @(posedge clk);
                ready_wait = ready_wait + 1;
            end
            if (!s_axis_tready)
                fail("protocol-test beat was not admitted");
            @(negedge clk);
            s_axis_tvalid <= 1'b0;
            s_axis_tdata <= 64'd0;
            s_axis_tkeep <= 8'd0;
            s_axis_tlast <= 1'b0;
        end
    endtask

    task protocol_wait_closed;
        integer done_wait;
        begin
            done_wait = 0;
            while (!input_done && done_wait < 128) begin
                @(posedge clk);
                done_wait = done_wait + 1;
            end
            @(negedge clk);
            if (!input_done)
                fail("protocol-test frame did not reach bounded input_done");
            if (s_axis_tready !== 1'b0)
                fail("protocol-test input did not close after expected bytes");
        end
    endtask

    task protocol_reset_state;
        begin
            @(negedge clk);
            rst <= 1'b1;
            @(posedge clk);
            @(negedge clk);
            if (busy || input_done || m_entry_valid ||
                accepted_beats != 0 || accepted_bytes != 0 ||
                config_error || tkeep_error || tlast_error ||
                overflow_error || bank_collision_error ||
                row_overwrite_error || protocol_error ||
                dut.s0_valid_q || dut.m0_valid_q || dut.m1_valid_q ||
                dut.m2_valid_q || dut.defer_valid_q ||
                dut.beat_fifo_valid_q != 0 || dut.accept_closed_q ||
                dut.finish_pending_q ||
                dut.logical_remaining_q != 0 ||
                dut.row_valid_q != 0 || dut.spec_row_valid_q != 0)
                fail("protocol-test reset did not clear sticky state");
            rst <= 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    task run_logical_end_in_defer;
        integer directed_wait;
        begin
            // The physical frame is 25 bytes, but this test-only boundary
            // closes it after byte 12.  Bytes 9..12 map as x1/ch3, x1/ch4,
            // x2/ch0, x2/ch1: three packed words in one rolling row.  M1 can
            // commit the first two fragments only, so the logical final byte
            // must follow lanes 2..3 into the deferred suffix.
            protocol_start_1x1(1, 5, 5, 8'hd5);
            force dut.expected_bytes_q = 32'd12;
            force prevalidated_dut.expected_bytes_q = 32'd12;
            dut.logical_remaining_q = 32'd12;
            prevalidated_dut.logical_remaining_q = 32'd12;
            logical_end_defer_queued_seen = 0;
            logical_end_defer_issued_seen = 0;
            logical_end_defer_m1_seen = 0;
            logical_end_defer_m2_seen = 0;
            logical_end_defer_m3_seen = 0;
            logical_end_defer_active = 1'b1;

            protocol_send_beat(64'h0706050403020100, 8'hff, 1'b0);
            protocol_send_beat(64'h0f0e0d0c0b0a0908, 8'h0f, 1'b1);

            directed_wait = 0;
            while (!input_done && directed_wait < 128) begin
                @(negedge clk);
                directed_wait = directed_wait + 1;
            end
            if (!input_done)
                logical_end_defer_fail(
                    "deferred logical end did not reach bounded input_done");

            // Allow the registered finish-pending lifetime bit to observe the
            // M3 commit and clear after the write pipeline is empty.
            @(posedge clk);
            @(negedge clk);
            if (logical_end_defer_queued_seen != 1 ||
                logical_end_defer_issued_seen != 1 ||
                logical_end_defer_m1_seen != 1 ||
                logical_end_defer_m2_seen != 1 ||
                logical_end_defer_m3_seen != 1)
                logical_end_defer_fail(
                    "logical-end defer/M1/M2/M3 coverage was not exactly once");
            if (!input_done || !dut.accept_closed_q ||
                accepted_beats != 2 || accepted_bytes != 12 ||
                dut.spec_stored_bytes_q != 12 || dut.stored_bytes_q != 12)
                logical_end_defer_fail(
                    "directed final counters or close state were incorrect");
            if (dut.beat_fifo_valid_q != 0 || dut.s0_valid_q ||
                dut.defer_valid_q || dut.m0_valid_q || dut.m1_valid_q ||
                dut.m2_valid_q || dut.finish_pending_q)
                logical_end_defer_fail(
                    "directed finish did not drain FIFO/defer/write pipeline");
            if (config_error || tkeep_error || tlast_error ||
                overflow_error || bank_collision_error ||
                row_overwrite_error || protocol_error)
                logical_end_defer_fail(
                    "directed logical-end path raised a sticky error");
            if (!pre_input_done || pre_accepted_beats != 2 ||
                pre_accepted_bytes != 12 ||
                prevalidated_dut.spec_stored_bytes_q != 12 ||
                prevalidated_dut.stored_bytes_q != 12)
                logical_end_defer_fail(
                    "prevalidated mirror diverged on deferred logical end");

            $display("PASS: logical end followed deferred suffix through M1/M2/M3");
            logical_end_defer_active = 1'b0;
            release dut.expected_bytes_q;
            release prevalidated_dut.expected_bytes_q;
            protocol_reset_state();
        end
    endtask

    task run_cin1023_directed;
        integer saved_case_id;
        integer raw_i;
        integer directed_wait;
        begin
            // Keep the original twelve release vectors untouched.  This
            // independent p1 vector adds the MAX_CHANNELS-1 tail where the
            // final 18-lane pass contains exactly fifteen live channels.
            while (busy)
                @(posedge clk);
            @(negedge clk);
            saved_case_id = case_id;
            case_id = 4;
            case_h = 1;
            case_w = 1;
            case_cin = 1023;
            case_oh = 1;
            case_ow = 1;
            case_kernel = 1;
            case_stride = 1;
            case_pad = 0;
            case_passes = 57;
            case_total_bytes = 1023;
            case_expected_entries = 57;
            case_epoch = 8'h74;
            case_zp = 8'd149;
            observed_entries = 0;
            held_q = 1'b0;
            case_phase_a_count = 0;
            case_phase_b_count = 0;
            case_stream_hash = 64'hcbf29ce484222325;
            for (raw_i = 0; raw_i < case_total_bytes;
                 raw_i = raw_i + 1)
                raw_mem[raw_i] =
                    (raw_i * 13 + raw_i / 7 + 4 * 29) & 8'hff;

            cfg_fm_h <= 16'd1;
            cfg_fm_w <= 16'd1;
            cfg_cin <= 14'd1023;
            cfg_ofm_h <= 16'd1;
            cfg_ofm_w <= 16'd1;
            cfg_kernel_1x1 <= 1'b1;
            cfg_stride <= 2'd1;
            cfg_pad <= 2'd0;
            cfg_input_zero_point <= case_zp;
            cfg_epoch <= case_epoch;
            case_active <= 1'b1;
            cfg_start <= 1'b1;
            @(negedge clk);
            cfg_start <= 1'b0;
            if (!busy)
                fail("Cin=1023 descriptor did not start");

            send_current_frame();
            directed_wait = 0;
            while (!done && directed_wait < 200000) begin
                @(posedge clk);
                directed_wait = directed_wait + 1;
            end
            @(negedge clk);
            if (!done && busy)
                fail("Cin=1023 directed test did not finish");
            if (observed_entries != 57 || emitted_entries != 57 ||
                accepted_bytes != 1023 || accepted_beats != 128 ||
                !input_done)
                fail("Cin=1023 output/counter boundary was incorrect");
            if (case_phase_a_count != case_phase_b_count)
                fail("Cin=1023 quiescent Phase-A/Phase-B counts differed");
            if (case_stream_hash !== 64'h3b1b7d0f8f258b78)
                fail("Cin=1023 exact output stream hash changed");
            if (config_error || tkeep_error || tlast_error ||
                overflow_error || bank_collision_error ||
                row_overwrite_error || protocol_error)
                fail("Cin=1023 directed test raised a sticky error");
            $display("PASS: independent Cin=1023 tail entries/phases/hash=%0d/%0d:%0d/%016x",
                     observed_entries, case_phase_a_count,
                     case_phase_b_count, case_stream_hash);

            case_active <= 1'b0;
            case_id = saved_case_id;
            repeat (3) @(negedge clk);
        end
    endtask

    task run_noncontiguous_keep_output;
        integer saved_case_id;
        integer directed_wait;
        begin
            // Logical bytes 0..3 are selected from physical lanes 1,2,4,6.
            // This crosses the Phase-A/Phase-B lane1/2 boundary and the raw
            // beat's low/upper halves; the next upper byte and second beat
            // complete a byte-exact three-pixel output check.
            while (busy)
                @(posedge clk);
            @(negedge clk);
            saved_case_id = case_id;
            case_id = 90;
            case_h = 1;
            case_w = 3;
            case_cin = 4;
            case_oh = 1;
            case_ow = 3;
            case_kernel = 1;
            case_stride = 1;
            case_pad = 0;
            case_passes = 1;
            case_total_bytes = 12;
            case_expected_entries = 3;
            case_epoch = 8'hde;
            case_zp = 8'd0;
            raw_mem[0] = 8'h11;
            raw_mem[1] = 8'h22;
            raw_mem[2] = 8'h44;
            raw_mem[3] = 8'h66;
            raw_mem[4] = 8'h77;
            raw_mem[5] = 8'h08;
            raw_mem[6] = 8'h09;
            raw_mem[7] = 8'h0a;
            raw_mem[8] = 8'h0b;
            raw_mem[9] = 8'h0c;
            raw_mem[10] = 8'h0d;
            raw_mem[11] = 8'h0e;
            observed_entries = 0;
            held_q = 1'b0;
            case_phase_a_count = 0;
            case_phase_b_count = 0;
            case_stream_hash = 64'hcbf29ce484222325;
            case_active <= 1'b1;

            protocol_start_1x1(1, 3, 4, 8'hde);
            protocol_send_beat(64'h7766a544a32211a0,
                               8'b11010110, 1'b0);
            protocol_send_beat(64'hf00e0d0c0b0a0908,
                               8'b01111111, 1'b1);

            directed_wait = 0;
            while (!done && directed_wait < 256) begin
                @(posedge clk);
                directed_wait = directed_wait + 1;
            end
            @(negedge clk);
            if (!done && busy)
                fail("non-contiguous TKEEP output test did not finish");
            if (observed_entries != 3 || emitted_entries != 3 ||
                accepted_beats != 2 || accepted_bytes != 12 ||
                dut.stored_bytes_q != 12 || !input_done)
                fail("non-contiguous TKEEP output/counters were incorrect");
            if (case_phase_a_count != case_phase_b_count)
                fail("non-contiguous TKEEP Phase-A/Phase-B counts differed");
            if (case_stream_hash !== 64'h2a293aca1e3e5b8c)
                fail("non-contiguous TKEEP byte-exact output hash changed");
            if (!tkeep_error || tlast_error || overflow_error ||
                bank_collision_error || row_overwrite_error ||
                protocol_error)
                fail("non-contiguous TKEEP output sticky semantics changed");
            $display("PASS: non-contiguous TKEEP crossed lane1/2 and low/upper with exact output hash=%016x",
                     case_stream_hash);

            case_active <= 1'b0;
            case_id = saved_case_id;
            protocol_reset_state();
        end
    endtask

    task run_protocol_error_matrix;
        integer held_beats;
        begin
            // Non-contiguous TKEEP: popcount reaches the exact byte count, so
            // only the prefix rule is violated.
            protocol_start_1x1(1, 1, 3, 8'hd1);
            protocol_send_beat(64'h0706050403020100, 8'h0b, 1'b1);
            protocol_wait_closed();
            if (!tkeep_error || tlast_error || overflow_error ||
                bank_collision_error || row_overwrite_error ||
                protocol_error || accepted_beats != 1 ||
                accepted_bytes != 3)
                fail("non-contiguous TKEEP sticky-bit semantics changed");
            protocol_reset_state();

            // Early TLAST is reported but does not discard the remaining
            // in-range bytes; the next correctly terminated beat can drain.
            protocol_start_1x1(1, 4, 4, 8'hd2);
            protocol_send_beat(64'h1716151413121110, 8'hff, 1'b1);
            if (!tlast_error || tkeep_error || overflow_error)
                fail("early TLAST was not isolated to tlast_error");
            protocol_send_beat(64'h1f1e1d1c1b1a1918, 8'hff, 1'b1);
            protocol_wait_closed();
            if (!tlast_error || tkeep_error || overflow_error ||
                accepted_beats != 2 || accepted_bytes != 16)
                fail("early TLAST bounded-drain semantics changed");
            protocol_reset_state();

            // Missing TLAST on the exact final beat must close admission; a
            // later beat cannot be accepted to repair the framing error.
            protocol_start_1x1(1, 2, 4, 8'hd3);
            protocol_send_beat(64'h2726252423222120, 8'hff, 1'b0);
            protocol_wait_closed();
            held_beats = accepted_beats;
            s_axis_tvalid <= 1'b1;
            s_axis_tdata <= 64'h2f2e2d2c2b2a2928;
            s_axis_tkeep <= 8'hff;
            s_axis_tlast <= 1'b1;
            repeat (4) @(posedge clk);
            @(negedge clk);
            s_axis_tvalid <= 1'b0;
            s_axis_tdata <= 64'd0;
            s_axis_tkeep <= 8'd0;
            s_axis_tlast <= 1'b0;
            if (!tlast_error || tkeep_error || overflow_error ||
                accepted_beats != held_beats || s_axis_tready !== 1'b0)
                fail("late TLAST fail-closed semantics changed");
            protocol_reset_state();

            // One overlong beat is counted at the AXIS boundary, while M1
            // clips memory/cursor commits to expected_bytes and closes input.
            protocol_start_1x1(1, 1, 4, 8'hd4);
            protocol_send_beat(64'h3736353433323130, 8'hff, 1'b0);
            protocol_wait_closed();
            if (!overflow_error || tkeep_error || tlast_error ||
                bank_collision_error || row_overwrite_error ||
                protocol_error || accepted_beats != 1 ||
                accepted_bytes != 8 || dut.stored_bytes_q != 4)
                fail("overlong input clipping/error semantics changed");
            protocol_reset_state();

            $display("PASS: materializer TKEEP/TLAST/overlong protocol matrix");
        end
    endtask

    task run_defer_consume_replace_priority;
        reg [40:0] old_payload;
        reg [40:0] new_payload;
        begin
            // In legal traffic phase_a_from_defer implies phase_a_m1_safe,
            // which excludes an M1 that is itself creating a suffix.  Force
            // the otherwise unreachable conjunction for one edge to lock down
            // the intended sequential priority: consume the old suffix into
            // M0, then let the later defer assignment install the new suffix.
            while (busy)
                @(posedge clk);
            @(negedge clk);
            old_payload = {32'h11223344, 4'b1010, 4'b0101, 1'b1};
            new_payload = {32'hdeadbeef, 4'b0011, 4'b0010, 1'b0};
            dut.defer_valid_q = 1'b1;
            dut.defer_data_q = old_payload[40:9];
            dut.defer_keep_q = old_payload[8:5];
            dut.defer_end_q = old_payload[4:1];
            dut.defer_finishes_beat_q = old_payload[0];
            dut.m1_source_finishes_beat_q = new_payload[0];
            prevalidated_dut.defer_valid_q = 1'b1;
            prevalidated_dut.defer_data_q = old_payload[40:9];
            prevalidated_dut.defer_keep_q = old_payload[8:5];
            prevalidated_dut.defer_end_q = old_payload[4:1];
            prevalidated_dut.defer_finishes_beat_q = old_payload[0];
            prevalidated_dut.m1_source_finishes_beat_q = new_payload[0];
            force dut.phase_a_from_defer = 1'b1;
            force dut.m1_issue = 1'b1;
            force dut.m1_defer_required_comb = 1'b1;
            force dut.m1_admit_defer_required_q = 1'b1;
            force dut.m1_defer_data_comb = new_payload[40:9];
            force dut.m1_defer_keep_comb = new_payload[8:5];
            force dut.m1_defer_end_comb = new_payload[4:1];
            force prevalidated_dut.phase_a_from_defer = 1'b1;
            force prevalidated_dut.m1_issue = 1'b1;
            force prevalidated_dut.m1_defer_required_comb = 1'b1;
            force prevalidated_dut.m1_admit_defer_required_q = 1'b1;
            force prevalidated_dut.m1_defer_data_comb = new_payload[40:9];
            force prevalidated_dut.m1_defer_keep_comb = new_payload[8:5];
            force prevalidated_dut.m1_defer_end_comb = new_payload[4:1];
            @(posedge clk);
            @(negedge clk);
            if (!dut.m0_valid_q || !dut.m0_source_from_defer_q ||
                {dut.m0_data_q, dut.m0_keep_q, dut.m0_end_q,
                 dut.m0_source_finishes_beat_q} !== old_payload)
                fail("forced replacement edge did not consume old suffix into M0");
            if (!dut.defer_valid_q ||
                {dut.defer_data_q, dut.defer_keep_q, dut.defer_end_q,
                 dut.defer_finishes_beat_q} !== new_payload)
                fail("forced replacement edge did not retain exact new suffix");
            release dut.phase_a_from_defer;
            release dut.m1_issue;
            release dut.m1_defer_required_comb;
            release dut.m1_admit_defer_required_q;
            release dut.m1_defer_data_comb;
            release dut.m1_defer_keep_comb;
            release dut.m1_defer_end_comb;
            release prevalidated_dut.phase_a_from_defer;
            release prevalidated_dut.m1_issue;
            release prevalidated_dut.m1_defer_required_comb;
            release prevalidated_dut.m1_admit_defer_required_q;
            release prevalidated_dut.m1_defer_data_comb;
            release prevalidated_dut.m1_defer_keep_comb;
            release prevalidated_dut.m1_defer_end_comb;
            rst <= 1'b1;
            @(posedge clk);
            @(negedge clk);
            rst <= 1'b0;
            repeat (2) @(negedge clk);
            $display("PASS: forced defer consume/replacement priority kept exact new suffix");
        end
    endtask

    // Functional cases obey the same authoritative descriptor boundary used
    // when the release instance sets CFG_PREVALIDATED: Cin is never below 3.
    // This also makes the one-cycle speculative row-tag derivation safe: a
    // 4-byte micro-op cannot traverse four >=3-byte rows and reuse a bank.
    task run_case;
        input integer h;
        input integer w;
        input integer cin;
        input integer oh;
        input integer ow;
        input integer kernel_1x1;
        input integer stride;
        input integer pad;
        input integer epoch;
        integer raw_i;
        integer pass_i;
        integer start_errors;
        integer expected_beats;
        integer busy_cfg_wait;
        integer recovery_seen_at_start;
        integer directed_hold_at_start;
        integer directed_hazard_at_start;
        integer directed_issue_at_start;
        reg [31:0] busy_cfg_expected_stored;
        begin
            if (cin < 3)
                fail("run_case violated the validated Cin>=3 contract");
            while (busy)
                @(posedge clk);
            @(negedge clk);

            case_id = case_id + 1;
            case_h = h;
            case_w = w;
            case_cin = cin;
            case_oh = oh;
            case_ow = ow;
            case_kernel = kernel_1x1;
            case_stride = stride;
            case_pad = pad;
            case_epoch = epoch[EPOCH_W-1:0];
            case_zp = (8'd73 + case_id * 8'd19);
            case_passes = ((cin * (kernel_1x1 ? 1 : 9)) + ROWS - 1) /
                          ROWS;
            case_total_bytes = h * w * cin;
            case_expected_entries = oh * ow * case_passes;
            expected_beats = (case_total_bytes + KEEP_W - 1) / KEEP_W;
            observed_entries = 0;
            start_errors = errors;
            recovery_seen_at_start = m1_row_admit_recovery_seen;
            directed_hold_at_start = directed_m1_reader_hold_cycles;
            directed_hazard_at_start = directed_m1_hazard_count;
            directed_issue_at_start = directed_m1_issue_count;
            held_q = 1'b0;
            case_defer_cycles = 0;
            case_rw_overlap_cycles = 0;
            case_finish_drain_cycles = 0;
            case_back_to_back_m1_cycles = 0;
            case_input_refill_cycles = 0;
            case_phase_a_count = 0;
            case_phase_b_count = 0;
            case_stream_hash = 64'hcbf29ce484222325;

            for (raw_i = 0; raw_i < case_total_bytes;
                 raw_i = raw_i + 1)
                raw_mem[raw_i] =
                    (raw_i * 13 + raw_i / 7 + case_id * 29) & 8'hff;

            cfg_fm_h <= h;
            cfg_fm_w <= w;
            cfg_cin <= cin;
            cfg_ofm_h <= oh;
            cfg_ofm_w <= ow;
            cfg_kernel_1x1 <= kernel_1x1;
            cfg_stride <= stride;
            cfg_pad <= pad;
            cfg_input_zero_point <= case_zp;
            cfg_epoch <= case_epoch;
            case_active <= 1'b1;
            cfg_start <= 1'b1;
            @(negedge clk);
            cfg_start <= 1'b0;

            if (!busy)
                fail("configuration did not start the materializer");

            if (case_id == 1) begin
                // Pulse cfg_start on a cycle that also has live M0 and M2.
                // The descriptor must be rejected without dropping either
                // the mapped transaction or the M3 bundle.
                fork
                    begin
                        send_current_frame();
                    end
                    begin
                        busy_cfg_wait = 0;
                        while (!(dut.m0_valid_q && dut.m2_valid_q) &&
                               busy_cfg_wait < 256) begin
                            @(negedge clk);
                            busy_cfg_wait = busy_cfg_wait + 1;
                        end
                        if (!(dut.m0_valid_q && dut.m2_valid_q)) begin
                            fail("could not align busy cfg_start with live M0/M2");
                        end else begin
                            busy_cfg_expected_stored =
                                dut.m2_stored_post_bytes_q;
                            cfg_start <= 1'b1;
                            @(negedge clk);
                            cfg_start <= 1'b0;
                            if (!protocol_error)
                                fail("busy cfg_start did not set protocol_error");
                            if (dut.stored_bytes_q !==
                                busy_cfg_expected_stored)
                                fail("busy cfg_start suppressed atomic M3 commit");
                            busy_cfg_injected_seen =
                                busy_cfg_injected_seen + 1;
                        end
                    end
                join
            end else begin
                send_current_frame();
            end

            timeout_cycles = 0;
            while (!done && timeout_cycles < 200000) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (!done)
                fail("timeout waiting for done");

            // Observe all nonblocking updates made on the done edge.
            @(negedge clk);
            if (busy)
                fail("busy remained asserted after done");
            if (!input_done)
                fail("input_done was not asserted");
            if (observed_entries != case_expected_entries)
                fail("wrong number of output entries");
            if (emitted_entries != case_expected_entries)
                fail("emitted_entries counter mismatch");
            if (accepted_bytes != case_total_bytes)
                fail("accepted_bytes counter mismatch");
            if (accepted_beats != expected_beats)
                fail("accepted_beats counter mismatch");
            if (materialize_cycles < emitted_entries)
                fail("materialize cycle counter is too small");
            if (kernel_1x1) begin
                // Three read groups plus the two-cycle XPM response pipeline
                // establish a five-cycle native-1x1 service interval.  The
                // response FIFO can hide some (or all) sink stalls, so bound
                // the result instead of charging every stalled output cycle.
                if (materialize_cycles <
                        case_expected_entries * 5 + oh ||
                    materialize_cycles >
                        case_expected_entries * 5 + oh +
                        entry_stall_cycles)
                    fail("native 1x1 service is not five cycles per entry");
            end else if (materialize_cycles <
                             case_expected_entries + (oh * 3) ||
                         materialize_cycles >
                             case_expected_entries + (oh * 3) +
                             entry_stall_cycles) begin
                // READ_LATENCY=2 followed by the registered response FIFO
                // costs three counted fill/retire cycles per output row; the
                // steady state must remain one 144-bit entry per cycle.
                fail("3x3 pipeline did not sustain one entry per cycle");
            end
            if (pass_ready_epoch != case_epoch)
                fail("final pass-ready epoch mismatch");
            for (pass_i = 0; pass_i < MAX_PASSES;
                 pass_i = pass_i + 1) begin
                if (pass_i < case_passes) begin
                    if (!pass_ready_bitmap[pass_i])
                        fail("expected pass-ready bit is clear");
                end else if (pass_ready_bitmap[pass_i]) begin
                    fail("unused pass-ready bit is set");
                end
            end

            if (config_error || tkeep_error || tlast_error ||
                overflow_error || bank_collision_error ||
                row_overwrite_error ||
                ((case_id == 1) ? !protocol_error : protocol_error)) begin
                $display("  sticky cfg/keep/last/overflow/collision/overwrite/protocol=%0d/%0d/%0d/%0d/%0d/%0d/%0d",
                         config_error, tkeep_error, tlast_error,
                         overflow_error, bank_collision_error,
                         row_overwrite_error, protocol_error);
                fail("a sticky protocol/banking error was asserted");
            end
            if (case_stream_hash !== expected_case_hash(case_id))
                fail("functional-case exact output stream hash changed");
            if (case_phase_a_count != case_phase_b_count)
                fail("quiescent case Phase-A/Phase-B counts differed");
            if (m0_row_hold_state != 0)
                fail("row-held M0 had not committed exactly once at quiescence");
            if (case_id == 6) begin
                if (!directed_m1_reader_hold_started_q ||
                    !directed_m1_hazard_seen_q ||
                    directed_m1_reader_hold_cycles <=
                        directed_hold_at_start ||
                    directed_m1_hazard_count -
                        directed_hazard_at_start != 1 ||
                    directed_m1_issue_count -
                        directed_issue_at_start != 1 ||
                    directed_m1_payload_watch_active_q)
                    fail("directed unsafe M1 hold/release/unique issue was incomplete");
                if (m1_row_admit_recovery_seen <=
                    recovery_seen_at_start)
                    fail("unsafe M1 did not recover across row admission");
                else
                    $display("PASS: case6 unsafe M1 held/released/recovered hold_cycles=%0d hazard/issue=%0d/%0d row_recovery_delta=%0d",
                             directed_m1_reader_hold_cycles -
                                 directed_hold_at_start,
                             directed_m1_hazard_count -
                                 directed_hazard_at_start,
                             directed_m1_issue_count -
                                 directed_issue_at_start,
                             m1_row_admit_recovery_seen -
                                 recovery_seen_at_start);
            end

            // Cin=5 at odd pixel boundaries necessarily creates a third
            // packed-word fragment; it must exercise the deferred suffix
            // queue instead of raising a collision.  The full-row cases must
            // also prove that inactive-row writes overlap active 3x3 reads.
            if (!kernel_1x1 && cin == 5 && case_defer_cycles == 0)
                fail("odd-Cin case did not exercise fragment deferral");
            if (!kernel_1x1 && (oh * ow) >= 936 &&
                case_rw_overlap_cycles == 0)
                fail("large case did not overlap inactive-row writes/reads");
            if (case_finish_drain_cycles == 0)
                fail("case did not exercise final M1-to-M3 drain");
            if (case_total_bytes > 4 && case_back_to_back_m1_cycles == 0)
                fail("case did not exercise consecutive M1 micro-ops");
            if ((w * cin) > KEEP_W && case_total_bytes >= 16 &&
                case_input_refill_cycles == 0)
                fail("case did not enqueue while issuing a micro-op");

            $display("PASS case=%0d %0s h=%0d w=%0d cin=%0d pixels=%0d passes=%0d entries=%0d mat_cycles=%0d stalls(axis/entry)=%0d/%0d defer=%0d rw_overlap=%0d finish_drain=%0d m1_b2b=%0d refill=%0d hash=%016x",
                     case_id, kernel_1x1 ? "1x1" : "3x3",
                     h, w, cin, oh * ow, case_passes,
                     case_expected_entries, materialize_cycles,
                     axis_stall_cycles,
                     entry_stall_cycles, case_defer_cycles,
                     case_rw_overlap_cycles, case_finish_drain_cycles,
                     case_back_to_back_m1_cycles,
                     case_input_refill_cycles, case_stream_hash);
            if (errors != start_errors)
                $display("  case %0d accumulated %0d new errors",
                         case_id, errors - start_errors);

            case_active <= 1'b0;
            repeat (3) @(negedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        cfg_start = 1'b0;
        cfg_fm_h = 16'd0;
        cfg_fm_w = 16'd0;
        cfg_cin = 14'd0;
        cfg_ofm_h = 16'd0;
        cfg_ofm_w = 16'd0;
        cfg_kernel_1x1 = 1'b0;
        cfg_stride = 2'd1;
        cfg_pad = 2'd0;
        cfg_input_zero_point = 8'd0;
        cfg_epoch = 8'd0;
        s_axis_tvalid = 1'b0;
        s_axis_tdata = 64'd0;
        s_axis_tkeep = 8'd0;
        s_axis_tlast = 1'b0;
        m_entry_ready = 1'b0;
        errors = 0;
        observed_entries = 0;
        case_id = 0;
        case_active = 1'b0;
        held_q = 1'b0;
        case_defer_cycles = 0;
        case_rw_overlap_cycles = 0;
        case_finish_drain_cycles = 0;
        case_back_to_back_m1_cycles = 0;
        case_input_refill_cycles = 0;
        fifo_empty_seen = 0;
        fifo_one_seen = 0;
        fifo_full_seen = 0;
        fifo_full_stall_seen = 0;
        fifo_enqueue_pop_seen = 0;
        fifo_row_retained_seen = 0;
        fifo_defer_priority_seen = 0;
        fifo_accept_closed_seen = 0;
        m1_held_seen = 0;
        m1_issue_refill_seen = 0;
        m1_defer_no_refill_seen = 0;
        s0_drain_refill_seen = 0;
        phase_a_seen = 0;
        phase_b_seen = 0;
        defer_consume_stale_seen = 0;
        defer_idle_cfg_stale_seen = 0;
        defer_replace_seen = 0;
        m0_row_quiet_seen = 0;
        case_phase_a_count = 0;
        case_phase_b_count = 0;
        s0_load_identity_seen = 0;
        s0_to_m0_identity_seen = 0;
        fifo_low_to_upper_seen = 0;
        fifo_low_tail_pop_seen = 0;
        fifo_upper_pop_seen = 0;
        m1_nohazard_interval_seen = 0;
        case_clock_count = 0;
        m1_nohazard_last_cycle = 0;
        m1_nohazard_chain_q = 1'b0;
        m0_row_hold_state = 0;
        m0_row_hold_capture_seen = 0;
        m0_row_hold_map_seen = 0;
        m0_row_hold_issue_seen = 0;
        s0_load_check_q = 1'b0;
        s0_to_m0_check_q = 1'b0;
        m0_row_hold_edge_check_q = 1'b0;
        m1_row_hold_watchdog = 0;
        m1_row_admit_recovery_seen = 0;
        m1_row_admit_recovery_watchdog = 0;
        m1_row_admit_recovery_pending_q = 1'b0;
        m1_row_hazard_seen_q = 1'b0;
        m1_row_admit_reader_check_q = 1'b0;
        directed_m1_reader_hold_started_q = 1'b0;
        directed_m1_hazard_seen_q = 1'b0;
        directed_m1_payload_watch_started_q = 1'b0;
        directed_m1_payload_watch_active_q = 1'b0;
        directed_m1_reader_hold_cycles = 0;
        directed_m1_hazard_count = 0;
        directed_m1_issue_count = 0;
        busy_cfg_injected_seen = 0;
        fifo_check_full_pop_recovery_q = 1'b0;
        fifo_check_accept_close_q = 1'b0;
        logical_end_defer_active = 1'b0;
        logical_end_defer_queued_seen = 0;
        logical_end_defer_issued_seen = 0;
        logical_end_defer_m1_seen = 0;
        logical_end_defer_m2_seen = 0;
        logical_end_defer_m3_seen = 0;
        logical_end_check_m1_q = 1'b0;
        logical_end_expect_m1_valid_q = 1'b0;
        logical_end_expect_m1_finish_q = 1'b0;
        logical_end_check_m2_q = 1'b0;
        logical_end_expect_m2_valid_q = 1'b0;
        logical_end_expect_m2_finish_q = 1'b0;
        logical_end_expect_m2_post_q = 32'd0;
        logical_end_check_m3_q = 1'b0;
        logical_end_expect_m3_valid_q = 1'b0;
        logical_end_expect_m3_finish_q = 1'b0;
        logical_end_expect_m3_stored_q = 32'd0;
        logical_end_expect_spec_q = 32'd0;
        logical_end_input_done_before_q = 1'b0;
        read_oracle_issues = 0;
        read_oracle_mode_mask = 0;
        read_oracle_row_start_seen = 0;
        read_oracle_row_end_seen = 0;
        read_oracle_bottom_seen = 0;
        planner_oracle_checks = 0;
        planner_oracle_held_checks = 0;
        planner_oracle_defer2_seen = 0;
        planner_oracle_defer3_seen = 0;
        case_stream_hash = 64'hcbf29ce484222325;
        // Establish a deterministic random stream for source gaps and sink
        // backpressure in simulators that implement the SystemVerilog seed.
        random_seed = 32'h18c0ffee;
        timeout_cycles = $urandom(random_seed);

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Tail TKEEP, channel-bank wrap, and K tail.
        run_case(5, 7, 20, 5, 7, 1, 1, 0, 8'h21);
        // Small 3x3 directed padding case with three K passes.
        run_case(4, 5, 5, 4, 5, 0, 1, 1, 8'h42);
        // Stride-two plus all four line-bank epochs.
        run_case(7, 9, 3, 4, 5, 0, 2, 1, 8'h63);
        // Exact one-pixel boundary and release maximum native-1x1 Cin.
        run_case(1, 1, 1024, 1, 1, 1, 1, 0, 8'h74);
        // Conv7 release boundary: seven packed x-pairs times 256 channel
        // groups requires 1792 words in each row store.
        run_case(13, 13, 1024, 13, 13, 1, 1, 0, 8'h76);
        // Exact 13x13/169-pixel spatial boundary.
        run_case(13, 13, 3, 13, 13, 0, 1, 1, 8'h75);
        // Exact 936-pixel boundary (24x39).
        run_case(24, 39, 3, 24, 39, 0, 1, 1, 8'h84);
        // Exact 1024-pixel boundary (32x32).
        run_case(32, 32, 3, 32, 32, 0, 1, 1, 8'ha5);
        // Pipeline boundary matrix: exact beat-per-row, odd fragment split,
        // packed-word boundary, and one full ROWS channel group.
        run_inflight_reset(0);
        run_case(3, 2, 4, 3, 2, 1, 1, 0, 8'hb4);
        run_inflight_reset(1);
        run_case(3, 4, 7, 3, 4, 0, 1, 1, 8'hb7);
        run_inflight_reset(2);
        run_case(2, 3, 8, 2, 3, 1, 1, 0, 8'hb8);
        run_inflight_reset(3);
        run_case(3, 3, 18, 3, 3, 0, 1, 1, 8'hc2);
        run_inflight_reset(4);
        run_inflight_reset(5);
        run_cin1023_directed();
        run_noncontiguous_keep_output();
        run_logical_end_in_defer();
        run_protocol_error_matrix();
        run_defer_consume_replace_priority();

        if (fifo_empty_seen == 0 || fifo_one_seen == 0 ||
            fifo_full_seen == 0 || fifo_full_stall_seen == 0 ||
            fifo_enqueue_pop_seen == 0 || fifo_row_retained_seen == 0 ||
            fifo_defer_priority_seen == 0 ||
            fifo_accept_closed_seen == 0)
            fail("accepted-beat FIFO directed coverage matrix was incomplete");
        else
            $display("PASS: beat FIFO empty/one/full/full-stall/enqueue-pop/row/defer/last coverage %0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d",
                     fifo_empty_seen, fifo_one_seen, fifo_full_seen,
                     fifo_full_stall_seen, fifo_enqueue_pop_seen,
                     fifo_row_retained_seen, fifo_defer_priority_seen,
                     fifo_accept_closed_seen);

        if (m1_held_seen == 0 || m1_issue_refill_seen == 0 ||
            m1_defer_no_refill_seen == 0 ||
            m1_row_admit_recovery_seen == 0 ||
            directed_m1_hazard_count == 0 ||
            directed_m1_issue_count == 0)
            fail("elastic M1 held/phase-A refill/defer coverage was incomplete");
        else
            $display("PASS: elastic M1 held/phase-A refill/defer coverage %0d/%0d/%0d (row-recovery=%0d)",
                     m1_held_seen, m1_issue_refill_seen,
                     m1_defer_no_refill_seen,
                     m1_row_admit_recovery_seen);

        if (s0_drain_refill_seen == 0 || phase_a_seen == 0 ||
            phase_b_seen == 0 || phase_b_seen > phase_a_seen ||
            m0_row_quiet_seen == 0)
            fail("S0/M0 two-phase mapper coverage/count was incomplete");
        else
            $display("PASS: S0 drain-refill, phase-A/phase-B, row-quiet coverage %0d/%0d/%0d/%0d",
                     s0_drain_refill_seen, phase_a_seen, phase_b_seen,
                     m0_row_quiet_seen);

        if (s0_load_identity_seen == 0 ||
            s0_to_m0_identity_seen == 0 ||
            fifo_low_to_upper_seen == 0 ||
            fifo_low_tail_pop_seen == 0 ||
            fifo_upper_pop_seen == 0 ||
            m1_nohazard_interval_seen == 0)
            fail("S0/FIFO identity or two-clock M1 interval coverage was incomplete");
        else
            $display("PASS: S0 load/M0 identity and FIFO low-next/low-pop/upper-pop/M1-2clk coverage %0d/%0d/%0d/%0d/%0d/%0d",
                     s0_load_identity_seen, s0_to_m0_identity_seen,
                     fifo_low_to_upper_seen, fifo_low_tail_pop_seen,
                     fifo_upper_pop_seen, m1_nohazard_interval_seen);

        if (m0_row_hold_capture_seen == 0 ||
            m0_row_hold_capture_seen != m0_row_hold_map_seen ||
            m0_row_hold_capture_seen != m0_row_hold_issue_seen ||
            m0_row_hold_state != 0)
            fail("M0 row-admission hold/map/issue coverage was not exactly once per item");
        else
            $display("PASS: M0 row-admission hold/map/issue exact recovery %0d/%0d/%0d",
                     m0_row_hold_capture_seen, m0_row_hold_map_seen,
                     m0_row_hold_issue_seen);

        if (read_oracle_issues == 0 ||
            (read_oracle_mode_mask & 8'h1a) != 8'h1a ||
            read_oracle_row_start_seen == 0 ||
            read_oracle_row_end_seen == 0 ||
            read_oracle_bottom_seen == 0)
            fail("read-address shadow-oracle coverage was incomplete");
        else
            $display("PASS: read-address old-formula oracle issues/modes/start/end/bottom %0d/%02x/%0d/%0d/%0d",
                     read_oracle_issues, read_oracle_mode_mask,
                     read_oracle_row_start_seen,
                     read_oracle_row_end_seen,
                     read_oracle_bottom_seen);

        if (planner_oracle_checks == 0 ||
            planner_oracle_held_checks == 0 ||
            planner_oracle_defer2_seen == 0)
            fail("ordered M1 planner shadow-oracle coverage was incomplete");
        else
            $display("PASS: ordered M1 planner oracle checks/held/defer2/defer3 %0d/%0d/%0d/%0d",
                     planner_oracle_checks, planner_oracle_held_checks,
                     planner_oracle_defer2_seen,
                     planner_oracle_defer3_seen);

        if (busy_cfg_injected_seen != 1)
            fail("busy cfg_start atomic-continuation coverage was not exactly once");
        else
            $display("PASS: busy cfg_start preserved exact M0/M2 transaction and hash");

        if (defer_consume_stale_seen == 0 ||
            defer_idle_cfg_stale_seen == 0 || defer_replace_seen != 1)
            fail("deferred stale-payload valid gating coverage was incomplete");
        else
            $display("PASS: deferred payload stale gating and replacement coverage consume/idle-cfg/replace=%0d/%0d/%0d",
                     defer_consume_stale_seen, defer_idle_cfg_stale_seen,
                     defer_replace_seen);

        if (errors == 0) begin
            $display("PASS: axis_hwc_window_materializer randomized self-check");
            $finish;
        end else begin
            $display("FAIL: axis_hwc_window_materializer errors=%0d", errors);
            $fatal(1);
        end
    end
endmodule

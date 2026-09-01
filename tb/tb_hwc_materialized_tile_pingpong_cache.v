`timescale 1ns / 1ps

module tb_hwc_materialized_tile_pingpong_cache;
    localparam integer ROWS = 4;
    localparam integer EPOCH_W = 8;
    localparam integer TILE_W = 4;
    localparam integer PASS_W = 16;
    localparam integer PIXEL_W = 32;
    // Match the release configuration so the narrow watermark and the full
    // 512-bit compatibility view are both exercised by this unit test.
    localparam integer MAX_PASSES = 512;
    localparam integer BANK_AW = 9;
    localparam integer BANK_DEPTH = 512;
    localparam integer OFM_W = 3;
    localparam integer OFM_H = 5;
    localparam integer TILE_H = 2;
    localparam integer PASS_COUNT = 2;

    reg clk;
    reg rst;
    reg cfg_start;
    reg [EPOCH_W-1:0] cfg_epoch;
    reg [15:0] cfg_ofm_w;
    reg [15:0] cfg_ofm_h;
    reg [15:0] cfg_tile_h_max;
    reg [15:0] cfg_k_total;

    reg entry_valid;
    wire entry_ready;
    reg [ROWS*8-1:0] entry_data;
    reg [ROWS-1:0] entry_lane_valid;
    reg [PIXEL_W-1:0] entry_pixel;
    reg [PASS_W-1:0] entry_k_pass;
    reg [EPOCH_W-1:0] entry_epoch;
    reg entry_last;

    reg fill_req;
    wire fill_req_ready;
    wire fill_req_accept;
    reg [15:0] pass_base_k;
    reg [PASS_W-1:0] fill_k_pass;
    reg [TILE_W-1:0] fill_tile_index;
    reg [PIXEL_W-1:0] fill_pixel_base;
    reg [PIXEL_W-1:0] fill_num_pixels;
    wire fill_req_pending;
    wire [ROWS*8-1:0] vector_data;
    wire [ROWS-1:0] vector_lane_valid;
    wire vector_valid;
    reg vector_ready;
    wire vector_last;
    wire packet_done;

    reg release_valid;
    wire release_ready;
    reg [EPOCH_W-1:0] release_epoch;
    reg [TILE_W-1:0] release_tile_index;

    wire configured;
    wire materialize_active;
    wire materialize_done;
    wire replay_active;
    wire [TILE_W-1:0] active_replay_tile;
    wire [PASS_W-1:0] active_replay_pass;
    wire bank0_owned;
    wire bank0_fill_complete;
    wire [EPOCH_W-1:0] bank0_epoch;
    wire [TILE_W-1:0] bank0_tile_index;
    wire [PIXEL_W-1:0] bank0_pixel_base;
    wire [PIXEL_W-1:0] bank0_pixel_count;
    wire [MAX_PASSES-1:0] bank0_pass_ready_bitmap;
    wire bank1_owned;
    wire bank1_fill_complete;
    wire [EPOCH_W-1:0] bank1_epoch;
    wire [TILE_W-1:0] bank1_tile_index;
    wire [PIXEL_W-1:0] bank1_pixel_base;
    wire [PIXEL_W-1:0] bank1_pixel_count;
    wire [MAX_PASSES-1:0] bank1_pass_ready_bitmap;
    wire config_error;
    wire order_error;
    wire tag_error;
    wire ownership_error;
    wire overflow_error;
    wire [4:0] error_status;
    wire [31:0] accepted_entries;
    wire [31:0] stored_entries;
    wire [31:0] completed_packets;
    wire [31:0] completed_pixels;
    wire [31:0] order_error_count;
    wire [31:0] tag_error_count;
    wire [31:0] ownership_error_count;
    wire [31:0] ownership_stall_cycles;
    wire [31:0] context_gap_cycles;
    wire [31:0] vector_backpressure_stall_cycles;
    wire [31:0] release_stall_cycles;

    integer pass_count_score;
    integer fail_count;
    integer score_seen;
    integer score_base;
    integer score_count;
    integer score_pass;
    integer score_epoch;
    integer timeout_count;
    integer high_pass;
    integer phase;
    wire prevalidated_probe_done;
    wire prevalidated_probe_failed;
    wire epoch_pipe_probe_done;
    wire epoch_pipe_probe_failed;

    cache_prevalidated_pass_probe u_prevalidated_probe (
        .clk(clk),
        .done(prevalidated_probe_done),
        .failed(prevalidated_probe_failed)
    );
    cache_epoch_pipe_probe u_epoch_pipe_probe (
        .clk(clk),
        .done(epoch_pipe_probe_done),
        .failed(epoch_pipe_probe_failed)
    );
    reg score_active;
    reg random_ready_enable;
    reg held_output_q;
    reg [ROWS*8-1:0] held_data_q;
    reg [ROWS-1:0] held_lane_q;
    reg held_last_q;
    reg overlap_seen_q;
    reg layer_done_seen_q;
    reg tile2_driver_started_q;

    function [MAX_PASSES-1:0] ready_prefix;
        input integer ready_count_i;
        integer ready_i;
        begin
            ready_prefix = {MAX_PASSES{1'b0}};
            for (ready_i = 0; ready_i < MAX_PASSES;
                 ready_i = ready_i + 1)
                if (ready_i < ready_count_i)
                    ready_prefix[ready_i] = 1'b1;
        end
    endfunction

    hwc_materialized_tile_pingpong_cache #(
        .ROWS(ROWS), .EPOCH_W(EPOCH_W), .TILE_W(TILE_W),
        .PASS_W(PASS_W), .PIXEL_W(PIXEL_W),
        .MAX_PASSES(MAX_PASSES), .BANK_AW(BANK_AW),
        .BANK_DEPTH(BANK_DEPTH)
    ) dut (
        .clk(clk), .rst(rst),
        .cfg_start(cfg_start), .cfg_epoch(cfg_epoch),
        .cfg_ofm_w(cfg_ofm_w), .cfg_ofm_h(cfg_ofm_h),
        .cfg_tile_h_max(cfg_tile_h_max), .cfg_k_total(cfg_k_total),
        .entry_valid(entry_valid), .entry_ready(entry_ready),
        .entry_data(entry_data), .entry_lane_valid(entry_lane_valid),
        .entry_pixel(entry_pixel), .entry_k_pass(entry_k_pass),
        .entry_epoch(entry_epoch), .entry_last(entry_last),
        .fill_req(fill_req), .fill_req_ready(fill_req_ready),
        .fill_req_accept(fill_req_accept), .pass_base_k(pass_base_k),
        .fill_k_pass(fill_k_pass),
        .fill_tile_index(fill_tile_index),
        .fill_pixel_base(fill_pixel_base),
        .fill_num_pixels(fill_num_pixels),
        .fill_req_pending(fill_req_pending),
        .vector_data(vector_data),
        .vector_lane_valid(vector_lane_valid),
        .vector_valid(vector_valid), .vector_ready(vector_ready),
        .vector_last(vector_last), .packet_done(packet_done),
        .release_valid(release_valid), .release_ready(release_ready),
        .release_epoch(release_epoch),
        .release_tile_index(release_tile_index),
        .configured(configured), .materialize_active(materialize_active),
        .materialize_done(materialize_done),
        .replay_active(replay_active),
        .active_replay_tile(active_replay_tile),
        .active_replay_pass(active_replay_pass),
        .bank0_owned(bank0_owned),
        .bank0_fill_complete(bank0_fill_complete),
        .bank0_epoch(bank0_epoch), .bank0_tile_index(bank0_tile_index),
        .bank0_pixel_base(bank0_pixel_base),
        .bank0_pixel_count(bank0_pixel_count),
        .bank0_pass_ready_bitmap(bank0_pass_ready_bitmap),
        .bank1_owned(bank1_owned),
        .bank1_fill_complete(bank1_fill_complete),
        .bank1_epoch(bank1_epoch), .bank1_tile_index(bank1_tile_index),
        .bank1_pixel_base(bank1_pixel_base),
        .bank1_pixel_count(bank1_pixel_count),
        .bank1_pass_ready_bitmap(bank1_pass_ready_bitmap),
        .config_error(config_error), .order_error(order_error),
        .tag_error(tag_error), .ownership_error(ownership_error),
        .overflow_error(overflow_error), .error_status(error_status),
        .accepted_entries(accepted_entries),
        .stored_entries(stored_entries),
        .completed_packets(completed_packets),
        .completed_pixels(completed_pixels),
        .order_error_count(order_error_count),
        .tag_error_count(tag_error_count),
        .ownership_error_count(ownership_error_count),
        .ownership_stall_cycles(ownership_stall_cycles),
        .context_gap_cycles(context_gap_cycles),
        .vector_backpressure_stall_cycles(
            vector_backpressure_stall_cycles),
        .release_stall_cycles(release_stall_cycles)
    );

    always #5 clk = ~clk;

    function [7:0] expected_byte;
        input integer epoch_i;
        input integer pixel_i;
        input integer pass_i;
        input integer lane_i;
        begin
            expected_byte = (epoch_i * 41 + pixel_i * 7 +
                             pass_i * 13 + lane_i) & 8'hff;
        end
    endfunction

    function [ROWS*8-1:0] make_vector;
        input integer epoch_i;
        input integer pixel_i;
        input integer pass_i;
        integer lane_i;
        begin
            make_vector = {ROWS*8{1'b0}};
            for (lane_i = 0; lane_i < ROWS; lane_i = lane_i + 1)
                make_vector[lane_i*8 +: 8] =
                    expected_byte(epoch_i, pixel_i, pass_i, lane_i);
        end
    endfunction

    function [ROWS-1:0] make_lane_valid;
        input integer pass_i;
        integer lane_i;
        begin
            make_lane_valid = {ROWS{1'b0}};
            for (lane_i = 0; lane_i < ROWS; lane_i = lane_i + 1)
                if ((pass_i * ROWS + lane_i) < cfg_k_total)
                    make_lane_valid[lane_i] = 1'b1;
        end
    endfunction

    task fail;
        input [8*120-1:0] message;
        begin
            $display("[FAIL] %0s", message);
            fail_count = fail_count + 1;
        end
    endtask

    task pass;
        input [8*120-1:0] message;
        begin
            $display("[PASS] %0s", message);
            pass_count_score = pass_count_score + 1;
        end
    endtask

    task apply_custom_config;
        input integer epoch_i;
        input integer ofm_w_i;
        input integer ofm_h_i;
        input integer tile_h_i;
        input integer k_total_i;
        begin
            @(negedge clk);
            cfg_epoch = epoch_i[EPOCH_W-1:0];
            cfg_ofm_w = ofm_w_i;
            cfg_ofm_h = ofm_h_i;
            cfg_tile_h_max = tile_h_i;
            cfg_k_total = k_total_i;
            cfg_start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            cfg_start = 1'b0;
            // Configuration products are first captured, then committed
            // atomically to the allocator/cache state one cycle later.
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task apply_config;
        input integer epoch_i;
        input integer tile_h_i;
        begin
            apply_custom_config(epoch_i, OFM_W, OFM_H, tile_h_i,
                                ROWS * PASS_COUNT - 2);
        end
    endtask

    task drive_entry;
        input integer epoch_i;
        input integer pixel_i;
        input integer pass_i;
        input integer last_i;
        begin
            @(negedge clk);
            entry_valid = 1'b1;
            entry_epoch = epoch_i[EPOCH_W-1:0];
            entry_pixel = pixel_i;
            entry_k_pass = pass_i[PASS_W-1:0];
            entry_last = last_i[0:0];
            entry_data = make_vector(epoch_i, pixel_i, pass_i);
            entry_lane_valid = make_lane_valid(pass_i);
            while (!entry_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            entry_valid = 1'b0;
        end
    endtask

    task drive_bad_lane_entry;
        input integer epoch_i;
        input integer pixel_i;
        input integer pass_i;
        begin
            @(negedge clk);
            entry_valid = 1'b1;
            entry_epoch = epoch_i[EPOCH_W-1:0];
            entry_pixel = pixel_i;
            entry_k_pass = pass_i[PASS_W-1:0];
            entry_last = 1'b0;
            entry_data = make_vector(epoch_i, pixel_i, pass_i);
            entry_lane_valid = {ROWS{1'b0}};
            while (!entry_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            entry_valid = 1'b0;
        end
    endtask

    // Retire the final accepted entry of a directed fill and make the new
    // accept/commit boundary explicit.  Completion metadata must remain old
    // for the whole cycle in which wr_commit_valid is first asserted, then
    // change atomically with the physical RAM write on the following edge.
    task retire_pending_write;
        reg saved_bank;
        reg [BANK_AW-1:0] saved_addr;
        reg [ROWS*8-1:0] saved_data;
        reg [PASS_W-1:0] saved_ready_count;
        reg saved_finishes_pass;
        reg saved_finishes_tile;
        reg saved_finishes_layer;
        reg [31:0] stored_before;
        begin
            saved_bank = dut.wr_commit_bank_q;
            saved_addr = dut.wr_commit_addr_q;
            saved_data = dut.wr_commit_data_q;
            saved_ready_count = dut.wr_commit_ready_count_q;
            saved_finishes_pass = dut.wr_commit_finishes_pass_q;
            saved_finishes_tile = dut.wr_commit_finishes_tile_q;
            saved_finishes_layer = dut.wr_commit_finishes_layer_q;
            stored_before = stored_entries;

            if (!dut.wr_commit_valid_q)
                fail("final accept did not populate write-commit bundle");
            if (saved_finishes_pass &&
                dut.bank_ready_count_q[saved_bank] >= saved_ready_count)
                fail("pass-ready published before physical write commit");
            if (saved_finishes_tile &&
                dut.bank_complete_q[saved_bank])
                fail("bank-complete published before physical write commit");
            if (saved_finishes_layer && materialize_done)
                fail("materialize_done published before physical write commit");

            @(posedge clk);
            @(negedge clk);
            if (stored_entries != stored_before + 1)
                fail("stored entry did not retire exactly once at commit");
            if (saved_finishes_pass &&
                dut.bank_ready_count_q[saved_bank] != saved_ready_count)
                fail("pass-ready did not publish with physical write commit");
            if (saved_finishes_tile &&
                !dut.bank_complete_q[saved_bank])
                fail("bank-complete did not publish with physical write commit");
            if (saved_finishes_layer && !materialize_done)
                fail("materialize_done did not publish with physical write commit");
            if (!saved_bank &&
                dut.u_bank0.data_mem[saved_addr] !== saved_data)
                fail("bank0 physical write did not match commit bundle");
            if (saved_bank &&
                dut.u_bank1.data_mem[saved_addr] !== saved_data)
                fail("bank1 physical write did not match commit bundle");
        end
    endtask

    // Two adjacent valid cycles prove that retiring the old bundle and
    // capturing the next bundle share one edge without reducing throughput.
    task drive_two_entries_gapless;
        input integer epoch_i;
        input integer pixel0_i;
        input integer pass0_i;
        input integer pixel1_i;
        input integer pass1_i;
        reg [31:0] stored_before;
        reg [ROWS*8-1:0] data0;
        reg [ROWS*8-1:0] data1;
        begin
            stored_before = stored_entries;
            data0 = make_vector(epoch_i, pixel0_i, pass0_i);
            data1 = make_vector(epoch_i, pixel1_i, pass1_i);
            @(negedge clk);
            entry_valid = 1'b1;
            entry_epoch = epoch_i[EPOCH_W-1:0];
            entry_pixel = pixel0_i;
            entry_k_pass = pass0_i[PASS_W-1:0];
            entry_last = 1'b0;
            entry_data = data0;
            entry_lane_valid = make_lane_valid(pass0_i);
            if (!entry_ready)
                fail("gapless entry0 was not ready");
            @(posedge clk);
            @(negedge clk);
            if (!dut.wr_commit_valid_q || stored_entries != stored_before)
                fail("entry0 commit bundle was not isolated from stored count");
            entry_pixel = pixel1_i;
            entry_k_pass = pass1_i[PASS_W-1:0];
            entry_data = data1;
            entry_lane_valid = make_lane_valid(pass1_i);
            if (!entry_ready)
                fail("gapless entry1 lost one-entry-per-clock credit");
            @(posedge clk);
            @(negedge clk);
            if (stored_entries != stored_before + 1 ||
                !dut.wr_commit_valid_q ||
                dut.u_bank0.data_mem[0] !== data0)
                fail("old commit and new capture did not share one edge");
            entry_valid = 1'b0;
            @(posedge clk);
            @(negedge clk);
            if (stored_entries != stored_before + 2 ||
                dut.u_bank0.data_mem[2] !== data1)
                fail("gapless second entry did not retire exactly once");
            else
                pass("registered write bundle sustained one entry per clock");
        end
    endtask

    // Hold a spurious N+1 entry and assert cfg_start while the final physical
    // write is pending.  Credit must close at accept, and the rejected config
    // must not suppress commit or alter the active owner.
    task retire_final_with_nplus1_busy_cfg;
        input integer epoch_i;
        input integer pixel_i;
        input integer pass_i;
        reg [31:0] stored_before;
        reg [31:0] accepted_before;
        reg [31:0] ownership_errors_before;
        begin
            stored_before = stored_entries;
            accepted_before = accepted_entries;
            ownership_errors_before = ownership_error_count;
            @(negedge clk);
            entry_valid = 1'b1;
            entry_epoch = epoch_i[EPOCH_W-1:0];
            entry_pixel = pixel_i;
            entry_k_pass = pass_i[PASS_W-1:0];
            entry_last = 1'b1;
            entry_data = make_vector(epoch_i, pixel_i, pass_i);
            entry_lane_valid = make_lane_valid(pass_i);
            while (!entry_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            if (!dut.wr_commit_valid_q || entry_ready ||
                stored_entries != stored_before ||
                bank0_fill_complete || materialize_done)
                fail("final accept did not reserve credit before commit");

            // Keep valid asserted with a distinct N+1 payload while a busy
            // configuration request competes with the pending commit.
            entry_pixel = pixel_i + 1;
            entry_data = make_vector(epoch_i, pixel_i + 1, pass_i);
            entry_last = 1'b0;
            cfg_epoch = epoch_i + 8'h20;
            cfg_ofm_w = 1;
            cfg_ofm_h = 1;
            cfg_tile_h_max = 1;
            cfg_k_total = ROWS;
            cfg_start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            entry_valid = 1'b0;
            cfg_start = 1'b0;
            if (accepted_entries != accepted_before + 1 ||
                stored_entries != stored_before + 1 ||
                !bank0_fill_complete || !materialize_done ||
                dut.wr_commit_valid_q || entry_ready)
                fail("pending final commit was lost or accepted N+1 entry");
            if (ownership_error_count != ownership_errors_before + 1 ||
                bank0_epoch != epoch_i[EPOCH_W-1:0])
                fail("busy cfg_start perturbed pending write ownership");
            else
                pass("final credit, N+1 rejection, and busy-cfg commit ordering held");
        end
    endtask

    task fill_tile;
        input integer tile_i;
        input integer epoch_i;
        integer y_i;
        integer p_i;
        integer x_i;
        integer first_y;
        integer last_y;
        integer pixel_i;
        integer last_i;
        integer expected_last_bit_i;
        integer last_bit_stable_i;
        begin
            first_y = tile_i * TILE_H;
            last_y = first_y + TILE_H;
            if (last_y > OFM_H)
                last_y = OFM_H;
            expected_last_bit_i = (last_y == OFM_H);
            last_bit_stable_i = 1;
            for (y_i = first_y; y_i < last_y; y_i = y_i + 1) begin
                for (p_i = 0; p_i < PASS_COUNT; p_i = p_i + 1) begin
                    for (x_i = 0; x_i < OFM_W; x_i = x_i + 1) begin
                        pixel_i = y_i * OFM_W + x_i;
                        last_i = (pixel_i == OFM_W*OFM_H-1) &&
                                 (p_i == PASS_COUNT-1);
                        drive_entry(epoch_i, pixel_i, p_i, last_i);
                        if (dut.fill_tile_is_layer_last_q !==
                                expected_last_bit_i[0:0])
                            last_bit_stable_i = 0;
                    end
                end
            end
            if (!last_bit_stable_i)
                fail("registered layer-last bit changed within a tile");
            else
                pass("registered layer-last bit stayed stable for a full tile");
            retire_pending_write();
        end
    endtask

    task fill_custom_tile_checked;
        input integer tile_i;
        input integer epoch_i;
        input integer ofm_w_i;
        input integer ofm_h_i;
        input integer tile_h_i;
        input integer pass_count_i;
        input integer expected_last_bit_i;
        integer y_i;
        integer p_i;
        integer x_i;
        integer first_y;
        integer last_y;
        integer pixel_i;
        integer last_i;
        integer last_bit_stable_i;
        begin
            first_y = tile_i * tile_h_i;
            last_y = first_y + tile_h_i;
            if (last_y > ofm_h_i)
                last_y = ofm_h_i;
            last_bit_stable_i = 1;
            for (y_i = first_y; y_i < last_y; y_i = y_i + 1) begin
                for (p_i = 0; p_i < pass_count_i; p_i = p_i + 1) begin
                    for (x_i = 0; x_i < ofm_w_i; x_i = x_i + 1) begin
                        pixel_i = y_i * ofm_w_i + x_i;
                        last_i = (pixel_i == ofm_w_i*ofm_h_i-1) &&
                                 (p_i == pass_count_i-1);
                        drive_entry(epoch_i, pixel_i, p_i, last_i);
                        if (dut.fill_tile_is_layer_last_q !==
                                expected_last_bit_i[0:0])
                            last_bit_stable_i = 0;
                    end
                end
            end
            if (!last_bit_stable_i)
                fail("custom tile observed an unstable layer-last bit");
            else
                pass("custom tile kept its registered layer-last bit stable");
            retire_pending_write();
        end
    endtask

    task replay_packet;
        input integer epoch_i;
        input integer tile_i;
        input integer base_i;
        input integer count_i;
        input integer pass_i;
        begin
            while (score_active)
                @(negedge clk);
            score_active = 1'b1;
            score_seen = 0;
            score_base = base_i;
            score_count = count_i;
            score_pass = pass_i;
            score_epoch = epoch_i;

            @(negedge clk);
            pass_base_k = pass_i * ROWS;
            fill_k_pass = pass_i;
            fill_tile_index = tile_i[TILE_W-1:0];
            fill_pixel_base = base_i;
            fill_num_pixels = count_i;
            fill_req = 1'b1;
            wait (fill_req_accept);
            wait (packet_done);
            @(negedge clk);
            fill_req = 1'b0;
            if (score_seen != count_i)
                fail("packet produced the wrong vector count");
            else
                pass("held replay request completed with exact vector count");
            score_active = 1'b0;
            @(posedge clk);
        end
    endtask

    task release_tile;
        input integer epoch_i;
        input integer tile_i;
        begin
            @(negedge clk);
            release_epoch = epoch_i[EPOCH_W-1:0];
            release_tile_index = tile_i[TILE_W-1:0];
            release_valid = 1'b1;
            wait (release_ready);
            @(posedge clk);
            @(negedge clk);
            release_valid = 1'b0;
            @(posedge clk);
        end
    endtask

    task replay_with_simultaneous_release;
        input integer epoch_i;
        input integer tile_i;
        input integer base_i;
        input integer count_i;
        input integer pass_i;
        begin
            while (score_active)
                @(negedge clk);
            score_active = 1'b1;
            score_seen = 0;
            score_base = base_i;
            score_count = count_i;
            score_pass = pass_i;
            score_epoch = epoch_i;

            @(negedge clk);
            pass_base_k = pass_i * ROWS;
            fill_k_pass = pass_i;
            fill_tile_index = tile_i[TILE_W-1:0];
            fill_pixel_base = base_i;
            fill_num_pixels = count_i;
            release_epoch = epoch_i[EPOCH_W-1:0];
            release_tile_index = tile_i[TILE_W-1:0];
            fill_req = 1'b1;
            release_valid = 1'b1;
            #1;
            if (!fill_req_ready || release_ready)
                fail("incoming replay did not win same-owner release edge");
            @(posedge clk);
            @(negedge clk);
            fill_req = 1'b0;
            if (!fill_req_pending || !bank0_owned)
                fail("captured replay did not retain owner against release");
            wait (packet_done);
            wait (release_ready);
            @(posedge clk);
            @(negedge clk);
            release_valid = 1'b0;
            if (bank0_owned || score_seen != count_i)
                fail("release did not retire exactly after captured replay");
            else
                pass("incoming replay/release ordering preserved the owner");
            score_active = 1'b0;
        end
    endtask

    integer lane_score;
    always @(posedge clk) begin
        if (rst) begin
            held_output_q <= 1'b0;
            overlap_seen_q <= 1'b0;
            layer_done_seen_q <= 1'b0;
        end else begin
            if (bank0_pass_ready_bitmap !==
                    ready_prefix(dut.bank_ready_count_q[0]) ||
                bank1_pass_ready_bitmap !==
                    ready_prefix(dut.bank_ready_count_q[1]))
                fail("compatibility bitmap does not match ready watermark");

            if (held_output_q) begin
                if (!vector_valid || vector_data !== held_data_q ||
                    vector_lane_valid !== held_lane_q ||
                    vector_last !== held_last_q)
                    fail("replay output changed while backpressured");
            end
            held_output_q <= vector_valid && !vector_ready;
            if (vector_valid && !vector_ready) begin
                held_data_q <= vector_data;
                held_lane_q <= vector_lane_valid;
                held_last_q <= vector_last;
            end

            if (entry_valid && entry_ready && replay_active &&
                (entry_pixel >= OFM_W*TILE_H) &&
                (entry_pixel < OFM_W*TILE_H*2))
                overlap_seen_q <= 1'b1;
            if (materialize_done)
                layer_done_seen_q <= 1'b1;

            if (vector_valid && vector_ready) begin
                if (!score_active) begin
                    fail("vector appeared without an active scoreboard packet");
                end else begin
                    if (vector_lane_valid !== make_lane_valid(score_pass))
                        fail("lane-valid tag mismatch");
                    for (lane_score = 0; lane_score < ROWS;
                         lane_score = lane_score + 1) begin
                        if (vector_data[lane_score*8 +: 8] !==
                            expected_byte(score_epoch,
                                score_base + score_seen,
                                score_pass, lane_score))
                            fail("replayed vector data/tag mismatch");
                    end
                    if (vector_last !== (score_seen + 1 == score_count))
                        fail("vector_last mismatch");
                    score_seen = score_seen + 1;
                end
            end
        end
    end

    always @(negedge clk) begin
        if (rst)
            vector_ready <= 1'b0;
        else if (random_ready_enable)
            vector_ready <= ($urandom_range(0, 3) != 0);
        else
            vector_ready <= 1'b1;
    end

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        cfg_start = 1'b0;
        cfg_epoch = 0;
        cfg_ofm_w = 0;
        cfg_ofm_h = 0;
        cfg_tile_h_max = 0;
        cfg_k_total = 0;
        entry_valid = 1'b0;
        entry_data = 0;
        entry_lane_valid = 0;
        entry_pixel = 0;
        entry_k_pass = 0;
        entry_epoch = 0;
        entry_last = 1'b0;
        fill_req = 1'b0;
        pass_base_k = 0;
        fill_k_pass = 0;
        fill_tile_index = 0;
        fill_pixel_base = 0;
        fill_num_pixels = 0;
        vector_ready = 1'b0;
        release_valid = 1'b0;
        release_epoch = 0;
        release_tile_index = 0;
        pass_count_score = 0;
        fail_count = 0;
        score_seen = 0;
        score_base = 0;
        score_count = 0;
        score_pass = 0;
        score_epoch = 0;
        score_active = 1'b0;
        random_ready_enable = 1'b1;
        tile2_driver_started_q = 1'b0;
        phase = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // A 3x3 tile with 57 passes would require 513 entries in one 512-entry
        // bank.  This must fail, whereas the ordinary two-pass layer is legal
        // because its maximum tile footprint is only 12 entries.
        apply_custom_config(1, OFM_W, OFM_H, 3, ROWS * 57);
        phase = 1;
        if (configured || !config_error || !overflow_error)
            fail("maximum-tile capacity validation did not fail closed");
        else
            pass("configuration checks maximum tile entries, not layer size");

        // A layer shorter than tile_h_max is a one-tile layer.  Its final-bit
        // decision is captured with the initial allocation, and both early
        // and missing TLAST must fail closed without moving the fill cursor.
        apply_custom_config(2, 3, 1, 2, 6);
        if (!configured || dut.fill_tile_is_layer_last_q !== 1'b1 ||
            bank0_pixel_count != 3)
            fail("one-tile configuration did not register layer-last");
        else
            pass("one-tile configuration registered layer-last at commit");
        drive_entry(2, 0, 0, 1);
        drive_bad_lane_entry(2, 0, 0);
        if (!order_error || order_error_count != 2 ||
            stored_entries != 0 || bank0_pass_ready_bitmap != 0)
            fail("bad last/lane tags advanced cache commit state");
        else
            pass("bad last/lane tags fail closed before RAM commit");

        drive_two_entries_gapless(2, 0, 0, 1, 0);
        drive_entry(2, 2, 0, 0);
        drive_entry(2, 0, 1, 0);
        drive_entry(2, 1, 1, 0);
        drive_entry(2, 2, 1, 0);
        if (order_error_count != 3 || stored_entries != 5 ||
            bank0_fill_complete || materialize_done ||
            dut.fill_tile_is_layer_last_q !== 1'b1)
            fail("missing final TLAST did not hold the final fill entry");
        else
            pass("missing final TLAST failed closed with final bit stable");
        retire_final_with_nplus1_busy_cfg(2, 2, 1);
        if (stored_entries != 6 || !bank0_fill_complete ||
            !materialize_done || dut.fill_tile_is_layer_last_q !== 1'b1)
            fail("corrected final TLAST did not complete one-tile fill");
        else
            pass("corrected final TLAST completed the one-tile fill once");

        // The busy cfg_start issued with the pending physical write above must
        // not perturb the active fill context or registered final decision.
        if (!configured || !ownership_error ||
            ownership_error_count != 1 || bank0_epoch != 2 ||
            dut.fill_tile_is_layer_last_q !== 1'b1)
            fail("busy cfg_start changed the registered layer-last context");
        else
            pass("busy cfg_start preserved the registered layer-last context");

        replay_with_simultaneous_release(2, 0, 0, 3, 0);

        @(negedge clk);
        rst = 1'b1;
        repeat (3) @(posedge clk);
        if (dut.fill_tile_is_layer_last_q !== 1'b0)
            fail("reset did not clear registered layer-last state");
        else
            pass("reset cleared registered layer-last state");
        @(negedge clk);
        rst = 1'b0;

        // Reset at each newly introduced pipeline boundary.  A pending write
        // may leave stale RAM payload, but no commit metadata is published;
        // WAIT/ADDR requests must not survive to start replay.
        apply_custom_config(8'h31, 2, 1, 1, ROWS);
        drive_entry(8'h31, 0, 0, 0);
        if (!dut.wr_commit_valid_q)
            fail("reset probe did not reach pending write state");
        rst = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (dut.wr_commit_valid_q || stored_entries != 0 ||
            dut.bank_ready_count_q[0] != 0 || bank0_fill_complete ||
            materialize_done)
            fail("reset published or retained a pending write commit");
        else
            pass("reset cancelled pending write metadata publication");
        rst = 1'b0;

        apply_custom_config(8'h32, 1, 1, 1, ROWS * 2);
        @(negedge clk);
        pass_base_k = ROWS;
        fill_k_pass = 1;
        fill_tile_index = 0;
        fill_pixel_base = 0;
        fill_num_pixels = 1;
        fill_req = 1'b1;
        @(posedge clk);
        @(negedge clk);
        fill_req = 1'b0;
        if (dut.req_state_q != 2'd1 || !fill_req_pending)
            fail("reset probe did not reach request WAIT state");
        rst = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (dut.req_state_q != 2'd0 || fill_req_pending ||
            replay_active || vector_valid)
            fail("reset retained request WAIT state");
        else
            pass("reset cleared request WAIT state");
        rst = 1'b0;

        apply_custom_config(8'h33, 1, 1, 1, ROWS);
        drive_entry(8'h33, 0, 0, 1);
        retire_pending_write();
        @(negedge clk);
        pass_base_k = 0;
        fill_k_pass = 0;
        fill_tile_index = 0;
        fill_pixel_base = 0;
        fill_num_pixels = 1;
        fill_req = 1'b1;
        @(posedge clk);
        @(negedge clk);
        fill_req = 1'b0;
        @(posedge clk);
        @(negedge clk);
        if (dut.req_state_q != 2'd2 || !fill_req_pending)
            fail("reset probe did not reach request ADDR state");
        rst = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (dut.req_state_q != 2'd0 || fill_req_pending ||
            replay_active || vector_valid)
            fail("reset retained request ADDR state or launched replay");
        else
            pass("reset cleared request ADDR before replay launch");
        rst = 1'b0;

        // A statically legal range that belongs to neither the active owner
        // nor the one future owner must be rejected exactly once.  Holding
        // fill_req high proves the edge-arm prevents repeated diagnostics
        // after the registered WAIT classification is consumed.
        apply_custom_config(8'h34, 3, 3, 2, ROWS);
        phase = 14;
        @(negedge clk);
        pass_base_k = 0;
        fill_k_pass = 0;
        fill_tile_index = 1;
        fill_pixel_base = 5;
        fill_num_pixels = 3;
        fill_req = 1'b1;
        #1;
        if (!fill_req_ready)
            fail("invalid-future probe was not accepted into the request slot");
        @(posedge clk);
        #1;
        if (!fill_req_accept || !fill_req_pending ||
            dut.req_future_known_q !== 1'b0 ||
            dut.req_future_match_q !== 1'b0)
            fail("invalid-future request did not enter unclassified WAIT");
        @(posedge clk);
        #1;
        if (!fill_req_pending || dut.req_future_known_q !== 1'b1 ||
            dut.req_future_match_q !== 1'b0 || order_error)
            fail("invalid-future WAIT classification was not captured false");
        @(posedge clk);
        #1;
        if (!order_error || order_error_count != 1 || fill_req_pending ||
            dut.req_state_q != 2'd0 || replay_active)
            fail("invalid future range did not fail closed exactly once");
        repeat (3) @(posedge clk);
        #1;
        if (order_error_count != 1 || fill_req_ready || replay_active)
            fail("held invalid future request repeated its diagnostic");
        else
            pass("invalid future snapshot raised one fail-stop diagnostic");
        @(negedge clk);
        fill_req = 1'b0;

        // Reset away the negative probe, then accept a request for the short
        // tail tile on the exact edge that the allocator publishes that tile
        // into bank1.  WAIT sees the newly allocated owner on the following
        // cycle and therefore does not need a future-descriptor classification.
        rst = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        apply_custom_config(8'h35, 3, 3, 2, ROWS);
        phase = 15;
        random_ready_enable = 1'b0;
        drive_entry(8'h35, 0, 0, 0);
        drive_entry(8'h35, 1, 0, 0);
        drive_entry(8'h35, 2, 0, 0);
        drive_entry(8'h35, 3, 0, 0);
        drive_entry(8'h35, 4, 0, 0);
        drive_entry(8'h35, 5, 0, 0);
        if (!dut.wr_commit_valid_q || dut.fill_bank_valid_q || bank1_owned)
            fail("allocator-adjacent probe missed the pre-allocation edge");

        score_active = 1'b1;
        score_seen = 0;
        score_base = 6;
        score_count = 3;
        score_pass = 0;
        score_epoch = 8'h35;
        pass_base_k = 0;
        fill_k_pass = 0;
        fill_tile_index = 1;
        fill_pixel_base = 6;
        fill_num_pixels = 3;
        fill_req = 1'b1;
        #1;
        if (!fill_req_ready || dut.next_tile_base_q != 6 ||
            dut.next_tile_count_math != 3)
            fail("tail request was not ready against the exact next descriptor");
        @(posedge clk);
        #1;
        if (!fill_req_accept || !fill_req_pending ||
            dut.req_future_known_q !== 1'b0 || !bank1_owned ||
            bank1_tile_index != 1 || bank1_pixel_base != 6 ||
            bank1_pixel_count != 3)
            fail("request WAIT and tail allocation were not atomic neighbors");
        else
            pass("same-edge short-tail allocation became the request owner");
        @(negedge clk);
        fill_req = 1'b0;

        fill_custom_tile_checked(1, 8'h35, 3, 3, 2, 1, 1);
        wait (packet_done);
        @(negedge clk);
        if (score_seen != 3 || completed_packets != 1 ||
            completed_pixels != 3 || order_error || ownership_error ||
            overflow_error)
            fail("allocator-adjacent tail request did not replay its exact range");
        else
            pass("tail future snapshot replayed exactly three vectors");
        score_active = 1'b0;
        release_tile(8'h35, 0);
        release_tile(8'h35, 1);
        random_ready_enable = 1'b1;

        // Strict module-level edge case: while tile1 is allocated, accept a
        // request for tile2, which is the descriptor that becomes "next" only
        // after this same edge.  The first registered WAIT classification must
        // observe the post-allocation descriptor and keep the request pending.
        @(negedge clk);
        rst = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        apply_custom_config(8'h36, 3, 3, 1, ROWS);
        phase = 16;
        drive_entry(8'h36, 0, 0, 0);
        drive_entry(8'h36, 1, 0, 0);
        drive_entry(8'h36, 2, 0, 0);
        if (!dut.wr_commit_valid_q || dut.fill_bank_valid_q || bank1_owned ||
            dut.next_tile_q != 1 || dut.next_tile_base_q != 3)
            fail("post-allocation future probe missed tile1 allocation edge");
        pass_base_k = 0;
        fill_k_pass = 0;
        fill_tile_index = 2;
        fill_pixel_base = 6;
        fill_num_pixels = 3;
        fill_req = 1'b1;
        #1;
        if (!fill_req_ready || !dut.next_alloc_fire)
            fail("post-allocation future probe missed the shared accept edge");
        @(posedge clk);
        #1;
        if (!fill_req_accept || !fill_req_pending ||
            dut.req_future_known_q !== 1'b0 || !bank1_owned ||
            bank1_tile_index != 1 || dut.next_tile_q != 2 ||
            dut.next_tile_base_q != 6 || dut.next_tile_end_q != 9)
            fail("allocator did not publish the prospective next descriptor");
        @(negedge clk);
        fill_req = 1'b0;
        @(posedge clk);
        #1;
        if (!fill_req_pending || dut.req_future_known_q !== 1'b1 ||
            dut.req_future_match_q !== 1'b1 || order_error || replay_active)
            fail("post-allocation next descriptor was not classified in WAIT");
        else
            pass("WAIT classified the descriptor after same-edge allocation");

        @(negedge clk);
        rst = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // With two exactly full tiles, the first allocation is non-final and
        // remaining==tile_pixels makes the second allocation final.  This is
        // the equality edge of the allocator comparison.
        apply_custom_config(7, 3, 4, 2, 6);
        if (!configured || dut.fill_tile_is_layer_last_q !== 1'b0 ||
            bank0_pixel_count != 6)
            fail("first exact-full tile was incorrectly marked final");
        else
            pass("first exact-full tile registered non-final");
        fill_custom_tile_checked(0, 7, 3, 4, 2, 2, 0);
        wait (dut.fill_bank_valid_q && dut.fill_bank_q &&
              bank1_tile_index == 1);
        if (dut.fill_tile_is_layer_last_q !== 1'b1 ||
            bank1_pixel_count != 6)
            fail("remaining==tile_pixels did not register final tile");
        else
            pass("remaining==tile_pixels registered the final full tile");
        fill_custom_tile_checked(1, 7, 3, 4, 2, 2, 1);
        if (!bank1_fill_complete || !materialize_done ||
            order_error || tag_error || ownership_error || overflow_error)
            fail("two exact-full tiles did not complete cleanly");
        else
            pass("two exact-full tiles completed with exact final-bit state");

        @(negedge clk);
        rst = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        apply_config(3, TILE_H);
        phase = 2;
        if (!configured || config_error || overflow_error)
            fail("legal three-tile layer configuration was rejected");
        else if (dut.fill_tile_is_layer_last_q !== 1'b0)
            fail("three-tile layer marked its first tile final");
        else
            pass("three-tile short-tail layer started non-final");

        fill_tile(0, 3);
        phase = 3;
        if (!bank0_owned || !bank0_fill_complete ||
            bank0_tile_index != 0 || bank0_pixel_base != 0 ||
            bank0_pixel_count != 6 ||
            bank0_pass_ready_bitmap != ready_prefix(2))
            fail("tile0 bank ownership or pass-ready metadata mismatch");
        else
            pass("tile0 ownership and per-pass readiness recorded");

        // Replay tile0 while tile1 is accepted into the other bank.
        fork
            replay_packet(3, 0, 0, 6, 0);
            fill_tile(1, 3);
        join
        phase = 4;
        if (!overlap_seen_q)
            fail("tile0 replay never overlapped tile1 materialization");
        else
            pass("tile replay overlapped next-tile materialization");
        if (!bank1_owned || !bank1_fill_complete ||
            bank1_tile_index != 1 || bank1_pixel_base != 6 ||
            bank1_pixel_count != 6 ||
            bank1_pass_ready_bitmap != ready_prefix(2))
            fail("tile1 bank metadata mismatch");
        else
            pass("tile1 completed in the inactive bank");

        // Same pass is intentionally replayed twice, modelling a second
        // COUT block.  No release occurs between these requests.
        replay_packet(3, 0, 0, 6, 0);
        phase = 5;
        if (!bank0_owned || bank0_tile_index != 0)
            fail("bank ownership was lost between COUT replays");
        else
            pass("same pass can be replayed for a second COUT block");

        // Present tile2 while both banks remain owned.  It must stall until
        // tile0 receives a real release handshake, then reuse bank0.
        fork
            begin
                tile2_driver_started_q = 1'b1;
                fill_tile(2, 3);
            end
            begin
                // Capture a replay for the not-yet-allocated future owner
                // while both banks are occupied.  Releasing tile0 must remain
                // possible; after allocation the request waits for pass0's
                // physical commit, then launches without stale data.
                replay_packet(3, 2, 12, 3, 0);
            end
            begin
                wait (tile2_driver_started_q && entry_valid);
                repeat (8) @(posedge clk);
                if (entry_ready)
                    fail("tile2 entered a bank before tile0 release");
                if (!bank0_owned || bank0_tile_index != 0 ||
                    !bank1_owned || bank1_tile_index != 1)
                    fail("owned bank metadata changed before release");
                else
                    pass("both owned banks block premature tile reuse");
                release_tile(3, 0);
            end
        join
        phase = 6;
        @(posedge clk);
        @(negedge clk);
        if (!bank0_owned || !bank0_fill_complete ||
            bank0_tile_index != 2 || bank0_pixel_base != 12 ||
            bank0_pixel_count != 3)
            fail("released bank was not safely reused for tail tile");
        else
            pass("release handshake enabled safe bank reuse by tile2");
        if (!layer_done_seen_q)
            fail("layer materialization completion was not observed");
        else
            pass("final layer entry generated materialize_done");
        if (ownership_stall_cycles < 8)
            fail("ownership stall counter missed the full-bank wait");
        else
            pass("ownership stall cycles counted blocked materialization");

        replay_packet(3, 1, 6, 6, 1);
        phase = 7;
        phase = 8;
        release_tile(3, 1);
        phase = 9;
        release_tile(3, 2);
        phase = 10;
        if (completed_packets != 4 || completed_pixels != 21)
            fail("main-layer replay telemetry mismatch");
        else
            pass("packet and pixel completion telemetry is exact");
        if (order_error || tag_error || ownership_error || overflow_error)
            fail("positive three-tile run raised a sticky error");
        else
            pass("positive three-tile run remained error-free");
        if (vector_backpressure_stall_cycles == 0)
            fail("random output backpressure was not exercised");
        else
            pass("random backpressure exercised the stable output skid");

        // Reconfigure without clearing RAM.  A deliberately stale entry is
        // accepted then discarded.  Hold a request for future pass 1 before
        // either pass is ready: pass 0 becoming ready must not launch it, and
        // every byte released after pass 1 commits must carry the new epoch.
        apply_config(4, TILE_H);
        phase = 11;
        drive_entry(3, 0, 0, 0);
        if (!tag_error || tag_error_count != 1 || stored_entries != 0)
            fail("stale materializer entry was not rejected by epoch tag");
        else
            pass("stale materializer epoch was rejected without advancing");

        fork
            begin
                replay_packet(4, 0, 0, 6, 1);
            end
            begin
                wait (fill_req_pending);
                repeat (7) begin
                    @(posedge clk);
                    if (vector_valid)
                        fail("stale RAM data escaped before new pass-ready");
                end
                fork
                    fill_tile(0, 4);
                    begin
                        wait (bank0_pass_ready_bitmap[0]);
                        if (bank0_pass_ready_bitmap != ready_prefix(1) ||
                            !fill_req_pending || replay_active || vector_valid)
                            fail("future-pass request launched at pass-0 watermark");
                        else
                            pass("future-pass request waited beyond pass-0 watermark");
                    end
                join
            end
        join
        if (context_gap_cycles == 0)
            fail("held request wait was not reflected in context-gap telemetry");
        else
            pass("held request wait counted context-gap cycles");
        if (order_error || ownership_error || overflow_error ||
            tag_error_count != 1)
            fail("epoch replacement produced an unexpected diagnostic");
        else
            pass("new epoch replay suppressed every stale cache location");

        // cfg_start must not provide a back door around explicit release.
        apply_config(5, TILE_H);
        phase = 12;
        if (!configured || !ownership_error ||
            ownership_error_count != 1 || bank0_epoch != 4)
            fail("new configuration reused an owned bank without release");
        else
            pass("owned banks reject implicit reuse by a new epoch");

        // Exercise the release-width endpoint directly.  One pixel across
        // 512 passes fills exactly one bank, so the 10-bit watermark must
        // reach 512 without wrapping and pass 511 must remain replayable.
        @(negedge clk);
        rst = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        apply_custom_config(6, 1, 1, 1, ROWS * MAX_PASSES);
        phase = 13;
        if (!configured || config_error || overflow_error)
            fail("exact 512-pass bank configuration was rejected");
        else
            pass("exact 512-pass bank configuration was accepted");
        for (high_pass = 0; high_pass < MAX_PASSES;
             high_pass = high_pass + 1)
            drive_entry(6, 0, high_pass,
                        high_pass == MAX_PASSES-1);
        retire_pending_write();
        if (dut.bank_ready_count_q[0] != MAX_PASSES ||
            bank0_pass_ready_bitmap != {MAX_PASSES{1'b1}} ||
            !bank0_fill_complete)
            fail("512-pass watermark wrapped or lost its final prefix bit");
        else
            pass("512-pass watermark reached the non-wrapping terminal value");
        replay_packet(6, 0, 0, 1, MAX_PASSES-1);
        if (completed_packets != 1 || completed_pixels != 1)
            fail("pass-511 replay telemetry did not retire exactly once");
        else
            pass("pass 511 remained addressable and replayable");
        release_tile(6, 0);

        wait (prevalidated_probe_done);
        if (prevalidated_probe_failed)
            fail("prevalidated explicit k-pass probe failed");
        else
            pass("prevalidated explicit k-pass accepts aligned and rejects mismatched base");

        wait (epoch_pipe_probe_done);
        if (epoch_pipe_probe_failed)
            fail("bank-local return/output pipeline probe failed");
        else
            pass("bank-local return/output pipeline preserved exact elastic semantics");

        if (fail_count == 0)
            $display("[PASS] hwc materialized tile ping-pong cache: %0d checks", pass_count_score);
        else
            $display("[FAIL] hwc materialized tile ping-pong cache: %0d failures", fail_count);
        $finish;
    end

    initial begin
        timeout_count = 0;
        while (timeout_count < 20000) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
        end
        $display("[FAIL] timeout phase=%0d cfg=%0b fill_valid=%0b entry_ready=%0b req_pending=%0b replay=%0b rd_valid=%0b rd_bank=%0b release=%0b/%0b/%0d bank0=%0b/%0b/%0d bank1=%0b/%0b/%0d",
                 phase, configured, dut.fill_bank_valid_q, entry_ready,
                 fill_req_pending, replay_active, dut.rd_valid_q,
                 dut.rd_bank_q, release_valid, release_ready,
                 release_tile_index, bank0_owned, bank0_fill_complete,
                 bank0_tile_index, bank1_owned, bank1_fill_complete,
                 bank1_tile_index);
        $finish;
    end
endmodule

// Directed read-pipeline probe.  It isolates the synchronous RAM return from
// the bank-local fabric output register and proves the two parent valid slots
// keep their exact credit, completion, release, and reset semantics.
module cache_epoch_pipe_probe (
    input  wire clk,
    output reg  done,
    output reg  failed
);
    localparam integer ROWS = 4;
    localparam integer EPOCH_W = 8;
    localparam integer TILE_W = 4;
    localparam integer PASS_W = 16;
    localparam integer PIXEL_W = 32;
    localparam integer BANK_AW = 4;
    localparam integer BANK_DEPTH = 16;

    reg rst;
    reg cfg_start;
    reg [EPOCH_W-1:0] cfg_epoch;
    reg entry_valid;
    wire entry_ready;
    reg [ROWS*8-1:0] entry_data;
    reg [ROWS-1:0] entry_lane_valid;
    reg [PIXEL_W-1:0] entry_pixel;
    reg [PASS_W-1:0] entry_k_pass;
    reg [EPOCH_W-1:0] entry_epoch;
    reg entry_last;
    reg fill_req;
    wire fill_req_ready;
    wire fill_req_accept;
    reg [15:0] pass_base_k;
    reg [PASS_W-1:0] fill_k_pass;
    reg [TILE_W-1:0] fill_tile_index;
    reg [PIXEL_W-1:0] fill_pixel_base;
    reg [PIXEL_W-1:0] fill_num_pixels;
    wire [ROWS*8-1:0] vector_data;
    wire [ROWS-1:0] vector_lane_valid;
    wire vector_valid;
    reg vector_ready;
    wire vector_last;
    wire packet_done;
    reg release_valid;
    wire release_ready;
    reg [EPOCH_W-1:0] release_epoch;
    reg [TILE_W-1:0] release_tile_index;
    wire configured;
    wire materialize_done;
    wire replay_active;
    wire bank0_owned;
    wire bank0_fill_complete;
    wire bank1_owned;
    wire bank1_fill_complete;
    wire ownership_error;
    wire [31:0] ownership_error_count;
    wire [31:0] completed_packets;
    wire [31:0] completed_pixels;

    integer pixel_i;
    integer drain_i;
    integer watchdog;
    integer probe_checks;
    time prior_fire_time;
    reg [ROWS*8-1:0] held_out_data;
    reg [ROWS*8-1:0] held_return_data;
    reg [PIXEL_W-1:0] held_return_pixel;
    reg [ROWS*8-1:0] bank1_payload_before_reset;
    reg [31:0] ownership_errors_before;

    function [ROWS*8-1:0] probe_vector;
        input integer pixel_value;
        begin
            probe_vector = {ROWS*8{1'b0}};
            probe_vector[7:0] = pixel_value;
            probe_vector[15:8] = pixel_value + 8'h20;
            probe_vector[23:16] = pixel_value + 8'h40;
            probe_vector[31:24] = pixel_value + 8'h60;
        end
    endfunction

    task probe_fail;
        input [8*120-1:0] message;
        begin
            $display("[FAIL] epoch-pipe: %0s", message);
            failed = 1'b1;
        end
    endtask

    task probe_pass;
        input [8*120-1:0] message;
        begin
            $display("[PASS] epoch-pipe: %0s", message);
            probe_checks = probe_checks + 1;
        end
    endtask

    task send_probe_entry;
        input integer pixel_value;
        input integer last_value;
        begin
            @(negedge clk);
            entry_valid = 1'b1;
            entry_data = probe_vector(pixel_value);
            entry_lane_valid = {ROWS{1'b1}};
            entry_pixel = pixel_value;
            entry_k_pass = {PASS_W{1'b0}};
            entry_epoch = cfg_epoch;
            entry_last = last_value[0:0];
            while (!entry_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            entry_valid = 1'b0;
        end
    endtask

    task launch_probe_replay;
        input integer tile_value;
        input integer base_value;
        begin
            @(negedge clk);
            pass_base_k = 16'd0;
            fill_k_pass = {PASS_W{1'b0}};
            fill_tile_index = tile_value[TILE_W-1:0];
            fill_pixel_base = base_value;
            fill_num_pixels = 4;
            fill_req = 1'b1;
            while (!fill_req_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            if (!fill_req_accept)
                probe_fail("replay request was not accepted on its ready edge");
            fill_req = 1'b0;
        end
    endtask

    hwc_materialized_tile_pingpong_cache #(
        .ROWS(ROWS), .EPOCH_W(EPOCH_W), .TILE_W(TILE_W),
        .PASS_W(PASS_W), .PIXEL_W(PIXEL_W), .MAX_PASSES(4),
        .BANK_AW(BANK_AW), .BANK_DEPTH(BANK_DEPTH)
    ) dut (
        .clk(clk), .rst(rst),
        .cfg_start(cfg_start), .cfg_epoch(cfg_epoch),
        .cfg_ofm_w(16'd4), .cfg_ofm_h(16'd2),
        .cfg_tile_h_max(16'd1), .cfg_k_total(16'd4),
        .cfg_prevalidated_layer_pixels({PIXEL_W{1'b0}}),
        .cfg_prevalidated_tile_pixels({PIXEL_W{1'b0}}),
        .cfg_prevalidated_pass_count({PASS_W{1'b0}}),
        .cfg_prevalidated_final_pass({PASS_W{1'b0}}),
        .cfg_prevalidated_final_lane_mask({ROWS{1'b0}}),
        .entry_valid(entry_valid), .entry_ready(entry_ready),
        .entry_data(entry_data), .entry_lane_valid(entry_lane_valid),
        .entry_pixel(entry_pixel), .entry_k_pass(entry_k_pass),
        .entry_epoch(entry_epoch), .entry_last(entry_last),
        .fill_req(fill_req), .fill_req_ready(fill_req_ready),
        .fill_req_accept(fill_req_accept), .pass_base_k(pass_base_k),
        .fill_k_pass(fill_k_pass), .fill_tile_index(fill_tile_index),
        .fill_pixel_base(fill_pixel_base),
        .fill_num_pixels(fill_num_pixels),
        .vector_data(vector_data),
        .vector_lane_valid(vector_lane_valid),
        .vector_valid(vector_valid), .vector_ready(vector_ready),
        .vector_last(vector_last), .packet_done(packet_done),
        .release_valid(release_valid), .release_ready(release_ready),
        .release_epoch(release_epoch),
        .release_tile_index(release_tile_index),
        .configured(configured), .materialize_done(materialize_done),
        .replay_active(replay_active),
        .bank0_owned(bank0_owned),
        .bank0_fill_complete(bank0_fill_complete),
        .bank1_owned(bank1_owned),
        .bank1_fill_complete(bank1_fill_complete),
        .ownership_error(ownership_error),
        .ownership_error_count(ownership_error_count),
        .completed_packets(completed_packets),
        .completed_pixels(completed_pixels)
    );

    initial begin
        rst = 1'b1;
        cfg_start = 1'b0;
        cfg_epoch = 8'h71;
        entry_valid = 1'b0;
        entry_data = {ROWS*8{1'b0}};
        entry_lane_valid = {ROWS{1'b0}};
        entry_pixel = {PIXEL_W{1'b0}};
        entry_k_pass = {PASS_W{1'b0}};
        entry_epoch = {EPOCH_W{1'b0}};
        entry_last = 1'b0;
        fill_req = 1'b0;
        pass_base_k = 16'd0;
        fill_k_pass = {PASS_W{1'b0}};
        fill_tile_index = {TILE_W{1'b0}};
        fill_pixel_base = {PIXEL_W{1'b0}};
        fill_num_pixels = {PIXEL_W{1'b0}};
        vector_ready = 1'b0;
        release_valid = 1'b0;
        release_epoch = {EPOCH_W{1'b0}};
        release_tile_index = {TILE_W{1'b0}};
        done = 1'b0;
        failed = 1'b0;
        probe_checks = 0;
        prior_fire_time = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        cfg_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        cfg_start = 1'b0;
        @(posedge clk);
        @(negedge clk);
        if (!configured)
            probe_fail("legal two-bank configuration did not commit");

        for (pixel_i = 0; pixel_i < 8; pixel_i = pixel_i + 1)
            send_probe_entry(pixel_i, pixel_i == 7);
        wait (bank0_fill_complete && bank1_fill_complete);
        @(negedge clk);
        if (!bank0_owned || !bank1_owned || !materialize_done)
            probe_fail("two directed tiles did not complete in separate banks");
        else
            probe_pass("bank0 and bank1 fills completed before replay");

        // Bank0: the first URAM return must spend exactly one additional
        // cycle in the bank-local fabric register before vector_valid rises.
        launch_probe_replay(0, 0);
        wait (replay_active);
        wait (dut.rd_valid_q);
        @(negedge clk);
        if (dut.rd_bank_q || dut.out_valid_q || vector_valid)
            probe_fail("first return bypassed the added bank-local stage");
        else
            probe_pass("first return added exactly one registered stage");
        ownership_errors_before = ownership_error_count;
        cfg_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        cfg_start = 1'b0;
        if (!dut.rd_valid_q || !dut.out_valid_q || !vector_valid ||
            dut.out_bank_q || vector_data !== probe_vector(0) ||
            ownership_error_count != ownership_errors_before + 1)
            probe_fail("return/output slots did not fill together for bank0");
        else
            probe_pass("busy cfg preserved return transfer and next issue");

        // A busy configuration request is rejected without consuming either
        // occupied slot.  Release must remain blocked while return/output
        // state for its bank is live.
        release_epoch = cfg_epoch;
        release_tile_index = {TILE_W{1'b0}};
        release_valid = 1'b1;
        ownership_errors_before = ownership_error_count;
        cfg_start = 1'b1;
        held_out_data = vector_data;
        held_return_data = dut.u_bank0.ram_rd_data_q;
        held_return_pixel = dut.rd_expected_pixel_q;
        @(posedge clk);
        @(negedge clk);
        cfg_start = 1'b0;
        if (!ownership_error ||
            ownership_error_count != ownership_errors_before + 1 ||
            !dut.rd_valid_q || !dut.out_valid_q || release_ready)
            probe_fail("busy cfg/release did not preserve both occupied slots");
        repeat (8) begin
            @(posedge clk);
            @(negedge clk);
            if (!dut.rd_valid_q || !dut.out_valid_q || release_ready ||
                vector_data !== held_out_data ||
                dut.u_bank0.ram_rd_data_q !== held_return_data ||
                dut.rd_expected_pixel_q !== held_return_pixel)
                probe_fail("long backpressure changed a full return/output pair");
        end
        probe_pass("long backpressure held both slots and blocked release");

        // Pop three vectors.  Every edge simultaneously pops output,
        // transfers return, and issues the next read, so no bubble is legal.
        ownership_errors_before = ownership_error_count;
        cfg_start = 1'b1;
        vector_ready = 1'b1;
        for (drain_i = 0; drain_i < 3; drain_i = drain_i + 1) begin
            if (!vector_valid || vector_data !== probe_vector(drain_i) ||
                vector_lane_valid !== {ROWS{1'b1}} || vector_last)
                probe_fail("gapless drain exposed wrong bank0 payload/metadata");
            @(posedge clk);
            if ((drain_i != 0) && ($time != prior_fire_time + 10))
                probe_fail("gapless drain inserted a throughput bubble");
            prior_fire_time = $time;
            @(negedge clk);
            if (drain_i == 0) begin
                cfg_start = 1'b0;
                if (ownership_error_count != ownership_errors_before + 1 ||
                    completed_pixels != 1)
                    probe_fail("busy cfg swallowed a visible replay handshake");
            end
        end
        vector_ready = 1'b0;
        if (!vector_valid || !vector_last ||
            vector_data !== probe_vector(3) || packet_done ||
            !replay_active || dut.rd_valid_q || !dut.out_valid_q ||
            completed_pixels != 3 || completed_packets != 0 || release_ready)
            probe_fail("final vector did not wait exclusively in output slot");
        else
            probe_pass("steady replay sustained one vector per clock");

        held_out_data = vector_data;
        repeat (5) begin
            @(posedge clk);
            @(negedge clk);
            if (!vector_valid || !vector_last || packet_done ||
                !replay_active || release_ready ||
                vector_data !== held_out_data || completed_pixels != 3)
                probe_fail("final completion occurred without a real pop");
        end
        probe_pass("final done and release stayed blocked until real pop");

        vector_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (!packet_done || replay_active || vector_valid ||
            completed_pixels != 4 || completed_packets != 1 ||
            !release_ready)
            probe_fail("final real pop did not retire packet atomically");
        else
            probe_pass("final real pop alone retired packet and opened release");

        // With the pipeline now empty, a busy cfg pulse must suppress the
        // externally advertised release handshake.  Ownership is retained,
        // then the still-held release retires exactly once after cfg drops.
        ownership_errors_before = ownership_error_count;
        cfg_start = 1'b1;
        #1;
        if (release_ready)
            probe_fail("busy cfg advertised a release it could not retire");
        @(posedge clk);
        @(negedge clk);
        cfg_start = 1'b0;
        #1;
        if (!bank0_owned || !release_ready ||
            ownership_error_count != ownership_errors_before + 1 ||
            completed_packets != 1 || completed_pixels != 4)
            probe_fail("busy cfg consumed or perturbed the held release");
        @(posedge clk);
        @(negedge clk);
        release_valid = 1'b0;
        if (bank0_owned || release_ready || completed_packets != 1)
            probe_fail("bank0 release did not retire exactly once after retry");
        else
            probe_pass("busy cfg deferred release until one real handshake");

        // Bank1 uses the same two stages without crossing the bank mux.  Hit
        // reset with both valids asserted and prove only valid/control clears;
        // the wide bank-local payload register deliberately retains its bits.
        vector_ready = 1'b0;
        launch_probe_replay(1, 4);
        wait (dut.rd_valid_q);
        @(negedge clk);
        if (!dut.rd_bank_q || dut.out_valid_q)
            probe_fail("bank1 return did not occupy the return-only phase");
        @(posedge clk);
        @(negedge clk);
        if (!dut.rd_valid_q || !dut.out_valid_q || !dut.out_bank_q ||
            vector_data !== probe_vector(4))
            probe_fail("bank1 return crossed the wrong bank-local output FF");
        else
            probe_pass("bank0/bank1 replay alternated without mux contamination");
        release_epoch = cfg_epoch;
        release_tile_index = {{(TILE_W-1){1'b0}}, 1'b1};
        release_valid = 1'b1;
        if (release_ready)
            probe_fail("bank1 release opened while return/output were occupied");
        bank1_payload_before_reset = dut.u_bank1.rd_data;
        rst = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (dut.rd_valid_q || dut.out_valid_q || vector_valid ||
            replay_active || packet_done || configured ||
            bank0_owned || bank1_owned || release_ready)
            probe_fail("reset retained return/output control state");
        if (dut.u_bank1.rd_data !== bank1_payload_before_reset)
            probe_fail("reset unexpectedly touched wide bank-local payload");
        else
            probe_pass("reset cleared both valids without resetting payload");
        rst = 1'b0;
        release_valid = 1'b0;

        if (!failed)
            $display("[PASS] epoch-pipe directed probe: %0d checks",
                     probe_checks);
        done = 1'b1;
    end

    initial begin
        watchdog = 0;
        while (!done && watchdog < 1000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        if (!done) begin
            $display("[FAIL] epoch-pipe timeout replay=%0b ret=%0b out=%0b ready=%0b release=%0b/%0b",
                     replay_active, dut.rd_valid_q, dut.out_valid_q,
                     vector_ready, release_valid, release_ready);
            failed = 1'b1;
            done = 1'b1;
        end
    end
endmodule

// Short release-mode probe.  The main DUT above preserves the standalone
// divider/modulo validation path; this companion instance selects
// CFG_PREVALIDATED=1 and proves that the explicit feeder k-pass is used while
// a mismatched pass_base still fails closed.
module cache_prevalidated_pass_probe (
    input  wire clk,
    output reg  done,
    output reg  failed
);
    localparam integer ROWS = 18;
    localparam integer PASS_W = 16;
    localparam integer PIXEL_W = 32;
    localparam integer TILE_W = 4;
    localparam integer EPOCH_W = 8;

    reg rst;
    reg cfg_start;
    reg [EPOCH_W-1:0] cfg_epoch;
    reg entry_valid;
    wire entry_ready;
    reg [ROWS*8-1:0] entry_data;
    reg [ROWS-1:0] entry_lane_valid;
    reg [PIXEL_W-1:0] entry_pixel;
    reg [PASS_W-1:0] entry_k_pass;
    reg [EPOCH_W-1:0] entry_epoch;
    reg entry_last;
    reg fill_req;
    wire fill_req_ready;
    wire fill_req_accept;
    reg [15:0] pass_base_k;
    reg [PASS_W-1:0] fill_k_pass;
    wire [ROWS*8-1:0] vector_data;
    wire vector_valid;
    wire packet_done;
    wire bank0_fill_complete;
    wire order_error;
    wire [31:0] order_error_count;
    integer watchdog;

    hwc_materialized_tile_pingpong_cache #(
        .ROWS(ROWS), .EPOCH_W(EPOCH_W), .TILE_W(TILE_W),
        .PASS_W(PASS_W), .PIXEL_W(PIXEL_W), .MAX_PASSES(8),
        .BANK_AW(5), .BANK_DEPTH(32), .CFG_PREVALIDATED(1),
        .ENABLE_PASS_READY_BITMAP(0)
    ) dut (
        .clk(clk), .rst(rst),
        .cfg_start(cfg_start), .cfg_epoch(cfg_epoch),
        .cfg_ofm_w(16'd1), .cfg_ofm_h(16'd1),
        .cfg_tile_h_max(16'd1), .cfg_k_total(16'd36),
        .cfg_prevalidated_layer_pixels(32'd1),
        .cfg_prevalidated_tile_pixels(32'd1),
        .cfg_prevalidated_pass_count(16'd2),
        .cfg_prevalidated_final_pass(16'd1),
        .cfg_prevalidated_final_lane_mask({ROWS{1'b1}}),
        .entry_valid(entry_valid), .entry_ready(entry_ready),
        .entry_data(entry_data), .entry_lane_valid(entry_lane_valid),
        .entry_pixel(entry_pixel), .entry_k_pass(entry_k_pass),
        .entry_epoch(entry_epoch), .entry_last(entry_last),
        .fill_req(fill_req), .fill_req_ready(fill_req_ready),
        .fill_req_accept(fill_req_accept), .pass_base_k(pass_base_k),
        .fill_k_pass(fill_k_pass), .fill_tile_index({TILE_W{1'b0}}),
        .fill_pixel_base({PIXEL_W{1'b0}}),
        .fill_num_pixels({{(PIXEL_W-1){1'b0}}, 1'b1}),
        .vector_data(vector_data), .vector_valid(vector_valid),
        .vector_ready(1'b1), .packet_done(packet_done),
        .release_valid(1'b0), .release_epoch({EPOCH_W{1'b0}}),
        .release_tile_index({TILE_W{1'b0}}),
        .bank0_fill_complete(bank0_fill_complete),
        .order_error(order_error), .order_error_count(order_error_count)
    );

    task send_entry;
        input [PASS_W-1:0] pass_i;
        input [7:0] byte_i;
        input last_i;
        begin
            @(negedge clk);
            entry_data = {ROWS{byte_i}};
            entry_lane_valid = {ROWS{1'b1}};
            entry_pixel = {PIXEL_W{1'b0}};
            entry_k_pass = pass_i;
            entry_epoch = cfg_epoch;
            entry_last = last_i;
            entry_valid = 1'b1;
            while (!entry_ready)
                @(negedge clk);
            @(negedge clk);
            entry_valid = 1'b0;
        end
    endtask

    initial begin
        rst = 1'b1;
        cfg_start = 1'b0;
        cfg_epoch = 8'h5a;
        entry_valid = 1'b0;
        entry_data = {ROWS*8{1'b0}};
        entry_lane_valid = {ROWS{1'b0}};
        entry_pixel = {PIXEL_W{1'b0}};
        entry_k_pass = {PASS_W{1'b0}};
        entry_epoch = {EPOCH_W{1'b0}};
        entry_last = 1'b0;
        fill_req = 1'b0;
        pass_base_k = 16'd0;
        fill_k_pass = {PASS_W{1'b0}};
        done = 1'b0;
        failed = 1'b0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        cfg_start = 1'b1;
        @(negedge clk);
        cfg_start = 1'b0;

        send_entry(16'd0, 8'h31, 1'b0);
        send_entry(16'd1, 8'ha7, 1'b1);
        wait (bank0_fill_complete);

        @(negedge clk);
        pass_base_k = 16'd18;
        fill_k_pass = 16'd1;
        fill_req = 1'b1;
        wait (fill_req_accept);
        @(negedge clk);
        fill_req = 1'b0;
        wait (vector_valid);
        // Sample after the synchronous RAM response and cache metadata have
        // both settled from the issuing edge.
        @(negedge clk);
        if (vector_data !== {ROWS{8'ha7}}) begin
            $display("[FAIL] prevalidated probe replay data=%h expected=%h",
                     vector_data, {ROWS{8'ha7}});
            failed = 1'b1;
        end
        wait (packet_done);

        repeat (2) @(negedge clk);
        pass_base_k = 16'd0;
        fill_k_pass = 16'd1;
        fill_req = 1'b1;
        wait (fill_req_accept);
        @(negedge clk);
        fill_req = 1'b0;
        repeat (2) @(posedge clk);
        if (!order_error || order_error_count != 1) begin
            $display("[FAIL] prevalidated probe mismatch status order=%0b count=%0d pending=%0b ready=%0b",
                     order_error, order_error_count,
                     dut.req_pending_q, fill_req_ready);
            failed = 1'b1;
        end
        done = 1'b1;
    end

    initial begin
        watchdog = 0;
        while (!done && watchdog < 500) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        if (!done) begin
            $display("[FAIL] prevalidated probe timeout entry_ready=%0b complete=%0b fill=%0b/%0b vector=%0b packet=%0b order=%0b/%0d",
                     entry_ready, bank0_fill_complete, fill_req,
                     fill_req_accept, vector_valid, packet_done,
                     order_error, order_error_count);
            failed = 1'b1;
            done = 1'b1;
        end
    end
endmodule

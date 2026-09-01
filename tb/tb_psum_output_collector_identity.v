`timescale 1ns / 1ps

module tb_psum_output_collector_identity;
    localparam COLS = 2;
    localparam PSUM_W = 32;
    localparam EPOCH_W = 8;
    localparam CONTEXT_W = 16;
    localparam TAG_W = EPOCH_W + 2;
    localparam DATA_W = COLS*2*PSUM_W;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg enable = 1'b1;
    reg ctx_valid = 1'b0;
    wire ctx_ready;
    reg [15:0] ctx_num_pixels = 16'd0;
    reg ctx_is_final = 1'b0;
    reg ctx_wr_bank = 1'b0;
    reg [10:0] ctx_cout_base = 11'd0;
    reg [10:0] ctx_cout_valid = 11'd0;
    reg ctx_trace_match = 1'b0;
    reg [EPOCH_W-1:0] ctx_epoch = {EPOCH_W{1'b0}};
    reg ctx_ifm_bank = 1'b0;
    reg [CONTEXT_W-1:0] ctx_context_id = {CONTEXT_W{1'b0}};
    reg [EPOCH_W-1:0] ctx_parent_epoch = {EPOCH_W{1'b0}};
    reg [CONTEXT_W-1:0] ctx_parent_context_id = {CONTEXT_W{1'b0}};
    reg ctx_first = 1'b0;

    wire [31:0] rd_en;
    reg [DATA_W-1:0] rd_data = {DATA_W{1'b0}};
    reg [COLS*TAG_W-1:0] rd_tag = {COLS*TAG_W{1'b0}};
    reg [31:0] empty = 32'hffff_fffc;

    wire packet_valid;
    reg packet_ready = 1'b1;
    wire [3:0] packet_addr;
    wire [DATA_W-1:0] packet_data;
    wire packet_is_final;
    wire packet_wr_bank;
    wire [10:0] packet_cout_base;
    wire [10:0] packet_cout_valid;
    wire [EPOCH_W-1:0] packet_epoch;
    wire packet_ifm_bank;
    wire [CONTEXT_W-1:0] packet_context_id;
    wire [EPOCH_W-1:0] packet_parent_epoch;
    wire [CONTEXT_W-1:0] packet_parent_context_id;
    wire packet_first;

    wire context_start;
    wire context_done;
    wire partial_done;
    wire final_done;
    wire context_active;
    wire context_wr_bank;
    wire context_is_final;
    wire [EPOCH_W-1:0] context_epoch;
    wire context_ifm_bank;
    wire [CONTEXT_W-1:0] context_id;
    wire [EPOCH_W-1:0] context_parent_epoch;
    wire [CONTEXT_W-1:0] context_parent_context_id;
    wire context_first;
    wire [EPOCH_W-1:0] context_done_epoch;
    wire context_done_ifm_bank;
    wire [CONTEXT_W-1:0] context_done_context_id;
    wire [EPOCH_W-1:0] context_done_parent_epoch;
    wire [CONTEXT_W-1:0] context_done_parent_context_id;
    wire context_done_first;
    wire context_done_final;
    wire context_done_wr_bank;
    wire tag_mismatch_sticky;
    wire [31:0] tag_mismatch_count;
    wire fail_stop;

    integer fail = 0;
    integer packet_count_1 = 0;
    integer packet_count_2 = 0;
    integer done_count = 0;
    integer source_value = 0;
    integer source_read_count = 0;
    integer bad_mode = 0;
    integer bad_read_index = -1;
    integer fault_phase = 0;
    integer fault_packet_count = 0;
    integer fault_done_count = 0;
    integer bad_event_count = 0;
    integer extra_reads_on_bad_edge = 0;
    integer reads_after_bad_edge = 0;
    reg bad_event_seen = 1'b0;
    reg bad_ptr_check_q = 1'b0;
    reg bad_ptr_expected_q = 1'b0;
    reg bad_rd_ptr_expected_q = 1'b0;
    reg bad_count_commit_check_q = 1'b0;
    integer bad_ptr_transition_count = 0;
    integer bad_rd_ptr_transition_count = 0;
    integer bad_count_delay_check_count = 0;
    integer bad_sticky_edge_check_count = 0;
    integer bad_blocked_ptr_count = 0;
    integer col_idx;
    reg [TAG_W-1:0] source_tag;

    psum_output_collector #(
        .COLS(COLS), .PSUM_W(PSUM_W), .ADDR_W(4),
        .CTX_DEPTH(4), .CTX_AW(2), .EPOCH_W(EPOCH_W),
        .CONTEXT_W(CONTEXT_W), .TAG_W(TAG_W),
        .ENABLE_TAG_CHECK(1)
    ) dut (
        .clk(clk), .rst(rst), .enable(enable),
        .ctx_valid(ctx_valid), .ctx_ready(ctx_ready),
        .ctx_num_pixels(ctx_num_pixels), .ctx_is_final(ctx_is_final),
        .ctx_wr_bank(ctx_wr_bank), .ctx_cout_base(ctx_cout_base),
        .ctx_cout_valid(ctx_cout_valid),
        .ctx_trace_match(ctx_trace_match),
        .ctx_epoch(ctx_epoch), .ctx_ifm_bank(ctx_ifm_bank),
        .ctx_context_id(ctx_context_id),
        .ctx_parent_epoch(ctx_parent_epoch),
        .ctx_parent_context_id(ctx_parent_context_id),
        .ctx_first(ctx_first),
        .psum_fifo_rd_en(rd_en), .psum_fifo_rd_data(rd_data),
        .psum_fifo_rd_tag(rd_tag), .psum_fifo_empty(empty),
        .packet_valid(packet_valid), .packet_ready(packet_ready),
        .packet_addr(packet_addr), .packet_data(packet_data),
        .packet_is_final(packet_is_final), .packet_wr_bank(packet_wr_bank),
        .packet_cout_base(packet_cout_base),
        .packet_cout_valid(packet_cout_valid),
        .packet_epoch(packet_epoch), .packet_ifm_bank(packet_ifm_bank),
        .packet_context_id(packet_context_id),
        .packet_parent_epoch(packet_parent_epoch),
        .packet_parent_context_id(packet_parent_context_id),
        .packet_first(packet_first),
        .context_start(context_start), .context_done(context_done),
        .partial_done(partial_done), .final_done(final_done),
        .context_active(context_active),
        .context_wr_bank(context_wr_bank),
        .context_is_final(context_is_final),
        .context_epoch(context_epoch), .context_ifm_bank(context_ifm_bank),
        .context_id(context_id), .context_parent_epoch(context_parent_epoch),
        .context_parent_context_id(context_parent_context_id),
        .context_first(context_first),
        .context_done_epoch(context_done_epoch),
        .context_done_ifm_bank(context_done_ifm_bank),
        .context_done_context_id(context_done_context_id),
        .context_done_parent_epoch(context_done_parent_epoch),
        .context_done_parent_context_id(context_done_parent_context_id),
        .context_done_first(context_done_first),
        .context_done_final(context_done_final),
        .context_done_wr_bank(context_done_wr_bank),
        .trace_context_active(), .trace_context_done(),
        .perf_context_push(), .perf_context_pop(),
        .perf_context_full_stall(), .perf_column_empty_wait(),
        .tag_mismatch_sticky(tag_mismatch_sticky),
        .tag_mismatch_count(tag_mismatch_count),
        .fail_stop(fail_stop)
    );

    always #5 clk = ~clk;

    // Model the one-cycle output-FIFO read latency.  bad_mode=1 returns a
    // column-consistent tag that disagrees with the active descriptor;
    // bad_mode=2 makes column 1 disagree with column 0.
    always @(posedge clk) begin
        if (rst) begin
            rd_data <= {DATA_W{1'b0}};
            rd_tag <= {COLS*TAG_W{1'b0}};
            source_value <= 0;
            source_read_count <= 0;
        end else if (rd_en != 0) begin
            rd_data <= {4{source_value[31:0]}};
            source_value <= source_value + 1;
            source_tag = {
                context_epoch,
                context_ifm_bank,
                (dut.rd_count == dut.pixels_to_collect - 16'd1)
            };
            if (bad_mode == 1 && source_read_count == bad_read_index)
                source_tag = source_tag ^ {{(TAG_W-1){1'b0}}, 1'b1};
            for (col_idx = 0; col_idx < COLS; col_idx = col_idx + 1)
                rd_tag[(col_idx+1)*TAG_W-1 -: TAG_W] <= source_tag;
            if (bad_mode == 2 && source_read_count == bad_read_index)
                rd_tag[2*TAG_W-1 -: TAG_W] <=
                    source_tag ^ {{(TAG_W-1){1'b0}}, 1'b1};
            source_read_count <= source_read_count + 1;
        end
    end

    task push_context;
        input [15:0] pixels;
        input is_final;
        input wr_bank;
        input [10:0] cout_base;
        input [EPOCH_W-1:0] epoch;
        input ifm_bank;
        input [CONTEXT_W-1:0] context_id_in;
        input [EPOCH_W-1:0] parent_epoch;
        input [CONTEXT_W-1:0] parent_context_id;
        input first;
        begin
            @(negedge clk);
            ctx_valid = 1'b1;
            ctx_num_pixels = pixels;
            ctx_is_final = is_final;
            ctx_wr_bank = wr_bank;
            ctx_cout_base = cout_base;
            ctx_cout_valid = 11'd4;
            ctx_trace_match = 1'b1;
            ctx_epoch = epoch;
            ctx_ifm_bank = ifm_bank;
            ctx_context_id = context_id_in;
            ctx_parent_epoch = parent_epoch;
            ctx_parent_context_id = parent_context_id;
            ctx_first = first;
            while (!ctx_ready)
                @(negedge clk);
            @(negedge clk);
            ctx_valid = 1'b0;
        end
    endtask

    task reset_phase;
        begin
            @(negedge clk);
            rst = 1'b1;
            ctx_valid = 1'b0;
            packet_ready = 1'b1;
            bad_mode = 0;
            bad_read_index = -1;
            repeat (3) @(negedge clk);
            if (dut.packet_wr_ptr_q !== 1'b0 ||
                dut.packet_rd_ptr_q !== 1'b0 ||
                dut.packet_count_q !== 2'd0 || dut.return_valid_q ||
                dut.packet_head_addr_q !== 4'd0 || packet_addr !== 4'd0) begin
                $display("[FAIL] reset did not align/empty packet pointers");
                fail = fail + 1;
            end
            rst = 1'b0;
        end
    endtask

    task wait_for_fail_stop;
        integer timeout;
        begin
            timeout = 0;
            while (!fail_stop && timeout < 40) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!fail_stop) begin
                $display("[FAIL] timeout waiting for collector fail-stop");
                fail = fail + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            packet_count_1 <= 0;
            packet_count_2 <= 0;
            done_count <= 0;
            fault_packet_count <= 0;
            fault_done_count <= 0;
            bad_event_count <= 0;
            extra_reads_on_bad_edge <= 0;
            reads_after_bad_edge <= 0;
            bad_event_seen <= 1'b0;
            bad_ptr_check_q <= 1'b0;
            bad_ptr_expected_q <= 1'b0;
            bad_ptr_transition_count <= 0;
            bad_rd_ptr_expected_q <= 1'b0;
            bad_rd_ptr_transition_count <= 0;
            bad_count_delay_check_count <= 0;
            bad_sticky_edge_check_count <= 0;
            bad_blocked_ptr_count <= 0;
        end else begin
            bad_ptr_check_q <= dut.bad_tag_return;
            if (dut.bad_tag_return) begin
                bad_ptr_expected_q <= dut.return_advance ?
                    ~dut.packet_wr_ptr_q : dut.packet_wr_ptr_q;
                bad_rd_ptr_expected_q <= dut.packet_pop ?
                    ~dut.packet_rd_ptr_q : dut.packet_rd_ptr_q;
            end
            if (dut.bad_tag_return) begin
                bad_event_count <= bad_event_count + 1;
                bad_event_seen <= 1'b1;
                if (!dut.return_advance) begin
                    bad_blocked_ptr_count <= bad_blocked_ptr_count + 1;
                    if (dut.packet_count_q != 2 || !dut.return_valid_q) begin
                        $display("[FAIL] blocked bad return was not held behind a full packet queue");
                        fail = fail + 1;
                    end
                end
                if (rd_en != 0)
                    extra_reads_on_bad_edge <=
                        extra_reads_on_bad_edge + 1;
            end else if (bad_event_seen && rd_en != 0) begin
                reads_after_bad_edge <= reads_after_bad_edge + 1;
            end

            if (packet_valid && packet_ready) begin
                if (fault_phase != 0) begin
                    fault_packet_count <= fault_packet_count + 1;
                    if (packet_addr >= bad_read_index ||
                        packet_data[31:0] !== packet_addr) begin
                        $display("[FAIL] fault phase retired bad/late packet addr=%0d data=%0d bad_index=%0d",
                                 packet_addr, packet_data[31:0],
                                 bad_read_index);
                        fail = fail + 1;
                    end
                end else case (packet_context_id)
                    16'h1001: begin
                        packet_count_1 <= packet_count_1 + 1;
                        if (packet_epoch != 8'h21 || packet_ifm_bank != 1'b0 ||
                            packet_parent_epoch != 8'h00 ||
                            packet_parent_context_id != 16'h0000 ||
                            !packet_first || packet_is_final || packet_wr_bank ||
                            packet_cout_base != 11'd0 ||
                            packet_cout_valid != 11'd4) begin
                            $display("[FAIL] packet identity mismatch for context 1001");
                            fail = fail + 1;
                        end
                    end
                    16'h1002: begin
                        packet_count_2 <= packet_count_2 + 1;
                        if (packet_epoch != 8'h22 || packet_ifm_bank != 1'b1 ||
                            packet_parent_epoch != 8'h21 ||
                            packet_parent_context_id != 16'h1001 ||
                            packet_first || !packet_is_final || !packet_wr_bank ||
                            packet_cout_base != 11'd16 ||
                            packet_cout_valid != 11'd4) begin
                            $display("[FAIL] packet identity mismatch for context 1002");
                            fail = fail + 1;
                        end
                    end
                    default: begin
                        $display("[FAIL] unexpected packet context id %h",
                                 packet_context_id);
                        fail = fail + 1;
                    end
                endcase
            end

            if (context_done) begin
                if (fault_phase != 0) begin
                    fault_done_count <= fault_done_count + 1;
                    $display("[FAIL] fault phase completed a context");
                    fail = fail + 1;
                end else begin
                    done_count <= done_count + 1;
                    case (context_done_context_id)
                    16'h1001: begin
                        if (context_done_epoch != 8'h21 ||
                            context_done_ifm_bank != 1'b0 ||
                            context_done_parent_epoch != 8'h00 ||
                            context_done_parent_context_id != 16'h0000 ||
                            !context_done_first || context_done_final ||
                            context_done_wr_bank || !partial_done || final_done) begin
                            $display("[FAIL] done identity mismatch for context 1001");
                            fail = fail + 1;
                        end
                    end
                    16'h1002: begin
                        if (context_done_epoch != 8'h22 ||
                            context_done_ifm_bank != 1'b1 ||
                            context_done_parent_epoch != 8'h21 ||
                            context_done_parent_context_id != 16'h1001 ||
                            context_done_first || !context_done_final ||
                            !context_done_wr_bank || partial_done || !final_done) begin
                            $display("[FAIL] done identity mismatch for context 1002");
                            fail = fail + 1;
                        end
                    end
                    default: begin
                        $display("[FAIL] unexpected done context id %h",
                                 context_done_context_id);
                        fail = fail + 1;
                    end
                    endcase
                end
            end
        end
    end

    always @(negedge clk) begin
        if (rst) begin
            bad_count_commit_check_q = 1'b0;
        end else begin
            if (bad_count_commit_check_q) begin
                bad_count_delay_check_count =
                    bad_count_delay_check_count + 1;
                if (dut.bad_tag_event_q !== 1'b0 ||
                    tag_mismatch_count !== 32'd1) begin
                    $display("[FAIL] delayed bad-tag count did not retire exactly one cycle later event/count=%0d/%0d",
                             dut.bad_tag_event_q, tag_mismatch_count);
                    fail = fail + 1;
                end
                bad_count_commit_check_q = 1'b0;
            end

            if (bad_ptr_check_q) begin
                bad_ptr_transition_count = bad_ptr_transition_count + 1;
                bad_rd_ptr_transition_count =
                    bad_rd_ptr_transition_count + 1;
                bad_sticky_edge_check_count =
                    bad_sticky_edge_check_count + 1;
                if (dut.packet_wr_ptr_q !== bad_ptr_expected_q) begin
                    $display("[FAIL] bad return write-pointer transition got=%0d expected=%0d",
                             dut.packet_wr_ptr_q, bad_ptr_expected_q);
                    fail = fail + 1;
                end
                if (dut.packet_rd_ptr_q !== bad_rd_ptr_expected_q) begin
                    $display("[FAIL] bad return read-pointer transition got=%0d expected=%0d",
                             dut.packet_rd_ptr_q, bad_rd_ptr_expected_q);
                    fail = fail + 1;
                end
                if (!tag_mismatch_sticky || !fail_stop ||
                    dut.bad_tag_event_q !== 1'b1 ||
                    tag_mismatch_count !== 32'd0 ||
                    dut.packet_head_addr_q !== 4'd0 ||
                    packet_addr !== 4'd0) begin
                    $display("[FAIL] bad-tag fail-stop/count/head edge sticky/fail/event/count/head=%0d/%0d/%0d/%0d/%0d",
                             tag_mismatch_sticky, fail_stop,
                             dut.bad_tag_event_q, tag_mismatch_count,
                             dut.packet_head_addr_q);
                    fail = fail + 1;
                end
                bad_count_commit_check_q = 1'b1;
            end
        end
    end

    task check_fault_state;
        input [8*48-1:0] label;
        input integer expected_packets;
        input integer expected_reads;
        input integer expected_extra_reads;
        input integer expected_blocked_ptr;
        begin
            repeat (2) @(negedge clk);
            if (!tag_mismatch_sticky || !fail_stop ||
                tag_mismatch_count != 1 || ctx_ready || rd_en != 0 ||
                packet_valid || context_done || fault_done_count != 0 ||
                packet_addr != 0 || dut.packet_head_addr_q != 0) begin
                $display("[FAIL] %0s did not reach clean fail-stop", label);
                fail = fail + 1;
            end
            if (bad_event_count != 1 ||
                bad_ptr_transition_count != 1 ||
                bad_rd_ptr_transition_count != 1 ||
                bad_sticky_edge_check_count != 1 ||
                bad_count_delay_check_count != 1 ||
                bad_blocked_ptr_count != expected_blocked_ptr ||
                extra_reads_on_bad_edge != expected_extra_reads ||
                extra_reads_on_bad_edge > 1 || reads_after_bad_edge != 0) begin
                $display("[FAIL] %0s read boundary events/wptr/rptr/sticky/count/blocked=%0d/%0d/%0d/%0d/%0d/%0d extra=%0d after=%0d expected_extra/blocked=%0d/%0d",
                         label, bad_event_count, bad_ptr_transition_count,
                         bad_rd_ptr_transition_count,
                         bad_sticky_edge_check_count,
                         bad_count_delay_check_count,
                         bad_blocked_ptr_count, extra_reads_on_bad_edge,
                         reads_after_bad_edge, expected_extra_reads,
                         expected_blocked_ptr);
                fail = fail + 1;
            end
            if (source_read_count != expected_reads ||
                fault_packet_count != expected_packets) begin
                $display("[FAIL] %0s counts reads=%0d/%0d packets=%0d/%0d",
                         label, source_read_count, expected_reads,
                         fault_packet_count, expected_packets);
                fail = fail + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;

        push_context(16'd3, 1'b0, 1'b0, 11'd0,
                     8'h21, 1'b0, 16'h1001, 8'h00, 16'h0000, 1'b1);
        push_context(16'd2, 1'b1, 1'b1, 11'd16,
                     8'h22, 1'b1, 16'h1002, 8'h21, 16'h1001, 1'b0);

        wait(done_count == 1);
        @(negedge clk);
        packet_ready = 1'b0;
        wait(packet_valid && packet_context_id == 16'h1002);
        repeat (3) begin
            @(negedge clk);
            if (!packet_valid || packet_context_id != 16'h1002 ||
                packet_epoch != 8'h22 || packet_parent_context_id != 16'h1001) begin
                $display("[FAIL] packet identity changed under backpressure");
                fail = fail + 1;
            end
        end
        packet_ready = 1'b1;
        wait(done_count == 2);
        repeat (2) @(negedge clk);
        if (packet_count_1 != 3 || packet_count_2 != 2) begin
            $display("[FAIL] packet counts c1=%0d c2=%0d expected 3/2",
                     packet_count_1, packet_count_2);
            fail = fail + 1;
        end
        if (tag_mismatch_sticky || fail_stop || tag_mismatch_count != 0) begin
            $display("[FAIL] clean identity phase raised tag fail-stop");
            fail = fail + 1;
        end

        // A bad first return may trigger one following speculative dequeue,
        // but the malformed packet must never retire.
        reset_phase();
        fault_phase = 1;
        bad_mode = 1;
        bad_read_index = 0;
        push_context(16'd4, 1'b1, 1'b0, 11'd0,
                     8'h31, 1'b0, 16'h2001, 8'h30, 16'h2000, 1'b0);
        wait_for_fail_stop();
        check_fault_state("descriptor first ready", 0, 2, 1, 0);

        // With a good packet already staged, a middle bad return may coincide
        // with retirement of that earlier packet and one speculative read.
        reset_phase();
        fault_phase = 2;
        bad_mode = 1;
        bad_read_index = 1;
        push_context(16'd4, 1'b1, 1'b0, 11'd0,
                     8'h32, 1'b0, 16'h2101, 8'h31, 16'h2100, 1'b0);
        wait_for_fail_stop();
        check_fault_state("descriptor middle ready", 1, 3, 1, 0);

        // Disabling the collector is not a recovery mechanism: only reset may
        // clear the sticky error and its single-event count.
        enable = 1'b0;
        repeat (2) @(negedge clk);
        if (!tag_mismatch_sticky || !fail_stop || tag_mismatch_count != 1) begin
            $display("[FAIL] enable toggle cleared fail-stop state");
            fail = fail + 1;
        end
        enable = 1'b1;

        // Backpressure may occupy both validated packet slots.  A middle
        // cross-column mismatch must discard every held packet.  Read issue is
        // intentionally independent of packet_ready, so the mismatch edge may
        // still make the one permitted speculative dequeue.
        reset_phase();
        fault_phase = 3;
        packet_ready = 1'b0;
        bad_mode = 2;
        bad_read_index = 1;
        push_context(16'd4, 1'b1, 1'b1, 11'd0,
                     8'h41, 1'b1, 16'h3001, 8'h40, 16'h3000, 1'b0);
        wait_for_fail_stop();
        check_fault_state("cross-column middle stalled", 0, 3, 1, 0);
        packet_ready = 1'b1;
        repeat (2) @(negedge clk);
        if (packet_valid || fault_packet_count != 0) begin
            $display("[FAIL] held packet escaped after fail-stop");
            fail = fail + 1;
        end

        // Two good returns can fill both validated slots while a third bad
        // return remains resident in the synchronous return slot.  Tag fault
        // detection is independent of queue credit, so fail-stop must fire
        // with return_advance low and the write pointer must remain unchanged.
        reset_phase();
        fault_phase = 4;
        packet_ready = 1'b0;
        bad_mode = 1;
        bad_read_index = 2;
        push_context(16'd5, 1'b1, 1'b0, 11'd0,
                     8'h51, 1'b0, 16'h4001, 8'h50, 16'h4000, 1'b0);
        wait_for_fail_stop();
        check_fault_state("descriptor third full", 0, 3, 0, 1);
        packet_ready = 1'b1;

        // Reset clears both elastic stages and error state; a fresh tagged
        // context must then run to completion with exact identity and count.
        reset_phase();
        fault_phase = 0;
        push_context(16'd2, 1'b0, 1'b0, 11'd0,
                     8'h21, 1'b0, 16'h1001, 8'h00, 16'h0000, 1'b1);
        wait(done_count == 1);
        repeat (2) @(negedge clk);
        if (packet_count_1 != 2 || source_read_count != 2 ||
            tag_mismatch_sticky || fail_stop || tag_mismatch_count != 0) begin
            $display("[FAIL] reset recovery packets=%0d reads=%0d sticky/count=%0d/%0d",
                     packet_count_1, source_read_count,
                     tag_mismatch_sticky, tag_mismatch_count);
            fail = fail + 1;
        end

        $display("=== tb_psum_output_collector_identity: %0d fail ===", fail);
        if (fail != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        repeat (800) @(negedge clk);
        $fatal(1, "[FAIL] timeout");
    end
endmodule

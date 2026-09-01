`timescale 1ns / 1ps

// Focused integration of the collector's registered read-credit boundary and
// the partial-PSUM owner scoreboard.  The scoreboard intentionally has no
// fail-stop feedback port into the collector: after a collision it holds
// packet_ready low.  Starting from one queued packet and an empty return slot
// is the worst reservation state; at most two more reads may then fill the
// two-entry validated queue plus the one-entry return slot.
module tb_psum_output_collector_scoreboard_failstop;
    localparam COLS = 2;
    localparam PSUM_W = 32;
    localparam ADDR_W = 4;
    localparam EPOCH_W = 8;
    localparam CONTEXT_W = 16;
    localparam TAG_W = EPOCH_W + 2;
    localparam DATA_W = COLS*PSUM_W*2;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg enable = 1'b0;
    reg ctx_valid = 1'b0;
    wire ctx_ready;
    reg [31:0] fifo_empty = 32'hffff_ffff;
    reg [DATA_W-1:0] fifo_data = {DATA_W{1'b0}};
    reg [COLS*TAG_W-1:0] fifo_tag = {COLS*TAG_W{1'b0}};
    wire [31:0] fifo_rd_en;

    wire packet_valid;
    wire packet_ready;
    wire [ADDR_W-1:0] packet_addr;
    wire [DATA_W-1:0] packet_data;
    wire packet_is_final;
    wire packet_wr_bank;
    wire [EPOCH_W-1:0] packet_epoch;
    wire [CONTEXT_W-1:0] packet_context_id;
    wire context_done;
    wire collector_tag_error;

    reg score_alloc_valid = 1'b0;
    wire score_alloc_ready;
    reg setup_wr_valid = 1'b0;
    reg [ADDR_W-1:0] setup_wr_addr = {ADDR_W{1'b0}};
    wire score_wr_valid = setup_wr_valid || packet_valid;
    wire [ADDR_W-1:0] score_wr_addr = setup_wr_valid ?
        setup_wr_addr : packet_addr;
    wire score_wr_ready;
    reg score_rd_valid = 1'b0;
    reg [ADDR_W-1:0] score_rd_addr = {ADDR_W{1'b0}};
    wire score_rd_ready;
    wire score_fail_stop;
    wire score_error_underflow;
    wire score_error_overwrite;
    wire score_error_epoch;
    wire score_error_context;
    wire score_error_collision;
    wire [31:0] score_collision_count;

    integer fail = 0;
    integer source_read_count = 0;
    integer packet_pop_count = 0;
    integer context_done_count = 0;
    integer collision_extra_reads = 0;
    integer reads_after_full = 0;
    reg collision_seen = 1'b0;
    reg full_seen = 1'b0;
    reg [TAG_W-1:0] source_tag;
    integer col_idx;

    psum_output_collector #(
        .COLS(COLS), .PSUM_W(PSUM_W), .ADDR_W(ADDR_W),
        .CTX_DEPTH(4), .CTX_AW(2), .EPOCH_W(EPOCH_W),
        .CONTEXT_W(CONTEXT_W), .TAG_W(TAG_W),
        .ENABLE_TAG_CHECK(1)
    ) u_collector (
        .clk(clk), .rst(rst), .enable(enable),
        .ctx_valid(ctx_valid), .ctx_ready(ctx_ready),
        .ctx_num_pixels(16'd8), .ctx_is_final(1'b0),
        .ctx_wr_bank(1'b0), .ctx_cout_base(11'd0),
        .ctx_cout_valid(11'd4), .ctx_trace_match(1'b0),
        .ctx_epoch(8'h55), .ctx_ifm_bank(1'b0),
        .ctx_context_id(16'h1234), .ctx_parent_epoch(8'h44),
        .ctx_parent_context_id(16'h1122), .ctx_first(1'b0),
        .psum_fifo_rd_en(fifo_rd_en), .psum_fifo_rd_data(fifo_data),
        .psum_fifo_rd_tag(fifo_tag), .psum_fifo_empty(fifo_empty),
        .packet_valid(packet_valid), .packet_ready(packet_ready),
        .packet_addr(packet_addr), .packet_data(packet_data),
        .packet_is_final(packet_is_final),
        .packet_wr_bank(packet_wr_bank), .packet_cout_base(),
        .packet_cout_valid(), .packet_epoch(packet_epoch),
        .packet_ifm_bank(), .packet_context_id(packet_context_id),
        .packet_parent_epoch(), .packet_parent_context_id(),
        .packet_first(), .context_start(), .context_done(context_done),
        .partial_done(), .final_done(), .context_active(),
        .context_wr_bank(), .context_is_final(), .context_epoch(),
        .context_ifm_bank(), .context_id(), .context_parent_epoch(),
        .context_parent_context_id(), .context_first(),
        .context_done_epoch(), .context_done_ifm_bank(),
        .context_done_context_id(), .context_done_parent_epoch(),
        .context_done_parent_context_id(), .context_done_first(),
        .context_done_final(), .context_done_wr_bank(),
        .trace_context_active(), .trace_context_done(),
        .perf_context_push(), .perf_context_pop(),
        .perf_context_full_stall(), .perf_column_empty_wait(),
        .tag_mismatch_sticky(collector_tag_error),
        .tag_mismatch_count(), .fail_stop()
    );

    assign packet_ready = score_wr_ready;

    psum_bank_owner_scoreboard #(
        .DEPTH(16), .AW(ADDR_W), .EPOCH_W(EPOCH_W),
        .CONTEXT_W(CONTEXT_W)
    ) u_score (
        .clk(clk), .rst(rst),
        .alloc_valid(score_alloc_valid), .alloc_bank(1'b0),
        .alloc_epoch(8'h55), .alloc_context(16'h1234),
        .alloc_expected(5'd8), .alloc_ready(score_alloc_ready),
        .wr_valid(score_wr_valid), .wr_bank(1'b0),
        .wr_epoch(8'h55), .wr_context(16'h1234),
        .wr_addr(score_wr_addr), .wr_ready(score_wr_ready),
        .commit_valid(1'b0), .commit_bank(1'b0),
        .commit_epoch(8'h55), .commit_context(16'h1234),
        .commit_ready(), .rd_req_valid(score_rd_valid),
        .rd_req_bank(1'b0), .rd_req_epoch(8'h55),
        .rd_req_context(16'h1234), .rd_req_addr(score_rd_addr),
        .rd_req_last(1'b0), .rd_req_ready(score_rd_ready),
        .rd_return_valid(1'b0), .rd_return_bank(1'b0),
        .rd_return_epoch(8'h55), .rd_return_context(16'h1234),
        .rd_return_last(1'b0), .rd_return_ready(),
        .release_valid(1'b0), .release_bank(1'b0),
        .release_epoch(8'h55), .release_context(16'h1234),
        .release_ready(), .bank_allocated(), .bank_writer_done(),
        .bank_reader_done(), .bank_reusable(), .bank0_owner_epoch(),
        .bank1_owner_epoch(), .bank0_owner_context(),
        .bank1_owner_context(), .bank0_committed_credits(),
        .bank1_committed_credits(), .bank0_outstanding(),
        .bank1_outstanding(), .alloc_count(), .commit_count(),
        .release_count(), .ownership_stall_cycles(),
        .underflow_count(), .overwrite_count(),
        .epoch_mismatch_count(), .context_mismatch_count(),
        .same_address_conflict_count(score_collision_count),
        .error_underflow(score_error_underflow),
        .error_overwrite(score_error_overwrite),
        .error_epoch_mismatch(score_error_epoch),
        .error_context_mismatch(score_error_context),
        .error_same_address_conflict(score_error_collision),
        .fail_stop(score_fail_stop)
    );

    always #5 clk = ~clk;

    // Synchronous result-FIFO model with correctly tagged returns.
    always @(posedge clk) begin
        if (rst) begin
            fifo_data <= {DATA_W{1'b0}};
            fifo_tag <= {COLS*TAG_W{1'b0}};
            source_read_count <= 0;
        end else if (fifo_rd_en != 0) begin
            fifo_data <= {4{source_read_count[31:0]}};
            source_tag = {
                8'h55, 1'b0,
                (u_collector.rd_count ==
                 u_collector.pixels_to_collect - 16'd1)
            };
            for (col_idx = 0; col_idx < COLS; col_idx = col_idx + 1)
                fifo_tag[col_idx*TAG_W +: TAG_W] <= source_tag;
            source_read_count <= source_read_count + 1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            packet_pop_count <= 0;
            context_done_count <= 0;
            collision_extra_reads <= 0;
            reads_after_full <= 0;
            collision_seen <= 1'b0;
            full_seen <= 1'b0;
        end else begin
            if (u_score.same_address_conflict) begin
                collision_seen <= 1'b1;
                if (fifo_rd_en != 0)
                    collision_extra_reads <= collision_extra_reads + 1;
            end else if (collision_seen && fifo_rd_en != 0) begin
                collision_extra_reads <= collision_extra_reads + 1;
            end

            if (u_collector.packet_count_q == 2 &&
                u_collector.return_valid_q)
                full_seen <= 1'b1;
            if (full_seen && fifo_rd_en != 0)
                reads_after_full <= reads_after_full + 1;

            if (packet_valid && packet_ready)
                packet_pop_count <= packet_pop_count + 1;
            if (context_done)
                context_done_count <= context_done_count + 1;
        end
    end

    task check;
        input condition;
        input [8*96-1:0] message;
        begin
            if (!condition) begin
                $display("[FAIL] %0s", message);
                fail = fail + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // Seed address zero so the simultaneous intent below contains a legal
        // read and a malformed duplicate collector write to the same address.
        @(negedge clk);
        score_alloc_valid = 1'b1;
        #1 check(score_alloc_ready, "scoreboard owner allocation ready");
        @(negedge clk);
        score_alloc_valid = 1'b0;
        setup_wr_addr = 0;
        setup_wr_valid = 1'b1;
        #1 check(score_wr_ready, "seed write accepted");
        @(negedge clk);
        setup_wr_valid = 1'b0;

        enable = 1'b1;
        ctx_valid = 1'b1;
        while (!ctx_ready)
            @(negedge clk);
        @(negedge clk);
        ctx_valid = 1'b0;

        // Allow only the first FIFO dequeue, then remove column credit.  Its
        // return moves into queue slot zero while the return slot becomes
        // empty, constructing the worst scoreboard-fail-stop reservation case.
        fifo_empty = 32'hffff_fffc;
        wait (fifo_rd_en != 0);
        @(negedge clk);
        fifo_empty = 32'hffff_ffff;
        wait (packet_valid && !u_collector.return_valid_q);
        check(packet_addr == 0 && packet_data[31:0] == 0,
              "one verified packet is resident before collision");

        // Re-enable the columns on the collision edge.  The collector cannot
        // see the scoreboard's registered fail-stop, only packet_ready low.
        // It may therefore reserve two additional responses, filling the
        // remaining validated slot and return slot, but must then stop.
        @(negedge clk);
        score_rd_addr = 0;
        score_rd_valid = 1'b1;
        fifo_empty = 32'hffff_fffc;
        #1;
        check(u_score.same_address_conflict && score_rd_ready &&
              !score_wr_ready && !packet_ready,
              "duplicate collector write is rejected while legal read advances");
        @(negedge clk);
        // Keep the rejected intent pair asserted.  Holding valid while ready
        // is low is legal and isolates the original collision event from a
        // later reclassification of the same collector write as overwrite.
        wait (score_fail_stop);
        repeat (5) @(negedge clk);
        check(collision_seen && score_error_collision &&
              score_collision_count == 1,
              "collision becomes one registered scoreboard fail-stop");
        check(!score_error_underflow && !score_error_overwrite &&
              !score_error_epoch && !score_error_context,
              "collision test raises no unrelated scoreboard error");
        check(collision_extra_reads == 2 && source_read_count == 3,
              "worst-state collision admits exactly two extra reads");
        check(u_collector.packet_count_q == 2 &&
              u_collector.return_valid_q && full_seen &&
              fifo_rd_en == 0 && reads_after_full == 0,
              "registered queue/return capacity bounds all later reads");
        check(packet_pop_count == 0 && context_done_count == 0 &&
              packet_valid && !packet_ready && !collector_tag_error,
              "scoreboard fail-stop retires no packet or context");
        check(packet_addr == 0 && packet_data[31:0] == 0 &&
              !packet_is_final && !packet_wr_bank &&
              packet_epoch == 8'h55 && packet_context_id == 16'h1234,
              "queue head remains stable under fail-stop backpressure");

        $display("=== tb_psum_output_collector_scoreboard_failstop: %0d fail ===",
                 fail);
        if (fail != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        repeat (300) @(negedge clk);
        $fatal(1, "[FAIL] timeout reads=%0d queue=%0d return=%0d collision=%0d",
               source_read_count, u_collector.packet_count_q,
               u_collector.return_valid_q, score_fail_stop);
    end
endmodule

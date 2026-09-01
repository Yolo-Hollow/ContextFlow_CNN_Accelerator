`timescale 1ns / 1ps

// Focused release-path test for background weight preload and the zero-bubble
// context handoff.  The DUT intentionally contains the real DSP48E2 cascade;
// canonical XSIM elaboration must therefore include unisims_ver and glbl.
module tb_systolic_top_tagged_preload_handoff;
    localparam ROWS = 2;
    localparam COLS = 2;
    localparam IFM_W = 8;
    localparam WEIGHT_W = 8;
    localparam PSUM_W = 32;
    localparam EPOCH_W = 8;
    localparam TAG_W = EPOCH_W + 2;
    localparam [EPOCH_W-1:0] EPOCH_A = 8'h41;
    localparam [EPOCH_W-1:0] EPOCH_B = 8'h92;
    localparam [31:0] COL_MASK = (32'h1 << COLS) - 1;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg start = 1'b0;
    reg [15:0] num_pixels = 16'd2;
    reg [15:0] tail_cycles_config = 16'd0;
    reg context_bank = 1'b0;
    reg [EPOCH_W-1:0] context_epoch = EPOCH_A;
    wire start_ready;
    wire done;
    wire compute_fire;
    wire input_issued_done;
    wire array_retired_done;
    wire array_retired_bank;
    wire [EPOCH_W-1:0] array_retired_epoch;

    reg [ROWS*IFM_W-1:0] ifm_vector_data = 0;
    reg ifm_vector_valid = 1'b0;
    wire ifm_vector_ready;
    reg ifm_vector_bank = 1'b0;
    reg [EPOCH_W-1:0] ifm_vector_epoch = EPOCH_A;
    reg ifm_vector_last = 1'b0;

    reg [5:0] bias_wr_addr = 0;
    reg [PSUM_W-1:0] bias_wr_data = 0;
    reg bias_wr_en = 1'b0;
    reg is_first_pass = 1'b1;

    reg [ROWS-1:0] wgt_fifo_wr_en = 0;
    reg [ROWS*WEIGHT_W*2-1:0] wgt_fifo_wr_data = 0;
    reg weight_tile_complete = 1'b0;
    reg weight_context_alloc_valid = 1'b0;
    reg weight_context_alloc_bank = 1'b0;
    reg [EPOCH_W-1:0] weight_context_alloc_epoch = EPOCH_A;
    wire weight_context_alloc_ready;
    wire [ROWS-1:0] wgt_fifo_full;

    reg [31:0] psum_fifo_rd_en = 0;
    wire [COLS*PSUM_W*2-1:0] psum_fifo_rd_data;
    wire [COLS*TAG_W-1:0] psum_fifo_rd_tag;
    wire [31:0] psum_fifo_empty;
    wire [31:0] psum_fifo_wr_en_dbg;
    wire [31:0] psum_credit_stall_cycles;
    wire [31:0] weight_ownership_stall_cycles;
    wire [31:0] epoch_mismatch_count;
    wire [31:0] context_mismatch_count;
    wire [31:0] ifm_underflow_count;
    wire [31:0] psum_underflow_count;
    wire [31:0] fifo_drop_count;
    wire [31:0] tagged_error_status;
    wire fatal_error;

    systolic_top_tagged #(
        .ROWS(ROWS),
        .COLS(COLS),
        .IFM_W(IFM_W),
        .WEIGHT_W(WEIGHT_W),
        .PSUM_W(PSUM_W),
        .EPOCH_W(EPOCH_W),
        .TAG_W(TAG_W),
        .WGT_FIFO_DEPTH(8),
        .WGT_FIFO_AW(3),
        .PSUM_FIFO_DEPTH(8),
        .PSUM_FIFO_AW(3),
        .RETIRE_DEPTH(4),
        .RETIRE_AW(2),
        .ENABLE_WEIGHT_PRELOAD(1),
        .ENABLE_FAST_CONTEXT_HANDOFF(1)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .num_pixels(num_pixels),
        .tail_cycles_config(tail_cycles_config),
        .context_admission_ready(1'b1),
        .context_bank(context_bank),
        .context_epoch(context_epoch),
        .start_ready(start_ready),
        .done(done),
        .compute_fire_out(compute_fire),
        .input_issued_done(input_issued_done),
        .array_retired_done(array_retired_done),
        .array_retired_bank(array_retired_bank),
        .array_retired_epoch(array_retired_epoch),
        .perf_comp_wload(),
        .perf_comp_active(),
        .perf_comp_ifm_stall(),
        .perf_comp_tail(),
        .perf_tail_cycles_configured(),
        .ifm_vector_data(ifm_vector_data),
        .ifm_vector_valid(ifm_vector_valid),
        .ifm_vector_ready(ifm_vector_ready),
        .ifm_vector_bank(ifm_vector_bank),
        .ifm_vector_epoch(ifm_vector_epoch),
        .ifm_vector_last(ifm_vector_last),
        .bias_wr_addr(bias_wr_addr),
        .bias_wr_data(bias_wr_data),
        .bias_wr_en(bias_wr_en),
        .is_first_pass(is_first_pass),
        .psum_top_ext({COLS*2*PSUM_W{1'b0}}),
        .use_ext_psum(1'b0),
        .psum_stream_data({COLS*2*PSUM_W{1'b0}}),
        .psum_stream_valid(1'b0),
        .psum_stream_compute_ready(1'b1),
        .use_psum_stream(1'b0),
        .psum_column_stream_data({COLS*2*PSUM_W{1'b0}}),
        .psum_column_stream_valid({COLS{1'b0}}),
        .use_column_psum_stream(1'b0),
        .wgt_fifo_wr_en(wgt_fifo_wr_en),
        .wgt_fifo_wr_data(wgt_fifo_wr_data),
        .weight_tile_complete(weight_tile_complete),
        .weight_context_alloc_valid(weight_context_alloc_valid),
        .weight_context_alloc_bank(weight_context_alloc_bank),
        .weight_context_alloc_epoch(weight_context_alloc_epoch),
        .weight_context_alloc_ready(weight_context_alloc_ready),
        .wgt_fifo_full(wgt_fifo_full),
        .psum_fifo_rd_en(psum_fifo_rd_en),
        .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_rd_tag(psum_fifo_rd_tag),
        .psum_fifo_empty(psum_fifo_empty),
        .psum_fifo_wr_en_dbg(psum_fifo_wr_en_dbg),
        .psum_credit_stall_cycles(psum_credit_stall_cycles),
        .weight_ownership_stall_cycles(weight_ownership_stall_cycles),
        .epoch_mismatch_count(epoch_mismatch_count),
        .context_mismatch_count(context_mismatch_count),
        .ifm_underflow_count(ifm_underflow_count),
        .psum_underflow_count(psum_underflow_count),
        .fifo_drop_count(fifo_drop_count),
        .tagged_error_status(tagged_error_status),
        .fatal_error(fatal_error)
    );

    integer pass_count = 0;
    integer fail_count = 0;
    integer cycle_count = 0;
    integer start_count = 0;
    integer fire_count = 0;
    integer input_done_count = 0;
    integer done_count = 0;
    integer retire_count = 0;
    integer handoff_cycle = -1;
    integer context1_first_cycle = -1;
    reg bank0_released_seen = 1'b0;
    reg bank1_released_seen = 1'b0;

    task check;
        input condition;
        input [8*112-1:0] message;
        begin
            if (condition)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task write_bias;
        input [5:0] addr;
        input signed [31:0] value;
        begin
            @(negedge clk);
            bias_wr_addr = addr;
            bias_wr_data = value;
            bias_wr_en = 1'b1;
            @(negedge clk);
            bias_wr_en = 1'b0;
        end
    endtask

    task allocate_weight_context;
        input bank;
        input [EPOCH_W-1:0] epoch;
        begin
            @(negedge clk);
            weight_context_alloc_bank = bank;
            weight_context_alloc_epoch = epoch;
            weight_context_alloc_valid = 1'b1;
            #1;
            check(weight_context_alloc_ready,
                  "weight context allocation was not accepted");
            @(negedge clk);
            weight_context_alloc_valid = 1'b0;
        end
    endtask

    // One tile word is written to every row FIFO on each call.  The two bytes
    // are the adjacent output-channel weights for that row and column.
    task write_weight_word;
        input signed [7:0] row0_w0;
        input signed [7:0] row0_w1;
        input signed [7:0] row1_w0;
        input signed [7:0] row1_w1;
        begin
            @(negedge clk);
            wgt_fifo_wr_data[15:0] = {row0_w1, row0_w0};
            wgt_fifo_wr_data[31:16] = {row1_w1, row1_w0};
            wgt_fifo_wr_en = {ROWS{1'b1}};
            #1;
            check(!( |wgt_fifo_full),
                  "weight row FIFO unexpectedly became full");
            @(negedge clk);
            wgt_fifo_wr_en = {ROWS{1'b0}};
        end
    endtask

    task commit_weight_tile;
        begin
            @(negedge clk);
            weight_tile_complete = 1'b1;
            @(negedge clk);
            weight_tile_complete = 1'b0;
        end
    endtask

    task wait_weight_ready;
        input bank;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!dut.preload_bank_ready[bank] && wait_cycles < 40) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            check(dut.preload_bank_ready[bank],
                  "preloaded weight bank did not commit");
        end
    endtask

    task read_and_check_packet;
        input integer packet_index;
        integer col_index;
        reg [TAG_W-1:0] expected_tag;
        reg signed [31:0] lane0;
        reg signed [31:0] lane1;
        reg signed [31:0] lane2;
        reg signed [31:0] lane3;
        begin
            wait((psum_fifo_empty & COL_MASK) == 0);
            @(negedge clk);
            psum_fifo_rd_en = COL_MASK;
            @(negedge clk);
            psum_fifo_rd_en = 32'd0;
            #1;

            lane0 = $signed(psum_fifo_rd_data[31:0]);
            lane1 = $signed(psum_fifo_rd_data[63:32]);
            lane2 = $signed(psum_fifo_rd_data[95:64]);
            lane3 = $signed(psum_fifo_rd_data[127:96]);
            case (packet_index)
                0: begin
                    expected_tag = {EPOCH_A, 1'b0, 1'b0};
                    check(lane0 == 107 && lane1 == 210 &&
                          lane2 == 319 && lane3 == 422,
                          "context0 first result or bias seed is incorrect");
                end
                1: begin
                    expected_tag = {EPOCH_A, 1'b0, 1'b1};
                    check(lane0 == 115 && lane1 == 222 &&
                          lane2 == 343 && lane3 == 450,
                          "context0 final result lost its first-pass bias seed");
                end
                2: begin
                    expected_tag = {EPOCH_B, 1'b1, 1'b0};
                    check(lane0 == 29 && lane1 == 32 &&
                          lane2 == 41 && lane3 == 44,
                          "context1 first result inherited the prior bias or weights");
                end
                3: begin
                    expected_tag = {EPOCH_B, 1'b1, 1'b1};
                    check(lane0 == 24 && lane1 == 26 &&
                          lane2 == 32 && lane3 == 34,
                          "context1 final non-first-pass result is incorrect");
                end
                default: begin
                    expected_tag = {TAG_W{1'bx}};
                    check(1'b0, "unexpected result packet index");
                end
            endcase

            for (col_index = 0; col_index < COLS;
                 col_index = col_index + 1)
                check(psum_fifo_rd_tag[
                          col_index*TAG_W +: TAG_W] == expected_tag,
                      "result packet carries the wrong epoch/bank/last tag");
        end
    endtask

    // Sample handshakes before DUT nonblocking assignments replace the live
    // context.  This proves that old-last/new-start share one physical edge
    // and that the next context fires on the immediately following edge.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count = 0;
        end else begin
            cycle_count = cycle_count + 1;

            if (start && start_ready) begin
                if (start_count == 0) begin
                    check(context_bank == 1'b0 &&
                          context_epoch == EPOCH_A,
                          "first start did not select preloaded bank0");
                end else if (start_count == 1) begin
                    check(compute_fire && ifm_vector_last,
                          "context1 start did not coincide with context0 last fire");
                    check(dut.active_context_bank_q == 1'b0 &&
                          dut.active_context_epoch_q == EPOCH_A,
                          "handoff edge replaced context0 before its final issue");
                    check(context_bank == 1'b1 &&
                          context_epoch == EPOCH_B,
                          "handoff start did not select preloaded bank1");
                    handoff_cycle = cycle_count;
                end else begin
                    check(1'b0, "unexpected extra context start");
                end
                start_count = start_count + 1;
            end

            if (compute_fire) begin
                case (fire_count)
                    0: check(ifm_vector_bank == 1'b0 &&
                             ifm_vector_epoch == EPOCH_A &&
                             !ifm_vector_last,
                             "context0 first compute token is malformed");
                    1: check(ifm_vector_bank == 1'b0 &&
                             ifm_vector_epoch == EPOCH_A &&
                             ifm_vector_last && start && start_ready,
                             "context0 final token missed same-edge handoff");
                    2: begin
                        context1_first_cycle = cycle_count;
                        check(ifm_vector_bank == 1'b1 &&
                              ifm_vector_epoch == EPOCH_B &&
                              !ifm_vector_last,
                              "context1 first compute token is malformed");
                        check(handoff_cycle >= 0 &&
                              cycle_count == handoff_cycle + 1,
                              "a compute bubble remained after fast handoff");
                    end
                    3: check(ifm_vector_bank == 1'b1 &&
                             ifm_vector_epoch == EPOCH_B &&
                             ifm_vector_last,
                             "context1 final compute token is malformed");
                    default: check(1'b0, "unexpected extra compute fire");
                endcase
                fire_count = fire_count + 1;
            end

            if (input_issued_done)
                input_done_count = input_done_count + 1;
            if (done)
                done_count = done_count + 1;

            if (array_retired_done) begin
                if (retire_count == 0) begin
                    check(array_retired_bank == 1'b0 &&
                          array_retired_epoch == EPOCH_A,
                          "first array retirement did not belong to context0");
                    check(!dut.preload_bank_active[0],
                          "weight bank0 stayed ACTIVE after array retirement");
                end else if (retire_count == 1) begin
                    check(array_retired_bank == 1'b1 &&
                          array_retired_epoch == EPOCH_B,
                          "second array retirement did not belong to context1");
                    check(!dut.preload_bank_active[1],
                          "weight bank1 stayed ACTIVE after array retirement");
                end else begin
                    check(1'b0, "unexpected extra array retirement");
                end
                retire_count = retire_count + 1;
            end
        end
    end

    // RETIRING is a deliberate one-cycle fence.  Observe the following EMPTY
    // state rather than requiring the epoch-valid bit to clear in the same
    // cycle as array_retired_done.
    always @(negedge clk) begin
        if (!rst) begin
            if (retire_count >= 1 && !dut.preload_bank_epoch_valid[0])
                bank0_released_seen = 1'b1;
            if (retire_count >= 2 && !dut.preload_bank_epoch_valid[1])
                bank1_released_seen = 1'b1;
        end
    end

    initial begin
        repeat (5) @(negedge clk);
        rst = 1'b0;

        // Biases distinguish the first pass from the following non-first
        // pass, especially across the same-edge context state replacement.
        write_bias(6'd0, 32'sd100);
        write_bias(6'd1, 32'sd200);
        write_bias(6'd2, 32'sd300);
        write_bias(6'd3, 32'sd400);

        // Bank0 tile: columns {{1,2},{3,4}} and {{5,6},{7,8}}.
        allocate_weight_context(1'b0, EPOCH_A);
        write_weight_word(8'sd1, 8'sd2, 8'sd3, 8'sd4);
        write_weight_word(8'sd5, 8'sd6, 8'sd7, 8'sd8);
        commit_weight_tile();
        wait_weight_ready(1'b0);

        // Bank1 tile is loaded while no start consumes either bank.  It uses
        // visibly different weights so a bad bank switch cannot hide.
        allocate_weight_context(1'b1, EPOCH_B);
        write_weight_word(8'sd9, 8'sd10, 8'sd11, 8'sd12);
        write_weight_word(8'sd13, 8'sd14, 8'sd15, 8'sd16);
        commit_weight_tile();
        wait_weight_ready(1'b1);
        check(dut.preload_bank_ready == 2'b11,
              "both inactive weight banks were not committed before issue");
        check(dut.g_weight_preload.u_weight_preloader.preload_commit_count == 2,
              "weight preloader commit count is incorrect");
        check(dut.g_weight_preload.u_weight_preloader.array_write_count ==
              2*COLS,
              "weight preloader did not write every bank/column pair");

        // Start context0 with its first vector.  Since weights are already in
        // the DSP bank, its first fire occurs without a weight-load state.
        @(negedge clk);
        context_bank = 1'b0;
        context_epoch = EPOCH_A;
        num_pixels = 16'd2;
        is_first_pass = 1'b1;
        ifm_vector_bank = 1'b0;
        ifm_vector_epoch = EPOCH_A;
        ifm_vector_data[7:0] = 8'sd1;
        ifm_vector_data[15:8] = 8'sd2;
        ifm_vector_last = 1'b0;
        ifm_vector_valid = 1'b1;
        start = 1'b1;
        #1;
        check(start_ready, "context0 start was not ready");
        @(negedge clk);
        start = 1'b0;

        // The first context0 fire occurs on the next rising edge.
        @(posedge clk);
        #1;
        check(fire_count == 1, "context0 first token did not compute");

        // Present context0's last token and context1's descriptor together.
        // The old token still uses first-pass bias; the new context captures
        // non-first-pass seed control on this same edge.
        @(negedge clk);
        ifm_vector_data[7:0] = 8'sd3;
        ifm_vector_data[15:8] = 8'sd4;
        ifm_vector_last = 1'b1;
        context_bank = 1'b1;
        context_epoch = EPOCH_B;
        num_pixels = 16'd2;
        is_first_pass = 1'b0;
        start = 1'b1;
        #1;
        check(start_ready && compute_fire,
              "fast handoff was not armed on context0 final token");
        @(posedge clk);
        #1;
        check(fire_count == 2 && start_count == 2,
              "same-edge final-fire/start handshake was not observed");

        // The first bank1 token must fire on the very next rising edge.
        @(negedge clk);
        start = 1'b0;
        ifm_vector_bank = 1'b1;
        ifm_vector_epoch = EPOCH_B;
        ifm_vector_data[7:0] = 8'sd2;
        ifm_vector_data[15:8] = 8'sd1;
        ifm_vector_last = 1'b0;
        @(posedge clk);
        #1;
        check(fire_count == 3,
              "context1 first token did not fire on the next cycle");

        @(negedge clk);
        ifm_vector_data[7:0] = -8'sd1;
        ifm_vector_data[15:8] = 8'sd3;
        ifm_vector_last = 1'b1;
        @(posedge clk);
        #1;
        check(fire_count == 4, "context1 final token did not compute");
        @(negedge clk);
        ifm_vector_valid = 1'b0;
        ifm_vector_last = 1'b0;

        // Retirement does not depend on software draining the result FIFOs.
        wait(retire_count == 2);
        repeat (2) @(negedge clk);
        check(bank0_released_seen && bank1_released_seen,
              "retired weight banks did not reach EMPTY/reusable state");
        check(dut.preload_bank_epoch_valid == 2'b00,
              "retired weight bank epoch ownership remained live");

        read_and_check_packet(0);
        read_and_check_packet(1);
        read_and_check_packet(2);
        read_and_check_packet(3);

        repeat (3) @(negedge clk);
        check(start_count == 2, "context start count is incorrect");
        check(fire_count == 4, "compute fire count is incorrect");
        check(input_done_count == 2,
              "input-issued lifecycle count is incorrect");
        check(done_count == 2, "controller done count is incorrect");
        check(retire_count == 2, "array-retired lifecycle count is incorrect");
        check(context1_first_cycle == handoff_cycle + 1,
              "fast handoff did not sustain one compute fire per cycle");
        check(dut.g_weight_preload.u_weight_preloader.start_match_count == 2,
              "preloader start-match count is incorrect");
        check(dut.g_weight_preload.u_weight_preloader.retire_match_count == 2,
              "preloader retire-match count is incorrect");
        check(dut.g_weight_preload.u_weight_preloader.protocol_error_count == 0 &&
              dut.g_weight_preload.u_weight_preloader.owner_error_count == 0 &&
              dut.g_weight_preload.u_weight_preloader.epoch_error_count == 0,
              "weight preloader reported a lifecycle error");
        check(psum_credit_stall_cycles == 0 &&
              weight_ownership_stall_cycles == 0 &&
              epoch_mismatch_count == 0 && context_mismatch_count == 0 &&
              ifm_underflow_count == 0 && psum_underflow_count == 0 &&
              fifo_drop_count == 0,
              "tagged datapath telemetry reported an error or stall");
        check(!fatal_error && tagged_error_status == 0,
              "tagged datapath sticky/fatal status is nonzero");

        $display("=== tb_systolic_top_tagged_preload_handoff: %0d pass, %0d fail ===",
            pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "tb_systolic_top_tagged_preload_handoff timeout");
    end
endmodule

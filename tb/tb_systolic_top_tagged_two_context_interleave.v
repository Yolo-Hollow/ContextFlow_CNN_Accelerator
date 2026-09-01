`timescale 1ns / 1ps

module tb_systolic_top_tagged_two_context_interleave;
    localparam ROWS = 2;
    localparam COLS = 8;
    localparam IFM_W = 8;
    localparam WEIGHT_W = 8;
    localparam PSUM_W = 32;
    localparam EPOCH_W = 8;
    localparam TAG_W = EPOCH_W + 2;
    localparam [EPOCH_W-1:0] EPOCH_A = 8'h31;
    localparam [EPOCH_W-1:0] EPOCH_B = 8'h52;
    localparam [EPOCH_W-1:0] EPOCH_C = 8'h73;
    localparam [31:0] COL_MASK = (32'h1 << COLS) - 1;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg start = 1'b0;
    reg [15:0] num_pixels = 16'd1;
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
    reg ifm_vector_last = 1'b1;

    reg [5:0] bias_wr_addr = 0;
    reg [PSUM_W-1:0] bias_wr_data = 0;
    reg bias_wr_en = 1'b0;
    reg [ROWS-1:0] wgt_fifo_wr_en = 0;
    reg [ROWS*WEIGHT_W*2-1:0] wgt_fifo_wr_data = 0;
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
        .WGT_FIFO_DEPTH(32),
        .WGT_FIFO_AW(5),
        .PSUM_FIFO_DEPTH(8),
        .PSUM_FIFO_AW(3),
        .RETIRE_DEPTH(4),
        .RETIRE_AW(2)
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
        .is_first_pass(1'b1),
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
    integer input_done_count = 0;
    integer retire_count = 0;
    integer done_count = 0;
    integer b_start_cycle = -1;
    integer a_retire_cycle = -1;
    integer a_late_last_cycle = -1;
    integer a_early_last_cycle = -1;
    integer b_early_last_cycle = -1;
    integer b_late_last_cycle = -1;
    reg [COLS-1:0] a_last_mask = {COLS{1'b0}};
    reg [COLS-1:0] b_last_mask = {COLS{1'b0}};
    reg [COLS-1:0] c_last_mask = {COLS{1'b0}};

    task check;
        input cond;
        input [511:0] message;
        begin
            if (cond)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task push_weight_word;
        integer row_idx;
        begin
            @(negedge clk);
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                wgt_fifo_wr_data[row_idx*WEIGHT_W*2 +: WEIGHT_W] = 8'sd1;
                wgt_fifo_wr_data[row_idx*WEIGHT_W*2+WEIGHT_W +: WEIGHT_W] = 8'sd1;
            end
            wgt_fifo_wr_en = {ROWS{1'b1}};
            #1;
            check(!( |wgt_fifo_full), "preloaded weight FIFOs have capacity");
            @(negedge clk);
            wgt_fifo_wr_en = {ROWS{1'b0}};
        end
    endtask

    task launch_one_pixel;
        input bank;
        input [EPOCH_W-1:0] epoch;
        input signed [7:0] row0_data;
        input signed [7:0] row1_data;
        begin
            @(negedge clk);
            context_bank = bank;
            context_epoch = epoch;
            ifm_vector_bank = bank;
            ifm_vector_epoch = epoch;
            ifm_vector_data[7:0] = row0_data;
            ifm_vector_data[15:8] = row1_data;
            ifm_vector_last = 1'b1;
            ifm_vector_valid = 1'b1;
            wait(start_ready);
            @(negedge clk);
            start = 1'b1;
            #1;
            check(start_ready, "back-to-back context starts only on ready");
            @(negedge clk);
            start = 1'b0;
            // Wait for the active-edge handshake, not merely the combinational
            // ready level that appears after the controller enters COMPUTE.
            @(posedge clk);
            while (!compute_fire)
                @(posedge clk);
            @(negedge clk);
            ifm_vector_valid = 1'b0;
        end
    endtask

    task read_and_check_packet;
        input [EPOCH_W-1:0] epoch;
        input bank;
        integer col_idx;
        reg [TAG_W-1:0] expected_tag;
        begin
            expected_tag = {epoch, bank, 1'b1};
            wait((psum_fifo_empty & COL_MASK) == 0);
            @(negedge clk);
            psum_fifo_rd_en = COL_MASK;
            @(negedge clk);
            psum_fifo_rd_en = 32'd0;
            #1;
            for (col_idx = 0; col_idx < COLS; col_idx = col_idx + 1) begin
                check(psum_fifo_rd_tag[col_idx*TAG_W +: TAG_W] == expected_tag,
                      "every output column carries the expected packet tag");
            end
        end
    endtask

    integer monitor_col;
    reg [TAG_W-1:0] monitor_tag;
    always @(posedge clk) begin
        if (rst) begin
            cycle_count = 0;
        end else begin
            cycle_count = cycle_count + 1;

            if (start && start_ready) begin
                if (start_count == 1) begin
                    b_start_cycle = cycle_count;
                    check(retire_count == 0,
                          "context B starts while context A is still retiring");
                    check(dut.mesh_epoch_valid_q[0] &&
                          dut.mesh_epoch_bank0_q == EPOCH_A,
                          "context A epoch mapping remains live until retirement");
                end else if (start_count == 2) begin
                    check((psum_fifo_empty & COL_MASK) == 0,
                          "context A packets remain queued when bank0 is reused");
                end
                start_count = start_count + 1;
            end

            for (monitor_col = 0; monitor_col < COLS;
                 monitor_col = monitor_col + 1) begin
                if (dut.psum_write_last[monitor_col]) begin
                    monitor_tag = dut.tag_v_bot[
                        monitor_col*TAG_W +: TAG_W];
                    if (monitor_tag == {EPOCH_A, 1'b0, 1'b1}) begin
                        check(!a_last_mask[monitor_col],
                              "context A emits one last token per column");
                        a_last_mask[monitor_col] = 1'b1;
                        if (monitor_col == 0)
                            a_early_last_cycle = cycle_count;
                        if (monitor_col == COLS-1)
                            a_late_last_cycle = cycle_count;
                    end else if (monitor_tag ==
                                 {EPOCH_B, 1'b1, 1'b1}) begin
                        check(!b_last_mask[monitor_col],
                              "context B emits one last token per column");
                        b_last_mask[monitor_col] = 1'b1;
                        if (monitor_col == 0)
                            b_early_last_cycle = cycle_count;
                        if (monitor_col == COLS-1)
                            b_late_last_cycle = cycle_count;
                    end else if (monitor_tag ==
                                 {EPOCH_C, 1'b0, 1'b1}) begin
                        check(!c_last_mask[monitor_col],
                              "context C emits one last token per column");
                        c_last_mask[monitor_col] = 1'b1;
                    end else begin
                        check(1'b0,
                              "bottom last token belongs to a live context");
                    end
                end
            end
        end
    end

    always @(negedge clk) begin
        if (!rst) begin
            if (input_issued_done) begin
                if (input_done_count == 0)
                    check(dut.active_context_epoch_q == EPOCH_A &&
                          dut.active_context_bank_q == 1'b0,
                          "first input-issued pulse belongs to context A");
                else if (input_done_count == 1)
                    check(dut.active_context_epoch_q == EPOCH_B &&
                          dut.active_context_bank_q == 1'b1,
                          "second input-issued pulse belongs to context B");
                else if (input_done_count == 2)
                    check(dut.active_context_epoch_q == EPOCH_C &&
                          dut.active_context_bank_q == 1'b0,
                          "third input-issued pulse belongs to reused bank0 context C");
                else
                    check(1'b0, "unexpected extra input-issued pulse");
                input_done_count = input_done_count + 1;
            end

            if (done)
                done_count = done_count + 1;

            if (array_retired_done) begin
                if (retire_count == 0) begin
                    check(array_retired_epoch == EPOCH_A &&
                          array_retired_bank == 1'b0,
                          "first array retirement is context A");
                    check(!dut.mesh_epoch_valid_q[0] &&
                          dut.mesh_epoch_valid_q[1] &&
                          dut.mesh_epoch_bank1_q == EPOCH_B,
                          "A mapping releases while B mapping remains live");
                    a_retire_cycle = cycle_count;
                end else if (retire_count == 1) begin
                    check(array_retired_epoch == EPOCH_B &&
                          array_retired_bank == 1'b1,
                          "second array retirement is context B");
                    check(dut.mesh_epoch_valid_q[0] &&
                          dut.mesh_epoch_bank0_q == EPOCH_C &&
                          !dut.mesh_epoch_valid_q[1],
                          "B mapping releases while reused bank0 mapping remains live");
                end else if (retire_count == 2) begin
                    check(array_retired_epoch == EPOCH_C &&
                          array_retired_bank == 1'b0,
                          "third array retirement is reused bank0 context C");
                    check(dut.mesh_epoch_valid_q == 2'b00,
                          "both epoch mappings release after C retires");
                end else begin
                    check(1'b0, "unexpected extra array retirement");
                end
                retire_count = retire_count + 1;
            end
        end
    end

    integer preload_idx;
    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;

        // Initialize every static PSUM input and preload exactly two complete
        // weight tiles in FIFO order: context A, context B, then context C.
        for (preload_idx = 0; preload_idx < COLS*3;
             preload_idx = preload_idx + 1) begin
            @(negedge clk);
            bias_wr_en = 1'b1;
            bias_wr_addr = preload_idx[5:0];
            bias_wr_data = 32'd0;
        end
        @(negedge clk);
        bias_wr_en = 1'b0;

        for (preload_idx = 0; preload_idx < COLS*3;
             preload_idx = preload_idx + 1)
            push_weight_word();

        launch_one_pixel(1'b0, EPOCH_A, 8'sd2, 8'sd3);
        launch_one_pixel(1'b1, EPOCH_B, 8'sd5, 8'sd7);
        wait(retire_count >= 1);
        launch_one_pixel(1'b0, EPOCH_C, 8'sd11, 8'sd13);
        check(dut.mesh_epoch_valid_q[0] &&
              dut.mesh_epoch_bank0_q == EPOCH_C,
              "retired bank0 immediately accepts a new epoch mapping");
        check((psum_fifo_empty & COL_MASK) == 0,
              "old full-tag packets survive compact mesh-bank reuse");

        wait(retire_count == 3);
        repeat (2) @(negedge clk);

        check(start_count == 3, "exactly three contexts are accepted");
        check(input_done_count == 3,
              "exactly three input-issued pulses are observed");
        check(done_count == 3,
              "issue controller produces exactly three completion pulses");
        check(a_last_mask == {COLS{1'b1}},
              "all context A columns emit their tagged last token");
        check(b_last_mask == {COLS{1'b1}},
              "all context B columns emit their tagged last token");
        check(c_last_mask == {COLS{1'b1}},
              "all reused-bank context C columns emit their tagged last token");
        check(a_early_last_cycle >= 0 && a_late_last_cycle >= 0 &&
              a_early_last_cycle == a_late_last_cycle,
              "cascade emits every context A column last in lockstep");
        check(b_early_last_cycle >= 0 && b_late_last_cycle >= 0 &&
              b_early_last_cycle == b_late_last_cycle,
              "cascade emits every context B column last in lockstep");
        check(a_late_last_cycle < b_early_last_cycle,
              "context A last result remains ordered before context B");
        check(b_start_cycle >= 0 && a_retire_cycle >= 0 &&
              b_start_cycle < a_retire_cycle,
              "context B starts before context A array retirement");

        read_and_check_packet(EPOCH_A, 1'b0);
        read_and_check_packet(EPOCH_B, 1'b1);
        read_and_check_packet(EPOCH_C, 1'b0);
        repeat (2) @(negedge clk);
        check((psum_fifo_empty & COL_MASK) == COL_MASK,
              "all tagged packets are drained from every column FIFO");

        check(!fatal_error && tagged_error_status == 32'd0,
              "interleaved tagged retirement leaves all sticky errors clear");
        check(weight_ownership_stall_cycles == 32'd0 &&
              epoch_mismatch_count == 32'd0 &&
              context_mismatch_count == 32'd0 &&
              ifm_underflow_count == 32'd0 &&
              psum_underflow_count == 32'd0 && fifo_drop_count == 32'd0,
              "interleaved contexts leave all error telemetry at zero");

        $display("interleave cycles: A.cols=%0d B.cols=%0d B.start=%0d A.retire=%0d",
                 a_late_last_cycle, b_early_last_cycle,
                 b_start_cycle, a_retire_cycle);
        $display("=== tb_systolic_top_tagged_two_context_interleave: %0d pass, %0d fail ===",
                 pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        repeat (1500) @(posedge clk);
        $display("[FAIL] timeout starts=%0d issued=%0d retired=%0d A=%b B=%b fatal=%0d status=%h ctrl_state=%0d active=%0d stream_match=%0d ifm_valid=%0d ready=%0d credits=%0d",
                 start_count, input_done_count, retire_count,
                 a_last_mask, b_last_mask, fatal_error,
                 tagged_error_status, dut.u_ctrl.state_q,
                 dut.active_context_q, dut.context_stream_match,
                 ifm_vector_valid, ifm_vector_ready,
                 dut.all_output_credit_available);
        $fatal(1);
    end
endmodule

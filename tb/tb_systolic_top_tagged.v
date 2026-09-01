`timescale 1ns / 1ps

module tb_systolic_top_tagged;
    localparam ROWS = 2;
    localparam COLS = 2;
    localparam EPOCH_W = 8;
    localparam TAG_W = 10;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg start = 1'b0;
    reg [15:0] num_pixels = 16'd3;
    reg [15:0] tail_cycles_config = 16'd0;
    reg context_bank = 1'b0;
    reg [7:0] context_epoch = 8'h21;
    wire done;
    wire start_ready;
    wire compute_fire;
    wire input_issued_done;
    wire array_retired_done;
    wire array_retired_bank;
    wire [7:0] array_retired_epoch;

    reg [ROWS*8-1:0] ifm_vector_data = 0;
    reg ifm_vector_valid = 1'b0;
    wire ifm_vector_ready;
    reg ifm_vector_bank = 1'b0;
    reg [7:0] ifm_vector_epoch = 8'h21;
    reg ifm_vector_last = 1'b0;

    reg [5:0] bias_wr_addr = 0;
    reg [31:0] bias_wr_data = 0;
    reg bias_wr_en = 1'b0;
    reg [ROWS-1:0] wgt_fifo_wr_en = 0;
    reg [ROWS*16-1:0] wgt_fifo_wr_data = 0;
    wire [ROWS-1:0] wgt_fifo_full;

    reg [31:0] psum_fifo_rd_en = 0;
    wire [COLS*64-1:0] psum_fifo_rd_data;
    wire [COLS*TAG_W-1:0] psum_fifo_rd_tag;
    wire [31:0] psum_fifo_empty;
    wire [31:0] psum_fifo_wr_en_dbg;
    wire [31:0] tagged_error_status;
    wire fatal_error;

    systolic_top_tagged #(
        .ROWS(ROWS), .COLS(COLS),
        .WGT_FIFO_DEPTH(8), .WGT_FIFO_AW(3),
        .PSUM_FIFO_DEPTH(8), .PSUM_FIFO_AW(3),
        .EPOCH_W(EPOCH_W), .TAG_W(TAG_W)
    ) dut (
        .clk(clk), .rst(rst),
        .start(start), .num_pixels(num_pixels),
        .tail_cycles_config(tail_cycles_config),
        .context_admission_ready(1'b1),
        .context_bank(context_bank), .context_epoch(context_epoch),
        .start_ready(start_ready),
        .done(done), .compute_fire_out(compute_fire),
        .input_issued_done(input_issued_done),
        .array_retired_done(array_retired_done),
        .array_retired_bank(array_retired_bank),
        .array_retired_epoch(array_retired_epoch),
        .perf_comp_wload(), .perf_comp_active(),
        .perf_comp_ifm_stall(), .perf_comp_tail(),
        .perf_tail_cycles_configured(),
        .ifm_vector_data(ifm_vector_data),
        .ifm_vector_valid(ifm_vector_valid),
        .ifm_vector_ready(ifm_vector_ready),
        .ifm_vector_bank(ifm_vector_bank),
        .ifm_vector_epoch(ifm_vector_epoch),
        .ifm_vector_last(ifm_vector_last),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data),
        .bias_wr_en(bias_wr_en), .is_first_pass(1'b1),
        .psum_top_ext({COLS*64{1'b0}}), .use_ext_psum(1'b0),
        .psum_stream_data({COLS*64{1'b0}}),
        .psum_stream_valid(1'b0), .psum_stream_compute_ready(1'b1),
        .use_psum_stream(1'b0),
        .psum_column_stream_data({COLS*64{1'b0}}),
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
        .psum_credit_stall_cycles(),
        .weight_ownership_stall_cycles(),
        .epoch_mismatch_count(), .context_mismatch_count(),
        .ifm_underflow_count(), .psum_underflow_count(),
        .fifo_drop_count(), .tagged_error_status(tagged_error_status),
        .fatal_error(fatal_error)
    );

    task write_weight_column;
        input signed [7:0] r0w0;
        input signed [7:0] r0w1;
        input signed [7:0] r1w0;
        input signed [7:0] r1w1;
        begin
            @(negedge clk);
            wgt_fifo_wr_data[15:0] = {r0w1, r0w0};
            wgt_fifo_wr_data[31:16] = {r1w1, r1w0};
            wgt_fifo_wr_en = {ROWS{1'b1}};
            @(negedge clk);
            wgt_fifo_wr_en = 0;
        end
    endtask

    reg signed [7:0] pixels_r0 [0:2];
    reg signed [7:0] pixels_r1 [0:2];
    integer sent = 0;
    integer retired_seen = 0;
    integer done_seen = 0;
    integer input_done_seen = 0;
    integer failures = 0;
    integer read_index = 0;
    integer retired_before_full = 0;
    reg read_pending = 1'b0;
    reg advance_pending = 1'b0;

    task check_packet;
        input integer idx;
        reg signed [31:0] c0a;
        reg signed [31:0] c0b;
        reg signed [31:0] c1a;
        reg signed [31:0] c1b;
        reg [TAG_W-1:0] expected_tag;
        begin
            c0a = $signed(psum_fifo_rd_data[31:0]);
            c0b = $signed(psum_fifo_rd_data[63:32]);
            c1a = $signed(psum_fifo_rd_data[95:64]);
            c1b = $signed(psum_fifo_rd_data[127:96]);
            expected_tag = {8'h21, 1'b0, idx == 2};
            case (idx)
                0: if (c0a != 7 || c0b != 10 || c1a != 19 || c1b != 22)
                    failures = failures + 1;
                1: if (c0a != 15 || c0b != 22 || c1a != 43 || c1b != 50)
                    failures = failures + 1;
                2: if (c0a != 5 || c0b != 6 || c1a != 9 || c1b != 10)
                    failures = failures + 1;
                default: failures = failures + 1;
            endcase
            if (psum_fifo_rd_tag[TAG_W-1:0] != expected_tag ||
                psum_fifo_rd_tag[2*TAG_W-1:TAG_W] != expected_tag) begin
                $display("ERROR: packet %0d tags %h/%h expected %h", idx,
                    psum_fifo_rd_tag[TAG_W-1:0],
                    psum_fifo_rd_tag[2*TAG_W-1:TAG_W], expected_tag);
                failures = failures + 1;
            end
            if (failures != 0)
                $display("packet %0d data=%0d,%0d,%0d,%0d", idx,
                    c0a, c0b, c1a, c1b);
        end
    endtask

    // Sample ready/valid in the active region of the rising edge, before the
    // controller's state NBA updates can describe the following cycle.
    always @(posedge clk) begin
        if (!rst) begin
            if (compute_fire) begin
                sent = sent + 1;
                advance_pending = 1'b1;
            end
        end
    end

    always @(negedge clk) begin
        if (!rst) begin
            if (advance_pending) begin
                advance_pending = 1'b0;
                if (sent < 3) begin
                    ifm_vector_data[7:0] = pixels_r0[sent];
                    ifm_vector_data[15:8] = pixels_r1[sent];
                    ifm_vector_last = sent == 2;
                end else begin
                    ifm_vector_valid = 1'b0;
                end
            end
            if (input_issued_done)
                input_done_seen = input_done_seen + 1;
            if (array_retired_done) begin
                retired_seen = retired_seen + 1;
                if (array_retired_epoch != 8'h21 || array_retired_bank != 1'b0)
                    failures = failures + 1;
            end
            if (done)
                done_seen = done_seen + 1;

            if (!read_pending &&
                ((psum_fifo_empty & 32'h3) == 0) && read_index < 3) begin
                psum_fifo_rd_en = 32'h3;
                read_pending = 1'b1;
            end else begin
                psum_fifo_rd_en = 0;
                if (read_pending) begin
                    check_packet(read_index);
                    read_index = read_index + 1;
                    read_pending = 1'b0;
                end
            end
        end
    end

    initial begin
        pixels_r0[0] = 8'sd1;  pixels_r1[0] = 8'sd2;
        pixels_r0[1] = 8'sd3;  pixels_r1[1] = 8'sd4;
        pixels_r0[2] = -8'sd1; pixels_r1[2] = 8'sd2;
        repeat (4) @(negedge clk);
        rst = 1'b0;

        // The retirement queue has separate credits for two different
        // transactions.  A full queue may still replace its head when that
        // descriptor retires in the same cycle, but a new context must wait
        // for the registered occupancy to fall.  Exercise the otherwise
        // unreachable defensive boundary without clocking forced state into
        // the DUT.
        force dut.retire_count_q = 3'd4;
        force dut.retire_pop = 1'b1;
        #1;
        if (dut.retire_push_ready !== 1'b1 ||
            dut.retire_start_credit !== 1'b0 || start_ready !== 1'b0) begin
            $display("ERROR: full+pop retire/start credit split push/start/ready=%b/%b/%b",
                     dut.retire_push_ready, dut.retire_start_credit,
                     start_ready);
            failures = failures + 1;
        end
        release dut.retire_pop;
        release dut.retire_count_q;

        force dut.retire_count_q = 3'd3;
        force dut.retire_pop = 1'b0;
        #1;
        if (dut.retire_push_ready !== 1'b1 ||
            dut.retire_start_credit !== 1'b1 || start_ready !== 1'b1) begin
            $display("ERROR: non-full retire/start credit split push/start/ready=%b/%b/%b",
                     dut.retire_push_ready, dut.retire_start_credit,
                     start_ready);
            failures = failures + 1;
        end
        release dut.retire_pop;
        release dut.retire_count_q;

        // Bias storage is intentionally load-only in hardware.
        bias_wr_addr = 6'h3f;
        repeat (4) begin
            @(negedge clk);
            bias_wr_en = 1'b1;
            bias_wr_data = 32'd0;
            bias_wr_addr = bias_wr_addr + 1'b1;
        end
        @(negedge clk);
        bias_wr_en = 1'b0;

        write_weight_column(8'sd1, 8'sd2, 8'sd3, 8'sd4);
        write_weight_column(8'sd5, 8'sd6, 8'sd7, 8'sd8);

        @(negedge clk);
        ifm_vector_data[7:0] = pixels_r0[0];
        ifm_vector_data[15:8] = pixels_r1[0];
        ifm_vector_valid = 1'b1;
        ifm_vector_last = 1'b0;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait(done_seen == 1 && read_index == 3);
        repeat (4) @(posedge clk);
        if (sent != 3 || input_done_seen != 1 || retired_seen != 1 ||
            done_seen != 1) begin
            $display("ERROR: sent=%0d input_done=%0d retired=%0d done=%0d",
                sent, input_done_seen, retired_seen, done_seen);
            failures = failures + 1;
        end
        if (fatal_error || tagged_error_status != 0) begin
            $display("ERROR: fatal=%0d status=%h", fatal_error,
                tagged_error_status);
            failures = failures + 1;
        end
        if (dut.mesh_epoch_valid_q != 2'b00) begin
            $display("ERROR: retired bank epoch mapping remained live: %b",
                dut.mesh_epoch_valid_q);
            failures = failures + 1;
        end

        // A last result which encounters a full result FIFO is an attempted
        // write, not a retired column.  Hold both FIFOs full while the final
        // wave crosses the mesh and require fail-stop without releasing the
        // compact-tag bank-to-epoch mapping.
        rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        sent = 0;
        advance_pending = 1'b0;
        ifm_vector_valid = 1'b0;
        context_bank = 1'b1;
        context_epoch = 8'h42;
        ifm_vector_bank = 1'b1;
        ifm_vector_epoch = 8'h42;
        num_pixels = 16'd1;
        retired_before_full = retired_seen;

        write_weight_column(8'sd1, 8'sd2, 8'sd3, 8'sd4);
        write_weight_column(8'sd5, 8'sd6, 8'sd7, 8'sd8);
        @(negedge clk);
        ifm_vector_data[7:0] = pixels_r0[0];
        ifm_vector_data[15:8] = pixels_r1[0];
        ifm_vector_valid = 1'b1;
        ifm_vector_last = 1'b1;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait(dut.valid_v_bot[0] && dut.mesh_tag_v_bot[0]);
        force dut.psum_fifo_full_int = {COLS{1'b1}};
        repeat (12) begin
            @(posedge clk);
            #1;
            if ((psum_fifo_wr_en_dbg & 32'h3) != 0) begin
                $display("ERROR: full FIFO reported an accepted write");
                failures = failures + 1;
            end
            if (array_retired_done) begin
                $display("ERROR: full last write retired its context");
                failures = failures + 1;
            end
        end
        release dut.psum_fifo_full_int;
        if (!fatal_error || !tagged_error_status[25]) begin
            $display("ERROR: full result FIFO did not enter fail-stop");
            failures = failures + 1;
        end
        if (retired_seen != retired_before_full ||
            dut.mesh_epoch_valid_q[1] !== 1'b1) begin
            $display("ERROR: dropped last released mapping retired=%0d/%0d map=%b",
                retired_seen, retired_before_full, dut.mesh_epoch_valid_q);
            failures = failures + 1;
        end

        // Clear the intentional fail-stop before checking the independent
        // invalid-mapping guard below.
        rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // A compact mesh result with no live bank-to-epoch mapping must never
        // enter the full-tag result FIFO.  Inject one post-retirement pair at
        // the mesh boundary to exercise the fail-closed reconstruction path.
        force dut.mesh_tag_v_bot = 4'b0000;
        force dut.valid_v_bot = 4'b0011;
        @(posedge clk);
        #1;
        release dut.valid_v_bot;
        release dut.mesh_tag_v_bot;
        if (!fatal_error || !tagged_error_status[30]) begin
            $display("ERROR: invalid mesh epoch mapping did not fail closed");
            failures = failures + 1;
        end
        if (failures == 0)
            $display("PASS: tagged top exact results/retirement/credits/map guard");
        else begin
            $display("FAIL: tagged top failures=%0d", failures);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        repeat (1000) @(posedge clk);
        $display("FAIL: timeout sent=%0d read=%0d empty=%h fatal=%0d status=%h",
            sent, read_index, psum_fifo_empty, fatal_error,
            tagged_error_status);
        $fatal(1);
    end
endmodule

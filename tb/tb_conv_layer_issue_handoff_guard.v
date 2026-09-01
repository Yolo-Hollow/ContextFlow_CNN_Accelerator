`timescale 1ns / 1ps

// Focused ownership test for conv_layer_top_stream's issue descriptor guard.
//
// The datapath is elaborated with the release tagged/weight-preload/fast-
// handoff switches, but payload and collector activity are intentionally not
// modeled.  Test-only forces inject an already-accepted context event into the
// layer and drive the real systolic_ctrl_tagged ready input.  This keeps the
// production issue_context_active_q / issue_handoff_done_guard_q always block
// and the controller's registered done timing in the loop without requiring a
// full layer stream fixture.
module tb_conv_layer_issue_handoff_guard;
    localparam ROWS = 2;
    localparam COLS = 1;
    localparam IFM_W = 8;
    localparam WEIGHT_W = 8;
    localparam PSUM_W = 32;
    // weight_tile_loader slices [ADDR_W-1:3] for its eight byte banks, so the
    // focused elaboration still needs at least one bank-address bit.
    localparam WGT_TILE_AW = 4;
    localparam PSUM_AW = 2;
    localparam OFM_ADDR_W = 4;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg context_start_drive = 1'b0;
    reg context_admit_drive = 1'b0;
    reg compute_ready_drive = 1'b0;
    reg [7:0] dma_wr_data [0:4];
    wire dut_busy;

    integer pass_count = 0;
    integer fail_count = 0;
    integer idx;

    conv_layer_top_stream #(
        .ROWS(ROWS),
        .COLS(COLS),
        .IFM_W(IFM_W),
        .WEIGHT_W(WEIGHT_W),
        .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(4),
        .IFM_FIFO_AW(2),
        .WGT_FIFO_DEPTH(4),
        .WGT_FIFO_AW(2),
        .PSUM_FIFO_DEPTH(8),
        .PSUM_FIFO_AW(3),
        .FM_W_MAX(1),
        .FM_H_MAX(1),
        .K_TILE(ROWS),
        .COUT_TILE(COLS*2),
        .WGT_TILE_AW(WGT_TILE_AW),
        .PSUM_BUF_AW(PSUM_AW),
        .PSUM_BUF_DEPTH(4),
        .OFM_ADDR_W(OFM_ADDR_W),
        .OFM_FIFO_DEPTH(4),
        .OFM_FIFO_AW(2),
        .ENABLE_VECTOR_ONLY_IFM(1),
        .ENABLE_TAGGED_CONTEXT(1),
        .ENABLE_WEIGHT_PRELOAD(1),
        .ENABLE_FAST_CONTEXT_HANDOFF(1),
        .ENABLE_DETAILED_TRACE(0)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start(1'b0),
        .busy(dut_busy),
        .fm_h(9'd1),
        .fm_w(9'd1),
        .ofm_h(9'd1),
        .ofm_w(9'd1),
        .conv_stride(2'd1),
        .conv_pad(2'd0),
        .kernel_1x1(1'b1),
        .stream_raw_hwc_mode(1'b1),
        .k_total(14'd2),
        .cout_total(11'd2),
        .num_pixels(16'd1),
        .tail_cycles_config(16'd0),
        .raw_hwc_compute_start_level(16'd1),
        .early_drain_enable(1'b0),
        .pass_prefetch_enable(1'b1),
        .psum_stream_overlap_enable(1'b1),
        .continuous_psum_enable(1'b1),
        .column_psum_enable(1'b0),
        .during_compute_prefetch_enable(1'b1),
        .pass_trace_enable(1'b0),
        .pass_trace_cout_block(8'd0),
        .pass_trace_k_pass(16'd0),
        .col_trace_selected_col(5'd0),
        .raw_replay_active(1'b0),
        .tile_oy_base(9'd0),
        .tile_ofm_h(9'd1),
        .tile_pixel_base({OFM_ADDR_W{1'b0}}),
        .pool_enable(1'b0),
        .pool_stride(2'd0),
        .bias_load_done(1'b0),
        .bias_wr_addr(6'd0),
        .bias_wr_data({PSUM_W{1'b0}}),
        .bias_wr_en(1'b0),
        .weight_tile_ready(1'b0),
        .wgt_tile_wr_en(1'b0),
        .wgt_tile_wr_addr({WGT_TILE_AW{1'b0}}),
        .wgt_tile_wr_data({WEIGHT_W{1'b0}}),
        .wgt_tile_wr8_en(1'b0),
        .wgt_tile_wr8_addr({WGT_TILE_AW{1'b0}}),
        .wgt_tile_wr8_data({WEIGHT_W*8{1'b0}}),
        .wgt_tile_wr8_keep(8'd0),
        .dma_bank_wr_en(5'd0),
        .dma_wr_x(9'd0),
        .dma_wr_fy(10'd0),
        .dma_wr_data(dma_wr_data),
        .dma_line_advance(1'b0),
        .vector_ifm_data({ROWS*IFM_W{1'b0}}),
        .vector_ifm_valid(1'b0),
        .vector_packet_done(1'b0),
        .quant_mult_flat({COLS*2{16'd0}}),
        .quant_shift_flat({COLS*2{4'd0}}),
        .quant_zp_flat({COLS*2{8'd0}}),
        .activation_mode(2'd0),
        .act_lut_wr_en(1'b0),
        .act_lut_wr_addr(8'd0),
        .act_lut_wr_data(8'd0),
        .act_lut_rd_addr(8'd0),
        .ofm_mem_wr_ready(1'b1),
        .packed_ofm_packet_ready(1'b1),
        .packed_ofm_busy(1'b0)
    );

    // Keep only the event/timing logic under test live.  The controller is
    // real; these forces replace weight/mesh/payload prerequisites that are
    // orthogonal to issue-descriptor ownership.
    initial begin
        force dut.context_admit_fire = context_admit_drive;
        force dut.prepared_first = 1'b1;
        force dut.prepared_final = 1'b1;
        force dut.prepared_num_pixels = 16'd1;
        force dut.prepared_psum_rd_bank = 1'b0;
        force dut.prepared_psum_wr_bank = 1'b0;
        force dut.compute_context_epoch = 8'h5a;
        force dut.compute_context_bank = 1'b0;

        force dut.u_top.g_tagged_context_core.u_core.start =
            context_start_drive;
        force dut.u_top.g_tagged_context_core.u_core.num_pixels = 16'd1;
        force dut.u_top.g_tagged_context_core.u_core.compute_ready =
            compute_ready_drive;
        force dut.u_top.g_tagged_context_core.u_core.selected_weight_ready =
            1'b1;
        force dut.u_top.g_tagged_context_core.u_core.datapath_fatal = 1'b0;
        force dut.u_top.g_tagged_context_core.u_core.retire_push_ready = 1'b1;
        force dut.u_top.g_tagged_context_core.u_core.mesh_epoch_valid_q = 2'b00;
    end

    task check_bit;
        input got;
        input expected;
        input [8*96-1:0] label;
        begin
            if (got === expected)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s got=%b expected=%b time=%0t",
                         label, got, expected, $time);
            end
        end
    endtask

    task check_preedge;
        input expected_active;
        input expected_guard;
        input expected_done;
        input expected_fire;
        input [8*64-1:0] label;
        begin
            check_bit(dut.issue_context_active_q, expected_active,
                      {label, " active"});
            check_bit(dut.issue_handoff_done_guard_q, expected_guard,
                      {label, " guard"});
            check_bit(dut.compute_done, expected_done,
                      {label, " done"});
            check_bit(dut.compute_fire, expected_fire,
                      {label, " fire"});
        end
    endtask

    task admit_context;
        begin
            context_start_drive = 1'b1;
            context_admit_drive = 1'b1;
        end
    endtask

    task stop_admit;
        begin
            context_start_drive = 1'b0;
            context_admit_drive = 1'b0;
        end
    endtask

    task reset_case;
        begin
            stop_admit();
            compute_ready_drive = 1'b0;
            rst = 1'b1;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            check_preedge(1'b0, 1'b0, 1'b0, 1'b0,
                          "post-reset");
        end
    endtask

    initial begin
        for (idx = 0; idx < 5; idx = idx + 1)
            dma_wr_data[idx] = 8'd0;

        // Case 1: three one-pixel contexts hand off on consecutive issue
        // edges.  C then stalls for one cycle while B's registered done is
        // visible.  That done belongs to B and must not clear C's descriptor.
        reset_case();
        admit_context();
        @(posedge clk);
        #1;
        check_preedge(1'b1, 1'b0, 1'b0, 1'b0,
                      "A admitted");

        @(negedge clk);
        compute_ready_drive = 1'b1;
        #1;
        // B is admitted on A's only/final compute_fire.
        admit_context();
        check_preedge(1'b1, 1'b0, 1'b0, 1'b1,
                      "A-final/B-admit preedge");
        @(posedge clk);
        #1;
        check_preedge(1'b1, 1'b1, 1'b1, 1'b1,
                      "A-final/B-admit postedge");

        // Keep start asserted for the immediately adjacent B-final/C-admit.
        @(negedge clk);
        check_preedge(1'b1, 1'b1, 1'b1, 1'b1,
                      "B-final/C-admit preedge");
        @(posedge clk);
        #1;
        check_preedge(1'b1, 1'b1, 1'b1, 1'b1,
                      "B-final/C-admit postedge");

        // Withdraw C's first ready for one edge.  B's done is high before the
        // edge and the one-cycle guard must consume exactly that completion.
        @(negedge clk);
        stop_admit();
        compute_ready_drive = 1'b0;
        #1;
        check_preedge(1'b1, 1'b1, 1'b1, 1'b0,
                      "C-stall preedge");
        @(posedge clk);
        #1;
        check_preedge(1'b1, 1'b0, 1'b0, 1'b0,
                      "C-stall postedge");

        @(negedge clk);
        compute_ready_drive = 1'b1;
        #1;
        check_preedge(1'b1, 1'b0, 1'b0, 1'b1,
                      "C-final preedge");
        @(posedge clk);
        #1;
        check_preedge(1'b1, 1'b0, 1'b1, 1'b0,
                      "C-final postedge");
        @(posedge clk);
        #1;
        check_preedge(1'b0, 1'b0, 1'b0, 1'b0,
                      "C-done consumed");

        // Case 2: no same-edge replacement.  B is admitted one cycle after
        // A's final fire, exactly while A's registered done is visible.  The
        // admit branch owns the edge, so active stays set without a guard.
        reset_case();
        admit_context();
        @(posedge clk);
        #1;
        check_preedge(1'b1, 1'b0, 1'b0, 1'b0,
                      "delayed A admitted");

        @(negedge clk);
        stop_admit();
        compute_ready_drive = 1'b1;
        #1;
        check_preedge(1'b1, 1'b0, 1'b0, 1'b1,
                      "delayed A final preedge");
        @(posedge clk);
        #1;
        check_preedge(1'b1, 1'b0, 1'b1, 1'b0,
                      "delayed A final postedge");

        @(negedge clk);
        admit_context();
        check_preedge(1'b1, 1'b0, 1'b1, 1'b0,
                      "delayed B admit preedge");
        @(posedge clk);
        #1;
        check_preedge(1'b1, 1'b0, 1'b0, 1'b1,
                      "delayed B admit postedge");

        @(negedge clk);
        stop_admit();
        check_preedge(1'b1, 1'b0, 1'b0, 1'b1,
                      "delayed B final preedge");
        @(posedge clk);
        #1;
        check_preedge(1'b1, 1'b0, 1'b1, 1'b0,
                      "delayed B final postedge");
        @(posedge clk);
        #1;
        check_preedge(1'b0, 1'b0, 1'b0, 1'b0,
                      "delayed B done consumed");

        $display("=== tb_conv_layer_issue_handoff_guard: %0d pass, %0d fail ===",
                 pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "tb_conv_layer_issue_handoff_guard timeout");
    end
endmodule

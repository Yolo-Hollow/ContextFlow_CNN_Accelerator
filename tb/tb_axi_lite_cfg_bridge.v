`timescale 1ns / 1ps

module tb_axi_lite_cfg_bridge;
    reg clk, rst;

    reg  [9:0]  awaddr;
    reg         awvalid;
    wire        awready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;
    reg  [9:0]  araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;

    wire        cfg_wr_en;
    wire [7:0]  cfg_addr;
    wire [31:0] cfg_wdata;
    wire [31:0] cfg_rdata;
    wire        cfg_rd_en;

    reg layer_busy, layer_done;
    wire start_pulse;
    wire datapath_reset_active;
    wire [8:0] fm_h, fm_w, ofm_h, ofm_w;
    wire [1:0] conv_stride, conv_pad, activation_mode;
    wire kernel_1x1;
    wire [13:0] k_total;
    wire [10:0] cout_total;
    wire [15:0] num_pixels;
    wire [8:0] tile_oy_base, tile_ofm_h;
    wire [23:0] tile_pixel_base;
    wire [7:0] input_zero_point;
    wire pool_enable;
    wire [1:0] pool_stride;
    wire [31:0] expected_bytes;
    wire stream_batch_mode;
    wire stream_raw_hwc_mode;
    wire early_drain_enable;
    wire pass_prefetch_enable;
    wire psum_stream_overlap_enable;
    wire continuous_psum_enable;
    wire column_psum_enable;
    wire during_compute_prefetch_enable;
    wire [31:0] stream_bias_packets;
    wire [31:0] stream_weight_packets;
    wire [31:0] stream_ifm_packets;
    wire [15:0] tail_cycles_config;
    wire [15:0] raw_hwc_compute_start_level;
    reg compute_gap_pulse;
    reg preload_commit_pulse;
    reg preload_hit_pulse;
    reg preload_miss_pulse;
    reg eligible_handoff_pulse;
    reg next_cycle_hit_pulse;
    reg extra_gap_pulse;
    reg [5:0] wait_reason_pulse;
    reg protocol_error_pulse;
    wire [31:0] compute_pipe_compute_gap_count;
    wire [31:0] compute_pipe_preload_commit_count;
    wire [31:0] compute_pipe_preload_hit_count;
    wire [31:0] compute_pipe_preload_miss_count;
    wire [31:0] compute_pipe_eligible_handoff_count;
    wire [31:0] compute_pipe_next_cycle_hit_count;
    wire [31:0] compute_pipe_extra_gap_count;
    wire [31:0] compute_pipe_wait_bank_retire_count;
    wire [31:0] compute_pipe_wait_weight_count;
    wire [31:0] compute_pipe_wait_ifm_count;
    wire [31:0] compute_pipe_wait_psum_count;
    wire [31:0] compute_pipe_wait_collector_output_count;
    wire [31:0] compute_pipe_wait_control_count;
    wire [31:0] compute_pipe_protocol_error_count;

    axi_lite_cfg_bridge dut_bridge (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_rdata(cfg_rdata), .cfg_rd_en(cfg_rd_en)
    );

    // Mirror the core-level integration: the datapath-reset window generated
    // by layer_config_regs is the soft reset for cumulative compute-pipeline
    // telemetry.  Distinct counts below prove the complete 0x248..0x27c
    // address ordering instead of only checking the first and last words.
    compute_pipe_telemetry dut_compute_pipe_telemetry (
        .clk(clk), .rst(rst), .soft_reset(datapath_reset_active),
        .compute_gap_pulse(compute_gap_pulse),
        .preload_commit_pulse(preload_commit_pulse),
        .preload_hit_pulse(preload_hit_pulse),
        .preload_miss_pulse(preload_miss_pulse),
        .eligible_handoff_pulse(eligible_handoff_pulse),
        .next_cycle_hit_pulse(next_cycle_hit_pulse),
        .extra_gap_pulse(extra_gap_pulse),
        .wait_reason_pulse(wait_reason_pulse),
        .protocol_error_pulse(protocol_error_pulse),
        .compute_gap_count(compute_pipe_compute_gap_count),
        .preload_commit_count(compute_pipe_preload_commit_count),
        .preload_hit_count(compute_pipe_preload_hit_count),
        .preload_miss_count(compute_pipe_preload_miss_count),
        .eligible_handoff_count(compute_pipe_eligible_handoff_count),
        .next_cycle_hit_count(compute_pipe_next_cycle_hit_count),
        .extra_gap_count(compute_pipe_extra_gap_count),
        .wait_bank_retire_count(compute_pipe_wait_bank_retire_count),
        .wait_weight_count(compute_pipe_wait_weight_count),
        .wait_ifm_count(compute_pipe_wait_ifm_count),
        .wait_psum_count(compute_pipe_wait_psum_count),
        .wait_collector_output_count(
            compute_pipe_wait_collector_output_count),
        .wait_control_count(compute_pipe_wait_control_count),
        .protocol_error_count(compute_pipe_protocol_error_count)
    );

    // Leave CLOCK_HZ at its default here; the descriptor-focused test covers
    // an explicit 200 MHz override independently.
    layer_config_regs #(
        .ENABLE_COLUMN_PSUM(1)
    ) dut_regs (
        .clk(clk), .rst(rst),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_rd_en(cfg_rd_en), .cfg_rdata(cfg_rdata),
        .layer_busy(layer_busy), .layer_done(layer_done),
        .dbg_expected_bytes(32'd0), .dbg_core_wr_count(32'd0),
        .dbg_axis_wr_count(32'd0), .dbg_tlast_count(32'd0),
        .dbg_last_tlast_index(32'd0),
        .perf_wait_bias(1'b0), .perf_wait_weight(1'b0),
        .perf_wait_ifm(1'b0), .perf_wait_ofm(1'b0),
        .perf_compute_fire(1'b0),
        .perf_stage_bias(1'b0),
        .perf_stage_weight(1'b0),
        .perf_stage_feeder(1'b0),
        .perf_stage_compute(1'b0),
        .perf_stage_drain(1'b0),
        .perf_stage_ofm_post(1'b0),
        .perf_feed_fill_wait(1'b0),
        .perf_feed_push(1'b0),
        .perf_feed_fifo_stall(1'b0),
        .perf_feed_win_not_ready(1'b0),
        .perf_comp_wload(1'b0),
        .perf_comp_active(1'b0),
        .perf_comp_ifm_stall(1'b0),
        .perf_comp_tail(1'b0),
        .perf_tail_cycles_configured(32'd138),
        .perf_drain_fifo_empty_wait(1'b0),
        .perf_drain_fifo_empty_sticky(1'b0),
        .perf_drain_read_fire(1'b0),
        .perf_drain_packet_fire(1'b0),
        .perf_drain_ready_stall(1'b0),
        .perf_drain_internal_full_wait(1'b0),
        .perf_prefetch_start(1'b0),
        .perf_prefetch_weight_done(1'b0),
        .perf_prefetch_feed_done(1'b0),
        .perf_prefetch_hit(1'b0),
        .perf_prefetch_miss(1'b0),
        .perf_prefetch_stall(1'b0),
        .stream_bias_completed(32'd7),
        .stream_weight_completed(32'd11),
        .stream_ifm_completed(32'd13),
        .vector_completed_packets(32'd0),
        .vector_completed_pixels(32'd0),
        .vector_accepted_beats(32'd0),
        .vector_fifo_stall_cycles(32'd0),
        .raw_hwc_load_active_cycles(32'd0),
        .raw_hwc_load_unpack_cycles(32'd0),
        .raw_hwc_replay_active_cycles(32'd0),
        .raw_hwc_replay_wait_ready_cycles(32'd0),
        .context_alloc_count(32'd501),
        .context_input_issued_count(32'd502),
        .context_array_retired_count(32'd503),
        .context_collector_done_count(32'd504),
        .context_gap_cycles(32'd505),
        .context_ifm_ownership_stall_cycles(32'd506),
        .context_weight_ownership_stall_cycles(32'd507),
        .context_psum_credit_stall_cycles(32'd508),
        .context_epoch_mismatch_count(32'd509),
        .context_mismatch_count(32'd510),
        .context_ifm_underflow_count(32'd511),
        .context_psum_underflow_count(32'd512),
        .context_fifo_drop_count(32'd513),
        .context_bank_overwrite_count(32'd514),
        .context_full_stall_cycles(32'd515),
        .compute_pipe_compute_gap_count(compute_pipe_compute_gap_count),
        .compute_pipe_preload_commit_count(
            compute_pipe_preload_commit_count),
        .compute_pipe_preload_hit_count(compute_pipe_preload_hit_count),
        .compute_pipe_preload_miss_count(compute_pipe_preload_miss_count),
        .compute_pipe_eligible_handoff_count(
            compute_pipe_eligible_handoff_count),
        .compute_pipe_next_cycle_hit_count(
            compute_pipe_next_cycle_hit_count),
        .compute_pipe_extra_gap_count(compute_pipe_extra_gap_count),
        .compute_pipe_wait_bank_retire_count(
            compute_pipe_wait_bank_retire_count),
        .compute_pipe_wait_weight_count(compute_pipe_wait_weight_count),
        .compute_pipe_wait_ifm_count(compute_pipe_wait_ifm_count),
        .compute_pipe_wait_psum_count(compute_pipe_wait_psum_count),
        .compute_pipe_wait_collector_output_count(
            compute_pipe_wait_collector_output_count),
        .compute_pipe_wait_control_count(compute_pipe_wait_control_count),
        .compute_pipe_protocol_error_count(
            compute_pipe_protocol_error_count),
        .start_pulse(start_pulse),
        .datapath_reset_active(datapath_reset_active),
        .fm_h(fm_h), .fm_w(fm_w), .ofm_h(ofm_h), .ofm_w(ofm_w),
        .conv_stride(conv_stride), .conv_pad(conv_pad),
        .kernel_1x1(kernel_1x1),
        .activation_mode(activation_mode),
        .k_total(k_total), .cout_total(cout_total), .num_pixels(num_pixels),
        .tile_oy_base(tile_oy_base), .tile_ofm_h(tile_ofm_h),
        .tile_pixel_base(tile_pixel_base),
        .input_zero_point(input_zero_point),
        .pool_enable(pool_enable), .pool_stride(pool_stride),
        .expected_bytes(expected_bytes),
        .stream_batch_mode(stream_batch_mode),
        .stream_raw_hwc_mode(stream_raw_hwc_mode),
        .early_drain_enable(early_drain_enable),
        .pass_prefetch_enable(pass_prefetch_enable),
        .psum_stream_overlap_enable(psum_stream_overlap_enable),
        .continuous_psum_enable(continuous_psum_enable),
        .column_psum_enable(column_psum_enable),
        .during_compute_prefetch_enable(during_compute_prefetch_enable),
        .stream_bias_packets(stream_bias_packets),
        .stream_weight_packets(stream_weight_packets),
        .stream_ifm_packets(stream_ifm_packets),
        .tail_cycles_config(tail_cycles_config),
        .raw_hwc_compute_start_level(raw_hwc_compute_start_level),
        .config_error()
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer start_pulse_count;
    integer count_before;
    integer telemetry_index;
    reg [31:0] rd;

    always @(posedge clk) begin
        if (rst)
            start_pulse_count <= 0;
        else if (start_pulse)
            start_pulse_count <= start_pulse_count + 1;
    end

    task axi_write;
        input [9:0] addr;
        input [31:0] data;
        input [3:0] strb;
        begin
            @(negedge clk);
            awaddr = addr;
            wdata = data;
            wstrb = strb;
            awvalid = 1'b1;
            wvalid = 1'b1;
            wait(awready && wready);
            @(negedge clk);
            awvalid = 1'b0;
            wvalid = 1'b0;
            wait(bvalid);
            if (bresp !== 2'b00) begin
                $display("[FAIL] write bresp addr=%h resp=%b", addr, bresp);
                fail = fail + 1;
            end else pass = pass + 1;
            @(negedge clk);
        end
    endtask

    task axi_write_split;
        input [9:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            awaddr = addr;
            awvalid = 1'b1;
            wait(awready);
            @(negedge clk);
            awvalid = 1'b0;
            repeat (2) @(negedge clk);
            wdata = data;
            wstrb = 4'hf;
            wvalid = 1'b1;
            wait(wready);
            @(negedge clk);
            wvalid = 1'b0;
            wait(bvalid);
            if (bresp !== 2'b00) begin
                $display("[FAIL] split write bresp addr=%h resp=%b", addr, bresp);
                fail = fail + 1;
            end else pass = pass + 1;
            @(negedge clk);
        end
    endtask

    task axi_write_split_wfirst;
        input [9:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            wdata = data;
            wstrb = 4'hf;
            wvalid = 1'b1;
            wait(wready);
            @(negedge clk);
            wvalid = 1'b0;
            repeat (2) @(negedge clk);
            awaddr = addr;
            awvalid = 1'b1;
            wait(awready);
            @(negedge clk);
            awvalid = 1'b0;
            wait(bvalid);
            if (bresp !== 2'b00) begin
                $display("[FAIL] split wfirst write bresp addr=%h resp=%b", addr, bresp);
                fail = fail + 1;
            end else pass = pass + 1;
            @(negedge clk);
        end
    endtask

    task axi_read;
        input [9:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            araddr = addr;
            arvalid = 1'b1;
            @(posedge clk);
            while (!arready)
                @(posedge clk);
            @(negedge clk);
            arvalid = 1'b0;
            wait(rvalid);
            data = rdata;
            if (rresp !== 2'b00) begin
                $display("[FAIL] read rresp addr=%h resp=%b", addr, rresp);
                fail = fail + 1;
            end else pass = pass + 1;
            @(negedge clk);
        end
    endtask

    task check_eq;
        input [31:0] got;
        input [31:0] exp;
        input [127:0] name;
        begin
            if (got !== exp) begin
                $display("[FAIL] %0s got=%h exp=%h", name, got, exp);
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    task populate_compute_pipe_telemetry;
        integer event_index;
        integer wait_index;
        integer wait_repeat;
        begin
            // Scalar counters become 7,6,5,4,3,2,1 respectively.
            for (event_index = 0; event_index < 7;
                 event_index = event_index + 1) begin
                @(negedge clk);
                compute_gap_pulse = 1'b1;
                preload_commit_pulse = event_index < 6;
                preload_hit_pulse = event_index < 5;
                preload_miss_pulse = event_index < 4;
                eligible_handoff_pulse = event_index < 3;
                next_cycle_hit_pulse = event_index < 2;
                extra_gap_pulse = event_index < 1;
            end
            @(negedge clk);
            compute_gap_pulse = 1'b0;
            preload_commit_pulse = 1'b0;
            preload_hit_pulse = 1'b0;
            preload_miss_pulse = 1'b0;
            eligible_handoff_pulse = 1'b0;
            next_cycle_hit_pulse = 1'b0;
            extra_gap_pulse = 1'b0;

            // The six one-hot wait counters become 1..6.
            for (wait_index = 0; wait_index < 6;
                 wait_index = wait_index + 1)
                for (wait_repeat = 0; wait_repeat <= wait_index;
                     wait_repeat = wait_repeat + 1) begin
                    @(negedge clk);
                    wait_reason_pulse = 6'b000001 << wait_index;
                end
            @(negedge clk);
            wait_reason_pulse = 6'b000000;

            // The final counter is seven, giving every adjacent register a
            // distinct expected value across the whole block.
            repeat (7) begin
                @(negedge clk);
                protocol_error_pulse = 1'b1;
            end
            @(negedge clk);
            protocol_error_pulse = 1'b0;
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        awaddr = 8'd0;
        awvalid = 1'b0;
        wdata = 32'd0;
        wstrb = 4'h0;
        wvalid = 1'b0;
        bready = 1'b1;
        araddr = 8'd0;
        arvalid = 1'b0;
        rready = 1'b1;
        layer_busy = 1'b0;
        layer_done = 1'b0;
        compute_gap_pulse = 1'b0;
        preload_commit_pulse = 1'b0;
        preload_hit_pulse = 1'b0;
        preload_miss_pulse = 1'b0;
        eligible_handoff_pulse = 1'b0;
        next_cycle_hit_pulse = 1'b0;
        extra_gap_pulse = 1'b0;
        wait_reason_pulse = 6'b000000;
        protocol_error_pulse = 1'b0;
        pass = 0;
        fail = 0;
        start_pulse_count = 0;

        repeat (4) @(negedge clk);
        rst = 0;
        populate_compute_pipe_telemetry();

        axi_write(8'h04, {7'd0, 9'd5, 7'd0, 9'd7}, 4'hf);
        axi_read(8'h04, rd);
        check_eq(rd, {7'd0, 9'd5, 7'd0, 9'd7}, "fm_size");
        check_eq({23'd0, fm_h}, 32'd7, "fm_h");
        check_eq({23'd0, fm_w}, 32'd5, "fm_w");

        axi_write(8'h04, 32'd8, 4'h1);
        axi_read(8'h04, rd);
        check_eq(rd, {7'd0, 9'd5, 7'd0, 9'd8}, "fm_size partial wstrb");

        axi_write_split(8'h08, {7'd0, 9'd3, 7'd0, 9'd4});
        axi_read(8'h08, rd);
        check_eq(rd, {7'd0, 9'd3, 7'd0, 9'd4}, "ofm_size");

        axi_write_split_wfirst(8'h08, {7'd0, 9'd6, 7'd0, 9'd7});
        axi_read(8'h08, rd);
        check_eq(rd, {7'd0, 9'd6, 7'd0, 9'd7}, "ofm_size wfirst");

        axi_write(8'h0c, {22'd0, 2'd1, 6'd0, 2'd2}, 4'hf);
        axi_write(8'h10, 32'd9216, 4'hf);
        axi_write(8'h14, 32'd10, 4'hf);
        axi_write(8'h18, 32'd12, 4'hf);
        axi_write(8'h1c, 32'd2, 4'hf);
        axi_write(8'h20, {7'd0, 9'd3, 7'd0, 9'd2}, 4'hf);
        axi_write(8'h24, 32'd6, 4'hf);
        axi_write(8'h3c, 32'd36, 4'hf);
        axi_write(8'h40, {28'd0, 2'd2, 1'b0, 1'b1}, 4'hf);
        axi_write(8'h64, 32'd255, 4'hf);
        axi_write(8'h68, 32'd7, 4'hf);
        axi_write(8'h6c, 32'd11, 4'hf);
        axi_write(8'h70, 32'd13, 4'hf);
        axi_read(8'h64, rd);
        check_eq(rd, 32'd255, "stream cfg read");
        check_eq({31'd0, stream_batch_mode}, 32'd1, "stream batch output");
        check_eq({31'd0, stream_raw_hwc_mode}, 32'd1, "stream raw hwc output");
        check_eq({31'd0, early_drain_enable}, 32'd1, "early drain output");
        check_eq({31'd0, pass_prefetch_enable}, 32'd1, "pass prefetch output");
        check_eq({31'd0, psum_stream_overlap_enable}, 32'd1, "psum stream overlap output");
        check_eq({31'd0, continuous_psum_enable}, 32'd1, "continuous psum output");
        check_eq({31'd0, column_psum_enable}, 32'd1, "column psum output");
        check_eq({31'd0, during_compute_prefetch_enable}, 32'd1, "during compute prefetch output");
        axi_read(8'h74, rd);
        check_eq(rd, 32'd7, "stream bias completed read");
        axi_read(8'h78, rd);
        check_eq(rd, 32'd11, "stream weight completed read");
        axi_read(8'h7c, rd);
        check_eq(rd, 32'd13, "stream ifm completed read");
        axi_read(8'ha0, rd);
        check_eq(rd, 32'd0, "stage bias counter read");
        axi_read(8'hb8, rd);
        check_eq(rd, 32'd0, "feed fill counter read");
        axi_read(8'hd0, rd);
        check_eq(rd, 32'd0, "comp fire counter read");
        axi_read(8'hdc, rd);
        check_eq(rd, 32'd2, "subperf version read");
        axi_read(9'h110, rd);
        check_eq(rd, 32'd1, "drainperf version read");
        axi_read(8'he0, rd);
        check_eq(rd, {16'd0, 16'd138}, "tail config read");
        axi_read(8'h3c, rd);
        check_eq(rd, 32'd36, "input_zero_point read");
        check_eq({24'd0, input_zero_point}, 32'd36, "input_zero_point output");

        axi_read(10'h200, rd);
        check_eq(rd, 32'd2, "context telemetry version high-address decode");
        axi_read(10'h204, rd);
        check_eq(rd, 32'd501, "context alloc high-address decode");
        axi_read(10'h23c, rd);
        check_eq(rd, 32'd515, "context-full stall high-address decode");
        axi_read(10'h244, rd);
        check_eq(rd, 32'd1, "compute-pipe version high-address decode");
        for (telemetry_index = 0; telemetry_index < 14;
             telemetry_index = telemetry_index + 1) begin
            axi_read(10'h248 + telemetry_index*4, rd);
            if (telemetry_index < 7)
                check_eq(rd, 32'd7 - telemetry_index,
                         "compute-pipe counter high-address decode");
            else if (telemetry_index < 13)
                check_eq(rd, telemetry_index - 6,
                         "compute-pipe counter high-address decode");
            else
                check_eq(rd, 32'd7,
                     "compute-pipe counter high-address decode");
        end

        axi_read(8'h40, rd);
        check_eq(rd, {28'd0, 2'd2, 1'b0, 1'b1}, "pool cfg read");
        check_eq({31'd0, pool_enable}, 32'd1, "pool_enable output");
        check_eq({30'd0, pool_stride}, 32'd2, "pool_stride output");

        axi_write(8'h3c, 32'h0000_5500, 4'h2);
        axi_read(8'h3c, rd);
        check_eq(rd, 32'd36, "input_zero_point upper-byte partial keeps low byte");

        axi_write(8'h3c, 32'd42, 4'h1);
        axi_read(8'h3c, rd);
        check_eq(rd, 32'd42, "input_zero_point lower-byte partial");

        check_eq({30'd0, conv_pad, 6'd0, conv_stride}, {22'd0, 2'd1, 6'd0, 2'd2}, "conv");
        check_eq({18'd0, k_total}, 32'd9216, "k_total");
        check_eq({21'd0, cout_total}, 32'd10, "cout_total");
        check_eq({16'd0, num_pixels}, 32'd12, "num_pixels");
        check_eq({30'd0, activation_mode}, 32'd2, "activation");
        check_eq({23'd0, tile_oy_base}, 32'd2, "tile_oy_base");
        check_eq({23'd0, tile_ofm_h}, 32'd3, "tile_ofm_h");
        check_eq({8'd0, tile_pixel_base}, 32'd6, "tile_pixel_base");

        axi_write(8'h00, 32'd1, 4'hf);
        repeat (2) @(negedge clk);
        if (start_pulse_count != 1) begin
            $display("[FAIL] start_pulse count got=%0d exp=1", start_pulse_count);
            fail = fail + 1;
        end else pass = pass + 1;
        if (start_pulse !== 1'b0) begin
            $display("[FAIL] start_pulse should be one cycle");
            fail = fail + 1;
        end else pass = pass + 1;

        @(negedge clk);
        layer_busy = 1'b1;
        layer_done = 1'b1;
        @(negedge clk);
        layer_done = 1'b0;
        axi_read(8'h00, rd);
        check_eq(rd[1:0], 2'b11, "status busy_done");

        axi_write(8'h00, 32'd2, 4'hf);
        axi_read(8'h00, rd);
        check_eq(rd[1], 1'b0, "done clear");

        count_before = start_pulse_count;
        layer_busy = 1'b1;
        axi_write(8'h00, 32'h0000_0100, 4'h2);
        repeat (2) @(negedge clk);
        if (start_pulse_count != count_before) begin
            $display("[FAIL] ctrl upper-byte partial write caused start count=%0d exp=%0d",
                     start_pulse_count, count_before);
            fail = fail + 1;
        end else pass = pass + 1;

        axi_write(8'h04, {7'd0, 9'd99, 7'd0, 9'd88}, 4'hf);
        axi_read(8'h04, rd);
        check_eq(rd, {7'd0, 9'd5, 7'd0, 9'd8}, "busy freezes fm_size");

        axi_write(8'h3c, 32'd99, 4'hf);
        axi_read(8'h3c, rd);
        check_eq(rd, 32'd42, "busy freezes input_zero_point");

        axi_write(8'h40, 32'd0, 4'hf);
        axi_read(8'h40, rd);
        check_eq(rd, {28'd0, 2'd2, 1'b0, 1'b1}, "busy freezes pool cfg");

        axi_write(8'h00, 32'd1, 4'h1);
        repeat (2) @(negedge clk);
        if (start_pulse_count != count_before) begin
            $display("[FAIL] busy ctrl start count=%0d exp=%0d",
                     start_pulse_count, count_before);
            fail = fail + 1;
        end else pass = pass + 1;

        layer_busy = 1'b0;
        axi_write(8'h00, 32'd1, 4'h1);
        repeat (2) @(negedge clk);
        if (start_pulse_count != count_before + 1) begin
            $display("[FAIL] idle ctrl start count=%0d exp=%0d",
                     start_pulse_count, count_before + 1);
            fail = fail + 1;
        end else pass = pass + 1;

        // 0x240 is the first register above the context telemetry block.
        // Exercise it through AXI-Lite to cover the full ten-bit decode and
        // prove that reset has priority over a simultaneous start request.
        axi_read(10'h240, rd);
        check_eq(rd, 32'd0, "initial datapath reset count");
        count_before = start_pulse_count;
        axi_write(10'h000, 32'h0000_0005, 4'h1);
        repeat (6) @(negedge clk);
        axi_read(10'h240, rd);
        check_eq(rd, 32'd1, "datapath reset count high-address decode");
        check_eq(start_pulse_count, count_before,
                 "AXI datapath reset wins over start");
        axi_read(10'h004, rd);
        check_eq(rd, {7'd0, 9'd5, 7'd0, 9'd8},
                 "AXI datapath reset preserves configuration");
        check_eq(datapath_reset_active, 1'b0,
                 "AXI datapath reset completes");
        axi_read(10'h248, rd);
        check_eq(rd, 32'd0, "datapath reset clears compute-gap telemetry");
        axi_read(10'h27c, rd);
        check_eq(rd, 32'd0,
                 "datapath reset clears compute-pipe protocol telemetry");
        axi_read(10'h244, rd);
        check_eq(rd, 32'd1, "datapath reset preserves telemetry version");
        axi_read(10'h280, rd);
        check_eq(rd, 32'd100000000,
                 "AXI 0x280 returns default 100 MHz CLOCK_HZ");

        $display("=== tb_axi_lite_cfg_bridge: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (1000) @(negedge clk);
        $display("[FAIL] timeout awready=%b wready=%b arready=%b bvalid=%b rvalid=%b wr_state=%b rd_state=%b aw_hold=%b w_hold=%b cfg_addr=%h",
                 awready, wready, arready, bvalid, rvalid,
                 dut_bridge.wr_state, dut_bridge.rd_state,
                 dut_bridge.aw_hold_valid, dut_bridge.w_hold_valid, cfg_addr);
        $fatal(1);
    end
endmodule

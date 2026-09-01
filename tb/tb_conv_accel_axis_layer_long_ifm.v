`timescale 1ns / 1ps

// Small integration smoke for the compile-time layer-long raw-HWC branch.
// It isolates the AXIS wrapper from arithmetic by forcing the feeder-shaped
// request/ready nets, while retaining the real materializer, tile cache,
// epoch capture, active-tile address mapping, and held release handshake.
module tb_conv_accel_axis_layer_long_ifm;
    localparam integer ROWS = 18;
    localparam integer COLS = 2;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg ifm_valid = 1'b0;
    reg [63:0] ifm_data = 64'd0;
    reg [7:0] ifm_keep = 8'd0;
    reg ifm_last = 1'b0;
    wire ifm_ready;
    wire ifm_axis_error;

    reg forced_stream_reset = 1'b0;
    reg forced_fill_req = 1'b0;
    reg forced_vector_ready = 1'b1;
    reg [8:0] forced_tile_oy_base = 9'd0;
    reg [23:0] forced_tile_output_pixel_base = 24'd0;
    reg [15:0] forced_tile_pixels = 16'd4;
    reg [15:0] forced_tile_index = 16'd0;
    reg forced_tile_done = 1'b0;
    reg forced_pool_enable = 1'b0;
    reg [1:0] forced_pool_stride = 2'd0;

    integer checks = 0;
    integer failures = 0;
    integer replay_seen = 0;
    integer expected_replay_base = 0;
    integer expected_replay_count = 0;
    reg replay_score_active = 1'b0;
    reg saw_release_valid = 1'b0;
    integer lane;
    integer expected_byte;

    conv_accel_core_axi_lite_axis_stream #(
        .ROWS(ROWS), .COLS(COLS), .K_TILE(ROWS),
        .COUT_TILE(COLS*2), .IFM_BANKS(2),
        .IFM_FIFO_DEPTH(16), .IFM_FIFO_AW(4),
        .WGT_FIFO_DEPTH(16), .WGT_FIFO_AW(4),
        .PSUM_FIFO_DEPTH(16), .PSUM_FIFO_AW(4),
        .FM_W_MAX(8), .FM_H_MAX(8),
        .WGT_TILE_AW(7), .PSUM_BUF_AW(4),
        .PSUM_BUF_DEPTH(16),
        .OFM_FIFO_DEPTH(8), .OFM_FIFO_AW(3),
        .HWC_CACHE_AW(6), .HWC_CACHE_DEPTH(64),
        .MATERIALIZED_CACHE_AW(6),
        .MATERIALIZED_CACHE_DEPTH(64),
        .ENABLE_LAYER_TILE_SEQUENCER(1),
        .ENABLE_LAYER_LONG_HWC_IFM(1)
    ) dut (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(10'd0), .s_axi_awvalid(1'b0),
        .s_axi_wdata(32'd0), .s_axi_wstrb(4'd0),
        .s_axi_wvalid(1'b0), .s_axi_bready(1'b1),
        .s_axi_araddr(10'd0), .s_axi_arvalid(1'b0),
        .s_axi_rready(1'b1),
        .bias_s_axis_tvalid(1'b0),
        .bias_s_axis_tdata(64'd0), .bias_s_axis_tkeep(8'd0),
        .bias_s_axis_tlast(1'b0),
        .weight_s_axis_tvalid(1'b0),
        .weight_s_axis_tdata(64'd0), .weight_s_axis_tkeep(8'd0),
        .weight_s_axis_tlast(1'b0),
        .ifm_line_words(9'd2),
        .ifm_s_axis_tready(ifm_ready),
        .ifm_s_axis_tvalid(ifm_valid),
        .ifm_s_axis_tdata(ifm_data),
        .ifm_s_axis_tkeep(ifm_keep),
        .ifm_s_axis_tlast(ifm_last),
        .ofm_m_axis_tready(1'b1),
        .ifm_axis_error(ifm_axis_error)
    );

    // Drive the wrapper/core boundary directly. This keeps the smoke small
    // while still elaborating the complete parameter-1 generate branch.
    initial begin
        force dut.configured_stream_raw_hwc_mode = 1'b1;
        force dut.configured_stream_reset = forced_stream_reset;
        force dut.configured_fm_h = 9'd3;
        force dut.configured_fm_w = 9'd2;
        force dut.configured_ofm_h = 9'd3;
        force dut.configured_ofm_w = 9'd2;
        force dut.configured_tile_h_max = 9'd2;
        force dut.configured_kernel_1x1 = 1'b1;
        force dut.configured_k_total = 14'd4;
        force dut.configured_conv_stride = 2'd1;
        force dut.configured_conv_pad = 2'd0;
        force dut.configured_pool_enable = forced_pool_enable;
        force dut.configured_pool_stride = forced_pool_stride;
        force dut.configured_input_zero_point = 8'd0;
        force dut.configured_ifm_total_bytes = 32'd24;
        // This smoke bypasses the descriptor validator and drives the
        // wrapper/core boundary directly, so its validator-owned release
        // metadata must be forced with the configured geometry as well.
        force dut.validated_long_cin = 14'd4;
        force dut.validated_long_pass_count = 16'd1;
        force dut.validated_long_final_pass = 16'd0;
        force dut.validated_long_final_lane_mask = 18'h0000f;
        force dut.validated_long_layer_pixels = 32'd6;
        force dut.validated_long_tile_pixels = 32'd4;
        force dut.feeder_fill_req = forced_fill_req;
        force dut.current_feeder_pass_base_k = 14'd0;
        force dut.current_feeder_k_pass = 16'd0;
        force dut.vector_ifm_ready = forced_vector_ready;
        force dut.active_tile_oy_base = forced_tile_oy_base;
        force dut.active_tile_output_pixel_base =
            forced_tile_output_pixel_base;
        force dut.active_tile_num_pixels = forced_tile_pixels;
        force dut.active_tile_index = forced_tile_index;
        force dut.active_tile_done = forced_tile_done;
    end

    task check;
        input condition;
        input [8*128-1:0] label;
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $display("[FAIL] %0s", label);
            end
        end
    endtask

    task send_layer_frame;
        integer beat;
        integer byte_i;
        integer raw_index;
        reg [63:0] beat_word;
        begin
            raw_index = 0;
            for (beat = 0; beat < 3; beat = beat + 1) begin
                beat_word = 64'd0;
                for (byte_i = 0; byte_i < 8; byte_i = byte_i + 1) begin
                    beat_word[byte_i*8 +: 8] = raw_index + 1;
                    raw_index = raw_index + 1;
                end
                @(negedge clk);
                ifm_data = beat_word;
                ifm_keep = 8'hff;
                ifm_last = (beat == 2);
                ifm_valid = 1'b1;
                @(posedge clk);
                while (!ifm_ready)
                    @(posedge clk);
                @(negedge clk);
                ifm_valid = 1'b0;
                ifm_data = 64'd0;
                ifm_keep = 8'd0;
                ifm_last = 1'b0;
            end
        end
    endtask

    task replay_tile;
        input integer pixel_base;
        input integer pixel_count;
        integer timeout;
        begin
            expected_replay_base = pixel_base;
            expected_replay_count = pixel_count;
            replay_seen = 0;
            replay_score_active = 1'b1;
            @(negedge clk);
            forced_fill_req = 1'b1;
            timeout = 0;
            while (!dut.raw_hwc_packet_done && timeout < 200) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            @(negedge clk);
            forced_fill_req = 1'b0;
            replay_score_active = 1'b0;
            check(timeout < 200, "replay request completed");
            check(replay_seen == pixel_count,
                  "replay emitted exact tile pixel count");
            repeat (2) @(posedge clk);
        end
    endtask

    task retire_tile;
        input integer tile_index;
        integer timeout;
        begin
            forced_tile_index = tile_index;
            saw_release_valid = 1'b0;
            @(negedge clk);
            forced_tile_done = 1'b1;
            @(negedge clk);
            forced_tile_done = 1'b0;
            timeout = 0;
            while (dut.layer_long_release_valid && timeout < 20) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            repeat (2) @(posedge clk);
            check(saw_release_valid, "tile done became held release request");
            check(!dut.layer_long_release_valid,
                  "matching cache owner acknowledged release");
        end
    endtask

    always @(posedge clk) begin
        if (dut.layer_long_release_valid)
            saw_release_valid <= 1'b1;

        if (replay_score_active && dut.raw_hwc_ifm_valid &&
            dut.vector_ifm_ready) begin
            for (lane = 0; lane < ROWS; lane = lane + 1) begin
                expected_byte = (lane < 4) ?
                    (((expected_replay_base + replay_seen) * 4) + lane + 1) : 0;
                if (dut.raw_hwc_ifm_data[lane*8 +: 8] !==
                    expected_byte[7:0]) begin
                    failures = failures + 1;
                    $display("[FAIL] replay byte pixel=%0d lane=%0d got=%02x exp=%02x",
                             expected_replay_base + replay_seen, lane,
                             dut.raw_hwc_ifm_data[lane*8 +: 8],
                             expected_byte[7:0]);
                end
            end
            replay_seen = replay_seen + 1;
        end
    end

    initial begin
        repeat (5) @(negedge clk);
        rst = 1'b0;
        force dut.u_core.u_core.cfg_addr = 7'h78;
        #1;
        check(dut.u_core.u_core.layer_cfg_rdata == 32'h0504_0212,
              "capability advertises HWC/layer-long but withholds token epoch");
        release dut.u_core.u_core.cfg_addr;
        forced_tile_output_pixel_base = 24'd17;
        #1;
        check(dut.layer_long_fill_pixel_base == 32'd17,
              "unpooled fill base reuses sequencer output base");
        forced_pool_enable = 1'b1;
        forced_pool_stride = 2'd2;
        forced_tile_output_pixel_base = 24'd3;
        #1;
        check(dut.layer_long_fill_pixel_base == 32'd12,
              "2x2 pooled fill base reconstructs pre-pool pixel base");
        forced_pool_enable = 1'b0;
        forced_pool_stride = 2'd0;
        forced_tile_output_pixel_base = 24'd0;
        @(negedge clk);
        forced_stream_reset = 1'b1;
        @(negedge clk);
        forced_stream_reset = 1'b0;

        send_layer_frame();
        wait(dut.raw_hwc_load_unpack_cycles == 32'd6);
        check(dut.raw_hwc_accepted_beats == 3,
              "one layer-long AXIS frame accepted three beats");
        check(!ifm_axis_error, "materializer/cache integration error-free");

        forced_tile_oy_base = 0;
        forced_tile_output_pixel_base = 0;
        forced_tile_pixels = 4;
        forced_tile_index = 0;
        replay_tile(0, 4);
        retire_tile(0);

        forced_tile_oy_base = 2;
        forced_tile_output_pixel_base = 4;
        forced_tile_pixels = 2;
        forced_tile_index = 1;
        replay_tile(4, 2);
        retire_tile(1);

        check(dut.raw_hwc_completed_packets == 2,
              "two tile replay packets completed");
        check(dut.raw_hwc_completed_pixels == 6,
              "all six layer pixels replayed exactly once");
        check(dut.layer_long_epoch == 8'd1,
              "layer start advanced epoch exactly once");
        check(dut.layer_long_cache_error_status == 5'd0,
              "cache ownership/context scoreboard remained clean");
        check(!ifm_axis_error, "final IFM protocol status remained clean");

        if (failures == 0)
            $display("[PASS] tb_conv_accel_axis_layer_long_ifm checks=%0d",
                     checks);
        else
            $display("[FAIL] tb_conv_accel_axis_layer_long_ifm failures=%0d checks=%0d",
                     failures, checks);
        $finish;
    end

    initial begin
        #200000;
        $display("[FAIL] tb_conv_accel_axis_layer_long_ifm timeout ready=%0b valid=%0b beats=%0d bytes=%0d entries=%0d busy=%0b input_done=%0b fifo=%0b defer=%0b cfgerr=%0b cache=%0h",
                 ifm_ready, ifm_valid, dut.raw_hwc_accepted_beats,
                 dut.g_layer_long_hwc_ifm.u_layer_long_replay.accepted_axis_bytes,
                 dut.raw_hwc_load_unpack_cycles,
                 dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_materializer.busy_q,
                 dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_materializer.input_done,
                  |dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_materializer.beat_fifo_valid_q,
                 dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_materializer.defer_valid_q,
                 dut.g_layer_long_hwc_ifm.materializer_config_error,
                 dut.layer_long_cache_error_status);
        $finish;
    end
endmodule

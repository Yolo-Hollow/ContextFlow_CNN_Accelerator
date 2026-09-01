`timescale 1ns / 1ps

// Startup guard for the ABI-v2 layer-long descriptor.  The test deliberately
// leaves unrelated telemetry inputs unconnected: layer_busy is held low, so
// none of those counters participates in the control/status checks below.
module tb_layer_long_descriptor_validation;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg cfg_wr_en = 1'b0;
    reg [7:0] cfg_addr = 8'd0;
    reg [31:0] cfg_wdata = 32'd0;
    wire [31:0] cfg_rdata;
    wire start_pulse;
    wire config_error;
    wire [13:0] validated_long_cin;
    wire [15:0] validated_long_pass_count;
    wire [15:0] validated_long_final_pass;
    wire [17:0] validated_long_final_lane_mask;
    wire [31:0] validated_long_layer_pixels;
    wire [31:0] validated_long_tile_pixels;
    wire [31:0] validated_long_tile_output_pixels;
    wire [15:0] validated_long_cout_blocks;

    integer checks = 0;
    integer failures = 0;
    integer start_count = 0;
    integer validation_timeout = 0;
    integer expected_release_cin = 0;
    integer expected_release_pass_count = 0;
    integer expected_release_final_pass = 0;
    integer expected_release_final_lane_mask = 0;
    integer expected_release_layer_pixels = 0;
    integer expected_release_tile_pixels = 0;
    integer expected_release_tile_output_pixels = 0;
    integer expected_release_cout_blocks = 0;
    integer reciprocal_k = 0;
    reg [25:0] reciprocal_product = 26'd0;
    reg reciprocal_exact = 1'b1;

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (rst)
            start_count <= 0;
        else if (start_pulse)
            start_count <= start_count + 1;
    end

    layer_config_regs #(
        .CLOCK_HZ(200000000),
        .IFM_FIFO_DEPTH(1024),
        .ROWS(18), .COLS(16), .COUT_TILE(32),
        .FM_W_MAX(416), .FM_H_MAX(416), .PSUM_BUF_DEPTH(1024),
        .MATERIALIZED_CACHE_DEPTH(32768),
        .PACKED_OFM_BUFFER_DEPTH(4096),
        .ENABLE_PACKED_HWC_OFM(1),
        .ENABLE_LAYER_TILE_SEQUENCER(1),
        .ENABLE_LAYER_LONG_HWC_IFM(1)
    ) dut (
        .clk(clk), .rst(rst),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata), .cfg_rd_en(1'b1),
        .cfg_rdata(cfg_rdata),
        .layer_busy(1'b0), .layer_done(1'b0),
        .external_config_error(1'b0),
        .compute_pipe_compute_gap_count(32'd0),
        .compute_pipe_preload_commit_count(32'd0),
        .compute_pipe_preload_hit_count(32'd0),
        .compute_pipe_preload_miss_count(32'd0),
        .compute_pipe_eligible_handoff_count(32'd0),
        .compute_pipe_next_cycle_hit_count(32'd0),
        .compute_pipe_extra_gap_count(32'd0),
        .compute_pipe_wait_bank_retire_count(32'd0),
        .compute_pipe_wait_weight_count(32'd0),
        .compute_pipe_wait_ifm_count(32'd0),
        .compute_pipe_wait_psum_count(32'd0),
        .compute_pipe_wait_collector_output_count(32'd0),
        .compute_pipe_wait_control_count(32'd0),
        .compute_pipe_protocol_error_count(32'd0),
        .start_pulse(start_pulse), .config_error(config_error),
        .validated_long_cin(validated_long_cin),
        .validated_long_pass_count(validated_long_pass_count),
        .validated_long_final_pass(validated_long_final_pass),
        .validated_long_final_lane_mask(
            validated_long_final_lane_mask),
        .validated_long_layer_pixels(validated_long_layer_pixels),
        .validated_long_tile_pixels(validated_long_tile_pixels),
        .validated_long_tile_output_pixels(
            validated_long_tile_output_pixels),
        .validated_long_cout_blocks(validated_long_cout_blocks)
    );

    task write_reg;
        input [7:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            cfg_addr = addr;
            cfg_wdata = data;
            cfg_wr_en = 1'b1;
            @(negedge clk);
            cfg_wr_en = 1'b0;
        end
    endtask

    task check;
        input condition;
        input [8*96-1:0] label;
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $display("[FAIL] %0s", label);
            end
        end
    endtask

    task program_legal_1x1;
        begin
            // 3x2x4 -> 3x2x4, two spatial tiles of at most two rows.
            write_reg(7'h01, {7'd0, 9'd2, 7'd0, 9'd3});
            write_reg(7'h02, {7'd0, 9'd2, 7'd0, 9'd3});
            write_reg(7'h03, {15'd0, 1'b1, 6'd0, 2'd0, 6'd0, 2'd1});
            write_reg(7'h04, 32'd4);
            write_reg(7'h05, 32'd4);
            write_reg(7'h06, 32'd4);
            write_reg(7'h10, 32'd0);
            write_reg(7'h11, 32'd24);
            write_reg(7'h19, 32'h0000_0003);
            write_reg(7'h1a, 32'd2);
            write_reg(7'h1b, 32'd2);
            write_reg(7'h1c, 32'd1);
            write_reg(7'h7a, 32'd2);
            write_reg(7'h7b, 32'd24);
            write_reg(7'h7c, 32'd24);
        end
    endtask

    task program_release_layer;
        input integer fm_dim;
        input integer cin;
        input integer cout;
        input integer kernel;
        input integer pool;
        input integer tile_h;
        input integer ifm_bytes;
        input integer ofm_bytes;
        integer k_value;
        integer tile_pixels;
        begin
            k_value = (kernel == 1) ? cin : cin * 9;
            tile_pixels = fm_dim * tile_h;
            expected_release_cin = cin;
            expected_release_pass_count = (k_value + 17) / 18;
            expected_release_final_pass =
                expected_release_pass_count - 1;
            expected_release_final_lane_mask =
                (1 << (k_value - expected_release_final_pass * 18)) - 1;
            expected_release_layer_pixels = fm_dim * fm_dim;
            expected_release_tile_pixels = tile_pixels;
            expected_release_tile_output_pixels = pool ?
                ((fm_dim / 2) * (tile_h / 2)) : tile_pixels;
            expected_release_cout_blocks = (cout + 31) / 32;
            write_reg(7'h01, {7'd0, fm_dim[8:0], 7'd0,
                              fm_dim[8:0]});
            write_reg(7'h02, {7'd0, fm_dim[8:0], 7'd0,
                              fm_dim[8:0]});
            write_reg(7'h03, {15'd0, (kernel == 1), 6'd0,
                              (kernel == 1) ? 2'd0 : 2'd1,
                              6'd0, 2'd1});
            write_reg(7'h04, k_value);
            write_reg(7'h05, cout);
            write_reg(7'h06, tile_pixels);
            write_reg(7'h10, pool ? 32'h0000_0009 : 32'd0);
            write_reg(7'h11, ofm_bytes);
            write_reg(7'h19, 32'h0000_0003);
            write_reg(7'h1a, 32'd1);
            write_reg(7'h1b, 32'd1);
            write_reg(7'h1c, 32'd1);
            write_reg(7'h7a, tile_h);
            write_reg(7'h7b, ifm_bytes);
            write_reg(7'h7c, ofm_bytes);
        end
    endtask

    task expect_legal_release_layer;
        input [8*96-1:0] label;
        integer before_count;
        integer timeout;
        begin
            before_count = start_count;
            write_reg(7'h00, 32'h0000_0001);
            timeout = 0;
            while (!start_pulse && !config_error && timeout < 12) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
            end
            check(timeout < 12, "release descriptor validation completes");
            check(start_pulse, label);
            check(!config_error, "release descriptor remains error-free");
            check(validated_long_cin == expected_release_cin &&
                  validated_long_pass_count ==
                      expected_release_pass_count &&
                  validated_long_final_pass ==
                      expected_release_final_pass &&
                  validated_long_final_lane_mask ==
                      expected_release_final_lane_mask,
                  "release descriptor channel geometry is bit-exact");
            check(validated_long_layer_pixels ==
                      expected_release_layer_pixels &&
                  validated_long_tile_pixels ==
                      expected_release_tile_pixels &&
                  validated_long_tile_output_pixels ==
                      expected_release_tile_output_pixels &&
                  validated_long_cout_blocks ==
                      expected_release_cout_blocks,
                  "release descriptor spatial geometry is bit-exact");
            repeat (2) @(posedge clk);
            check(start_count == before_count + 1,
                  "release descriptor emits exactly one start");
            clear_status();
        end
    endtask

    task clear_status;
        begin
            write_reg(7'h00, 32'h0000_0002);
            check(!config_error, "clear removes descriptor error sticky");
        end
    endtask

    task expect_rejected_start;
        input [8*96-1:0] label;
        integer before_count;
        integer timeout;
        begin
            before_count = start_count;
            write_reg(7'h00, 32'h0000_0001);
            timeout = 0;
            while (!start_pulse && !config_error && timeout < 12) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
            end
            check(timeout < 12, "rejected descriptor validation completes");
            check(!start_pulse, label);
            check(config_error, "rejected descriptor sets config_error");
            check(cfg_rdata[1], "rejected descriptor completes fail-closed");
            repeat (2) @(posedge clk);
            check(start_count == before_count,
                  "rejected descriptor never emits start_pulse");
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;

        // Exhaust the complete hardware input domain, not only the ten
        // release descriptors, before relying on the divider-free quotient.
        reciprocal_exact = 1'b1;
        for (reciprocal_k = 0; reciprocal_k < 16384;
             reciprocal_k = reciprocal_k + 1) begin
            reciprocal_product = reciprocal_k * 3641;
            if ((reciprocal_product >> 15) != (reciprocal_k / 9) ||
                (reciprocal_product >> 16) != (reciprocal_k / 18))
                reciprocal_exact = 1'b0;
        end
        check(reciprocal_exact,
              "reciprocal quotient is exact over all 14-bit K values");

        program_legal_1x1();
        write_reg(7'h00, 32'h0000_0001);
        // A write attempted while the captured descriptor is in the geometry
        // and capacity pipeline must not alter either the transaction or the
        // programmed register bank.
        write_reg(7'h7b, 32'd23);
        check(dut.ifm_total_bytes == 32'd24,
              "descriptor writes are locked throughout validation");
        check(validated_long_cin == 14'd0 &&
              validated_long_layer_pixels == 32'd0,
              "derived descriptor outputs wait for atomic commit");
        validation_timeout = 0;
        while (!start_pulse && !config_error &&
               validation_timeout < 12) begin
            @(posedge clk);
            #1;
            validation_timeout = validation_timeout + 1;
        end
        check(validation_timeout < 12,
              "captured descriptor validation completes");
        #1;
        check(start_pulse, "legal layer-long descriptor starts");
        check(!config_error, "legal descriptor has no config error");
        check(validated_long_cin == 14'd4,
              "validator exports registered CIN");
        check(validated_long_pass_count == 16'd1 &&
              validated_long_final_pass == 16'd0,
              "validator exports registered pass geometry");
        check(validated_long_final_lane_mask == 18'h0000f,
              "validator exports registered final-lane mask");
        check(validated_long_layer_pixels == 32'd6 &&
              validated_long_tile_pixels == 32'd4 &&
              validated_long_tile_output_pixels == 32'd4,
              "validator exports registered layer/tile pixel geometry");
        check(validated_long_cout_blocks == 16'd1,
              "validator exports registered COUT block count");
        cfg_addr = 8'ha0;
        #1;
        check(cfg_rdata == 32'd200000000,
              "CLOCK_HZ readback returns build parameter");
        repeat (2) @(posedge clk);
        check(start_count == 1, "legal descriptor emits one start pulse");

        clear_status();
        // Every descriptor in the fixed ten-layer 18x16 release schedule must
        // pass the same gate used by hardware.  Weight/bias packet counts are
        // nonzero here; their exact layer-wide repetition is checked by the
        // software schedule verifier.
        program_release_layer(416, 3, 16, 3, 1, 2, 519168, 692224);
        expect_legal_release_layer("Conv0 descriptor accepted");
        program_release_layer(208, 16, 32, 3, 1, 4, 692224, 346112);
        expect_legal_release_layer("Conv1 descriptor accepted");
        program_release_layer(104, 32, 64, 3, 1, 8, 346112, 173056);
        expect_legal_release_layer("Conv2 descriptor accepted");
        program_release_layer(52, 64, 128, 3, 1, 8, 173056, 86528);
        expect_legal_release_layer("Conv3 descriptor accepted");
        program_release_layer(26, 128, 256, 3, 1, 8, 86528, 43264);
        expect_legal_release_layer("Conv4 descriptor accepted");
        program_release_layer(13, 256, 512, 3, 0, 8, 43264, 86528);
        expect_legal_release_layer("Conv5 descriptor accepted");
        program_release_layer(13, 512, 1024, 3, 0, 8, 86528, 173056);
        expect_legal_release_layer("Conv6 descriptor accepted");
        program_release_layer(13, 1024, 256, 1, 0, 13, 173056, 43264);
        expect_legal_release_layer("Conv7 descriptor accepted");
        program_release_layer(13, 256, 512, 3, 0, 8, 43264, 86528);
        expect_legal_release_layer("Conv8 descriptor accepted");
        program_release_layer(13, 512, 24, 1, 0, 13, 86528, 4056);
        expect_legal_release_layer("Conv9 descriptor accepted");

        // The packed four-row store needs
        // ceil(CIN/4)*ceil(FM_W/2)=205*9=1845 words per row bank here.
        // This is deliberately above the obsolete 1024-word limit.  It also
        // remains just above 1024 if both old assumptions return together
        // (ceil(17/4)*205=1025), so the guard cannot be defeated by changing
        // the depth and x packing divisor in the same regression.
        program_release_layer(17, 820, 32, 1, 0, 1, 236980, 9248);
        expect_legal_release_layer("near-capacity 2048-word row descriptor accepted");

        // A 3x3 K count must be an exact multiple of nine.
        write_reg(7'h03, {15'd0, 1'b0, 6'd0, 2'd1, 6'd0, 2'd1});
        write_reg(7'h04, 32'd28);
        expect_rejected_start("non-divisible 3x3 K is rejected");

        clear_status();
        // The packed four-row store needs
        // ceil(CIN/4)*ceil(FM_W/2)=11*208=2288 words per row bank here,
        // exceeding the formal 2048-word bank.  A stale ceil(FM_W/4)
        // calculation produces only 1144 and would incorrectly accept this
        // descriptor, even though the tile cache and PSUM buffers remain
        // within their independent limits.
        program_release_layer(416, 41, 16, 3, 1, 2,
                              7095296, 692224);
        expect_rejected_start("packed row-store line-bank overflow is rejected");

        clear_status();
        program_legal_1x1();
        write_reg(7'h7b, 32'd23);
        expect_rejected_start("mismatched IFM byte count is rejected");

        clear_status();
        program_legal_1x1();
        write_reg(7'h02, {7'd0, 9'd3, 7'd0, 9'd3});
        expect_rejected_start("mismatched convolution geometry is rejected");

        clear_status();
        // 32x32 with 33 passes requires 33792 materialized entries,
        // exceeding the formal 32768-entry bank while the tile itself still
        // fits the 1024-pixel PSUM/OFM buffers.
        write_reg(7'h01, {7'd0, 9'd32, 7'd0, 9'd32});
        write_reg(7'h02, {7'd0, 9'd32, 7'd0, 9'd32});
        write_reg(7'h03, {15'd0, 1'b0, 6'd0, 2'd1, 6'd0, 2'd1});
        write_reg(7'h04, 32'd594);
        write_reg(7'h05, 32'd4);
        write_reg(7'h06, 32'd1024);
        write_reg(7'h10, 32'd0);
        write_reg(7'h11, 32'd4096);
        write_reg(7'h19, 32'h0000_0003);
        write_reg(7'h1a, 32'd1);
        write_reg(7'h1b, 32'd33);
        write_reg(7'h1c, 32'd1);
        write_reg(7'h7a, 32'd32);
        write_reg(7'h7b, 32'd67584);
        write_reg(7'h7c, 32'd4096);
        expect_rejected_start("oversized materialized tile is rejected");

        if (failures == 0)
            $display("[PASS] tb_layer_long_descriptor_validation checks=%0d",
                     checks);
        else
            $display("[FAIL] tb_layer_long_descriptor_validation failures=%0d checks=%0d",
                     failures, checks);
        $finish;
    end

    initial begin
        #100000;
        $display("[FAIL] tb_layer_long_descriptor_validation timeout");
        $finish;
    end
endmodule

`timescale 1ns / 1ps

// Wiring smoke test for the optional layer-level spatial sequencer.  The
// compute completion is forced so geometry/control can be checked separately
// from the arithmetic datapath regression.
module tb_conv_accel_core_layer_tile_sequence;
    // Layer-long ABI v2 is deliberately fixed to the formal 18-row build.
    localparam integer ROWS = 18;
    localparam integer COLS = 2;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg cfg_wr_en = 1'b0;
    reg cfg_rd_en = 1'b0;
    reg [7:0] cfg_addr = 8'd0;
    reg [31:0] cfg_wdata = 32'd0;
    wire [31:0] cfg_rdata;
    reg synthetic_tile_done = 1'b0;
    reg tile_retire_ready = 1'b0;
    wire [7:0] dma_wr_data_zero [0:1];
    assign dma_wr_data_zero[0] = 8'd0;
    assign dma_wr_data_zero[1] = 8'd0;

    wire active_tile_start;
    wire active_tile_last;
    wire [8:0] active_tile_oy_base;
    wire [8:0] active_tile_ofm_h;
    wire [15:0] active_tile_num_pixels;
    wire [15:0] active_tile_output_pixels;
    wire [23:0] active_tile_output_pixel_base;
    wire [15:0] active_tile_index;
    wire active_tile_done;
    wire configured_config_error;

    integer checks = 0;
    integer failures = 0;

    conv_accel_core #(
        .ROWS(ROWS), .COLS(COLS),
        .IFM_FIFO_DEPTH(16), .IFM_FIFO_AW(4),
        .WGT_FIFO_DEPTH(16), .WGT_FIFO_AW(4),
        .PSUM_FIFO_DEPTH(16), .PSUM_FIFO_AW(4),
        .FM_W_MAX(5), .FM_H_MAX(5),
        .K_TILE(4), .COUT_TILE(COLS*2),
        .IFM_BANKS(2), .WGT_TILE_AW(6),
        .PSUM_BUF_AW(4), .PSUM_BUF_DEPTH(16),
        .OFM_ADDR_W(24),
        .ENABLE_LAYER_TILE_SEQUENCER(1),
        .ENABLE_LAYER_LONG_HWC_IFM(1)
    ) dut (
        .clk(clk), .rst(rst), .tile_start_ready(1'b1),
        .tile_retire_ready(tile_retire_ready),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata), .cfg_rd_en(cfg_rd_en),
        .cfg_rdata(cfg_rdata),
        .bias_load_done(1'b0), .weight_tile_ready(1'b0),
        .bias_wr_addr(6'd0), .bias_wr_data(32'd0), .bias_wr_en(1'b0),
        .wgt_tile_wr_en(1'b0), .wgt_tile_wr_addr(6'd0),
        .wgt_tile_wr_data(8'd0), .wgt_tile_wr8_en(1'b0),
        .wgt_tile_wr8_addr(6'd0), .wgt_tile_wr8_data(64'd0),
        .wgt_tile_wr8_keep(8'd0),
        .dma_bank_wr_en(2'd0), .dma_wr_x(9'd0), .dma_wr_fy(10'd0),
        .dma_wr_data(dma_wr_data_zero), .dma_line_advance(1'b0),
        .vector_ifm_data({ROWS*8{1'b0}}), .vector_ifm_valid(1'b0),
        .vector_packet_done(1'b0),
        .quant_wr_en(1'b0), .quant_wr_addr(6'd0),
        .quant_wr_data(32'd0), .quant_rd_addr(6'd0),
        .act_lut_wr_en(1'b0), .act_lut_wr_addr(8'd0),
        .act_lut_wr_data(8'd0),
        .ofm_mem_wr_ready(1'b1), .packed_ofm_packet_ready(1'b0),
        .packed_ofm_busy(1'b0),
        .debug_expected_bytes(32'd0), .debug_core_wr_count(32'd0),
        .debug_axis_wr_count(32'd0), .debug_tlast_count(32'd0),
        .debug_last_tlast_index(32'd0),
        .debug_packed_ofm_axis_byte_count(32'd0),
        .debug_packed_ofm_axis_stall_cycles(32'd0),
        .debug_packed_ofm_protocol_error(1'b0),
        .stream_bias_completed(32'd0), .stream_weight_completed(32'd0),
        .stream_ifm_completed(32'd0), .vector_completed_packets(32'd0),
        .vector_completed_pixels(32'd0), .vector_accepted_beats(32'd0),
        .vector_fifo_stall_cycles(32'd0),
        .raw_hwc_load_active_cycles(32'd0),
        .raw_hwc_load_unpack_cycles(32'd0),
        .raw_hwc_replay_active_cycles(32'd0),
        .raw_hwc_replay_wait_ready_cycles(32'd0),
        .active_tile_start(active_tile_start),
        .active_tile_last(active_tile_last),
        .active_tile_oy_base(active_tile_oy_base),
        .active_tile_ofm_h(active_tile_ofm_h),
        .active_tile_num_pixels(active_tile_num_pixels),
        .active_tile_output_pixels(active_tile_output_pixels),
        .active_tile_output_pixel_base(active_tile_output_pixel_base),
        .active_tile_index(active_tile_index),
        .active_tile_done(active_tile_done),
        .configured_config_error(configured_config_error)
    );

    initial force dut.tile_engine_done = synthetic_tile_done;

    task cfg_write;
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

    task complete_tile;
        begin
            @(negedge clk);
            synthetic_tile_done = 1'b1;
            @(negedge clk);
            synthetic_tile_done = 1'b0;
        end
    endtask

    task acknowledge_tile_retire;
        begin
            @(negedge clk);
            tile_retire_ready = 1'b1;
            @(negedge clk);
            tile_retire_ready = 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;

        // Full convolution geometry is 3x3. tile_h_max=2 creates a two-row
        // tile followed by a one-row tail tile.
        cfg_write(7'h01, {7'd0, 9'd5, 7'd0, 9'd5});
        cfg_write(7'h02, {7'd0, 9'd3, 7'd0, 9'd3});
        cfg_write(7'h03, {22'd0, 2'd0, 6'd0, 2'd1});
        cfg_write(7'h04, 32'd27);
        cfg_write(7'h05, 32'd5);
        cfg_write(7'h06, 32'd6);
        cfg_write(7'h11, 32'd45);
        cfg_write(7'h19, 32'd3);
        cfg_write(7'h1a, 32'd1);
        cfg_write(7'h1b, 32'd1);
        cfg_write(7'h1c, 32'd1);
        cfg_write(7'h7a, {1'b1, 22'd0, 9'd2});
        cfg_write(7'h7b, 32'd75);
        cfg_write(7'h7c, 32'd45);
        cfg_write(7'h00, 32'd1);

        wait(active_tile_start);
        #1;
        check(!configured_config_error, "legal layer tile config");
        check(active_tile_oy_base == 0, "first tile y base");
        check(active_tile_ofm_h == 2, "first tile height");
        check(active_tile_num_pixels == 6, "first tile input pixels");
        check(active_tile_output_pixels == 6, "first tile output pixels");
        check(active_tile_output_pixel_base == 0,
              "first tile output base");
        check(active_tile_index == 0, "first tile index");
        check(!active_tile_last, "first tile is not last");

        synthetic_tile_done = 1'b1;
        #1;
        check(active_tile_done, "first tile done exported");
        synthetic_tile_done = 1'b0;
        complete_tile();
        repeat (2) @(negedge clk);
        check(dut.tile_retire_pending,
              "first engine-done retained until cache release");
        check(active_tile_index == 0,
              "sequencer holds first tile before retirement");
        acknowledge_tile_retire();
        wait(active_tile_start);
        #1;
        check(active_tile_oy_base == 2, "tail tile y base");
        check(active_tile_ofm_h == 1, "tail tile height");
        check(active_tile_num_pixels == 3, "tail tile input pixels");
        check(active_tile_output_pixels == 3, "tail tile output pixels");
        check(active_tile_output_pixel_base == 6,
              "tail tile output base");
        check(active_tile_index == 1, "tail tile index");
        check(active_tile_last, "tail tile is last");

        complete_tile();
        repeat (2) @(negedge clk);
        check(dut.tile_retire_pending,
              "final engine-done retained until cache release");
        check(dut.layer_busy,
              "layer remains busy before final retirement");
        acknowledge_tile_retire();
        cfg_addr = 7'h00;
        wait(cfg_rdata[1]);
        check(!dut.layer_busy, "layer busy clears after final tile");
        check(dut.g_layer_tiles.u_tile_sequencer.tile_start_count == 2,
              "two tile starts counted");
        check(dut.g_layer_tiles.u_tile_sequencer.tile_done_count == 2,
              "two tile completions counted");

        if (failures == 0)
            $display("[PASS] tb_conv_accel_core_layer_tile_sequence checks=%0d",
                     checks);
        else
            $display("[FAIL] tb_conv_accel_core_layer_tile_sequence failures=%0d checks=%0d",
                     failures, checks);
        $finish;
    end

    initial begin
        #100000;
        $display("[FAIL] tb_conv_accel_core_layer_tile_sequence timeout");
        $finish;
    end
endmodule

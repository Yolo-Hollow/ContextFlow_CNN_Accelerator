`timescale 1ns / 1ps

module tb_layer_tile_sequencer;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg layer_start = 1'b0;
    reg [8:0] cfg_ofm_h = 9'd0;
    reg [8:0] cfg_ofm_w = 9'd0;
    reg [8:0] cfg_tile_h_max = 9'd0;
    reg [10:0] cfg_cout_total = 11'd0;
    reg cfg_pool_enable = 1'b0;
    reg [1:0] cfg_pool_stride = 2'd0;
    reg tile_start_ready = 1'b1;
    reg tile_done = 1'b0;
    wire layer_busy, layer_done, tile_start;
    wire [8:0] tile_oy_base, tile_ofm_h;
    wire [15:0] tile_num_pixels, tile_output_pixels;
    wire [23:0] tile_output_pixel_base;
    wire tile_last;
    wire [15:0] tile_index;
    wire config_error, protocol_error;
    wire [31:0] tile_start_count, tile_done_count;
    integer pass_count = 0;
    integer fail_count = 0;

    always #5 clk = ~clk;

    layer_tile_sequencer dut (
        .clk(clk), .rst(rst), .layer_start(layer_start),
        .cfg_ofm_h(cfg_ofm_h), .cfg_ofm_w(cfg_ofm_w),
        .cfg_tile_h_max(cfg_tile_h_max),
        .cfg_cout_total(cfg_cout_total),
        .cfg_pool_enable(cfg_pool_enable),
        .cfg_pool_stride(cfg_pool_stride),
        .layer_busy(layer_busy), .layer_done(layer_done),
        .tile_start(tile_start), .tile_start_ready(tile_start_ready),
        .tile_done(tile_done),
        .tile_oy_base(tile_oy_base), .tile_ofm_h(tile_ofm_h),
        .tile_num_pixels(tile_num_pixels),
        .tile_output_pixels(tile_output_pixels),
        .tile_output_pixel_base(tile_output_pixel_base),
        .tile_last(tile_last), .tile_index(tile_index),
        .config_error(config_error), .protocol_error(protocol_error),
        .tile_start_count(tile_start_count),
        .tile_done_count(tile_done_count)
    );

    task check;
        input condition;
        input [255:0] message;
        begin
            if (condition)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task start_layer;
        input [8:0] h;
        input [8:0] w;
        input [8:0] tile_h;
        input pool;
        input [10:0] cout_total;
        begin
            @(negedge clk);
            cfg_ofm_h = h;
            cfg_ofm_w = w;
            cfg_tile_h_max = tile_h;
            cfg_cout_total = cout_total;
            cfg_pool_enable = pool;
            cfg_pool_stride = pool ? 2'd2 : 2'd0;
            layer_start = 1'b1;
            @(negedge clk);
            layer_start = 1'b0;
        end
    endtask

    task retire_tile;
        begin
            repeat (3) @(negedge clk);
            tile_done = 1'b1;
            @(negedge clk);
            tile_done = 1'b0;
        end
    endtask

    task wait_tile_start;
        integer timeout;
        begin
            timeout = 0;
            while (!tile_start && timeout < 12) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            check(tile_start, "tile start arrived after atomic geometry commit");
        end
    endtask

    task wait_layer_done;
        integer timeout;
        begin
            timeout = 0;
            while (!layer_done && timeout < 12) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            check(layer_done, "layer done arrived after final retirement");
        end
    endtask

    task wait_config_reject;
        integer timeout;
        begin
            timeout = 0;
            while (layer_busy && timeout < 12) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            check(!layer_busy && config_error,
                  "invalid geometry rejected after registered validation");
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;

        tile_start_ready = 1'b0;
        start_layer(9'd13, 9'd13, 9'd8, 1'b0, 11'd1024);
        repeat (3) @(negedge clk);
        check(!tile_start && layer_busy && tile_start_count == 0,
              "first tile waits for downstream ownership");
        repeat (2) @(negedge clk);
        tile_start_ready = 1'b1;
        wait_tile_start();
        check(tile_start && layer_busy, "first nonpool tile starts");
        check(tile_oy_base == 0 && tile_ofm_h == 8,
              "first nonpool geometry");
        check(tile_num_pixels == 104 && tile_output_pixels == 104,
              "first nonpool pixel counts");
        check(!tile_last, "first tile is not last");
        retire_tile();
        wait_tile_start();
        check(tile_start && tile_oy_base == 8 && tile_ofm_h == 5,
              "tail tile starts without software");
        check(tile_output_pixel_base == 104 && tile_last,
              "tail tile output base and last");
        retire_tile();
        wait_layer_done();
        check(layer_done && !layer_busy, "nonpool layer completes");
        check(tile_start_count == 2 && tile_done_count == 2,
              "nonpool tile counters");

        start_layer(9'd16, 9'd10, 9'd8, 1'b1, 11'd256);
        wait_tile_start();
        check(tile_output_pixels == 20, "pooled tile output pixels");
        retire_tile();
        wait_tile_start();
        check(tile_output_pixel_base == 20 && tile_output_pixels == 20,
              "pooled output base increments densely");
        retire_tile();
        wait_layer_done();
        check(layer_done && tile_start_count == 2,
              "pooled layer completes in two tiles");

        start_layer(9'd13, 9'd13, 9'd8, 1'b1, 11'd256);
        wait_config_reject();
        check(!protocol_error, "no protocol error in legal sequence");

        start_layer(9'd416, 9'd416, 9'd8, 1'b1, 11'd16);
        wait_config_reject();

        $display("=== tb_layer_tile_sequencer: %0d pass, %0d fail ===",
                 pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "timeout");
    end
endmodule

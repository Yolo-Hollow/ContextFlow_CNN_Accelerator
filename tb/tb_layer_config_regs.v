`timescale 1ns / 1ps

module tb_layer_config_regs;
    reg clk, rst;
    reg cfg_wr_en;
    reg [5:0] cfg_addr;
    reg [31:0] cfg_wdata;
    reg cfg_rd_en;
    wire [31:0] cfg_rdata;
    reg layer_busy, layer_done;
    reg perf_wait_bias, perf_wait_weight, perf_wait_ifm, perf_wait_ofm;
    reg perf_compute_fire;
    reg perf_stage_bias, perf_stage_weight, perf_stage_feeder;
    reg perf_stage_compute, perf_stage_drain, perf_stage_ofm_post;
    reg perf_feed_fill_wait, perf_feed_push, perf_feed_fifo_stall;
    reg perf_feed_win_not_ready;
    reg perf_comp_wload, perf_comp_active, perf_comp_ifm_stall, perf_comp_tail;
    reg perf_drain_fifo_empty_wait, perf_drain_fifo_empty_sticky;
    reg [31:0] stream_bias_completed;
    reg [31:0] stream_weight_completed;
    reg [31:0] stream_ifm_completed;
    reg [31:0] vector_completed_packets;
    reg [31:0] vector_completed_pixels;
    reg [31:0] vector_accepted_beats;
    reg [31:0] vector_fifo_stall_cycles;
    reg [31:0] raw_hwc_load_active_cycles;
    reg [31:0] raw_hwc_load_unpack_cycles;
    reg [31:0] raw_hwc_replay_active_cycles;
    reg [31:0] raw_hwc_replay_wait_ready_cycles;
    wire start_pulse;
    wire [8:0] fm_h, fm_w, ofm_h, ofm_w;
    wire [1:0] conv_stride, conv_pad;
    wire kernel_1x1;
    wire [1:0] activation_mode;
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
    wire [31:0] stream_bias_packets;
    wire [31:0] stream_weight_packets;
    wire [31:0] stream_ifm_packets;
    wire [15:0] tail_cycles_config;
    wire [15:0] raw_hwc_compute_start_level;
    wire [31:0] tail_cycles_selected =
        {16'd0, (tail_cycles_config == 16'd0) ? 16'd138 : tail_cycles_config};
    wire config_error;

    layer_config_regs #(
        .IFM_FIFO_DEPTH(64)
    ) dut (
        .clk(clk), .rst(rst),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_rd_en(cfg_rd_en), .cfg_rdata(cfg_rdata),
        .layer_busy(layer_busy), .layer_done(layer_done),
        .dbg_expected_bytes(32'd0), .dbg_core_wr_count(32'd0),
        .dbg_axis_wr_count(32'd0), .dbg_tlast_count(32'd0),
        .dbg_last_tlast_index(32'd0),
        .perf_wait_bias(perf_wait_bias), .perf_wait_weight(perf_wait_weight),
        .perf_wait_ifm(perf_wait_ifm), .perf_wait_ofm(perf_wait_ofm),
        .perf_compute_fire(perf_compute_fire),
        .perf_stage_bias(perf_stage_bias),
        .perf_stage_weight(perf_stage_weight),
        .perf_stage_feeder(perf_stage_feeder),
        .perf_stage_compute(perf_stage_compute),
        .perf_stage_drain(perf_stage_drain),
        .perf_stage_ofm_post(perf_stage_ofm_post),
        .perf_feed_fill_wait(perf_feed_fill_wait),
        .perf_feed_push(perf_feed_push),
        .perf_feed_fifo_stall(perf_feed_fifo_stall),
        .perf_feed_win_not_ready(perf_feed_win_not_ready),
        .perf_comp_wload(perf_comp_wload),
        .perf_comp_active(perf_comp_active),
        .perf_comp_ifm_stall(perf_comp_ifm_stall),
        .perf_comp_tail(perf_comp_tail),
        .perf_tail_cycles_configured(tail_cycles_selected),
        .perf_drain_fifo_empty_wait(perf_drain_fifo_empty_wait),
        .perf_drain_fifo_empty_sticky(perf_drain_fifo_empty_sticky),
        .stream_bias_completed(stream_bias_completed),
        .stream_weight_completed(stream_weight_completed),
        .stream_ifm_completed(stream_ifm_completed),
        .vector_completed_packets(vector_completed_packets),
        .vector_completed_pixels(vector_completed_pixels),
        .vector_accepted_beats(vector_accepted_beats),
        .vector_fifo_stall_cycles(vector_fifo_stall_cycles),
        .raw_hwc_load_active_cycles(raw_hwc_load_active_cycles),
        .raw_hwc_load_unpack_cycles(raw_hwc_load_unpack_cycles),
        .raw_hwc_replay_active_cycles(raw_hwc_replay_active_cycles),
        .raw_hwc_replay_wait_ready_cycles(raw_hwc_replay_wait_ready_cycles),
        .start_pulse(start_pulse),
        .fm_h(fm_h), .fm_w(fm_w), .ofm_h(ofm_h), .ofm_w(ofm_w),
        .conv_stride(conv_stride), .conv_pad(conv_pad), .kernel_1x1(kernel_1x1),
        .activation_mode(activation_mode),
        .k_total(k_total), .cout_total(cout_total), .num_pixels(num_pixels),
        .tile_oy_base(tile_oy_base), .tile_ofm_h(tile_ofm_h),
        .tile_pixel_base(tile_pixel_base),
        .input_zero_point(input_zero_point),
        .pool_enable(pool_enable), .pool_stride(pool_stride),
        .expected_bytes(expected_bytes),
        .stream_batch_mode(stream_batch_mode),
        .stream_raw_hwc_mode(stream_raw_hwc_mode),
        .stream_bias_packets(stream_bias_packets),
        .stream_weight_packets(stream_weight_packets),
        .stream_ifm_packets(stream_ifm_packets),
        .tail_cycles_config(tail_cycles_config),
        .raw_hwc_compute_start_level(raw_hwc_compute_start_level),
        .config_error(config_error)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer start_pulse_count;

    always @(posedge clk) begin
        if (rst)
            start_pulse_count <= 0;
        else if (start_pulse)
            start_pulse_count <= start_pulse_count + 1;
    end

    task write_reg;
        input [5:0] addr;
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

    task check_value;
        input integer got;
        input integer exp;
        input [127:0] name;
        begin
            if (got !== exp) begin
                $display("[FAIL] %0s got=%0d exp=%0d", name, got, exp);
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        cfg_wr_en = 0;
        cfg_addr = 0;
        cfg_wdata = 0;
        cfg_rd_en = 0;
        layer_busy = 0;
        layer_done = 0;
        perf_wait_bias = 0;
        perf_wait_weight = 0;
        perf_wait_ifm = 0;
        perf_wait_ofm = 0;
        perf_compute_fire = 0;
        perf_stage_bias = 0;
        perf_stage_weight = 0;
        perf_stage_feeder = 0;
        perf_stage_compute = 0;
        perf_stage_drain = 0;
        perf_stage_ofm_post = 0;
        perf_feed_fill_wait = 0;
        perf_feed_push = 0;
        perf_feed_fifo_stall = 0;
        perf_feed_win_not_ready = 0;
        perf_comp_wload = 0;
        perf_comp_active = 0;
        perf_comp_ifm_stall = 0;
        perf_comp_tail = 0;
        perf_drain_fifo_empty_wait = 0;
        perf_drain_fifo_empty_sticky = 0;
        stream_bias_completed = 32'd7;
        stream_weight_completed = 32'd11;
        stream_ifm_completed = 32'd13;
        vector_completed_packets = 32'd17;
        vector_completed_pixels = 32'd19;
        vector_accepted_beats = 32'd23;
        vector_fifo_stall_cycles = 32'd29;
        raw_hwc_load_active_cycles = 32'd31;
        raw_hwc_load_unpack_cycles = 32'd37;
        raw_hwc_replay_active_cycles = 32'd41;
        raw_hwc_replay_wait_ready_cycles = 32'd43;
        pass = 0;
        fail = 0;
        start_pulse_count = 0;

        repeat (3) @(negedge clk);
        rst = 0;

        write_reg(6'h01, {7'd0, 9'd5, 7'd0, 9'd7});
        write_reg(6'h02, {7'd0, 9'd3, 7'd0, 9'd4});
        write_reg(6'h03, {22'd0, 2'd1, 6'd0, 2'd2});
        write_reg(6'h04, 32'd9216);
        write_reg(6'h05, 32'd10);
        write_reg(6'h06, 32'd12);
        write_reg(6'h07, 32'd2);
        write_reg(6'h08, {7'd0, 9'd3, 7'd0, 9'd2});
        write_reg(6'h09, 32'd6);
        write_reg(6'h0f, 32'd36);
        write_reg(6'h10, {28'd0, 2'd2, 1'b0, 1'b1});
        write_reg(6'h19, 32'd3);
        write_reg(6'h1a, 32'd7);
        write_reg(6'h1b, 32'd11);
        write_reg(6'h1c, 32'd13);
        write_reg(6'h38, {16'd64, 16'd96});

        check_value(fm_h, 7, "fm_h");
        check_value(fm_w, 5, "fm_w");
        check_value(ofm_h, 4, "ofm_h");
        check_value(ofm_w, 3, "ofm_w");
        check_value(conv_stride, 2, "stride");
        check_value(conv_pad, 1, "pad");
        check_value(k_total, 9216, "k_total");
        check_value(cout_total, 10, "cout_total");
        check_value(num_pixels, 12, "num_pixels");
        check_value(activation_mode, 2, "activation");
        check_value(tile_oy_base, 2, "tile_oy_base");
        check_value(tile_ofm_h, 3, "tile_ofm_h");
        check_value(tile_pixel_base, 6, "tile_pixel_base");
        check_value(input_zero_point, 36, "input_zero_point");
        check_value(pool_enable, 1, "pool_enable");
        check_value(pool_stride, 2, "pool_stride");
        check_value(stream_batch_mode, 1, "stream batch mode");
        check_value(stream_raw_hwc_mode, 1, "stream raw hwc mode");
        check_value(stream_bias_packets, 7, "stream bias packets");
        check_value(stream_weight_packets, 11, "stream weight packets");
        check_value(stream_ifm_packets, 13, "stream ifm packets");
        check_value(tail_cycles_config, 96, "tail cycles config output");
        check_value(raw_hwc_compute_start_level, 64, "raw hwc compute start level");
        cfg_addr = 6'h1d;
        #1;
        check_value(cfg_rdata, 7, "stream bias completed");
        cfg_addr = 6'h1e;
        #1;
        check_value(cfg_rdata, 11, "stream weight completed");
        cfg_addr = 6'h1f;
        #1;
        check_value(cfg_rdata, 13, "stream ifm completed");

        cfg_addr = 6'h07;
        #1;
        if (cfg_rdata !== 32'd2) begin
            $display("[FAIL] act cfg read got=%h exp=2", cfg_rdata);
            fail = fail + 1;
        end else pass = pass + 1;

        cfg_addr = 6'h08;
        #1;
        if (cfg_rdata !== {7'd0, 9'd3, 7'd0, 9'd2}) begin
            $display("[FAIL] tile rows read got=%h", cfg_rdata);
            fail = fail + 1;
        end else pass = pass + 1;

        cfg_addr = 6'h09;
        #1;
        if (cfg_rdata !== 32'd6) begin
            $display("[FAIL] pixel base read got=%h exp=6", cfg_rdata);
            fail = fail + 1;
        end else pass = pass + 1;

        cfg_addr = 6'h0f;
        #1;
        if (cfg_rdata !== 32'd36) begin
            $display("[FAIL] input zero point read got=%h exp=24", cfg_rdata);
            fail = fail + 1;
        end else pass = pass + 1;

        cfg_addr = 6'h10;
        #1;
        if (cfg_rdata !== {28'd0, 2'd2, 1'b0, 1'b1}) begin
            $display("[FAIL] pool cfg read got=%h", cfg_rdata);
            fail = fail + 1;
        end else pass = pass + 1;

        @(negedge clk);
        cfg_addr = 6'h00;
        cfg_wdata = 32'd1;
        cfg_wr_en = 1'b1;
        @(posedge clk);
        #1;
        check_value(start_pulse, 1, "start pulse");
        @(negedge clk);
        cfg_wr_en = 1'b0;
        @(posedge clk);
        #1;
        check_value(start_pulse, 0, "start one cycle");

        @(negedge clk);
        layer_busy = 1'b1;
        perf_wait_ifm = 1'b1;
        perf_compute_fire = 1'b1;
        perf_stage_feeder = 1'b1;
        perf_stage_compute = 1'b1;
        perf_stage_ofm_post = 1'b1;
        perf_feed_fill_wait = 1'b1;
        perf_feed_push = 1'b1;
        perf_feed_win_not_ready = 1'b1;
        perf_comp_wload = 1'b1;
        perf_comp_active = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        perf_wait_ifm = 1'b0;
        perf_compute_fire = 1'b0;
        perf_stage_feeder = 1'b0;
        perf_stage_compute = 1'b0;
        perf_stage_drain = 1'b1;
        perf_feed_fill_wait = 1'b0;
        perf_feed_push = 1'b0;
        perf_feed_fifo_stall = 1'b1;
        perf_feed_win_not_ready = 1'b0;
        perf_comp_wload = 1'b0;
        perf_comp_active = 1'b0;
        perf_comp_ifm_stall = 1'b1;
        perf_comp_tail = 1'b1;
        perf_drain_fifo_empty_wait = 1'b1;
        perf_drain_fifo_empty_sticky = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        layer_busy = 1'b0;
        perf_stage_drain = 1'b0;
        perf_stage_ofm_post = 1'b0;
        perf_feed_fifo_stall = 1'b0;
        perf_comp_ifm_stall = 1'b0;
        perf_comp_tail = 1'b0;
        perf_drain_fifo_empty_wait = 1'b0;
        perf_drain_fifo_empty_sticky = 1'b0;
        cfg_addr = 6'h12;
        #1;
        check_value(cfg_rdata, 5, "perf busy cycles");
        cfg_addr = 6'h13;
        #1;
        check_value(cfg_rdata, 3, "perf wait any cycles");
        cfg_addr = 6'h16;
        #1;
        check_value(cfg_rdata, 3, "perf wait ifm cycles");
        cfg_addr = 6'h18;
        #1;
        check_value(cfg_rdata, 3, "perf compute cycles");
        cfg_addr = 6'h2a;
        #1;
        check_value(cfg_rdata, 3, "stage feeder cycles");
        cfg_addr = 6'h2b;
        #1;
        check_value(cfg_rdata, 3, "stage compute cycles");
        cfg_addr = 6'h2c;
        #1;
        check_value(cfg_rdata, 2, "stage drain cycles");
        cfg_addr = 6'h2d;
        #1;
        check_value(cfg_rdata, 5, "stage ofm post cycles");
        cfg_addr = 6'h2e;
        #1;
        check_value(cfg_rdata, 3, "feed fill wait cycles");
        cfg_addr = 6'h2f;
        #1;
        check_value(cfg_rdata, 3, "feed push cycles");
        cfg_addr = 6'h30;
        #1;
        check_value(cfg_rdata, 2, "feed fifo stall cycles");
        cfg_addr = 6'h31;
        #1;
        check_value(cfg_rdata, 3, "feed window not ready cycles");
        cfg_addr = 6'h32;
        #1;
        check_value(cfg_rdata, 3, "comp wload cycles");
        cfg_addr = 6'h33;
        #1;
        check_value(cfg_rdata, 3, "comp active cycles");
        cfg_addr = 6'h34;
        #1;
        check_value(cfg_rdata, 3, "comp fire cycles");
        cfg_addr = 6'h35;
        #1;
        check_value(cfg_rdata, 2, "comp ifm stall cycles");
        cfg_addr = 6'h36;
        #1;
        check_value(cfg_rdata, 2, "comp tail cycles");
        cfg_addr = 6'h37;
        #1;
        check_value(cfg_rdata, 2, "subperf version");
        cfg_addr = 6'h38;
        #1;
        check_value(cfg_rdata, {16'd64, 16'd96}, "tail cycles configured");
        cfg_addr = 6'h39;
        #1;
        check_value(cfg_rdata, 2, "tail elapsed alias");
        cfg_addr = 6'h3a;
        #1;
        check_value(cfg_rdata, 2, "drain empty wait cycles");
        cfg_addr = 6'h3b;
        #1;
        check_value(cfg_rdata, 1, "drain empty sticky");

        @(negedge clk);
        layer_done = 1'b1;
        layer_busy = 1'b1;
        @(posedge clk);
        #1;
        layer_done = 1'b0;
        cfg_addr = 6'h00;
        #1;
        if (cfg_rdata[1:0] !== 2'b11) begin
            $display("[FAIL] status got=%b exp=11", cfg_rdata[1:0]);
            fail = fail + 1;
        end else pass = pass + 1;

        write_reg(6'h00, 32'd2);
        #1;
        if (cfg_rdata[1] !== 1'b0) begin
            $display("[FAIL] done clear got=%b", cfg_rdata[1]);
            fail = fail + 1;
        end else pass = pass + 1;

        write_reg(6'h01, {7'd0, 9'd99, 7'd0, 9'd88});
        write_reg(6'h04, 32'd99);
        write_reg(6'h07, 32'd1);
        write_reg(6'h08, {7'd0, 9'd8, 7'd0, 9'd7});
        write_reg(6'h09, 32'd99);
        write_reg(6'h0f, 32'd99);
        write_reg(6'h10, 32'd0);
        write_reg(6'h19, 32'd0);
        write_reg(6'h1a, 32'd99);
        write_reg(6'h1b, 32'd99);
        write_reg(6'h1c, 32'd99);
        write_reg(6'h38, 32'd99);
        check_value(fm_h, 7, "busy freeze fm_h");
        check_value(fm_w, 5, "busy freeze fm_w");
        check_value(k_total, 9216, "busy freeze k_total");
        check_value(activation_mode, 2, "busy freeze activation");
        check_value(tile_oy_base, 2, "busy freeze tile_oy_base");
        check_value(tile_ofm_h, 3, "busy freeze tile_ofm_h");
        check_value(tile_pixel_base, 6, "busy freeze pixel base");
        check_value(input_zero_point, 36, "busy freeze input zero point");
        check_value(pool_enable, 1, "busy freeze pool enable");
        check_value(pool_stride, 2, "busy freeze pool stride");
        check_value(stream_batch_mode, 1, "busy freeze stream mode");
        check_value(stream_raw_hwc_mode, 1, "busy freeze raw hwc mode");
        check_value(stream_bias_packets, 7, "busy freeze bias packets");
        check_value(stream_weight_packets, 11, "busy freeze weight packets");
        check_value(stream_ifm_packets, 13, "busy freeze ifm packets");
        check_value(tail_cycles_config, 96, "busy freeze tail config");
        check_value(raw_hwc_compute_start_level, 64, "busy freeze raw start level");

        write_reg(6'h00, 32'd1);
        repeat (2) @(negedge clk);
        check_value(start_pulse_count, 1, "busy ignores start");

        layer_busy = 1'b0;
        write_reg(6'h01, {7'd0, 9'd9, 7'd0, 9'd8});
        write_reg(6'h00, 32'd1);
        repeat (2) @(negedge clk);
        check_value(fm_h, 8, "idle accepts fm_h");
        check_value(fm_w, 9, "idle accepts fm_w");
        check_value(start_pulse_count, 2, "idle accepts start");
        cfg_addr = 6'h2d;
        #1;
        check_value(cfg_rdata, 0, "start clears stage counters");
        cfg_addr = 6'h2f;
        #1;
        check_value(cfg_rdata, 0, "start clears subperf counters");

        write_reg(6'h00, 32'd2);
        write_reg(6'h03, {15'd0, 1'b1, 6'd0, 2'd0, 6'd0, 2'd1});
        write_reg(6'h06, 32'd12);
        write_reg(6'h19, 32'd0);
        write_reg(6'h00, 32'd1);
        repeat (2) @(negedge clk);
        check_value(start_pulse_count, 2, "native 1x1 rejects legacy mode");
        check_value(config_error, 1, "native 1x1 legacy config error");

        write_reg(6'h00, 32'd2);
        write_reg(6'h19, 32'd1);
        write_reg(6'h06, 32'd65);
        write_reg(6'h00, 32'd1);
        repeat (2) @(negedge clk);
        check_value(start_pulse_count, 2, "native 1x1 rejects oversized tile");
        check_value(config_error, 1, "native 1x1 depth config error");

        write_reg(6'h00, 32'd2);
        write_reg(6'h06, 32'd64);
        write_reg(6'h00, 32'd1);
        repeat (2) @(negedge clk);
        check_value(start_pulse_count, 3, "native 1x1 accepts valid config");
        check_value(kernel_1x1, 1, "native 1x1 mode");
        check_value(config_error, 0, "native 1x1 valid config no error");

        cfg_addr = 6'h24;
        #1;
        check_value(cfg_rdata, 17, "vector packet counter");
        cfg_addr = 6'h25;
        #1;
        check_value(cfg_rdata, 19, "vector pixel counter");
        cfg_addr = 6'h26;
        #1;
        check_value(cfg_rdata, 23, "vector beat counter");
        cfg_addr = 6'h27;
        #1;
        check_value(cfg_rdata, 29, "vector stall counter");
        cfg_addr = 6'h3c;
        #1;
        check_value(cfg_rdata, 31, "raw load active counter");
        cfg_addr = 6'h3d;
        #1;
        check_value(cfg_rdata, 37, "raw load unpack counter");
        cfg_addr = 6'h3e;
        #1;
        check_value(cfg_rdata, 41, "raw replay active counter");
        cfg_addr = 6'h3f;
        #1;
        check_value(cfg_rdata, 43, "raw replay wait-ready counter");

        $display("=== tb_layer_config_regs: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

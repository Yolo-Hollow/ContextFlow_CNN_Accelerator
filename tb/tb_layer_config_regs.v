`timescale 1ns / 1ps

module tb_layer_config_regs;
    reg clk, rst;
    reg cfg_wr_en;
    reg [5:0] cfg_addr;
    reg [31:0] cfg_wdata;
    reg cfg_rd_en;
    wire [31:0] cfg_rdata;
    reg layer_busy, layer_done;
    wire start_pulse;
    wire [8:0] fm_h, fm_w, ofm_h, ofm_w;
    wire [1:0] conv_stride, conv_pad;
    wire [1:0] activation_mode;
    wire [10:0] k_total, cout_total;
    wire [15:0] num_pixels;
    wire [8:0] tile_oy_base, tile_ofm_h;
    wire [23:0] tile_pixel_base;
    wire [7:0] input_zero_point;
    wire pool_enable;
    wire [1:0] pool_stride;
    wire [31:0] expected_bytes;

    layer_config_regs dut (
        .clk(clk), .rst(rst),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_rd_en(cfg_rd_en), .cfg_rdata(cfg_rdata),
        .layer_busy(layer_busy), .layer_done(layer_done),
        .dbg_expected_bytes(32'd0), .dbg_core_wr_count(32'd0),
        .dbg_axis_wr_count(32'd0), .dbg_tlast_count(32'd0),
        .dbg_last_tlast_index(32'd0), .start_pulse(start_pulse),
        .fm_h(fm_h), .fm_w(fm_w), .ofm_h(ofm_h), .ofm_w(ofm_w),
        .conv_stride(conv_stride), .conv_pad(conv_pad),
        .activation_mode(activation_mode),
        .k_total(k_total), .cout_total(cout_total), .num_pixels(num_pixels),
        .tile_oy_base(tile_oy_base), .tile_ofm_h(tile_ofm_h),
        .tile_pixel_base(tile_pixel_base),
        .input_zero_point(input_zero_point),
        .pool_enable(pool_enable), .pool_stride(pool_stride),
        .expected_bytes(expected_bytes)
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
        pass = 0;
        fail = 0;
        start_pulse_count = 0;

        repeat (3) @(negedge clk);
        rst = 0;

        write_reg(6'h01, {7'd0, 9'd5, 7'd0, 9'd7});
        write_reg(6'h02, {7'd0, 9'd3, 7'd0, 9'd4});
        write_reg(6'h03, {22'd0, 2'd1, 6'd0, 2'd2});
        write_reg(6'h04, 32'd45);
        write_reg(6'h05, 32'd10);
        write_reg(6'h06, 32'd12);
        write_reg(6'h07, 32'd2);
        write_reg(6'h08, {7'd0, 9'd3, 7'd0, 9'd2});
        write_reg(6'h09, 32'd6);
        write_reg(6'h0f, 32'd36);
        write_reg(6'h10, {28'd0, 2'd2, 1'b0, 1'b1});

        check_value(fm_h, 7, "fm_h");
        check_value(fm_w, 5, "fm_w");
        check_value(ofm_h, 4, "ofm_h");
        check_value(ofm_w, 3, "ofm_w");
        check_value(conv_stride, 2, "stride");
        check_value(conv_pad, 1, "pad");
        check_value(k_total, 45, "k_total");
        check_value(cout_total, 10, "cout_total");
        check_value(num_pixels, 12, "num_pixels");
        check_value(activation_mode, 2, "activation");
        check_value(tile_oy_base, 2, "tile_oy_base");
        check_value(tile_ofm_h, 3, "tile_ofm_h");
        check_value(tile_pixel_base, 6, "tile_pixel_base");
        check_value(input_zero_point, 36, "input_zero_point");
        check_value(pool_enable, 1, "pool_enable");
        check_value(pool_stride, 2, "pool_stride");

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
        check_value(fm_h, 7, "busy freeze fm_h");
        check_value(fm_w, 5, "busy freeze fm_w");
        check_value(k_total, 45, "busy freeze k_total");
        check_value(activation_mode, 2, "busy freeze activation");
        check_value(tile_oy_base, 2, "busy freeze tile_oy_base");
        check_value(tile_ofm_h, 3, "busy freeze tile_ofm_h");
        check_value(tile_pixel_base, 6, "busy freeze pixel base");
        check_value(input_zero_point, 36, "busy freeze input zero point");
        check_value(pool_enable, 1, "busy freeze pool enable");
        check_value(pool_stride, 2, "busy freeze pool stride");

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

        $display("=== tb_layer_config_regs: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

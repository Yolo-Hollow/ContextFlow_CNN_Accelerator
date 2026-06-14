`timescale 1ns / 1ps

module tb_conv_accel_core_axi_lite_quant_lut;
    localparam ROWS = 18;
    localparam COLS = 16;
    localparam COUT_TILE = COLS * 2;
    localparam IFM_BANKS = 2;
    localparam OFM_ADDR_W = 24;

    reg clk, rst;
    reg  [8:0]  awaddr;
    reg         awvalid;
    wire        awready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;
    reg  [8:0]  araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;

    wire bias_load_req;
    reg bias_load_done;
    wire weight_load_req;
    reg weight_tile_ready;
    wire feeder_fill_req;
    wire [8:0] feeder_fill_fy;
    wire [10:0] current_cout_base;
    wire [10:0] current_pass_base_k;
    wire [10:0] configured_cout_total;
    wire [15:0] configured_num_pixels;
    wire [7:0] configured_input_zero_point;
    wire [8:0] configured_ofm_w;
    wire configured_pool_enable;
    wire [1:0] configured_pool_stride;
    wire [31:0] configured_expected_bytes;

    reg [5:0] bias_wr_addr;
    reg [31:0] bias_wr_data;
    reg bias_wr_en;
    reg wgt_tile_wr_en;
    reg [10:0] wgt_tile_wr_addr;
    reg [7:0] wgt_tile_wr_data;
    reg [IFM_BANKS-1:0] dma_bank_wr_en;
    reg [8:0] dma_wr_x;
    reg [9:0] dma_wr_fy;
    reg [7:0] dma_wr_data [0:IFM_BANKS-1];
    reg dma_line_advance;

    reg quant_wr_en;
    reg [5:0] quant_wr_addr;
    reg [31:0] quant_wr_data;
    reg [5:0] quant_rd_addr;
    wire [31:0] quant_rd_data;
    reg act_lut_wr_en;
    reg [7:0] act_lut_wr_addr;
    reg [7:0] act_lut_wr_data;

    wire ofm_mem_wr_en;
    wire [OFM_ADDR_W-1:0] ofm_mem_wr_addr;
    wire [7:0] ofm_mem_wr_data;
    wire ofm_packet_full;

    conv_accel_core_axi_lite #(
        .ROWS(ROWS), .COLS(COLS), .K_TILE(ROWS), .COUT_TILE(COUT_TILE),
        .IFM_BANKS(IFM_BANKS), .WGT_TILE_AW(11),
        .OFM_ADDR_W(OFM_ADDR_W)
    ) dut (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
        .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
        .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .bias_load_req(bias_load_req), .bias_load_done(bias_load_done),
        .current_cout_base(current_cout_base), .current_pass_base_k(current_pass_base_k),
        .configured_cout_total(configured_cout_total),
        .configured_num_pixels(configured_num_pixels),
        .configured_input_zero_point(configured_input_zero_point),
        .configured_ofm_w(configured_ofm_w),
        .configured_pool_enable(configured_pool_enable),
        .configured_pool_stride(configured_pool_stride),
        .configured_expected_bytes(configured_expected_bytes),
        .debug_expected_bytes(32'd0), .debug_core_wr_count(32'd0),
        .debug_axis_wr_count(32'd0), .debug_tlast_count(32'd0),
        .debug_last_tlast_index(32'd0),
        .raw_hwc_load_active_cycles(32'd0),
        .raw_hwc_load_unpack_cycles(32'd0),
        .raw_hwc_replay_active_cycles(32'd0),
        .raw_hwc_replay_wait_ready_cycles(32'd0),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .weight_load_req(weight_load_req), .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en), .wgt_tile_wr_addr(wgt_tile_wr_addr),
        .wgt_tile_wr_data(wgt_tile_wr_data),
        .wgt_tile_wr8_en(1'b0), .wgt_tile_wr8_addr(11'd0),
        .wgt_tile_wr8_data(64'd0), .wgt_tile_wr8_keep(8'd0),
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .quant_wr_en(quant_wr_en), .quant_wr_addr(quant_wr_addr),
        .quant_wr_data(quant_wr_data), .quant_rd_addr(quant_rd_addr),
        .quant_rd_data(quant_rd_data),
        .act_lut_wr_en(act_lut_wr_en), .act_lut_wr_addr(act_lut_wr_addr),
        .act_lut_wr_data(act_lut_wr_data),
        .ofm_mem_wr_en(ofm_mem_wr_en), .ofm_mem_wr_ready(1'b1),
        .ofm_mem_wr_addr(ofm_mem_wr_addr), .ofm_mem_wr_data(ofm_mem_wr_data),
        .ofm_packet_full(ofm_packet_full)
    );

    always #5 clk = ~clk;

    integer pass, fail, b;
    reg [31:0] rd;

    task axi_write;
        input [7:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            awaddr = addr;
            wdata = data;
            wstrb = 4'hf;
            awvalid = 1'b1;
            wvalid = 1'b1;
            wait(awready && wready);
            @(negedge clk);
            awvalid = 1'b0;
            wvalid = 1'b0;
            wait(bvalid);
            if (bresp !== 2'b00) begin
                $display("[FAIL] write addr=%h bresp=%b", addr, bresp);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
            @(negedge clk);
        end
    endtask

    task axi_read;
        input [7:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            araddr = addr;
            arvalid = 1'b1;
            wait(arready);
            @(negedge clk);
            arvalid = 1'b0;
            wait(rvalid);
            data = rdata;
            if (rresp !== 2'b00) begin
                $display("[FAIL] read addr=%h rresp=%b", addr, rresp);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
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
            end else begin
                pass = pass + 1;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        awaddr = 8'd0;
        awvalid = 1'b0;
        wdata = 32'd0;
        wstrb = 4'd0;
        wvalid = 1'b0;
        bready = 1'b1;
        araddr = 8'd0;
        arvalid = 1'b0;
        rready = 1'b1;
        bias_load_done = 1'b0;
        weight_tile_ready = 1'b0;
        bias_wr_addr = 6'd0;
        bias_wr_data = 32'd0;
        bias_wr_en = 1'b0;
        wgt_tile_wr_en = 1'b0;
        wgt_tile_wr_addr = 11'd0;
        wgt_tile_wr_data = 8'd0;
        dma_bank_wr_en = {IFM_BANKS{1'b0}};
        dma_wr_x = 9'd0;
        dma_wr_fy = 10'd0;
        for (b = 0; b < IFM_BANKS; b = b + 1)
            dma_wr_data[b] = 8'd0;
        dma_line_advance = 1'b0;
        quant_wr_en = 1'b0;
        quant_wr_addr = 6'd0;
        quant_wr_data = 32'd0;
        quant_rd_addr = 6'd0;
        act_lut_wr_en = 1'b0;
        act_lut_wr_addr = 8'd0;
        act_lut_wr_data = 8'd0;
        pass = 0;
        fail = 0;

        repeat (4) @(negedge clk);
        rst = 1'b0;

        axi_write(8'h80, 32'd7);
        axi_read(8'h80, rd);
        check_eq(rd, 32'd7, "quant addr");
        axi_write(8'h84, {8'h45, 4'd0, 4'd9, 16'h1234});
        axi_read(8'h84, rd);
        check_eq(rd, {8'h45, 4'd0, 4'd9, 16'h1234}, "quant data readback");

        axi_write(8'h80, 32'd31);
        axi_write(8'h84, {8'h80, 4'd0, 4'd7, 16'h4321});
        axi_read(8'h84, rd);
        check_eq(rd, {8'h80, 4'd0, 4'd7, 16'h4321}, "quant lane31 readback");

        quant_rd_addr = 6'd7;
        #1;
        check_eq(quant_rd_data, {8'h45, 4'd0, 4'd9, 16'h1234}, "legacy quant read port");

        axi_write(8'h88, 32'h0000_00a5);
        axi_read(8'h88, rd);
        check_eq(rd, 32'h0000_00a5, "lut addr");
        axi_write(8'h8c, 32'h0000_005c);
        axi_read(8'h8c, rd);
        check_eq(rd, 32'h0000_005c, "lut data readback");

        act_lut_wr_addr = 8'h12;
        act_lut_wr_data = 8'h34;
        @(negedge clk);
        act_lut_wr_en = 1'b1;
        @(negedge clk);
        act_lut_wr_en = 1'b0;
        axi_write(8'h88, 32'h0000_0012);
        axi_read(8'h8c, rd);
        check_eq(rd, 32'h0000_0034, "legacy lut write shadow");

        $display("=== tb_conv_accel_core_axi_lite_quant_lut: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (2000) @(negedge clk);
        $display("[FAIL] timeout");
        $fatal(1);
    end
endmodule

`timescale 1ns / 1ps

// AXI-Lite configured convolution accelerator with 64-bit AXI-Stream data ports.
//
// This is the first formal AXI-Stream boundary top. It keeps the proven
// conv_accel_core_axi_lite datapath and only replaces the local data movement
// pins with thin protocol wrappers:
//   - bias AXI-Stream input: 2x int32 per 64-bit beat
//   - weight AXI-Stream input: 8x int8 per 64-bit beat
//   - IFM line AXI-Stream input: 5 bank bytes per 64-bit beat
//   - OFM AXI-Stream debug output: {addr, data} per 64-bit beat
module conv_accel_core_axi_lite_axis_stream #(
    parameter ROWS = 32,
    parameter COLS = 32,
    parameter IFM_W = 8,
    parameter WEIGHT_W = 8,
    parameter PSUM_W = 32,
    parameter IFM_FIFO_DEPTH = 256,
    parameter IFM_FIFO_AW = 8,
    parameter WGT_FIFO_DEPTH = 64,
    parameter WGT_FIFO_AW = 6,
    parameter PSUM_FIFO_DEPTH = 256,
    parameter PSUM_FIFO_AW = 8,
    parameter FM_W_MAX = 416,
    parameter FM_H_MAX = 416,
    parameter K_TILE = 32,
    parameter COUT_TILE = 64,
    parameter IFM_BANKS = 5,
    parameter WGT_TILE_AW = 11,
    parameter PSUM_BUF_AW = 10,
    parameter PSUM_BUF_DEPTH = 1024,
    parameter MULT_W = 16,
    parameter SHIFT_W = 4,
    parameter ZP_W = 8,
    parameter OFM_ADDR_W = 24,
    parameter OFM_FIFO_DEPTH = 32,
    parameter OFM_FIFO_AW = 5,
    parameter AXIS_W = 64,
    parameter AXIS_KEEP_W = AXIS_W / 8
) (
    input  clk,
    input  rst,

    input  [7:0]  s_axi_awaddr,
    input         s_axi_awvalid,
    output        s_axi_awready,
    input  [31:0] s_axi_wdata,
    input  [3:0]  s_axi_wstrb,
    input         s_axi_wvalid,
    output        s_axi_wready,
    output [1:0]  s_axi_bresp,
    output        s_axi_bvalid,
    input         s_axi_bready,
    input  [7:0]  s_axi_araddr,
    input         s_axi_arvalid,
    output        s_axi_arready,
    output [31:0] s_axi_rdata,
    output [1:0]  s_axi_rresp,
    output        s_axi_rvalid,
    input         s_axi_rready,

    output bias_load_req,
    output weight_load_req,
    output feeder_fill_req,
    output [8:0] feeder_fill_fy,
    output [10:0] current_cout_base,
    output [10:0] current_pass_base_k,

    output                 bias_s_axis_tready,
    input                  bias_s_axis_tvalid,
    input  [AXIS_W-1:0]    bias_s_axis_tdata,
    input  [AXIS_KEEP_W-1:0] bias_s_axis_tkeep,
    input                  bias_s_axis_tlast,

    output                 weight_s_axis_tready,
    input                  weight_s_axis_tvalid,
    input  [AXIS_W-1:0]    weight_s_axis_tdata,
    input  [AXIS_KEEP_W-1:0] weight_s_axis_tkeep,
    input                  weight_s_axis_tlast,

    input  [8:0]           ifm_line_words,
    output                 ifm_s_axis_tready,
    input                  ifm_s_axis_tvalid,
    input  [AXIS_W-1:0]    ifm_s_axis_tdata,
    input  [AXIS_KEEP_W-1:0] ifm_s_axis_tkeep,
    input                  ifm_s_axis_tlast,

    input         quant_wr_en,
    input  [5:0]  quant_wr_addr,
    input  [31:0] quant_wr_data,
    input  [5:0]  quant_rd_addr,
    output [31:0] quant_rd_data,
    input         act_lut_wr_en,
    input  [7:0]  act_lut_wr_addr,
    input  [7:0]  act_lut_wr_data,

    output                      ofm_mem_wr_en,
    output [OFM_ADDR_W-1:0]     ofm_mem_wr_addr,
    output [7:0]                ofm_mem_wr_data,
    output [AXIS_W-1:0]         ofm_m_axis_tdata,
    output [AXIS_KEEP_W-1:0]    ofm_m_axis_tkeep,
    output                      ofm_m_axis_tvalid,
    input                       ofm_m_axis_tready,
    output                      ofm_m_axis_tlast,

    output                      ofm_packet_full,
    output                      bias_axis_error,
    output                      weight_axis_error,
    output                      ifm_axis_error
);
    wire bias_load_done;
    wire bias_wr_en;
    wire [5:0] bias_wr_addr;
    wire [PSUM_W-1:0] bias_wr_data;
    wire weight_tile_ready;
    wire wgt_tile_wr_en;
    wire [WGT_TILE_AW-1:0] wgt_tile_wr_addr;
    wire [WEIGHT_W-1:0] wgt_tile_wr_data;

    wire [IFM_BANKS-1:0] dma_bank_wr_en;
    wire [8:0] dma_wr_x;
    wire [9:0] dma_wr_fy;
    wire [7:0] dma_wr_data [0:IFM_BANKS-1];
    wire dma_line_advance;

    wire core_ofm_wr_en;
    wire core_ofm_wr_ready;
    wire [OFM_ADDR_W-1:0] core_ofm_wr_addr;
    wire [7:0] core_ofm_wr_data;
    wire ofm_stream_valid;
    wire ofm_stream_ready;
    wire [OFM_ADDR_W-1:0] ofm_stream_addr;
    wire [7:0] ofm_stream_data;
    wire ofm_stream_full;
    wire ofm_stream_almost_full;
    wire [10:0] configured_cout_total;
    wire [15:0] configured_num_pixels;

    wire bias_tkeep_error;
    wire bias_tlast_error;
    wire weight_tkeep_error;
    wire weight_tlast_error;
    wire ifm_tkeep_error;
    wire ifm_tlast_error;
    reg [31:0] ofm_byte_count;
    reg [31:0] core_ofm_wr_count;
    reg [31:0] axis_ofm_wr_count;
    reg [31:0] axis_tlast_count;
    reg [31:0] last_tlast_index;
    wire [31:0] ofm_expected_bytes = configured_num_pixels * configured_cout_total;
    wire core_ofm_wr_fire = core_ofm_wr_en && core_ofm_wr_ready;
    wire ofm_stream_fire = ofm_stream_valid && ofm_stream_ready;
    wire ofm_stream_last = ofm_stream_valid && (ofm_expected_bytes != 32'd0) &&
                           (ofm_byte_count == ofm_expected_bytes - 1'b1);

    assign ofm_mem_wr_en = ofm_stream_valid && ofm_stream_ready;
    assign ofm_mem_wr_addr = ofm_stream_addr;
    assign ofm_mem_wr_data = ofm_stream_data;
    assign bias_axis_error = bias_tkeep_error || bias_tlast_error;
    assign weight_axis_error = weight_tkeep_error || weight_tlast_error;
    assign ifm_axis_error = ifm_tkeep_error || ifm_tlast_error;
    always @(posedge clk) begin
        if (rst) begin
            ofm_byte_count <= 32'd0;
            core_ofm_wr_count <= 32'd0;
            axis_ofm_wr_count <= 32'd0;
            axis_tlast_count <= 32'd0;
            last_tlast_index <= 32'd0;
        end else begin
            if (core_ofm_wr_fire)
                core_ofm_wr_count <= core_ofm_wr_count + 1'b1;

            if (ofm_stream_fire) begin
                axis_ofm_wr_count <= axis_ofm_wr_count + 1'b1;
                if (ofm_stream_last)
                    ofm_byte_count <= 32'd0;
                else
                    ofm_byte_count <= ofm_byte_count + 1'b1;
                if (ofm_stream_last) begin
                    axis_tlast_count <= axis_tlast_count + 1'b1;
                    last_tlast_index <= axis_ofm_wr_count + 1'b1;
                end
            end
        end
    end

    axis_bias_weight_loader #(
        .ROWS(ROWS),
        .COLS(COLS),
        .PSUM_W(PSUM_W),
        .WEIGHT_W(WEIGHT_W),
        .BIAS_ADDR_W(6),
        .WGT_ADDR_W(WGT_TILE_AW),
        .AXIS_W(AXIS_W),
        .KEEP_W(AXIS_KEEP_W)
    ) u_axis_bw_loader (
        .clk(clk),
        .rst(rst),
        .bias_load_req(bias_load_req),
        .bias_s_axis_tready(bias_s_axis_tready),
        .bias_s_axis_tvalid(bias_s_axis_tvalid),
        .bias_s_axis_tdata(bias_s_axis_tdata),
        .bias_s_axis_tkeep(bias_s_axis_tkeep),
        .bias_s_axis_tlast(bias_s_axis_tlast),
        .bias_load_done(bias_load_done),
        .bias_wr_en(bias_wr_en),
        .bias_wr_addr(bias_wr_addr),
        .bias_wr_data(bias_wr_data),
        .weight_load_req(weight_load_req),
        .weight_s_axis_tready(weight_s_axis_tready),
        .weight_s_axis_tvalid(weight_s_axis_tvalid),
        .weight_s_axis_tdata(weight_s_axis_tdata),
        .weight_s_axis_tkeep(weight_s_axis_tkeep),
        .weight_s_axis_tlast(weight_s_axis_tlast),
        .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en),
        .wgt_tile_wr_addr(wgt_tile_wr_addr),
        .wgt_tile_wr_data(wgt_tile_wr_data),
        .bias_tkeep_error(bias_tkeep_error),
        .bias_tlast_error(bias_tlast_error),
        .weight_tkeep_error(weight_tkeep_error),
        .weight_tlast_error(weight_tlast_error)
    );

    axis_ifm_line_loader #(
        .AW(9),
        .AXIS_W(AXIS_W),
        .KEEP_W(AXIS_KEEP_W),
        .BANKS(IFM_BANKS)
    ) u_axis_ifm_loader (
        .clk(clk),
        .rst(rst),
        .fm_w(ifm_line_words),
        .fill_req(feeder_fill_req),
        .fill_fy(feeder_fill_fy),
        .s_axis_tready(ifm_s_axis_tready),
        .s_axis_tvalid(ifm_s_axis_tvalid),
        .s_axis_tdata(ifm_s_axis_tdata),
        .s_axis_tkeep(ifm_s_axis_tkeep),
        .s_axis_tlast(ifm_s_axis_tlast),
        .dma_bank_wr_en(dma_bank_wr_en),
        .dma_wr_x(dma_wr_x),
        .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data),
        .dma_line_advance(dma_line_advance),
        .tkeep_error(ifm_tkeep_error),
        .tlast_error(ifm_tlast_error)
    );

    conv_accel_core_axi_lite #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WEIGHT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_FIFO_DEPTH), .IFM_FIFO_AW(IFM_FIFO_AW),
        .WGT_FIFO_DEPTH(WGT_FIFO_DEPTH), .WGT_FIFO_AW(WGT_FIFO_AW),
        .PSUM_FIFO_DEPTH(PSUM_FIFO_DEPTH), .PSUM_FIFO_AW(PSUM_FIFO_AW),
        .FM_W_MAX(FM_W_MAX), .FM_H_MAX(FM_H_MAX),
        .K_TILE(K_TILE), .COUT_TILE(COUT_TILE), .IFM_BANKS(IFM_BANKS),
        .WGT_TILE_AW(WGT_TILE_AW), .PSUM_BUF_AW(PSUM_BUF_AW), .PSUM_BUF_DEPTH(PSUM_BUF_DEPTH),
        .MULT_W(MULT_W), .SHIFT_W(SHIFT_W), .ZP_W(ZP_W),
        .OFM_ADDR_W(OFM_ADDR_W), .OFM_FIFO_DEPTH(OFM_FIFO_DEPTH), .OFM_FIFO_AW(OFM_FIFO_AW)
    ) u_core (
        .clk(clk),
        .rst(rst),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .bias_load_req(bias_load_req),
        .bias_load_done(bias_load_done),
        .current_cout_base(current_cout_base),
        .current_pass_base_k(current_pass_base_k),
        .configured_cout_total(configured_cout_total),
        .configured_num_pixels(configured_num_pixels),
        .debug_expected_bytes(ofm_expected_bytes),
        .debug_core_wr_count(core_ofm_wr_count),
        .debug_axis_wr_count(axis_ofm_wr_count),
        .debug_tlast_count(axis_tlast_count),
        .debug_last_tlast_index(last_tlast_index),
        .bias_wr_addr(bias_wr_addr),
        .bias_wr_data(bias_wr_data),
        .bias_wr_en(bias_wr_en),
        .weight_load_req(weight_load_req),
        .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en),
        .wgt_tile_wr_addr(wgt_tile_wr_addr),
        .wgt_tile_wr_data(wgt_tile_wr_data),
        .feeder_fill_req(feeder_fill_req),
        .feeder_fill_fy(feeder_fill_fy),
        .dma_bank_wr_en(dma_bank_wr_en),
        .dma_wr_x(dma_wr_x),
        .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data),
        .dma_line_advance(dma_line_advance),
        .quant_wr_en(quant_wr_en),
        .quant_wr_addr(quant_wr_addr),
        .quant_wr_data(quant_wr_data),
        .quant_rd_addr(quant_rd_addr),
        .quant_rd_data(quant_rd_data),
        .act_lut_wr_en(act_lut_wr_en),
        .act_lut_wr_addr(act_lut_wr_addr),
        .act_lut_wr_data(act_lut_wr_data),
        .ofm_mem_wr_en(core_ofm_wr_en),
        .ofm_mem_wr_ready(core_ofm_wr_ready),
        .ofm_mem_wr_addr(core_ofm_wr_addr),
        .ofm_mem_wr_data(core_ofm_wr_data),
        .ofm_packet_full(ofm_packet_full)
    );

    ofm_byte_stream_fifo #(
        .ADDR_W(OFM_ADDR_W),
        .DEPTH(OFM_FIFO_DEPTH),
        .AW(OFM_FIFO_AW)
    ) u_ofm_stream_fifo (
        .clk(clk),
        .rst(rst),
        .wr_en(core_ofm_wr_en),
        .wr_ready(core_ofm_wr_ready),
        .wr_addr(core_ofm_wr_addr),
        .wr_data(core_ofm_wr_data),
        .m_valid(ofm_stream_valid),
        .m_ready(ofm_stream_ready),
        .m_addr(ofm_stream_addr),
        .m_data(ofm_stream_data),
        .full(ofm_stream_full),
        .almost_full(ofm_stream_almost_full)
    );

    axis_ofm_byte_writer #(
        .OFM_ADDR_W(OFM_ADDR_W),
        .AXIS_W(AXIS_W),
        .KEEP_W(AXIS_KEEP_W)
    ) u_axis_ofm_writer (
        .byte_addr(ofm_stream_addr),
        .byte_data(ofm_stream_data),
        .byte_valid(ofm_stream_valid),
        .byte_ready(ofm_stream_ready),
        .byte_last(ofm_stream_last),
        .m_axis_tdata(ofm_m_axis_tdata),
        .m_axis_tkeep(ofm_m_axis_tkeep),
        .m_axis_tvalid(ofm_m_axis_tvalid),
        .m_axis_tready(ofm_m_axis_tready),
        .m_axis_tlast(ofm_m_axis_tlast)
    );
endmodule

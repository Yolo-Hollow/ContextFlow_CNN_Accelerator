`timescale 1ns / 1ps

// AXI-Lite configured convolution accelerator with 64-bit AXI-Stream data ports.
//
// This is the first formal AXI-Stream boundary top. It keeps the proven
// conv_accel_core_axi_lite datapath and only replaces the local data movement
// pins with thin protocol wrappers:
//   - bias AXI-Stream input: 2x int32 per 64-bit beat
//   - weight AXI-Stream input: 8x int8 per 64-bit beat
//   - IFM AXI-Stream input: 3x3 line packets or native 1x1 vectors
//   - OFM AXI-Stream debug output: {addr, data} per 64-bit beat
`ifndef SYSTOLIC_TAIL_CYCLES_CONFIG
`define SYSTOLIC_TAIL_CYCLES_CONFIG 0
`endif

module conv_accel_core_axi_lite_axis_stream #(
    parameter ROWS = 32,
    parameter COLS = 32,
    parameter IFM_W = 8,
    parameter WEIGHT_W = 8,
    parameter PSUM_W = 32,
    parameter IFM_FIFO_DEPTH = 1024,
    parameter IFM_FIFO_AW = 10,
    parameter WGT_FIFO_DEPTH = 64,
    parameter WGT_FIFO_AW = 6,
    parameter PSUM_FIFO_DEPTH = 1024,
    parameter PSUM_FIFO_AW = 10,
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
    parameter HWC_CACHE_AW = 12,
    parameter HWC_CACHE_DEPTH = (1 << HWC_CACHE_AW),
    parameter HWC_CACHE_STRIPES = 1,
    parameter HWC_CACHE_USE_URAM = 0,
    parameter AXIS_W = 64,
    parameter AXIS_KEEP_W = AXIS_W / 8,
    parameter TAIL_CYCLES_CONFIG = `SYSTOLIC_TAIL_CYCLES_CONFIG
) (
    input  clk,
    input  rst,

    input  [8:0]  s_axi_awaddr,
    input         s_axi_awvalid,
    output        s_axi_awready,
    input  [31:0] s_axi_wdata,
    input  [3:0]  s_axi_wstrb,
    input         s_axi_wvalid,
    output        s_axi_wready,
    output [1:0]  s_axi_bresp,
    output        s_axi_bvalid,
    input         s_axi_bready,
    input  [8:0]  s_axi_araddr,
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
    output [13:0] current_pass_base_k,

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
    wire wgt_tile_wr8_en;
    wire [WGT_TILE_AW-1:0] wgt_tile_wr8_addr;
    wire [WEIGHT_W*8-1:0] wgt_tile_wr8_data;
    wire [7:0] wgt_tile_wr8_keep;

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
    wire [7:0] configured_input_zero_point;
    wire [8:0] configured_fm_h;
    wire [8:0] configured_fm_w;
    wire [8:0] configured_ofm_w;
    wire [8:0] configured_tile_oy_base;
    wire [8:0] configured_tile_ofm_h;
    wire [1:0] configured_conv_stride;
    wire [1:0] configured_conv_pad;
    wire [13:0] configured_k_total;
    wire configured_pool_enable;
    wire [1:0] configured_pool_stride;
    wire [31:0] configured_expected_bytes;
    wire configured_stream_batch_mode;
    wire configured_stream_raw_hwc_mode;
    wire [31:0] configured_stream_bias_packets;
    wire [31:0] configured_stream_weight_packets;
    wire [31:0] configured_stream_ifm_packets;
    wire configured_stream_reset;
    wire configured_kernel_1x1;
    wire configured_config_error;
    wire [13:0] current_feeder_pass_base_k;
    wire [31:0] bias_completed_packets;
    wire [31:0] weight_completed_packets;
    wire [31:0] line_completed_packets;
    wire [31:0] vector_completed_packets;
    wire [31:0] raw_hwc_completed_packets;
    wire [31:0] raw_hwc_completed_pixels;
    wire [31:0] raw_hwc_accepted_beats;
    wire [31:0] raw_hwc_fifo_stall_cycles;
    wire [31:0] raw_hwc_load_active_cycles;
    wire [31:0] raw_hwc_load_unpack_cycles;
    wire [31:0] raw_hwc_replay_active_cycles;
    wire [31:0] raw_hwc_replay_wait_ready_cycles;
    wire [31:0] vector_completed_pixels;
    wire [31:0] vector_accepted_beats;
    wire [31:0] vector_fifo_stall_cycles;
    wire [31:0] ifm_completed_packets =
        configured_stream_raw_hwc_mode ? raw_hwc_completed_packets :
        (configured_kernel_1x1 ? vector_completed_packets : line_completed_packets);
    wire [ROWS*IFM_W-1:0] vector_loader_ifm_data;
    wire vector_loader_ifm_valid;
    wire vector_ifm_ready;
    wire vector_loader_packet_done;
    wire [ROWS*IFM_W-1:0] raw_hwc_ifm_data;
    wire raw_hwc_ifm_valid;
    wire raw_hwc_packet_done;
    wire [ROWS*IFM_W-1:0] vector_ifm_data =
        configured_stream_raw_hwc_mode ? raw_hwc_ifm_data : vector_loader_ifm_data;
    wire vector_ifm_valid =
        configured_stream_raw_hwc_mode ? raw_hwc_ifm_valid : vector_loader_ifm_valid;
    wire vector_packet_done =
        configured_stream_raw_hwc_mode ? raw_hwc_packet_done : vector_loader_packet_done;
    wire line_ifm_tready;
    wire vector_loader_ifm_tready;
    wire raw_hwc_ifm_tready;

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
    wire [31:0] ofm_expected_bytes = configured_expected_bytes;
    wire core_ofm_wr_fire = core_ofm_wr_en && core_ofm_wr_ready;
    wire ofm_stream_fire = ofm_stream_valid && ofm_stream_ready;
    wire ofm_stream_last = ofm_stream_valid && (ofm_expected_bytes != 32'd0) &&
                           (ofm_byte_count == ofm_expected_bytes - 1'b1);

    assign ofm_mem_wr_en = ofm_stream_valid && ofm_stream_ready;
    assign ofm_mem_wr_addr = ofm_stream_addr;
    assign ofm_mem_wr_data = ofm_stream_data;
    assign bias_axis_error = bias_tkeep_error || bias_tlast_error;
    assign weight_axis_error = weight_tkeep_error || weight_tlast_error;
    wire vector_tkeep_error;
    wire vector_tlast_error;
    wire raw_hwc_tkeep_error;
    wire raw_hwc_tlast_error;
    wire raw_hwc_overflow_error;
    assign ifm_axis_error = configured_config_error ||
                            (configured_stream_raw_hwc_mode ?
                                (raw_hwc_tkeep_error || raw_hwc_tlast_error ||
                                 raw_hwc_overflow_error) :
                                (configured_kernel_1x1 ?
                                    (vector_tkeep_error || vector_tlast_error) :
                                    (ifm_tkeep_error || ifm_tlast_error)));
    assign ifm_s_axis_tready =
        configured_stream_raw_hwc_mode ? raw_hwc_ifm_tready :
        (configured_kernel_1x1 ? vector_loader_ifm_tready : line_ifm_tready);
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
        .stream_reset(configured_stream_reset),
        .batch_mode(configured_stream_batch_mode),
        .bias_expected_packets(configured_stream_bias_packets),
        .weight_expected_packets(configured_stream_weight_packets),
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
        .wgt_tile_wr8_en(wgt_tile_wr8_en),
        .wgt_tile_wr8_addr(wgt_tile_wr8_addr),
        .wgt_tile_wr8_data(wgt_tile_wr8_data),
        .wgt_tile_wr8_keep(wgt_tile_wr8_keep),
        .bias_tkeep_error(bias_tkeep_error),
        .bias_tlast_error(bias_tlast_error),
        .weight_tkeep_error(weight_tkeep_error),
        .weight_tlast_error(weight_tlast_error),
        .bias_completed_packets(bias_completed_packets),
        .weight_completed_packets(weight_completed_packets)
    );

    axis_ifm_line_loader #(
        .AW(9),
        .AXIS_W(AXIS_W),
        .KEEP_W(AXIS_KEEP_W),
        .BANKS(IFM_BANKS)
    ) u_axis_ifm_loader (
        .clk(clk),
        .rst(rst),
        .stream_reset(configured_stream_reset),
        .batch_mode(configured_stream_batch_mode),
        .expected_packets(configured_stream_ifm_packets),
        .fm_w(ifm_line_words),
        .fill_req(feeder_fill_req && !configured_kernel_1x1 &&
                  !configured_stream_raw_hwc_mode),
        .fill_fy(feeder_fill_fy),
        .input_zero_point(configured_input_zero_point),
        .s_axis_tready(line_ifm_tready),
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
        .tlast_error(ifm_tlast_error),
        .completed_packets(line_completed_packets)
    );

    axis_ifm_vector_loader #(
        .ROWS(ROWS),
        .AXIS_W(AXIS_W),
        .KEEP_W(AXIS_KEEP_W)
    ) u_axis_ifm_vector_loader (
        .clk(clk),
        .rst(rst),
        .stream_reset(configured_stream_reset),
        .batch_mode(configured_stream_batch_mode),
        .expected_packets(configured_stream_ifm_packets),
        .num_pixels(configured_num_pixels),
        .input_zero_point(configured_input_zero_point),
        .fill_req(feeder_fill_req && configured_kernel_1x1 &&
                  !configured_stream_raw_hwc_mode),
        .s_axis_tready(vector_loader_ifm_tready),
        .s_axis_tvalid(ifm_s_axis_tvalid),
        .s_axis_tdata(ifm_s_axis_tdata),
        .s_axis_tkeep(ifm_s_axis_tkeep),
        .s_axis_tlast(ifm_s_axis_tlast),
        .vector_data(vector_loader_ifm_data),
        .vector_valid(vector_loader_ifm_valid),
        .vector_ready(vector_ifm_ready),
        .packet_done(vector_loader_packet_done),
        .tkeep_error(vector_tkeep_error),
        .tlast_error(vector_tlast_error),
        .completed_packets(vector_completed_packets),
        .completed_pixels(vector_completed_pixels),
        .accepted_beats(vector_accepted_beats),
        .fifo_stall_cycles(vector_fifo_stall_cycles)
    );

    axis_hwc_tile_cache #(
        .ROWS(ROWS),
        .AXIS_W(AXIS_W),
        .KEEP_W(AXIS_KEEP_W),
        .CACHE_AW(HWC_CACHE_AW),
        .CACHE_DEPTH(HWC_CACHE_DEPTH),
        .CACHE_STRIPES(HWC_CACHE_STRIPES),
        .CACHE_USE_URAM(HWC_CACHE_USE_URAM)
    ) u_axis_hwc_tile_cache (
        .clk(clk),
        .rst(rst),
        .stream_reset(configured_stream_reset && configured_stream_raw_hwc_mode),
        .expected_packets(configured_stream_ifm_packets),
        .num_pixels(configured_num_pixels),
        .fm_h(configured_fm_h),
        .fm_w(configured_fm_w),
        .ofm_w(configured_ofm_w),
        .tile_oy_base(configured_tile_oy_base),
        .tile_ofm_h(configured_tile_ofm_h),
        .conv_stride(configured_conv_stride),
        .conv_pad(configured_conv_pad),
        .kernel_1x1(configured_kernel_1x1),
        .k_total(configured_k_total),
        .pass_base_k(current_feeder_pass_base_k),
        .input_zero_point(configured_input_zero_point),
        .fill_req(feeder_fill_req && configured_stream_raw_hwc_mode),
        .s_axis_tready(raw_hwc_ifm_tready),
        .s_axis_tvalid(ifm_s_axis_tvalid),
        .s_axis_tdata(ifm_s_axis_tdata),
        .s_axis_tkeep(ifm_s_axis_tkeep),
        .s_axis_tlast(ifm_s_axis_tlast),
        .vector_data(raw_hwc_ifm_data),
        .vector_valid(raw_hwc_ifm_valid),
        .vector_ready(vector_ifm_ready),
        .packet_done(raw_hwc_packet_done),
        .tkeep_error(raw_hwc_tkeep_error),
        .tlast_error(raw_hwc_tlast_error),
        .overflow_error(raw_hwc_overflow_error),
        .completed_packets(raw_hwc_completed_packets),
        .completed_pixels(raw_hwc_completed_pixels),
        .accepted_beats(raw_hwc_accepted_beats),
        .fifo_stall_cycles(raw_hwc_fifo_stall_cycles),
        .load_active_cycles(raw_hwc_load_active_cycles),
        .load_unpack_cycles(raw_hwc_load_unpack_cycles),
        .replay_active_cycles(raw_hwc_replay_active_cycles),
        .replay_wait_ready_cycles(raw_hwc_replay_wait_ready_cycles)
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
        .OFM_ADDR_W(OFM_ADDR_W), .OFM_FIFO_DEPTH(OFM_FIFO_DEPTH), .OFM_FIFO_AW(OFM_FIFO_AW),
        .TAIL_CYCLES_CONFIG(TAIL_CYCLES_CONFIG)
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
        .current_feeder_pass_base_k(current_feeder_pass_base_k),
        .configured_cout_total(configured_cout_total),
        .configured_k_total(configured_k_total),
        .configured_num_pixels(configured_num_pixels),
        .configured_input_zero_point(configured_input_zero_point),
        .configured_fm_h(configured_fm_h),
        .configured_fm_w(configured_fm_w),
        .configured_ofm_w(configured_ofm_w),
        .configured_tile_oy_base(configured_tile_oy_base),
        .configured_tile_ofm_h(configured_tile_ofm_h),
        .configured_conv_stride(configured_conv_stride),
        .configured_conv_pad(configured_conv_pad),
        .configured_kernel_1x1(configured_kernel_1x1),
        .configured_pool_enable(configured_pool_enable),
        .configured_pool_stride(configured_pool_stride),
        .configured_expected_bytes(configured_expected_bytes),
        .configured_stream_batch_mode(configured_stream_batch_mode),
        .configured_stream_raw_hwc_mode(configured_stream_raw_hwc_mode),
        .configured_stream_bias_packets(configured_stream_bias_packets),
        .configured_stream_weight_packets(configured_stream_weight_packets),
        .configured_stream_ifm_packets(configured_stream_ifm_packets),
        .configured_stream_reset(configured_stream_reset),
        .configured_config_error(configured_config_error),
        .debug_expected_bytes(ofm_expected_bytes),
        .debug_core_wr_count(core_ofm_wr_count),
        .debug_axis_wr_count(axis_ofm_wr_count),
        .debug_tlast_count(axis_tlast_count),
        .debug_last_tlast_index(last_tlast_index),
        .stream_bias_completed(bias_completed_packets),
        .stream_weight_completed(weight_completed_packets),
        .stream_ifm_completed(ifm_completed_packets),
        .vector_completed_packets(configured_stream_raw_hwc_mode ?
                                  raw_hwc_completed_packets :
                                  vector_completed_packets),
        .vector_completed_pixels(configured_stream_raw_hwc_mode ?
                                 raw_hwc_completed_pixels :
                                 vector_completed_pixels),
        .vector_accepted_beats(configured_stream_raw_hwc_mode ?
                               raw_hwc_accepted_beats :
                               vector_accepted_beats),
        .vector_fifo_stall_cycles(configured_stream_raw_hwc_mode ?
                                  raw_hwc_fifo_stall_cycles :
                                  vector_fifo_stall_cycles),
        .raw_hwc_load_active_cycles(raw_hwc_load_active_cycles),
        .raw_hwc_load_unpack_cycles(raw_hwc_load_unpack_cycles),
        .raw_hwc_replay_active_cycles(raw_hwc_replay_active_cycles),
        .raw_hwc_replay_wait_ready_cycles(raw_hwc_replay_wait_ready_cycles),
        .bias_wr_addr(bias_wr_addr),
        .bias_wr_data(bias_wr_data),
        .bias_wr_en(bias_wr_en),
        .weight_load_req(weight_load_req),
        .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en),
        .wgt_tile_wr_addr(wgt_tile_wr_addr),
        .wgt_tile_wr_data(wgt_tile_wr_data),
        .wgt_tile_wr8_en(wgt_tile_wr8_en),
        .wgt_tile_wr8_addr(wgt_tile_wr8_addr),
        .wgt_tile_wr8_data(wgt_tile_wr8_data),
        .wgt_tile_wr8_keep(wgt_tile_wr8_keep),
        .feeder_fill_req(feeder_fill_req),
        .feeder_fill_fy(feeder_fill_fy),
        .dma_bank_wr_en(dma_bank_wr_en),
        .dma_wr_x(dma_wr_x),
        .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data),
        .dma_line_advance(dma_line_advance),
        .vector_ifm_data(vector_ifm_data),
        .vector_ifm_valid(vector_ifm_valid),
        .vector_ifm_ready(vector_ifm_ready),
        .vector_packet_done(vector_packet_done),
        .quant_wr_en(1'b0),
        .quant_wr_addr(6'd0),
        .quant_wr_data(32'd0),
        .quant_rd_addr(6'd0),
        .quant_rd_data(),
        .act_lut_wr_en(1'b0),
        .act_lut_wr_addr(8'd0),
        .act_lut_wr_data(8'd0),
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

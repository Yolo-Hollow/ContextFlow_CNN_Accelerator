`timescale 1ns / 1ps

// AXI-Lite configured convolution accelerator with 64-bit AXI-Stream data ports.
//
// This is the first formal AXI-Stream boundary top. It keeps the proven
// conv_accel_core_axi_lite datapath and only replaces the local data movement
// pins with thin protocol wrappers:
//   - bias AXI-Stream input: 2x int32 per 64-bit beat
//   - weight AXI-Stream input: 8x int8 per 64-bit beat
//   - IFM AXI-Stream input: 3x3 line packets or native 1x1 vectors
//   - OFM AXI-Stream output: packed uint8 HWC in release mode; the legacy
//     byte/address debug format remains available only when explicitly built
`ifndef SYSTOLIC_TAIL_CYCLES_CONFIG
`define SYSTOLIC_TAIL_CYCLES_CONFIG 0
`endif

module conv_accel_core_axi_lite_axis_stream #(
    parameter integer CLOCK_HZ = 100000000,
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
    parameter MATERIALIZED_CACHE_AW = 15,
    parameter MATERIALIZED_CACHE_DEPTH = (1 << MATERIALIZED_CACHE_AW),
    parameter integer LAYER_LONG_LINE_BANK_DEPTH = 2048,
    parameter AXIS_W = 64,
    parameter AXIS_KEEP_W = AXIS_W / 8,
    parameter TAIL_CYCLES_CONFIG = `SYSTOLIC_TAIL_CYCLES_CONFIG,
    parameter ENABLE_COLUMN_PSUM = 0,
    parameter ENABLE_PACKED_HWC_OFM = 0,
    parameter ENABLE_LAYER_TILE_SEQUENCER = 0,
    parameter ENABLE_LAYER_LONG_HWC_IFM = 0,
    parameter ENABLE_TAGGED_CONTEXT = 0,
    parameter ENABLE_WEIGHT_PRELOAD = 0,
    parameter ENABLE_FAST_CONTEXT_HANDOFF = 0,
    parameter IFM_EPOCH_USE_URAM = 0,
    parameter ENABLE_DETAILED_TRACE = 1,
    parameter PACKED_OFM_MAX_PIXELS = 1024,
    parameter PACKED_OFM_MAX_COUT = 1024,
    parameter PACKED_OFM_BUFFER_DEPTH = 4096
) (
    input  clk,
    input  rst,

    input  [9:0]  s_axi_awaddr,
    input         s_axi_awvalid,
    output        s_axi_awready,
    input  [31:0] s_axi_wdata,
    input  [3:0]  s_axi_wstrb,
    input         s_axi_wvalid,
    output        s_axi_wready,
    output [1:0]  s_axi_bresp,
    output        s_axi_bvalid,
    input         s_axi_bready,
    input  [9:0]  s_axi_araddr,
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
    output                      ifm_axis_error,
    output                      ofm_axis_error
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
    wire packed_ofm_packet_valid;
    wire packed_ofm_packet_ready;
    wire [PSUM_BUF_AW-1:0] packed_ofm_packet_pixel;
    wire [10:0] packed_ofm_packet_cout_base;
    wire [COLS*2-1:0] packed_ofm_packet_channel_valid;
    wire [COLS*2*8-1:0] packed_ofm_packet_data;
    wire packed_ofm_busy;
    wire packed_ofm_tile_free;
    wire packed_tile_begin_ready;
    wire packed_ofm_protocol_error_raw;
    wire packed_ofm_overwrite_error;
    wire packed_ofm_underflow_error;
    wire packed_ofm_protocol_error = packed_ofm_protocol_error_raw ||
                                     packed_ofm_overwrite_error ||
                                     packed_ofm_underflow_error;
    wire packed_ofm_packet_fire =
        packed_ofm_packet_valid && packed_ofm_packet_ready;
    wire [31:0] packed_ofm_accepted_packets;
    wire [31:0] packed_ofm_expected_packets;
    wire [31:0] packed_ofm_axis_valid_cycles;
    wire [31:0] packed_ofm_axis_stall_cycles;
    wire [31:0] packed_ofm_axis_beat_count;
    wire [31:0] packed_ofm_axis_byte_count;
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
    wire [8:0] configured_ofm_h;
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
    wire configured_datapath_reset;
    wire datapath_rst = rst || configured_datapath_reset;
    wire configured_layer_last;
    wire [8:0] configured_tile_h_max;
    wire [31:0] configured_ifm_total_bytes;
    wire [31:0] configured_ofm_total_bytes;
    wire [13:0] validated_long_cin;
    wire [15:0] validated_long_pass_count;
    wire [15:0] validated_long_final_pass;
    wire [ROWS-1:0] validated_long_final_lane_mask;
    wire [31:0] validated_long_layer_pixels;
    wire [31:0] validated_long_tile_pixels;
    wire [31:0] validated_long_tile_output_pixels;
    wire [15:0] validated_long_cout_blocks;
    wire active_tile_start;
    wire active_tile_last;
    wire [8:0] active_tile_oy_base;
    wire [8:0] active_tile_ofm_h;
    wire [15:0] active_tile_num_pixels;
    wire [15:0] active_tile_output_pixels;
    wire [23:0] active_tile_output_pixel_base;
    wire [15:0] active_tile_index;
    wire active_tile_done;
    reg  [15:0] packed_begin_output_pixels_q;
    reg  [10:0] packed_begin_cout_total_q;
    reg         packed_begin_layer_last_q;
    reg  [15:0] packed_begin_cout_blocks_q;
    reg  [31:0] packed_begin_span_q;
    wire [31:0] packed_begin_span_lookahead =
        active_tile_output_pixels * validated_long_cout_blocks;
    wire configured_kernel_1x1;
    wire configured_config_error;
    wire [13:0] current_feeder_pass_base_k;
    wire [15:0] current_feeder_k_pass;
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
    wire layer_long_replay_active;
    wire layer_long_release_ready;
    wire [4:0] layer_long_cache_error_status;
    wire [15:0] layer_long_ifm_error_status;
    wire layer_long_release_protocol_error;
    reg  [7:0] layer_long_epoch;
    reg        layer_long_release_valid;
    reg  [7:0] layer_long_release_epoch;
    reg  [15:0] layer_long_release_tile_index;
    reg        layer_long_release_error;
    reg  [31:0] layer_long_replay_cycles;
    wire [31:0] vector_completed_pixels;
    wire [31:0] vector_accepted_beats;
    wire [31:0] vector_fifo_stall_cycles;
    wire [8:0] packed_tile_h =
        (configured_tile_ofm_h != 9'd0) ?
        configured_tile_ofm_h : configured_ofm_h;
    wire [17:0] packed_pool_pixels_math =
        packed_tile_h[8:1] * configured_ofm_w[8:1];
    wire [15:0] packed_tile_pixels =
        configured_pool_enable && (configured_pool_stride == 2'd2) ?
        packed_pool_pixels_math[15:0] : configured_num_pixels;
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
    wire [13:0] layer_long_cin = validated_long_cin;
    // The sequencer already accumulates the tile's packed output-pixel base.
    // For an unpooled layer this is exactly oy_base*ofm_w.  Legal 2x2 pooling
    // halves both spatial axes, so multiplying that packed base by four
    // reconstructs the pre-pool input-pixel base.  Reuse this authoritative
    // registered geometry instead of inferring a runtime y*width multiplier.
    wire [31:0] layer_long_fill_pixel_base =
        configured_pool_enable && (configured_pool_stride == 2'd2) ?
        {6'd0, active_tile_output_pixel_base, 2'b00} :
        {8'd0, active_tile_output_pixel_base};

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
    wire ofm_axis_fire = ofm_m_axis_tvalid && ofm_m_axis_tready;

    function [3:0] count_axis_keep;
        input [AXIS_KEEP_W-1:0] keep;
        integer keep_lane;
        begin
            count_axis_keep = 4'd0;
            for (keep_lane = 0; keep_lane < AXIS_KEEP_W;
                 keep_lane = keep_lane + 1)
                count_axis_keep = count_axis_keep + keep[keep_lane];
        end
    endfunction

    assign bias_axis_error = bias_tkeep_error || bias_tlast_error;
    assign weight_axis_error = weight_tkeep_error || weight_tlast_error;
    assign ofm_axis_error = (ENABLE_PACKED_HWC_OFM != 0) &&
                            packed_ofm_protocol_error;
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

    assign layer_long_release_protocol_error =
        (ENABLE_LAYER_LONG_HWC_IFM != 0) && layer_long_release_error;

    // The tile sequencer commits the active geometry one cycle before it
    // raises active_tile_start.  Register that stable lookahead every cycle so
    // the precomputed packer contract is ready on the start pulse without an
    // extra tile-start cycle or a geometry multiplier in the bank-enable cone.
    always @(posedge clk) begin
        if (datapath_rst) begin
            packed_begin_output_pixels_q <= 16'd0;
            packed_begin_cout_total_q <= 11'd0;
            packed_begin_layer_last_q <= 1'b0;
            packed_begin_cout_blocks_q <= 16'd0;
            packed_begin_span_q <= 32'd0;
        end else begin
            packed_begin_output_pixels_q <= active_tile_output_pixels;
            packed_begin_cout_total_q <= configured_cout_total;
            packed_begin_layer_last_q <= active_tile_last;
            packed_begin_cout_blocks_q <= validated_long_cout_blocks;
            packed_begin_span_q <= packed_begin_span_lookahead;
        end
    end

    // A bank release is a held valid/ready transaction.  active_tile_done is
    // only a one-cycle retirement pulse, so capture the exact epoch/tile tag
    // and retain it until the cache acknowledges that no read remains live.
    always @(posedge clk) begin
        if (datapath_rst) begin
            layer_long_epoch <= 8'd0;
            layer_long_release_valid <= 1'b0;
            layer_long_release_epoch <= 8'd0;
            layer_long_release_tile_index <= 16'd0;
            layer_long_release_error <= 1'b0;
            layer_long_replay_cycles <= 32'd0;
        end else begin
            if (configured_stream_reset) begin
                layer_long_epoch <= layer_long_epoch + 1'b1;
                layer_long_release_valid <= 1'b0;
                layer_long_release_error <= 1'b0;
                layer_long_replay_cycles <= 32'd0;
            end else begin
                if (layer_long_replay_active)
                    layer_long_replay_cycles <=
                        layer_long_replay_cycles + 1'b1;

                if (layer_long_release_valid && layer_long_release_ready)
                    layer_long_release_valid <= 1'b0;

                if ((ENABLE_LAYER_LONG_HWC_IFM != 0) &&
                    configured_stream_raw_hwc_mode && active_tile_done) begin
                    if (layer_long_release_valid &&
                        !layer_long_release_ready)
                        layer_long_release_error <= 1'b1;
                    layer_long_release_valid <= 1'b1;
                    layer_long_release_epoch <= layer_long_epoch;
                    layer_long_release_tile_index <= active_tile_index;
                end
            end
        end
    end
    always @(posedge clk) begin
        if (datapath_rst) begin
            ofm_byte_count <= 32'd0;
            core_ofm_wr_count <= 32'd0;
            axis_ofm_wr_count <= 32'd0;
            axis_tlast_count <= 32'd0;
            last_tlast_index <= 32'd0;
        end else if (configured_stream_reset) begin
            ofm_byte_count <= 32'd0;
            core_ofm_wr_count <= 32'd0;
            axis_ofm_wr_count <= 32'd0;
            axis_tlast_count <= 32'd0;
            last_tlast_index <= 32'd0;
        end else begin
            if ((ENABLE_PACKED_HWC_OFM != 0) ?
                packed_ofm_packet_fire : core_ofm_wr_fire)
                core_ofm_wr_count <= core_ofm_wr_count + 1'b1;

            if (ofm_axis_fire) begin
                axis_ofm_wr_count <= axis_ofm_wr_count + 1'b1;
                if (ofm_m_axis_tlast)
                    ofm_byte_count <= 32'd0;
                else
                    ofm_byte_count <= ofm_byte_count +
                        ((ENABLE_PACKED_HWC_OFM != 0) ?
                         count_axis_keep(ofm_m_axis_tkeep) : 4'd1);
                if (ofm_m_axis_tlast) begin
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
        .rst(datapath_rst),
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
        .rst(datapath_rst),
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
        .rst(datapath_rst),
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

    generate
        if (ENABLE_LAYER_LONG_HWC_IFM != 0) begin : g_layer_long_hwc_ifm
            wire materializer_config_error;
            wire materializer_overflow_error;
            wire bank_collision_error;
            wire row_overwrite_error;
            wire materializer_protocol_error;
            wire [ROWS-1:0] vector_lane_valid_unused;
            wire vector_last_unused;
            wire [31:0] accepted_axis_bytes_unused;
            wire [31:0] stored_entries_unused;
            wire [31:0] axis_stall_cycles_unused;
            wire [31:0] ownership_stall_cycles_unused;
            wire [31:0] replay_backpressure_stall_cycles_unused;
            wire [31:0] release_stall_cycles_unused;

            assign raw_hwc_overflow_error = materializer_config_error ||
                materializer_overflow_error ||
                bank_collision_error || row_overwrite_error ||
                materializer_protocol_error ||
                (layer_long_cache_error_status != 5'd0) ||
                layer_long_release_protocol_error;
            assign layer_long_ifm_error_status = {
                3'd0,
                layer_long_release_protocol_error,
                layer_long_cache_error_status,
                materializer_protocol_error,
                row_overwrite_error,
                bank_collision_error,
                materializer_overflow_error,
                raw_hwc_tlast_error,
                raw_hwc_tkeep_error,
                materializer_config_error
            };
            assign raw_hwc_replay_active_cycles =
                layer_long_replay_cycles;

            axis_hwc_tile_materialized_replay #(
                .ROWS(ROWS), .AXIS_W(AXIS_W), .KEEP_W(AXIS_KEEP_W),
                .MAX_FM_W(FM_W_MAX), .MAX_CHANNELS(1024),
                .LINE_BANK_DEPTH(LAYER_LONG_LINE_BANK_DEPTH),
                .MAX_PASSES(512),
                .EPOCH_W(8), .TILE_W(16), .PIXEL_W(32),
                .CACHE_AW(MATERIALIZED_CACHE_AW),
                .CACHE_DEPTH(MATERIALIZED_CACHE_DEPTH),
                // configured_stream_reset is emitted only after the v2
                // layer descriptor validator accepts this exact geometry.
                .CACHE_CFG_PREVALIDATED(1),
                .MATERIALIZER_CFG_PREVALIDATED(1)
            ) u_layer_long_replay (
                .clk(clk), .rst(datapath_rst),
                .cfg_start(configured_stream_reset &&
                           configured_stream_raw_hwc_mode),
                .cfg_fm_h({7'd0, configured_fm_h}),
                .cfg_fm_w({7'd0, configured_fm_w}),
                .cfg_cin(layer_long_cin),
                .cfg_ofm_h({7'd0, configured_ofm_h}),
                .cfg_ofm_w({7'd0, configured_ofm_w}),
                .cfg_tile_h_max({7'd0, configured_tile_h_max}),
                .cfg_k_total({2'd0, configured_k_total}),
                .cfg_prevalidated_layer_pixels(
                    validated_long_layer_pixels),
                .cfg_prevalidated_tile_pixels(
                    validated_long_tile_pixels),
                .cfg_prevalidated_pass_count(
                    validated_long_pass_count),
                .cfg_prevalidated_final_pass(
                    validated_long_final_pass),
                .cfg_prevalidated_final_lane_mask(
                    validated_long_final_lane_mask),
                .cfg_ifm_total_bytes(configured_ifm_total_bytes),
                .cfg_kernel_1x1(configured_kernel_1x1),
                .cfg_stride(configured_conv_stride),
                .cfg_pad(configured_conv_pad),
                .cfg_input_zero_point(configured_input_zero_point),
                .cfg_epoch(layer_long_epoch + 1'b1),
                .s_axis_tready(raw_hwc_ifm_tready),
                .s_axis_tvalid(ifm_s_axis_tvalid),
                .s_axis_tdata(ifm_s_axis_tdata),
                .s_axis_tkeep(ifm_s_axis_tkeep),
                .s_axis_tlast(ifm_s_axis_tlast),
                .fill_req(feeder_fill_req &&
                          configured_stream_raw_hwc_mode),
                .fill_req_ready(), .fill_req_accept(),
                .pass_base_k({2'd0, current_feeder_pass_base_k}),
                .fill_k_pass(current_feeder_k_pass),
                .fill_tile_index(active_tile_index),
                .fill_pixel_base(layer_long_fill_pixel_base),
                .fill_num_pixels({16'd0, active_tile_num_pixels}),
                .fill_req_pending(),
                .vector_data(raw_hwc_ifm_data),
                .vector_lane_valid(vector_lane_valid_unused),
                .vector_valid(raw_hwc_ifm_valid),
                .vector_ready(vector_ifm_ready),
                .vector_last(vector_last_unused),
                .packet_done(raw_hwc_packet_done),
                .release_valid(layer_long_release_valid),
                .release_ready(layer_long_release_ready),
                .release_epoch(layer_long_release_epoch),
                .release_tile_index(layer_long_release_tile_index),
                .materializer_busy(), .materializer_input_done(),
                .materialize_done(),
                .replay_active(layer_long_replay_active),
                .active_replay_tile(), .active_replay_pass(),
                .materializer_config_error(materializer_config_error),
                .tkeep_error(raw_hwc_tkeep_error),
                .tlast_error(raw_hwc_tlast_error),
                .materializer_overflow_error(materializer_overflow_error),
                .bank_collision_error(bank_collision_error),
                .row_overwrite_error(row_overwrite_error),
                .materializer_protocol_error(materializer_protocol_error),
                .cache_error_status(layer_long_cache_error_status),
                .accepted_axis_beats(raw_hwc_accepted_beats),
                .accepted_axis_bytes(accepted_axis_bytes_unused),
                .emitted_entries(raw_hwc_load_unpack_cycles),
                .stored_entries(stored_entries_unused),
                .completed_replay_packets(raw_hwc_completed_packets),
                .completed_replay_pixels(raw_hwc_completed_pixels),
                .axis_stall_cycles(axis_stall_cycles_unused),
                .materializer_entry_stall_cycles(
                    raw_hwc_fifo_stall_cycles),
                .materialize_cycles(raw_hwc_load_active_cycles),
                .ownership_stall_cycles(ownership_stall_cycles_unused),
                .context_gap_cycles(raw_hwc_replay_wait_ready_cycles),
                .replay_backpressure_stall_cycles(
                    replay_backpressure_stall_cycles_unused),
                .release_stall_cycles(release_stall_cycles_unused)
            );
        end else begin : g_legacy_raw_hwc_ifm
            assign layer_long_replay_active = 1'b0;
            assign layer_long_release_ready = 1'b0;
            assign layer_long_cache_error_status = 5'd0;
            assign layer_long_ifm_error_status = 16'd0;

            axis_hwc_tile_cache #(
                .ROWS(ROWS),
                .AXIS_W(AXIS_W),
                .KEEP_W(AXIS_KEEP_W),
                .CACHE_AW(HWC_CACHE_AW),
                .CACHE_DEPTH(HWC_CACHE_DEPTH),
                .CACHE_STRIPES(HWC_CACHE_STRIPES),
                .CACHE_USE_URAM(HWC_CACHE_USE_URAM)
            ) u_axis_hwc_tile_cache (
                .clk(clk), .rst(datapath_rst),
                .stream_reset(configured_stream_reset &&
                              configured_stream_raw_hwc_mode),
                .expected_packets(configured_stream_ifm_packets),
                .num_pixels(configured_num_pixels),
                .fm_h(configured_fm_h), .fm_w(configured_fm_w),
                .ofm_w(configured_ofm_w),
                .tile_oy_base(configured_tile_oy_base),
                .tile_ofm_h(configured_tile_ofm_h),
                .conv_stride(configured_conv_stride),
                .conv_pad(configured_conv_pad),
                .kernel_1x1(configured_kernel_1x1),
                .k_total(configured_k_total),
                .pass_base_k(current_feeder_pass_base_k),
                .input_zero_point(configured_input_zero_point),
                .fill_req(feeder_fill_req &&
                          configured_stream_raw_hwc_mode),
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
                .replay_wait_ready_cycles(
                    raw_hwc_replay_wait_ready_cycles)
            );
        end
    endgenerate

    conv_accel_core_axi_lite #(
        .CLOCK_HZ(CLOCK_HZ),
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WEIGHT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_FIFO_DEPTH), .IFM_FIFO_AW(IFM_FIFO_AW),
        .WGT_FIFO_DEPTH(WGT_FIFO_DEPTH), .WGT_FIFO_AW(WGT_FIFO_AW),
        .PSUM_FIFO_DEPTH(PSUM_FIFO_DEPTH), .PSUM_FIFO_AW(PSUM_FIFO_AW),
        .FM_W_MAX(FM_W_MAX), .FM_H_MAX(FM_H_MAX),
        .K_TILE(K_TILE), .COUT_TILE(COUT_TILE), .IFM_BANKS(IFM_BANKS),
        .WGT_TILE_AW(WGT_TILE_AW), .PSUM_BUF_AW(PSUM_BUF_AW), .PSUM_BUF_DEPTH(PSUM_BUF_DEPTH),
        .MULT_W(MULT_W), .SHIFT_W(SHIFT_W), .ZP_W(ZP_W),
        .OFM_ADDR_W(OFM_ADDR_W), .OFM_FIFO_DEPTH(OFM_FIFO_DEPTH), .OFM_FIFO_AW(OFM_FIFO_AW),
        .TAIL_CYCLES_CONFIG(TAIL_CYCLES_CONFIG),
        .ENABLE_COLUMN_PSUM(ENABLE_COLUMN_PSUM),
        .ENABLE_PACKED_HWC_OFM(ENABLE_PACKED_HWC_OFM),
        .ENABLE_LAYER_TILE_SEQUENCER(ENABLE_LAYER_TILE_SEQUENCER),
        .ENABLE_LAYER_LONG_HWC_IFM(ENABLE_LAYER_LONG_HWC_IFM),
        .ENABLE_TAGGED_CONTEXT(ENABLE_TAGGED_CONTEXT),
        .ENABLE_WEIGHT_PRELOAD(ENABLE_WEIGHT_PRELOAD),
        .ENABLE_FAST_CONTEXT_HANDOFF(ENABLE_FAST_CONTEXT_HANDOFF),
        .IFM_EPOCH_USE_URAM(IFM_EPOCH_USE_URAM),
        .ENABLE_DETAILED_TRACE(ENABLE_DETAILED_TRACE),
        .MATERIALIZED_CACHE_DEPTH(MATERIALIZED_CACHE_DEPTH),
        .LAYER_LONG_LINE_BANK_DEPTH(LAYER_LONG_LINE_BANK_DEPTH),
        .PACKED_OFM_BUFFER_DEPTH(PACKED_OFM_BUFFER_DEPTH)
    ) u_core (
        .clk(clk),
        .rst(rst),
        .tile_start_ready((ENABLE_PACKED_HWC_OFM != 0) ?
                          packed_tile_begin_ready : 1'b1),
        .tile_retire_ready(
            ((ENABLE_LAYER_LONG_HWC_IFM != 0) &&
             configured_stream_raw_hwc_mode) ?
            (layer_long_release_valid && layer_long_release_ready) : 1'b1),
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
        .current_feeder_k_pass(current_feeder_k_pass),
        .configured_cout_total(configured_cout_total),
        .configured_k_total(configured_k_total),
        .configured_num_pixels(configured_num_pixels),
        .configured_input_zero_point(configured_input_zero_point),
        .configured_fm_h(configured_fm_h),
        .configured_fm_w(configured_fm_w),
        .configured_ofm_h(configured_ofm_h),
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
        .configured_datapath_reset(configured_datapath_reset),
        .configured_layer_last(configured_layer_last),
        .configured_tile_h_max(configured_tile_h_max),
        .configured_ifm_total_bytes(configured_ifm_total_bytes),
        .configured_ofm_total_bytes(configured_ofm_total_bytes),
        .validated_long_cin(validated_long_cin),
        .validated_long_pass_count(validated_long_pass_count),
        .validated_long_final_pass(validated_long_final_pass),
        .validated_long_final_lane_mask(
            validated_long_final_lane_mask),
        .validated_long_layer_pixels(validated_long_layer_pixels),
        .validated_long_tile_pixels(validated_long_tile_pixels),
        .validated_long_tile_output_pixels(
            validated_long_tile_output_pixels),
        .validated_long_cout_blocks(validated_long_cout_blocks),
        .active_tile_start(active_tile_start),
        .active_tile_last(active_tile_last),
        .active_tile_oy_base(active_tile_oy_base),
        .active_tile_ofm_h(active_tile_ofm_h),
        .active_tile_num_pixels(active_tile_num_pixels),
        .active_tile_output_pixels(active_tile_output_pixels),
        .active_tile_output_pixel_base(active_tile_output_pixel_base),
        .active_tile_index(active_tile_index),
        .active_tile_done(active_tile_done),
        .configured_config_error(configured_config_error),
        .debug_expected_bytes(ofm_expected_bytes),
        .debug_core_wr_count(core_ofm_wr_count),
        .debug_axis_wr_count(axis_ofm_wr_count),
        .debug_tlast_count(axis_tlast_count),
        .debug_last_tlast_index(last_tlast_index),
        .debug_packed_ofm_axis_byte_count(packed_ofm_axis_byte_count),
        .debug_packed_ofm_axis_stall_cycles(packed_ofm_axis_stall_cycles),
        .debug_packed_ofm_protocol_error(packed_ofm_protocol_error),
        .external_datapath_error_status(
            {13'd0, layer_long_ifm_error_status, 3'd0}),
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
        // RAWSTAT belongs to the current layer.  The cache intentionally
        // retains its last raw-layer counters until its next raw reset, so
        // suppress them for non-raw layers instead of exposing stale values.
        .raw_hwc_load_active_cycles(configured_stream_raw_hwc_mode ?
                                    raw_hwc_load_active_cycles : 32'd0),
        .raw_hwc_load_unpack_cycles(configured_stream_raw_hwc_mode ?
                                    raw_hwc_load_unpack_cycles : 32'd0),
        .raw_hwc_replay_active_cycles(configured_stream_raw_hwc_mode ?
                                      raw_hwc_replay_active_cycles : 32'd0),
        .raw_hwc_replay_wait_ready_cycles(configured_stream_raw_hwc_mode ?
                                          raw_hwc_replay_wait_ready_cycles : 32'd0),
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
        .ofm_packet_full(ofm_packet_full),
        .packed_ofm_packet_valid(packed_ofm_packet_valid),
        .packed_ofm_packet_ready(packed_ofm_packet_ready),
        .packed_ofm_packet_pixel(packed_ofm_packet_pixel),
        .packed_ofm_packet_cout_base(packed_ofm_packet_cout_base),
        .packed_ofm_packet_channel_valid(packed_ofm_packet_channel_valid),
        .packed_ofm_packet_data(packed_ofm_packet_data),
        .packed_ofm_busy(packed_ofm_busy)
    );

    generate
        if (ENABLE_PACKED_HWC_OFM != 0) begin : g_packed_ofm_axis
            // A complete post-pool packet is accepted atomically into the
            // tile-local reorder RAM.
            assign core_ofm_wr_ready = 1'b0;
            assign ofm_stream_valid = 1'b0;
            assign ofm_stream_ready = 1'b0;
            assign ofm_stream_addr = {OFM_ADDR_W{1'b0}};
            assign ofm_stream_data = 8'd0;
            assign ofm_stream_full = 1'b0;
            assign ofm_stream_almost_full = 1'b0;
            assign ofm_mem_wr_en = 1'b0;
            assign ofm_mem_wr_addr = {OFM_ADDR_W{1'b0}};
            assign ofm_mem_wr_data = 8'd0;

            if (ENABLE_LAYER_TILE_SEQUENCER != 0) begin : g_pingpong
                wire pingpong_load_active;
                wire pingpong_all_free;

                // Intermediate tiles retire once their packets commit into
                // a reorder bank.  The final tile waits for both banks to
                // drain, preserving layer_done-after-final-AXIS semantics.
                assign packed_ofm_busy = active_tile_last ?
                                         !pingpong_all_free :
                                         pingpong_load_active;
                assign packed_ofm_tile_free = pingpong_all_free;
                assign packed_ofm_accepted_packets = 32'd0;
                assign packed_ofm_expected_packets = 32'd0;

                ofm_hwc_axis_pingpong #(
                    .COUT_TILE(COLS*2),
                    .MAX_PIXELS(PACKED_OFM_MAX_PIXELS),
                    .MAX_COUT(PACKED_OFM_MAX_COUT),
                    .BUFFER_DEPTH(PACKED_OFM_BUFFER_DEPTH),
                    .RAM_STYLE("ultra"),
                    .PRECOMPUTED_BEGIN_GEOMETRY(
                        ENABLE_LAYER_LONG_HWC_IFM != 0),
                    .PIXEL_INDEX_W(PSUM_BUF_AW),
                    .PIXEL_COUNT_W(PSUM_BUF_AW+1),
                    .COUT_W(11)
                ) u_ofm_hwc_axis_pingpong (
                    .clk(clk), .rst(datapath_rst),
                    .clear_stats(configured_stream_reset),
                    .tile_begin_valid(active_tile_start),
                    .tile_begin_ready(packed_tile_begin_ready),
                    .tile_pixels((ENABLE_LAYER_LONG_HWC_IFM != 0) ?
                        packed_begin_output_pixels_q[PSUM_BUF_AW:0] :
                        active_tile_output_pixels[PSUM_BUF_AW:0]),
                    .tile_cout_total((ENABLE_LAYER_LONG_HWC_IFM != 0) ?
                        packed_begin_cout_total_q : configured_cout_total),
                    .tile_begin_blocks((ENABLE_LAYER_LONG_HWC_IFM != 0) ?
                        packed_begin_cout_blocks_q : 16'd0),
                    .tile_begin_span((ENABLE_LAYER_LONG_HWC_IFM != 0) ?
                        packed_begin_span_q : 32'd0),
                    .tile_layer_last((ENABLE_LAYER_LONG_HWC_IFM != 0) ?
                        packed_begin_layer_last_q : active_tile_last),
                    .tile_accept(),
                    .packet_valid(packed_ofm_packet_valid),
                    .packet_ready(packed_ofm_packet_ready),
                    .packet_pixel(packed_ofm_packet_pixel),
                    .packet_cout_base(packed_ofm_packet_cout_base),
                    .packet_channel_valid(
                        packed_ofm_packet_channel_valid),
                    .packet_data(packed_ofm_packet_data),
                    .tile_commit_valid(1'b1),
                    .tile_commit_ready(), .tile_commit(),
                    .m_axis_tdata(ofm_m_axis_tdata),
                    .m_axis_tkeep(ofm_m_axis_tkeep),
                    .m_axis_tvalid(ofm_m_axis_tvalid),
                    .m_axis_tready(ofm_m_axis_tready),
                    .m_axis_tlast(ofm_m_axis_tlast),
                    .all_free(pingpong_all_free),
                    .tile_load_active(pingpong_load_active),
                    .protocol_error(packed_ofm_protocol_error_raw),
                    .overwrite_error(packed_ofm_overwrite_error),
                    .underflow_error(packed_ofm_underflow_error),
                    .axis_valid_cycles(packed_ofm_axis_valid_cycles),
                    .axis_stall_cycles(packed_ofm_axis_stall_cycles),
                    .axis_beat_count(packed_ofm_axis_beat_count),
                    .axis_byte_count(packed_ofm_axis_byte_count)
                );
            end else begin : g_single_buffer
                // Preserve the proven single-tile path when automatic layer
                // tiling is not compiled in.
                assign packed_ofm_busy = !packed_ofm_tile_free;

                ofm_hwc_axis_packer #(
                    .COUT_TILE(COLS*2),
                    .MAX_PIXELS(PACKED_OFM_MAX_PIXELS),
                    .MAX_COUT(PACKED_OFM_MAX_COUT),
                    .BUFFER_DEPTH(PACKED_OFM_BUFFER_DEPTH),
                    .PIXEL_INDEX_W(PSUM_BUF_AW),
                    .PIXEL_COUNT_W(PSUM_BUF_AW+1),
                    .COUT_W(11)
                ) u_ofm_hwc_axis_packer (
                    .clk(clk), .rst(datapath_rst),
                    .tile_begin_valid(configured_stream_reset),
                    .tile_begin_ready(packed_tile_begin_ready),
                    .tile_pixels(packed_tile_pixels[PSUM_BUF_AW:0]),
                    .tile_cout_total(configured_cout_total),
                    .tile_begin_blocks(16'd0),
                    .tile_begin_span(32'd0),
                    .tile_layer_last(configured_layer_last),
                    .packet_valid(packed_ofm_packet_valid),
                    .packet_ready(packed_ofm_packet_ready),
                    .packet_pixel(packed_ofm_packet_pixel),
                    .packet_cout_base(packed_ofm_packet_cout_base),
                    .packet_channel_valid(
                        packed_ofm_packet_channel_valid),
                    .packet_data(packed_ofm_packet_data),
                    .tile_commit_valid(1'b1),
                    .tile_commit_ready(), .tile_committed(),
                    .drain_start_valid(1'b1), .drain_start_ready(),
                    .drain_done(), .tile_free(packed_ofm_tile_free),
                    .m_axis_tdata(ofm_m_axis_tdata),
                    .m_axis_tkeep(ofm_m_axis_tkeep),
                    .m_axis_tvalid(ofm_m_axis_tvalid),
                    .m_axis_tready(ofm_m_axis_tready),
                    .m_axis_tlast(ofm_m_axis_tlast),
                    .protocol_error(packed_ofm_protocol_error_raw),
                    .overwrite_error(packed_ofm_overwrite_error),
                    .underflow_error(packed_ofm_underflow_error),
                    .accepted_packet_count(packed_ofm_accepted_packets),
                    .expected_packet_count(packed_ofm_expected_packets),
                    .committed_credit_count(),
                    .axis_valid_cycles(packed_ofm_axis_valid_cycles),
                    .axis_stall_cycles(packed_ofm_axis_stall_cycles),
                    .axis_beat_count(packed_ofm_axis_beat_count),
                    .axis_byte_count(packed_ofm_axis_byte_count)
                );
            end
        end else begin : g_legacy_ofm_axis
            assign packed_ofm_packet_ready = 1'b0;
            assign packed_ofm_busy = 1'b0;
            assign packed_ofm_tile_free = 1'b1;
            assign packed_tile_begin_ready = 1'b1;
            assign packed_ofm_protocol_error_raw = 1'b0;
            assign packed_ofm_overwrite_error = 1'b0;
            assign packed_ofm_underflow_error = 1'b0;
            assign packed_ofm_accepted_packets = 32'd0;
            assign packed_ofm_expected_packets = 32'd0;
            assign packed_ofm_axis_valid_cycles = 32'd0;
            assign packed_ofm_axis_stall_cycles = 32'd0;
            assign packed_ofm_axis_beat_count = 32'd0;
            assign packed_ofm_axis_byte_count = 32'd0;

            ofm_byte_stream_fifo #(
                .ADDR_W(OFM_ADDR_W), .DEPTH(OFM_FIFO_DEPTH),
                .AW(OFM_FIFO_AW)
            ) u_ofm_stream_fifo (
                .clk(clk), .rst(datapath_rst),
                .wr_en(core_ofm_wr_en), .wr_ready(core_ofm_wr_ready),
                .wr_addr(core_ofm_wr_addr), .wr_data(core_ofm_wr_data),
                .m_valid(ofm_stream_valid), .m_ready(ofm_stream_ready),
                .m_addr(ofm_stream_addr), .m_data(ofm_stream_data),
                .full(ofm_stream_full),
                .almost_full(ofm_stream_almost_full)
            );

            axis_ofm_byte_writer #(
                .OFM_ADDR_W(OFM_ADDR_W), .AXIS_W(AXIS_W),
                .KEEP_W(AXIS_KEEP_W)
            ) u_axis_ofm_writer (
                .byte_addr(ofm_stream_addr), .byte_data(ofm_stream_data),
                .byte_valid(ofm_stream_valid),
                .byte_ready(ofm_stream_ready), .byte_last(ofm_stream_last),
                .m_axis_tdata(ofm_m_axis_tdata),
                .m_axis_tkeep(ofm_m_axis_tkeep),
                .m_axis_tvalid(ofm_m_axis_tvalid),
                .m_axis_tready(ofm_m_axis_tready),
                .m_axis_tlast(ofm_m_axis_tlast)
            );

            assign ofm_mem_wr_en = ofm_stream_valid && ofm_stream_ready;
            assign ofm_mem_wr_addr = ofm_stream_addr;
            assign ofm_mem_wr_data = ofm_stream_data;
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if ((ENABLE_PACKED_HWC_OFM != 0) && (AXIS_W != 64))
            $error("packed HWC OFM requires AXIS_W=64");
        if ((ENABLE_PACKED_HWC_OFM != 0) &&
            ((COLS != 8) && (COLS != 16)))
            $error("packed HWC OFM requires COLS=8 or COLS=16");
    end
`endif
endmodule

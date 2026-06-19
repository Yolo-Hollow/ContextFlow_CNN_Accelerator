`timescale 1ns / 1ps

`ifndef TB_CONV_ACCEL_CORE_MODULE
`define TB_CONV_ACCEL_CORE_MODULE tb_conv_accel_core_realistic_small
`endif
`ifndef TB_CONV_ACCEL_CORE_COLS
`define TB_CONV_ACCEL_CORE_COLS 4
`endif
`ifndef TB_CONV_ACCEL_CORE_ROWS
`define TB_CONV_ACCEL_CORE_ROWS 32
`endif
`ifndef TB_CONV_ACCEL_CORE_IFM_BANKS
`define TB_CONV_ACCEL_CORE_IFM_BANKS 5
`endif
`ifndef TB_CONV_ACCEL_CORE_CIN
`define TB_CONV_ACCEL_CORE_CIN 16
`endif
`ifndef TB_CONV_ACCEL_CORE_IFM_D
`define TB_CONV_ACCEL_CORE_IFM_D 128
`endif
`ifndef TB_CONV_ACCEL_CORE_IFM_AW
`define TB_CONV_ACCEL_CORE_IFM_AW 7
`endif
`ifndef TB_CONV_ACCEL_CORE_PSUM_D
`define TB_CONV_ACCEL_CORE_PSUM_D 128
`endif
`ifndef TB_CONV_ACCEL_CORE_PSUM_AW
`define TB_CONV_ACCEL_CORE_PSUM_AW 7
`endif
`ifndef TB_CONV_ACCEL_CORE_PSUM_BUF_AW
`define TB_CONV_ACCEL_CORE_PSUM_BUF_AW 6
`endif
`ifndef TB_CONV_ACCEL_CORE_PSUM_BUF_DEPTH
`define TB_CONV_ACCEL_CORE_PSUM_BUF_DEPTH 64
`endif
`ifndef TB_CONV_ACCEL_CORE_OFM_ADDR_W
`define TB_CONV_ACCEL_CORE_OFM_ADDR_W 16
`endif
`ifndef TB_CONV_ACCEL_CORE_OFM_FIFO_DEPTH
`define TB_CONV_ACCEL_CORE_OFM_FIFO_DEPTH 64
`endif
`ifndef TB_CONV_ACCEL_CORE_OFM_FIFO_AW
`define TB_CONV_ACCEL_CORE_OFM_FIFO_AW 6
`endif
`ifndef TB_CONV_ACCEL_CORE_HWC_CACHE_AW
`define TB_CONV_ACCEL_CORE_HWC_CACHE_AW 12
`endif
`ifndef TB_CONV_ACCEL_CORE_HWC_CACHE_DEPTH
`define TB_CONV_ACCEL_CORE_HWC_CACHE_DEPTH (1 << `TB_CONV_ACCEL_CORE_HWC_CACHE_AW)
`endif
`ifndef TB_CONV_ACCEL_CORE_HWC_CACHE_STRIPES
`define TB_CONV_ACCEL_CORE_HWC_CACHE_STRIPES 1
`endif
`ifndef TB_CONV_ACCEL_CORE_HWC_CACHE_USE_URAM
`define TB_CONV_ACCEL_CORE_HWC_CACHE_USE_URAM 0
`endif
`ifndef TB_CONV_ACCEL_CORE_QUANT_MULT
`define TB_CONV_ACCEL_CORE_QUANT_MULT 16'd1
`endif
`ifndef TB_CONV_ACCEL_CORE_QUANT_SHIFT
`define TB_CONV_ACCEL_CORE_QUANT_SHIFT 4'd0
`endif
`ifndef TB_CONV_ACCEL_CORE_QUANT_ZP
`define TB_CONV_ACCEL_CORE_QUANT_ZP 8'd0
`endif
`ifndef TB_CONV_ACCEL_CORE_INPUT_ZP
`define TB_CONV_ACCEL_CORE_INPUT_ZP 8'd0
`endif
`ifndef TB_CONV_ACCEL_CORE_ACT_MODE
`define TB_CONV_ACCEL_CORE_ACT_MODE 0
`endif
`ifndef TB_CONV_ACCEL_CORE_POOL_ENABLE
`define TB_CONV_ACCEL_CORE_POOL_ENABLE 0
`endif
`ifndef TB_CONV_ACCEL_CORE_POOL_STRIDE
`define TB_CONV_ACCEL_CORE_POOL_STRIDE 0
`endif
`ifndef TB_CONV_ACCEL_CORE_FM_W
`define TB_CONV_ACCEL_CORE_FM_W 8
`endif
`ifndef TB_CONV_ACCEL_CORE_FM_H
`define TB_CONV_ACCEL_CORE_FM_H 8
`endif
`ifndef TB_CONV_ACCEL_CORE_OFM_W
`define TB_CONV_ACCEL_CORE_OFM_W 8
`endif
`ifndef TB_CONV_ACCEL_CORE_OFM_H
`define TB_CONV_ACCEL_CORE_OFM_H 8
`endif
`ifndef TB_CONV_ACCEL_CORE_COUT_TOTAL
`define TB_CONV_ACCEL_CORE_COUT_TOTAL 18
`endif
`ifndef TB_CONV_ACCEL_CORE_GOLDEN_COUT_STRIDE
`define TB_CONV_ACCEL_CORE_GOLDEN_COUT_STRIDE `TB_CONV_ACCEL_CORE_COUT_TOTAL
`endif
`ifndef TB_CONV_ACCEL_CORE_PAD
`define TB_CONV_ACCEL_CORE_PAD 1
`endif
`ifndef TB_CONV_ACCEL_CORE_STRIDE
`define TB_CONV_ACCEL_CORE_STRIDE 1
`endif
`ifndef TB_CONV_ACCEL_CORE_TIMEOUT
`define TB_CONV_ACCEL_CORE_TIMEOUT 120000
`endif
`ifndef TB_CONV_ACCEL_CORE_PROGRESS_INTERVAL
`define TB_CONV_ACCEL_CORE_PROGRESS_INTERVAL 1000000
`endif
`include "tail_cycles_override.vh"
`ifndef TB_TAIL_CYCLES_OVERRIDE
`define TB_TAIL_CYCLES_OVERRIDE 0
`endif
`ifndef TB_RAW_HWC_COMPUTE_START_LEVEL_OVERRIDE
`define TB_RAW_HWC_COMPUTE_START_LEVEL_OVERRIDE 0
`endif
`ifndef TB_EARLY_DRAIN_OVERRIDE
`define TB_EARLY_DRAIN_OVERRIDE 0
`endif
`ifndef TB_PASS_PREFETCH_OVERRIDE
`define TB_PASS_PREFETCH_OVERRIDE 0
`endif
`ifndef TB_DURING_COMPUTE_PREFETCH_OVERRIDE
`define TB_DURING_COMPUTE_PREFETCH_OVERRIDE 0
`endif
`ifndef TB_PSUM_STREAM_OVERLAP_OVERRIDE
`define TB_PSUM_STREAM_OVERLAP_OVERRIDE 0
`endif
`ifndef TB_CONTINUOUS_PSUM_OVERRIDE
`define TB_CONTINUOUS_PSUM_OVERRIDE 0
`endif
`ifndef TB_COLUMN_PSUM_OVERRIDE
`define TB_COLUMN_PSUM_OVERRIDE 0
`endif
`ifndef TB_CONV_ACCEL_CORE_TILE_OY_BASE
`define TB_CONV_ACCEL_CORE_TILE_OY_BASE 0
`endif
`ifndef TB_CONV_ACCEL_CORE_TILE_OFM_H
`define TB_CONV_ACCEL_CORE_TILE_OFM_H 0
`endif
`ifndef TB_CONV_ACCEL_CORE_TILE_PIXEL_BASE
`define TB_CONV_ACCEL_CORE_TILE_PIXEL_BASE 0
`endif
`ifndef TB_CONV_ACCEL_CORE_TILE_COUNT
`define TB_CONV_ACCEL_CORE_TILE_COUNT 1
`endif
`ifndef TB_CONV_ACCEL_CORE_TILE1_OY_BASE
`define TB_CONV_ACCEL_CORE_TILE1_OY_BASE 0
`endif
`ifndef TB_CONV_ACCEL_CORE_TILE1_OFM_H
`define TB_CONV_ACCEL_CORE_TILE1_OFM_H 0
`endif
`ifndef TB_CONV_ACCEL_CORE_TILE1_PIXEL_BASE
`define TB_CONV_ACCEL_CORE_TILE1_PIXEL_BASE 0
`endif
`ifndef TB_CONV_ACCEL_CORE_TILE2_OY_BASE
`define TB_CONV_ACCEL_CORE_TILE2_OY_BASE 0
`endif
`ifndef TB_CONV_ACCEL_CORE_TILE2_OFM_H
`define TB_CONV_ACCEL_CORE_TILE2_OFM_H 0
`endif
`ifndef TB_CONV_ACCEL_CORE_TILE2_PIXEL_BASE
`define TB_CONV_ACCEL_CORE_TILE2_PIXEL_BASE 0
`endif

`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
`define TB_DUT_LAYER dut.u_core.u_core.u_layer
`define TB_DUT_CFG dut.u_core.u_core.u_cfg
`define TB_DUT_AXI_CFG dut.u_core.u_axi_cfg
`define TB_DUT_BW_LOADER dut.u_axis_bw_loader
`define TB_DUT_IFM_LOADER dut.u_axis_ifm_loader.u_line_loader
`elsif TB_CONV_ACCEL_CORE_USE_FULL_STREAM
`define TB_DUT_LAYER dut.u_core.u_core.u_core.u_layer
`define TB_DUT_CFG dut.u_core.u_core.u_core.u_cfg
`define TB_DUT_AXI_CFG dut.u_core.u_core.u_axi_cfg
`define TB_DUT_BW_LOADER dut.u_core.u_bw_loader
`define TB_DUT_IFM_LOADER dut.u_ifm_loader
`elsif TB_CONV_ACCEL_CORE_USE_BW_STREAM
`define TB_DUT_LAYER dut.u_core.u_core.u_layer
`define TB_DUT_CFG dut.u_core.u_core.u_cfg
`define TB_DUT_AXI_CFG dut.u_core.u_axi_cfg
`define TB_DUT_BW_LOADER dut.u_bw_loader
`define TB_DUT_IFM_LOADER dut
`elsif TB_CONV_ACCEL_CORE_USE_AXI_LITE
`define TB_DUT_LAYER dut.u_core.u_layer
`define TB_DUT_CFG dut.u_core.u_cfg
`define TB_DUT_AXI_CFG dut.u_axi_cfg
`define TB_DUT_BW_LOADER dut
`define TB_DUT_IFM_LOADER dut
`else
`define TB_DUT_LAYER dut.u_layer
`define TB_DUT_CFG dut.u_cfg
`define TB_DUT_AXI_CFG dut
`define TB_DUT_BW_LOADER dut
`define TB_DUT_IFM_LOADER dut
`endif

module `TB_CONV_ACCEL_CORE_MODULE;
    localparam ROWS = `TB_CONV_ACCEL_CORE_ROWS;
    localparam COLS = `TB_CONV_ACCEL_CORE_COLS;
    localparam IFM_BANKS = `TB_CONV_ACCEL_CORE_IFM_BANKS;
    localparam IFM_W = 8;
    localparam WGT_W = 8;
    localparam PSUM_W = 32;
    localparam IFM_D = `TB_CONV_ACCEL_CORE_IFM_D;
    localparam IFM_AW = `TB_CONV_ACCEL_CORE_IFM_AW;
    localparam WGT_D = 64;
    localparam WGT_AW = 6;
    localparam PSUM_D = `TB_CONV_ACCEL_CORE_PSUM_D;
    localparam PSUM_AW = `TB_CONV_ACCEL_CORE_PSUM_AW;
    localparam FM_W = `TB_CONV_ACCEL_CORE_FM_W;
    localparam FM_H = `TB_CONV_ACCEL_CORE_FM_H;
    localparam OFM_W = `TB_CONV_ACCEL_CORE_OFM_W;
    localparam OFM_H = `TB_CONV_ACCEL_CORE_OFM_H;
    localparam [8:0] TILE_OY_BASE = `TB_CONV_ACCEL_CORE_TILE_OY_BASE;
    localparam [8:0] TILE_OFM_H = `TB_CONV_ACCEL_CORE_TILE_OFM_H;
    localparam [23:0] TILE_PIXEL_BASE = `TB_CONV_ACCEL_CORE_TILE_PIXEL_BASE;
    localparam TILE_COUNT = `TB_CONV_ACCEL_CORE_TILE_COUNT;
    localparam [8:0] TILE1_OY_BASE = `TB_CONV_ACCEL_CORE_TILE1_OY_BASE;
    localparam [8:0] TILE1_OFM_H = `TB_CONV_ACCEL_CORE_TILE1_OFM_H;
    localparam [23:0] TILE1_PIXEL_BASE = `TB_CONV_ACCEL_CORE_TILE1_PIXEL_BASE;
    localparam [8:0] TILE2_OY_BASE = `TB_CONV_ACCEL_CORE_TILE2_OY_BASE;
    localparam [8:0] TILE2_OFM_H = `TB_CONV_ACCEL_CORE_TILE2_OFM_H;
    localparam [23:0] TILE2_PIXEL_BASE = `TB_CONV_ACCEL_CORE_TILE2_PIXEL_BASE;
    localparam ACTIVE_OFM_H = (TILE_OFM_H == 0) ? OFM_H : TILE_OFM_H;
    localparam TILE1_ACTIVE_OFM_H = (TILE1_OFM_H == 0) ? OFM_H : TILE1_OFM_H;
    localparam TILE2_ACTIVE_OFM_H = (TILE2_OFM_H == 0) ? OFM_H : TILE2_OFM_H;
    localparam [1:0] CONV_PAD = `TB_CONV_ACCEL_CORE_PAD;
    localparam [1:0] CONV_STRIDE = `TB_CONV_ACCEL_CORE_STRIDE;
    localparam POOL_ENABLE = `TB_CONV_ACCEL_CORE_POOL_ENABLE;
    localparam [1:0] POOL_STRIDE = `TB_CONV_ACCEL_CORE_POOL_STRIDE;
    localparam POOL_ACTIVE = (POOL_ENABLE != 0) && (POOL_STRIDE == 2);
    localparam PIXELS = OFM_W * ACTIVE_OFM_H;
    localparam TILE1_PIXELS = OFM_W * TILE1_ACTIVE_OFM_H;
    localparam TILE2_PIXELS = OFM_W * TILE2_ACTIVE_OFM_H;
    localparam RUN_PIXELS = (TILE_COUNT == 1) ? PIXELS :
                            (TILE_COUNT == 2) ? (PIXELS + TILE1_PIXELS) :
                            (PIXELS + TILE1_PIXELS + TILE2_PIXELS);
    localparam OUT_W = POOL_ACTIVE ? (OFM_W / 2) : OFM_W;
    localparam OUT_H = POOL_ACTIVE ? (OFM_H / 2) : OFM_H;
    localparam ACTIVE_OUT_H = POOL_ACTIVE ? (ACTIVE_OFM_H / 2) : ACTIVE_OFM_H;
    localparam TILE1_ACTIVE_OUT_H = POOL_ACTIVE ? (TILE1_ACTIVE_OFM_H / 2) : TILE1_ACTIVE_OFM_H;
    localparam TILE2_ACTIVE_OUT_H = POOL_ACTIVE ? (TILE2_ACTIVE_OFM_H / 2) : TILE2_ACTIVE_OFM_H;
    localparam OUT_PIXELS = OUT_W * ACTIVE_OUT_H;
    localparam TILE1_OUT_PIXELS = OUT_W * TILE1_ACTIVE_OUT_H;
    localparam TILE2_OUT_PIXELS = OUT_W * TILE2_ACTIVE_OUT_H;
    localparam RUN_OUT_PIXELS = (TILE_COUNT == 1) ? OUT_PIXELS :
                                (TILE_COUNT == 2) ? (OUT_PIXELS + TILE1_OUT_PIXELS) :
                                (OUT_PIXELS + TILE1_OUT_PIXELS + TILE2_OUT_PIXELS);
    localparam CIN = `TB_CONV_ACCEL_CORE_CIN;
`ifdef TB_CONV_ACCEL_CORE_KERNEL_1X1
    localparam KERNEL_1X1 = 1;
`else
    localparam KERNEL_1X1 = 0;
`endif
    localparam K_TOTAL = KERNEL_1X1 ? CIN : CIN * 3 * 3;
    localparam K_PASSES = (K_TOTAL + ROWS - 1) / ROWS;
    localparam COUT_TILE = COLS * 2;
    localparam COUT_TOTAL = `TB_CONV_ACCEL_CORE_COUT_TOTAL;
    localparam GOLDEN_COUT_STRIDE = `TB_CONV_ACCEL_CORE_GOLDEN_COUT_STRIDE;
    localparam COUT_BLOCKS = (COUT_TOTAL + COUT_TILE - 1) / COUT_TILE;
    localparam [7:0] IFM_TKEEP_MASK =
        KERNEL_1X1 ? 8'hff : (8'hff >> (8 - IFM_BANKS));
    localparam WGT_TILE_AW = 11;
    localparam PSUM_A = `TB_CONV_ACCEL_CORE_PSUM_BUF_AW;
    localparam PSUM_BUF_D = `TB_CONV_ACCEL_CORE_PSUM_BUF_DEPTH;
    localparam OFM_ADDR_W = `TB_CONV_ACCEL_CORE_OFM_ADDR_W;
    localparam FULL_PIXELS = OFM_W * OFM_H;
    localparam OUT_FULL_PIXELS = OUT_W * OUT_H;
    localparam OFM_WORDS = OUT_W * OUT_H * COUT_TOTAL;
    localparam EXPECTED_OFM_WRITES = RUN_OUT_PIXELS * COUT_TOTAL;
    localparam [7:0] INPUT_ZERO_POINT = `TB_CONV_ACCEL_CORE_INPUT_ZP;

    reg clk, rst;
    reg cfg_wr_en, cfg_rd_en;
    reg [6:0] cfg_addr;
    reg [31:0] cfg_wdata;
    wire [31:0] cfg_rdata;
    reg [31:0] cfg_read_data;
`ifdef TB_CONV_ACCEL_CORE_USE_AXI_LITE
    reg [8:0] axi_awaddr;
    reg axi_awvalid;
    wire axi_awready;
    reg [31:0] axi_wdata;
    reg [3:0] axi_wstrb;
    reg axi_wvalid;
    wire axi_wready;
    wire [1:0] axi_bresp;
    wire axi_bvalid;
    reg axi_bready;
    reg [8:0] axi_araddr;
    reg axi_arvalid;
    wire axi_arready;
    wire [31:0] axi_rdata;
    wire [1:0] axi_rresp;
    wire axi_rvalid;
    reg axi_rready;
`endif
    wire bias_load_req, weight_load_req;
    reg bias_load_done, weight_tile_ready;
    wire [10:0] current_cout_base;
    wire [13:0] current_pass_base_k;
    reg [5:0] bias_wr_addr;
    reg [PSUM_W-1:0] bias_wr_data;
    reg bias_wr_en;
    reg wgt_tile_wr_en;
    reg [WGT_TILE_AW-1:0] wgt_tile_wr_addr;
    reg [WGT_W-1:0] wgt_tile_wr_data;
`ifdef TB_CONV_ACCEL_CORE_USE_BW_STREAM
    wire bias_s_ready;
    reg bias_s_valid;
    reg [PSUM_W-1:0] bias_s_data;
    wire weight_s_ready;
    reg weight_s_valid;
    reg [WGT_W-1:0] weight_s_data;
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
    wire bias_axis_tready;
    reg bias_axis_tvalid;
    reg [63:0] bias_axis_tdata;
    reg [7:0] bias_axis_tkeep;
    reg bias_axis_tlast;
    wire weight_axis_tready;
    reg weight_axis_tvalid;
    reg [63:0] weight_axis_tdata;
    reg [7:0] weight_axis_tkeep;
    reg weight_axis_tlast;
    wire ifm_axis_tready;
    reg ifm_axis_tvalid;
    reg [63:0] ifm_axis_tdata;
    reg [7:0] ifm_axis_tkeep;
    reg ifm_axis_tlast;
    wire [63:0] ofm_m_axis_tdata;
    wire [7:0] ofm_m_axis_tkeep;
    wire ofm_m_axis_tvalid;
    reg ofm_m_axis_tready;
    wire ofm_m_axis_tlast;
    wire bias_axis_error;
    wire weight_axis_error;
    wire ifm_axis_error;
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
    wire ifm_line_s_ready;
    reg ifm_line_s_valid;
    reg [7:0] ifm_line_s_data [0:IFM_BANKS-1];
`endif
    wire feeder_fill_req;
    wire [8:0] feeder_fill_fy;
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
    reg [7:0] act_lut_wr_addr, act_lut_wr_data;
    wire ofm_mem_wr_en;
    wire [OFM_ADDR_W-1:0] ofm_mem_wr_addr;
    wire [7:0] ofm_mem_wr_data;
    wire ofm_packet_full;
`ifdef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
    wire ofm_m_valid;
    wire [15:0] ofm_m_addr;
    wire [7:0] ofm_m_data;
    reg ofm_m_ready;
`endif
`ifdef TB_CONV_ACCEL_CORE_OFM_READY_STALL
    integer ofm_ready_cycle;
    integer ofm_stall_count;
    reg ofm_stall_seen;
`endif

`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
    conv_accel_core_axi_lite_axis_stream #(
`elsif TB_CONV_ACCEL_CORE_USE_FULL_STREAM
    conv_accel_core_axi_lite_full_stream #(
`elsif TB_CONV_ACCEL_CORE_USE_BW_STREAM
    conv_accel_core_axi_lite_stream #(
`elsif TB_CONV_ACCEL_CORE_USE_AXI_LITE
    conv_accel_core_axi_lite #(
`else
    conv_accel_core #(
`endif
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WGT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_D), .IFM_FIFO_AW(IFM_AW),
        .WGT_FIFO_DEPTH(WGT_D), .WGT_FIFO_AW(WGT_AW),
        .PSUM_FIFO_DEPTH(PSUM_D), .PSUM_FIFO_AW(PSUM_AW),
        .FM_W_MAX(FM_W), .FM_H_MAX(FM_H),
        .K_TILE(ROWS), .COUT_TILE(COUT_TILE), .IFM_BANKS(IFM_BANKS),
        .WGT_TILE_AW(WGT_TILE_AW), .PSUM_BUF_AW(PSUM_A), .PSUM_BUF_DEPTH(PSUM_BUF_D),
        .OFM_ADDR_W(OFM_ADDR_W),
        .OFM_FIFO_DEPTH(`TB_CONV_ACCEL_CORE_OFM_FIFO_DEPTH),
        .OFM_FIFO_AW(`TB_CONV_ACCEL_CORE_OFM_FIFO_AW)
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
        , .HWC_CACHE_AW(`TB_CONV_ACCEL_CORE_HWC_CACHE_AW)
        , .HWC_CACHE_DEPTH(`TB_CONV_ACCEL_CORE_HWC_CACHE_DEPTH)
        , .HWC_CACHE_STRIPES(`TB_CONV_ACCEL_CORE_HWC_CACHE_STRIPES)
        , .HWC_CACHE_USE_URAM(`TB_CONV_ACCEL_CORE_HWC_CACHE_USE_URAM)
`endif
    ) dut (
        .clk(clk), .rst(rst),
`ifdef TB_CONV_ACCEL_CORE_USE_AXI_LITE
        .s_axi_awaddr(axi_awaddr), .s_axi_awvalid(axi_awvalid), .s_axi_awready(axi_awready),
        .s_axi_wdata(axi_wdata), .s_axi_wstrb(axi_wstrb), .s_axi_wvalid(axi_wvalid),
        .s_axi_wready(axi_wready), .s_axi_bresp(axi_bresp), .s_axi_bvalid(axi_bvalid),
        .s_axi_bready(axi_bready), .s_axi_araddr(axi_araddr), .s_axi_arvalid(axi_arvalid),
        .s_axi_arready(axi_arready), .s_axi_rdata(axi_rdata), .s_axi_rresp(axi_rresp),
        .s_axi_rvalid(axi_rvalid), .s_axi_rready(axi_rready),
`else
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_rd_en(cfg_rd_en), .cfg_rdata(cfg_rdata),
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_BW_STREAM
        .bias_load_req(bias_load_req), .weight_load_req(weight_load_req),
        .current_cout_base(current_cout_base), .current_pass_base_k(current_pass_base_k),
        .bias_s_ready(bias_s_ready), .bias_s_valid(bias_s_valid), .bias_s_data(bias_s_data),
        .weight_s_ready(weight_s_ready), .weight_s_valid(weight_s_valid), .weight_s_data(weight_s_data),
`elsif TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
        .bias_load_req(bias_load_req), .weight_load_req(weight_load_req),
        .current_cout_base(current_cout_base), .current_pass_base_k(current_pass_base_k),
        .bias_s_axis_tready(bias_axis_tready), .bias_s_axis_tvalid(bias_axis_tvalid),
        .bias_s_axis_tdata(bias_axis_tdata), .bias_s_axis_tkeep(bias_axis_tkeep),
        .bias_s_axis_tlast(bias_axis_tlast),
        .weight_s_axis_tready(weight_axis_tready), .weight_s_axis_tvalid(weight_axis_tvalid),
        .weight_s_axis_tdata(weight_axis_tdata), .weight_s_axis_tkeep(weight_axis_tkeep),
        .weight_s_axis_tlast(weight_axis_tlast),
`else
        .bias_load_req(bias_load_req), .bias_load_done(bias_load_done),
        .current_cout_base(current_cout_base), .current_pass_base_k(current_pass_base_k),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .weight_load_req(weight_load_req), .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en), .wgt_tile_wr_addr(wgt_tile_wr_addr),
        .wgt_tile_wr_data(wgt_tile_wr_data),
        .wgt_tile_wr8_en(1'b0), .wgt_tile_wr8_addr({WGT_TILE_AW{1'b0}}),
        .wgt_tile_wr8_data(64'd0), .wgt_tile_wr8_keep(8'd0),
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .ifm_line_words(FM_W[8:0]), .ifm_s_axis_tready(ifm_axis_tready),
        .ifm_s_axis_tvalid(ifm_axis_tvalid), .ifm_s_axis_tdata(ifm_axis_tdata),
        .ifm_s_axis_tkeep(ifm_axis_tkeep), .ifm_s_axis_tlast(ifm_axis_tlast),
`elsif TB_CONV_ACCEL_CORE_USE_FULL_STREAM
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .ifm_line_words(FM_W[8:0]), .ifm_line_s_ready(ifm_line_s_ready),
        .ifm_line_s_valid(ifm_line_s_valid), .ifm_line_s_data(ifm_line_s_data),
`else
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .raw_hwc_load_active_cycles(32'd0),
        .raw_hwc_load_unpack_cycles(32'd0),
        .raw_hwc_replay_active_cycles(32'd0),
        .raw_hwc_replay_wait_ready_cycles(32'd0),
`endif
`ifndef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
        .quant_wr_en(quant_wr_en), .quant_wr_addr(quant_wr_addr), .quant_wr_data(quant_wr_data),
        .quant_rd_addr(quant_rd_addr), .quant_rd_data(quant_rd_data),
        .act_lut_wr_en(act_lut_wr_en), .act_lut_wr_addr(act_lut_wr_addr),
        .act_lut_wr_data(act_lut_wr_data),
`endif
        .ofm_mem_wr_en(ofm_mem_wr_en), .ofm_mem_wr_addr(ofm_mem_wr_addr),
        .ofm_mem_wr_data(ofm_mem_wr_data),
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
        .ofm_m_axis_tdata(ofm_m_axis_tdata), .ofm_m_axis_tkeep(ofm_m_axis_tkeep),
        .ofm_m_axis_tvalid(ofm_m_axis_tvalid), .ofm_m_axis_tready(ofm_m_axis_tready),
        .ofm_m_axis_tlast(ofm_m_axis_tlast),
        .bias_axis_error(bias_axis_error), .weight_axis_error(weight_axis_error),
        .ifm_axis_error(ifm_axis_error),
`elsif TB_CONV_ACCEL_CORE_USE_FULL_STREAM
        .ofm_m_valid(ofm_m_valid), .ofm_m_ready(ofm_m_ready),
        .ofm_m_addr(ofm_m_addr), .ofm_m_data(ofm_m_data),
`else
        .ofm_mem_wr_ready(1'b1),
`endif
        .ofm_packet_full(ofm_packet_full)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer b, y, x, kk, cc, co, k, ch, ker, ky, kx, idx;
    integer fy, fx, bank_ch;
    integer ofm_mem_wr_count;
    integer first_extra_ofm_wr_addr;
    integer first_extra_ofm_wr_data;
    integer first_extra_ofm_wr_index;
    integer ifm_write_count, compute_fire_count, psum_wr_count, drain_capture_count;
    integer final_raw_lane, final_raw_index;
    integer run_idx, run_pixels, run_oy_base, run_ofm_h, run_pixel_base;
    integer coltrace_first, coltrace_last, coltrace_count, coltrace_empty;
    integer ps_tile_start_count, ps_done_seen_count, ps_done_clear_count;
    integer tail_cycles_override;
    integer raw_hwc_compute_start_level_override;
    integer early_drain_override;
    integer pass_prefetch_override;
    integer during_compute_prefetch_override;
    integer psum_stream_overlap_override;
    integer continuous_psum_override;
    integer column_psum_override;
    integer layer_done_pulse_count;
    integer ps_bias_service_count, ps_weight_service_count, ps_line_fill_count;
`ifdef TB_CONV_ACCEL_CORE_CHECK_VECTOR_IFM
    integer vector_check_pixel;
    integer vector_check_lane;
    integer vector_check_ch;
    integer vector_check_y;
    integer vector_check_x;
    reg [7:0] vector_check_expected;
`endif
`ifdef TB_CONV_ACCEL_CORE_BATCH_STREAM
    integer batch_ifm_tile_end_count;
    integer batch_ifm_tile_packets;
    integer batch_first_fy;
    integer batch_last_fy;
`endif
`ifdef TB_CONV_ACCEL_CORE_RAW_HWC_IFM
    integer expected_raw_hwc_bytes;
    integer expected_raw_hwc_beats;
    integer expected_raw_hwc_replay_packets;
`endif
`ifdef TB_CONV_ACCEL_CORE_PROGRESS_PRINT
    integer progress_last_ofm_wr_count;
    integer progress_last_compute_fire_count;
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
    integer ifm_loader_write_count, ifm_loader_advance_count, ifm_loader_fail_count;
    integer ifm_loader_bank_ch, ifm_loader_expected;
`endif
`ifdef TB_CONV_ACCEL_CORE_CHECK_FEEDER_IFM
    integer feeder_ifm_fail_count;
    integer feeder_lane, feeder_gk, feeder_ch, feeder_ker, feeder_ky, feeder_kx, feeder_fy, feeder_fx;
    integer diag_loader_write_count, diag_loader_fail_count;
    integer diag_loader_bank_ch;
    reg [7:0] diag_loader_expected;
    reg [7:0] feeder_ifm_got, feeder_ifm_expected;
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
    integer axis_ofm_tlast_count;
`endif
    reg signed [7:0] feat [0:CIN-1][0:FM_H-1][0:FM_W-1];
    reg signed [7:0] weight [0:K_TOTAL-1][0:COUT_TOTAL-1];
    reg signed [PSUM_W-1:0] bias [0:COUT_TOTAL-1];
    reg signed [PSUM_W-1:0] golden [0:FULL_PIXELS-1][0:COUT_TOTAL-1];
    reg [7:0] ofm_mem [0:OFM_WORDS-1];
    reg signed [PSUM_W-1:0] final_raw_mem [0:OFM_WORDS-1];
    reg final_raw_valid [0:OFM_WORDS-1];
    reg [7:0] expected_det_byte;
    reg [7:0] expected_pool_byte;
`ifdef TB_CONV_ACCEL_CORE_USE_EXTERNAL_GOLDEN
    reg [7:0] ext_ifm [0:FM_W*FM_H*CIN-1];
    reg [7:0] ext_weight [0:K_TOTAL*COUT_TOTAL-1];
    reg [31:0] ext_bias [0:COUT_TOTAL-1];
    reg [7:0] ext_act_lut [0:255];
    reg [7:0] ext_golden [0:OFM_WORDS-1];
    reg [7:0] expected_ofm_byte;
`endif

    function [7:0] clamp8;
        input signed [PSUM_W-1:0] v;
        begin
            if (v > 127) clamp8 = 8'd127;
            else if (v < -128) clamp8 = 8'd128;
            else clamp8 = v[7:0];
        end
    endfunction

    function [7:0] requant_byte_tb;
        input signed [PSUM_W-1:0] psum;
        reg signed [63:0] prod;
        reg signed [63:0] rounded;
        integer effective_shift;
        begin
            effective_shift = `TB_CONV_ACCEL_CORE_QUANT_SHIFT + 15;
            prod = psum * $signed({1'b0, `TB_CONV_ACCEL_CORE_QUANT_MULT});
            rounded = (prod + (64'sd1 <<< (effective_shift - 1))) >>> effective_shift;
            rounded = rounded + $signed({1'b0, `TB_CONV_ACCEL_CORE_QUANT_ZP});
            if (rounded > 127)
                requant_byte_tb = 8'd127;
            else if (rounded < -128)
                requant_byte_tb = 8'd128;
            else
                requant_byte_tb = rounded[7:0];
        end
    endfunction

    function [7:0] max4_u8;
        input [7:0] a;
        input [7:0] b;
        input [7:0] c;
        input [7:0] d;
        reg [7:0] m0;
        reg [7:0] m1;
        begin
            m0 = (a > b) ? a : b;
            m1 = (c > d) ? c : d;
            max4_u8 = (m0 > m1) ? m0 : m1;
        end
    endfunction

    function [7:0] center_ifm_byte_tb;
        input [7:0] raw_u8;
        input [7:0] zero_point;
        reg signed [9:0] centered;
        begin
            centered = $signed({2'b00, raw_u8}) - $signed({2'b00, zero_point});
            if (centered > 10'sd127)
                center_ifm_byte_tb = 8'h7f;
            else if (centered < -10'sd128)
                center_ifm_byte_tb = 8'h80;
            else
                center_ifm_byte_tb = centered[7:0];
        end
    endfunction

    function [7:0] add_input_zp_byte_tb;
        input signed [7:0] centered_s8;
        reg signed [9:0] raw_sum;
        begin
            raw_sum = centered_s8 + $signed({2'b00, INPUT_ZERO_POINT});
            if (raw_sum < 10'sd0)
                add_input_zp_byte_tb = 8'd0;
            else if (raw_sum > 10'sd255)
                add_input_zp_byte_tb = 8'hff;
            else
                add_input_zp_byte_tb = raw_sum[7:0];
        end
    endfunction

    function [7:0] stream_ifm_byte_tb;
        input integer stream_ch;
        input integer stream_y;
        input integer stream_x;
        begin
            if (stream_ch < 0) begin
                stream_ifm_byte_tb = INPUT_ZERO_POINT;
            end else begin
`ifdef TB_CONV_ACCEL_CORE_USE_EXTERNAL_GOLDEN
`ifdef TB_CONV_ACCEL_CORE_CENTER_EXTERNAL_IFM
                stream_ifm_byte_tb = ext_ifm[(stream_y*FM_W + stream_x)*CIN + stream_ch];
`else
                stream_ifm_byte_tb = feat[stream_ch][stream_y][stream_x];
`endif
`else
`ifdef TB_CONV_ACCEL_CORE_IFM_U8_FROM_CENTERED
                stream_ifm_byte_tb = add_input_zp_byte_tb(feat[stream_ch][stream_y][stream_x]);
`else
                stream_ifm_byte_tb = feat[stream_ch][stream_y][stream_x];
`endif
`endif
            end
        end
    endfunction

    function integer pass_needs_ch;
        input integer k_base;
        input integer c;
        begin
            pass_needs_ch = (c < CIN) && (k_base < (c + 1) * 9) && ((k_base + ROWS) > c * 9);
        end
    endfunction

    function integer channel_for_bank;
        input integer k_base;
        input integer bank;
        integer c;
        begin
            channel_for_bank = -1;
            for (c = 0; c < CIN; c = c + 1)
                if (pass_needs_ch(k_base, c) && (c % IFM_BANKS == bank))
                    channel_for_bank = c;
        end
    endfunction

    function integer raw_hwc_first_y_tb;
        input integer oy_base;
        begin
            if (KERNEL_1X1)
                raw_hwc_first_y_tb = oy_base;
            else if ((oy_base * CONV_STRIDE) <= CONV_PAD)
                raw_hwc_first_y_tb = 0;
            else
                raw_hwc_first_y_tb = oy_base * CONV_STRIDE - CONV_PAD;
        end
    endfunction

    function integer raw_hwc_last_y_tb;
        input integer oy_base;
        input integer tile_h;
        integer last_calc;
        begin
            if (KERNEL_1X1)
                last_calc = oy_base + tile_h - 1;
            else
                last_calc = (oy_base + tile_h - 1) * CONV_STRIDE - CONV_PAD + 2;
            raw_hwc_last_y_tb = (last_calc >= FM_H) ? (FM_H - 1) : last_calc;
        end
    endfunction

    function [7:0] expected_feeder_ifm_tb;
        input integer base_k;
        input integer lane;
        input integer out_y;
        input integer out_x;
        integer local_gk, local_ch, local_ker, local_ky, local_kx, local_fy, local_fx;
        begin
            local_gk = base_k + lane;
            if (local_gk >= K_TOTAL) begin
                expected_feeder_ifm_tb = 8'd0;
            end else begin
                local_ch = local_gk / 9;
                local_ker = local_gk % 9;
                local_ky = local_ker / 3;
                local_kx = local_ker % 3;
                local_fy = out_y * CONV_STRIDE + local_ky - CONV_PAD;
                local_fx = out_x * CONV_STRIDE + local_kx - CONV_PAD;
                if (local_ch >= CIN || local_fy < 0 || local_fy >= FM_H ||
                    local_fx < 0 || local_fx >= FM_W)
                    expected_feeder_ifm_tb = 8'd0;
                else
                    expected_feeder_ifm_tb = feat[local_ch][local_fy][local_fx];
            end
        end
    endfunction

    task cfg_write;
        input [6:0] addr;
        input [31:0] data;
        begin
`ifdef TB_CONV_ACCEL_CORE_USE_AXI_LITE
            @(negedge clk);
            axi_awaddr = {addr, 2'b00};
            axi_wdata = data;
            axi_wstrb = 4'hf;
            axi_awvalid = 1'b1;
            axi_wvalid = 1'b1;
            wait(axi_awready && axi_wready);
            @(negedge clk);
            axi_awvalid = 1'b0;
            axi_wvalid = 1'b0;
            axi_bready = 1'b1;
            wait(axi_bvalid);
            if (axi_bresp !== 2'b00) begin
                $display("[FAIL] AXI cfg write addr=%0h bresp=%b", addr, axi_bresp);
                fail = fail + 1;
            end
            @(posedge clk);
            @(negedge clk);
            axi_bready = 1'b0;
`else
            @(negedge clk);
            cfg_addr = addr;
            cfg_wdata = data;
            cfg_wr_en = 1'b1;
            @(negedge clk);
            cfg_wr_en = 1'b0;
`endif
        end
    endtask

    task cfg_read;
        input [6:0] addr;
        output [31:0] data;
        begin
`ifdef TB_CONV_ACCEL_CORE_USE_AXI_LITE
            @(negedge clk);
            axi_araddr = {addr, 2'b00};
            axi_arvalid = 1'b1;
            wait(axi_arready);
            @(negedge clk);
            axi_arvalid = 1'b0;
            axi_rready = 1'b1;
            wait(axi_rvalid);
            data = axi_rdata;
            if (axi_rresp !== 2'b00) begin
                $display("[FAIL] AXI cfg read addr=%0h rresp=%b", addr, axi_rresp);
                fail = fail + 1;
            end
            @(posedge clk);
            @(negedge clk);
            axi_rready = 1'b0;
`else
            cfg_addr = addr;
            cfg_rd_en = 1'b1;
            #1;
            data = cfg_rdata;
            @(negedge clk);
            cfg_rd_en = 1'b0;
`endif
        end
    endtask

    task quant_write;
        input integer lane;
        input [15:0] mult;
        input [3:0] shift;
        input [7:0] zp;
        begin
`ifdef TB_CONV_ACCEL_CORE_USE_AXI_LITE
            cfg_write(6'h20, {26'd0, lane[5:0]});
            cfg_write(6'h21, {zp, 4'd0, shift, mult});
`else
            @(negedge clk);
            quant_wr_addr = lane[5:0];
            quant_wr_data = {zp, 4'd0, shift, mult};
            quant_wr_en = 1'b1;
            @(negedge clk);
            quant_wr_en = 1'b0;
`endif
        end
    endtask

    task act_lut_write;
        input [7:0] addr;
        input [7:0] data;
        begin
`ifdef TB_CONV_ACCEL_CORE_USE_AXI_LITE
            cfg_write(6'h22, {24'd0, addr});
            cfg_write(6'h23, {24'd0, data});
`else
            @(negedge clk);
            act_lut_wr_addr = addr;
            act_lut_wr_data = data;
            act_lut_wr_en = 1'b1;
            @(negedge clk);
            act_lut_wr_en = 1'b0;
`endif
        end
    endtask

    task clear_inputs;
        begin
            cfg_wr_en = 1'b0;
            cfg_rd_en = 1'b0;
            cfg_addr = 6'd0;
            cfg_wdata = 32'd0;
            cfg_read_data = 32'd0;
`ifdef TB_CONV_ACCEL_CORE_USE_AXI_LITE
            axi_awaddr = 8'd0;
            axi_awvalid = 1'b0;
            axi_wdata = 32'd0;
            axi_wstrb = 4'h0;
            axi_wvalid = 1'b0;
            axi_bready = 1'b0;
            axi_araddr = 8'd0;
            axi_arvalid = 1'b0;
            axi_rready = 1'b0;
`endif
            bias_load_done = 1'b0;
            weight_tile_ready = 1'b0;
            bias_wr_addr = 6'd0;
            bias_wr_data = {PSUM_W{1'b0}};
            bias_wr_en = 1'b0;
            wgt_tile_wr_en = 1'b0;
            wgt_tile_wr_addr = {WGT_TILE_AW{1'b0}};
            wgt_tile_wr_data = 8'd0;
`ifdef TB_CONV_ACCEL_CORE_USE_BW_STREAM
            bias_s_valid = 1'b0;
            bias_s_data = {PSUM_W{1'b0}};
            weight_s_valid = 1'b0;
            weight_s_data = {WGT_W{1'b0}};
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
            bias_axis_tvalid = 1'b0;
            bias_axis_tdata = 64'd0;
            bias_axis_tkeep = 8'd0;
            bias_axis_tlast = 1'b0;
            weight_axis_tvalid = 1'b0;
            weight_axis_tdata = 64'd0;
            weight_axis_tkeep = 8'd0;
            weight_axis_tlast = 1'b0;
            ifm_axis_tvalid = 1'b0;
            ifm_axis_tdata = 64'd0;
            ifm_axis_tkeep = 8'd0;
            ifm_axis_tlast = 1'b0;
            ofm_m_axis_tready = 1'b1;
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
            ifm_line_s_valid = 1'b0;
            for (b = 0; b < IFM_BANKS; b = b + 1)
                ifm_line_s_data[b] = 8'd0;
            ofm_m_ready = 1'b1;
`endif
            dma_bank_wr_en = {IFM_BANKS{1'b0}};
            dma_wr_x = 9'd0;
            dma_wr_fy = 10'd0;
            dma_line_advance = 1'b0;
            for (b = 0; b < IFM_BANKS; b = b + 1)
                dma_wr_data[b] = 8'd0;
            quant_wr_en = 1'b0;
            quant_wr_addr = 6'd0;
            quant_wr_data = 32'd0;
            quant_rd_addr = 6'd0;
            act_lut_wr_en = 1'b0;
            act_lut_wr_addr = 8'd0;
            act_lut_wr_data = 8'd0;
        end
    endtask

    task write_row;
        input integer row_y;
        integer k_base;
        integer vector_y;
        integer vector_beat;
        integer vector_byte;
        integer vector_ch;
        integer raw_y;
        integer raw_ch;
        integer raw_byte_idx;
        integer raw_total_bytes;
        integer raw_first_y;
        integer raw_last_y;
        reg [63:0] axis_word;
        reg [7:0] axis_keep;
        begin
            k_base = current_pass_base_k;
`ifdef TB_CONV_ACCEL_CORE_RAW_HWC_IFM
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
            if (ps_line_fill_count == batch_ifm_tile_end_count) begin
`ifdef TB_CONV_ACCEL_CORE_KERNEL_1X1
                raw_first_y = run_oy_base;
                raw_last_y = run_oy_base + run_ofm_h - 1;
`else
                raw_first_y = run_oy_base * CONV_STRIDE - CONV_PAD;
                raw_last_y =
                    (run_oy_base + run_ofm_h - 1) * CONV_STRIDE -
                    CONV_PAD + 2;
                if (raw_first_y < 0)
                    raw_first_y = 0;
                if (raw_last_y >= FM_H)
                    raw_last_y = FM_H - 1;
`endif
                raw_total_bytes = (raw_last_y - raw_first_y + 1) * FM_W * CIN;
                raw_byte_idx = 0;
                axis_word = 64'd0;
                axis_keep = 8'd0;
                for (raw_y = raw_first_y; raw_y <= raw_last_y; raw_y = raw_y + 1) begin
                    for (x = 0; x < FM_W; x = x + 1) begin
                        for (raw_ch = 0; raw_ch < CIN; raw_ch = raw_ch + 1) begin
                            axis_word[(raw_byte_idx % 8)*8 +: 8] =
                                stream_ifm_byte_tb(raw_ch, raw_y, x);
                            axis_keep[raw_byte_idx % 8] = 1'b1;
                            raw_byte_idx = raw_byte_idx + 1;
                            if ((raw_byte_idx % 8) == 0 ||
                                raw_byte_idx == raw_total_bytes) begin
                                @(negedge clk);
                                ifm_axis_tdata = axis_word;
                                ifm_axis_tkeep = axis_keep;
                                ifm_axis_tlast =
                                    (raw_byte_idx == raw_total_bytes);
                                ifm_axis_tvalid = 1'b1;
                                wait(ifm_axis_tready);
                                @(posedge clk);
                                axis_word = 64'd0;
                                axis_keep = 8'd0;
                            end
                        end
                    end
                end
                @(negedge clk);
                ifm_axis_tvalid = 1'b0;
                ifm_axis_tdata = 64'd0;
                ifm_axis_tkeep = 8'd0;
                ifm_axis_tlast = 1'b0;
            end
            wait(!feeder_fill_req);
`else
            $fatal(1, "raw HWC IFM test requires AXI stream");
`endif
`else
`ifdef TB_CONV_ACCEL_CORE_KERNEL_1X1
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
            repeat (2) @(negedge clk);
            k_base = ((ps_line_fill_count - 1) % K_PASSES) * ROWS;
            for (vector_y = run_oy_base;
                 vector_y < run_oy_base + run_ofm_h;
                 vector_y = vector_y + 1) begin
                for (x = 0; x < FM_W; x = x + 1) begin
                    for (vector_beat = 0; vector_beat < 3; vector_beat = vector_beat + 1) begin
                        @(negedge clk);
                        axis_word = 64'd0;
                        for (vector_byte = 0; vector_byte < 8; vector_byte = vector_byte + 1) begin
                            vector_ch = k_base + vector_beat * 8 + vector_byte;
                            axis_word[vector_byte*8 +: 8] =
                                (vector_beat * 8 + vector_byte < ROWS &&
                                 vector_ch < CIN) ?
                                stream_ifm_byte_tb(vector_ch, vector_y, x) :
                                INPUT_ZERO_POINT;
                        end
                        ifm_axis_tdata = axis_word;
                        ifm_axis_tkeep = 8'hff;
                        ifm_axis_tlast =
                            (vector_y == run_oy_base + run_ofm_h - 1) &&
                            (x == FM_W - 1) && (vector_beat == 2) &&
                            (ps_line_fill_count == batch_ifm_tile_end_count);
                        ifm_axis_tvalid = 1'b1;
                        wait(ifm_axis_tready);
                        @(posedge clk);
                    end
                end
            end
            @(negedge clk);
            ifm_axis_tvalid = 1'b0;
            ifm_axis_tdata = 64'd0;
            ifm_axis_tkeep = 8'd0;
            ifm_axis_tlast = 1'b0;
`else
            $fatal(1, "native 1x1 test requires AXI stream");
`endif
`else
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
            wait(ifm_axis_tready);
`elsif TB_CONV_ACCEL_CORE_USE_FULL_STREAM
            wait(ifm_line_s_ready);
`else
            @(negedge clk);
            dma_bank_wr_en = {IFM_BANKS{1'b1}};
            dma_wr_fy = row_y[9:0];
`endif
            for (x = 0; x < FM_W; x = x + 1) begin
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
                @(negedge clk);
                axis_word = 64'd0;
`elsif TB_CONV_ACCEL_CORE_USE_FULL_STREAM
                @(negedge clk);
                ifm_line_s_valid = 1'b1;
`else
                dma_wr_x = x[8:0];
`endif
                for (b = 0; b < IFM_BANKS; b = b + 1) begin
                    bank_ch = channel_for_bank(k_base, b);
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
                    axis_word[b*8 +: 8] = stream_ifm_byte_tb(bank_ch, row_y, x);
`elsif TB_CONV_ACCEL_CORE_USE_FULL_STREAM
                    ifm_line_s_data[b] = stream_ifm_byte_tb(bank_ch, row_y, x);
`else
                    dma_wr_data[b] = (bank_ch >= 0) ? feat[bank_ch][row_y][x] : 8'd0;
`endif
                end
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
                ifm_axis_tdata = axis_word;
                ifm_axis_tkeep = IFM_TKEEP_MASK;
`ifdef TB_CONV_ACCEL_CORE_BATCH_STREAM
                ifm_axis_tlast = (x == FM_W - 1) &&
                                  (ps_line_fill_count == batch_ifm_tile_end_count);
`else
                ifm_axis_tlast = (x == FM_W - 1);
`endif
                ifm_axis_tvalid = 1'b1;
                wait(ifm_axis_tready);
                @(posedge clk);
`endif
`ifndef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
`ifndef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
                @(negedge clk);
`endif
`endif
            end
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
            @(negedge clk);
            ifm_axis_tvalid = 1'b0;
            ifm_axis_tdata = 64'd0;
            ifm_axis_tkeep = 8'd0;
            ifm_axis_tlast = 1'b0;
`elsif TB_CONV_ACCEL_CORE_USE_FULL_STREAM
            @(negedge clk);
            ifm_line_s_valid = 1'b0;
            for (b = 0; b < IFM_BANKS; b = b + 1)
                ifm_line_s_data[b] = 8'd0;
`else
            dma_line_advance = 1'b1;
            @(negedge clk);
            dma_line_advance = 1'b0;
            dma_bank_wr_en = {IFM_BANKS{1'b0}};
`endif
`endif
`endif
        end
    endtask

    task service_bias;
        integer i;
        integer base;
        reg [63:0] axis_word;
        begin
            ps_bias_service_count = ps_bias_service_count + 1;
            base = current_cout_base;
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
            wait(bias_axis_tready);
`elsif TB_CONV_ACCEL_CORE_USE_BW_STREAM
            wait(bias_s_ready);
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
            for (i = 0; i < COUT_TILE; i = i + 2) begin
                @(negedge clk);
                axis_word = 64'd0;
                axis_word[31:0] = (base + i < COUT_TOTAL) ? bias[base + i] : {PSUM_W{1'b0}};
                axis_word[63:32] = (base + i + 1 < COUT_TOTAL) ? bias[base + i + 1] : {PSUM_W{1'b0}};
                bias_axis_tdata = axis_word;
                bias_axis_tkeep = 8'hff;
`ifdef TB_CONV_ACCEL_CORE_BATCH_STREAM
                bias_axis_tlast = (i + 2 >= COUT_TILE) &&
                                  ((ps_bias_service_count % COUT_BLOCKS) == 0);
`else
                bias_axis_tlast = (i + 2 >= COUT_TILE);
`endif
                bias_axis_tvalid = 1'b1;
                wait(bias_axis_tready);
                @(posedge clk);
            end
            @(negedge clk);
            bias_axis_tvalid = 1'b0;
            bias_axis_tdata = 64'd0;
            bias_axis_tkeep = 8'd0;
            bias_axis_tlast = 1'b0;
`else
            for (i = 0; i < COUT_TILE; i = i + 1) begin
                @(negedge clk);
`ifdef TB_CONV_ACCEL_CORE_USE_BW_STREAM
                bias_s_valid = 1'b1;
                bias_s_data = (base + i < COUT_TOTAL) ? bias[base + i] : {PSUM_W{1'b0}};
`else
                bias_wr_en = 1'b1;
                bias_wr_addr = i[5:0];
                bias_wr_data = (base + i < COUT_TOTAL) ? bias[base + i] : {PSUM_W{1'b0}};
`endif
            end
            @(negedge clk);
`ifdef TB_CONV_ACCEL_CORE_USE_BW_STREAM
            bias_s_valid = 1'b0;
            bias_s_data = {PSUM_W{1'b0}};
`else
            bias_wr_en = 1'b0;
            bias_load_done = 1'b1;
            @(negedge clk);
            bias_load_done = 1'b0;
`endif
`endif
        end
    endtask

    task service_weight;
        integer co_base;
        integer k_base;
        integer gk;
        integer axis_lane;
        reg [63:0] axis_word;
        begin
            ps_weight_service_count = ps_weight_service_count + 1;
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
            co_base = (((ps_weight_service_count - 1) %
                       (COUT_BLOCKS * K_PASSES)) / K_PASSES) * COUT_TILE;
            k_base = (((ps_weight_service_count - 1) %
                      (COUT_BLOCKS * K_PASSES)) % K_PASSES) * ROWS;
`else
            co_base = current_cout_base;
            k_base = current_pass_base_k;
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
            wait(weight_axis_tready);
            axis_lane = 0;
            axis_word = 64'd0;
`elsif TB_CONV_ACCEL_CORE_USE_BW_STREAM
            wait(weight_s_ready);
`endif
            for (kk = 0; kk < ROWS; kk = kk + 1) begin
                for (cc = 0; cc < COUT_TILE; cc = cc + 1) begin
                    gk = k_base + kk;
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
                    axis_word[axis_lane*8 +: 8] = ((gk < K_TOTAL) && (co_base + cc < COUT_TOTAL)) ?
                                                   weight[gk][co_base + cc] : 8'd0;
                    if (axis_lane == 7) begin
                        @(negedge clk);
                        weight_axis_tdata = axis_word;
                        weight_axis_tkeep = 8'hff;
`ifdef TB_CONV_ACCEL_CORE_BATCH_STREAM
                        weight_axis_tlast =
                            (kk == ROWS - 1) && (cc == COUT_TILE - 1) &&
                            ((ps_weight_service_count % (COUT_BLOCKS * K_PASSES)) == 0);
`else
                        weight_axis_tlast = (kk == ROWS - 1) && (cc == COUT_TILE - 1);
`endif
                        weight_axis_tvalid = 1'b1;
                        wait(weight_axis_tready);
                        @(posedge clk);
                        axis_word = 64'd0;
                        axis_lane = 0;
                    end else begin
                        axis_lane = axis_lane + 1;
                    end
`else
                    @(negedge clk);
`ifdef TB_CONV_ACCEL_CORE_USE_BW_STREAM
                    weight_s_valid = 1'b1;
                    weight_s_data = ((gk < K_TOTAL) && (co_base + cc < COUT_TOTAL)) ?
                                    weight[gk][co_base + cc] : 8'd0;
`else
                    wgt_tile_wr_en = 1'b1;
                    wgt_tile_wr_addr = kk*COUT_TILE + cc;
                    wgt_tile_wr_data = ((gk < K_TOTAL) && (co_base + cc < COUT_TOTAL)) ?
                                       weight[gk][co_base + cc] : 8'd0;
`endif
`endif
                end
            end
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
            @(negedge clk);
            weight_axis_tvalid = 1'b0;
            weight_axis_tdata = 64'd0;
            weight_axis_tkeep = 8'd0;
            weight_axis_tlast = 1'b0;
`else
            @(negedge clk);
`ifdef TB_CONV_ACCEL_CORE_USE_BW_STREAM
            weight_s_valid = 1'b0;
            weight_s_data = {WGT_W{1'b0}};
`else
            wgt_tile_wr_en = 1'b0;
            weight_tile_ready = 1'b1;
            @(negedge clk);
            weight_tile_ready = 1'b0;
`endif
`endif
        end
    endtask

    task get_tile_cfg;
        input integer tile_id;
        output integer oy_base;
        output integer tile_h;
        output integer pixel_base;
        begin
            if (tile_id == 0) begin
                oy_base = TILE_OY_BASE;
                tile_h = ACTIVE_OFM_H;
                pixel_base = TILE_PIXEL_BASE;
            end else if (tile_id == 1) begin
                oy_base = TILE1_OY_BASE;
                tile_h = TILE1_ACTIVE_OFM_H;
                pixel_base = TILE1_PIXEL_BASE;
            end else begin
                oy_base = TILE2_OY_BASE;
                tile_h = TILE2_ACTIVE_OFM_H;
                pixel_base = TILE2_PIXEL_BASE;
            end
        end
    endtask

    task run_tile;
        input integer tile_id;
        begin
            get_tile_cfg(tile_id, run_oy_base, run_ofm_h, run_pixel_base);
            run_pixels = OFM_W * run_ofm_h;
`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
            $display("[EARLY] t=%0t run_tile%0d wait idle", $time, tile_id);
            $fflush();
`endif
            cfg_read(6'h00, cfg_read_data);
            while (cfg_read_data[0] != 1'b0)
                cfg_read(6'h00, cfg_read_data);
`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
            $display("[EARLY] t=%0t run_tile%0d configure oy=%0d h=%0d pixels=%0d pixel_base=%0d",
                $time, tile_id, run_oy_base, run_ofm_h, run_pixels, run_pixel_base);
            $fflush();
`endif
            cfg_write(6'h06, run_pixels);
            cfg_write(6'h08, {7'd0, run_ofm_h[8:0], 7'd0, run_oy_base[8:0]});
            cfg_write(6'h09, run_pixel_base[23:0]);
`ifdef TB_CONV_ACCEL_CORE_COLTRACE
            cfg_write(7'h59, {1'b1, 7'd0, 8'd0, 16'd0});
            cfg_write(7'h6e, 32'd0);
`endif
`ifdef TB_CONV_ACCEL_CORE_BATCH_STREAM
`ifdef TB_CONV_ACCEL_CORE_RAW_HWC_IFM
            batch_ifm_tile_packets = 1;
`else
`ifdef TB_CONV_ACCEL_CORE_KERNEL_1X1
            batch_ifm_tile_packets = K_PASSES * COUT_BLOCKS;
`else
            batch_first_fy = run_oy_base - CONV_PAD;
            if (batch_first_fy < 0)
                batch_first_fy = 0;
            batch_last_fy = run_oy_base + run_ofm_h;
            if (batch_last_fy >= FM_H)
                batch_last_fy = FM_H - 1;
            batch_ifm_tile_packets =
                (batch_last_fy - batch_first_fy + 1) * K_PASSES * COUT_BLOCKS;
`endif
`endif
            batch_ifm_tile_end_count = ps_line_fill_count + batch_ifm_tile_packets;
`ifdef TB_CONV_ACCEL_CORE_RAW_HWC_IFM
            cfg_write(6'h19, 32'd3 |
                (early_drain_override ? 32'd4 : 32'd0) |
                (pass_prefetch_override ? 32'd8 : 32'd0) |
                (psum_stream_overlap_override ? 32'd16 : 32'd0) |
                (continuous_psum_override ? 32'd32 : 32'd0) |
                (column_psum_override ? 32'd64 : 32'd0) |
                (during_compute_prefetch_override ? 32'd128 : 32'd0));
`else
            cfg_write(6'h19, 32'd1 |
                (early_drain_override ? 32'd4 : 32'd0) |
                (psum_stream_overlap_override ? 32'd16 : 32'd0));
`endif
            cfg_write(6'h1a, COUT_BLOCKS);
            cfg_write(6'h1b, COUT_BLOCKS * K_PASSES);
            cfg_write(6'h1c, batch_ifm_tile_packets);
`endif
            ps_tile_start_count = ps_tile_start_count + 1;
`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
            $display("[EARLY] t=%0t run_tile%0d start", $time, tile_id);
            $fflush();
`endif
            cfg_write(6'h00, 32'd1);
            cfg_read(6'h00, cfg_read_data);
`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
            $display("[EARLY] t=%0t run_tile%0d first status=0x%08h", $time, tile_id, cfg_read_data);
            $fflush();
`endif
            while (cfg_read_data[1] != 1'b1 || cfg_read_data[0] != 1'b0)
                cfg_read(6'h00, cfg_read_data);
            ps_done_seen_count = ps_done_seen_count + 1;
`ifdef TB_CONV_ACCEL_CORE_COLTRACE
            if (continuous_psum_override) begin
                cfg_read(7'h6e, cfg_read_data);
                if (!cfg_read_data[31]) begin
                    $display("[FAIL] column trace not valid");
                    fail = fail + 1;
                end else pass = pass + 1;
                for (b = 0; b < COLS; b = b + 1) begin
                    cfg_write(7'h6e, b);
                    cfg_read(7'h6f, cfg_read_data);
                    coltrace_first = cfg_read_data;
                    cfg_read(7'h70, cfg_read_data);
                    coltrace_last = cfg_read_data;
                    cfg_read(7'h71, cfg_read_data);
                    coltrace_count = cfg_read_data;
                    if (cfg_read_data != run_pixels) begin
                        $display("[FAIL] column trace col=%0d writes=%0d exp=%0d",
                                 b, cfg_read_data, run_pixels);
                        fail = fail + 1;
                    end else pass = pass + 1;
                    cfg_read(7'h72, cfg_read_data);
                    coltrace_empty = cfg_read_data;
                    $display("[COLTRACE] col=%0d first_wr=%0d last_wr=%0d writes=%0d empty_wait=%0d",
                             b, coltrace_first, coltrace_last,
                             coltrace_count, coltrace_empty);
                end
                cfg_read(7'h73, cfg_read_data);
                $display("[COLTRACE] missing_or=0x%08h", cfg_read_data);
                cfg_read(7'h74, cfg_read_data);
                $display("[COLTRACE] missing_first=0x%08h", cfg_read_data);
                cfg_read(7'h75, cfg_read_data);
                $display("[COLTRACE] missing_last=0x%08h", cfg_read_data);
            end
`endif
`ifdef TB_CONV_ACCEL_CORE_BATCH_STREAM
            cfg_read(6'h1d, cfg_read_data);
            if (cfg_read_data != COUT_BLOCKS) begin
                $display("[FAIL] batch bias packets got=%0d exp=%0d", cfg_read_data, COUT_BLOCKS);
                fail = fail + 1;
            end else pass = pass + 1;
            cfg_read(6'h1e, cfg_read_data);
            if (cfg_read_data != COUT_BLOCKS * K_PASSES) begin
                $display("[FAIL] batch weight packets got=%0d exp=%0d",
                         cfg_read_data, COUT_BLOCKS * K_PASSES);
                fail = fail + 1;
            end else pass = pass + 1;
            cfg_read(6'h1f, cfg_read_data);
            if (cfg_read_data != batch_ifm_tile_packets) begin
                $display("[FAIL] batch IFM packets got=%0d exp=%0d",
                         cfg_read_data, batch_ifm_tile_packets);
                fail = fail + 1;
            end else pass = pass + 1;
`endif
`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
            $display("[EARLY] t=%0t run_tile%0d done status=0x%08h", $time, tile_id, cfg_read_data);
            $fflush();
`endif
            repeat (6) @(negedge clk);
            ps_done_clear_count = ps_done_clear_count + 1;
            cfg_write(6'h00, 32'd2);
            repeat (6) @(negedge clk);
        end
    endtask

    initial begin
        @(negedge rst);
        forever begin
            wait(bias_load_req);
`ifdef TB_CONV_ACCEL_CORE_STAGE_PRINT
            $display("[STAGE] t=%0t bias load start cout=%0d", $time, current_cout_base);
            $fflush();
`endif
            service_bias();
`ifdef TB_CONV_ACCEL_CORE_STAGE_PRINT
            $display("[STAGE] t=%0t bias load done cout=%0d", $time, current_cout_base);
            $fflush();
`endif
            wait(!bias_load_req);
        end
    end

    initial begin
        @(negedge rst);
        forever begin
            wait(weight_load_req);
`ifdef TB_CONV_ACCEL_CORE_STAGE_PRINT
            $display("[STAGE] t=%0t weight load start cout=%0d k=%0d",
                $time, current_cout_base, current_pass_base_k);
            $fflush();
`endif
            service_weight();
`ifdef TB_CONV_ACCEL_CORE_STAGE_PRINT
            $display("[STAGE] t=%0t weight load done cout=%0d k=%0d",
                $time, current_cout_base, current_pass_base_k);
            $fflush();
`endif
            wait(!weight_load_req);
        end
    end

    initial begin
        @(negedge rst);
        forever begin
            wait(feeder_fill_req);
            ps_line_fill_count = ps_line_fill_count + 1;
`ifdef TB_CONV_ACCEL_CORE_STAGE_PRINT
            $display("[STAGE] t=%0t IFM line fill start count=%0d fy=%0d k=%0d",
                $time, ps_line_fill_count, feeder_fill_fy, current_pass_base_k);
            $fflush();
`endif
            write_row(feeder_fill_fy);
`ifdef TB_CONV_ACCEL_CORE_STAGE_PRINT
            $display("[STAGE] t=%0t IFM line fill done count=%0d fy=%0d k=%0d",
                $time, ps_line_fill_count, feeder_fill_fy, current_pass_base_k);
            $fflush();
`endif
            @(posedge clk);
            #1;
        end
    end

    always @(negedge clk) begin
        if (!rst && ofm_mem_wr_en) begin
            if (ofm_mem_wr_addr < OFM_WORDS)
                ofm_mem[ofm_mem_wr_addr] <= ofm_mem_wr_data;
            if (ofm_mem_wr_count >= EXPECTED_OFM_WRITES && first_extra_ofm_wr_index < 0) begin
                first_extra_ofm_wr_index <= ofm_mem_wr_count;
                first_extra_ofm_wr_addr <= ofm_mem_wr_addr;
                first_extra_ofm_wr_data <= ofm_mem_wr_data;
            end
            ofm_mem_wr_count <= ofm_mem_wr_count + 1;
        end
    end

    always @(posedge clk) begin
        if (!rst && `TB_DUT_LAYER.final_fifo_valid && `TB_DUT_LAYER.rq_in_ready) begin
            for (final_raw_lane = 0; final_raw_lane < COUT_TILE; final_raw_lane = final_raw_lane + 1) begin
                if (`TB_DUT_LAYER.final_fifo_channel_valid[final_raw_lane] &&
                    (`TB_DUT_LAYER.final_fifo_cout_base + final_raw_lane) < COUT_TOTAL) begin
                    final_raw_index = (`TB_DUT_LAYER.final_fifo_addr * COUT_TOTAL) +
                                      `TB_DUT_LAYER.final_fifo_cout_base + final_raw_lane;
                    if (final_raw_index < OFM_WORDS) begin
                        final_raw_mem[final_raw_index] <=
                            $signed(`TB_DUT_LAYER.final_fifo_data[final_raw_lane*PSUM_W +: PSUM_W]);
                        final_raw_valid[final_raw_index] <= 1'b1;
                    end
                end
            end
        end
    end

`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
    always @(posedge clk) begin
        if (!rst && ofm_m_axis_tvalid && ofm_m_axis_tready && ofm_m_axis_tlast)
            axis_ofm_tlast_count <= axis_ofm_tlast_count + 1;
    end
`endif

`ifdef TB_CONV_ACCEL_CORE_OFM_READY_STALL
    always @(posedge clk) begin
        if (rst) begin
            ofm_ready_cycle <= 0;
            ofm_stall_count <= 0;
            ofm_stall_seen <= 1'b0;
`ifdef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
            ofm_m_ready <= 1'b1;
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
            ofm_m_axis_tready <= 1'b1;
`endif
        end else begin
            ofm_ready_cycle <= ofm_ready_cycle + 1;
            if (!ofm_stall_seen && ofm_mem_wr_count >= 64) begin
                ofm_stall_seen <= 1'b1;
                ofm_stall_count <= 12;
`ifdef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
                ofm_m_ready <= 1'b0;
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
                ofm_m_axis_tready <= 1'b0;
`endif
            end else if (ofm_stall_count != 0) begin
                ofm_stall_count <= ofm_stall_count - 1;
`ifdef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
                ofm_m_ready <= 1'b0;
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
                ofm_m_axis_tready <= 1'b0;
`endif
            end else begin
`ifdef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
                ofm_m_ready <= 1'b1;
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
                ofm_m_axis_tready <= 1'b1;
`endif
            end
        end
    end
`endif

    always @(posedge clk) begin
`ifdef TB_CONV_ACCEL_CORE_KERNEL_1X1
        if (!rst && `TB_DUT_LAYER.u_top.vector_ifm_valid &&
            `TB_DUT_LAYER.u_top.vector_ifm_ready) begin
            ifm_write_count <= ifm_write_count + 1;
`ifdef TB_CONV_ACCEL_CORE_CHECK_VECTOR_IFM
            vector_check_y = run_oy_base + vector_check_pixel / FM_W;
            vector_check_x = vector_check_pixel % FM_W;
            for (vector_check_lane = 0; vector_check_lane < ROWS;
                 vector_check_lane = vector_check_lane + 1) begin
                vector_check_ch =
                    ((ps_line_fill_count - 1) % K_PASSES) * ROWS +
                    vector_check_lane;
                vector_check_expected =
                    (vector_check_ch < CIN) ?
                    feat[vector_check_ch][vector_check_y][vector_check_x] : 8'd0;
                if (`TB_DUT_LAYER.u_top.vector_ifm_data[vector_check_lane*8 +: 8] !==
                    vector_check_expected) begin
                    if (fail < 20)
                        $display("[FAIL] vector IFM packet=%0d pixel=%0d lane=%0d ch=%0d got=%0d exp=%0d",
                            ps_line_fill_count, vector_check_pixel,
                            vector_check_lane, vector_check_ch,
                            $signed(`TB_DUT_LAYER.u_top.vector_ifm_data[vector_check_lane*8 +: 8]),
                            $signed(vector_check_expected));
                    fail = fail + 1;
                end
            end
            if (vector_check_pixel + 1 == run_pixels)
                vector_check_pixel = 0;
            else
                vector_check_pixel = vector_check_pixel + 1;
`endif
        end
`else
        if (!rst && `TB_DUT_LAYER.u_top.feeder_ifm_valid)
            ifm_write_count <= ifm_write_count + 1;
`endif
        if (!rst && `TB_DUT_LAYER.compute_fire)
            compute_fire_count <= compute_fire_count + 1;
`ifdef TB_CONV_ACCEL_CORE_STAGE_PRINT
        if (!rst && `TB_DUT_LAYER.compute_fire &&
            ((compute_fire_count + 1) % 64 == 0)) begin
            $display("[DATA] t=%0t compute=%0d/%0d cout=%0d k=%0d ifm_full=%h",
                $time, compute_fire_count + 1,
                RUN_PIXELS * K_PASSES * COUT_BLOCKS,
                current_cout_base, current_pass_base_k,
                `TB_DUT_LAYER.u_top.ifm_fifo_full);
            $fflush();
        end
        if (!rst && ofm_mem_wr_en && ((ofm_mem_wr_count + 1) % 256 == 0)) begin
            $display("[DATA] t=%0t ofm=%0d/%0d addr=%0d",
                $time, ofm_mem_wr_count + 1, EXPECTED_OFM_WRITES,
                ofm_mem_wr_addr);
            $fflush();
        end
`endif
        if (!rst && `TB_DUT_LAYER.u_top.u_core.psum_fifo_wr_en[0])
            psum_wr_count <= psum_wr_count + 1;
        if (!rst && `TB_DUT_LAYER.drain_packet_valid &&
            `TB_DUT_LAYER.drain_packet_ready)
            drain_capture_count <= drain_capture_count + 1;
        if (!rst && `TB_DUT_LAYER.done)
            layer_done_pulse_count <= layer_done_pulse_count + 1;
    end

`ifdef TB_CONV_ACCEL_CORE_CHECK_FEEDER_IFM
    always @(posedge clk) begin
        if (!rst && (|`TB_DUT_IFM_LOADER.dma_bank_wr_en)) begin
            diag_loader_write_count <= diag_loader_write_count + 1;
            if (`TB_DUT_IFM_LOADER.dma_wr_fy >= FM_H ||
                `TB_DUT_IFM_LOADER.dma_wr_x >= FM_W) begin
                $display("[FAIL] diagnostic IFM loader write out of range fy=%0d x=%0d",
                    `TB_DUT_IFM_LOADER.dma_wr_fy, `TB_DUT_IFM_LOADER.dma_wr_x);
                diag_loader_fail_count <= diag_loader_fail_count + 1;
            end else begin
                for (b = 0; b < IFM_BANKS; b = b + 1) begin
                    diag_loader_bank_ch = channel_for_bank(current_pass_base_k, b);
                    diag_loader_expected = (diag_loader_bank_ch >= 0) ?
                        feat[diag_loader_bank_ch][`TB_DUT_IFM_LOADER.dma_wr_fy][`TB_DUT_IFM_LOADER.dma_wr_x] :
                        8'd0;
                    if (`TB_DUT_IFM_LOADER.dma_wr_data[b] !== diag_loader_expected) begin
                        if (diag_loader_fail_count < 32) begin
                            $display("[FAIL] diagnostic IFM loader fy=%0d x=%0d bank=%0d ch=%0d got=%0d exp=%0d k_base=%0d",
                                `TB_DUT_IFM_LOADER.dma_wr_fy,
                                `TB_DUT_IFM_LOADER.dma_wr_x,
                                b, diag_loader_bank_ch,
                                $signed(`TB_DUT_IFM_LOADER.dma_wr_data[b]),
                                $signed(diag_loader_expected),
                                current_pass_base_k);
                            $fflush();
                        end
                        diag_loader_fail_count <= diag_loader_fail_count + 1;
                    end
                end
            end
        end

        if (!rst && `TB_DUT_LAYER.u_top.feeder_ifm_valid) begin
            for (feeder_lane = 0; feeder_lane < ROWS; feeder_lane = feeder_lane + 1) begin
                feeder_ifm_got = `TB_DUT_LAYER.u_top.feeder_ifm_data[feeder_lane*8 +: 8];
                feeder_ifm_expected = expected_feeder_ifm_tb(
                    current_pass_base_k, feeder_lane,
                    `TB_DUT_LAYER.u_top.feeder_oy,
                    `TB_DUT_LAYER.u_top.feeder_ox);
                if (feeder_ifm_got !== feeder_ifm_expected) begin
                    feeder_gk = current_pass_base_k + feeder_lane;
                    feeder_ch = feeder_gk / 9;
                    feeder_ker = feeder_gk % 9;
                    feeder_ky = feeder_ker / 3;
                    feeder_kx = feeder_ker % 3;
                    feeder_fy = `TB_DUT_LAYER.u_top.feeder_oy * CONV_STRIDE + feeder_ky - CONV_PAD;
                    feeder_fx = `TB_DUT_LAYER.u_top.feeder_ox * CONV_STRIDE + feeder_kx - CONV_PAD;
                    if (feeder_ifm_fail_count < 32) begin
                        $display("[FAIL] feeder IFM oy=%0d ox=%0d lane=%0d k=%0d ch=%0d ky=%0d kx=%0d fy=%0d fx=%0d got=%0d exp=%0d",
                            `TB_DUT_LAYER.u_top.feeder_oy,
                            `TB_DUT_LAYER.u_top.feeder_ox,
                            feeder_lane, feeder_gk, feeder_ch, feeder_ky, feeder_kx,
                            feeder_fy, feeder_fx,
                            $signed(feeder_ifm_got), $signed(feeder_ifm_expected));
                        $fflush();
                    end
                    feeder_ifm_fail_count <= feeder_ifm_fail_count + 1;
                end
            end
        end
    end
`endif

`ifdef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
    always @(posedge clk) begin
        if (!rst) begin
            if (`TB_DUT_IFM_LOADER.dma_line_advance)
                ifm_loader_advance_count <= ifm_loader_advance_count + 1;
            if (|`TB_DUT_IFM_LOADER.dma_bank_wr_en) begin
                ifm_loader_write_count <= ifm_loader_write_count + 1;
                if (`TB_DUT_IFM_LOADER.dma_wr_fy >= FM_H ||
                    `TB_DUT_IFM_LOADER.dma_wr_x >= FM_W) begin
                    $display("[FAIL] IFM loader write out of range fy=%0d x=%0d",
                        `TB_DUT_IFM_LOADER.dma_wr_fy, `TB_DUT_IFM_LOADER.dma_wr_x);
                    ifm_loader_fail_count <= ifm_loader_fail_count + 1;
                end else begin
                    for (b = 0; b < IFM_BANKS; b = b + 1) begin
                        ifm_loader_bank_ch = channel_for_bank(current_pass_base_k, b);
                        ifm_loader_expected = (ifm_loader_bank_ch >= 0) ?
                            feat[ifm_loader_bank_ch][`TB_DUT_IFM_LOADER.dma_wr_fy][`TB_DUT_IFM_LOADER.dma_wr_x] :
                            8'd0;
                        if (`TB_DUT_IFM_LOADER.dma_wr_data[b] !== ifm_loader_expected[7:0]) begin
                            $display("[FAIL] IFM loader data fy=%0d x=%0d bank=%0d ch=%0d got=%0d exp=%0d k_base=%0d",
                                `TB_DUT_IFM_LOADER.dma_wr_fy, `TB_DUT_IFM_LOADER.dma_wr_x,
                                b, ifm_loader_bank_ch, `TB_DUT_IFM_LOADER.dma_wr_data[b],
                                ifm_loader_expected[7:0], current_pass_base_k);
                            ifm_loader_fail_count <= ifm_loader_fail_count + 1;
                        end
                    end
                end
            end
        end
    end
`endif

`ifdef TB_CONV_ACCEL_CORE_PROGRESS_PRINT
    task print_progress;
        begin
            $display("[PROGRESS] t=%0t ofm_wr=%0d/%0d delta=%0d axis_tlast=%0d cout=%0d k=%0d feed_k=%0d sched_state=%0d busy=%0d done_pending=%0d prefetch_started=%0d prefetch_w=%0d prefetch_f=%0d prefetch_pass=%0d weight_req=%0d wgt_start=%0d wgt_done=%0d vector_fill=%0d vector_push=%0d fill_req=%0d feeder_done=%0d compute_done=%0d drain_done=%0d compute_fire=%0d delta_fire=%0d psum_wr=%0d vector_valid=%0d vector_ready=%0d vector_done=%0d raw_loaded=%0d raw_replay=%0d raw_pixel=%0d raw_completed_packets=%0d raw_completed_pixels=%0d raw_beats=%0d raw_stalls=%0d final_valid=%0d final_full=%0d rq_valid=%0d rq_full=%0d rq_level=%0d act_valid=%0d act_fifo_valid=%0d act_full=%0d act_level=%0d wb_busy=%0d wb_full=%0d wb_level=%0d ofm_packet_full=%0d ofm_valid=%0d ofm_stream_valid=%0d ofm_stream_ready=%0d ofm_stream_full=%0d ofm_stream_level=%0d",
                $time,
                ofm_mem_wr_count, EXPECTED_OFM_WRITES,
                ofm_mem_wr_count - progress_last_ofm_wr_count,
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
                axis_ofm_tlast_count,
`else
                0,
`endif
                current_cout_base, current_pass_base_k,
                `TB_DUT_LAYER.current_feeder_pass_base_k,
                `TB_DUT_LAYER.u_sched.state, `TB_DUT_LAYER.busy, `TB_DUT_LAYER.done_pending,
                `TB_DUT_LAYER.u_sched.prefetch_started,
                `TB_DUT_LAYER.u_sched.prefetch_weight_done,
                `TB_DUT_LAYER.u_sched.prefetch_feed_done,
                `TB_DUT_LAYER.u_sched.prefetch_pass_base_k,
                `TB_DUT_LAYER.weight_req_r,
                `TB_DUT_LAYER.wgt_loader_start,
                `TB_DUT_LAYER.wgt_loader_done,
                `TB_DUT_LAYER.u_top.vector_fill_req,
                `TB_DUT_LAYER.u_top.vector_push_count,
                feeder_fill_req, `TB_DUT_LAYER.feeder_done, `TB_DUT_LAYER.compute_done,
                `TB_DUT_LAYER.drain_done, compute_fire_count,
                compute_fire_count - progress_last_compute_fire_count,
                psum_wr_count,
                `TB_DUT_LAYER.u_top.vector_ifm_valid,
                `TB_DUT_LAYER.u_top.vector_ifm_ready,
                `TB_DUT_LAYER.u_top.vector_packet_done,
`ifdef TB_CONV_ACCEL_CORE_RAW_HWC_IFM
                dut.u_axis_hwc_tile_cache.tile_loaded,
                dut.u_axis_hwc_tile_cache.replay_active,
                dut.u_axis_hwc_tile_cache.replay_pixel,
                dut.u_axis_hwc_tile_cache.completed_packets,
                dut.u_axis_hwc_tile_cache.completed_pixels,
                dut.u_axis_hwc_tile_cache.accepted_beats,
                dut.u_axis_hwc_tile_cache.fifo_stall_cycles,
`else
                1'b0, 1'b0, 0, 0, 0, 0, 0,
`endif
                `TB_DUT_LAYER.final_fifo_valid, `TB_DUT_LAYER.final_fifo_full,
                `TB_DUT_LAYER.rq_fifo_valid, `TB_DUT_LAYER.rq_fifo_full,
                `TB_DUT_LAYER.u_rq_packet_fifo.level,
                `TB_DUT_LAYER.act_valid, `TB_DUT_LAYER.act_fifo_valid,
                `TB_DUT_LAYER.act_fifo_full, `TB_DUT_LAYER.u_ofm_packet_fifo.level,
                `TB_DUT_LAYER.ofm_wb_busy, `TB_DUT_LAYER.u_ofm_writeback.fifo_full,
                `TB_DUT_LAYER.u_ofm_writeback.wptr - `TB_DUT_LAYER.u_ofm_writeback.rptr,
                ofm_packet_full, `TB_DUT_LAYER.ofm_valid,
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
                dut.ofm_stream_valid, dut.ofm_stream_ready, dut.ofm_stream_full,
                dut.u_ofm_stream_fifo.level
`elsif TB_CONV_ACCEL_CORE_USE_FULL_STREAM
                dut.ofm_m_valid, dut.ofm_m_ready, dut.ofm_stream_full,
                dut.u_ofm_stream_fifo.level
`else
                1'b0, 1'b1, 1'b0, 0
`endif
            );
`ifdef TB_CONV_ACCEL_CORE_PROGRESS_COREDBG
            $display("[COREDBG] t=%0t ctrl_state=%0d w_col=%0d compute_cnt=%0d drain_cnt=%0d compute_ready=%0d compute_active=%0d ctrl_w_load=%0d ctrl_pre_write=%0d ctrl_done=%0d ifm_empty=%h ifm_full=%h ifm_rd_en=%h ifm_rd_valid=%h psum_wr_en=%h psum_empty=%h valid_v_bot=%h wgt_empty=%h",
                $time,
                `TB_DUT_LAYER.u_top.u_core.u_ctrl.state,
                `TB_DUT_LAYER.u_top.u_core.u_ctrl.w_col,
                `TB_DUT_LAYER.u_top.u_core.u_ctrl.compute_cnt,
                `TB_DUT_LAYER.u_top.u_core.u_ctrl.drain_cnt,
                `TB_DUT_LAYER.u_top.u_core.compute_ready,
                `TB_DUT_LAYER.u_top.u_core.compute_active,
                `TB_DUT_LAYER.u_top.u_core.ctrl_w_load,
                `TB_DUT_LAYER.u_top.u_core.ctrl_pre_write,
                `TB_DUT_LAYER.u_top.u_core.done,
                `TB_DUT_LAYER.u_top.u_core.ifm_fifo_empty_active,
                `TB_DUT_LAYER.u_top.u_core.ifm_full_active,
                `TB_DUT_LAYER.u_top.u_core.ifm_fifo_rd_en_active,
                `TB_DUT_LAYER.u_top.u_core.ifm_fifo_rd_valid,
                `TB_DUT_LAYER.u_top.u_core.psum_fifo_wr_en,
                `TB_DUT_LAYER.u_top.u_core.psum_fifo_empty,
                `TB_DUT_LAYER.u_top.u_core.valid_v_bot,
                `TB_DUT_LAYER.u_top.u_core.wgt_fifo_empty
            );
`endif
            progress_last_ofm_wr_count = ofm_mem_wr_count;
            progress_last_compute_fire_count = compute_fire_count;
        end
    endtask

    initial begin
        progress_last_ofm_wr_count = 0;
        progress_last_compute_fire_count = 0;
        forever begin
            repeat (`TB_CONV_ACCEL_CORE_PROGRESS_INTERVAL) @(negedge clk);
            if (!rst)
                print_progress();
            $fflush();
        end
    end
`endif

    initial begin
        clk = 0;
        rst = 1;
        pass = 0;
        fail = 0;
        ofm_mem_wr_count = 0;
        first_extra_ofm_wr_addr = -1;
        first_extra_ofm_wr_data = -1;
        first_extra_ofm_wr_index = -1;
        ifm_write_count = 0;
        compute_fire_count = 0;
        psum_wr_count = 0;
        drain_capture_count = 0;
        ps_tile_start_count = 0;
        ps_done_seen_count = 0;
        ps_done_clear_count = 0;
        tail_cycles_override = `TB_TAIL_CYCLES_OVERRIDE;
        raw_hwc_compute_start_level_override = `TB_RAW_HWC_COMPUTE_START_LEVEL_OVERRIDE;
        early_drain_override = `TB_EARLY_DRAIN_OVERRIDE;
        pass_prefetch_override = `TB_PASS_PREFETCH_OVERRIDE;
        during_compute_prefetch_override = `TB_DURING_COMPUTE_PREFETCH_OVERRIDE;
        psum_stream_overlap_override = `TB_PSUM_STREAM_OVERLAP_OVERRIDE;
        continuous_psum_override = `TB_CONTINUOUS_PSUM_OVERRIDE;
        column_psum_override = `TB_COLUMN_PSUM_OVERRIDE;
        if (tail_cycles_override != 0) begin
            $display("[INFO] tail_cycles override=%0d", tail_cycles_override);
        end
        if (raw_hwc_compute_start_level_override != 0) begin
            $display("[INFO] raw_hwc_compute_start_level override=%0d",
                raw_hwc_compute_start_level_override);
        end
        if (early_drain_override != 0) begin
            $display("[INFO] early_drain override=%0d", early_drain_override);
        end
        if (pass_prefetch_override != 0) begin
            $display("[INFO] pass_prefetch override=%0d", pass_prefetch_override);
        end
        if (during_compute_prefetch_override != 0) begin
            $display("[INFO] during_compute_prefetch override=%0d",
                during_compute_prefetch_override);
        end
        if (psum_stream_overlap_override != 0) begin
            $display("[INFO] psum_stream_overlap override=%0d", psum_stream_overlap_override);
        end
        if (continuous_psum_override != 0) begin
            $display("[INFO] continuous_psum override=%0d", continuous_psum_override);
        end
        if (column_psum_override != 0) begin
            $display("[INFO] column_psum override=%0d", column_psum_override);
        end
        layer_done_pulse_count = 0;
        ps_bias_service_count = 0;
        ps_weight_service_count = 0;
        ps_line_fill_count = 0;
`ifdef TB_CONV_ACCEL_CORE_CHECK_VECTOR_IFM
        vector_check_pixel = 0;
`endif
`ifdef TB_CONV_ACCEL_CORE_BATCH_STREAM
        batch_ifm_tile_end_count = 0;
        batch_ifm_tile_packets = 0;
        batch_first_fy = 0;
        batch_last_fy = 0;
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
        ifm_loader_write_count = 0;
        ifm_loader_advance_count = 0;
        ifm_loader_fail_count = 0;
`ifdef TB_CONV_ACCEL_CORE_OFM_READY_STALL
        ofm_ready_cycle = 0;
        ofm_stall_count = 0;
        ofm_stall_seen = 1'b0;
`endif
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
        axis_ofm_tlast_count = 0;
`endif
`ifdef TB_CONV_ACCEL_CORE_PROGRESS_PRINT
        progress_last_ofm_wr_count = 0;
        progress_last_compute_fire_count = 0;
`endif
`ifdef TB_CONV_ACCEL_CORE_CHECK_FEEDER_IFM
        feeder_ifm_fail_count = 0;
        diag_loader_write_count = 0;
        diag_loader_fail_count = 0;
`endif
        clear_inputs();
        for (idx = 0; idx < OFM_WORDS; idx = idx + 1) begin
            ofm_mem[idx] = 8'hxx;
            final_raw_mem[idx] = {PSUM_W{1'bx}};
            final_raw_valid[idx] = 1'b0;
        end

`ifdef TB_CONV_ACCEL_CORE_USE_EXTERNAL_GOLDEN
        $display("[INFO] loading external IFM/weight/bias/LUT/golden memories");
        $fflush();
        $readmemh(`TB_CONV_ACCEL_CORE_IFM_MEM, ext_ifm);
        $display("[INFO] loaded IFM memory");
        $fflush();
        $readmemh(`TB_CONV_ACCEL_CORE_WEIGHT_MEM, ext_weight);
        $display("[INFO] loaded weight memory");
        $fflush();
        $readmemh(`TB_CONV_ACCEL_CORE_BIAS_MEM, ext_bias);
        $readmemh(`TB_CONV_ACCEL_CORE_ACT_LUT_MEM, ext_act_lut);
        $readmemh(`TB_CONV_ACCEL_CORE_GOLDEN_MEM, ext_golden);
        $display("[INFO] loaded bias/LUT/golden memories");
        $fflush();

`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
        $display("[EARLY] t=%0t unpack external IFM start CIN=%0d FM=%0dx%0d",
            $time, CIN, FM_H, FM_W);
        $fflush();
`endif
        for (ch = 0; ch < CIN; ch = ch + 1)
            for (y = 0; y < FM_H; y = y + 1)
                for (x = 0; x < FM_W; x = x + 1)
`ifdef TB_CONV_ACCEL_CORE_CENTER_EXTERNAL_IFM
                    feat[ch][y][x] = center_ifm_byte_tb(ext_ifm[(y*FM_W + x)*CIN + ch], INPUT_ZERO_POINT);
`else
                    feat[ch][y][x] = ext_ifm[(y*FM_W + x)*CIN + ch];
`endif

`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
        $display("[EARLY] t=%0t unpack external IFM done; unpack weight start K_TOTAL=%0d COUT_TOTAL=%0d",
            $time, K_TOTAL, COUT_TOTAL);
        $fflush();
`endif
        for (k = 0; k < K_TOTAL; k = k + 1) begin
`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
            if ((k % 256) == 0) begin
                $display("[EARLY] t=%0t unpack weight k=%0d/%0d", $time, k, K_TOTAL);
                $fflush();
            end
`endif
            for (co = 0; co < COUT_TOTAL; co = co + 1)
                weight[k][co] = ext_weight[k*COUT_TOTAL + co];
        end

        for (co = 0; co < COUT_TOTAL; co = co + 1)
            bias[co] = ext_bias[co];
`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
        $display("[EARLY] t=%0t unpack weight/bias done", $time);
        $fflush();
`endif
`else
        for (ch = 0; ch < CIN; ch = ch + 1)
            for (y = 0; y < FM_H; y = y + 1)
                for (x = 0; x < FM_W; x = x + 1)
                    feat[ch][y][x] = ((ch * 3 + y * 5 + x * 2) % 9) - 4;

        for (k = 0; k < K_TOTAL; k = k + 1)
            for (co = 0; co < COUT_TOTAL; co = co + 1)
                weight[k][co] = ((k * 2 + co * 3) % 7) - 3;

        for (co = 0; co < COUT_TOTAL; co = co + 1) begin
            bias[co] = co - 9;
            for (idx = 0; idx < FULL_PIXELS; idx = idx + 1) begin
                y = idx / OFM_W;
                x = idx % OFM_W;
                golden[idx][co] = bias[co];
                for (k = 0; k < K_TOTAL; k = k + 1) begin
`ifdef TB_CONV_ACCEL_CORE_KERNEL_1X1
                    ch = k;
                    fy = y;
                    fx = x;
`else
                    ch = k / 9;
                    ker = k % 9;
                    ky = ker / 3;
                    kx = ker % 3;
                    fy = y * CONV_STRIDE + ky - CONV_PAD;
                    fx = x * CONV_STRIDE + kx - CONV_PAD;
`endif
                    if (fy >= 0 && fy < FM_H && fx >= 0 && fx < FM_W)
                        golden[idx][co] = golden[idx][co] + feat[ch][fy][fx] * weight[k][co];
                end
            end
        end
`endif

        repeat (3) @(negedge clk);
`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
        $display("[EARLY] t=%0t release reset", $time);
        $fflush();
`endif
        rst = 0;
        repeat (2) @(negedge clk);
`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
        $display("[EARLY] t=%0t write quant params start COUT_TILE=%0d", $time, COUT_TILE);
        $fflush();
`endif
        for (cc = 0; cc < COUT_TILE; cc = cc + 1)
            quant_write(cc, `TB_CONV_ACCEL_CORE_QUANT_MULT,
                            `TB_CONV_ACCEL_CORE_QUANT_SHIFT,
                            `TB_CONV_ACCEL_CORE_QUANT_ZP);
`ifdef TB_CONV_ACCEL_CORE_USE_EXTERNAL_GOLDEN
`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
        $display("[EARLY] t=%0t write activation LUT start", $time);
        $fflush();
`endif
        for (idx = 0; idx < 256; idx = idx + 1)
            act_lut_write(idx[7:0], ext_act_lut[idx]);
`endif

`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
        $display("[EARLY] t=%0t write layer config start", $time);
        $fflush();
`endif
        cfg_write(6'h01, {7'd0, FM_W[8:0], 7'd0, FM_H[8:0]});
        cfg_write(6'h02, {7'd0, OFM_W[8:0], 7'd0, OFM_H[8:0]});
        cfg_write(
            6'h03,
            {15'd0, (KERNEL_1X1 != 0),
             6'd0, CONV_PAD, 6'd0, CONV_STRIDE});
        cfg_write(6'h04, K_TOTAL);
        cfg_write(6'h05, COUT_TOTAL);
        cfg_write(6'h07, `TB_CONV_ACCEL_CORE_ACT_MODE);
        cfg_write(6'h0f, {24'd0, INPUT_ZERO_POINT});
        cfg_write(6'h10, {28'd0, POOL_STRIDE, 1'b0, (POOL_ENABLE != 0)});
        cfg_write(6'h11, EXPECTED_OFM_WRITES);
        if (tail_cycles_override != 0 || raw_hwc_compute_start_level_override != 0)
            cfg_write(6'h38, {raw_hwc_compute_start_level_override[15:0],
                              tail_cycles_override[15:0]});
`ifdef TB_CONV_ACCEL_CORE_EARLY_PRINT
        $display("[EARLY] t=%0t layer config done; run tiles start TILE_COUNT=%0d EXPECTED_OFM_WRITES=%0d",
            $time, TILE_COUNT, EXPECTED_OFM_WRITES);
        $fflush();
`endif
        for (run_idx = 0; run_idx < TILE_COUNT; run_idx = run_idx + 1)
            run_tile(run_idx);
`ifdef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
        while (ofm_mem_wr_count < EXPECTED_OFM_WRITES)
            @(negedge clk);
`endif

        if (ofm_mem_wr_count != EXPECTED_OFM_WRITES) begin
            $display("[FAIL] ofm writes got=%0d exp=%0d", ofm_mem_wr_count, EXPECTED_OFM_WRITES);
            if (first_extra_ofm_wr_index >= 0)
                $display("[INFO] first extra OFM write index=%0d addr=%0d data=%0d",
                    first_extra_ofm_wr_index, first_extra_ofm_wr_addr, first_extra_ofm_wr_data);
            fail = fail + 1;
        end else pass = pass + 1;
`ifdef TB_CONV_ACCEL_CORE_RAW_HWC_IFM
        expected_raw_hwc_bytes = 0;
        for (run_idx = 0; run_idx < TILE_COUNT; run_idx = run_idx + 1) begin
            get_tile_cfg(run_idx, run_oy_base, run_ofm_h, run_pixel_base);
            expected_raw_hwc_bytes = expected_raw_hwc_bytes +
                (raw_hwc_last_y_tb(run_oy_base, run_ofm_h) -
                 raw_hwc_first_y_tb(run_oy_base) + 1) * FM_W * CIN;
        end
        expected_raw_hwc_beats = (expected_raw_hwc_bytes + 7) / 8;
        expected_raw_hwc_replay_packets = RUN_PIXELS * K_PASSES * COUT_BLOCKS;
        if (dut.u_axis_hwc_tile_cache.completed_packets != TILE_COUNT) begin
            $display("[FAIL] raw HWC packets got=%0d exp=%0d",
                dut.u_axis_hwc_tile_cache.completed_packets, TILE_COUNT);
            fail = fail + 1;
        end else pass = pass + 1;
        if (dut.u_axis_hwc_tile_cache.accepted_beats != expected_raw_hwc_beats) begin
            $display("[FAIL] raw HWC beats got=%0d exp=%0d bytes=%0d",
                dut.u_axis_hwc_tile_cache.accepted_beats, expected_raw_hwc_beats,
                expected_raw_hwc_bytes);
            fail = fail + 1;
        end else pass = pass + 1;
        if (dut.u_axis_hwc_tile_cache.completed_pixels != expected_raw_hwc_replay_packets) begin
            $display("[FAIL] raw HWC replay packets got=%0d exp=%0d",
                dut.u_axis_hwc_tile_cache.completed_pixels, expected_raw_hwc_replay_packets);
            fail = fail + 1;
        end else pass = pass + 1;
`else
        if (ifm_write_count != RUN_PIXELS * K_PASSES * COUT_BLOCKS) begin
            $display("[FAIL] ifm writes got=%0d exp=%0d", ifm_write_count, RUN_PIXELS * K_PASSES * COUT_BLOCKS);
            fail = fail + 1;
        end else pass = pass + 1;
`endif
        if (compute_fire_count != RUN_PIXELS * K_PASSES * COUT_BLOCKS) begin
            $display("[FAIL] compute fires got=%0d exp=%0d", compute_fire_count, RUN_PIXELS * K_PASSES * COUT_BLOCKS);
            fail = fail + 1;
        end else pass = pass + 1;
        if (psum_wr_count != RUN_PIXELS * K_PASSES * COUT_BLOCKS) begin
            $display("[FAIL] psum writes got=%0d exp=%0d", psum_wr_count, RUN_PIXELS * K_PASSES * COUT_BLOCKS);
            fail = fail + 1;
        end else pass = pass + 1;
        if (COUT_TOTAL <= COUT_TILE && current_cout_base !== 11'd0) begin
            $display("[FAIL] unexpected Cout block advance, cout_base=%0d", current_cout_base);
            fail = fail + 1;
        end else pass = pass + 1;
        if (ps_tile_start_count != TILE_COUNT) begin
            $display("[FAIL] PS tile starts got=%0d exp=%0d", ps_tile_start_count, TILE_COUNT);
            fail = fail + 1;
        end else pass = pass + 1;
        if (ps_done_seen_count != TILE_COUNT) begin
            $display("[FAIL] PS done seen got=%0d exp=%0d", ps_done_seen_count, TILE_COUNT);
            fail = fail + 1;
        end else pass = pass + 1;
        if (ps_done_clear_count != TILE_COUNT) begin
            $display("[FAIL] PS done clear got=%0d exp=%0d", ps_done_clear_count, TILE_COUNT);
            fail = fail + 1;
        end else pass = pass + 1;
        if (ps_bias_service_count != TILE_COUNT * COUT_BLOCKS) begin
            $display("[FAIL] PS bias services got=%0d exp=%0d", ps_bias_service_count, TILE_COUNT * COUT_BLOCKS);
            fail = fail + 1;
        end else pass = pass + 1;
        if (ps_weight_service_count != TILE_COUNT * COUT_BLOCKS * K_PASSES) begin
            $display("[FAIL] PS weight services got=%0d exp=%0d", ps_weight_service_count, TILE_COUNT * COUT_BLOCKS * K_PASSES);
            fail = fail + 1;
        end else pass = pass + 1;
        if (ps_line_fill_count <= 0) begin
            $display("[FAIL] PS line fill service count should be non-zero");
            fail = fail + 1;
        end else pass = pass + 1;
`ifdef TB_CONV_ACCEL_CORE_OFM_READY_STALL
        if (!ofm_stall_seen) begin
            $display("[FAIL] OFM ready stall was not exercised");
            fail = fail + 1;
        end else pass = pass + 1;
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
        if (ifm_loader_fail_count != 0) begin
            $display("[FAIL] IFM stream loader write mismatches=%0d", ifm_loader_fail_count);
            fail = fail + 1;
        end else pass = pass + 1;
        if (ifm_loader_write_count <= 0 || ifm_loader_advance_count <= 0) begin
            $display("[FAIL] IFM stream loader did not write rows writes=%0d advances=%0d",
                ifm_loader_write_count, ifm_loader_advance_count);
            fail = fail + 1;
        end else pass = pass + 1;
`endif
`ifdef TB_CONV_ACCEL_CORE_CHECK_FEEDER_IFM
        if (diag_loader_fail_count != 0) begin
            $display("[FAIL] diagnostic IFM loader mismatches=%0d writes=%0d",
                diag_loader_fail_count, diag_loader_write_count);
            fail = fail + 1;
        end else begin
            $display("[PASS] diagnostic IFM loader writes match expected rows writes=%0d",
                diag_loader_write_count);
            pass = pass + 1;
        end
        if (feeder_ifm_fail_count != 0) begin
            $display("[FAIL] feeder IFM mismatches=%0d", feeder_ifm_fail_count);
            fail = fail + 1;
        end else begin
            $display("[PASS] feeder IFM stream matches expected windows");
            pass = pass + 1;
        end
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_AXIS_STREAM
        if (axis_ofm_tlast_count != TILE_COUNT) begin
            $display("[FAIL] AXIS OFM TLAST count got=%0d exp=%0d",
                axis_ofm_tlast_count, TILE_COUNT);
            fail = fail + 1;
        end else pass = pass + 1;
        cfg_read(6'h0b, cfg_read_data);
        if (cfg_read_data != EXPECTED_OFM_WRITES) begin
            $display("[FAIL] AXIS debug core write count got=%0d exp=%0d",
                cfg_read_data, EXPECTED_OFM_WRITES);
            fail = fail + 1;
        end else pass = pass + 1;
        cfg_read(6'h0c, cfg_read_data);
        if (cfg_read_data != EXPECTED_OFM_WRITES) begin
            $display("[FAIL] AXIS debug sink write count got=%0d exp=%0d",
                cfg_read_data, EXPECTED_OFM_WRITES);
            fail = fail + 1;
        end else pass = pass + 1;
        cfg_read(6'h0d, cfg_read_data);
        if (cfg_read_data != TILE_COUNT) begin
            $display("[FAIL] AXIS debug TLAST count got=%0d exp=%0d",
                cfg_read_data, TILE_COUNT);
            fail = fail + 1;
        end else pass = pass + 1;
        cfg_read(6'h0e, cfg_read_data);
        if (cfg_read_data != EXPECTED_OFM_WRITES) begin
            $display("[FAIL] AXIS debug last TLAST index got=%0d exp=%0d",
                cfg_read_data, EXPECTED_OFM_WRITES);
            fail = fail + 1;
        end else pass = pass + 1;
        if (bias_axis_error || weight_axis_error || ifm_axis_error) begin
            $display("[FAIL] AXIS protocol errors bias=%0d weight=%0d ifm=%0d",
                bias_axis_error, weight_axis_error, ifm_axis_error);
            fail = fail + 1;
        end else pass = pass + 1;
`endif

        for (run_idx = 0; run_idx < TILE_COUNT; run_idx = run_idx + 1) begin
            get_tile_cfg(run_idx, run_oy_base, run_ofm_h, run_pixel_base);
            run_pixels = POOL_ACTIVE ? (OUT_W * (run_ofm_h / 2)) : (OFM_W * run_ofm_h);
            for (idx = 0; idx < run_pixels; idx = idx + 1) begin
                for (co = 0; co < COUT_TOTAL; co = co + 1) begin
`ifdef TB_CONV_ACCEL_CORE_USE_EXTERNAL_GOLDEN
                    expected_ofm_byte = ext_golden[(run_pixel_base + idx)*GOLDEN_COUT_STRIDE + co];
                    if (ofm_mem[(run_pixel_base + idx)*COUT_TOTAL + co] !== expected_ofm_byte) begin
                        if (fail < 20)
                            $display("[FAIL] tile%0d pixel%0d global%0d cout%0d addr%0d got=%0d exp=%0d raw_got=%0d raw_valid=%0d",
                                run_idx, idx, run_pixel_base + idx, co,
                                (run_pixel_base + idx)*COUT_TOTAL + co,
                                ofm_mem[(run_pixel_base + idx)*COUT_TOTAL + co],
                                expected_ofm_byte,
                                final_raw_mem[(run_pixel_base + idx)*COUT_TOTAL + co],
                                final_raw_valid[(run_pixel_base + idx)*COUT_TOTAL + co]);
                        fail = fail + 1;
                    end else pass = pass + 1;
`else
                    if (POOL_ACTIVE) begin
                        y = idx / OUT_W;
                        x = idx % OUT_W;
                        expected_pool_byte = max4_u8(
                            requant_byte_tb(golden[(run_oy_base + y*2) * OFM_W + x*2][co]),
                            requant_byte_tb(golden[(run_oy_base + y*2) * OFM_W + x*2 + 1][co]),
                            requant_byte_tb(golden[(run_oy_base + y*2 + 1) * OFM_W + x*2][co]),
                            requant_byte_tb(golden[(run_oy_base + y*2 + 1) * OFM_W + x*2 + 1][co])
                        );
                        expected_det_byte = expected_pool_byte;
                    end else begin
                        expected_det_byte = requant_byte_tb(golden[run_pixel_base + idx][co]);
                    end
                    if (ofm_mem[(run_pixel_base + idx)*COUT_TOTAL + co] !== expected_det_byte) begin
                        $display("[FAIL] tile%0d pixel%0d global%0d cout%0d got=%0d exp=%0d raw_got=%0d raw_exp=%0d raw_valid=%0d",
                            run_idx, idx, run_pixel_base + idx, co,
                            ofm_mem[(run_pixel_base + idx)*COUT_TOTAL + co],
                            expected_det_byte,
                            final_raw_mem[(run_pixel_base + idx)*COUT_TOTAL + co],
                            golden[run_pixel_base + idx][co],
                            final_raw_valid[(run_pixel_base + idx)*COUT_TOTAL + co]);
                        fail = fail + 1;
                    end else pass = pass + 1;
`endif
                end
            end
        end

        $display("=== %m: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (`TB_CONV_ACCEL_CORE_TIMEOUT) @(negedge clk);
        $display("[FAIL] timeout status=%b cfg_done_sticky=%0d layer_done_pulses=%0d axi_arv=%0d axi_arr=%0d axi_rv=%0d axi_rr=%0d axi_rd_state=%0d bw_bias_busy=%0d bw_bias_count=%0d bw_bias_done=%0d bw_wgt_busy=%0d bw_wgt_count=%0d bw_wgt_done=%0d ifm_busy=%0d ifm_cool=%0d ifm_x=%0d ifm_adv=%0d line_state=%0d line_oy=%0d lvalid=%b%b%b lfy=%0d,%0d,%0d lbvalid=%b%b%b lbfy=%0d,%0d,%0d win_active=%0d win_oy=%0d win_ox=%0d win_ready=%0d row_done=%0d ofm_wr=%0d cout=%0d k=%0d fill_req=%0d sched_state=%0d feeder_done=%0d compute_done=%0d drain_done=%0d done_pending=%0d done_cnt=%0d ofm_wb_busy=%0d ofm_valid=%0d act_valid=%0d ifm_full=%h psum_empty=%h fire=%0d ifm_wr=%0d fire_cnt=%0d psum_wr=%0d ps_start=%0d ps_done=%0d ps_clear=%0d",
            cfg_read_data[1:0], `TB_DUT_CFG.done_sticky, layer_done_pulse_count,
`ifdef TB_CONV_ACCEL_CORE_USE_AXI_LITE
            axi_arvalid, axi_arready, axi_rvalid, axi_rready, `TB_DUT_AXI_CFG.rd_state,
`else
            1'b0, 1'b0, 1'b0, 1'b0, 1'b0,
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_BW_STREAM
            `TB_DUT_BW_LOADER.bias_busy, `TB_DUT_BW_LOADER.bias_count, `TB_DUT_BW_LOADER.bias_load_done,
            `TB_DUT_BW_LOADER.weight_busy, `TB_DUT_BW_LOADER.weight_count, `TB_DUT_BW_LOADER.weight_tile_ready,
`else
            1'b0, 32'd0, 1'b0, 1'b0, 32'd0, 1'b0,
`endif
`ifdef TB_CONV_ACCEL_CORE_USE_FULL_STREAM
            `TB_DUT_IFM_LOADER.busy, `TB_DUT_IFM_LOADER.cooldown, `TB_DUT_IFM_LOADER.x_count,
            `TB_DUT_IFM_LOADER.dma_line_advance,
`else
            1'b0, 1'b0, 32'd0, 1'b0,
`endif
            `TB_DUT_LAYER.u_top.u_feeder.u_line_ctrl.state, `TB_DUT_LAYER.u_top.u_feeder.u_line_ctrl.oy,
            `TB_DUT_LAYER.u_top.u_feeder.u_line_ctrl.line_valid[0],
            `TB_DUT_LAYER.u_top.u_feeder.u_line_ctrl.line_valid[1],
            `TB_DUT_LAYER.u_top.u_feeder.u_line_ctrl.line_valid[2],
            `TB_DUT_LAYER.u_top.u_feeder.u_line_ctrl.line_fy[0],
            `TB_DUT_LAYER.u_top.u_feeder.u_line_ctrl.line_fy[1],
            `TB_DUT_LAYER.u_top.u_feeder.u_line_ctrl.line_fy[2],
            `TB_DUT_LAYER.u_top.u_feeder.line_valid[0],
            `TB_DUT_LAYER.u_top.u_feeder.line_valid[1],
            `TB_DUT_LAYER.u_top.u_feeder.line_valid[2],
            `TB_DUT_LAYER.u_top.u_feeder.line_fy[0],
            `TB_DUT_LAYER.u_top.u_feeder.line_fy[1],
            `TB_DUT_LAYER.u_top.u_feeder.line_fy[2],
            `TB_DUT_LAYER.u_top.u_feeder.u_window_ctrl.active, `TB_DUT_LAYER.u_top.u_feeder.cur_oy,
            `TB_DUT_LAYER.u_top.u_feeder.cur_ox, `TB_DUT_LAYER.u_top.u_feeder.window_ready,
            `TB_DUT_LAYER.u_top.u_feeder.row_done,
            ofm_mem_wr_count, current_cout_base, current_pass_base_k, feeder_fill_req,
            `TB_DUT_LAYER.u_sched.state, `TB_DUT_LAYER.feeder_done, `TB_DUT_LAYER.compute_done,
            `TB_DUT_LAYER.drain_done, `TB_DUT_LAYER.done_pending, `TB_DUT_LAYER.done_drain_cnt,
            `TB_DUT_LAYER.ofm_wb_busy, `TB_DUT_LAYER.ofm_valid, `TB_DUT_LAYER.act_valid,
            `TB_DUT_LAYER.ifm_fifo_full, `TB_DUT_LAYER.psum_fifo_empty,
            `TB_DUT_LAYER.compute_fire, ifm_write_count, compute_fire_count, psum_wr_count,
            ps_tile_start_count, ps_done_seen_count, ps_done_clear_count);
        $fatal(1);
    end
endmodule

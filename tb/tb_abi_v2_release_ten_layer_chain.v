`timescale 1ns / 1ps

// The dedicated XSIM launcher creates this file in its isolated run
// directory.  Compile-time settings avoid the Vivado 2022.2 Windows xsim
// command-line parser bug which rejects -testplusarg values containing '='.
`include "abi_v2_chain_run_config.vh"

`ifndef TB_ABI_V2_FIXTURE_ROOT
`define TB_ABI_V2_FIXTURE_ROOT "build_xsim/fixtures"
`endif
`ifndef TB_ABI_V2_START_LAYER
`define TB_ABI_V2_START_LAYER 0
`endif
`ifndef TB_ABI_V2_STOP_LAYER
`define TB_ABI_V2_STOP_LAYER 9
`endif
`ifndef TB_ABI_V2_STREAM_CFG
`define TB_ABI_V2_STREAM_CFG 8'hbf
`endif
`ifndef TB_ABI_V2_TRACE_PIXEL0
`define TB_ABI_V2_TRACE_PIXEL0 0
`endif

// Full ABI-v2 release-chain gate.
//
// One exact 18x16/COUT32 RTL instance executes Conv0..Conv9 in order.  The
// packed HWC bytes produced by layer N are copied into chain_ifm and are the
// only bytes sent to layer N+1.  The repository fixture for layer N+1 is read
// into a separate reference array and compared before that transfer starts.
// Consequently a model/cycle estimate cannot satisfy this test: every layer
// must run through the real materializer, scheduler, tagged mesh, PSUM path,
// requant/activation/pool path and packed OFM writer.
module tb_abi_v2_release_ten_layer_chain;
    localparam integer ROWS = 18;
    localparam integer COLS = 16;
    localparam integer COUT_TILE = 32;
    localparam integer MAX_IFM_BYTES = 692224;
    localparam integer MAX_OFM_BYTES = 692224;
    localparam integer MAX_WEIGHT_BYTES = 4718592;
    localparam integer MAX_COUT = 1024;

    localparam integer EXPECTED_TOTAL_CONTEXTS = 29253;
    localparam integer EXPECTED_TOTAL_COMPUTE_FIRE = 3889197;
    localparam integer EXPECTED_TOTAL_IFM_BYTES = 2249728;
    localparam integer EXPECTED_TOTAL_OFM_BYTES = 1734616;
    localparam integer EXPECTED_TOTAL_OFM_BEATS = 216827;
    localparam integer EXPECTED_TOTAL_BIAS_PACKETS = 483;
    localparam integer EXPECTED_TOTAL_WEIGHT_PACKETS = 29253;
    localparam integer EXPECTED_TOTAL_BIAS_BYTES = 61824;
    localparam integer EXPECTED_TOTAL_WEIGHT_BYTES = 16849728;
    localparam [7:0] RELEASE_STREAM_CFG = `TB_ABI_V2_STREAM_CFG;
    localparam integer TRACE_PIXEL0 = `TB_ABI_V2_TRACE_PIXEL0;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg  [9:0]  axi_awaddr = 10'd0;
    reg         axi_awvalid = 1'b0;
    wire        axi_awready;
    reg  [31:0] axi_wdata = 32'd0;
    reg  [3:0]  axi_wstrb = 4'd0;
    reg         axi_wvalid = 1'b0;
    wire        axi_wready;
    wire [1:0]  axi_bresp;
    wire        axi_bvalid;
    reg         axi_bready = 1'b0;
    reg  [9:0]  axi_araddr = 10'd0;
    reg         axi_arvalid = 1'b0;
    wire        axi_arready;
    wire [31:0] axi_rdata;
    wire [1:0]  axi_rresp;
    wire        axi_rvalid;
    reg         axi_rready = 1'b0;

    wire        bias_load_req;
    wire        weight_load_req;
    wire [10:0] current_cout_base;
    wire [13:0] current_pass_base_k;
    wire        bias_tready;
    reg         bias_tvalid = 1'b0;
    reg  [63:0] bias_tdata = 64'd0;
    reg  [7:0]  bias_tkeep = 8'd0;
    reg         bias_tlast = 1'b0;
    wire        weight_tready;
    reg         weight_tvalid = 1'b0;
    reg  [63:0] weight_tdata = 64'd0;
    reg  [7:0]  weight_tkeep = 8'd0;
    reg         weight_tlast = 1'b0;
    wire        ifm_tready;
    reg         ifm_tvalid = 1'b0;
    reg  [63:0] ifm_tdata = 64'd0;
    reg  [7:0]  ifm_tkeep = 8'd0;
    reg         ifm_tlast = 1'b0;
    wire [63:0] ofm_tdata;
    wire [7:0]  ofm_tkeep;
    wire        ofm_tvalid;
    reg         ofm_tready = 1'b1;
    wire        ofm_tlast;
    wire bias_axis_error;
    wire weight_axis_error;
    wire ifm_axis_error;
    wire ofm_axis_error;

    reg [7:0] chain_ifm [0:MAX_IFM_BYTES-1];
    reg [7:0] fixture_ifm [0:MAX_IFM_BYTES-1];
    reg [7:0] layer_ofm [0:MAX_OFM_BYTES-1];
    reg [7:0] golden_ofm [0:MAX_OFM_BYTES-1];
    reg [7:0] weight_mem [0:MAX_WEIGHT_BYTES-1];
    reg [31:0] bias_mem [0:MAX_COUT-1];
    reg [7:0] act_lut_mem [0:255];

    string fixture_root = `TB_ABI_V2_FIXTURE_ROOT;
    string layer_name;
    string fixture_path;
    integer start_layer = `TB_ABI_V2_START_LAYER;
    integer stop_layer = `TB_ABI_V2_STOP_LAYER;
    integer layer_index;
    integer cfg_fm_h;
    integer cfg_fm_w;
    integer cfg_cin;
    integer cfg_cout;
    integer cfg_kernel;
    integer cfg_stride;
    integer cfg_pad;
    integer cfg_pool_enable;
    integer cfg_pool_stride;
    integer cfg_k_total;
    integer cfg_k_passes;
    integer cfg_cout_blocks;
    integer cfg_tile_h;
    integer cfg_tile_count;
    integer cfg_tile_pixels;
    integer cfg_ifm_bytes;
    integer cfg_ofm_bytes;
    integer cfg_ofm_beats;
    integer cfg_bias_packets;
    integer cfg_weight_packets;
    integer cfg_quant_mult;
    integer cfg_quant_shift;
    integer cfg_quant_zp;
    integer cfg_input_zp;
    integer cfg_expected_contexts;
    integer cfg_expected_compute_fire;

    integer checks = 0;
    integer failures = 0;
    integer cycle_count = 0;
    integer layer_start_cycle = 0;
    integer layer_ofm_bytes = 0;
    integer layer_ofm_beats = 0;
    integer layer_tlast_count = 0;
    integer layer_output_protocol_failures = 0;
    integer bias_service_count = 0;
    integer weight_service_count = 0;
    integer trace_fire_in_context = 0;
    integer trace_no_compute_cycles = 0;
    reg trace_stall_dumped = 1'b0;
    reg run_active = 1'b0;

    reg [63:0] total_busy = 64'd0;
    reg [63:0] total_feeder = 64'd0;
    reg [63:0] total_context_psum_gap = 64'd0;
    reg [63:0] total_drain_ofm = 64'd0;
    reg [63:0] total_bias_weight = 64'd0;
    reg [63:0] total_unclassified = 64'd0;
    reg [63:0] total_compute_fire = 64'd0;
    reg [63:0] total_contexts = 64'd0;
    reg [63:0] total_ifm_bytes = 64'd0;
    reg [63:0] total_ofm_bytes = 64'd0;
    reg [63:0] total_ofm_beats = 64'd0;
    reg [63:0] total_bias_packets = 64'd0;
    reg [63:0] total_weight_packets = 64'd0;

    reg [31:0] rd_value;
    reg [31:0] ctx_before_alloc;
    reg [31:0] ctx_before_issued;
    reg [31:0] ctx_before_retired;
    reg [31:0] ctx_before_collected;
    reg [31:0] weight_credit_before;
    reg [31:0] weight_commit_before;
    reg [31:0] ctx_after_alloc;
    reg [31:0] ctx_after_issued;
    reg [31:0] ctx_after_retired;
    reg [31:0] ctx_after_collected;
    reg [31:0] layer_busy_cycles;
    reg [31:0] layer_feeder_cycles;
    reg [31:0] layer_context_gap_cycles;
    reg [31:0] layer_psum_credit_cycles;
    reg [31:0] layer_drain_cycles;
    reg [31:0] layer_ofm_post_cycles;
    reg [31:0] layer_bias_cycles;
    reg [31:0] layer_weight_cycles;
    reg [31:0] layer_unclassified_cycles;
    reg [31:0] layer_compute_fire;

    // A spatial-tile start is allowed to reset only a fully drained staging
    // engine.  Likewise, a formatter completion must never outrun the
    // preloader credit interface.  Keep these contracts explicit in the
    // release-chain gate so a future scheduler change fails immediately.
    always @(posedge clk) begin
        if (!rst && !dut.u_core.u_core.datapath_rst &&
            dut.u_core.u_core.u_layer.start) begin
            if ((dut.u_core.u_core.u_layer.weight_req_r !== 1'b0) ||
                (dut.u_core.u_core.u_layer.weight_format_pending_q !== 1'b0) ||
                (dut.u_core.u_core.u_layer.g_weight_tile_pingpong.u_weight_loader.committed_count_q !== 0) ||
                (dut.u_core.u_core.u_layer.g_weight_tile_pingpong.u_weight_loader.occupied_q !== 0) ||
                (dut.u_core.u_core.u_layer.g_weight_tile_pingpong.u_weight_loader.format_busy_q !== 1'b0)) begin
                $display("[FAIL] non-quiescent weight staging at spatial-tile start");
                $fatal(1);
            end
        end
        if (!rst && !dut.u_core.u_core.datapath_rst &&
            dut.u_core.u_core.u_layer.wgt_loader_done &&
            (dut.u_core.u_core.u_layer.weight_tile_complete_ready !== 1'b1)) begin
            $display("[FAIL] weight formatter completion was not captured by completion skid");
            $fatal(1);
        end
    end

    conv_accel_core_axi_lite_axis_stream #(
        .ROWS(ROWS), .COLS(COLS), .K_TILE(ROWS),
        .COUT_TILE(COUT_TILE), .IFM_BANKS(2),
        .IFM_FIFO_DEPTH(1024), .IFM_FIFO_AW(10),
        .WGT_FIFO_DEPTH(64), .WGT_FIFO_AW(6),
        .PSUM_FIFO_DEPTH(256), .PSUM_FIFO_AW(8),
        .FM_W_MAX(416), .FM_H_MAX(416),
        .WGT_TILE_AW(11),
        .PSUM_BUF_AW(10), .PSUM_BUF_DEPTH(1024),
        .OFM_ADDR_W(24),
        .OFM_FIFO_DEPTH(32), .OFM_FIFO_AW(5),
        .HWC_CACHE_AW(16), .HWC_CACHE_DEPTH(43264),
        .HWC_CACHE_STRIPES(4), .HWC_CACHE_USE_URAM(1),
        .MATERIALIZED_CACHE_AW(15),
        .MATERIALIZED_CACHE_DEPTH(32768),
        .ENABLE_COLUMN_PSUM(0),
        .ENABLE_PACKED_HWC_OFM(1),
        .ENABLE_LAYER_TILE_SEQUENCER(1),
        .ENABLE_LAYER_LONG_HWC_IFM(1),
        .ENABLE_TAGGED_CONTEXT(1),
        .ENABLE_WEIGHT_PRELOAD(1),
        .ENABLE_FAST_CONTEXT_HANDOFF(1),
        .IFM_EPOCH_USE_URAM(1),
        .ENABLE_DETAILED_TRACE(0),
        .TAIL_CYCLES_CONFIG(1),
        .PACKED_OFM_MAX_PIXELS(1024),
        .PACKED_OFM_MAX_COUT(1024),
        .PACKED_OFM_BUFFER_DEPTH(4096)
    ) dut (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(axi_awaddr), .s_axi_awvalid(axi_awvalid),
        .s_axi_awready(axi_awready),
        .s_axi_wdata(axi_wdata), .s_axi_wstrb(axi_wstrb),
        .s_axi_wvalid(axi_wvalid), .s_axi_wready(axi_wready),
        .s_axi_bresp(axi_bresp), .s_axi_bvalid(axi_bvalid),
        .s_axi_bready(axi_bready),
        .s_axi_araddr(axi_araddr), .s_axi_arvalid(axi_arvalid),
        .s_axi_arready(axi_arready), .s_axi_rdata(axi_rdata),
        .s_axi_rresp(axi_rresp), .s_axi_rvalid(axi_rvalid),
        .s_axi_rready(axi_rready),
        .bias_load_req(bias_load_req),
        .weight_load_req(weight_load_req),
        .current_cout_base(current_cout_base),
        .current_pass_base_k(current_pass_base_k),
        .bias_s_axis_tready(bias_tready),
        .bias_s_axis_tvalid(bias_tvalid),
        .bias_s_axis_tdata(bias_tdata),
        .bias_s_axis_tkeep(bias_tkeep),
        .bias_s_axis_tlast(bias_tlast),
        .weight_s_axis_tready(weight_tready),
        .weight_s_axis_tvalid(weight_tvalid),
        .weight_s_axis_tdata(weight_tdata),
        .weight_s_axis_tkeep(weight_tkeep),
        .weight_s_axis_tlast(weight_tlast),
        // ABI-v2 release ignores the legacy line-word sideband.
        .ifm_line_words(9'd0),
        .ifm_s_axis_tready(ifm_tready),
        .ifm_s_axis_tvalid(ifm_tvalid),
        .ifm_s_axis_tdata(ifm_tdata),
        .ifm_s_axis_tkeep(ifm_tkeep),
        .ifm_s_axis_tlast(ifm_tlast),
        .ofm_m_axis_tdata(ofm_tdata),
        .ofm_m_axis_tkeep(ofm_tkeep),
        .ofm_m_axis_tvalid(ofm_tvalid),
        .ofm_m_axis_tready(ofm_tready),
        .ofm_m_axis_tlast(ofm_tlast),
        .bias_axis_error(bias_axis_error),
        .weight_axis_error(weight_axis_error),
        .ifm_axis_error(ifm_axis_error),
        .ofm_axis_error(ofm_axis_error)
    );

    task automatic check;
        input condition;
        input string label;
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $display("[FAIL] layer=%0d %s", layer_index, label);
            end
        end
    endtask

    task automatic cfg_write;
        input [7:0] addr;
        input [31:0] data;
        begin
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
                failures = failures + 1;
                $display("[FAIL] AXI-Lite write addr=%02x BRESP=%b",
                         addr, axi_bresp);
            end
            @(posedge clk);
            @(negedge clk);
            axi_bready = 1'b0;
        end
    endtask

    task automatic cfg_read;
        input [7:0] addr;
        output [31:0] data;
        begin
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
                failures = failures + 1;
                $display("[FAIL] AXI-Lite read addr=%02x RRESP=%b",
                         addr, axi_rresp);
            end
            @(posedge clk);
            @(negedge clk);
            axi_rready = 1'b0;
        end
    endtask

    task automatic set_layer_config;
        input integer index;
        begin
            // Geometry is the convolution output geometry; pooling is a
            // downstream transform selected independently.
            case (index)
                0: begin
                    layer_name = "00_conv0_pool";
                    cfg_fm_h=416; cfg_fm_w=416; cfg_cin=3; cfg_cout=16;
                    cfg_kernel=3; cfg_stride=1; cfg_pad=1;
                    cfg_pool_enable=1; cfg_pool_stride=2; cfg_tile_h=2;
                    cfg_quant_mult=18898; cfg_quant_shift=9;
                    cfg_quant_zp=69; cfg_input_zp=0;
                    cfg_expected_contexts=416;
                    cfg_expected_compute_fire=346112;
                end
                1: begin
                    layer_name = "01_conv1_pool";
                    cfg_fm_h=208; cfg_fm_w=208; cfg_cin=16; cfg_cout=32;
                    cfg_kernel=3; cfg_stride=1; cfg_pad=1;
                    cfg_pool_enable=1; cfg_pool_stride=2; cfg_tile_h=4;
                    cfg_quant_mult=18333; cfg_quant_shift=7;
                    cfg_quant_zp=101; cfg_input_zp=13;
                    cfg_expected_contexts=416;
                    cfg_expected_compute_fire=346112;
                end
                2: begin
                    layer_name = "02_conv2_pool";
                    cfg_fm_h=104; cfg_fm_w=104; cfg_cin=32; cfg_cout=64;
                    cfg_kernel=3; cfg_stride=1; cfg_pad=1;
                    cfg_pool_enable=1; cfg_pool_stride=2; cfg_tile_h=8;
                    cfg_quant_mult=21260; cfg_quant_shift=7;
                    cfg_quant_zp=101; cfg_input_zp=36;
                    cfg_expected_contexts=416;
                    cfg_expected_compute_fire=346112;
                end
                3: begin
                    layer_name = "03_conv3_pool";
                    cfg_fm_h=52; cfg_fm_w=52; cfg_cin=64; cfg_cout=128;
                    cfg_kernel=3; cfg_stride=1; cfg_pad=1;
                    cfg_pool_enable=1; cfg_pool_stride=2; cfg_tile_h=8;
                    cfg_quant_mult=18055; cfg_quant_shift=7;
                    cfg_quant_zp=75; cfg_input_zp=36;
                    cfg_expected_contexts=896;
                    cfg_expected_compute_fire=346112;
                end
                4: begin
                    layer_name = "04_conv4_pool";
                    cfg_fm_h=26; cfg_fm_w=26; cfg_cin=128; cfg_cout=256;
                    cfg_kernel=3; cfg_stride=1; cfg_pad=1;
                    cfg_pool_enable=1; cfg_pool_stride=2; cfg_tile_h=8;
                    cfg_quant_mult=18831; cfg_quant_shift=7;
                    cfg_quant_zp=73; cfg_input_zp=16;
                    cfg_expected_contexts=2048;
                    cfg_expected_compute_fire=346112;
                end
                5: begin
                    layer_name = "05_conv5_pool_like_tiny";
                    cfg_fm_h=13; cfg_fm_w=13; cfg_cin=256; cfg_cout=512;
                    cfg_kernel=3; cfg_stride=1; cfg_pad=1;
                    cfg_pool_enable=0; cfg_pool_stride=0; cfg_tile_h=8;
                    cfg_quant_mult=16863; cfg_quant_shift=7;
                    cfg_quant_zp=82; cfg_input_zp=15;
                    cfg_expected_contexts=4096;
                    cfg_expected_compute_fire=346112;
                end
                6: begin
                    layer_name = "06_head_conv6_3x3";
                    cfg_fm_h=13; cfg_fm_w=13; cfg_cin=512; cfg_cout=1024;
                    cfg_kernel=3; cfg_stride=1; cfg_pad=1;
                    cfg_pool_enable=0; cfg_pool_stride=0; cfg_tile_h=8;
                    cfg_quant_mult=26505; cfg_quant_shift=9;
                    cfg_quant_zp=85; cfg_input_zp=19;
                    cfg_expected_contexts=16384;
                    cfg_expected_compute_fire=1384448;
                end
                7: begin
                    layer_name = "07_head_conv7_1x1";
                    cfg_fm_h=13; cfg_fm_w=13; cfg_cin=1024; cfg_cout=256;
                    cfg_kernel=1; cfg_stride=1; cfg_pad=0;
                    cfg_pool_enable=0; cfg_pool_stride=0; cfg_tile_h=13;
                    cfg_quant_mult=28217; cfg_quant_shift=7;
                    cfg_quant_zp=69; cfg_input_zp=21;
                    cfg_expected_contexts=456;
                    cfg_expected_compute_fire=77064;
                end
                8: begin
                    layer_name = "08_head_conv8_3x3";
                    cfg_fm_h=13; cfg_fm_w=13; cfg_cin=256; cfg_cout=512;
                    cfg_kernel=3; cfg_stride=1; cfg_pad=1;
                    cfg_pool_enable=0; cfg_pool_stride=0; cfg_tile_h=8;
                    cfg_quant_mult=22396; cfg_quant_shift=8;
                    cfg_quant_zp=63; cfg_input_zp=13;
                    cfg_expected_contexts=4096;
                    cfg_expected_compute_fire=346112;
                end
                default: begin
                    layer_name = "09_head_detect_conv9_1x1";
                    cfg_fm_h=13; cfg_fm_w=13; cfg_cin=512; cfg_cout=24;
                    cfg_kernel=1; cfg_stride=1; cfg_pad=0;
                    cfg_pool_enable=0; cfg_pool_stride=0; cfg_tile_h=13;
                    cfg_quant_mult=23304; cfg_quant_shift=8;
                    cfg_quant_zp=80; cfg_input_zp=11;
                    cfg_expected_contexts=29;
                    cfg_expected_compute_fire=4901;
                end
            endcase
            cfg_k_total = cfg_cin * cfg_kernel * cfg_kernel;
            cfg_k_passes = (cfg_k_total + ROWS - 1) / ROWS;
            cfg_cout_blocks = (cfg_cout + COUT_TILE - 1) / COUT_TILE;
            cfg_tile_count = (cfg_fm_h + cfg_tile_h - 1) / cfg_tile_h;
            cfg_tile_pixels = cfg_fm_w * cfg_tile_h;
            cfg_ifm_bytes = cfg_fm_h * cfg_fm_w * cfg_cin;
            if (cfg_pool_enable)
                cfg_ofm_bytes = (cfg_fm_h/2) * (cfg_fm_w/2) * cfg_cout;
            else
                cfg_ofm_bytes = cfg_fm_h * cfg_fm_w * cfg_cout;
            cfg_ofm_beats = (cfg_ofm_bytes + 7) / 8;
            cfg_bias_packets = cfg_tile_count * cfg_cout_blocks;
            cfg_weight_packets = cfg_bias_packets * cfg_k_passes;
        end
    endtask

    task automatic load_layer_fixture;
        input integer use_fixture_as_chain_input;
        begin
            fixture_path = $sformatf("%s/%s/ifm_u8_hwc.mem",
                                     fixture_root, layer_name);
            $readmemh(fixture_path, fixture_ifm, 0, cfg_ifm_bytes-1);
            if (use_fixture_as_chain_input) begin
                for (integer i = 0; i < cfg_ifm_bytes; i = i + 1)
                    chain_ifm[i] = fixture_ifm[i];
            end else begin
                for (integer i = 0; i < cfg_ifm_bytes; i = i + 1) begin
                    if (chain_ifm[i] !== fixture_ifm[i]) begin
                        if (failures < 20)
                            $display("[FAIL] layer=%0d chained IFM byte=%0d got=%02x exp=%02x",
                                     layer_index, i, chain_ifm[i], fixture_ifm[i]);
                        failures = failures + 1;
                    end
                end
                checks = checks + 1;
            end

            fixture_path = $sformatf("%s/%s/weight_kco_s8.mem",
                                     fixture_root, layer_name);
            $readmemh(fixture_path, weight_mem, 0,
                      cfg_k_total*cfg_cout-1);
            fixture_path = $sformatf("%s/%s/bias_i32.mem",
                                     fixture_root, layer_name);
            $readmemh(fixture_path, bias_mem, 0, cfg_cout-1);
            fixture_path = $sformatf("%s/%s/activation_lut_u8.mem",
                                     fixture_root, layer_name);
            $readmemh(fixture_path, act_lut_mem, 0, 255);
            if (layer_index == 3)
                fixture_path = $sformatf(
                    "%s/%s/golden_pool2x2s2_u8_hwc.mem",
                    fixture_root, layer_name);
            else
                fixture_path = $sformatf(
                    "%s/%s/golden_ofm_u8_hwc.mem",
                    fixture_root, layer_name);
            $readmemh(fixture_path, golden_ofm, 0, cfg_ofm_bytes-1);
        end
    endtask

    task automatic program_layer_descriptor;
        begin
            for (integer lane = 0; lane < COUT_TILE; lane = lane + 1) begin
                cfg_write(8'h20, lane);
                cfg_write(8'h21, {cfg_quant_zp[7:0], 4'd0,
                                  cfg_quant_shift[3:0],
                                  cfg_quant_mult[15:0]});
            end
            for (integer lut_index = 0; lut_index < 256;
                 lut_index = lut_index + 1) begin
                cfg_write(8'h22, lut_index);
                cfg_write(8'h23, act_lut_mem[lut_index]);
            end

            cfg_write(8'h01, {7'd0, cfg_fm_w[8:0],
                              7'd0, cfg_fm_h[8:0]});
            cfg_write(8'h02, {7'd0, cfg_fm_w[8:0],
                              7'd0, cfg_fm_h[8:0]});
            cfg_write(8'h03, {15'd0, (cfg_kernel == 1),
                              6'd0, cfg_pad[1:0],
                              6'd0, cfg_stride[1:0]});
            cfg_write(8'h04, cfg_k_total);
            cfg_write(8'h05, cfg_cout);
            cfg_write(8'h06, cfg_tile_pixels);
            cfg_write(8'h07, 32'd2);
            cfg_write(8'h0f, cfg_input_zp);
            cfg_write(8'h10, {28'd0, cfg_pool_stride[1:0],
                              1'b0, cfg_pool_enable[0]});
            cfg_write(8'h11, cfg_ofm_bytes);
            // Formal runtime configuration: batch/raw-HWC, early drain,
            // pass prefetch, PSUM overlap, continuous PSUM and compute-time
            // prefetch.  Column PSUM (bit 6) remains statically disabled.
            cfg_write(8'h19, {24'd0, RELEASE_STREAM_CFG});
            cfg_write(8'h1a, cfg_bias_packets);
            cfg_write(8'h1b, cfg_weight_packets);
            cfg_write(8'h1c, 32'd1);
            cfg_write(8'h38, 32'h0000_0001);
            cfg_write(8'h7a, {(layer_index == 9), 22'd0,
                              cfg_tile_h[8:0]});
            cfg_write(8'h7b, cfg_ifm_bytes);
            cfg_write(8'h7c, cfg_ofm_bytes);
        end
    endtask

    task automatic send_ifm_frame;
        integer beat;
        integer byte_lane;
        integer byte_index;
        begin
            wait(dut.configured_stream_reset);
            for (beat = 0; beat < (cfg_ifm_bytes+7)/8;
                 beat = beat + 1) begin
                @(negedge clk);
                ifm_tdata = 64'd0;
                ifm_tkeep = 8'd0;
                for (byte_lane = 0; byte_lane < 8;
                     byte_lane = byte_lane + 1) begin
                    byte_index = beat*8 + byte_lane;
                    if (byte_index < cfg_ifm_bytes) begin
                        ifm_tdata[byte_lane*8 +: 8] =
                            chain_ifm[byte_index];
                        ifm_tkeep[byte_lane] = 1'b1;
                    end
                end
                ifm_tlast = (beat + 1 == (cfg_ifm_bytes+7)/8);
                ifm_tvalid = 1'b1;
                @(posedge clk);
                while (ifm_tready !== 1'b1)
                    @(posedge clk);
            end
            @(negedge clk);
            ifm_tvalid = 1'b0;
            ifm_tdata = 64'd0;
            ifm_tkeep = 8'd0;
            ifm_tlast = 1'b0;
        end
    endtask

    task automatic service_bias_stream;
        integer packet;
        integer beat;
        integer global_cout;
        reg [10:0] packet_cout_base;
        reg [10:0] expected_cout_base;
        begin
            for (packet = 0; packet < cfg_bias_packets;
                 packet = packet + 1) begin
                wait(bias_load_req);
                // ABI-v2 parameter DMA is one deterministic layer-long
                // stream.  Derive the descriptor from packet order rather
                // than sampling scheduler live state at a request boundary.
                expected_cout_base = (packet % cfg_cout_blocks) * COUT_TILE;
                packet_cout_base = expected_cout_base;
                check(current_cout_base == expected_cout_base,
                      $sformatf("bias request order packet=%0d", packet));
                for (beat = 0; beat < COUT_TILE/2; beat = beat + 1) begin
                    @(negedge clk);
                    global_cout = packet_cout_base + beat*2;
                    bias_tdata[31:0] = (global_cout < cfg_cout) ?
                        bias_mem[global_cout] : 32'd0;
                    bias_tdata[63:32] = (global_cout+1 < cfg_cout) ?
                        bias_mem[global_cout+1] : 32'd0;
                    bias_tkeep = 8'hff;
                    bias_tlast = (packet + 1 == cfg_bias_packets) &&
                                 (beat + 1 == COUT_TILE/2);
                    bias_tvalid = 1'b1;
                    @(posedge clk);
                    while (bias_tready !== 1'b1)
                        @(posedge clk);
                end
                @(negedge clk);
                bias_tvalid = 1'b0;
                bias_tdata = 64'd0;
                bias_tkeep = 8'd0;
                bias_tlast = 1'b0;
                wait(!bias_load_req);
                bias_service_count = bias_service_count + 1;
            end
        end
    endtask

    task automatic service_weight_stream;
        integer packet;
        integer beat;
        integer byte_lane;
        integer local_index;
        integer local_k;
        integer local_cout;
        integer global_k;
        integer global_cout;
        integer packet_in_tile;
        reg [13:0] packet_pass_base;
        reg [10:0] packet_cout_base;
        reg [13:0] ingress_pass_base;
        reg [10:0] ingress_cout_base;
        begin
            for (packet = 0; packet < cfg_weight_packets;
                 packet = packet + 1) begin
                wait(weight_load_req);
                // Prefetch requests are intentionally raised while the live
                // scheduler pass still names the context being computed.
                // Software sends a prepacked layer-long stream, so packet
                // sequence—not current_pass_base_k—is authoritative.
                packet_in_tile = packet %
                    (cfg_cout_blocks * cfg_k_passes);
                packet_cout_base =
                    (packet_in_tile / cfg_k_passes) * COUT_TILE;
                packet_pass_base =
                    (packet_in_tile % cfg_k_passes) * ROWS;
                ingress_pass_base =
                    dut.u_core.u_core.u_layer.weight_ingress_k_q;
                ingress_cout_base =
                    dut.u_core.u_core.u_layer.weight_ingress_cout_q;
                check(ingress_cout_base == packet_cout_base,
                      $sformatf("weight ingress COUT order packet=%0d expected=%0d got=%0d",
                                packet, packet_cout_base,
                                ingress_cout_base));
                check(ingress_pass_base == packet_pass_base,
                      $sformatf("weight ingress K-pass order packet=%0d expected=%0d got=%0d",
                                packet, packet_pass_base,
                                ingress_pass_base));
                if (TRACE_PIXEL0 && (layer_index == 9)) begin
                    $display("[CHAIN_TRACE_WEIGHT] pass=%0d k_base=%0d cout_base=%0d w_k0_c0=%0d w_klast_c0=%0d w_k0_clast=%0d",
                             packet_pass_base / ROWS,
                             packet_pass_base, packet_cout_base,
                             $signed(weight_mem[packet_pass_base*cfg_cout +
                                                packet_cout_base]),
                             $signed(weight_mem[((packet_pass_base+ROWS < cfg_k_total) ?
                                                 packet_pass_base+ROWS-1 :
                                                 cfg_k_total-1)*cfg_cout +
                                                packet_cout_base]),
                             $signed(weight_mem[packet_pass_base*cfg_cout +
                                                cfg_cout-1]));
                end
                for (beat = 0; beat < ROWS*COUT_TILE/8;
                     beat = beat + 1) begin
                    @(negedge clk);
                    weight_tdata = 64'd0;
                    for (byte_lane = 0; byte_lane < 8;
                         byte_lane = byte_lane + 1) begin
                        local_index = beat*8 + byte_lane;
                        local_k = local_index / COUT_TILE;
                        local_cout = local_index % COUT_TILE;
                        global_k = packet_pass_base + local_k;
                        global_cout = packet_cout_base + local_cout;
                        if ((global_k < cfg_k_total) &&
                            (global_cout < cfg_cout))
                            weight_tdata[byte_lane*8 +: 8] =
                                weight_mem[global_k*cfg_cout + global_cout];
                    end
                    weight_tkeep = 8'hff;
                    weight_tlast = (packet + 1 == cfg_weight_packets) &&
                                   (beat + 1 == ROWS*COUT_TILE/8);
                    weight_tvalid = 1'b1;
                    @(posedge clk);
                    while (weight_tready !== 1'b1)
                        @(posedge clk);
                end
                @(negedge clk);
                weight_tvalid = 1'b0;
                weight_tdata = 64'd0;
                weight_tkeep = 8'd0;
                weight_tlast = 1'b0;
                wait(!weight_load_req);
                weight_service_count = weight_service_count + 1;
            end
        end
    endtask

    task automatic read_layer_telemetry;
        reg [31:0] value;
        begin
            cfg_read(8'h12, layer_busy_cycles);
            cfg_read(8'h2a, layer_feeder_cycles);
            cfg_read(8'h85, layer_context_gap_cycles);
            cfg_read(8'h88, layer_psum_credit_cycles);
            cfg_read(8'h2c, layer_drain_cycles);
            cfg_read(8'h2d, layer_ofm_post_cycles);
            cfg_read(8'h28, layer_bias_cycles);
            cfg_read(8'h29, layer_weight_cycles);
            cfg_read(8'h79, layer_unclassified_cycles);
            cfg_read(8'h34, layer_compute_fire);
            cfg_read(8'h81, ctx_after_alloc);
            cfg_read(8'h82, ctx_after_issued);
            cfg_read(8'h83, ctx_after_retired);
            cfg_read(8'h84, ctx_after_collected);

            check((ctx_after_alloc-ctx_before_alloc) == cfg_expected_contexts,
                  "context alloc delta");
            check((ctx_after_issued-ctx_before_issued) == cfg_expected_contexts,
                  "input-issued delta");
            check((ctx_after_retired-ctx_before_retired) == cfg_expected_contexts,
                  "array-retired delta");
            check((ctx_after_collected-ctx_before_collected) == cfg_expected_contexts,
                  "collector-done delta");
            check(layer_compute_fire == cfg_expected_compute_fire,
                  "exact compute-fire count");
            check((dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.g_weight_preload.u_weight_preloader.tile_credit_accept_count -
                   weight_credit_before) ==
                  cfg_expected_contexts,
                  "one accepted weight credit per context");
            check((dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.g_weight_preload.u_weight_preloader.preload_commit_count -
                   weight_commit_before) ==
                  cfg_expected_contexts,
                  "one committed PE weight bank per context");

            for (integer error_addr = 8'h89;
                 error_addr <= 8'h8f; error_addr = error_addr + 1) begin
                cfg_read(error_addr[7:0], value);
                check(value == 32'd0,
                      $sformatf("zero context error/stall telemetry 0x%02x",
                                error_addr));
            end
            cfg_read(8'h49, value);
            check(value == 32'd0, "zero prefetch miss");
            cfg_read(8'h4f, value);
            check(value == 32'd0, "zero PSUM overlap underflow");
            cfg_read(8'h7f, value);
            check(value == 32'd0, "zero DATAPATH_ERRORS");

            cfg_read(8'h26, value);
            check(value == (cfg_ifm_bytes+7)/8,
                  "exact raw-HWC accepted beat count");
            check(dut.g_layer_long_hwc_ifm.accepted_axis_bytes_unused ==
                  cfg_ifm_bytes, "exact raw-HWC accepted byte count");
            cfg_read(8'h0c, value);
            check(value == cfg_ofm_beats,
                  "exact packed OFM beat telemetry");
            cfg_read(8'h7d, value);
            check(value == cfg_ofm_bytes,
                  "exact packed OFM byte telemetry");
            cfg_read(8'h7e, value);
            check(value == 32'd0,
                  "performance run has no OFM backpressure");
            cfg_read(8'h1d, value);
            check(value == cfg_bias_packets,
                  "all bias stream packets completed");
            cfg_read(8'h1e, value);
            check(value == cfg_weight_packets,
                  "all weight stream packets completed");

            total_busy = total_busy + layer_busy_cycles;
            total_feeder = total_feeder + layer_feeder_cycles;
            total_context_psum_gap = total_context_psum_gap +
                                     layer_context_gap_cycles +
                                     layer_psum_credit_cycles;
            total_drain_ofm = total_drain_ofm + layer_drain_cycles +
                              layer_ofm_post_cycles;
            total_bias_weight = total_bias_weight + layer_bias_cycles +
                                layer_weight_cycles;
            total_unclassified = total_unclassified +
                                 layer_unclassified_cycles;
            total_compute_fire = total_compute_fire + layer_compute_fire;
            total_contexts = total_contexts +
                             (ctx_after_alloc-ctx_before_alloc);
            total_ifm_bytes = total_ifm_bytes + cfg_ifm_bytes;
            total_ofm_bytes = total_ofm_bytes + cfg_ofm_bytes;
            total_ofm_beats = total_ofm_beats + cfg_ofm_beats;
            total_bias_packets = total_bias_packets + cfg_bias_packets;
            total_weight_packets = total_weight_packets +
                                   cfg_weight_packets;

            $display("[CHAIN_LAYER] index=%0d name=%s busy=%0d feeder=%0d context_psum_gap=%0d drain_ofm=%0d bias_weight=%0d unclassified=%0d contexts=%0d compute_fire=%0d ifm_bytes=%0d ofm_bytes=%0d ofm_beats=%0d sim_cycles=%0d",
                     layer_index, layer_name, layer_busy_cycles,
                     layer_feeder_cycles,
                     layer_context_gap_cycles+layer_psum_credit_cycles,
                     layer_drain_cycles+layer_ofm_post_cycles,
                     layer_bias_cycles+layer_weight_cycles,
                     layer_unclassified_cycles,
                     ctx_after_alloc-ctx_before_alloc,
                     layer_compute_fire, cfg_ifm_bytes, cfg_ofm_bytes,
                     cfg_ofm_beats, cycle_count-layer_start_cycle);
        end
    endtask

    task automatic run_one_layer;
        input integer index;
        integer mismatch_count;
        integer poll_count;
        reg ifm_task_done;
        reg bias_task_done;
        reg weight_task_done;
        begin
            layer_index = index;
            set_layer_config(index);
            load_layer_fixture(index == start_layer);
            program_layer_descriptor();

            cfg_read(8'h81, ctx_before_alloc);
            cfg_read(8'h82, ctx_before_issued);
            cfg_read(8'h83, ctx_before_retired);
            cfg_read(8'h84, ctx_before_collected);
            weight_credit_before =
                dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.g_weight_preload.u_weight_preloader.tile_credit_accept_count;
            weight_commit_before =
                dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.g_weight_preload.u_weight_preloader.preload_commit_count;

            layer_ofm_bytes = 0;
            layer_ofm_beats = 0;
            layer_tlast_count = 0;
            layer_output_protocol_failures = 0;
            bias_service_count = 0;
            weight_service_count = 0;
            ifm_task_done = 1'b0;
            bias_task_done = 1'b0;
            weight_task_done = 1'b0;
            run_active = 1'b1;
            layer_start_cycle = cycle_count;

            fork
                begin send_ifm_frame(); ifm_task_done = 1'b1; end
                begin service_bias_stream(); bias_task_done = 1'b1; end
                begin service_weight_stream(); weight_task_done = 1'b1; end
            join_none

            cfg_write(8'h00, 32'd1);
            cfg_read(8'h00, rd_value);
            poll_count = 0;
            while (!rd_value[0] && !rd_value[2] && poll_count < 32) begin
                cfg_read(8'h00, rd_value);
                poll_count = poll_count + 1;
            end
            check(rd_value[0] && !rd_value[2],
                  "validated start entered busy state");

            poll_count = 0;
            while (!rd_value[1] && poll_count < 8000000) begin
                // Frequent MMIO polling would dominate simulation and alter
                // the software-independent PL-cycle measurement.  Poll the
                // architectural state at a coarse fixed cadence.
                repeat (64) @(posedge clk);
                cfg_read(8'h00, rd_value);
                poll_count = poll_count + 64;
            end
            check(rd_value[1] && !rd_value[0] && !rd_value[2],
                  "layer completed before 8M-cycle timeout");
            wait(ifm_task_done && bias_task_done && weight_task_done);
            wait(layer_tlast_count == 1);
            repeat (4) @(posedge clk);
            run_active = 1'b0;

            check(bias_service_count == cfg_bias_packets,
                  "bias service request count");
            check(weight_service_count == cfg_weight_packets,
                  "weight service request count");
            check(layer_ofm_bytes == cfg_ofm_bytes,
                  "packed OFM captured byte count");
            check(layer_ofm_beats == cfg_ofm_beats,
                  "packed OFM captured beat count");
            check(layer_tlast_count == 1,
                  "one layer-final packed TLAST");
            check(layer_output_protocol_failures == 0,
                  "dense packed OFM TKEEP/TLAST protocol");

            mismatch_count = 0;
            for (integer output_index = 0;
                 output_index < cfg_ofm_bytes;
                 output_index = output_index + 1) begin
                if (layer_ofm[output_index] !== golden_ofm[output_index]) begin
                    if (mismatch_count < 20)
                        $display("[FAIL] layer=%0d OFM byte=%0d got=%02x exp=%02x",
                                 layer_index, output_index,
                                 layer_ofm[output_index],
                                 golden_ofm[output_index]);
                    mismatch_count = mismatch_count + 1;
                end
            end
            check(mismatch_count == 0, "layer output is byte-exact");

            read_layer_telemetry();
            check(!bias_axis_error && !weight_axis_error &&
                  !ifm_axis_error && !ofm_axis_error,
                  "all four AXIS protocol flags clear");

            // This is the actual next-layer input.  No fixture/golden array
            // is copied into chain_ifm after the first selected layer.
            for (integer output_index = 0;
                 output_index < cfg_ofm_bytes;
                 output_index = output_index + 1)
                chain_ifm[output_index] = layer_ofm[output_index];
        end
    endtask

    always @(posedge clk) begin
        if (!rst)
            cycle_count = cycle_count + 1;

        if (!rst && run_active && ofm_tvalid && ofm_tready) begin
            for (integer byte_lane = 0; byte_lane < 8;
                 byte_lane = byte_lane + 1) begin
                if (ofm_tkeep[byte_lane]) begin
                    if (layer_ofm_bytes < MAX_OFM_BYTES)
                        layer_ofm[layer_ofm_bytes] =
                            ofm_tdata[byte_lane*8 +: 8];
                    else
                        layer_output_protocol_failures =
                            layer_output_protocol_failures + 1;
                    layer_ofm_bytes = layer_ofm_bytes + 1;
                end else if ((layer_ofm_beats + 1 < cfg_ofm_beats) ||
                             (byte_lane < (cfg_ofm_bytes & 7))) begin
                    layer_output_protocol_failures =
                        layer_output_protocol_failures + 1;
                end
            end
            if (ofm_tlast != (layer_ofm_beats + 1 == cfg_ofm_beats))
                layer_output_protocol_failures =
                    layer_output_protocol_failures + 1;
            if (ofm_tlast)
                layer_tlast_count = layer_tlast_count + 1;
            layer_ofm_beats = layer_ofm_beats + 1;
        end
    end

    // Targeted release-path diagnostic.  Pixel zero is sufficient to locate
    // the first bad K-pass while keeping a 29-pass Conv9 log compact.  These
    // are observation-only hierarchical probes and are compile-time disabled
    // for the formal full-chain run.
    always @(posedge clk) begin
        if (rst) begin
            trace_fire_in_context = 0;
            trace_no_compute_cycles = 0;
            trace_stall_dumped = 1'b0;
        end else if (TRACE_PIXEL0 && run_active && (layer_index == 9)) begin
            if (dut.u_core.u_core.u_layer.compute_fire) begin
                trace_no_compute_cycles = 0;
            end else if (dut.u_core.u_core.context_alloc_count >= 3) begin
                trace_no_compute_cycles = trace_no_compute_cycles + 1;
            end

            if (dut.u_core.u_core.u_layer.accepted_compute_context_start) begin
                trace_fire_in_context = 0;
                $display("[CHAIN_TRACE_CONTEXT] id=%0d pass=%0d k_base=%0d epoch=%0d ifm_bank=%0d psum_rd=%0d psum_wr=%0d first=%0d final=%0d",
                         dut.u_core.u_core.u_layer.next_context_id_q,
                         dut.u_core.u_core.u_layer.sched_pass_base_k / ROWS,
                         dut.u_core.u_core.u_layer.sched_pass_base_k,
                         dut.u_core.u_core.u_layer.compute_context_epoch,
                         dut.u_core.u_core.u_layer.compute_context_bank,
                         dut.u_core.u_core.u_layer.sched_psum_rd_bank,
                         dut.u_core.u_core.u_layer.sched_psum_wr_bank,
                         dut.u_core.u_core.u_layer.sched_first_pass,
                         dut.u_core.u_core.u_layer.sched_final_pass);
            end
            if (dut.u_core.u_core.u_layer.u_top.feeder_start_accept ||
                dut.raw_hwc_packet_done ||
                dut.g_layer_long_hwc_ifm.u_layer_long_replay.fill_req_accept) begin
                $display("[CHAIN_TRACE_FEED] sched_start=%0b accept=%0b ready=%0b vector_fill=%0b push=%0d raw_done=%0b feeder_done=%0b fill_req/ready/accept=%0b/%0b/%0b pass_base=%0d k_pass=%0d replay_active=%0b replay_pass=%0d",
                         dut.u_core.u_core.u_layer.sched_feeder_start,
                         dut.u_core.u_core.u_layer.u_top.feeder_start_accept,
                         dut.u_core.u_core.u_layer.feeder_start_ready,
                         dut.u_core.u_core.u_layer.u_top.vector_fill_req,
                         dut.u_core.u_core.u_layer.u_top.vector_push_count,
                         dut.raw_hwc_packet_done,
                         dut.u_core.u_core.u_layer.feeder_done,
                         dut.u_core.u_core.u_layer.feeder_fill_req,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.fill_req_ready,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.fill_req_accept,
                         dut.current_feeder_pass_base_k,
                         dut.u_core.u_core.u_layer.sched_feeder_k_pass,
                         dut.layer_long_replay_active,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.active_replay_pass);
            end
            if (dut.u_core.u_core.u_layer.compute_fire) begin
                if (trace_fire_in_context == 0) begin
                    $display("[CHAIN_TRACE_IFM] id=%0d v0_7=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d vlast=%0d last=%0d",
                             dut.u_core.u_core.u_layer.issue_context_id_q,
                             $signed(dut.u_core.u_core.u_layer.vector_ifm_data[7:0]),
                             $signed(dut.u_core.u_core.u_layer.vector_ifm_data[15:8]),
                             $signed(dut.u_core.u_core.u_layer.vector_ifm_data[23:16]),
                             $signed(dut.u_core.u_core.u_layer.vector_ifm_data[31:24]),
                             $signed(dut.u_core.u_core.u_layer.vector_ifm_data[39:32]),
                             $signed(dut.u_core.u_core.u_layer.vector_ifm_data[47:40]),
                             $signed(dut.u_core.u_core.u_layer.vector_ifm_data[55:48]),
                             $signed(dut.u_core.u_core.u_layer.vector_ifm_data[63:56]),
                             $signed(dut.u_core.u_core.u_layer.vector_ifm_data[143:136]),
                             dut.u_core.u_core.u_layer.vector_packet_done);
                end
                trace_fire_in_context = trace_fire_in_context + 1;
            end
            if (dut.u_core.u_core.u_layer.collector_packet_valid &&
                dut.u_core.u_core.u_layer.collector_packet_ready &&
                (dut.u_core.u_core.u_layer.collector_packet_addr == 0)) begin
                $display("[CHAIN_TRACE_PSUM] id=%0d parent=%0d epoch=%0d bank=%0d first=%0d final=%0d ch0_7=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                         dut.u_core.u_core.u_layer.collector_packet_context_id,
                         dut.u_core.u_core.u_layer.collector_packet_parent_context_id,
                         dut.u_core.u_core.u_layer.collector_packet_epoch,
                         dut.u_core.u_core.u_layer.collector_packet_wr_bank,
                         dut.u_core.u_core.u_layer.collector_packet_first,
                         dut.u_core.u_core.u_layer.collector_packet_is_final,
                         $signed(dut.u_core.u_core.u_layer.collector_packet_data[31:0]),
                         $signed(dut.u_core.u_core.u_layer.collector_packet_data[63:32]),
                         $signed(dut.u_core.u_core.u_layer.collector_packet_data[95:64]),
                         $signed(dut.u_core.u_core.u_layer.collector_packet_data[127:96]),
                         $signed(dut.u_core.u_core.u_layer.collector_packet_data[159:128]),
                         $signed(dut.u_core.u_core.u_layer.collector_packet_data[191:160]),
                         $signed(dut.u_core.u_core.u_layer.collector_packet_data[223:192]),
                         $signed(dut.u_core.u_core.u_layer.collector_packet_data[255:224]));
            end

            // Trace mode is deliberately diagnostic rather than a release
            // result.  Stop a deterministic no-compute episode early and
            // capture every ownership/admission gate needed to distinguish
            // scheduler, IFM, weight-preload, and PSUM-owner waits.  Keeping
            // this behind TRACE_PIXEL0 leaves the canonical chain unchanged.
            if (!trace_stall_dumped && (trace_no_compute_cycles == 2048)) begin
                trace_stall_dumped = 1'b1;
                $display("[CHAIN_STALL_SCHED] state=%0d pass_base=%0d pass_index=%0d compute_start=%0b accepted=%0b done=%0b fire=%0b prefetch=%0b wdone=%0b fdone=%0b fast_armed=%0b fast_accepted=%0b prepared_level=%0d prepared_k=%0d first=%0b final=%0b",
                         dut.u_core.u_core.u_layer.u_sched.state,
                         dut.u_core.u_core.u_layer.u_sched.pass_base_k,
                         dut.u_core.u_core.u_layer.u_sched.pass_index,
                         dut.u_core.u_core.u_layer.compute_context_start,
                         dut.u_core.u_core.u_layer.accepted_compute_context_start,
                         dut.u_core.u_core.u_layer.compute_done,
                         dut.u_core.u_core.u_layer.compute_fire,
                         dut.u_core.u_core.u_layer.u_sched.prefetch_started,
                         dut.u_core.u_core.u_layer.u_sched.prefetch_weight_done,
                         dut.u_core.u_core.u_layer.u_sched.prefetch_feed_done,
                         dut.u_core.u_core.u_layer.u_sched.fast_handoff_armed,
                         dut.u_core.u_core.u_layer.u_sched.fast_handoff_accepted,
                         dut.u_core.u_core.u_layer.u_prepared_context_queue.count_q,
                         dut.u_core.u_core.u_layer.prepared_k_pass,
                         dut.u_core.u_core.u_layer.prepared_first,
                         dut.u_core.u_core.u_layer.prepared_final);
                $display("[CHAIN_STALL_IFM] req_pending=%0b ctx_count=%0d head_bank=%0b head_epoch=%0d select_valid=%0b select_fire=%0b core_ready=%0b buffer_ready=%0b alloc_pending=%0b fill_active=%0b banks_alloc=%b banks_commit=%b avail0=%0d avail1=%0d reader_active=%0b",
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.compute_request_pending_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.context_count_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.head_bank,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.head_epoch,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.select_valid,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.select_fire,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.core_ready,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.buffer_select_ready,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.alloc_pending_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.fill_active_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.bank_allocated,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.bank_committed,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.bank0_available,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.bank1_available,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_context_frontend.reader_active);
                $display("[CHAIN_STALL_CORE] start=%0b start_ready=%0b ctrl_ready=%0b active=%0b active_bank=%0b active_epoch=%0d mesh_valid=%b selected_weight=%0b preload_ready=%0b preload_states=%0d/%0d desc=%0d credit=%0d loading=%0b errors=%b%b%b fatal=%0b",
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.start,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.start_ready,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.ctrl_start_ready,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.active_context_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.active_context_bank_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.active_context_epoch_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.mesh_epoch_valid_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.selected_weight_ready,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.preload_start_ready,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.g_weight_preload.u_weight_preloader.bank0_state_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.g_weight_preload.u_weight_preloader.bank1_state_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.g_weight_preload.u_weight_preloader.desc_count_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.g_weight_preload.u_weight_preloader.credit_count_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.g_weight_preload.u_weight_preloader.loading_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.preload_sticky_protocol,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.preload_sticky_owner,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.preload_sticky_epoch,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.fatal_error);
                $display("[CHAIN_STALL_GATES] compute_ready=%0b ifm_valid=%0b ifm_ready=%0b stream_match=%0b weight_match=%0b admission=%0b psum_ready=%0b output_credit=%0b ctrl_state=%0d tagged_stream_valid/ready=%0b/%0b vector_fill=%0b push_count=%0d source_valid/ready/done=%0b/%0b/%0b feeder_done=%0b",
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.compute_ready,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.ifm_vector_valid,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.ifm_vector_ready,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.context_stream_match,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.active_weight_epoch_match,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.context_admission_ready,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.psum_input_ready,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.all_output_credit_available,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.u_core.u_ctrl.state_q,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.tagged_stream_valid,
                         dut.u_core.u_core.u_layer.u_top.g_tagged_context_core.tagged_stream_ready,
                         dut.u_core.u_core.u_layer.u_top.vector_fill_req,
                         dut.u_core.u_core.u_layer.u_top.vector_push_count,
                         dut.raw_hwc_ifm_valid,
                         dut.vector_ifm_ready,
                         dut.raw_hwc_packet_done,
                         dut.u_core.u_core.u_layer.feeder_done);
                $display("[CHAIN_STALL_REPLAY] active=%0b req_pending=%0b req_tile/pass=%0d/%0d bank_owned=%b complete=%b ready_count=%0d/%0d replay_bank=%0b replay_tile/pass=%0d/%0d issue_pixel/end=%0d/%0d rd_valid=%0b vector_valid/ready=%0b/%0b packet_done=%0b cache_err=0x%02x",
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.replay_active_q,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.req_pending_q,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.req_tile_q,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.req_pass_q,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.bank_owned_q,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.bank_complete_q,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.bank_ready_count_q[0],
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.bank_ready_count_q[1],
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.replay_bank_q,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.replay_tile_q,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.replay_pass_q,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.issue_pixel_q,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.replay_end_q,
                         dut.g_layer_long_hwc_ifm.u_layer_long_replay.u_tile_cache.rd_valid_q,
                         dut.raw_hwc_ifm_valid,
                         dut.vector_ifm_ready,
                         dut.raw_hwc_packet_done,
                         dut.layer_long_cache_error_status);
                $display("[CHAIN_STALL_PSUM] issue_active=%0b issue_id=%0d issue_epoch=%0d first=%0b final=%0b rd/wr=%0b/%0b admit_ready=%0b allocated=%b owner0=%0d/%0d owner1=%0d/%0d credit=%0d/%0d outstanding=%0d/%0d alloc_q=%0d release_q=%0d alloc_valid/ready=%0b/%0b release_valid/ready=%0b/%0b fail=%0b errors=0x%08x",
                         dut.u_core.u_core.u_layer.issue_context_active_q,
                         dut.u_core.u_core.u_layer.issue_context_id_q,
                         dut.u_core.u_core.u_layer.issue_context_epoch_q,
                         dut.u_core.u_core.u_layer.issue_first_q,
                         dut.u_core.u_core.u_layer.issue_final_q,
                         dut.u_core.u_core.u_layer.issue_psum_rd_bank_q,
                         dut.u_core.u_core.u_layer.issue_psum_wr_bank_q,
                         dut.u_core.u_core.u_layer.tagged_context_admission_ready,
                         dut.u_core.u_core.u_layer.psum_score_bank_allocated,
                         dut.u_core.u_core.u_layer.psum_score_bank0_epoch,
                         dut.u_core.u_core.u_layer.psum_score_bank0_context,
                         dut.u_core.u_core.u_layer.psum_score_bank1_epoch,
                         dut.u_core.u_core.u_layer.psum_score_bank1_context,
                         dut.u_core.u_core.u_layer.psum_score_credit0,
                         dut.u_core.u_core.u_layer.psum_score_credit1,
                         dut.u_core.u_core.u_layer.psum_score_outstanding0,
                         dut.u_core.u_core.u_layer.psum_score_outstanding1,
                         dut.u_core.u_core.u_layer.u_psum_alloc_events.count_q,
                         dut.u_core.u_core.u_layer.u_psum_release_events.count_q,
                         dut.u_core.u_core.u_layer.psum_score_alloc_valid,
                         dut.u_core.u_core.u_layer.psum_score_alloc_ready,
                         dut.u_core.u_core.u_layer.psum_score_release_valid,
                         dut.u_core.u_core.u_layer.psum_score_release_ready,
                         dut.u_core.u_core.u_layer.psum_score_fail_stop,
                         dut.u_core.u_core.u_layer.tagged_datapath_error_status);
                $display("[FAIL] diagnostic stop after Conv9 compute stall");
                $finish;
            end
        end
    end

    initial begin
        if ((start_layer < 0) || (stop_layer > 9) ||
            (start_layer > stop_layer)) begin
            $display("[FAIL] invalid START_LAYER=%0d STOP_LAYER=%0d",
                     start_layer, stop_layer);
            $finish;
        end

        repeat (8) @(negedge clk);
        rst = 1'b0;
        cfg_read(8'h77, rd_value);
        check(rd_value == 32'd2, "ABI version is two");
        cfg_read(8'h78, rd_value);
        check(rd_value == 32'h0f20_1012,
              "release capability is 18x16/COUT32/flags0f");
        cfg_read(8'h80, rd_value);
        check(rd_value == 32'd2, "context telemetry version is two");

        for (integer run_layer = start_layer;
             run_layer <= stop_layer; run_layer = run_layer + 1)
            run_one_layer(run_layer);

        if ((start_layer == 0) && (stop_layer == 9)) begin
            check(total_contexts == EXPECTED_TOTAL_CONTEXTS,
                  "aggregate context count");
            check(total_compute_fire == EXPECTED_TOTAL_COMPUTE_FIRE,
                  "aggregate compute-fire count");
            check(total_ifm_bytes == EXPECTED_TOTAL_IFM_BYTES,
                  "aggregate IFM byte traffic");
            check(total_ifm_bytes <= 2500000,
                  "aggregate IFM byte engineering ceiling");
            check(total_ofm_bytes == EXPECTED_TOTAL_OFM_BYTES,
                  "aggregate OFM byte traffic");
            check(total_ofm_beats == EXPECTED_TOTAL_OFM_BEATS,
                  "aggregate OFM beat traffic");
            check(total_bias_packets == EXPECTED_TOTAL_BIAS_PACKETS,
                  "aggregate bias packet traffic");
            check(total_weight_packets == EXPECTED_TOTAL_WEIGHT_PACKETS,
                  "aggregate weight packet traffic");
            check(total_bias_packets*(COUT_TILE*4) ==
                  EXPECTED_TOTAL_BIAS_BYTES,
                  "aggregate bias byte traffic");
            check(total_weight_packets*(ROWS*COUT_TILE) ==
                  EXPECTED_TOTAL_WEIGHT_BYTES,
                  "aggregate weight byte traffic");
            // The registered tile-cache write/request and replay-return
            // boundaries add deterministic launch cycles without changing
            // useful work.  At 100 MHz this revised 47.35 ms PL ceiling plus
            // the board-measured ABI-v2 software overhead of about 2.11 ms
            // still leaves roughly 0.54 ms below the 50 ms requirement.
            check(total_busy <= 4735000,
                  "aggregate PL busy <= 4,735,000 cycles");
            check(total_feeder <= 2000000,
                  "aggregate feeder <= 2,000,000 cycles");
            check(total_context_psum_gap <= 300000,
                  "aggregate context/PSUM gap <= 300,000 cycles");
            check(total_drain_ofm <= 600000,
                  "aggregate drain+OFM <= 600,000 cycles");
            check(total_bias_weight <= 200000,
                  "aggregate bias+weight <= 200,000 cycles");
            check(total_unclassified <= 10000,
                  "aggregate unclassified <= 10,000 cycles");
        end

        $display("[CHAIN_TOTAL] start=%0d stop=%0d stream_cfg=0x%02x busy=%0d feeder=%0d context_psum_gap=%0d drain_ofm=%0d bias_weight=%0d unclassified=%0d contexts=%0d compute_fire=%0d ifm_bytes=%0d ofm_bytes=%0d ofm_beats=%0d bias_packets=%0d weight_packets=%0d bias_bytes=%0d weight_bytes=%0d",
                 start_layer, stop_layer, RELEASE_STREAM_CFG,
                 total_busy, total_feeder,
                 total_context_psum_gap, total_drain_ofm,
                 total_bias_weight, total_unclassified, total_contexts,
                 total_compute_fire, total_ifm_bytes, total_ofm_bytes,
                 total_ofm_beats, total_bias_packets,
                 total_weight_packets,
                 total_bias_packets*(COUT_TILE*4),
                 total_weight_packets*(ROWS*COUT_TILE));
        if (failures == 0)
            $display("[PASS] tb_abi_v2_release_ten_layer_chain checks=%0d",
                     checks);
        else
            $display("[FAIL] tb_abi_v2_release_ten_layer_chain failures=%0d checks=%0d",
                     failures, checks);
        $finish;
    end

    initial begin
        repeat (10000000) @(posedge clk);
        $display("[FAIL] tb_abi_v2_release_ten_layer_chain global timeout layer=%0d cycles=%0d contexts=%0d compute_fire=%0d ofm=%0d",
                 layer_index, cycle_count, total_contexts,
                 total_compute_fire, layer_ofm_bytes);
        $finish;
    end

    // Full-chain XSIM is intentionally large.  Emit a low-rate heartbeat so
    // CI and interactive users can distinguish forward progress from a hung
    // simulator without enabling detailed PASSTRACE/COLTRACE hardware.
    initial begin
        forever begin
            // At the current release snapshot 250k simulated cycles can take
            // more than twenty minutes on Windows XSIM.  Keep the heartbeat
            // comfortably below typical CI no-output timeouts without adding
            // enough log traffic to affect simulation throughput.
            repeat (50000) @(posedge clk);
            if (!rst && run_active) begin
                $display("[CHAIN_PROGRESS] layer=%0d cycles=%0d layer_cycles=%0d contexts=%0d compute_fire=%0d ofm_bytes=%0d bias_packets=%0d weight_packets=%0d",
                         layer_index, cycle_count,
                         cycle_count-layer_start_cycle,
                         dut.u_core.u_core.context_alloc_count,
                         dut.u_core.u_core.u_cfg.perf_compute_cycles,
                         layer_ofm_bytes, bias_service_count,
                         weight_service_count);
                $fflush();
            end
        end
    end
endmodule

`timescale 1ns / 1ps
`include "tail_cycles_override.vh"

// This test is the executable definition of the abi_v2_release parameter
// profile.  Overrides remain available for focused debug, but the manifest
// top always elaborates the exact 18x16/COUT32 release configuration.
`ifndef TB_LAYER_LONG_TWO_TILE_MODULE
`define TB_LAYER_LONG_TWO_TILE_MODULE tb_conv_accel_axis_layer_long_two_tile_e2e
`endif
`ifndef TB_LAYER_LONG_ROWS
`define TB_LAYER_LONG_ROWS 18
`endif
`ifndef TB_LAYER_LONG_COLS
`define TB_LAYER_LONG_COLS 16
`endif
`ifndef TB_LAYER_LONG_IFM_FIFO_DEPTH
`define TB_LAYER_LONG_IFM_FIFO_DEPTH 1024
`endif
`ifndef TB_LAYER_LONG_IFM_FIFO_AW
`define TB_LAYER_LONG_IFM_FIFO_AW 10
`endif
`ifndef TB_LAYER_LONG_PSUM_FIFO_DEPTH
`define TB_LAYER_LONG_PSUM_FIFO_DEPTH 256
`endif
`ifndef TB_LAYER_LONG_PSUM_FIFO_AW
`define TB_LAYER_LONG_PSUM_FIFO_AW 8
`endif
`ifndef TB_LAYER_LONG_HWC_CACHE_AW
`define TB_LAYER_LONG_HWC_CACHE_AW 16
`endif
`ifndef TB_LAYER_LONG_HWC_CACHE_DEPTH
`define TB_LAYER_LONG_HWC_CACHE_DEPTH 43264
`endif
`ifndef TB_LAYER_LONG_HWC_CACHE_STRIPES
`define TB_LAYER_LONG_HWC_CACHE_STRIPES 4
`endif
`ifndef TB_LAYER_LONG_HWC_CACHE_USE_URAM
`define TB_LAYER_LONG_HWC_CACHE_USE_URAM 1
`endif
`ifndef TB_LAYER_LONG_MATERIALIZED_CACHE_AW
`define TB_LAYER_LONG_MATERIALIZED_CACHE_AW 15
`endif
`ifndef TB_LAYER_LONG_MATERIALIZED_CACHE_DEPTH
`define TB_LAYER_LONG_MATERIALIZED_CACHE_DEPTH 32768
`endif
`ifndef TB_LAYER_LONG_IFM_EPOCH_USE_URAM
`define TB_LAYER_LONG_IFM_EPOCH_USE_URAM 1
`endif
`ifndef TB_LAYER_LONG_TAIL_CYCLES
`define TB_LAYER_LONG_TAIL_CYCLES 1
`endif
`ifndef TB_LAYER_LONG_CIN_TOTAL
`define TB_LAYER_LONG_CIN_TOTAL 37
`endif
`ifndef TB_LAYER_LONG_COUT_TOTAL
`define TB_LAYER_LONG_COUT_TOTAL 37
`endif
`ifndef TB_LAYER_LONG_FM_H
`define TB_LAYER_LONG_FM_H 2
`endif
`ifndef TB_LAYER_LONG_FM_W
`define TB_LAYER_LONG_FM_W 2
`endif
`ifndef TB_LAYER_LONG_OFM_H
`define TB_LAYER_LONG_OFM_H `TB_LAYER_LONG_FM_H
`endif
`ifndef TB_LAYER_LONG_OFM_W
`define TB_LAYER_LONG_OFM_W `TB_LAYER_LONG_FM_W
`endif
`ifndef TB_LAYER_LONG_KERNEL_1X1
`define TB_LAYER_LONG_KERNEL_1X1 1
`endif
`ifndef TB_LAYER_LONG_CONV_STRIDE
`define TB_LAYER_LONG_CONV_STRIDE 1
`endif
`ifndef TB_LAYER_LONG_CONV_PAD
`define TB_LAYER_LONG_CONV_PAD 0
`endif
`ifndef TB_LAYER_LONG_TILE_H_MAX
`define TB_LAYER_LONG_TILE_H_MAX 1
`endif
`ifndef TB_LAYER_LONG_TILE_PIXELS
`define TB_LAYER_LONG_TILE_PIXELS \
    (`TB_LAYER_LONG_TILE_H_MAX * `TB_LAYER_LONG_OFM_W)
`endif
`ifndef TB_LAYER_LONG_TOTAL_PIXELS
`define TB_LAYER_LONG_TOTAL_PIXELS \
    (`TB_LAYER_LONG_OFM_H * `TB_LAYER_LONG_OFM_W)
`endif
`ifndef TB_LAYER_LONG_STREAM_CFG
`define TB_LAYER_LONG_STREAM_CFG 8'hbf
`endif

// Real two-spatial-tile integration test for the ABI-v2 layer-long path.
//
// Unlike tb_conv_accel_axis_layer_long_ifm, this test does not force any
// wrapper/core boundary signal.  A valid descriptor is written through
// AXI-Lite, one layer-long raw-HWC frame is supplied, and the real scheduler,
// feeder, arithmetic pipeline, tile retirement handshake, cache release, tile
// sequencer, and packed-OFM ping-pong writer all run to completion.
module `TB_LAYER_LONG_TWO_TILE_MODULE;
    localparam integer ROWS = `TB_LAYER_LONG_ROWS;
    localparam integer COLS = `TB_LAYER_LONG_COLS;
    localparam integer COUT_TILE = COLS * 2;
    localparam integer WGT_TILE_AW = 11;
    localparam integer PSUM_BUF_AW = 10;
    localparam integer CIN_TOTAL = `TB_LAYER_LONG_CIN_TOTAL;
    localparam integer COUT_TOTAL = `TB_LAYER_LONG_COUT_TOTAL;
    localparam integer FM_H = `TB_LAYER_LONG_FM_H;
    localparam integer FM_W = `TB_LAYER_LONG_FM_W;
    localparam integer OFM_H = `TB_LAYER_LONG_OFM_H;
    localparam integer OFM_W = `TB_LAYER_LONG_OFM_W;
    localparam integer KERNEL_1X1 = `TB_LAYER_LONG_KERNEL_1X1;
    localparam integer CONV_STRIDE = `TB_LAYER_LONG_CONV_STRIDE;
    localparam integer CONV_PAD = `TB_LAYER_LONG_CONV_PAD;
    localparam integer TILE_H_MAX = `TB_LAYER_LONG_TILE_H_MAX;
    localparam integer TILE_PIXELS = `TB_LAYER_LONG_TILE_PIXELS;
    localparam integer TOTAL_PIXELS = `TB_LAYER_LONG_TOTAL_PIXELS;
    localparam integer K_TOTAL = KERNEL_1X1 ?
        CIN_TOTAL : CIN_TOTAL * 9;
    localparam integer IFM_BYTES = FM_H * FM_W * CIN_TOTAL;
    localparam integer K_PASSES =
        (K_TOTAL + ROWS - 1) / ROWS;
    localparam integer COUT_BLOCKS =
        (COUT_TOTAL + COUT_TILE - 1) / COUT_TILE;
    localparam integer EXPECTED_CONTEXTS =
        2 * K_PASSES * COUT_BLOCKS;
    localparam integer EXPECTED_COMPUTE_FIRE =
        K_PASSES * COUT_BLOCKS * TOTAL_PIXELS;
    localparam integer EXPECTED_PSUM_TRANSFERS =
        (K_PASSES - 1) * COUT_BLOCKS * TOTAL_PIXELS;
    localparam integer EXPECTED_OFM_BYTES = TOTAL_PIXELS * COUT_TOTAL;
    localparam integer EXPECTED_OFM_BEATS =
        (EXPECTED_OFM_BYTES + 7) / 8;
    // AXI-Lite polling itself advances several PL cycles per iteration.  Scale
    // the bound with every layer-long work component: context setup, compute,
    // raw-HWC ingestion, and packed output.  This keeps the bound finite while
    // avoiding false hangs at both the Cin=1024 and 936/1024-pixel boundaries.
    localparam integer LAYER_POLL_LIMIT =
        5000 + EXPECTED_CONTEXTS * 100 +
        EXPECTED_COMPUTE_FIRE * 4 +
        ((IFM_BYTES + 7) / 8) * 4 + EXPECTED_OFM_BEATS * 4;
    // During the destructive reset case OFM ready is deliberately held low.
    // A large second tile still has to be ingested/materialized and finish its
    // first K pass before partial-PSUM ownership can overlap the stalled drain.
    localparam integer ACTIVE_RESET_WAIT_LIMIT =
        20000 + TILE_PIXELS * K_PASSES * 64;
    localparam integer BIAS_BEATS = COUT_TILE / 2;
    localparam integer WEIGHT_BEATS = (ROWS * COUT_TILE) / 8;
    localparam [7:0] RELEASE_STREAM_CFG = `TB_LAYER_LONG_STREAM_CFG;

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
    wire [10:0] current_cout_base;
    wire [13:0] current_pass_base_k;
    wire        bias_tready;
    reg         bias_tvalid = 1'b0;
    reg  [63:0] bias_tdata = 64'd0;
    reg  [7:0]  bias_tkeep = 8'd0;
    reg         bias_tlast = 1'b0;

    wire        weight_load_req;
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
    reg         ofm_tready = 1'b0;
    wire        ofm_tlast;

    wire bias_axis_error;
    wire weight_axis_error;
    wire ifm_axis_error;
    wire ofm_axis_error;

    integer checks = 0;
    integer failures = 0;
    integer cycle_count = 0;
    integer configured_start_count = 0;
    integer tile_start_count = 0;
    integer packed_begin_accept_count = 0;
    integer tile_engine_done_count = 0;
    integer release_handshake_count = 0;
    integer compute_fire_count = 0;
    integer pp_write_count = 0;
    integer pp_read_count = 0;
    integer bias_service_count = 0;
    integer weight_service_count = 0;
    integer bias_request_count = 0;
    integer weight_request_count = 0;
    integer bias_stream_beat_count = 0;
    integer weight_stream_beat_count = 0;
    integer bias_stream_tlast_count = 0;
    integer weight_stream_tlast_count = 0;
    integer bias_backpressure_cycles = 0;
    integer weight_backpressure_cycles = 0;
    integer ofm_beat_count = 0;
    integer ofm_byte_count = 0;
    integer ofm_payload_index = 0;
    integer tlast_count = 0;
    integer engine_done0_cycle = -1;
    integer engine_done1_cycle = -1;
    integer release0_cycle = -1;
    integer release1_cycle = -1;
    integer datapath_reset_active_cycles = 0;
    integer tile1_start_cycle = -1;
    integer active_seed = 0;
    integer active_run = -1;
    integer bias_gap_cycles = 0;
    integer weight_gap_cycles = 0;
    integer ifm_gap_cycles = 0;
    integer completed_runs = 0;
    integer active_reset_wait_cycles = 0;
    integer poll_count;
    integer lane;
    integer output_lane;
    reg [31:0] read_data;
    reg pending_seen_tile0 = 1'b0;
    reg pending_seen_tile1 = 1'b0;
    reg saw_ofm_stall = 1'b0;
    reg pingpong_overlap_seen = 1'b0;
    reg stall_hold_valid = 1'b0;
    reg [63:0] stall_hold_data = 64'd0;
    reg [7:0] stall_hold_keep = 8'd0;
    reg stall_hold_last = 1'b0;
    reg ifm_frame_sent = 1'b0;
    reg run_active = 1'b0;
    reg active_reset_stress = 1'b0;
    reg active_reset_overlap_seen = 1'b0;
    reg bias_req_q = 1'b0;
    reg weight_req_q = 1'b0;
    reg bias_stall_hold_valid = 1'b0;
    reg [63:0] bias_stall_hold_data = 64'd0;
    reg [7:0] bias_stall_hold_keep = 8'd0;
    reg bias_stall_hold_last = 1'b0;
    reg weight_stall_hold_valid = 1'b0;
    reg [63:0] weight_stall_hold_data = 64'd0;
    reg [7:0] weight_stall_hold_keep = 8'd0;
    reg weight_stall_hold_last = 1'b0;
    reg packed_error_reported = 1'b0;
    reg last_packed_packet_valid = 1'b0;
    integer last_packed_packet_cycle = -1;
    reg [PSUM_BUF_AW-1:0] last_packed_packet_pixel =
        {PSUM_BUF_AW{1'b0}};
    reg [10:0] last_packed_packet_cout = 11'd0;
    reg [7:0] last_packed_packet_epoch = 8'd0;
    reg [15:0] last_packed_packet_context = 16'd0;
    reg [31:0] ofm_ready_lfsr = 32'h1;
    integer ofm_ready_run = -1;

    // The three fixed seeds exercise genuinely different arithmetic as well
    // as independent AXIS source gaps and packed-OFM backpressure.  Values are
    // deliberately small enough that the Q15 requantizer stays away from
    // saturation, so every output byte remains sensitive to weight, IFM, and
    // bias routing mistakes.
    function integer ifm_sample;
        input integer seed;
        input integer pixel;
        input integer channel;
        begin
            ifm_sample = 1 + ((seed * 3 + pixel * 7 + channel * 5) % 5);
        end
    endfunction

    function integer weight_sample;
        input integer seed;
        input integer channel;
        input integer cout;
        integer residue;
        begin
            if ((channel < 0) || (channel >= K_TOTAL) ||
                (cout < 0) || (cout >= COUT_TOTAL)) begin
                weight_sample = 0;
            end else begin
                residue = (seed + channel * 7 + cout * 3) % 7;
                if (residue == 0)
                    weight_sample = 1;
                else if (residue == 1)
                    weight_sample = -1;
                else
                    weight_sample = 0;
            end
        end
    endfunction

    function integer bias_sample;
        input integer seed;
        input integer cout;
        begin
            if ((cout < 0) || (cout >= COUT_TOTAL))
                bias_sample = 0;
            else
                bias_sample = 40 + ((seed + cout * 5) % 17);
        end
    endfunction

    function [7:0] golden_ofm_byte;
        input integer seed;
        input integer pixel;
        input integer cout;
        integer global_k;
        integer channel;
        integer kernel_pos;
        integer kernel_y;
        integer kernel_x;
        integer output_y;
        integer output_x;
        integer input_y;
        integer input_x;
        integer input_pixel;
        integer accum;
        integer quantized;
        begin
            accum = bias_sample(seed, cout);
            output_y = pixel / OFM_W;
            output_x = pixel % OFM_W;
            for (global_k = 0; global_k < K_TOTAL;
                 global_k = global_k + 1) begin
                if (KERNEL_1X1) begin
                    channel = global_k;
                    kernel_y = 0;
                    kernel_x = 0;
                end else begin
                    channel = global_k / 9;
                    kernel_pos = global_k % 9;
                    kernel_y = kernel_pos / 3;
                    kernel_x = kernel_pos % 3;
                end
                input_y = output_y * CONV_STRIDE +
                          kernel_y - CONV_PAD;
                input_x = output_x * CONV_STRIDE +
                          kernel_x - CONV_PAD;
                if ((input_y >= 0) && (input_y < FM_H) &&
                    (input_x >= 0) && (input_x < FM_W)) begin
                    input_pixel = input_y * FM_W + input_x;
                    accum = accum +
                            ifm_sample(seed, input_pixel, channel) *
                            weight_sample(seed, global_k, cout);
                end
            end

            // Mirrors requant.v for mult=32767, shift=0, zp=0.  The directed
            // vectors keep accum positive, avoiding implementation-defined
            // host-language rounding for negative values.
            quantized = (accum * 32767 + 16384) >>> 15;
            if (quantized > 127)
                golden_ofm_byte = 8'd127;
            else if (quantized < -128)
                golden_ofm_byte = 8'h80;
            else
                golden_ofm_byte = quantized[7:0];
        end
    endfunction

    conv_accel_core_axi_lite_axis_stream #(
        .ROWS(ROWS), .COLS(COLS), .K_TILE(ROWS),
        .COUT_TILE(COUT_TILE), .IFM_BANKS(2),
        .IFM_FIFO_DEPTH(`TB_LAYER_LONG_IFM_FIFO_DEPTH),
        .IFM_FIFO_AW(`TB_LAYER_LONG_IFM_FIFO_AW),
        .WGT_FIFO_DEPTH(64), .WGT_FIFO_AW(6),
        .PSUM_FIFO_DEPTH(`TB_LAYER_LONG_PSUM_FIFO_DEPTH),
        .PSUM_FIFO_AW(`TB_LAYER_LONG_PSUM_FIFO_AW),
        .FM_W_MAX(416), .FM_H_MAX(416),
        .WGT_TILE_AW(WGT_TILE_AW),
        .PSUM_BUF_AW(PSUM_BUF_AW), .PSUM_BUF_DEPTH(1024),
        .OFM_ADDR_W(24),
        .OFM_FIFO_DEPTH(32), .OFM_FIFO_AW(5),
        .HWC_CACHE_AW(`TB_LAYER_LONG_HWC_CACHE_AW),
        .HWC_CACHE_DEPTH(`TB_LAYER_LONG_HWC_CACHE_DEPTH),
        .HWC_CACHE_STRIPES(`TB_LAYER_LONG_HWC_CACHE_STRIPES),
        .HWC_CACHE_USE_URAM(`TB_LAYER_LONG_HWC_CACHE_USE_URAM),
        .MATERIALIZED_CACHE_AW(`TB_LAYER_LONG_MATERIALIZED_CACHE_AW),
        .MATERIALIZED_CACHE_DEPTH(`TB_LAYER_LONG_MATERIALIZED_CACHE_DEPTH),
        .ENABLE_PACKED_HWC_OFM(1),
        .ENABLE_LAYER_TILE_SEQUENCER(1),
        .ENABLE_LAYER_LONG_HWC_IFM(1),
        .ENABLE_TAGGED_CONTEXT(1),
        .IFM_EPOCH_USE_URAM(`TB_LAYER_LONG_IFM_EPOCH_USE_URAM),
        .ENABLE_DETAILED_TRACE(0),
        .TAIL_CYCLES_CONFIG(`TB_LAYER_LONG_TAIL_CYCLES),
        .PACKED_OFM_MAX_PIXELS(1024),
        .PACKED_OFM_MAX_COUT(1024),
        .PACKED_OFM_BUFFER_DEPTH(4096)
    ) dut (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(axi_awaddr),
        .s_axi_awvalid(axi_awvalid),
        .s_axi_awready(axi_awready),
        .s_axi_wdata(axi_wdata),
        .s_axi_wstrb(axi_wstrb),
        .s_axi_wvalid(axi_wvalid),
        .s_axi_wready(axi_wready),
        .s_axi_bresp(axi_bresp),
        .s_axi_bvalid(axi_bvalid),
        .s_axi_bready(axi_bready),
        .s_axi_araddr(axi_araddr),
        .s_axi_arvalid(axi_arvalid),
        .s_axi_arready(axi_arready),
        .s_axi_rdata(axi_rdata),
        .s_axi_rresp(axi_rresp),
        .s_axi_rvalid(axi_rvalid),
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
        .ifm_line_words(9'd2),
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

    task check;
        input condition;
        input [8*160-1:0] label;
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $display("[FAIL] %0s", label);
            end
        end
    endtask

    task cfg_write;
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

    task cfg_read;
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

    task automatic send_bias_packet;
        input integer packet_index;
        output integer packet_complete;
        integer beat;
        integer gap;
        integer gap_index;
        integer packet_cout_base;
        integer bias0;
        integer bias1;
        begin : bias_packet_tx
            packet_complete = 0;
            // The ABI-v2 parameter DMA is a deterministic layer-long stream.
            // Packet order, rather than a scheduler signal that can still
            // name the live pass during prefetch, is authoritative.
            packet_cout_base =
                (packet_index % COUT_BLOCKS) * COUT_TILE;
            for (beat = 0; beat < BIAS_BEATS; beat = beat + 1) begin
                gap = (active_seed + beat * 3 +
                       packet_index * 5) % 4;
                for (gap_index = 0; gap_index < gap;
                     gap_index = gap_index + 1) begin
                    @(negedge clk);
                    if (dut.configured_datapath_reset) begin
                        bias_tvalid = 1'b0;
                        bias_tdata = 64'd0;
                        bias_tkeep = 8'd0;
                        bias_tlast = 1'b0;
                        disable bias_packet_tx;
                    end
                    bias_tvalid = 1'b0;
                    bias_tdata = 64'd0;
                    bias_tkeep = 8'd0;
                    bias_tlast = 1'b0;
                    bias_gap_cycles = bias_gap_cycles + 1;
                end
                @(negedge clk);
                bias0 = bias_sample(active_seed,
                                    packet_cout_base + beat * 2);
                bias1 = bias_sample(active_seed,
                                    packet_cout_base + beat * 2 + 1);
                bias_tdata[31:0] = bias0;
                bias_tdata[63:32] = bias1;
                bias_tkeep = 8'hff;
                bias_tlast = (packet_index == 2 * COUT_BLOCKS - 1) &&
                             (beat == BIAS_BEATS - 1);
                bias_tvalid = 1'b1;
                @(posedge clk);
                while (!bias_tready &&
                       !dut.configured_datapath_reset)
                    @(posedge clk);
                if (dut.configured_datapath_reset) begin
                    bias_tvalid = 1'b0;
                    bias_tdata = 64'd0;
                    bias_tkeep = 8'd0;
                    bias_tlast = 1'b0;
                    disable bias_packet_tx;
                end
                if (beat == 0)
                    check(current_cout_base == packet_cout_base,
                          "bias stream packet order matches COUT request");
                bias_stream_beat_count = bias_stream_beat_count + 1;
                if (bias_tlast)
                    bias_stream_tlast_count =
                        bias_stream_tlast_count + 1;
            end
            @(negedge clk);
            bias_tvalid = 1'b0;
            bias_tdata = 64'd0;
            bias_tkeep = 8'd0;
            bias_tlast = 1'b0;
            packet_complete = 1;
        end
    endtask

    task automatic send_weight_packet;
        input integer packet_index;
        output integer packet_complete;
        integer beat;
        integer byte_lane;
        integer flat_index;
        integer row_index;
        integer cout_lane;
        integer packet_pass_base;
        integer packet_cout_base;
        integer weight_value;
        integer gap;
        integer gap_index;
        integer packet_in_tile;
        begin : weight_packet_tx
            packet_complete = 0;
            packet_in_tile = packet_index %
                             (COUT_BLOCKS * K_PASSES);
            packet_cout_base =
                (packet_in_tile / K_PASSES) * COUT_TILE;
            packet_pass_base =
                (packet_in_tile % K_PASSES) * ROWS;
            for (beat = 0; beat < WEIGHT_BEATS; beat = beat + 1) begin
                gap = (active_seed * 3 + beat * 5 +
                       packet_index * 7) % 3;
                for (gap_index = 0; gap_index < gap;
                     gap_index = gap_index + 1) begin
                    @(negedge clk);
                    if (dut.configured_datapath_reset) begin
                        weight_tvalid = 1'b0;
                        weight_tdata = 64'd0;
                        weight_tkeep = 8'd0;
                        weight_tlast = 1'b0;
                        disable weight_packet_tx;
                    end
                    weight_tvalid = 1'b0;
                    weight_tdata = 64'd0;
                    weight_tkeep = 8'd0;
                    weight_tlast = 1'b0;
                    weight_gap_cycles = weight_gap_cycles + 1;
                end
                @(negedge clk);
                weight_tdata = 64'd0;
                for (byte_lane = 0; byte_lane < 8;
                     byte_lane = byte_lane + 1) begin
                    flat_index = beat * 8 + byte_lane;
                    row_index = flat_index / COUT_TILE;
                    cout_lane = flat_index % COUT_TILE;
                    weight_value = weight_sample(
                        active_seed,
                        packet_pass_base + row_index,
                        packet_cout_base + cout_lane);
                    weight_tdata[byte_lane*8 +: 8] = weight_value[7:0];
                end
                weight_tkeep = 8'hff;
                weight_tlast = (packet_index == EXPECTED_CONTEXTS - 1) &&
                               (beat == WEIGHT_BEATS - 1);
                weight_tvalid = 1'b1;
                @(posedge clk);
                while (!weight_tready &&
                       !dut.configured_datapath_reset)
                    @(posedge clk);
                if (dut.configured_datapath_reset) begin
                    weight_tvalid = 1'b0;
                    weight_tdata = 64'd0;
                    weight_tkeep = 8'd0;
                    weight_tlast = 1'b0;
                    disable weight_packet_tx;
                end
                if (beat == 0) begin
                    check(current_cout_base == packet_cout_base,
                          "weight stream packet order matches COUT request");
                    check((current_pass_base_k == packet_pass_base) ||
                          (dut.current_feeder_pass_base_k ==
                           packet_pass_base),
                          "weight stream packet order matches live/prefetch K request");
                end
                weight_stream_beat_count =
                    weight_stream_beat_count + 1;
                if (weight_tlast)
                    weight_stream_tlast_count =
                        weight_stream_tlast_count + 1;
            end
            @(negedge clk);
            weight_tvalid = 1'b0;
            weight_tdata = 64'd0;
            weight_tkeep = 8'd0;
            weight_tlast = 1'b0;
            packet_complete = 1;
        end
    endtask

    task automatic send_ifm_frame;
        output integer frame_complete;
        integer beat;
        integer byte_lane;
        integer byte_index;
        integer pixel_index;
        integer channel_index;
        integer gap;
        integer gap_index;
        integer frame_seed;
        begin : ifm_frame_tx
            frame_complete = 0;
            frame_seed = active_seed;
            for (beat = 0; beat < (IFM_BYTES + 7)/8;
                 beat = beat + 1) begin
                gap = (frame_seed * 5 + beat * 7) % 4;
                for (gap_index = 0; gap_index < gap;
                     gap_index = gap_index + 1) begin
                    @(negedge clk);
                    if (dut.configured_datapath_reset) begin
                        ifm_tvalid = 1'b0;
                        ifm_tdata = 64'd0;
                        ifm_tkeep = 8'd0;
                        ifm_tlast = 1'b0;
                        disable ifm_frame_tx;
                    end
                    ifm_tvalid = 1'b0;
                    ifm_tdata = 64'd0;
                    ifm_tkeep = 8'd0;
                    ifm_tlast = 1'b0;
                    ifm_gap_cycles = ifm_gap_cycles + 1;
                end
                @(negedge clk);
                ifm_tdata = 64'd0;
                ifm_tkeep = 8'd0;
                for (byte_lane = 0; byte_lane < 8;
                     byte_lane = byte_lane + 1) begin
                    byte_index = beat * 8 + byte_lane;
                    if (byte_index < IFM_BYTES) begin
                        pixel_index = byte_index / CIN_TOTAL;
                        channel_index = byte_index % CIN_TOTAL;
                        ifm_tdata[byte_lane*8 +: 8] =
                            ifm_sample(frame_seed, pixel_index,
                                       channel_index);
                        ifm_tkeep[byte_lane] = 1'b1;
                    end
                end
                ifm_tlast = beat == ((IFM_BYTES + 7)/8 - 1);
                ifm_tvalid = 1'b1;
                @(posedge clk);
                while (!ifm_tready &&
                       !dut.configured_datapath_reset)
                    @(posedge clk);
                if (dut.configured_datapath_reset) begin
                    ifm_tvalid = 1'b0;
                    ifm_tdata = 64'd0;
                    ifm_tkeep = 8'd0;
                    ifm_tlast = 1'b0;
                    disable ifm_frame_tx;
                end
            end

            @(negedge clk);
            ifm_tvalid = 1'b0;
            ifm_tdata = 64'd0;
            ifm_tkeep = 8'd0;
            ifm_tlast = 1'b0;
            ifm_frame_sent = 1'b1;
            frame_complete = 1;
        end
    endtask

    // Model the three MM2S engines as true layer-long streams.  Each source
    // starts at the single layer stream-reset boundary and holds its current
    // beat until the corresponding loader accepts it.  It never derives
    // payload contents from the scheduler's live pass, which is deliberately
    // stale while STREAM_CFG[7:3] prefetches the next context.
    initial begin : bias_layer_stream_driver
        integer packet_index;
        integer packet_complete;
        wait(!rst);
        forever begin
            wait(dut.configured_stream_reset);
            begin : one_bias_layer_stream
                for (packet_index = 0;
                     packet_index < 2 * COUT_BLOCKS;
                     packet_index = packet_index + 1) begin
                    send_bias_packet(packet_index, packet_complete);
                    if (!packet_complete)
                        disable one_bias_layer_stream;
                    bias_service_count = bias_service_count + 1;
                end
            end
            wait(!dut.configured_stream_reset);
        end
    end

    initial begin : weight_layer_stream_driver
        integer packet_index;
        integer packet_complete;
        wait(!rst);
        forever begin
            wait(dut.configured_stream_reset);
            begin : one_weight_layer_stream
                for (packet_index = 0;
                     packet_index < EXPECTED_CONTEXTS;
                     packet_index = packet_index + 1) begin
                    send_weight_packet(packet_index, packet_complete);
                    if (!packet_complete)
                        disable one_weight_layer_stream;
                    weight_service_count = weight_service_count + 1;
                end
            end
            wait(!dut.configured_stream_reset);
        end
    end

    // The raw frame is a layer-level transfer, not a per-tile service.
    initial begin : ifm_layer_stream_driver
        integer frame_complete;
        wait(!rst);
        forever begin
            wait(dut.configured_stream_reset);
            send_ifm_frame(frame_complete);
            wait(!dut.configured_stream_reset);
        end
    end

    // Keep tile 0 resident in the output drain bank until tile 1 has started,
    // then apply a seed-specific pseudo-random ready pattern.  Thus every run
    // proves ping-pong overlap and also stresses stability across many later
    // packed-beat stalls.
    initial begin
        wait(!rst);
        forever begin
            @(negedge clk);
            if (!run_active || active_reset_stress) begin
                ofm_tready = 1'b0;
                ofm_ready_run = -1;
            end else begin
                if (ofm_ready_run != active_run) begin
                    ofm_ready_lfsr = 32'h9e37_79b9 ^ active_seed;
                    ofm_ready_run = active_run;
                end else begin
                    ofm_ready_lfsr = {ofm_ready_lfsr[30:0],
                                      ofm_ready_lfsr[31] ^
                                      ofm_ready_lfsr[21] ^
                                      ofm_ready_lfsr[1] ^
                                      ofm_ready_lfsr[0]};
                end
                if (tile_start_count < 2)
                    ofm_tready = 1'b0;
                else
                    ofm_tready = ofm_ready_lfsr[0] |
                                 ofm_ready_lfsr[3];
            end
        end
    end

    // Read-only control-flow and output scoreboards.  No force/release is used
    // anywhere in this testbench.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count = 0;
            configured_start_count = 0;
            datapath_reset_active_cycles = 0;
            bias_req_q = 1'b0;
            weight_req_q = 1'b0;
            bias_stall_hold_valid = 1'b0;
            weight_stall_hold_valid = 1'b0;
        end else begin
            cycle_count = cycle_count + 1;

            if (dut.configured_datapath_reset)
                datapath_reset_active_cycles =
                    datapath_reset_active_cycles + 1;

            if (dut.configured_stream_reset)
                configured_start_count = configured_start_count + 1;

            if (bias_load_req && !bias_req_q)
                bias_request_count = bias_request_count + 1;
            if (weight_load_req && !weight_req_q)
                weight_request_count = weight_request_count + 1;
            bias_req_q = bias_load_req;
            weight_req_q = weight_load_req;

            if (bias_tvalid && !bias_tready &&
                !dut.configured_datapath_reset) begin
                bias_backpressure_cycles =
                    bias_backpressure_cycles + 1;
                if (bias_stall_hold_valid) begin
                    if ((bias_tdata !== bias_stall_hold_data) ||
                        (bias_tkeep !== bias_stall_hold_keep) ||
                        (bias_tlast !== bias_stall_hold_last)) begin
                        failures = failures + 1;
                        $display("[FAIL] bias AXIS changed while backpressured");
                    end
                end else begin
                    bias_stall_hold_valid = 1'b1;
                    bias_stall_hold_data = bias_tdata;
                    bias_stall_hold_keep = bias_tkeep;
                    bias_stall_hold_last = bias_tlast;
                end
            end else begin
                bias_stall_hold_valid = 1'b0;
            end

            if (weight_tvalid && !weight_tready &&
                !dut.configured_datapath_reset) begin
                weight_backpressure_cycles =
                    weight_backpressure_cycles + 1;
                if (weight_stall_hold_valid) begin
                    if ((weight_tdata !== weight_stall_hold_data) ||
                        (weight_tkeep !== weight_stall_hold_keep) ||
                        (weight_tlast !== weight_stall_hold_last)) begin
                        failures = failures + 1;
                        $display("[FAIL] weight AXIS changed while backpressured");
                    end
                end else begin
                    weight_stall_hold_valid = 1'b1;
                    weight_stall_hold_data = weight_tdata;
                    weight_stall_hold_keep = weight_tkeep;
                    weight_stall_hold_last = weight_tlast;
                end
            end else begin
                weight_stall_hold_valid = 1'b0;
            end

            if (active_reset_stress && ofm_tvalid && !ofm_tready &&
                ((RELEASE_STREAM_CFG[5] &&
                  (dut.u_core.u_core.u_layer.issue_context_active_q ||
                   dut.u_core.u_core.u_layer.collector_context_active)) ||
                 (!RELEASE_STREAM_CFG[5] &&
                  dut.u_core.u_core.u_layer.issue_context_active_q &&
                  dut.u_core.u_core.u_layer.psum_score_ext_mode)) &&
                (dut.u_core.u_core.u_layer.u_top.
                 g_tagged_context_core.tagged_bank_allocated != 2'b00) &&
                (dut.u_core.u_core.u_layer.u_top.
                 g_tagged_context_core.tagged_bank_committed != 2'b00) &&
                (dut.u_core.u_core.u_layer.
                 psum_score_bank_allocated != 2'b00) &&
                dut.g_packed_ofm_axis.g_pingpong.
                    u_ofm_hwc_axis_pingpong.drain_active)
                active_reset_overlap_seen = 1'b1;

            if (dut.packed_ofm_packet_fire) begin
                last_packed_packet_valid = 1'b1;
                last_packed_packet_cycle = cycle_count;
                last_packed_packet_pixel = dut.packed_ofm_packet_pixel;
                last_packed_packet_cout = dut.packed_ofm_packet_cout_base;
                last_packed_packet_epoch =
                    dut.u_core.u_core.u_layer.collector_packet_epoch;
                last_packed_packet_context =
                    dut.u_core.u_core.u_layer.collector_packet_context_id;
            end

            if (!packed_error_reported &&
                ((dut.g_packed_ofm_axis.g_pingpong.
                  u_ofm_hwc_axis_pingpong.u_bank0.state == 2'd1 &&
                  dut.g_packed_ofm_axis.g_pingpong.
                  u_ofm_hwc_axis_pingpong.u_bank0.s0_valid &&
                  dut.g_packed_ofm_axis.g_pingpong.
                  u_ofm_hwc_axis_pingpong.u_bank0.s0_contract_ok &&
                  dut.g_packed_ofm_axis.g_pingpong.
                  u_ofm_hwc_axis_pingpong.u_bank0.s0_slot_committed) ||
                 (dut.g_packed_ofm_axis.g_pingpong.
                  u_ofm_hwc_axis_pingpong.u_bank1.state == 2'd1 &&
                  dut.g_packed_ofm_axis.g_pingpong.
                  u_ofm_hwc_axis_pingpong.u_bank1.s0_valid &&
                  dut.g_packed_ofm_axis.g_pingpong.
                  u_ofm_hwc_axis_pingpong.u_bank1.s0_contract_ok &&
                  dut.g_packed_ofm_axis.g_pingpong.
                  u_ofm_hwc_axis_pingpong.u_bank1.s0_slot_committed))) begin
                packed_error_reported = 1'b1;
                $display("[PACKED_OVERWRITE] t=%0t cycle=%0d bank=%0d load=%0d drain=%0d states=%0d/%0d packet(v/r/fire)=%0d/%0d/%0d pixel=%0d cout=%0d slots=%0d/%0d committed=%0d/%0d counts=%0d/%0d expected=%0d/%0d",
                         $time, cycle_count,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.load_bank,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.load_active,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.drain_active,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.u_bank0.state,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.u_bank1.state,
                         dut.packed_ofm_packet_valid,
                         dut.packed_ofm_packet_ready,
                         dut.packed_ofm_packet_fire,
                         dut.packed_ofm_packet_pixel,
                         dut.packed_ofm_packet_cout_base,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.u_bank0.s0_slot_addr,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.u_bank1.s0_slot_addr,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.u_bank0.s0_slot_committed,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.u_bank1.s0_slot_committed,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.u_bank0.packet_count_reg,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.u_bank1.packet_count_reg,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.u_bank0.expected_packets_reg,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.u_bank1.expected_packets_reg);
                $display("[PACKED_OVERWRITE_OWNER] last_valid=%0d last_cycle=%0d last_pixel=%0d last_cout=%0d last_epoch=%0d last_context=%0d collector(active/epoch/context/cout/final)=%0d/%0d/%0d/%0d/%0d issue(active/epoch/context/first/final)=%0d/%0d/%0d/%0d/%0d psum(allocated/owner0/owner1/credit0/credit1)=%b/%0d/%0d/%0d/%0d",
                         last_packed_packet_valid,
                         last_packed_packet_cycle,
                         last_packed_packet_pixel,
                         last_packed_packet_cout,
                         last_packed_packet_epoch,
                         last_packed_packet_context,
                         dut.u_core.u_core.u_layer.collector_context_active,
                         dut.u_core.u_core.u_layer.collector_context_epoch,
                         dut.u_core.u_core.u_layer.collector_context_id,
                         dut.u_core.u_core.u_layer.u_collector.active_cout_base,
                         dut.u_core.u_core.u_layer.collector_context_is_final,
                         dut.u_core.u_core.u_layer.issue_context_active_q,
                         dut.u_core.u_core.u_layer.issue_context_epoch_q,
                         dut.u_core.u_core.u_layer.issue_context_id_q,
                         dut.u_core.u_core.u_layer.issue_first_q,
                         dut.u_core.u_core.u_layer.issue_final_q,
                         dut.u_core.u_core.u_layer.psum_score_bank_allocated,
                         dut.u_core.u_core.u_layer.psum_score_bank0_context,
                         dut.u_core.u_core.u_layer.psum_score_bank1_context,
                         dut.u_core.u_core.u_layer.psum_score_credit0,
                         dut.u_core.u_core.u_layer.psum_score_credit1);
                $display("[PACKED_OVERWRITE_TLAST] external(v/r/last)=%0d/%0d/%0d source(v/r/last)=%0d/%0d/%0d layer_last_pending=%0d active_tile(index/last)=%0d/%0d",
                         ofm_tvalid, ofm_tready, ofm_tlast,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.source_axis_tvalid,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.source_axis_tready,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.source_axis_tlast,
                         dut.g_packed_ofm_axis.g_pingpong.
                             u_ofm_hwc_axis_pingpong.layer_last_pending,
                         dut.active_tile_index, dut.active_tile_last);
            end

            if (dut.active_tile_start) begin
                if (!dut.packed_tile_begin_ready ||
                    !dut.g_packed_ofm_axis.g_pingpong.
                        u_ofm_hwc_axis_pingpong.tile_accept) begin
                    failures = failures + 1;
                    $display("[FAIL] packed begin did not accept on tile-start cycle");
                end
                if ((dut.packed_begin_output_pixels_q !==
                     dut.active_tile_output_pixels) ||
                    (dut.packed_begin_cout_total_q !== COUT_TOTAL[10:0]) ||
                    (dut.packed_begin_layer_last_q !==
                     dut.active_tile_last) ||
                    (dut.packed_begin_cout_blocks_q !==
                     COUT_BLOCKS[15:0]) ||
                    (dut.packed_begin_span_q !==
                     (dut.active_tile_output_pixels * COUT_BLOCKS))) begin
                    failures = failures + 1;
                    $display("[FAIL] precomputed packed-begin geometry is not exact");
                end
                if (tile_start_count == 0) begin
                    if ((dut.active_tile_index !== 16'd0) ||
                        (dut.active_tile_oy_base !== 9'd0) ||
                        (dut.active_tile_ofm_h !== TILE_H_MAX[8:0]) ||
                        (dut.active_tile_num_pixels !==
                         TILE_PIXELS[15:0]) ||
                        dut.active_tile_last) begin
                        failures = failures + 1;
                        $display("[FAIL] tile 0 geometry/start descriptor");
                    end
                end else if (tile_start_count == 1) begin
                    tile1_start_cycle = cycle_count;
                    if ((dut.active_tile_index !== 16'd1) ||
                        (dut.active_tile_oy_base !== TILE_H_MAX[8:0]) ||
                        (dut.active_tile_ofm_h !==
                         (OFM_H-TILE_H_MAX)) ||
                        (dut.active_tile_num_pixels !==
                         (TOTAL_PIXELS-TILE_PIXELS)) ||
                        !dut.active_tile_last) begin
                        failures = failures + 1;
                        $display("[FAIL] tile 1 geometry/start descriptor");
                    end
                    if (!ofm_tready && (saw_ofm_stall || ofm_tvalid))
                        pingpong_overlap_seen = 1'b1;
                end else begin
                    failures = failures + 1;
                    $display("[FAIL] unexpected third tile start");
                end
                tile_start_count = tile_start_count + 1;
            end

            if (dut.g_packed_ofm_axis.g_pingpong.
                u_ofm_hwc_axis_pingpong.tile_accept)
                packed_begin_accept_count = packed_begin_accept_count + 1;

            if (dut.active_tile_done) begin
                if (dut.active_tile_index == 16'd0)
                    engine_done0_cycle = cycle_count;
                else if (dut.active_tile_index == 16'd1)
                    engine_done1_cycle = cycle_count;
                tile_engine_done_count = tile_engine_done_count + 1;
            end

            if (dut.u_core.u_core.tile_retire_pending) begin
                if (dut.active_tile_index == 16'd0)
                    pending_seen_tile0 = 1'b1;
                else if (dut.active_tile_index == 16'd1)
                    pending_seen_tile1 = 1'b1;
            end

            if (dut.layer_long_release_valid &&
                dut.layer_long_release_ready) begin
                if (release_handshake_count == 0) begin
                    release0_cycle = cycle_count;
                    if ((dut.layer_long_release_epoch !== 8'd1) ||
                        (dut.layer_long_release_tile_index !== 16'd0)) begin
                        failures = failures + 1;
                        $display("[FAIL] tile 0 release tag");
                    end
                end else if (release_handshake_count == 1) begin
                    release1_cycle = cycle_count;
                    if ((dut.layer_long_release_epoch !== 8'd1) ||
                        (dut.layer_long_release_tile_index !== 16'd1)) begin
                        failures = failures + 1;
                        $display("[FAIL] tile 1 release tag");
                    end
                end else begin
                    failures = failures + 1;
                    $display("[FAIL] unexpected extra cache release");
                end
                release_handshake_count = release_handshake_count + 1;
            end

            if (dut.u_core.u_core.layer_compute_fire)
                compute_fire_count = compute_fire_count + 1;

            if (!rst && !dut.configured_datapath_reset) begin
                if (dut.u_core.u_core.u_layer.pp_wr_en !==
                    dut.u_core.u_core.u_layer.u_psum_owner.wr_fire) begin
                    failures = failures + 1;
                    $display("[FAIL] tagged PSUM write credit/RAM handshake diverged");
                end
                if (dut.u_core.u_core.u_layer.pp_rd_en !==
                    dut.u_core.u_core.u_layer.u_psum_owner.rd_fire) begin
                    failures = failures + 1;
                    $display("[FAIL] tagged PSUM read credit/RAM handshake diverged");
                end
                if (dut.u_core.u_core.u_layer.pp_rd_en &&
                    !dut.u_core.u_core.u_layer.psum_score_ext_mode) begin
                    failures = failures + 1;
                    $display("[FAIL] tagged PSUM RAM read without external-parent context");
                end
            end
            if (run_active && dut.u_core.u_core.u_layer.pp_wr_en)
                pp_write_count = pp_write_count + 1;
            if (run_active && dut.u_core.u_core.u_layer.pp_rd_en)
                pp_read_count = pp_read_count + 1;

            if (ofm_tvalid && !ofm_tready) begin
                saw_ofm_stall = 1'b1;
                if (stall_hold_valid) begin
                    if ((ofm_tdata !== stall_hold_data) ||
                        (ofm_tkeep !== stall_hold_keep) ||
                        (ofm_tlast !== stall_hold_last)) begin
                        failures = failures + 1;
                        $display("[FAIL] packed OFM changed while stalled");
                    end
                end else begin
                    stall_hold_valid = 1'b1;
                    stall_hold_data = ofm_tdata;
                    stall_hold_keep = ofm_tkeep;
                    stall_hold_last = ofm_tlast;
                end
            end else begin
                stall_hold_valid = 1'b0;
            end

            if (ofm_tvalid && ofm_tready) begin
                for (output_lane = 0; output_lane < 8;
                     output_lane = output_lane + 1) begin
                    if (ofm_tkeep[output_lane]) begin
                        if (ofm_tdata[output_lane*8 +: 8] !==
                            golden_ofm_byte(
                                active_seed,
                                ofm_payload_index / COUT_TOTAL,
                                ofm_payload_index % COUT_TOTAL)) begin
                            failures = failures + 1;
                            $display("[FAIL] run=%0d seed=%0d packed OFM byte %0d data=%02x exp=%02x",
                                     active_run, active_seed,
                                     ofm_payload_index,
                                     ofm_tdata[output_lane*8 +: 8],
                                     golden_ofm_byte(
                                         active_seed,
                                         ofm_payload_index / COUT_TOTAL,
                                         ofm_payload_index % COUT_TOTAL));
                        end
                        ofm_payload_index = ofm_payload_index + 1;
                    end
                end
                if ((ofm_beat_count < EXPECTED_OFM_BEATS - 1) &&
                    (ofm_tkeep !== 8'hff)) begin
                    failures = failures + 1;
                    $display("[FAIL] non-final packed OFM beat %0d TKEEP=%02x",
                             ofm_beat_count, ofm_tkeep);
                end
                if (ofm_tlast !==
                    (ofm_beat_count == EXPECTED_OFM_BEATS - 1)) begin
                    failures = failures + 1;
                    $display("[FAIL] packed OFM beat %0d TLAST=%0d",
                             ofm_beat_count, ofm_tlast);
                end
                ofm_beat_count = ofm_beat_count + 1;
                for (output_lane = 0; output_lane < 8;
                     output_lane = output_lane + 1)
                    ofm_byte_count = ofm_byte_count +
                                     ofm_tkeep[output_lane];
                if (ofm_tlast)
                    tlast_count = tlast_count + 1;
            end
        end
    end

    task clear_run_scoreboard;
        begin
            @(negedge clk);
            cycle_count = 0;
            configured_start_count = 0;
            tile_start_count = 0;
            packed_begin_accept_count = 0;
            tile_engine_done_count = 0;
            release_handshake_count = 0;
            compute_fire_count = 0;
            pp_write_count = 0;
            pp_read_count = 0;
            bias_service_count = 0;
            weight_service_count = 0;
            bias_request_count = 0;
            weight_request_count = 0;
            bias_stream_beat_count = 0;
            weight_stream_beat_count = 0;
            bias_stream_tlast_count = 0;
            weight_stream_tlast_count = 0;
            bias_backpressure_cycles = 0;
            weight_backpressure_cycles = 0;
            ofm_beat_count = 0;
            ofm_byte_count = 0;
            ofm_payload_index = 0;
            tlast_count = 0;
            engine_done0_cycle = -1;
            engine_done1_cycle = -1;
            release0_cycle = -1;
            release1_cycle = -1;
            tile1_start_cycle = -1;
            pending_seen_tile0 = 1'b0;
            pending_seen_tile1 = 1'b0;
            saw_ofm_stall = 1'b0;
            pingpong_overlap_seen = 1'b0;
            stall_hold_valid = 1'b0;
            stall_hold_data = 64'd0;
            stall_hold_keep = 8'd0;
            stall_hold_last = 1'b0;
            ifm_frame_sent = 1'b0;
            bias_gap_cycles = 0;
            weight_gap_cycles = 0;
            ifm_gap_cycles = 0;
            active_reset_overlap_seen = 1'b0;
            packed_error_reported = 1'b0;
            last_packed_packet_valid = 1'b0;
            last_packed_packet_cycle = -1;
            last_packed_packet_pixel = {PSUM_BUF_AW{1'b0}};
            last_packed_packet_cout = 11'd0;
            last_packed_packet_epoch = 8'd0;
            last_packed_packet_context = 16'd0;
            bias_req_q = bias_load_req;
            weight_req_q = weight_load_req;
            bias_stall_hold_valid = 1'b0;
            weight_stall_hold_valid = 1'b0;
        end
    endtask

    task request_datapath_reset;
        input integer expected_count;
        integer scrub_wait_cycles;
        begin
            run_active = 1'b0;
            datapath_reset_active_cycles = 0;
            // Start and reset are intentionally written together on every
            // recovery boundary; reset must win and no transfer may launch.
            cfg_write(8'h00, 32'h0000_0005);
            wait(dut.configured_datapath_reset);
            wait(!dut.configured_datapath_reset);
            // Let the three software stream models observe reset and remove
            // any held TVALID before checking the recovered boundary.
            repeat (2) @(negedge clk);
            cfg_read(8'h90, read_data);
            check(read_data == expected_count,
                  "datapath reset count increments exactly once");
            check(datapath_reset_active_cycles == 4,
                  "datapath reset spans exactly four PL cycles");
            cfg_read(8'h00, read_data);
            check(read_data[3:0] == 4'b0000,
                  "reset priority leaves accelerator idle and error-free");
            cfg_read(8'h04, read_data);
            check(read_data[13:0] == K_TOTAL,
                  "datapath reset preserves K_TOTAL");
            cfg_read(8'h05, read_data);
            check(read_data[10:0] == COUT_TOTAL,
                  "datapath reset preserves COUT_TOTAL");
            cfg_read(8'h19, read_data);
            check(read_data[7:0] == RELEASE_STREAM_CFG,
                  "datapath reset preserves configured STREAM_CFG");
            cfg_read(8'h7a, read_data);
            check(read_data == {1'b1, 22'd0, TILE_H_MAX[8:0]},
                  "datapath reset preserves layer-long descriptor");
            cfg_read(8'h7b, read_data);
            check(read_data == IFM_BYTES,
                  "datapath reset preserves IFM byte contract");
            cfg_read(8'h7c, read_data);
            check(read_data == EXPECTED_OFM_BYTES,
                  "datapath reset preserves OFM byte contract");
            cfg_read(8'h80, read_data);
            check(read_data == 32'd2,
                  "context telemetry version is two");
            for (lane = 8'h81; lane <= 8'h8f; lane = lane + 1) begin
                cfg_read(lane[7:0], read_data);
                check(read_data == 32'd0,
                      "datapath reset clears context dynamic telemetry");
            end
            cfg_read(8'h34, read_data);
            check(read_data == 32'd0,
                  "datapath reset clears compute-fire counter");
            cfg_read(8'h7d, read_data);
            check(read_data == 32'd0,
                  "datapath reset clears packed OFM byte counter");
            cfg_read(8'h1d, read_data);
            check(read_data == 32'd0,
                  "datapath reset clears bias packet counter");
            cfg_read(8'h1e, read_data);
            check(read_data == 32'd0,
                  "datapath reset clears weight packet counter");
            cfg_read(8'h7f, read_data);
            check(read_data == 32'd0,
                  "datapath reset clears sticky datapath errors");
            check(!bias_axis_error && !weight_axis_error &&
                  !ifm_axis_error && !ofm_axis_error,
                  "datapath reset clears all AXIS protocol errors");
            check(!dut.u_axis_bw_loader.bias_busy &&
                  !dut.u_axis_bw_loader.weight_busy,
                  "datapath reset clears parameter loader state");
            check(dut.u_core.u_core.u_layer.u_top.
                  g_tagged_context_core.tagged_bank_allocated == 2'b00 &&
                  dut.u_core.u_core.u_layer.u_top.
                  g_tagged_context_core.tagged_bank_committed == 2'b00 &&
                  !dut.u_core.u_core.u_layer.u_top.
                  g_tagged_context_core.tagged_reader_active,
                  "datapath reset releases tagged IFM epoch banks");
            check(!dut.u_core.u_core.u_layer.issue_context_active_q &&
                  !dut.u_core.u_core.u_layer.collector_context_active &&
                  dut.u_core.u_core.u_layer.
                  psum_score_bank_allocated == 2'b00,
                  "datapath reset clears active context and PSUM ownership");
            check(dut.g_packed_ofm_axis.g_pingpong.pingpong_all_free &&
                  !dut.g_packed_ofm_axis.g_pingpong.
                   u_ofm_hwc_axis_pingpong.load_active &&
                  !dut.g_packed_ofm_axis.g_pingpong.
                   u_ofm_hwc_axis_pingpong.drain_active &&
                   !ofm_tvalid,
                  "datapath reset clears packed-OFM ping-pong state");
            // Slot RAM is deliberately not synchronously reset: doing so
            // would turn the dense ownership bitmap into resettable FFs.
            // The reset entry captures the active span and both banks scrub
            // it in parallel through their existing single write ports.  A
            // recovery tile is backpressured until this bounded cleanup ends.
            scrub_wait_cycles = 0;
            while ((dut.g_packed_ofm_axis.g_pingpong.
                    u_ofm_hwc_axis_pingpong.u_bank0.scrub_active ||
                    dut.g_packed_ofm_axis.g_pingpong.
                    u_ofm_hwc_axis_pingpong.u_bank1.scrub_active) &&
                   (scrub_wait_cycles <
                    TILE_PIXELS * COUT_BLOCKS + 8)) begin
                @(negedge clk);
                scrub_wait_cycles = scrub_wait_cycles + 1;
            end
            check(!dut.g_packed_ofm_axis.g_pingpong.
                   u_ofm_hwc_axis_pingpong.u_bank0.scrub_active &&
                  !dut.g_packed_ofm_axis.g_pingpong.
                   u_ofm_hwc_axis_pingpong.u_bank1.scrub_active,
                  "datapath reset completes bounded packed-slot scrub");
            for (lane = 0; lane < TILE_PIXELS * COUT_BLOCKS;
                 lane = lane + 1)
                check(!dut.g_packed_ofm_axis.g_pingpong.
                       u_ofm_hwc_axis_pingpong.u_bank0.
                       committed_slots[lane] &&
                      !dut.g_packed_ofm_axis.g_pingpong.
                       u_ofm_hwc_axis_pingpong.u_bank1.
                       committed_slots[lane],
                      "datapath reset clears packed-OFM committed slot ownership");
            check(!bias_tvalid && !weight_tvalid && !ifm_tvalid,
                  "software stream models abort held beats on reset");
        end
    endtask

    task run_active_datapath_reset_case;
        input integer seed;
        begin
            active_seed = seed;
            active_run = -1;
            clear_run_scoreboard();
            active_reset_stress = 1'b1;
            run_active = 1'b1;

            cfg_write(8'h00, 32'd1);
            cfg_read(8'h00, read_data);
            poll_count = 0;
            while (!read_data[0] && !read_data[2] && poll_count < 16) begin
                cfg_read(8'h00, read_data);
                poll_count = poll_count + 1;
            end
            if (!read_data[0])
                $display("[START_REJECT] ctrl=%08x external=%0d sequencer=%0d invalid(basic/geometry/channel/line/tile/materialized/stream/ifm/ofm/pool/packed)=%b%b%b%b%b%b%b%b%b%b%b fm=%0dx%0d ofm=%0dx%0d k=%0d cout=%0d pixels=%0d tile_h=%0d ifm_bytes=%0d ofm_bytes=%0d",
                         read_data, dut.configured_config_error,
                         dut.u_core.u_core.sequencer_config_error,
                         dut.u_core.u_core.u_cfg.start_validate_basic_invalid_q,
                         dut.u_core.u_core.u_cfg.start_validate_geometry_invalid_q,
                         dut.u_core.u_core.u_cfg.start_validate_channel_invalid_q,
                         dut.u_core.u_core.u_cfg.start_validate_line_invalid_q,
                         dut.u_core.u_core.u_cfg.start_validate_tile_invalid_q,
                         dut.u_core.u_core.u_cfg.start_validate_materialized_invalid_q,
                         dut.u_core.u_core.u_cfg.start_validate_stream_invalid_q,
                         dut.u_core.u_core.u_cfg.start_validate_ifm_bytes_invalid_q,
                         dut.u_core.u_core.u_cfg.start_validate_ofm_bytes_invalid_q,
                         dut.u_core.u_core.u_cfg.start_validate_pool_invalid_q,
                         dut.u_core.u_core.u_cfg.start_validate_packed_invalid_q,
                         FM_H, FM_W, OFM_H, OFM_W, K_TOTAL, COUT_TOTAL,
                         TILE_PIXELS, TILE_H_MAX, IFM_BYTES,
                         EXPECTED_OFM_BYTES);
            check(read_data[0] && !read_data[2],
                  "reset stress entered release layer-busy state");

            active_reset_wait_cycles = 0;
            while (!active_reset_overlap_seen &&
                   active_reset_wait_cycles < ACTIVE_RESET_WAIT_LIMIT) begin
                @(negedge clk);
                active_reset_wait_cycles = active_reset_wait_cycles + 1;
            end
            check(active_reset_overlap_seen,
                  "reset stress reached simultaneous tagged/FIFO/PSUM/packed-OFM activity");
            check(ofm_tvalid && !ofm_tready,
                  "reset stress held a packed OFM beat under backpressure");
            check(dut.u_core.u_core.u_layer.
                  psum_score_bank_allocated != 2'b00,
                  "reset stress had live partial-PSUM ownership");
            check(dut.u_core.u_core.u_layer.u_top.
                  g_tagged_context_core.tagged_bank_allocated != 2'b00,
                  "reset stress had a live tagged IFM FIFO bank");

            request_datapath_reset(1);
            active_reset_stress = 1'b0;
            run_active = 1'b0;
            $display("[INFO] active release datapath reset seed=%0d overlap_wait=%0d cycles checks=%0d failures=%0d",
                     seed, active_reset_wait_cycles, checks, failures);
            repeat (3) @(negedge clk);
        end
    endtask

    task run_seed_case;
        input integer seed;
        input integer run_number;
        input integer perform_reset;
        input integer expected_reset_count;
        integer channel;
        integer cout;
        integer positive_weights;
        integer negative_weights;
        begin
            active_seed = seed;
            active_run = run_number;
            if (perform_reset)
                request_datapath_reset(expected_reset_count);
            else begin
                cfg_read(8'h90, read_data);
                check(read_data == expected_reset_count,
                      "recovered rerun starts without a second reset");
            end
            clear_run_scoreboard();

            positive_weights = 0;
            negative_weights = 0;
            for (channel = 0; channel < K_TOTAL;
                 channel = channel + 1)
                for (cout = 0; cout < COUT_TOTAL; cout = cout + 1) begin
                    if (weight_sample(seed, channel, cout) > 0)
                        positive_weights = positive_weights + 1;
                    if (weight_sample(seed, channel, cout) < 0)
                        negative_weights = negative_weights + 1;
                end
            check(positive_weights > 0 && negative_weights > 0,
                  "seed contains positive and negative nonzero weights");

            run_active = 1'b1;
            cfg_read(7'h00, read_data);
            check(read_data[2:0] == 3'b000,
                  "descriptor is idle and error-free before start");
            cfg_read(8'h19, read_data);
            check(read_data[7:0] == RELEASE_STREAM_CFG,
                  "seed executes with configured STREAM_CFG");

            // Exactly one software layer start; the hardware emits both tile
            // starts and all eight K/COUT/spatial contexts.
            cfg_write(7'h00, 32'd1);
            cfg_read(7'h00, read_data);
            poll_count = 0;
            while (!read_data[0] && !read_data[2] && poll_count < 16) begin
                cfg_read(7'h00, read_data);
                poll_count = poll_count + 1;
            end
            check(read_data[0] && !read_data[2],
                  "AXI-Lite start entered layer-busy state");

            poll_count = 0;
            while (!read_data[1] && poll_count < LAYER_POLL_LIMIT) begin
                cfg_read(7'h00, read_data);
                poll_count = poll_count + 1;
            end
            check(poll_count < LAYER_POLL_LIMIT,
                  "layer completed before poll timeout");
            check(read_data[2:0] == 3'b010,
                  "layer completion is done-sticky, idle, and error-free");

            cfg_read(7'h34, read_data);
            check(read_data == EXPECTED_COMPUTE_FIRE,
                  "performance counter reports every context compute fire");
            cfg_read(7'h7d, read_data);
            check(read_data == EXPECTED_OFM_BYTES,
                  "packed OFM byte counter reports the dense layer payload");
            cfg_read(7'h7e, read_data);
            check(read_data >= 32'd1,
                  "packed OFM randomized backpressure was counted");
            cfg_read(7'h7f, read_data);
            if (read_data != 32'd0)
                $display("[INFO] run=%0d seed=%0d DATAPATH_ERRORS=%08x packed(raw/overwrite/underflow)=%0d/%0d/%0d packets(b/w)=%0d/%0d contexts=%0d/%0d/%0d/%0d",
                         run_number, seed, read_data,
                         dut.packed_ofm_protocol_error_raw,
                         dut.packed_ofm_overwrite_error,
                         dut.packed_ofm_underflow_error,
                         bias_service_count, weight_service_count,
                         dut.u_core.u_core.context_alloc_count,
                         dut.u_core.u_core.context_input_issued_count,
                         dut.u_core.u_core.context_array_retired_count,
                         dut.u_core.u_core.context_collector_done_count);
            check(read_data == 32'd0,
                  "all datapath/epoch/context error bits are clear");

            check(configured_start_count == 1,
                  "one AXI-Lite start produced one layer stream reset");
            check(ifm_frame_sent, "one raw-HWC layer frame was sent");
            check(dut.raw_hwc_accepted_beats ==
                  (IFM_BYTES + 7)/8,
                  "raw-HWC input accepted the exact layer beat count");
            check(dut.raw_hwc_completed_packets == EXPECTED_CONTEXTS,
                  "materialized cache completed every context replay");
            check(dut.raw_hwc_completed_pixels ==
                  EXPECTED_COMPUTE_FIRE,
                  "materialized cache replayed every context pixel");
            check(dut.layer_long_epoch == 8'd1,
                  "soft-reset layer-long epoch advanced exactly once");
            check(dut.layer_long_cache_error_status == 5'd0,
                  "materialized cache ownership scoreboard stayed clean");

            check(bias_service_count == 2 * COUT_BLOCKS,
                  "bias layer-long stream completed every packet");
            check(weight_service_count == EXPECTED_CONTEXTS,
                  "weight layer-long stream completed every packet");
            check(bias_request_count == 2 * COUT_BLOCKS,
                  "scheduler requested every ordered bias packet");
            check(weight_request_count == EXPECTED_CONTEXTS,
                  "scheduler requested every ordered weight packet");
            check(bias_stream_beat_count ==
                  2 * COUT_BLOCKS * BIAS_BEATS &&
                  bias_stream_tlast_count == 1,
                  "bias DMA delivered one complete ordered batch stream");
            check(weight_stream_beat_count ==
                  EXPECTED_CONTEXTS * WEIGHT_BEATS &&
                  weight_stream_tlast_count == 1,
                  "weight DMA delivered one complete ordered batch stream");
            check(dut.bias_completed_packets == 2 * COUT_BLOCKS,
                  "bias batch loader completed every packet");
            check(dut.weight_completed_packets == EXPECTED_CONTEXTS,
                  "weight batch loader completed every packet");
            check(bias_gap_cycles > 0 && weight_gap_cycles > 0 &&
                  ifm_gap_cycles > 0,
                  "bias/weight/IFM sources each injected deterministic gaps");
            check(bias_backpressure_cycles > 0 &&
                  weight_backpressure_cycles > 0,
                  "both parameter DMA streams held complete beats across backpressure");
            check(!bias_axis_error && !weight_axis_error && !ifm_axis_error,
                  "all AXI input protocol checkers stayed clear");
            check(!ofm_axis_error,
                  "packed OFM protocol checker stayed clear");

            check(tile_start_count == 2,
                  "sequencer emitted exactly two real tile starts");
            check(packed_begin_accept_count == 2,
                  "both packed begins accepted on their tile-start cycle");
            check(tile_engine_done_count == 2,
                  "tile engine emitted exactly two done pulses");
            check(pending_seen_tile0 && pending_seen_tile1,
                  "both engine-done pulses entered held retirement");
            check(release_handshake_count == 2,
                  "both cache banks retired through valid/ready release");
            check(engine_done0_cycle >= 0 &&
                  release0_cycle > engine_done0_cycle,
                  "tile 0 engine-done preceded its cache release");
            check(tile1_start_cycle > release0_cycle,
                  "tile 1 sequencer start followed tile 0 release");
            check(engine_done1_cycle >= 0 &&
                  release1_cycle > engine_done1_cycle,
                  "tile 1 engine-done preceded its cache release");
            check(compute_fire_count == EXPECTED_COMPUTE_FIRE,
                  "arithmetic accepted every context pixel vector");
            check(pp_write_count == EXPECTED_PSUM_TRANSFERS &&
                  pp_read_count == EXPECTED_PSUM_TRANSFERS,
                  "external scoreboard and PSUM RAM transferred every partial packet");
            check(dut.u_core.u_core.u_layer.pp_committed_count0 == 0 &&
                  dut.u_core.u_core.u_layer.pp_committed_count1 == 0,
                  "external guard statically replaces local PSUM credit state");

            cfg_read(8'h81, read_data);
            check(read_data == EXPECTED_CONTEXTS,
                  "every context allocation counted");
            cfg_read(8'h82, read_data);
            check(read_data == EXPECTED_CONTEXTS,
                  "every input-issued boundary counted");
            cfg_read(8'h83, read_data);
            check(read_data == EXPECTED_CONTEXTS,
                  "every array retirement counted");
            cfg_read(8'h84, read_data);
            check(read_data == EXPECTED_CONTEXTS,
                  "every collector/drain completion counted");
            for (lane = 8'h89; lane <= 8'h8e; lane = lane + 1) begin
                cfg_read(lane[7:0], read_data);
                check(read_data == 32'd0,
                      "context error telemetry counter stayed zero");
            end
            cfg_read(8'h8f, read_data);
            check(read_data == 32'd0,
                  "no context-full stall occurred");
            cfg_read(8'h7f, read_data);
            check(read_data == 32'd0,
                  "tagged datapath completed without sticky error");

            check(saw_ofm_stall,
                  "packed OFM held TVALID under randomized backpressure");
            check(pingpong_overlap_seen,
                  "tile 1 started while tile 0 occupied stalled drain bank");
            check(ofm_beat_count == EXPECTED_OFM_BEATS &&
                  ofm_byte_count == EXPECTED_OFM_BYTES &&
                  ofm_payload_index == EXPECTED_OFM_BYTES,
                  "golden-checked OFM is one dense layer-long HWC stream");
            check(tlast_count == 1,
                  "packed OFM asserted TLAST exactly once at layer end");

            run_active = 1'b0;
            completed_runs = completed_runs + 1;
            $display("[INFO] release stress run=%0d seed=%0d gaps(b/w/i)=%0d/%0d/%0d ofm_stalls=%0d",
                     run_number, seed, bias_gap_cycles, weight_gap_cycles,
                     ifm_gap_cycles, dut.packed_ofm_axis_stall_cycles);
            repeat (3) @(negedge clk);
        end
    endtask

    initial begin
        repeat (6) @(negedge clk);
        rst = 1'b0;

        cfg_read(7'h77, read_data);
        check(read_data == 32'd2, "ABI version is 2");
        cfg_read(7'h78, read_data);
        check(read_data == {8'h0f, COUT_TILE[7:0], COLS[7:0], ROWS[7:0]},
              "capability exposes exact tagged layer-long geometry");

        // Q15 multiplier 32767 preserves the small positive golden sums.
        for (lane = 0; lane < COUT_TILE; lane = lane + 1) begin
            cfg_write(7'h20, lane);
            cfg_write(7'h21, 32'h0000_7fff);
        end

        // The default 2x2x37 -> 2x2x37 descriptor is split into two one-row
        // tiles.  Dimension/channel macros are overridable by focused release
        // wrappers while the manifest top retains these exact defaults.
        cfg_write(7'h01, {7'd0, FM_W[8:0], 7'd0, FM_H[8:0]});
        cfg_write(7'h02, {7'd0, OFM_W[8:0], 7'd0, OFM_H[8:0]});
        cfg_write(7'h03, {15'd0, KERNEL_1X1[0], 6'd0,
                          CONV_PAD[1:0], 6'd0, CONV_STRIDE[1:0]});
        cfg_write(7'h04, K_TOTAL);
        cfg_write(7'h05, COUT_TOTAL);
        cfg_write(7'h06, TILE_PIXELS);
        cfg_write(7'h07, 32'd0);
        cfg_write(7'h0f, 32'd0);
        cfg_write(7'h10, 32'd0);
        cfg_write(7'h11, EXPECTED_OFM_BYTES);
        cfg_write(7'h19, {24'd0, RELEASE_STREAM_CFG});
        cfg_write(7'h1a, 2 * COUT_BLOCKS);
        cfg_write(7'h1b, EXPECTED_CONTEXTS);
        cfg_write(7'h1c, 32'd1);
        cfg_write(7'h7a, {1'b1, 22'd0, TILE_H_MAX[8:0]});
        cfg_write(7'h7b, IFM_BYTES);
        cfg_write(7'h7c, EXPECTED_OFM_BYTES);

        cfg_read(8'h90, read_data);
        check(read_data == 32'd0,
              "datapath reset count starts at zero");
        cfg_read(8'h19, read_data);
        check(read_data[7:0] == RELEASE_STREAM_CFG,
              "release E2E is configured for requested STREAM_CFG");

        // Abort the first seed only after the release datapath has a live
        // tagged context, epoch FIFO bank, partial-PSUM owner, and a stalled
        // packed-OFM drain.  The same seed is then rerun byte-exact without
        // another reset, proving the software recovery boundary is usable.
        run_active_datapath_reset_case(3);
        run_seed_case(3, 0, 0, 1);
        run_seed_case(11, 1, 1, 2);
        run_seed_case(29, 2, 1, 3);

        cfg_read(8'h90, read_data);
        check(read_data == 32'd3,
              "three consecutive soft-reset recoveries were counted");
        check(completed_runs == 3,
              "all three fixed-seed release stress runs completed");

        if (failures == 0)
            $display("[PASS] tb_conv_accel_axis_layer_long_two_tile_e2e checks=%0d seeds=3,11,29",
                     checks);
        else
            $display("[FAIL] tb_conv_accel_axis_layer_long_two_tile_e2e failures=%0d checks=%0d",
                     failures, checks);
        $finish;
    end

    initial begin
        #3000000;
        $display("[FAIL] tb_conv_accel_axis_layer_long_two_tile_e2e timeout t=%0t starts=%0d engine_done=%0d releases=%0d compute=%0d ofm_beats=%0d bias=%0d weight=%0d",
                 $time, tile_start_count, tile_engine_done_count,
                 release_handshake_count, compute_fire_count,
                 ofm_beat_count, bias_service_count,
                 weight_service_count);
        $finish;
    end
endmodule

`timescale 1ns / 1ps
// Simple local configuration register bank for one convolution layer.
//
// Register map:
//   0x00 CTRL/STATUS: write bit0=start pulse, bit1=clear done; read bit0=busy, bit1=done_sticky
//   0x01 FM_SIZE:     [8:0]=fm_h,   [24:16]=fm_w
//   0x02 OFM_SIZE:    [8:0]=ofm_h,  [24:16]=ofm_w
//   0x03 CONV:        [1:0]=stride, [9:8]=pad
//   0x04 K_TOTAL:     [13:0]=k_total
//   0x05 COUT_TOTAL:  [10:0]=cout_total
//   0x06 NUM_PIXELS:  [15:0]=num_pixels
//   0x07 ACT_CFG:     [1:0]=activation_mode, 0=bypass, 1=ReLU, 2=Leaky LUT
//   0x08 TILE_ROWS:   [8:0]=tile_oy_base, [24:16]=tile_ofm_h, 0 tile_ofm_h means full ofm_h
//   0x09 PIXEL_BASE:  [23:0]=tile_pixel_base
//   0x0a DBG_EXPECTED: expected OFM AXIS packets for the current tile
//   0x0b DBG_CORE_WR:  OFM packets accepted from core writeback
//   0x0c DBG_AXIS_WR:  OFM AXIS packets accepted by the downstream sink
//   0x0d DBG_TLASTS:   OFM AXIS TLAST handshake count
//   0x0e DBG_LAST_END: packet count at the most recent TLAST handshake
//   0x0f IFM_ZP:       [7:0]=input_zero_point for uint8-to-sint8 IFM centering
//   0x10 POOL_CFG:     bit0=pool_enable, [3:2]=pool_stride, 0/bypass by default
//   0x11 EXPECTED_BYTES: expected OFM byte-stream payload bytes for TLAST/debug
//   0x12 PERF_BUSY:     layer_busy cycles for the current tile
//   0x13 PERF_WAIT_ANY: busy cycles stalled on any external service request
//   0x14 PERF_WAIT_BIAS: busy cycles with bias_load_req asserted
//   0x15 PERF_WAIT_WEIGHT: busy cycles with weight_load_req asserted
//   0x16 PERF_WAIT_IFM: busy cycles with feeder_fill_req asserted
//   0x17 PERF_WAIT_OFM: busy cycles with OFM backpressure asserted
//   0x18 PERF_COMPUTE:  cycles where the systolic array accepts a pixel
module layer_config_regs (
    input  clk,
    input  rst,

    input         cfg_wr_en,
    input  [5:0]  cfg_addr,
    input  [31:0] cfg_wdata,
    input         cfg_rd_en,
    output reg [31:0] cfg_rdata,

    input  layer_busy,
    input  layer_done,
    input  [31:0] dbg_expected_bytes,
    input  [31:0] dbg_core_wr_count,
    input  [31:0] dbg_axis_wr_count,
    input  [31:0] dbg_tlast_count,
    input  [31:0] dbg_last_tlast_index,
    input         perf_wait_bias,
    input         perf_wait_weight,
    input         perf_wait_ifm,
    input         perf_wait_ofm,
    input         perf_compute_fire,
    output reg start_pulse,

    output reg [8:0]  fm_h,
    output reg [8:0]  fm_w,
    output reg [8:0]  ofm_h,
    output reg [8:0]  ofm_w,
    output reg [1:0]  conv_stride,
    output reg [1:0]  conv_pad,
    output reg [1:0]  activation_mode,
    output reg [13:0] k_total,
    output reg [10:0] cout_total,
    output reg [15:0] num_pixels,
    output reg [8:0]  tile_oy_base,
    output reg [8:0]  tile_ofm_h,
    output reg [23:0] tile_pixel_base,
    output reg [7:0]  input_zero_point,
    output reg        pool_enable,
    output reg [1:0]  pool_stride,
    output reg [31:0] expected_bytes
);
    reg done_sticky;
    reg [31:0] perf_busy_cycles;
    reg [31:0] perf_wait_any_cycles;
    reg [31:0] perf_wait_bias_cycles;
    reg [31:0] perf_wait_weight_cycles;
    reg [31:0] perf_wait_ifm_cycles;
    reg [31:0] perf_wait_ofm_cycles;
    reg [31:0] perf_compute_cycles;
    wire cfg_idle = !layer_busy;
    wire perf_wait_any = perf_wait_bias || perf_wait_weight ||
                         perf_wait_ifm || perf_wait_ofm;

    always @(posedge clk) begin
        if (rst) begin
            start_pulse <= 1'b0;
            done_sticky <= 1'b0;
            fm_h <= 9'd0;
            fm_w <= 9'd0;
            ofm_h <= 9'd0;
            ofm_w <= 9'd0;
            conv_stride <= 2'd1;
            conv_pad <= 2'd0;
            activation_mode <= 2'd0;
            k_total <= 14'd0;
            cout_total <= 11'd0;
            num_pixels <= 16'd0;
            tile_oy_base <= 9'd0;
            tile_ofm_h <= 9'd0;
            tile_pixel_base <= 24'd0;
            input_zero_point <= 8'd0;
            pool_enable <= 1'b0;
            pool_stride <= 2'd0;
            expected_bytes <= 32'd0;
            perf_busy_cycles <= 32'd0;
            perf_wait_any_cycles <= 32'd0;
            perf_wait_bias_cycles <= 32'd0;
            perf_wait_weight_cycles <= 32'd0;
            perf_wait_ifm_cycles <= 32'd0;
            perf_wait_ofm_cycles <= 32'd0;
            perf_compute_cycles <= 32'd0;
        end else begin
            start_pulse <= 1'b0;
            if (layer_done)
                done_sticky <= 1'b1;

            if (layer_busy) begin
                perf_busy_cycles <= perf_busy_cycles + 1'b1;
                if (perf_wait_any)
                    perf_wait_any_cycles <= perf_wait_any_cycles + 1'b1;
                if (perf_wait_bias)
                    perf_wait_bias_cycles <= perf_wait_bias_cycles + 1'b1;
                if (perf_wait_weight)
                    perf_wait_weight_cycles <= perf_wait_weight_cycles + 1'b1;
                if (perf_wait_ifm)
                    perf_wait_ifm_cycles <= perf_wait_ifm_cycles + 1'b1;
                if (perf_wait_ofm)
                    perf_wait_ofm_cycles <= perf_wait_ofm_cycles + 1'b1;
                if (perf_compute_fire)
                    perf_compute_cycles <= perf_compute_cycles + 1'b1;
            end

            if (cfg_wr_en) begin
                case (cfg_addr)
                    6'h00: begin
                        if (cfg_wdata[0] && cfg_idle) begin
                            start_pulse <= 1'b1;
                            done_sticky <= 1'b0;
                            perf_busy_cycles <= 32'd0;
                            perf_wait_any_cycles <= 32'd0;
                            perf_wait_bias_cycles <= 32'd0;
                            perf_wait_weight_cycles <= 32'd0;
                            perf_wait_ifm_cycles <= 32'd0;
                            perf_wait_ofm_cycles <= 32'd0;
                            perf_compute_cycles <= 32'd0;
                        end
                        if (cfg_wdata[1])
                            done_sticky <= 1'b0;
                    end
                    6'h01: begin
                        if (cfg_idle) begin
                            fm_h <= cfg_wdata[8:0];
                            fm_w <= cfg_wdata[24:16];
                        end
                    end
                    6'h02: begin
                        if (cfg_idle) begin
                            ofm_h <= cfg_wdata[8:0];
                            ofm_w <= cfg_wdata[24:16];
                        end
                    end
                    6'h03: begin
                        if (cfg_idle) begin
                            conv_stride <= cfg_wdata[1:0];
                            conv_pad <= cfg_wdata[9:8];
                        end
                    end
                    6'h04: if (cfg_idle) k_total <= cfg_wdata[13:0];
                    6'h05: if (cfg_idle) cout_total <= cfg_wdata[10:0];
                    6'h06: if (cfg_idle) num_pixels <= cfg_wdata[15:0];
                    6'h07: if (cfg_idle) activation_mode <= cfg_wdata[1:0];
                    6'h08: begin
                        if (cfg_idle) begin
                            tile_oy_base <= cfg_wdata[8:0];
                            tile_ofm_h <= cfg_wdata[24:16];
                        end
                    end
                    6'h09: if (cfg_idle) tile_pixel_base <= cfg_wdata[23:0];
                    6'h0f: if (cfg_idle) input_zero_point <= cfg_wdata[7:0];
                    6'h10: begin
                        if (cfg_idle) begin
                            pool_enable <= cfg_wdata[0];
                            pool_stride <= cfg_wdata[3:2];
                        end
                    end
                    6'h11: if (cfg_idle) expected_bytes <= cfg_wdata;
                    default: begin end
                endcase
            end
        end
    end

    always @(*) begin
        case (cfg_addr)
            6'h00: cfg_rdata = {30'd0, done_sticky, layer_busy};
            6'h01: cfg_rdata = {7'd0, fm_w, 7'd0, fm_h};
            6'h02: cfg_rdata = {7'd0, ofm_w, 7'd0, ofm_h};
            6'h03: cfg_rdata = {22'd0, conv_pad, 6'd0, conv_stride};
            6'h04: cfg_rdata = {18'd0, k_total};
            6'h05: cfg_rdata = {21'd0, cout_total};
            6'h06: cfg_rdata = {16'd0, num_pixels};
            6'h07: cfg_rdata = {30'd0, activation_mode};
            6'h08: cfg_rdata = {7'd0, tile_ofm_h, 7'd0, tile_oy_base};
            6'h09: cfg_rdata = {8'd0, tile_pixel_base};
            6'h0a: cfg_rdata = dbg_expected_bytes;
            6'h0b: cfg_rdata = dbg_core_wr_count;
            6'h0c: cfg_rdata = dbg_axis_wr_count;
            6'h0d: cfg_rdata = dbg_tlast_count;
            6'h0e: cfg_rdata = dbg_last_tlast_index;
            6'h0f: cfg_rdata = {24'd0, input_zero_point};
            6'h10: cfg_rdata = {28'd0, pool_stride, 1'b0, pool_enable};
            6'h11: cfg_rdata = expected_bytes;
            6'h12: cfg_rdata = perf_busy_cycles;
            6'h13: cfg_rdata = perf_wait_any_cycles;
            6'h14: cfg_rdata = perf_wait_bias_cycles;
            6'h15: cfg_rdata = perf_wait_weight_cycles;
            6'h16: cfg_rdata = perf_wait_ifm_cycles;
            6'h17: cfg_rdata = perf_wait_ofm_cycles;
            6'h18: cfg_rdata = perf_compute_cycles;
            default: cfg_rdata = 32'd0;
        endcase
    end
endmodule

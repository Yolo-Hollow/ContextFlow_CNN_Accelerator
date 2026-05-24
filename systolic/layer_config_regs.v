`timescale 1ns / 1ps
// Simple local configuration register bank for one convolution layer.
//
// Register map:
//   0x00 CTRL/STATUS: write bit0=start pulse, bit1=clear done; read bit0=busy, bit1=done_sticky
//   0x01 FM_SIZE:     [8:0]=fm_h,   [24:16]=fm_w
//   0x02 OFM_SIZE:    [8:0]=ofm_h,  [24:16]=ofm_w
//   0x03 CONV:        [1:0]=stride, [9:8]=pad
//   0x04 K_TOTAL:     [10:0]=k_total
//   0x05 COUT_TOTAL:  [10:0]=cout_total
//   0x06 NUM_PIXELS:  [15:0]=num_pixels
//   0x07 ACT_CFG:     [1:0]=activation_mode, 0=bypass, 1=ReLU, 2=Leaky LUT
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
    output reg start_pulse,

    output reg [8:0]  fm_h,
    output reg [8:0]  fm_w,
    output reg [8:0]  ofm_h,
    output reg [8:0]  ofm_w,
    output reg [1:0]  conv_stride,
    output reg [1:0]  conv_pad,
    output reg [1:0]  activation_mode,
    output reg [10:0] k_total,
    output reg [10:0] cout_total,
    output reg [15:0] num_pixels
);
    reg done_sticky;

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
            k_total <= 11'd0;
            cout_total <= 11'd0;
            num_pixels <= 16'd0;
        end else begin
            start_pulse <= 1'b0;
            if (layer_done)
                done_sticky <= 1'b1;

            if (cfg_wr_en) begin
                case (cfg_addr)
                    6'h00: begin
                        if (cfg_wdata[0]) begin
                            start_pulse <= 1'b1;
                            done_sticky <= 1'b0;
                        end
                        if (cfg_wdata[1])
                            done_sticky <= 1'b0;
                    end
                    6'h01: begin
                        fm_h <= cfg_wdata[8:0];
                        fm_w <= cfg_wdata[24:16];
                    end
                    6'h02: begin
                        ofm_h <= cfg_wdata[8:0];
                        ofm_w <= cfg_wdata[24:16];
                    end
                    6'h03: begin
                        conv_stride <= cfg_wdata[1:0];
                        conv_pad <= cfg_wdata[9:8];
                    end
                    6'h04: k_total <= cfg_wdata[10:0];
                    6'h05: cout_total <= cfg_wdata[10:0];
                    6'h06: num_pixels <= cfg_wdata[15:0];
                    6'h07: activation_mode <= cfg_wdata[1:0];
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
            6'h04: cfg_rdata = {21'd0, k_total};
            6'h05: cfg_rdata = {21'd0, cout_total};
            6'h06: cfg_rdata = {16'd0, num_pixels};
            6'h07: cfg_rdata = {30'd0, activation_mode};
            default: cfg_rdata = 32'd0;
        endcase
    end
endmodule

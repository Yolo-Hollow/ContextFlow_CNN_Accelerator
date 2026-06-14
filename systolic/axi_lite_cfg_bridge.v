`timescale 1ns / 1ps

// Minimal AXI4-Lite to local configuration bus bridge.
//
// Address mapping is word based:
//   AXI byte address [8:2] -> cfg_addr[6:0]
//
// This bridge intentionally only wraps the local config register path. Data
// movement for bias/weight/IFM/OFM remains outside this module.
module axi_lite_cfg_bridge #(
    parameter ADDR_W = 9,
    parameter DATA_W = 32
) (
    input  clk,
    input  rst,

    input  [ADDR_W-1:0]     s_axi_awaddr,
    input                   s_axi_awvalid,
    output reg              s_axi_awready,

    input  [DATA_W-1:0]     s_axi_wdata,
    input  [DATA_W/8-1:0]   s_axi_wstrb,
    input                   s_axi_wvalid,
    output reg              s_axi_wready,

    output reg [1:0]        s_axi_bresp,
    output reg              s_axi_bvalid,
    input                   s_axi_bready,

    input  [ADDR_W-1:0]     s_axi_araddr,
    input                   s_axi_arvalid,
    output reg              s_axi_arready,

    output reg [DATA_W-1:0] s_axi_rdata,
    output reg [1:0]        s_axi_rresp,
    output reg              s_axi_rvalid,
    input                   s_axi_rready,

    output reg              cfg_wr_en,
    output reg [6:0]        cfg_addr,
    output reg [DATA_W-1:0] cfg_wdata,
    input      [DATA_W-1:0] cfg_rdata,
    output reg              cfg_rd_en
);
    localparam RD_IDLE = 1'b0;
    localparam RD_WAIT = 1'b1;
    localparam WR_IDLE = 1'b0;
    localparam WR_MERGE = 1'b1;

    reg [ADDR_W-1:0] awaddr_hold;
    reg [DATA_W-1:0] wdata_hold;
    reg [DATA_W/8-1:0] wstrb_hold;
    reg [ADDR_W-1:0] wr_merge_addr;
    reg [DATA_W-1:0] wr_merge_data;
    reg [DATA_W/8-1:0] wr_merge_strb;
    reg aw_hold_valid;
    reg w_hold_valid;
    reg rd_state;
    reg wr_state;

    integer i;

    function [DATA_W-1:0] merge_wstrb;
        input [DATA_W-1:0] old_data;
        input [DATA_W-1:0] data;
        input [DATA_W/8-1:0] strb;
        begin
            merge_wstrb = old_data;
            for (i = 0; i < DATA_W/8; i = i + 1)
                if (strb[i])
                    merge_wstrb[i*8 +: 8] = data[i*8 +: 8];
        end
    endfunction

    function [DATA_W-1:0] apply_wstrb_mask;
        input [DATA_W-1:0] data;
        input [DATA_W/8-1:0] strb;
        begin
            apply_wstrb_mask = {DATA_W{1'b0}};
            for (i = 0; i < DATA_W/8; i = i + 1)
                if (strb[i])
                    apply_wstrb_mask[i*8 +: 8] = data[i*8 +: 8];
        end
    endfunction

    wire write_can_accept = !s_axi_bvalid && (wr_state == WR_IDLE);
    wire aw_fire = s_axi_awvalid && s_axi_awready;
    wire w_fire = s_axi_wvalid && s_axi_wready;
    wire have_aw = aw_hold_valid || aw_fire;
    wire have_w = w_hold_valid || w_fire;
    wire do_write = write_can_accept && have_aw && have_w;

    wire [ADDR_W-1:0] write_addr = aw_hold_valid ? awaddr_hold : s_axi_awaddr;
    wire [DATA_W-1:0] write_data = w_hold_valid ? wdata_hold : s_axi_wdata;
    wire [DATA_W/8-1:0] write_strb = w_hold_valid ? wstrb_hold : s_axi_wstrb;

    always @(posedge clk) begin
        if (rst) begin
            s_axi_awready <= 1'b0;
            s_axi_wready <= 1'b0;
            s_axi_bresp <= 2'b00;
            s_axi_bvalid <= 1'b0;
            s_axi_arready <= 1'b0;
            s_axi_rdata <= {DATA_W{1'b0}};
            s_axi_rresp <= 2'b00;
            s_axi_rvalid <= 1'b0;
            cfg_wr_en <= 1'b0;
            cfg_addr <= 7'd0;
            cfg_wdata <= {DATA_W{1'b0}};
            cfg_rd_en <= 1'b0;
            awaddr_hold <= {ADDR_W{1'b0}};
            wdata_hold <= {DATA_W{1'b0}};
            wstrb_hold <= {DATA_W/8{1'b0}};
            wr_merge_addr <= {ADDR_W{1'b0}};
            wr_merge_data <= {DATA_W{1'b0}};
            wr_merge_strb <= {DATA_W/8{1'b0}};
            aw_hold_valid <= 1'b0;
            w_hold_valid <= 1'b0;
            rd_state <= RD_IDLE;
            wr_state <= WR_IDLE;
        end else begin
            cfg_wr_en <= 1'b0;
            cfg_rd_en <= 1'b0;
            s_axi_awready <= write_can_accept && !aw_hold_valid;
            s_axi_wready <= write_can_accept && !w_hold_valid;
            s_axi_arready <= (rd_state == RD_IDLE) && !s_axi_rvalid && (wr_state == WR_IDLE);

            if (aw_fire && !do_write) begin
                awaddr_hold <= s_axi_awaddr;
                aw_hold_valid <= 1'b1;
            end
            if (w_fire && !do_write) begin
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
                w_hold_valid <= 1'b1;
            end

            if (do_write) begin
                cfg_addr <= write_addr[8:2];
                aw_hold_valid <= 1'b0;
                w_hold_valid <= 1'b0;
                if (write_strb == {DATA_W/8{1'b1}} || write_addr[8:2] == 7'h00) begin
                    cfg_wdata <= (write_addr[8:2] == 7'h00) ? apply_wstrb_mask(write_data, write_strb) : write_data;
                    cfg_wr_en <= 1'b1;
                    s_axi_bresp <= 2'b00;
                    s_axi_bvalid <= 1'b1;
                end else begin
                    cfg_rd_en <= 1'b1;
                    wr_merge_addr <= write_addr;
                    wr_merge_data <= write_data;
                    wr_merge_strb <= write_strb;
                    wr_state <= WR_MERGE;
                end
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            if (wr_state == WR_MERGE) begin
                cfg_addr <= wr_merge_addr[8:2];
                cfg_wdata <= merge_wstrb(cfg_rdata, wr_merge_data, wr_merge_strb);
                cfg_wr_en <= 1'b1;
                s_axi_bresp <= 2'b00;
                s_axi_bvalid <= 1'b1;
                wr_state <= WR_IDLE;
            end

            case (rd_state)
                RD_IDLE: begin
                    if (s_axi_arvalid && s_axi_arready) begin
                        cfg_addr <= s_axi_araddr[8:2];
                        cfg_rd_en <= 1'b1;
                        rd_state <= RD_WAIT;
                    end
                end

                RD_WAIT: begin
                    s_axi_rdata <= cfg_rdata;
                    s_axi_rresp <= 2'b00;
                    s_axi_rvalid <= 1'b1;
                    rd_state <= RD_IDLE;
                end
            endcase

            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end
endmodule

`timescale 1ns / 1ps

// One packed rolling-row store used by the layer-long HWC materializer.
//
// A word contains two adjacent pixels and four adjacent channels:
//
//   addr = (channel >> 2) * ceil(fm_w / 2) + (x >> 1)
//   byte = {x[0], channel[1:0]}
//
// Both ports are symmetric.  During materialization they are two read ports;
// while this row is not part of the active window they can commit two
// independently byte-enabled fragments.  The parent coalesces same-address
// fragments and never presents a write/write collision.
module axis_hwc_window_row_store #(
    parameter integer DEPTH = 2048,
    parameter integer ADDR_W = 11,
    // Release builds use one UltraRAM per rolling row.  Setting this to zero
    // selects the behavior-identical BRAM fallback (four RAMB36 per row at
    // the default geometry).
    parameter integer USE_URAM = 1
) (
    input  wire                 clk,
    input  wire                 rst,

    input  wire [ADDR_W-1:0]    port_a_addr,
    input  wire [7:0]           port_a_we,
    input  wire [63:0]          port_a_wdata,
    output wire [63:0]          port_a_rdata,

    input  wire [ADDR_W-1:0]    port_b_addr,
    input  wire [7:0]           port_b_we,
    input  wire [63:0]          port_b_wdata,
    output wire [63:0]          port_b_rdata
);
    initial begin
        if (DEPTH != (1 << ADDR_W))
            $error("row-store DEPTH must be a power of two");
    end

    generate
        if (USE_URAM != 0) begin : g_uram
            xpm_memory_tdpram #(
                .MEMORY_SIZE(DEPTH * 64),
                .MEMORY_PRIMITIVE("ultra"),
                .CLOCKING_MODE("common_clock"),
                .ECC_MODE("no_ecc"),
                .MEMORY_INIT_FILE("none"),
                .USE_MEM_INIT(0),
                .WAKEUP_TIME("disable_sleep"),
                .AUTO_SLEEP_TIME(0),
                .MESSAGE_CONTROL(0),
                .MEMORY_OPTIMIZATION("true"),
                .CASCADE_HEIGHT(0),
                .SIM_ASSERT_CHK(0),
                .WRITE_DATA_WIDTH_A(64),
                .READ_DATA_WIDTH_A(64),
                .BYTE_WRITE_WIDTH_A(8),
                .ADDR_WIDTH_A(ADDR_W),
                .READ_RESET_VALUE_A("0"),
                .READ_LATENCY_A(2),
                .WRITE_MODE_A("no_change"),
                .RST_MODE_A("SYNC"),
                .WRITE_DATA_WIDTH_B(64),
                .READ_DATA_WIDTH_B(64),
                .BYTE_WRITE_WIDTH_B(8),
                .ADDR_WIDTH_B(ADDR_W),
                .READ_RESET_VALUE_B("0"),
                .READ_LATENCY_B(2),
                .WRITE_MODE_B("no_change"),
                .RST_MODE_B("SYNC")
            ) u_mem (
                .sleep(1'b0),
                .clka(clk), .rsta(rst), .ena(1'b1), .regcea(1'b1),
                .wea(port_a_we), .addra(port_a_addr),
                .dina(port_a_wdata), .douta(port_a_rdata),
                .injectsbiterra(1'b0), .injectdbiterra(1'b0),
                .sbiterra(), .dbiterra(),
                .clkb(clk), .rstb(rst), .enb(1'b1), .regceb(1'b1),
                .web(port_b_we), .addrb(port_b_addr),
                .dinb(port_b_wdata), .doutb(port_b_rdata),
                .injectsbiterrb(1'b0), .injectdbiterrb(1'b0),
                .sbiterrb(), .dbiterrb()
            );
        end else begin : g_bram
            xpm_memory_tdpram #(
                .MEMORY_SIZE(DEPTH * 64),
                .MEMORY_PRIMITIVE("block"),
                .CLOCKING_MODE("common_clock"),
                .ECC_MODE("no_ecc"),
                .MEMORY_INIT_FILE("none"),
                .USE_MEM_INIT(0),
                .WAKEUP_TIME("disable_sleep"),
                .AUTO_SLEEP_TIME(0),
                .MESSAGE_CONTROL(0),
                .MEMORY_OPTIMIZATION("true"),
                .CASCADE_HEIGHT(0),
                .SIM_ASSERT_CHK(0),
                .WRITE_DATA_WIDTH_A(64),
                .READ_DATA_WIDTH_A(64),
                .BYTE_WRITE_WIDTH_A(8),
                .ADDR_WIDTH_A(ADDR_W),
                .READ_RESET_VALUE_A("0"),
                .READ_LATENCY_A(2),
                .WRITE_MODE_A("no_change"),
                .RST_MODE_A("SYNC"),
                .WRITE_DATA_WIDTH_B(64),
                .READ_DATA_WIDTH_B(64),
                .BYTE_WRITE_WIDTH_B(8),
                .ADDR_WIDTH_B(ADDR_W),
                .READ_RESET_VALUE_B("0"),
                .READ_LATENCY_B(2),
                .WRITE_MODE_B("no_change"),
                .RST_MODE_B("SYNC")
            ) u_mem (
                .sleep(1'b0),
                .clka(clk), .rsta(rst), .ena(1'b1), .regcea(1'b1),
                .wea(port_a_we), .addra(port_a_addr),
                .dina(port_a_wdata), .douta(port_a_rdata),
                .injectsbiterra(1'b0), .injectdbiterra(1'b0),
                .sbiterra(), .dbiterra(),
                .clkb(clk), .rstb(rst), .enb(1'b1), .regceb(1'b1),
                .web(port_b_we), .addrb(port_b_addr),
                .dinb(port_b_wdata), .doutb(port_b_rdata),
                .injectsbiterrb(1'b0), .injectdbiterrb(1'b0),
                .sbiterrb(), .dbiterrb()
            );
        end
    endgenerate
endmodule

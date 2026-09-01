`timescale 1ns / 1ps

// Icarus-only behavioral stand-in for the Xilinx XPM true-dual-port memory.
// Production RTL continues to instantiate the vendor XPM from
// axis_hwc_window_row_store.v; this model exists only because Icarus cannot
// parse Vivado 2022.2's SystemVerilog XPM simulation library.  The focused
// materializer uses equal 64-bit ports, common clocks, byte enables,
// READ_LATENCY=2, and WRITE_MODE="no_change".
module xpm_memory_tdpram #(
    parameter integer MEMORY_SIZE = 131072,
    parameter         MEMORY_PRIMITIVE = "auto",
    parameter         CLOCKING_MODE = "common_clock",
    parameter         ECC_MODE = "no_ecc",
    parameter         MEMORY_INIT_FILE = "none",
    parameter integer USE_MEM_INIT = 0,
    parameter         WAKEUP_TIME = "disable_sleep",
    parameter integer AUTO_SLEEP_TIME = 0,
    parameter integer MESSAGE_CONTROL = 0,
    parameter         MEMORY_OPTIMIZATION = "true",
    parameter integer CASCADE_HEIGHT = 0,
    parameter integer SIM_ASSERT_CHK = 0,
    parameter integer WRITE_DATA_WIDTH_A = 64,
    parameter integer READ_DATA_WIDTH_A = 64,
    parameter integer BYTE_WRITE_WIDTH_A = 8,
    parameter integer ADDR_WIDTH_A = 11,
    parameter         READ_RESET_VALUE_A = "0",
    parameter integer READ_LATENCY_A = 2,
    parameter         WRITE_MODE_A = "no_change",
    parameter         RST_MODE_A = "SYNC",
    parameter integer WRITE_DATA_WIDTH_B = 64,
    parameter integer READ_DATA_WIDTH_B = 64,
    parameter integer BYTE_WRITE_WIDTH_B = 8,
    parameter integer ADDR_WIDTH_B = 11,
    parameter         READ_RESET_VALUE_B = "0",
    parameter integer READ_LATENCY_B = 2,
    parameter         WRITE_MODE_B = "no_change",
    parameter         RST_MODE_B = "SYNC"
) (
    input  wire                         sleep,
    input  wire                         clka,
    input  wire                         rsta,
    input  wire                         ena,
    input  wire                         regcea,
    input  wire [WRITE_DATA_WIDTH_A /
                 BYTE_WRITE_WIDTH_A-1:0] wea,
    input  wire [ADDR_WIDTH_A-1:0]       addra,
    input  wire [WRITE_DATA_WIDTH_A-1:0] dina,
    output wire [READ_DATA_WIDTH_A-1:0]  douta,
    input  wire                         injectsbiterra,
    input  wire                         injectdbiterra,
    output wire                         sbiterra,
    output wire                         dbiterra,
    input  wire                         clkb,
    input  wire                         rstb,
    input  wire                         enb,
    input  wire                         regceb,
    input  wire [WRITE_DATA_WIDTH_B /
                 BYTE_WRITE_WIDTH_B-1:0] web,
    input  wire [ADDR_WIDTH_B-1:0]       addrb,
    input  wire [WRITE_DATA_WIDTH_B-1:0] dinb,
    output wire [READ_DATA_WIDTH_B-1:0]  doutb,
    input  wire                         injectsbiterrb,
    input  wire                         injectdbiterrb,
    output wire                         sbiterrb,
    output wire                         dbiterrb
);
    localparam integer DEPTH = MEMORY_SIZE / WRITE_DATA_WIDTH_A;
    localparam integer BYTE_LANES_A = WRITE_DATA_WIDTH_A /
                                      BYTE_WRITE_WIDTH_A;
    localparam integer BYTE_LANES_B = WRITE_DATA_WIDTH_B /
                                      BYTE_WRITE_WIDTH_B;
    reg [WRITE_DATA_WIDTH_A-1:0] mem [0:DEPTH-1];
    reg [READ_DATA_WIDTH_A-1:0] read_a_q;
    reg [READ_DATA_WIDTH_A-1:0] read_a_out_q;
    reg [READ_DATA_WIDTH_B-1:0] read_b_q;
    reg [READ_DATA_WIDTH_B-1:0] read_b_out_q;
    integer byte_a_i;
    integer byte_b_i;

    initial begin
        if (WRITE_DATA_WIDTH_A != READ_DATA_WIDTH_A ||
            WRITE_DATA_WIDTH_A != WRITE_DATA_WIDTH_B ||
            WRITE_DATA_WIDTH_A != READ_DATA_WIDTH_B ||
            BYTE_WRITE_WIDTH_A != 8 || BYTE_WRITE_WIDTH_B != 8 ||
            READ_LATENCY_A != 2 || READ_LATENCY_B != 2 ||
            CLOCKING_MODE != "common_clock" ||
            WRITE_MODE_A != "no_change" || WRITE_MODE_B != "no_change")
            $fatal(1, "Icarus XPM shim used outside focused row-store contract");
    end

    always @(posedge clka) begin
        if (rsta) begin
            read_a_q <= {READ_DATA_WIDTH_A{1'b0}};
            read_a_out_q <= {READ_DATA_WIDTH_A{1'b0}};
        end else if (ena && !sleep) begin
            if (!(|wea))
                read_a_q <= mem[addra];
            if (regcea)
                read_a_out_q <= read_a_q;
            for (byte_a_i = 0; byte_a_i < BYTE_LANES_A;
                 byte_a_i = byte_a_i + 1)
                if (wea[byte_a_i])
                    mem[addra][byte_a_i*8 +: 8] <=
                        dina[byte_a_i*8 +: 8];
        end
    end

    always @(posedge clkb) begin
        if (rstb) begin
            read_b_q <= {READ_DATA_WIDTH_B{1'b0}};
            read_b_out_q <= {READ_DATA_WIDTH_B{1'b0}};
        end else if (enb && !sleep) begin
            if (!(|web))
                read_b_q <= mem[addrb];
            if (regceb)
                read_b_out_q <= read_b_q;
            for (byte_b_i = 0; byte_b_i < BYTE_LANES_B;
                 byte_b_i = byte_b_i + 1)
                if (web[byte_b_i])
                    mem[addrb][byte_b_i*8 +: 8] <=
                        dinb[byte_b_i*8 +: 8];
        end
    end

    assign douta = read_a_out_q;
    assign doutb = read_b_out_q;
    assign sbiterra = 1'b0;
    assign dbiterra = 1'b0;
    assign sbiterrb = 1'b0;
    assign dbiterrb = 1'b0;

    wire unused_error_injection = injectsbiterra || injectdbiterra ||
                                  injectsbiterrb || injectdbiterrb;
endmodule

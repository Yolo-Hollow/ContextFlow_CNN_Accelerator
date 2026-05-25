`timescale 1ns / 1ps

// Debug-friendly AXI-Stream wrapper for the current OFM byte stream.
//
// 64-bit stream format:
//   TDATA[OFM_ADDR_W-1:0]       = byte address
//   TDATA[OFM_ADDR_W +: 8]      = OFM byte data
//   upper bits                  = zero
//
// This is route A from the design notes: each output byte carries its address.
// It is simple to verify and useful while the PS/DMA contract is still being
// hardened. A later ofm_axis_packer can replace it with contiguous HWC bursts.
module axis_ofm_byte_writer #(
    parameter OFM_ADDR_W = 24,
    parameter AXIS_W = 64,
    parameter KEEP_W = AXIS_W / 8
) (
    input  [OFM_ADDR_W-1:0] byte_addr,
    input  [7:0]            byte_data,
    input                   byte_valid,
    output                  byte_ready,
    input                   byte_last,

    output [AXIS_W-1:0]     m_axis_tdata,
    output [KEEP_W-1:0]     m_axis_tkeep,
    output                  m_axis_tvalid,
    input                   m_axis_tready,
    output                  m_axis_tlast
);
    localparam USED_BYTES = (OFM_ADDR_W + 8 + 7) / 8;

    assign byte_ready = m_axis_tready;
    assign m_axis_tvalid = byte_valid;
    assign m_axis_tlast = byte_last;
    assign m_axis_tdata = {{(AXIS_W-OFM_ADDR_W-8){1'b0}}, byte_data, byte_addr};
    assign m_axis_tkeep =
        (USED_BYTES == 1) ? {{(KEEP_W-1){1'b0}}, 1'b1} :
        (USED_BYTES == 2) ? {{(KEEP_W-2){1'b0}}, 2'b11} :
        (USED_BYTES == 3) ? {{(KEEP_W-3){1'b0}}, 3'b111} :
        (USED_BYTES == 4) ? {{(KEEP_W-4){1'b0}}, 4'b1111} :
        (USED_BYTES == 5) ? {{(KEEP_W-5){1'b0}}, 5'b1_1111} :
        (USED_BYTES == 6) ? {{(KEEP_W-6){1'b0}}, 6'b11_1111} :
        (USED_BYTES == 7) ? {{(KEEP_W-7){1'b0}}, 7'b111_1111} :
                            {KEEP_W{1'b1}};
endmodule

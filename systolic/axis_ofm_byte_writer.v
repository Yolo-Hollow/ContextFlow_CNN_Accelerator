`timescale 1ns / 1ps

// Debug-friendly AXI-Stream wrapper for the current OFM byte stream.
//
// 64-bit stream format:
//   TDATA[OFM_ADDR_W-1:0]       = byte address
//   TDATA[OFM_ADDR_W +: 8]      = OFM byte data
//   upper bits                  = zero
//   TKEEP                       = all lanes valid
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
    assign byte_ready = m_axis_tready;
    assign m_axis_tvalid = byte_valid;
    assign m_axis_tlast = byte_last;
    assign m_axis_tdata = {{(AXIS_W-OFM_ADDR_W-8){1'b0}}, byte_data, byte_addr};
    assign m_axis_tkeep = {KEEP_W{1'b1}};
endmodule

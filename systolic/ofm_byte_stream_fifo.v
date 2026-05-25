`timescale 1ns / 1ps

// Small ready/valid FIFO for OFM byte writes.
//
// It converts the internal writeback byte stream into a DMA-facing stream that
// can apply backpressure without dropping bytes. Address is kept with each byte
// so the testbench/PS model can verify the HWC destination ordering directly.
module ofm_byte_stream_fifo #(
    parameter ADDR_W = 24,
    parameter DEPTH = 64,
    parameter AW = 6
) (
    input  clk,
    input  rst,

    input                  wr_en,
    output                 wr_ready,
    input  [ADDR_W-1:0]    wr_addr,
    input  [7:0]           wr_data,

    output                 m_valid,
    input                  m_ready,
    output [ADDR_W-1:0]    m_addr,
    output [7:0]           m_data,
    output                 full,
    output                 almost_full
);
    localparam PTR_W = AW + 1;

    reg [ADDR_W-1:0] addr_mem [0:DEPTH-1];
    reg [7:0] data_mem [0:DEPTH-1];
    reg [PTR_W-1:0] wptr, rptr;

    wire empty = (wptr == rptr);
    wire fifo_full = (wptr[PTR_W-1] != rptr[PTR_W-1]) &&
                     (wptr[AW-1:0] == rptr[AW-1:0]);
    wire [PTR_W-1:0] level = wptr - rptr;
    wire pop = m_valid && m_ready;
    wire can_push = !fifo_full || pop;
    wire push = wr_en && can_push;

    assign wr_ready = can_push;
    assign full = fifo_full;
    assign almost_full = (level >= (DEPTH - 2));
    assign m_valid = !empty;
    assign m_addr = addr_mem[rptr[AW-1:0]];
    assign m_data = data_mem[rptr[AW-1:0]];

    always @(posedge clk) begin
        if (rst) begin
            wptr <= {PTR_W{1'b0}};
            rptr <= {PTR_W{1'b0}};
        end else begin
            if (push) begin
                addr_mem[wptr[AW-1:0]] <= wr_addr;
                data_mem[wptr[AW-1:0]] <= wr_data;
                wptr <= wptr + 1'b1;
            end
            if (pop)
                rptr <= rptr + 1'b1;
        end
    end
endmodule

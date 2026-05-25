`timescale 1ns / 1ps

// Packet FIFO for post-activation OFM packets.
//
// This is a packet-level skid buffer between activation and byte writeback.
// It absorbs short downstream stalls before packets are expanded into bytes.
module ofm_packet_fifo #(
    parameter COUT_TILE = 64,
    parameter ADDR_W = 10,
    parameter DEPTH = 16,
    parameter AW = 4
) (
    input  clk,
    input  rst,

    input                       in_valid,
    output                      in_ready,
    input  [ADDR_W-1:0]         in_addr,
    input  [10:0]               in_cout_base,
    input  [COUT_TILE-1:0]      in_channel_valid,
    input  [COUT_TILE*8-1:0]    in_data,

    output                      out_valid,
    input                       out_ready,
    output [ADDR_W-1:0]         out_addr,
    output [10:0]               out_cout_base,
    output [COUT_TILE-1:0]      out_channel_valid,
    output [COUT_TILE*8-1:0]    out_data,
    output                      full,
    output                      almost_full
);
    localparam PTR_W = AW + 1;

    reg [ADDR_W-1:0] addr_mem [0:DEPTH-1];
    reg [10:0] cout_mem [0:DEPTH-1];
    reg [COUT_TILE-1:0] mask_mem [0:DEPTH-1];
    reg [COUT_TILE*8-1:0] data_mem [0:DEPTH-1];
    reg [PTR_W-1:0] wptr, rptr;

    wire empty = (wptr == rptr);
    wire fifo_full = (wptr[PTR_W-1] != rptr[PTR_W-1]) &&
                     (wptr[AW-1:0] == rptr[AW-1:0]);
    wire [PTR_W-1:0] level = wptr - rptr;
    wire pop = out_valid && out_ready;
    wire can_push = !fifo_full || pop;
    wire push = in_valid && can_push;

    assign in_ready = can_push;
    assign full = fifo_full;
    assign almost_full = (level >= (DEPTH - 2));
    assign out_valid = !empty;
    assign out_addr = addr_mem[rptr[AW-1:0]];
    assign out_cout_base = cout_mem[rptr[AW-1:0]];
    assign out_channel_valid = mask_mem[rptr[AW-1:0]];
    assign out_data = data_mem[rptr[AW-1:0]];

    always @(posedge clk) begin
        if (rst) begin
            wptr <= {PTR_W{1'b0}};
            rptr <= {PTR_W{1'b0}};
        end else begin
            if (push) begin
                addr_mem[wptr[AW-1:0]] <= in_addr;
                cout_mem[wptr[AW-1:0]] <= in_cout_base;
                mask_mem[wptr[AW-1:0]] <= in_channel_valid;
                data_mem[wptr[AW-1:0]] <= in_data;
                wptr <= wptr + 1'b1;
            end
            if (pop)
                rptr <= rptr + 1'b1;
        end
    end
endmodule

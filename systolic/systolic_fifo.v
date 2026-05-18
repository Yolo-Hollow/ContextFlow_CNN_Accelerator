`timescale 1ns / 1ps
// Generic FIFO with overflow/underflow protection + data_out reset
// Write silently ignored when full; read silently ignored when empty
module systolic_fifo #(
    parameter WIDTH = 8,
    parameter DEPTH = 256,          // must be power-of-2
    parameter AW    = 8             // clog2(DEPTH)
) (
    input  clk, rst,
    input  wr_en, rd_en,
    input  [WIDTH-1:0] data_in,
    output [WIDTH-1:0] data_out,
    output empty, full
);
    localparam PTR_W = AW + 1;

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_W-1:0] wptr, rptr;

    assign empty = (wptr == rptr);
    assign full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);

    // Internal gated enables: prevent overflow/underflow
    wire wren_int = wr_en && !full;
    wire rden_int = rd_en && !empty;

    // Write datapath (single always block avoids race)
    always @(posedge clk) begin
        if (rst) begin
            wptr <= {PTR_W{1'b0}};
        end else if (wren_int) begin
            wptr <= wptr + 1'b1;
            mem[wptr[AW-1:0]] <= data_in;
        end
    end

    // Read datapath
    always @(posedge clk) begin
        if (rst) begin
            rptr <= {PTR_W{1'b0}};
        end else if (rden_int) begin
            rptr <= rptr + 1'b1;
        end
    end

    reg [WIDTH-1:0] data_out_reg;
    always @(posedge clk) begin
        if (rst)
            data_out_reg <= {WIDTH{1'b0}};
        else if (rden_int)
            data_out_reg <= mem[rptr[AW-1:0]];
    end
    assign data_out = data_out_reg;
endmodule

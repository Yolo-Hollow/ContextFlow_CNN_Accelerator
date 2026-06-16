`timescale 1ns / 1ps

// Two-bank partial-PSUM storage split by systolic output column.
//
// This is the storage primitive needed for column-granular partial-PSUM
// streaming. Unlike psum_pingpong_buffer, each column can be written and read
// independently, so a later K pass does not have to wait for a full
// COLS*2-channel packet to be assembled before consuming earlier columns.
module psum_column_pingpong_buffer #(
    parameter COLS   = 8,
    parameter DATA_W = 64,
    parameter DEPTH  = 1024,
    parameter AW     = 10
) (
    input  clk,
    input  rst,

    input  [COLS-1:0]             wr_en,
    input                         wr_bank,
    input  [COLS*AW-1:0]          wr_addr_flat,
    input  [COLS*DATA_W-1:0]      wr_data_flat,

    input  [COLS-1:0]             rd_en,
    input                         rd_bank,
    input  [COLS*AW-1:0]          rd_addr_flat,
    output [COLS*DATA_W-1:0]      rd_data_flat,
    output reg [COLS-1:0]         rd_valid
);
    genvar c;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : col_mem
            wire [AW-1:0] wr_addr =
                wr_addr_flat[(c+1)*AW-1 -: AW];
            wire [AW-1:0] rd_addr =
                rd_addr_flat[(c+1)*AW-1 -: AW];
            wire [DATA_W-1:0] wr_data =
                wr_data_flat[(c+1)*DATA_W-1 -: DATA_W];

            (* ram_style = "block" *)
            reg [DATA_W-1:0] bank0 [0:DEPTH-1];
            (* ram_style = "block" *)
            reg [DATA_W-1:0] bank1 [0:DEPTH-1];
            reg [DATA_W-1:0] rd_q;

            always @(posedge clk) begin
                if (wr_en[c] && !wr_bank)
                    bank0[wr_addr] <= wr_data;
                if (wr_en[c] && wr_bank)
                    bank1[wr_addr] <= wr_data;

                if (rd_en[c])
                    rd_q <= rd_bank ? bank1[rd_addr] : bank0[rd_addr];
            end

            assign rd_data_flat[(c+1)*DATA_W-1 -: DATA_W] = rd_q;
        end
    endgenerate

    always @(posedge clk) begin
        if (rst)
            rd_valid <= {COLS{1'b0}};
        else
            rd_valid <= rd_en;
    end
endmodule

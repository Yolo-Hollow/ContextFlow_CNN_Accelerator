`timescale 1ns / 1ps

// Two-bank PSUM storage for K-tile feedback.
// The scheduler chooses which bank to read and which bank to write.
module psum_pingpong_buffer #(
    parameter DATA_W = 256,
    parameter DEPTH  = 16,
    parameter AW     = 4
) (
    input  clk,
    input  rst,

    input              wr_en,
    input              wr_bank,
    input  [AW-1:0]    wr_addr,
    input  [DATA_W-1:0] wr_data,

    input              rd_en,
    input              rd_bank,
    input  [AW-1:0]    rd_addr,
    output [DATA_W-1:0] rd_data,
    output reg         rd_valid
);
    localparam LANE_W = 64;
    localparam LANES = DATA_W / LANE_W;

    initial begin
        if ((DATA_W % LANE_W) != 0)
            $error("psum_pingpong_buffer DATA_W must be a multiple of 64");
    end

    wire [DATA_W-1:0] bank0_rd_data;
    wire [DATA_W-1:0] bank1_rd_data;
    reg rd_bank_q;

    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : lane_mem
            (* ram_style = "block" *)
            reg [LANE_W-1:0] bank0 [0:DEPTH-1];
            (* ram_style = "block" *)
            reg [LANE_W-1:0] bank1 [0:DEPTH-1];
            reg [LANE_W-1:0] bank0_q;
            reg [LANE_W-1:0] bank1_q;

            always @(posedge clk) begin
                if (wr_en && !wr_bank)
                    bank0[wr_addr] <= wr_data[(lane+1)*LANE_W-1 -: LANE_W];
                if (rd_en && !rd_bank)
                    bank0_q <= bank0[rd_addr];
            end

            always @(posedge clk) begin
                if (wr_en && wr_bank)
                    bank1[wr_addr] <= wr_data[(lane+1)*LANE_W-1 -: LANE_W];
                if (rd_en && rd_bank)
                    bank1_q <= bank1[rd_addr];
            end

            assign bank0_rd_data[(lane+1)*LANE_W-1 -: LANE_W] = bank0_q;
            assign bank1_rd_data[(lane+1)*LANE_W-1 -: LANE_W] = bank1_q;
        end
    endgenerate

    assign rd_data = rd_bank_q ? bank1_rd_data : bank0_rd_data;

    always @(posedge clk) begin
        if (rst) begin
            rd_valid <= 1'b0;
            rd_bank_q <= 1'b0;
        end else begin
            rd_valid <= rd_en;
            if (rd_en)
                rd_bank_q <= rd_bank;
        end
    end
endmodule

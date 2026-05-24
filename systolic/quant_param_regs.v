`timescale 1ns / 1ps
// Per-output-lane quantization parameter registers for one COUT tile.
//
// cfg_addr selects lane [0, COUT_TILE-1].
// cfg_wdata layout:
//   [15:0]  mult
//   [19:16] shift
//   [31:24] zp
module quant_param_regs #(
    parameter COUT_TILE = 64,
    parameter MULT_W = 16,
    parameter SHIFT_W = 4,
    parameter ZP_W = 8,
    parameter ADDR_W = 6
) (
    input  clk,
    input  rst,
    input  wr_en,
    input  [ADDR_W-1:0] wr_addr,
    input  [31:0] wr_data,
    input  [ADDR_W-1:0] rd_addr,
    output [31:0] rd_data,

    output [COUT_TILE*MULT_W-1:0]  mult_flat,
    output [COUT_TILE*SHIFT_W-1:0] shift_flat,
    output [COUT_TILE*ZP_W-1:0]    zp_flat
);
    reg [MULT_W-1:0] mult_mem [0:COUT_TILE-1];
    reg [SHIFT_W-1:0] shift_mem [0:COUT_TILE-1];
    reg [ZP_W-1:0] zp_mem [0:COUT_TILE-1];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < COUT_TILE; i = i + 1) begin
                mult_mem[i] <= {{(MULT_W-1){1'b0}}, 1'b1};
                shift_mem[i] <= {SHIFT_W{1'b0}};
                zp_mem[i] <= {ZP_W{1'b0}};
            end
        end else if (wr_en) begin
            mult_mem[wr_addr] <= wr_data[15:0];
            shift_mem[wr_addr] <= wr_data[16 +: SHIFT_W];
            zp_mem[wr_addr] <= wr_data[24 +: ZP_W];
        end
    end

    assign rd_data = {zp_mem[rd_addr], 4'd0, shift_mem[rd_addr], mult_mem[rd_addr]};

    genvar lane;
    generate
        for (lane = 0; lane < COUT_TILE; lane = lane + 1) begin : flat_gen
            assign mult_flat[lane*MULT_W +: MULT_W] = mult_mem[lane];
            assign shift_flat[lane*SHIFT_W +: SHIFT_W] = shift_mem[lane];
            assign zp_flat[lane*ZP_W +: ZP_W] = zp_mem[lane];
        end
    endgenerate
endmodule

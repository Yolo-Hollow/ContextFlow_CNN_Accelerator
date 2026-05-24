`timescale 1ns / 1ps

module tb_quant_param_regs;
    localparam COUT_TILE = 8;
    localparam MULT_W = 16;
    localparam SHIFT_W = 4;
    localparam ZP_W = 8;
    localparam ADDR_W = 3;

    reg clk, rst;
    reg wr_en;
    reg [ADDR_W-1:0] wr_addr;
    reg [31:0] wr_data;
    reg [ADDR_W-1:0] rd_addr;
    wire [31:0] rd_data;
    wire [COUT_TILE*MULT_W-1:0] mult_flat;
    wire [COUT_TILE*SHIFT_W-1:0] shift_flat;
    wire [COUT_TILE*ZP_W-1:0] zp_flat;

    quant_param_regs #(
        .COUT_TILE(COUT_TILE), .MULT_W(MULT_W), .SHIFT_W(SHIFT_W),
        .ZP_W(ZP_W), .ADDR_W(ADDR_W)
    ) dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_addr(rd_addr), .rd_data(rd_data),
        .mult_flat(mult_flat), .shift_flat(shift_flat), .zp_flat(zp_flat)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer lane;

    task write_lane;
        input integer idx;
        input [15:0] mult;
        input [3:0] shift;
        input [7:0] zp;
        begin
            @(negedge clk);
            wr_addr = idx[ADDR_W-1:0];
            wr_data = {zp, 4'd0, shift, mult};
            wr_en = 1'b1;
            @(negedge clk);
            wr_en = 1'b0;
        end
    endtask

    task check_lane;
        input integer idx;
        input [15:0] mult;
        input [3:0] shift;
        input [7:0] zp;
        begin
            if (mult_flat[idx*MULT_W +: MULT_W] !== mult) begin
                $display("[FAIL] lane%0d mult got=%0d exp=%0d", idx, mult_flat[idx*MULT_W +: MULT_W], mult);
                fail = fail + 1;
            end else pass = pass + 1;
            if (shift_flat[idx*SHIFT_W +: SHIFT_W] !== shift) begin
                $display("[FAIL] lane%0d shift got=%0d exp=%0d", idx, shift_flat[idx*SHIFT_W +: SHIFT_W], shift);
                fail = fail + 1;
            end else pass = pass + 1;
            if (zp_flat[idx*ZP_W +: ZP_W] !== zp) begin
                $display("[FAIL] lane%0d zp got=%0d exp=%0d", idx, zp_flat[idx*ZP_W +: ZP_W], zp);
                fail = fail + 1;
            end else pass = pass + 1;
            rd_addr = idx[ADDR_W-1:0];
            #1;
            if (rd_data !== {zp, 4'd0, shift, mult}) begin
                $display("[FAIL] lane%0d rd got=%h exp=%h", idx, rd_data, {zp, 4'd0, shift, mult});
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        wr_en = 0;
        wr_addr = 0;
        wr_data = 0;
        rd_addr = 0;
        pass = 0;
        fail = 0;

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        for (lane = 0; lane < COUT_TILE; lane = lane + 1)
            check_lane(lane, 16'd1, 4'd0, 8'd0);

        write_lane(0, 16'd123, 4'd5, 8'd7);
        write_lane(7, 16'd456, 4'd2, 8'd9);
        check_lane(0, 16'd123, 4'd5, 8'd7);
        check_lane(7, 16'd456, 4'd2, 8'd9);
        check_lane(3, 16'd1, 4'd0, 8'd0);

        $display("=== tb_quant_param_regs: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

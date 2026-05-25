`timescale 1ns / 1ps

module tb_ofm_writeback;
    localparam COUT_TILE = 8;
    localparam PIXEL_AW = 4;
    localparam ADDR_W = 12;
    localparam FIFO_DEPTH = 8;
    localparam FIFO_AW = 3;
    localparam COUT_TOTAL = 10;

    reg clk, rst;
    reg packet_valid;
    reg [PIXEL_AW-1:0] packet_pixel;
    reg [10:0] packet_cout_base;
    reg [COUT_TILE-1:0] packet_channel_valid;
    reg [COUT_TILE*8-1:0] packet_data;
    wire packet_full;
    reg wr_ready;
    wire wr_en;
    wire [ADDR_W-1:0] wr_addr;
    wire [7:0] wr_data;
    wire busy;

    ofm_writeback #(
        .COUT_TILE(COUT_TILE), .PIXEL_AW(PIXEL_AW), .ADDR_W(ADDR_W),
        .FIFO_DEPTH(FIFO_DEPTH), .FIFO_AW(FIFO_AW)
    ) dut (
        .clk(clk), .rst(rst),
        .packet_valid(packet_valid), .packet_pixel(packet_pixel),
        .packet_cout_base(packet_cout_base),
        .packet_channel_valid(packet_channel_valid), .packet_data(packet_data),
        .packet_full(packet_full), .cout_total(11'd10), .pixel_base({ADDR_W{1'b0}}),
        .wr_en(wr_en), .wr_ready(wr_ready),
        .wr_addr(wr_addr), .wr_data(wr_data), .busy(busy)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer i;
    integer wr_count;
    reg [7:0] mem [0:63];

    task send_packet;
        input integer pixel;
        input integer cout_base;
        input [COUT_TILE-1:0] mask;
        integer lane;
        begin
            packet_pixel = pixel[PIXEL_AW-1:0];
            packet_cout_base = cout_base[10:0];
            packet_channel_valid = mask;
            for (lane = 0; lane < COUT_TILE; lane = lane + 1)
                packet_data[lane*8 +: 8] = pixel*32 + cout_base + lane;
            packet_valid = 1'b1;
            @(negedge clk);
            packet_valid = 1'b0;
        end
    endtask

    task expect_mem;
        input integer addr;
        input integer exp;
        begin
            if (mem[addr] !== exp[7:0]) begin
                $display("[FAIL] mem[%0d] got=%0d exp=%0d", addr, mem[addr], exp[7:0]);
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    always @(negedge clk) begin
        if (!rst && wr_en) begin
            mem[wr_addr] <= wr_data;
            wr_count <= wr_count + 1;
        end
    end

    initial begin
        clk = 0;
        rst = 1;
        packet_valid = 0;
        packet_pixel = 0;
        packet_cout_base = 0;
        packet_channel_valid = 0;
        packet_data = 0;
        wr_ready = 1'b1;
        pass = 0;
        fail = 0;
        wr_count = 0;
        for (i = 0; i < 64; i = i + 1)
            mem[i] = 8'hxx;

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        send_packet(0, 0, 8'b1111_1111);
        send_packet(0, 8, 8'b0000_0011);
        send_packet(1, 0, 8'b1111_1111);
        send_packet(1, 8, 8'b0000_0011);

        wait(wr_count == 20);
        repeat (2) @(negedge clk);

        if (packet_full !== 1'b0) begin
            $display("[FAIL] unexpected packet_full");
            fail = fail + 1;
        end else pass = pass + 1;
        if (wr_count != 20) begin
            $display("[FAIL] wr_count got=%0d exp=20", wr_count);
            fail = fail + 1;
        end else pass = pass + 1;

        for (i = 0; i < COUT_TOTAL; i = i + 1) begin
            expect_mem(i, i);
            expect_mem(COUT_TOTAL + i, 32 + i);
        end

        $display("=== tb_ofm_writeback: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (500) @(negedge clk);
        $display("[FAIL] timeout wr_count=%0d busy=%0d full=%0d", wr_count, busy, packet_full);
        $fatal(1);
    end
endmodule

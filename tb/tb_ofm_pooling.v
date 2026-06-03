`timescale 1ns / 1ps

module tb_ofm_pooling;
    localparam COUT_TILE = 4;
    localparam ADDR_W = 5;
    localparam OFM_W_MAX = 8;

    reg clk, rst;
    reg pool_enable;
    reg [1:0] pool_stride;
    reg [8:0] conv_ofm_w;
    reg in_valid;
    wire in_ready;
    reg [ADDR_W-1:0] in_addr;
    reg [10:0] in_cout_base;
    reg [COUT_TILE-1:0] in_channel_valid;
    reg [COUT_TILE*8-1:0] in_data;
    wire out_valid;
    reg out_ready;
    wire [ADDR_W-1:0] out_addr;
    wire [10:0] out_cout_base;
    wire [COUT_TILE-1:0] out_channel_valid;
    wire [COUT_TILE*8-1:0] out_data;

    ofm_pooling #(
        .COUT_TILE(COUT_TILE), .ADDR_W(ADDR_W), .OFM_W_MAX(OFM_W_MAX)
    ) dut (
        .clk(clk), .rst(rst),
        .pool_enable(pool_enable), .pool_stride(pool_stride), .conv_ofm_w(conv_ofm_w),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_addr(in_addr), .in_cout_base(in_cout_base),
        .in_channel_valid(in_channel_valid), .in_data(in_data),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_addr(out_addr), .out_cout_base(out_cout_base),
        .out_channel_valid(out_channel_valid), .out_data(out_data)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer lane;
    integer pkt;

    function [7:0] pix_val;
        input integer y;
        input integer x;
        input integer l;
        begin
            pix_val = (y * 37 + x * 11 + l * 5) & 8'hff;
        end
    endfunction

    function [7:0] max4;
        input [7:0] a;
        input [7:0] b;
        input [7:0] c;
        input [7:0] d;
        reg [7:0] m0, m1;
        begin
            m0 = (a > b) ? a : b;
            m1 = (c > d) ? c : d;
            max4 = (m0 > m1) ? m0 : m1;
        end
    endfunction

    task check;
        input cond;
        input [127:0] name;
        begin
            if (!cond) begin
                $display("[FAIL] %0s", name);
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    task make_packet;
        input integer addr;
        output [COUT_TILE*8-1:0] data_o;
        integer y, x, l;
        begin
            y = addr / 4;
            x = addr % 4;
            data_o = {COUT_TILE*8{1'b0}};
            for (l = 0; l < COUT_TILE; l = l + 1)
                data_o[l*8 +: 8] = pix_val(y, x, l);
        end
    endtask

    task send_packet;
        input integer addr;
        input [10:0] cout_base;
        input [COUT_TILE-1:0] mask;
        reg [COUT_TILE*8-1:0] data_tmp;
        begin
            make_packet(addr, data_tmp);
            @(negedge clk);
            in_addr = addr[ADDR_W-1:0];
            in_cout_base = cout_base;
            in_channel_valid = mask;
            in_data = data_tmp;
            in_valid = 1'b1;
            wait(in_ready);
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task expect_bypass;
        input integer addr;
        reg [COUT_TILE*8-1:0] data_tmp;
        begin
            make_packet(addr, data_tmp);
            send_packet(addr, 11'd12, 4'b1011);
            wait(out_valid);
            #1;
            check(out_addr == addr[ADDR_W-1:0], "bypass addr");
            check(out_cout_base == 11'd12, "bypass cout");
            check(out_channel_valid == 4'b1011, "bypass mask");
            for (lane = 0; lane < COUT_TILE; lane = lane + 1)
                check(out_data[lane*8 +: 8] == data_tmp[lane*8 +: 8], "bypass data");
            @(negedge clk);
        end
    endtask

    task expect_pool_output;
        input integer out_idx;
        input integer py;
        input integer px;
        reg [7:0] exp;
        begin
            wait(out_valid);
            #1;
            check(out_addr == out_idx[ADDR_W-1:0], "pool addr");
            check(out_cout_base == 11'd20, "pool cout");
            check(out_channel_valid == 4'b1111, "pool mask");
            for (lane = 0; lane < COUT_TILE; lane = lane + 1) begin
                exp = max4(
                    pix_val(py*2,   px*2,   lane),
                    pix_val(py*2,   px*2+1, lane),
                    pix_val(py*2+1, px*2,   lane),
                    pix_val(py*2+1, px*2+1, lane)
                );
                check(out_data[lane*8 +: 8] == exp, "pool data");
            end
            @(negedge clk);
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        pool_enable = 1'b0;
        pool_stride = 2'd0;
        conv_ofm_w = 9'd4;
        in_valid = 1'b0;
        in_addr = {ADDR_W{1'b0}};
        in_cout_base = 11'd0;
        in_channel_valid = {COUT_TILE{1'b0}};
        in_data = {COUT_TILE*8{1'b0}};
        out_ready = 1'b1;
        pass = 0;
        fail = 0;

        repeat (4) @(negedge clk);
        rst = 0;

        $display("=== bypass ===");
        expect_bypass(3);

        $display("=== 2x2 stride2 pool 4x4 -> 2x2 ===");
        pool_enable = 1'b1;
        pool_stride = 2'd2;
        for (pkt = 0; pkt < 16; pkt = pkt + 1) begin
            send_packet(pkt, 11'd20, 4'b1111);
            if (pkt == 5)
                expect_pool_output(0, 0, 0);
            else if (pkt == 7)
                expect_pool_output(1, 0, 1);
            else if (pkt == 13)
                expect_pool_output(2, 1, 0);
            else if (pkt == 15)
                expect_pool_output(3, 1, 1);
            else begin
                #1;
                check(out_valid == 1'b0, "no output on non-bottom-right packet");
            end
        end

        $display("=== output backpressure ===");
        @(negedge clk);
        rst = 1;
        @(negedge clk);
        rst = 0;
        pool_enable = 1'b1;
        pool_stride = 2'd2;
        out_ready = 1'b0;
        for (pkt = 0; pkt < 5; pkt = pkt + 1)
            send_packet(pkt, 11'd9, 4'b1111);
        @(negedge clk);
        in_addr = 5;
        make_packet(5, in_data);
        in_cout_base = 11'd9;
        in_channel_valid = 4'b1111;
        in_valid = 1'b1;
        @(negedge clk);
        check(out_valid == 1'b1, "held pooled output valid");
        check(in_ready == 1'b0, "input stalls while pooled output held");
        out_ready = 1'b1;
        @(negedge clk);
        in_valid = 1'b0;
        check(out_valid == 1'b0 || out_ready == 1'b1, "backpressure released");

        $display("=== tb_ofm_pooling: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

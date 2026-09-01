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
    wire in_addr_zero = (in_addr == {ADDR_W{1'b0}});
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
        .in_addr(in_addr), .in_addr_zero(in_addr_zero),
        .in_cout_base(in_cout_base),
        .in_channel_valid(in_channel_valid), .in_data(in_data),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_addr(out_addr), .out_cout_base(out_cout_base),
        .out_channel_valid(out_channel_valid), .out_data(out_data)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer lane;
    integer pkt;
    integer hold_cycle;
    reg [ADDR_W-1:0] held_out_addr;
    reg [10:0] held_out_cout_base;
    reg [COUT_TILE-1:0] held_out_channel_valid;
    reg [COUT_TILE*8-1:0] held_out_data;
    reg [8:0] held_x_cnt;
    reg [8:0] held_y_cnt;

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

    task make_constant_packet;
        input integer base;
        output [COUT_TILE*8-1:0] data_o;
        integer l;
        begin
            data_o = {COUT_TILE*8{1'b0}};
            for (l = 0; l < COUT_TILE; l = l + 1)
                data_o[l*8 +: 8] = (base + l) & 8'hff;
        end
    endtask

    task send_payload;
        input [ADDR_W-1:0] addr_i;
        input [10:0] cout_base;
        input [COUT_TILE-1:0] mask;
        input [COUT_TILE*8-1:0] data_i;
        begin
            @(negedge clk);
            in_addr = addr_i;
            in_cout_base = cout_base;
            in_channel_valid = mask;
            in_data = data_i;
            in_valid = 1'b1;
            wait(in_ready);
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task send_packet;
        input integer addr;
        input [10:0] cout_base;
        input [COUT_TILE-1:0] mask;
        reg [COUT_TILE*8-1:0] data_tmp;
        begin
            make_packet(addr, data_tmp);
            send_payload(addr[ADDR_W-1:0], cout_base, mask, data_tmp);
        end
    endtask

    task send_constant_packet;
        input integer addr;
        input integer base;
        input [10:0] cout_base;
        input [COUT_TILE-1:0] mask;
        reg [COUT_TILE*8-1:0] data_tmp;
        begin
            make_constant_packet(base, data_tmp);
            send_payload(addr[ADDR_W-1:0], cout_base, mask, data_tmp);
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

    task check_pool_now;
        input integer out_idx;
        input integer py;
        input integer px;
        input [10:0] cout_base;
        input [COUT_TILE-1:0] mask;
        integer l;
        reg [7:0] exp;
        begin
            check(out_valid == 1'b1, "pool output valid");
            check(out_addr == out_idx[ADDR_W-1:0], "pool addr");
            check(out_cout_base == cout_base, "pool cout");
            check(out_channel_valid == mask, "pool mask");
            for (l = 0; l < COUT_TILE; l = l + 1) begin
                exp = max4(
                    pix_val(py*2,   px*2,   l),
                    pix_val(py*2,   px*2+1, l),
                    pix_val(py*2+1, px*2,   l),
                    pix_val(py*2+1, px*2+1, l)
                );
                check(out_data[l*8 +: 8] == exp, "pool data");
            end
        end
    endtask

    task expect_pool_output;
        input integer out_idx;
        input integer py;
        input integer px;
        begin
            wait(out_valid);
            #1;
            check_pool_now(out_idx, py, px, 11'd20, 4'b1111);
            @(negedge clk);
        end
    endtask

    task reset_stream;
        begin
            @(negedge clk);
            rst = 1'b1;
            in_valid = 1'b0;
            out_ready = 1'b1;
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    task run_continuous_4x4;
        integer p;
        reg [COUT_TILE*8-1:0] data_tmp;
        begin
            @(negedge clk);
            in_valid = 1'b1;
            in_cout_base = 11'd20;
            in_channel_valid = 4'b1111;
            for (p = 0; p < 16; p = p + 1) begin
                make_packet(p, data_tmp);
                in_addr = p[ADDR_W-1:0];
                in_data = data_tmp;
                #1;
                check(in_ready == 1'b1, "continuous input ready");
                @(posedge clk);
                #1;
                if (p == 5)
                    check_pool_now(0, 0, 0, 11'd20, 4'b1111);
                else if (p == 7)
                    check_pool_now(1, 0, 1, 11'd20, 4'b1111);
                else if (p == 13)
                    check_pool_now(2, 1, 0, 11'd20, 4'b1111);
                else if (p == 15)
                    check_pool_now(3, 1, 1, 11'd20, 4'b1111);
                else
                    check(out_valid == 1'b0,
                          "continuous non-bottom-right quiet");
                @(negedge clk);
            end
            in_valid = 1'b0;
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
        expect_bypass(0);
        expect_bypass(3);
        pool_enable = 1'b1;
        pool_stride = 2'd1;
        expect_bypass(7);

        $display("=== continuous 2x2 stride2 pool, two output rows ===");
        reset_stream();
        pool_enable = 1'b1;
        pool_stride = 2'd2;
        run_continuous_4x4();

        $display("=== repeated addr0 resync at stale bottom-right ===");
        reset_stream();
        pool_enable = 1'b1;
        pool_stride = 2'd2;
        // Stop immediately before the old frame's first bottom-right pixel.
        send_constant_packet(0, 200, 11'd30, 4'b1111);
        send_constant_packet(1, 210, 11'd30, 4'b1111);
        send_constant_packet(2, 220, 11'd30, 4'b1111);
        send_constant_packet(3, 230, 11'd30, 4'b1111);
        send_constant_packet(4, 190, 11'd30, 4'b1111);
        #1;
        check(out_valid == 1'b0, "pre-resync produces no output");
        check(dut.x_cnt == 9'd1 && dut.y_cnt == 9'd1,
              "pre-resync stale bottom-right position");

        // Both address-zero packets are first-pixel resyncs.  The first one
        // arrives while registered x/y names a bottom-right pixel and must
        // still suppress the stale pooled result; the second must restart in
        // place rather than advancing to column two.
        send_constant_packet(0, 10, 11'd31, 4'b1011);
        #1;
        check(out_valid == 1'b0, "addr0 suppresses stale bottom-right output");
        check(dut.x_cnt == 9'd1 && dut.y_cnt == 9'd0,
              "addr0 restarts registered position");
        send_constant_packet(0, 12, 11'd32, 4'b0111);
        #1;
        check(out_valid == 1'b0, "repeated addr0 produces no output");
        check(dut.x_cnt == 9'd1 && dut.y_cnt == 9'd0,
              "repeated addr0 remains first-pixel position");
        for (lane = 0; lane < COUT_TILE; lane = lane + 1)
            check(dut.top_row_data[0][lane*8 +: 8] == ((12 + lane) & 8'hff),
                  "repeated addr0 replaces top-row column zero");

        send_constant_packet(1, 20, 11'd33, 4'b1101);
        send_constant_packet(2, 5,  11'd33, 4'b1101);
        send_constant_packet(3, 6,  11'd33, 4'b1101);
        send_constant_packet(4, 30, 11'd33, 4'b1101);
        send_constant_packet(5, 40, 11'd33, 4'b1101);
        wait(out_valid);
        #1;
        check(out_addr == {ADDR_W{1'b0}}, "resync pooled addr");
        check(out_cout_base == 11'd33, "resync pooled cout");
        check(out_channel_valid == 4'b1101, "resync pooled mask");
        for (lane = 0; lane < COUT_TILE; lane = lane + 1)
            check(out_data[lane*8 +: 8] == ((40 + lane) & 8'hff),
                  "resync pooled data uses replacement row");

        $display("=== output backpressure ===");
        reset_stream();
        pool_enable = 1'b1;
        pool_stride = 2'd2;
        out_ready = 1'b0;
        for (pkt = 0; pkt < 6; pkt = pkt + 1)
            send_packet(pkt, 11'd9, 4'b1111);
        #1;
        check_pool_now(0, 0, 0, 11'd9, 4'b1111);
        held_out_addr = out_addr;
        held_out_cout_base = out_cout_base;
        held_out_channel_valid = out_channel_valid;
        held_out_data = out_data;
        held_x_cnt = dut.x_cnt;
        held_y_cnt = dut.y_cnt;

        // Present the next packet while the pooled result is blocked.  No
        // internal coordinate or output payload may move until out_ready.
        @(negedge clk);
        in_addr = 6;
        make_packet(6, in_data);
        in_cout_base = 11'd9;
        in_channel_valid = 4'b1111;
        in_valid = 1'b1;
        for (hold_cycle = 0; hold_cycle < 3; hold_cycle = hold_cycle + 1) begin
            @(posedge clk);
            #1;
            check(out_valid == 1'b1, "held pooled output valid");
            check(in_ready == 1'b0, "input stalls while pooled output held");
            check(out_addr == held_out_addr &&
                  out_cout_base == held_out_cout_base &&
                  out_channel_valid == held_out_channel_valid &&
                  out_data == held_out_data,
                  "held pooled output payload stable");
            check(dut.x_cnt == held_x_cnt && dut.y_cnt == held_y_cnt,
                  "pool position stable under backpressure");
        end

        @(negedge clk);
        out_ready = 1'b1;
        #1;
        check(in_ready == 1'b1, "input ready with output release");
        @(posedge clk);
        #1;
        check(out_valid == 1'b0, "held output consumed with packet six");
        check(dut.x_cnt == 9'd3 && dut.y_cnt == 9'd1,
              "packet six advances exactly once");
        @(negedge clk);
        in_valid = 1'b0;
        send_packet(7, 11'd9, 4'b1111);
        wait(out_valid);
        #1;
        check_pool_now(1, 0, 1, 11'd9, 4'b1111);

        $display("=== tb_ofm_pooling: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

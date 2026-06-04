`timescale 1ns / 1ps

module tb_ofm_requant_writer;
    localparam COLS = 4;
    localparam PSUM_W = 32;
    localparam MULT_W = 16;
    localparam SHIFT_W = 4;
    localparam ZP_W = 8;
    localparam ADDR_W = 4;

    reg clk, rst;
    reg packet_valid;
    reg [ADDR_W-1:0] packet_addr;
    reg [10:0] packet_cout_base;
    reg [COLS*2-1:0] packet_channel_valid;
    reg [COLS*2*PSUM_W-1:0] packet_data;
    reg [COLS*2*MULT_W-1:0] mult_flat;
    reg [COLS*2*SHIFT_W-1:0] shift_flat;
    reg [COLS*2*ZP_W-1:0] zp_flat;
    wire packet_ready;
    wire ofm_valid;
    reg ofm_ready;
    wire [ADDR_W-1:0] ofm_addr;
    wire [10:0] ofm_cout_base;
    wire [COLS*2-1:0] ofm_channel_valid;
    wire [COLS*2*8-1:0] ofm_data;

    ofm_requant_writer #(
        .COLS(COLS), .PSUM_W(PSUM_W), .MULT_W(MULT_W), .SHIFT_W(SHIFT_W),
        .ZP_W(ZP_W), .ADDR_W(ADDR_W)
    ) dut (
        .clk(clk), .rst(rst),
        .packet_valid(packet_valid), .packet_ready(packet_ready), .packet_addr(packet_addr),
        .packet_cout_base(packet_cout_base), .packet_channel_valid(packet_channel_valid),
        .packet_data(packet_data),
        .mult_flat(mult_flat), .shift_flat(shift_flat), .zp_flat(zp_flat),
        .ofm_ready(ofm_ready),
        .ofm_valid(ofm_valid), .ofm_addr(ofm_addr),
        .ofm_cout_base(ofm_cout_base), .ofm_channel_valid(ofm_channel_valid),
        .ofm_data(ofm_data)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer i;

    function [7:0] golden;
        input signed [PSUM_W-1:0] p;
        input [MULT_W-1:0] m;
        input [SHIFT_W-1:0] sh;
        input [ZP_W-1:0] zp;
        reg signed [63:0] v;
        reg signed [63:0] rnd;
        integer effective_shift;
        begin
            effective_shift = sh + 15;
            v = p * $signed({1'b0, m});
            rnd = 64'sd1 <<< (effective_shift - 1);
            v = (v + rnd) >>> effective_shift;
            v = v + $signed({1'b0, zp});
            if (v > 127) golden = 8'd127;
            else if (v < -128) golden = 8'd128;
            else golden = v[7:0];
        end
    endfunction

    task check_byte;
        input integer lane;
        reg [7:0] got;
        reg [7:0] exp;
        begin
            got = ofm_data[lane*8 +: 8];
            exp = golden(packet_data[lane*PSUM_W +: PSUM_W],
                         mult_flat[lane*MULT_W +: MULT_W],
                         shift_flat[lane*SHIFT_W +: SHIFT_W],
                         zp_flat[lane*ZP_W +: ZP_W]);
            if (got !== exp) begin
                $display("[FAIL] lane%0d got=%0d exp=%0d", lane, got, exp);
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    task check_identity_negative;
        integer lane;
        begin
            packet_data = {COLS*2*PSUM_W{1'b0}};
            mult_flat = {COLS*2*MULT_W{1'b0}};
            shift_flat = {COLS*2*SHIFT_W{1'b0}};
            zp_flat = {COLS*2*ZP_W{1'b0}};
            for (lane = 0; lane < COLS*2; lane = lane + 1) begin
                packet_data[lane*PSUM_W +: PSUM_W] = (lane[0] ? -32'sd29 : -32'sd128) + lane;
                mult_flat[lane*MULT_W +: MULT_W] = 16'd32767;
                shift_flat[lane*SHIFT_W +: SHIFT_W] = 4'd0;
                zp_flat[lane*ZP_W +: ZP_W] = 8'd0;
            end

            packet_addr = 4'd2;
            packet_cout_base = 11'd0;
            packet_channel_valid = {COLS*2{1'b1}};
            ofm_ready = 1'b1;
            wait(packet_ready);
            @(negedge clk);
            packet_valid = 1'b1;
            @(negedge clk);
            packet_valid = 1'b0;

            wait(ofm_valid);
            #1;
            for (lane = 0; lane < COLS*2; lane = lane + 1)
                check_byte(lane);

            @(posedge clk);
            @(posedge clk);
            #1;
            if (ofm_valid !== 1'b0) begin
                $display("[FAIL] identity negative valid did not clear");
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    task make_packet;
        input integer pkt;
        output [ADDR_W-1:0] addr_o;
        output [10:0] cout_o;
        output [COLS*2-1:0] mask_o;
        output [COLS*2*PSUM_W-1:0] data_o;
        integer lane;
        begin
            addr_o = 4'd3 + pkt[ADDR_W-1:0];
            cout_o = 11'd16 + pkt[10:0];
            mask_o = 8'ha5 ^ pkt[7:0];
            data_o = {COLS*2*PSUM_W{1'b0}};
            for (lane = 0; lane < COLS*2; lane = lane + 1)
                data_o[lane*PSUM_W +: PSUM_W] =
                    (lane[0] ? -32'sd300 : 32'sd120) + pkt*32'sd31 + lane*32'sd19;
        end
    endtask

    task expect_packet;
        input integer pkt;
        reg [ADDR_W-1:0] exp_addr;
        reg [10:0] exp_cout;
        reg [COLS*2-1:0] exp_mask;
        reg [COLS*2*PSUM_W-1:0] exp_data;
        reg [7:0] exp;
        integer lane;
        begin
            make_packet(pkt, exp_addr, exp_cout, exp_mask, exp_data);
            if (ofm_valid !== 1'b1) begin
                $display("[FAIL] burst pkt%0d valid", pkt);
                fail = fail + 1;
            end else pass = pass + 1;
            if (ofm_addr !== exp_addr || ofm_cout_base !== exp_cout || ofm_channel_valid !== exp_mask) begin
                $display("[FAIL] burst pkt%0d metadata addr=%0d/%0d cout=%0d/%0d mask=%b/%b",
                         pkt, ofm_addr, exp_addr, ofm_cout_base, exp_cout,
                         ofm_channel_valid, exp_mask);
                fail = fail + 1;
            end else pass = pass + 1;
            for (lane = 0; lane < COLS*2; lane = lane + 1) begin
                exp = golden(exp_data[lane*PSUM_W +: PSUM_W],
                             mult_flat[lane*MULT_W +: MULT_W],
                             shift_flat[lane*SHIFT_W +: SHIFT_W],
                             zp_flat[lane*ZP_W +: ZP_W]);
                if (ofm_data[lane*8 +: 8] !== exp) begin
                    $display("[FAIL] burst pkt%0d lane%0d got=%0d exp=%0d",
                             pkt, lane, ofm_data[lane*8 +: 8], exp);
                    fail = fail + 1;
                end else pass = pass + 1;
            end
        end
    endtask

    task check_back_to_back;
        reg [ADDR_W-1:0] pkt_addr;
        reg [10:0] pkt_cout;
        reg [COLS*2-1:0] pkt_mask;
        reg [COLS*2*PSUM_W-1:0] pkt_data;
        integer pkt;
        integer exp_pkt;
        integer wait_count;
        begin
            repeat (2) @(negedge clk);
            pkt = 0;
            exp_pkt = 0;
            wait_count = 0;
            make_packet(0, pkt_addr, pkt_cout, pkt_mask, pkt_data);
            packet_valid = 1'b1;
            packet_addr = pkt_addr;
            packet_cout_base = pkt_cout;
            packet_channel_valid = pkt_mask;
            packet_data = pkt_data;
            pkt = 1;

            while (exp_pkt < 3 && wait_count < 16) begin
                @(negedge clk);
                #1;
                if (ofm_valid) begin
                    expect_packet(exp_pkt);
                    exp_pkt = exp_pkt + 1;
                end
                if (pkt < 3) begin
                    make_packet(pkt, pkt_addr, pkt_cout, pkt_mask, pkt_data);
                    packet_valid = 1'b1;
                    packet_addr = pkt_addr;
                    packet_cout_base = pkt_cout;
                    packet_channel_valid = pkt_mask;
                    packet_data = pkt_data;
                    pkt = pkt + 1;
                end else begin
                    packet_valid = 1'b0;
                end
                wait_count = wait_count + 1;
            end
            if (exp_pkt != 3) begin
                $display("[FAIL] burst output count got=%0d exp=3", exp_pkt);
                fail = fail + 1;
            end else pass = pass + 1;

            @(posedge clk);
            @(posedge clk);
            #1;
            if (ofm_valid !== 1'b0) begin
                $display("[FAIL] burst valid did not clear");
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    task check_output_backpressure;
        reg [ADDR_W-1:0] pkt_addr;
        reg [10:0] pkt_cout;
        reg [COLS*2-1:0] pkt_mask;
        reg [COLS*2*PSUM_W-1:0] pkt_data;
        reg [ADDR_W-1:0] hold_addr;
        reg [10:0] hold_cout;
        reg [COLS*2-1:0] hold_mask;
        reg [COLS*2*8-1:0] hold_data;
        begin
            repeat (3) @(negedge clk);
            ofm_ready = 1'b1;
            make_packet(4, pkt_addr, pkt_cout, pkt_mask, pkt_data);
            packet_valid = 1'b1;
            packet_addr = pkt_addr;
            packet_cout_base = pkt_cout;
            packet_channel_valid = pkt_mask;
            packet_data = pkt_data;
            @(negedge clk);
            packet_valid = 1'b0;

            wait(ofm_valid);
            #1;
            hold_addr = ofm_addr;
            hold_cout = ofm_cout_base;
            hold_mask = ofm_channel_valid;
            hold_data = ofm_data;
            ofm_ready = 1'b0;

            make_packet(5, pkt_addr, pkt_cout, pkt_mask, pkt_data);
            packet_valid = 1'b1;
            packet_addr = pkt_addr;
            packet_cout_base = pkt_cout;
            packet_channel_valid = pkt_mask;
            packet_data = pkt_data;
            repeat (3) begin
                @(negedge clk);
                #1;
                if (packet_ready !== 1'b0 || ofm_valid !== 1'b1 ||
                    ofm_addr !== hold_addr || ofm_cout_base !== hold_cout ||
                    ofm_channel_valid !== hold_mask || ofm_data !== hold_data) begin
                    $display("[FAIL] output changed or input ready during backpressure ready=%0d valid=%0d",
                        packet_ready, ofm_valid);
                    fail = fail + 1;
                end else pass = pass + 1;
            end

            ofm_ready = 1'b1;
            @(negedge clk);
            packet_valid = 1'b0;

            wait(ofm_valid && ofm_addr == pkt_addr);
            #1;
            expect_packet(5);
            @(posedge clk);
            @(posedge clk);
            #1;
            if (ofm_valid !== 1'b0) begin
                $display("[FAIL] backpressure valid did not clear");
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        packet_valid = 0;
        packet_addr = 0;
        packet_cout_base = 0;
        packet_channel_valid = 8'b0000_0011;
        packet_data = 0;
        ofm_ready = 1'b1;
        mult_flat = 0;
        shift_flat = 0;
        zp_flat = 0;
        pass = 0;
        fail = 0;

        for (i = 0; i < COLS*2; i = i + 1) begin
            packet_data[i*PSUM_W +: PSUM_W] = (i[0] ? -32'sd200 : 32'sd100) + i*32'sd17;
            mult_flat[i*MULT_W +: MULT_W] = 16'd64 + i;
            shift_flat[i*SHIFT_W +: SHIFT_W] = 4'd6;
            zp_flat[i*ZP_W +: ZP_W] = 8'd3 + i;
        end

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        packet_addr = 4'd7;
        packet_cout_base = 11'd8;
        packet_valid = 1'b1;
        @(negedge clk);
        packet_valid = 1'b0;

        wait(ofm_valid);
        #1;
        if (ofm_addr !== 4'd7) begin
            $display("[FAIL] addr got=%0d", ofm_addr);
            fail = fail + 1;
        end else pass = pass + 1;
        if (ofm_cout_base !== 11'd8) begin
            $display("[FAIL] cout_base got=%0d", ofm_cout_base);
            fail = fail + 1;
        end else pass = pass + 1;
        if (ofm_channel_valid !== 8'b0000_0011) begin
            $display("[FAIL] channel mask got=%b", ofm_channel_valid);
            fail = fail + 1;
        end else pass = pass + 1;
        for (i = 0; i < COLS*2; i = i + 1)
            check_byte(i);

        @(posedge clk);
        #1;
        if (ofm_valid !== 1'b0) begin
            $display("[FAIL] valid did not clear");
            fail = fail + 1;
        end else pass = pass + 1;

        check_identity_negative();

        check_back_to_back();
        check_output_backpressure();

        $display("=== tb_ofm_requant_writer: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (1000) @(negedge clk);
        $display("[FAIL] timeout valid=%0d", ofm_valid);
        $fatal(1);
    end
endmodule

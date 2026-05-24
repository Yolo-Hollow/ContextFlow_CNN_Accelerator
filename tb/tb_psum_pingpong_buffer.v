`timescale 1ns / 1ps

module tb_psum_pingpong_buffer;
    localparam DATA_W = 256;
    localparam DEPTH = 9;
    localparam AW = 4;

    reg clk, rst;
    reg wr_en, wr_bank;
    reg [AW-1:0] wr_addr;
    reg [DATA_W-1:0] wr_data;
    reg rd_en, rd_bank;
    reg [AW-1:0] rd_addr;
    wire [DATA_W-1:0] rd_data;
    wire rd_valid;

    psum_pingpong_buffer #(.DATA_W(DATA_W), .DEPTH(DEPTH), .AW(AW)) dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_bank(wr_bank), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_bank(rd_bank), .rd_addr(rd_addr),
        .rd_data(rd_data), .rd_valid(rd_valid)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer i;
    reg [DATA_W-1:0] pass0 [0:DEPTH-1];
    reg [DATA_W-1:0] pass1 [0:DEPTH-1];

    function [DATA_W-1:0] make_pkt;
        input integer base;
        integer j;
        begin
            make_pkt = 0;
            for (j = 0; j < 8; j = j + 1)
                make_pkt[j*32 +: 32] = base + j;
        end
    endfunction

    task idle_bus;
        begin
            wr_en = 1'b0;
            wr_bank = 1'b0;
            wr_addr = 0;
            wr_data = 0;
            rd_en = 1'b0;
            rd_bank = 1'b0;
            rd_addr = 0;
        end
    endtask

    task write_bank;
        input integer bank;
        input integer addr;
        input [DATA_W-1:0] data;
        begin
            wr_en = 1'b1;
            wr_bank = bank[0];
            wr_addr = addr[AW-1:0];
            wr_data = data;
            @(negedge clk);
            wr_en = 1'b0;
        end
    endtask

    task read_check;
        input integer bank;
        input integer addr;
        input [DATA_W-1:0] exp;
        begin
            rd_en = 1'b1;
            rd_bank = bank[0];
            rd_addr = addr[AW-1:0];
            @(negedge clk);
            if (rd_valid !== 1'b1) begin
                $display("[FAIL] read bank%0d addr%0d valid low", bank, addr);
                fail = fail + 1;
            end else if (rd_data !== exp) begin
                $display("[FAIL] read bank%0d addr%0d mismatch got=%h exp=%h",
                    bank, addr, rd_data, exp);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
            rd_en = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        pass = 0;
        fail = 0;
        idle_bus();

        for (i = 0; i < DEPTH; i = i + 1) begin
            pass0[i] = make_pkt(1000 + i*16);
            pass1[i] = make_pkt(2000 + i*16);
        end

        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        for (i = 0; i < DEPTH; i = i + 1)
            write_bank(0, i, pass0[i]);

        for (i = 0; i < DEPTH; i = i + 1)
            read_check(0, i, pass0[i]);

        // Simulate pass1: read bank A while writing bank B in the same cycle.
        for (i = 0; i < DEPTH; i = i + 1) begin
            rd_en = 1'b1;
            rd_bank = 1'b0;
            rd_addr = i[AW-1:0];
            wr_en = 1'b1;
            wr_bank = 1'b1;
            wr_addr = i[AW-1:0];
            wr_data = pass1[i];
            @(negedge clk);
            if (rd_valid !== 1'b1 || rd_data !== pass0[i]) begin
                $display("[FAIL] concurrent readA/writeB addr%0d got=%h exp=%h",
                    i, rd_data, pass0[i]);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
            rd_en = 1'b0;
            wr_en = 1'b0;
            @(negedge clk);
        end

        for (i = 0; i < DEPTH; i = i + 1)
            read_check(1, i, pass1[i]);

        $display("=== tb_psum_pingpong_buffer: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

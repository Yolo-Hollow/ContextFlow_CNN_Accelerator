`timescale 1ns / 1ps

module tb_psum_pingpong_buffer_bram;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg wr_en = 1'b0;
    reg wr_bank = 1'b0;
    reg [3:0] wr_addr = 4'd0;
    reg [127:0] wr_data = 128'd0;
    reg rd_en = 1'b0;
    reg rd_bank = 1'b0;
    reg [3:0] rd_addr = 4'd0;
    wire [127:0] rd_data;
    wire rd_valid;
    integer fail = 0;

    psum_pingpong_buffer #(.DATA_W(128), .DEPTH(16), .AW(4)) dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_bank(wr_bank), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_bank(rd_bank), .rd_addr(rd_addr),
        .rd_data(rd_data), .rd_valid(rd_valid)
    );

    always #5 clk = ~clk;

    task write_word;
        input bank;
        input [3:0] addr;
        input [127:0] data;
        begin
            @(negedge clk);
            wr_en = 1'b1; wr_bank = bank; wr_addr = addr; wr_data = data;
            @(negedge clk);
            wr_en = 1'b0;
        end
    endtask

    task read_check;
        input bank;
        input [3:0] addr;
        input [127:0] expected;
        begin
            @(negedge clk);
            rd_en = 1'b1; rd_bank = bank; rd_addr = addr;
            @(negedge clk);
            #1;
            if (!rd_valid || rd_data !== expected) begin
                $display("[FAIL] bank=%0d addr=%0d got=%h valid=%0d expected=%h",
                         bank, addr, rd_data, rd_valid, expected);
                fail = fail + 1;
            end
            rd_en = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        write_word(1'b0, 4'd3, 128'h00112233445566778899aabbccddeeff);
        write_word(1'b1, 4'd3, 128'hffeeddccbbaa99887766554433221100);
        read_check(1'b0, 4'd3, 128'h00112233445566778899aabbccddeeff);
        read_check(1'b1, 4'd3, 128'hffeeddccbbaa99887766554433221100);
        $display("=== tb_psum_pingpong_buffer_bram: %0d fail ===", fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

`timescale 1ns / 1ps

module tb_psum_stream_feeder;
    localparam DATA_W = 256;
    localparam DEPTH = 9;
    localparam AW = 4;

    reg clk, rst, start, compute_fire;
    reg is_first_pass, use_ext_psum;
    reg [DATA_W-1:0] bias_data;
    reg rd_bank;
    wire rd_en, rd_bank_out;
    wire [AW-1:0] rd_addr;
    wire [DATA_W-1:0] pp_rd_data;
    wire pp_rd_valid;
    wire [DATA_W-1:0] psum_top_data;
    wire psum_top_valid;
    wire [AW-1:0] pixel_addr;

    reg pp_wr_en, pp_wr_bank;
    reg [AW-1:0] pp_wr_addr;
    reg [DATA_W-1:0] pp_wr_data;

    psum_pingpong_buffer #(.DATA_W(DATA_W), .DEPTH(DEPTH), .AW(AW)) u_pp (
        .clk(clk), .rst(rst),
        .wr_en(pp_wr_en), .wr_bank(pp_wr_bank), .wr_addr(pp_wr_addr), .wr_data(pp_wr_data),
        .rd_en(rd_en), .rd_bank(rd_bank_out), .rd_addr(rd_addr),
        .rd_data(pp_rd_data), .rd_valid(pp_rd_valid)
    );

    psum_stream_feeder #(.DATA_W(DATA_W), .AW(AW)) dut (
        .clk(clk), .rst(rst), .start(start), .compute_fire(compute_fire),
        .is_first_pass(is_first_pass), .use_ext_psum(use_ext_psum), .bias_data(bias_data),
        .rd_bank(rd_bank), .rd_en(rd_en), .rd_bank_out(rd_bank_out), .rd_addr(rd_addr),
        .rd_data(pp_rd_data), .rd_valid(pp_rd_valid),
        .psum_top_data(psum_top_data), .psum_top_valid(psum_top_valid),
        .pixel_addr(pixel_addr)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer i;
    reg [DATA_W-1:0] partial [0:DEPTH-1];

    function [DATA_W-1:0] make_pkt;
        input integer base;
        integer j;
        begin
            make_pkt = 0;
            for (j = 0; j < 8; j = j + 1)
                make_pkt[j*32 +: 32] = base + j;
        end
    endfunction

    task start_pass;
        begin
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task load_bank0;
        begin
            for (i = 0; i < DEPTH; i = i + 1) begin
                pp_wr_en = 1'b1;
                pp_wr_bank = 1'b0;
                pp_wr_addr = i[AW-1:0];
                pp_wr_data = partial[i];
                @(negedge clk);
                pp_wr_en = 1'b0;
            end
        end
    endtask

    task check_bias_stream;
        begin
            start_pass();
            is_first_pass = 1'b1;
            use_ext_psum = 1'b0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                compute_fire = 1'b1;
                @(posedge clk);
                #1;
                compute_fire = 1'b0;
                if (psum_top_valid !== 1'b1 || psum_top_data !== bias_data) begin
                    $display("[FAIL] bias stream idx%0d valid=%0d got=%h exp=%h",
                        i, psum_top_valid, psum_top_data, bias_data);
                    fail = fail + 1;
                end else begin
                    pass = pass + 1;
                end
                @(negedge clk);
            end
            if (pixel_addr !== DEPTH[AW-1:0]) begin
                $display("[FAIL] bias pixel_addr got=%0d exp=%0d", pixel_addr, DEPTH);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
        end
    endtask

    task check_partial_stream;
        begin
            start_pass();
            is_first_pass = 1'b0;
            use_ext_psum = 1'b1;
            rd_bank = 1'b0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                compute_fire = 1'b1;
                #1;
                if (rd_en !== 1'b1 || rd_addr !== i[AW-1:0] || rd_bank_out !== 1'b0) begin
                    $display("[FAIL] rd request idx%0d en=%0d addr=%0d bank=%0d",
                        i, rd_en, rd_addr, rd_bank_out);
                    fail = fail + 1;
                end else begin
                    pass = pass + 1;
                end
                @(posedge clk);
                #1;
                compute_fire = 1'b0;
                if (psum_top_valid !== 1'b1 || psum_top_data !== partial[i]) begin
                    $display("[FAIL] partial stream idx%0d valid=%0d got=%h exp=%h",
                        i, psum_top_valid, psum_top_data, partial[i]);
                    fail = fail + 1;
                end else begin
                    pass = pass + 1;
                end
                @(negedge clk);
            end
            if (pixel_addr !== DEPTH[AW-1:0]) begin
                $display("[FAIL] partial pixel_addr got=%0d exp=%0d", pixel_addr, DEPTH);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        start = 0;
        compute_fire = 0;
        is_first_pass = 1'b1;
        use_ext_psum = 1'b0;
        bias_data = make_pkt(5000);
        rd_bank = 0;
        pp_wr_en = 0;
        pp_wr_bank = 0;
        pp_wr_addr = 0;
        pp_wr_data = 0;
        pass = 0;
        fail = 0;

        for (i = 0; i < DEPTH; i = i + 1)
            partial[i] = make_pkt(7000 + i*32);

        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        load_bank0();
        check_bias_stream();
        check_partial_stream();

        $display("=== tb_psum_stream_feeder: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

`timescale 1ns / 1ps

module tb_psum_column_stream;
    localparam COLS = 4;
    localparam DATA_W = 64;
    localparam DEPTH = 16;
    localparam AW = 4;
    localparam COL_DELAY = 4;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;
    reg compute_fire = 1'b0;
    reg use_ext_psum = 1'b0;
    reg rd_bank = 1'b0;
    reg overlap_guard_enable = 1'b0;
    reg [COLS*(AW+1)-1:0] available_count_flat = 0;

    reg [COLS-1:0] wr_en = 0;
    reg wr_bank = 1'b0;
    reg [COLS*AW-1:0] wr_addr_flat = 0;
    reg [COLS*DATA_W-1:0] wr_data_flat = 0;

    wire [COLS-1:0] rd_en;
    wire rd_bank_out;
    wire [COLS*AW-1:0] rd_addr_flat;
    wire [COLS*DATA_W-1:0] rd_data_flat;
    wire [COLS-1:0] rd_valid;
    wire [COLS*DATA_W-1:0] psum_top_data_flat;
    wire [COLS-1:0] psum_top_valid;
    wire psum_compute_ready;
    wire psum_underflow;
    wire psum_wait;
    wire [AW-1:0] pixel_addr;

    psum_column_pingpong_buffer #(
        .COLS(COLS), .DATA_W(DATA_W), .DEPTH(DEPTH), .AW(AW)
    ) u_buf (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_bank(wr_bank),
        .wr_addr_flat(wr_addr_flat), .wr_data_flat(wr_data_flat),
        .rd_en(rd_en), .rd_bank(rd_bank_out),
        .rd_addr_flat(rd_addr_flat),
        .rd_data_flat(rd_data_flat), .rd_valid(rd_valid)
    );

    psum_column_stream_feeder #(
        .COLS(COLS), .DATA_W(DATA_W), .AW(AW), .COL_DELAY(COL_DELAY)
    ) dut (
        .clk(clk), .rst(rst),
        .start(start), .compute_fire(compute_fire),
        .use_ext_psum(use_ext_psum), .rd_bank(rd_bank),
        .overlap_guard_enable(overlap_guard_enable),
        .available_count_flat(available_count_flat),
        .rd_en(rd_en), .rd_bank_out(rd_bank_out),
        .rd_addr_flat(rd_addr_flat),
        .rd_data_flat(rd_data_flat), .rd_valid(rd_valid),
        .psum_top_data_flat(psum_top_data_flat),
        .psum_top_valid(psum_top_valid),
        .psum_compute_ready(psum_compute_ready),
        .psum_underflow(psum_underflow),
        .psum_wait(psum_wait),
        .pixel_addr(pixel_addr)
    );

    always #5 clk = ~clk;

    integer pass = 0;
    integer fail = 0;
    integer cyc = 0;
    integer i;
    integer c;
    integer expect_col;
    integer expect_addr;
    integer fire_count = 0;
    integer rd_count [0:COLS-1];
    integer valid_count [0:COLS-1];

    function [DATA_W-1:0] make_data;
        input integer col;
        input integer addr;
        begin
            make_data = 64'h1000_0000_0000_0000 +
                        (col[15:0] << 16) + addr[15:0];
        end
    endfunction

    task set_flat_addr;
        input integer col;
        input integer addr;
        begin
            wr_addr_flat[col*AW +: AW] = addr[AW-1:0];
        end
    endtask

    task set_flat_data;
        input integer col;
        input [DATA_W-1:0] data;
        begin
            wr_data_flat[col*DATA_W +: DATA_W] = data;
        end
    endtask

    task set_available;
        input integer col;
        input integer count;
        begin
            available_count_flat[col*(AW+1) +: (AW+1)] = count[AW:0];
        end
    endtask

    task load_column_bank;
        begin
            for (i = 0; i < DEPTH; i = i + 1) begin
                wr_en = {COLS{1'b1}};
                for (c = 0; c < COLS; c = c + 1) begin
                    set_flat_addr(c, i);
                    set_flat_data(c, make_data(c, i));
                end
                @(negedge clk);
                wr_en = {COLS{1'b0}};
            end
        end
    endtask

    always @(posedge clk) begin
        if (!rst) begin
            cyc <= cyc + 1;
            for (c = 0; c < COLS; c = c + 1) begin
                if (rd_en[c]) begin
                    expect_addr = rd_count[c];
                    if (rd_addr_flat[c*AW +: AW] !== expect_addr[AW-1:0]) begin
                        $display("[FAIL] col%0d rd addr got=%0d exp=%0d cycle=%0d",
                            c, rd_addr_flat[c*AW +: AW], expect_addr, cyc);
                        fail <= fail + 1;
                    end else begin
                        pass <= pass + 1;
                    end
                    rd_count[c] <= rd_count[c] + 1;
                end
                if (psum_top_valid[c]) begin
                    expect_addr = valid_count[c];
                    if (psum_top_data_flat[c*DATA_W +: DATA_W] !==
                        make_data(c, expect_addr)) begin
                        $display("[FAIL] col%0d data got=%h exp=%h cycle=%0d",
                            c, psum_top_data_flat[c*DATA_W +: DATA_W],
                            make_data(c, expect_addr), cyc);
                        fail <= fail + 1;
                    end else begin
                        pass <= pass + 1;
                    end
                    valid_count[c] <= valid_count[c] + 1;
                end
            end
        end
    end

    initial begin
        for (c = 0; c < COLS; c = c + 1) begin
            rd_count[c] = 0;
            valid_count[c] = 0;
            set_available(c, DEPTH);
        end

        repeat (4) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        load_column_bank();

        start = 1'b1;
        use_ext_psum = 1'b1;
        @(negedge clk);
        start = 1'b0;

        for (i = 0; i < 5; i = i + 1) begin
            if (psum_compute_ready !== 1'b1) begin
                $display("[FAIL] compute not ready before fire %0d", i);
                fail = fail + 1;
            end
            compute_fire = 1'b1;
            @(negedge clk);
            compute_fire = 1'b0;
            @(negedge clk);
        end

        repeat (COLS*COL_DELAY + 4) @(negedge clk);

        for (c = 0; c < COLS; c = c + 1) begin
            if (rd_count[c] != 5) begin
                $display("[FAIL] col%0d rd_count=%0d exp=5", c, rd_count[c]);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
            if (valid_count[c] != 5) begin
                $display("[FAIL] col%0d valid_count=%0d exp=5", c, valid_count[c]);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
        end

        overlap_guard_enable = 1'b1;
        set_available(0, 5);
        set_available(1, 4);
        set_available(2, 5);
        set_available(3, 5);
        #1;
        if (psum_compute_ready !== 1'b0 || psum_wait !== 1'b1) begin
            $display("[FAIL] guard ready=%0d wait=%0d",
                psum_compute_ready, psum_wait);
            fail = fail + 1;
        end else begin
            pass = pass + 1;
        end
        compute_fire = 1'b1;
        #1;
        if (psum_underflow !== 1'b1) begin
            $display("[FAIL] expected underflow when forced fire");
            fail = fail + 1;
        end else begin
            pass = pass + 1;
        end
        compute_fire = 1'b0;

        $display("=== tb_psum_column_stream: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0)
            $fatal(1);
        $finish;
    end
endmodule

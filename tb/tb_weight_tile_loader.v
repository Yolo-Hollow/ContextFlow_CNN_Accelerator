`timescale 1ns / 1ps

module tb_weight_tile_loader;
    localparam ROWS = 4;
    localparam COLS = 4;
    localparam WEIGHT_W = 8;
    localparam COUT_TILE = COLS * 2;
    localparam TILE_WORDS = ROWS * COUT_TILE;
    localparam ADDR_W = 5;

    reg clk, rst;
    reg tile_wr_en;
    reg [ADDR_W-1:0] tile_wr_addr;
    reg [WEIGHT_W-1:0] tile_wr_data;
    reg tile_wr8_en;
    reg [ADDR_W-1:0] tile_wr8_addr;
    reg [WEIGHT_W*8-1:0] tile_wr8_data;
    reg [7:0] tile_wr8_keep;
    reg start;
    wire busy, done;
    reg [ROWS-1:0] wgt_fifo_full;
    wire [ROWS-1:0] wgt_fifo_wr_en;
    wire [ROWS*WEIGHT_W*2-1:0] wgt_fifo_wr_data;

    weight_tile_loader #(
        .ROWS(ROWS), .COLS(COLS), .WEIGHT_W(WEIGHT_W), .ADDR_W(ADDR_W)
    ) dut (
        .clk(clk), .rst(rst),
        .tile_wr_en(tile_wr_en), .tile_wr_addr(tile_wr_addr), .tile_wr_data(tile_wr_data),
        .tile_wr8_en(tile_wr8_en), .tile_wr8_addr(tile_wr8_addr),
        .tile_wr8_data(tile_wr8_data), .tile_wr8_keep(tile_wr8_keep),
        .start(start), .busy(busy), .done(done),
        .wgt_fifo_full(wgt_fifo_full),
        .wgt_fifo_wr_en(wgt_fifo_wr_en), .wgt_fifo_wr_data(wgt_fifo_wr_data)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer row, col, addr, cycle_count, lane;
    reg [7:0] expected0, expected1, got0, got1;

    function [7:0] weight_value;
        input integer r;
        input integer co;
        begin
            weight_value = r*8 + co + 8'd3;
        end
    endfunction

    task check_cycle;
        input integer col_pair;
        begin
            if (wgt_fifo_wr_en !== {ROWS{1'b1}}) begin
                $display("[FAIL] col%0d wr_en got=%b", col_pair, wgt_fifo_wr_en);
                fail = fail + 1;
            end else pass = pass + 1;

            for (row = 0; row < ROWS; row = row + 1) begin
                expected0 = weight_value(row, 2*col_pair);
                expected1 = weight_value(row, 2*col_pair + 1);
                got0 = wgt_fifo_wr_data[row*16 +: 8];
                got1 = wgt_fifo_wr_data[row*16+8 +: 8];
                if (got0 !== expected0) begin
                    $display("[FAIL] col%0d row%0d w0 got=%0d exp=%0d", col_pair, row, got0, expected0);
                    fail = fail + 1;
                end else pass = pass + 1;
                if (got1 !== expected1) begin
                    $display("[FAIL] col%0d row%0d w1 got=%0d exp=%0d", col_pair, row, got1, expected1);
                    fail = fail + 1;
                end else pass = pass + 1;
            end
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        tile_wr_en = 0;
        tile_wr_addr = 0;
        tile_wr_data = 0;
        tile_wr8_en = 0;
        tile_wr8_addr = 0;
        tile_wr8_data = 0;
        tile_wr8_keep = 0;
        start = 0;
        wgt_fifo_full = 0;
        pass = 0;
        fail = 0;

        repeat (3) @(negedge clk);
        rst = 0;

        for (addr = 0; addr < TILE_WORDS; addr = addr + 1) begin
            @(negedge clk);
            tile_wr_en = 1'b1;
            tile_wr_addr = addr[ADDR_W-1:0];
            tile_wr_data = weight_value(addr / COUT_TILE, addr % COUT_TILE);
        end
        @(negedge clk);
        tile_wr_en = 1'b0;

        for (addr = 0; addr < TILE_WORDS; addr = addr + 8) begin
            @(negedge clk);
            tile_wr8_en = 1'b1;
            tile_wr8_addr = addr[ADDR_W-1:0];
            tile_wr8_keep = 8'hff;
            tile_wr8_data = 64'd0;
            for (lane = 0; lane < 8; lane = lane + 1)
                tile_wr8_data[lane*8 +: 8] =
                    weight_value((addr + lane) / COUT_TILE, (addr + lane) % COUT_TILE);
        end
        @(negedge clk);
        tile_wr8_en = 1'b0;
        tile_wr8_keep = 8'd0;

        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        cycle_count = 0;
        for (col = 0; col < COLS; col = col + 1) begin
            if (col == 1) begin
                wgt_fifo_full = 4'b0010;
                #1;
                if (wgt_fifo_wr_en !== 0) begin
                    $display("[FAIL] wr_en asserted while fifo full");
                    fail = fail + 1;
                end else pass = pass + 1;
                @(negedge clk);
                wgt_fifo_full = 4'b0000;
            end
            #1;
            check_cycle(col);
            cycle_count = cycle_count + 1;
            @(negedge clk);
        end

        #1;
        if (!done) begin
            $display("[FAIL] loader did not assert done");
            fail = fail + 1;
        end else pass = pass + 1;

        if (cycle_count != COLS) begin
            $display("[FAIL] emitted cycles got=%0d exp=%0d", cycle_count, COLS);
            fail = fail + 1;
        end else pass = pass + 1;

        $display("=== tb_weight_tile_loader: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

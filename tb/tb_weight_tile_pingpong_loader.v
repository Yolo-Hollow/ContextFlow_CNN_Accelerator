`timescale 1ns / 1ps

module tb_weight_tile_pingpong_loader;
    localparam ROWS = 2;
    localparam COLS = 4;
    localparam WEIGHT_W = 8;
    localparam ADDR_W = 5;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg soft_reset = 1'b0;
    reg tile_wr_en = 1'b0;
    reg [ADDR_W-1:0] tile_wr_addr = 0;
    reg [WEIGHT_W-1:0] tile_wr_data = 0;
    reg tile_wr8_en = 1'b0;
    reg [ADDR_W-1:0] tile_wr8_addr = 0;
    reg [WEIGHT_W*8-1:0] tile_wr8_data = 0;
    reg [7:0] tile_wr8_keep = 0;
    wire write_ready;
    reg commit_valid = 1'b0;
    wire commit_ready;
    reg consume_valid = 1'b0;
    wire consume_ready;
    reg [ROWS-1:0] row_fifo_full = 0;
    wire [ROWS-1:0] row_fifo_wr_en;
    wire [ROWS*WEIGHT_W*2-1:0] row_fifo_wr_data;
    wire done;
    wire format_busy;
    wire [1:0] committed_level;
    wire [1:0] bank_busy;
    wire sticky_commit_overflow;
    wire sticky_consume_underflow;
    wire sticky_write_no_slot;
    wire sticky_protocol_error;
    wire fatal_error;

    integer checks = 0;
    integer failures = 0;
    integer beat;
    integer lane;
    integer col;

    always #5 clk = ~clk;

    weight_tile_pingpong_loader #(
        .ROWS(ROWS), .COLS(COLS), .WEIGHT_W(WEIGHT_W),
        .ADDR_W(ADDR_W)
    ) dut (
        .clk(clk), .rst(rst), .soft_reset(soft_reset),
        .tile_wr_en(tile_wr_en), .tile_wr_addr(tile_wr_addr),
        .tile_wr_data(tile_wr_data),
        .tile_wr8_en(tile_wr8_en), .tile_wr8_addr(tile_wr8_addr),
        .tile_wr8_data(tile_wr8_data), .tile_wr8_keep(tile_wr8_keep),
        .write_ready(write_ready),
        .commit_valid(commit_valid), .commit_ready(commit_ready),
        .consume_valid(consume_valid), .consume_ready(consume_ready),
        .row_fifo_full(row_fifo_full),
        .row_fifo_wr_en(row_fifo_wr_en),
        .row_fifo_wr_data(row_fifo_wr_data),
        .done(done), .format_busy(format_busy),
        .committed_level(committed_level), .bank_busy(bank_busy),
        .sticky_commit_overflow(sticky_commit_overflow),
        .sticky_consume_underflow(sticky_consume_underflow),
        .sticky_write_no_slot(sticky_write_no_slot),
        .sticky_protocol_error(sticky_protocol_error),
        .fatal_error(fatal_error)
    );

    task automatic check;
        input condition;
        input [8*96-1:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task automatic write_packed_tile;
        input integer base;
        begin
            for (beat = 0; beat < 2; beat = beat + 1) begin
                @(negedge clk);
                tile_wr8_en = 1'b1;
                tile_wr8_addr = beat * 8;
                tile_wr8_keep = 8'hff;
                for (lane = 0; lane < 8; lane = lane + 1)
                    tile_wr8_data[lane*8 +: 8] = base + beat*8 + lane;
                commit_valid = (beat == 1);
                @(posedge clk);
                check(write_ready, "packed write has a reserved bank");
                if (commit_valid)
                    check(commit_ready, "tile commit accepted");
            end
            @(negedge clk);
            tile_wr8_en = 1'b0;
            tile_wr8_keep = 8'd0;
            tile_wr8_data = 64'd0;
            commit_valid = 1'b0;
        end
    endtask

    task automatic accept_consume;
        begin
            consume_valid = 1'b1;
            @(posedge clk);
            while (!consume_ready)
                @(posedge clk);
            @(negedge clk);
            consume_valid = 1'b0;
        end
    endtask

    task automatic check_formatted_tile;
        input integer base;
        begin
            col = 0;
            while (col < COLS) begin
                @(posedge clk);
                if (row_fifo_wr_en == {ROWS{1'b1}}) begin
                    check(row_fifo_wr_data[7:0] == base + 2*col,
                          "row0 even lane");
                    check(row_fifo_wr_data[15:8] == base + 2*col + 1,
                          "row0 odd lane");
                    check(row_fifo_wr_data[23:16] == base + 8 + 2*col,
                          "row1 even lane");
                    check(row_fifo_wr_data[31:24] == base + 8 + 2*col + 1,
                          "row1 odd lane");
                    col = col + 1;
                end
            end
            @(posedge clk);
            check(done, "formatter done after COLS writes");
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
        check(write_ready, "bank0 initially writable");

        // A demand is allowed to wait for its packet; it must not be reported
        // as an underflow.  Commit tile0, then fill tile1 while tile0 formats.
        consume_valid = 1'b1;
        fork
            begin
                write_packed_tile(0);
                write_packed_tile(100);
            end
            begin
                @(posedge clk);
                while (!consume_ready)
                    @(posedge clk);
                @(negedge clk);
                consume_valid = 1'b0;
                // Stall one formatter cycle to prove payload/column hold.
                row_fifo_full = 2'b01;
                @(negedge clk);
                row_fifo_full = 2'b00;
                check_formatted_tile(0);
            end
        join

        check(!sticky_consume_underflow,
              "held consume wait is not an underflow");
        check(!fatal_error, "parallel fill/format remains error free");
        check(committed_level == 1, "second tile remains queued");

        accept_consume();
        check_formatted_tile(100);
        check(committed_level == 0, "commit queue drained");
        check(bank_busy == 0, "both staging banks released");
        check(write_ready, "a bank is writable after drain");

        // Soft reset clears protocol state but retains payload RAM.
        @(negedge clk);
        soft_reset = 1'b1;
        @(posedge clk);
        @(negedge clk);
        soft_reset = 1'b0;
        @(posedge clk);
        check(!fatal_error && write_ready && committed_level == 0,
              "soft reset restores empty staging state");

        // Scalar and packed writes in one cycle fail closed.
        @(negedge clk);
        tile_wr_en = 1'b1;
        tile_wr_addr = 0;
        tile_wr_data = 8'h55;
        tile_wr8_en = 1'b1;
        tile_wr8_addr = 0;
        tile_wr8_keep = 8'hff;
        @(posedge clk);
        @(negedge clk);
        tile_wr_en = 1'b0;
        tile_wr8_en = 1'b0;
        tile_wr8_keep = 0;
        @(posedge clk);
        check(sticky_protocol_error && fatal_error,
              "simultaneous scalar/packed write fails closed");

        if (failures == 0)
            $display("PASS tb_weight_tile_pingpong_loader checks=%0d", checks);
        else
            $display("[FAIL] tb_weight_tile_pingpong_loader checks=%0d failures=%0d",
                     checks, failures);
        $finish;
    end
endmodule

`timescale 1ns / 1ps

module tb_weight_context_preloader;
    localparam ROWS = 18;
    localparam COLS = 16;
    localparam EPOCH_W = 8;
    localparam FIFO_DEPTH = 64;

    reg clk;
    reg rst;
    reg soft_reset;
    reg alloc_valid;
    wire alloc_ready;
    reg alloc_bank;
    reg [EPOCH_W-1:0] alloc_epoch;
    reg weight_tile_credit_valid;
    wire weight_tile_credit_ready;
    wire [1:0] weight_credit_level;
    reg [ROWS-1:0] row_fifo_empty;
    wire row_fifo_rd_en;
    reg [ROWS*16-1:0] row_fifo_rd_data;
    wire array_w_load;
    wire [4:0] array_w_col;
    wire array_w_bank;
    wire [ROWS*16-1:0] array_w_row_data;
    reg start_valid;
    wire start_ready;
    wire start_fire;
    reg start_bank;
    reg [EPOCH_W-1:0] start_epoch;
    reg retire_valid;
    wire retire_match;
    reg retire_bank;
    reg [EPOCH_W-1:0] retire_epoch;
    wire [1:0] bank_ready;
    wire [1:0] bank_active;
    wire [1:0] bank_epoch_valid;
    wire [EPOCH_W-1:0] bank0_epoch;
    wire [EPOCH_W-1:0] bank1_epoch;
    wire [2:0] bank0_state;
    wire [2:0] bank1_state;
    wire preload_busy;
    wire fatal_error;
    wire sticky_protocol_error;
    wire sticky_owner_error;
    wire sticky_epoch_error;
    wire [31:0] alloc_count;
    wire [31:0] tile_credit_accept_count;
    wire [31:0] preload_commit_count;
    wire [31:0] array_write_count;
    wire [31:0] start_match_count;
    wire [31:0] start_miss_count;
    wire [31:0] retire_match_count;
    wire [31:0] protocol_error_count;
    wire [31:0] owner_error_count;
    wire [31:0] epoch_error_count;

    weight_context_preloader #(
        .ROWS(ROWS),
        .COLS(COLS),
        .EPOCH_W(EPOCH_W)
    ) dut (
        .clk(clk), .rst(rst), .soft_reset(soft_reset),
        .alloc_valid(alloc_valid), .alloc_ready(alloc_ready),
        .alloc_bank(alloc_bank), .alloc_epoch(alloc_epoch),
        .weight_tile_credit_valid(weight_tile_credit_valid),
        .weight_tile_credit_ready(weight_tile_credit_ready),
        .weight_credit_level(weight_credit_level),
        .row_fifo_empty(row_fifo_empty),
        .row_fifo_rd_en(row_fifo_rd_en),
        .row_fifo_rd_data(row_fifo_rd_data),
        .array_w_load(array_w_load), .array_w_col(array_w_col),
        .array_w_bank(array_w_bank),
        .array_w_row_data(array_w_row_data),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_fire(start_fire), .start_bank(start_bank),
        .start_epoch(start_epoch),
        .retire_valid(retire_valid), .retire_match(retire_match),
        .retire_bank(retire_bank), .retire_epoch(retire_epoch),
        .bank_ready(bank_ready), .bank_active(bank_active),
        .bank_epoch_valid(bank_epoch_valid),
        .bank0_epoch(bank0_epoch), .bank1_epoch(bank1_epoch),
        .bank0_state(bank0_state), .bank1_state(bank1_state),
        .preload_busy(preload_busy), .fatal_error(fatal_error),
        .sticky_protocol_error(sticky_protocol_error),
        .sticky_owner_error(sticky_owner_error),
        .sticky_epoch_error(sticky_epoch_error),
        .alloc_count(alloc_count),
        .tile_credit_accept_count(tile_credit_accept_count),
        .preload_commit_count(preload_commit_count),
        .array_write_count(array_write_count),
        .start_match_count(start_match_count),
        .start_miss_count(start_miss_count),
        .retire_match_count(retire_match_count),
        .protocol_error_count(protocol_error_count),
        .owner_error_count(owner_error_count),
        .epoch_error_count(epoch_error_count)
    );

    reg [15:0] fifo_mem [0:ROWS-1][0:FIFO_DEPTH-1];
    integer fifo_rptr [0:ROWS-1];
    integer fifo_wptr [0:ROWS-1];
    integer fifo_count [0:ROWS-1];
    integer expected_tile [0:1];
    integer write_seen [0:1];
    integer pass;
    integer fail;
    integer cycles;
    reg [15:0] expected_word;
    reg [15:0] observed_word;

    function [15:0] make_weight_word;
        input integer tile;
        input integer row_idx;
        input integer col_idx;
        begin
            make_weight_word = ((tile & 15) << 12) |
                ((row_idx & 31) << 7) | ((col_idx & 31) << 2) | 1;
        end
    endfunction

    task check;
        input condition;
        input [8*96-1:0] message;
        begin
            if (condition) begin
                pass = pass + 1;
            end else begin
                $display("[FAIL] %0s", message);
                fail = fail + 1;
            end
        end
    endtask

    task append_tile;
        input integer tile;
        integer append_row;
        integer append_col;
        begin
            for (append_row = 0; append_row < ROWS;
                 append_row = append_row + 1) begin
                for (append_col = 0; append_col < COLS;
                     append_col = append_col + 1) begin
                    fifo_mem[append_row][fifo_wptr[append_row]] =
                        make_weight_word(tile, append_row, append_col);
                    fifo_wptr[append_row] =
                        (fifo_wptr[append_row] + 1) % FIFO_DEPTH;
                    fifo_count[append_row] =
                        fifo_count[append_row] + 1;
                end
            end
        end
    endtask

    task send_alloc;
        input bank;
        input [EPOCH_W-1:0] epoch;
        begin
            @(negedge clk);
            alloc_bank = bank;
            alloc_epoch = epoch;
            alloc_valid = 1'b1;
            cycles = 0;
            @(posedge clk);
            while ((alloc_ready !== 1'b1) && cycles < 20) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (!alloc_ready)
                $display("[DIAG] alloc timeout t=%0t bank=%0d epoch=%h states=%0d/%0d fatal=%0d",
                    $time, bank, epoch, bank0_state, bank1_state,
                    fatal_error);
            check(alloc_ready, "allocation never became ready");
            @(negedge clk);
            alloc_valid = 1'b0;
        end
    endtask

    task send_credit;
        begin
            @(negedge clk);
            weight_tile_credit_valid = 1'b1;
            cycles = 0;
            @(posedge clk);
            while ((weight_tile_credit_ready !== 1'b1) && cycles < 20) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            check(weight_tile_credit_ready, "tile credit never became ready");
            @(negedge clk);
            weight_tile_credit_valid = 1'b0;
        end
    endtask

    task send_start;
        input bank;
        input [EPOCH_W-1:0] epoch;
        begin
            @(negedge clk);
            start_bank = bank;
            start_epoch = epoch;
            start_valid = 1'b1;
            #1;
            check(start_ready, "matching start was not ready");
            @(negedge clk);
            start_valid = 1'b0;
        end
    endtask

    task send_retire;
        input bank;
        input [EPOCH_W-1:0] epoch;
        begin
            @(negedge clk);
            retire_bank = bank;
            retire_epoch = epoch;
            retire_valid = 1'b1;
            #1;
            check(retire_match, "matching retire did not match");
            @(negedge clk);
            retire_valid = 1'b0;
        end
    endtask

    task pulse_soft_reset;
        begin
            @(negedge clk);
            soft_reset = 1'b1;
            @(negedge clk);
            soft_reset = 1'b0;
            @(negedge clk);
        end
    endtask

    always #5 clk = ~clk;

    integer empty_row;
    always @(*) begin
        for (empty_row = 0; empty_row < ROWS;
             empty_row = empty_row + 1)
            row_fifo_empty[empty_row] = (fifo_count[empty_row] == 0);
    end

    // Behavioral model of the existing registered-output systolic_fifo.
    integer model_row;
    always @(posedge clk) begin
        if (rst) begin
            row_fifo_rd_data <= {ROWS*16{1'b0}};
        end else if (row_fifo_rd_en) begin
            for (model_row = 0; model_row < ROWS;
                 model_row = model_row + 1) begin
                row_fifo_rd_data[model_row*16 +: 16] <=
                    fifo_mem[model_row][fifo_rptr[model_row]];
                fifo_rptr[model_row] =
                    (fifo_rptr[model_row] + 1) % FIFO_DEPTH;
                fifo_count[model_row] = fifo_count[model_row] - 1;
            end
        end
    end

    // Check the write packet after the synchronous FIFO output and DUT
    // metadata have both settled for the cycle.
    integer check_row;
    always @(negedge clk) begin
        if (array_w_load) begin
            check(array_w_col == write_seen[array_w_bank],
                "array column sequence mismatch");
            for (check_row = 0; check_row < ROWS;
                 check_row = check_row + 1) begin
                expected_word = make_weight_word(
                    expected_tile[array_w_bank], check_row, array_w_col);
                observed_word = array_w_row_data[check_row*16 +: 16];
                if (observed_word !== expected_word) begin
                    $display("[FAIL] bank%0d col%0d row%0d got=%h exp=%h",
                        array_w_bank, array_w_col, check_row,
                        observed_word, expected_word);
                    fail = fail + 1;
                end else begin
                    pass = pass + 1;
                end
            end
            write_seen[array_w_bank] = write_seen[array_w_bank] + 1;
        end
    end

    integer init_row;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
        soft_reset = 1'b0;
        alloc_valid = 1'b0;
        alloc_bank = 1'b0;
        alloc_epoch = 0;
        weight_tile_credit_valid = 1'b0;
        row_fifo_rd_data = 0;
        start_valid = 1'b0;
        start_bank = 1'b0;
        start_epoch = 0;
        retire_valid = 1'b0;
        retire_bank = 1'b0;
        retire_epoch = 0;
        pass = 0;
        fail = 0;
        expected_tile[0] = 0;
        expected_tile[1] = 1;
        write_seen[0] = 0;
        write_seen[1] = 0;
        for (init_row = 0; init_row < ROWS;
             init_row = init_row + 1) begin
            fifo_rptr[init_row] = 0;
            fifo_wptr[init_row] = 0;
            fifo_count[init_row] = 0;
        end

        repeat (4) @(negedge clk);
        rst = 1'b0;

        append_tile(0);
        append_tile(1);
        send_alloc(1'b0, 8'h11);
        send_alloc(1'b1, 8'h22);
        send_credit();
        send_credit();

        cycles = 0;
        while (!bank_ready[0] && cycles < 80) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        check(bank_ready[0], "bank0 did not reach READY");
        check(bank0_epoch == 8'h11, "bank0 epoch mismatch at READY");
        check(write_seen[0] == COLS, "bank0 did not receive 16 writes");
        send_start(1'b0, 8'h11);
        check(bank_active[0], "bank0 did not enter ACTIVE");

        cycles = 0;
        while (!bank_ready[1] && cycles < 80) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        check(bank_ready[1], "bank1 did not load while bank0 was ACTIVE");
        check(bank_active[0], "bank0 lost ACTIVE during bank1 preload");
        check(write_seen[1] == COLS, "bank1 did not receive 16 writes");
        send_start(1'b1, 8'h22);
        check(bank_active == 2'b11, "two ACTIVE banks did not coexist");

        send_retire(1'b0, 8'h11);
        check(bank0_state == 3'd5, "bank0 did not enter RETIRING");
        @(negedge clk);
        check(bank0_state == 3'd0, "bank0 did not leave RETIRING for EMPTY");
        send_retire(1'b1, 8'h22);
        @(negedge clk);
        check(bank_active == 2'b00, "active bits did not clear after retire");
        check(alloc_count == 2, "alloc counter mismatch");
        check(tile_credit_accept_count == 2, "credit counter mismatch");
        check(preload_commit_count == 2, "commit counter mismatch");
        check(array_write_count == 2*COLS, "array write counter mismatch");
        check(start_match_count == 2, "start match counter mismatch");
        check(retire_match_count == 2, "retire match counter mismatch");
        check(!fatal_error, "normal lifecycle raised fatal_error");

        // A READY-bank epoch mismatch is fail-stop and sticky.
        pulse_soft_reset();
        expected_tile[0] = 2;
        write_seen[0] = 0;
        append_tile(2);
        send_alloc(1'b0, 8'h33);
        send_credit();
        cycles = 0;
        while (!bank_ready[0] && cycles < 80) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        check(bank_ready[0], "epoch scenario did not preload bank0");
        @(negedge clk);
        start_bank = 1'b0;
        start_epoch = 8'h34;
        start_valid = 1'b1;
        @(negedge clk);
        start_valid = 1'b0;
        #1;
        check(fatal_error && sticky_epoch_error,
            "wrong start epoch did not fail closed");
        check(epoch_error_count == 1, "epoch error count mismatch");
        check(start_miss_count == 1, "start miss count mismatch");

        // Soft reset clears lifecycle, queued work, counters, and stickies.
        pulse_soft_reset();
        check(!fatal_error, "soft reset did not clear fatal error");
        check(bank0_state == 0 && bank1_state == 0,
            "soft reset did not empty both banks");
        check(alloc_count == 0 && preload_commit_count == 0 &&
              array_write_count == 0 && epoch_error_count == 0,
            "soft reset did not clear counters");

        // Retiring an EMPTY bank is an ownership violation.
        @(negedge clk);
        retire_bank = 1'b0;
        retire_epoch = 8'h55;
        retire_valid = 1'b1;
        @(negedge clk);
        retire_valid = 1'b0;
        #1;
        check(fatal_error && sticky_owner_error,
            "EMPTY-bank retire did not raise owner error");
        check(owner_error_count == 1, "owner error count mismatch");

        // A credit is a full-tile promise.  Empty row FIFOs therefore cause
        // a protocol fail-stop rather than a partial bank commit.
        pulse_soft_reset();
        send_alloc(1'b0, 8'h66);
        send_credit();
        cycles = 0;
        while (!fatal_error && cycles < 10) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        check(fatal_error && sticky_protocol_error,
            "empty FIFO after tile credit did not raise protocol error");
        check(protocol_error_count == 1, "protocol error count mismatch");
        check(preload_commit_count == 0,
            "protocol failure committed a partial bank");

        $display("=== tb_weight_context_preloader: %0d pass, %0d fail ===",
            pass, fail);
        if (fail != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "tb_weight_context_preloader timeout");
    end
endmodule

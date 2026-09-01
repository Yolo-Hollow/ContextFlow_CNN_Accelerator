`timescale 1ns / 1ps

module tb_psum_pingpong_buffer;
    localparam DATA_W = 256;
    localparam DEPTH = 9;
    localparam AW = 4;

    reg clk, rst;
    reg clear_valid, clear_bank;
    reg wr_en, wr_bank;
    reg [AW-1:0] wr_addr;
    reg [DATA_W-1:0] wr_data;
    reg rd_en, rd_bank;
    reg [AW-1:0] rd_addr;
    wire [DATA_W-1:0] rd_data;
    wire rd_valid;
    wire [AW:0] committed_count0, committed_count1;
    wire error_underflow, error_overwrite, error_bank_conflict;
    wire [DATA_W-1:0] external_rd_data;
    wire external_rd_valid;
    wire [AW:0] external_committed_count0;
    wire [AW:0] external_committed_count1;
    wire external_error_underflow;
    wire external_error_overwrite;
    wire external_error_bank_conflict;

    psum_pingpong_buffer #(.DATA_W(DATA_W), .DEPTH(DEPTH), .AW(AW)) dut (
        .clk(clk), .rst(rst),
        .clear_valid(clear_valid), .clear_bank(clear_bank),
        .wr_en(wr_en), .wr_bank(wr_bank), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_bank(rd_bank), .rd_addr(rd_addr),
        .rd_data(rd_data), .rd_valid(rd_valid),
        .committed_count0(committed_count0),
        .committed_count1(committed_count1),
        .error_underflow(error_underflow),
        .error_overwrite(error_overwrite),
        .error_bank_conflict(error_bank_conflict)
    );

    // The tagged-context integration uses the same RAM interface after an
    // external owner scoreboard has accepted each read/write handshake.
    psum_pingpong_buffer #(
        .DATA_W(DATA_W), .DEPTH(DEPTH), .AW(AW),
        .EXTERNAL_CREDIT_GUARD(1)
    ) external_guard_dut (
        .clk(clk), .rst(rst),
        .clear_valid(clear_valid), .clear_bank(clear_bank),
        .wr_en(wr_en), .wr_bank(wr_bank), .wr_addr(wr_addr),
        .wr_data(wr_data),
        .rd_en(rd_en), .rd_bank(rd_bank), .rd_addr(rd_addr),
        .rd_data(external_rd_data), .rd_valid(external_rd_valid),
        .committed_count0(external_committed_count0),
        .committed_count1(external_committed_count1),
        .error_underflow(external_error_underflow),
        .error_overwrite(external_error_overwrite),
        .error_bank_conflict(external_error_bank_conflict)
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
            clear_valid = 1'b0;
            clear_bank = 1'b0;
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
            end else if (external_rd_valid !== 1'b1 ||
                         external_rd_data !== exp) begin
                $display("[FAIL] external guard read bank%0d addr%0d got=%h exp=%h valid=%b",
                    bank, addr, external_rd_data, exp, external_rd_valid);
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
        if (committed_count0 !== DEPTH) begin
            $display("[FAIL] bank0 committed credits got=%0d exp=%0d",
                     committed_count0, DEPTH);
            fail = fail + 1;
        end else pass = pass + 1;

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
            if (rd_valid !== 1'b1 || rd_data !== pass0[i] ||
                external_rd_valid !== 1'b1 ||
                external_rd_data !== pass0[i]) begin
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

        if (committed_count1 !== DEPTH || error_underflow ||
            error_overwrite || error_bank_conflict) begin
            $display("[FAIL] clean scoreboard count1=%0d err=%b%b%b",
                     committed_count1, error_bank_conflict,
                     error_overwrite, error_underflow);
            fail = fail + 1;
        end else pass = pass + 1;

        // Releasing a bank removes all per-address credits. A stale read is
        // rejected instead of returning RAM contents from the prior context.
        clear_valid = 1'b1;
        clear_bank = 1'b0;
        @(negedge clk);
        clear_valid = 1'b0;
        if (committed_count0 !== 0) begin
            $display("[FAIL] bank0 clear left %0d credits", committed_count0);
            fail = fail + 1;
        end else pass = pass + 1;
        rd_en = 1'b1;
        rd_bank = 1'b0;
        rd_addr = 0;
        @(negedge clk);
        rd_en = 1'b0;
        if (rd_valid || !error_underflow) begin
            $display("[FAIL] stale read valid=%b underflow=%b",
                     rd_valid, error_underflow);
            fail = fail + 1;
        end else pass = pass + 1;

        // Rewriting a committed address and accessing one bank from both
        // sides are independently diagnosed.
        wr_en = 1'b1;
        wr_bank = 1'b1;
        wr_addr = 0;
        wr_data = pass1[0];
        rd_en = 1'b1;
        rd_bank = 1'b1;
        rd_addr = 0;
        @(negedge clk);
        wr_en = 1'b0;
        rd_en = 1'b0;
        if (!error_overwrite || !error_bank_conflict) begin
            $display("[FAIL] overwrite/conflict err=%b%b",
                     error_bank_conflict, error_overwrite);
            fail = fail + 1;
        end else pass = pass + 1;

        if (external_committed_count0 !== 0 ||
            external_committed_count1 !== 0 ||
            external_error_underflow || external_error_overwrite ||
            external_error_bank_conflict) begin
            $display("[FAIL] external guard exposed duplicate credit state count=%0d/%0d err=%b%b%b",
                external_committed_count0, external_committed_count1,
                external_error_bank_conflict, external_error_overwrite,
                external_error_underflow);
            fail = fail + 1;
        end else pass = pass + 1;

        $display("=== tb_psum_pingpong_buffer: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

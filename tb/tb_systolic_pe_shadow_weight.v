`timescale 1ns / 1ps

module tb_systolic_pe_shadow_weight;
    localparam EPOCH_W = 8;
    localparam TOKEN_TOTAL = 82;

    reg clk;
    reg rst;
    reg weight_valid;
    wire weight_ready;
    reg weight_bank;
    reg [EPOCH_W-1:0] weight_epoch;
    reg signed [7:0] weight0_data;
    reg signed [7:0] weight1_data;
    reg token_valid;
    wire token_ready;
    reg signed [7:0] token_ifm;
    reg signed [31:0] token_psum0;
    reg signed [31:0] token_psum1;
    reg token_weight_bank;
    reg [EPOCH_W-1:0] token_weight_epoch;
    wire result_valid;
    reg result_ready;
    wire signed [31:0] result_psum0;
    wire signed [31:0] result_psum1;
    wire result_weight_bank;
    wire [EPOCH_W-1:0] result_weight_epoch;
    wire [1:0] bank_valid;
    wire [15:0] bank0_inflight;
    wire [15:0] bank1_inflight;
    wire [15:0] total_outstanding;
    wire ownership_error_sticky;
    wire bank_tag_error_sticky;
    wire epoch_error_sticky;
    wire protocol_error_sticky;
    wire [31:0] blocked_weight_write_count;
    wire [31:0] bad_bank_token_count;
    wire [31:0] epoch_mismatch_count;
    wire [31:0] accepted_token_count;
    wire [31:0] retired_token_count;

    systolic_pe_shadow_weight #(
        .EPOCH_W(EPOCH_W),
        .OUTSTANDING_MAX(8)
    ) dut (
        .clk(clk), .rst(rst),
        .weight_valid(weight_valid), .weight_ready(weight_ready),
        .weight_bank(weight_bank), .weight_epoch(weight_epoch),
        .weight0_data(weight0_data), .weight1_data(weight1_data),
        .token_valid(token_valid), .token_ready(token_ready),
        .token_ifm(token_ifm), .token_psum0(token_psum0),
        .token_psum1(token_psum1), .token_weight_bank(token_weight_bank),
        .token_weight_epoch(token_weight_epoch),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_psum0(result_psum0), .result_psum1(result_psum1),
        .result_weight_bank(result_weight_bank),
        .result_weight_epoch(result_weight_epoch),
        .bank_valid(bank_valid), .bank0_inflight(bank0_inflight),
        .bank1_inflight(bank1_inflight), .total_outstanding(total_outstanding),
        .ownership_error_sticky(ownership_error_sticky),
        .bank_tag_error_sticky(bank_tag_error_sticky),
        .epoch_error_sticky(epoch_error_sticky),
        .protocol_error_sticky(protocol_error_sticky),
        .blocked_weight_write_count(blocked_weight_write_count),
        .bad_bank_token_count(bad_bank_token_count),
        .epoch_mismatch_count(epoch_mismatch_count),
        .accepted_token_count(accepted_token_count),
        .retired_token_count(retired_token_count)
    );

    always #5 clk = ~clk;

    reg [15:0] ready_lfsr;
    always @(negedge clk) begin
        if (rst) begin
            ready_lfsr <= 16'h1ace;
            result_ready <= 1'b0;
        end else begin
            ready_lfsr <= {ready_lfsr[14:0],
                           ready_lfsr[15] ^ ready_lfsr[13] ^
                           ready_lfsr[12] ^ ready_lfsr[10]};
            result_ready <= ready_lfsr[0] | ready_lfsr[3];
        end
    end

    integer model_w0 [0:1];
    integer model_w1 [0:1];
    integer expected_psum0 [0:255];
    integer expected_psum1 [0:255];
    reg expected_bank [0:255];
    reg [EPOCH_W-1:0] expected_epoch [0:255];
    integer wr_index;
    integer rd_index;
    integer failures;
    integer ifm_model;
    integer psum0_model;
    integer psum1_model;
    reg shadow_load_while_active_seen;
    reg stall_seen;
    reg held_bank;
    reg [EPOCH_W-1:0] held_epoch;
    reg signed [31:0] held_psum0;
    reg signed [31:0] held_psum1;

    always @(posedge clk) begin
        if (!rst) begin
            if (weight_valid && weight_ready) begin
                model_w0[weight_bank] = $signed(weight0_data);
                model_w1[weight_bank] = $signed(weight1_data);
                if (weight_bank && (bank0_inflight != 0))
                    shadow_load_while_active_seen = 1'b1;
            end

            if (token_valid && token_ready) begin
                ifm_model = $signed(token_ifm);
                psum0_model = $signed(token_psum0);
                psum1_model = $signed(token_psum1);
                expected_psum0[wr_index] = psum0_model +
                    ifm_model * model_w0[token_weight_bank];
                expected_psum1[wr_index] = psum1_model +
                    ifm_model * model_w1[token_weight_bank];
                expected_bank[wr_index] = token_weight_bank;
                expected_epoch[wr_index] = token_weight_epoch;
                wr_index = wr_index + 1;
            end

            if (result_valid && result_ready) begin
                if ($signed(result_psum0) !== expected_psum0[rd_index]) begin
                    $display("[FAIL] result %0d psum0=%0d expected=%0d",
                             rd_index, $signed(result_psum0), expected_psum0[rd_index]);
                    failures = failures + 1;
                end
                if ($signed(result_psum1) !== expected_psum1[rd_index]) begin
                    $display("[FAIL] result %0d psum1=%0d expected=%0d",
                             rd_index, $signed(result_psum1), expected_psum1[rd_index]);
                    failures = failures + 1;
                end
                if (result_weight_bank !== expected_bank[rd_index]) begin
                    $display("[FAIL] result %0d bank=%0d expected=%0d",
                             rd_index, result_weight_bank, expected_bank[rd_index]);
                    failures = failures + 1;
                end
                if (result_weight_epoch !== expected_epoch[rd_index]) begin
                    $display("[FAIL] result %0d epoch=%0h expected=%0h",
                             rd_index, result_weight_epoch, expected_epoch[rd_index]);
                    failures = failures + 1;
                end
                rd_index = rd_index + 1;
            end

            if (stall_seen) begin
                if (!result_valid || result_weight_bank !== held_bank ||
                    result_weight_epoch !== held_epoch ||
                    result_psum0 !== held_psum0 || result_psum1 !== held_psum1) begin
                    $display("[FAIL] result changed while downstream was stalled");
                    failures = failures + 1;
                end
            end
            stall_seen = result_valid && !result_ready;
            if (result_valid && !result_ready) begin
                held_bank = result_weight_bank;
                held_epoch = result_weight_epoch;
                held_psum0 = result_psum0;
                held_psum1 = result_psum1;
            end
        end
    end

    task load_weight;
        input bank;
        input [EPOCH_W-1:0] epoch;
        input signed [7:0] w0;
        input signed [7:0] w1;
        begin
            @(negedge clk);
            weight_bank = bank;
            weight_epoch = epoch;
            weight0_data = w0;
            weight1_data = w1;
            weight_valid = 1'b1;
            @(posedge clk);
            while (!weight_ready)
                @(posedge clk);
            @(negedge clk);
            weight_valid = 1'b0;
        end
    endtask

    task send_token;
        input bank;
        input [EPOCH_W-1:0] epoch;
        input signed [7:0] ifm;
        input signed [31:0] psum0;
        input signed [31:0] psum1;
        begin
            @(negedge clk);
            token_weight_bank = bank;
            token_weight_epoch = epoch;
            token_ifm = ifm;
            token_psum0 = psum0;
            token_psum1 = psum1;
            token_valid = 1'b1;
            @(posedge clk);
            while (!token_ready)
                @(posedge clk);
            @(negedge clk);
            token_valid = 1'b0;
        end
    endtask

    integer n;
    integer drain_timeout;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
        weight_valid = 1'b0;
        weight_bank = 1'b0;
        weight_epoch = 0;
        weight0_data = 0;
        weight1_data = 0;
        token_valid = 1'b0;
        token_ifm = 0;
        token_psum0 = 0;
        token_psum1 = 0;
        token_weight_bank = 0;
        token_weight_epoch = 0;
        result_ready = 1'b0;
        ready_lfsr = 16'h1ace;
        model_w0[0] = 0;
        model_w0[1] = 0;
        model_w1[0] = 0;
        model_w1[1] = 0;
        wr_index = 0;
        rd_index = 0;
        failures = 0;
        shadow_load_while_active_seen = 1'b0;
        stall_seen = 1'b0;
        held_bank = 0;
        held_epoch = 0;
        held_psum0 = 0;
        held_psum1 = 0;

        repeat (4) @(negedge clk);
        rst = 1'b0;

        // An unloaded bank tag is rejected and counted once.
        @(negedge clk);
        token_valid = 1'b1;
        token_weight_bank = 1'b1;
        token_weight_epoch = 8'h20;
        token_ifm = 7;
        @(posedge clk);
        if (token_ready) begin
            $display("[FAIL] unloaded bank token was accepted");
            failures = failures + 1;
        end
        @(negedge clk);
        token_valid = 1'b0;

        load_weight(1'b0, 8'h10, 8'sd3, -8'sd2);
        send_token(1'b0, 8'h10, 8'sd4, 32'sd100, 32'sd200);

        // This is the key overlap: load bank1 while bank0 still owns a token.
        load_weight(1'b1, 8'h20, -8'sd5, 8'sd7);

        // Reusing bank0 before its token retires must be blocked and counted.
        @(negedge clk);
        weight_valid = 1'b1;
        weight_bank = 1'b0;
        weight_epoch = 8'h11;
        weight0_data = 8'sd11;
        weight1_data = -8'sd9;
        #1;
        if (weight_ready) begin
            $display("[FAIL] active bank overwrite reported ready");
            failures = failures + 1;
        end
        @(negedge clk);
        weight_valid = 1'b0;

        // A stale epoch is rejected without entering the multiplier pipeline.
        @(negedge clk);
        token_valid = 1'b1;
        token_weight_bank = 1'b1;
        token_weight_epoch = 8'h21;
        token_ifm = -8'sd3;
        token_psum0 = 32'sd1;
        token_psum1 = 32'sd2;
        @(posedge clk);
        if (token_ready) begin
            $display("[FAIL] stale epoch token was accepted");
            failures = failures + 1;
        end
        @(negedge clk);
        token_valid = 1'b0;

        // Interleave both banks with deterministic random bubbles.  The output
        // also experiences pseudo-random backpressure from the LFSR above.
        for (n = 0; n < 80; n = n + 1) begin
            repeat ((n * 7 + 3) % 4) @(negedge clk);
            if (n[0])
                send_token(1'b1, 8'h20, $signed((n * 13) & 8'hff),
                           n * 101 - 3000, 9000 - n * 37);
            else
                send_token(1'b0, 8'h10, $signed((n * 9) & 8'hff),
                           n * 73 - 5000, n * 29 + 17);
        end

        drain_timeout = 0;
        while ((retired_token_count != accepted_token_count ||
                total_outstanding != 0 || result_valid) && drain_timeout < 1000) begin
            @(negedge clk);
            drain_timeout = drain_timeout + 1;
        end
        if (drain_timeout >= 1000) begin
            $display("[FAIL] timed out draining tagged MAC");
            failures = failures + 1;
        end

        // Once the last bank0 result retires, the bank can be safely reused.
        load_weight(1'b0, 8'h11, 8'sd11, -8'sd9);
        send_token(1'b0, 8'h11, -8'sd6, 32'sd700, -32'sd400);

        drain_timeout = 0;
        while ((retired_token_count != accepted_token_count || result_valid) &&
               drain_timeout < 200) begin
            @(negedge clk);
            drain_timeout = drain_timeout + 1;
        end

        if (!shadow_load_while_active_seen) begin
            $display("[FAIL] did not observe bank1 load while bank0 was active");
            failures = failures + 1;
        end
        if (blocked_weight_write_count !== 1) begin
            $display("[FAIL] blocked write count=%0d expected=1",
                     blocked_weight_write_count);
            failures = failures + 1;
        end
        if (!ownership_error_sticky) begin
            $display("[FAIL] blocked overwrite did not set ownership sticky");
            failures = failures + 1;
        end
        if (bad_bank_token_count !== 1 || !bank_tag_error_sticky) begin
            $display("[FAIL] bad-bank telemetry count=%0d sticky=%0d",
                     bad_bank_token_count, bank_tag_error_sticky);
            failures = failures + 1;
        end
        if (epoch_mismatch_count !== 1 || !epoch_error_sticky) begin
            $display("[FAIL] epoch telemetry count=%0d sticky=%0d",
                     epoch_mismatch_count, epoch_error_sticky);
            failures = failures + 1;
        end
        if (protocol_error_sticky) begin
            $display("[FAIL] internal protocol error asserted");
            failures = failures + 1;
        end
        if (accepted_token_count !== TOKEN_TOTAL ||
            retired_token_count !== TOKEN_TOTAL || wr_index != TOKEN_TOTAL ||
            rd_index != TOKEN_TOTAL) begin
            $display("[FAIL] lifetime counts accept=%0d retire=%0d wr=%0d rd=%0d expected=%0d",
                     accepted_token_count, retired_token_count,
                     wr_index, rd_index, TOKEN_TOTAL);
            failures = failures + 1;
        end
        if (bank0_inflight != 0 || bank1_inflight != 0 ||
            total_outstanding != 0) begin
            $display("[FAIL] ownership did not drain b0=%0d b1=%0d total=%0d",
                     bank0_inflight, bank1_inflight, total_outstanding);
            failures = failures + 1;
        end

        if (failures == 0)
            $display("PASS tb_systolic_pe_shadow_weight (%0d tagged tokens)", TOKEN_TOTAL);
        else
            $fatal(1, "FAIL tb_systolic_pe_shadow_weight failures=%0d", failures);
        $finish;
    end
endmodule

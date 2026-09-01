`timescale 1ns / 1ps

// Exhaustive Boolean miter for the read-ready Shannon expansion used by
// psum_bank_owner_scoreboard.  Equality, ordering, and count comparisons are
// represented by their Boolean results; enumerating all 2^15 combinations is
// therefore a superset of every concrete scoreboard state and request value.
module tb_psum_bank_ready_cut_equiv;
    reg bank;
    reg fail_stop;
    reg bank0_allocated;
    reg bank0_epoch_match;
    reg bank0_context_match;
    reg bank0_order;
    reg bank0_credit;
    reg bank0_expected;
    reg bank1_allocated;
    reg bank1_epoch_match;
    reg bank1_context_match;
    reg bank1_order;
    reg bank1_credit;
    reg bank1_expected;
    reg addr_valid;

    wire selected_allocated = bank ? bank1_allocated : bank0_allocated;
    wire selected_epoch_match = bank ?
        bank1_epoch_match : bank0_epoch_match;
    wire selected_context_match = bank ?
        bank1_context_match : bank0_context_match;
    wire selected_epoch_ok = selected_allocated && selected_epoch_match;
    wire selected_context_ok = selected_allocated && selected_context_match;
    wire selected_identity = selected_epoch_ok && selected_context_ok;
    wire selected_order = bank ? bank1_order : bank0_order;
    wire selected_credit = bank ? bank1_credit : bank0_credit;
    wire selected_expected = bank ? bank1_expected : bank0_expected;
    wire old_ready = !fail_stop && selected_identity && addr_valid &&
        selected_order && selected_credit && selected_expected;

    wire bank0_identity = bank0_allocated && bank0_epoch_match &&
        bank0_context_match;
    wire bank1_identity = bank1_allocated && bank1_epoch_match &&
        bank1_context_match;
    wire bank0_ready = !fail_stop && bank0_identity && addr_valid &&
        bank0_order && bank0_credit && bank0_expected;
    wire bank1_ready = !fail_stop && bank1_identity && addr_valid &&
        bank1_order && bank1_credit && bank1_expected;
    wire expanded_ready = bank ? bank1_ready : bank0_ready;

    integer vector;
    integer comparisons;
    initial begin
        comparisons = 0;
        for (vector = 0; vector < 32768; vector = vector + 1) begin
            {bank, fail_stop,
             bank1_allocated, bank1_epoch_match, bank1_context_match,
             bank1_order, bank1_credit, bank1_expected,
             bank0_allocated, bank0_epoch_match, bank0_context_match,
             bank0_order, bank0_credit, bank0_expected,
             addr_valid} = vector[14:0];
            #1;
            comparisons = comparisons + 1;
            if (expanded_ready !== old_ready) begin
                $display("[FAIL] ready miter vector=%04x old=%b expanded=%b",
                         vector[14:0], old_ready, expanded_ready);
                $fatal(1);
            end
            if ((!bank && expanded_ready !== bank0_ready) ||
                (bank && expanded_ready !== bank1_ready)) begin
                $display("[FAIL] final bank select vector=%04x bank=%b",
                         vector[14:0], bank);
                $fatal(1);
            end
        end
        $display("PASS: exhaustive PSUM bank-ready cut miter (%0d vectors)",
                 comparisons);
        $finish;
    end
endmodule

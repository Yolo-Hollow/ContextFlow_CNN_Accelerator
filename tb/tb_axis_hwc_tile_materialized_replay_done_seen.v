`timescale 1ns / 1ps

// Focused join test for the materializer/cache completion pulses.  The two
// large datapath children are intentionally left unconnected and their four
// relevant status wires are forced; this isolates the wrapper state without
// duplicating a full layer-stream test.
module tb_axis_hwc_tile_materialized_replay_done_seen;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg cfg_start = 1'b0;
    reg forced_materializer_done = 1'b0;
    reg forced_cache_done = 1'b0;
    reg forced_bank0_owned = 1'b1;
    wire materialize_done;

    integer failures = 0;
    integer done_pulses = 0;

    always #5 clk = ~clk;
    always @(posedge clk)
        if (!rst && materialize_done)
            done_pulses = done_pulses + 1;

    axis_hwc_tile_materialized_replay #(
        .ROWS(18), .AXIS_W(64), .KEEP_W(8),
        .MAX_FM_W(2), .MAX_CHANNELS(18),
        .LINE_BANK_DEPTH(4), .MAX_PASSES(2),
        .TILE_W(2), .CACHE_AW(2), .CACHE_DEPTH(4)
    ) dut (
        .clk(clk), .rst(rst), .cfg_start(cfg_start),
        .materialize_done(materialize_done)
    );

    initial begin
        force dut.materializer_done = forced_materializer_done;
        force dut.cache_materialize_done = forced_cache_done;
        force dut.cache_bank0_owned = forced_bank0_owned;
        force dut.cache_bank1_owned = 1'b0;
        force dut.replay_active = 1'b0;
        force dut.fill_req_pending = 1'b0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Materializer completion arrives first.
        forced_materializer_done = 1'b1;
        @(posedge clk);
        @(negedge clk);
        forced_materializer_done = 1'b0;
        if (!dut.materializer_done_seen_q || materialize_done) begin
            $display("[FAIL] early materializer_done was not held privately");
            failures = failures + 1;
        end

        // A cfg_start rejected by the owned cache must not clear done_seen.
        cfg_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        cfg_start = 1'b0;
        if (!dut.materializer_done_seen_q) begin
            $display("[FAIL] busy cfg_start erased materializer_done_seen");
            failures = failures + 1;
        end

        // Model cache completion becoming registered just after an edge.  The
        // joined pulse remains asserted until exactly the following edge.
        @(posedge clk);
        #1 forced_cache_done = 1'b1;
        @(negedge clk);
        if (!materialize_done) begin
            $display("[FAIL] delayed cache commit did not join completion");
            failures = failures + 1;
        end
        @(posedge clk);
        @(negedge clk);
        if (materialize_done || dut.materializer_done_seen_q ||
            done_pulses != 1) begin
            $display("[FAIL] delayed join was not an exactly-once pulse count=%0d",
                     done_pulses);
            failures = failures + 1;
        end
        forced_cache_done = 1'b0;

        // Reset while waiting for cache completion must cancel the sticky bit.
        forced_materializer_done = 1'b1;
        @(posedge clk);
        @(negedge clk);
        forced_materializer_done = 1'b0;
        rst = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        if (dut.materializer_done_seen_q) begin
            $display("[FAIL] reset retained materializer_done_seen");
            failures = failures + 1;
        end
        @(posedge clk);
        #1 forced_cache_done = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (materialize_done || done_pulses != 1) begin
            $display("[FAIL] stale cache_done escaped after reset count=%0d",
                     done_pulses);
            failures = failures + 1;
        end
        forced_cache_done = 1'b0;

        // Conversely, an idle/new configuration is allowed to discard a
        // stale unmatched materializer pulse from an abandoned context.
        forced_materializer_done = 1'b1;
        @(posedge clk);
        @(negedge clk);
        forced_materializer_done = 1'b0;
        forced_bank0_owned = 1'b0;
        cfg_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        cfg_start = 1'b0;
        if (dut.materializer_done_seen_q) begin
            $display("[FAIL] idle cfg_start retained stale done_seen");
            failures = failures + 1;
        end

        // Same-cycle pulses remain supported and produce one joined pulse.
        @(posedge clk);
        #1 begin
            forced_materializer_done = 1'b1;
            forced_cache_done = 1'b1;
        end
        @(posedge clk);
        @(negedge clk);
        forced_materializer_done = 1'b0;
        forced_cache_done = 1'b0;
        #1;
        if (materialize_done || done_pulses != 2) begin
            $display("[FAIL] same-cycle join pulse count=%0d", done_pulses);
            failures = failures + 1;
        end

        if (failures == 0)
            $display("[PASS] tile replay materialize_done join checks=6");
        else
            $display("[FAIL] tile replay materialize_done join failures=%0d",
                     failures);
        release dut.materializer_done;
        release dut.cache_materialize_done;
        release dut.cache_bank0_owned;
        release dut.cache_bank1_owned;
        release dut.replay_active;
        release dut.fill_req_pending;
        $finish;
    end
endmodule

`timescale 1ns / 1ps

module tb_context_lifecycle_queue;
    localparam DEPTH = 4;
    localparam AW = 2;
    localparam EPOCH_W = 8;
    localparam TILE_W = 16;
    localparam COUT_W = 11;
    localparam K_PASS_W = 14;
    localparam PIXEL_W = 16;
    localparam CONTEXT_W = 16;
    localparam DESC_W = EPOCH_W + 1 + TILE_W + COUT_W + COUT_W +
        K_PASS_W + PIXEL_W + 1 + 1 + 1 + 1 + EPOCH_W +
        CONTEXT_W + CONTEXT_W;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg push_valid = 1'b0;
    wire push_ready;
    reg [EPOCH_W-1:0] push_epoch = 0;
    reg push_ifm_bank = 0;
    reg [TILE_W-1:0] push_tile = 0;
    reg [COUT_W-1:0] push_cout_base = 0;
    reg [COUT_W-1:0] push_cout_valid = 0;
    reg [K_PASS_W-1:0] push_k_pass = 0;
    reg [PIXEL_W-1:0] push_num_pixels = 0;
    reg push_first = 0;
    reg push_final = 0;
    reg push_psum_rd_bank = 0;
    reg push_psum_wr_bank = 0;
    reg [EPOCH_W-1:0] push_parent_epoch = 0;
    reg [CONTEXT_W-1:0] push_parent_context = 0;
    reg [CONTEXT_W-1:0] push_context_id = 0;

    wire pop_valid;
    reg pop_ready = 1'b0;
    wire [EPOCH_W-1:0] pop_epoch;
    wire pop_ifm_bank;
    wire [TILE_W-1:0] pop_tile;
    wire [COUT_W-1:0] pop_cout_base;
    wire [COUT_W-1:0] pop_cout_valid;
    wire [K_PASS_W-1:0] pop_k_pass;
    wire [PIXEL_W-1:0] pop_num_pixels;
    wire pop_first;
    wire pop_final;
    wire pop_psum_rd_bank;
    wire pop_psum_wr_bank;
    wire [EPOCH_W-1:0] pop_parent_epoch;
    wire [CONTEXT_W-1:0] pop_parent_context;
    wire [CONTEXT_W-1:0] pop_context_id;
    wire empty;
    wire full;
    wire [AW:0] level;
    wire [31:0] push_count;
    wire [31:0] pop_count;
    wire overflow_sticky;
    wire [31:0] overflow_count;
    wire underflow_sticky;
    wire [31:0] underflow_count;

    context_lifecycle_queue #(
        .DEPTH(DEPTH), .AW(AW), .EPOCH_W(EPOCH_W),
        .TILE_W(TILE_W), .COUT_W(COUT_W), .K_PASS_W(K_PASS_W),
        .PIXEL_W(PIXEL_W), .CONTEXT_W(CONTEXT_W),
        .REGISTERED_HEAD(1)
    ) dut (
        .clk(clk), .rst(rst),
        .push_valid(push_valid), .push_ready(push_ready),
        .push_epoch(push_epoch), .push_ifm_bank(push_ifm_bank),
        .push_tile(push_tile), .push_cout_base(push_cout_base),
        .push_cout_valid(push_cout_valid), .push_k_pass(push_k_pass),
        .push_num_pixels(push_num_pixels), .push_first(push_first),
        .push_final(push_final), .push_psum_rd_bank(push_psum_rd_bank),
        .push_psum_wr_bank(push_psum_wr_bank),
        .push_parent_epoch(push_parent_epoch),
        .push_parent_context(push_parent_context),
        .push_context_id(push_context_id),
        .pop_valid(pop_valid), .pop_ready(pop_ready),
        .pop_epoch(pop_epoch), .pop_ifm_bank(pop_ifm_bank),
        .pop_tile(pop_tile), .pop_cout_base(pop_cout_base),
        .pop_cout_valid(pop_cout_valid), .pop_k_pass(pop_k_pass),
        .pop_num_pixels(pop_num_pixels), .pop_first(pop_first),
        .pop_final(pop_final), .pop_psum_rd_bank(pop_psum_rd_bank),
        .pop_psum_wr_bank(pop_psum_wr_bank),
        .pop_parent_epoch(pop_parent_epoch),
        .pop_parent_context(pop_parent_context),
        .pop_context_id(pop_context_id),
        .empty(empty), .full(full), .level(level),
        .push_count(push_count), .pop_count(pop_count),
        .overflow_sticky(overflow_sticky),
        .overflow_count(overflow_count),
        .underflow_sticky(underflow_sticky),
        .underflow_count(underflow_count)
    );

    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;
    integer i;
    integer produced;
    integer consumed;
    integer random_cycles;
    reg [15:0] lfsr;
    reg push_fire_sample;
    reg pop_fire_sample;
    reg [DESC_W-1:0] oracle_queue [0:DEPTH-1];
    integer oracle_level;
    integer oracle_push_count;
    integer oracle_pop_count;
    integer oracle_overflow_count;
    integer oracle_underflow_count;
    reg oracle_overflow_sticky;
    reg oracle_underflow_sticky;
    reg oracle_overflow_episode;
    reg oracle_underflow_episode;
    reg oracle_push_fire;
    reg oracle_pop_fire;
    reg oracle_overflow_attempt;
    reg oracle_underflow_attempt;
    integer oracle_next_level;
    integer oracle_i;

    wire [DESC_W-1:0] push_desc_packed = {
        push_epoch, push_ifm_bank, push_tile, push_cout_base,
        push_cout_valid, push_k_pass, push_num_pixels, push_first,
        push_final, push_psum_rd_bank, push_psum_wr_bank,
        push_parent_epoch, push_parent_context, push_context_id
    };
    wire [DESC_W-1:0] pop_desc_packed = {
        pop_epoch, pop_ifm_bank, pop_tile, pop_cout_base,
        pop_cout_valid, pop_k_pass, pop_num_pixels, pop_first,
        pop_final, pop_psum_rd_bank, pop_psum_wr_bank,
        pop_parent_epoch, pop_parent_context, pop_context_id
    };

    task check;
        input condition;
        input [8*96-1:0] message;
        begin
            if (condition)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task set_descriptor;
        input integer index;
        begin
            push_epoch = 8'h31 + index;
            push_ifm_bank = index & 1;
            push_tile = 16'h1000 + index;
            push_cout_base = index * 3;
            push_cout_valid = (index % 31) + 1;
            push_k_pass = index * 5;
            push_num_pixels = (index % 1024) + 1;
            push_first = ((index % 5) == 0);
            push_final = ((index % 7) == 0);
            push_psum_rd_bank = (index >> 1) & 1;
            push_psum_wr_bank = ~((index >> 1) & 1);
            push_parent_epoch = 8'h21 + index;
            push_parent_context = 16'h8000 + index;
            push_context_id = 16'h4000 + index;
        end
    endtask

    task check_descriptor;
        input integer index;
        begin
            check(
                (pop_epoch == ((8'h31 + index) & 8'hff)) &&
                (pop_ifm_bank == (index & 1)) &&
                (pop_tile == (16'h1000 + index)) &&
                (pop_cout_base == (index * 3)) &&
                (pop_cout_valid == ((index % 31) + 1)) &&
                (pop_k_pass == (index * 5)) &&
                (pop_num_pixels == ((index % 1024) + 1)) &&
                (pop_first == ((index % 5) == 0)) &&
                (pop_final == ((index % 7) == 0)) &&
                (pop_psum_rd_bank == ((index >> 1) & 1)) &&
                (pop_psum_wr_bank == !((index >> 1) & 1)) &&
                (pop_parent_epoch == ((8'h21 + index) & 8'hff)) &&
                (pop_parent_context == (16'h8000 + index)) &&
                (pop_context_id == (16'h4000 + index)),
                "all lifecycle descriptor fields preserve atomic ordering");
        end
    endtask

    task push_one;
        input integer index;
        begin
            @(negedge clk);
            set_descriptor(index);
            push_valid = 1'b1;
            #1;
            check(push_ready, "ordinary descriptor push ready");
            @(negedge clk);
            push_valid = 1'b0;
        end
    endtask

    task pop_one;
        input integer index;
        begin
            @(negedge clk);
            pop_ready = 1'b1;
            #1;
            check(pop_valid, "ordinary descriptor pop valid");
            if (pop_valid)
                check_descriptor(index);
            @(negedge clk);
            pop_ready = 1'b0;
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk);
            rst = 1'b1;
            push_valid = 1'b0;
            pop_ready = 1'b0;
            repeat (3) @(negedge clk);
            rst = 1'b0;
            @(negedge clk);
        end
    endtask

    // Cycle-accurate independent FIFO oracle.  It checks the visible state
    // before each active edge, then applies exactly the handshakes sampled by
    // the RTL.  This covers adjacent no-bubble transfers as well as directed
    // boundary sequences below without relying on internal DUT state.
    always @(posedge clk) begin
        if (rst) begin
            oracle_level = 0;
            oracle_push_count = 0;
            oracle_pop_count = 0;
            oracle_overflow_count = 0;
            oracle_underflow_count = 0;
            oracle_overflow_sticky = 1'b0;
            oracle_underflow_sticky = 1'b0;
            oracle_overflow_episode = 1'b0;
            oracle_underflow_episode = 1'b0;
        end else begin
            check(pop_valid === (oracle_level != 0),
                  "cycle oracle: pop_valid matches occupancy");
            check(empty === (oracle_level == 0),
                  "cycle oracle: empty matches occupancy");
            check(full === (oracle_level == DEPTH),
                  "cycle oracle: full matches occupancy");
            check(level === oracle_level[AW:0],
                  "cycle oracle: level matches occupancy");
            check(push_ready ===
                      ((oracle_level != DEPTH) || pop_ready),
                  "cycle oracle: full replacement ready is exact");
            if (oracle_level != 0)
                check(pop_desc_packed === oracle_queue[0],
                      "cycle oracle: registered head descriptor is exact");
            else
                check(pop_desc_packed === {DESC_W{1'b0}},
                      "cycle oracle: invalid descriptor output is zero");
            check(push_count === oracle_push_count[31:0],
                  "cycle oracle: push counter is exact");
            check(pop_count === oracle_pop_count[31:0],
                  "cycle oracle: pop counter is exact");
            check(overflow_count === oracle_overflow_count[31:0] &&
                      overflow_sticky === oracle_overflow_sticky,
                  "cycle oracle: overflow telemetry is exact");
            check(underflow_count === oracle_underflow_count[31:0] &&
                      underflow_sticky === oracle_underflow_sticky,
                  "cycle oracle: underflow telemetry is exact");

            oracle_push_fire = push_valid && push_ready;
            oracle_pop_fire = pop_ready && pop_valid;
            oracle_overflow_attempt = push_valid && !push_ready;
            oracle_underflow_attempt = pop_ready && !pop_valid;

            if (oracle_overflow_attempt) begin
                oracle_overflow_sticky = 1'b1;
                if (!oracle_overflow_episode)
                    oracle_overflow_count = oracle_overflow_count + 1;
            end
            if (oracle_underflow_attempt) begin
                oracle_underflow_sticky = 1'b1;
                if (!oracle_underflow_episode)
                    oracle_underflow_count = oracle_underflow_count + 1;
            end
            oracle_overflow_episode = oracle_overflow_attempt;
            oracle_underflow_episode = oracle_underflow_attempt;

            oracle_next_level = oracle_level;
            if (oracle_pop_fire) begin
                for (oracle_i = 0; oracle_i < oracle_level - 1;
                     oracle_i = oracle_i + 1)
                    oracle_queue[oracle_i] = oracle_queue[oracle_i + 1];
                oracle_next_level = oracle_next_level - 1;
                oracle_pop_count = oracle_pop_count + 1;
            end
            if (oracle_push_fire) begin
                oracle_queue[oracle_next_level] = push_desc_packed;
                oracle_next_level = oracle_next_level + 1;
                oracle_push_count = oracle_push_count + 1;
            end
            oracle_level = oracle_next_level;
        end
    end

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        check(empty && !full && level == 0 && !pop_valid,
              "queue resets empty");

        // Fill every slot and verify the stable head.
        for (i = 0; i < DEPTH; i = i + 1)
            push_one(i);
        check(full && !empty && level == DEPTH,
              "queue reports exact full level");
        check_descriptor(0);

        // Hold a fifth descriptor against full backpressure.  This is one
        // unavailable episode, not one overflow count per held cycle.
        @(negedge clk);
        set_descriptor(99);
        push_valid = 1'b1;
        pop_ready = 1'b0;
        repeat (3) begin
            #1;
            check(!push_ready && full,
                  "held-valid descriptor waits while queue full");
            @(negedge clk);
        end
        check(overflow_sticky && overflow_count == 1,
              "held full request produces one overflow episode");

        // A same-cycle pop makes room for the held push.  At full depth the
        // pointers alias, so this specifically proves old-head read plus
        // new-tail replacement is lossless.
        pop_ready = 1'b1;
        #1;
        check(pop_valid && push_ready,
              "full queue accepts simultaneous pop and push");
        check_descriptor(0);
        @(negedge clk);
        push_valid = 1'b0;
        pop_ready = 1'b0;
        check(full && level == DEPTH,
              "same-cycle replacement preserves full occupancy");
        check(push_count == 5 && pop_count == 1,
              "same-cycle replacement counts both handshakes");

        pop_one(1);
        pop_one(2);
        pop_one(3);
        pop_one(99);
        check(empty && level == 0, "replacement drains in FIFO order");

        // Empty ready may be held.  It creates one diagnostic underflow
        // episode, then automatically consumes a later descriptor without
        // dropping or duplicating it.
        pop_ready = 1'b1;
        repeat (3) begin
            #1;
            check(!pop_valid, "held pop-ready waits while queue empty");
            @(negedge clk);
        end
        check(underflow_sticky && underflow_count == 1,
              "held empty request produces one underflow episode");
        set_descriptor(123);
        push_valid = 1'b1;
        #1;
        check(push_ready && !pop_valid,
              "empty queue is registered rather than fall-through");
        @(negedge clk);
        push_valid = 1'b0;
        #1;
        check(pop_valid, "held pop-ready sees descriptor after push edge");
        check_descriptor(123);
        @(negedge clk);
        pop_ready = 1'b0;
        check(empty, "held-ready descriptor consumed exactly once");
        check(overflow_count == 1 && underflow_count == 1,
              "unavailable episode counts remain de-duplicated");

        // Reset clears telemetry and exercise two complete pointer wraps.
        reset_dut();
        for (i = 0; i < DEPTH; i = i + 1)
            push_one(i + 10);
        for (i = 0; i < DEPTH; i = i + 1)
            pop_one(i + 10);
        for (i = 0; i < DEPTH; i = i + 1)
            push_one(i + 20);
        for (i = 0; i < DEPTH; i = i + 1)
            pop_one(i + 20);
        check(empty && level == 0, "read/write pointers wrap cleanly");
        check(push_count == 8 && pop_count == 8,
              "wrap sequence handshake counters exact");
        check(!overflow_sticky && !underflow_sticky,
              "clean wrap sequence has no unavailable attempts");

        // A one-entry pop+push cannot prefetch from RAM: the replacement is
        // written on this edge and therefore must bypass directly into the
        // registered head.
        reset_dut();
        push_one(300);
        @(negedge clk);
        set_descriptor(301);
        push_valid = 1'b1;
        pop_ready = 1'b1;
        #1;
        check(pop_valid && push_ready && level == 1,
              "single-entry queue accepts direct replacement");
        check_descriptor(300);
        @(negedge clk);
        push_valid = 1'b0;
        pop_ready = 1'b0;
        check(level == 1 && pop_valid,
              "single-entry replacement preserves occupancy");
        check_descriptor(301);
        pop_one(301);
        check(empty, "single-entry replacement drains exactly once");

        // With two or more entries, a pop must prefetch the second RAM entry
        // into the head register.  Exercise it both alone and alongside a
        // new tail write so the queue sustains one descriptor per clock.
        reset_dut();
        push_one(310);
        push_one(311);
        push_one(312);
        pop_one(310);
        check_descriptor(311);
        @(negedge clk);
        set_descriptor(313);
        push_valid = 1'b1;
        pop_ready = 1'b1;
        #1;
        check_descriptor(311);
        @(negedge clk);
        push_valid = 1'b0;
        pop_ready = 1'b0;
        check(level == 2, "prefetch plus tail write preserves occupancy");
        check_descriptor(312);
        pop_one(312);
        pop_one(313);
        check(empty, "registered prefetch sequence preserves FIFO order");

        // Keep a full queue replacing its head on every clock.  This makes
        // the one-descriptor-per-clock contract explicit across repeated RAM
        // prefetches, tail writes, pointer wrap and full-pointer aliasing.
        reset_dut();
        for (i = 0; i < DEPTH; i = i + 1)
            push_one(i + 400);
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge clk);
            set_descriptor(i + 404);
            push_valid = 1'b1;
            pop_ready = 1'b1;
            #1;
            check(full && push_ready && pop_valid,
                  "full queue sustains one replacement per clock");
            check_descriptor(i + 400);
        end
        @(negedge clk);
        push_valid = 1'b0;
        pop_ready = 1'b0;
        check(full && level == DEPTH,
              "sustained replacement keeps exact full occupancy");
        for (i = 0; i < DEPTH; i = i + 1)
            pop_one(i + 408);
        check(empty, "sustained replacement tail drains in FIFO order");

        // Random producer gaps and consumer backpressure.  Requests are only
        // launched when the relevant side is available so this phase must not
        // add overflow/underflow diagnostics.
        reset_dut();
        produced = 0;
        consumed = 0;
        random_cycles = 0;
        lfsr = 16'h1ace;
        while (consumed < 96 && random_cycles < 5000) begin
            @(negedge clk);
            push_valid = 1'b0;
            pop_ready = 1'b0;
            if ((produced < 96) && !full && (lfsr[0] || lfsr[3])) begin
                set_descriptor(produced + 200);
                push_valid = 1'b1;
            end
            if (pop_valid && (lfsr[1] || lfsr[4]))
                pop_ready = 1'b1;
            #1;
            push_fire_sample = push_valid && push_ready;
            pop_fire_sample = pop_valid && pop_ready;
            if (pop_fire_sample)
                check_descriptor(consumed + 200);
            lfsr = {lfsr[14:0],
                    lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            @(posedge clk);
            #1;
            if (push_fire_sample)
                produced = produced + 1;
            if (pop_fire_sample)
                consumed = consumed + 1;
            random_cycles = random_cycles + 1;
        end
        @(negedge clk);
        push_valid = 1'b0;
        pop_ready = 1'b0;
        check(produced == 96 && consumed == 96,
              "random-backpressure phase transfers every descriptor");
        check(empty && level == 0,
              "random-backpressure phase finishes empty");
        check(push_count == 96 && pop_count == 96,
              "random-backpressure handshake counts exact");
        check(!overflow_sticky && !underflow_sticky,
              "available-only random requests produce no diagnostics");

        $display("=== tb_context_lifecycle_queue: %0d pass, %0d fail ===",
                 pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        repeat (12000) @(negedge clk);
        $display("[FAIL] timeout level=%0d push=%0d pop=%0d ov=%0d uf=%0d",
                 level, push_count, pop_count,
                 overflow_count, underflow_count);
        $fatal(1);
    end
endmodule

`timescale 1ns / 1ps

module tb_systolic_result_tagged_fifo;
    localparam DATA_W = 64;
    localparam TAG_W = 10;
    localparam DEPTH = 4;
    localparam AW = 2;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg wr_en = 1'b0;
    reg rd_en = 1'b0;
    reg [DATA_W-1:0] data_in = {DATA_W{1'b0}};
    reg [TAG_W-1:0] tag_in = {TAG_W{1'b0}};
    wire [DATA_W-1:0] data_out;
    wire [TAG_W-1:0] tag_out;
    wire empty;
    wire full;

    systolic_result_tagged_fifo #(
        .DATA_W(DATA_W),
        .TAG_W(TAG_W),
        .DEPTH(DEPTH),
        .AW(AW)
    ) dut (
        .clk(clk),
        .rst(rst),
        .wr_en(wr_en),
        .rd_en(rd_en),
        .data_in(data_in),
        .tag_in(tag_in),
        .data_out(data_out),
        .tag_out(tag_out),
        .empty(empty),
        .full(full)
    );

    integer pass_count = 0;
    integer fail_count = 0;
    integer ref_count = 0;
    integer ref_wr_idx = 0;
    integer ref_rd_idx = 0;
    integer ref_write_count = 0;
    integer ref_read_count = 0;
    integer ref_wr_wrap_count = 0;
    integer ref_rd_wrap_count = 0;
    integer held_full_cycles = 0;
    integer held_empty_cycles = 0;
    integer random_cycle;
    integer write_sequence;
    reg ref_write_fire = 1'b0;
    reg ref_read_fire = 1'b0;
    reg [DATA_W-1:0] ref_data_mem [0:DEPTH-1];
    reg [TAG_W-1:0] ref_tag_mem [0:DEPTH-1];
    reg [DATA_W-1:0] ref_last_data = {DATA_W{1'b0}};
    reg [TAG_W-1:0] ref_last_tag = {TAG_W{1'b0}};
    reg [31:0] lfsr = 32'h1ace_b00c;
    reg wr_pending = 1'b0;
    reg rd_pending = 1'b0;
    reg [DATA_W-1:0] held_data = {DATA_W{1'b0}};
    reg [TAG_W-1:0] held_tag = {TAG_W{1'b0}};

    task check;
        input condition;
        input [511:0] message;
        begin
            if (condition)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task push;
        input [DATA_W-1:0] value;
        input [TAG_W-1:0] tag;
        begin
            @(negedge clk);
            data_in = value;
            tag_in = tag;
            wr_en = 1'b1;
            @(negedge clk);
            wr_en = 1'b0;
        end
    endtask

    task pop_and_check;
        input [DATA_W-1:0] expected_value;
        input [TAG_W-1:0] expected_tag;
        begin
            @(negedge clk);
            rd_en = 1'b1;
            @(negedge clk);
            rd_en = 1'b0;
            #1;
            check(data_out == expected_value,
                  "payload follows FIFO order");
            check(tag_out == expected_tag,
                  "tag remains atomic with its payload");
        end
    endtask

    // Drive exactly one clock and compare the registered FIFO boundary to an
    // occupancy/data reference model.  Acceptance is intentionally derived
    // from the pre-edge occupancy so this also checks the non-replacement
    // full boundary and the non-fall-through empty boundary on every cycle.
    task reference_cycle;
        input drive_wr;
        input drive_rd;
        input [DATA_W-1:0] drive_data;
        input [TAG_W-1:0] drive_tag;
        begin
            @(negedge clk);
            wr_en = drive_wr;
            rd_en = drive_rd;
            data_in = drive_data;
            tag_in = drive_tag;

            #1;
            if ((empty !== (ref_count == 0)) ||
                (full !== (ref_count == DEPTH))) begin
                $display("[FAIL] pre-edge flag mismatch count=%0d empty=%b full=%b",
                         ref_count, empty, full);
                $fatal(1);
            end

            ref_write_fire = drive_wr && (ref_count != DEPTH);
            ref_read_fire = drive_rd && (ref_count != 0);
            if (drive_wr && !ref_write_fire)
                held_full_cycles = held_full_cycles + 1;
            if (drive_rd && !ref_read_fire)
                held_empty_cycles = held_empty_cycles + 1;

            @(posedge clk);
            if (ref_read_fire) begin
                ref_last_data = ref_data_mem[ref_rd_idx];
                ref_last_tag = ref_tag_mem[ref_rd_idx];
                if (ref_rd_idx == DEPTH-1) begin
                    ref_rd_idx = 0;
                    ref_rd_wrap_count = ref_rd_wrap_count + 1;
                end else
                    ref_rd_idx = ref_rd_idx + 1;
                ref_read_count = ref_read_count + 1;
            end
            if (ref_write_fire) begin
                ref_data_mem[ref_wr_idx] = drive_data;
                ref_tag_mem[ref_wr_idx] = drive_tag;
                if (ref_wr_idx == DEPTH-1) begin
                    ref_wr_idx = 0;
                    ref_wr_wrap_count = ref_wr_wrap_count + 1;
                end else
                    ref_wr_idx = ref_wr_idx + 1;
                ref_write_count = ref_write_count + 1;
            end
            ref_count = ref_count + ref_write_fire - ref_read_fire;

            #1;
            if ((empty !== (ref_count == 0)) ||
                (full !== (ref_count == DEPTH))) begin
                $display("[FAIL] next-state flag mismatch count=%0d wr=%b/%b rd=%b/%b empty=%b full=%b",
                         ref_count, drive_wr, ref_write_fire,
                         drive_rd, ref_read_fire, empty, full);
                $fatal(1);
            end
            if ((data_out !== ref_last_data) ||
                (tag_out !== ref_last_tag)) begin
                $display("[FAIL] atomic output mismatch data=%h/%h tag=%h/%h count=%0d",
                         data_out, ref_last_data, tag_out, ref_last_tag,
                         ref_count);
                $fatal(1);
            end
            pass_count = pass_count + 2;
        end
    endtask

    localparam [DATA_W-1:0] DATA0 = 64'h0011_2233_4455_6677;
    localparam [DATA_W-1:0] DATA1 = 64'h1021_3243_5465_7687;
    localparam [DATA_W-1:0] DATA2 = 64'h2031_4253_6475_8697;
    localparam [DATA_W-1:0] DATA3 = 64'h3041_5263_7485_96a7;
    localparam [DATA_W-1:0] DATA4 = 64'h4051_6273_8495_a6b7;
    localparam [DATA_W-1:0] DATA5 = 64'h5061_7283_94a5_b6c7;
    localparam [DATA_W-1:0] BLOCKED_DATA = 64'hdead_beef_cafe_f00d;
    localparam [TAG_W-1:0] TAG0 = 10'h041;
    localparam [TAG_W-1:0] TAG1 = 10'h0a2;
    localparam [TAG_W-1:0] TAG2 = 10'h103;
    localparam [TAG_W-1:0] TAG3 = 10'h164;
    localparam [TAG_W-1:0] TAG4 = 10'h1c5;
    localparam [TAG_W-1:0] TAG5 = 10'h226;
    localparam [TAG_W-1:0] BLOCKED_TAG = 10'h3ff;

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        #1;
        check(empty && !full, "reset leaves FIFO empty");
        check(data_out == 0 && tag_out == 0,
              "reset clears the registered read outputs");

        push(DATA0, TAG0);
        push(DATA1, TAG1);
        push(DATA2, TAG2);
        push(DATA3, TAG3);
        #1;
        check(full && !empty, "four accepted writes fill a depth-four FIFO");

        // Match systolic_fifo exactly: while full, a simultaneous read is
        // accepted but the write is rejected rather than replacing the head.
        @(negedge clk);
        data_in = BLOCKED_DATA;
        tag_in = BLOCKED_TAG;
        wr_en = 1'b1;
        rd_en = 1'b1;
        @(negedge clk);
        wr_en = 1'b0;
        rd_en = 1'b0;
        #1;
        check(data_out == DATA0 && tag_out == TAG0,
              "full-cycle read returns the original atomic entry");
        check(!full && !empty,
              "full-cycle blocked write leaves one free entry");

        // Away from full/empty, simultaneous read and write both advance the
        // one shared pointer pair and keep occupancy unchanged.
        @(negedge clk);
        data_in = DATA4;
        tag_in = TAG4;
        wr_en = 1'b1;
        rd_en = 1'b1;
        @(negedge clk);
        wr_en = 1'b0;
        rd_en = 1'b0;
        #1;
        check(data_out == DATA1 && tag_out == TAG1,
              "simultaneous read/write preserves the outgoing pair");
        check(!full && !empty,
              "simultaneous read/write preserves occupancy");

        pop_and_check(DATA2, TAG2);
        pop_and_check(DATA3, TAG3);
        pop_and_check(DATA4, TAG4);
        #1;
        check(empty && !full, "all accepted entries drain exactly once");

        // Empty reads are ignored and must not disturb either half of the
        // registered atomic output.
        @(negedge clk);
        rd_en = 1'b1;
        @(negedge clk);
        rd_en = 1'b0;
        #1;
        check(data_out == DATA4 && tag_out == TAG4,
              "empty read holds the previous payload and tag");

        // At empty, the inverse boundary case accepts only the write.  The
        // newly written pair is not a fall-through read result.
        @(negedge clk);
        data_in = DATA5;
        tag_in = TAG5;
        wr_en = 1'b1;
        rd_en = 1'b1;
        @(negedge clk);
        wr_en = 1'b0;
        rd_en = 1'b0;
        #1;
        check(data_out == DATA4 && tag_out == TAG4,
              "empty-cycle simultaneous write/read holds the old output");
        check(!empty && !full,
              "empty-cycle simultaneous write/read accepts only the write");
        pop_and_check(DATA5, TAG5);
        check(empty, "entry written on an empty read cycle drains normally");

        // Start a clean reference-model phase.  The two explicit held cases
        // prove that a denied request can remain asserted until the next
        // credit without being accepted twice or corrupting its atomic pair.
        @(negedge clk);
        rst = 1'b1;
        wr_en = 1'b0;
        rd_en = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        ref_count = 0;
        ref_wr_idx = 0;
        ref_rd_idx = 0;
        ref_write_count = 0;
        ref_read_count = 0;
        ref_wr_wrap_count = 0;
        ref_rd_wrap_count = 0;
        ref_last_data = {DATA_W{1'b0}};
        ref_last_tag = {TAG_W{1'b0}};

        // Empty+write+read: accept only the write, then accept the held read.
        reference_cycle(1'b1, 1'b1, DATA0, TAG0);
        check(ref_write_fire && !ref_read_fire,
              "empty boundary accepts only write in reference phase");
        reference_cycle(1'b0, 1'b1, DATA0, TAG0);
        check(!ref_write_fire && ref_read_fire,
              "held empty read accepts once after data arrives");

        // Full+write+read: accept only the read, then accept the identical
        // held write on the first cycle whose registered credit is visible.
        reference_cycle(1'b1, 1'b0, DATA1, TAG1);
        reference_cycle(1'b1, 1'b0, DATA2, TAG2);
        reference_cycle(1'b1, 1'b0, DATA3, TAG3);
        reference_cycle(1'b1, 1'b0, DATA4, TAG4);
        check(full, "reference phase reaches exact full boundary");
        reference_cycle(1'b1, 1'b1, BLOCKED_DATA, BLOCKED_TAG);
        check(!ref_write_fire && ref_read_fire,
              "full boundary rejects replacement write");
        reference_cycle(1'b1, 1'b0, BLOCKED_DATA, BLOCKED_TAG);
        check(ref_write_fire && !ref_read_fire,
              "held full write accepts once after read credit appears");

        // Reset directly from full to prove that both registered credits and
        // both accepted-operation pointers return to their original phase.
        check(full && ref_count == DEPTH,
              "held full write restores exact full occupancy");
        @(negedge clk);
        rst = 1'b1;
        wr_en = 1'b0;
        rd_en = 1'b0;
        @(posedge clk);
        #1;
        check(empty && !full && data_out == 0 && tag_out == 0,
              "synchronous reset clears a full FIFO and read outputs");
        @(negedge clk);
        rst = 1'b0;
        ref_count = 0;
        ref_wr_idx = 0;
        ref_rd_idx = 0;
        ref_write_count = 0;
        ref_read_count = 0;
        ref_wr_wrap_count = 0;
        ref_rd_wrap_count = 0;
        ref_last_data = {DATA_W{1'b0}};
        ref_last_tag = {TAG_W{1'b0}};

        // Deterministic random held-valid/held-ready stress.  A pending write
        // keeps both payload and tag stable until accepted; a pending read
        // similarly stays asserted through empty.  More than one hundred
        // accepted pairs force many pointer and phase-bit wraps.
        write_sequence = 0;
        wr_pending = 1'b0;
        rd_pending = 1'b0;
        for (random_cycle = 0; random_cycle < 768;
             random_cycle = random_cycle + 1) begin
            if (!wr_pending && (lfsr[0] || lfsr[5])) begin
                wr_pending = 1'b1;
                held_data = {32'hc001_0000 ^ write_sequence,
                             lfsr ^ write_sequence};
                held_tag = write_sequence[TAG_W-1:0] ^
                           lfsr[TAG_W-1:0];
            end
            if (!rd_pending && (lfsr[1] || lfsr[7]))
                rd_pending = 1'b1;

            reference_cycle(wr_pending, rd_pending, held_data, held_tag);
            if (ref_write_fire) begin
                wr_pending = 1'b0;
                write_sequence = write_sequence + 1;
            end
            if (ref_read_fire)
                rd_pending = 1'b0;
            lfsr = {lfsr[30:0],
                    lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        end

        // Do not discard a write held at the end of the random window.  Give
        // it credit, then drain the exact reference occupancy.
        rd_pending = 1'b0;
        while (wr_pending) begin
            reference_cycle(1'b1, 1'b1, held_data, held_tag);
            if (ref_write_fire) begin
                wr_pending = 1'b0;
                write_sequence = write_sequence + 1;
            end
        end
        while (ref_count != 0)
            reference_cycle(1'b0, 1'b1, {DATA_W{1'b0}},
                            {TAG_W{1'b0}});
        reference_cycle(1'b0, 1'b0, {DATA_W{1'b0}},
                        {TAG_W{1'b0}});
        wr_en = 1'b0;
        rd_en = 1'b0;

        check(ref_write_count == ref_read_count && empty && !full,
              "random held traffic drains every accepted pair exactly once");
        check(ref_write_count > 100 && ref_wr_wrap_count > 20 &&
              ref_rd_wrap_count > 20,
              "random traffic exercises repeated write/read pointer wraps");
        check(held_full_cycles > 0 && held_empty_cycles > 0,
              "random and directed traffic cover both denied held boundaries");

        $display("=== tb_systolic_result_tagged_fifo: %0d pass, %0d fail ===",
                 pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        repeat (1400) @(posedge clk);
        $display("[FAIL] timeout");
        $fatal(1);
    end
endmodule

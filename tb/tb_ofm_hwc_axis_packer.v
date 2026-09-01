`timescale 1ns / 1ps

module tb_ofm_hwc_axis_packer;
    reg clk;
    reg rst;
    wire done16, done32, done_max, done_fault;
    wire [31:0] fail16, fail32, fail_max, fail_fault;

    always #5 clk = ~clk;

    ofm_hwc_axis_packer_case #(
        .CASE_ID(16), .COUT_TILE(16), .COUT_TOTAL(24), .PIXELS(3),
        .MAX_PIXELS(4), .MAX_COUT(32)
    ) u_case16 (
        .clk(clk), .rst(rst), .done(done16), .fail_count(fail16)
    );

    ofm_hwc_axis_packer_case #(
        .CASE_ID(32), .COUT_TILE(32), .COUT_TOTAL(19), .PIXELS(2),
        .MAX_PIXELS(4), .MAX_COUT(40)
    ) u_case32 (
        .clk(clk), .rst(rst), .done(done32), .fail_count(fail32)
    );

    // Full configured stride: 1024 channels / 32 channels per packet gives
    // the production maximum of 32 blocks per pixel.  Randomized READY makes
    // every word-boundary read occur after a varying number of stalled beats.
    ofm_hwc_axis_packer_case #(
        .CASE_ID(1024), .COUT_TILE(32), .COUT_TOTAL(1024), .PIXELS(3),
        .MAX_PIXELS(3), .MAX_COUT(1024), .RANDOM_READY(1)
    ) u_case_max (
        .clk(clk), .rst(rst), .done(done_max), .fail_count(fail_max)
    );

    ofm_hwc_axis_packer_fault_case u_fault (
        .clk(clk), .done(done_fault), .fail_count(fail_fault)
    );

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        repeat (4) @(negedge clk);
        rst = 1'b0;

        wait(done16 && done32 && done_max && done_fault);
        $display("=== tb_ofm_hwc_axis_packer: fail16=%0d fail32=%0d failmax=%0d fault=%0d ===",
                 fail16, fail32, fail_max, fail_fault);
        if ((fail16 != 0) || (fail32 != 0) || (fail_max != 0) ||
            (fail_fault != 0))
            $fatal(1);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "tb_ofm_hwc_axis_packer timeout");
    end

endmodule


// Fault-focused S0 checks use an independent reset so the two streaming/data
// cases above remain uninterrupted.  The tile has two packet locations: this
// makes a duplicate occupy the final reservation and proves ready reopens only
// after that bad S0 item is dropped.
module ofm_hwc_axis_packer_fault_case (
    input  wire        clk,
    output reg         done,
    output reg [31:0]  fail_count
);
    localparam integer COUT_TILE = 16;
    localparam integer MAX_PIXELS = 2;
    localparam integer MAX_COUT = 32;
    localparam integer PIXEL_INDEX_W = 1;
    localparam integer PIXEL_COUNT_W = 2;
    localparam integer COUT_W = 6;
    localparam integer BUFFER_DEPTH = 4;
    localparam integer COUT_TOTAL = 24;
    localparam integer EXPECTED_PACKETS = 2;

    reg rst;
    reg tile_begin_valid;
    wire tile_begin_ready;
    reg [PIXEL_COUNT_W-1:0] tile_pixels;
    reg [COUT_W-1:0] tile_cout_total;
    reg tile_layer_last;
    reg packet_valid;
    wire packet_ready;
    reg [PIXEL_INDEX_W-1:0] packet_pixel;
    reg [COUT_W-1:0] packet_cout_base;
    reg [COUT_TILE-1:0] packet_channel_valid;
    reg [COUT_TILE*8-1:0] packet_data;
    reg tile_commit_valid;
    wire tile_commit_ready;
    wire tile_committed;
    reg drain_start_valid;
    wire drain_start_ready;
    wire drain_done;
    wire tile_free;
    wire [63:0] m_axis_tdata;
    wire [7:0] m_axis_tkeep;
    wire m_axis_tvalid;
    reg m_axis_tready;
    wire m_axis_tlast;
    wire protocol_error;
    wire overwrite_error;
    wire underflow_error;
    wire [31:0] accepted_packet_count;
    wire [31:0] expected_packet_count;
    wire [31:0] committed_credit_count;
    wire [31:0] axis_valid_cycles;
    wire [31:0] axis_stall_cycles;
    wire [31:0] axis_beat_count;
    wire [31:0] axis_byte_count;

    integer lane;

    ofm_hwc_axis_packer #(
        .COUT_TILE(COUT_TILE),
        .MAX_PIXELS(MAX_PIXELS),
        .MAX_COUT(MAX_COUT),
        .BUFFER_DEPTH(BUFFER_DEPTH),
        .RAM_STYLE("distributed")
    ) dut (
        .clk(clk), .rst(rst),
        .tile_begin_valid(tile_begin_valid),
        .tile_begin_ready(tile_begin_ready),
        .tile_pixels(tile_pixels),
        .tile_cout_total(tile_cout_total),
        .tile_begin_blocks(16'd0),
        .tile_begin_span(32'd0),
        .tile_layer_last(tile_layer_last),
        .packet_valid(packet_valid), .packet_ready(packet_ready),
        .packet_pixel(packet_pixel),
        .packet_cout_base(packet_cout_base),
        .packet_channel_valid(packet_channel_valid),
        .packet_data(packet_data),
        .tile_commit_valid(tile_commit_valid),
        .tile_commit_ready(tile_commit_ready),
        .tile_committed(tile_committed),
        .drain_start_valid(drain_start_valid),
        .drain_start_ready(drain_start_ready),
        .drain_done(drain_done), .tile_free(tile_free),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .protocol_error(protocol_error),
        .overwrite_error(overwrite_error),
        .underflow_error(underflow_error),
        .accepted_packet_count(accepted_packet_count),
        .expected_packet_count(expected_packet_count),
        .committed_credit_count(committed_credit_count),
        .axis_valid_cycles(axis_valid_cycles),
        .axis_stall_cycles(axis_stall_cycles),
        .axis_beat_count(axis_beat_count),
        .axis_byte_count(axis_byte_count)
    );

    task check;
        input condition;
        input [255:0] message;
        begin
            if (!condition) begin
                fail_count = fail_count + 1'b1;
                $display("[FAIL][fault] %0s", message);
            end
        end
    endtask

    task set_packet_fields;
        input integer pixel;
        input integer cout_base;
        input integer corrupt_mask;
        begin
            packet_pixel = pixel;
            packet_cout_base = cout_base;
            packet_channel_valid = {COUT_TILE{1'b0}};
            packet_data = {COUT_TILE*8{1'b0}};
            for (lane = 0; lane < COUT_TILE; lane = lane + 1) begin
                if ((cout_base + lane) < COUT_TOTAL) begin
                    packet_channel_valid[lane] = 1'b1;
                    packet_data[lane*8 +: 8] =
                        (pixel * 53 + cout_base + lane + 8'h21) & 8'hff;
                end
            end
            if (corrupt_mask != 0)
                packet_channel_valid[0] = ~packet_channel_valid[0];
        end
    endtask

    task begin_tile;
        begin
            @(negedge clk);
            tile_pixels = 1;
            tile_cout_total = COUT_TOTAL;
            tile_layer_last = 1'b1;
            tile_begin_valid = 1'b1;
            @(posedge clk);
            while (!tile_begin_ready)
                @(posedge clk);
            @(negedge clk);
            tile_begin_valid = 1'b0;
            check(expected_packet_count == EXPECTED_PACKETS,
                  "tile begin expected packet count");
        end
    endtask

    task accept_packet;
        input integer pixel;
        input integer cout_base;
        input integer corrupt_mask;
        begin
            @(negedge clk);
            set_packet_fields(pixel, cout_base, corrupt_mask);
            packet_valid = 1'b1;
            @(posedge clk);
            while (!packet_ready)
                @(posedge clk);
            @(negedge clk);
            packet_valid = 1'b0;
        end
    endtask

    task commit_tile;
        begin
            @(negedge clk);
            tile_commit_valid = 1'b1;
            @(posedge clk);
            while (!tile_commit_ready)
                @(posedge clk);
            @(negedge clk);
            tile_commit_valid = 1'b0;
        end
    endtask

    task pulse_reset;
        begin
            @(negedge clk);
            rst = 1'b1;
            packet_valid = 1'b0;
            tile_begin_valid = 1'b0;
            tile_commit_valid = 1'b0;
            drain_start_valid = 1'b0;
            repeat (3) @(negedge clk);
            rst = 1'b0;
        end
    endtask

    initial begin
        done = 1'b0;
        fail_count = 32'd0;
        rst = 1'b1;
        tile_begin_valid = 1'b0;
        tile_pixels = {PIXEL_COUNT_W{1'b0}};
        tile_cout_total = {COUT_W{1'b0}};
        tile_layer_last = 1'b0;
        packet_valid = 1'b0;
        packet_pixel = {PIXEL_INDEX_W{1'b0}};
        packet_cout_base = {COUT_W{1'b0}};
        packet_channel_valid = {COUT_TILE{1'b0}};
        packet_data = {COUT_TILE*8{1'b0}};
        tile_commit_valid = 1'b0;
        drain_start_valid = 1'b0;
        m_axis_tready = 1'b0;

        repeat (4) @(negedge clk);
        rst = 1'b0;

        // Reset immediately after capture, before S0's normal retirement.
        // The reset edge may coincide with the old S0 write; dense scrub must
        // still clear that slot before the next tile is admitted.
        begin_tile();
        @(negedge clk);
        set_packet_fields(0, 0, 0);
        packet_valid = 1'b1;
        @(posedge clk);
        check(packet_ready, "packet captured immediately before reset");
        @(negedge clk);
        packet_valid = 1'b0;
        rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        begin_tile();
        accept_packet(0, 0, 0);
        @(posedge clk);
        @(negedge clk);
        check(accepted_packet_count == 32'd1,
              "post-S0-reset address commits after scrub");
        check(!protocol_error && !overwrite_error,
              "post-S0-reset address is not falsely duplicate");
        pulse_reset();

        // Invalid address: it enters S0 because ready has no raw-payload
        // feedback, then retires without any write or credit.
        begin_tile();
        accept_packet(0, 1, 0);
        @(posedge clk);
        @(negedge clk);
        check(accepted_packet_count == 32'd0,
              "invalid packet does not increment accepted count");
        check(committed_credit_count == 32'd0,
              "invalid packet does not increment committed credit");
        check(protocol_error && !overwrite_error,
              "invalid packet raises contract diagnostic only");

        // Reset abandons the bad tile and scrubs its active address span.  A
        // new begin waits for scrub completion and starts a clean epoch.
        pulse_reset();
        begin_tile();
        check(!protocol_error && !overwrite_error && !underflow_error,
              "reset and new begin clear invalid diagnostics");

        // Store address zero, then retry it.  The duplicate is accepted into
        // S0, dropped on the next cycle, and cannot consume the final credit.
        accept_packet(0, 0, 0);
        @(posedge clk);
        @(negedge clk);
        check(accepted_packet_count == 32'd1,
              "first unique packet commits through S0");

        accept_packet(0, 0, 0);
        set_packet_fields(0, COUT_TILE, 0);
        packet_valid = 1'b1;
        @(posedge clk);
        check(!packet_ready,
              "duplicate final reservation blocks younger packet");
        @(negedge clk);
        check(accepted_packet_count == 32'd1,
              "duplicate drop does not increment accepted count");
        check(committed_credit_count == 32'd1,
              "duplicate drop does not increment committed credit");
        check(protocol_error && overwrite_error,
              "duplicate raises sticky overwrite diagnostic");
        check(packet_ready,
              "ready reopens after bad final reservation drops");
        @(posedge clk);
        check(packet_ready, "held younger packet is accepted after reopen");
        @(negedge clk);
        packet_valid = 1'b0;
        check(!packet_ready, "good final S0 reservation closes ready");
        @(posedge clk);
        @(negedge clk);
        check(accepted_packet_count == EXPECTED_PACKETS,
              "unique replacement reaches exact packet count");
        check(committed_credit_count == EXPECTED_PACKETS,
              "unique replacement reaches exact credit count");
        check(tile_commit_ready,
              "duplicate recovery still permits exact tile commit");
        commit_tile();
        check(tile_committed, "duplicate recovery tile commits");

        // Reset a committed tile, wait through scrub, and prove a mask error
        // is diagnostic-only: it writes/counts and the tile still commits.
        pulse_reset();
        begin_tile();
        check(!protocol_error && !overwrite_error,
              "committed-tile reset starts clean epoch");
        @(negedge clk);
        set_packet_fields(0, 0, 1);
        packet_valid = 1'b1;
        @(posedge clk);
        check(packet_ready, "mask-mismatch packet enters empty S0");
        @(negedge clk);
        set_packet_fields(0, COUT_TILE, 0);
        @(posedge clk);
        check(packet_ready,
              "mask mismatch commits with same-cycle S0 refill");
        @(negedge clk);
        packet_valid = 1'b0;
        check(!packet_ready, "mask case final reservation closes ready");
        @(posedge clk);
        @(negedge clk);
        check(accepted_packet_count == EXPECTED_PACKETS,
              "mask mismatch still increments accepted count");
        check(committed_credit_count == EXPECTED_PACKETS,
              "mask mismatch still increments committed credit");
        check(protocol_error && !overwrite_error,
              "mask mismatch is sticky protocol diagnostic only");
        check(tile_commit_ready,
              "mask mismatch does not block exact tile commit");
        commit_tile();
        check(tile_committed, "mask mismatch tile commits");

        done = 1'b1;
    end
endmodule


module ofm_hwc_axis_packer_case #(
    parameter integer CASE_ID = 0,
    parameter integer COUT_TILE = 16,
    parameter integer COUT_TOTAL = 24,
    parameter integer PIXELS = 3,
    parameter integer MAX_PIXELS = 4,
    parameter integer MAX_COUT = 32,
    parameter integer RANDOM_READY = 0,
    parameter integer PIXEL_INDEX_W =
        (MAX_PIXELS <= 1) ? 1 : $clog2(MAX_PIXELS),
    parameter integer PIXEL_COUNT_W =
        (MAX_PIXELS <= 1) ? 1 : $clog2(MAX_PIXELS + 1),
    parameter integer COUT_W =
        (MAX_COUT <= 1) ? 1 : $clog2(MAX_COUT + 1)
) (
    input  wire        clk,
    input  wire        rst,
    output reg         done,
    output reg [31:0]  fail_count
);
    localparam integer BLOCKS =
        (COUT_TOTAL + COUT_TILE - 1) / COUT_TILE;
    localparam integer CHUNKS_PER_PIXEL = (COUT_TOTAL + 7) / 8;
    localparam integer EXPECTED_PACKETS = PIXELS * BLOCKS;
    localparam integer EXPECTED_BEATS = PIXELS * CHUNKS_PER_PIXEL;

    reg tile_begin_valid;
    wire tile_begin_ready;
    reg [PIXEL_COUNT_W-1:0] tile_pixels;
    reg [COUT_W-1:0] tile_cout_total;
    reg tile_layer_last;

    reg packet_valid;
    wire packet_ready;
    reg [PIXEL_INDEX_W-1:0] packet_pixel;
    reg [COUT_W-1:0] packet_cout_base;
    reg [COUT_TILE-1:0] packet_channel_valid;
    reg [COUT_TILE*8-1:0] packet_data;

    reg tile_commit_valid;
    wire tile_commit_ready;
    wire tile_committed;
    reg drain_start_valid;
    wire drain_start_ready;
    wire drain_done;
    wire tile_free;

    wire [63:0] m_axis_tdata;
    wire [7:0] m_axis_tkeep;
    wire m_axis_tvalid;
    reg m_axis_tready;
    wire m_axis_tlast;
    wire protocol_error;
    wire overwrite_error;
    wire underflow_error;
    wire [31:0] accepted_packet_count;
    wire [31:0] expected_packet_count;
    wire [31:0] committed_credit_count;
    wire [31:0] axis_valid_cycles;
    wire [31:0] axis_stall_cycles;
    wire [31:0] axis_beat_count;
    wire [31:0] axis_byte_count;

    integer block_idx;
    integer pixel_idx;
    integer lane;
    integer ready_cycle;
    integer recv_count;
    integer exp_pixel;
    integer exp_chunk;
    integer exp_channel;
    integer valid_bytes;
    integer oracle_read_count;
    integer oracle_cross_pixel_count;
    reg ready_enable;
    reg [15:0] ready_lfsr;
    reg held_valid;
    reg [63:0] held_data;
    reg [7:0] held_keep;
    reg held_last;
    reg [63:0] expected_data;
    reg [7:0] expected_keep;

    ofm_hwc_axis_packer #(
        .COUT_TILE(COUT_TILE),
        .MAX_PIXELS(MAX_PIXELS),
        .MAX_COUT(MAX_COUT),
        .BUFFER_DEPTH(MAX_PIXELS *
                      ((MAX_COUT + COUT_TILE - 1) / COUT_TILE)),
        .RAM_STYLE("distributed")
    ) dut (
        .clk(clk), .rst(rst),
        .tile_begin_valid(tile_begin_valid),
        .tile_begin_ready(tile_begin_ready),
        .tile_pixels(tile_pixels),
        .tile_cout_total(tile_cout_total),
        .tile_begin_blocks(16'd0),
        .tile_begin_span(32'd0),
        .tile_layer_last(tile_layer_last),
        .packet_valid(packet_valid), .packet_ready(packet_ready),
        .packet_pixel(packet_pixel),
        .packet_cout_base(packet_cout_base),
        .packet_channel_valid(packet_channel_valid),
        .packet_data(packet_data),
        .tile_commit_valid(tile_commit_valid),
        .tile_commit_ready(tile_commit_ready),
        .tile_committed(tile_committed),
        .drain_start_valid(drain_start_valid),
        .drain_start_ready(drain_start_ready),
        .drain_done(drain_done), .tile_free(tile_free),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .protocol_error(protocol_error),
        .overwrite_error(overwrite_error),
        .underflow_error(underflow_error),
        .accepted_packet_count(accepted_packet_count),
        .expected_packet_count(expected_packet_count),
        .committed_credit_count(committed_credit_count),
        .axis_valid_cycles(axis_valid_cycles),
        .axis_stall_cycles(axis_stall_cycles),
        .axis_beat_count(axis_beat_count),
        .axis_byte_count(axis_byte_count)
    );

    function [7:0] sample_value;
        input integer pixel;
        input integer channel;
        begin
            sample_value =
                (CASE_ID + pixel * 67 + channel * 3 + 7) & 8'hff;
        end
    endfunction

    task check;
        input condition;
        input [255:0] message;
        begin
            if (!condition) begin
                fail_count = fail_count + 1'b1;
                $display("[FAIL][case%0d] %0s", CASE_ID, message);
            end
        end
    endtask

    task begin_tile;
        begin
            @(negedge clk);
            tile_pixels = PIXELS;
            tile_cout_total = COUT_TOTAL;
            tile_layer_last = 1'b1;
            tile_begin_valid = 1'b1;
            @(posedge clk);
            while (!tile_begin_ready)
                @(posedge clk);
            @(negedge clk);
            tile_begin_valid = 1'b0;
        end
    endtask

    task set_packet_fields;
        input integer pixel;
        input integer cout_base;
        integer data_lane;
        begin
            packet_pixel = pixel;
            packet_cout_base = cout_base;
            packet_channel_valid = {COUT_TILE{1'b0}};
            packet_data = {COUT_TILE*8{1'b0}};
            for (data_lane = 0; data_lane < COUT_TILE;
                 data_lane = data_lane + 1) begin
                if ((cout_base + data_lane) < COUT_TOTAL) begin
                    packet_channel_valid[data_lane] = 1'b1;
                    packet_data[data_lane*8 +: 8] =
                        sample_value(pixel, cout_base + data_lane);
                end
            end
        end
    endtask

    // Keep VALID asserted and change payload only on falling edges after each
    // handshake.  After the initial S0 fill every following input acceptance
    // coincides with retirement of the preceding packet.
    task send_packet_burst;
        integer packet_idx;
        integer burst_block;
        integer burst_pixel;
        begin
            @(negedge clk);
            packet_valid = 1'b1;
            set_packet_fields(0, 0);
            for (packet_idx = 0; packet_idx < EXPECTED_PACKETS;
                 packet_idx = packet_idx + 1) begin
                @(posedge clk);
                check(packet_ready,
                      "continuous burst accepts one packet per clock");
                @(negedge clk);
                check(accepted_packet_count == packet_idx,
                      "same-cycle S0 retire/refill count");
                if ((packet_idx + 1) < EXPECTED_PACKETS) begin
                    burst_block = (packet_idx + 1) / PIXELS;
                    burst_pixel = (packet_idx + 1) % PIXELS;
                    set_packet_fields(burst_pixel,
                                      burst_block * COUT_TILE);
                end
            end

            // The final packet is resident in S0.  Its reservation consumes
            // the last credit, so a still-asserted VALID cannot be accepted.
            check(!packet_ready, "final S0 reservation closes packet ready");
            @(posedge clk);
            check(!packet_ready, "final retirement cannot refill S0");
            @(negedge clk);
            packet_valid = 1'b0;
            check(accepted_packet_count == EXPECTED_PACKETS,
                  "final S0 packet retired before count check");
        end
    endtask

    task commit_tile;
        begin
            @(negedge clk);
            tile_commit_valid = 1'b1;
            @(posedge clk);
            while (!tile_commit_ready)
                @(posedge clk);
            @(negedge clk);
            tile_commit_valid = 1'b0;
        end
    endtask

    task start_drain;
        begin
            @(negedge clk);
            drain_start_valid = 1'b1;
            @(posedge clk);
            while (!drain_start_ready)
                @(posedge clk);
            @(negedge clk);
            drain_start_valid = 1'b0;
            ready_enable = 1'b1;
        end
    endtask

    // Deterministic, irregular output backpressure.
    always @(negedge clk) begin
        if (rst || !ready_enable) begin
            ready_cycle <= 0;
            ready_lfsr <= 16'h1ace;
            m_axis_tready <= 1'b0;
        end else begin
            ready_cycle <= ready_cycle + 1;
            ready_lfsr <= {ready_lfsr[14:0],
                           ready_lfsr[15] ^ ready_lfsr[13] ^
                           ready_lfsr[12] ^ ready_lfsr[10]};
            if (RANDOM_READY != 0)
                m_axis_tready <= ready_lfsr[0] || ready_lfsr[5];
            else
                m_axis_tready <=
                    ((ready_cycle % 5) != 1) &&
                    ((ready_cycle % 7) != 3);
        end
    end

    // Scoreboard and AXI stability checks.
    always @(posedge clk) begin
        if (rst) begin
            recv_count <= 0;
            oracle_read_count <= 0;
            oracle_cross_pixel_count <= 0;
            held_valid <= 1'b0;
            held_data <= 64'd0;
            held_keep <= 8'd0;
            held_last <= 1'b0;
        end else begin
            // The physical RAM-read sequence is the address oracle for the
            // dense layout.  It is independent of AXI stall duration: the
            // initial read is address zero and each completed packet word
            // must issue exactly the next linear address.
            if (dut.mem_rd_en) begin
                check(dut.mem_rd_addr == oracle_read_count,
                      "RAM read address advances linearly");
                oracle_read_count <= oracle_read_count + 1;

                if (dut.word_advance_fire && dut.at_last_block) begin
                    check(dut.mem_rd_addr == (dut.drain_word_addr + 1'b1),
                          "pixel-boundary read is current address plus one");
                    check(dut.mem_rd_addr ==
                          ((dut.drain_pixel + 1'b1) * BLOCKS),
                          "pixel-boundary read matches next dense pixel base");
                    oracle_cross_pixel_count <=
                        oracle_cross_pixel_count + 1;
                end
            end

            if (held_valid) begin
                check(m_axis_tvalid, "TVALID dropped under backpressure");
                check(m_axis_tdata == held_data,
                      "TDATA changed under backpressure");
                check(m_axis_tkeep == held_keep,
                      "TKEEP changed under backpressure");
                check(m_axis_tlast == held_last,
                      "TLAST changed under backpressure");
            end

            held_valid <= m_axis_tvalid && !m_axis_tready;
            if (m_axis_tvalid && !m_axis_tready) begin
                held_data <= m_axis_tdata;
                held_keep <= m_axis_tkeep;
                held_last <= m_axis_tlast;
            end

            if (m_axis_tvalid && m_axis_tready) begin
                exp_pixel = recv_count / CHUNKS_PER_PIXEL;
                exp_chunk = recv_count % CHUNKS_PER_PIXEL;
                exp_channel = exp_chunk * 8;
                valid_bytes = COUT_TOTAL - exp_channel;
                if (valid_bytes > 8)
                    valid_bytes = 8;

                expected_data = 64'd0;
                expected_keep = 8'd0;
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if (lane < valid_bytes) begin
                        expected_keep[lane] = 1'b1;
                        expected_data[lane*8 +: 8] =
                            sample_value(exp_pixel, exp_channel + lane);
                    end
                end

                check(m_axis_tdata == expected_data, "HWC output data");
                check(m_axis_tkeep == expected_keep, "HWC output TKEEP");
                check(m_axis_tlast == (recv_count == EXPECTED_BEATS - 1),
                      "TLAST position");
                recv_count <= recv_count + 1;
            end
        end
    end

    initial begin
        done = 1'b0;
        fail_count = 32'd0;
        tile_begin_valid = 1'b0;
        tile_pixels = {PIXEL_COUNT_W{1'b0}};
        tile_cout_total = {COUT_W{1'b0}};
        tile_layer_last = 1'b0;
        packet_valid = 1'b0;
        packet_pixel = {PIXEL_INDEX_W{1'b0}};
        packet_cout_base = {COUT_W{1'b0}};
        packet_channel_valid = {COUT_TILE{1'b0}};
        packet_data = {COUT_TILE*8{1'b0}};
        tile_commit_valid = 1'b0;
        drain_start_valid = 1'b0;
        m_axis_tready = 1'b0;
        ready_enable = 1'b0;
        ready_cycle = 0;
        ready_lfsr = 16'h1ace;

        wait(!rst);
        begin_tile();
        $display("[case%0d] begin accepted t=%0t expected=%0d", CASE_ID, $time,
                 expected_packet_count);
        check(dut.blocks_per_pixel_reg == BLOCKS,
              "configured blocks-per-pixel stride");

        // Deliberately use cout-block-major order. The output must still be
        // pixel-major HWC.  The input side is a gap-free burst.
        send_packet_burst();

        $display("[case%0d] packets accepted t=%0t count=%0d/%0d err=%0b",
                 CASE_ID, $time, accepted_packet_count,
                 expected_packet_count, protocol_error);

        check(accepted_packet_count == EXPECTED_PACKETS,
              "accepted packet count");
        check(expected_packet_count == EXPECTED_PACKETS,
              "expected packet count");
        check(committed_credit_count == EXPECTED_PACKETS,
              "committed address credits before drain");
        check(!underflow_error, "no committed-credit underflow");
        check(!protocol_error, "packet contract diagnostics");
        check(!overwrite_error, "no packet overwrite");

        commit_tile();
        $display("[case%0d] commit accepted t=%0t", CASE_ID, $time);
        check(tile_committed, "tile committed state");
        start_drain();
        $display("[case%0d] drain started t=%0t", CASE_ID, $time);

        wait(drain_done);
        @(negedge clk);
        check(recv_count == EXPECTED_BEATS, "output beat count");
        check(oracle_read_count == EXPECTED_PACKETS,
              "one linear RAM read per packet word");
        check(oracle_cross_pixel_count == PIXELS - 1,
              "every cross-pixel final block used linear successor");
        if (RANDOM_READY != 0)
            check(axis_stall_cycles != 0,
                  "randomized READY exercised output backpressure");
        $display("[case%0d] address oracle reads=%0d cross_pixel=%0d stalls=%0d",
                 CASE_ID, oracle_read_count, oracle_cross_pixel_count,
                 axis_stall_cycles);
        check(axis_beat_count == EXPECTED_BEATS,
              "packed AXIS beat counter");
        check(axis_byte_count == PIXELS*COUT_TOTAL,
              "packed AXIS byte counter");
        check(axis_valid_cycles == axis_beat_count + axis_stall_cycles,
              "packed AXIS utilization counters partition valid cycles");
        check(tile_free, "tile returns to free state");
        check(committed_credit_count == 32'd0,
              "all committed credits retired after drain");
        check(!protocol_error, "no protocol error after drain");

        // A new layer/tile begin is the telemetry epoch boundary.  Exercise a
        // second begin on the clean case to prove counts and sticky protocol
        // state cannot leak into the next layer.
        if (CASE_ID == 32) begin
            ready_enable = 1'b0;
            begin_tile();
            check(axis_valid_cycles == 32'd0,
                  "new begin clears AXIS valid cycles");
            check(axis_stall_cycles == 32'd0,
                  "new begin clears AXIS stall cycles");
            check(axis_beat_count == 32'd0,
                  "new begin clears AXIS beat count");
            check(axis_byte_count == 32'd0,
                  "new begin clears AXIS byte count");
            check(!protocol_error && !overwrite_error && !underflow_error,
                  "new begin clears packed protocol status");
        end
        done = 1'b1;
    end
endmodule

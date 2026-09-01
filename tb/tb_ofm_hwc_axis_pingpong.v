`timescale 1ns / 1ps

`ifndef TB_OFM_PINGPONG_PRECOMPUTED
`define TB_OFM_PINGPONG_PRECOMPUTED 1
`endif

module tb_ofm_hwc_axis_pingpong;
    localparam integer COUT_TILE = 32;
    localparam integer COUT_TOTAL = 37;
    localparam integer MAX_PIXELS = 8;
    localparam integer MAX_COUT = 64;
    localparam integer PIXEL_INDEX_W = $clog2(MAX_PIXELS);
    localparam integer PIXEL_COUNT_W = $clog2(MAX_PIXELS + 1);
    localparam integer COUT_W = $clog2(MAX_COUT + 1);
    localparam integer TILE0_PIXELS = 4;
    localparam integer TILE1_PIXELS = 3;
    localparam integer BLOCKS =
        (COUT_TOTAL + COUT_TILE - 1) / COUT_TILE;
    localparam integer BUFFER_DEPTH = MAX_PIXELS *
        ((MAX_COUT + COUT_TILE - 1) / COUT_TILE);
    localparam integer PRECOMPUTED_BEGIN_GEOMETRY =
        `TB_OFM_PINGPONG_PRECOMPUTED;
    localparam integer TOTAL_BYTES =
        (TILE0_PIXELS + TILE1_PIXELS) * COUT_TOTAL;
    localparam integer TILE0_BYTES = TILE0_PIXELS * COUT_TOTAL;
    localparam integer TOTAL_BEATS = (TOTAL_BYTES + 7) / 8;

    reg clk;
    reg rst;
    reg clear_stats;

    reg tile_begin_valid;
    wire tile_begin_ready;
    reg [PIXEL_COUNT_W-1:0] tile_pixels;
    reg [COUT_W-1:0] tile_cout_total;
    reg [15:0] tile_begin_blocks;
    reg [31:0] tile_begin_span;
    reg tile_layer_last;
    wire tile_accept;

    reg packet_valid;
    wire packet_ready;
    reg [PIXEL_INDEX_W-1:0] packet_pixel;
    reg [COUT_W-1:0] packet_cout_base;
    reg [COUT_TILE-1:0] packet_channel_valid;
    reg [COUT_TILE*8-1:0] packet_data;

    reg tile_commit_valid;
    wire tile_commit_ready;
    wire tile_commit;

    wire [63:0] m_axis_tdata;
    wire [7:0] m_axis_tkeep;
    wire m_axis_tvalid;
    reg m_axis_tready;
    wire m_axis_tlast;

    wire all_free;
    wire tile_load_active;
    wire protocol_error;
    wire overwrite_error;
    wire underflow_error;
    wire [31:0] axis_valid_cycles;
    wire [31:0] axis_stall_cycles;
    wire [31:0] axis_beat_count;
    wire [31:0] axis_byte_count;

    integer fail_count;
    integer recv_count;
    integer recv_byte_count;
    integer tile_accept_count;
    integer tile_commit_count;
    integer tlast_count;
    integer load_tile_id;
    integer exp_tile;
    integer exp_tile_byte;
    integer exp_pixel;
    integer exp_chunk;
    integer exp_channel;
    integer valid_bytes;
    integer lane;
    integer block_idx;
    integer pixel_idx;
    integer reset_scrub_cycles;
    reg overlap_seen;
    reg [15:0] ready_lfsr;
    reg held_valid;
    reg [63:0] held_data;
    reg [7:0] held_keep;
    reg held_last;
    reg [63:0] expected_data;
    reg [7:0] expected_keep;

    always #5 clk = ~clk;

    ofm_hwc_axis_pingpong #(
        .COUT_TILE(COUT_TILE),
        .MAX_PIXELS(MAX_PIXELS),
        .MAX_COUT(MAX_COUT),
        .BUFFER_DEPTH(BUFFER_DEPTH),
        .RAM_STYLE("distributed"),
        .PRECOMPUTED_BEGIN_GEOMETRY(PRECOMPUTED_BEGIN_GEOMETRY)
    ) dut (
        .clk(clk), .rst(rst), .clear_stats(clear_stats),
        .tile_begin_valid(tile_begin_valid),
        .tile_begin_ready(tile_begin_ready),
        .tile_pixels(tile_pixels), .tile_cout_total(tile_cout_total),
        .tile_begin_blocks(tile_begin_blocks),
        .tile_begin_span(tile_begin_span),
        .tile_layer_last(tile_layer_last), .tile_accept(tile_accept),
        .packet_valid(packet_valid), .packet_ready(packet_ready),
        .packet_pixel(packet_pixel), .packet_cout_base(packet_cout_base),
        .packet_channel_valid(packet_channel_valid),
        .packet_data(packet_data),
        .tile_commit_valid(tile_commit_valid),
        .tile_commit_ready(tile_commit_ready), .tile_commit(tile_commit),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast), .all_free(all_free),
        .tile_load_active(tile_load_active),
        .protocol_error(protocol_error),
        .overwrite_error(overwrite_error),
        .underflow_error(underflow_error),
        .axis_valid_cycles(axis_valid_cycles),
        .axis_stall_cycles(axis_stall_cycles),
        .axis_beat_count(axis_beat_count),
        .axis_byte_count(axis_byte_count)
    );

    function [7:0] sample_value;
        input integer tile_id;
        input integer pixel;
        input integer channel;
        begin
            sample_value =
                (tile_id * 97 + pixel * 23 + channel * 3 + 5) & 8'hff;
        end
    endfunction

    task check;
        input condition;
        input [511:0] message;
        begin
            if (!condition) begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task begin_tile;
        input integer tile_id;
        input integer pixels;
        input integer layer_last;
        begin
            @(negedge clk);
            load_tile_id = tile_id;
            tile_pixels = pixels;
            tile_cout_total = COUT_TOTAL;
            tile_begin_blocks = BLOCKS;
            tile_begin_span = pixels * BLOCKS;
            tile_layer_last = layer_last;
            tile_begin_valid = 1'b1;
            #1;
            check(tile_begin_ready,
                  "precomputed begin has no valid-cycle wait");
            @(posedge clk);
            while (!tile_begin_ready)
                @(posedge clk);
            @(negedge clk);
            tile_begin_valid = 1'b0;
            check(packet_ready,
                  "first packet may start in first load cycle");
            if (dut.load_bank) begin
                check(dut.u_bank1.blocks_per_pixel_reg == BLOCKS,
                      "bank1 stores exact precomputed block count");
                check(dut.u_bank1.expected_packets_reg == pixels * BLOCKS,
                      "bank1 stores exact precomputed span");
            end else begin
                check(dut.u_bank0.blocks_per_pixel_reg == BLOCKS,
                      "bank0 stores exact precomputed block count");
                check(dut.u_bank0.expected_packets_reg == pixels * BLOCKS,
                      "bank0 stores exact precomputed span");
            end
        end
    endtask

    task send_packet;
        input integer pixel;
        input integer cout_base;
        integer data_lane;
        begin
            @(negedge clk);
            packet_pixel = pixel;
            packet_cout_base = cout_base;
            packet_channel_valid = {COUT_TILE{1'b0}};
            packet_data = {COUT_TILE*8{1'b0}};
            for (data_lane = 0; data_lane < COUT_TILE;
                 data_lane = data_lane + 1) begin
                if ((cout_base + data_lane) < COUT_TOTAL) begin
                    packet_channel_valid[data_lane] = 1'b1;
                    packet_data[data_lane*8 +: 8] =
                        sample_value(load_tile_id, pixel,
                                     cout_base + data_lane);
                end
            end
            packet_valid = 1'b1;
            @(posedge clk);
            while (!packet_ready)
                @(posedge clk);
            @(negedge clk);
            packet_valid = 1'b0;
        end
    endtask

    task send_tile_packets;
        input integer pixels;
        begin
            // Block-major input proves that each bank performs HWC reorder.
            for (block_idx = 0; block_idx < BLOCKS;
                 block_idx = block_idx + 1)
                for (pixel_idx = 0; pixel_idx < pixels;
                     pixel_idx = pixel_idx + 1)
                    send_packet(pixel_idx, block_idx * COUT_TILE);
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

    // Deterministic pseudo-random backpressure, including multi-cycle stalls.
    always @(negedge clk) begin
        if (rst) begin
            ready_lfsr <= 16'h1ace;
            m_axis_tready <= 1'b0;
        end else begin
            ready_lfsr <= {ready_lfsr[14:0],
                           ready_lfsr[15] ^ ready_lfsr[13] ^
                           ready_lfsr[12] ^ ready_lfsr[10]};
            m_axis_tready <= ready_lfsr[0] | ready_lfsr[3];
        end
    end

    // AXI stability, ordering, tail keep and TLAST scoreboard.
    always @(posedge clk) begin
        if (rst) begin
            recv_count <= 0;
            recv_byte_count <= 0;
            tile_accept_count <= 0;
            tile_commit_count <= 0;
            tlast_count <= 0;
            overlap_seen <= 1'b0;
            held_valid <= 1'b0;
            held_data <= 64'd0;
            held_keep <= 8'd0;
            held_last <= 1'b0;
        end else begin
            if (tile_accept)
                tile_accept_count <= tile_accept_count + 1;
            if (tile_commit)
                tile_commit_count <= tile_commit_count + 1;

            if (packet_valid && packet_ready && m_axis_tvalid)
                overlap_seen <= 1'b1;

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
                expected_data = 64'd0;
                expected_keep = 8'd0;
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if ((recv_byte_count + lane) < TOTAL_BYTES) begin
                        if ((recv_byte_count + lane) < TILE0_BYTES) begin
                            exp_tile = 0;
                            exp_tile_byte = recv_byte_count + lane;
                        end else begin
                            exp_tile = 1;
                            exp_tile_byte = recv_byte_count + lane -
                                            TILE0_BYTES;
                        end
                        exp_pixel = exp_tile_byte / COUT_TOTAL;
                        exp_channel = exp_tile_byte % COUT_TOTAL;
                        expected_keep[lane] = 1'b1;
                        expected_data[lane*8 +: 8] =
                            sample_value(exp_tile, exp_pixel,
                                         exp_channel);
                    end
                end

                check(m_axis_tdata == expected_data, "ordered HWC data");
                check(m_axis_tkeep == expected_keep,
                      "only the layer-final beat may have partial TKEEP");
                check(m_axis_tlast == (recv_count == TOTAL_BEATS - 1),
                      "TLAST only on final layer tile");
                if (m_axis_tlast)
                    tlast_count <= tlast_count + 1;
                recv_byte_count <= recv_byte_count +
                    ((recv_byte_count + 8 <= TOTAL_BYTES) ?
                     8 : (TOTAL_BYTES - recv_byte_count));
                recv_count <= recv_count + 1;
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        clear_stats = 1'b0;
        fail_count = 0;
        tile_begin_valid = 1'b0;
        tile_pixels = {PIXEL_COUNT_W{1'b0}};
        tile_cout_total = {COUT_W{1'b0}};
        tile_begin_blocks = 16'd0;
        tile_begin_span = 32'd0;
        tile_layer_last = 1'b0;
        packet_valid = 1'b0;
        packet_pixel = {PIXEL_INDEX_W{1'b0}};
        packet_cout_base = {COUT_W{1'b0}};
        packet_channel_valid = {COUT_TILE{1'b0}};
        packet_data = {COUT_TILE*8{1'b0}};
        tile_commit_valid = 1'b0;
        m_axis_tready = 1'b0;
        ready_lfsr = 16'h1ace;
        load_tile_id = 0;

        repeat (5) @(negedge clk);
        rst = 1'b0;

        if (PRECOMPUTED_BEGIN_GEOMETRY != 0) begin
            // Before valid, precomputed mode exposes bank availability without
            // placing the registered geometry on the ready path.  Once valid
            // is asserted the overflowing span must be rejected fail-closed.
            #1;
            check(tile_begin_ready,
                  "precomputed ready bypasses zero lookahead while valid is low");
            tile_pixels = 1;
            tile_cout_total = COUT_TOTAL;
            tile_begin_blocks = BLOCKS;
            tile_begin_span = BUFFER_DEPTH + 1;
            tile_begin_valid = 1'b0;
            #1;
            check(tile_begin_ready,
                  "invalid lookahead cannot delay the pre-valid ready cycle");
            tile_begin_valid = 1'b1;
            #1;
            check(!tile_begin_ready && !tile_accept,
                  "overflowing precomputed span is not accepted");
            @(posedge clk);
            @(negedge clk);
            tile_begin_valid = 1'b0;
            check(dut.u_bank0.state == 2'd0 && !tile_load_active,
                  "overflow rejection leaves bank FREE");
            check(dut.u_bank0.protocol_error,
                  "overflow rejection sets selected-bank protocol error");
            check(protocol_error,
                  "overflow rejection reaches aggregate protocol error");

            // Clear the deliberate negative-test diagnostic before the
            // functional two-bank and soft-reset scenarios below.
            rst = 1'b1;
            repeat (4) @(negedge clk);
            rst = 1'b0;
        end

        // Leave committed ownership behind in a partially loaded bank, then
        // emulate the four-cycle datapath soft reset.  The bank must scrub its
        // dense active span before accepting the recovery tile; otherwise the
        // first reused slot is falsely reported as an overwrite.
        begin_tile(7, TILE0_PIXELS, 0);
        send_packet(0, 0);
        send_packet(1, 0);
        // The packer input is now a one-stage elastic pipeline: the raw
        // handshake precedes the physical reorder-RAM commit by one cycle.
        // Wait for both accepted packets to retire from S0 before sampling
        // the reset/scrub setup state.
        wait(dut.u_bank0.committed_credit_count == 2);
        @(negedge clk);
        check(dut.u_bank0.committed_credit_count == 2,
              "reset setup leaves two committed packet slots");
        @(negedge clk);
        rst = 1'b1;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        reset_scrub_cycles = 0;
        while (!tile_begin_ready && reset_scrub_cycles < 64) begin
            @(negedge clk);
            reset_scrub_cycles = reset_scrub_cycles + 1;
        end
        check(reset_scrub_cycles != 0 && reset_scrub_cycles < 64,
              "soft-reset slot scrub completes before recovery begin");
        check(!protocol_error && !overwrite_error && !underflow_error,
              "soft-reset slot scrub leaves diagnostics clear");

        begin_tile(0, TILE0_PIXELS, 0);
        send_tile_packets(TILE0_PIXELS);
        commit_tile();

        // Bank 0 drains automatically while bank 1 receives and commits tile
        // 1.  Backpressure makes the overlap window intentionally long.
        begin_tile(1, TILE1_PIXELS, 1);
        send_tile_packets(TILE1_PIXELS);
        commit_tile();
        check(recv_byte_count < TILE0_BYTES,
              "second tile committed before first tile finished draining");

        wait(all_free);
        @(negedge clk);
        check(overlap_seen, "load and drain overlap observed");
        check(tile_accept_count == 2, "two tile accepts exposed");
        check(tile_commit_count == 2, "two tile commits exposed");
        check(recv_count == TOTAL_BEATS, "all output beats received");
        check(recv_byte_count == TOTAL_BYTES, "all dense output bytes received");
        check(tlast_count == 1, "exactly one TLAST observed");
        check(axis_beat_count == TOTAL_BEATS,
              "aggregate AXIS beat counter");
        check(axis_byte_count == TOTAL_BYTES,
              "aggregate AXIS byte counter");
        check(axis_valid_cycles == axis_beat_count + axis_stall_cycles,
              "aggregate valid cycles partition into beat and stall");
        check(axis_stall_cycles != 0, "random backpressure produced stalls");
        check(!protocol_error, "no aggregate protocol error");
        check(!overwrite_error, "no aggregate overwrite error");
        check(!underflow_error, "no aggregate underflow error");

        $display("=== tb_ofm_hwc_axis_pingpong: fail=%0d beats=%0d bytes=%0d stalls=%0d ===",
                 fail_count, axis_beat_count,
                 axis_byte_count, axis_stall_cycles);
        if (fail_count != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        #300000;
        $fatal(1, "tb_ofm_hwc_axis_pingpong timeout");
    end
endmodule

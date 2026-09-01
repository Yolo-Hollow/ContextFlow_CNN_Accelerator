`timescale 1ns / 1ps

// Tile-local packet reorder buffer and packed HWC AXI-Stream writer.
//
// The post-pool path produces one COUT_TILE-wide packet for a single spatial
// pixel. Packets may arrive in any order, but every expected {pixel,
// cout_block} location must be supplied exactly once. This module stores them
// at that address, then drains the committed tile in HWC order:
//
//   pixel 0: channel 0 .. cout_total-1
//   pixel 1: channel 0 .. cout_total-1
//   ...
//
// There are no byte addresses in the output stream. Every output beat carries
// up to eight adjacent channels. TKEEP describes the final channel group of a
// pixel and TLAST is asserted on the final beat only when tile_layer_last was
// set at tile_begin. All AXI outputs remain stable under backpressure.
//
// One instance owns one tile buffer. Instantiate two copies and alternate the
// tile_begin/tile_commit and drain_start handshakes for ping-pong operation.
module ofm_hwc_axis_packer #(
    parameter integer COUT_TILE = 32,
    parameter integer MAX_PIXELS = 1024,
    parameter integer MAX_COUT = 1024,
    parameter integer BUFFER_DEPTH =
        MAX_PIXELS * ((MAX_COUT + COUT_TILE - 1) / COUT_TILE),
    parameter RAM_STYLE = "block",
    parameter integer PRECOMPUTED_BEGIN_GEOMETRY = 0,
    parameter integer PIXEL_INDEX_W =
        (MAX_PIXELS <= 1) ? 1 : $clog2(MAX_PIXELS),
    parameter integer PIXEL_COUNT_W =
        (MAX_PIXELS <= 1) ? 1 : $clog2(MAX_PIXELS + 1),
    parameter integer COUT_W =
        (MAX_COUT <= 1) ? 1 : $clog2(MAX_COUT + 1)
) (
    input  wire                         clk,
    input  wire                         rst,

    // Begin loading a free tile buffer. Counts, rather than last indices, are
    // supplied here. A zero-sized or out-of-range tile is not accepted.
    input  wire                         tile_begin_valid,
    output wire                         tile_begin_ready,
    input  wire [PIXEL_COUNT_W-1:0]     tile_pixels,
    input  wire [COUT_W-1:0]            tile_cout_total,
    input  wire [15:0]                  tile_begin_blocks,
    input  wire [31:0]                  tile_begin_span,
    input  wire                         tile_layer_last,

    // Existing post-pool wide packet interface.
    input  wire                         packet_valid,
    output wire                         packet_ready,
    input  wire [PIXEL_INDEX_W-1:0]     packet_pixel,
    input  wire [COUT_W-1:0]            packet_cout_base,
    input  wire [COUT_TILE-1:0]         packet_channel_valid,
    input  wire [COUT_TILE*8-1:0]       packet_data,

    // Commit is accepted only after the exact number of in-range packets has
    // been stored. tile_committed remains high until drain_start is accepted.
    input  wire                         tile_commit_valid,
    output wire                         tile_commit_ready,
    output wire                         tile_committed,

    // A committed tile is drained only after this explicit handshake.
    input  wire                         drain_start_valid,
    output wire                         drain_start_ready,
    output reg                          drain_done,
    output wire                         tile_free,

    output wire [63:0]                  m_axis_tdata,
    output wire [7:0]                   m_axis_tkeep,
    output wire                         m_axis_tvalid,
    input  wire                         m_axis_tready,
    output wire                         m_axis_tlast,

    // Per-tile diagnostics clear on the next accepted tile_begin.  Every
    // dense {pixel,cout-block} address owns one committed credit, preventing
    // a duplicate packet from hiding a missing packet at commit time.
    output reg                          protocol_error,
    output reg                          overwrite_error,
    output reg                          underflow_error,
    output wire [31:0]                  accepted_packet_count,
    output wire [31:0]                  expected_packet_count,
    output reg  [31:0]                  committed_credit_count,
    output reg  [31:0]                  axis_valid_cycles,
    output reg  [31:0]                  axis_stall_cycles,
    output reg  [31:0]                  axis_beat_count,
    output reg  [31:0]                  axis_byte_count
);
    localparam integer AXIS_BYTES = 8;
    localparam integer COUT_SHIFT = $clog2(COUT_TILE);
    localparam integer BEATS_PER_PACKET = COUT_TILE / AXIS_BYTES;
    localparam integer CHUNK_W =
        (BEATS_PER_PACKET <= 1) ? 1 : $clog2(BEATS_PER_PACKET);
    localparam integer BLOCKS_MAX =
        (MAX_COUT + COUT_TILE - 1) / COUT_TILE;
    localparam integer BLOCK_W =
        (BLOCKS_MAX <= 1) ? 1 : $clog2(BLOCKS_MAX + 1);
    localparam integer DEPTH_AW =
        (BUFFER_DEPTH <= 1) ? 1 : $clog2(BUFFER_DEPTH);

    localparam [1:0] ST_FREE      = 2'd0;
    localparam [1:0] ST_LOAD      = 2'd1;
    localparam [1:0] ST_COMMITTED = 2'd2;
    localparam [1:0] ST_DRAIN     = 2'd3;

    reg [1:0] state;
    reg [PIXEL_COUNT_W-1:0] tile_pixels_reg;
    reg [COUT_W-1:0] tile_cout_total_reg;
    reg tile_layer_last_reg;
    reg [BLOCK_W-1:0] blocks_per_pixel_reg;
    reg [31:0] packet_count_reg;
    reg [31:0] expected_packets_reg;
    // One validity bit per dense packet slot.  The memory is emptied as each
    // packet word drains, so it is already clear whenever the bank returns to
    // ST_FREE.  Avoiding a synchronous whole-vector reset lets Vivado infer a
    // compact LUTRAM instead of thousands of resettable flip-flops.
    (* ram_style = "distributed" *) reg committed_slots
        [0:BUFFER_DEPTH-1];
    // A datapath soft reset may interrupt a partially loaded or draining
    // tile.  The state/credit registers reset immediately, but resetting the
    // complete slot RAM in one cycle would prevent RAM inference.  Capture
    // the dense active span on reset entry and scrub that span through the
    // existing single write port before accepting another tile.
    reg scrub_active;
    reg reset_seen;
    reg [DEPTH_AW-1:0] scrub_addr;
    reg [DEPTH_AW:0] scrub_limit;
    integer committed_init_i;
    initial begin
        for (committed_init_i = 0; committed_init_i < BUFFER_DEPTH;
             committed_init_i = committed_init_i + 1)
            committed_slots[committed_init_i] = 1'b0;
        scrub_active = 1'b0;
        reset_seen = 1'b0;
        scrub_addr = {DEPTH_AW{1'b0}};
        scrub_limit = {(DEPTH_AW+1){1'b0}};
    end

    reg [PIXEL_INDEX_W-1:0] drain_pixel;
    reg [BLOCK_W-1:0] drain_block;
    reg [CHUNK_W-1:0] drain_chunk;
    reg [DEPTH_AW-1:0] drain_word_addr;

    wire [BLOCK_W-1:0] raw_begin_blocks_per_pixel =
        (tile_cout_total + COUT_TILE - 1) >> COUT_SHIFT;
    // Storage is dense for the active tile.  The state machine never accepts
    // a second tile before drain completes, so a runtime block stride is safe
    // and avoids sizing RAM for MAX_PIXELS*MAX_COUT simultaneously.
    wire [31:0] raw_begin_storage_span =
        tile_pixels * raw_begin_blocks_per_pixel;
    wire raw_begin_config_valid =
        (tile_pixels != {PIXEL_COUNT_W{1'b0}}) &&
        (tile_pixels <= MAX_PIXELS) &&
        (tile_cout_total != {COUT_W{1'b0}}) &&
        (tile_cout_total <= MAX_COUT) &&
        (raw_begin_storage_span <= BUFFER_DEPTH);

    // The release wrapper registers the already validated layer geometry one
    // cycle before tile_begin_valid.  Selecting those fields here removes the
    // runtime pixel*block product from the bank-enable cone.  The raw/default
    // mode deliberately retains its original arithmetic and ready semantics.
    wire [BLOCK_W-1:0] precomputed_begin_blocks = tile_begin_blocks;
    wire precomputed_begin_config_valid =
        (tile_pixels != {PIXEL_COUNT_W{1'b0}}) &&
        (tile_pixels <= MAX_PIXELS) &&
        (tile_cout_total != {COUT_W{1'b0}}) &&
        (tile_cout_total <= MAX_COUT) &&
        (tile_begin_blocks != 16'd0) &&
        (tile_begin_blocks <= BLOCKS_MAX) &&
        (tile_begin_span != 32'd0) &&
        (tile_begin_span <= BUFFER_DEPTH);
    wire [BLOCK_W-1:0] begin_blocks_per_pixel =
        (PRECOMPUTED_BEGIN_GEOMETRY != 0) ?
        precomputed_begin_blocks : raw_begin_blocks_per_pixel;
    wire [31:0] begin_storage_span =
        (PRECOMPUTED_BEGIN_GEOMETRY != 0) ?
        tile_begin_span : raw_begin_storage_span;
    wire begin_config_valid =
        (PRECOMPUTED_BEGIN_GEOMETRY != 0) ?
        precomputed_begin_config_valid : raw_begin_config_valid;
    wire tile_begin_fire = tile_begin_valid && tile_begin_ready;

    wire [31:0] begin_expected_packets = begin_storage_span;

    assign tile_free = (state == ST_FREE);
    assign tile_begin_ready = (state == ST_FREE) && !scrub_active &&
                              (((PRECOMPUTED_BEGIN_GEOMETRY != 0) &&
                                !tile_begin_valid) || begin_config_valid) &&
                              (committed_credit_count == 32'd0);
    assign tile_committed = (state == ST_COMMITTED);
    assign drain_start_ready = (state == ST_COMMITTED);
    assign accepted_packet_count = packet_count_reg;
    assign expected_packet_count = expected_packets_reg;

    function [3:0] count_keep;
        input [7:0] keep;
        integer keep_lane;
        begin
            count_keep = 4'd0;
            for (keep_lane = 0; keep_lane < 8; keep_lane = keep_lane + 1)
                count_keep = count_keep + keep[keep_lane];
        end
    endfunction

    function [COUT_TILE-1:0] expected_channel_mask;
        input [COUT_W-1:0] base;
        input [COUT_W-1:0] total;
        integer lane;
        begin
            expected_channel_mask = {COUT_TILE{1'b0}};
            for (lane = 0; lane < COUT_TILE; lane = lane + 1)
                expected_channel_mask[lane] = ((base + lane) < total);
        end
    endfunction

    wire [BLOCK_W-1:0] packet_block = packet_cout_base >> COUT_SHIFT;
    wire [31:0] packet_addr_math =
        (packet_pixel * blocks_per_pixel_reg) + packet_block;
    wire packet_base_aligned =
        (packet_cout_base[COUT_SHIFT-1:0] == {COUT_SHIFT{1'b0}});
    wire packet_in_range =
        (packet_pixel < tile_pixels_reg) &&
        (packet_cout_base < tile_cout_total_reg) &&
        (packet_block < blocks_per_pixel_reg) &&
        (packet_addr_math < BUFFER_DEPTH);
    wire packet_contract_valid = packet_base_aligned && packet_in_range;
    wire [DEPTH_AW-1:0] packet_slot_addr =
        packet_addr_math[DEPTH_AW-1:0];
    // One elastic stage terminates the raw packet interface after address and
    // contract decoding.  In particular, the upstream FIFO ready path does
    // not depend on the committed-slot LUTRAM lookup or its write feedback.
    reg s0_valid;
    reg [DEPTH_AW-1:0] s0_slot_addr;
    reg s0_contract_ok;
    reg s0_mask_bad;
    reg [COUT_TILE-1:0] s0_channel_valid;
    reg [COUT_TILE*8-1:0] s0_data;

    wire [DEPTH_AW-1:0] committed_rd_addr = (state == ST_LOAD) ?
        s0_slot_addr : drain_word_addr;
    wire committed_rd_data = committed_slots[committed_rd_addr];
    wire [COUT_TILE-1:0] packet_expected_mask =
        expected_channel_mask(packet_cout_base, tile_cout_total_reg);

    wire s0_slot_committed = committed_rd_data;
    wire s0_retire = (state == ST_LOAD) && s0_valid;
    wire s0_commit =
        s0_retire && s0_contract_ok && !s0_slot_committed &&
        (packet_count_reg < expected_packets_reg);
    wire [32:0] packet_reservation_count =
        {1'b0, packet_count_reg} + s0_valid;

    // S0 retires every LOAD cycle.  A good packet writes/counts, while an
    // invalid or duplicate packet is dropped with sticky diagnostics.  Ready
    // is pure registered-credit arithmetic: non-final retirement can refill
    // in the same cycle, while the final reservation closes ready naturally.
    assign packet_ready =
        (state == ST_LOAD) &&
        (packet_reservation_count < {1'b0, expected_packets_reg});
    wire packet_fire = packet_valid && packet_ready;

    assign tile_commit_ready =
        (state == ST_LOAD) &&
        !s0_valid &&
        (packet_count_reg == expected_packets_reg) &&
        (committed_credit_count == expected_packets_reg);
    wire tile_commit_fire = tile_commit_valid && tile_commit_ready;
    wire drain_start_fire = drain_start_valid && drain_start_ready;

    // The storage is split into one 72-bit bank per output beat. A wide input
    // packet writes all banks in parallel. During drain, the banks are read
    // together once per packet and their registered outputs are selected over
    // the following BEATS_PER_PACKET cycles. This maps to simple dual-port
    // BRAM/URAM banks and sustains one AXIS beat per cycle across packet words.
    wire [71:0] bank_rd_data [0:BEATS_PER_PACKET-1];
    wire [DEPTH_AW-1:0] mem_wr_addr = s0_slot_addr;
    wire mem_wr_en = s0_commit;

    wire [COUT_W+CHUNK_W+3:0] drain_channel_base =
        (drain_block * COUT_TILE) + (drain_chunk * AXIS_BYTES);
    wire at_last_chunk =
        ((drain_chunk == BEATS_PER_PACKET - 1) ||
         ((drain_channel_base + AXIS_BYTES) >= tile_cout_total_reg));
    wire at_last_block = (drain_block == blocks_per_pixel_reg - 1'b1);
    wire at_last_pixel =
        (drain_pixel == tile_pixels_reg[PIXEL_INDEX_W-1:0] - 1'b1);
    wire at_final_beat = at_last_chunk && at_last_block && at_last_pixel;
    wire axis_fire = m_axis_tvalid && m_axis_tready;
    wire word_advance_fire = axis_fire && at_last_chunk && !at_final_beat;

    // s0_commit and the end-of-word drain handshake are mutually exclusive
    // because they occur in ST_LOAD and ST_DRAIN, respectively.  Express the
    // scoreboard update as one write port so Vivado can infer distributed RAM
    // instead of dissolving the complete array into resetless registers.
    wire committed_slot_update =
        s0_commit || (axis_fire && at_last_chunk);
    wire committed_wr_en = scrub_active || committed_slot_update;
    wire [DEPTH_AW-1:0] committed_wr_addr = scrub_active ?
        scrub_addr : (s0_commit ? mem_wr_addr : drain_word_addr);
    wire committed_wr_data = scrub_active ? 1'b0 : s0_commit;

    always @(posedge clk) begin
        if (committed_wr_en)
            committed_slots[committed_wr_addr] <= committed_wr_data;
    end

    // Active packet words are stored densely in pixel-major order.  The word
    // after a pixel's final block is therefore exactly the first word of the
    // next pixel; no runtime stride multiply is needed at that boundary.
    wire [31:0] next_word_addr_math = drain_word_addr + 1'b1;
    wire mem_rd_en = drain_start_fire || word_advance_fire;
    wire [DEPTH_AW-1:0] mem_rd_addr = drain_start_fire ?
        {DEPTH_AW{1'b0}} : next_word_addr_math[DEPTH_AW-1:0];

    genvar bank;
    generate
        for (bank = 0; bank < BEATS_PER_PACKET; bank = bank + 1) begin : g_bank
            ofm_hwc_axis_packer_bank #(
                .DEPTH(BUFFER_DEPTH),
                .ADDR_W(DEPTH_AW),
                .RAM_STYLE(RAM_STYLE)
            ) u_bank (
                .clk(clk),
                .wr_en(mem_wr_en),
                .wr_addr(mem_wr_addr),
                .wr_data({s0_channel_valid[bank*8 +: 8],
                          s0_data[bank*64 +: 64]}),
                .rd_en(mem_rd_en),
                .rd_addr(mem_rd_addr),
                .rd_data(bank_rd_data[bank])
            );
        end
    endgenerate

    reg [71:0] selected_bank_data;
    integer bank_sel;
    always @(*) begin
        selected_bank_data = 72'd0;
        for (bank_sel = 0; bank_sel < BEATS_PER_PACKET;
             bank_sel = bank_sel + 1) begin
            if (drain_chunk == bank_sel)
                selected_bank_data = bank_rd_data[bank_sel];
        end
    end

    reg [7:0] expected_keep;
    reg [63:0] masked_axis_data;
    integer byte_lane;
    always @(*) begin
        expected_keep = 8'd0;
        masked_axis_data = 64'd0;
        for (byte_lane = 0; byte_lane < AXIS_BYTES;
             byte_lane = byte_lane + 1) begin
            if ((drain_channel_base + byte_lane) < tile_cout_total_reg) begin
                expected_keep[byte_lane] = 1'b1;
                masked_axis_data[byte_lane*8 +: 8] =
                    selected_bank_data[byte_lane*8 +: 8];
            end
        end
    end

    assign m_axis_tdata = masked_axis_data;
    assign m_axis_tkeep = expected_keep;
    assign m_axis_tvalid = (state == ST_DRAIN) && committed_rd_data;
    assign m_axis_tlast =
        (state == ST_DRAIN) && tile_layer_last_reg && at_final_beat;

    always @(posedge clk) begin
        if (rst) begin
            // Only the first cycle of a multi-cycle reset observes the live
            // tile state.  Later reset cycles retain the captured scrub span.
            if (!reset_seen) begin
                scrub_addr <= {DEPTH_AW{1'b0}};
                if (scrub_active) begin
                    // A second reset during recovery restarts the same scrub.
                    scrub_active <= 1'b1;
                end else if ((state != ST_FREE) ||
                             (committed_credit_count != 32'd0)) begin
                    scrub_active <= (expected_packets_reg != 32'd0);
                    scrub_limit <= expected_packets_reg[DEPTH_AW:0];
                end else begin
                    scrub_active <= 1'b0;
                    scrub_limit <= {(DEPTH_AW+1){1'b0}};
                end
            end
            reset_seen <= 1'b1;
            state <= ST_FREE;
            tile_pixels_reg <= {PIXEL_COUNT_W{1'b0}};
            tile_cout_total_reg <= {COUT_W{1'b0}};
            tile_layer_last_reg <= 1'b0;
            blocks_per_pixel_reg <= {BLOCK_W{1'b0}};
            packet_count_reg <= 32'd0;
            expected_packets_reg <= 32'd0;
            s0_valid <= 1'b0;
            committed_credit_count <= 32'd0;
            drain_pixel <= {PIXEL_INDEX_W{1'b0}};
            drain_block <= {BLOCK_W{1'b0}};
            drain_chunk <= {CHUNK_W{1'b0}};
            drain_word_addr <= {DEPTH_AW{1'b0}};
            drain_done <= 1'b0;
            protocol_error <= 1'b0;
            overwrite_error <= 1'b0;
            underflow_error <= 1'b0;
            axis_valid_cycles <= 32'd0;
            axis_stall_cycles <= 32'd0;
            axis_beat_count <= 32'd0;
            axis_byte_count <= 32'd0;
        end else begin
            reset_seen <= 1'b0;
            drain_done <= 1'b0;

            if (scrub_active) begin
                if (({1'b0, scrub_addr} + 1'b1) >= scrub_limit) begin
                    scrub_active <= 1'b0;
                    scrub_addr <= {DEPTH_AW{1'b0}};
                end else begin
                    scrub_addr <= scrub_addr + 1'b1;
                end
            end

            if (m_axis_tvalid)
                axis_valid_cycles <= axis_valid_cycles + 1'b1;
            if (m_axis_tvalid && !m_axis_tready)
                axis_stall_cycles <= axis_stall_cycles + 1'b1;
            if (axis_fire) begin
                axis_beat_count <= axis_beat_count + 1'b1;
                axis_byte_count <= axis_byte_count + count_keep(m_axis_tkeep);
            end

            if (tile_begin_fire) begin
                state <= ST_LOAD;
                tile_pixels_reg <= tile_pixels;
                tile_cout_total_reg <= tile_cout_total;
                tile_layer_last_reg <= tile_layer_last;
                blocks_per_pixel_reg <= begin_blocks_per_pixel;
                packet_count_reg <= 32'd0;
                expected_packets_reg <= begin_expected_packets;
                s0_valid <= 1'b0;
                protocol_error <= 1'b0;
                overwrite_error <= 1'b0;
                underflow_error <= 1'b0;
                axis_valid_cycles <= 32'd0;
                axis_stall_cycles <= 32'd0;
                axis_beat_count <= 32'd0;
                axis_byte_count <= 32'd0;
            end else begin
                if (tile_begin_valid && (state == ST_FREE) &&
                    !begin_config_valid)
                    protocol_error <= 1'b1;

                if (s0_retire && !s0_contract_ok)
                    protocol_error <= 1'b1;

                if (s0_retire && s0_contract_ok &&
                    s0_slot_committed) begin
                    overwrite_error <= 1'b1;
                    protocol_error <= 1'b1;
                end

                if ((state == ST_DRAIN) &&
                    !committed_rd_data) begin
                    underflow_error <= 1'b1;
                    protocol_error <= 1'b1;
                end

                // The old S0 item always retires in LOAD.  packet_fire may
                // replace it in the same edge; otherwise the slot becomes
                // empty.  Wide payload registers intentionally have no reset.
                if (state == ST_LOAD) begin
                    s0_valid <= packet_fire;
                    if (packet_fire) begin
                        s0_slot_addr <= packet_slot_addr;
                        s0_contract_ok <= packet_contract_valid;
                        s0_mask_bad <=
                            (packet_channel_valid != packet_expected_mask);
                        s0_channel_valid <= packet_channel_valid;
                        s0_data <= packet_data;
                    end
                end

                if (s0_commit) begin
                    packet_count_reg <= packet_count_reg + 1'b1;
                    committed_credit_count <= committed_credit_count + 1'b1;
                    if (s0_mask_bad)
                        protocol_error <= 1'b1;
                end

                if (tile_commit_fire)
                    state <= ST_COMMITTED;

                if (drain_start_fire) begin
                    state <= ST_DRAIN;
                    drain_pixel <= {PIXEL_INDEX_W{1'b0}};
                    drain_block <= {BLOCK_W{1'b0}};
                    drain_chunk <= {CHUNK_W{1'b0}};
                    drain_word_addr <= {DEPTH_AW{1'b0}};
                end else if (axis_fire) begin
                    if (at_last_chunk) begin
                        committed_credit_count <=
                            committed_credit_count - 1'b1;
                    end
                    if (at_final_beat) begin
                        state <= ST_FREE;
                        drain_done <= 1'b1;
                    end else if (at_last_chunk) begin
                        drain_chunk <= {CHUNK_W{1'b0}};
                        drain_word_addr <=
                            next_word_addr_math[DEPTH_AW-1:0];
                        if (at_last_block) begin
                            drain_block <= {BLOCK_W{1'b0}};
                            drain_pixel <= drain_pixel + 1'b1;
                        end else begin
                            drain_block <= drain_block + 1'b1;
                        end
                    end else begin
                        drain_chunk <= drain_chunk + 1'b1;
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    wire [15:0] simulation_expected_begin_blocks =
        (tile_cout_total + COUT_TILE - 1) >> COUT_SHIFT;
    wire [31:0] simulation_expected_begin_span =
        tile_pixels * tile_begin_blocks;

    // Precomputed geometry is a validated contract.  Keep exact-product
    // checking in simulation only so synthesis does not rebuild the multiplier
    // in the ready/bank-enable cone.
    always @(posedge clk) begin
        if (!rst && (PRECOMPUTED_BEGIN_GEOMETRY != 0) &&
            tile_begin_fire) begin
            if (tile_begin_blocks != simulation_expected_begin_blocks)
                $error("ofm_hwc_axis_packer: precomputed block count mismatch");
            if (tile_begin_span != simulation_expected_begin_span)
                $error("ofm_hwc_axis_packer: precomputed span mismatch");
        end
    end

    initial begin
        if ((COUT_TILE != 16) && (COUT_TILE != 32))
            $error("ofm_hwc_axis_packer: COUT_TILE must be 16 or 32");
        if ((COUT_TILE % AXIS_BYTES) != 0)
            $error("ofm_hwc_axis_packer: COUT_TILE must be byte-beat aligned");
    end
`endif
endmodule


// One independently inferred 64-data + 8-mask memory bank.
module ofm_hwc_axis_packer_bank #(
    parameter integer DEPTH = 1024,
    parameter integer ADDR_W = 10,
    parameter RAM_STYLE = "block"
) (
    input  wire              clk,
    input  wire              wr_en,
    input  wire [ADDR_W-1:0] wr_addr,
    input  wire [71:0]       wr_data,
    input  wire              rd_en,
    input  wire [ADDR_W-1:0] rd_addr,
    output reg  [71:0]       rd_data
);
    (* ram_style = RAM_STYLE *) reg [71:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        if (rd_en)
            rd_data <= mem[rd_addr];
    end
endmodule

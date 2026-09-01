`timescale 1ns / 1ps

// Two-bank tile-local HWC reorder and AXI-Stream writer.
//
// The input side owns at most one tile at a time.  Once that tile is
// committed, the other bank may immediately accept the next tile while the
// first bank drains.  Banks are allocated and drained in the same alternating
// order, so AXI output can never pass an earlier committed tile.
//
// A small byte reservoir compacts the per-pixel tail groups emitted by the
// tile banks.  Residual bytes survive pixel and tile boundaries, so the
// external stream has TKEEP=8'hff on every beat except the one layer-final
// beat.  tile_layer_last belongs to the tile accepted by tile_begin and must
// only be asserted for the final tile of a layer.
module ofm_hwc_axis_pingpong #(
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
    input  wire                         clear_stats,

    input  wire                         tile_begin_valid,
    output wire                         tile_begin_ready,
    input  wire [PIXEL_COUNT_W-1:0]     tile_pixels,
    input  wire [COUT_W-1:0]            tile_cout_total,
    input  wire [15:0]                  tile_begin_blocks,
    input  wire [31:0]                  tile_begin_span,
    input  wire                         tile_layer_last,
    output wire                         tile_accept,

    input  wire                         packet_valid,
    output wire                         packet_ready,
    input  wire [PIXEL_INDEX_W-1:0]     packet_pixel,
    input  wire [COUT_W-1:0]            packet_cout_base,
    input  wire [COUT_TILE-1:0]         packet_channel_valid,
    input  wire [COUT_TILE*8-1:0]       packet_data,

    input  wire                         tile_commit_valid,
    output wire                         tile_commit_ready,
    output wire                         tile_commit,

    output wire [63:0]                  m_axis_tdata,
    output wire [7:0]                   m_axis_tkeep,
    output wire                         m_axis_tvalid,
    input  wire                         m_axis_tready,
    output wire                         m_axis_tlast,

    output wire                         all_free,
    output wire                         tile_load_active,
    output reg                          protocol_error,
    output reg                          overwrite_error,
    output reg                          underflow_error,
    output reg  [31:0]                  axis_valid_cycles,
    output reg  [31:0]                  axis_stall_cycles,
    output reg  [31:0]                  axis_beat_count,
    output reg  [31:0]                  axis_byte_count
);
    reg alloc_bank;
    reg load_active;
    reg load_bank;
    reg drain_active;
    reg drain_bank;
    reg next_drain_bank;

    localparam integer BLOCKS_MAX =
        (MAX_COUT + COUT_TILE - 1) / COUT_TILE;

    wire bank0_begin_ready;
    wire bank1_begin_ready;
    wire bank0_packet_ready;
    wire bank1_packet_ready;
    wire bank0_commit_ready;
    wire bank1_commit_ready;
    wire bank0_committed;
    wire bank1_committed;
    wire bank0_drain_start_ready;
    wire bank1_drain_start_ready;
    wire bank0_drain_done;
    wire bank1_drain_done;
    wire bank0_free;
    wire bank1_free;

    wire [63:0] bank0_axis_tdata;
    wire [63:0] bank1_axis_tdata;
    wire [7:0] bank0_axis_tkeep;
    wire [7:0] bank1_axis_tkeep;
    wire bank0_axis_tvalid;
    wire bank1_axis_tvalid;
    wire bank0_axis_tlast;
    wire bank1_axis_tlast;

    wire bank0_protocol_error;
    wire bank1_protocol_error;
    wire bank0_overwrite_error;
    wire bank1_overwrite_error;
    wire bank0_underflow_error;
    wire bank1_underflow_error;

    // Invalid precomputed descriptors never enter either bank.  Latch the
    // rejected contract at this level as well, because a rejected bank stays
    // free and its per-bank diagnostic is intentionally masked from the normal
    // aggregate path while free.
    wire precomputed_begin_config_valid =
        (tile_pixels != {PIXEL_COUNT_W{1'b0}}) &&
        (tile_pixels <= MAX_PIXELS) &&
        (tile_cout_total != {COUT_W{1'b0}}) &&
        (tile_cout_total <= MAX_COUT) &&
        (tile_begin_blocks != 16'd0) &&
        (tile_begin_blocks <= BLOCKS_MAX) &&
        (tile_begin_span != 32'd0) &&
        (tile_begin_span <= BUFFER_DEPTH);
    wire precomputed_begin_contract_error =
        (PRECOMPUTED_BEGIN_GEOMETRY != 0) && tile_begin_valid &&
        !precomputed_begin_config_valid;

    assign tile_begin_ready = !load_active &&
        (alloc_bank ? bank1_begin_ready : bank0_begin_ready);
    assign tile_accept = tile_begin_valid && tile_begin_ready;

    assign packet_ready = load_active &&
        (load_bank ? bank1_packet_ready : bank0_packet_ready);

    assign tile_commit_ready = load_active &&
        (load_bank ? bank1_commit_ready : bank0_commit_ready);
    assign tile_commit = tile_commit_valid && tile_commit_ready;

    wire bank0_begin_valid = tile_begin_valid && !load_active && !alloc_bank;
    wire bank1_begin_valid = tile_begin_valid && !load_active && alloc_bank;
    wire bank0_packet_valid = packet_valid && load_active && !load_bank;
    wire bank1_packet_valid = packet_valid && load_active && load_bank;
    wire bank0_commit_valid = tile_commit_valid && load_active && !load_bank;
    wire bank1_commit_valid = tile_commit_valid && load_active && load_bank;

    // Commit order is allocation order.  next_drain_bank therefore acts as a
    // one-bit ordered queue head; the other committed bank cannot start until
    // the current bank has produced its final accepted beat.
    wire bank0_drain_start_valid =
        !drain_active && !next_drain_bank && bank0_committed;
    wire bank1_drain_start_valid =
        !drain_active && next_drain_bank && bank1_committed;
    wire bank0_drain_start =
        bank0_drain_start_valid && bank0_drain_start_ready;
    wire bank1_drain_start =
        bank1_drain_start_valid && bank1_drain_start_ready;

    wire [63:0] source_axis_tdata =
        drain_bank ? bank1_axis_tdata : bank0_axis_tdata;
    wire [7:0] source_axis_tkeep =
        drain_bank ? bank1_axis_tkeep : bank0_axis_tkeep;
    wire source_axis_tvalid = drain_active &&
        (drain_bank ? bank1_axis_tvalid : bank0_axis_tvalid);
    wire source_axis_tlast = drain_active &&
        (drain_bank ? bank1_axis_tlast : bank0_axis_tlast);

    // At most seven residual bytes are retained whenever another source beat
    // is accepted.  A 16-byte reservoir therefore supports a simultaneous
    // output pop and input append without creating a combinational path from
    // source TVALID to external TVALID.
    reg [127:0] byte_reservoir;
    reg [4:0] byte_count;
    reg layer_last_pending;
    reg [127:0] byte_reservoir_next;
    reg [4:0] byte_count_next;
    reg layer_last_pending_next;

    function [7:0] low_keep_mask;
        input [4:0] count;
        integer keep_index;
        begin
            low_keep_mask = 8'd0;
            for (keep_index = 0; keep_index < 8;
                 keep_index = keep_index + 1)
                if (keep_index < count)
                    low_keep_mask[keep_index] = 1'b1;
        end
    endfunction

    function [63:0] keep_masked_data;
        input [63:0] data;
        input [7:0] keep;
        integer data_index;
        begin
            keep_masked_data = 64'd0;
            for (data_index = 0; data_index < 8;
                 data_index = data_index + 1)
                if (keep[data_index])
                    keep_masked_data[data_index*8 +: 8] =
                        data[data_index*8 +: 8];
        end
    endfunction

    assign m_axis_tdata = byte_reservoir[63:0];
    assign m_axis_tkeep = (byte_count >= 5'd8) ?
        8'hff : low_keep_mask(byte_count);
    assign m_axis_tvalid = (byte_count >= 5'd8) ||
        (layer_last_pending && (byte_count != 5'd0));
    assign m_axis_tlast = layer_last_pending &&
        (byte_count != 5'd0) && (byte_count <= 5'd8);

    wire axis_fire = m_axis_tvalid && m_axis_tready;
    wire [3:0] source_byte_count = count_keep(source_axis_tkeep);
    wire source_axis_tready = !layer_last_pending &&
        ((byte_count <= 5'd7) || axis_fire);
    wire source_axis_fire = source_axis_tvalid && source_axis_tready;
    wire bank0_axis_tready = drain_active && !drain_bank &&
        source_axis_tready;
    wire bank1_axis_tready = drain_active && drain_bank &&
        source_axis_tready;

    assign all_free = !load_active && !drain_active &&
                      bank0_free && bank1_free &&
                      (byte_count == 5'd0) && !layer_last_pending;
    assign tile_load_active = load_active;

    function [3:0] count_keep;
        input [7:0] keep;
        integer lane;
        begin
            count_keep = 4'd0;
            for (lane = 0; lane < 8; lane = lane + 1)
                count_keep = count_keep + keep[lane];
        end
    endfunction

    wire active_drain_done = drain_active &&
        (drain_bank ? bank1_drain_done : bank0_drain_done);

    always @(*) begin
        byte_reservoir_next = byte_reservoir;
        byte_count_next = byte_count;
        layer_last_pending_next = layer_last_pending;

        if (axis_fire) begin
            if (byte_count > 5'd8) begin
                byte_reservoir_next = byte_reservoir >> 64;
                byte_count_next = byte_count - 5'd8;
            end else begin
                byte_reservoir_next = 128'd0;
                byte_count_next = 5'd0;
            end
            if (m_axis_tlast)
                layer_last_pending_next = 1'b0;
        end

        if (source_axis_fire) begin
            byte_reservoir_next = byte_reservoir_next |
                ({64'd0, keep_masked_data(source_axis_tdata,
                                          source_axis_tkeep)} <<
                 (byte_count_next * 8));
            byte_count_next = byte_count_next + source_byte_count;
            if (source_axis_tlast)
                layer_last_pending_next = 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            alloc_bank <= 1'b0;
            load_active <= 1'b0;
            load_bank <= 1'b0;
            drain_active <= 1'b0;
            drain_bank <= 1'b0;
            next_drain_bank <= 1'b0;
            protocol_error <= 1'b0;
            overwrite_error <= 1'b0;
            underflow_error <= 1'b0;
            axis_valid_cycles <= 32'd0;
            axis_stall_cycles <= 32'd0;
            axis_beat_count <= 32'd0;
            axis_byte_count <= 32'd0;
            byte_reservoir <= 128'd0;
            byte_count <= 5'd0;
            layer_last_pending <= 1'b0;
        end else begin
            byte_reservoir <= byte_reservoir_next;
            byte_count <= byte_count_next;
            layer_last_pending <= layer_last_pending_next;
            if (clear_stats) begin
                protocol_error <= 1'b0;
                overwrite_error <= 1'b0;
                underflow_error <= 1'b0;
                axis_valid_cycles <= 32'd0;
                axis_stall_cycles <= 32'd0;
                axis_beat_count <= 32'd0;
                axis_byte_count <= 32'd0;
                byte_reservoir <= 128'd0;
                byte_count <= 5'd0;
                layer_last_pending <= 1'b0;
            end else begin
                // Ignore stale diagnostics left in a free bank.  The packer
                // clears them when that bank accepts its next tile.
                protocol_error <= protocol_error |
                    precomputed_begin_contract_error |
                    ((!bank0_free) && bank0_protocol_error) |
                    ((!bank1_free) && bank1_protocol_error);
                overwrite_error <= overwrite_error |
                    ((!bank0_free) && bank0_overwrite_error) |
                    ((!bank1_free) && bank1_overwrite_error);
                underflow_error <= underflow_error |
                    ((!bank0_free) && bank0_underflow_error) |
                    ((!bank1_free) && bank1_underflow_error);

                if (m_axis_tvalid)
                    axis_valid_cycles <= axis_valid_cycles + 1'b1;
                if (m_axis_tvalid && !m_axis_tready)
                    axis_stall_cycles <= axis_stall_cycles + 1'b1;
                if (axis_fire) begin
                    axis_beat_count <= axis_beat_count + 1'b1;
                    axis_byte_count <= axis_byte_count +
                                       count_keep(m_axis_tkeep);
                end
            end

            if (tile_accept) begin
                load_active <= 1'b1;
                load_bank <= alloc_bank;
            end

            if (tile_commit) begin
                load_active <= 1'b0;
                alloc_bank <= ~load_bank;
            end

            if (bank0_drain_start || bank1_drain_start) begin
                drain_active <= 1'b1;
                drain_bank <= bank1_drain_start;
            end else if (active_drain_done) begin
                drain_active <= 1'b0;
                next_drain_bank <= ~drain_bank;
            end
        end
    end

    ofm_hwc_axis_packer #(
        .COUT_TILE(COUT_TILE),
        .MAX_PIXELS(MAX_PIXELS),
        .MAX_COUT(MAX_COUT),
        .BUFFER_DEPTH(BUFFER_DEPTH),
        .RAM_STYLE(RAM_STYLE),
        .PRECOMPUTED_BEGIN_GEOMETRY(PRECOMPUTED_BEGIN_GEOMETRY)
    ) u_bank0 (
        .clk(clk), .rst(rst),
        .tile_begin_valid(bank0_begin_valid),
        .tile_begin_ready(bank0_begin_ready),
        .tile_pixels(tile_pixels), .tile_cout_total(tile_cout_total),
        .tile_begin_blocks(tile_begin_blocks),
        .tile_begin_span(tile_begin_span),
        .tile_layer_last(tile_layer_last),
        .packet_valid(bank0_packet_valid),
        .packet_ready(bank0_packet_ready),
        .packet_pixel(packet_pixel), .packet_cout_base(packet_cout_base),
        .packet_channel_valid(packet_channel_valid),
        .packet_data(packet_data),
        .tile_commit_valid(bank0_commit_valid),
        .tile_commit_ready(bank0_commit_ready),
        .tile_committed(bank0_committed),
        .drain_start_valid(bank0_drain_start_valid),
        .drain_start_ready(bank0_drain_start_ready),
        .drain_done(bank0_drain_done), .tile_free(bank0_free),
        .m_axis_tdata(bank0_axis_tdata),
        .m_axis_tkeep(bank0_axis_tkeep),
        .m_axis_tvalid(bank0_axis_tvalid),
        .m_axis_tready(bank0_axis_tready),
        .m_axis_tlast(bank0_axis_tlast),
        .protocol_error(bank0_protocol_error),
        .overwrite_error(bank0_overwrite_error),
        .underflow_error(bank0_underflow_error),
        .accepted_packet_count(), .expected_packet_count(),
        .committed_credit_count(), .axis_valid_cycles(),
        .axis_stall_cycles(), .axis_beat_count(), .axis_byte_count()
    );

    ofm_hwc_axis_packer #(
        .COUT_TILE(COUT_TILE),
        .MAX_PIXELS(MAX_PIXELS),
        .MAX_COUT(MAX_COUT),
        .BUFFER_DEPTH(BUFFER_DEPTH),
        .RAM_STYLE(RAM_STYLE),
        .PRECOMPUTED_BEGIN_GEOMETRY(PRECOMPUTED_BEGIN_GEOMETRY)
    ) u_bank1 (
        .clk(clk), .rst(rst),
        .tile_begin_valid(bank1_begin_valid),
        .tile_begin_ready(bank1_begin_ready),
        .tile_pixels(tile_pixels), .tile_cout_total(tile_cout_total),
        .tile_begin_blocks(tile_begin_blocks),
        .tile_begin_span(tile_begin_span),
        .tile_layer_last(tile_layer_last),
        .packet_valid(bank1_packet_valid),
        .packet_ready(bank1_packet_ready),
        .packet_pixel(packet_pixel), .packet_cout_base(packet_cout_base),
        .packet_channel_valid(packet_channel_valid),
        .packet_data(packet_data),
        .tile_commit_valid(bank1_commit_valid),
        .tile_commit_ready(bank1_commit_ready),
        .tile_committed(bank1_committed),
        .drain_start_valid(bank1_drain_start_valid),
        .drain_start_ready(bank1_drain_start_ready),
        .drain_done(bank1_drain_done), .tile_free(bank1_free),
        .m_axis_tdata(bank1_axis_tdata),
        .m_axis_tkeep(bank1_axis_tkeep),
        .m_axis_tvalid(bank1_axis_tvalid),
        .m_axis_tready(bank1_axis_tready),
        .m_axis_tlast(bank1_axis_tlast),
        .protocol_error(bank1_protocol_error),
        .overwrite_error(bank1_overwrite_error),
        .underflow_error(bank1_underflow_error),
        .accepted_packet_count(), .expected_packet_count(),
        .committed_credit_count(), .axis_valid_cycles(),
        .axis_stall_cycles(), .axis_beat_count(), .axis_byte_count()
    );
endmodule

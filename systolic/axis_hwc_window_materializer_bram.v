`timescale 1ns / 1ps

// One 64-bit, byte-write-enabled true-dual-port line-store bank.  Port A is
// used for AXIS writes while the input side is active and becomes the first
// read port while a window row is being materialized.  Port B is read-only.
// The parent never writes and materializes in the same cycle.
module axis_hwc_window_bram_bank #(
    parameter integer DEPTH = 1024,
    parameter integer ADDR_W = 10
) (
    input  wire                  clk,
    input  wire [ADDR_W-1:0]     a_addr,
    input  wire                  a_wr_en,
    input  wire [7:0]            a_wr_keep,
    input  wire [63:0]           a_wr_data,
    output reg  [63:0]           a_rd_data,
    input  wire [ADDR_W-1:0]     b_addr,
    output reg  [63:0]           b_rd_data
);
    (* ram_style = "block" *) reg [63:0] mem [0:DEPTH-1];
    integer byte_i;

    always @(posedge clk) begin
        if (a_wr_en) begin
            for (byte_i = 0; byte_i < 8; byte_i = byte_i + 1)
                if (a_wr_keep[byte_i])
                    mem[a_addr][byte_i*8 +: 8] <=
                        a_wr_data[byte_i*8 +: 8];
        end else begin
            a_rd_data <= mem[a_addr];
        end
        b_rd_data <= mem[b_addr];
    end
endmodule

// Resource-bounded layer-long raw-HWC window materializer.
//
// Storage is organized as 32 true-dual-port BRAM banks:
//
//     bank = {input_row mod 4, input_x mod 4,
//             (channel / 8) mod 2}
//     word = {(channel / 8) / 2, input_x / 4}
//     byte = channel mod 8
//
// The channel-group parity bit is essential: an unaligned 64-bit HWC beat can
// straddle two adjacent channel groups, and those two words must not compete
// for the single write address of one BRAM port.  With CIN >= 3, eight
// consecutive HWC bytes now update at most one word in each physical bank.
// Splitting the original 1024-word spatial bank into two 512-word parity banks
// keeps the total stored bit count unchanged.  A 3x3
// ROWS=18 vector is exactly two channels by nine spatial taps, so both
// channels are read in parallel through the two BRAM ports.  This removes the
// 216 asynchronous byte memories and their 18 large dynamic read muxes from
// the first implementation.  Three-by-three entries sustain one issue per
// cycle after the synchronous read latency; native 1x1 entries use two pairs
// of word reads and are intentionally lower throughput because they account
// for only a small fraction of the fixed ten-layer workload.
module axis_hwc_window_materializer_bram #(
    parameter integer ROWS = 18,
    parameter integer AXIS_W = 64,
    parameter integer KEEP_W = AXIS_W / 8,
    parameter integer MAX_FM_W = 416,
    parameter integer MAX_CHANNELS = 1024,
    parameter integer LINE_BANK_DEPTH = 1024,
    parameter integer MAX_PASSES = 512,
    parameter integer EPOCH_W = 8
) (
    input  wire                         clk,
    input  wire                         rst,

    input  wire                         cfg_start,
    input  wire [15:0]                  cfg_fm_h,
    input  wire [15:0]                  cfg_fm_w,
    input  wire [13:0]                  cfg_cin,
    input  wire [15:0]                  cfg_ofm_h,
    input  wire [15:0]                  cfg_ofm_w,
    input  wire                         cfg_kernel_1x1,
    input  wire [1:0]                   cfg_stride,
    input  wire [1:0]                   cfg_pad,
    input  wire [7:0]                   cfg_input_zero_point,
    input  wire [EPOCH_W-1:0]           cfg_epoch,

    output wire                         s_axis_tready,
    input  wire                         s_axis_tvalid,
    input  wire [AXIS_W-1:0]            s_axis_tdata,
    input  wire [KEEP_W-1:0]            s_axis_tkeep,
    input  wire                         s_axis_tlast,

    output wire                         m_entry_valid,
    input  wire                         m_entry_ready,
    output wire [ROWS*8-1:0]            m_entry_data,
    output wire [ROWS-1:0]              m_entry_lane_valid,
    output wire [31:0]                  m_entry_pixel,
    output wire [15:0]                  m_entry_k_pass,
    output wire [EPOCH_W-1:0]           m_entry_epoch,
    output wire                         m_entry_last,

    output reg  [MAX_PASSES-1:0]        pass_ready_bitmap,
    output wire [EPOCH_W-1:0]           pass_ready_epoch,
    output wire                         busy,
    output reg                          input_done,
    output reg                          done,

    output reg                          config_error,
    output reg                          tkeep_error,
    output reg                          tlast_error,
    output reg                          overflow_error,
    output reg                          bank_collision_error,
    output reg                          row_overwrite_error,
    output reg                          protocol_error,
    output reg  [31:0]                  accepted_beats,
    output reg  [31:0]                  accepted_bytes,
    output reg  [31:0]                  emitted_entries,
    output reg  [31:0]                  axis_stall_cycles,
    output reg  [31:0]                  entry_stall_cycles,
    output reg  [31:0]                  materialize_cycles
);
    localparam integer ROW_BANKS = 4;
    localparam integer X_BANKS = 4;
    localparam integer CHANNEL_BANKS = 2;
    localparam integer CHANNEL_BYTES = 8;
    localparam integer SPATIAL_BANKS = ROW_BANKS * X_BANKS;
    localparam integer BANK_COUNT = SPATIAL_BANKS * CHANNEL_BANKS;
    localparam integer BANK_W = $clog2(BANK_COUNT);
    localparam integer BANK_DEPTH = LINE_BANK_DEPTH / CHANNEL_BANKS;
    localparam integer LINE_AW =
        (BANK_DEPTH <= 2) ? 1 : $clog2(BANK_DEPTH);

    localparam [2:0] ONE_IDLE      = 3'd0;
    localparam [2:0] ONE_ISSUE01   = 3'd1;
    localparam [2:0] ONE_CAPTURE01 = 3'd2;
    localparam [2:0] ONE_CAPTURE23 = 3'd3;
    localparam [2:0] ONE_WAIT_OUT  = 3'd4;

    initial begin
        if (ROWS != 18)
            $error("axis_hwc_window_materializer_bram requires ROWS=18");
        if (AXIS_W != 64 || KEEP_W != 8)
            $error("axis_hwc_window_materializer_bram requires 64-bit AXIS");
        if (LINE_BANK_DEPTH < CHANNEL_BANKS ||
            BANK_DEPTH != (1 << LINE_AW) ||
            LINE_BANK_DEPTH != BANK_DEPTH * CHANNEL_BANKS)
            $error("LINE_BANK_DEPTH must be twice a power of two");
    end

    reg busy_q;
    reg [15:0] fm_h_q;
    reg [15:0] fm_w_q;
    reg [13:0] cin_q;
    reg [15:0] ofm_h_q;
    reg [15:0] ofm_w_q;
    reg kernel_1x1_q;
    reg [1:0] stride_q;
    reg [1:0] pad_q;
    reg [7:0] input_zero_point_q;
    reg [EPOCH_W-1:0] epoch_q;
    reg [15:0] x_groups_q;
    reg [15:0] channel_groups_q;
    reg [15:0] pass_count_q;
    reg [15:0] k_total_q;
    reg [31:0] expected_bytes_q;

    // Raw-HWC write cursor.  The grouped counters make the hot write path an
    // increment/carry network instead of eight copies of division/modulo.
    reg [15:0] wr_y_q;
    reg [15:0] wr_x_q;
    reg [13:0] wr_ch_q;
    reg [1:0]  wr_x_mod_q;
    reg [15:0] wr_x_group_q;
    reg [2:0]  wr_ch_mod_q;
    reg [15:0] wr_ch_group_q;
    reg [LINE_AW-1:0] wr_word_addr_q;

    reg loaded_any_q;
    reg [15:0] loaded_through_y_q;
    reg [ROW_BANKS-1:0] row_valid_q;
    reg [15:0] row_tag_q [0:ROW_BANKS-1];

    // Current output row and the next entry in row/pass/x order.
    reg mat_active_q;
    reg [15:0] mat_oy_q;
    reg [15:0] mat_x_q;
    reg [15:0] mat_pass_q;
    reg [15:0] next_oy_q;
    reg all_issued_q;

    // Shared output holding register.  It is the only state visible on the
    // entry ready/valid interface and therefore guarantees AXIS-style hold.
    reg out_valid_q;
    reg [ROWS*8-1:0] out_data_q;
    reg [ROWS-1:0] out_lane_valid_q;
    reg [31:0] out_pixel_q;
    reg [15:0] out_pass_q;
    reg [15:0] out_oy_q;
    reg [15:0] out_x_q;
    reg out_last_q;

    assign busy = busy_q;
    assign pass_ready_epoch = epoch_q;
    assign m_entry_valid = out_valid_q;
    assign m_entry_data = out_data_q;
    assign m_entry_lane_valid = out_lane_valid_q;
    assign m_entry_pixel = out_pixel_q;
    assign m_entry_k_pass = out_pass_q;
    assign m_entry_epoch = epoch_q;
    assign m_entry_last = out_last_q;
    assign s_axis_tready = busy_q && !input_done && !mat_active_q &&
                           !out_valid_q;

    wire axis_fire = s_axis_tvalid && s_axis_tready;
    wire out_fire = out_valid_q && m_entry_ready;

    function [7:0] center_ifm_byte;
        input [7:0] raw_u8;
        input [7:0] zero_point;
        reg signed [9:0] centered;
        begin
            centered = $signed({2'b00, raw_u8}) -
                       $signed({2'b00, zero_point});
            if (centered > 10'sd127)
                center_ifm_byte = 8'h7f;
            else if (centered < -10'sd128)
                center_ifm_byte = 8'h80;
            else
                center_ifm_byte = centered[7:0];
        end
    endfunction

    function [15:0] convolution_output_dim;
        input [15:0] input_dim;
        input kernel_1x1;
        input [1:0] stride;
        input [1:0] pad;
        integer extent;
        begin
            extent = input_dim + (pad << 1) -
                     (kernel_1x1 ? 1 : 3);
            if (extent < 0 || (stride != 1 && stride != 2))
                convolution_output_dim = 16'd0;
            else if (stride == 1)
                convolution_output_dim = extent + 1;
            else
                convolution_output_dim = (extent >> 1) + 1;
        end
    endfunction

    function output_row_ready;
        input [15:0] oy;
        input [15:0] loaded_y;
        input loaded_any;
        input all_input_done;
        integer max_fy;
        begin
            if (kernel_1x1_q)
                max_fy = (oy * stride_q) - pad_q;
            else
                max_fy = (oy * stride_q) + 2 - pad_q;
            if (max_fy < 0)
                output_row_ready = 1'b1;
            else if (max_fy >= fm_h_q)
                output_row_ready = all_input_done;
            else
                output_row_ready = loaded_any && (loaded_y >= max_fy);
        end
    endfunction

    // ------------------------------------------------------------------
    // Eight-byte HWC write mapper
    // ------------------------------------------------------------------
    reg [15:0] lane_y [0:KEEP_W-1];
    reg [15:0] lane_x [0:KEEP_W-1];
    reg [13:0] lane_ch [0:KEEP_W-1];
    reg [BANK_W-1:0] lane_bank [0:KEEP_W-1];
    reg [LINE_AW-1:0] lane_addr [0:KEEP_W-1];
    reg [2:0] lane_byte [0:KEEP_W-1];
    reg [KEEP_W-1:0] lane_map_valid;
    reg [15:0] post_wr_y;
    reg [15:0] post_wr_x;
    reg [13:0] post_wr_ch;
    reg [1:0] post_wr_x_mod;
    reg [15:0] post_wr_x_group;
    reg [2:0] post_wr_ch_mod;
    reg [15:0] post_wr_ch_group;
    reg [LINE_AW-1:0] post_wr_word_addr;
    reg [7:0] keep_count_comb;
    reg keep_prefix_comb;
    reg row_completed_comb;
    reg [15:0] last_completed_y_comb;
    reg bank_collision_comb;
    reg bank_addr_overflow_comb;
    reg overwrite_comb;

    reg [BANK_COUNT-1:0] bank_wr_en;
    reg [7:0] bank_wr_keep [0:BANK_COUNT-1];
    reg [63:0] bank_wr_data [0:BANK_COUNT-1];
    reg [LINE_AW-1:0] bank_wr_addr [0:BANK_COUNT-1];

    integer map_i;
    integer map_j;
    integer init_i;
    integer tmp_y;
    integer tmp_x;
    integer tmp_ch;
    integer tmp_x_mod;
    integer tmp_x_group;
    integer tmp_ch_mod;
    integer tmp_ch_group;
    integer tmp_word_addr;
    integer tmp_valid_count;
    integer tmp_bank;
    integer min_needed_y;
    reg seen_keep_zero;

    wire [31:0] post_byte_count = accepted_bytes + keep_count_comb;
    wire beat_finishes_input = (post_byte_count == expected_bytes_q);

    always @* begin
        tmp_y = wr_y_q;
        tmp_x = wr_x_q;
        tmp_ch = wr_ch_q;
        tmp_x_mod = wr_x_mod_q;
        tmp_x_group = wr_x_group_q;
        tmp_ch_mod = wr_ch_mod_q;
        tmp_ch_group = wr_ch_group_q;
        tmp_word_addr = wr_word_addr_q;
        tmp_valid_count = 0;
        keep_count_comb = 0;
        keep_prefix_comb = 1'b1;
        seen_keep_zero = 1'b0;
        row_completed_comb = 1'b0;
        last_completed_y_comb = loaded_through_y_q;

        for (map_i = 0; map_i < KEEP_W; map_i = map_i + 1) begin
            lane_y[map_i] = tmp_y[15:0];
            lane_x[map_i] = tmp_x[15:0];
            lane_ch[map_i] = tmp_ch[13:0];
            lane_bank[map_i] =
                ((((tmp_y & 3) * X_BANKS) + tmp_x_mod) *
                 CHANNEL_BANKS) + (tmp_ch_group & 1);
            lane_addr[map_i] = tmp_word_addr[LINE_AW-1:0];
            lane_byte[map_i] = tmp_ch_mod[2:0];
            lane_map_valid[map_i] = s_axis_tkeep[map_i] &&
                ((accepted_bytes + tmp_valid_count) < expected_bytes_q);

            if (s_axis_tkeep[map_i]) begin
                if (seen_keep_zero)
                    keep_prefix_comb = 1'b0;
                keep_count_comb = keep_count_comb + 1'b1;
                tmp_valid_count = tmp_valid_count + 1;

                if (tmp_ch + 1 == cin_q) begin
                    tmp_ch = 0;
                    tmp_ch_mod = 0;
                    tmp_ch_group = 0;
                    if (tmp_x + 1 == fm_w_q) begin
                        row_completed_comb = 1'b1;
                        last_completed_y_comb = tmp_y[15:0];
                        tmp_x = 0;
                        tmp_x_mod = 0;
                        tmp_x_group = 0;
                        tmp_y = tmp_y + 1;
                    end else begin
                        tmp_x = tmp_x + 1;
                        if (tmp_x_mod == X_BANKS-1) begin
                            tmp_x_mod = 0;
                            tmp_x_group = tmp_x_group + 1;
                        end else begin
                            tmp_x_mod = tmp_x_mod + 1;
                        end
                    end
                    tmp_word_addr = tmp_x_group;
                end else begin
                    tmp_ch = tmp_ch + 1;
                    if (tmp_ch_mod == CHANNEL_BYTES-1) begin
                        tmp_ch_mod = 0;
                        tmp_ch_group = tmp_ch_group + 1;
                        if (!tmp_ch_group[0])
                            tmp_word_addr = tmp_word_addr + x_groups_q;
                    end else begin
                        tmp_ch_mod = tmp_ch_mod + 1;
                    end
                end
            end else begin
                seen_keep_zero = 1'b1;
            end
        end

        post_wr_y = tmp_y[15:0];
        post_wr_x = tmp_x[15:0];
        post_wr_ch = tmp_ch[13:0];
        post_wr_x_mod = tmp_x_mod[1:0];
        post_wr_x_group = tmp_x_group[15:0];
        post_wr_ch_mod = tmp_ch_mod[2:0];
        post_wr_ch_group = tmp_ch_group[15:0];
        post_wr_word_addr = tmp_word_addr[LINE_AW-1:0];
    end

    always @* begin
        bank_wr_en = {BANK_COUNT{1'b0}};
        bank_addr_overflow_comb = 1'b0;
        for (init_i = 0; init_i < BANK_COUNT; init_i = init_i + 1) begin
            bank_wr_keep[init_i] = 8'd0;
            bank_wr_data[init_i] = 64'd0;
            bank_wr_addr[init_i] = {LINE_AW{1'b0}};
        end

        for (map_i = 0; map_i < KEEP_W; map_i = map_i + 1) begin
            if (lane_map_valid[map_i]) begin
                tmp_bank = lane_bank[map_i];
                if (lane_addr[map_i] < BANK_DEPTH) begin
                    bank_wr_en[tmp_bank] = 1'b1;
                    bank_wr_addr[tmp_bank] = lane_addr[map_i];
                    bank_wr_keep[tmp_bank][lane_byte[map_i]] = 1'b1;
                    bank_wr_data[tmp_bank][lane_byte[map_i]*8 +: 8] =
                        center_ifm_byte(
                            s_axis_tdata[map_i*8 +: 8],
                            input_zero_point_q);
                end else begin
                    bank_addr_overflow_comb = 1'b1;
                end
            end
        end
    end

    always @* begin
        bank_collision_comb = 1'b0;
        for (map_i = 0; map_i < KEEP_W; map_i = map_i + 1)
            for (map_j = map_i + 1; map_j < KEEP_W;
                 map_j = map_j + 1)
                if (lane_map_valid[map_i] && lane_map_valid[map_j] &&
                    (lane_bank[map_i] == lane_bank[map_j]) &&
                    ((lane_addr[map_i] != lane_addr[map_j]) ||
                     (lane_byte[map_i] == lane_byte[map_j])))
                    bank_collision_comb = 1'b1;
    end

    always @* begin
        overwrite_comb = 1'b0;
        min_needed_y = (next_oy_q * stride_q) - pad_q;
        if (min_needed_y < 0)
            min_needed_y = 0;
        for (map_i = 0; map_i < KEEP_W; map_i = map_i + 1)
            if (lane_map_valid[map_i] && lane_x[map_i] == 0 &&
                lane_ch[map_i] == 0 &&
                row_valid_q[lane_y[map_i][1:0]] &&
                row_tag_q[lane_y[map_i][1:0]] != lane_y[map_i] &&
                row_tag_q[lane_y[map_i][1:0]] >= min_needed_y)
                overwrite_comb = 1'b1;
    end

    // ------------------------------------------------------------------
    // BRAM read descriptor generation
    // ------------------------------------------------------------------
    reg [LINE_AW-1:0] issue_addr_a [0:BANK_COUNT-1];
    reg [LINE_AW-1:0] issue_addr_b [0:BANK_COUNT-1];
    reg [BANK_W-1:0] issue_bank_a [0:8];
    reg [BANK_W-1:0] issue_bank_b [0:8];
    reg [8:0] issue_mem_valid_a;
    reg [8:0] issue_mem_valid_b;
    reg [ROWS-1:0] issue_lane_valid;
    reg [2:0] issue_byte_a;
    reg [2:0] issue_byte_b;
    reg issue_read_overflow;

    integer desc_i;
    integer ky_i;
    integer kx_i;
    integer lane_i;
    integer ch0_i;
    integer ch1_i;
    integer ch0_group_i;
    integer ch1_group_i;
    integer fy_i;
    integer fx_i;
    integer x_group_i;
    integer bank_i;
    integer addr_i;

    always @* begin
        for (desc_i = 0; desc_i < BANK_COUNT; desc_i = desc_i + 1) begin
            issue_addr_a[desc_i] = {LINE_AW{1'b0}};
            issue_addr_b[desc_i] = {LINE_AW{1'b0}};
        end
        issue_mem_valid_a = 9'd0;
        issue_mem_valid_b = 9'd0;
        issue_lane_valid = {ROWS{1'b0}};
        issue_read_overflow = 1'b0;

        ch0_i = mat_pass_q * 2;
        ch1_i = ch0_i + 1;
        ch0_group_i = ch0_i >> 3;
        ch1_group_i = ch1_i >> 3;
        issue_byte_a = ch0_i[2:0];
        issue_byte_b = ch1_i[2:0];

        for (ky_i = 0; ky_i < 3; ky_i = ky_i + 1) begin
            for (kx_i = 0; kx_i < 3; kx_i = kx_i + 1) begin
                lane_i = ky_i * 3 + kx_i;
                issue_bank_a[lane_i] = {BANK_W{1'b0}};
                issue_bank_b[lane_i] = {BANK_W{1'b0}};
                if (ch0_i < cin_q)
                    issue_lane_valid[lane_i] = 1'b1;
                if (ch1_i < cin_q)
                    issue_lane_valid[9 + lane_i] = 1'b1;

                fy_i = (mat_oy_q * stride_q) + ky_i - pad_q;
                fx_i = (mat_x_q * stride_q) + kx_i - pad_q;
                if (fy_i >= 0 && fy_i < fm_h_q &&
                    fx_i >= 0 && fx_i < fm_w_q) begin
                    x_group_i = fx_i / X_BANKS;
                    if (ch0_i < cin_q) begin
                        bank_i = ((((fy_i & 3) * X_BANKS) +
                                  (fx_i % X_BANKS)) * CHANNEL_BANKS) +
                                 (ch0_group_i & 1);
                        issue_bank_a[lane_i] = bank_i[BANK_W-1:0];
                        addr_i = (ch0_group_i >> 1) * x_groups_q +
                                 x_group_i;
                        if (addr_i < BANK_DEPTH) begin
                            issue_addr_a[bank_i] = addr_i[LINE_AW-1:0];
                            issue_mem_valid_a[lane_i] = 1'b1;
                        end else begin
                            issue_read_overflow = 1'b1;
                        end
                    end
                    if (ch1_i < cin_q) begin
                        bank_i = ((((fy_i & 3) * X_BANKS) +
                                  (fx_i % X_BANKS)) * CHANNEL_BANKS) +
                                 (ch1_group_i & 1);
                        issue_bank_b[lane_i] = bank_i[BANK_W-1:0];
                        addr_i = (ch1_group_i >> 1) * x_groups_q +
                                 x_group_i;
                        if (addr_i < BANK_DEPTH) begin
                            issue_addr_b[bank_i] = addr_i[LINE_AW-1:0];
                            issue_mem_valid_b[lane_i] = 1'b1;
                        end else begin
                            issue_read_overflow = 1'b1;
                        end
                    end
                end
            end
        end
    end

    // Pending metadata for the one-cycle 3x3 synchronous read pipeline.
    reg three_pending_q;
    reg [BANK_W-1:0] pending_bank_a [0:8];
    reg [BANK_W-1:0] pending_bank_b [0:8];
    reg [8:0] pending_mem_valid_a;
    reg [8:0] pending_mem_valid_b;
    reg [ROWS-1:0] pending_lane_valid;
    reg [2:0] pending_byte_a;
    reg [2:0] pending_byte_b;
    reg [31:0] pending_pixel;
    reg [15:0] pending_pass;
    reg [15:0] pending_oy;
    reg [15:0] pending_x;
    reg pending_last;

    wire output_slot = !out_valid_q || m_entry_ready;
    wire capture_three = three_pending_q && output_slot;
    wire issue_three = mat_active_q && !kernel_1x1_q && !all_issued_q &&
                       (!three_pending_q || capture_three);

    // Native-1x1 word-gather state.  Four adjacent 64-bit words cover any
    // 18-byte window regardless of the starting channel residue.
    reg [2:0] one_state_q;
    reg [BANK_W-1:0] one_bank0_q;
    reg [BANK_W-1:0] one_bank1_q;
    reg [BANK_W-1:0] one_bank2_q;
    reg [BANK_W-1:0] one_bank3_q;
    reg [2:0] one_base_mod_q;
    reg [13:0] one_base_ch_q;
    reg [ROWS-1:0] one_lane_valid_q;
    reg one_spatial_valid_q;
    reg [63:0] one_word0_q;
    reg [63:0] one_word1_q;
    reg [31:0] one_pixel_q;
    reg [15:0] one_pass_q;
    reg [15:0] one_oy_q;
    reg [15:0] one_x_q;
    reg one_last_q;

    reg [LINE_AW-1:0] one_addr_a_comb [0:BANK_COUNT-1];
    reg [LINE_AW-1:0] one_addr_b_comb [0:BANK_COUNT-1];
    reg [BANK_W-1:0] one_bank_a_comb;
    reg [BANK_W-1:0] one_bank_b_comb;
    reg [2:0] one_base_mod_comb;
    reg [13:0] one_base_ch_comb;
    reg [ROWS-1:0] one_lane_valid_comb;
    reg one_spatial_valid_comb;
    reg one_read_overflow;
    integer one_base_i;
    integer one_group_i;
    integer one_fy_i;
    integer one_fx_i;
    integer one_x_group_i;
    integer one_spatial_bank_i;
    integer one_bank_a_i;
    integer one_bank_b_i;
    integer one_group_offset_i;
    integer one_addr_i;

    always @* begin
        for (desc_i = 0; desc_i < BANK_COUNT; desc_i = desc_i + 1) begin
            one_addr_a_comb[desc_i] = {LINE_AW{1'b0}};
            one_addr_b_comb[desc_i] = {LINE_AW{1'b0}};
        end
        one_base_i = mat_pass_q * ROWS;
        one_group_i = one_base_i >> 3;
        one_base_ch_comb = one_base_i[13:0];
        one_base_mod_comb = one_base_i[2:0];
        one_lane_valid_comb = {ROWS{1'b0}};
        for (lane_i = 0; lane_i < ROWS; lane_i = lane_i + 1)
            if (one_base_i + lane_i < cin_q)
                one_lane_valid_comb[lane_i] = 1'b1;

        one_fy_i = (mat_oy_q * stride_q) - pad_q;
        one_fx_i = (mat_x_q * stride_q) - pad_q;
        one_spatial_valid_comb = one_fy_i >= 0 && one_fy_i < fm_h_q &&
                                 one_fx_i >= 0 && one_fx_i < fm_w_q;
        one_spatial_bank_i = 0;
        one_x_group_i = 0;
        if (one_spatial_valid_comb) begin
            one_x_group_i = one_fx_i / X_BANKS;
            one_spatial_bank_i = ((one_fy_i & 3) * X_BANKS) +
                                 (one_fx_i % X_BANKS);
        end
        one_read_overflow = 1'b0;

        if (one_state_q == ONE_ISSUE01)
            one_group_offset_i = 0;
        else
            one_group_offset_i = 2;

        one_bank_a_i = (one_spatial_bank_i * CHANNEL_BANKS) +
                       ((one_group_i + one_group_offset_i) & 1);
        one_bank_b_i = (one_spatial_bank_i * CHANNEL_BANKS) +
                       ((one_group_i + one_group_offset_i + 1) & 1);
        one_bank_a_comb = one_bank_a_i[BANK_W-1:0];
        one_bank_b_comb = one_bank_b_i[BANK_W-1:0];

        if (one_spatial_valid_comb) begin
            one_addr_i = ((one_group_i + one_group_offset_i) >> 1) *
                         x_groups_q + one_x_group_i;
            if ((one_group_i + one_group_offset_i) < channel_groups_q &&
                one_addr_i < BANK_DEPTH)
                one_addr_a_comb[one_bank_a_i] =
                    one_addr_i[LINE_AW-1:0];
            else if ((one_group_i + one_group_offset_i) < channel_groups_q)
                one_read_overflow = 1'b1;

            one_addr_i = ((one_group_i + one_group_offset_i + 1) >> 1) *
                         x_groups_q + one_x_group_i;
            if ((one_group_i + one_group_offset_i + 1) <
                    channel_groups_q && one_addr_i < BANK_DEPTH)
                one_addr_b_comb[one_bank_b_i] =
                    one_addr_i[LINE_AW-1:0];
            else if ((one_group_i + one_group_offset_i + 1) <
                     channel_groups_q)
                one_read_overflow = 1'b1;
        end
    end

    wire one_read_issue = mat_active_q && kernel_1x1_q &&
        (one_state_q == ONE_ISSUE01 ||
         one_state_q == ONE_CAPTURE01);

    reg [LINE_AW-1:0] read_addr_a_hold [0:BANK_COUNT-1];
    reg [LINE_AW-1:0] read_addr_b_hold [0:BANK_COUNT-1];
    wire [63:0] bank_a_rd_data [0:BANK_COUNT-1];
    wire [63:0] bank_b_rd_data [0:BANK_COUNT-1];

    genvar storage_bank;
    generate
        for (storage_bank = 0; storage_bank < BANK_COUNT;
             storage_bank = storage_bank + 1) begin : line_banks
            wire [LINE_AW-1:0] selected_read_a = issue_three ?
                issue_addr_a[storage_bank] :
                (one_read_issue ? one_addr_a_comb[storage_bank] :
                                  read_addr_a_hold[storage_bank]);
            wire [LINE_AW-1:0] selected_read_b = issue_three ?
                issue_addr_b[storage_bank] :
                (one_read_issue ? one_addr_b_comb[storage_bank] :
                                  read_addr_b_hold[storage_bank]);
            wire [LINE_AW-1:0] port_a_addr =
                (axis_fire && bank_wr_en[storage_bank]) ?
                    bank_wr_addr[storage_bank] : selected_read_a;

            axis_hwc_window_bram_bank #(
                .DEPTH(BANK_DEPTH), .ADDR_W(LINE_AW)
            ) u_bank (
                .clk(clk),
                .a_addr(port_a_addr),
                .a_wr_en(axis_fire && bank_wr_en[storage_bank]),
                .a_wr_keep(bank_wr_keep[storage_bank]),
                .a_wr_data(bank_wr_data[storage_bank]),
                .a_rd_data(bank_a_rd_data[storage_bank]),
                .b_addr(selected_read_b),
                .b_rd_data(bank_b_rd_data[storage_bank])
            );
        end
    endgenerate

    wire [255:0] one_concat = {
        bank_b_rd_data[one_bank3_q], bank_a_rd_data[one_bank2_q],
        one_word1_q, one_word0_q
    };
    wire [255:0] one_shifted =
        one_concat >> ({5'd0, one_base_mod_q} << 3);

    // Config math is sampled only on cfg_start and is not part of an entry
    // data path.
    wire [15:0] cfg_x_groups = (cfg_fm_w + X_BANKS - 1) / X_BANKS;
    wire [15:0] cfg_channel_groups =
        (cfg_cin + CHANNEL_BYTES - 1) / CHANNEL_BYTES;
    wire [31:0] cfg_bank_words = cfg_x_groups *
        ((cfg_channel_groups + CHANNEL_BANKS - 1) / CHANNEL_BANKS);
    wire [15:0] cfg_pass_count = cfg_kernel_1x1 ?
        ((cfg_cin + ROWS - 1) / ROWS) : ((cfg_cin + 1) >> 1);
    wire [31:0] cfg_expected_bytes = cfg_fm_h * cfg_fm_w * cfg_cin;
    wire cfg_legal = (ROWS == 18) && (AXIS_W == 64) && (KEEP_W == 8) &&
        cfg_fm_h != 0 && cfg_fm_w != 0 && cfg_fm_w <= MAX_FM_W &&
        cfg_cin >= 3 && cfg_cin <= MAX_CHANNELS &&
        cfg_ofm_h != 0 && cfg_ofm_w != 0 &&
        (cfg_stride == 1 || cfg_stride == 2) &&
        cfg_ofm_h == convolution_output_dim(
            cfg_fm_h, cfg_kernel_1x1, cfg_stride, cfg_pad) &&
        cfg_ofm_w == convolution_output_dim(
            cfg_fm_w, cfg_kernel_1x1, cfg_stride, cfg_pad) &&
        cfg_bank_words <= BANK_DEPTH &&
        cfg_pass_count != 0 && cfg_pass_count <= MAX_PASSES;

    integer seq_i;
    integer row_i;
    always @(posedge clk) begin
        if (rst) begin
            busy_q <= 1'b0;
            fm_h_q <= 16'd0;
            fm_w_q <= 16'd0;
            cin_q <= 14'd0;
            ofm_h_q <= 16'd0;
            ofm_w_q <= 16'd0;
            kernel_1x1_q <= 1'b0;
            stride_q <= 2'd1;
            pad_q <= 2'd0;
            input_zero_point_q <= 8'd0;
            epoch_q <= {EPOCH_W{1'b0}};
            x_groups_q <= 16'd0;
            channel_groups_q <= 16'd0;
            pass_count_q <= 16'd0;
            k_total_q <= 16'd0;
            expected_bytes_q <= 32'd0;
            wr_y_q <= 16'd0;
            wr_x_q <= 16'd0;
            wr_ch_q <= 14'd0;
            wr_x_mod_q <= 2'd0;
            wr_x_group_q <= 16'd0;
            wr_ch_mod_q <= 3'd0;
            wr_ch_group_q <= 16'd0;
            wr_word_addr_q <= {LINE_AW{1'b0}};
            loaded_any_q <= 1'b0;
            loaded_through_y_q <= 16'd0;
            row_valid_q <= {ROW_BANKS{1'b0}};
            for (row_i = 0; row_i < ROW_BANKS; row_i = row_i + 1)
                row_tag_q[row_i] <= 16'd0;
            mat_active_q <= 1'b0;
            mat_oy_q <= 16'd0;
            mat_x_q <= 16'd0;
            mat_pass_q <= 16'd0;
            next_oy_q <= 16'd0;
            all_issued_q <= 1'b0;
            three_pending_q <= 1'b0;
            out_valid_q <= 1'b0;
            out_data_q <= {ROWS*8{1'b0}};
            out_lane_valid_q <= {ROWS{1'b0}};
            out_pixel_q <= 32'd0;
            out_pass_q <= 16'd0;
            out_oy_q <= 16'd0;
            out_x_q <= 16'd0;
            out_last_q <= 1'b0;
            one_state_q <= ONE_IDLE;
            one_bank0_q <= {BANK_W{1'b0}};
            one_bank1_q <= {BANK_W{1'b0}};
            one_bank2_q <= {BANK_W{1'b0}};
            one_bank3_q <= {BANK_W{1'b0}};
            one_base_mod_q <= 3'd0;
            one_base_ch_q <= 14'd0;
            one_lane_valid_q <= {ROWS{1'b0}};
            one_spatial_valid_q <= 1'b0;
            one_word0_q <= 64'd0;
            one_word1_q <= 64'd0;
            one_pixel_q <= 32'd0;
            one_pass_q <= 16'd0;
            one_oy_q <= 16'd0;
            one_x_q <= 16'd0;
            one_last_q <= 1'b0;
            input_done <= 1'b0;
            done <= 1'b0;
            pass_ready_bitmap <= {MAX_PASSES{1'b0}};
            config_error <= 1'b0;
            tkeep_error <= 1'b0;
            tlast_error <= 1'b0;
            overflow_error <= 1'b0;
            bank_collision_error <= 1'b0;
            row_overwrite_error <= 1'b0;
            protocol_error <= 1'b0;
            accepted_beats <= 32'd0;
            accepted_bytes <= 32'd0;
            emitted_entries <= 32'd0;
            axis_stall_cycles <= 32'd0;
            entry_stall_cycles <= 32'd0;
            materialize_cycles <= 32'd0;
            for (seq_i = 0; seq_i < BANK_COUNT; seq_i = seq_i + 1) begin
                read_addr_a_hold[seq_i] <= {LINE_AW{1'b0}};
                read_addr_b_hold[seq_i] <= {LINE_AW{1'b0}};
            end
        end else begin
            done <= 1'b0;

            if (s_axis_tvalid && !s_axis_tready)
                axis_stall_cycles <= axis_stall_cycles + 1'b1;
            if (out_valid_q && !m_entry_ready)
                entry_stall_cycles <= entry_stall_cycles + 1'b1;
            if (mat_active_q)
                materialize_cycles <= materialize_cycles + 1'b1;

            if (cfg_start) begin
                if (busy_q) begin
                    protocol_error <= 1'b1;
                end else begin
                    busy_q <= cfg_legal;
                    fm_h_q <= cfg_fm_h;
                    fm_w_q <= cfg_fm_w;
                    cin_q <= cfg_cin;
                    ofm_h_q <= cfg_ofm_h;
                    ofm_w_q <= cfg_ofm_w;
                    kernel_1x1_q <= cfg_kernel_1x1;
                    stride_q <= cfg_stride;
                    pad_q <= cfg_pad;
                    input_zero_point_q <= cfg_input_zero_point;
                    epoch_q <= cfg_epoch;
                    x_groups_q <= cfg_x_groups;
                    channel_groups_q <= cfg_channel_groups;
                    pass_count_q <= cfg_pass_count;
                    k_total_q <= cfg_kernel_1x1 ? cfg_cin : cfg_cin * 9;
                    expected_bytes_q <= cfg_expected_bytes;
                    wr_y_q <= 16'd0;
                    wr_x_q <= 16'd0;
                    wr_ch_q <= 14'd0;
                    wr_x_mod_q <= 2'd0;
                    wr_x_group_q <= 16'd0;
                    wr_ch_mod_q <= 3'd0;
                    wr_ch_group_q <= 16'd0;
                    wr_word_addr_q <= {LINE_AW{1'b0}};
                    loaded_any_q <= 1'b0;
                    loaded_through_y_q <= 16'd0;
                    row_valid_q <= {ROW_BANKS{1'b0}};
                    mat_active_q <= 1'b0;
                    mat_oy_q <= 16'd0;
                    mat_x_q <= 16'd0;
                    mat_pass_q <= 16'd0;
                    next_oy_q <= 16'd0;
                    all_issued_q <= 1'b0;
                    three_pending_q <= 1'b0;
                    out_valid_q <= 1'b0;
                    one_state_q <= ONE_IDLE;
                    input_done <= 1'b0;
                    pass_ready_bitmap <= {MAX_PASSES{1'b0}};
                    config_error <= !cfg_legal;
                    tkeep_error <= 1'b0;
                    tlast_error <= 1'b0;
                    overflow_error <= cfg_bank_words > BANK_DEPTH;
                    bank_collision_error <= 1'b0;
                    row_overwrite_error <= 1'b0;
                    protocol_error <= 1'b0;
                    accepted_beats <= 32'd0;
                    accepted_bytes <= 32'd0;
                    emitted_entries <= 32'd0;
                    axis_stall_cycles <= 32'd0;
                    entry_stall_cycles <= 32'd0;
                    materialize_cycles <= 32'd0;
                    if (!cfg_legal)
                        done <= 1'b1;
                end
            end else begin
                if (axis_fire) begin
                    accepted_beats <= accepted_beats + 1'b1;
                    accepted_bytes <= post_byte_count;
                    wr_y_q <= post_wr_y;
                    wr_x_q <= post_wr_x;
                    wr_ch_q <= post_wr_ch;
                    wr_x_mod_q <= post_wr_x_mod;
                    wr_x_group_q <= post_wr_x_group;
                    wr_ch_mod_q <= post_wr_ch_mod;
                    wr_ch_group_q <= post_wr_ch_group;
                    wr_word_addr_q <= post_wr_word_addr;

                    if (!keep_prefix_comb || s_axis_tkeep == 0 ||
                        ((post_byte_count < expected_bytes_q) &&
                         s_axis_tkeep != {KEEP_W{1'b1}}))
                        tkeep_error <= 1'b1;
                    if (post_byte_count > expected_bytes_q ||
                        bank_addr_overflow_comb)
                        overflow_error <= 1'b1;
                    if (s_axis_tlast != beat_finishes_input)
                        tlast_error <= 1'b1;
                    if (bank_collision_comb)
                        bank_collision_error <= 1'b1;
                    if (overwrite_comb)
                        row_overwrite_error <= 1'b1;

                    for (seq_i = 0; seq_i < KEEP_W; seq_i = seq_i + 1)
                        if (lane_map_valid[seq_i] &&
                            lane_ch[seq_i] + 1 == cin_q &&
                            lane_x[seq_i] + 1 == fm_w_q) begin
                            row_valid_q[lane_y[seq_i][1:0]] <= 1'b1;
                            row_tag_q[lane_y[seq_i][1:0]] <= lane_y[seq_i];
                        end

                    if (row_completed_comb) begin
                        loaded_any_q <= 1'b1;
                        loaded_through_y_q <= last_completed_y_comb;
                    end
                    if (beat_finishes_input)
                        input_done <= 1'b1;

                    if (row_completed_comb &&
                        output_row_ready(next_oy_q, last_completed_y_comb,
                                         1'b1, beat_finishes_input)) begin
                        mat_active_q <= 1'b1;
                        mat_oy_q <= next_oy_q;
                        mat_x_q <= 16'd0;
                        mat_pass_q <= 16'd0;
                        all_issued_q <= 1'b0;
                        three_pending_q <= 1'b0;
                        one_state_q <= cfg_kernel_1x1 ?
                            ONE_ISSUE01 : ONE_IDLE;
                    end
                end

                // Latch the address used on every synchronous read so a
                // stalled pending entry keeps its BRAM output stable.
                if (issue_three) begin
                    for (seq_i = 0; seq_i < BANK_COUNT;
                         seq_i = seq_i + 1) begin
                        read_addr_a_hold[seq_i] <= issue_addr_a[seq_i];
                        read_addr_b_hold[seq_i] <= issue_addr_b[seq_i];
                    end
                    if (issue_read_overflow)
                        overflow_error <= 1'b1;
                end else if (one_read_issue) begin
                    for (seq_i = 0; seq_i < BANK_COUNT;
                         seq_i = seq_i + 1) begin
                        read_addr_a_hold[seq_i] <= one_addr_a_comb[seq_i];
                        read_addr_b_hold[seq_i] <= one_addr_b_comb[seq_i];
                    end
                    if (one_read_overflow)
                        overflow_error <= 1'b1;
                end

                // Consume an old pending 3x3 read before replacing its
                // metadata with a newly issued entry on the same edge.
                if (capture_three) begin
                    out_valid_q <= 1'b1;
                    out_data_q <= {ROWS*8{1'b0}};
                    for (seq_i = 0; seq_i < 9; seq_i = seq_i + 1) begin
                        if (pending_mem_valid_a[seq_i])
                            out_data_q[seq_i*8 +: 8] <=
                                bank_a_rd_data[pending_bank_a[seq_i]]
                                    [pending_byte_a*8 +: 8];
                        if (pending_mem_valid_b[seq_i])
                            out_data_q[(9+seq_i)*8 +: 8] <=
                                bank_b_rd_data[pending_bank_b[seq_i]]
                                    [pending_byte_b*8 +: 8];
                    end
                    out_lane_valid_q <= pending_lane_valid;
                    out_pixel_q <= pending_pixel;
                    out_pass_q <= pending_pass;
                    out_oy_q <= pending_oy;
                    out_x_q <= pending_x;
                    out_last_q <= pending_last;
                end else if (out_fire) begin
                    out_valid_q <= 1'b0;
                end

                if (issue_three) begin
                    for (seq_i = 0; seq_i < 9; seq_i = seq_i + 1) begin
                        pending_bank_a[seq_i] <= issue_bank_a[seq_i];
                        pending_bank_b[seq_i] <= issue_bank_b[seq_i];
                    end
                    pending_mem_valid_a <= issue_mem_valid_a;
                    pending_mem_valid_b <= issue_mem_valid_b;
                    pending_lane_valid <= issue_lane_valid;
                    pending_byte_a <= issue_byte_a;
                    pending_byte_b <= issue_byte_b;
                    pending_pixel <= mat_oy_q * ofm_w_q + mat_x_q;
                    pending_pass <= mat_pass_q;
                    pending_oy <= mat_oy_q;
                    pending_x <= mat_x_q;
                    pending_last <=
                        mat_oy_q + 1 == ofm_h_q &&
                        mat_pass_q + 1 == pass_count_q &&
                        mat_x_q + 1 == ofm_w_q;
                    three_pending_q <= 1'b1;

                    if (mat_x_q + 1 != ofm_w_q) begin
                        mat_x_q <= mat_x_q + 1'b1;
                    end else if (mat_pass_q + 1 != pass_count_q) begin
                        mat_x_q <= 16'd0;
                        mat_pass_q <= mat_pass_q + 1'b1;
                    end else begin
                        all_issued_q <= 1'b1;
                    end
                end else if (capture_three) begin
                    three_pending_q <= 1'b0;
                end

                // Native 1x1 gather: issue groups 0/1, capture them while
                // issuing 2/3, then assemble the 18-byte shifted window.
                if (mat_active_q && kernel_1x1_q) begin
                    case (one_state_q)
                        ONE_ISSUE01: begin
                            one_bank0_q <= one_bank_a_comb;
                            one_bank1_q <= one_bank_b_comb;
                            one_base_mod_q <= one_base_mod_comb;
                            one_base_ch_q <= one_base_ch_comb;
                            one_lane_valid_q <= one_lane_valid_comb;
                            one_spatial_valid_q <= one_spatial_valid_comb;
                            one_pixel_q <= mat_oy_q * ofm_w_q + mat_x_q;
                            one_pass_q <= mat_pass_q;
                            one_oy_q <= mat_oy_q;
                            one_x_q <= mat_x_q;
                            one_last_q <=
                                mat_oy_q + 1 == ofm_h_q &&
                                mat_pass_q + 1 == pass_count_q &&
                                mat_x_q + 1 == ofm_w_q;
                            one_state_q <= ONE_CAPTURE01;
                        end
                        ONE_CAPTURE01: begin
                            one_word0_q <= bank_a_rd_data[one_bank0_q];
                            one_word1_q <= bank_b_rd_data[one_bank1_q];
                            one_bank2_q <= one_bank_a_comb;
                            one_bank3_q <= one_bank_b_comb;
                            one_state_q <= ONE_CAPTURE23;
                        end
                        ONE_CAPTURE23: begin
                            out_valid_q <= 1'b1;
                            out_data_q <= {ROWS*8{1'b0}};
                            for (seq_i = 0; seq_i < ROWS;
                                 seq_i = seq_i + 1)
                                if (one_lane_valid_q[seq_i] &&
                                    one_spatial_valid_q)
                                    out_data_q[seq_i*8 +: 8] <=
                                        one_shifted[seq_i*8 +: 8];
                            out_lane_valid_q <= one_lane_valid_q;
                            out_pixel_q <= one_pixel_q;
                            out_pass_q <= one_pass_q;
                            out_oy_q <= one_oy_q;
                            out_x_q <= one_x_q;
                            out_last_q <= one_last_q;
                            one_state_q <= ONE_WAIT_OUT;
                        end
                        default: begin
                        end
                    endcase
                end

                if (out_fire) begin
                    emitted_entries <= emitted_entries + 1'b1;
                    if (out_oy_q + 1 == ofm_h_q &&
                        out_x_q + 1 == ofm_w_q)
                        pass_ready_bitmap[out_pass_q] <= 1'b1;

                    if (out_x_q + 1 == ofm_w_q &&
                        out_pass_q + 1 == pass_count_q) begin
                        next_oy_q <= out_oy_q + 1'b1;
                        three_pending_q <= 1'b0;
                        all_issued_q <= 1'b0;
                        if (out_oy_q + 1 == ofm_h_q) begin
                            mat_active_q <= 1'b0;
                            busy_q <= 1'b0;
                            done <= 1'b1;
                            one_state_q <= ONE_IDLE;
                        end else if (output_row_ready(
                                out_oy_q + 1'b1,
                                loaded_through_y_q,
                                loaded_any_q, input_done)) begin
                            mat_active_q <= 1'b1;
                            mat_oy_q <= out_oy_q + 1'b1;
                            mat_x_q <= 16'd0;
                            mat_pass_q <= 16'd0;
                            one_state_q <= kernel_1x1_q ?
                                ONE_ISSUE01 : ONE_IDLE;
                        end else begin
                            mat_active_q <= 1'b0;
                            one_state_q <= ONE_IDLE;
                        end
                    end else if (kernel_1x1_q) begin
                        if (out_x_q + 1 != ofm_w_q) begin
                            mat_x_q <= out_x_q + 1'b1;
                        end else begin
                            mat_x_q <= 16'd0;
                            mat_pass_q <= out_pass_q + 1'b1;
                        end
                        one_state_q <= ONE_ISSUE01;
                    end
                end
            end
        end
    end
endmodule

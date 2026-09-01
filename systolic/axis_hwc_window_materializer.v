`timescale 1ns / 1ps

// One physical line-store bank: one byte write and one asynchronous byte read
// per cycle.  The parent guarantees that accepted AXIS beats and emitted
// vectors address every physical bank at most once per cycle.
module axis_hwc_window_line_bank #(
    parameter integer DEPTH = 320,
    parameter integer ADDR_W = 9
) (
    input  wire              clk,
    input  wire              wr_en,
    input  wire [ADDR_W-1:0] wr_addr,
    input  wire [7:0]        wr_data,
    input  wire [ADDR_W-1:0] rd_addr,
    output wire [7:0]        rd_data
);
    (* ram_style = "distributed" *) reg [7:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    assign rd_data = mem[rd_addr];
endmodule

// Streaming raw-HWC window materializer.
//
// Input is one layer-long uint8 HWC byte stream packed into 64-bit AXIS
// beats.  The module keeps four physical input rows and partitions each row
// by channel modulo ROWS and x modulo three.  For the supported project
// configurations (ROWS=18 and CIN>=3), the eight bytes of an accepted beat
// land in distinct physical banks.  A 3x3/18-row cache entry consequently
// reads 2 channels x 3 rows x 3 columns from 18 distinct banks; a 1x1 entry
// reads 18 distinct channel banks.
//
// Entries are emitted one per cycle when m_entry_ready is asserted.  The
// order is output-row, k-pass, x.  This preserves a four-row working set and
// lets pass_ready_bitmap[n] become visible as soon as pass n of the final
// output row has been emitted.  The consumer may write entries at
// {m_entry_k_pass,m_entry_pixel} into its replay cache.
//
// Notes:
// * cfg_start is accepted only while idle and all cfg_* inputs are sampled
//   atomically on that edge.
// * TKEEP must be a contiguous low-bit prefix.  Only the final beat may be
//   partial.  TLAST must coincide with cfg_fm_h*cfg_fm_w*cfg_cin bytes.
// * Padding bytes and K-tail lanes are signed zero after centering.
// * The line store is intentionally expressed as an explicitly banked array.
//   Integrators should retain/verify the banking during implementation.
module axis_hwc_window_materializer #(
    parameter integer ROWS = 18,
    parameter integer AXIS_W = 64,
    parameter integer KEEP_W = AXIS_W / 8,
    parameter integer MAX_FM_W = 416,
    parameter integer MAX_CHANNELS = 1024,
    // Max model requirement is 285 for 13x13x1024.  Padding the physical
    // depth to 320 keeps address decoding simple without allocating the
    // impossible MAX_FM_W*MAX_CHANNELS Cartesian product.
    parameter integer LINE_BANK_DEPTH = 320,
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
    output reg  [ROWS*8-1:0]            m_entry_data,
    output reg  [ROWS-1:0]              m_entry_lane_valid,
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
    localparam integer X_BANKS = 3;
    localparam integer BANK_COUNT = ROW_BANKS * ROWS * X_BANKS;
    localparam integer LINE_AW =
        (LINE_BANK_DEPTH <= 2) ? 1 : $clog2(LINE_BANK_DEPTH);
    localparam integer BANK_INDEX_W =
        (BANK_COUNT <= 2) ? 1 : $clog2(BANK_COUNT);

    reg [BANK_COUNT-1:0] bank_wr_en;
    reg [LINE_AW-1:0] bank_wr_addr [0:BANK_COUNT-1];
    reg [7:0] bank_wr_data [0:BANK_COUNT-1];
    reg [LINE_AW-1:0] bank_rd_addr [0:BANK_COUNT-1];
    wire [7:0] bank_rd_data [0:BANK_COUNT-1];

    reg [ROWS-1:0] lane_rd_valid;
    reg [BANK_INDEX_W-1:0] lane_rd_bank [0:ROWS-1];
    reg [LINE_AW-1:0] lane_rd_addr [0:ROWS-1];

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
    reg [15:0] pass_count_q;
    reg [15:0] k_total_q;
    reg [31:0] expected_bytes_q;

    reg [15:0] wr_y_q;
    reg [15:0] wr_x_q;
    reg [13:0] wr_ch_q;
    reg loaded_any_q;
    reg [15:0] loaded_through_y_q;
    reg [ROW_BANKS-1:0] row_valid_q;
    reg [15:0] row_tag_q [0:ROW_BANKS-1];

    reg mat_active_q;
    reg [15:0] mat_oy_q;
    reg [15:0] mat_x_q;
    reg [15:0] mat_pass_q;
    reg [15:0] next_oy_q;

    reg [15:0] lane_y [0:KEEP_W-1];
    reg [15:0] lane_x [0:KEEP_W-1];
    reg [13:0] lane_ch [0:KEEP_W-1];
    reg [KEEP_W-1:0] lane_map_valid;
    reg [15:0] post_wr_y;
    reg [15:0] post_wr_x;
    reg [13:0] post_wr_ch;
    reg [7:0] keep_count_comb;
    reg keep_prefix_comb;
    reg row_completed_comb;
    reg [15:0] last_completed_y_comb;
    reg bank_collision_comb;
    reg bank_addr_overflow_comb;
    reg overwrite_comb;

    integer map_i;
    integer keep_scan_i;
    integer bank_i;
    integer bank_j;
    integer overwrite_i;
    integer meta_write_i;
    integer row_i;
    integer wr_bank_init_i;
    integer wr_route_i;
    integer wr_route_bank_int;
    integer wr_route_addr_int;
    integer rd_desc_i;
    integer rd_route_i;
    integer rd_bank_init_i;
    integer rd_assemble_i;
    integer tmp_y;
    integer tmp_x;
    integer tmp_ch;
    integer tmp_count;
    integer min_needed_y;

    wire axis_fire = s_axis_tvalid && s_axis_tready;
    wire entry_fire = m_entry_valid && m_entry_ready;
    wire [31:0] post_byte_count = accepted_bytes + keep_count_comb;
    wire beat_finishes_input = (post_byte_count == expected_bytes_q);

    assign busy = busy_q;
    assign s_axis_tready = busy_q && !input_done && !mat_active_q;
    assign m_entry_valid = busy_q && mat_active_q;
    assign m_entry_pixel = (mat_oy_q * ofm_w_q) + mat_x_q;
    assign m_entry_k_pass = mat_pass_q;
    assign m_entry_epoch = epoch_q;
    assign pass_ready_epoch = epoch_q;
    assign m_entry_last = m_entry_valid &&
        (mat_oy_q + 1'b1 == ofm_h_q) &&
        (mat_pass_q + 1'b1 == pass_count_q) &&
        (mat_x_q + 1'b1 == ofm_w_q);

    genvar storage_bank;
    generate
        for (storage_bank = 0; storage_bank < BANK_COUNT;
             storage_bank = storage_bank + 1) begin : line_banks
            axis_hwc_window_line_bank #(
                .DEPTH(LINE_BANK_DEPTH),
                .ADDR_W(LINE_AW)
            ) u_bank (
                .clk(clk),
                .wr_en(bank_wr_en[storage_bank]),
                .wr_addr(bank_wr_addr[storage_bank]),
                .wr_data(bank_wr_data[storage_bank]),
                .rd_addr(bank_rd_addr[storage_bank]),
                .rd_data(bank_rd_data[storage_bank])
            );
        end
    endgenerate

    function [7:0] center_ifm_byte;
        input [7:0] raw_u8;
        input [7:0] zero_point;
        reg signed [9:0] centered;
        begin
            centered = $signed({2'b00, raw_u8}) -
                       $signed({2'b00, zero_point});
            if (centered > 10'sd127)
                center_ifm_byte = 8'sh7f;
            else if (centered < -10'sd128)
                center_ifm_byte = 8'sh80;
            else
                center_ifm_byte = centered[7:0];
        end
    endfunction

    function [15:0] convolution_output_dim;
        input [15:0] input_dim;
        input kernel_1x1;
        input [1:0] stride;
        input [1:0] pad;
        integer padded_extent;
        integer kernel_extent;
        begin
            kernel_extent = kernel_1x1 ? 1 : 3;
            padded_extent = input_dim + (2 * pad) - kernel_extent;
            if ((stride == 0) || (padded_extent < 0))
                convolution_output_dim = 16'd0;
            else
                convolution_output_dim = (padded_extent / stride) + 1;
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

    // Map all valid bytes of the current AXIS beat without a byte-serial
    // unpack phase.  The low-prefix TKEEP convention makes this a simple
    // eight-step combinational carry chain.
    always @* begin
        tmp_y = wr_y_q;
        tmp_x = wr_x_q;
        tmp_ch = wr_ch_q;
        tmp_count = 0;
        keep_count_comb = 8'd0;
        keep_prefix_comb = 1'b1;
        row_completed_comb = 1'b0;
        last_completed_y_comb = loaded_through_y_q;

        for (map_i = 0; map_i < KEEP_W; map_i = map_i + 1) begin
            lane_y[map_i] = tmp_y[15:0];
            lane_x[map_i] = tmp_x[15:0];
            lane_ch[map_i] = tmp_ch[13:0];
            lane_map_valid[map_i] = s_axis_tkeep[map_i] &&
                ((accepted_bytes + tmp_count) < expected_bytes_q);

            if (s_axis_tkeep[map_i]) begin
                keep_count_comb = keep_count_comb + 1'b1;
                tmp_count = tmp_count + 1;
                if (tmp_ch + 1 == cin_q) begin
                    tmp_ch = 0;
                    if (tmp_x + 1 == fm_w_q) begin
                        row_completed_comb = 1'b1;
                        last_completed_y_comb = tmp_y[15:0];
                        tmp_x = 0;
                        tmp_y = tmp_y + 1;
                    end else begin
                        tmp_x = tmp_x + 1;
                    end
                end else begin
                    tmp_ch = tmp_ch + 1;
                end
            end else if (keep_count_comb != 0 ||
                         s_axis_tkeep != {KEEP_W{1'b0}}) begin
                // Once a zero is observed after valid low lanes, no later
                // lane may be asserted.
                for (keep_scan_i = map_i + 1; keep_scan_i < KEEP_W;
                     keep_scan_i = keep_scan_i + 1)
                    if (s_axis_tkeep[keep_scan_i])
                        keep_prefix_comb = 1'b0;
            end
        end

        post_wr_y = tmp_y[15:0];
        post_wr_x = tmp_x[15:0];
        post_wr_ch = tmp_ch[13:0];
    end

    // A legal project beat has at most one write to every physical bank.
    // Detect violations explicitly so an unsupported configuration cannot
    // silently rely on simulator-only multi-write array behavior.
    always @* begin
        bank_collision_comb = 1'b0;
        for (bank_i = 0; bank_i < KEEP_W; bank_i = bank_i + 1) begin
            for (bank_j = bank_i + 1; bank_j < KEEP_W;
                 bank_j = bank_j + 1) begin
                if (lane_map_valid[bank_i] && lane_map_valid[bank_j] &&
                    (lane_y[bank_i][1:0] == lane_y[bank_j][1:0]) &&
                    ((lane_ch[bank_i] % ROWS) ==
                     (lane_ch[bank_j] % ROWS)) &&
                    ((lane_x[bank_i] % X_BANKS) ==
                     (lane_x[bank_j] % X_BANKS)))
                    bank_collision_comb = 1'b1;
            end
        end
    end

    // Check that a row about to reuse one of the four physical row banks is
    // older than the first row still needed by next_oy_q.
    always @* begin
        overwrite_comb = 1'b0;
        min_needed_y = (next_oy_q * stride_q) - pad_q;
        if (min_needed_y < 0)
            min_needed_y = 0;
        for (overwrite_i = 0; overwrite_i < KEEP_W;
             overwrite_i = overwrite_i + 1) begin
            if (lane_map_valid[overwrite_i] &&
                (lane_x[overwrite_i] == 0) &&
                (lane_ch[overwrite_i] == 0) &&
                row_valid_q[lane_y[overwrite_i][1:0]] &&
                (row_tag_q[lane_y[overwrite_i][1:0]] !=
                 lane_y[overwrite_i]) &&
                (row_tag_q[lane_y[overwrite_i][1:0]] >= min_needed_y))
                overwrite_comb = 1'b1;
        end
    end

    // Route all accepted bytes into explicit one-write physical banks.  This
    // avoids a generic multi-write memory inference and makes the collision
    // assertion above correspond directly to the hardware structure.
    always @* begin
        bank_wr_en = {BANK_COUNT{1'b0}};
        bank_addr_overflow_comb = 1'b0;
        for (wr_bank_init_i = 0; wr_bank_init_i < BANK_COUNT;
             wr_bank_init_i = wr_bank_init_i + 1) begin
            bank_wr_addr[wr_bank_init_i] = {LINE_AW{1'b0}};
            bank_wr_data[wr_bank_init_i] = 8'd0;
        end

        for (wr_route_i = 0; wr_route_i < KEEP_W;
             wr_route_i = wr_route_i + 1) begin
            if (lane_map_valid[wr_route_i]) begin
                wr_route_bank_int =
                    (((lane_y[wr_route_i] % ROW_BANKS) * ROWS) +
                     (lane_ch[wr_route_i] % ROWS)) * X_BANKS +
                    (lane_x[wr_route_i] % X_BANKS);
                wr_route_addr_int =
                    ((lane_ch[wr_route_i] / ROWS) * x_groups_q) +
                    (lane_x[wr_route_i] / X_BANKS);
                if ((wr_route_addr_int >= 0) &&
                    (wr_route_addr_int < LINE_BANK_DEPTH)) begin
                    bank_wr_en[wr_route_bank_int] = axis_fire;
                    bank_wr_addr[wr_route_bank_int] =
                        wr_route_addr_int[LINE_AW-1:0];
                    bank_wr_data[wr_route_bank_int] = center_ifm_byte(
                        s_axis_tdata[wr_route_i*8 +: 8],
                        input_zero_point_q);
                end else begin
                    bank_addr_overflow_comb = 1'b1;
                end
            end
        end
    end

    // First compute one physical read-bank/address descriptor per output
    // lane.  K-tail lanes remain invalid; spatial padding lanes are K-valid
    // but deliberately have no memory read and therefore return signed zero.
    integer gk_int;
    integer ch_int;
    integer kp_int;
    integer ky_int;
    integer kx_int;
    integer fy_int;
    integer fx_int;
    integer rd_addr_int;
    integer rd_bank_int;
    always @* begin
        m_entry_lane_valid = {ROWS{1'b0}};
        lane_rd_valid = {ROWS{1'b0}};
        for (rd_desc_i = 0; rd_desc_i < ROWS;
             rd_desc_i = rd_desc_i + 1) begin
            lane_rd_bank[rd_desc_i] = {BANK_INDEX_W{1'b0}};
            lane_rd_addr[rd_desc_i] = {LINE_AW{1'b0}};
            gk_int = (mat_pass_q * ROWS) + rd_desc_i;
            if (gk_int < k_total_q) begin
                m_entry_lane_valid[rd_desc_i] = 1'b1;
                if (kernel_1x1_q) begin
                    ch_int = gk_int;
                    ky_int = 0;
                    kx_int = 0;
                end else begin
                    ch_int = gk_int / 9;
                    kp_int = gk_int % 9;
                    ky_int = kp_int / 3;
                    kx_int = kp_int % 3;
                end

                fy_int = (mat_oy_q * stride_q) + ky_int - pad_q;
                fx_int = (mat_x_q * stride_q) + kx_int - pad_q;
                rd_addr_int = ((ch_int / ROWS) * x_groups_q) +
                              (fx_int / X_BANKS);
                rd_bank_int = (((fy_int % ROW_BANKS) * ROWS) +
                               (ch_int % ROWS)) * X_BANKS +
                              (fx_int % X_BANKS);

                if ((fy_int >= 0) && (fy_int < fm_h_q) &&
                    (fx_int >= 0) && (fx_int < fm_w_q) &&
                    (ch_int < cin_q) &&
                    (rd_addr_int >= 0) &&
                    (rd_addr_int < LINE_BANK_DEPTH)) begin
                    if (row_valid_q[fy_int % ROW_BANKS] &&
                        (row_tag_q[fy_int % ROW_BANKS] == fy_int)) begin
                        lane_rd_valid[rd_desc_i] = 1'b1;
                        lane_rd_bank[rd_desc_i] =
                            rd_bank_int[BANK_INDEX_W-1:0];
                        lane_rd_addr[rd_desc_i] =
                            rd_addr_int[LINE_AW-1:0];
                    end
                end
            end
        end
    end

    // Every valid output lane selects a distinct bank for ROWS=18, so each
    // line-bank receives a single asynchronous read address.
    always @* begin
        for (rd_bank_init_i = 0; rd_bank_init_i < BANK_COUNT;
             rd_bank_init_i = rd_bank_init_i + 1)
            bank_rd_addr[rd_bank_init_i] = {LINE_AW{1'b0}};
        for (rd_route_i = 0; rd_route_i < ROWS;
             rd_route_i = rd_route_i + 1)
            if (lane_rd_valid[rd_route_i])
                bank_rd_addr[lane_rd_bank[rd_route_i]] =
                    lane_rd_addr[rd_route_i];
    end

    always @* begin
        m_entry_data = {ROWS*8{1'b0}};
        for (rd_assemble_i = 0; rd_assemble_i < ROWS;
             rd_assemble_i = rd_assemble_i + 1)
            if (lane_rd_valid[rd_assemble_i])
                m_entry_data[rd_assemble_i*8 +: 8] =
                    bank_rd_data[lane_rd_bank[rd_assemble_i]];
    end

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
            pass_count_q <= 16'd0;
            k_total_q <= 16'd0;
            expected_bytes_q <= 32'd0;
            wr_y_q <= 16'd0;
            wr_x_q <= 16'd0;
            wr_ch_q <= 14'd0;
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
            pass_ready_bitmap <= {MAX_PASSES{1'b0}};
            input_done <= 1'b0;
            done <= 1'b0;
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
        end else begin
            done <= 1'b0;

            if (s_axis_tvalid && !s_axis_tready)
                axis_stall_cycles <= axis_stall_cycles + 1'b1;
            if (m_entry_valid && !m_entry_ready)
                entry_stall_cycles <= entry_stall_cycles + 1'b1;
            if (mat_active_q)
                materialize_cycles <= materialize_cycles + 1'b1;

            if (cfg_start) begin
                if (busy_q) begin
                    protocol_error <= 1'b1;
                end else begin
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
                    x_groups_q <= (cfg_fm_w + X_BANKS - 1) / X_BANKS;
                    k_total_q <= cfg_kernel_1x1 ? cfg_cin :
                                 (cfg_cin * 9);
                    pass_count_q <= cfg_kernel_1x1 ?
                        ((cfg_cin + ROWS - 1) / ROWS) :
                        (((cfg_cin * 9) + ROWS - 1) / ROWS);
                    expected_bytes_q <= cfg_fm_h * cfg_fm_w * cfg_cin;
                    wr_y_q <= 16'd0;
                    wr_x_q <= 16'd0;
                    wr_ch_q <= 14'd0;
                    loaded_any_q <= 1'b0;
                    loaded_through_y_q <= 16'd0;
                    row_valid_q <= {ROW_BANKS{1'b0}};
                    mat_active_q <= 1'b0;
                    mat_oy_q <= 16'd0;
                    mat_x_q <= 16'd0;
                    mat_pass_q <= 16'd0;
                    next_oy_q <= 16'd0;
                    pass_ready_bitmap <= {MAX_PASSES{1'b0}};
                    input_done <= 1'b0;
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

                    if ((ROWS != 18) || (AXIS_W != 64) || (KEEP_W != 8) ||
                        (cfg_fm_h == 0) || (cfg_fm_w == 0) ||
                        (cfg_cin < 3) || (cfg_cin > MAX_CHANNELS) ||
                        (cfg_fm_w > MAX_FM_W) ||
                        (cfg_ofm_h == 0) || (cfg_ofm_w == 0) ||
                        ((cfg_stride != 1) && (cfg_stride != 2)) ||
                        (cfg_ofm_h != convolution_output_dim(
                            cfg_fm_h, cfg_kernel_1x1,
                            cfg_stride, cfg_pad)) ||
                        (cfg_ofm_w != convolution_output_dim(
                            cfg_fm_w, cfg_kernel_1x1,
                            cfg_stride, cfg_pad)) ||
                        ((((cfg_cin + ROWS - 1) / ROWS) *
                          ((cfg_fm_w + X_BANKS - 1) / X_BANKS)) >
                         LINE_BANK_DEPTH) ||
                        ((cfg_kernel_1x1 ?
                          ((cfg_cin + ROWS - 1) / ROWS) :
                          (((cfg_cin * 9) + ROWS - 1) / ROWS)) >
                         MAX_PASSES)) begin
                        config_error <= 1'b1;
                        busy_q <= 1'b0;
                        done <= 1'b1;
                    end else begin
                        busy_q <= 1'b1;
                    end
                end
            end

            if (axis_fire) begin
                accepted_beats <= accepted_beats + 1'b1;
                accepted_bytes <= post_byte_count;
                wr_y_q <= post_wr_y;
                wr_x_q <= post_wr_x;
                wr_ch_q <= post_wr_ch;

                if (!keep_prefix_comb || (s_axis_tkeep == 0) ||
                    ((post_byte_count < expected_bytes_q) &&
                     (s_axis_tkeep != {KEEP_W{1'b1}})))
                    tkeep_error <= 1'b1;
                if (post_byte_count > expected_bytes_q)
                    overflow_error <= 1'b1;
                if (bank_addr_overflow_comb)
                    overflow_error <= 1'b1;
                if (s_axis_tlast != beat_finishes_input)
                    tlast_error <= 1'b1;
                if (bank_collision_comb)
                    bank_collision_error <= 1'b1;
                if (overwrite_comb)
                    row_overwrite_error <= 1'b1;

                for (meta_write_i = 0; meta_write_i < KEEP_W;
                     meta_write_i = meta_write_i + 1) begin
                    if (lane_map_valid[meta_write_i] &&
                        (lane_ch[meta_write_i] + 1 == cin_q) &&
                        (lane_x[meta_write_i] + 1 == fm_w_q)) begin
                        row_valid_q[lane_y[meta_write_i][1:0]] <= 1'b1;
                        row_tag_q[lane_y[meta_write_i][1:0]] <=
                            lane_y[meta_write_i];
                    end
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
                    mat_pass_q <= 16'd0;
                    mat_x_q <= 16'd0;
                end
            end

            if (entry_fire) begin
                emitted_entries <= emitted_entries + 1'b1;

                if ((mat_oy_q + 1'b1 == ofm_h_q) &&
                    (mat_x_q + 1'b1 == ofm_w_q))
                    pass_ready_bitmap[mat_pass_q] <= 1'b1;

                if (mat_x_q + 1'b1 != ofm_w_q) begin
                    mat_x_q <= mat_x_q + 1'b1;
                end else if (mat_pass_q + 1'b1 != pass_count_q) begin
                    mat_x_q <= 16'd0;
                    mat_pass_q <= mat_pass_q + 1'b1;
                end else begin
                    mat_x_q <= 16'd0;
                    mat_pass_q <= 16'd0;
                    next_oy_q <= mat_oy_q + 1'b1;

                    if (mat_oy_q + 1'b1 == ofm_h_q) begin
                        mat_active_q <= 1'b0;
                        busy_q <= 1'b0;
                        done <= 1'b1;
                    end else if (output_row_ready(
                                     mat_oy_q + 1'b1,
                                     loaded_through_y_q,
                                     loaded_any_q,
                                     input_done)) begin
                        mat_oy_q <= mat_oy_q + 1'b1;
                        mat_active_q <= 1'b1;
                    end else begin
                        mat_active_q <= 1'b0;
                    end
                end
            end
        end
    end
endmodule

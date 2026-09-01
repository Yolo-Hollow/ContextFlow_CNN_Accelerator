`timescale 1ns / 1ps

`ifndef TB_CONV_LAYER_TOP_MODULE
`define TB_CONV_LAYER_TOP_MODULE tb_conv_layer_top_stream
`endif
`ifndef TB_CONV_LAYER_ENABLE_TAGGED_CONTEXT
`define TB_CONV_LAYER_ENABLE_TAGGED_CONTEXT 0
`endif
`ifndef TB_CONV_LAYER_ENABLE_WEIGHT_PRELOAD
`define TB_CONV_LAYER_ENABLE_WEIGHT_PRELOAD 0
`endif
`ifndef TB_CONV_LAYER_ENABLE_FAST_CONTEXT_HANDOFF
`define TB_CONV_LAYER_ENABLE_FAST_CONTEXT_HANDOFF 0
`endif
`ifndef TB_CONV_LAYER_PASS_PREFETCH_ENABLE
`define TB_CONV_LAYER_PASS_PREFETCH_ENABLE 1'b0
`endif
`ifndef TB_CONV_LAYER_DURING_COMPUTE_PREFETCH_ENABLE
`define TB_CONV_LAYER_DURING_COMPUTE_PREFETCH_ENABLE 1'b0
`endif
`ifndef TB_CONV_LAYER_PSUM_STREAM_OVERLAP_ENABLE
`define TB_CONV_LAYER_PSUM_STREAM_OVERLAP_ENABLE 1'b0
`endif
`ifndef TB_CONV_LAYER_REQUIRE_CONTEXT_OVERLAP
`define TB_CONV_LAYER_REQUIRE_CONTEXT_OVERLAP 0
`endif
`ifndef TB_CONV_LAYER_REQUIRE_FAST_HANDOFF
`define TB_CONV_LAYER_REQUIRE_FAST_HANDOFF 0
`endif
`ifndef TB_CONV_LAYER_PACKED_WEIGHT_WRITE
`define TB_CONV_LAYER_PACKED_WEIGHT_WRITE 0
`endif
`ifndef TB_CONV_LAYER_FORCE_COMMIT_BACKPRESSURE
`define TB_CONV_LAYER_FORCE_COMMIT_BACKPRESSURE 0
`endif
`ifndef TB_CONV_LAYER_FORCE_WEIGHT_CREDIT_BACKPRESSURE
`define TB_CONV_LAYER_FORCE_WEIGHT_CREDIT_BACKPRESSURE 0
`endif
`ifndef TB_CONV_LAYER_FM_W
`define TB_CONV_LAYER_FM_W 5
`endif
`ifndef TB_CONV_LAYER_FM_H
`define TB_CONV_LAYER_FM_H 5
`endif
`ifndef TB_CONV_LAYER_OFM_W
`define TB_CONV_LAYER_OFM_W 3
`endif
`ifndef TB_CONV_LAYER_OFM_H
`define TB_CONV_LAYER_OFM_H 3
`endif
`ifndef TB_CONV_LAYER_IFM_D
`define TB_CONV_LAYER_IFM_D 16
`endif
`ifndef TB_CONV_LAYER_IFM_AW
`define TB_CONV_LAYER_IFM_AW 4
`endif
`ifndef TB_CONV_LAYER_PSUM_D
`define TB_CONV_LAYER_PSUM_D 16
`endif
`ifndef TB_CONV_LAYER_PSUM_AW
`define TB_CONV_LAYER_PSUM_AW 4
`endif
`ifndef TB_CONV_LAYER_PSUM_BUF_AW
`define TB_CONV_LAYER_PSUM_BUF_AW 4
`endif
`ifndef TB_CONV_LAYER_TIMEOUT_CYCLES
`define TB_CONV_LAYER_TIMEOUT_CYCLES 12000
`endif
`ifndef TB_CONV_LAYER_RAW_VECTOR_MODE
`define TB_CONV_LAYER_RAW_VECTOR_MODE 1'b0
`endif
`ifndef TB_CONV_LAYER_ROWS
`define TB_CONV_LAYER_ROWS 32
`endif
`ifndef TB_CONV_LAYER_COLS
`define TB_CONV_LAYER_COLS 4
`endif
`ifndef TB_CONV_LAYER_CIN
`define TB_CONV_LAYER_CIN 5
`endif

module `TB_CONV_LAYER_TOP_MODULE;
    localparam ROWS = `TB_CONV_LAYER_ROWS;
    localparam COLS = `TB_CONV_LAYER_COLS;
    localparam IFM_W = 8;
    localparam WGT_W = 8;
    localparam PSUM_W = 32;
    localparam IFM_D = `TB_CONV_LAYER_IFM_D;
    localparam IFM_AW = `TB_CONV_LAYER_IFM_AW;
    localparam WGT_D = 64;
    localparam WGT_AW = 6;
    localparam PSUM_D = `TB_CONV_LAYER_PSUM_D;
    localparam PSUM_AW = `TB_CONV_LAYER_PSUM_AW;
    localparam FM_W = `TB_CONV_LAYER_FM_W;
    localparam FM_H = `TB_CONV_LAYER_FM_H;
    localparam OFM_W = `TB_CONV_LAYER_OFM_W;
    localparam OFM_H = `TB_CONV_LAYER_OFM_H;
    localparam PIXELS = OFM_W * OFM_H;
    localparam CIN = `TB_CONV_LAYER_CIN;
    localparam K_TOTAL = CIN * 3 * 3;
    localparam COUT_TILE = COLS * 2;
    localparam COUT_TOTAL = COUT_TILE + 2;
    localparam COUT_BLOCKS = (COUT_TOTAL + COUT_TILE - 1) / COUT_TILE;
    localparam K_PASSES = (K_TOTAL + ROWS - 1) / ROWS;
    localparam WGT_TILE_AW = 11;
    localparam PSUM_A = `TB_CONV_LAYER_PSUM_BUF_AW;

    reg clk, rst, start;
    wire busy, done;
    wire bias_load_req, weight_load_req;
    reg bias_load_done, weight_tile_ready;
    wire [10:0] current_cout_base;
    wire [13:0] current_pass_base_k;
    reg [5:0] bias_wr_addr;
    reg [PSUM_W-1:0] bias_wr_data;
    reg bias_wr_en;
    reg wgt_tile_wr_en;
    reg [WGT_TILE_AW-1:0] wgt_tile_wr_addr;
    reg [WGT_W-1:0] wgt_tile_wr_data;
    reg wgt_tile_wr8_en;
    reg [WGT_TILE_AW-1:0] wgt_tile_wr8_addr;
    reg [WGT_W*8-1:0] wgt_tile_wr8_data;
    reg [7:0] wgt_tile_wr8_keep;
    wire feeder_fill_req;
    wire [8:0] feeder_fill_fy;
    reg [4:0] dma_bank_wr_en;
    reg [8:0] dma_wr_x;
    reg [9:0] dma_wr_fy;
    reg [7:0] dma_wr_data [0:4];
    reg dma_line_advance;
    reg [ROWS*IFM_W-1:0] vector_ifm_data;
    reg vector_ifm_valid;
    wire vector_ifm_ready;
    reg vector_packet_done;
    wire [13:0] current_feeder_pass_base_k;
    wire final_valid;
    wire [PSUM_A-1:0] final_addr;
    wire [COLS*2*PSUM_W-1:0] final_data;
    wire [10:0] final_cout_base;
    wire [COLS*2-1:0] final_channel_valid;
    reg [COLS*2*16-1:0] quant_mult_flat;
    reg [COLS*2*4-1:0] quant_shift_flat;
    reg [COLS*2*8-1:0] quant_zp_flat;
    reg [1:0] activation_mode;
    reg act_lut_wr_en;
    reg [7:0] act_lut_wr_addr, act_lut_wr_data;
    wire ofm_valid;
    wire [PSUM_A-1:0] ofm_addr;
    wire [10:0] ofm_cout_base;
    wire [COLS*2-1:0] ofm_channel_valid;
    wire [COLS*2*8-1:0] ofm_data;
    wire ofm_mem_wr_en;
    wire [15:0] ofm_mem_wr_addr;
    wire [7:0] ofm_mem_wr_data;
    wire ofm_packet_full;
    wire [31:0] datapath_error_status;
    wire [31:0] context_alloc_count;
    wire [31:0] context_input_issued_count;
    wire [31:0] context_array_retired_count;
    wire [31:0] context_collector_done_count;

    conv_layer_top_stream #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WGT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_D), .IFM_FIFO_AW(IFM_AW),
        .WGT_FIFO_DEPTH(WGT_D), .WGT_FIFO_AW(WGT_AW),
        .PSUM_FIFO_DEPTH(PSUM_D), .PSUM_FIFO_AW(PSUM_AW),
        .FM_W_MAX(FM_W), .FM_H_MAX(FM_H),
        .K_TILE(ROWS), .COUT_TILE(COUT_TILE),
        .WGT_TILE_AW(WGT_TILE_AW), .PSUM_BUF_AW(PSUM_A), .PSUM_BUF_DEPTH(PIXELS),
        .OFM_ADDR_W(16),
        .ENABLE_TAGGED_CONTEXT(`TB_CONV_LAYER_ENABLE_TAGGED_CONTEXT),
        .ENABLE_WEIGHT_PRELOAD(`TB_CONV_LAYER_ENABLE_WEIGHT_PRELOAD),
        .ENABLE_FAST_CONTEXT_HANDOFF(
            `TB_CONV_LAYER_ENABLE_FAST_CONTEXT_HANDOFF)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done),
        .perf_compute_fire(),
        .perf_stage_bias(), .perf_stage_weight(), .perf_stage_feeder(),
        .perf_stage_compute(), .perf_stage_drain(), .perf_stage_ofm_post(),
        .perf_feed_fill_wait(), .perf_feed_push(), .perf_feed_fifo_stall(),
        .perf_feed_win_not_ready(),
        .perf_comp_wload(), .perf_comp_active(), .perf_comp_ifm_stall(),
        .perf_comp_tail(), .perf_tail_cycles_configured(),
        .perf_drain_fifo_empty_wait(), .perf_drain_fifo_empty_sticky(),
        .perf_drain_read_fire(), .perf_drain_packet_fire(),
        .perf_drain_ready_stall(), .perf_drain_internal_full_wait(),
        .perf_prefetch_start(), .perf_prefetch_weight_done(),
        .perf_prefetch_feed_done(), .perf_prefetch_hit(),
        .perf_prefetch_miss(), .perf_prefetch_stall(),
        .perf_psumovl_start(), .perf_psumovl_hit(),
        .perf_psumovl_wait_psum(), .perf_psumovl_underflow(),
        .perf_collect_packet_fire(), .perf_collect_partial_write(),
        .perf_collect_final_write(), .perf_collect_context_push(),
        .perf_collect_context_pop(), .perf_collect_context_full_stall(),
        .perf_collect_column_empty_wait(),
        .perf_pass_count(), .perf_pass_start_to_first_fire(),
        .perf_pass_first_to_last_fire(), .perf_pass_last_fire_to_done(),
        .perf_pass_collect_first_wait(), .perf_pass_collect_column_empty(),
        .perf_pass_replay_active_during_compute(),
        .perf_pass_compute_idle_in_stage(),
        .pass_trace_weight_done(), .pass_trace_feed_start(),
        .pass_trace_feed_ready(), .pass_trace_feed_done(),
        .pass_trace_compute_start(), .pass_trace_first_fire(),
        .pass_trace_last_fire(), .pass_trace_compute_done(),
        .pass_trace_collect_first(), .pass_trace_collect_last(),
        .pass_trace_pass_done(), .pass_trace_valid(),
        .fm_h(FM_H[8:0]), .fm_w(FM_W[8:0]),
        .ofm_h(OFM_H[8:0]), .ofm_w(OFM_W[8:0]),
        .conv_stride(2'd1), .conv_pad(2'd0), .kernel_1x1(1'b0),
        .stream_raw_hwc_mode(`TB_CONV_LAYER_RAW_VECTOR_MODE),
        .tail_cycles_config(16'd0),
        .raw_hwc_compute_start_level(
            `TB_CONV_LAYER_RAW_VECTOR_MODE ? PIXELS[15:0] : 16'd0),
        .early_drain_enable(1'b0),
        .pass_prefetch_enable(`TB_CONV_LAYER_PASS_PREFETCH_ENABLE),
        .during_compute_prefetch_enable(
            `TB_CONV_LAYER_DURING_COMPUTE_PREFETCH_ENABLE),
        .psum_stream_overlap_enable(
            `TB_CONV_LAYER_PSUM_STREAM_OVERLAP_ENABLE),
        .continuous_psum_enable(1'b1),
        // Release elaboration must ignore this unsupported request and must
        // not require any column-PSUM module definitions to link.
        .column_psum_enable(1'b1),
        .pass_trace_enable(1'b0),
        .pass_trace_cout_block(8'd0),
        .pass_trace_k_pass(16'd0),
        .raw_replay_active(1'b0),
        .k_total(K_TOTAL[13:0]), .cout_total(COUT_TOTAL[10:0]),
        .num_pixels(PIXELS[15:0]),
        .tile_oy_base(9'd0), .tile_ofm_h(9'd0), .tile_pixel_base(16'd0),
        .pool_enable(1'b0), .pool_stride(2'd0),
        .bias_load_req(bias_load_req), .bias_load_done(bias_load_done),
        .current_cout_base(current_cout_base), .current_pass_base_k(current_pass_base_k),
        .current_feeder_pass_base_k(current_feeder_pass_base_k),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .weight_load_req(weight_load_req), .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en), .wgt_tile_wr_addr(wgt_tile_wr_addr), .wgt_tile_wr_data(wgt_tile_wr_data),
        .wgt_tile_wr8_en(wgt_tile_wr8_en),
        .wgt_tile_wr8_addr(wgt_tile_wr8_addr),
        .wgt_tile_wr8_data(wgt_tile_wr8_data),
        .wgt_tile_wr8_keep(wgt_tile_wr8_keep),
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .vector_ifm_data(vector_ifm_data),
        .vector_ifm_valid(vector_ifm_valid),
        .vector_ifm_ready(vector_ifm_ready),
        .vector_packet_done(vector_packet_done),
        .final_valid(final_valid), .final_addr(final_addr),
        .final_data(final_data), .final_cout_base(final_cout_base),
        .final_channel_valid(final_channel_valid),
        .quant_mult_flat(quant_mult_flat), .quant_shift_flat(quant_shift_flat),
        .quant_zp_flat(quant_zp_flat),
        .activation_mode(activation_mode), .act_lut_wr_en(act_lut_wr_en),
        .act_lut_wr_addr(act_lut_wr_addr), .act_lut_wr_data(act_lut_wr_data),
        .ofm_valid(ofm_valid), .ofm_addr(ofm_addr),
        .ofm_cout_base(ofm_cout_base), .ofm_channel_valid(ofm_channel_valid),
        .ofm_data(ofm_data),
        .ofm_mem_wr_en(ofm_mem_wr_en), .ofm_mem_wr_ready(1'b1),
        .ofm_mem_wr_addr(ofm_mem_wr_addr),
        .ofm_mem_wr_data(ofm_mem_wr_data), .ofm_packet_full(ofm_packet_full),
        .datapath_error_status(datapath_error_status),
        .context_alloc_count(context_alloc_count),
        .context_input_issued_count(context_input_issued_count),
        .context_array_retired_count(context_array_retired_count),
        .context_collector_done_count(context_collector_done_count)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer b, y, x, r, c, co, k, ch, ker, ky, kx, idx;
    integer final_count, ofm_count, ofm_mem_wr_count, valid_ofm_lanes, ifm_write_count, compute_fire_count, psum_wr_count;
    integer drain_capture_count;
    integer max_context_desc_level;
    integer commit_backpressure_exercised;
    integer weight_credit_backpressure_exercised;
    integer fast_handoff_count;
    integer fast_next_cycle_fire_count;
    integer fast_next_cycle_gap_count;
    integer fast_owner_setup_event_count;
    integer fast_owner_setup_gap_count;
    integer fast_owner_setup_recovery_count;
    integer fast_owner_setup_age_q;
    integer fast_owner_setup_max_age;
    integer fast_cycle_count;
    integer weight_packet_ordinal;
    integer psum_credit_refill_count;
    integer psum_credit_continuous_count;
    integer psum_credit_hold_stall_count;
    integer psum_credit_last_count;
    integer psum_owner_permit_compare_count;
    reg fast_handoff_expect_fire_q;
    reg fast_handoff_owner_setup_ok_q;
    reg fast_owner_setup_recovery_q;
    reg signed [7:0] feat [0:CIN-1][0:FM_H-1][0:FM_W-1];
    reg signed [7:0] weight [0:K_TOTAL-1][0:COUT_TOTAL-1];
    reg signed [PSUM_W-1:0] bias [0:COUT_TOTAL-1];
    reg signed [PSUM_W-1:0] golden [0:PIXELS-1][0:COUT_TOTAL-1];
    reg [7:0] golden_q [0:PIXELS-1][0:COUT_TOTAL-1];
    reg [7:0] ofm_mem [0:PIXELS*COUT_TOTAL-1];
    reg [COLS*2*PSUM_W-1:0] final_pkt [0:COUT_BLOCKS-1][0:PIXELS-1];
    reg signed [PSUM_W-1:0] got0, got1;

    task clear_inputs;
        begin
            start = 0;
            bias_load_done = 0;
            weight_tile_ready = 0;
            bias_wr_addr = 0;
            bias_wr_data = 0;
            bias_wr_en = 0;
            wgt_tile_wr_en = 0;
            wgt_tile_wr_addr = 0;
            wgt_tile_wr_data = 0;
            wgt_tile_wr8_en = 0;
            wgt_tile_wr8_addr = 0;
            wgt_tile_wr8_data = 0;
            wgt_tile_wr8_keep = 0;
            dma_bank_wr_en = 0;
            dma_wr_x = 0;
            dma_wr_fy = 0;
            dma_line_advance = 0;
            vector_ifm_data = {ROWS*IFM_W{1'b0}};
            vector_ifm_valid = 1'b0;
            vector_packet_done = 1'b0;
            for (b = 0; b < 5; b = b + 1) dma_wr_data[b] = 0;
            quant_mult_flat = {COLS*2{16'd32768}};
            quant_shift_flat = {COLS*2{4'd0}};
            quant_zp_flat = {COLS*2{8'd0}};
            activation_mode = 2'd0;
            act_lut_wr_en = 1'b0;
            act_lut_wr_addr = 8'd0;
            act_lut_wr_data = 8'd0;
        end
    endtask

    task service_vector_context;
        integer vp;
        integer vr;
        integer vgk;
        integer vch;
        integer vker;
        integer vky;
        integer vkx;
        integer voy;
        integer vox;
        integer vk_base;
        reg [ROWS*IFM_W-1:0] next_vector;
        begin
            vk_base = current_feeder_pass_base_k;
            for (vp = 0; vp < PIXELS; vp = vp + 1) begin
                voy = vp / OFM_W;
                vox = vp % OFM_W;
                next_vector = {ROWS*IFM_W{1'b0}};
                for (vr = 0; vr < ROWS; vr = vr + 1) begin
                    vgk = vk_base + vr;
                    if (vgk < K_TOTAL) begin
                        vch = vgk / 9;
                        vker = vgk % 9;
                        vky = vker / 3;
                        vkx = vker % 3;
                        next_vector[vr*IFM_W +: IFM_W] =
                            feat[vch][voy+vky][vox+vkx];
                    end
                end
                @(negedge clk);
                vector_ifm_data = next_vector;
                vector_ifm_valid = 1'b1;
                vector_packet_done = (vp == PIXELS - 1);
                @(posedge clk);
                while (!vector_ifm_ready)
                    @(posedge clk);
            end
            @(negedge clk);
            vector_ifm_valid = 1'b0;
            vector_packet_done = 1'b0;
            vector_ifm_data = {ROWS*IFM_W{1'b0}};
        end
    endtask

    task write_row;
        input integer row_y;
        begin
            @(negedge clk);
            dma_bank_wr_en = 5'b11111;
            dma_wr_fy = row_y[9:0];
            for (x = 0; x < FM_W; x = x + 1) begin
                dma_wr_x = x[8:0];
                for (b = 0; b < 5; b = b + 1)
                    dma_wr_data[b] = feat[b][row_y][x];
                @(negedge clk);
            end
            dma_line_advance = 1'b1;
            @(negedge clk);
            dma_line_advance = 1'b0;
            dma_bank_wr_en = 5'b00000;
            @(negedge clk);
        end
    endtask

    task service_bias;
        integer i;
        integer base;
        begin
            base = current_cout_base;
            for (i = 0; i < COUT_TILE; i = i + 1) begin
                @(negedge clk);
                bias_wr_en = 1'b1;
                bias_wr_addr = i[5:0];
                bias_wr_data = (base + i < COUT_TOTAL) ? bias[base + i] : {PSUM_W{1'b0}};
            end
            @(negedge clk);
            bias_wr_en = 1'b0;
            bias_load_done = 1'b1;
            @(negedge clk);
            bias_load_done = 1'b0;
        end
    endtask

    task service_weight;
        integer kk;
        integer cc;
        integer gk;
        integer co_base;
        integer k_base;
        integer packed_base;
        integer packed_lane;
        integer packed_flat;
        begin
            if ((`TB_CONV_LAYER_ENABLE_WEIGHT_PRELOAD != 0) &&
                (`TB_CONV_LAYER_ENABLE_FAST_CONTEXT_HANDOFF != 0)) begin
                // The release staging engine can request two raw packets
                // ahead of the live scheduler state.  Packet order, not the
                // current descriptor, is authoritative for the AXIS stream.
                co_base = (weight_packet_ordinal / K_PASSES) * COUT_TILE;
                k_base = (weight_packet_ordinal % K_PASSES) * ROWS;
            end else begin
                co_base = current_cout_base;
                k_base = dut.u_sched.prefetch_started ?
                    current_feeder_pass_base_k : current_pass_base_k;
            end
            if (`TB_CONV_LAYER_PACKED_WEIGHT_WRITE != 0) begin
                for (packed_base = 0;
                     packed_base < ROWS*COUT_TILE;
                     packed_base = packed_base + 8) begin
                    @(negedge clk);
                    wgt_tile_wr8_en = 1'b1;
                    wgt_tile_wr8_addr = packed_base[WGT_TILE_AW-1:0];
                    wgt_tile_wr8_data = {WGT_W*8{1'b0}};
                    wgt_tile_wr8_keep = 8'd0;
                    for (packed_lane = 0; packed_lane < 8;
                         packed_lane = packed_lane + 1) begin
                        packed_flat = packed_base + packed_lane;
                        if (packed_flat < ROWS*COUT_TILE) begin
                            kk = packed_flat / COUT_TILE;
                            cc = packed_flat % COUT_TILE;
                            gk = k_base + kk;
                            wgt_tile_wr8_keep[packed_lane] = 1'b1;
                            wgt_tile_wr8_data[packed_lane*WGT_W +: WGT_W] =
                                ((gk < K_TOTAL) &&
                                 (co_base + cc < COUT_TOTAL)) ?
                                weight[gk][co_base + cc] : 8'd0;
                        end
                    end
                end
                @(negedge clk);
                wgt_tile_wr8_en = 1'b0;
                wgt_tile_wr8_keep = 8'd0;
                wgt_tile_wr8_data = {WGT_W*8{1'b0}};
            end else begin
                for (kk = 0; kk < ROWS; kk = kk + 1) begin
                    for (cc = 0; cc < COUT_TILE; cc = cc + 1) begin
                        gk = k_base + kk;
                        @(negedge clk);
                        wgt_tile_wr_en = 1'b1;
                        wgt_tile_wr_addr = kk*COUT_TILE + cc;
                        wgt_tile_wr_data =
                            ((gk < K_TOTAL) &&
                             (co_base + cc < COUT_TOTAL)) ?
                            weight[gk][co_base + cc] : 8'd0;
                    end
                end
                @(negedge clk);
                wgt_tile_wr_en = 1'b0;
            end
            weight_tile_ready = 1'b1;
            @(negedge clk);
            weight_tile_ready = 1'b0;
            weight_packet_ordinal = weight_packet_ordinal + 1;
        end
    endtask

    initial begin
        @(negedge rst);
        forever begin
            wait(bias_load_req);
            service_bias();
            wait(!bias_load_req);
        end
    end

    initial begin
        @(negedge rst);
        forever begin
            wait(weight_load_req);
            service_weight();
            wait(!weight_load_req);
        end
    end

    initial begin
        @(negedge rst);
        forever begin
            wait(feeder_fill_req);
            if (`TB_CONV_LAYER_RAW_VECTOR_MODE != 0)
                service_vector_context();
            else begin
                write_row(feeder_fill_fy);
                @(posedge clk);
                #1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst && final_valid && dut.final_fifo_ready) begin
            final_pkt[final_cout_base / COUT_TILE][final_addr] <= final_data;
            final_count <= final_count + 1;
        end
        if (!rst && ofm_valid && dut.rq_fifo_ready)
            ofm_count <= ofm_count + 1;
        if (!rst && ofm_valid && dut.rq_fifo_ready) begin
            for (b = 0; b < COUT_TILE; b = b + 1)
                if (ofm_channel_valid[b])
                    valid_ofm_lanes = valid_ofm_lanes + 1;
        end
        if (!rst && dut.u_top.feeder_ifm_valid)
            ifm_write_count <= ifm_write_count + 1;
        if (!rst && dut.compute_fire)
            compute_fire_count <= compute_fire_count + 1;
        if (!rst && dut.psum_fifo_wr_en_dbg[0])
            psum_wr_count <= psum_wr_count + 1;
        if (!rst && dut.drain_packet_fire)
            drain_capture_count <= drain_capture_count + 1;
        if (!rst && dut.context_desc_level > max_context_desc_level)
            max_context_desc_level <= dut.context_desc_level;
    end

    generate
        if (`TB_CONV_LAYER_REQUIRE_FAST_HANDOFF != 0) begin : fast_handoff_check
            wire owner_wait_only =
                !dut.issue_final_q &&
                dut.psum_score_active_rd_parent_owned &&
                !dut.psum_score_active_wr_bank_owned &&
                !dut.u_top.g_tagged_context_core.u_core.context_admission_ready &&
                dut.u_top.g_tagged_context_core.u_core.ctrl_compute_active &&
                dut.u_top.g_tagged_context_core.u_core.ifm_vector_valid &&
                dut.u_top.g_tagged_context_core.u_core.context_stream_match &&
                dut.u_top.g_tagged_context_core.u_core.active_weight_epoch_match &&
                dut.u_top.g_tagged_context_core.u_core.psum_input_ready &&
                dut.u_top.g_tagged_context_core.u_core.all_output_credit_available &&
                !dut.u_top.g_tagged_context_core.u_core.datapath_fatal;

            always @(posedge clk) begin
                if (rst) begin
                    fast_handoff_count <= 0;
                    fast_next_cycle_fire_count <= 0;
                    fast_next_cycle_gap_count <= 0;
                    fast_owner_setup_event_count <= 0;
                    fast_owner_setup_gap_count <= 0;
                    fast_owner_setup_recovery_count <= 0;
                    fast_owner_setup_age_q <= 0;
                    fast_owner_setup_max_age <= 0;
                    fast_handoff_expect_fire_q <= 1'b0;
                    fast_handoff_owner_setup_ok_q <= 1'b0;
                    fast_owner_setup_recovery_q <= 1'b0;
                    fast_cycle_count <= 0;
                end else begin
                    fast_cycle_count <= fast_cycle_count + 1;
                    if (fast_owner_setup_recovery_q) begin
                        if (dut.u_top.g_tagged_context_core.u_core.ctrl_compute_fire) begin
                            fast_owner_setup_recovery_count <=
                                fast_owner_setup_recovery_count + 1;
                            fast_owner_setup_recovery_q <= 1'b0;
                            fast_owner_setup_age_q <= 0;
                        end else if (owner_wait_only &&
                                     (fast_owner_setup_age_q < ROWS + 8)) begin
                            fast_owner_setup_gap_count <=
                                fast_owner_setup_gap_count + 1;
                            fast_owner_setup_age_q <=
                                fast_owner_setup_age_q + 1;
                            if (fast_owner_setup_max_age <
                                fast_owner_setup_age_q + 1)
                                fast_owner_setup_max_age <=
                                    fast_owner_setup_age_q + 1;
                        end else begin
                            fast_next_cycle_gap_count <=
                                fast_next_cycle_gap_count + 1;
                            fast_owner_setup_recovery_q <= 1'b0;
                            $display("[FAST_TRACE] cycle=%0d owner wait escaped bound/reason age=%0d",
                                fast_cycle_count, fast_owner_setup_age_q);
                        end
                    end
                    if (fast_handoff_expect_fire_q) begin
                        if (dut.u_top.g_tagged_context_core.u_core.ctrl_compute_fire)
                            fast_next_cycle_fire_count <=
                                fast_next_cycle_fire_count + 1;
                        else if (fast_handoff_owner_setup_ok_q &&
                                 owner_wait_only) begin
                            fast_owner_setup_event_count <=
                                fast_owner_setup_event_count + 1;
                            fast_owner_setup_gap_count <=
                                fast_owner_setup_gap_count + 1;
                            fast_owner_setup_recovery_q <= 1'b1;
                            fast_owner_setup_age_q <= 1;
                            if (fast_owner_setup_max_age < 1)
                                fast_owner_setup_max_age <= 1;
                        end
                        else begin
                            fast_next_cycle_gap_count <=
                                fast_next_cycle_gap_count + 1;
                            $display("[FAST_TRACE] cycle=%0d next-cycle gap ctrl_active=%0d ifm_valid=%0d stream_match=%0d weight_match=%0d admission=%0d psum_ready=%0d credit=%0d fatal=%0d active_first=%0d ifm_bank=%0d/%0d epoch=%0d/%0d",
                                fast_cycle_count,
                                dut.u_top.g_tagged_context_core.u_core.ctrl_compute_active,
                                dut.u_top.g_tagged_context_core.u_core.ifm_vector_valid,
                                dut.u_top.g_tagged_context_core.u_core.context_stream_match,
                                dut.u_top.g_tagged_context_core.u_core.active_weight_epoch_match,
                                dut.u_top.g_tagged_context_core.u_core.context_admission_ready,
                                dut.u_top.g_tagged_context_core.u_core.psum_input_ready,
                                dut.u_top.g_tagged_context_core.u_core.all_output_credit_available,
                                dut.u_top.g_tagged_context_core.u_core.datapath_fatal,
                                dut.u_top.g_tagged_context_core.u_core.active_is_first_pass_q,
                                dut.u_top.g_tagged_context_core.u_core.ifm_vector_bank,
                                dut.u_top.g_tagged_context_core.u_core.active_context_bank_q,
                                dut.u_top.g_tagged_context_core.u_core.ifm_vector_epoch,
                                dut.u_top.g_tagged_context_core.u_core.active_context_epoch_q);
                        end
                    end
                    fast_handoff_expect_fire_q <=
                        dut.u_top.g_tagged_context_core.u_core.final_input_fire &&
                        dut.u_top.g_tagged_context_core.u_core.start_fire;
                    fast_handoff_owner_setup_ok_q <=
                        dut.u_top.g_tagged_context_core.u_core.final_input_fire &&
                        dut.u_top.g_tagged_context_core.u_core.start_fire &&
                        !dut.start_desc_final;
                    if (dut.u_top.g_tagged_context_core.u_core.final_input_fire &&
                        dut.u_top.g_tagged_context_core.u_core.start_fire)
                        fast_handoff_count <= fast_handoff_count + 1;
                    if (dut.perf_prefetch_start)
                        $display("[FAST_TRACE] cycle=%0d prefetch feeder_k=%0d prepared=%0d preload_state=%0d/%0d",
                            fast_cycle_count, dut.sched_feeder_k_pass,
                            dut.prepared_pop_valid,
                            dut.u_top.g_tagged_context_core.u_core.g_weight_preload.u_weight_preloader.bank0_state,
                            dut.u_top.g_tagged_context_core.u_core.g_weight_preload.u_weight_preloader.bank1_state);
                    if (dut.u_top.g_tagged_context_core.u_core.final_input_fire)
                        $display("[FAST_TRACE] cycle=%0d final bank=%0d start=%0d ctrl_ready=%0d top_ready=%0d selected_weight=%0d mesh=%b request=%0d prepared=%0d admit_ready=%0d",
                            fast_cycle_count,
                            dut.u_top.g_tagged_context_core.u_core.active_context_bank_q,
                            dut.u_top.g_tagged_context_core.u_core.start_fire,
                            dut.u_top.g_tagged_context_core.u_core.ctrl_start_ready,
                            dut.u_top.g_tagged_context_core.u_core.start_ready,
                            dut.u_top.g_tagged_context_core.u_core.selected_weight_ready,
                            dut.u_top.g_tagged_context_core.u_core.mesh_epoch_valid_q,
                            dut.u_top.g_tagged_context_core.u_context_frontend.compute_request_pending_q,
                            dut.prepared_pop_valid,
                            dut.tagged_context_start_ready);
                    if (dut.accepted_compute_context_start)
                        $display("[FAST_TRACE] cycle=%0d accepted bank=%0d epoch=%0d k=%0d",
                            fast_cycle_count, dut.compute_context_bank,
                            dut.compute_context_epoch, dut.start_desc_k_pass);
                end
            end
        end
    endgenerate

    always @(negedge clk) begin
        if (!rst && ofm_mem_wr_en) begin
            ofm_mem[ofm_mem_wr_addr] <= ofm_mem_wr_data;
            ofm_mem_wr_count <= ofm_mem_wr_count + 1;
        end
    end

    generate
        if (`TB_CONV_LAYER_ENABLE_TAGGED_CONTEXT != 0) begin : tagged_fail_fast
            if (`TB_CONV_LAYER_FORCE_COMMIT_BACKPRESSURE != 0) begin : commit_bp
                initial begin
                    wait (!rst);
                    wait (dut.collector_packet_valid &&
                          !dut.collector_packet_is_final &&
                          (dut.collector_packet_addr ==
                           dut.context_desc_num_pixels[PSUM_A-1:0] - 1'b1));
                    @(negedge clk);
                    force dut.psum_commit_event_in_ready = 1'b0;
                    repeat (2) begin
                        @(posedge clk);
                        #1;
                        if (!dut.collector_packet_valid ||
                            dut.u_psum_owner.wr_fire || dut.pp_wr_en) begin
                            $display("[FAIL] final partial packet advanced under commit FIFO backpressure");
                            $fatal(1);
                        end
                    end
                    @(negedge clk);
                    release dut.psum_commit_event_in_ready;
                    commit_backpressure_exercised = 1;
                end
            end

            if (`TB_CONV_LAYER_FORCE_WEIGHT_CREDIT_BACKPRESSURE != 0) begin : weight_credit_bp
                initial begin
                    wait (!rst);
                    wait (dut.g_weight_tile_pingpong.u_weight_loader.format_busy_q);
                    force dut.u_top.g_tagged_context_core.u_core.g_weight_preload.u_weight_preloader.weight_tile_credit_ready = 1'b0;
                    wait (dut.wgt_loader_done);
                    @(posedge clk);
                    #1;
                    if ((dut.weight_tile_complete_pending_q !== 1'b1) ||
                        (dut.sched_weight_done !== 1'b0)) begin
                        $display("[FAIL] weight completion was not held under credit backpressure");
                        $fatal(1);
                    end
                    repeat (2) begin
                        @(posedge clk);
                        #1;
                        if ((dut.weight_tile_complete_pending_q !== 1'b1) ||
                            (dut.sched_weight_done !== 1'b0)) begin
                            $display("[FAIL] held weight completion advanced before credit ready");
                            $fatal(1);
                        end
                    end
                    @(negedge clk);
                    release dut.u_top.g_tagged_context_core.u_core.g_weight_preload.u_weight_preloader.weight_tile_credit_ready;
                    @(posedge clk);
                    #1;
                    if ((dut.weight_tile_complete_pending_q !== 1'b0) ||
                        (dut.sched_weight_done !== 1'b1)) begin
                        $display("[FAIL] held weight completion did not handshake after credit recovery");
                        $fatal(1);
                    end
                    weight_credit_backpressure_exercised = 1;
                end
            end

            always @(posedge clk) begin
                #1;
                if (!rst &&
                    dut.u_top.g_tagged_context_core.u_core.ctrl_compute_active &&
                    (dut.issue_psum_owner_permit_q !==
                     (dut.psum_score_active_rd_parent_owned &&
                      (dut.issue_final_q ||
                       dut.psum_score_active_wr_bank_owned)))) begin
                    $display("[FAIL] registered PSUM owner permit diverged q=%0b old=%0b rd=%0b wr=%0b final=%0b alloc_fire=%0b",
                        dut.issue_psum_owner_permit_q,
                        dut.psum_score_active_rd_parent_owned &&
                            (dut.issue_final_q ||
                             dut.psum_score_active_wr_bank_owned),
                        dut.psum_score_active_rd_parent_owned,
                        dut.psum_score_active_wr_bank_owned,
                        dut.issue_final_q, dut.psum_score_alloc_fire);
                    $fatal(1);
                end
                if (!rst &&
                    dut.u_top.g_tagged_context_core.u_core.ctrl_compute_active)
                    psum_owner_permit_compare_count <=
                        psum_owner_permit_compare_count + 1;
            end

            always @(posedge clk) begin
                if (!rst &&
                    ((dut.psum_score_rd_credit_q[0] !==
                      (dut.psum_score_credit0 != 0)) ||
                     (dut.psum_score_rd_credit_q[1] !==
                      (dut.psum_score_credit1 != 0)))) begin
                    $display("[FAIL] registered PSUM credits diverged q=%b exact=%0d%0d",
                        dut.psum_score_rd_credit_q,
                        dut.psum_score_credit1 != 0,
                        dut.psum_score_credit0 != 0);
                    $fatal(1);
                end
                if (!rst &&
                    (dut.pp_wr_en !== dut.u_psum_owner.wr_fire)) begin
                    $display("[FAIL] tagged PSUM write credit/RAM handshake diverged");
                    $fatal(1);
                end
                if (!rst &&
                    (dut.pp_rd_en !== (dut.psum_score_rd_valid &&
                                       dut.psum_score_rd_ready))) begin
                    $display("[FAIL] tagged PSUM read credit/RAM handshake diverged");
                    $fatal(1);
                end
                if (!rst && dut.psum_score_ext_mode && dut.compute_fire &&
                    (!dut.psum_score_rd_ready || !dut.psum_score_rd_fire ||
                     !dut.pp_rd_en)) begin
                    $display("[FAIL] PSUM compute/read/owner handshakes diverged ready=%0d fire=%0d ram=%0d",
                        dut.psum_score_rd_ready, dut.psum_score_rd_fire,
                        dut.pp_rd_en);
                    $fatal(1);
                end
                if (!rst && dut.psum_score_ext_mode &&
                    dut.psum_score_rd_credit &&
                    !dut.psum_score_rd_ready && !dut.psum_score_fail_stop) begin
                    $display("[FAIL] registered PSUM credit outran exact owner readiness");
                    $fatal(1);
                end
                if (!rst && dut.psum_score_wr_fire &&
                    (dut.drain_packet_wr_bank ?
                        (dut.psum_score_credit1 == 0) :
                        (dut.psum_score_credit0 == 0)))
                    psum_credit_refill_count <=
                        psum_credit_refill_count + 1;
                if (!rst && dut.psum_score_rd_fire &&
                    !dut.psum_score_rd_last &&
                    ((dut.pp_rd_bank ? dut.psum_score_credit1 :
                                       dut.psum_score_credit0) > 1 ||
                     (dut.psum_score_wr_fire &&
                      (dut.drain_packet_wr_bank == dut.pp_rd_bank))))
                    psum_credit_continuous_count <=
                        psum_credit_continuous_count + 1;
                if (!rst && dut.psum_score_ext_mode &&
                    dut.psum_score_rd_credit && dut.psum_score_rd_ready &&
                    !dut.compute_fire)
                    psum_credit_hold_stall_count <=
                        psum_credit_hold_stall_count + 1;
                if (!rst && dut.psum_score_rd_fire &&
                    dut.psum_score_rd_last)
                    psum_credit_last_count <= psum_credit_last_count + 1;
                if (!rst && datapath_error_status != 32'd0) begin
                    $display("[FAIL] tagged datapath error=%h top=%h collector_tag=%0d/%0d got=%h expected=%h addr=%0d active_epoch=%h bank=%0d score=%0d%0d%0d%0d%0d fill=%0d/%0d/%0d vec=%0d/%0d produced=%0d/%0d expected=%0d/%0d committed=%b allocated=%b",
                        datapath_error_status,
                        dut.tagged_datapath_error_status,
                        dut.collector_tag_mismatch_sticky,
                        dut.collector_tag_mismatch_count,
                        dut.u_collector.return_tag0,
                        dut.u_collector.expected_return_tag,
                        dut.u_collector.packet_addr,
                        dut.u_collector.active_epoch,
                        dut.u_collector.active_ifm_bank,
                        dut.psum_score_error_underflow,
                        dut.psum_score_error_overwrite,
                        dut.psum_score_error_epoch,
                        dut.psum_score_error_context,
                        dut.psum_score_error_conflict,
                        dut.u_top.g_tagged_context_core.u_context_frontend.fill_active_q,
                        dut.u_top.g_tagged_context_core.u_context_frontend.fill_bank_q,
                        dut.u_top.vector_push_count,
                        vector_ifm_valid, vector_ifm_ready,
                        dut.u_top.g_tagged_context_core.u_context_frontend.u_epoch_buffer.produced0_q,
                        dut.u_top.g_tagged_context_core.u_context_frontend.u_epoch_buffer.produced1_q,
                        dut.u_top.g_tagged_context_core.u_context_frontend.u_epoch_buffer.expected0_q,
                        dut.u_top.g_tagged_context_core.u_context_frontend.u_epoch_buffer.expected1_q,
                        dut.u_top.g_tagged_context_core.u_context_frontend.u_epoch_buffer.committed_q,
                        dut.u_top.g_tagged_context_core.u_context_frontend.u_epoch_buffer.allocated_q);
                    $fatal(1);
                end
            end
        end
    endgenerate

    function [7:0] clamp8;
        input signed [PSUM_W-1:0] v;
        begin
            if (v > 127) clamp8 = 8'd127;
            else if (v < -128) clamp8 = 8'd128;
            else clamp8 = v[7:0];
        end
    endfunction

    initial begin
        clk = 0;
        rst = 1;
        pass = 0;
        fail = 0;
        final_count = 0;
        ofm_count = 0;
        ofm_mem_wr_count = 0;
        valid_ofm_lanes = 0;
        ifm_write_count = 0;
        compute_fire_count = 0;
        psum_wr_count = 0;
        drain_capture_count = 0;
        max_context_desc_level = 0;
        commit_backpressure_exercised = 0;
        weight_credit_backpressure_exercised = 0;
        fast_handoff_count = 0;
        fast_next_cycle_fire_count = 0;
        fast_next_cycle_gap_count = 0;
        fast_owner_setup_event_count = 0;
        fast_owner_setup_gap_count = 0;
        fast_owner_setup_recovery_count = 0;
        fast_owner_setup_age_q = 0;
        fast_owner_setup_max_age = 0;
        fast_handoff_expect_fire_q = 1'b0;
        fast_handoff_owner_setup_ok_q = 1'b0;
        fast_owner_setup_recovery_q = 1'b0;
        fast_cycle_count = 0;
        weight_packet_ordinal = 0;
        psum_credit_refill_count = 0;
        psum_credit_continuous_count = 0;
        psum_credit_hold_stall_count = 0;
        psum_credit_last_count = 0;
        psum_owner_permit_compare_count = 0;
        clear_inputs();
        for (idx = 0; idx < PIXELS*COUT_TOTAL; idx = idx + 1)
            ofm_mem[idx] = 8'hxx;

        for (ch = 0; ch < CIN; ch = ch + 1)
            for (y = 0; y < FM_H; y = y + 1)
                for (x = 0; x < FM_W; x = x + 1)
                    feat[ch][y][x] = ch*13 + y*3 + x - 25;

        for (k = 0; k < K_TOTAL; k = k + 1)
            for (co = 0; co < COUT_TOTAL; co = co + 1)
                weight[k][co] = (k*5 + co*3) % 17 - 8;

        for (co = 0; co < COUT_TOTAL; co = co + 1) begin
            bias[co] = co*7 - 19;
            for (idx = 0; idx < PIXELS; idx = idx + 1) begin
                y = idx / OFM_W;
                x = idx % OFM_W;
                golden[idx][co] = bias[co];
                for (k = 0; k < K_TOTAL; k = k + 1) begin
                    ch = k / 9;
                    ker = k % 9;
                    ky = ker / 3;
                    kx = ker % 3;
                    golden[idx][co] = golden[idx][co] + feat[ch][y+ky][x+kx] * weight[k][co];
                end
                golden_q[idx][co] = clamp8(golden[idx][co]);
            end
        end

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        wait(done);
        repeat (5) @(negedge clk);

        if (final_count != PIXELS * COUT_BLOCKS) begin
            $display("[FAIL] final_count got=%0d exp=%0d", final_count, PIXELS * COUT_BLOCKS);
            fail = fail + 1;
        end else pass = pass + 1;
        if (ofm_count != PIXELS * COUT_BLOCKS) begin
            $display("[FAIL] ofm_count got=%0d exp=%0d", ofm_count, PIXELS * COUT_BLOCKS);
            fail = fail + 1;
        end else pass = pass + 1;
        if (valid_ofm_lanes != PIXELS * COUT_TOTAL) begin
            $display("[FAIL] valid_ofm_lanes got=%0d exp=%0d", valid_ofm_lanes, PIXELS * COUT_TOTAL);
            fail = fail + 1;
        end else pass = pass + 1;
        if (ofm_mem_wr_count != PIXELS * COUT_TOTAL) begin
            $display("[FAIL] ofm_mem_wr_count got=%0d exp=%0d", ofm_mem_wr_count, PIXELS * COUT_TOTAL);
            fail = fail + 1;
        end else pass = pass + 1;

        if (`TB_CONV_LAYER_ENABLE_TAGGED_CONTEXT != 0) begin
            if (context_alloc_count != COUT_BLOCKS *
                ((K_TOTAL + ROWS - 1) / ROWS)) begin
                $display("[FAIL] context_alloc_count got=%0d exp=%0d",
                    context_alloc_count,
                    COUT_BLOCKS * ((K_TOTAL + ROWS - 1) / ROWS));
                fail = fail + 1;
            end else pass = pass + 1;
            if (context_input_issued_count != context_alloc_count) begin
                $display("[FAIL] input-issued contexts got=%0d alloc=%0d",
                    context_input_issued_count, context_alloc_count);
                fail = fail + 1;
            end else pass = pass + 1;
            if (context_array_retired_count != context_alloc_count) begin
                $display("[FAIL] array-retired contexts got=%0d alloc=%0d",
                    context_array_retired_count, context_alloc_count);
                fail = fail + 1;
            end else pass = pass + 1;
            if (context_collector_done_count != context_alloc_count) begin
                $display("[FAIL] collector-done contexts got=%0d alloc=%0d",
                    context_collector_done_count, context_alloc_count);
                fail = fail + 1;
            end else pass = pass + 1;
            if (dut.context_desc_level != 0) begin
                $display("[FAIL] lifecycle descriptor queue not empty level=%0d",
                    dut.context_desc_level);
                fail = fail + 1;
            end else pass = pass + 1;
            if ((K_TOTAL + ROWS - 1) / ROWS > 1) begin
                if (psum_owner_permit_compare_count == 0) begin
                    $display("[FAIL] PSUM owner permit oracle was not exercised");
                    fail = fail + 1;
                end else begin
                    $display("[PSUM_OWNER_PERMIT_METRIC] comparisons=%0d",
                        psum_owner_permit_compare_count);
                    pass = pass + 1;
                end
                if (psum_credit_refill_count == 0 ||
                    psum_credit_continuous_count == 0 ||
                    psum_credit_hold_stall_count == 0 ||
                    psum_credit_last_count == 0) begin
                    $display("[FAIL] PSUM token corner coverage refill=%0d continuous=%0d hold=%0d last=%0d",
                        psum_credit_refill_count,
                        psum_credit_continuous_count,
                        psum_credit_hold_stall_count,
                        psum_credit_last_count);
                    fail = fail + 1;
                end else begin
                    $display("[PSUM_TOKEN_METRIC] refill=%0d continuous=%0d hold=%0d last=%0d",
                        psum_credit_refill_count,
                        psum_credit_continuous_count,
                        psum_credit_hold_stall_count,
                        psum_credit_last_count);
                    pass = pass + 1;
                end
            end
            if (`TB_CONV_LAYER_REQUIRE_CONTEXT_OVERLAP != 0) begin
                if (max_context_desc_level < 2) begin
                    $display("[FAIL] no collector overlap observed max descriptor level=%0d",
                        max_context_desc_level);
                    fail = fail + 1;
                end else pass = pass + 1;
            end
            if (`TB_CONV_LAYER_FORCE_COMMIT_BACKPRESSURE != 0) begin
                if (commit_backpressure_exercised != 1) begin
                    $display("[FAIL] commit-event FIFO backpressure corner was not exercised");
                    fail = fail + 1;
                end else pass = pass + 1;
            end
            if (`TB_CONV_LAYER_FORCE_WEIGHT_CREDIT_BACKPRESSURE != 0) begin
                if (weight_credit_backpressure_exercised != 1) begin
                    $display("[FAIL] weight-credit backpressure corner was not exercised");
                    fail = fail + 1;
                end else pass = pass + 1;
            end
            if (`TB_CONV_LAYER_REQUIRE_FAST_HANDOFF != 0) begin
                if (fast_handoff_count == 0) begin
                    $display("[FAIL] no same-edge final/start handoff observed");
                    fail = fail + 1;
                end else pass = pass + 1;
                if ((fast_next_cycle_fire_count +
                     fast_owner_setup_recovery_count) != fast_handoff_count ||
                    fast_next_cycle_gap_count != 0 ||
                    fast_owner_setup_recovery_count !=
                        fast_owner_setup_event_count ||
                    fast_owner_setup_max_age > ROWS + 8) begin
                    $display("[FAIL] fast handoff next-cycle=%0d owner-events=%0d owner-gap-cycles=%0d recovered=%0d max-age=%0d handoff=%0d unexpected=%0d",
                        fast_next_cycle_fire_count,
                        fast_owner_setup_event_count,
                        fast_owner_setup_gap_count,
                        fast_owner_setup_recovery_count,
                        fast_owner_setup_max_age,
                        fast_handoff_count,
                        fast_next_cycle_gap_count);
                    fail = fail + 1;
                end else begin
                    $display("[FAST_METRIC] handoff=%0d next_cycle=%0d owner_events=%0d owner_gap_cycles=%0d owner_max_age=%0d unexpected=0",
                        fast_handoff_count, fast_next_cycle_fire_count,
                        fast_owner_setup_event_count,
                        fast_owner_setup_gap_count,
                        fast_owner_setup_max_age);
                    pass = pass + 1;
                end
            end
        end

        for (idx = 0; idx < PIXELS; idx = idx + 1) begin
            for (co = 0; co < COUT_TOTAL; co = co + 2) begin
                c = (co % COUT_TILE) / 2;
                got0 = final_pkt[co / COUT_TILE][idx][(2*c)*PSUM_W +: PSUM_W];
                if (got0 !== golden[idx][co]) begin
                    $display("[FAIL] pixel%0d cout%0d got=%0d exp=%0d", idx, co, got0, golden[idx][co]);
                    fail = fail + 1;
                end else pass = pass + 1;
                if (co + 1 < COUT_TOTAL) begin
                    got1 = final_pkt[co / COUT_TILE][idx][(2*c+1)*PSUM_W +: PSUM_W];
                    if (got1 !== golden[idx][co+1]) begin
                        $display("[FAIL] pixel%0d cout%0d got=%0d exp=%0d", idx, co+1, got1, golden[idx][co+1]);
                        fail = fail + 1;
                    end else pass = pass + 1;
                end
            end
        end

        for (idx = 0; idx < PIXELS; idx = idx + 1) begin
            for (co = 0; co < COUT_TOTAL; co = co + 1) begin
                if (ofm_mem[idx*COUT_TOTAL + co] !== golden_q[idx][co]) begin
                    $display("[FAIL] ofm_mem pixel%0d cout%0d got=%0d exp=%0d",
                        idx, co, ofm_mem[idx*COUT_TOTAL + co], golden_q[idx][co]);
                    fail = fail + 1;
                end else pass = pass + 1;
            end
        end

        // The aggregated FIFO-drop diagnostic is intentionally pipelined at
        // the layer boundary.  Its value must remain coherent and advance by
        // exactly one clock; datapath behavior above is independent of this
        // software-only readback latency.
        force dut.context_fifo_drop_count_comb = 32'h1357_2468;
        @(posedge clk); #1;
        if (dut.context_fifo_drop_count !== 32'h1357_2468) begin
            $display("[FAIL] registered FIFO-drop readback first sample got=%h",
                     dut.context_fifo_drop_count);
            fail = fail + 1;
        end else pass = pass + 1;
        force dut.context_fifo_drop_count_comb = 32'h89ab_cdef;
        #1;
        if (dut.context_fifo_drop_count !== 32'h1357_2468) begin
            $display("[FAIL] FIFO-drop readback changed combinationally got=%h",
                     dut.context_fifo_drop_count);
            fail = fail + 1;
        end else pass = pass + 1;
        @(posedge clk); #1;
        if (dut.context_fifo_drop_count !== 32'h89ab_cdef) begin
            $display("[FAIL] registered FIFO-drop readback second sample got=%h",
                     dut.context_fifo_drop_count);
            fail = fail + 1;
        end else pass = pass + 1;
        release dut.context_fifo_drop_count_comb;

        $display("=== tb_conv_layer_top_stream: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (`TB_CONV_LAYER_TIMEOUT_CYCLES) @(negedge clk);
        $display("[FAIL] timeout done=%0d busy=%0d final_count=%0d ofm_count=%0d ifm_wr=%0d fire=%0d psum_wr=%0d bias_req=%0d wgt_req=%0d fill_req=%0d cout=%0d k=%0d sched_state=%0d feeder_done=%0d compute_done=%0d drain_done=%0d drain_busy=%0d psum_empty=%h rd_en=%h err=%h ctx=%0d/%0d/%0d/%0d score_fail=%0d score_err=%0d%0d%0d%0d%0d",
            done, busy, final_count, ofm_count, ifm_write_count, compute_fire_count, psum_wr_count,
            bias_load_req, weight_load_req, feeder_fill_req,
            current_cout_base, current_pass_base_k, dut.u_sched.state, dut.feeder_done, dut.compute_done, dut.drain_done,
            dut.u_drain.busy, dut.psum_fifo_empty, dut.psum_fifo_rd_en,
            datapath_error_status, context_alloc_count,
            context_input_issued_count, context_array_retired_count,
            context_collector_done_count, dut.psum_score_fail_stop,
            dut.psum_score_error_underflow, dut.psum_score_error_overwrite,
            dut.psum_score_error_epoch, dut.psum_score_error_context,
            dut.psum_score_error_conflict);
        $fatal(1);
    end
endmodule

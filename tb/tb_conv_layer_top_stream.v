`timescale 1ns / 1ps

module tb_conv_layer_top_stream;
    localparam ROWS = 32;
    localparam COLS = 4;
    localparam IFM_W = 8;
    localparam WGT_W = 8;
    localparam PSUM_W = 32;
    localparam IFM_D = 16;
    localparam IFM_AW = 4;
    localparam WGT_D = 64;
    localparam WGT_AW = 6;
    localparam PSUM_D = 16;
    localparam PSUM_AW = 4;
    localparam FM_W = 5;
    localparam FM_H = 5;
    localparam OFM_W = 3;
    localparam OFM_H = 3;
    localparam PIXELS = OFM_W * OFM_H;
    localparam CIN = 5;
    localparam K_TOTAL = CIN * 3 * 3;
    localparam COUT_TILE = COLS * 2;
    localparam COUT_TOTAL = COUT_TILE + 2;
    localparam COUT_BLOCKS = (COUT_TOTAL + COUT_TILE - 1) / COUT_TILE;
    localparam WGT_TILE_AW = 11;
    localparam PSUM_A = 4;

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
    wire feeder_fill_req;
    wire [8:0] feeder_fill_fy;
    reg [4:0] dma_bank_wr_en;
    reg [8:0] dma_wr_x;
    reg [9:0] dma_wr_fy;
    reg [7:0] dma_wr_data [0:4];
    reg dma_line_advance;
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

    conv_layer_top_stream #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WGT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_D), .IFM_FIFO_AW(IFM_AW),
        .WGT_FIFO_DEPTH(WGT_D), .WGT_FIFO_AW(WGT_AW),
        .PSUM_FIFO_DEPTH(PSUM_D), .PSUM_FIFO_AW(PSUM_AW),
        .FM_W_MAX(FM_W), .FM_H_MAX(FM_H),
        .K_TILE(32), .COUT_TILE(COUT_TILE),
        .WGT_TILE_AW(WGT_TILE_AW), .PSUM_BUF_AW(PSUM_A), .PSUM_BUF_DEPTH(PIXELS),
        .OFM_ADDR_W(16)
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
        .fm_h(9'd5), .fm_w(9'd5), .ofm_h(9'd3), .ofm_w(9'd3),
        .conv_stride(2'd1), .conv_pad(2'd0), .kernel_1x1(1'b0),
        .stream_raw_hwc_mode(1'b0),
        .tail_cycles_config(16'd0),
        .raw_hwc_compute_start_level(16'd0),
        .early_drain_enable(1'b0),
        .pass_prefetch_enable(1'b0),
        .during_compute_prefetch_enable(1'b0),
        .psum_stream_overlap_enable(1'b0),
        .continuous_psum_enable(1'b0),
        .pass_trace_enable(1'b0),
        .pass_trace_cout_block(8'd0),
        .pass_trace_k_pass(16'd0),
        .raw_replay_active(1'b0),
        .k_total(K_TOTAL[13:0]), .cout_total(COUT_TOTAL[10:0]), .num_pixels(16'd9),
        .tile_oy_base(9'd0), .tile_ofm_h(9'd0), .tile_pixel_base(16'd0),
        .pool_enable(1'b0), .pool_stride(2'd0),
        .bias_load_req(bias_load_req), .bias_load_done(bias_load_done),
        .current_cout_base(current_cout_base), .current_pass_base_k(current_pass_base_k),
        .current_feeder_pass_base_k(),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .weight_load_req(weight_load_req), .weight_tile_ready(weight_tile_ready),
        .wgt_tile_wr_en(wgt_tile_wr_en), .wgt_tile_wr_addr(wgt_tile_wr_addr), .wgt_tile_wr_data(wgt_tile_wr_data),
        .wgt_tile_wr8_en(1'b0), .wgt_tile_wr8_addr({WGT_TILE_AW{1'b0}}),
        .wgt_tile_wr8_data(64'd0), .wgt_tile_wr8_keep(8'd0),
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
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
        .ofm_mem_wr_data(ofm_mem_wr_data), .ofm_packet_full(ofm_packet_full)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer b, y, x, r, c, co, k, ch, ker, ky, kx, idx;
    integer final_count, ofm_count, ofm_mem_wr_count, valid_ofm_lanes, ifm_write_count, compute_fire_count, psum_wr_count;
    integer drain_capture_count;
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
            dma_bank_wr_en = 0;
            dma_wr_x = 0;
            dma_wr_fy = 0;
            dma_line_advance = 0;
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
        begin
            co_base = current_cout_base;
            k_base = current_pass_base_k;
            for (kk = 0; kk < ROWS; kk = kk + 1) begin
                for (cc = 0; cc < COUT_TILE; cc = cc + 1) begin
                    gk = k_base + kk;
                    @(negedge clk);
                    wgt_tile_wr_en = 1'b1;
                    wgt_tile_wr_addr = kk*COUT_TILE + cc;
                    wgt_tile_wr_data = ((gk < K_TOTAL) && (co_base + cc < COUT_TOTAL)) ?
                                       weight[gk][co_base + cc] : 8'd0;
                end
            end
            @(negedge clk);
            wgt_tile_wr_en = 1'b0;
            weight_tile_ready = 1'b1;
            @(negedge clk);
            weight_tile_ready = 1'b0;
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
            write_row(feeder_fill_fy);
            @(posedge clk);
            #1;
        end
    end

    always @(posedge clk) begin
        if (!rst && final_valid) begin
            final_pkt[final_cout_base / COUT_TILE][final_addr] <= final_data;
            final_count <= final_count + 1;
        end
        if (!rst && ofm_valid)
            ofm_count <= ofm_count + 1;
        if (!rst && ofm_valid) begin
            for (b = 0; b < COUT_TILE; b = b + 1)
                if (ofm_channel_valid[b])
                    valid_ofm_lanes = valid_ofm_lanes + 1;
        end
        if (!rst && dut.u_top.feeder_ifm_valid)
            ifm_write_count <= ifm_write_count + 1;
        if (!rst && dut.compute_fire)
            compute_fire_count <= compute_fire_count + 1;
        if (!rst && dut.u_top.u_core.psum_fifo_wr_en[0])
            psum_wr_count <= psum_wr_count + 1;
        if (!rst && dut.drain_packet_fire)
            drain_capture_count <= drain_capture_count + 1;
    end

    always @(negedge clk) begin
        if (!rst && ofm_mem_wr_en) begin
            ofm_mem[ofm_mem_wr_addr] <= ofm_mem_wr_data;
            ofm_mem_wr_count <= ofm_mem_wr_count + 1;
        end
    end

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

        $display("=== tb_conv_layer_top_stream: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (12000) @(negedge clk);
        $display("[FAIL] timeout done=%0d busy=%0d final_count=%0d ofm_count=%0d ifm_wr=%0d fire=%0d psum_wr=%0d bias_req=%0d wgt_req=%0d fill_req=%0d cout=%0d k=%0d sched_state=%0d feeder_done=%0d compute_done=%0d drain_done=%0d drain_busy=%0d psum_empty=%h rd_en=%h wptr0=%0d rptr0=%0d empty0=%0d",
            done, busy, final_count, ofm_count, ifm_write_count, compute_fire_count, psum_wr_count,
            bias_load_req, weight_load_req, feeder_fill_req,
            current_cout_base, current_pass_base_k, dut.u_sched.state, dut.feeder_done, dut.compute_done, dut.drain_done,
            dut.u_drain.busy, dut.psum_fifo_empty, dut.psum_fifo_rd_en,
            dut.u_top.u_core.psum_fifo_gen[0].u_psum_fifo.wptr,
            dut.u_top.u_core.psum_fifo_gen[0].u_psum_fifo.rptr,
            dut.u_top.u_core.psum_fifo_gen[0].u_psum_fifo.empty);
        $fatal(1);
    end
endmodule

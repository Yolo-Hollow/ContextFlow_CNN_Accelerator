`timescale 1ns / 1ps

// Focused contract test for the single vector-replay request slot in
// systolic_top_feeder.  The tagged context frontend can reserve two epoch
// banks, but the external vector producer is driven by one level request.
// A second feeder start must therefore remain backpressured until the first
// packet completes and fill_req has been low for one real cycle.
module tb_systolic_top_feeder_vector_replay_ready;
    localparam integer ROWS = 2;
    localparam integer COLS = 2;
    localparam integer IFM_W = 8;
    localparam integer WEIGHT_W = 8;
    localparam integer PSUM_W = 32;
    localparam integer EPOCH_W = 8;
    localparam integer IFM_BANKS = 5;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg feeder_start = 1'b0;
    wire feeder_start_ready;
    wire feeder_done;
    wire feeder_busy;
    wire feeder_fill_req;

    reg [ROWS*IFM_W-1:0] vector_ifm_data = {ROWS*IFM_W{1'b0}};
    reg vector_ifm_valid = 1'b0;
    wire vector_ifm_ready;
    reg vector_packet_done = 1'b0;

    reg [IFM_BANKS-1:0] dma_bank_wr_en = {IFM_BANKS{1'b0}};
    reg [8:0] dma_wr_x = 9'd0;
    reg [9:0] dma_wr_fy = 10'd0;
    reg [7:0] dma_wr_data [0:IFM_BANKS-1];
    reg dma_line_advance = 1'b0;

    wire [31:0] tagged_datapath_error_status;
    wire [31:0] context_alloc_count;
    wire [31:0] context_fifo_drop_count;
    wire [ROWS-1:0] ifm_fifo_full;

    systolic_top_feeder #(
        .ROWS(ROWS), .COLS(COLS),
        .IFM_W(IFM_W), .WEIGHT_W(WEIGHT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(8), .IFM_FIFO_AW(3),
        .WGT_FIFO_DEPTH(8), .WGT_FIFO_AW(3),
        .PSUM_FIFO_DEPTH(8), .PSUM_FIFO_AW(3),
        .FM_W_MAX(2), .FM_H_MAX(2),
        .IFM_BANKS(IFM_BANKS),
        .ENABLE_TAGGED_CONTEXT(1),
        .ENABLE_WEIGHT_PRELOAD(0),
        .ENABLE_FAST_CONTEXT_HANDOFF(0),
        .ENABLE_VECTOR_ONLY_IFM(1),
        .IFM_EPOCH_USE_URAM(0),
        .EPOCH_W(EPOCH_W)
    ) dut (
        .clk(clk), .rst(rst),
        .feeder_start(feeder_start),
        .feeder_start_ready(feeder_start_ready),
        .feeder_done(feeder_done),
        .feeder_busy(feeder_busy),
        .feeder_fill_req(feeder_fill_req),
        .feeder_fill_fy(),
        .kernel_1x1(1'b1),
        .raw_hwc_mode(1'b1),
        .compute_start(1'b0),
        .num_pixels(16'd2),
        .tail_cycles_config(16'd0),
        .tagged_context_start_ready(1'b1),
        .tagged_context_admission_ready(1'b1),
        .raw_hwc_compute_start_level(16'd1),
        .feeder_compute_ready(),
        .compute_done(),
        .compute_fire_out(),
        .compute_context_start(),
        .compute_context_bank(),
        .compute_context_epoch(),
        .perf_feed_push(),
        .perf_feed_fifo_stall(),
        .perf_feed_win_not_ready(),
        .perf_comp_wload(),
        .perf_comp_active(),
        .perf_comp_ifm_stall(),
        .perf_comp_tail(),
        .perf_tail_cycles_configured(),
        .fm_h(9'd1), .fm_w(9'd2),
        .ofm_h(9'd1), .ofm_w(9'd2),
        .tile_oy_base(9'd0), .tile_ofm_h(9'd1),
        .conv_stride(2'd1), .conv_pad(2'd0),
        .pass_base_k(14'd0),
        .dma_bank_wr_en(dma_bank_wr_en),
        .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data),
        .dma_line_advance(dma_line_advance),
        .vector_ifm_data(vector_ifm_data),
        .vector_ifm_valid(vector_ifm_valid),
        .vector_ifm_ready(vector_ifm_ready),
        .vector_packet_done(vector_packet_done),
        .bias_wr_addr(6'd0), .bias_wr_data({PSUM_W{1'b0}}),
        .bias_wr_en(1'b0), .is_first_pass(1'b1),
        .psum_top_ext({COLS*2*PSUM_W{1'b0}}),
        .use_ext_psum(1'b0),
        .psum_stream_data({COLS*2*PSUM_W{1'b0}}),
        .psum_stream_valid(1'b0),
        .psum_stream_compute_ready(1'b1),
        .use_psum_stream(1'b0),
        .psum_column_stream_data({COLS*2*PSUM_W{1'b0}}),
        .psum_column_stream_valid({COLS{1'b0}}),
        .use_column_psum_stream(1'b0),
        .wgt_fifo_wr_en({ROWS{1'b0}}),
        .wgt_fifo_wr_data({ROWS*WEIGHT_W*2{1'b0}}),
        .weight_tile_complete(1'b0),
        .wgt_fifo_full(),
        .psum_fifo_rd_en(32'd0),
        .psum_fifo_rd_data(), .psum_fifo_rd_tag(),
        .psum_fifo_empty(), .psum_fifo_wr_en_dbg(),
        .ifm_fifo_full(ifm_fifo_full),
        .collector_done_valid(1'b0),
        .collector_done_epoch({EPOCH_W{1'b0}}),
        .tagged_datapath_error_status(tagged_datapath_error_status),
        .context_alloc_count(context_alloc_count),
        .context_input_issued_count(),
        .context_array_retired_count(),
        .context_collector_done_count(),
        .context_gap_cycles(),
        .ifm_ownership_stall_cycles(),
        .weight_ownership_stall_cycles(),
        .psum_credit_stall_cycles(),
        .context_epoch_mismatch_count(),
        .context_mismatch_count(),
        .context_ifm_underflow_count(),
        .context_psum_underflow_count(),
        .context_fifo_drop_count(context_fifo_drop_count),
        .context_bank_overwrite_count(),
        .context_full_stall_cycles()
    );

    always #5 clk = ~clk;

    integer checks = 0;
    integer failures = 0;
    integer cycle_count = 0;
    integer accepted_start_count = 0;
    integer packet_done_count = 0;
    integer feeder_done_count = 0;
    integer vector_fire_count = 0;
    integer blocked_start_cycles = 0;
    integer outstanding_packets = 0;
    integer last_packet_done_cycle = -1;
    reg saw_low_since_packet_done = 1'b0;

    task check;
        input condition;
        input [8*96-1:0] message;
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $display("[FAIL] cycle=%0d %0s", cycle_count, message);
            end
        end
    endtask

    // This monitor checks the handshake contract at the edge where the DUT
    // consumes each event.  feeder_fill_req is the pre-edge state here, so a
    // second start cannot be accepted on the old packet_done edge.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count = 0;
            accepted_start_count = 0;
            packet_done_count = 0;
            feeder_done_count = 0;
            vector_fire_count = 0;
            blocked_start_cycles = 0;
            outstanding_packets = 0;
            last_packet_done_cycle = -1;
            saw_low_since_packet_done = 1'b0;
        end else begin
            cycle_count = cycle_count + 1;

            if ((last_packet_done_cycle >= 0) && !feeder_fill_req)
                saw_low_since_packet_done = 1'b1;

            if (feeder_start && feeder_start_ready) begin
                if (accepted_start_count != 0) begin
                    check(last_packet_done_cycle >= 0,
                          "next start accepted before prior packet_done");
                    check(saw_low_since_packet_done || !feeder_fill_req,
                          "next start accepted without a low fill_req cycle");
                    check(cycle_count > last_packet_done_cycle,
                          "next start accepted on prior packet_done edge");
                end
                check(outstanding_packets == 0,
                      "more than one vector replay request became active");
                accepted_start_count = accepted_start_count + 1;
                outstanding_packets = outstanding_packets + 1;
                saw_low_since_packet_done = 1'b0;
            end

            if (feeder_start && !feeder_start_ready) begin
                blocked_start_cycles = blocked_start_cycles + 1;
                check(feeder_fill_req,
                      "start backpressured without an active fill request");
            end

            if (vector_ifm_valid && vector_ifm_ready)
                vector_fire_count = vector_fire_count + 1;

            if (feeder_fill_req && vector_packet_done) begin
                check(outstanding_packets == 1,
                      "packet_done has no matching accepted start");
                packet_done_count = packet_done_count + 1;
                outstanding_packets = outstanding_packets - 1;
                last_packet_done_cycle = cycle_count;
                saw_low_since_packet_done = 1'b0;
            end

            if (feeder_done)
                feeder_done_count = feeder_done_count + 1;
        end
    end

    task send_vector;
        input [ROWS*IFM_W-1:0] data;
        input last;
        begin
            @(negedge clk);
            vector_ifm_data = data;
            vector_ifm_valid = 1'b1;
            vector_packet_done = last;
            while (!vector_ifm_ready)
                @(negedge clk);
            @(posedge clk);
            #1;
            @(negedge clk);
            vector_ifm_valid = 1'b0;
            vector_packet_done = 1'b0;
        end
    endtask

    integer bank_idx;
    initial begin
        for (bank_idx = 0; bank_idx < IFM_BANKS;
             bank_idx = bank_idx + 1)
            dma_wr_data[bank_idx] = 8'd0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);
        #1;

        check(feeder_start_ready, "initial feeder start is ready");
        check(!feeder_fill_req, "initial fill request is low");

        // Accept packet zero.
        @(negedge clk);
        feeder_start = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        feeder_start = 1'b0;
        wait (feeder_fill_req);
        check(!feeder_start_ready,
              "busy vector replay removes feeder start readiness");

        // Present packet one's start early and hold it as a legal valid.  It
        // must remain backpressured, including on packet zero's done edge.
        @(negedge clk);
        feeder_start = 1'b1;
        repeat (2) begin
            @(posedge clk);
            #1;
            check(!feeder_start_ready,
                  "early next start remains backpressured");
        end

        send_vector(16'h1011, 1'b0);
        send_vector(16'h1213, 1'b1);

        // The held start may be accepted on the edge after the required low
        // interval.  It must not have been consumed on the old done edge.
        wait (accepted_start_count == 2);
        @(negedge clk);
        feeder_start = 1'b0;
        wait (feeder_fill_req);
        check(!feeder_start_ready,
              "second active replay also removes start readiness");

        send_vector(16'h2021, 1'b0);
        send_vector(16'h2223, 1'b1);

        wait (packet_done_count == 2);
        wait (feeder_done_count == 2);
        repeat (2) @(posedge clk);
        #1;

        check(accepted_start_count == 2,
              "exactly two feeder starts were accepted");
        check(packet_done_count == 2,
              "each accepted start has an independent packet_done");
        check(feeder_done_count == 2,
              "each packet_done produces one feeder_done pulse");
        check(vector_fire_count == 4,
              "both two-word packets transferred without loss");
        check(blocked_start_cycles >= 2,
              "early second start observed explicit backpressure");
        check(outstanding_packets == 0,
              "no vector replay request remains outstanding");
        check(!feeder_fill_req && !feeder_busy,
              "vector replay slot returns idle after packet two");
        // Both tagged context banks are intentionally left allocated because
        // this focused test never starts compute.  The outer replay slot is
        // idle here, while aggregate feeder_start_ready may correctly remain
        // low due to the independent context-queue capacity gate.
        check(context_alloc_count == 32'd2,
              "tagged frontend allocated one context per accepted start");
        check(context_fifo_drop_count == 32'd0,
              "backpressured start did not enter the frontend as a drop");
        check(tagged_datapath_error_status == 32'd0,
              "focused replay sequence has no tagged datapath error");

        $display("=== tb_systolic_top_feeder_vector_replay_ready: %0d pass, %0d fail ===",
                 checks - failures, failures);
        if (failures != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        repeat (500) @(posedge clk);
        $display("[FAIL] timeout accepted=%0d packet_done=%0d feeder_done=%0d fires=%0d fill_req=%0b ready=%0b",
                 accepted_start_count, packet_done_count,
                 feeder_done_count, vector_fire_count,
                 feeder_fill_req, feeder_start_ready);
        $fatal(1);
    end
endmodule

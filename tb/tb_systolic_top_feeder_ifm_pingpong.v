`timescale 1ns / 1ps

module tb_systolic_top_feeder_ifm_pingpong;
    localparam ROWS = 4;
    localparam COLS = 2;
    localparam IFM_W = 8;
    localparam WGT_W = 8;
    localparam PSUM_W = 32;
    localparam IFM_D = 16;
    localparam IFM_AW = 4;
    localparam WGT_D = 16;
    localparam WGT_AW = 4;
    localparam PSUM_D = 16;
    localparam PSUM_AW = 4;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg feeder_start = 1'b0;
    reg feeder_prefetch = 1'b0;
    reg compute_start = 1'b0;
    wire feeder_done;
    wire feeder_busy;
    wire feeder_fill_req;
    wire [8:0] feeder_fill_fy;
    wire feeder_compute_ready;
    wire compute_done;
    wire compute_fire;
    wire perf_comp_ifm_stall;
    wire [31:0] perf_tail_cycles_configured;
    reg [ROWS*IFM_W-1:0] vector_ifm_data = {ROWS*IFM_W{1'b0}};
    reg vector_ifm_valid = 1'b0;
    wire vector_ifm_ready;
    reg vector_packet_done = 1'b0;
    reg [4:0] dma_bank_wr_en = 5'd0;
    reg [8:0] dma_wr_x = 9'd0;
    reg [9:0] dma_wr_fy = 10'd0;
    reg [7:0] dma_wr_data [0:4];
    reg dma_line_advance = 1'b0;
    reg [5:0] bias_wr_addr = 6'd0;
    reg [PSUM_W-1:0] bias_wr_data = {PSUM_W{1'b0}};
    reg bias_wr_en = 1'b0;
    reg [ROWS-1:0] wgt_fifo_wr_en = {ROWS{1'b0}};
    reg [ROWS*WGT_W*2-1:0] wgt_fifo_wr_data = {ROWS*WGT_W*2{1'b0}};
    wire [ROWS-1:0] wgt_fifo_full;
    reg [31:0] psum_fifo_rd_en = 32'd0;
    wire [COLS*PSUM_W*2-1:0] psum_fifo_rd_data;
    wire [31:0] psum_fifo_empty;
    wire [ROWS-1:0] ifm_fifo_full;

    systolic_top_feeder #(
        .ROWS(ROWS), .COLS(COLS), .IFM_W(IFM_W), .WEIGHT_W(WGT_W), .PSUM_W(PSUM_W),
        .IFM_FIFO_DEPTH(IFM_D), .IFM_FIFO_AW(IFM_AW),
        .WGT_FIFO_DEPTH(WGT_D), .WGT_FIFO_AW(WGT_AW),
        .PSUM_FIFO_DEPTH(PSUM_D), .PSUM_FIFO_AW(PSUM_AW)
    ) dut (
        .clk(clk), .rst(rst),
        .feeder_start(feeder_start), .feeder_done(feeder_done),
        .feeder_busy(feeder_busy), .feeder_prefetch(feeder_prefetch),
        .feeder_fill_req(feeder_fill_req), .feeder_fill_fy(feeder_fill_fy),
        .kernel_1x1(1'b1), .raw_hwc_mode(1'b1), .ifm_pingpong_enable(1'b1),
        .compute_start(compute_start), .num_pixels(16'd8),
        .tail_cycles_config(16'd8), .raw_hwc_compute_start_level(16'd2),
        .feeder_compute_ready(feeder_compute_ready),
        .compute_done(compute_done), .compute_fire_out(compute_fire),
        .perf_feed_push(), .perf_feed_fifo_stall(),
        .perf_feed_win_not_ready(), .perf_comp_wload(),
        .perf_comp_active(), .perf_comp_ifm_stall(perf_comp_ifm_stall),
        .perf_comp_tail(), .perf_tail_cycles_configured(perf_tail_cycles_configured),
        .fm_h(9'd1), .fm_w(9'd8), .ofm_h(9'd1), .ofm_w(9'd8),
        .tile_oy_base(9'd0), .tile_ofm_h(9'd1),
        .conv_stride(2'd1), .conv_pad(2'd0), .pass_base_k(14'd0),
        .dma_bank_wr_en(dma_bank_wr_en), .dma_wr_x(dma_wr_x), .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data), .dma_line_advance(dma_line_advance),
        .vector_ifm_data(vector_ifm_data), .vector_ifm_valid(vector_ifm_valid),
        .vector_ifm_ready(vector_ifm_ready), .vector_packet_done(vector_packet_done),
        .bias_wr_addr(bias_wr_addr), .bias_wr_data(bias_wr_data), .bias_wr_en(bias_wr_en),
        .is_first_pass(1'b1), .psum_top_ext({COLS*2*PSUM_W{1'b0}}), .use_ext_psum(1'b0),
        .psum_stream_data({COLS*2*PSUM_W{1'b0}}), .psum_stream_valid(1'b0),
        .psum_stream_compute_ready(1'b1), .use_psum_stream(1'b0),
        .psum_column_stream_data({COLS*2*PSUM_W{1'b0}}),
        .psum_column_stream_valid({COLS{1'b0}}),
        .use_column_psum_stream(1'b0),
        .wgt_fifo_wr_en(wgt_fifo_wr_en), .wgt_fifo_wr_data(wgt_fifo_wr_data),
        .wgt_fifo_full(wgt_fifo_full),
        .psum_fifo_rd_en(psum_fifo_rd_en), .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_empty(psum_fifo_empty), .psum_fifo_wr_en_dbg(),
        .ifm_fifo_full(ifm_fifo_full)
    );

    always #5 clk = ~clk;

    integer pass = 0;
    integer fail = 0;
    integer i;

    task check;
        input cond;
        input [127:0] msg;
        begin
            if (!cond) begin
                $display("[FAIL] %0s", msg);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
        end
    endtask

    task pulse_feeder_start;
        input is_prefetch;
        begin
            @(negedge clk);
            feeder_prefetch = is_prefetch;
            feeder_start = 1'b1;
            @(negedge clk);
            feeder_start = 1'b0;
            feeder_prefetch = 1'b0;
        end
    endtask

    task pulse_compute_start;
        begin
            @(negedge clk);
            compute_start = 1'b1;
            @(negedge clk);
            compute_start = 1'b0;
        end
    endtask

    task push_vector;
        input integer value;
        input last;
        integer lane;
        begin
            for (lane = 0; lane < ROWS; lane = lane + 1)
                vector_ifm_data[lane*8 +: 8] = value[7:0] + lane[7:0];
            vector_packet_done = last;
            vector_ifm_valid = 1'b1;
            wait(vector_ifm_ready);
            @(negedge clk);
            vector_ifm_valid = 1'b0;
            vector_packet_done = 1'b0;
        end
    endtask

    initial begin
        for (i = 0; i < 5; i = i + 1)
            dma_wr_data[i] = 8'd0;

        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        pulse_feeder_start(1'b0);
        check(dut.ifm_wr_bank == 1'b0, "initial fill writes bank0");
        for (i = 0; i < 8; i = i + 1)
            push_vector(10 + i, i == 7);
        check(feeder_busy == 1'b0, "initial feeder packet completed");
        check(dut.ifm_bank_count0 == 16'd8, "bank0 received full packet");

        pulse_compute_start();
        @(posedge clk);
        check(dut.ifm_rd_bank == 1'b0, "first compute reads bank0");

        pulse_feeder_start(1'b1);
        check(dut.ifm_wr_bank == 1'b1, "prefetch writes inactive bank1");
        push_vector(40, 1'b0);
        push_vector(41, 1'b0);
        check(feeder_compute_ready == 1'b1, "prefetch bank reaches start level");

        wait(compute_done);
        pulse_compute_start();
        @(posedge clk);
        check(dut.ifm_rd_bank == 1'b1, "second compute swaps to prefetched bank1");
        check(feeder_busy == 1'b1, "prefetch can continue after bank swap");

        for (i = 2; i < 8; i = i + 1)
            push_vector(40 + i, i == 7);
        check(feeder_busy == 1'b0, "prefetch feeder packet completed");
        wait(dut.compute_inflight == 1'b0);
        check(perf_comp_ifm_stall == 1'b0, "no IFM stall after pingpong fill");

        $display("=== tb_systolic_top_feeder_ifm_pingpong: %0d pass, %0d fail ===",
                 pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (2000) @(negedge clk);
        $display("[FAIL] timeout feeder_busy=%0d compute_done=%0d rd_bank=%0d wr_bank=%0d",
                 feeder_busy, compute_done, dut.ifm_rd_bank, dut.ifm_wr_bank);
        $fatal(1);
    end
endmodule

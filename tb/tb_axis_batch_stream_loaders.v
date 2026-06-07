`timescale 1ns / 1ps

module tb_axis_batch_stream_loaders;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg stream_reset = 1'b0;
    reg bias_req = 1'b0;
    reg bias_valid = 1'b0;
    reg [63:0] bias_data = 64'd0;
    reg [7:0] bias_keep = 8'hff;
    reg bias_last = 1'b0;
    wire bias_ready;
    wire bias_done;
    wire bias_keep_error;
    wire bias_last_error;
    wire [31:0] bias_completed;

    reg ifm_req = 1'b0;
    reg [8:0] ifm_fy = 9'd0;
    reg ifm_valid = 1'b0;
    reg [63:0] ifm_data = 64'd0;
    reg [7:0] ifm_keep = 8'h1f;
    reg ifm_last = 1'b0;
    wire ifm_ready;
    wire ifm_keep_error;
    wire ifm_last_error;
    wire [31:0] ifm_completed;

    integer pass = 0;
    integer fail = 0;
    integer done_count = 0;
    integer line_count = 0;

    always #5 clk = ~clk;

    task check;
        input cond;
        input [255:0] msg;
        begin
            if (cond) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("[FAIL] %0s", msg);
            end
        end
    endtask

    task request_bias;
        begin
            @(negedge clk);
            bias_req = 1'b1;
            @(negedge clk);
            bias_req = 1'b0;
        end
    endtask

    task send_bias;
        input last;
        begin
            @(negedge clk);
            bias_valid = 1'b1;
            bias_last = last;
            wait(bias_ready);
            @(negedge clk);
            bias_valid = 1'b0;
            bias_last = 1'b0;
        end
    endtask

    task request_ifm;
        input [8:0] fy;
        begin
            @(negedge clk);
            ifm_fy = fy;
            ifm_req = 1'b1;
            @(negedge clk);
            ifm_req = 1'b0;
        end
    endtask

    task send_ifm;
        input last;
        begin
            @(negedge clk);
            ifm_valid = 1'b1;
            ifm_last = last;
            wait(ifm_ready);
            @(negedge clk);
            ifm_valid = 1'b0;
            ifm_last = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (bias_done)
            done_count = done_count + 1;
        if (dut_ifm.dma_line_advance)
            line_count = line_count + 1;
    end

    axis_bias_weight_loader #(
        .ROWS(2), .COLS(1), .BIAS_ADDR_W(2), .WGT_ADDR_W(3)
    ) dut_bw (
        .clk(clk), .rst(rst), .stream_reset(stream_reset),
        .batch_mode(1'b1), .bias_expected_packets(32'd2),
        .weight_expected_packets(32'd0),
        .bias_load_req(bias_req), .bias_s_axis_tready(bias_ready),
        .bias_s_axis_tvalid(bias_valid), .bias_s_axis_tdata(bias_data),
        .bias_s_axis_tkeep(bias_keep), .bias_s_axis_tlast(bias_last),
        .bias_load_done(bias_done), .bias_wr_en(), .bias_wr_addr(), .bias_wr_data(),
        .weight_load_req(1'b0), .weight_s_axis_tready(),
        .weight_s_axis_tvalid(1'b0), .weight_s_axis_tdata(64'd0),
        .weight_s_axis_tkeep(8'd0), .weight_s_axis_tlast(1'b0),
        .weight_tile_ready(), .wgt_tile_wr_en(), .wgt_tile_wr_addr(), .wgt_tile_wr_data(),
        .bias_tkeep_error(bias_keep_error), .bias_tlast_error(bias_last_error),
        .weight_tkeep_error(), .weight_tlast_error(),
        .bias_completed_packets(bias_completed), .weight_completed_packets()
    );

    axis_ifm_line_loader #(.AW(9), .BANKS(5)) dut_ifm (
        .clk(clk), .rst(rst), .stream_reset(stream_reset),
        .batch_mode(1'b1), .expected_packets(32'd2),
        .fm_w(9'd2), .fill_req(ifm_req), .fill_fy(ifm_fy),
        .input_zero_point(8'd0), .s_axis_tready(ifm_ready),
        .s_axis_tvalid(ifm_valid), .s_axis_tdata(ifm_data),
        .s_axis_tkeep(ifm_keep), .s_axis_tlast(ifm_last),
        .dma_bank_wr_en(), .dma_wr_x(), .dma_wr_fy(), .dma_wr_data(),
        .dma_line_advance(), .tkeep_error(ifm_keep_error),
        .tlast_error(ifm_last_error), .completed_packets(ifm_completed)
    );

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        stream_reset = 1'b1;
        @(negedge clk);
        stream_reset = 1'b0;

        @(negedge clk);
        bias_req = 1'b1;
        send_bias(1'b0);
        wait(bias_completed == 1);
        bias_valid = 1'b1;
        bias_last = 1'b0;
        repeat (3) @(negedge clk);
        check(!bias_ready, "held-high bias request does not rearm");
        check(bias_completed == 1, "held-high bias request does not consume next packet");
        bias_valid = 1'b0;
        bias_last = 1'b0;
        bias_req = 1'b0;
        request_bias();
        send_bias(1'b1);
        wait(bias_completed == 2);
        repeat (2) @(negedge clk);
        check(done_count == 2, "two bias packets completed");
        check(bias_completed == 2, "bias completed counter");
        check(!bias_keep_error, "batch bias TKEEP clean");
        check(!bias_last_error, "batch bias TLAST only on final packet");

        @(negedge clk);
        ifm_fy = 9'd3;
        ifm_req = 1'b1;
        send_ifm(1'b0);
        send_ifm(1'b0);
        wait(ifm_completed == 1);
        ifm_valid = 1'b1;
        ifm_last = 1'b0;
        repeat (3) @(negedge clk);
        check(!ifm_ready, "held-high IFM request does not rearm");
        check(ifm_completed == 1, "held-high IFM request does not consume next packet");
        ifm_valid = 1'b0;
        ifm_last = 1'b0;
        ifm_req = 1'b0;
        request_ifm(9'd4);
        send_ifm(1'b0);
        send_ifm(1'b1);
        wait(ifm_completed == 2);
        repeat (2) @(negedge clk);
        check(line_count == 2, "two IFM packets completed");
        check(ifm_completed == 2, "IFM completed counter");
        check(!ifm_keep_error, "batch IFM TKEEP clean");
        check(!ifm_last_error, "batch IFM TLAST only on final packet");

        $display("=== %m: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (2000) @(negedge clk);
        $display("[FAIL] timeout bias_completed=%0d ifm_completed=%0d bias_ready=%b ifm_ready=%b",
                 bias_completed, ifm_completed, bias_ready, ifm_ready);
        $fatal(1);
    end
endmodule

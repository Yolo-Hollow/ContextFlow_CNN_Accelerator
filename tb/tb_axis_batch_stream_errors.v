`timescale 1ns / 1ps

module tb_axis_batch_stream_errors;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg bias_req = 1'b0;
    reg bias_valid = 1'b0;
    reg bias_last = 1'b0;
    wire bias_ready;
    wire bias_last_error;

    reg ifm_req = 1'b0;
    reg ifm_valid = 1'b0;
    reg ifm_last = 1'b0;
    wire ifm_ready;
    wire ifm_last_error;

    integer pass = 0;
    integer fail = 0;

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

    axis_bias_weight_loader #(
        .ROWS(2), .COLS(1), .BIAS_ADDR_W(2), .WGT_ADDR_W(3)
    ) bias_dut (
        .clk(clk), .rst(rst), .stream_reset(1'b0),
        .batch_mode(1'b1), .bias_expected_packets(32'd2),
        .weight_expected_packets(32'd0),
        .bias_load_req(bias_req), .bias_s_axis_tready(bias_ready),
        .bias_s_axis_tvalid(bias_valid), .bias_s_axis_tdata(64'd0),
        .bias_s_axis_tkeep(8'hff), .bias_s_axis_tlast(bias_last),
        .bias_load_done(), .bias_wr_en(), .bias_wr_addr(), .bias_wr_data(),
        .weight_load_req(1'b0), .weight_s_axis_tready(),
        .weight_s_axis_tvalid(1'b0), .weight_s_axis_tdata(64'd0),
        .weight_s_axis_tkeep(8'd0), .weight_s_axis_tlast(1'b0),
        .weight_tile_ready(), .wgt_tile_wr_en(), .wgt_tile_wr_addr(), .wgt_tile_wr_data(),
        .bias_tkeep_error(), .bias_tlast_error(bias_last_error),
        .weight_tkeep_error(), .weight_tlast_error(),
        .bias_completed_packets(), .weight_completed_packets()
    );

    axis_ifm_line_loader #(.AW(9), .BANKS(5)) ifm_dut (
        .clk(clk), .rst(rst), .stream_reset(1'b0),
        .batch_mode(1'b1), .expected_packets(32'd1),
        .fm_w(9'd1), .fill_req(ifm_req), .fill_fy(9'd0),
        .input_zero_point(8'd0), .s_axis_tready(ifm_ready),
        .s_axis_tvalid(ifm_valid), .s_axis_tdata(64'd0),
        .s_axis_tkeep(8'h1f), .s_axis_tlast(ifm_last),
        .dma_bank_wr_en(), .dma_wr_x(), .dma_wr_fy(), .dma_wr_data(),
        .dma_line_advance(), .tkeep_error(),
        .tlast_error(ifm_last_error), .completed_packets()
    );

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;

        @(negedge clk);
        bias_req = 1'b1;
        @(negedge clk);
        bias_req = 1'b0;
        bias_valid = 1'b1;
        bias_last = 1'b1;
        wait(bias_ready);
        @(negedge clk);
        bias_valid = 1'b0;
        bias_last = 1'b0;
        repeat (2) @(negedge clk);
        check(bias_last_error, "early batch TLAST is rejected");

        @(negedge clk);
        ifm_req = 1'b1;
        @(negedge clk);
        ifm_req = 1'b0;
        ifm_valid = 1'b1;
        ifm_last = 1'b0;
        wait(ifm_ready);
        @(negedge clk);
        ifm_valid = 1'b0;
        repeat (2) @(negedge clk);
        check(ifm_last_error, "missing final batch TLAST is rejected");

        $display("=== %m: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

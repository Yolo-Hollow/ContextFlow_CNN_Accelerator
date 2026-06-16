`timescale 1ns / 1ps

module tb_coltrace_monitor;
    localparam COLS = 3;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg layer_start = 1'b0;
    reg layer_busy = 1'b0;
    reg trace_enable = 1'b1;
    reg trace_pass_start = 1'b0;
    reg [15:0] trace_num_pixels = 16'd2;
    reg [31:0] psum_fifo_wr_en = 32'd0;
    reg collector_trace_active = 1'b0;
    reg collector_trace_done = 1'b0;
    reg collector_read_wait = 1'b0;
    reg [31:0] collector_missing_mask = 32'd0;
    reg [4:0] selected_col = 5'd0;
    wire [31:0] selected_first_wr;
    wire [31:0] selected_last_wr;
    wire [31:0] selected_wr_count;
    wire [31:0] selected_empty_wait;
    wire [31:0] missing_mask_or;
    wire [31:0] missing_mask_first;
    wire [31:0] missing_mask_last;
    wire trace_valid;
    integer fail = 0;

    coltrace_monitor #(.COLS(COLS)) dut (
        .clk(clk), .rst(rst),
        .layer_start(layer_start), .layer_busy(layer_busy),
        .trace_enable(trace_enable),
        .trace_pass_start(trace_pass_start),
        .trace_num_pixels(trace_num_pixels),
        .psum_fifo_wr_en(psum_fifo_wr_en),
        .collector_trace_active(collector_trace_active),
        .collector_trace_done(collector_trace_done),
        .collector_read_wait(collector_read_wait),
        .collector_missing_mask(collector_missing_mask),
        .selected_col(selected_col),
        .selected_first_wr(selected_first_wr),
        .selected_last_wr(selected_last_wr),
        .selected_wr_count(selected_wr_count),
        .selected_empty_wait(selected_empty_wait),
        .missing_mask_or(missing_mask_or),
        .missing_mask_first(missing_mask_first),
        .missing_mask_last(missing_mask_last),
        .trace_valid(trace_valid)
    );

    always #5 clk = ~clk;

    task step;
        input [31:0] wr_en;
        input wait_en;
        input [31:0] missing;
        begin
            @(negedge clk);
            psum_fifo_wr_en = wr_en;
            collector_read_wait = wait_en;
            collector_missing_mask = missing;
            @(negedge clk);
            psum_fifo_wr_en = 32'd0;
            collector_read_wait = 1'b0;
            collector_missing_mask = 32'd0;
        end
    endtask

    task check;
        input [31:0] got;
        input [31:0] expected;
        input [127:0] name;
        begin
            if (got !== expected) begin
                $display("[FAIL] %0s got=%0d expected=%0d",
                         name, got, expected);
                fail = fail + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        layer_busy = 1'b1;
        layer_start = 1'b1;
        @(negedge clk);
        layer_start = 1'b0;
        trace_pass_start = 1'b1;
        @(negedge clk);
        trace_pass_start = 1'b0;
        collector_trace_active = 1'b1;

        step(32'b001, 1'b1, 32'b110);
        step(32'b011, 1'b1, 32'b100);
        step(32'b100, 1'b1, 32'b001);
        step(32'b110, 1'b0, 32'b000);

        collector_trace_done = 1'b1;
        @(negedge clk);
        collector_trace_done = 1'b0;
        collector_trace_active = 1'b0;

        selected_col = 5'd0;
        #1;
        check(selected_wr_count, 2, "col0 write count");
        check(selected_empty_wait, 1, "col0 empty wait");
        if (selected_last_wr <= selected_first_wr) begin
            $display("[FAIL] col0 timestamp ordering");
            fail = fail + 1;
        end

        selected_col = 5'd1;
        #1;
        check(selected_wr_count, 2, "col1 write count");
        check(selected_empty_wait, 1, "col1 empty wait");

        selected_col = 5'd2;
        #1;
        check(selected_wr_count, 2, "col2 write count");
        check(selected_empty_wait, 2, "col2 empty wait");
        check(missing_mask_or, 7, "missing mask or");
        check(missing_mask_first, 6, "missing mask first");
        check(missing_mask_last, 1, "missing mask last");
        check({31'd0, trace_valid}, 1, "trace valid");

        $display("=== tb_coltrace_monitor: %0d fail ===", fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

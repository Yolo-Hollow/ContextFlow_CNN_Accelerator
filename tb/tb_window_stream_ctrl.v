`timescale 1ns / 1ps

module tb_window_stream_ctrl;
    localparam AW = 4;

    reg clk, rst, start;
    reg [AW-1:0] start_oy, ofm_w;
    reg window_ready, ifm_fifo_full_any;
    wire active, ifm_push, row_done;
    wire [AW-1:0] oy, ox;

    window_stream_ctrl #(.AW(AW)) dut (
        .clk(clk), .rst(rst), .start(start),
        .start_oy(start_oy), .ofm_w(ofm_w),
        .window_ready(window_ready), .ifm_fifo_full_any(ifm_fifo_full_any),
        .active(active), .oy(oy), .ox(ox),
        .ifm_push(ifm_push), .row_done(row_done)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer push_idx;
    integer exp_ox [0:3];

    task expect_hold;
        input integer exp_x;
        begin
            @(negedge clk);
            if (ifm_push !== 1'b0) begin
                $display("[FAIL] unexpected push during hold ox=%0d", ox);
                fail = fail + 1;
            end else if (ox !== exp_x[AW-1:0]) begin
                $display("[FAIL] hold ox got=%0d exp=%0d", ox, exp_x);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        start = 0;
        start_oy = 2;
        ofm_w = 4;
        window_ready = 0;
        ifm_fifo_full_any = 0;
        pass = 0;
        fail = 0;
        push_idx = 0;
        exp_ox[0] = 0;
        exp_ox[1] = 1;
        exp_ox[2] = 2;
        exp_ox[3] = 3;

        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;

        if (active !== 1'b1 || oy !== 2 || ox !== 0) begin
            $display("[FAIL] start state active=%0d oy=%0d ox=%0d", active, oy, ox);
            fail = fail + 1;
        end else pass = pass + 1;

        expect_hold(0);
        window_ready = 1;
        ifm_fifo_full_any = 1;
        expect_hold(0);
        ifm_fifo_full_any = 0;
    end

    always @(posedge clk) begin
        if (ifm_push) begin
            if (push_idx >= 4) begin
                $display("[FAIL] unexpected extra push ox=%0d", ox);
                fail = fail + 1;
            end else if (oy !== 2 || ox !== exp_ox[push_idx][AW-1:0]) begin
                $display("[FAIL] push%0d got oy=%0d ox=%0d exp oy=2 ox=%0d",
                    push_idx, oy, ox, exp_ox[push_idx]);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
            push_idx = push_idx + 1;
        end
    end

    initial begin
        wait(row_done);
        @(negedge clk);
        if (push_idx != 4) begin
            $display("[FAIL] push count got=%0d exp=4", push_idx);
            fail = fail + 1;
        end else pass = pass + 1;
        if (active !== 1'b0) begin
            $display("[FAIL] active should drop after row_done");
            fail = fail + 1;
        end else pass = pass + 1;

        $display("=== tb_window_stream_ctrl: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (100) @(negedge clk);
        $display("[FAIL] timeout push_idx=%0d active=%0d oy=%0d ox=%0d row_done=%0d",
            push_idx, active, oy, ox, row_done);
        $fatal(1);
    end
endmodule

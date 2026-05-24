`timescale 1ns / 1ps

module tb_line_stream_ctrl;
    localparam AW = 4;

    reg clk, rst, start;
    reg [AW-1:0] fm_h, ofm_h;
    reg fill_done, compute_done;
    wire fill_req, compute_start, busy, done;
    wire [AW-1:0] fill_fy, compute_oy;

    line_stream_ctrl #(.AW(AW)) dut (
        .clk(clk), .rst(rst), .start(start),
        .fm_h(fm_h), .ofm_h(ofm_h),
        .fill_done(fill_done), .compute_done(compute_done),
        .fill_req(fill_req), .fill_fy(fill_fy),
        .compute_start(compute_start), .compute_oy(compute_oy),
        .busy(busy), .done(done)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer exp_fill [0:4];
    integer exp_compute [0:2];
    integer fill_idx, compute_idx;

    task check_fill;
        input integer exp;
        begin
            if (fill_fy !== exp[AW-1:0]) begin
                $display("[FAIL] fill_fy got=%0d exp=%0d", fill_fy, exp);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
        end
    endtask

    task check_compute;
        input integer exp;
        begin
            if (compute_oy !== exp[AW-1:0]) begin
                $display("[FAIL] compute_oy got=%0d exp=%0d", compute_oy, exp);
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
        fm_h = 5;
        ofm_h = 3;
        fill_done = 0;
        compute_done = 0;
        pass = 0;
        fail = 0;
        fill_idx = 0;
        compute_idx = 0;
        exp_fill[0] = 0;
        exp_fill[1] = 1;
        exp_fill[2] = 2;
        exp_fill[3] = 3;
        exp_fill[4] = 4;
        exp_compute[0] = 0;
        exp_compute[1] = 1;
        exp_compute[2] = 2;

        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
    end

    initial begin
        @(negedge rst);
        forever begin
            wait(fill_req);
            if (fill_idx >= 5) begin
                $display("[FAIL] unexpected fill request fy=%0d", fill_fy);
                fail = fail + 1;
            end else begin
                check_fill(exp_fill[fill_idx]);
                fill_idx = fill_idx + 1;
            end
            repeat (2) @(negedge clk);
            fill_done = 1;
            @(negedge clk);
            fill_done = 0;
            @(posedge clk);
            #1;
        end
    end

    initial begin
        @(negedge rst);
        forever begin
            @(posedge clk);
            if (compute_start) begin
                if (compute_idx >= 3) begin
                    $display("[FAIL] unexpected compute start oy=%0d", compute_oy);
                    fail = fail + 1;
                end else begin
                    check_compute(exp_compute[compute_idx]);
                    compute_idx = compute_idx + 1;
                end
                repeat (3) @(negedge clk);
                compute_done = 1;
                @(negedge clk);
                compute_done = 0;
            end
        end
    end

    initial begin
        repeat (200) @(negedge clk);
        $display("[FAIL] timeout fill_idx=%0d compute_idx=%0d busy=%0d done=%0d fill_req=%0d fill_fy=%0d compute_start=%0d compute_oy=%0d",
            fill_idx, compute_idx, busy, done, fill_req, fill_fy, compute_start, compute_oy);
        $fatal(1);
    end

    initial begin
        wait(done);
        @(negedge clk);
        if (fill_idx != 5) begin
            $display("[FAIL] fill count got=%0d exp=5", fill_idx);
            fail = fail + 1;
        end else pass = pass + 1;

        if (compute_idx != 3) begin
            $display("[FAIL] compute count got=%0d exp=3", compute_idx);
            fail = fail + 1;
        end else pass = pass + 1;

        if (busy !== 1'b0) begin
            $display("[FAIL] busy should be low at done");
            fail = fail + 1;
        end else pass = pass + 1;

        $display("=== tb_line_stream_ctrl: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

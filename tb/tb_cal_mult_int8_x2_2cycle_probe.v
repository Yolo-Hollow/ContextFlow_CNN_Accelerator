`timescale 1ns / 1ps

module tb_cal_mult_int8_x2_2cycle_probe;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg signed [7:0] a = 0;
    reg signed [7:0] b = 0;
    reg signed [7:0] c = 0;
    wire signed [15:0] old_ac;
    wire signed [15:0] old_bc;
    wire signed [15:0] fast_ac;
    wire signed [15:0] fast_bc;

    cal_mult_int8_x2 u_old (
        .clk(clk), .a(a), .b(b), .c(c), .ac(old_ac), .bc(old_bc)
    );
    cal_mult_int8_x2_2cycle u_fast (
        .clk(clk), .a(a), .b(b), .c(c), .ac(fast_ac), .bc(fast_bc)
    );

    integer failures = 0;
    integer checks = 0;
    integer idx;
    reg signed [15:0] expected_ac;
    reg signed [15:0] expected_bc;

    task check_held;
        input signed [7:0] ta;
        input signed [7:0] tb;
        input signed [7:0] tc;
        begin
            @(negedge clk);
            a = ta;
            b = tb;
            c = tc;
            repeat (6) @(posedge clk);
            #1;
            expected_ac = ta * tc;
            expected_bc = tb * tc;
            checks = checks + 1;
            if (old_ac !== expected_ac || old_bc !== expected_bc ||
                fast_ac !== expected_ac || fast_bc !== expected_bc ||
                fast_ac !== old_ac || fast_bc !== old_bc) begin
                $display("FAIL a=%0d b=%0d c=%0d old=%0d/%0d fast=%0d/%0d exp=%0d/%0d",
                    ta, tb, tc, old_ac, old_bc, fast_ac, fast_bc,
                    expected_ac, expected_bc);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        check_held(-8'sd128, -8'sd128, -8'sd128);
        check_held(-8'sd128,  8'sd127,  8'sd127);
        check_held( 8'sd127, -8'sd128, -8'sd1);
        check_held( 8'sd127,  8'sd127,  8'sd127);
        check_held( 8'sd0,    8'sd0,   -8'sd128);
        for (idx = 0; idx < 512; idx = idx + 1)
            check_held($random, $random, $random);

        if (failures == 0)
            $display("PASS: 2-cycle packed multiplier %0d bit-exact checks", checks);
        else begin
            $display("FAIL: 2-cycle packed multiplier failures=%0d/%0d",
                failures, checks);
            $fatal(1);
        end
        $finish;
    end
endmodule

// Requant direct testbench: exact three-enabled-cycle latency, one result per
// clock, per-packet quant parameters, saturation and global-ce stalls.
`timescale 1ns / 1ps

module tb_requant;
    localparam PSUM_W = 32;
    localparam MULT_W = 16;
    localparam SHIFT_W = 4;
    localparam ZP_W = 8;

    reg clk;
    reg rst;
    reg ce;
    reg [MULT_W-1:0] m0, m1;
    reg [SHIFT_W-1:0] s0, s1;
    reg [ZP_W-1:0] z0, z1;
    reg signed [PSUM_W-1:0] pa, pb;
    reg v;
    wire signed [7:0] oa, ob;
    wire vo;

    requant #(
        .PSUM_W(PSUM_W), .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W), .ZP_W(ZP_W)
    ) dut (
        .clk(clk), .rst(rst),
        .mult0(m0), .mult1(m1),
        .shift0(s0), .shift1(s1),
        .zp_out0(z0), .zp_out1(z1),
        .psuma_in(pa), .psumb_in(pb),
        .valid_in(v), .ce(ce),
        .ofm_a(oa), .ofm_b(ob), .valid_out(vo)
    );

    always #5 clk = ~clk;

    integer pass_count;
    integer fail_count;
    integer accepted_count;
    integer retired_count;
    integer case_index;

    function [7:0] golden;
        input signed [PSUM_W-1:0] psum;
        input [MULT_W-1:0] mult;
        input [SHIFT_W-1:0] shift;
        input [ZP_W-1:0] zp;
        reg signed [63:0] value;
        reg signed [63:0] rounding;
        integer effective_shift;
        begin
            effective_shift = shift + 15;
            value = psum * $signed({1'b0, mult});
            rounding = 64'sd1 <<< (effective_shift - 1);
            value = (value + rounding) >>> effective_shift;
            value = value + $signed({1'b0, zp});
            if (value > 127)
                golden = 8'd127;
            else if (value < -128)
                golden = 8'd128;
            else
                golden = value[7:0];
        end
    endfunction

    task check;
        input condition;
        input [1023:0] message;
        begin
            if (!condition) begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end else begin
                pass_count = pass_count + 1;
            end
        end
    endtask

    // Each case deliberately changes both lanes' quant parameters.  The
    // continuous burst therefore detects accidental use of live Stage-3
    // shift/zero-point inputs instead of the parameters captured with PSUM.
    task set_case;
        input integer which;
        begin
            case (which)
                0: begin
                    pa = -32'sd29; pb = 32'sd32;
                    m0 = 16'd32767; m1 = 16'd32767;
                    s0 = 4'd0; s1 = 4'd0; z0 = 8'd0; z1 = 8'd0;
                end
                1: begin
                    pa = 32'sd500000000; pb = -32'sd500000000;
                    m0 = 16'd32767; m1 = 16'd32767;
                    s0 = 4'd0; s1 = 4'd0; z0 = 8'd0; z1 = 8'd0;
                end
                2: begin
                    pa = -32'sd1510; pb = 32'sd581;
                    m0 = 16'd18055; m1 = 16'd18055;
                    s0 = 4'd7; s1 = 4'd7; z0 = 8'd75; z1 = 8'd75;
                end
                3: begin
                    pa = 32'sd0; pb = 32'sd0;
                    m0 = 16'd12345; m1 = 16'd23456;
                    s0 = 4'd12; s1 = 4'd14; z0 = 8'd50; z1 = 8'd100;
                end
                4: begin
                    pa = 32'sd250000; pb = -32'sd100000;
                    m0 = 16'd8191; m1 = 16'd16383;
                    s0 = 4'd9; s1 = 4'd11; z0 = 8'd17; z1 = 8'd31;
                end
                5: begin
                    pa = -32'sd128; pb = 32'sd127;
                    m0 = 16'd65535; m1 = 16'd1;
                    s0 = 4'd15; s1 = 4'd2; z0 = 8'd255; z1 = 8'd3;
                end
                6: begin
                    pa = 32'sd7654321; pb = -32'sd3456789;
                    m0 = 16'd31337; m1 = 16'd27183;
                    s0 = 4'd13; s1 = 4'd8; z0 = 8'd9; z1 = 8'd201;
                end
                7: begin
                    pa = -32'sd77777; pb = 32'sd88888;
                    m0 = 16'd22222; m1 = 16'd11111;
                    s0 = 4'd6; s1 = 4'd5; z0 = 8'd44; z1 = 8'd55;
                end
                8: begin
                    pa = 32'sd333333; pb = -32'sd444444;
                    m0 = 16'd54321; m1 = 16'd12345;
                    s0 = 4'd10; s1 = 4'd12; z0 = 8'd66; z1 = 8'd77;
                end
                default: begin
                    pa = -32'sd999; pb = 32'sd1234;
                    m0 = 16'd13579; m1 = 16'd24680;
                    s0 = 4'd4; s1 = 4'd9; z0 = 8'd88; z1 = 8'd99;
                end
            endcase
        end
    endtask

    // Independent enabled-cycle model of the three pipeline stages.
    reg exp_v1, exp_v2, exp_v3;
    reg [7:0] exp_a1, exp_a2, exp_a3;
    reg [7:0] exp_b1, exp_b2, exp_b3;
    localparam PROD_W = PSUM_W + MULT_W + 1;
    reg freeze_history_valid;
    reg signed [PROD_W:0] hold_prod0, hold_prod1;
    reg signed [PROD_W:0] hold_rounded0, hold_rounded1;
    reg [SHIFT_W:0] hold_shift0_r1, hold_shift1_r1;
    reg [SHIFT_W:0] hold_shift0_r2, hold_shift1_r2;
    reg [ZP_W-1:0] hold_zp0_r1, hold_zp1_r1;
    reg [ZP_W-1:0] hold_zp0_r2, hold_zp1_r2;
    reg hold_valid_r1, hold_valid_r2, hold_valid_r3;
    reg signed [7:0] hold_ofm_a, hold_ofm_b;

    always @(posedge clk) begin
        if (rst) begin
            exp_v1 = 1'b0;
            exp_v2 = 1'b0;
            exp_v3 = 1'b0;
            exp_a1 = 8'd0;
            exp_a2 = 8'd0;
            exp_a3 = 8'd0;
            exp_b1 = 8'd0;
            exp_b2 = 8'd0;
            exp_b3 = 8'd0;
            accepted_count = 0;
            retired_count = 0;
        end else if (ce) begin
            if (vo)
                retired_count = retired_count + 1;

            // Shift the test-only oracle from oldest to newest with blocking
            // assignments.  This is cycle-equivalent to an NBA pipeline but
            // avoids a Vivado 2022.2 O2 testbench optimization that can make
            // the data model advance one stage farther than its valid model.
            exp_v3 = exp_v2;
            exp_v2 = exp_v1;
            exp_a3 = exp_a2;
            exp_a2 = exp_a1;
            exp_b3 = exp_b2;
            exp_b2 = exp_b1;
            if (v) begin
                accepted_count = accepted_count + 1;
                exp_a1 = golden(pa, m0, s0, z0);
                exp_b1 = golden(pb, m1, s1, z1);
            end
            exp_v1 = v;
        end

        #1;
        if (!rst) begin
            if ((dut.valid_r1 !== exp_v1) ||
                (dut.valid_r2 !== exp_v2) ||
                (dut.valid_r3 !== exp_v3)) begin
                fail_count = fail_count + 1;
                $display("[FAIL] internal valid stages got=%0b/%0b/%0b exp=%0b/%0b/%0b",
                         dut.valid_r1, dut.valid_r2, dut.valid_r3,
                         exp_v1, exp_v2, exp_v3);
            end else begin
                pass_count = pass_count + 1;
            end
            if (vo !== exp_v3) begin
                fail_count = fail_count + 1;
                $display("[FAIL] valid latency/freeze got=%0b exp=%0b",
                         vo, exp_v3);
            end else begin
                pass_count = pass_count + 1;
            end
            if (exp_v3) begin
                if (oa !== exp_a3) begin
                    fail_count = fail_count + 1;
                    $display("[FAIL] lane A got=%0d exp=%0d", oa,
                             exp_a3);
                end else begin
                    pass_count = pass_count + 1;
                end
                if (ob !== exp_b3) begin
                    fail_count = fail_count + 1;
                    $display("[FAIL] lane B got=%0d exp=%0d", ob,
                             exp_b3);
                end else begin
                    pass_count = pass_count + 1;
                end
            end

            if (freeze_history_valid && !ce) begin
                if ((dut.prod0_r !== hold_prod0) ||
                    (dut.prod1_r !== hold_prod1) ||
                    (dut.effective_shift0_r1 !== hold_shift0_r1) ||
                    (dut.effective_shift1_r1 !== hold_shift1_r1) ||
                    (dut.zp_out0_r1 !== hold_zp0_r1) ||
                    (dut.zp_out1_r1 !== hold_zp1_r1) ||
                    (dut.valid_r1 !== hold_valid_r1) ||
                    (dut.rounded0_r !== hold_rounded0) ||
                    (dut.rounded1_r !== hold_rounded1) ||
                    (dut.effective_shift0_r2 !== hold_shift0_r2) ||
                    (dut.effective_shift1_r2 !== hold_shift1_r2) ||
                    (dut.zp_out0_r2 !== hold_zp0_r2) ||
                    (dut.zp_out1_r2 !== hold_zp1_r2) ||
                    (dut.valid_r2 !== hold_valid_r2) ||
                    (dut.ofm_a_r !== hold_ofm_a) ||
                    (dut.ofm_b_r !== hold_ofm_b) ||
                    (dut.valid_r3 !== hold_valid_r3)) begin
                    fail_count = fail_count + 1;
                    $display("[FAIL] requant internal state advanced while ce=0");
                end else begin
                    pass_count = pass_count + 1;
                end
            end

            hold_prod0 = dut.prod0_r;
            hold_prod1 = dut.prod1_r;
            hold_shift0_r1 = dut.effective_shift0_r1;
            hold_shift1_r1 = dut.effective_shift1_r1;
            hold_zp0_r1 = dut.zp_out0_r1;
            hold_zp1_r1 = dut.zp_out1_r1;
            hold_valid_r1 = dut.valid_r1;
            hold_rounded0 = dut.rounded0_r;
            hold_rounded1 = dut.rounded1_r;
            hold_shift0_r2 = dut.effective_shift0_r2;
            hold_shift1_r2 = dut.effective_shift1_r2;
            hold_zp0_r2 = dut.zp_out0_r2;
            hold_zp1_r2 = dut.zp_out1_r2;
            hold_valid_r2 = dut.valid_r2;
            hold_ofm_a = dut.ofm_a_r;
            hold_ofm_b = dut.ofm_b_r;
            hold_valid_r3 = dut.valid_r3;
            freeze_history_valid = 1'b1;
        end else begin
            freeze_history_valid = 1'b0;
        end
    end

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        ce = 1'b1;
        v = 1'b0;
        m0 = 0; m1 = 0; s0 = 0; s1 = 0; z0 = 0; z1 = 0;
        pa = 0; pb = 0;
        pass_count = 0;
        fail_count = 0;
        accepted_count = 0;
        retired_count = 0;
        freeze_history_valid = 1'b0;
        hold_prod0 = 0; hold_prod1 = 0;
        hold_rounded0 = 0; hold_rounded1 = 0;
        hold_shift0_r1 = 0; hold_shift1_r1 = 0;
        hold_shift0_r2 = 0; hold_shift1_r2 = 0;
        hold_zp0_r1 = 0; hold_zp1_r1 = 0;
        hold_zp0_r2 = 0; hold_zp1_r2 = 0;
        hold_valid_r1 = 0; hold_valid_r2 = 0; hold_valid_r3 = 0;
        hold_ofm_a = 0; hold_ofm_b = 0;

        repeat (3) @(negedge clk);
        rst = 1'b0;

        // Six back-to-back inputs: after the initial three enabled clocks,
        // valid_out must remain asserted and retire one result every clock.
        for (case_index = 0; case_index < 6; case_index = case_index + 1) begin
            set_case(case_index);
            v = 1'b1;
            @(negedge clk);
        end
        v = 1'b0;
        repeat (4) @(negedge clk);

        // Put two packets in flight, then hold a third valid input while ce
        // is low.  No stage may advance during these three stall cycles.
        set_case(6);
        v = 1'b1;
        @(negedge clk);
        set_case(7);
        @(negedge clk);
        set_case(8);
        ce = 1'b0;
        repeat (3) @(negedge clk);

        // Resume once: case 6 reaches the output and held case 8 is accepted.
        ce = 1'b1;
        @(negedge clk);

        // Stall with a valid result already at the output.  Case 9 remains
        // held at the input and output valid/data must stay bit-exact.
        set_case(9);
        ce = 1'b0;
        repeat (2) @(negedge clk);
        ce = 1'b1;
        @(negedge clk);
        v = 1'b0;
        repeat (5) @(negedge clk);

        if (accepted_count != 10)
            $display("[FAIL] accepted packets got=%0d exp=10",
                     accepted_count);
        check(accepted_count == 10, "ten packets accepted");
        if (retired_count != 10)
            $display("[FAIL] retired packets got=%0d exp=10",
                     retired_count);
        check(retired_count == 10, "ten packets retired");

        $display("=== tb_requant: %0d pass, %0d fail, accepted=%0d retired=%0d ===",
                 pass_count, fail_count, accepted_count, retired_count);
        if (fail_count != 0)
            $fatal(1);
        $finish;
    end

    initial begin
        repeat (200) @(negedge clk);
        $fatal(1, "tb_requant timeout");
    end
endmodule

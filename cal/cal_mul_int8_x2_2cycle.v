`timescale 1ns / 1ps

// Two-cycle packed signed int8 multiplier for the tagged mesh.  The packed
// pre-adder identity is identical to cal_mult_int8_x2_dsp; only the input/
// pre-adder pipeline is removed.  Keeping M and P registers gives one new
// result per cycle while cutting the mesh hop latency from four clocks to two.
(* use_dsp = "yes" *)
module cal_mult_int8_x2_dsp_2cycle (
    input  wire                    clk,
    input  wire signed [7:0]       a,
    input  wire signed [7:0]       b,
    input  wire signed [7:0]       c,
    output wire signed [15:0]      ac,
    output wire signed [15:0]      bc
);
    wire signed [26:0] a_port = {a[7], a, 18'd0};
    wire signed [26:0] d_port = {{19{b[7]}}, b};
    wire signed [17:0] b_port = {{10{c[7]}}, c};
    wire signed [26:0] packed_ad = a_port + d_port;

    reg signed [44:0] mult_q;
    reg signed [44:0] p_q;
    always @(posedge clk) begin
        mult_q <= packed_ad * b_port;
        p_q <= mult_q;
    end

    assign ac = p_q[33:18];
    assign bc = p_q[15:0];
endmodule

// Keep the packed-product sign correction outside the DSP-attributed module;
// otherwise Vivado can spend a second DSP on the conditional +1.
module cal_mult_int8_x2_2cycle (
    input  wire                    clk,
    input  wire signed [7:0]       a,
    input  wire signed [7:0]       b,
    input  wire signed [7:0]       c,
    output wire signed [15:0]      ac,
    output wire signed [15:0]      bc
);
    wire signed [15:0] ac_raw;
    wire signed [15:0] bc_raw;
    cal_mult_int8_x2_dsp_2cycle u_dsp (
        .clk(clk), .a(a), .b(b), .c(c), .ac(ac_raw), .bc(bc_raw)
    );
    assign ac = bc_raw[15] ? (ac_raw + 1'b1) : ac_raw;
    assign bc = bc_raw;
endmodule

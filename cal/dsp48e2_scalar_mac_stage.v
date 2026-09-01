`timescale 1ns / 1ps

// One signed int8 multiply/add stage of a scalar DSP48E2 cascade.
//
// The first stage adds the sign-extended 32-bit seed through C.  Every later
// stage adds the previous DSP's registered PCOUT.  AREG/BREG are deliberately
// bypassed, while MREG and PREG are enabled.  Consequently the first stage
// has two clocks of latency and each following PCIN/PCOUT stage adds one
// clock.  Data registers are not reset; validity is flushed by the enclosing
// lane, matching the reset style of the release datapath.
module dsp48e2_scalar_mac_stage #(
    parameter integer FIRST_STAGE = 0
) (
    input  wire                    clk,
    input  wire signed [7:0]       ifm_in,
    input  wire signed [7:0]       weight_in,
    input  wire signed [47:0]      seed_in,
    input  wire signed [47:0]      pcin,
    output wire signed [47:0]      p_out,
    output wire signed [47:0]      pcout
);
    // OPMODE fields are W/Z/Y/X.  X=01 and Y=01 select the multiplier
    // decomposition.  Z=011 selects C for row zero; Z=001 selects PCIN for
    // all remaining rows.
    localparam [8:0] MAC_OPMODE = FIRST_STAGE ?
        9'b000110101 : 9'b000010101;

    wire [29:0] a_port = {{22{ifm_in[7]}}, ifm_in};
    wire [17:0] b_port = {{10{weight_in[7]}}, weight_in};
    wire [47:0] p_wire;
    wire [47:0] pcout_wire;

    DSP48E2 #(
        .ACASCREG(0),
        .ADREG(0),
        .ALUMODEREG(0),
        .AMULTSEL("A"),
        .AREG(0),
        .A_INPUT("DIRECT"),
        .BCASCREG(0),
        .BMULTSEL("B"),
        .BREG(0),
        .B_INPUT("DIRECT"),
        .CARRYINREG(0),
        .CARRYINSELREG(0),
        .CREG(FIRST_STAGE),
        .DREG(0),
        .INMODEREG(0),
        .MREG(1),
        .OPMODEREG(0),
        .PREG(1),
        .USE_MULT("MULTIPLY"),
        .USE_PATTERN_DETECT("NO_PATDET"),
        .USE_SIMD("ONE48")
    ) u_dsp48e2 (
        .ACOUT(),
        .BCOUT(),
        .CARRYCASCOUT(),
        .CARRYOUT(),
        .MULTSIGNOUT(),
        .OVERFLOW(),
        .P(p_wire),
        .PATTERNBDETECT(),
        .PATTERNDETECT(),
        .PCOUT(pcout_wire),
        .UNDERFLOW(),
        .XOROUT(),

        .A(a_port),
        .ACIN(30'd0),
        .ALUMODE(4'b0000),
        .B(b_port),
        .BCIN(18'd0),
        .C(seed_in),
        .CARRYCASCIN(1'b0),
        .CARRYIN(1'b0),
        .CARRYINSEL(3'b000),
        .CEA1(1'b1),
        .CEA2(1'b1),
        .CEAD(1'b1),
        .CEALUMODE(1'b1),
        .CEB1(1'b1),
        .CEB2(1'b1),
        .CEC(1'b1),
        .CECARRYIN(1'b1),
        .CECTRL(1'b1),
        .CED(1'b1),
        .CEINMODE(1'b1),
        .CEM(1'b1),
        .CEP(1'b1),
        .CLK(clk),
        .D(27'd0),
        .INMODE(5'b00000),
        .MULTSIGNIN(1'b0),
        .OPMODE(MAC_OPMODE),
        .PCIN(pcin),
        .RSTA(1'b0),
        .RSTALLCARRYIN(1'b0),
        .RSTALUMODE(1'b0),
        .RSTB(1'b0),
        .RSTC(1'b0),
        .RSTCTRL(1'b0),
        .RSTD(1'b0),
        .RSTINMODE(1'b0),
        .RSTM(1'b0),
        .RSTP(1'b0)
    );

    assign p_out = p_wire;
    assign pcout = pcout_wire;
endmodule

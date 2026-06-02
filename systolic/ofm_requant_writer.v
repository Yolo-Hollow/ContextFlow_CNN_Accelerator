`timescale 1ns / 1ps
// Convert one final PSUM packet (COLS output-channel pairs) to INT8 OFM bytes.
module ofm_requant_writer #(
    parameter COLS = 32,
    parameter PSUM_W = 32,
    parameter MULT_W = 16,
    parameter SHIFT_W = 4,
    parameter ZP_W = 8,
    parameter ADDR_W = 10
) (
    input  clk,
    input  rst,

    input  packet_valid,
    output packet_ready,
    input  [ADDR_W-1:0] packet_addr,
    input  [10:0] packet_cout_base,
    input  [COLS*2-1:0] packet_channel_valid,
    input  [COLS*2*PSUM_W-1:0] packet_data,

    input  [COLS*2*MULT_W-1:0]  mult_flat,
    input  [COLS*2*SHIFT_W-1:0] shift_flat,
    input  [COLS*2*ZP_W-1:0]    zp_flat,

    output                      ofm_valid,
    input                       ofm_ready,
    output reg [ADDR_W-1:0]     ofm_addr,
    output reg [10:0]           ofm_cout_base,
    output reg [COLS*2-1:0]     ofm_channel_valid,
    output [COLS*2*8-1:0]       ofm_data
);
    wire ce = !ofm_valid || ofm_ready;
    assign packet_ready = ce;

    reg [ADDR_W-1:0] addr_r1;
    reg [10:0] cout_r1;
    reg [COLS*2-1:0] mask_r1;
    always @(posedge clk) begin
        if (rst) begin
            addr_r1 <= {ADDR_W{1'b0}};
            cout_r1 <= 11'd0;
            mask_r1 <= {COLS*2{1'b0}};
            ofm_addr <= {ADDR_W{1'b0}};
            ofm_cout_base <= 11'd0;
            ofm_channel_valid <= {COLS*2{1'b0}};
        end else if (ce) begin
            if (packet_valid) begin
                addr_r1 <= packet_addr;
                cout_r1 <= packet_cout_base;
                mask_r1 <= packet_channel_valid;
            end
            ofm_addr <= addr_r1;
            ofm_cout_base <= cout_r1;
            ofm_channel_valid <= mask_r1;
        end
    end

    wire [COLS-1:0] valid_vec;
    genvar c;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : rq_col
            wire signed [7:0] qa;
            wire signed [7:0] qb;
            requant #(.PSUM_W(PSUM_W), .MULT_W(MULT_W), .SHIFT_W(SHIFT_W), .ZP_W(ZP_W)) u_rq (
                .clk(clk),
                .rst(rst),
                .mult0(mult_flat[(2*c)*MULT_W +: MULT_W]),
                .mult1(mult_flat[(2*c+1)*MULT_W +: MULT_W]),
                .shift0(shift_flat[(2*c)*SHIFT_W +: SHIFT_W]),
                .shift1(shift_flat[(2*c+1)*SHIFT_W +: SHIFT_W]),
                .zp_out0(zp_flat[(2*c)*ZP_W +: ZP_W]),
                .zp_out1(zp_flat[(2*c+1)*ZP_W +: ZP_W]),
                .psuma_in(packet_data[(2*c)*PSUM_W +: PSUM_W]),
                .psumb_in(packet_data[(2*c+1)*PSUM_W +: PSUM_W]),
                .valid_in(packet_valid),
                .ce(ce),
                .ofm_a(qa),
                .ofm_b(qb),
                .valid_out(valid_vec[c])
            );
            assign ofm_data[(2*c)*8 +: 8] = qa;
            assign ofm_data[(2*c+1)*8 +: 8] = qb;
        end
    endgenerate

    assign ofm_valid = valid_vec[0];
endmodule

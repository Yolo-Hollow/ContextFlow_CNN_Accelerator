`timescale 1ns / 1ps

// Column-granular partial-PSUM reader.
//
// For full-packet partial feedback the old path reads one packet on each
// compute_fire and then skews each column by COL_DELAY cycles. This module
// performs the equivalent operation by delaying the read request per column.
// That makes the storage and future availability guard column-local.
module psum_column_stream_feeder #(
    parameter COLS      = 8,
    parameter DATA_W    = 64,
    parameter AW        = 10,
    parameter COL_DELAY = 4
) (
    input  clk,
    input  rst,
    input  start,
    input  compute_fire,

    input  use_ext_psum,
    input  rd_bank,
    input  overlap_guard_enable,
    input  [COLS*(AW+1)-1:0] available_count_flat,

    output [COLS-1:0]        rd_en,
    output                   rd_bank_out,
    output [COLS*AW-1:0]     rd_addr_flat,
    input  [COLS*DATA_W-1:0] rd_data_flat,
    input  [COLS-1:0]        rd_valid,

    output [COLS*DATA_W-1:0] psum_top_data_flat,
    output [COLS-1:0]        psum_top_valid,
    output                   psum_compute_ready,
    output                   psum_underflow,
    output                   psum_wait,
    output reg [AW-1:0]      pixel_addr
);
    wire [AW:0] pixel_addr_ext = {1'b0, pixel_addr};

    wire [COLS-1:0] col_available;
    genvar c;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : avail_gen
            wire [AW:0] available_count =
                available_count_flat[(c+1)*(AW+1)-1 -: (AW+1)];
            assign col_available[c] =
                !overlap_guard_enable || (pixel_addr_ext < available_count);
        end
    endgenerate

    assign psum_compute_ready = !use_ext_psum || (&col_available);
    assign psum_wait = use_ext_psum && !(&col_available);
    assign psum_underflow = use_ext_psum && compute_fire && !(&col_available);
    assign rd_bank_out = rd_bank;

    generate
        for (c = 0; c < COLS; c = c + 1) begin : rd_delay_gen
            localparam DELAY = c * COL_DELAY;
            wire fire_d;
            wire [AW-1:0] addr_d;

            com_shift_reg #(.DEPTH(DELAY), .WIDTH(1)) u_fire_delay (
                .clk(clk), .rst(rst),
                .si(compute_fire && use_ext_psum && (&col_available)),
                .so(fire_d)
            );

            com_shift_reg #(.DEPTH(DELAY), .WIDTH(AW)) u_addr_delay (
                .clk(clk), .rst(rst),
                .si(pixel_addr),
                .so(addr_d)
            );

            assign rd_en[c] = fire_d;
            assign rd_addr_flat[(c+1)*AW-1 -: AW] = addr_d;
            assign psum_top_data_flat[(c+1)*DATA_W-1 -: DATA_W] =
                rd_data_flat[(c+1)*DATA_W-1 -: DATA_W];
            assign psum_top_valid[c] = rd_valid[c];
        end
    endgenerate

    always @(posedge clk) begin
        if (rst)
            pixel_addr <= {AW{1'b0}};
        else if (start)
            pixel_addr <= {AW{1'b0}};
        else if (compute_fire && psum_compute_ready)
            pixel_addr <= pixel_addr + {{(AW-1){1'b0}}, 1'b1};
    end
endmodule

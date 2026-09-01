`timescale 1ns / 1ps

// Compact-tagged, dual-weight-bank variant of the fixed-latency systolic mesh.
// Only {bank,last} traverses the mesh.  Full epoch ownership and reconstruction
// remain centralized in systolic_top_tagged.
module systolic_array_tagged #(
    parameter ROWS     = 18,
    parameter COLS     = 8,
    parameter IFM_W    = 8,
    parameter WEIGHT_W = 8,
    parameter PSUM_W   = 32,
    parameter EPOCH_W  = 8,
    parameter TAG_W    = 2
) (
    input  wire                                 clk,
    input  wire                                 rst,
    input  wire                                 w_load,
    input  wire [4:0]                           w_col,
    input  wire                                 w_bank,
    input  wire [ROWS*WEIGHT_W*2-1:0]           w_row_data,

    input  wire [ROWS*IFM_W-1:0]                ifm_in_flat,
    input  wire [ROWS-1:0]                      valid_h_left,
    input  wire [ROWS*TAG_W-1:0]                tag_h_left_flat,

    input  wire [COLS*2*PSUM_W-1:0]             psum_top_flat,
    input  wire [COLS*2-1:0]                    valid_v_top,
    input  wire [COLS*TAG_W-1:0]                tag_v_top_flat,

    output wire [COLS*2*PSUM_W-1:0]             psum_bot_flat,
    output wire [COLS*2-1:0]                    valid_v_bot,
    output wire [COLS*TAG_W-1:0]                tag_v_bot_flat,

    output wire                                 tag_mismatch_event,
    output wire                                 weight_write_collision_event
);
    initial begin
        if (TAG_W != 2)
            $error("systolic_array_tagged requires the 2-bit {bank,last} mesh tag");
    end

    wire [(ROWS*COLS)*IFM_W-1:0] ifm_h_o;
    wire [(ROWS*COLS)*PSUM_W-1:0] psuma_o;
    wire [(ROWS*COLS)*PSUM_W-1:0] psumb_o;
    wire [(ROWS*COLS)-1:0] valid_h_o;
    wire [(ROWS*COLS)-1:0] valid_va_o;
    wire [(ROWS*COLS)-1:0] valid_vb_o;
    wire [(ROWS*COLS)*TAG_W-1:0] tag_h_o;
    wire [(ROWS*COLS)*TAG_W-1:0] tag_v_o;
    wire [(ROWS*COLS)-1:0] tag_mismatch_pe;
    wire [(ROWS*COLS)-1:0] weight_write_collision_pe;

    genvar r;
    genvar c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : row_blk
            for (c = 0; c < COLS; c = c + 1) begin : col_blk
                localparam integer PE_INDEX = r*COLS + c;
                wire signed [IFM_W-1:0] ifm_pe_in;
                wire signed [IFM_W-1:0] ifm_pe_out;
                wire valid_h_in;
                wire valid_h_out;
                wire [TAG_W-1:0] tag_h_in;
                wire [TAG_W-1:0] tag_h_out;
                wire signed [PSUM_W-1:0] psuma_pe_in;
                wire signed [PSUM_W-1:0] psumb_pe_in;
                wire signed [PSUM_W-1:0] psuma_pe_out;
                wire signed [PSUM_W-1:0] psumb_pe_out;
                wire valid_va_in;
                wire valid_vb_in;
                wire valid_va_out;
                wire valid_vb_out;
                wire [TAG_W-1:0] tag_v_in;
                wire [TAG_W-1:0] tag_v_out;

                if (c == 0) begin : ifm_src
                    assign ifm_pe_in = ifm_in_flat[(r+1)*IFM_W-1:r*IFM_W];
                    assign valid_h_in = valid_h_left[r];
                    assign tag_h_in = tag_h_left_flat[(r+1)*TAG_W-1:r*TAG_W];
                end else begin : ifm_chain
                    assign ifm_pe_in = ifm_h_o[(PE_INDEX)*IFM_W-1:(PE_INDEX-1)*IFM_W];
                    assign valid_h_in = valid_h_o[PE_INDEX-1];
                    assign tag_h_in = tag_h_o[(PE_INDEX)*TAG_W-1:(PE_INDEX-1)*TAG_W];
                end
                assign ifm_h_o[(PE_INDEX+1)*IFM_W-1:PE_INDEX*IFM_W] = ifm_pe_out;
                assign valid_h_o[PE_INDEX] = valid_h_out;
                assign tag_h_o[(PE_INDEX+1)*TAG_W-1:PE_INDEX*TAG_W] = tag_h_out;

                if (r == 0) begin : psum_src
                    assign psuma_pe_in = psum_top_flat[(2*c+1)*PSUM_W-1:2*c*PSUM_W];
                    assign psumb_pe_in = psum_top_flat[(2*c+2)*PSUM_W-1:(2*c+1)*PSUM_W];
                    assign valid_va_in = valid_v_top[2*c];
                    assign valid_vb_in = valid_v_top[2*c+1];
                    assign tag_v_in = tag_v_top_flat[(c+1)*TAG_W-1:c*TAG_W];
                end else begin : psum_chain
                    assign psuma_pe_in = psuma_o[((r-1)*COLS+c+1)*PSUM_W-1:((r-1)*COLS+c)*PSUM_W];
                    assign psumb_pe_in = psumb_o[((r-1)*COLS+c+1)*PSUM_W-1:((r-1)*COLS+c)*PSUM_W];
                    assign valid_va_in = valid_va_o[(r-1)*COLS+c];
                    assign valid_vb_in = valid_vb_o[(r-1)*COLS+c];
                    assign tag_v_in = tag_v_o[((r-1)*COLS+c+1)*TAG_W-1:((r-1)*COLS+c)*TAG_W];
                end
                assign psuma_o[(PE_INDEX+1)*PSUM_W-1:PE_INDEX*PSUM_W] = psuma_pe_out;
                assign psumb_o[(PE_INDEX+1)*PSUM_W-1:PE_INDEX*PSUM_W] = psumb_pe_out;
                assign valid_va_o[PE_INDEX] = valid_va_out;
                assign valid_vb_o[PE_INDEX] = valid_vb_out;
                assign tag_v_o[(PE_INDEX+1)*TAG_W-1:PE_INDEX*TAG_W] = tag_v_out;

                wire signed [WEIGHT_W-1:0] pe_w0 =
                    w_row_data[(r*2+1)*WEIGHT_W-1:r*2*WEIGHT_W];
                wire signed [WEIGHT_W-1:0] pe_w1 =
                    w_row_data[(r*2+2)*WEIGHT_W-1:(r*2+1)*WEIGHT_W];
                wire pe_w_load = w_load && (w_col == c[4:0]);

                systolic_pe_tagged #(
                    .IFM_W(IFM_W),
                    .WEIGHT_W(WEIGHT_W),
                    .PSUM_W(PSUM_W),
                    .EPOCH_W(EPOCH_W),
                    .TAG_W(TAG_W)
                ) u_pe (
                    .clk(clk),
                    .rst(rst),
                    .w_load(pe_w_load),
                    .w_bank(w_bank),
                    .w0_in(pe_w0),
                    .w1_in(pe_w1),
                    .ifm_in(ifm_pe_in),
                    .valid_in_h(valid_h_in),
                    .tag_in_h(tag_h_in),
                    .ifm_out(ifm_pe_out),
                    .valid_out_h(valid_h_out),
                    .tag_out_h(tag_h_out),
                    .psuma_in(psuma_pe_in),
                    .valid_in_va(valid_va_in),
                    .psumb_in(psumb_pe_in),
                    .valid_in_vb(valid_vb_in),
                    .tag_in_v(tag_v_in),
                    .psuma_out(psuma_pe_out),
                    .valid_out_va(valid_va_out),
                    .psumb_out(psumb_pe_out),
                    .valid_out_vb(valid_vb_out),
                    .tag_out_v(tag_v_out),
                    .tag_mismatch_event(tag_mismatch_pe[PE_INDEX]),
                    .weight_write_collision_event(weight_write_collision_pe[PE_INDEX])
                );
            end
        end
    endgenerate

    generate
        for (c = 0; c < COLS; c = c + 1) begin : psum_bot_blk
            localparam integer BOT_INDEX = (ROWS-1)*COLS+c;
            assign psum_bot_flat[(2*c+1)*PSUM_W-1:2*c*PSUM_W] =
                psuma_o[(BOT_INDEX+1)*PSUM_W-1:BOT_INDEX*PSUM_W];
            assign psum_bot_flat[(2*c+2)*PSUM_W-1:(2*c+1)*PSUM_W] =
                psumb_o[(BOT_INDEX+1)*PSUM_W-1:BOT_INDEX*PSUM_W];
            assign valid_v_bot[2*c] = valid_va_o[BOT_INDEX];
            assign valid_v_bot[2*c+1] = valid_vb_o[BOT_INDEX];
            assign tag_v_bot_flat[(c+1)*TAG_W-1:c*TAG_W] =
                tag_v_o[(BOT_INDEX+1)*TAG_W-1:BOT_INDEX*TAG_W];
        end
    endgenerate

    assign tag_mismatch_event = |tag_mismatch_pe;
    assign weight_write_collision_event = |weight_write_collision_pe;
endmodule

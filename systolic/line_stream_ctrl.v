`timescale 1ns / 1ps

// Conservative line-level scheduler for streaming a 3x3 convolution.
// For each output row, it requests any missing input rows required by
// fy = oy * stride + ky - pad before starting that row's window stream.
module line_stream_ctrl #(
    parameter AW = 9
) (
    input  clk,
    input  rst,
    input  start,
    input  [AW-1:0] fm_h,
    input  [AW-1:0] ofm_h,
    input  [AW-1:0] start_oy,
    input  [AW-1:0] tile_ofm_h,
    input  [1:0] stride,
    input  [1:0] pad,
    input  fill_done,
    input  compute_done,
    output reg fill_req,
    output reg [AW-1:0] fill_fy,
    output reg compute_start,
    output reg [AW-1:0] compute_oy,
    output reg busy,
    output reg done
);
    localparam ST_IDLE          = 3'd0;
    localparam ST_FILL_CHECK    = 3'd1;
    localparam ST_COMPUTE_START = 3'd2;
    localparam ST_COMPUTE_WAIT  = 3'd3;
    localparam ST_ADVANCE       = 3'd4;
    localparam ST_DONE          = 3'd5;

    reg [2:0] state;
    reg [AW-1:0] oy;
    reg [AW-1:0] line_fy [0:2];
    reg line_valid [0:2];
    reg [1:0] wr_ptr;

    wire [AW-1:0] active_tile_h = (tile_ofm_h == {AW{1'b0}}) ? ofm_h : tile_ofm_h;
    wire [AW-1:0] last_tile_oy = start_oy + active_tile_h - {{(AW-1){1'b0}}, 1'b1};
    wire last_oy = (oy == last_tile_oy);

    wire signed [AW+1:0] base_fy = $signed({1'b0, oy}) * $signed({{AW{1'b0}}, stride}) -
                                   $signed({{AW{1'b0}}, pad});
    wire signed [AW+1:0] req_fy0_s = base_fy;
    wire signed [AW+1:0] req_fy1_s = base_fy + 1;
    wire signed [AW+1:0] req_fy2_s = base_fy + 2;

    wire need_fy0 = (req_fy0_s >= 0) && (req_fy0_s < $signed({1'b0, fm_h}));
    wire need_fy1 = (req_fy1_s >= 0) && (req_fy1_s < $signed({1'b0, fm_h}));
    wire need_fy2 = (req_fy2_s >= 0) && (req_fy2_s < $signed({1'b0, fm_h}));
    wire have_fy0 = !need_fy0 ||
                    ((line_valid[0] && line_fy[0] == req_fy0_s[AW-1:0]) ||
                     (line_valid[1] && line_fy[1] == req_fy0_s[AW-1:0]) ||
                     (line_valid[2] && line_fy[2] == req_fy0_s[AW-1:0]));
    wire have_fy1 = !need_fy1 ||
                    ((line_valid[0] && line_fy[0] == req_fy1_s[AW-1:0]) ||
                     (line_valid[1] && line_fy[1] == req_fy1_s[AW-1:0]) ||
                     (line_valid[2] && line_fy[2] == req_fy1_s[AW-1:0]));
    wire have_fy2 = !need_fy2 ||
                    ((line_valid[0] && line_fy[0] == req_fy2_s[AW-1:0]) ||
                     (line_valid[1] && line_fy[1] == req_fy2_s[AW-1:0]) ||
                     (line_valid[2] && line_fy[2] == req_fy2_s[AW-1:0]));
    wire all_rows_ready = have_fy0 && have_fy1 && have_fy2;

    wire [AW-1:0] missing_fy =
        (!have_fy0 && need_fy0) ? req_fy0_s[AW-1:0] :
        (!have_fy1 && need_fy1) ? req_fy1_s[AW-1:0] :
        req_fy2_s[AW-1:0];

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            oy <= {AW{1'b0}};
            line_fy[0] <= {AW{1'b0}};
            line_fy[1] <= {AW{1'b0}};
            line_fy[2] <= {AW{1'b0}};
            line_valid[0] <= 1'b0;
            line_valid[1] <= 1'b0;
            line_valid[2] <= 1'b0;
            wr_ptr <= 2'd0;
            fill_req <= 1'b0;
            fill_fy <= {AW{1'b0}};
            compute_start <= 1'b0;
            compute_oy <= {AW{1'b0}};
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            fill_req <= 1'b0;
            compute_start <= 1'b0;
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        oy <= start_oy;
                        compute_oy <= start_oy;
                        line_valid[0] <= 1'b0;
                        line_valid[1] <= 1'b0;
                        line_valid[2] <= 1'b0;
                        wr_ptr <= 2'd0;
                        fill_fy <= {AW{1'b0}};
                        if (active_tile_h == {AW{1'b0}}) begin
                            state <= ST_DONE;
                        end else begin
                            state <= ST_FILL_CHECK;
                        end
                    end
                end

                ST_FILL_CHECK: begin
                    busy <= 1'b1;
                    if (fill_done) begin
                        line_fy[wr_ptr] <= fill_fy;
                        line_valid[wr_ptr] <= 1'b1;
                        wr_ptr <= (wr_ptr == 2'd2) ? 2'd0 : wr_ptr + 2'd1;
                    end else if (all_rows_ready) begin
                        state <= ST_COMPUTE_START;
                    end else begin
                        fill_req <= 1'b1;
                        fill_fy <= missing_fy;
                    end
                end

                ST_COMPUTE_START: begin
                    busy <= 1'b1;
                    compute_start <= 1'b1;
                    compute_oy <= oy;
                    state <= ST_COMPUTE_WAIT;
                end

                ST_COMPUTE_WAIT: begin
                    busy <= 1'b1;
                    compute_oy <= oy;
                    if (compute_done) begin
                        if (last_oy) begin
                            state <= ST_DONE;
                        end else begin
                            state <= ST_ADVANCE;
                        end
                    end
                end

                ST_ADVANCE: begin
                    busy <= 1'b1;
                    oy <= oy + {{(AW-1){1'b0}}, 1'b1};
                    compute_oy <= oy + {{(AW-1){1'b0}}, 1'b1};
                    state <= ST_FILL_CHECK;
                end

                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

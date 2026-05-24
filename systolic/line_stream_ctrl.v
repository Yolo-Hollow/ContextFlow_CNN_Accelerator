`timescale 1ns / 1ps

// Conservative line-level scheduler for streaming a 3x3 convolution.
// It fills the first three input rows, computes one output row, then
// prefetches the next input row only after the current output row completes.
module line_stream_ctrl #(
    parameter AW = 9
) (
    input  clk,
    input  rst,
    input  start,
    input  [AW-1:0] fm_h,
    input  [AW-1:0] ofm_h,
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
    localparam ST_FILL_INITIAL  = 3'd1;
    localparam ST_COMPUTE_START = 3'd2;
    localparam ST_COMPUTE_WAIT  = 3'd3;
    localparam ST_PREFETCH      = 3'd4;
    localparam ST_ADVANCE       = 3'd5;
    localparam ST_DONE          = 3'd6;

    reg [2:0] state;
    reg [AW-1:0] oy;
    reg [AW-1:0] next_initial_fy;
    reg [AW-1:0] prefetch_fy;

    wire initial_fill_last = (next_initial_fy == {{(AW-2){1'b0}}, 2'd2});
    wire last_oy = (oy == (ofm_h - {{(AW-1){1'b0}}, 1'b1}));
    wire [AW:0] oy_plus_three = {1'b0, oy} + {{(AW-1){1'b0}}, 2'd3};
    wire need_prefetch = (oy_plus_three < {1'b0, fm_h});

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            oy <= {AW{1'b0}};
            next_initial_fy <= {AW{1'b0}};
            prefetch_fy <= {AW{1'b0}};
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
                        oy <= {AW{1'b0}};
                        compute_oy <= {AW{1'b0}};
                        next_initial_fy <= {AW{1'b0}};
                        fill_fy <= {AW{1'b0}};
                        if (ofm_h == {AW{1'b0}}) begin
                            state <= ST_DONE;
                        end else begin
                            state <= ST_FILL_INITIAL;
                        end
                    end
                end

                ST_FILL_INITIAL: begin
                    busy <= 1'b1;
                    fill_req <= 1'b1;
                    fill_fy <= next_initial_fy;
                    if (fill_done) begin
                        if (initial_fill_last) begin
                            state <= ST_COMPUTE_START;
                        end else begin
                            next_initial_fy <= next_initial_fy + {{(AW-1){1'b0}}, 1'b1};
                            fill_fy <= next_initial_fy + {{(AW-1){1'b0}}, 1'b1};
                        end
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
                        end else if (need_prefetch) begin
                            prefetch_fy <= oy_plus_three[AW-1:0];
                            fill_fy <= oy_plus_three[AW-1:0];
                            state <= ST_PREFETCH;
                        end else begin
                            state <= ST_ADVANCE;
                        end
                    end
                end

                ST_PREFETCH: begin
                    busy <= 1'b1;
                    fill_req <= 1'b1;
                    fill_fy <= prefetch_fy;
                    if (fill_done) begin
                        state <= ST_ADVANCE;
                    end
                end

                ST_ADVANCE: begin
                    busy <= 1'b1;
                    oy <= oy + {{(AW-1){1'b0}}, 1'b1};
                    compute_oy <= oy + {{(AW-1){1'b0}}, 1'b1};
                    state <= ST_COMPUTE_START;
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

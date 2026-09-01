`timescale 1ns / 1ps

// Two-bank PSUM storage for K-tile feedback.
// The scheduler chooses which bank to read and which bank to write.
module psum_pingpong_buffer #(
    parameter DATA_W = 256,
    parameter DEPTH  = 16,
    parameter AW     = 4,
    // Tagged-context integrations already place a per-address committed-
    // credit and ownership scoreboard in front of this RAM.  In that mode,
    // statically remove the duplicate local bitmap and diagnostics while
    // preserving the same registered one-cycle RAM read interface.
    parameter EXTERNAL_CREDIT_GUARD = 0
) (
    input  clk,
    input  rst,

    // A context owner clears the destination bank before the first write of
    // a new context.  Each following address write atomically commits one
    // readable packet credit.
    input              clear_valid,
    input              clear_bank,

    input              wr_en,
    input              wr_bank,
    input  [AW-1:0]    wr_addr,
    input  [DATA_W-1:0] wr_data,

    input              rd_en,
    input              rd_bank,
    input  [AW-1:0]    rd_addr,
    output [DATA_W-1:0] rd_data,
    output reg         rd_valid,

    output [AW:0]      committed_count0,
    output [AW:0]      committed_count1,
    output reg         error_underflow,
    output reg         error_overwrite,
    output reg         error_bank_conflict
);
    localparam LANE_W = 64;
    localparam LANES = DATA_W / LANE_W;

    initial begin
        if ((DATA_W % LANE_W) != 0)
            $error("psum_pingpong_buffer DATA_W must be a multiple of 64");
    end

    wire [DATA_W-1:0] bank0_rd_data;
    wire [DATA_W-1:0] bank1_rd_data;
    reg rd_bank_q;

    // Case equality makes omitted legacy clear ports benign in simulation;
    // real integrations drive both ports explicitly.
    wire clear_fire = (clear_valid === 1'b1);
    wire wr_addr_valid = (wr_addr < DEPTH);
    wire rd_addr_valid = (rd_addr < DEPTH);
    wire rd_fire;

    generate
        if (EXTERNAL_CREDIT_GUARD != 0) begin : g_external_credit_guard
            // rd_en/wr_en are accepted handshakes from the external owner
            // scoreboard.  Clear only changes that scoreboard's ownership;
            // stale RAM payload remains masked by its committed credits.
            assign rd_fire = rd_en && rd_addr_valid;
            assign committed_count0 = {(AW+1){1'b0}};
            assign committed_count1 = {(AW+1){1'b0}};

            always @(posedge clk) begin
                if (rst) begin
                    error_underflow <= 1'b0;
                    error_overwrite <= 1'b0;
                    error_bank_conflict <= 1'b0;
                end else begin
                    error_underflow <= 1'b0;
                    error_overwrite <= 1'b0;
                    error_bank_conflict <= 1'b0;
                end
            end
        end else begin : g_internal_credit_guard
            reg [DEPTH-1:0] committed0_q;
            reg [DEPTH-1:0] committed1_q;
            reg [AW:0] committed_count0_q;
            reg [AW:0] committed_count1_q;
            wire rd_committed = rd_addr_valid &&
                (rd_bank ? committed1_q[rd_addr] : committed0_q[rd_addr]);
            wire wr_was_committed = wr_addr_valid &&
                (wr_bank ? committed1_q[wr_addr] : committed0_q[wr_addr]);
            wire wr_new_credit = wr_en && wr_addr_valid &&
                (!wr_was_committed ||
                 (clear_fire && (clear_bank == wr_bank)));

            assign rd_fire = rd_en && rd_committed;
            assign committed_count0 = committed_count0_q;
            assign committed_count1 = committed_count1_q;

            always @(posedge clk) begin
                if (rst) begin
                    committed0_q <= {DEPTH{1'b0}};
                    committed1_q <= {DEPTH{1'b0}};
                    committed_count0_q <= {(AW+1){1'b0}};
                    committed_count1_q <= {(AW+1){1'b0}};
                    error_underflow <= 1'b0;
                    error_overwrite <= 1'b0;
                    error_bank_conflict <= 1'b0;
                end else begin
                    if (clear_fire) begin
                        if (clear_bank) begin
                            committed1_q <= {DEPTH{1'b0}};
                            committed_count1_q <= {(AW+1){1'b0}};
                        end else begin
                            committed0_q <= {DEPTH{1'b0}};
                            committed_count0_q <= {(AW+1){1'b0}};
                        end
                    end

                    if (wr_en && wr_addr_valid) begin
                        if (wr_bank) begin
                            committed1_q[wr_addr] <= 1'b1;
                            if (wr_new_credit)
                                committed_count1_q <=
                                    (clear_fire && clear_bank) ?
                                    {{AW{1'b0}}, 1'b1} :
                                    committed_count1_q + 1'b1;
                        end else begin
                            committed0_q[wr_addr] <= 1'b1;
                            if (wr_new_credit)
                                committed_count0_q <=
                                    (clear_fire && !clear_bank) ?
                                    {{AW{1'b0}}, 1'b1} :
                                    committed_count0_q + 1'b1;
                        end
                    end

                    if (rd_en && !rd_committed)
                        error_underflow <= 1'b1;
                    if (wr_en && (!wr_addr_valid ||
                        (wr_was_committed &&
                         !(clear_fire && (clear_bank == wr_bank)))))
                        error_overwrite <= 1'b1;
                    if ((wr_en && rd_en && (wr_bank == rd_bank) &&
                         (wr_addr == rd_addr)) ||
                        (clear_fire && rd_en && (clear_bank == rd_bank)))
                        error_bank_conflict <= 1'b1;
                end
            end
        end
    endgenerate

    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : lane_mem
            (* ram_style = "block" *)
            reg [LANE_W-1:0] bank0 [0:DEPTH-1];
            (* ram_style = "block" *)
            reg [LANE_W-1:0] bank1 [0:DEPTH-1];
            reg [LANE_W-1:0] bank0_q;
            reg [LANE_W-1:0] bank1_q;

            // Preserve one read-enable decode beside each inferred RAM lane.
            // A shared decode otherwise spans every BRAM enable and creates a
            // long route from the owner/credit cone to the physical banks.
            // These aliases are combinationally identical to the original
            // conditions, so the registered read latency is unchanged.
            (* KEEP = "TRUE" *) wire bank0_read_fire_local;
            (* KEEP = "TRUE" *) wire bank1_read_fire_local;
            assign bank0_read_fire_local = rd_fire && !rd_bank;
            assign bank1_read_fire_local = rd_fire && rd_bank;

            always @(posedge clk) begin
                if (wr_en && wr_addr_valid && !wr_bank)
                    bank0[wr_addr] <= wr_data[(lane+1)*LANE_W-1 -: LANE_W];
                if (bank0_read_fire_local)
                    bank0_q <= bank0[rd_addr];
            end

            always @(posedge clk) begin
                if (wr_en && wr_addr_valid && wr_bank)
                    bank1[wr_addr] <= wr_data[(lane+1)*LANE_W-1 -: LANE_W];
                if (bank1_read_fire_local)
                    bank1_q <= bank1[rd_addr];
            end

            assign bank0_rd_data[(lane+1)*LANE_W-1 -: LANE_W] = bank0_q;
            assign bank1_rd_data[(lane+1)*LANE_W-1 -: LANE_W] = bank1_q;
        end
    endgenerate

    assign rd_data = rd_bank_q ? bank1_rd_data : bank0_rd_data;

    always @(posedge clk) begin
        if (rst) begin
            rd_valid <= 1'b0;
            rd_bank_q <= 1'b0;
        end else begin
            rd_valid <= rd_fire;
            if (rd_fire)
                rd_bank_q <= rd_bank;
        end
    end
endmodule

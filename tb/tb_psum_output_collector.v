`timescale 1ns / 1ps

module tb_psum_output_collector;
    localparam COLS = 2;
    localparam DATA_W = COLS*2*32;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg enable = 1'b1;
    reg ctx_valid = 1'b0;
    wire ctx_ready;
    reg [15:0] ctx_num_pixels = 16'd0;
    reg ctx_is_final = 1'b0;
    reg ctx_wr_bank = 1'b0;
    reg [10:0] ctx_cout_base = 11'd0;
    reg [10:0] ctx_cout_valid = 11'd0;
    reg ctx_trace_match = 1'b0;
    wire [31:0] rd_en;
    reg [DATA_W-1:0] rd_data = {DATA_W{1'b0}};
    reg [31:0] empty = 32'hffff_ffff;
    wire packet_valid;
    reg packet_ready = 1'b1;
    wire [3:0] packet_addr;
    wire [DATA_W-1:0] packet_data;
    wire packet_is_final;
    wire packet_wr_bank;
    wire [10:0] packet_cout_base;
    wire [10:0] packet_cout_valid;
    wire context_start, context_done, partial_done, final_done;
    integer fail = 0;
    integer partial_packets = 0;
    integer final_packets = 0;
    integer context_done_count = 0;
    integer source_value = 0;

    psum_output_collector #(
        .COLS(COLS), .PSUM_W(32), .ADDR_W(4), .CTX_DEPTH(4), .CTX_AW(2)
    ) dut (
        .clk(clk), .rst(rst), .enable(enable),
        .ctx_valid(ctx_valid), .ctx_ready(ctx_ready),
        .ctx_num_pixels(ctx_num_pixels), .ctx_is_final(ctx_is_final),
        .ctx_wr_bank(ctx_wr_bank), .ctx_cout_base(ctx_cout_base),
        .ctx_cout_valid(ctx_cout_valid),
        .ctx_trace_match(ctx_trace_match),
        .psum_fifo_rd_en(rd_en), .psum_fifo_rd_data(rd_data),
        .psum_fifo_empty(empty),
        .packet_valid(packet_valid), .packet_ready(packet_ready),
        .packet_addr(packet_addr), .packet_data(packet_data),
        .packet_is_final(packet_is_final), .packet_wr_bank(packet_wr_bank),
        .packet_cout_base(packet_cout_base),
        .packet_cout_valid(packet_cout_valid),
        .context_start(context_start), .context_done(context_done),
        .partial_done(partial_done), .final_done(final_done),
        .context_active(), .context_wr_bank(), .context_is_final(),
        .trace_context_active(), .trace_context_done(),
        .perf_context_push(), .perf_context_pop(),
        .perf_context_full_stall(), .perf_column_empty_wait()
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rd_en != 0)
            rd_data <= {4{source_value[31:0]}};
        if (rd_en != 0)
            source_value <= source_value + 1;
        if (packet_valid && packet_ready) begin
            if (packet_is_final)
                final_packets <= final_packets + 1;
            else
                partial_packets <= partial_packets + 1;
        end
        if (context_done)
            context_done_count <= context_done_count + 1;
    end

    task push_context;
        input [15:0] pixels;
        input is_final;
        input bank;
        input [10:0] cout_base;
        begin
            @(negedge clk);
            ctx_valid = 1'b1;
            ctx_num_pixels = pixels;
            ctx_is_final = is_final;
            ctx_wr_bank = bank;
            ctx_cout_base = cout_base;
            ctx_cout_valid = 11'd4;
            while (!ctx_ready) @(negedge clk);
            @(negedge clk);
            ctx_valid = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        empty = 32'hffff_fffc;
        push_context(16'd3, 1'b0, 1'b0, 11'd0);
        push_context(16'd2, 1'b0, 1'b1, 11'd0);
        push_context(16'd4, 1'b1, 1'b0, 11'd16);

        wait(final_packets == 1);
        packet_ready = 1'b0;
        repeat (4) @(negedge clk);
        if (!packet_valid || !packet_is_final) begin
            $display("[FAIL] final packet not held under backpressure");
            fail = fail + 1;
        end
        packet_ready = 1'b1;
        wait(context_done_count == 3);
        repeat (2) @(negedge clk);

        if (partial_packets != 5) begin
            $display("[FAIL] partial_packets=%0d expected=5", partial_packets);
            fail = fail + 1;
        end
        if (final_packets != 4) begin
            $display("[FAIL] final_packets=%0d expected=4", final_packets);
            fail = fail + 1;
        end
        $display("=== tb_psum_output_collector: %0d fail ===", fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (500) @(negedge clk);
        $fatal(1, "[FAIL] timeout partial=%0d final=%0d done=%0d",
               partial_packets, final_packets, context_done_count);
    end
endmodule

`timescale 1ns / 1ps

module tb_ofm_packet_fifo;
    localparam COUT_TILE = 8;
    localparam ADDR_W = 4;
    localparam DEPTH = 4;
    localparam AW = 2;

    reg clk, rst;
    reg in_valid;
    wire in_ready;
    reg [ADDR_W-1:0] in_addr;
    reg [10:0] in_cout_base;
    reg [COUT_TILE-1:0] in_channel_valid;
    reg [COUT_TILE*8-1:0] in_data;
    wire out_valid;
    reg out_ready;
    wire [ADDR_W-1:0] out_addr;
    wire [10:0] out_cout_base;
    wire [COUT_TILE-1:0] out_channel_valid;
    wire [COUT_TILE*8-1:0] out_data;
    wire full;
    wire almost_full;

    ofm_packet_fifo #(
        .COUT_TILE(COUT_TILE), .ADDR_W(ADDR_W), .DEPTH(DEPTH), .AW(AW)
    ) dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_addr(in_addr), .in_cout_base(in_cout_base),
        .in_channel_valid(in_channel_valid), .in_data(in_data),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_addr(out_addr), .out_cout_base(out_cout_base),
        .out_channel_valid(out_channel_valid), .out_data(out_data),
        .full(full), .almost_full(almost_full)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer i, lane, pop_count;

    task push_packet;
        input integer id;
        begin
            @(negedge clk);
            if (!in_ready) begin
                $display("[FAIL] in_ready low before push%0d", id);
                fail = fail + 1;
            end
            in_valid = 1'b1;
            in_addr = id[ADDR_W-1:0];
            in_cout_base = 11'd16 + id[10:0];
            in_channel_valid = 8'hf0 | id[7:0];
            for (lane = 0; lane < COUT_TILE; lane = lane + 1)
                in_data[lane*8 +: 8] = id*16 + lane;
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task drive_packet;
        input integer id;
        begin
            in_valid = 1'b1;
            in_addr = id[ADDR_W-1:0];
            in_cout_base = 11'd16 + id[10:0];
            in_channel_valid = 8'hf0 | id[7:0];
            for (lane = 0; lane < COUT_TILE; lane = lane + 1)
                in_data[lane*8 +: 8] = id*16 + lane;
        end
    endtask

    always @(posedge clk) begin
        if (!rst && out_valid && out_ready) begin
            if (out_addr !== pop_count[ADDR_W-1:0] ||
                out_cout_base !== 11'd16 + pop_count ||
                out_channel_valid !== (8'hf0 | pop_count[7:0])) begin
                $display("[FAIL] pop%0d metadata addr=%0d cout=%0d mask=%h",
                    pop_count, out_addr, out_cout_base, out_channel_valid);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
            for (lane = 0; lane < COUT_TILE; lane = lane + 1) begin
                if (out_data[lane*8 +: 8] !== (pop_count*16 + lane)) begin
                    $display("[FAIL] pop%0d lane%0d got=%0d exp=%0d",
                        pop_count, lane, out_data[lane*8 +: 8], pop_count*16 + lane);
                    fail = fail + 1;
                end else begin
                    pass = pass + 1;
                end
            end
            pop_count <= pop_count + 1;
        end
    end

    initial begin
        clk = 0;
        rst = 1;
        in_valid = 0;
        in_addr = 0;
        in_cout_base = 0;
        in_channel_valid = 0;
        in_data = 0;
        out_ready = 0;
        pass = 0;
        fail = 0;
        pop_count = 0;

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        for (i = 0; i < DEPTH; i = i + 1)
            push_packet(i);

        if (!full || in_ready) begin
            $display("[FAIL] FIFO should be full full=%0d in_ready=%0d", full, in_ready);
            fail = fail + 1;
        end else pass = pass + 1;

        repeat (3) @(negedge clk);
        if (pop_count != 0) begin
            $display("[FAIL] popped while out_ready=0 count=%0d", pop_count);
            fail = fail + 1;
        end else pass = pass + 1;

        out_ready = 1'b1;
        wait(pop_count == DEPTH);
        @(negedge clk);
        if (out_valid !== 1'b0 || full !== 1'b0) begin
            $display("[FAIL] FIFO should drain valid=%0d full=%0d", out_valid, full);
            fail = fail + 1;
        end else pass = pass + 1;

        pop_count = 0;
        repeat (2) @(negedge clk);

        for (i = 0; i < DEPTH; i = i + 1)
            push_packet(i);

        out_ready = 1'b1;
        for (i = DEPTH; i < DEPTH + 12; i = i + 1) begin
            @(negedge clk);
            if (!in_ready) begin
                $display("[FAIL] in_ready should allow same-cycle push/pop at i=%0d", i);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
            drive_packet(i);
        end
        @(negedge clk);
        in_valid = 1'b0;
        wait(pop_count == DEPTH + 12);
        @(negedge clk);
        out_ready = 1'b0;
        if (out_valid !== 1'b0 || full !== 1'b0) begin
            $display("[FAIL] FIFO should drain after same-cycle stream valid=%0d full=%0d", out_valid, full);
            fail = fail + 1;
        end else pass = pass + 1;

        $display("=== tb_ofm_packet_fifo: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (200) @(negedge clk);
        $display("[FAIL] timeout pop_count=%0d valid=%0d ready=%0d full=%0d",
            pop_count, out_valid, out_ready, full);
        $fatal(1);
    end
endmodule

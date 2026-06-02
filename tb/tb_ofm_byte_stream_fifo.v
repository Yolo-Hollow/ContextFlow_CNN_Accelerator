`timescale 1ns / 1ps

module tb_ofm_byte_stream_fifo;
    localparam ADDR_W = 12;
    localparam DEPTH = 4;
    localparam AW = 2;

    reg clk, rst;
    reg wr_en;
    wire wr_ready;
    reg [ADDR_W-1:0] wr_addr;
    reg [7:0] wr_data;
    wire m_valid;
    reg m_ready;
    wire [ADDR_W-1:0] m_addr;
    wire [7:0] m_data;
    wire full;
    wire almost_full;

    ofm_byte_stream_fifo #(.ADDR_W(ADDR_W), .DEPTH(DEPTH), .AW(AW)) dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_ready(wr_ready),
        .wr_addr(wr_addr), .wr_data(wr_data),
        .m_valid(m_valid), .m_ready(m_ready),
        .m_addr(m_addr), .m_data(m_data), .full(full), .almost_full(almost_full)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer i, pop_count;
    integer seq_push;
    integer seq_exp;

    task push_word;
        input integer addr;
        input integer data;
        begin
            @(negedge clk);
            if (!wr_ready) begin
                $display("[FAIL] wr_ready low before push addr=%0d", addr);
                fail = fail + 1;
            end
            wr_addr = addr[ADDR_W-1:0];
            wr_data = data[7:0];
            wr_en = 1'b1;
            @(negedge clk);
            wr_en = 1'b0;
        end
    endtask

    task drive_stream_word;
        input integer addr;
        input integer data;
        begin
            wr_addr = addr[ADDR_W-1:0];
            wr_data = data[7:0];
            wr_en = 1'b1;
        end
    endtask

    always @(posedge clk) begin
        if (!rst && m_valid && m_ready) begin
            if (m_addr !== (12'h120 + pop_count) || m_data !== (8'h40 + pop_count)) begin
                $display("[FAIL] pop%0d got addr=%0h data=%0h exp addr=%0h data=%0h",
                    pop_count, m_addr, m_data, 12'h120 + pop_count, 8'h40 + pop_count);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
            pop_count <= pop_count + 1;
        end
    end

    initial begin
        clk = 0;
        rst = 1;
        wr_en = 0;
        wr_addr = 0;
        wr_data = 0;
        m_ready = 0;
        pass = 0;
        fail = 0;
        pop_count = 0;
        seq_push = 0;
        seq_exp = 0;

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        for (i = 0; i < DEPTH; i = i + 1)
            push_word(12'h120 + i, 8'h40 + i);

        if (!full || wr_ready) begin
            $display("[FAIL] FIFO should be full full=%0d wr_ready=%0d", full, wr_ready);
            fail = fail + 1;
        end else pass = pass + 1;

        repeat (3) @(negedge clk);
        if (pop_count != 0) begin
            $display("[FAIL] FIFO popped while m_ready=0 count=%0d", pop_count);
            fail = fail + 1;
        end else pass = pass + 1;

        m_ready = 1'b1;
        wait(pop_count == DEPTH);
        @(negedge clk);
        if (m_valid !== 1'b0 || full !== 1'b0) begin
            $display("[FAIL] FIFO should drain valid=%0d full=%0d", m_valid, full);
            fail = fail + 1;
        end else pass = pass + 1;

        pop_count = 0;
        repeat (2) @(negedge clk);

        for (i = 0; i < DEPTH; i = i + 1)
            push_word(12'h120 + i, 8'h40 + i);

        m_ready = 1'b1;
        for (i = DEPTH; i < DEPTH + 12; i = i + 1) begin
            @(negedge clk);
            if (!wr_ready) begin
                $display("[FAIL] wr_ready should allow same-cycle push/pop at i=%0d", i);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
            drive_stream_word(12'h120 + i, 8'h40 + i);
        end
        @(negedge clk);
        wr_en = 1'b0;
        wait(pop_count == DEPTH + 12);
        @(negedge clk);
        m_ready = 1'b0;
        if (m_valid !== 1'b0 || full !== 1'b0) begin
            $display("[FAIL] FIFO should drain after same-cycle stream valid=%0d full=%0d", m_valid, full);
            fail = fail + 1;
        end else pass = pass + 1;

        $display("=== tb_ofm_byte_stream_fifo: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (200) @(negedge clk);
        $display("[FAIL] timeout pop_count=%0d valid=%0d ready=%0d full=%0d",
            pop_count, m_valid, m_ready, full);
        $fatal(1);
    end
endmodule

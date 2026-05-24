`timescale 1ns / 1ps

module tb_psum_drain_writer;
    localparam COLS = 4;
    localparam PSUM_W = 32;
    localparam AW = 4;
    localparam DATA_W = COLS * PSUM_W * 2;
    localparam [31:0] COL_MASK = (32'h1 << COLS) - 1;

    reg clk, rst, start, is_final_pass;
    reg [15:0] num_pixels;
    reg [PSUM_W-1:0] baseline_col0;
    wire busy, done;
    wire [31:0] psum_fifo_rd_en;
    reg [DATA_W-1:0] psum_fifo_rd_data;
    reg [31:0] psum_fifo_empty;
    wire packet_valid;
    wire [AW-1:0] packet_addr;
    wire [DATA_W-1:0] packet_data;
    wire packet_is_final;

    psum_drain_writer #(.COLS(COLS), .PSUM_W(PSUM_W), .AW(AW)) dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done),
        .num_pixels(num_pixels), .baseline_col0(baseline_col0), .is_final_pass(is_final_pass),
        .psum_fifo_rd_en(psum_fifo_rd_en), .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_empty(psum_fifo_empty),
        .packet_valid(packet_valid), .packet_addr(packet_addr),
        .packet_data(packet_data), .packet_is_final(packet_is_final)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer rd_count, pkt_count, c;
    reg [DATA_W-1:0] source_pkt [0:4];
    reg [DATA_W-1:0] expected_pkt [0:2];

    task put_word;
        input integer pkt;
        input integer lane;
        input [PSUM_W-1:0] value;
        begin
            source_pkt[pkt][lane*PSUM_W +: PSUM_W] = value;
        end
    endtask

    task check_equal;
        input integer got;
        input integer exp;
        input [127:0] name;
        begin
            if (got !== exp) begin
                $display("[FAIL] %0s got=%0d exp=%0d", name, got, exp);
                fail = fail + 1;
            end else pass = pass + 1;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            rd_count <= 0;
            psum_fifo_rd_data <= 0;
        end else if (psum_fifo_rd_en == COL_MASK) begin
            psum_fifo_rd_data <= source_pkt[rd_count];
            rd_count <= rd_count + 1;
        end
    end

    always @(posedge clk) begin
        if (!rst && packet_valid) begin
            if (packet_data !== expected_pkt[pkt_count]) begin
                $display("[FAIL] packet%0d data mismatch", pkt_count);
                fail = fail + 1;
            end else pass = pass + 1;
            check_equal(packet_addr, pkt_count, "packet addr");
            check_equal(packet_is_final, 1, "packet final");
            pkt_count = pkt_count + 1;
        end
    end

    initial begin
        clk = 0;
        rst = 1;
        start = 0;
        is_final_pass = 1'b1;
        num_pixels = 16'd3;
        baseline_col0 = 32'd100;
        psum_fifo_empty = 32'hffff_ffff;
        pass = 0;
        fail = 0;
        pkt_count = 0;

        for (c = 0; c < 5; c = c + 1)
            source_pkt[c] = 0;

        put_word(0, 0, 32'd100);
        put_word(0, 1, 32'd101);
        put_word(1, 0, 32'd11);
        put_word(1, 1, 32'd12);
        put_word(2, 0, 32'd100);
        put_word(2, 1, 32'd200);
        put_word(3, 0, 32'd21);
        put_word(3, 1, 32'd22);
        put_word(4, 0, 32'd31);
        put_word(4, 1, 32'd32);

        expected_pkt[0] = source_pkt[1];
        expected_pkt[1] = source_pkt[3];
        expected_pkt[2] = source_pkt[4];

        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        repeat (2) @(negedge clk);
        psum_fifo_empty = ~COL_MASK;

        wait(done);
        repeat (2) @(negedge clk);

        check_equal(pkt_count, 3, "packet count");
        check_equal(rd_count, 5, "read count");
        check_equal(busy, 0, "busy clear");

        $display("=== tb_psum_drain_writer: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (500) @(negedge clk);
        $display("[FAIL] timeout pkt=%0d rd=%0d busy=%0d", pkt_count, rd_count, busy);
        $fatal(1);
    end
endmodule

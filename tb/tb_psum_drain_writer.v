`timescale 1ns / 1ps

module tb_psum_drain_writer;
    localparam COLS = 4;
    localparam PSUM_W = 32;
    localparam AW = 5;
    localparam DATA_W = COLS * PSUM_W * 2;
    localparam MAX_PKT = 32;
    localparam [31:0] COL_MASK = (32'h1 << COLS) - 1;

    reg clk, rst, start, is_final_pass;
    reg [15:0] num_pixels;
    reg [PSUM_W-1:0] baseline_col0;
    wire busy, done;
    wire [31:0] psum_fifo_rd_en;
    reg [DATA_W-1:0] psum_fifo_rd_data;
    reg [31:0] psum_fifo_empty;
    wire packet_valid;
    reg packet_ready;
    wire [AW-1:0] packet_addr;
    wire [DATA_W-1:0] packet_data;
    wire packet_is_final;
    wire fifo_empty_wait;
    wire fifo_empty_wait_sticky;
    wire drain_read_fire;
    wire drain_packet_fire;
    wire drain_ready_stall;
    wire drain_internal_full_wait;

    psum_drain_writer #(.COLS(COLS), .PSUM_W(PSUM_W), .AW(AW)) dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done),
        .num_pixels(num_pixels), .baseline_col0(baseline_col0), .is_final_pass(is_final_pass),
        .psum_fifo_rd_en(psum_fifo_rd_en), .psum_fifo_rd_data(psum_fifo_rd_data),
        .psum_fifo_empty(psum_fifo_empty),
        .packet_valid(packet_valid), .packet_ready(packet_ready), .packet_addr(packet_addr),
        .packet_data(packet_data), .packet_is_final(packet_is_final),
        .fifo_empty_wait(fifo_empty_wait),
        .fifo_empty_wait_sticky(fifo_empty_wait_sticky),
        .drain_read_fire(drain_read_fire),
        .drain_packet_fire(drain_packet_fire),
        .drain_ready_stall(drain_ready_stall),
        .drain_internal_full_wait(drain_internal_full_wait)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer rd_count, pkt_count, lane, pkt;
    integer monitor_enable;
    integer expected_pixels;
    integer expected_final;
    integer stall_active;
    integer read_fire_count;
    integer packet_fire_count;
    integer ready_stall_count;
    integer internal_full_count;
    integer empty_wait_count;
    reg [AW-1:0] stall_addr;
    reg [DATA_W-1:0] stall_data;
    reg stall_final;
    reg [DATA_W-1:0] source_pkt [0:MAX_PKT-1];
    reg [DATA_W-1:0] expected_pkt [0:MAX_PKT-1];

    task put_word;
        input integer pkt_i;
        input integer lane_i;
        input [PSUM_W-1:0] value;
        begin
            source_pkt[pkt_i][lane_i*PSUM_W +: PSUM_W] = value;
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
            end else begin
                pass = pass + 1;
            end
        end
    endtask

    task check_le;
        input integer got;
        input integer exp;
        input [127:0] name;
        begin
            if (got > exp) begin
                $display("[FAIL] %0s got=%0d exp<=%0d", name, got, exp);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
        end
    endtask

    task init_packets;
        input integer n;
        begin
            for (pkt = 0; pkt < MAX_PKT; pkt = pkt + 1) begin
                source_pkt[pkt] = {DATA_W{1'b0}};
                expected_pkt[pkt] = {DATA_W{1'b0}};
            end
            for (pkt = 0; pkt < n; pkt = pkt + 1) begin
                for (lane = 0; lane < COLS * 2; lane = lane + 1)
                    put_word(pkt, lane, 32'h1000_0000 + pkt * 32 + lane);
                expected_pkt[pkt] = source_pkt[pkt];
            end
        end
    endtask

    task reset_case;
        begin
            rst = 1'b1;
            start = 1'b0;
            packet_ready = 1'b0;
            psum_fifo_empty = 32'hffff_ffff;
            psum_fifo_rd_data = {DATA_W{1'b0}};
            baseline_col0 = 32'd100;
            rd_count = 0;
            pkt_count = 0;
            monitor_enable = 0;
            stall_active = 0;
            read_fire_count = 0;
            packet_fire_count = 0;
            ready_stall_count = 0;
            internal_full_count = 0;
            empty_wait_count = 0;
            repeat (3) @(negedge clk);
            rst = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    task run_case;
        input [15:0] npix;
        input integer final_flag;
        input integer ready_mode;
        input integer gap_after_reads;
        input integer gap_cycles;
        input integer max_cycles;
        input integer throughput_limit;
        input [127:0] name;
        integer cycles;
        integer gap_used;
        integer gap_left;
        begin
            expected_pixels = (npix == 16'd0) ? 1 : npix;
            expected_final = final_flag;
            init_packets(expected_pixels);
            reset_case();

            num_pixels = npix;
            is_final_pass = final_flag[0];
            monitor_enable = 1;
            cycles = 0;
            gap_used = 0;
            gap_left = 0;
            psum_fifo_empty = ~COL_MASK;

            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            while (!done && cycles < max_cycles) begin
                case (ready_mode)
                    0: packet_ready = 1'b1;
                    1: packet_ready = ((cycles % 5) != 1) && ((cycles % 7) != 3);
                    2: packet_ready = (cycles > 4);
                    default: packet_ready = 1'b1;
                endcase

                if (gap_after_reads >= 0 && !gap_used && rd_count >= gap_after_reads) begin
                    gap_used = 1;
                    gap_left = gap_cycles;
                end
                if (gap_left > 0) begin
                    psum_fifo_empty = 32'hffff_ffff;
                    gap_left = gap_left - 1;
                end else begin
                    psum_fifo_empty = ~COL_MASK;
                end

                @(negedge clk);
                cycles = cycles + 1;
            end

            packet_ready = 1'b1;
            psum_fifo_empty = 32'hffff_ffff;
            monitor_enable = 0;

            if (!done) begin
                $display("[FAIL] %0s timeout pkt=%0d rd=%0d busy=%0d", name, pkt_count, rd_count, busy);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end

            check_equal(pkt_count, expected_pixels, "packet count");
            check_equal(rd_count, expected_pixels, "read count");
            check_equal(read_fire_count, expected_pixels, "drain read fire count");
            check_equal(packet_fire_count, expected_pixels, "drain packet fire count");
            if (ready_mode != 0)
                check_le(1, ready_stall_count, "ready stall seen");
            if (gap_after_reads >= 0)
                check_le(1, empty_wait_count, "empty wait seen");
            check_equal(busy, 0, "busy clear");
            if (throughput_limit > 0)
                check_le(cycles, throughput_limit, name);
            repeat (3) @(negedge clk);
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
        if (rst || !monitor_enable) begin
            read_fire_count <= 0;
            packet_fire_count <= 0;
            ready_stall_count <= 0;
            internal_full_count <= 0;
            empty_wait_count <= 0;
        end else begin
            if (drain_read_fire)
                read_fire_count <= read_fire_count + 1;
            if (drain_packet_fire)
                packet_fire_count <= packet_fire_count + 1;
            if (drain_ready_stall)
                ready_stall_count <= ready_stall_count + 1;
            if (drain_internal_full_wait)
                internal_full_count <= internal_full_count + 1;
            if (fifo_empty_wait)
                empty_wait_count <= empty_wait_count + 1;
        end
    end

    always @(posedge clk) begin
        if (rst || !monitor_enable || !packet_valid || packet_ready) begin
            stall_active <= 0;
        end else if (!stall_active) begin
            stall_active <= 1;
            stall_addr <= packet_addr;
            stall_data <= packet_data;
            stall_final <= packet_is_final;
        end else begin
            if (packet_addr !== stall_addr || packet_data !== stall_data ||
                packet_is_final !== stall_final) begin
                $display("[FAIL] packet changed while backpressured");
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst && monitor_enable && packet_valid && packet_ready) begin
            if (pkt_count >= expected_pixels) begin
                $display("[FAIL] unexpected extra packet addr=%0d", packet_addr);
                fail = fail + 1;
            end else begin
                if (packet_data !== expected_pkt[pkt_count]) begin
                    $display("[FAIL] packet%0d data mismatch", pkt_count);
                    fail = fail + 1;
                end else begin
                    pass = pass + 1;
                end
                check_equal(packet_addr, pkt_count, "packet addr");
                check_equal(packet_is_final, expected_final, "packet final");
            end
            pkt_count = pkt_count + 1;
        end
    end

    initial begin
        clk = 0;
        rst = 1;
        start = 0;
        is_final_pass = 1'b1;
        num_pixels = 16'd0;
        baseline_col0 = 32'd0;
        psum_fifo_empty = 32'hffff_ffff;
        packet_ready = 1'b0;
        pass = 0;
        fail = 0;
        rd_count = 0;
        pkt_count = 0;
        monitor_enable = 0;
        stall_active = 0;
        read_fire_count = 0;
        packet_fire_count = 0;
        ready_stall_count = 0;
        internal_full_count = 0;
        empty_wait_count = 0;

        run_case(16'd8, 1, 0, -1, 0, 80, 14, "no backpressure throughput");
        run_case(16'd9, 1, 1, -1, 0, 160, 0, "deterministic backpressure");
        run_case(16'd7, 0, 0, 3, 5, 120, 0, "fifo empty gap");
        run_case(16'd1, 1, 0, -1, 0, 40, 8, "single packet");
        run_case(16'd0, 0, 0, -1, 0, 40, 8, "zero means one packet");
        run_case(16'd32, 1, 0, -1, 0, 80, 40, "full address range");

        $display("=== tb_psum_drain_writer: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end

    initial begin
        repeat (2000) @(negedge clk);
        $display("[FAIL] global timeout pkt=%0d rd=%0d busy=%0d", pkt_count, rd_count, busy);
        $fatal(1);
    end
endmodule

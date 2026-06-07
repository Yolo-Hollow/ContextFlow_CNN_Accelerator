`timescale 1ns / 1ps

module tb_axis_ifm_line_loader;
    localparam AW = 9;
    localparam FM_W = 6;

    reg clk;
    reg rst;
    reg stream_reset;
    reg batch_mode;
    reg [31:0] expected_packets;
    reg [AW-1:0] fm_w;
    reg fill_req;
    reg [AW-1:0] fill_fy;
    reg [7:0] input_zero_point;
    wire s_axis_tready;
    reg s_axis_tvalid;
    reg [63:0] s_axis_tdata;
    reg [7:0] s_axis_tkeep;
    reg s_axis_tlast;
    wire [4:0] dma_bank_wr_en;
    wire [AW-1:0] dma_wr_x;
    wire [AW:0] dma_wr_fy;
    wire [7:0] dma_wr_data [0:4];
    wire dma_line_advance;
    wire tkeep_error;
    wire tlast_error;
    wire [31:0] completed_packets;

    integer pass;
    integer fail;
    integer beat_seen;
    integer advance_seen;
    integer b;
    reg use_custom_expected;
    reg [7:0] custom_expected [0:4];
    reg [AW:0] expected_fy;

    axis_ifm_line_loader #(.AW(AW)) dut (
        .clk(clk),
        .rst(rst),
        .stream_reset(stream_reset),
        .batch_mode(batch_mode),
        .expected_packets(expected_packets),
        .fm_w(fm_w),
        .fill_req(fill_req),
        .fill_fy(fill_fy),
        .input_zero_point(input_zero_point),
        .s_axis_tready(s_axis_tready),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .dma_bank_wr_en(dma_bank_wr_en),
        .dma_wr_x(dma_wr_x),
        .dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data),
        .dma_line_advance(dma_line_advance),
        .tkeep_error(tkeep_error),
        .tlast_error(tlast_error),
        .completed_packets(completed_packets)
    );

    always #5 clk = ~clk;

    task check;
        input cond;
        input [255:0] msg;
        begin
            if (cond) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("[FAIL] %0s", msg);
            end
        end
    endtask

    function [7:0] center_ifm_byte_tb;
        input [7:0] raw_u8;
        input [7:0] zero_point;
        reg signed [9:0] centered;
        begin
            centered = $signed({2'b00, raw_u8}) - $signed({2'b00, zero_point});
            if (centered > 10'sd127)
                center_ifm_byte_tb = 8'h7f;
            else if (centered < -10'sd128)
                center_ifm_byte_tb = 8'h80;
            else
                center_ifm_byte_tb = centered[7:0];
        end
    endfunction

    function [63:0] pack_line_word;
        input integer x;
        begin
            pack_line_word = 64'd0;
            pack_line_word[7:0] = (8'h40 + x*5 + 0) & 8'hff;
            pack_line_word[15:8] = (8'h40 + x*5 + 1) & 8'hff;
            pack_line_word[23:16] = (8'h40 + x*5 + 2) & 8'hff;
            pack_line_word[31:24] = (8'h40 + x*5 + 3) & 8'hff;
            pack_line_word[39:32] = (8'h40 + x*5 + 4) & 8'hff;
        end
    endfunction

    function [63:0] pack_custom_word;
        input [7:0] d0;
        input [7:0] d1;
        input [7:0] d2;
        input [7:0] d3;
        input [7:0] d4;
        begin
            pack_custom_word = 64'd0;
            pack_custom_word[7:0] = d0;
            pack_custom_word[15:8] = d1;
            pack_custom_word[23:16] = d2;
            pack_custom_word[31:24] = d3;
            pack_custom_word[39:32] = d4;
        end
    endfunction

    task send_axis_word;
        input integer x;
        input last;
        input [7:0] keep;
        begin
            @(negedge clk);
            s_axis_tvalid = 1'b1;
            s_axis_tdata = pack_line_word(x);
            s_axis_tkeep = keep;
            s_axis_tlast = last;
            wait(s_axis_tready);
            @(negedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tdata = 64'd0;
            s_axis_tkeep = 8'd0;
            s_axis_tlast = 1'b0;
        end
    endtask

    task send_axis_custom_word;
        input [63:0] data;
        begin
            @(negedge clk);
            s_axis_tvalid = 1'b1;
            s_axis_tdata = data;
            s_axis_tkeep = 8'h1f;
            s_axis_tlast = 1'b1;
            wait(s_axis_tready);
            @(negedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tdata = 64'd0;
            s_axis_tkeep = 8'd0;
            s_axis_tlast = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (!rst && |dma_bank_wr_en) begin
            check(dma_bank_wr_en == 5'b11111, "all banks written from AXIS beat");
            check(dma_wr_x == beat_seen[AW-1:0], "AXIS x write order");
            check(dma_wr_fy == expected_fy, "AXIS fy latched");
            for (b = 0; b < 5; b = b + 1) begin
                if (use_custom_expected)
                    check(dma_wr_data[b] == custom_expected[b], "AXIS centered custom byte");
                else
                    check(dma_wr_data[b] == center_ifm_byte_tb(8'h40 + beat_seen*5 + b, input_zero_point),
                          "AXIS bank byte order");
            end
            beat_seen = beat_seen + 1;
        end
        if (!rst && dma_line_advance)
            advance_seen = advance_seen + 1;
    end

    integer x;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
        stream_reset = 1'b0;
        batch_mode = 1'b0;
        expected_packets = 32'd0;
        fm_w = FM_W[AW-1:0];
        fill_req = 1'b0;
        fill_fy = 9'd3;
        input_zero_point = 8'd0;
        s_axis_tvalid = 1'b0;
        s_axis_tdata = 64'd0;
        s_axis_tkeep = 8'd0;
        s_axis_tlast = 1'b0;
        pass = 0;
        fail = 0;
        beat_seen = 0;
        advance_seen = 0;
        use_custom_expected = 1'b0;
        expected_fy = 10'd3;
        for (b = 0; b < 5; b = b + 1)
            custom_expected[b] = 8'd0;

        repeat (4) @(negedge clk);
        rst = 1'b0;
        check(!s_axis_tready, "AXIS ready low before request");

        @(negedge clk);
        fm_w = {AW{1'b0}};
        fill_req = 1'b1;
        s_axis_tvalid = 1'b1;
        s_axis_tdata = pack_line_word(0);
        s_axis_tkeep = 8'h1f;
        s_axis_tlast = 1'b1;
        @(negedge clk);
        fill_req = 1'b0;
        repeat (2) @(negedge clk);
        check(!s_axis_tready, "AXIS ready stays low for zero-width row");
        check(beat_seen == 0, "zero-width row writes no beats");
        check(advance_seen == 0, "zero-width row has no advance pulse");
        s_axis_tvalid = 1'b0;
        s_axis_tdata = 64'd0;
        s_axis_tkeep = 8'd0;
        s_axis_tlast = 1'b0;
        fm_w = FM_W[AW-1:0];

        @(negedge clk);
        fill_req = 1'b1;
        @(negedge clk);
        fill_req = 1'b0;
        check(s_axis_tready, "AXIS ready asserted after request");

        send_axis_word(0, 1'b0, 8'h1f);
        repeat (2) @(negedge clk);
        for (x = 1; x < FM_W; x = x + 1)
            send_axis_word(x, x == FM_W - 1, 8'h1f);

        @(negedge clk);
        check(beat_seen == FM_W, "all AXIS IFM beats written");
        check(advance_seen == 1, "AXIS line advance pulse count");
        check(!s_axis_tready, "AXIS ready low after row");
        check(!tkeep_error, "no TKEEP error on legal row");
        check(!tlast_error, "no TLAST error on legal row");

        repeat (3) @(negedge clk);
        fm_w = {{(AW-1){1'b0}}, 1'b1};
        fill_fy = 9'd4;
        expected_fy = 10'd4;
        input_zero_point = 8'd36;
        use_custom_expected = 1'b1;
        custom_expected[0] = 8'h00;
        custom_expected[1] = 8'hf2;
        custom_expected[2] = 8'h32;
        custom_expected[3] = 8'h7f;
        custom_expected[4] = 8'h7f;
        beat_seen = 0;
        advance_seen = 0;
        @(negedge clk);
        fill_req = 1'b1;
        @(negedge clk);
        fill_req = 1'b0;
        send_axis_custom_word(pack_custom_word(8'd36, 8'd22, 8'd86, 8'd255, 8'd220));
        @(negedge clk);
        check(beat_seen == 1, "AXIS zp36 custom row beat count");
        check(advance_seen == 1, "AXIS zp36 custom row advance count");

        repeat (3) @(negedge clk);
        fill_fy = 9'd5;
        expected_fy = 10'd5;
        input_zero_point = 8'd200;
        custom_expected[0] = 8'h80;
        custom_expected[1] = 8'h00;
        custom_expected[2] = 8'h37;
        custom_expected[3] = 8'h80;
        custom_expected[4] = 8'h81;
        beat_seen = 0;
        advance_seen = 0;
        @(negedge clk);
        fill_req = 1'b1;
        @(negedge clk);
        fill_req = 1'b0;
        send_axis_custom_word(pack_custom_word(8'd0, 8'd200, 8'd255, 8'd72, 8'd73));
        @(negedge clk);
        check(beat_seen == 1, "AXIS zp200 custom row beat count");
        check(advance_seen == 1, "AXIS zp200 custom row advance count");
        check(!tkeep_error, "no TKEEP error after custom rows");
        check(!tlast_error, "no TLAST error after custom rows");
        check(completed_packets == 3, "legacy IFM packet count");

        $display("=== %m: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

`timescale 1ns / 1ps

module tb_ifm_fill_handshake;
    localparam AW = 9;
    localparam FM_W = 416;

    reg clk;
    reg rst;
    reg start;
    reg [AW-1:0] fm_w;
    reg [AW-1:0] fm_h;
    reg [AW-1:0] ofm_h;
    reg [AW-1:0] start_oy;
    reg [AW-1:0] tile_ofm_h;
    reg [1:0] stride;
    reg [1:0] pad;
    reg compute_done;

    wire fill_req;
    wire [AW-1:0] fill_fy;
    wire compute_start;
    wire [AW-1:0] compute_oy;
    wire ctrl_busy;
    wire ctrl_done;

    wire s_axis_tready;
    reg s_axis_tvalid;
    reg [63:0] s_axis_tdata;
    reg [7:0] s_axis_tkeep;
    reg s_axis_tlast;
    wire [1:0] dma_bank_wr_en;
    wire [AW-1:0] dma_wr_x;
    wire [AW:0] dma_wr_fy;
    wire [7:0] dma_wr_data [0:1];
    wire dma_line_advance;
    wire tkeep_error;
    wire tlast_error;

    integer cycle;
    integer request_count;
    integer advance_count;
    integer beat_count;
    reg source_active;
    reg fill_req_d;
    reg [AW-1:0] fill_fy_d;
    reg ready_d;
    reg advance_d;

    line_stream_ctrl #(.AW(AW)) u_ctrl (
        .clk(clk),
        .rst(rst),
        .start(start),
        .fm_h(fm_h),
        .ofm_h(ofm_h),
        .start_oy(start_oy),
        .tile_ofm_h(tile_ofm_h),
        .stride(stride),
        .pad(pad),
        .fill_done(dma_line_advance),
        .compute_done(compute_done),
        .fill_req(fill_req),
        .fill_fy(fill_fy),
        .compute_start(compute_start),
        .compute_oy(compute_oy),
        .busy(ctrl_busy),
        .done(ctrl_done)
    );

    axis_ifm_line_loader #(
        .AW(AW),
        .AXIS_W(64),
        .KEEP_W(8),
        .BANKS(2)
    ) u_loader (
        .clk(clk),
        .rst(rst),
        .fm_w(fm_w),
        .fill_req(fill_req),
        .fill_fy(fill_fy),
        .input_zero_point(8'd0),
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
        .tlast_error(tlast_error)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        cycle <= cycle + 1;
        fill_req_d <= fill_req;
        fill_fy_d <= fill_fy;
        ready_d <= s_axis_tready;
        advance_d <= dma_line_advance;

        if ((fill_req != fill_req_d) || (fill_fy != fill_fy_d) ||
            (s_axis_tready != ready_d) || (dma_line_advance != advance_d)) begin
            $display("TRACE cycle=%0d req=%0b fy=%0d ready=%0b advance=%0b loader_busy=%0b cooldown=%0b last_valid=%0b last_fy=%0d ctrl_state=%0d",
                     cycle, fill_req, fill_fy, s_axis_tready, dma_line_advance,
                     u_loader.u_line_loader.busy,
                     u_loader.u_line_loader.cooldown,
                     u_loader.u_line_loader.last_done_valid,
                     u_loader.u_line_loader.last_done_fy,
                     u_ctrl.state);
        end

        if (!rst && fill_req && !fill_req_d) begin
            request_count <= request_count + 1;
            source_active <= 1'b1;
            beat_count <= 0;
        end

        if (!rst && source_active && s_axis_tready) begin
            s_axis_tvalid <= 1'b1;
            s_axis_tdata <= {48'd0, beat_count[7:0], beat_count[7:0]};
            s_axis_tkeep <= 8'h03;
            s_axis_tlast <= (beat_count == FM_W - 1);
            if (beat_count == FM_W - 1) begin
                source_active <= 1'b0;
                beat_count <= 0;
            end else begin
                beat_count <= beat_count + 1;
            end
        end else begin
            s_axis_tvalid <= 1'b0;
            s_axis_tlast <= 1'b0;
        end

        if (!rst && dma_line_advance)
            advance_count <= advance_count + 1;

        if (!rst && compute_start)
            compute_done <= 1'b1;
        else
            compute_done <= 1'b0;
    end

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        start = 1'b0;
        fm_w = FM_W;
        fm_h = 416;
        ofm_h = 416;
        start_oy = 0;
        tile_ofm_h = 2;
        stride = 1;
        pad = 1;
        compute_done = 1'b0;
        s_axis_tvalid = 1'b0;
        s_axis_tdata = 64'd0;
        s_axis_tkeep = 8'h03;
        s_axis_tlast = 1'b0;
        cycle = 0;
        request_count = 0;
        advance_count = 0;
        beat_count = 0;
        source_active = 1'b0;
        fill_req_d = 1'b0;
        fill_fy_d = 0;
        ready_d = 1'b0;
        advance_d = 1'b0;

        repeat (4) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait(ctrl_done);
        repeat (3) @(posedge clk);
        if (request_count != 3 || advance_count != 3 || tkeep_error || tlast_error) begin
            $display("[FAIL] requests=%0d advances=%0d keep_err=%0b last_err=%0b",
                     request_count, advance_count, tkeep_error, tlast_error);
            $fatal(1);
        end
        $display("=== tb_ifm_fill_handshake: PASS requests=%0d advances=%0d ===",
                 request_count, advance_count);
        $finish;
    end

    initial begin
        repeat (5000) @(posedge clk);
        $display("[FAIL] timeout requests=%0d advances=%0d req=%0b fy=%0d ready=%0b ctrl_state=%0d",
                 request_count, advance_count, fill_req, fill_fy, s_axis_tready, u_ctrl.state);
        $fatal(1);
    end
endmodule

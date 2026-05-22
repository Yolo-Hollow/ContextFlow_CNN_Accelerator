// Testbench: 3-port line buffer + window extractor
// 5x5 IFM, 1 channel, 3x3 kernel, pad=0, stride=1 → 3x3 output
`timescale 1ns / 1ps
module tb_linebuf;
    localparam FM_W=5, FM_H=5, AW=3;

    reg clk,rst;
    reg [4:0] bank_wr_en; reg [AW-1:0] wr_x; reg [7:0] wr_data [0:4];
    reg line_advance; reg [AW:0] wr_fy;
    reg [AW-1:0] rd_x0,rd_x1,rd_x2;
    wire [7:0] rd_data [0:4][0:2][0:2];  // [bank][line][kx]
    wire [AW:0] line_fy [0:2];

    line_buffer_5bank #(.FM_W(FM_W),.AW(AW)) u_lb (
        .clk(clk),.rst(rst),.bank_wr_en(bank_wr_en),.wr_x(wr_x),
        .wr_data(wr_data),.line_advance(line_advance),.wr_fy(wr_fy),
        .rd_x0(rd_x0),.rd_x1(rd_x1),.rd_x2(rd_x2),.rd_data(rd_data),
        .line_fy_out(line_fy)
    );

    reg [1:0] stride,pad; reg [AW-1:0] oy,ox; reg [10:0] base;
    wire [255:0] ifm_d; wire ifm_v;

    window_extract #(.FM_W(FM_W),.FM_H(FM_H),.AW(AW)) u_we (
        .stride(stride),.pad(pad),.oy(oy),.ox(ox),.pass_base_k(base),
        .lb_data(rd_data),.line_fy(line_fy),.lb_valid(1'b1),
        .ifm_data(ifm_d),.ifm_valid(ifm_v)
    );

    always #5 clk=~clk;
    integer pass,fail,i;

    initial begin
        clk=0; rst=1; pass=0; fail=0; line_advance=0; wr_fy=0;
        bank_wr_en=0; wr_x=0; for(i=0;i<5;i=i+1) wr_data[i]=0;
        stride=1; pad=0; oy=0; ox=0; base=0;
        rd_x0=0; rd_x1=0; rd_x2=0;
        repeat(3)@(negedge clk); rst=0; @(negedge clk); @(negedge clk);

        // Fill bank0: 3 lines only (ring buffer holds exactly 3)
        $display("=== Fill bank0 with 3 IFM lines ===");
        bank_wr_en = 5'b00001;
        for (int y=0; y<3; y=y+1) begin
            wr_fy = y;  // set BEFORE x loop so line_fy tracks correctly
            for (int x=0; x<FM_W; x=x+1) begin
                wr_x=x[AW-1:0]; wr_data[0]=y*10+x; @(negedge clk);
            end
            if (y<2) begin line_advance=1; @(negedge clk); line_advance=0; end
        end
        bank_wr_en=0;

        // Verify 3-port read at window (oy=1,ox=1): needs IFM rows 0,1,2 cols 0,1,2
        $display("=== Verify window at oy=1,ox=1 ===");
        rd_x0=0; rd_x1=1; rd_x2=2;
        oy=1; ox=1; base=0;
        #1;
        $display("  line_fy = {%0d,%0d,%0d}", line_fy[0], line_fy[1], line_fy[2]);
        $display("  line_fy = {%0d,%0d,%0d}", line_fy[0], line_fy[1], line_fy[2]);
        $display("  rd[0][0]={%0d,%0d,%0d}", rd_data[0][0][0], rd_data[0][0][1], rd_data[0][0][2]);
        $display("  rd[0][1]={%0d,%0d,%0d}", rd_data[0][1][0], rd_data[0][1][1], rd_data[0][1][2]);
        $display("  rd[0][2]={%0d,%0d,%0d}", rd_data[0][2][0], rd_data[0][2][1], rd_data[0][2][2]);

        // ch0 only, rows 0-8 fill
        // Row0: ker0(kx=0) → line0(IFM_y0), col0 → 0*10+0=0
        // Row1: ker1(kx=1) → line0, col1 → 1
        // Row2: ker2(kx=2) → line0, col2 → 2
        // Row3: ker3(ky=1,kx=0) → line1(IFM_y1), col0 → 10
        // Row4: ker4(ky=1,kx=1) → line1, col1 → 11
        // Row5: ker5(ky=1,kx=2) → line1, col2 → 12
        // Row6: ker6(ky=2,kx=0) → line2(IFM_y2), col0 → 20
        // Row7: ker7(ky=2,kx=1) → line2, col1 → 21
        // Row8: ker8(ky=2,kx=2) → line2, col2 → 22
        if(ifm_d[7:0]   !== 0)  begin $display("[FAIL] row0=%0d exp=0", ifm_d[7:0]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[15:8]  !== 1)  begin $display("[FAIL] row1=%0d exp=1", ifm_d[15:8]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[23:16] !== 2)  begin $display("[FAIL] row2=%0d exp=2", ifm_d[23:16]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[31:24] !== 10) begin $display("[FAIL] row3=%0d exp=10", ifm_d[31:24]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[39:32] !== 11) begin $display("[FAIL] row4=%0d exp=11", ifm_d[39:32]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[47:40] !== 12) begin $display("[FAIL] row5=%0d exp=12", ifm_d[47:40]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[55:48] !== 20) begin $display("[FAIL] row6=%0d exp=20", ifm_d[55:48]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[63:56] !== 21) begin $display("[FAIL] row7=%0d exp=21", ifm_d[63:56]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[71:64] !== 22) begin $display("[FAIL] row8=%0d exp=22", ifm_d[71:64]); fail=fail+1; end else pass=pass+1;

        // Verify padding: next window oy=1,ox=2 needs col3 which exists
        $display("=== Verify padding at oy=1,ox=0 (left edge) ===");
        oy=1; ox=0; rd_x0=0; rd_x1=1; rd_x2=2;
        #1;
        // ker0(kx=0): fx=-1 → pad=0
        if(ifm_d[7:0] !== 0) begin $display("[FAIL] pad row0=%0d exp=0", ifm_d[7:0]); fail=fail+1; end else pass=pass+1;

        $display("=== %0d pass, %0d fail ===", pass, fail); $finish;
    end
endmodule

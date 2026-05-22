// 3-port line buffer + window extractor test
// 5x5 IFM ch0, 3x3 kernel, pad=0, stride=1
`timescale 1ns / 1ps
module tb_linebuf;
    localparam FM_W=5, FM_H=5, AW=3;

    reg clk,rst; reg [4:0] bank_wr_en; reg [AW-1:0] wr_x; reg [7:0] wr_data [0:4];
    reg line_advance; reg [AW:0] wr_fy;
    reg [AW-1:0] rd_x0,rd_x1,rd_x2;
    wire [7:0] rd_data [0:4][0:2][0:2];
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
    integer pass,fail, i;

    initial begin
        clk=0; rst=1; pass=0; fail=0; line_advance=0; wr_fy=0;
        bank_wr_en=0; wr_x=0; for(i=0;i<5;i=i+1) wr_data[i]=0;
        stride=1; pad=0; oy=0; ox=0; base=0;
        rd_x0=0; rd_x1=1; rd_x2=2;
        repeat(3)@(negedge clk); rst=0; @(negedge clk); @(negedge clk);

        // Fill bank0 with 3 IFM lines: value = y*10 + x
        bank_wr_en = 5'b00001;
        for (int y=0; y<3; y=y+1) begin
            wr_fy = y;
            for (int x=0; x<FM_W; x=x+1) begin
                wr_x=x[AW-1:0]; wr_data[0]=y*10+x; @(negedge clk);
            end
            if (y<2) begin line_advance=1; @(negedge clk); line_advance=0; end
        end
        bank_wr_en=0;

        // Window at oy=0,ox=1: fy=0,1,2 all in buffer, fx=0,1,2 in bounds
        // ch0: 3x3 kernel rows 0,1,2 at cols 0,1,2
        // Row0 ker0(0,0)→fy=0,fx=0→0  Row1 ker1(0,1)→fy=0,fx=1→1  Row2 ker2(0,2)→fy=0,fx=2→2
        // Row3 ker3(1,0)→fy=1,fx=0→10 Row4 ker4(1,1)→fy=1,fx=1→11 Row5 ker5(1,2)→fy=1,fx=2→12
        // Row6 ker6(2,0)→fy=2,fx=0→20 Row7 ker7(2,1)→fy=2,fx=1→21 Row8 ker8(2,2)→fy=2,fx=2→22
        $display("=== Window at oy=0,ox=1 ===");
        oy=0; ox=1; #1;
        $display("  line_fy={%0d,%0d,%0d}", line_fy[0], line_fy[1], line_fy[2]);
        if(ifm_d[ 7: 0]!==0) begin $display("[FAIL] r0=%0d exp=0", ifm_d[7:0]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[15: 8]!==1) begin $display("[FAIL] r1=%0d exp=1", ifm_d[15:8]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[23:16]!==2) begin $display("[FAIL] r2=%0d exp=2", ifm_d[23:16]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[31:24]!==10)begin $display("[FAIL] r3=%0d exp=10", ifm_d[31:24]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[39:32]!==11)begin $display("[FAIL] r4=%0d exp=11", ifm_d[39:32]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[47:40]!==12)begin $display("[FAIL] r5=%0d exp=12", ifm_d[47:40]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[55:48]!==20)begin $display("[FAIL] r6=%0d exp=20", ifm_d[55:48]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[63:56]!==21)begin $display("[FAIL] r7=%0d exp=21", ifm_d[63:56]); fail=fail+1; end else pass=pass+1;
        if(ifm_d[71:64]!==22)begin $display("[FAIL] r8=%0d exp=22", ifm_d[71:64]); fail=fail+1; end else pass=pass+1;

        // Padding: oy=0,ox=0 → ker0(kx=0): fx=-1 → pad=0
        $display("=== Padding left edge oy=0,ox=0 ===");
        oy=0; ox=0; #1;
        if(ifm_d[7:0]!==0) begin $display("[FAIL] pad-r0=%0d exp=0", ifm_d[7:0]); fail=fail+1; end else pass=pass+1;

        // Padding: oy=0,ox=4 → ker2(kx=2): fx=6 → out of bounds
        $display("=== Padding right edge oy=0,ox=4 ===");
        oy=0; ox=4; #1;
        if(ifm_d[23:16]!==0) begin $display("[FAIL] pad-r2=%0d exp=0", ifm_d[23:16]); fail=fail+1; end else pass=pass+1;

        $display("=== %0d pass, %0d fail ===", pass, fail); $finish;
    end
endmodule

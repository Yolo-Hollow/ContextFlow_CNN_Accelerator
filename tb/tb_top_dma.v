// DMA streaming + sliding window — all 9 pixels (oy=0,1,2; ox=0,1,2)
// 3 passes: each loads 3 IFM rows, computes one oy with 3 ox positions
`timescale 1ns / 1ps
module tb_top_dma;
    localparam ROWS=32, COLS=32, IFM_W=8, WGT_W=8, PSUM_W=32;
    localparam IFM_D=256, IFM_AW=8, WGT_D=64, WGT_AW=6, PSUM_D=256, PSUM_AW=8;
    localparam FM_W=5, FM_H=5;

    reg clk,rst,start; wire done;
    reg [4:0] dma_bank_wr_en; reg [8:0] dma_wr_x; reg [9:0] dma_wr_fy;
    reg [7:0] dma_wr_data [0:4]; reg dma_line_advance;
    reg [8:0] fm_h,fm_w,oy,ox; reg [1:0] cs,cp; reg [10:0] base;
    wire [31:0] ifm_full;
    reg [31:0] wgt_wr_en; reg [ROWS*WGT_W*2-1:0] wgt_wr_data; wire [31:0] wgt_full;
    reg [31:0] psum_rd_en; wire [COLS*PSUM_W*2-1:0] psum_rd_data; wire [31:0] psum_empty;
    reg [5:0] bias_addr; reg [PSUM_W-1:0] bias_data; reg bias_en,is_first,use_ext;
    reg [COLS*2*PSUM_W-1:0] psum_top_ext;

    systolic_top #(.ROWS(ROWS),.COLS(COLS),.IFM_FIFO_DEPTH(IFM_D),.IFM_FIFO_AW(IFM_AW)) u_top (
        .clk(clk),.rst(rst),.start(start),.done(done),
        .dma_bank_wr_en(dma_bank_wr_en),.dma_wr_x(dma_wr_x),.dma_wr_fy(dma_wr_fy),
        .dma_wr_data(dma_wr_data),.dma_line_advance(dma_line_advance),
        .fm_h(fm_h),.fm_w(fm_w),.conv_stride(cs),.conv_pad(cp),.pass_base_k(base),
        .oy(oy),.ox(ox),.ifm_fifo_full(ifm_full),
        .wgt_fifo_wr_en(wgt_wr_en),.wgt_fifo_wr_data(wgt_wr_data),.wgt_fifo_full(wgt_full),
        .psum_fifo_rd_en(psum_rd_en),.psum_fifo_rd_data(psum_rd_data),.psum_fifo_empty(psum_empty),
        .bias_wr_addr(bias_addr),.bias_wr_data(bias_data),.bias_wr_en(bias_en),
        .is_first_pass(is_first),.psum_top_ext(psum_top_ext),.use_ext_psum(use_ext)
    );
    always #5 clk=~clk;
    integer pass,fail,i,rr,cc;
    reg [7:0] w0b,w1b; reg [511:0] wtmp;

    // Test one output row (oy): fill 3 IFM lines, feed 3 ox positions, verify
    task test_row;
        input [8:0] py;         // oy
        input [8:0] fy_start;   // first IFM row to fill
        input [PSUM_W-1:0] exp_a0, exp_a1, exp_a2;
        input [PSUM_W-1:0] exp_b0, exp_b1, exp_b2;
        reg [PSUM_W-1:0] exp_a;
        reg [PSUM_W-1:0] exp_b;
        begin
            // Reset
            rst=1; repeat(3)@(negedge clk); rst=0; repeat(2)@(negedge clk);

            // Weights
            for (cc=0; cc<32; cc=cc+1) begin
                wtmp=0;
                for (rr=0; rr<32; rr=rr+1) begin
                    w0b=(rr<9)?(cc+1):0; w1b=(rr<9)?(rr+1):0;
                    wtmp = wtmp | ({w1b,w0b} << (rr*16));
                end
                wgt_wr_data=wtmp; wgt_wr_en={32{1'b1}}; @(negedge clk);
            end
            wgt_wr_en=0;
            bias_en=1; bias_data=0;
            for(i=0;i<64;i=i+1) begin bias_addr=i[5:0]; @(negedge clk); end
            bias_en=0;

            // DMA: 3 IFM lines starting at fy_start
            dma_bank_wr_en=5'b11111;
            for (int y=fy_start; y<fy_start+3; y=y+1) begin
                dma_wr_fy=y;
                for (int x=0; x<FM_W; x=x+1) begin
                    dma_wr_x=x[8:0];
                    dma_wr_data[0]=(y>=0 && y<FM_H)?(y*10+x):0;
                    dma_wr_data[1]=0; dma_wr_data[2]=0; dma_wr_data[3]=0; dma_wr_data[4]=0;
                    @(negedge clk);
                end
                if (y<fy_start+2) begin dma_line_advance=1; @(negedge clk); dma_line_advance=0; end
            end
            dma_bank_wr_en=0;

            oy=py;
            @(negedge clk); start=1; @(negedge clk); start=0;
            repeat(35) @(negedge clk);  // wait weight load

            // Feed 3 ox positions
            for (int px=0; px<3; px=px+1) begin
                ox=px[8:0]; @(negedge clk);
            end

            repeat(500) @(negedge clk);  // wait drain
            for (i=0; i<230; i=i+1) begin psum_rd_en={32{1'b1}}; @(negedge clk); end
            psum_rd_en=0; @(negedge clk);

            // Verify 3 pixels
            for (int px=0; px<3; px=px+1) begin
                case (px)
                    0: begin exp_a = exp_a0; exp_b = exp_b0; end
                    1: begin exp_a = exp_a1; exp_b = exp_b1; end
                    default: begin exp_a = exp_a2; exp_b = exp_b2; end
                endcase
                psum_rd_en=5'b00001; @(negedge clk); psum_rd_en=0; @(negedge clk);
                if(psum_rd_data[PSUM_W-1:0]!==exp_a)begin $display("[FAIL](%0d,%0d)a=%0d exp=%0d",py,px,psum_rd_data[PSUM_W-1:0],exp_a); fail=fail+1; end else pass=pass+1;
                if(psum_rd_data[2*PSUM_W-1:PSUM_W]!==exp_b)begin $display("[FAIL](%0d,%0d)b=%0d exp=%0d",py,px,psum_rd_data[2*PSUM_W-1:PSUM_W],exp_b); fail=fail+1; end else pass=pass+1;
            end
        end
    endtask

    initial begin
        clk=0; pass=0; fail=0;
        dma_bank_wr_en=0; dma_wr_x=0; dma_wr_fy=0; dma_line_advance=0;
        for(i=0;i<5;i=i+1) dma_wr_data[i]=0;
        fm_h=FM_H; fm_w=FM_W; cs=1; cp=0; base=0; oy=0; ox=0;
        wgt_wr_en=0; wgt_wr_data=0; psum_rd_en=0; start=0;
        bias_en=0; bias_addr=0; bias_data=0; is_first=1; use_ext=0;

        // oy=0: IFM rows 0,1,2 → pixels (0,0),(0,1),(0,2)
        // psuma: sum*1, psumb: weighted sum
        // (0,0): sum=0+1+2+10+11+12+20+21+22=99
        // (0,1): sum=1+2+3+11+12+13+21+22+23=108
        // (0,2): sum=2+3+4+12+13+14+22+23+24=117
        test_row(0, 0, 99, 108, 117, 681, 726, 771);

        // oy=1: IFM rows 1,2,3
        // (1,0): sum=10+11+12+20+21+22+30+31+32=189
        // (1,1): sum=11+12+13+21+22+23+31+32+33=198
        // (1,2): sum=12+13+14+22+23+24+32+33+34=207
        test_row(1, 1, 189, 198, 207, 1176, 1221, 1266);

        // oy=2: IFM rows 2,3,4
        // (2,0): sum=20+21+22+30+31+32+40+41+42=279
        // (2,1): sum=21+22+23+31+32+33+41+42+43=288
        // (2,2): sum=22+23+24+32+33+34+42+43+44=297
        test_row(2, 2, 279, 288, 297, 1671, 1716, 1761);

        $display("=== %0d pass, %0d fail ===", pass, fail); $finish;
    end
endmodule

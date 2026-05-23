// DMA streaming test — one pixel per compute pass, 3 passes for (0,0),(0,1),(0,2)
`timescale 1ns / 1ps
module tb_top_dma;
    localparam ROWS=32, COLS=32, IFM_W=8, WGT_W=8, PSUM_W=24;
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
    integer px;  // which pixel index to test

    // Run one pixel test
    task test_pixel;
        input [8:0] py, px_in;
        input [PSUM_W-1:0] exp_a, exp_b;
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

            // Bias=0
            bias_en=1; bias_data=0;
            for(i=0;i<64;i=i+1) begin bias_addr=i[5:0]; @(negedge clk); end
            bias_en=0;

            // DMA: 3 IFM lines
            dma_bank_wr_en = 5'b11111;
            for (int y=0; y<3; y=y+1) begin
                dma_wr_fy = y;
                for (int x=0; x<FM_W; x=x+1) begin
                    dma_wr_x=x[8:0]; dma_wr_data[0]=y*10+x;
                    dma_wr_data[1]=0; dma_wr_data[2]=0; dma_wr_data[3]=0; dma_wr_data[4]=0;
                    @(negedge clk);
                end
                if (y<2) begin dma_line_advance=1; @(negedge clk); dma_line_advance=0; end
            end
            dma_bank_wr_en=0;

            // Set window position
            oy=py; ox=px_in;

            // Start compute
            @(negedge clk); start=1; @(negedge clk); start=0;
            repeat(500) @(negedge clk);  // wait compute+drain

            // Drain PSUM: skip pipe fill (~230)
            for (i=0; i<230; i=i+1) begin psum_rd_en={32{1'b1}}; @(negedge clk); end
            psum_rd_en=0; @(negedge clk);

            // Read and check one pixel
            psum_rd_en=5'b00001; @(negedge clk); psum_rd_en=0; @(negedge clk);
            if(psum_rd_data[23:0]!==exp_a)begin $display("[FAIL]p(%0d,%0d)a=%0d exp=%0d",py,px_in,psum_rd_data[23:0],exp_a); fail=fail+1; end else pass=pass+1;
            if(psum_rd_data[47:24]!==exp_b)begin $display("[FAIL]p(%0d,%0d)b=%0d exp=%0d",py,px_in,psum_rd_data[47:24],exp_b); fail=fail+1; end else pass=pass+1;
        end
    endtask

    initial begin
        clk=0; pass=0; fail=0;
        dma_bank_wr_en=0; dma_wr_x=0; dma_wr_fy=0; dma_line_advance=0;
        for(i=0;i<5;i=i+1) dma_wr_data[i]=0;
        fm_h=FM_H; fm_w=FM_W; cs=1; cp=0; base=0; oy=0; ox=0;
        wgt_wr_en=0; wgt_wr_data=0; psum_rd_en=0; start=0;
        bias_en=0; bias_addr=0; bias_data=0; is_first=1; use_ext=0;

        test_pixel(0,0,99,681);
        test_pixel(0,1,108,726);
        test_pixel(0,2,117,771);

        $display("=== %0d pass, %0d fail ===", pass, fail); $finish;
    end
endmodule

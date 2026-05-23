// Top-level test with DMA streaming line buffer input
// 5x5 IFM, ch0 only, 3x3 kernel, pad=0, stride=1 → 3x3 output
`timescale 1ns / 1ps
module tb_top_dma;
    localparam ROWS=32, COLS=32, IFM_W=8, WGT_W=8, PSUM_W=24;
    localparam IFM_D=256, IFM_AW=8, WGT_D=64, WGT_AW=6, PSUM_D=256, PSUM_AW=8;
    localparam FM_W=5, FM_H=5;  // small test IFM

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

    initial begin
        clk=0; rst=1; start=0; pass=0; fail=0;
        dma_bank_wr_en=0; dma_wr_x=0; dma_wr_fy=0; dma_line_advance=0;
        for(i=0;i<5;i=i+1) dma_wr_data[i]=0;
        fm_h=FM_H; fm_w=FM_W; cs=1; cp=0; base=0; oy=0; ox=0;
        wgt_wr_en=0; wgt_wr_data=0; psum_rd_en=0;
        bias_en=0; bias_addr=0; bias_data=0; is_first=1; use_ext=0;

        repeat(3)@(negedge clk); rst=0; repeat(2)@(negedge clk);

        // ---- Load weights: ch0 only, all 32 rows use ch0 for 64 OFM channels ----
        $display("=== Load weights ===");
        for (cc=0; cc<32; cc=cc+1) begin
            wtmp=0;
            for (rr=0; rr<32; rr=rr+1) begin
                w0b = (rr<9) ? (cc+1) : 0;  // rows 0-8: ch0 weights; rows 9-31: 0
                w1b = (rr<9) ? (rr+1) : 0;
                wtmp = wtmp | ({w1b,w0b} << (rr*16));
            end
            wgt_wr_data=wtmp; wgt_wr_en={32{1'b1}}; @(negedge clk);
        end
        wgt_wr_en=0;

        // ---- Init bias to 0 ----
        bias_en=1; bias_data=0;
        for(i=0;i<64;i=i+1) begin bias_addr=i[5:0]; @(negedge clk); end
        bias_en=0;

        // ---- DMA stream IFM: 5x5 pattern, 1 channel (bank0) ----
        $display("=== DMA stream 5x5 IFM ===");
        dma_bank_wr_en = 5'b00001;  // only bank0 active
        for (int y=0; y<FM_H; y=y+1) begin
            dma_wr_fy = y;
            for (int x=0; x<FM_W; x=x+1) begin
                dma_wr_x=x[8:0]; dma_wr_data[0]=y*10+x; @(negedge clk);
            end
            if (y<FM_H-1) begin dma_line_advance=1; @(negedge clk); dma_line_advance=0; end
        end
        dma_bank_wr_en=0;

        // ---- Start compute + iterate windows ----
        $display("=== Start compute ===");
        @(negedge clk); start=1; @(negedge clk); start=0;
        repeat(5) @(negedge clk);  // let weight load pipeline settle

        // Slide window across 3×3 output (valid: oy=0..2, ox=0..2)
        // Manually: oy=0, ox=0,1,2 → oy=1, ox=0,1,2 → oy=2, ox=0,1,2
        for (int py=0; py<3; py=py+1) begin
            for (int px=0; px<3; px=px+1) begin
                oy=py[8:0]; ox=px[8:0];
                @(negedge clk);
            end
        end

        // Wait for pipeline drain
        repeat (200) @(negedge clk);

        // ---- Verify PSUM FIFOs ----
        $display("=== Drain PSUM FIFOs ===");
        // TODO: read PSUM entries and verify

        $display("=== %0d pass, %0d fail ===", pass, fail); $finish;
    end
endmodule

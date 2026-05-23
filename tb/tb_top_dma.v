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

        // ---- Start compute ----
        $display("=== Start compute ===");
        @(negedge clk); start=1; @(negedge clk); start=0;

        // Wait for weight load (32 cycles) + compute_active start
        // Then IFM stagger begins: row 0 reads at compute_active posedge
        // Window positions must arrive during compute_active
        repeat (60) @(negedge clk);  // wait for weight load + pipeline init
        $display("  compute_active=%0d", u_top.done);

        // Slide window for oy=0 only (only 3 rows in line buffer)
        // Probe window extractor output BEFORE feeding window positions
        $display("  we_ifm_data[7:0]=%0d we_valid=%0d", u_top.we_ifm_data[7:0], u_top.we_ifm_valid);
        $display("  ifm_empty[0]=%0d ifm_full[0]=%0d", u_top.ifm_fifo_empty[0], ifm_full[0]);

        for (int px=0; px<3; px=px+1) begin
            oy=0; ox=px[8:0];
            @(negedge clk);
        end

        // Wait for pipeline to process and drain
        repeat (400) @(negedge clk);

        // ---- Verify PSUM FIFOs ----
        // Only oy=0 has valid data (fy=0,1,2 all in line buffer).
        // 3 pixels: (0,0),(0,1),(0,2), each 1 IFM FIFO entry.
        // Drain garbage entries from pipeline fill, then verify 3 pixels.
        $display("=== Drain & Verify PSUM FIFOs ===");

        // Skip pipeline fill entries (~220, data arrives ~220 cycles in)
        for (i=0; i<220; i=i+1) begin psum_rd_en={32{1'b1}}; @(negedge clk); end
        psum_rd_en=0; @(negedge clk);

        // Pixel (0,0): IFM sum = 0+1+2+10+11+12+20+21+22 = 99
        // psuma[c]=(c+1)*99, psumb[c]=1*0+2*1+3*2+4*10+5*11+6*12+7*20+8*21+9*22=681
        $display("=== Pixel (0,0) ===");
        psum_rd_en=5'b00001; @(negedge clk); psum_rd_en=0; @(negedge clk);
        $display("  col0: a=%0d exp=99  b=%0d exp=681", psum_rd_data[23:0], psum_rd_data[47:24]);
        if(psum_rd_data[23:0]  !== 99)  begin $display("[FAIL] p0a"); fail=fail+1; end else pass=pass+1;
        if(psum_rd_data[47:24] !== 681) begin $display("[FAIL] p0b"); fail=fail+1; end else pass=pass+1;

        // Pixel (0,1): IFM sum = 1+2+3+11+12+13+21+22+23 = 108
        // psumb = 1*1+2*2+3*3+4*11+5*12+6*13+7*21+8*22+9*23 = 726
        $display("=== Pixel (0,1) ===");
        psum_rd_en=5'b00001; @(negedge clk); psum_rd_en=0; @(negedge clk);
        $display("  col0: a=%0d exp=108  b=%0d exp=726", psum_rd_data[23:0], psum_rd_data[47:24]);
        if(psum_rd_data[23:0]  !== 108) begin $display("[FAIL] p1a"); fail=fail+1; end else pass=pass+1;
        if(psum_rd_data[47:24] !== 726) begin $display("[FAIL] p1b"); fail=fail+1; end else pass=pass+1;

        // Pixel (0,2): IFM sum = 2+3+4+12+13+14+22+23+24 = 117
        // psumb = 1*2+2*3+3*4+4*12+5*13+6*14+7*22+8*23+9*24 = 771
        $display("=== Pixel (0,2) ===");
        psum_rd_en=5'b00001; @(negedge clk); psum_rd_en=0; @(negedge clk);
        $display("  col0: a=%0d exp=117  b=%0d exp=771", psum_rd_data[23:0], psum_rd_data[47:24]);
        if(psum_rd_data[23:0]  !== 117) begin $display("[FAIL] p2a"); fail=fail+1; end else pass=pass+1;
        if(psum_rd_data[47:24] !== 771) begin $display("[FAIL] p2b"); fail=fail+1; end else pass=pass+1;

        $display("=== %0d pass, %0d fail ===", pass, fail); $finish;
    end
endmodule

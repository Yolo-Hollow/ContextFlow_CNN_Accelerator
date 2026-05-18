// Focused test: pre-fill FIFOs → load array → feed IFM → read PSUM FIFOs
// Bypasses RAM models, FSM, and complex drain logic
`timescale 1ns / 1ps

module tb_systolic_fifo_array;
    localparam ROWS = 32, COLS = 32;
    localparam IFM_W = 8, WGT_W = 8, PSUM_W = 24;
    localparam IFM_D = 256, IFM_AW = 8, WGT_D = 64, WGT_AW = 6, PSUM_D = 256, PSUM_AW = 8;

    reg clk, rst;

    // IFM FIFOs
    reg [ROWS*IFM_W-1:0]     ifm_wr_data;
    reg [31:0]               ifm_wr_en, ifm_rd_en;
    wire [ROWS*IFM_W-1:0]    ifm_rd_data;
    wire [31:0]              ifm_empty;

    // Weight FIFOs
    reg [ROWS*WGT_W*2-1:0]   wgt_wr_data;
    reg [31:0]               wgt_wr_en, wgt_rd_en;
    wire [ROWS*WGT_W*2-1:0]  wgt_rd_data;

    // PSUM FIFOs
    wire [COLS*PSUM_W*2-1:0] psum_rd_data;
    reg [31:0]               psum_rd_en;
    wire [31:0]              psum_empty;

    // Array
    reg w_load; reg [4:0] w_col;
    wire [COLS*2*PSUM_W-1:0] psum_bot;

    genvar c;
    generate
        for (c = 0; c < ROWS; c = c + 1) begin : ifm_gen
            systolic_fifo #(.WIDTH(IFM_W),.DEPTH(IFM_D),.AW(IFM_AW))
            u_fifo (.clk(clk),.rst(rst),.wr_en(ifm_wr_en[c]),.rd_en(ifm_rd_en[c]),
                    .data_in(ifm_wr_data[(c+1)*IFM_W-1:c*IFM_W]),
                    .data_out(ifm_rd_data[(c+1)*IFM_W-1:c*IFM_W]),
                    .empty(ifm_empty[c]),.full());
        end
        for (c = 0; c < ROWS; c = c + 1) begin : wgt_gen
            systolic_fifo #(.WIDTH(WGT_W*2),.DEPTH(WGT_D),.AW(WGT_AW))
            u_fifo (.clk(clk),.rst(rst),.wr_en(wgt_wr_en[c]),.rd_en(wgt_rd_en[c]),
                    .data_in(wgt_wr_data[(c+1)*WGT_W*2-1:c*WGT_W*2]),
                    .data_out(wgt_rd_data[(c+1)*WGT_W*2-1:c*WGT_W*2]),
                    .empty(),.full());
        end
        for (c = 0; c < COLS; c = c + 1) begin : psum_gen
            systolic_fifo #(.WIDTH(PSUM_W*2),.DEPTH(PSUM_D),.AW(PSUM_AW))
            u_fifo (.clk(clk),.rst(rst),.wr_en(1'b1),  // always write
                    .rd_en(psum_rd_en[c]),
                    .data_in(psum_bot[(c*2+2)*PSUM_W-1:c*2*PSUM_W]),
                    .data_out(psum_rd_data[(c+1)*PSUM_W*2-1:c*PSUM_W*2]),
                    .empty(psum_empty[c]),.full());
        end
    endgenerate

    systolic_array_32x32 #(.ROWS(ROWS),.COLS(COLS)) u_arr (
        .clk(clk),.rst(rst),.w_load(w_load),.w_col(w_col),
        .w_row_data(wgt_rd_data),.ifm_in_flat(ifm_rd_data),
        .psum_top_flat({COLS*2*PSUM_W{1'b0}}),.psum_bot_flat(psum_bot)
    );

    always #5 clk=~clk;

    integer ii, rr, cc, pass, fail;
    reg [7:0] w0b, w1b;
    reg [511:0] wtmp;

    initial begin
        clk=0; rst=1; pass=0; fail=0;
        w_load=0; w_col=0; ifm_wr_en=0; ifm_wr_data=0; ifm_rd_en=0;
        wgt_wr_en=0; wgt_wr_data=0; wgt_rd_en=0; psum_rd_en=0;

        repeat(3) @(negedge clk); rst=0; @(negedge clk); @(negedge clk);

        // ---- 1: Fill Weight FIFOs (32 entries, col 0..31) ----
        $display("=== 1: Fill Weight FIFOs ===");
        for (cc=0; cc<32; cc=cc+1) begin
            wtmp=0;
            for (rr=0; rr<32; rr=rr+1) begin
                w0b=cc+1; w1b=rr+1;
                wtmp = wtmp | ({w0b, w1b} << (rr*16));
            end
            wgt_wr_data = wtmp;
            wgt_wr_en = {32{1'b1}};
            @(negedge clk);
        end
        wgt_wr_en = 0;

        // ---- 2: Load weights into array (32 cycles) ----
        $display("=== 2: Load weights into array ===");
        w_load=1; wgt_rd_en={32{1'b1}};
        for (cc=0; cc<32; cc=cc+1) begin w_col=cc[4:0]; @(negedge clk); end
        w_load=0; wgt_rd_en=0;

        // ---- 3: Fill IFM FIFOs (400 entries, all 1s) ----
        $display("=== 3: Fill IFM FIFOs ===");
        ifm_wr_data = {ROWS{8'd1}}; ifm_wr_en = {32{1'b1}};
        for (ii=0; ii<400; ii=ii+1) @(negedge clk);
        ifm_wr_en = 0;

        // ---- 4: Feed IFM with stagger, run array ----
        $display("=== 4: Staggered IFM feed ===");
        for (ii=0; ii<600; ii=ii+1) begin
            ifm_rd_en = 0;
            for (rr=0; rr<32; rr=rr+1)
                if (ii >= rr*5) ifm_rd_en[rr] = 1'b1;
            @(negedge clk);
        end
        ifm_rd_en = 0;

        // ---- 5: Read PSUM FIFOs & verify ----
        $display("=== 5: Read & Verify PSUM FIFOs ===");
        for (cc=0; cc<32; cc=cc+1) begin
            psum_rd_en = (1'b1 << cc);
            @(negedge clk);
            psum_rd_en = 0;
            @(negedge clk);
            // After read, psum_rd_data has the column's 48-bit entry
            $display("  col%0d: empty=%0d", cc, psum_empty[cc]);
        end

        $display("=== Done (0 empty = all FIFOs have data) ===");
        $finish;
    end
endmodule

// Systolic accelerator top — FIFO-buffered architecture
// 32 IFM FIFOs (8b) + 32 Weight FIFOs (16b) + 32 PSUM FIFOs (48b)
// Large RAM bursts are decoupled from the systolic array via FIFOs
module systolic_top #(
    parameter ROWS = 32,
    parameter COLS = 32,
    parameter IFM_W = 8,
    parameter WEIGHT_W = 8,
    parameter PSUM_W = 24,
    // RAM address widths
    parameter IFM_RAM_AW  = 12,      // IFM RAM depth (4096 x 256b)
    parameter WGT_RAM_AW  = 7,       // Weight RAM depth (128 x 512b)
    parameter PSUM_RAM_AW = 5,       // PSUM RAM depth (32 x 48b, one per column)
    // FIFO depths
    parameter IFM_FIFO_DEPTH  = 256,
    parameter IFM_FIFO_AW     = 8,
    parameter WGT_FIFO_DEPTH  = 64,
    parameter WGT_FIFO_AW     = 6,
    parameter PSUM_FIFO_DEPTH = 256,
    parameter PSUM_FIFO_AW    = 8
) (
    input  clk, rst,
    input  start,
    output done,

    // ---- IFM RAM (burst read, 256-bit) ----
    output ifm_ram_rd_en,
    output [IFM_RAM_AW-1:0] ifm_ram_rd_addr,
    input  [ROWS*IFM_W-1:0] ifm_ram_rd_data,

    // ---- Weight RAM (burst read, 512-bit) ----
    output wgt_ram_rd_en,
    output [WGT_RAM_AW-1:0] wgt_ram_rd_addr,
    input  [ROWS*WEIGHT_W*2-1:0] wgt_ram_rd_data,

    // ---- PSUM RAM (burst write, 48-bit per entry) ----
    output psum_ram_wr_en,
    output [PSUM_RAM_AW-1:0] psum_ram_wr_addr,
    output [PSUM_W*2-1:0] psum_ram_wr_data,     // 48-bit: 2 OFM channels per column
    output psum_ram_rd_en,
    output [PSUM_RAM_AW-1:0] psum_ram_rd_addr,
    input  [PSUM_W-1:0] psum_ram_rd_data
);
    // ================================================================
    // Control
    // ================================================================
    wire ctrl_wgt_prefill, ctrl_w_load, ctrl_done;
    wire [4:0] ctrl_w_col;
    wire compute_active;

    systolic_ctrl #(.ROWS(ROWS), .COLS(COLS)) u_ctrl (
        .clk(clk), .rst(rst), .start(start),
        .wgt_prefill(ctrl_wgt_prefill), .w_load(ctrl_w_load), .w_col(ctrl_w_col),
        .compute_active(compute_active), .done(ctrl_done)
    );
    assign done = ctrl_done;

    // ================================================================
    // Weight: pre-fill 32 FIFOs from RAM (32 cycles) → array drains (32 cycles)
    // ================================================================
    reg [WGT_RAM_AW-1:0] wgt_ram_addr;
    always @(posedge clk) begin
        if (rst)                           wgt_ram_addr <= {WGT_RAM_AW{1'b0}};
        else if (ctrl_wgt_prefill)         wgt_ram_addr <= wgt_ram_addr + 1'b1;
        else                               wgt_ram_addr <= {WGT_RAM_AW{1'b0}};
    end
    assign wgt_ram_rd_en   = ctrl_wgt_prefill;
    assign wgt_ram_rd_addr = wgt_ram_addr;

    wire [ROWS*WEIGHT_W*2-1:0] wgt_fifo_data_out;
    genvar r;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : wgt_fifo_gen
            systolic_fifo #(.WIDTH(WEIGHT_W*2), .DEPTH(WGT_FIFO_DEPTH), .AW(WGT_FIFO_AW))
            u_wgt_fifo (
                .clk(clk), .rst(rst),
                .wr_en(ctrl_wgt_prefill),
                .rd_en(ctrl_w_load),
                .data_in (wgt_ram_rd_data[(r+1)*WEIGHT_W*2-1 : r*WEIGHT_W*2]),
                .data_out(wgt_fifo_data_out[(r+1)*WEIGHT_W*2-1 : r*WEIGHT_W*2]),
                .empty(), .full()
            );
        end
    endgenerate

    // ================================================================
    // IFM: 32 x 8-bit FIFOs → array (staggered read)
    // ================================================================
    reg ifm_ram_rd_en_reg;
    reg [IFM_RAM_AW-1:0] ifm_ram_addr_reg;
    wire [31:0] ifm_fifo_empty;
    reg  [7:0] ifm_start_cnt;          // count up to 155 (31*5) for stagger init
    reg        ifm_all_active;

    always @(posedge clk) begin
        if (rst) begin
            ifm_ram_rd_en_reg <= 1'b0;
            ifm_ram_addr_reg  <= {IFM_RAM_AW{1'b0}};
            ifm_start_cnt     <= 6'd0;
            ifm_all_active    <= 1'b0;
        end else if (compute_active) begin
            ifm_ram_rd_en_reg <= 1'b1;
            ifm_ram_addr_reg  <= ifm_ram_addr_reg + 1'b1;
            if (ifm_start_cnt < 6'd31*5) begin
                ifm_start_cnt <= ifm_start_cnt + 6'd1;
            end else begin
                ifm_all_active <= 1'b1;
            end
        end else begin
            ifm_ram_rd_en_reg <= 1'b0;
            ifm_ram_addr_reg  <= {IFM_RAM_AW{1'b0}};
            ifm_start_cnt     <= 6'd0;
            ifm_all_active    <= 1'b0;
        end
    end
    assign ifm_ram_rd_en   = ifm_ram_rd_en_reg;
    assign ifm_ram_rd_addr = ifm_ram_addr_reg;

    wire [ROWS*IFM_W-1:0] ifm_fifo_data_out;
    wire [31:0] ifm_fifo_rd_en;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : ifm_fifo_gen
            // Staggered read: row r starts reading after r*5 cycles
            wire row_active = (ifm_start_cnt >= (r * 5));
            assign ifm_fifo_rd_en[r] = row_active;

            systolic_fifo #(.WIDTH(IFM_W), .DEPTH(IFM_FIFO_DEPTH), .AW(IFM_FIFO_AW))
            u_ifm_fifo (
                .clk(clk), .rst(rst),
                .wr_en(ifm_ram_rd_en_reg),
                .rd_en(ifm_fifo_rd_en[r]),
                .data_in(ifm_ram_rd_data[(r+1)*IFM_W-1 : r*IFM_W]),
                .data_out(ifm_fifo_data_out[(r+1)*IFM_W-1 : r*IFM_W]),
                .empty(ifm_fifo_empty[r]),
                .full()
            );
        end
    endgenerate

    // ================================================================
    // Systolic array
    // ================================================================
    wire [COLS*2*PSUM_W-1:0] psum_top_init = {COLS*2*PSUM_W{1'b0}};
    wire [COLS*2*PSUM_W-1:0] psum_bot;

    systolic_array_32x32 #(.ROWS(ROWS), .COLS(COLS)) u_array (
        .clk(clk), .rst(rst),
        .w_load(ctrl_w_load), .w_col(ctrl_w_col),
        .w_row_data(wgt_fifo_data_out),
        .ifm_in_flat(ifm_fifo_data_out),
        .psum_top_flat(psum_top_init),
        .psum_bot_flat(psum_bot)
    );

    // ================================================================
    // PSUM: array output → 32 x 48-bit FIFOs → RAM
    // ================================================================
    wire [31:0] psum_fifo_wr_en;
    wire [31:0] psum_fifo_empty, psum_fifo_full;

    // Each column's output is valid at a different time due to horizontal skew.
    // The FIFO absorbs this: write whenever the column produces valid data.
    // Col c first valid output: (ROWS*5) + c*4 cycles into COMPUTE phase
    // ROWS*5 = 160 (vertical pipeline), then +4 per column (horizontal pipeline)
    reg  [8:0] psum_base_timer;
    reg  [1:0] psum_sub_cnt;
    reg  [5:0] psum_col_active;
    always @(posedge clk) begin
        if (rst) begin
            psum_base_timer <= 9'd0;
            psum_sub_cnt   <= 2'd0;
            psum_col_active <= 6'd0;
        end else if (compute_active) begin
            if (psum_base_timer >= 9'd155) begin
                if (psum_col_active < 6'd32) begin
                    psum_sub_cnt <= psum_sub_cnt + 2'd1;
                    if (psum_sub_cnt == 2'd3)
                        psum_col_active <= psum_col_active + 6'd1;
                end
            end else begin
                psum_base_timer <= psum_base_timer + 9'd1;
            end
        end else begin
            psum_base_timer <= 9'd0;
            psum_sub_cnt   <= 2'd0;
            psum_col_active <= 6'd0;
        end
    end

    generate
        for (r = 0; r < COLS; r = r + 1) begin : psum_fifo_gen  // r here = column index
            // Write enable: col r is active when psum_col_active > r
            assign psum_fifo_wr_en[r] = (psum_col_active > r) && compute_active;

            systolic_fifo #(.WIDTH(PSUM_W*2), .DEPTH(PSUM_FIFO_DEPTH), .AW(PSUM_FIFO_AW))
            u_psum_fifo (
                .clk(clk), .rst(rst),
                .wr_en(psum_fifo_wr_en[r]),
                .rd_en(psum_ram_wr_en && (psum_ram_wr_addr == r[5:0])),
                .data_in(psum_bot[(r*2+2)*PSUM_W-1 : r*2*PSUM_W]),
                .data_out(psum_ram_wr_data),
                .empty(psum_fifo_empty[r]),
                .full(psum_fifo_full[r])
            );
        end
    endgenerate

    // ---- PSUM RAM read (initial psum values) ----
    // For multi-tile accumulation: read previous psum from RAM
    assign psum_ram_rd_en   = 1'b0;  // disabled for now (single-tile mode)
    assign psum_ram_rd_addr = {PSUM_RAM_AW{1'b0}};

    // ---- PSUM RAM write (after compute, drain FIFOs) ----
    reg [PSUM_RAM_AW-1:0] psum_wr_addr;
    reg                    psum_drain;
    always @(posedge clk) begin
        if (rst) begin
            psum_wr_addr <= {PSUM_RAM_AW{1'b0}};
            psum_drain   <= 1'b0;
        end else if (!compute_active && !ctrl_done) begin
            // Drain phase: write FIFOs out to RAM
            psum_drain <= 1'b0;
            psum_wr_addr <= {PSUM_RAM_AW{1'b0}};
        end else if (psum_drain) begin
            if (psum_wr_addr < {PSUM_RAM_AW{1'b1}})
                psum_wr_addr <= psum_wr_addr + 1'b1;
            else
                psum_drain <= 1'b0;
        end else if (!compute_active && done) begin
            psum_drain <= 1'b1;
        end
    end
    assign psum_ram_wr_en   = psum_drain;
    assign psum_ram_wr_addr = psum_wr_addr;

endmodule

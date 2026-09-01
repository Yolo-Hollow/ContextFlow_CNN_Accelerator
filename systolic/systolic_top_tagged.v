`timescale 1ns / 1ps

// Release datapath for atomic tagged IFM contexts.  Unlike systolic_top, this
// module accepts a ready/valid vector stream from ifm_context_epoch_frontend,
// uses a dual-weight tagged mesh, reserves every column FIFO before admission,
// and completes only when the tagged last result retires from every column.
module systolic_top_tagged #(
    parameter ROWS = 18,
    parameter COLS = 8,
    parameter IFM_W = 8,
    parameter WEIGHT_W = 8,
    parameter PSUM_W = 32,
    parameter EPOCH_W = 8,
    parameter TAG_W = EPOCH_W + 2,
    parameter WGT_FIFO_DEPTH = 64,
    parameter WGT_FIFO_AW = 6,
    parameter PSUM_FIFO_DEPTH = 256,
    parameter PSUM_FIFO_AW = 8,
    parameter RETIRE_DEPTH = 4,
    parameter RETIRE_AW = 2,
    parameter TAIL_CYCLES_CONFIG = 0,
    parameter ENABLE_COLUMN_PSUM = 0,
    parameter ENABLE_WEIGHT_PRELOAD = 0,
    parameter ENABLE_FAST_CONTEXT_HANDOFF = 0
) (
    input  wire                                 clk,
    input  wire                                 rst,
    input  wire                                 start,
    input  wire [15:0]                          num_pixels,
    input  wire [15:0]                          tail_cycles_config,
    input  wire                                 context_admission_ready,
    input  wire                                 context_bank,
    input  wire [EPOCH_W-1:0]                   context_epoch,
    output wire                                 start_ready,
    output wire                                 done,
    output wire                                 compute_fire_out,
    output wire                                 input_issued_done,
    output reg                                  array_retired_done,
    output reg                                  array_retired_bank,
    output reg  [EPOCH_W-1:0]                   array_retired_epoch,
    output wire                                 perf_comp_wload,
    output wire                                 perf_comp_active,
    output wire                                 perf_comp_ifm_stall,
    output wire                                 perf_comp_tail,
    output wire [31:0]                          perf_tail_cycles_configured,

    input  wire [ROWS*IFM_W-1:0]                ifm_vector_data,
    input  wire                                 ifm_vector_valid,
    output wire                                 ifm_vector_ready,
    input  wire                                 ifm_vector_bank,
    input  wire [EPOCH_W-1:0]                   ifm_vector_epoch,
    input  wire                                 ifm_vector_last,

    input  wire [5:0]                           bias_wr_addr,
    input  wire [PSUM_W-1:0]                    bias_wr_data,
    input  wire                                 bias_wr_en,
    input  wire                                 is_first_pass,
    input  wire [COLS*2*PSUM_W-1:0]             psum_top_ext,
    input  wire                                 use_ext_psum,
    input  wire [COLS*2*PSUM_W-1:0]             psum_stream_data,
    input  wire                                 psum_stream_valid,
    input  wire                                 psum_stream_compute_ready,
    input  wire                                 use_psum_stream,
    input  wire [COLS*2*PSUM_W-1:0]             psum_column_stream_data,
    input  wire [COLS-1:0]                      psum_column_stream_valid,
    input  wire                                 use_column_psum_stream,

    input  wire [ROWS-1:0]                      wgt_fifo_wr_en,
    input  wire [ROWS*WEIGHT_W*2-1:0]           wgt_fifo_wr_data,
    input  wire                                 weight_tile_complete,
    output wire                                 weight_tile_complete_ready,
    input  wire                                 weight_context_alloc_valid,
    input  wire                                 weight_context_alloc_bank,
    input  wire [EPOCH_W-1:0]                   weight_context_alloc_epoch,
    output wire                                 weight_context_alloc_ready,
    output wire [ROWS-1:0]                      wgt_fifo_full,

    input  wire [31:0]                          psum_fifo_rd_en,
    output wire [COLS*PSUM_W*2-1:0]             psum_fifo_rd_data,
    output wire [COLS*TAG_W-1:0]                psum_fifo_rd_tag,
    output wire [31:0]                          psum_fifo_empty,
    output wire [31:0]                          psum_fifo_wr_en_dbg,

    output reg  [31:0]                          psum_credit_stall_cycles,
    output reg  [31:0]                          weight_ownership_stall_cycles,
    output reg  [31:0]                          epoch_mismatch_count,
    output reg  [31:0]                          context_mismatch_count,
    output reg  [31:0]                          ifm_underflow_count,
    output reg  [31:0]                          psum_underflow_count,
    output reg  [31:0]                          fifo_drop_count,
    output wire [31:0]                          tagged_error_status,
    output wire                                 fatal_error
);
    localparam [PSUM_FIFO_AW:0] PSUM_DEPTH_COUNT = PSUM_FIFO_DEPTH;
    localparam MESH_TAG_W = 2;
    localparam MESH_TAG_LAST_BIT = 0;
    localparam MESH_TAG_BANK_BIT = 1;

    initial begin
        if (RETIRE_DEPTH != (1 << RETIRE_AW))
            $error("systolic_top_tagged RETIRE_DEPTH must equal 2**RETIRE_AW");
        if (ENABLE_COLUMN_PSUM != 0)
            $error("systolic_top_tagged does not support legacy column PSUM");
        if (TAG_W != EPOCH_W + 2)
            $error("systolic_top_tagged full TAG_W must equal EPOCH_W+2");
        if ((ENABLE_FAST_CONTEXT_HANDOFF != 0) &&
            (ENABLE_WEIGHT_PRELOAD == 0))
            $error("systolic_top_tagged fast handoff requires weight preload");
    end

    reg active_context_q;
    reg active_context_bank_q;
    reg [EPOCH_W-1:0] active_context_epoch_q;
    reg [15:0] active_expected_q;
    reg active_is_first_pass_q;
    reg active_use_ext_psum_q;
    reg active_use_psum_stream_q;
    reg active_use_column_psum_stream_q;
    reg [15:0] input_count_q;
    reg [1:0] weight_bank_busy_q;
    reg [1:0] weight_epoch_valid_q;
    reg [EPOCH_W-1:0] weight_epoch_bank0_q;
    reg [EPOCH_W-1:0] weight_epoch_bank1_q;
    // The two epoch mappings stay live until their corresponding tagged last
    // result has reached every column result FIFO.  Only the bank selector and
    // last marker traverse the dense mesh; the full ABI tag is restored at
    // the bottom edge from this ownership table.
    reg [1:0] mesh_epoch_valid_q;
    reg [EPOCH_W-1:0] mesh_epoch_bank0_q;
    reg [EPOCH_W-1:0] mesh_epoch_bank1_q;
    reg fatal_error_q;

    localparam RETIRE_DESC_W = EPOCH_W + 1;
    reg [RETIRE_DESC_W-1:0] retire_mem [0:RETIRE_DEPTH-1];
    reg [RETIRE_AW-1:0] retire_wr_ptr_q;
    reg [RETIRE_AW-1:0] retire_rd_ptr_q;
    reg [RETIRE_AW:0] retire_count_q;
    reg [RETIRE_DEPTH-1:0] retire_valid_q;
    reg [COLS-1:0] retire_mask_q [0:RETIRE_DEPTH-1];
    wire retire_empty = retire_count_q == 0;
    wire retire_full = retire_count_q == RETIRE_DEPTH;
    wire [RETIRE_DESC_W-1:0] retire_head =
        retire_mem[retire_rd_ptr_q];
    wire retire_head_bank = retire_head[0];
    wire [EPOCH_W-1:0] retire_head_epoch =
        retire_head[RETIRE_DESC_W-1:1];

    wire ctrl_compute_active;
    wire ctrl_compute_fire;
    wire ctrl_w_load;
    wire [4:0] ctrl_w_col;
    wire ctrl_tail_watchdog;
    wire ctrl_start_busy_error;
    wire ctrl_start_ready;
    wire preload_fatal_error;
    wire preload_start_ready;
    wire preload_wgt_fifo_rd;
    wire array_w_load;
    wire [4:0] array_w_col;
    wire array_w_bank;
    wire [ROWS*WEIGHT_W*2-1:0] array_w_row_data;
    wire [1:0] preload_bank_ready;
    wire [1:0] preload_bank_active;
    wire [1:0] preload_bank_epoch_valid;
    wire [EPOCH_W-1:0] preload_bank0_epoch;
    wire [EPOCH_W-1:0] preload_bank1_epoch;
    wire preload_sticky_protocol;
    wire preload_sticky_owner;
    wire preload_sticky_epoch;
    wire preload_start_fire;
    wire preload_retire_match;
    wire retire_pop;
    wire retire_push_ready;
    wire retire_start_credit;
    reg [4:0] w_col_q;
    wire start_fire = start && start_ready;
    wire all_output_credit_available;
    wire context_stream_match =
        (ifm_vector_bank == active_context_bank_q) &&
        (ifm_vector_epoch == active_context_epoch_q);
    wire active_weight_epoch_match = (ENABLE_WEIGHT_PRELOAD != 0) ?
        (preload_bank_active[active_context_bank_q] &&
         preload_bank_epoch_valid[active_context_bank_q] &&
         (active_context_epoch_q ==
            (active_context_bank_q ? preload_bank1_epoch :
                                     preload_bank0_epoch))) :
        (weight_epoch_valid_q[active_context_bank_q] &&
         (active_context_epoch_q ==
            (active_context_bank_q ? weight_epoch_bank1_q :
                                     weight_epoch_bank0_q)));
    wire psum_input_ready = !active_use_psum_stream_q ||
        psum_stream_compute_ready;
    wire expected_stream_last =
        input_count_q == active_expected_q - 1'b1;
    wire final_input_fire = ctrl_compute_fire && expected_stream_last;
    wire retire_push = final_input_fire;
    wire datapath_fatal = fatal_error_q || preload_fatal_error;
    wire fast_active_handoff = (ENABLE_FAST_CONTEXT_HANDOFF != 0) &&
        active_context_q && ctrl_start_ready;
    wire active_slot_ready = !active_context_q || fast_active_handoff;
    wire selected_weight_ready = (ENABLE_WEIGHT_PRELOAD != 0) ?
        preload_start_ready :
        (!weight_bank_busy_q[context_bank]);
    wire compute_ready = ifm_vector_valid && context_stream_match &&
        active_weight_epoch_match && context_admission_ready &&
        psum_input_ready && all_output_credit_available && !datapath_fatal;
    assign start_ready = ctrl_start_ready && active_slot_ready &&
        retire_start_credit && !datapath_fatal && selected_weight_ready &&
        !mesh_epoch_valid_q[context_bank];

    systolic_ctrl_tagged #(
        .ROWS(ROWS),
        .COLS(COLS),
        .TAIL_CYCLES_CONFIG(TAIL_CYCLES_CONFIG),
        .ENABLE_PRELOADED_WEIGHT(ENABLE_WEIGHT_PRELOAD),
        .ENABLE_FAST_HANDOFF(ENABLE_FAST_CONTEXT_HANDOFF),
        .ARRAY_PIPELINE_LATENCY(ROWS + 2)
    ) u_ctrl (
        .clk(clk),
        .rst(rst),
        .start(start_fire),
        .num_pixels(num_pixels),
        .tail_cycles_config(tail_cycles_config),
        .compute_ready(compute_ready),
        .array_retired(array_retired_done),
        .start_ready(ctrl_start_ready),
        .done(done),
        .w_load(ctrl_w_load),
        .w_col(ctrl_w_col),
        .compute_active(ctrl_compute_active),
        .compute_fire(ctrl_compute_fire),
        .input_issued_done(input_issued_done),
        .perf_comp_wload(perf_comp_wload),
        .perf_comp_active(perf_comp_active),
        .perf_comp_ifm_stall(perf_comp_ifm_stall),
        .perf_comp_tail(perf_comp_tail),
        .tail_cycles_configured(perf_tail_cycles_configured),
        .tail_watchdog_expired(ctrl_tail_watchdog),
        .start_while_busy_error(ctrl_start_busy_error)
    );
    assign compute_fire_out = ctrl_compute_fire;
    assign ifm_vector_ready = ctrl_compute_fire;

    // The release path drains each complete weight tile into the inactive PE
    // bank in the background.  The legacy path retains its historical
    // start-triggered synchronous-FIFO warmup and sixteen-cycle load.
    reg [5:0] wgt_reads_left_q;
    wire legacy_wgt_fifo_rd = start_fire ||
        (ctrl_w_load && (wgt_reads_left_q != 6'd0));
    wire wgt_fifo_rd = (ENABLE_WEIGHT_PRELOAD != 0) ?
        preload_wgt_fifo_rd : legacy_wgt_fifo_rd;
    wire [ROWS*WEIGHT_W*2-1:0] wgt_fifo_rd_data;
    wire [ROWS-1:0] wgt_fifo_empty;
    integer weight_idx;
    always @(posedge clk) begin
        if (rst)
            wgt_reads_left_q <= 6'd0;
        else if (start_fire)
            wgt_reads_left_q <= COLS - 1;
        else if (ctrl_w_load && (wgt_reads_left_q != 6'd0))
            wgt_reads_left_q <= wgt_reads_left_q - 1'b1;
    end

    genvar gr;
    generate
        for (gr = 0; gr < ROWS; gr = gr + 1) begin : weight_fifo_gen
            systolic_fifo #(
                .WIDTH(WEIGHT_W*2),
                .DEPTH(WGT_FIFO_DEPTH),
                .AW(WGT_FIFO_AW)
            ) u_wgt_fifo (
                .clk(clk),
                .rst(rst),
                .wr_en(wgt_fifo_wr_en[gr]),
                .rd_en(wgt_fifo_rd),
                .data_in(wgt_fifo_wr_data[(gr+1)*WEIGHT_W*2-1:gr*WEIGHT_W*2]),
                .data_out(wgt_fifo_rd_data[(gr+1)*WEIGHT_W*2-1:gr*WEIGHT_W*2]),
                .empty(wgt_fifo_empty[gr]),
                .full(wgt_fifo_full[gr])
            );
        end
    endgenerate

    generate
        if (ENABLE_WEIGHT_PRELOAD != 0) begin : g_weight_preload
            weight_context_preloader #(
                .ROWS(ROWS), .COLS(COLS), .EPOCH_W(EPOCH_W)
            ) u_weight_preloader (
                .clk(clk), .rst(rst), .soft_reset(1'b0),
                .alloc_valid(weight_context_alloc_valid),
                .alloc_ready(weight_context_alloc_ready),
                .alloc_bank(weight_context_alloc_bank),
                .alloc_epoch(weight_context_alloc_epoch),
                .weight_tile_credit_valid(weight_tile_complete),
                .weight_tile_credit_ready(weight_tile_complete_ready),
                .weight_credit_level(),
                .row_fifo_empty(wgt_fifo_empty),
                .row_fifo_rd_en(preload_wgt_fifo_rd),
                .row_fifo_rd_data(wgt_fifo_rd_data),
                .array_w_load(array_w_load),
                .array_w_col(array_w_col),
                .array_w_bank(array_w_bank),
                .array_w_row_data(array_w_row_data),
                .start_valid(start_fire),
                .start_ready(preload_start_ready),
                .start_fire(preload_start_fire),
                .start_bank(context_bank), .start_epoch(context_epoch),
                .retire_valid(retire_pop),
                .retire_match(preload_retire_match),
                .retire_bank(retire_head_bank),
                .retire_epoch(retire_head_epoch),
                .bank_ready(preload_bank_ready),
                .bank_active(preload_bank_active),
                .bank_epoch_valid(preload_bank_epoch_valid),
                .bank0_epoch(preload_bank0_epoch),
                .bank1_epoch(preload_bank1_epoch),
                .bank0_state(), .bank1_state(), .preload_busy(),
                .fatal_error(preload_fatal_error),
                .sticky_protocol_error(preload_sticky_protocol),
                .sticky_owner_error(preload_sticky_owner),
                .sticky_epoch_error(preload_sticky_epoch),
                .alloc_count(), .tile_credit_accept_count(),
                .preload_commit_count(), .array_write_count(),
                .start_match_count(), .start_miss_count(),
                .retire_match_count(), .protocol_error_count(),
                .owner_error_count(), .epoch_error_count()
            );
        end else begin : g_legacy_weight_load
            assign weight_tile_complete_ready = 1'b1;
            assign weight_context_alloc_ready = 1'b1;
            assign preload_wgt_fifo_rd = 1'b0;
            assign array_w_load = ctrl_w_load;
            assign array_w_col = w_col_q;
            assign array_w_bank = active_context_bank_q;
            assign array_w_row_data = wgt_fifo_rd_data;
            assign preload_bank_ready = 2'b00;
            assign preload_bank_active = 2'b00;
            assign preload_bank_epoch_valid = 2'b00;
            assign preload_bank0_epoch = {EPOCH_W{1'b0}};
            assign preload_bank1_epoch = {EPOCH_W{1'b0}};
            assign preload_sticky_protocol = 1'b0;
            assign preload_sticky_owner = 1'b0;
            assign preload_sticky_epoch = 1'b0;
            assign preload_start_ready = 1'b1;
            assign preload_start_fire = 1'b0;
            assign preload_retire_match = 1'b0;
            assign preload_fatal_error = 1'b0;
        end
    endgenerate

    reg [PSUM_W-1:0] bias_buf [0:63];
    always @(posedge clk) begin
        if (bias_wr_en)
            bias_buf[bias_wr_addr] <= bias_wr_data;
    end

    wire [COLS*2*PSUM_W-1:0] psum_top_int;
    genvar gi;
    generate
        for (gi = 0; gi < COLS*2; gi = gi + 1) begin : bias_mux
            assign psum_top_int[(gi+1)*PSUM_W-1:gi*PSUM_W] =
                active_is_first_pass_q ? bias_buf[gi] : {PSUM_W{1'b0}};
        end
    endgenerate

    wire [COLS*2*PSUM_W-1:0] psum_top_static =
        active_use_ext_psum_q ? psum_top_ext : psum_top_int;
    wire column_psum_active = (ENABLE_COLUMN_PSUM != 0) &&
        active_use_column_psum_stream_q;
    wire [MESH_TAG_W-1:0] stream_mesh_tag = {
        ifm_vector_bank, ifm_vector_last
    };
    // The no-delay array row fans directly into every scalar lane.  Keep the
    // synthesis replication target explicit so non-preloaded ablation builds
    // do not leave one routed source driving all DSP input slices.
    (* max_fanout = 8 *) reg [ROWS*IFM_W-1:0] issued_ifm_data_q;
    reg [MESH_TAG_W-1:0] issued_mesh_tag_q;
    reg issued_valid_q;
    reg issued_use_column_psum_q;
    reg issued_use_psum_stream_q;
    reg [COLS*2*PSUM_W-1:0] issued_static_psum_seed_q;
    always @(posedge clk) begin
        if (rst) begin
            issued_ifm_data_q <= {ROWS*IFM_W{1'b0}};
            issued_mesh_tag_q <= {MESH_TAG_W{1'b0}};
            issued_valid_q <= 1'b0;
            issued_use_column_psum_q <= 1'b0;
            issued_use_psum_stream_q <= 1'b0;
            issued_static_psum_seed_q <= {COLS*2*PSUM_W{1'b0}};
        end else begin
            issued_valid_q <= ctrl_compute_fire;
            if (ctrl_compute_fire) begin
                issued_ifm_data_q <= ifm_vector_data;
                issued_mesh_tag_q <= stream_mesh_tag;
                // These controls belong to the accepted token.  A fast
                // handoff may replace active_context_* on this same edge, so
                // selecting the seed from live context state one cycle later
                // would pair the old final IFM with the new pass's PSUM mode.
                issued_use_column_psum_q <= column_psum_active;
                issued_use_psum_stream_q <= active_use_psum_stream_q;
                issued_static_psum_seed_q <= psum_top_static;
            end
        end
    end

    // The PSUM replay feeder and the issued IFM register both present the
    // accepted pixel one cycle after compute_fire.  The scalar cascade takes
    // that atomic vector directly; no per-column or per-row external skew is
    // required.  A missing seed is fatal because output credit has already
    // been reserved for this token and no later retry is possible.
    wire [COLS*2*PSUM_W-1:0] atomic_psum_seed =
        issued_use_column_psum_q ?
        psum_column_stream_data :
        (issued_use_psum_stream_q ? psum_stream_data :
                                  issued_static_psum_seed_q);
    wire atomic_psum_seed_valid = issued_use_column_psum_q ?
        (&psum_column_stream_valid) :
        (issued_use_psum_stream_q ? psum_stream_valid : issued_valid_q);
    wire atomic_seed_valid_mismatch =
        issued_valid_q != atomic_psum_seed_valid;
    wire atomic_token_valid = issued_valid_q && atomic_psum_seed_valid;

    always @(posedge clk)
        w_col_q <= ctrl_w_col;

    wire [COLS*2*PSUM_W-1:0] psum_bot;
    wire [COLS*2-1:0] valid_v_bot;
    wire [COLS*MESH_TAG_W-1:0] mesh_tag_v_bot;
    // Full, reconstructed tags retain the historical internal name so
    // retirement logic and focused verification observe the ABI tag rather
    // than the compressed mesh representation.
    wire [COLS*TAG_W-1:0] tag_v_bot;
    wire [COLS-1:0] mesh_epoch_map_valid;
    wire [COLS-1:0] invalid_mesh_epoch_result;
    wire array_tag_mismatch_event;
    wire array_weight_write_collision_event;

    wire cascade_result_valid;
    wire [MESH_TAG_W-1:0] cascade_result_tag;
    wire cascade_tag_mismatch_event;
    wire cascade_weight_write_collision_event;

    systolic_array_dsp_cascade_tagged #(
        .ROWS(ROWS),
        .COLS(COLS),
        .IFM_W(IFM_W),
        .WEIGHT_W(WEIGHT_W),
        .PSUM_W(PSUM_W),
        .TAG_W(MESH_TAG_W),
        .LOCALIZE_A1_IFM_BITS(ENABLE_WEIGHT_PRELOAD == 0)
    ) u_array (
        .clk(clk),
        .rst(rst),
        .w_load(array_w_load),
        .w_col(array_w_col),
        .w_bank(array_w_bank),
        .w_row_data(array_w_row_data),
        .ifm_vector_flat(issued_ifm_data_q),
        .seed_psum_flat(atomic_psum_seed),
        .token_valid(atomic_token_valid),
        .token_tag(issued_mesh_tag_q),
        .result_psum_flat(psum_bot),
        .result_valid(cascade_result_valid),
        .result_tag(cascade_result_tag),
        .tag_mismatch_event(cascade_tag_mismatch_event),
        .weight_write_collision_event(
            cascade_weight_write_collision_event)
    );

    assign array_tag_mismatch_event = cascade_tag_mismatch_event ||
        atomic_seed_valid_mismatch;
    assign array_weight_write_collision_event =
        cascade_weight_write_collision_event;

    genvar gc;
    generate
        for (gc = 0; gc < COLS; gc = gc + 1) begin : cascade_bottom_fanout
            assign valid_v_bot[2*gc] = cascade_result_valid;
            assign valid_v_bot[2*gc+1] = cascade_result_valid;
            assign mesh_tag_v_bot[(gc+1)*MESH_TAG_W-1:gc*MESH_TAG_W] =
                cascade_result_tag;
        end
    endgenerate

    wire [COLS-1:0] psum_fifo_full_int;
    wire [COLS-1:0] psum_fifo_empty_int;
    wire [COLS-1:0] psum_write_attempt;
    wire [COLS-1:0] psum_write_fire;
    wire [COLS-1:0] psum_read_fire;
    wire [COLS-1:0] psum_write_last;
    wire [COLS-1:0] psum_pair_valid_match;
    reg [PSUM_FIFO_AW:0] output_credit_q [0:COLS-1];
    wire [COLS-1:0] output_credit_available;

    generate
        for (gc = 0; gc < COLS; gc = gc + 1) begin : psum_output_fifo
            wire [PSUM_W*2-1:0] fifo_data_out;
            wire [TAG_W-1:0] fifo_tag_out;
            wire [MESH_TAG_W-1:0] bottom_mesh_tag =
                mesh_tag_v_bot[(gc+1)*MESH_TAG_W-1:gc*MESH_TAG_W];
            wire bottom_mesh_bank = bottom_mesh_tag[MESH_TAG_BANK_BIT];
            wire [EPOCH_W-1:0] bottom_epoch = bottom_mesh_bank ?
                mesh_epoch_bank1_q : mesh_epoch_bank0_q;
            wire [TAG_W-1:0] bottom_tag =
                {bottom_epoch, bottom_mesh_tag};
            assign tag_v_bot[(gc+1)*TAG_W-1:gc*TAG_W] = bottom_tag;
            assign mesh_epoch_map_valid[gc] =
                mesh_epoch_valid_q[bottom_mesh_bank];
            assign invalid_mesh_epoch_result[gc] =
                valid_v_bot[2*gc] && !mesh_epoch_map_valid[gc];
            // Do not commit a result whose bank no longer has live epoch
            // ownership.  The sticky error path below stops further issue.
            assign psum_write_attempt[gc] = valid_v_bot[2*gc] &&
                mesh_epoch_map_valid[gc];
            assign psum_write_fire[gc] = psum_write_attempt[gc] &&
                !psum_fifo_full_int[gc];
            assign psum_pair_valid_match[gc] =
                valid_v_bot[2*gc] == valid_v_bot[2*gc+1];
            assign psum_write_last[gc] = psum_write_fire[gc] &&
                bottom_mesh_tag[MESH_TAG_LAST_BIT];
            assign psum_read_fire[gc] = psum_fifo_rd_en[gc] &&
                !psum_fifo_empty_int[gc];
            assign output_credit_available[gc] =
                (output_credit_q[gc] < PSUM_DEPTH_COUNT);

            // Keep the 64-bit PSUM payload within one RAMB36 at the release
            // depth.  A monolithic {tag, data} memory is 74 bits wide for the
            // ABI-v2 tag and therefore spills into a second RAMB36 per column.
            // The split FIFO below shares one pointer pair between two block-
            // RAM stores, so ordering, full/empty behavior, and registered
            // read latency stay atomic.  Keeping the 10-bit tags in RAMB18
            // uses eight additional BRAM tiles at 16 columns, but removes the
            // deep distributed-RAM read muxes from the collector tag checks.
            systolic_result_tagged_fifo #(
                .DATA_W(PSUM_W*2),
                .TAG_W(TAG_W),
                .DEPTH(PSUM_FIFO_DEPTH),
                .AW(PSUM_FIFO_AW)
            ) u_fifo (
                .clk(clk),
                .rst(rst),
                .wr_en(psum_write_fire[gc]),
                .rd_en(psum_fifo_rd_en[gc]),
                .data_in(psum_bot[(gc*2+2)*PSUM_W-1:gc*2*PSUM_W]),
                .tag_in(bottom_tag),
                .data_out(fifo_data_out),
                .tag_out(fifo_tag_out),
                .empty(psum_fifo_empty_int[gc]),
                .full(psum_fifo_full_int[gc])
            );
            assign psum_fifo_rd_data[(gc+1)*PSUM_W*2-1:gc*PSUM_W*2] =
                fifo_data_out;
            assign psum_fifo_rd_tag[(gc+1)*TAG_W-1:gc*TAG_W] =
                fifo_tag_out;

            always @(posedge clk) begin
                if (rst) begin
                    output_credit_q[gc] <= {(PSUM_FIFO_AW+1){1'b0}};
                end else begin
                    case ({ctrl_compute_fire, psum_read_fire[gc]})
                        2'b10: output_credit_q[gc] <=
                            output_credit_q[gc] + 1'b1;
                        2'b01: output_credit_q[gc] <=
                            output_credit_q[gc] - 1'b1;
                        default: output_credit_q[gc] <= output_credit_q[gc];
                    endcase
                end
            end
        end
    endgenerate

    assign all_output_credit_available = &output_credit_available;
    assign psum_fifo_empty =
        {{(32-COLS){1'b0}}, psum_fifo_empty_int};
    assign psum_fifo_wr_en_dbg =
        {{(32-COLS){1'b0}}, psum_write_fire};

    reg [COLS-1:0] retire_match_mask [0:RETIRE_DEPTH-1];
    reg [COLS-1:0] retire_last_match_any;
    reg retire_duplicate_match;
    integer retire_scan_idx;
    integer retire_col_idx;
    always @(*) begin
        retire_last_match_any = {COLS{1'b0}};
        retire_duplicate_match = 1'b0;
        for (retire_scan_idx = 0; retire_scan_idx < RETIRE_DEPTH;
             retire_scan_idx = retire_scan_idx + 1)
            retire_match_mask[retire_scan_idx] = {COLS{1'b0}};
        for (retire_col_idx = 0; retire_col_idx < COLS;
             retire_col_idx = retire_col_idx + 1) begin
            if (psum_write_last[retire_col_idx]) begin
                for (retire_scan_idx = 0;
                     retire_scan_idx < RETIRE_DEPTH;
                     retire_scan_idx = retire_scan_idx + 1) begin
                    if (retire_valid_q[retire_scan_idx] &&
                        (tag_v_bot[retire_col_idx*TAG_W + 1] ==
                            retire_mem[retire_scan_idx][0]) &&
                        (tag_v_bot[retire_col_idx*TAG_W + 2 +: EPOCH_W] ==
                            retire_mem[retire_scan_idx]
                                [RETIRE_DESC_W-1:1])) begin
                        if (retire_last_match_any[retire_col_idx])
                            retire_duplicate_match = 1'b1;
                        retire_last_match_any[retire_col_idx] = 1'b1;
                        retire_match_mask[retire_scan_idx]
                            [retire_col_idx] = 1'b1;
                    end
                end
            end
        end
    end
    wire [COLS-1:0] retire_head_mask_next =
        retire_mask_q[retire_rd_ptr_q] |
        retire_match_mask[retire_rd_ptr_q];
    assign retire_pop = !retire_empty && (&retire_head_mask_next);
    assign retire_push_ready = !retire_full || retire_pop;
    assign retire_start_credit = !retire_full;
    wire retire_push_fire = retire_push && retire_push_ready;

    reg error_weight_ownership_q;
    reg error_weight_epoch_q;
    reg error_context_mismatch_q;
    reg error_fifo_drop_q;
    reg error_output_credit_q;
    reg error_array_retire_q;
    reg error_psum_tag_q;
    assign fatal_error = datapath_fatal;
    assign tagged_error_status =
        ({32{error_weight_ownership_q | preload_sticky_owner}} &
            (32'h1 << 22)) |
        ({32{error_weight_epoch_q | preload_sticky_epoch}} &
            (32'h1 << 23)) |
        ({32{error_context_mismatch_q}} & (32'h1 << 24)) |
        ({32{error_fifo_drop_q | preload_sticky_protocol}} &
            (32'h1 << 25)) |
        ({32{error_output_credit_q}} & (32'h1 << 26)) |
        ({32{error_array_retire_q}} & (32'h1 << 27)) |
        ({32{error_psum_tag_q}} & (32'h1 << 30));

    integer status_idx;
    integer retire_update_idx;
    always @(posedge clk) begin
        if (rst) begin
            active_context_q <= 1'b0;
            active_context_bank_q <= 1'b0;
            active_context_epoch_q <= {EPOCH_W{1'b0}};
            active_expected_q <= 16'd0;
            active_is_first_pass_q <= 1'b0;
            active_use_ext_psum_q <= 1'b0;
            active_use_psum_stream_q <= 1'b0;
            active_use_column_psum_stream_q <= 1'b0;
            input_count_q <= 16'd0;
            weight_bank_busy_q <= 2'b00;
            weight_epoch_valid_q <= 2'b00;
            weight_epoch_bank0_q <= {EPOCH_W{1'b0}};
            weight_epoch_bank1_q <= {EPOCH_W{1'b0}};
            mesh_epoch_valid_q <= 2'b00;
            mesh_epoch_bank0_q <= {EPOCH_W{1'b0}};
            mesh_epoch_bank1_q <= {EPOCH_W{1'b0}};
            retire_wr_ptr_q <= {RETIRE_AW{1'b0}};
            retire_rd_ptr_q <= {RETIRE_AW{1'b0}};
            retire_count_q <= {(RETIRE_AW+1){1'b0}};
            retire_valid_q <= {RETIRE_DEPTH{1'b0}};
            for (retire_update_idx = 0;
                 retire_update_idx < RETIRE_DEPTH;
                 retire_update_idx = retire_update_idx + 1)
                retire_mask_q[retire_update_idx] <= {COLS{1'b0}};
            array_retired_done <= 1'b0;
            array_retired_bank <= 1'b0;
            array_retired_epoch <= {EPOCH_W{1'b0}};
            psum_credit_stall_cycles <= 32'd0;
            weight_ownership_stall_cycles <= 32'd0;
            epoch_mismatch_count <= 32'd0;
            context_mismatch_count <= 32'd0;
            ifm_underflow_count <= 32'd0;
            psum_underflow_count <= 32'd0;
            fifo_drop_count <= 32'd0;
            fatal_error_q <= 1'b0;
            error_weight_ownership_q <= 1'b0;
            error_weight_epoch_q <= 1'b0;
            error_context_mismatch_q <= 1'b0;
            error_fifo_drop_q <= 1'b0;
            error_output_credit_q <= 1'b0;
            error_array_retire_q <= 1'b0;
            error_psum_tag_q <= 1'b0;
        end else begin
            array_retired_done <= 1'b0;

            if (start) begin
                if (!start_ready) begin
                    fatal_error_q <= 1'b1;
                    error_weight_ownership_q <= 1'b1;
                    weight_ownership_stall_cycles <=
                        weight_ownership_stall_cycles + 1'b1;
                end else begin
                    active_context_q <= 1'b1;
                    active_context_bank_q <= context_bank;
                    active_context_epoch_q <= context_epoch;
                    active_expected_q <=
                        (num_pixels == 16'd0) ? 16'd1 : num_pixels;
                    active_is_first_pass_q <= is_first_pass;
                    active_use_ext_psum_q <= use_ext_psum;
                    active_use_psum_stream_q <= use_psum_stream;
                    active_use_column_psum_stream_q <=
                        use_column_psum_stream;
                    input_count_q <= 16'd0;
                    if (ENABLE_WEIGHT_PRELOAD == 0) begin
                        weight_bank_busy_q[context_bank] <= 1'b1;
                        weight_epoch_valid_q[context_bank] <= 1'b1;
                    end
                    mesh_epoch_valid_q[context_bank] <= 1'b1;
                    if (context_bank) begin
                        if (ENABLE_WEIGHT_PRELOAD == 0)
                            weight_epoch_bank1_q <= context_epoch;
                        mesh_epoch_bank1_q <= context_epoch;
                    end else begin
                        if (ENABLE_WEIGHT_PRELOAD == 0)
                            weight_epoch_bank0_q <= context_epoch;
                        mesh_epoch_bank0_q <= context_epoch;
                    end
                end
            end

            if (final_input_fire && !start_fire)
                active_context_q <= 1'b0;

            if (retire_push_fire) begin
                retire_mem[retire_wr_ptr_q] <= {
                    active_context_epoch_q, active_context_bank_q
                };
                retire_wr_ptr_q <= retire_wr_ptr_q + 1'b1;
            end else if (retire_push) begin
                fatal_error_q <= 1'b1;
                error_array_retire_q <= 1'b1;
                context_mismatch_count <= context_mismatch_count + 1'b1;
            end

            if (retire_pop)
                retire_rd_ptr_q <= retire_rd_ptr_q + 1'b1;

            for (retire_update_idx = 0;
                 retire_update_idx < RETIRE_DEPTH;
                 retire_update_idx = retire_update_idx + 1) begin
                if (|retire_match_mask[retire_update_idx])
                    retire_mask_q[retire_update_idx] <=
                        retire_mask_q[retire_update_idx] |
                        retire_match_mask[retire_update_idx];
                if (retire_pop &&
                    (retire_rd_ptr_q == retire_update_idx)) begin
                    retire_valid_q[retire_update_idx] <= 1'b0;
                    retire_mask_q[retire_update_idx] <= {COLS{1'b0}};
                end
                if (retire_push_fire &&
                    (retire_wr_ptr_q == retire_update_idx)) begin
                    retire_valid_q[retire_update_idx] <= 1'b1;
                    retire_mask_q[retire_update_idx] <= {COLS{1'b0}};
                end
            end

            case ({retire_push_fire, retire_pop})
                2'b10: retire_count_q <= retire_count_q + 1'b1;
                2'b01: retire_count_q <= retire_count_q - 1'b1;
                default: retire_count_q <= retire_count_q;
            endcase

            if (ctrl_compute_active && ifm_vector_valid &&
                !context_stream_match) begin
                fatal_error_q <= 1'b1;
                error_context_mismatch_q <= 1'b1;
                context_mismatch_count <= context_mismatch_count + 1'b1;
                epoch_mismatch_count <= epoch_mismatch_count + 1'b1;
            end

            if (ctrl_compute_fire) begin
                if (!(expected_stream_last && start_fire))
                    input_count_q <= input_count_q + 1'b1;
                if (ifm_vector_last != expected_stream_last) begin
                    fatal_error_q <= 1'b1;
                    error_context_mismatch_q <= 1'b1;
                    context_mismatch_count <= context_mismatch_count + 1'b1;
                end
            end

            if (ctrl_compute_active && !all_output_credit_available) begin
                psum_credit_stall_cycles <= psum_credit_stall_cycles + 1'b1;
            end

            if (ctrl_compute_fire && !ifm_vector_valid) begin
                fatal_error_q <= 1'b1;
                ifm_underflow_count <= ifm_underflow_count + 1'b1;
            end

            if (array_tag_mismatch_event) begin
                fatal_error_q <= 1'b1;
                error_psum_tag_q <= 1'b1;
                context_mismatch_count <= context_mismatch_count + 1'b1;
            end
            if (|invalid_mesh_epoch_result) begin
                // A result may only leave the compact-tag mesh while its
                // bank-to-epoch mapping is still owned by a live retirement
                // descriptor.  Suppress the FIFO write and fail closed.
                fatal_error_q <= 1'b1;
                error_psum_tag_q <= 1'b1;
                epoch_mismatch_count <= epoch_mismatch_count + 1'b1;
            end
            if (ctrl_compute_active && ifm_vector_valid &&
                context_stream_match && !active_weight_epoch_match) begin
                fatal_error_q <= 1'b1;
                error_weight_epoch_q <= 1'b1;
                epoch_mismatch_count <= epoch_mismatch_count + 1'b1;
            end
            if (array_weight_write_collision_event || ctrl_start_busy_error) begin
                fatal_error_q <= 1'b1;
                error_weight_ownership_q <= 1'b1;
                weight_ownership_stall_cycles <=
                    weight_ownership_stall_cycles + 1'b1;
            end

            for (status_idx = 0; status_idx < COLS; status_idx = status_idx + 1) begin
                if (psum_write_attempt[status_idx] &&
                    psum_fifo_full_int[status_idx]) begin
                    fatal_error_q <= 1'b1;
                    error_fifo_drop_q <= 1'b1;
                    fifo_drop_count <= fifo_drop_count + 1'b1;
                end
                if (psum_fifo_rd_en[status_idx] &&
                    psum_fifo_empty_int[status_idx]) begin
                    fatal_error_q <= 1'b1;
                    psum_underflow_count <= psum_underflow_count + 1'b1;
                end
                if (!psum_pair_valid_match[status_idx]) begin
                    fatal_error_q <= 1'b1;
                    error_array_retire_q <= 1'b1;
                end
                if (psum_write_last[status_idx] &&
                    !retire_last_match_any[status_idx]) begin
                    fatal_error_q <= 1'b1;
                    error_psum_tag_q <= 1'b1;
                    epoch_mismatch_count <= epoch_mismatch_count + 1'b1;
                end
                if (output_credit_q[status_idx] > PSUM_DEPTH_COUNT) begin
                    fatal_error_q <= 1'b1;
                    error_output_credit_q <= 1'b1;
                end
            end

            if (retire_duplicate_match) begin
                fatal_error_q <= 1'b1;
                error_psum_tag_q <= 1'b1;
                context_mismatch_count <= context_mismatch_count + 1'b1;
            end

            if (retire_pop) begin
                array_retired_done <= 1'b1;
                array_retired_bank <= retire_head_bank;
                array_retired_epoch <= retire_head_epoch;
                if (ENABLE_WEIGHT_PRELOAD == 0) begin
                    weight_bank_busy_q[retire_head_bank] <= 1'b0;
                    weight_epoch_valid_q[retire_head_bank] <= 1'b0;
                end
                mesh_epoch_valid_q[retire_head_bank] <= 1'b0;
            end

            if (ctrl_tail_watchdog && !array_retired_done) begin
                // Diagnostic only: do not manufacture a completion event.
                error_array_retire_q <= 1'b1;
            end
        end
    end
endmodule

// Result FIFO with one atomic control path and physically split memories.
//
// The payload and tag are written and read by the same accepted operations;
// neither memory has an independent pointer or ready condition.  This keeps
// the behavior identical to systolic_fifo, including blocking a write when
// full even if a read is requested on that same cycle, and holding the
// registered outputs across an empty read request.
module systolic_result_tagged_fifo #(
    parameter DATA_W = 64,
    parameter TAG_W = 10,
    parameter DEPTH = 256,
    parameter AW = 8
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  wr_en,
    input  wire                  rd_en,
    input  wire [DATA_W-1:0]     data_in,
    input  wire [TAG_W-1:0]      tag_in,
    output wire [DATA_W-1:0]     data_out,
    output wire [TAG_W-1:0]      tag_out,
    output wire                  empty,
    output wire                  full
);
    localparam PTR_W = AW + 1;

    (* ram_style = "block" *)
    reg [DATA_W-1:0] data_mem [0:DEPTH-1];
    (* ram_style = "block" *)
    reg [TAG_W-1:0] tag_mem [0:DEPTH-1];

    reg [PTR_W-1:0] wr_ptr_q;
    reg [PTR_W-1:0] rd_ptr_q;
    reg             empty_q;
    reg             full_q;
    reg [DATA_W-1:0] data_out_q;
    reg [TAG_W-1:0] tag_out_q;

    assign empty = empty_q;
    assign full = full_q;

    wire write_fire = wr_en && !full_q;
    wire read_fire = rd_en && !empty_q;
    // The data and tag BRAMs share FIFO state but may be placed far apart.
    // Keep a logically identical read-enable decode local to the tag RAM so
    // the common control cone does not end in one long cross-column route.
    (* KEEP = "TRUE" *) wire tag_read_fire;
    assign tag_read_fire = rd_en && !empty_q;
    wire [PTR_W-1:0] wr_ptr_next = write_fire ?
        (wr_ptr_q + 1'b1) : wr_ptr_q;
    wire [PTR_W-1:0] rd_ptr_next = read_fire ?
        (rd_ptr_q + 1'b1) : rd_ptr_q;
    wire empty_next = wr_ptr_next == rd_ptr_next;
    wire full_next = (wr_ptr_next[AW] != rd_ptr_next[AW]) &&
                     (wr_ptr_next[AW-1:0] == rd_ptr_next[AW-1:0]);

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr_q <= {PTR_W{1'b0}};
            rd_ptr_q <= {PTR_W{1'b0}};
            empty_q <= 1'b1;
            full_q <= 1'b0;
        end else begin
            wr_ptr_q <= wr_ptr_next;
            rd_ptr_q <= rd_ptr_next;
            // These registered flags are the exact state of the accepted
            // next pointers.  Acceptance still uses the pre-edge flags, so
            // the full+read and empty+write boundary rules are unchanged.
            empty_q <= empty_next;
            full_q <= full_next;
        end
    end

    always @(posedge clk) begin
        if (!rst && write_fire) begin
            data_mem[wr_ptr_q[AW-1:0]] <= data_in;
            tag_mem[wr_ptr_q[AW-1:0]] <= tag_in;
        end
    end

    always @(posedge clk) begin
        if (rst)
            data_out_q <= {DATA_W{1'b0}};
        else if (read_fire)
            data_out_q <= data_mem[rd_ptr_q[AW-1:0]];
    end

    always @(posedge clk) begin
        if (rst)
            tag_out_q <= {TAG_W{1'b0}};
        else if (tag_read_fire)
            tag_out_q <= tag_mem[rd_ptr_q[AW-1:0]];
    end

    assign data_out = data_out_q;
    assign tag_out = tag_out_q;
endmodule

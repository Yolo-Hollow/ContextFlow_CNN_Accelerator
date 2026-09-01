`timescale 1ns / 1ps

// One independently addressable vector bank.  Keeping the memory template in
// a dedicated module gives Vivado 2022.2 an unambiguous simple-dual-port RAM:
// one synchronous write port and one synchronous read port on the same clock.
// The numeric generate is intentional.  A parameterized string attribute is
// accepted by Vivado, but explicit ultra/block branches make the formal
// release mapping deterministic while small/debug instances retain BRAM.
module ifm_vector_epoch_bank_mem #(
    parameter DATA_W = 144,
    parameter DEPTH = 1024,
    parameter AW = 10,
    parameter USE_URAM = 0
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 wr_en,
    input  wire [AW-1:0]        wr_addr,
    input  wire [DATA_W-1:0]    wr_data,
    input  wire                 rd_en,
    input  wire [AW-1:0]        rd_addr,
    output reg  [DATA_W-1:0]    rd_data
);
    initial begin
        if (DEPTH != (1 << AW))
            $error("ifm_vector_epoch_bank_mem DEPTH must equal 2**AW");
    end

    generate
        if (USE_URAM != 0) begin : g_ultra
            // UltraRAM is 72 bits wide.  A 144x1024 bank therefore maps to
            // two URAM primitives; the two epoch banks use four in total.
            (* ram_style = "ultra" *)
            reg [DATA_W-1:0] mem [0:DEPTH-1];

            always @(posedge clk) begin
                if (rst)
                    rd_data <= {DATA_W{1'b0}};
                else begin
                    if (wr_en)
                        mem[wr_addr] <= wr_data;
                    if (rd_en)
                        rd_data <= mem[rd_addr];
                end
            end
        end else begin : g_block
            (* ram_style = "block" *)
            reg [DATA_W-1:0] mem [0:DEPTH-1];

            always @(posedge clk) begin
                if (rst)
                    rd_data <= {DATA_W{1'b0}};
                else begin
                    if (wr_en)
                        mem[wr_addr] <= wr_data;
                    if (rd_en)
                        rd_data <= mem[rd_addr];
                end
            end
        end
    endgenerate
endmodule

// Atomic two-bank IFM vector staging buffer.
//
// A bank is allocated to exactly one compute context (epoch).  The producer
// may continue filling the selected bank while the consumer drains it, but a
// bank cannot be reallocated until the packet is committed, every vector has
// been consumed, and software/scheduler explicitly releases it.
//
// The memory is vector-wide: all ROWS lanes enter and leave atomically.  This
// avoids the implicit "lane 0 represents all lanes" invariant of independent
// byte FIFOs.  Lane staggering belongs after this buffer, where a complete
// vector and its epoch have already been captured.
module ifm_vector_epoch_buffer #(
    parameter DATA_W = 144,
    parameter DEPTH = 1024,
    parameter AW = 10,
    parameter EPOCH_W = 8,
    // Formal tagged builds set this to one.  The default preserves the BRAM
    // mapping used by direct module tests and legacy/debug configurations.
    parameter USE_URAM = 0
) (
    input clk,
    input rst,

    input                   alloc_valid,
    input                   alloc_bank,
    input  [EPOCH_W-1:0]    alloc_epoch,
    input  [15:0]           alloc_expected,
    output                  alloc_ready,

    input                   wr_valid,
    input                   wr_bank,
    input  [EPOCH_W-1:0]    wr_epoch,
    input  [DATA_W-1:0]     wr_data,
    output                  wr_ready,

    input                   commit_valid,
    input                   commit_bank,
    input  [EPOCH_W-1:0]    commit_epoch,
    output                  commit_ready,

    input                   select_valid,
    input                   select_bank,
    input  [EPOCH_W-1:0]    select_epoch,
    output                  select_ready,

    output [DATA_W-1:0]     rd_data,
    output                  rd_bank,
    output [EPOCH_W-1:0]    rd_epoch,
    output                  rd_valid,
    output                  rd_last,
    input                   rd_ready,

    input                   release_valid,
    input                   release_bank,
    input  [EPOCH_W-1:0]    release_epoch,
    output                  release_ready,

    output [1:0]            bank_allocated,
    output [1:0]            bank_committed,
    output [EPOCH_W-1:0]    bank0_epoch,
    output [EPOCH_W-1:0]    bank1_epoch,
    output [15:0]           bank0_produced,
    output [15:0]           bank1_produced,
    output [15:0]           bank0_consumed,
    output [15:0]           bank1_consumed,
    output [15:0]           bank0_available,
    output [15:0]           bank1_available,
    output                  reader_active,
    output                  reader_bank,
    output reg              reader_context_done,

    output reg [31:0]       epoch_alloc_count,
    output reg [31:0]       bank_release_count,
    output reg [31:0]       bank_ownership_stall_cycles,
    output reg [31:0]       context_gap_cycles,

    output reg              error_epoch,
    output reg              error_overflow,
    output reg              error_protocol
);
    localparam COUNT_W = AW + 1;

    initial begin
        if (DEPTH != (1 << AW))
            $error("ifm_vector_epoch_buffer DEPTH must equal 2**AW");
        if (DEPTH > 65535)
            $error("ifm_vector_epoch_buffer DEPTH exceeds 16-bit counters");
    end

    reg [1:0] allocated_q;
    reg [1:0] committed_q;
    reg [EPOCH_W-1:0] epoch0_q;
    reg [EPOCH_W-1:0] epoch1_q;
    reg [15:0] expected0_q;
    reg [15:0] expected1_q;
    reg [15:0] produced0_q;
    reg [15:0] produced1_q;
    // Per-bank registered write credit.  Allocation guarantees a non-zero,
    // in-range expected count, so the final legal vector is accepted while
    // this bit is high and closes the bank on that same edge.  This keeps the
    // wide produced/expected comparison out of the upstream ready path.
    reg [1:0] write_open_q;
    reg [15:0] issued0_q;
    reg [15:0] issued1_q;
    reg [15:0] consumed0_q;
    reg [15:0] consumed1_q;

    reg reader_active_q;
    reg reader_bank_q;
    reg [EPOCH_W-1:0] reader_epoch_q;
    reg rd_bank_q;
    reg [EPOCH_W-1:0] rd_epoch_q;
    reg rd_valid_q;
    reg rd_last_q;
    // Each physical bank owns an independent synchronous read port.  Use the
    // otherwise-idle port to fetch entry zero before that bank becomes the
    // active reader.  A pending bit denotes the one-cycle RAM return; the
    // captured data remains private to the bank until an atomic select.
    reg [1:0] lookahead_pending_q;
    reg [1:0] lookahead_valid_q;
    reg [DATA_W-1:0] lookahead0_data_q;
    reg [DATA_W-1:0] lookahead1_data_q;
    reg rd_from_lookahead_q;
    reg [DATA_W-1:0] rd_lookahead_data_q;

    wire selected_allocated = select_bank ? allocated_q[1] : allocated_q[0];
    wire [EPOCH_W-1:0] selected_epoch = select_bank ? epoch1_q : epoch0_q;
    wire release_allocated = release_bank ? allocated_q[1] : allocated_q[0];
    wire release_committed = release_bank ? committed_q[1] : committed_q[0];
    wire [EPOCH_W-1:0] release_epoch_q = release_bank ? epoch1_q : epoch0_q;
    wire [15:0] release_expected = release_bank ? expected1_q : expected0_q;
    wire [15:0] release_issued = release_bank ? issued1_q : issued0_q;
    wire [15:0] release_consumed = release_bank ? consumed1_q : consumed0_q;
    wire release_has_output = reader_active_q && (reader_bank_q == release_bank) && rd_valid_q;

    wire wr_allocated = wr_bank ? allocated_q[1] : allocated_q[0];
    wire [EPOCH_W-1:0] wr_epoch_q = wr_bank ? epoch1_q : epoch0_q;
    wire [15:0] wr_expected = wr_bank ? expected1_q : expected0_q;
    wire [15:0] wr_produced = wr_bank ? produced1_q : produced0_q;
    wire commit_allocated = commit_bank ? allocated_q[1] : allocated_q[0];
    wire commit_committed = commit_bank ? committed_q[1] : committed_q[0];
    wire [EPOCH_W-1:0] commit_epoch_q = commit_bank ? epoch1_q : epoch0_q;
    wire [15:0] commit_expected = commit_bank ? expected1_q : expected0_q;
    wire [15:0] commit_produced = commit_bank ? produced1_q : produced0_q;

    wire [15:0] active_expected = reader_bank_q ? expected1_q : expected0_q;
    wire [15:0] active_produced = reader_bank_q ? produced1_q : produced0_q;
    wire [15:0] active_issued = reader_bank_q ? issued1_q : issued0_q;
    wire [15:0] selected_expected = select_bank ? expected1_q : expected0_q;
    wire [15:0] selected_issued = select_bank ? issued1_q : issued0_q;
    wire output_pop = rd_valid_q && rd_ready;
    wire output_finishes_context = output_pop && rd_last_q;
    wire issue_read = reader_active_q && (active_issued < active_produced) &&
                      (!rd_valid_q || rd_ready);
    wire context_gap = reader_active_q && !rd_valid_q &&
                       (active_issued < active_expected) &&
                       (active_issued >= active_produced);

    assign alloc_ready = !(alloc_bank ? allocated_q[1] : allocated_q[0]) &&
                         (alloc_expected != 16'd0) && (alloc_expected <= DEPTH);
    assign wr_ready = wr_allocated && (wr_epoch == wr_epoch_q) &&
                      write_open_q[wr_bank];
    assign commit_ready = commit_allocated && !commit_committed &&
                          (commit_epoch == commit_epoch_q) &&
                          (commit_produced == commit_expected);
    // The next context may be selected on the same edge that consumes the
    // previous context's final vector.  The old bank remains allocated until
    // an independent array-retirement release, so reader handoff cannot make
    // storage reusable too early.
    assign select_ready = (!reader_active_q || output_finishes_context) &&
                          selected_allocated &&
                          (select_epoch == selected_epoch);
    assign release_ready = release_allocated && release_committed &&
                           (release_epoch == release_epoch_q) &&
                           (release_issued == release_expected) &&
                           (release_consumed == release_expected) &&
                           !release_has_output;

    wire select_fire = select_valid && select_ready;
    wire selected_lookahead_valid = select_bank ?
        lookahead_valid_q[1] : lookahead_valid_q[0];
    wire selected_lookahead_pending = select_bank ?
        lookahead_pending_q[1] : lookahead_pending_q[0];
    wire select_lookahead_hit = select_fire && (selected_issued == 16'd0) &&
        (selected_lookahead_valid || selected_lookahead_pending);

    wire bank0_mem_wr_en = wr_valid && wr_ready && !wr_bank;
    wire bank1_mem_wr_en = wr_valid && wr_ready && wr_bank;
    wire bank0_active_rd_en = issue_read && !reader_bank_q;
    wire bank1_active_rd_en = issue_read && reader_bank_q;
    // Do not launch a new lookahead on the same edge that selects the bank.
    // A previously pending return is already safe to consume on that edge;
    // a just-launched synchronous read would not be visible until afterwards.
    wire bank0_lookahead_rd_en = allocated_q[0] &&
        (produced0_q != 16'd0) && (issued0_q == 16'd0) &&
        (!reader_active_q || reader_bank_q) &&
        !lookahead_pending_q[0] && !lookahead_valid_q[0] &&
        !(select_fire && !select_bank);
    wire bank1_lookahead_rd_en = allocated_q[1] &&
        (produced1_q != 16'd0) && (issued1_q == 16'd0) &&
        (!reader_active_q || !reader_bank_q) &&
        !lookahead_pending_q[1] && !lookahead_valid_q[1] &&
        !(select_fire && select_bank);
    wire bank0_mem_rd_en = bank0_active_rd_en || bank0_lookahead_rd_en;
    wire bank1_mem_rd_en = bank1_active_rd_en || bank1_lookahead_rd_en;
    wire [DATA_W-1:0] bank0_mem_rd_data;
    wire [DATA_W-1:0] bank1_mem_rd_data;

    ifm_vector_epoch_bank_mem #(
        .DATA_W(DATA_W), .DEPTH(DEPTH), .AW(AW), .USE_URAM(USE_URAM)
    ) u_bank0_mem (
        .clk(clk), .rst(rst),
        .wr_en(bank0_mem_wr_en),
        .wr_addr(produced0_q[AW-1:0]), .wr_data(wr_data),
        .rd_en(bank0_mem_rd_en),
        .rd_addr(bank0_active_rd_en ? issued0_q[AW-1:0] : {AW{1'b0}}),
        .rd_data(bank0_mem_rd_data)
    );

    ifm_vector_epoch_bank_mem #(
        .DATA_W(DATA_W), .DEPTH(DEPTH), .AW(AW), .USE_URAM(USE_URAM)
    ) u_bank1_mem (
        .clk(clk), .rst(rst),
        .wr_en(bank1_mem_wr_en),
        .wr_addr(produced1_q[AW-1:0]), .wr_data(wr_data),
        .rd_en(bank1_mem_rd_en),
        .rd_addr(bank1_active_rd_en ? issued1_q[AW-1:0] : {AW{1'b0}}),
        .rd_data(bank1_mem_rd_data)
    );

    // The lookahead word occupies the output slot for exactly its first
    // transfer.  On that transfer edge the ordinary read port fetches entry
    // one, and the mux returns to the RAM output without inserting a bubble.
    assign rd_data = rd_from_lookahead_q ? rd_lookahead_data_q :
        (rd_bank_q ? bank1_mem_rd_data : bank0_mem_rd_data);
    assign rd_bank = rd_bank_q;
    assign rd_epoch = rd_epoch_q;
    assign rd_valid = rd_valid_q;
    assign rd_last = rd_last_q;
    assign bank_allocated = allocated_q;
    assign bank_committed = committed_q;
    assign bank0_epoch = epoch0_q;
    assign bank1_epoch = epoch1_q;
    assign bank0_produced = produced0_q;
    assign bank1_produced = produced1_q;
    assign bank0_consumed = consumed0_q;
    assign bank1_consumed = consumed1_q;
    assign bank0_available = produced0_q - consumed0_q;
    assign bank1_available = produced1_q - consumed1_q;
    assign reader_active = reader_active_q;
    assign reader_bank = reader_bank_q;

    always @(posedge clk) begin
        if (rst) begin
            allocated_q <= 2'b00;
            committed_q <= 2'b00;
            epoch0_q <= {EPOCH_W{1'b0}};
            epoch1_q <= {EPOCH_W{1'b0}};
            expected0_q <= 16'd0;
            expected1_q <= 16'd0;
            produced0_q <= 16'd0;
            produced1_q <= 16'd0;
            write_open_q <= 2'b00;
            issued0_q <= 16'd0;
            issued1_q <= 16'd0;
            consumed0_q <= 16'd0;
            consumed1_q <= 16'd0;
            reader_active_q <= 1'b0;
            reader_bank_q <= 1'b0;
            reader_epoch_q <= {EPOCH_W{1'b0}};
            rd_bank_q <= 1'b0;
            rd_epoch_q <= {EPOCH_W{1'b0}};
            rd_valid_q <= 1'b0;
            rd_last_q <= 1'b0;
            lookahead_pending_q <= 2'b00;
            lookahead_valid_q <= 2'b00;
            lookahead0_data_q <= {DATA_W{1'b0}};
            lookahead1_data_q <= {DATA_W{1'b0}};
            rd_from_lookahead_q <= 1'b0;
            rd_lookahead_data_q <= {DATA_W{1'b0}};
            epoch_alloc_count <= 32'd0;
            bank_release_count <= 32'd0;
            bank_ownership_stall_cycles <= 32'd0;
            context_gap_cycles <= 32'd0;
            reader_context_done <= 1'b0;
            error_epoch <= 1'b0;
            error_overflow <= 1'b0;
            error_protocol <= 1'b0;
        end else begin
            reader_context_done <= 1'b0;
            rd_valid_q <= (rd_valid_q && !output_pop) || issue_read;
            if (issue_read || output_pop)
                rd_from_lookahead_q <= 1'b0;

            // A RAM return is captured one cycle after its lookahead request.
            // The selected-bank pending case below may consume the same return
            // directly on this edge; nonblocking assignment ordering keeps the
            // two paths deterministic.
            if (lookahead_pending_q[0]) begin
                lookahead_pending_q[0] <= 1'b0;
                lookahead_valid_q[0] <= 1'b1;
                lookahead0_data_q <= bank0_mem_rd_data;
            end
            if (lookahead_pending_q[1]) begin
                lookahead_pending_q[1] <= 1'b0;
                lookahead_valid_q[1] <= 1'b1;
                lookahead1_data_q <= bank1_mem_rd_data;
            end
            if (bank0_lookahead_rd_en)
                lookahead_pending_q[0] <= 1'b1;
            if (bank1_lookahead_rd_en)
                lookahead_pending_q[1] <= 1'b1;

            if (context_gap)
                context_gap_cycles <= context_gap_cycles + 1'b1;
            if (alloc_valid && !alloc_ready &&
                (alloc_bank ? allocated_q[1] : allocated_q[0]))
                bank_ownership_stall_cycles <=
                    bank_ownership_stall_cycles + 1'b1;

            if (alloc_valid) begin
                if (alloc_ready) begin
                    epoch_alloc_count <= epoch_alloc_count + 1'b1;
                    if (alloc_bank) begin
                        allocated_q[1] <= 1'b1;
                        committed_q[1] <= 1'b0;
                        epoch1_q <= alloc_epoch;
                        expected1_q <= alloc_expected;
                        produced1_q <= 16'd0;
                        write_open_q[1] <= 1'b1;
                        issued1_q <= 16'd0;
                        consumed1_q <= 16'd0;
                        lookahead_pending_q[1] <= 1'b0;
                        lookahead_valid_q[1] <= 1'b0;
                    end else begin
                        allocated_q[0] <= 1'b1;
                        committed_q[0] <= 1'b0;
                        epoch0_q <= alloc_epoch;
                        expected0_q <= alloc_expected;
                        produced0_q <= 16'd0;
                        write_open_q[0] <= 1'b1;
                        issued0_q <= 16'd0;
                        consumed0_q <= 16'd0;
                        lookahead_pending_q[0] <= 1'b0;
                        lookahead_valid_q[0] <= 1'b0;
                    end
                end else if (!(alloc_bank ? allocated_q[1] : allocated_q[0])) begin
                    // An occupied bank is ordinary valid/ready backpressure.
                    // Zero/oversized contexts are malformed descriptors.
                    error_protocol <= 1'b1;
                end
            end

            if (wr_valid) begin
                if (wr_ready) begin
                    if (wr_bank) begin
                        produced1_q <= produced1_q + 1'b1;
                        if (produced1_q + 1'b1 == expected1_q)
                            write_open_q[1] <= 1'b0;
                    end else begin
                        produced0_q <= produced0_q + 1'b1;
                        if (produced0_q + 1'b1 == expected0_q)
                            write_open_q[0] <= 1'b0;
                    end
                end else begin
                    if (!wr_allocated || (wr_epoch != wr_epoch_q))
                        error_epoch <= 1'b1;
                    else
                        error_overflow <= 1'b1;
                end
            end

            if (commit_valid) begin
                if (!commit_allocated || (commit_epoch != commit_epoch_q)) begin
                    error_epoch <= 1'b1;
                end else if (commit_produced > commit_expected) begin
                    error_protocol <= 1'b1;
                end else if (commit_ready) begin
                    committed_q[commit_bank] <= 1'b1;
                end
            end

            if (select_valid) begin
                if (select_ready) begin
                    reader_active_q <= 1'b1;
                    reader_bank_q <= select_bank;
                    reader_epoch_q <= select_epoch;
                    // A completed or returning entry-zero lookahead becomes a
                    // valid output immediately after the select edge.  Thus a
                    // same-edge old-last-pop/new-select permits the new first
                    // vector to transfer on the very next clock edge.
                    if (select_lookahead_hit) begin
                        rd_valid_q <= 1'b1;
                        rd_bank_q <= select_bank;
                        rd_epoch_q <= select_epoch;
                        rd_last_q <= (selected_expected == 16'd1);
                        rd_from_lookahead_q <= 1'b1;
                        if (select_bank) begin
                            rd_lookahead_data_q <= selected_lookahead_valid ?
                                lookahead1_data_q : bank1_mem_rd_data;
                            issued1_q <= issued1_q + 1'b1;
                            lookahead_pending_q[1] <= 1'b0;
                            lookahead_valid_q[1] <= 1'b0;
                        end else begin
                            rd_lookahead_data_q <= selected_lookahead_valid ?
                                lookahead0_data_q : bank0_mem_rd_data;
                            issued0_q <= issued0_q + 1'b1;
                            lookahead_pending_q[0] <= 1'b0;
                            lookahead_valid_q[0] <= 1'b0;
                        end
                    end
                end else if (!reader_active_q) begin
                    if (!selected_allocated || (select_epoch != selected_epoch))
                        error_epoch <= 1'b1;
                    else
                        error_protocol <= 1'b1;
                end
            end

            if (output_finishes_context) begin
                reader_context_done <= 1'b1;
                if (!(select_valid && select_ready))
                    reader_active_q <= 1'b0;
            end

            if (issue_read) begin
                if (reader_bank_q) begin
                    issued1_q <= issued1_q + 1'b1;
                    rd_last_q <= (issued1_q + 1'b1 == active_expected);
                end else begin
                    issued0_q <= issued0_q + 1'b1;
                    rd_last_q <= (issued0_q + 1'b1 == active_expected);
                end
                rd_bank_q <= reader_bank_q;
                rd_epoch_q <= reader_epoch_q;
            end

            if (output_pop) begin
                if (reader_bank_q)
                    consumed1_q <= consumed1_q + 1'b1;
                else
                    consumed0_q <= consumed0_q + 1'b1;
            end

            if (release_valid) begin
                if (release_ready) begin
                    bank_release_count <= bank_release_count + 1'b1;
                    allocated_q[release_bank] <= 1'b0;
                    committed_q[release_bank] <= 1'b0;
                    write_open_q[release_bank] <= 1'b0;
                    lookahead_pending_q[release_bank] <= 1'b0;
                    lookahead_valid_q[release_bank] <= 1'b0;
                    if (reader_active_q && (reader_bank_q == release_bank))
                        reader_active_q <= 1'b0;
                end else if (!release_allocated ||
                             (release_epoch != release_epoch_q)) begin
                    error_epoch <= 1'b1;
                end
            end
        end
    end
endmodule

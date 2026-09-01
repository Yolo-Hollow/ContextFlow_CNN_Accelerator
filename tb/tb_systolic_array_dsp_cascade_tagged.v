`timescale 1ns / 1ps

module tb_systolic_array_dsp_cascade_tagged;
    localparam ROWS = 2;
    localparam COLS = 2;
    localparam LANES = COLS * 2;
    localparam TOKENS = 5;
    localparam LATENCY = ROWS + 1;
    localparam EDGE_DELTA = LATENCY - 1;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg w_load = 1'b0;
    reg [4:0] w_col = 5'd0;
    reg w_bank = 1'b0;
    reg [ROWS*8*2-1:0] w_row_data = 0;
    reg [ROWS*8-1:0] ifm_vector_flat = 0;
    reg [LANES*32-1:0] seed_psum_flat = 0;
    reg token_valid = 1'b0;
    reg [1:0] token_tag = 2'b00;

    wire [LANES*32-1:0] result_psum_flat;
    wire result_valid;
    wire [1:0] result_tag;
    wire tag_mismatch_event;
    wire weight_write_collision_event;

    systolic_array_dsp_cascade_tagged #(
        .ROWS(ROWS),
        .COLS(COLS),
        .LOCALIZE_A1_IFM_BITS(1)
    ) dut (
        .clk(clk),
        .rst(rst),
        .w_load(w_load),
        .w_col(w_col),
        .w_bank(w_bank),
        .w_row_data(w_row_data),
        .ifm_vector_flat(ifm_vector_flat),
        .seed_psum_flat(seed_psum_flat),
        .token_valid(token_valid),
        .token_tag(token_tag),
        .result_psum_flat(result_psum_flat),
        .result_valid(result_valid),
        .result_tag(result_tag),
        .tag_mismatch_event(tag_mismatch_event),
        .weight_write_collision_event(weight_write_collision_event)
    );

    reg signed [7:0] weights [0:1][0:LANES-1][0:ROWS-1];
    reg signed [7:0] token_ifm [0:TOKENS-1][0:ROWS-1];
    reg signed [31:0] token_seed [0:TOKENS-1][0:LANES-1];
    reg [1:0] expected_tag [0:TOKENS-1];
    reg signed [31:0] expected_result [0:TOKENS-1][0:LANES-1];

    integer checks = 0;
    integer failures = 0;
    integer token_idx;
    integer lane_idx;
    integer row_idx;
    integer wave_idx;
    integer source_idx;
    integer signed accum;

    task check;
        input condition;
        input [8*120-1:0] description;
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $display("[FAIL] %0s", description);
            end
        end
    endtask

    task load_pair;
        input integer bank;
        input integer col;
        input integer row0_even;
        input integer row0_odd;
        input integer row1_even;
        input integer row1_odd;
        begin
            @(negedge clk);
            w_bank = bank[0];
            w_col = col[4:0];
            w_row_data[7:0] = row0_even[7:0];
            w_row_data[15:8] = row0_odd[7:0];
            w_row_data[23:16] = row1_even[7:0];
            w_row_data[31:24] = row1_odd[7:0];
            w_load = 1'b1;
            #1;
            check(!weight_write_collision_event,
                "idle bank load does not report collision");
            @(posedge clk);
            @(negedge clk);
            w_load = 1'b0;
        end
    endtask

    task drive_and_check_wave;
        input integer wave;
        begin
            @(negedge clk);
            if (wave < TOKENS) begin
                token_valid = 1'b1;
                token_tag = expected_tag[wave];
                for (row_idx = 0; row_idx < ROWS;
                     row_idx = row_idx + 1)
                    ifm_vector_flat[row_idx*8 +: 8] =
                        token_ifm[wave][row_idx];
                for (lane_idx = 0; lane_idx < LANES;
                     lane_idx = lane_idx + 1)
                    seed_psum_flat[lane_idx*32 +: 32] =
                        token_seed[wave][lane_idx];
            end else begin
                token_valid = 1'b0;
                token_tag = 2'b00;
                ifm_vector_flat = 0;
                seed_psum_flat = 0;
            end

            @(posedge clk);
            #2;
            source_idx = wave - EDGE_DELTA;
            if ((source_idx >= 0) && (source_idx < TOKENS)) begin
                check(result_valid,
                    "result_valid asserted at exact cascade latency");
                check(result_tag === expected_tag[source_idx],
                    "result tag matches exact source token");
                for (lane_idx = 0; lane_idx < LANES;
                     lane_idx = lane_idx + 1)
                    check($signed(result_psum_flat[
                            lane_idx*32 +: 32]) ===
                            expected_result[source_idx][lane_idx],
                        "lane result matches pair/row/bank mapping");
            end else begin
                check(!result_valid,
                    "result_valid remains low outside exact latency window");
            end

            // After token zero is sampled, bank zero is live and bank one is
            // still idle.  Pulse an invalid-column write entirely between
            // clock edges so diagnostics are exercised without changing any
            // stationary weight payload.
            if (wave == 0) begin
                w_load = 1'b1;
                w_col = 5'd31;
                w_bank = 1'b0;
                #1;
                check(weight_write_collision_event,
                    "same-bank live-token write reports collision");
                w_bank = 1'b1;
                #1;
                check(!weight_write_collision_event,
                    "other idle bank remains writable");
                w_load = 1'b0;
            end
        end
    endtask

    task drive_post_reset_token;
        input integer source;
        integer latency_idx;
        begin
            @(negedge clk);
            token_valid = 1'b1;
            token_tag = expected_tag[source];
            for (row_idx = 0; row_idx < ROWS;
                 row_idx = row_idx + 1)
                ifm_vector_flat[row_idx*8 +: 8] =
                    token_ifm[source][row_idx];
            for (lane_idx = 0; lane_idx < LANES;
                 lane_idx = lane_idx + 1)
                seed_psum_flat[lane_idx*32 +: 32] =
                    token_seed[source][lane_idx];
            @(posedge clk);
            #2;
            check(!result_valid,
                "post-reset token does not return too early");
            @(negedge clk);
            token_valid = 1'b0;
            for (latency_idx = 1; latency_idx <= EDGE_DELTA;
                 latency_idx = latency_idx + 1) begin
                @(posedge clk);
                #2;
                if (latency_idx < EDGE_DELTA)
                    check(!result_valid,
                        "post-reset token remains invalid before latency");
                else begin
                    check(result_valid,
                        "post-reset token returns at exact latency");
                    check(result_tag === expected_tag[source],
                        "post-reset result tag preserved");
                    for (lane_idx = 0; lane_idx < LANES;
                         lane_idx = lane_idx + 1)
                        check($signed(result_psum_flat[
                                lane_idx*32 +: 32]) ===
                                expected_result[source][lane_idx],
                            "soft reset preserves weight configuration");
                end
            end
            @(posedge clk);
            #2;
            check(!result_valid,
                "single post-reset token produces one valid cycle");
        end
    endtask

    initial begin
        // Explicit asymmetric values make every {bank,column,pair,row}
        // location independently observable in the result vector.
        weights[0][0][0] = 1;   weights[0][1][0] = 2;
        weights[0][0][1] = 3;   weights[0][1][1] = 4;
        weights[0][2][0] = 5;   weights[0][3][0] = 6;
        weights[0][2][1] = 7;   weights[0][3][1] = 8;
        weights[1][0][0] = -1;  weights[1][1][0] = -2;
        weights[1][0][1] = -3;  weights[1][1][1] = -4;
        weights[1][2][0] = -5;  weights[1][3][0] = -6;
        weights[1][2][1] = -7;  weights[1][3][1] = -8;

        expected_tag[0] = 2'b00;
        expected_tag[1] = 2'b10;
        expected_tag[2] = 2'b01;
        expected_tag[3] = 2'b11;
        expected_tag[4] = 2'b00;
        for (token_idx = 0; token_idx < TOKENS;
             token_idx = token_idx + 1) begin
            token_ifm[token_idx][0] = token_idx*7 - 11;
            token_ifm[token_idx][1] = 23 - token_idx*9;
            for (lane_idx = 0; lane_idx < LANES;
                 lane_idx = lane_idx + 1) begin
                token_seed[token_idx][lane_idx] =
                    token_idx*1000 + lane_idx*101 - 77;
                accum = token_seed[token_idx][lane_idx];
                for (row_idx = 0; row_idx < ROWS;
                     row_idx = row_idx + 1)
                    accum = accum +
                        $signed(token_ifm[token_idx][row_idx]) *
                        $signed(weights[expected_tag[token_idx][1]]
                            [lane_idx][row_idx]);
                expected_result[token_idx][lane_idx] = accum;
            end
        end

        // UNISIM global set/reset remains asserted for the first 100 ns.
        repeat (14) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        load_pair(0, 0, 1, 2, 3, 4);
        load_pair(0, 1, 5, 6, 7, 8);
        load_pair(1, 0, -1, -2, -3, -4);
        load_pair(1, 1, -5, -6, -7, -8);

        // All five tokens are presented on consecutive sampling edges and
        // alternate banks.  This distinguishes the shared row bank wave from
        // a current-cycle bank mux and verifies one-result-per-clock flow.
        for (wave_idx = 0; wave_idx < TOKENS + EDGE_DELTA;
             wave_idx = wave_idx + 1)
            drive_and_check_wave(wave_idx);

        // The occupancy diagnostic consumes the registered result on the
        // following sampling edge.  It intentionally remains conservative
        // throughout the cycle in which result_valid is externally visible.
        @(posedge clk);
        #2;
        check(!result_valid,
            "continuous result stream ends after the final token");
        @(negedge clk);
        w_load = 1'b1;
        w_col = 5'd31;
        w_bank = 1'b0;
        #1;
        check(!weight_write_collision_event,
            "bank becomes writable after every live token returns");
        w_load = 1'b0;

        // Put a token in flight and then apply the datapath soft reset.  The
        // arithmetic result may still move through DSP data registers, but
        // its validity must be discarded and occupancy must return to zero.
        @(negedge clk);
        token_tag = expected_tag[1];
        token_valid = 1'b1;
        ifm_vector_flat[7:0] = token_ifm[1][0];
        ifm_vector_flat[15:8] = token_ifm[1][1];
        for (lane_idx = 0; lane_idx < LANES;
             lane_idx = lane_idx + 1)
            seed_psum_flat[lane_idx*32 +: 32] = token_seed[1][lane_idx];
        @(posedge clk);
        @(negedge clk);
        token_valid = 1'b0;
        rst = 1'b1;
        repeat (2) begin
            @(posedge clk);
            #2;
            check(!result_valid,
                "soft reset flushes in-flight result validity");
        end
        @(negedge clk);
        rst = 1'b0;
        w_load = 1'b1;
        w_col = 5'd31;
        w_bank = 1'b1;
        #1;
        check(!weight_write_collision_event,
            "soft reset clears live-bank collision ownership");
        w_load = 1'b0;
        repeat (EDGE_DELTA + 1) begin
            @(posedge clk);
            #2;
            check(!result_valid,
                "reset token never reappears after deassertion");
        end

        drive_post_reset_token(3);
        check(tag_mismatch_event === 1'b0,
            "shared tag pipe cannot report lane mismatch");

        if (failures == 0)
            $display("PASS: DSP cascade tagged array checks=%0d continuous_tokens=%0d latency=%0d",
                checks, TOKENS, LATENCY);
        else
            $display("FAIL: DSP cascade tagged array failures=%0d checks=%0d",
                failures, checks);
        $finish;
    end
endmodule

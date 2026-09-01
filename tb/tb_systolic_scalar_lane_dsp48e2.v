`timescale 1ns / 1ps

module tb_systolic_scalar_lane_dsp48e2;
    localparam ROWS = 18;
    localparam LATENCY = ROWS + 1;
    localparam EDGE_DELTA = LATENCY - 1;
    localparam TOKENS = 256;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg [ROWS*8-1:0] ifm_rows_aligned_flat = 0;
    reg [ROWS*8-1:0] weight_rows_aligned_flat = 0;
    reg signed [31:0] seed_psum = 0;
    wire signed [31:0] result;

    systolic_scalar_lane_dsp48e2 #(
        .ROWS(ROWS)
    ) dut (
        .clk(clk),
        .ifm_rows_aligned_flat(ifm_rows_aligned_flat),
        .weight_rows_aligned_flat(weight_rows_aligned_flat),
        .seed_psum(seed_psum),
        .result(result)
    );

    reg [ROWS*8-1:0] token_ifm [0:TOKENS-1];
    reg [31:0] token_seed [0:TOKENS-1];
    reg token_bank [0:TOKENS-1];
    reg [31:0] expected [0:TOKENS-1];
    reg [ROWS*8-1:0] weight_bank0_flat;
    reg [ROWS*8-1:0] weight_bank1_flat;
    integer wave;
    integer token;
    integer row;
    integer signed acc;
    integer signed ifm_value;
    integer signed weight_value;
    integer checks = 0;
    integer failures = 0;

    task drive_aligned_wave;
        input integer wave_idx;
        integer wave_row;
        integer source_token;
        begin
            @(negedge clk);
            if (wave_idx < TOKENS)
                seed_psum = token_seed[wave_idx];
            else
                seed_psum = 0;
            for (wave_row = 0; wave_row < ROWS;
                 wave_row = wave_row + 1) begin
                source_token = wave_idx - wave_row;
                if (source_token >= 0 && source_token < TOKENS) begin
                    ifm_rows_aligned_flat[(wave_row+1)*8-1 -: 8] =
                        token_ifm[source_token][(wave_row+1)*8-1 -: 8];
                    if (token_bank[source_token])
                        weight_rows_aligned_flat[(wave_row+1)*8-1 -: 8] =
                            weight_bank1_flat[(wave_row+1)*8-1 -: 8];
                    else
                        weight_rows_aligned_flat[(wave_row+1)*8-1 -: 8] =
                            weight_bank0_flat[(wave_row+1)*8-1 -: 8];
                end else begin
                    ifm_rows_aligned_flat[(wave_row+1)*8-1 -: 8] = 0;
                    weight_rows_aligned_flat[(wave_row+1)*8-1 -: 8] = 0;
                end
            end
            @(posedge clk);
            #2;
            if (wave_idx >= EDGE_DELTA &&
                (wave_idx - EDGE_DELTA) < TOKENS) begin
                token = wave_idx - EDGE_DELTA;
                checks = checks + 1;
                if (result !== expected[token]) begin
                    $display("FAIL wave=%0d token=%0d result=%0d expected=%0d",
                        wave_idx, token, result, $signed(expected[token]));
                    failures = failures + 1;
                end
            end
        end
    endtask

    initial begin
        // Asymmetric signed extrema exercise sign extension through both the
        // multiplier and the 48-bit cascade adder.
        for (row = 0; row < ROWS; row = row + 1) begin
            weight_bank0_flat[(row+1)*8-1 -: 8] =
                (row == 0) ? -8'sd128 : (row*13 - 97);
            weight_bank1_flat[(row+1)*8-1 -: 8] =
                (row == ROWS-1) ? 8'sd127 : (71 - row*11);
        end

        for (token = 0; token < TOKENS; token = token + 1) begin
            token_seed[token] = $random;
            token_bank[token] = token[0];
            for (row = 0; row < ROWS; row = row + 1)
                token_ifm[token][(row+1)*8-1 -: 8] = $random;

            acc = $signed(token_seed[token]);
            for (row = 0; row < ROWS; row = row + 1) begin
                ifm_value = $signed(token_ifm[token][(row+1)*8-1 -: 8]);
                if (token_bank[token])
                    weight_value =
                        $signed(weight_bank1_flat[(row+1)*8-1 -: 8]);
                else
                    weight_value =
                        $signed(weight_bank0_flat[(row+1)*8-1 -: 8]);
                acc = acc + ifm_value * weight_value;
            end
            expected[token] = acc[31:0];
        end

        // UNISIM global set/reset remains asserted for the first 100 ns.
        repeat (14) @(posedge clk);
        for (wave = 0; wave < TOKENS + EDGE_DELTA; wave = wave + 1)
            drive_aligned_wave(wave);

        if (checks != TOKENS) begin
            $display("FAIL checks=%0d expected=%0d", checks, TOKENS);
            failures = failures + 1;
        end
        if (failures == 0)
            $display("PASS: scalar DSP48E2 lane tokens=%0d latency=%0d sampled clocks edge_delta=%0d",
                checks, LATENCY, EDGE_DELTA);
        else begin
            $display("FAIL: scalar DSP48E2 lane failures=%0d checks=%0d",
                failures, checks);
            $fatal(1);
        end
        $finish;
    end
endmodule

`timescale 1ns / 1ps

// Direct primitive-versus-fast differential test.  Compile this test without
// CONV_ACCEL_FAST_XSIM_DSP: dut_primitive then contains the real UNISIM
// DSP48E2 cascade, while dut_fast directly instantiates the behavioral model.
module tb_systolic_scalar_lane_dsp48e2_fast_diff;
`ifdef CONV_ACCEL_FAST_XSIM_DSP
    initial $fatal(1,
        "primitive-fast differential must not be compiled with CONV_ACCEL_FAST_XSIM_DSP");
`endif
    localparam integer ROWS = 18;
    localparam integer LATENCY = ROWS + 1;
    localparam integer EDGE_DELTA = LATENCY - 1;
    localparam integer WAVES = 384;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg [ROWS*8-1:0] ifm_rows_aligned_flat = 0;
    reg [ROWS*8-1:0] weight_rows_aligned_flat = 0;
    reg signed [31:0] seed_psum = 0;
    wire signed [31:0] primitive_result;
    wire signed [31:0] fast_result;

    systolic_scalar_lane_dsp48e2 #(
        .ROWS(ROWS)
    ) dut_primitive (
        .clk(clk),
        .ifm_rows_aligned_flat(ifm_rows_aligned_flat),
        .weight_rows_aligned_flat(weight_rows_aligned_flat),
        .seed_psum(seed_psum),
        .result(primitive_result)
    );

    systolic_scalar_lane_dsp48e2_fast_sim #(
        .ROWS(ROWS)
    ) dut_fast (
        .clk(clk),
        .ifm_rows_aligned_flat(ifm_rows_aligned_flat),
        .weight_rows_aligned_flat(weight_rows_aligned_flat),
        .seed_psum(seed_psum),
        .result(fast_result)
    );

    reg source_valid [0:WAVES-1];
    reg source_bank [0:WAVES-1];
    reg [31:0] source_seed [0:WAVES-1];
    reg [ROWS*8-1:0] source_ifm [0:WAVES-1];
    reg [31:0] expected [0:WAVES-1];
    reg [ROWS*8-1:0] weight_bank0;
    reg [ROWS*8-1:0] weight_bank1;

    integer wave;
    integer source;
    integer row;
    integer signed accumulator;
    integer signed ifm_value;
    integer signed weight_value;
    integer checks = 0;
    integer failures = 0;

    function signed [7:0] signed_extreme;
        input integer index;
        begin
            case (index % 8)
                0: signed_extreme = -8'sd128;
                1: signed_extreme = 8'sd127;
                2: signed_extreme = -8'sd1;
                3: signed_extreme = 8'sd0;
                4: signed_extreme = 8'sd1;
                5: signed_extreme = -8'sd127;
                6: signed_extreme = 8'sd126;
                default: signed_extreme = -8'sd64;
            endcase
        end
    endfunction

    task drive_wave;
        input integer wave_index;
        integer wave_row;
        integer source_index;
        begin
            @(negedge clk);
            if (wave_index < WAVES && source_valid[wave_index])
                seed_psum = source_seed[wave_index];
            else
                seed_psum = 0;

            for (wave_row = 0; wave_row < ROWS;
                 wave_row = wave_row + 1) begin
                source_index = wave_index - wave_row;
                if (source_index >= 0 && source_index < WAVES &&
                    source_valid[source_index]) begin
                    ifm_rows_aligned_flat[
                        wave_row*8 +: 8] = source_ifm[source_index][
                        wave_row*8 +: 8];
                    if (source_bank[source_index])
                        weight_rows_aligned_flat[
                            wave_row*8 +: 8] = weight_bank1[
                            wave_row*8 +: 8];
                    else
                        weight_rows_aligned_flat[
                            wave_row*8 +: 8] = weight_bank0[
                            wave_row*8 +: 8];
                end else begin
                    ifm_rows_aligned_flat[wave_row*8 +: 8] = 0;
                    weight_rows_aligned_flat[wave_row*8 +: 8] = 0;
                end
            end

            @(posedge clk);
            #2;
            source_index = wave_index - EDGE_DELTA;
            if (source_index >= 0 && source_index < WAVES) begin
                checks = checks + 1;
                if (primitive_result !== fast_result) begin
                    failures = failures + 1;
                    $display("[FAIL] diff wave=%0d source=%0d primitive=%0d fast=%0d valid=%0d bank=%0d",
                        wave_index, source_index, primitive_result,
                        fast_result, source_valid[source_index],
                        source_bank[source_index]);
                end
                if (source_valid[source_index] &&
                    primitive_result !== expected[source_index]) begin
                    failures = failures + 1;
                    $display("[FAIL] golden wave=%0d source=%0d primitive=%0d expected=%0d bank=%0d",
                        wave_index, source_index, primitive_result,
                        $signed(expected[source_index]),
                        source_bank[source_index]);
                end
            end
        end
    endtask

    initial begin
        for (row = 0; row < ROWS; row = row + 1) begin
            weight_bank0[row*8 +: 8] = signed_extreme(row);
            weight_bank1[row*8 +: 8] = signed_extreme(7-row);
        end

        for (source = 0; source < WAVES; source = source + 1) begin
            // Exercise long back-to-back bursts, isolated bubbles, and a
            // multi-cycle bubble while switching weight bank every token.
            source_valid[source] =
                !((source % 17) == 5 || (source % 41) == 23 ||
                  (source % 41) == 24 || (source % 41) == 25);
            source_bank[source] = source[0] ^ (source / 9);
            case (source % 6)
                0: source_seed[source] = 32'h7fffffff;
                1: source_seed[source] = 32'h80000000;
                2: source_seed[source] = 32'hffffffff;
                3: source_seed[source] = 32'h00000000;
                default: source_seed[source] = $random;
            endcase
            for (row = 0; row < ROWS; row = row + 1)
                source_ifm[source][row*8 +: 8] =
                    signed_extreme(source + row*3);

            accumulator = $signed(source_seed[source]);
            for (row = 0; row < ROWS; row = row + 1) begin
                ifm_value = $signed(source_ifm[source][row*8 +: 8]);
                if (source_bank[source])
                    weight_value = $signed(weight_bank1[row*8 +: 8]);
                else
                    weight_value = $signed(weight_bank0[row*8 +: 8]);
                accumulator = accumulator + ifm_value * weight_value;
            end
            expected[source] = accumulator[31:0];
        end

        // Wait out UNISIM global reset, then send zeros long enough to make
        // every compared stage state deterministic.
        repeat (14) @(posedge clk);
        repeat (LATENCY + 2) begin
            @(negedge clk);
            ifm_rows_aligned_flat = 0;
            weight_rows_aligned_flat = 0;
            seed_psum = 0;
            @(posedge clk);
        end

        for (wave = 0; wave < WAVES + EDGE_DELTA;
             wave = wave + 1)
            drive_wave(wave);

        if (checks != WAVES) begin
            failures = failures + 1;
            $display("[FAIL] checks=%0d expected=%0d", checks, WAVES);
        end
        if (failures == 0)
            $display("PASS: primitive-fast DSP cascade differential checks=%0d latency=%0d signed-extrema/back-to-back/bubbles/bank",
                checks, LATENCY);
        else begin
            $display("FAIL: primitive-fast DSP cascade differential failures=%0d checks=%0d",
                failures, checks);
            $fatal(1);
        end
        $finish;
    end
endmodule

`timescale 1ns / 1ps

module tb_tiling_model;
    localparam K_TILE = 32;
    localparam COUT_TILE = 64;
    localparam P = 3;
    localparam K = 96;
    localparam COUT = 128;

    reg signed [7:0] ifm [0:P-1][0:K-1];
    reg signed [7:0] wgt [0:K-1][0:COUT-1];
    reg signed [31:0] bias [0:COUT-1];
    reg signed [31:0] golden [0:P-1][0:COUT-1];
    reg signed [31:0] tiled [0:P-1][0:COUT-1];
    reg signed [31:0] psum [0:P-1][0:COUT_TILE-1];

    integer p, k, co, kb, cb, lane;
    integer pass, fail;

    initial begin
        pass = 0; fail = 0;

        for (p = 0; p < P; p = p + 1)
            for (k = 0; k < K; k = k + 1)
                ifm[p][k] = (p * 3 + k * 5) % 17 - 8;

        for (k = 0; k < K; k = k + 1)
            for (co = 0; co < COUT; co = co + 1)
                wgt[k][co] = (k * 7 + co * 3) % 19 - 9;

        for (co = 0; co < COUT; co = co + 1)
            bias[co] = co - 32;

        for (p = 0; p < P; p = p + 1) begin
            for (co = 0; co < COUT; co = co + 1) begin
                golden[p][co] = bias[co];
                tiled[p][co] = 0;
                for (k = 0; k < K; k = k + 1)
                    golden[p][co] = golden[p][co] + ifm[p][k] * wgt[k][co];
            end
        end

        for (cb = 0; cb < COUT; cb = cb + COUT_TILE) begin
            for (p = 0; p < P; p = p + 1)
                for (co = 0; co < COUT_TILE; co = co + 1)
                    psum[p][co] = bias[cb + co];

            for (kb = 0; kb < K; kb = kb + K_TILE) begin
                for (p = 0; p < P; p = p + 1) begin
                    for (co = 0; co < COUT_TILE; co = co + 1) begin
                        for (lane = 0; lane < K_TILE; lane = lane + 1)
                            psum[p][co] = psum[p][co] + ifm[p][kb + lane] * wgt[kb + lane][cb + co];
                    end
                end
            end

            for (p = 0; p < P; p = p + 1)
                for (co = 0; co < COUT_TILE; co = co + 1)
                    tiled[p][cb + co] = psum[p][co];
        end

        for (p = 0; p < P; p = p + 1) begin
            for (co = 0; co < COUT; co = co + 1) begin
                if (tiled[p][co] !== golden[p][co]) begin
                    $display("[FAIL] p=%0d co=%0d tiled=%0d ref=%0d", p, co, tiled[p][co], golden[p][co]);
                    fail = fail + 1;
                end else pass = pass + 1;
            end
        end

        $display("=== tb_tiling_model: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule

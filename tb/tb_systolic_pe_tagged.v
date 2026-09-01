`timescale 1ns / 1ps

module tb_systolic_pe_tagged;
    localparam EPOCH_W = 8;
    localparam TAG_W = 2;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg w_load;
    reg w_bank;
    reg signed [7:0] w0_in;
    reg signed [7:0] w1_in;
    reg signed [7:0] ifm_in;
    reg valid_in_h;
    reg [TAG_W-1:0] tag_in_h;
    reg signed [31:0] psuma_in;
    reg valid_in_va;
    reg signed [31:0] psumb_in;
    reg valid_in_vb;
    reg [TAG_W-1:0] tag_in_v;

    wire signed [7:0] ifm_out;
    wire valid_out_h;
    wire [TAG_W-1:0] tag_out_h;
    wire signed [31:0] psuma_out;
    wire valid_out_va;
    wire signed [31:0] psumb_out;
    wire valid_out_vb;
    wire [TAG_W-1:0] tag_out_v;
    wire tag_mismatch_event;
    wire weight_write_collision_event;

    systolic_pe_tagged #(.EPOCH_W(EPOCH_W), .TAG_W(TAG_W)) dut (
        .clk(clk),
        .rst(rst),
        .w_load(w_load),
        .w_bank(w_bank),
        .w0_in(w0_in),
        .w1_in(w1_in),
        .ifm_in(ifm_in),
        .valid_in_h(valid_in_h),
        .tag_in_h(tag_in_h),
        .ifm_out(ifm_out),
        .valid_out_h(valid_out_h),
        .tag_out_h(tag_out_h),
        .psuma_in(psuma_in),
        .valid_in_va(valid_in_va),
        .psumb_in(psumb_in),
        .valid_in_vb(valid_in_vb),
        .tag_in_v(tag_in_v),
        .psuma_out(psuma_out),
        .valid_out_va(valid_out_va),
        .psumb_out(psumb_out),
        .valid_out_vb(valid_out_vb),
        .tag_out_v(tag_out_v),
        .tag_mismatch_event(tag_mismatch_event),
        .weight_write_collision_event(weight_write_collision_event)
    );

    function [TAG_W-1:0] make_tag;
        input bank;
        input last;
        begin
            make_tag = {bank, last};
        end
    endfunction

    task load_weight;
        input bank;
        input signed [7:0] weight0;
        input signed [7:0] weight1;
        begin
            @(negedge clk);
            w_load = 1'b1;
            w_bank = bank;
            w0_in = weight0;
            w1_in = weight1;
            @(negedge clk);
            w_load = 1'b0;
        end
    endtask

    task send_token;
        input signed [7:0] ifm;
        input signed [31:0] psuma;
        input signed [31:0] psumb;
        input [TAG_W-1:0] h_tag;
        input [TAG_W-1:0] v_tag;
        input vertical_valid;
        begin
            @(negedge clk);
            ifm_in = ifm;
            psuma_in = psuma;
            psumb_in = psumb;
            tag_in_h = h_tag;
            tag_in_v = v_tag;
            valid_in_h = 1'b1;
            valid_in_va = vertical_valid;
            valid_in_vb = vertical_valid;
            @(negedge clk);
            valid_in_h = 1'b0;
            valid_in_va = 1'b0;
            valid_in_vb = 1'b0;
        end
    endtask

    integer failures = 0;
    integer result_count = 0;
    integer tag_mismatch_count = 0;
    integer collision_count = 0;

    always @(posedge clk) begin
        #1;
        if (!rst) begin
            if (valid_out_va !== valid_out_vb) begin
                $display("ERROR: paired result valids diverged");
                failures = failures + 1;
            end
            if (valid_out_va) begin
                case (result_count)
                    0: begin
                        if (($signed(psuma_out) !== 32'sd16) ||
                            ($signed(psumb_out) !== 32'sd11) ||
                            (tag_out_v !== make_tag(1'b0, 1'b0))) begin
                            $display("ERROR: bank0 result a=%0d b=%0d tag=%h",
                                $signed(psuma_out), $signed(psumb_out), tag_out_v);
                            failures = failures + 1;
                        end
                    end
                    1: begin
                        if (($signed(psuma_out) !== 32'sd92) ||
                            ($signed(psumb_out) !== -32'sd60) ||
                            (tag_out_v !== make_tag(1'b1, 1'b1))) begin
                            $display("ERROR: bank1 result a=%0d b=%0d tag=%h",
                                $signed(psuma_out), $signed(psumb_out), tag_out_v);
                            failures = failures + 1;
                        end
                    end
                    2: begin
                        if (($signed(psuma_out) !== 32'sd15) ||
                            ($signed(psumb_out) !== -32'sd2) ||
                            (tag_out_v !== make_tag(1'b0, 1'b1))) begin
                            $display("ERROR: post-reset result a=%0d b=%0d tag=%h",
                                $signed(psuma_out), $signed(psumb_out), tag_out_v);
                            failures = failures + 1;
                        end
                    end
                    default: begin
                        $display("ERROR: unexpected valid result a=%0d b=%0d tag=%h",
                            $signed(psuma_out), $signed(psumb_out), tag_out_v);
                        failures = failures + 1;
                    end
                endcase
                result_count = result_count + 1;
            end
            if (tag_mismatch_event)
                tag_mismatch_count = tag_mismatch_count + 1;
            if (weight_write_collision_event)
                collision_count = collision_count + 1;
        end
    end

    initial begin
        w_load = 1'b0;
        w_bank = 1'b0;
        w0_in = 8'sd0;
        w1_in = 8'sd0;
        ifm_in = 8'sd0;
        valid_in_h = 1'b0;
        tag_in_h = {TAG_W{1'b0}};
        psuma_in = 32'sd0;
        valid_in_va = 1'b0;
        psumb_in = 32'sd0;
        valid_in_vb = 1'b0;
        tag_in_v = {TAG_W{1'b0}};

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        load_weight(1'b0, 8'sd2, -8'sd3);
        load_weight(1'b1, 8'sd4, 8'sd5);

        // Adjacent cycles use different weight banks.  Both tails coexist in
        // the multiplier without changing the fixed mesh latency.
        send_token(8'sd3, 32'sd10, 32'sd20,
            make_tag(1'b0, 1'b0),
            make_tag(1'b0, 1'b0), 1'b1);
        send_token(-8'sd2, 32'sd100, -32'sd50,
            make_tag(1'b1, 1'b1),
            make_tag(1'b1, 1'b1), 1'b1);
        repeat (12) @(posedge clk);

        // A horizontal/vertical bank mismatch must be reported and must not
        // produce a committed vertical result.  Epoch is checked outside the
        // mesh before compact tags are issued.
        send_token(8'sd1, 32'sd0, 32'sd0,
            make_tag(1'b0, 1'b0),
            make_tag(1'b1, 1'b0), 1'b1);
        repeat (10) @(posedge clk);

        // Same-bank write and issue is illegal even if the epoch is unchanged.
        @(negedge clk);
        w_load = 1'b1;
        w_bank = 1'b1;
        w0_in = 8'sd4;
        w1_in = 8'sd5;
        ifm_in = 8'sd1;
        tag_in_h = make_tag(1'b1, 1'b0);
        valid_in_h = 1'b1;
        valid_in_va = 1'b0;
        valid_in_vb = 1'b0;
        @(negedge clk);
        w_load = 1'b0;
        valid_in_h = 1'b0;
        repeat (8) @(posedge clk);

        // Tag storage is intentionally reset-free so it can map to SRLs.
        // Resetting only valid must nevertheless flush an in-flight token;
        // stale bank/last bits must neither escape nor poison the first
        // token accepted after reset.
        send_token(8'sd7, 32'sd1, 32'sd2,
            make_tag(1'b1, 1'b0),
            make_tag(1'b1, 1'b0), 1'b1);
        rst = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (5) begin
            @(posedge clk);
            #1;
            if (valid_out_h || valid_out_va || valid_out_vb) begin
                $display("ERROR: in-flight token escaped validity reset");
                failures = failures + 1;
            end
        end

        send_token(8'sd4, 32'sd7, 32'sd10,
            make_tag(1'b0, 1'b1),
            make_tag(1'b0, 1'b1), 1'b1);
        repeat (12) @(posedge clk);

        if (result_count != 3) begin
            $display("ERROR: expected 3 committed results, got %0d", result_count);
            failures = failures + 1;
        end
        if (tag_mismatch_count == 0) begin
            $display("ERROR: tag mismatch was not detected");
            failures = failures + 1;
        end
        if (collision_count == 0) begin
            $display("ERROR: same-bank weight write collision was not detected");
            failures = failures + 1;
        end

        if (failures == 0)
            $display("PASS: tagged PE dual-bank/tag alignment");
        else
            $display("FAIL: tagged PE failures=%0d", failures);
        $finish;
    end
endmodule

`timescale 1ns / 1ps

module tb_axis_hwc_materialized_replay;
    localparam integer ROWS = 18;
    localparam integer PIXELS = 6;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg cfg_start = 1'b0;
    reg [7:0] cfg_epoch = 8'h41;
    wire s_axis_tready;
    reg s_axis_tvalid = 1'b0;
    reg [63:0] s_axis_tdata = 64'd0;
    reg [7:0] s_axis_tkeep = 8'd0;
    reg s_axis_tlast = 1'b0;
    reg fill_req = 1'b0;
    reg [15:0] pass_base_k = 16'd0;
    wire [ROWS*8-1:0] vector_data;
    wire [ROWS-1:0] vector_lane_valid;
    wire vector_valid;
    reg vector_ready = 1'b0;
    wire packet_done;

    wire [3:0] pass_ready_bitmap;
    wire [7:0] pass_ready_epoch;
    wire materializer_busy;
    wire replay_active;
    wire input_done;
    wire materialize_done;
    wire materializer_config_error;
    wire tkeep_error;
    wire tlast_error;
    wire materializer_overflow_error;
    wire bank_collision_error;
    wire row_overwrite_error;
    wire materializer_protocol_error;
    wire cache_config_error;
    wire cache_underflow_error;
    wire cache_overflow_error;
    wire cache_context_mismatch_error;
    wire [31:0] accepted_axis_beats;
    wire [31:0] accepted_axis_bytes;
    wire [31:0] emitted_entries;
    wire [31:0] accepted_cache_entries;
    wire [31:0] completed_replay_packets;
    wire [31:0] completed_replay_pixels;
    wire [31:0] underflow_count;
    wire [31:0] overflow_count;
    wire [31:0] context_mismatch_count;
    wire [31:0] axis_stall_cycles;
    wire [31:0] materializer_entry_stall_cycles;
    wire [31:0] materialize_cycles;
    wire [31:0] pass_wait_stall_cycles;
    wire [31:0] replay_backpressure_stall_cycles;
    wire [31:0] cache_entry_stall_cycles;

    integer checks = 0;
    integer failures = 0;
    integer expected_pass = 0;
    integer expected_pixel = 0;
    integer packet_pulses = 0;
    reg check_vectors = 1'b0;
    reg random_ready_enable = 1'b0;

    axis_hwc_materialized_replay #(
        .ROWS(ROWS),
        .MAX_FM_W(16),
        .MAX_CHANNELS(64),
        .LINE_BANK_DEPTH(16),
        .MAX_PASSES(4),
        .CACHE_AW(4),
        .CACHE_DEPTH(16)
    ) dut (
        .clk(clk),
        .rst(rst),
        .cfg_start(cfg_start),
        .cfg_fm_h(16'd2),
        .cfg_fm_w(16'd3),
        .cfg_cin(14'd20),
        .cfg_ofm_h(16'd2),
        .cfg_ofm_w(16'd3),
        .cfg_kernel_1x1(1'b1),
        .cfg_stride(2'd1),
        .cfg_pad(2'd0),
        .cfg_input_zero_point(8'd100),
        .cfg_epoch(cfg_epoch),
        .s_axis_tready(s_axis_tready),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .fill_req(fill_req),
        .pass_base_k(pass_base_k),
        .fill_pixel_base(32'd0),
        .fill_num_pixels(PIXELS),
        .vector_data(vector_data),
        .vector_lane_valid(vector_lane_valid),
        .vector_valid(vector_valid),
        .vector_ready(vector_ready),
        .packet_done(packet_done),
        .pass_ready_bitmap(pass_ready_bitmap),
        .pass_ready_epoch(pass_ready_epoch),
        .materializer_busy(materializer_busy),
        .replay_active(replay_active),
        .input_done(input_done),
        .materialize_done(materialize_done),
        .materializer_config_error(materializer_config_error),
        .tkeep_error(tkeep_error),
        .tlast_error(tlast_error),
        .materializer_overflow_error(materializer_overflow_error),
        .bank_collision_error(bank_collision_error),
        .row_overwrite_error(row_overwrite_error),
        .materializer_protocol_error(materializer_protocol_error),
        .cache_config_error(cache_config_error),
        .cache_underflow_error(cache_underflow_error),
        .cache_overflow_error(cache_overflow_error),
        .cache_context_mismatch_error(cache_context_mismatch_error),
        .accepted_axis_beats(accepted_axis_beats),
        .accepted_axis_bytes(accepted_axis_bytes),
        .emitted_entries(emitted_entries),
        .accepted_cache_entries(accepted_cache_entries),
        .completed_replay_packets(completed_replay_packets),
        .completed_replay_pixels(completed_replay_pixels),
        .underflow_count(underflow_count),
        .overflow_count(overflow_count),
        .context_mismatch_count(context_mismatch_count),
        .axis_stall_cycles(axis_stall_cycles),
        .materializer_entry_stall_cycles(
            materializer_entry_stall_cycles),
        .materialize_cycles(materialize_cycles),
        .pass_wait_stall_cycles(pass_wait_stall_cycles),
        .replay_backpressure_stall_cycles(
            replay_backpressure_stall_cycles),
        .cache_entry_stall_cycles(cache_entry_stall_cycles)
    );

    task check;
        input condition;
        input [8*96-1:0] label;
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $display("[FAIL] %0s", label);
            end
        end
    endtask

    function [7:0] raw_byte;
        input integer byte_index;
        integer pixel;
        integer channel;
        begin
            pixel = byte_index / 20;
            channel = byte_index % 20;
            raw_byte = 100 + pixel * 7 + channel;
        end
    endfunction

    function [ROWS*8-1:0] expected_vector;
        input integer pass_idx;
        input integer pixel_idx;
        integer lane;
        integer channel;
        begin
            expected_vector = {ROWS*8{1'b0}};
            for (lane = 0; lane < ROWS; lane = lane + 1) begin
                channel = pass_idx * ROWS + lane;
                if (channel < 20)
                    expected_vector[lane*8 +: 8] =
                        pixel_idx * 7 + channel;
            end
        end
    endfunction

    task send_raw_layer;
        integer beat;
        integer lane;
        integer byte_index;
        begin
            for (beat = 0; beat < 15; beat = beat + 1) begin
                @(negedge clk);
                s_axis_tdata = 64'd0;
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    byte_index = beat * 8 + lane;
                    s_axis_tdata[lane*8 +: 8] = raw_byte(byte_index);
                end
                s_axis_tkeep = 8'hff;
                s_axis_tlast = (beat == 14);
                s_axis_tvalid = 1'b1;
                @(posedge clk);
                while (!s_axis_tready)
                    @(posedge clk);
            end
            @(negedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tkeep = 8'd0;
            s_axis_tlast = 1'b0;
        end
    endtask

    task request_pass;
        input integer pass_idx;
        integer prior_packets;
        begin
            expected_pass = pass_idx;
            expected_pixel = 0;
            check_vectors = 1'b1;
            prior_packets = packet_pulses;
            @(negedge clk);
            pass_base_k = pass_idx * ROWS;
            fill_req = 1'b1;
            while (packet_pulses == prior_packets)
                @(negedge clk);
            fill_req = 1'b0;
            check_vectors = 1'b0;
            @(negedge clk);
        end
    endtask

    always @(negedge clk) begin
        if (random_ready_enable)
            vector_ready <= (($random & 32'h7) != 0);
    end

    always @(posedge clk) begin
        if (!rst && vector_valid && vector_ready && check_vectors) begin
            check(vector_data === expected_vector(expected_pass,
                                                  expected_pixel),
                  "materialized replay data");
            if (expected_pass == 0)
                check(vector_lane_valid === {ROWS{1'b1}},
                      "pass0 lane validity");
            else
                check(vector_lane_valid === 18'h00003,
                      "K-tail lane validity");
            expected_pixel = expected_pixel + 1;
        end
        if (!rst && packet_done) begin
            packet_pulses = packet_pulses + 1;
            check(expected_pixel == PIXELS,
                  "packet_done after all materialized pixels");
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);
        cfg_start = 1'b1;
        @(negedge clk);
        cfg_start = 1'b0;
        check(materializer_busy && !materializer_config_error &&
              !cache_config_error,
              "materializer and replay cache accept context");

        // Request pass0 before it is ready, then stream the layer.  The cache
        // waits on the materializer bitmap and begins without a second pulse.
        expected_pass = 0;
        expected_pixel = 0;
        check_vectors = 1'b1;
        pass_base_k = 16'd0;
        fill_req = 1'b1;
        vector_ready = 1'b1;
        random_ready_enable = 1'b1;
        fork
            send_raw_layer();
            begin
                while (packet_pulses == 0)
                    @(negedge clk);
            end
        join
        fill_req = 1'b0;
        check_vectors = 1'b0;
        @(negedge clk);

        check(expected_pixel == PIXELS, "pass0 full replay");
        check(cache_underflow_error && (underflow_count == 1),
              "early feeder request diagnosed once");
        check(pass_wait_stall_cycles != 0,
              "pass-ready wait cycles measured");

        request_pass(1);
        check(expected_pixel == PIXELS, "tail pass full replay");

        wait(materialize_done || !materializer_busy);
        repeat (2) @(posedge clk);
        check(input_done, "layer-long HWC input completed");
        check(pass_ready_bitmap[1:0] == 2'b11 &&
              (pass_ready_epoch == 8'h41),
              "both passes committed for active epoch");
        check(accepted_axis_beats == 15 && accepted_axis_bytes == 120,
              "packed AXIS traffic counted");
        check(emitted_entries == 12 && accepted_cache_entries == 12,
              "one atomic cache write per materialized vector");
        check(completed_replay_packets == 2 &&
              completed_replay_pixels == 12,
              "two feeder packets replayed");
        check(materializer_entry_stall_cycles == 0 &&
              cache_entry_stall_cycles == 0,
              "wide entry path sustains one vector per clock");
        check(!tkeep_error && !tlast_error &&
              !materializer_overflow_error && !bank_collision_error &&
              !row_overwrite_error && !materializer_protocol_error &&
              !cache_overflow_error && !cache_context_mismatch_error &&
              (overflow_count == 0) && (context_mismatch_count == 0),
              "no protocol, capacity, bank, or epoch errors");

        if (failures == 0)
            $display("[PASS] tb_axis_hwc_materialized_replay checks=%0d entries=%0d replay_bp=%0d",
                     checks, emitted_entries,
                     replay_backpressure_stall_cycles);
        else
            $display("[FAIL] tb_axis_hwc_materialized_replay failures=%0d checks=%0d",
                     failures, checks);
        $finish;
    end

    initial begin
        #300000;
        $display("[FAIL] tb_axis_hwc_materialized_replay timeout");
        $finish;
    end
endmodule

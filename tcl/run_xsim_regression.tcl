set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
source [file join $script_dir rtl_sources.tcl]
source [file join $script_dir build_common.tcl]
set build_dir [file join $root build_xsim]
file mkdir $build_dir
set run_id "[clock format [clock seconds] -format {%Y%m%d_%H%M%S}]_[pid]"
set run_root [file join $build_dir runs $run_id]

set top_filter {}
set waves 0
set include_diagnostic 0
set check_only 0
set result_json [file join $run_root regression_results.json]
set result_junit [file join $run_root regression_results.junit.xml]
set canonical_result_json [file join $build_dir regression_results.json]
set canonical_result_junit [file join $build_dir regression_results.junit.xml]
set driver_log [file join $build_dir "xsim_regression_driver_${run_id}.log"]
set tail_cycles 0
set raw_hwc_compute_start_level 0
set early_drain 0
set pass_prefetch 0
set during_compute_prefetch 0
set psum_stream_overlap 0
set continuous_psum 0
set column_psum 0
set coredbg 0
set layer_long_stream_cfg ""
for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-top"} {
        if {$i + 1 >= [llength $argv] ||
            [string match "-*" [lindex $argv [expr {$i + 1}]]]} {
            error "-top requires at least one test name"
        }
        incr i
        set top_filter [concat $top_filter [split [lindex $argv $i] ","]]
        while {$i + 1 < [llength $argv]} {
            set next_arg [lindex $argv [expr {$i + 1}]]
            if {[string match "-*" $next_arg]} {
                break
            }
            incr i
            set top_filter [concat $top_filter [split $next_arg ","]]
        }
    } elseif {$arg eq "-waves"} {
        set waves 1
    } elseif {$arg eq "-include_diagnostic"} {
        set include_diagnostic 1
    } elseif {$arg eq "-check_only"} {
        set check_only 1
    } elseif {$arg eq "-result_json"} {
        incr i
        if {$i >= [llength $argv]} {
            error "-result_json requires a path"
        }
        set result_json [file normalize [lindex $argv $i]]
    } elseif {$arg eq "-result_junit"} {
        incr i
        if {$i >= [llength $argv]} {
            error "-result_junit requires a path"
        }
        set result_junit [file normalize [lindex $argv $i]]
    } elseif {$arg eq "-driver_log"} {
        incr i
        if {$i >= [llength $argv]} {
            error "-driver_log requires a path"
        }
        set driver_log [file normalize [lindex $argv $i]]
    } elseif {$arg eq "-tail_cycles"} {
        incr i
        set tail_cycles [lindex $argv $i]
    } elseif {$arg eq "-raw_hwc_compute_start_level"} {
        incr i
        set raw_hwc_compute_start_level [lindex $argv $i]
    } elseif {$arg eq "-early_drain"} {
        set early_drain 1
    } elseif {$arg eq "-pass_prefetch"} {
        set pass_prefetch 1
    } elseif {$arg eq "-during_compute_prefetch"} {
        set during_compute_prefetch 1
    } elseif {$arg eq "-psum_stream_overlap"} {
        set psum_stream_overlap 1
    } elseif {$arg eq "-continuous_psum"} {
        set continuous_psum 1
    } elseif {$arg eq "-column_psum"} {
        set column_psum 1
    } elseif {$arg eq "-coredbg"} {
        set coredbg 1
    } elseif {$arg eq "-layer_long_stream_cfg"} {
        incr i
        if {$i >= [llength $argv]} {
            error "-layer_long_stream_cfg requires 03, 0b, or bf"
        }
        set layer_long_stream_cfg [string tolower [lindex $argv $i]]
        if {$layer_long_stream_cfg ni {03 0b bf}} {
            error "-layer_long_stream_cfg requires 03, 0b, or bf"
        }
    } else {
        error "unknown argument: $arg"
    }
}
set layer_long_stream_cfg_overridden [expr {$layer_long_stream_cfg ne ""}]
if {$layer_long_stream_cfg_overridden} {
    set effective_layer_long_stream_cfg $layer_long_stream_cfg
} else {
    set effective_layer_long_stream_cfg bf
}

# Per-run reports must never alias either canonical release result. Canonical
# files are published atomically only after the complete release gate passes.
set normalized_result_json [file normalize $result_json]
set normalized_result_junit [file normalize $result_junit]
set canonical_report_paths [list \
    [file normalize $canonical_result_json] \
    [file normalize $canonical_result_junit]]
if {[string equal -nocase $normalized_result_json $normalized_result_junit]} {
    error "-result_json and -result_junit must name different files"
}
foreach {option selected_path} [list \
    -result_json $normalized_result_json \
    -result_junit $normalized_result_junit] {
    foreach canonical_path $canonical_report_paths {
        if {[string equal -nocase $selected_path $canonical_path]} {
            error "$option may not overwrite a canonical regression result"
        }
    }
}

set common_files [::conv_accel_sources::relative_files]
set fast_sim_file [file normalize [file join $root tb \
    systolic_scalar_lane_dsp48e2_fast_sim.v]]
::conv_accel_sources::validate $root
::conv_accel_build::require_vivado_version 2022.2

set tests {
    {tb_tiling_model tb/tb_tiling_model.v}
    {tb_systolic_pe tb/tb_systolic_pe.v}
    {tb_systolic_pe_shadow_weight tb/tb_systolic_pe_shadow_weight.v}
    {tb_systolic_pe_tagged tb/tb_systolic_pe_tagged.v}
    {tb_cal_mult_int8_x2_2cycle_probe tb/tb_cal_mult_int8_x2_2cycle_probe.v}
    {tb_systolic_scalar_lane_dsp48e2 tb/tb_systolic_scalar_lane_dsp48e2.v}
    {tb_systolic_scalar_lane_dsp48e2_fast_diff tb/tb_systolic_scalar_lane_dsp48e2_fast_diff.v}
    {tb_systolic_array_dsp_cascade_tagged tb/tb_systolic_array_dsp_cascade_tagged.v}
    {tb_systolic_result_tagged_fifo tb/tb_systolic_result_tagged_fifo.v}
    {tb_systolic_top_tagged tb/tb_systolic_top_tagged.v}
    {tb_systolic_top_tagged_two_context_interleave tb/tb_systolic_top_tagged_two_context_interleave.v}
    {tb_systolic_top_tagged_preload_handoff tb/tb_systolic_top_tagged_preload_handoff.v}
    {tb_weight_context_preloader tb/tb_weight_context_preloader.v}
    {tb_weight_tile_pingpong_loader tb/tb_weight_tile_pingpong_loader.v}
    {tb_compute_pipe_telemetry tb/tb_compute_pipe_telemetry.v}
    {tb_conv_layer_top_stream_tagged_overlap tb/tb_conv_layer_top_stream_tagged_overlap.v}
    {tb_conv_layer_top_stream_tagged_overlap_r18c8 tb/tb_conv_layer_top_stream_tagged_overlap_r18c8.v}
    {tb_conv_layer_top_stream_tagged_overlap_r18c16 tb/tb_conv_layer_top_stream_tagged_overlap_r18c16.v}
    {tb_conv_layer_top_stream_tagged_fast_handoff tb/tb_conv_layer_top_stream_tagged_fast_handoff.v}
    {tb_conv_layer_top_stream_tagged_fast_handoff_k5 tb/tb_conv_layer_top_stream_tagged_fast_handoff_k5.v}
    {tb_conv_layer_top_stream_tagged_weight_credit_backpressure tb/tb_conv_layer_top_stream_tagged_weight_credit_backpressure.v}
    {tb_conv_layer_issue_handoff_guard tb/tb_conv_layer_issue_handoff_guard.v}
    {tb_systolic_top_feeder_vector_replay_ready tb/tb_systolic_top_feeder_vector_replay_ready.v}
    {tb_conv_layer_top_stream_tagged tb/tb_conv_layer_top_stream_tagged.v}
    {tb_systolic_array_small tb/tb_systolic_array_small.v}
    {tb_systolic_top_multipass tb/tb_systolic_top_multipass.v diagnostic}
    {tb_window_top_singlepass tb/tb_window_top_singlepass.v diagnostic}
    {tb_layer_scheduler_small tb/tb_layer_scheduler_small.v diagnostic}
    {tb_systolic_top_feeder_singlepass tb/tb_systolic_top_feeder_singlepass.v diagnostic}
    {tb_systolic_top_feeder_multipass_pingpong tb/tb_systolic_top_feeder_multipass_pingpong.v diagnostic}
    {tb_systolic_top_feeder_multipass_stream tb/tb_systolic_top_feeder_multipass_stream.v diagnostic}
    {tb_systolic_top_feeder_cout_blocks tb/tb_systolic_top_feeder_cout_blocks.v diagnostic}
    {tb_conv_layer_top_stream tb/tb_conv_layer_top_stream.v diagnostic}
    {tb_conv_accel_core tb/tb_conv_accel_core.v}
    {tb_conv_accel_core_layer_tile_sequence tb/tb_conv_accel_core_layer_tile_sequence.v}
    {tb_conv_accel_core_realistic_small tb/tb_conv_accel_core_realistic_small.v}
    {tb_conv_accel_core_pooling tb/tb_conv_accel_core_pooling.v}
    {tb_layer_scheduler_cout64_fulltile tb/tb_layer_scheduler_cout64_fulltile.v}
    {tb_layer_scheduler_stream tb/tb_layer_scheduler_stream.v}
    {tb_layer_scheduler_fast_context_handoff tb/tb_layer_scheduler_fast_context_handoff.v}
    {tb_layer_tile_sequencer tb/tb_layer_tile_sequencer.v}
    {tb_layer_scheduler_early_drain tb/tb_layer_scheduler_early_drain.v}
    {tb_layer_scheduler_pass_prefetch tb/tb_layer_scheduler_pass_prefetch.v}
    {tb_layer_scheduler_during_compute_prefetch tb/tb_layer_scheduler_during_compute_prefetch.v}
    {tb_layer_scheduler_psum_overlap tb/tb_layer_scheduler_psum_overlap.v}
    {tb_layer_scheduler_continuous_psum tb/tb_layer_scheduler_continuous_psum.v}
    {tb_layer_scheduler_overlap tb/tb_layer_scheduler_overlap.v}
    {tb_layer_scheduler_k9216 tb/tb_layer_scheduler_k9216.v}
    {tb_weight_tile_loader tb/tb_weight_tile_loader.v}
    {tb_conv_accel_core_cout64_fulltile tb/tb_conv_accel_core_cout64_fulltile.v}
    {tb_conv_accel_core_cout128_blocks tb/tb_conv_accel_core_cout128_blocks.v}
    {tb_conv_accel_core_spatial_tile tb/tb_conv_accel_core_spatial_tile.v}
    {tb_conv_accel_core_spatial_multitile tb/tb_conv_accel_core_spatial_multitile.v}
    {tb_conv_accel_core_ps_driver tb/tb_conv_accel_core_ps_driver.v}
    {tb_conv_accel_core_axi_lite_ps_driver tb/tb_conv_accel_core_axi_lite_ps_driver.v}
    {tb_conv_accel_core_axi_lite_stream_ps_driver tb/tb_conv_accel_core_axi_lite_stream_ps_driver.v}
    {tb_conv_accel_core_axi_lite_full_stream_ps_driver tb/tb_conv_accel_core_axi_lite_full_stream_ps_driver.v}
    {tb_conv_accel_core_axi_lite_axis_stream_smoke tb/tb_conv_accel_core_axi_lite_axis_stream_smoke.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r16_c16_smoke tb/tb_conv_accel_core_axi_lite_axis_stream_r16_c16_smoke.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c8_smoke tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c8_smoke.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_native1x1_small tb/tb_conv_accel_core_axi_lite_axis_stream_native1x1_small.v}
    {tb_conv_accel_axis_layer_long_release_p1_cin1024 tb/tb_conv_accel_axis_layer_long_release_p1_cin1024.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv7_native1x1_raw_hwc_ext_tile0 tb/tb_conv_accel_core_axi_lite_axis_stream_conv7_native1x1_raw_hwc_ext_tile0.v diagnostic}
    {tb_conv_accel_axis_layer_long_release_p169_odd_cin3 tb/tb_conv_accel_axis_layer_long_release_p169_odd_cin3.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv9_native1x1_raw_hwc_ext_tail tb/tb_conv_accel_core_axi_lite_axis_stream_conv9_native1x1_raw_hwc_ext_tail.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_smoke tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_smoke.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_packed_ofm_tail tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_packed_ofm_tail.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r32_c16_smoke tb/tb_conv_accel_core_axi_lite_axis_stream_r32_c16_smoke.v}
    {tb_conv_accel_core_axi_lite_axis_stream_pooling tb/tb_conv_accel_core_axi_lite_axis_stream_pooling.v}
    {tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_ext tb/tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_ext.v}
    {tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c8_b2_ext tb/tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c8_b2_ext.v}
    {tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c8_b2_batch_ext tb/tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c8_b2_batch_ext.v}
    {tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c16_b2_ext tb/tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c16_b2_ext.v}
    {tb_conv_accel_core_axi_lite_axis_stream_conv0_fullwidth_tile2_ext tb/tb_conv_accel_core_axi_lite_axis_stream_conv0_fullwidth_tile2_ext.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_input_zp tb/tb_conv_accel_core_axi_lite_axis_stream_input_zp.v}
    {tb_conv_accel_core_axi_lite_quant_lut tb/tb_conv_accel_core_axi_lite_quant_lut.v}
    {tb_conv_accel_core_axi_lite_full_stream_input_zp tb/tb_conv_accel_core_axi_lite_full_stream_input_zp.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tile4 tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tile4.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tile4_fifo16 tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tile4_fifo16.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tile4_fifo16_backpressure tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tile4_fifo16_backpressure.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_tile4 tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_tile4.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_layer06_ext_tile4 tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_layer06_ext_tile4.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_layer06_pool_ext_tile4 tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_layer06_pool_ext_tile4.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_conv4_pool_ext_tile4 tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_conv4_pool_ext_tile4.v}
    {tb_conv_accel_axis_layer_long_release_p936 tb/tb_conv_accel_axis_layer_long_release_p936.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_conv5_ext_tail tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_conv5_ext_tail.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv4_3x3_raw_hwc_ext_tile0_cout16 tb/tb_conv_accel_core_axi_lite_axis_stream_conv4_3x3_raw_hwc_ext_tile0_cout16.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv4_3x3_raw_hwc_ext_tile3_cout16 tb/tb_conv_accel_core_axi_lite_axis_stream_conv4_3x3_raw_hwc_ext_tile3_cout16.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv6_3x3_raw_hwc_ext_tile0_cout16 tb/tb_conv_accel_core_axi_lite_axis_stream_conv6_3x3_raw_hwc_ext_tile0_cout16.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv6_3x3_raw_hwc_fulltile_cout16 tb/tb_conv_accel_core_axi_lite_axis_stream_conv6_3x3_raw_hwc_fulltile_cout16.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv6_3x3_raw_hwc_ext_tile3_cout16 tb/tb_conv_accel_core_axi_lite_axis_stream_conv6_3x3_raw_hwc_ext_tile3_cout16.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv8_3x3_raw_hwc_ext_tile0_cout16 tb/tb_conv_accel_core_axi_lite_axis_stream_conv8_3x3_raw_hwc_ext_tile0_cout16.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv8_3x3_raw_hwc_fulltile_cout16 tb/tb_conv_accel_core_axi_lite_axis_stream_conv8_3x3_raw_hwc_fulltile_cout16.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv8_3x3_raw_hwc_ext_tile3_cout16 tb/tb_conv_accel_core_axi_lite_axis_stream_conv8_3x3_raw_hwc_ext_tile3_cout16.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv5_3x3_raw_hwc_ext_tile0_cout16 tb/tb_conv_accel_core_axi_lite_axis_stream_conv5_3x3_raw_hwc_ext_tile0_cout16.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv5_3x3_raw_hwc_fulltile_cout16 tb/tb_conv_accel_core_axi_lite_axis_stream_conv5_3x3_raw_hwc_fulltile_cout16.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv5_3x3_raw_hwc_overlap64_ext_tile0_cout16 tb/tb_conv_accel_core_axi_lite_axis_stream_conv5_3x3_raw_hwc_overlap64_ext_tile0_cout16.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv5_3x3_raw_hwc_ext_tile3_cout16 tb/tb_conv_accel_core_axi_lite_axis_stream_conv5_3x3_raw_hwc_ext_tile3_cout16.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tiles tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tiles.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_tiles tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_tiles.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_backpressure tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_backpressure.v}
    {tb_conv_accel_axis_layer_long_release_p1024 tb/tb_conv_accel_axis_layer_long_release_p1024.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_full tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_full.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_full tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_full.v}
    {tb_conv_accel_core_axi_lite_axis_stream_ps_driver tb/tb_conv_accel_core_axi_lite_axis_stream_ps_driver.v}
    {tb_conv_accel_core_axi_lite_axis_stream_backpressure tb/tb_conv_accel_core_axi_lite_axis_stream_backpressure.v}
    {tb_conv_accel_core_axi_lite_full_stream_backpressure tb/tb_conv_accel_core_axi_lite_full_stream_backpressure.v}
    {tb_layer_config_regs tb/tb_layer_config_regs.v}
    {tb_layer_long_descriptor_validation tb/tb_layer_long_descriptor_validation.v}
    {tb_pass_timeline_monitor tb/tb_pass_timeline_monitor.v}
    {tb_coltrace_monitor tb/tb_coltrace_monitor.v}
    {tb_axi_lite_cfg_bridge tb/tb_axi_lite_cfg_bridge.v}
    {tb_quant_param_regs tb/tb_quant_param_regs.v}
    {tb_requant tb/tb_requant.v}
    {tb_ofm_requant_writer tb/tb_ofm_requant_writer.v}
    {tb_psum_drain_writer tb/tb_psum_drain_writer.v}
    {tb_ofm_activation tb/tb_ofm_activation.v}
    {tb_ofm_pooling tb/tb_ofm_pooling.v}
    {tb_ofm_writeback tb/tb_ofm_writeback.v}
    {tb_bias_weight_stream_loader tb/tb_bias_weight_stream_loader.v}
    {tb_ifm_line_stream_loader tb/tb_ifm_line_stream_loader.v}
    {tb_axis_ifm_line_loader tb/tb_axis_ifm_line_loader.v}
    {tb_axis_ifm_vector_loader tb/tb_axis_ifm_vector_loader.v}
    {tb_axis_hwc_window_materializer tb/tb_axis_hwc_window_materializer.v}
    {tb_hwc_materialized_vector_cache tb/tb_hwc_materialized_vector_cache.v}
    {tb_hwc_materialized_tile_pingpong_cache tb/tb_hwc_materialized_tile_pingpong_cache.v}
    {tb_axis_hwc_tile_materialized_replay_done_seen tb/tb_axis_hwc_tile_materialized_replay_done_seen.v}
    {tb_axis_hwc_materialized_replay tb/tb_axis_hwc_materialized_replay.v}
    {tb_conv_accel_axis_layer_long_ifm tb/tb_conv_accel_axis_layer_long_ifm.v}
    {tb_conv_accel_axis_layer_long_two_tile_e2e tb/tb_conv_accel_axis_layer_long_two_tile_e2e.v}
    {tb_ifm_vector_epoch_buffer tb/tb_ifm_vector_epoch_buffer.v}
    {tb_ifm_context_epoch_frontend tb/tb_ifm_context_epoch_frontend.v}
    {tb_context_lifecycle_queue tb/tb_context_lifecycle_queue.v}
    {tb_context_event_fifo tb/tb_context_event_fifo.v}
    {tb_axis_hwc_tile_cache tb/tb_axis_hwc_tile_cache.v}
    {tb_psum_bank_ready_cut_equiv tb/tb_psum_bank_ready_cut_equiv.v}
    {tb_psum_bank_owner_scoreboard tb/tb_psum_bank_owner_scoreboard.v}
    {tb_psum_pingpong_buffer tb/tb_psum_pingpong_buffer.v}
    {tb_psum_pingpong_buffer_bram tb/tb_psum_pingpong_buffer_bram.v}
    {tb_psum_stream_feeder tb/tb_psum_stream_feeder.v}
    {tb_psum_column_stream tb/tb_psum_column_stream.v}
    {tb_psum_output_collector tb/tb_psum_output_collector.v}
    {tb_psum_output_collector_identity tb/tb_psum_output_collector_identity.v}
    {tb_psum_output_collector_scoreboard_failstop tb/tb_psum_output_collector_scoreboard_failstop.v}
    {tb_ifm_fill_handshake tb/tb_ifm_fill_handshake.v}
    {tb_line_stream_ctrl tb/tb_line_stream_ctrl.v}
    {tb_line_stream_ctrl_tile tb/tb_line_stream_ctrl_tile.v}
    {tb_linebuf_stream tb/tb_linebuf_stream.v}
    {tb_window_stream_ctrl tb/tb_window_stream_ctrl.v}
    {tb_window_feeder tb/tb_window_feeder.v}
    {tb_window_feeder_stride2 tb/tb_window_feeder_stride2.v}
    {tb_window_feeder_pad1 tb/tb_window_feeder_pad1.v}
    {tb_window_extract tb/tb_window_extract.v}
    {tb_axis_bias_weight_loader tb/tb_axis_bias_weight_loader.v}
    {tb_axis_batch_stream_loaders tb/tb_axis_batch_stream_loaders.v}
    {tb_axis_batch_stream_errors tb/tb_axis_batch_stream_errors.v}
    {tb_axis_ofm_byte_writer tb/tb_axis_ofm_byte_writer.v}
    {tb_ofm_hwc_axis_packer tb/tb_ofm_hwc_axis_packer.v}
    {tb_ofm_hwc_axis_pingpong tb/tb_ofm_hwc_axis_pingpong.v}
    {tb_ofm_packet_fifo tb/tb_ofm_packet_fifo.v}
    {tb_ofm_byte_stream_fifo tb/tb_ofm_byte_stream_fifo.v}
}

proc abs_files {root rels} {
    set out {}
    foreach rel $rels {
        lappend out [file normalize [file join $root $rel]]
    }
    return $out
}

proc selected {name filters} {
    if {[llength $filters] == 0} {
        return 1
    }
    foreach f $filters {
        if {$name eq $f} {
            return 1
        }
    }
    return 0
}

proc test_class {test} {
    set top [lindex $test 0]
    if {$top eq "tb_conv_accel_core_axi_lite_axis_stream_r18_c8_smoke"} {
        return "xfail"
    }
    if {[lindex $test 2] eq "diagnostic"} {
        return "stress"
    }
    return "normal"
}

proc json_escape {value} {
    return [string map [list \\ \\\\ \" \\" \n \\n \r \\r \t \\t] $value]
}

proc xml_escape {value} {
    return [string map [list & &amp\; < &lt\; > &gt\; \" &quot\; ' &apos\;] $value]
}

proc atomic_publish {source target} {
    if {![file isfile $source]} {
        error "cannot publish missing regression result: $source"
    }
    file mkdir [file dirname $target]
    set temporary "${target}.tmp.[pid]"
    if {[file exists $temporary]} {
        file delete -force -- $temporary
    }
    file copy -force -- $source $temporary
    file rename -force -- $temporary $target
}

proc count_result_status {results status} {
    set count 0
    foreach result $results {
        if {[dict get $result status] eq $status} {
            incr count
        }
    }
    return $count
}

proc write_json_report {path metadata manifest_counts results} {
    file mkdir [file dirname $path]
    set fh [open $path w]
    set dirty_literal [expr {[dict get $metadata git_dirty] ? "true" : "false"}]
    puts $fh "\{"
    puts $fh "  \"schema_version\": 1,"
    puts $fh "  \"git_root\": \"[json_escape [dict get $metadata git_root]]\","
    puts $fh "  \"git_sha\": \"[json_escape [dict get $metadata git_sha]]\","
    puts $fh "  \"git_dirty\": $dirty_literal,"
    puts $fh "  \"git_root_end\": \"[json_escape [dict get $metadata git_root_end]]\","
    puts $fh "  \"git_sha_end\": \"[json_escape [dict get $metadata git_sha_end]]\","
    puts $fh "  \"git_dirty_end\": [expr {[dict get $metadata git_dirty_end] ? {true} : {false}}],"
    puts $fh "  \"provenance_stable\": [expr {[dict get $metadata provenance_stable] ? {true} : {false}}],"
    puts $fh "  \"vivado_version\": \"[json_escape [dict get $metadata vivado_version]]\","
    puts $fh "  \"xelab_optimization\": \"[json_escape [dict get $metadata xelab_optimization]]\","
    puts $fh "  \"started_utc\": \"[json_escape [dict get $metadata started_utc]]\","
    puts $fh "  \"finished_utc\": \"[json_escape [dict get $metadata finished_utc]]\","
    puts $fh "  \"elapsed_seconds\": [format %.3f [dict get $metadata elapsed_seconds]],"
    puts $fh "  \"run_complete\": [expr {[dict get $metadata run_complete] ? {true} : {false}}],"
    puts $fh "  \"release_candidate\": [expr {[dict get $metadata release_candidate] ? {true} : {false}}],"
    puts $fh "  \"release_gate_passed\": [expr {[dict get $metadata release_gate_passed] ? {true} : {false}}],"
    puts $fh "  \"run_id\": \"[json_escape [dict get $metadata run_id]]\","
    puts $fh "  \"run_root\": \"[json_escape [dict get $metadata run_root]]\","
    puts $fh "  \"driver_log\": \"[json_escape [dict get $metadata driver_log]]\","
    puts $fh "  \"layer_long_stream_cfg\": \"[json_escape [dict get $metadata layer_long_stream_cfg]]\","
    puts $fh "  \"layer_long_stream_cfg_overridden\": [expr {[dict get $metadata layer_long_stream_cfg_overridden] ? {true} : {false}}],"
    puts $fh "  \"manifest\": \{"
    puts $fh "    \"normal\": [dict get $manifest_counts normal],"
    puts $fh "    \"stress\": [dict get $manifest_counts stress],"
    puts $fh "    \"xfail\": [dict get $manifest_counts xfail],"
    puts $fh "    \"must_pass\": [dict get $manifest_counts must_pass],"
    puts $fh "    \"total\": [dict get $manifest_counts total]"
    puts $fh "  \},"
    puts $fh "  \"summary\": \{"
    puts $fh "    \"selected\": [llength $results],"
    puts $fh "    \"pass\": [count_result_status $results PASS],"
    puts $fh "    \"xfail\": [count_result_status $results XFAIL],"
    puts $fh "    \"fail\": [count_result_status $results FAIL],"
    puts $fh "    \"xpass\": [count_result_status $results XPASS],"
    puts $fh "    \"xfail_signature_mismatch\": [count_result_status $results XFAIL_SIGNATURE_MISMATCH]"
    puts $fh "  \},"
    puts $fh "  \"tests\": \["
    set index 0
    foreach result $results {
        if {$index != 0} {
            puts $fh ","
        }
        puts -nonewline $fh "    \{"
        puts -nonewline $fh "\"name\":\"[json_escape [dict get $result name]]\","
        puts -nonewline $fh "\"class\":\"[json_escape [dict get $result class]]\","
        puts -nonewline $fh "\"status\":\"[json_escape [dict get $result status]]\","
        puts -nonewline $fh "\"elapsed_seconds\":[format %.3f [dict get $result elapsed_seconds]],"
        puts -nonewline $fh "\"message\":\"[json_escape [dict get $result message]]\","
        puts -nonewline $fh "\"xvlog_log\":\"[json_escape [dict get $result xvlog_log]]\","
        puts -nonewline $fh "\"xelab_log\":\"[json_escape [dict get $result xelab_log]]\","
        puts -nonewline $fh "\"xsim_log\":\"[json_escape [dict get $result xsim_log]]\"\}"
        incr index
    }
    puts $fh ""
    puts $fh "  \]"
    puts $fh "\}"
    close $fh
}

proc write_junit_report {path metadata results} {
    file mkdir [file dirname $path]
    set failures [expr {
        [count_result_status $results FAIL] +
        [count_result_status $results XPASS] +
        [count_result_status $results XFAIL_SIGNATURE_MISMATCH]
    }]
    set skipped [count_result_status $results XFAIL]
    set fh [open $path w]
    puts $fh "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    puts $fh "<testsuite name=\"xsim-regression\" tests=\"[llength $results]\" failures=\"$failures\" skipped=\"$skipped\" time=\"[format %.3f [dict get $metadata elapsed_seconds]]\">"
    puts $fh "  <properties>"
    puts $fh "    <property name=\"git.root\" value=\"[xml_escape [dict get $metadata git_root]]\"/>"
    puts $fh "    <property name=\"git.sha\" value=\"[xml_escape [dict get $metadata git_sha]]\"/>"
    puts $fh "    <property name=\"git.dirty\" value=\"[dict get $metadata git_dirty]\"/>"
    puts $fh "    <property name=\"git.root_end\" value=\"[xml_escape [dict get $metadata git_root_end]]\"/>"
    puts $fh "    <property name=\"git.sha_end\" value=\"[xml_escape [dict get $metadata git_sha_end]]\"/>"
    puts $fh "    <property name=\"git.dirty_end\" value=\"[dict get $metadata git_dirty_end]\"/>"
    puts $fh "    <property name=\"provenance.stable\" value=\"[dict get $metadata provenance_stable]\"/>"
    puts $fh "    <property name=\"vivado.version\" value=\"[xml_escape [dict get $metadata vivado_version]]\"/>"
    puts $fh "    <property name=\"xelab.optimization\" value=\"[xml_escape [dict get $metadata xelab_optimization]]\"/>"
    puts $fh "    <property name=\"run.id\" value=\"[xml_escape [dict get $metadata run_id]]\"/>"
    puts $fh "    <property name=\"run.root\" value=\"[xml_escape [dict get $metadata run_root]]\"/>"
    puts $fh "    <property name=\"driver.log\" value=\"[xml_escape [dict get $metadata driver_log]]\"/>"
    puts $fh "    <property name=\"layer_long.stream_cfg\" value=\"[xml_escape [dict get $metadata layer_long_stream_cfg]]\"/>"
    puts $fh "    <property name=\"layer_long.stream_cfg_overridden\" value=\"[dict get $metadata layer_long_stream_cfg_overridden]\"/>"
    puts $fh "    <property name=\"run.complete\" value=\"[dict get $metadata run_complete]\"/>"
    puts $fh "    <property name=\"release.candidate\" value=\"[dict get $metadata release_candidate]\"/>"
    puts $fh "    <property name=\"release.gate_passed\" value=\"[dict get $metadata release_gate_passed]\"/>"
    puts $fh "  </properties>"
    foreach result $results {
        set name [xml_escape [dict get $result name]]
        set class [xml_escape [dict get $result class]]
        set status [dict get $result status]
        set message [xml_escape [dict get $result message]]
        puts $fh "  <testcase classname=\"xsim.$class\" name=\"$name\" time=\"[format %.3f [dict get $result elapsed_seconds]]\">"
        if {$status eq "XFAIL"} {
            puts $fh "    <skipped message=\"expected failure: $message\"/>"
        } elseif {$status ne "PASS"} {
            puts $fh "    <failure type=\"$status\" message=\"$message\"/>"
        }
        puts $fh "    <system-out>xvlog=[xml_escape [dict get $result xvlog_log]]; xelab=[xml_escape [dict get $result xelab_log]]; xsim=[xml_escape [dict get $result xsim_log]]</system-out>"
        puts $fh "  </testcase>"
    }
    puts $fh "</testsuite>"
    close $fh
}

set known_tops {}
set known_tb_files {}
set manifest_counts [dict create normal 0 stress 0 xfail 0]
foreach test $tests {
    set top [lindex $test 0]
    set tb_file [lindex $test 1]
    set class [test_class $test]
    if {[lsearch -exact $known_tops $top] >= 0} {
        error "duplicate xsim top in manifest: $top"
    }
    if {[lsearch -exact $known_tb_files $tb_file] >= 0} {
        error "duplicate xsim testbench file in manifest: $tb_file"
    }
    if {![file exists [file join $root $tb_file]]} {
        error "xsim testbench file does not exist: $tb_file"
    }
    lappend known_tops $top
    lappend known_tb_files $tb_file
    dict incr manifest_counts $class
}
dict set manifest_counts must_pass [expr {
    [dict get $manifest_counts normal] + [dict get $manifest_counts stress]
}]
dict set manifest_counts total [llength $tests]

# This is a release gate, not merely an informational count.  Any test added,
# removed, or reclassified must deliberately update these expectations.
if {[dict get $manifest_counts normal] != 132 ||
    [dict get $manifest_counts stress] != 28 ||
    [dict get $manifest_counts xfail] != 1 ||
    [dict get $manifest_counts must_pass] != 160 ||
    [dict get $manifest_counts total] != 161} {
    error "XSIM manifest classification mismatch: expected normal=132 stress=28 xfail=1 must_pass=160 total=161, got normal=[dict get $manifest_counts normal] stress=[dict get $manifest_counts stress] xfail=[dict get $manifest_counts xfail] must_pass=[dict get $manifest_counts must_pass] total=[dict get $manifest_counts total]"
}

foreach requested_top $top_filter {
    if {[lsearch -exact $known_tops $requested_top] < 0} {
        error "unknown xsim test requested with -top: $requested_top"
    }
}

puts "=== XSIM manifest: normal=132 stress=28 xfail=1 must-pass=160 total=161 ==="
if {$check_only} {
    puts "=== XSIM manifest check passed; no simulations were run ==="
    return
}

# External-golden wrappers use paths relative to their immutable run
# directory.  The PowerShell entry point generates these ignored build
# products; direct Tcl users get an explicit preflight error rather than a
# cascade of readmemh warnings and X values.
set fixture_required 0
foreach test $tests {
    set top [lindex $test 0]
    set class [test_class $test]
    if {[llength $top_filter] == 0 && !$include_diagnostic && $class ne "normal"} {
        continue
    }
    if {![selected $top $top_filter]} {
        continue
    }
    set tb_path [file join $root [lindex $test 1]]
    set fh [open $tb_path r]
    set tb_text [read $fh]
    close $fh
    if {[string first "../../../fixtures/" $tb_text] >= 0} {
        set fixture_required 1
        break
    }
}
if {$fixture_required} {
    ::conv_accel_build::require_xsim_fixtures $root
}

set xvlog [auto_execok xvlog]
set xelab [auto_execok xelab]
set xsim  [auto_execok xsim]
set xelab_debug [expr {$waves ? "typical" : "off"}]
set xelab_optimization O2
if {$xvlog eq "" || $xelab eq "" || $xsim eq ""} {
    error "xvlog/xelab/xsim not found in PATH"
}
if {[info exists ::env(XILINX_VIVADO)] &&
    [string trim $::env(XILINX_VIVADO)] ne ""} {
    set vivado_install_root [file normalize $::env(XILINX_VIVADO)]
} else {
    # auto_execok may return a command prefix; its first element is the
    # executable path for a normal Vivado installation.
    set vivado_install_root [file dirname [file dirname \
        [file normalize [lindex $xvlog 0]]]]
}
set glbl_file [file normalize [file join $vivado_install_root \
    data verilog src glbl.v]]
if {![file isfile $glbl_file]} {
    error "Vivado global simulation source is missing: $glbl_file"
}

set regression_start_ms [clock milliseconds]
set unknown_provenance [dict create \
    git_root unknown git_sha unknown git_dirty 1]
set start_provenance $unknown_provenance
if {[catch {::conv_accel_build::git_provenance $root} detected_provenance] == 0} {
    set start_provenance $detected_provenance
}
set provenance_stable \
    [::conv_accel_build::git_provenance_valid $start_provenance]
set metadata [dict create \
    git_root [dict get $start_provenance git_root] \
    git_sha [dict get $start_provenance git_sha] \
    git_dirty [dict get $start_provenance git_dirty] \
    git_root_end unknown \
    git_sha_end unknown \
    git_dirty_end 1 \
    provenance_stable $provenance_stable \
    vivado_version [version -short] \
    xelab_optimization $xelab_optimization \
    started_utc [clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}] \
    finished_utc "" \
    elapsed_seconds 0.0 \
    run_complete 0 \
    release_candidate 0 \
    release_gate_passed 0 \
    run_id $run_id \
    run_root [file normalize $run_root] \
    driver_log [file normalize $driver_log]]
dict set metadata layer_long_stream_cfg $effective_layer_long_stream_cfg
dict set metadata layer_long_stream_cfg_overridden \
    $layer_long_stream_cfg_overridden

set results {}
set ran_count 0
foreach test $tests {
    set top [lindex $test 0]
    set tb_file [lindex $test 1]
    set class [test_class $test]
    if {[llength $top_filter] == 0 && !$include_diagnostic && $class ne "normal"} {
        continue
    }
    if {![selected $top $top_filter]} {
        continue
    }
    incr ran_count
    set test_start_ms [clock milliseconds]

    if {[catch {::conv_accel_build::git_provenance $root} checkpoint_provenance]} {
        set provenance_stable 0
    } elseif {![::conv_accel_build::git_provenance_matches \
            $start_provenance $checkpoint_provenance]} {
        set provenance_stable 0
    }

    puts "=== xsim compile $top (class=$class) ==="
    # Each invocation gets an immutable run directory.  This avoids transient
    # Windows locks on a previous xsim.log and prevents a later run from
    # silently reusing a stale snapshot or log.
    set run_dir [file join $run_root $top]
    file mkdir $run_dir
    set srcs [abs_files $root $common_files]
    if {$top eq "tb_systolic_scalar_lane_dsp48e2_fast_diff"} {
        lappend srcs $fast_sim_file
    }
    set srcs [concat $srcs [abs_files $root [list $tb_file]] \
        [list $glbl_file]]

    set xvlog_log [file normalize [file join $run_dir xvlog.log]]
    set xelab_log [file normalize [file join $run_dir xelab.log]]
    set xsim_log  [file normalize [file join $run_dir xsim.log]]
    # The per-test directory already provides namespace isolation.  A short
    # snapshot name avoids the Win32 MAX_PATH failure triggered by the longest
    # release stress-test top name under xsim.dir/.
    set snapshot xsim_snapshot
    cd $run_dir
    set tail_include [file join $run_dir tail_cycles_override.vh]
    set fh [open $tail_include w]
    if {$tail_cycles != 0} {
        puts $fh "`define TB_TAIL_CYCLES_OVERRIDE $tail_cycles"
    }
    if {$raw_hwc_compute_start_level != 0} {
        puts $fh "`define TB_RAW_HWC_COMPUTE_START_LEVEL_OVERRIDE $raw_hwc_compute_start_level"
    }
    if {$early_drain != 0} {
        puts $fh "`define TB_EARLY_DRAIN_OVERRIDE 1"
    }
    if {$pass_prefetch != 0} {
        puts $fh "`define TB_PASS_PREFETCH_OVERRIDE 1"
    }
    if {$during_compute_prefetch != 0} {
        puts $fh "`define TB_DURING_COMPUTE_PREFETCH_OVERRIDE 1"
    }
    if {$psum_stream_overlap != 0} {
        puts $fh "`define TB_PSUM_STREAM_OVERLAP_OVERRIDE 1"
    }
    if {$continuous_psum != 0} {
        puts $fh "`define TB_CONTINUOUS_PSUM_OVERRIDE 1"
    }
    if {$column_psum != 0} {
        puts $fh "`define TB_COLUMN_PSUM_OVERRIDE 1"
    }
    if {$coredbg != 0} {
        puts $fh "`define TB_CONV_ACCEL_CORE_PROGRESS_COREDBG 1"
    }
    puts $fh "`define TB_LAYER_LONG_STREAM_CFG 8'h${effective_layer_long_stream_cfg}"
    close $fh

    set stage_error ""
    set stage_error_kind ""
    if {[catch {
        exec {*}$xvlog -sv -L work \
            -i $root -i [file join $root tb] \
            -log $xvlog_log {*}$srcs >@ stdout 2>@ stderr
    } tool_message]} {
        set stage_error_kind "xvlog"
        set stage_error "xvlog failed: $tool_message"
    }
    # The release row-store instantiates xpm_memory_tdpram directly.  Keep the
    # precompiled XPM simulation library explicit so every selected test sees
    # the same elaboration environment, including focused materializer runs.
    # The release materializer uses XPM memories and the low-density tagged
    # array explicitly instantiates DSP48E2 primitives.  Use the same vendor
    # simulation libraries for every test so a module cannot pass a focused
    # flow and then fail only when it enters the canonical manifest.
    set xelab_args [list --$xelab_optimization -debug $xelab_debug \
        -L xpm -L unisims_ver]
    if {$stage_error eq "" && [catch {
        exec {*}$xelab {*}$xelab_args -top $top -top glbl \
            -snapshot $snapshot \
            -log $xelab_log >@ stdout 2>@ stderr
    } tool_message]} {
        set stage_error_kind "xelab"
        set stage_error "xelab failed: $tool_message"
    }

    if {$stage_error eq ""} {
        puts "=== xsim run $top (class=$class) ==="
        if {$waves} {
            set wdb [file join $run_dir "${top}.wdb"]
            if {[catch {
                exec {*}$xsim $snapshot -R -onerror quit -onfinish quit \
                    -wdb $wdb -log $xsim_log >@ stdout 2>@ stderr
            } tool_message]} {
                set stage_error_kind "xsim"
                set stage_error "xsim failed: $tool_message"
            }
        } elseif {[catch {
            exec {*}$xsim $snapshot -R -onerror quit -onfinish quit \
                -log $xsim_log >@ stdout 2>@ stderr
        } tool_message]} {
            set stage_error_kind "xsim"
            set stage_error "xsim failed: $tool_message"
        }
    }

    set log_text ""
    if {[file exists $xsim_log]} {
        set fh [open $xsim_log r]
        set log_text [read $fh]
        close $fh
    }

    set status PASS
    set message "completed without a failure signature"
    if {$stage_error ne "" && !($class eq "xfail" && $stage_error_kind eq "xsim")} {
        set status FAIL
        set message $stage_error
    } elseif {$class eq "xfail"} {
        set exact_summary_count [regexp -all -nocase {===\s*tb_conv_accel_core_axi_lite_axis_stream_r18_c8_smoke:\s*17\s+pass,\s*160\s+fail\s*===} $log_text]
        set fail_line_count [regexp -all -line -nocase {^\[FAIL\]} $log_text]
        set fatal_count [regexp -all -nocase {\mfatal\M|\merror:} $log_text]
        if {$stage_error eq "" && $exact_summary_count == 1 &&
            $fail_line_count == 160 && $fatal_count == 0} {
            set status XFAIL
            set message "matched exact expected signature: 17 pass / 160 fail"
        } elseif {$stage_error eq "" && $fail_line_count == 0 &&
                  ![regexp -nocase {\mfail[[:space:]]*(?:\:|case=)|\*\*\*[[:space:]]+failures[[:space:]]+detected[[:space:]]+\*\*\*|\mfatal\M|\merror:} $log_text]} {
            set status XPASS
            set message "expected 17 pass / 160 fail, but the test unexpectedly passed"
        } else {
            set status XFAIL_SIGNATURE_MISMATCH
            set message "expected exactly one 17 pass / 160 fail summary and 160 \[FAIL\] lines; observed summary_count=$exact_summary_count fail_lines=$fail_line_count fatal_or_error=$fatal_count"
        }
    } elseif {[regexp -nocase {\[fail\]|\mfail[[:space:]]*(?:\:|case=)|\*\*\*[[:space:]]+failures[[:space:]]+detected[[:space:]]+\*\*\*|\mfatal\M|\merror:} $log_text]} {
        set status FAIL
        set message "xsim log contains a failure signature"
    }

    set test_elapsed [expr {([clock milliseconds] - $test_start_ms) / 1000.0}]
    lappend results [dict create \
        name $top class $class status $status elapsed_seconds $test_elapsed \
        message [string range $message 0 2047] \
        xvlog_log $xvlog_log xelab_log $xelab_log xsim_log $xsim_log]
    puts "=== xsim result $top: $status ([format %.3f $test_elapsed] s) ==="

    dict set metadata finished_utc [clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]
    dict set metadata elapsed_seconds [expr {([clock milliseconds] - $regression_start_ms) / 1000.0}]
    dict set metadata provenance_stable $provenance_stable
    write_json_report $result_json $metadata $manifest_counts $results
    write_junit_report $result_junit $metadata $results
}

if {$ran_count == 0} {
    error "no xsim test matched -top filter"
}

set failure_count [expr {
    [count_result_status $results FAIL] +
    [count_result_status $results XPASS] +
    [count_result_status $results XFAIL_SIGNATURE_MISMATCH]
}]
set pass_count [count_result_status $results PASS]
set xfail_count [count_result_status $results XFAIL]
set end_provenance $unknown_provenance
if {[catch {::conv_accel_build::git_provenance $root} detected_provenance] == 0} {
    set end_provenance $detected_provenance
}
if {![::conv_accel_build::git_provenance_matches \
        $start_provenance $end_provenance]} {
    set provenance_stable 0
}
dict set metadata git_root_end [dict get $end_provenance git_root]
dict set metadata git_sha_end [dict get $end_provenance git_sha]
dict set metadata git_dirty_end [dict get $end_provenance git_dirty]
dict set metadata provenance_stable $provenance_stable
set source_provenance_clean [expr {
    [::conv_accel_build::git_provenance_is_clean $start_provenance] &&
    $provenance_stable
}]
set release_candidate [expr {
    [llength $top_filter] == 0 && $include_diagnostic && !$waves &&
    $tail_cycles == 0 && $raw_hwc_compute_start_level == 0 &&
    !$early_drain && !$pass_prefetch && !$during_compute_prefetch &&
    !$psum_stream_overlap && !$continuous_psum && !$column_psum &&
    !$coredbg && !$layer_long_stream_cfg_overridden &&
    $source_provenance_clean &&
    $ran_count == [dict get $manifest_counts total]
}]
set release_gate_passed [expr {
    $release_candidate && $failure_count == 0 &&
    $pass_count == [dict get $manifest_counts must_pass] &&
    $xfail_count == [dict get $manifest_counts xfail]
}]
dict set metadata finished_utc \
    [clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]
dict set metadata elapsed_seconds \
    [expr {([clock milliseconds] - $regression_start_ms) / 1000.0}]
dict set metadata run_complete 1
dict set metadata release_candidate $release_candidate
dict set metadata release_gate_passed $release_gate_passed
write_json_report $result_json $metadata $manifest_counts $results
write_junit_report $result_junit $metadata $results
if {$release_gate_passed} {
    atomic_publish $result_json $canonical_result_json
    atomic_publish $result_junit $canonical_result_junit
}
puts "=== XSIM summary: selected=$ran_count pass=$pass_count xfail=$xfail_count failures=$failure_count ==="
puts "=== JSON: [file normalize $result_json] ==="
puts "=== JUnit: [file normalize $result_junit] ==="
if {$release_gate_passed} {
    puts "=== Canonical JSON: [file normalize $canonical_result_json] ==="
    puts "=== Canonical JUnit: [file normalize $canonical_result_junit] ==="
} else {
    puts "=== Canonical result unchanged (requires the complete 160-pass plus one-exact-xfail release gate) ==="
}
if {$failure_count != 0} {
    error "XSIM regression completed with $failure_count failing result(s)"
}
puts "=== selected xsim regressions passed ==="

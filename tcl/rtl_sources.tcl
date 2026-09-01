# Canonical RTL source manifest shared by OOC synthesis, Block Design/IP
# packaging, and XSIM.  Keep this list explicit and ordered: helper modules
# must precede the tops that instantiate them.

namespace eval ::conv_accel_sources {
    variable rtl_files {
        cal/cal_mul_int8_x2_dsp.v
        cal/cal_mul_int8_x2.v
        cal/cal_mul_int8_x2_2cycle.v
        cal/dsp48e2_scalar_mac_stage.v
        com/com_shift_reg.v
        systolic/systolic_pe.v
        systolic/systolic_pe_shadow_weight.v
        systolic/systolic_pe_tagged.v
        systolic/systolic_scalar_lane_dsp48e2.v
        systolic/systolic_array_32x32.v
        systolic/systolic_array_tagged.v
        systolic/systolic_array_dsp_cascade_tagged.v
        systolic/systolic_fifo.v
        systolic/systolic_ctrl.v
        systolic/systolic_ctrl_tagged.v
        systolic/weight_context_preloader.v
        systolic/line_stream_ctrl.v
        systolic/window_stream_ctrl.v
        systolic/line_buffer_5bank.v
        systolic/window_extract.v
        systolic/window_feeder.v
        systolic/systolic_top_feeder.v
        systolic/layer_scheduler_stream.v
        systolic/layer_tile_sequencer.v
        systolic/pass_timeline_monitor.v
        systolic/compute_pipe_telemetry.v
        systolic/coltrace_monitor.v
        systolic/weight_tile_loader.v
        systolic/weight_tile_pingpong_loader.v
        systolic/bias_weight_stream_loader.v
        systolic/axis_bias_weight_loader.v
        systolic/ifm_line_stream_loader.v
        systolic/axis_ifm_line_loader.v
        systolic/axis_ifm_vector_loader.v
        systolic/axis_hwc_tile_cache.v
        systolic/axis_hwc_window_materializer.v
        systolic/axis_hwc_window_materializer_bram.v
        systolic/axis_hwc_window_row_store.v
        systolic/axis_hwc_window_materializer_byte_bram.v
        systolic/hwc_materialized_vector_cache.v
        systolic/hwc_materialized_tile_pingpong_cache.v
        systolic/axis_hwc_tile_materialized_replay.v
        systolic/axis_hwc_materialized_replay.v
        systolic/ifm_vector_epoch_buffer.v
        systolic/ifm_context_epoch_frontend.v
        systolic/context_lifecycle_queue.v
        systolic/context_event_fifo.v
        systolic/psum_bank_owner_scoreboard.v
        systolic/psum_pingpong_buffer.v
        systolic/psum_column_pingpong_buffer.v
        systolic/psum_column_stream_feeder.v
        systolic/psum_column_output_collector.v
        systolic/psum_output_collector.v
        systolic/psum_stream_feeder.v
        systolic/psum_drain_writer.v
        systolic/psum_packet_fifo.v
        systolic/ofm_requant_writer.v
        systolic/ofm_activation.v
        systolic/ofm_pooling.v
        systolic/ofm_writeback.v
        systolic/ofm_packet_fifo.v
        systolic/ofm_byte_stream_fifo.v
        systolic/axis_ofm_byte_writer.v
        systolic/ofm_hwc_axis_packer.v
        systolic/ofm_hwc_axis_pingpong.v
        systolic/conv_layer_top_stream.v
        systolic/layer_config_regs.v
        systolic/quant_param_regs.v
        systolic/axi_lite_cfg_bridge.v
        systolic/conv_accel_core.v
        systolic/conv_accel_core_axi_lite.v
        systolic/conv_accel_core_axi_lite_stream.v
        systolic/conv_accel_core_axi_lite_full_stream.v
        systolic/conv_accel_core_axi_lite_axis_stream.v
        systolic/requant.v
        systolic/leaky_lut.v
        systolic/systolic_top_tagged.v
        systolic/systolic_top.v
    }
}

proc ::conv_accel_sources::relative_files {} {
    variable rtl_files
    return $rtl_files
}

proc ::conv_accel_sources::validate {root} {
    variable rtl_files
    set seen [dict create]
    set missing {}
    foreach rel $rtl_files {
        if {[dict exists $seen $rel]} {
            error "duplicate RTL manifest entry: $rel"
        }
        dict set seen $rel 1
        if {![file isfile [file join $root $rel]]} {
            lappend missing $rel
        }
    }
    if {[llength $missing] != 0} {
        error "RTL manifest references missing files: [join $missing {, }]"
    }

    # A newly added synthesizable module must not silently enter only one flow.
    set unlisted {}
    foreach dir {cal com systolic} {
        foreach pattern {*.v *.sv} {
            foreach path [glob -nocomplain -directory [file join $root $dir] $pattern] {
                set rel "$dir/[file tail $path]"
                if {![dict exists $seen $rel]} {
                    lappend unlisted $rel
                }
            }
        }
    }
    if {[llength $unlisted] != 0} {
        error "Verilog files missing from canonical RTL manifest: [join [lsort $unlisted] {, }]"
    }
    return [llength $rtl_files]
}

proc ::conv_accel_sources::absolute_files {root} {
    variable rtl_files
    validate $root
    set out {}
    foreach rel $rtl_files {
        lappend out [file normalize [file join $root $rel]]
    }
    return $out
}

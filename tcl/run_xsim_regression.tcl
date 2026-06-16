set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
set build_dir [file join $root build_xsim]
file mkdir $build_dir

set top_filter {}
set waves 0
set tail_cycles 0
set raw_hwc_compute_start_level 0
set early_drain 0
set pass_prefetch 0
set during_compute_prefetch 0
set psum_stream_overlap 0
set continuous_psum 0
set column_psum 0
set coredbg 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-top"} {
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
    } else {
        error "unknown argument: $arg"
    }
}

set common_files {
    cal/cal_mul_int8_x2_dsp.v
    cal/cal_mul_int8_x2.v
    com/com_shift_reg.v
    systolic/systolic_pe.v
    systolic/systolic_array_32x32.v
    systolic/systolic_fifo.v
    systolic/systolic_ctrl.v
    systolic/line_stream_ctrl.v
    systolic/window_stream_ctrl.v
    systolic/line_buffer_5bank.v
    systolic/window_extract.v
    systolic/window_feeder.v
    systolic/systolic_top_feeder.v
    systolic/layer_scheduler_stream.v
    systolic/pass_timeline_monitor.v
    systolic/coltrace_monitor.v
    systolic/weight_tile_loader.v
    systolic/bias_weight_stream_loader.v
    systolic/axis_bias_weight_loader.v
    systolic/ifm_line_stream_loader.v
    systolic/axis_ifm_line_loader.v
    systolic/axis_ifm_vector_loader.v
    systolic/axis_hwc_tile_cache.v
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
    systolic/systolic_top.v
}

set tests {
    {tb_systolic_pe tb/tb_systolic_pe.v}
    {tb_systolic_array_small tb/tb_systolic_array_small.v}
    {tb_systolic_top_multipass tb/tb_systolic_top_multipass.v diagnostic}
    {tb_window_top_singlepass tb/tb_window_top_singlepass.v diagnostic}
    {tb_layer_scheduler_small tb/tb_layer_scheduler_small.v diagnostic}
    {tb_systolic_top_feeder_singlepass tb/tb_systolic_top_feeder_singlepass.v diagnostic}
    {tb_systolic_top_feeder_multipass_pingpong tb/tb_systolic_top_feeder_multipass_pingpong.v diagnostic}
    {tb_systolic_top_feeder_multipass_stream tb/tb_systolic_top_feeder_multipass_stream.v diagnostic}
    {tb_systolic_top_feeder_cout_blocks tb/tb_systolic_top_feeder_cout_blocks.v diagnostic}
    {tb_conv_layer_top_stream tb/tb_conv_layer_top_stream.v diagnostic}
    {tb_conv_accel_core_realistic_small tb/tb_conv_accel_core_realistic_small.v}
    {tb_conv_accel_core_pooling tb/tb_conv_accel_core_pooling.v}
    {tb_layer_scheduler_cout64_fulltile tb/tb_layer_scheduler_cout64_fulltile.v}
    {tb_layer_scheduler_stream tb/tb_layer_scheduler_stream.v}
    {tb_layer_scheduler_early_drain tb/tb_layer_scheduler_early_drain.v}
    {tb_layer_scheduler_pass_prefetch tb/tb_layer_scheduler_pass_prefetch.v}
    {tb_layer_scheduler_psum_overlap tb/tb_layer_scheduler_psum_overlap.v}
    {tb_layer_scheduler_continuous_psum tb/tb_layer_scheduler_continuous_psum.v}
    {tb_layer_scheduler_k9216 tb/tb_layer_scheduler_k9216.v}
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
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c8_smoke tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c8_smoke.v}
    {tb_conv_accel_core_axi_lite_axis_stream_native1x1_small tb/tb_conv_accel_core_axi_lite_axis_stream_native1x1_small.v}
    {tb_conv_accel_core_axi_lite_axis_stream_conv7_native1x1_ext_tile0 tb/tb_conv_accel_core_axi_lite_axis_stream_conv7_native1x1_ext_tile0.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv7_native1x1_raw_hwc_ext_tile0 tb/tb_conv_accel_core_axi_lite_axis_stream_conv7_native1x1_raw_hwc_ext_tile0.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv9_native1x1_ext_tail tb/tb_conv_accel_core_axi_lite_axis_stream_conv9_native1x1_ext_tail.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_conv9_native1x1_raw_hwc_ext_tail tb/tb_conv_accel_core_axi_lite_axis_stream_conv9_native1x1_raw_hwc_ext_tail.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_smoke tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_smoke.v}
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
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_conv5_ext_tail_cout16 tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_conv5_ext_tail_cout16.v diagnostic}
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
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_full_fifo256 tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_full_fifo256.v diagnostic}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_full tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_full.v}
    {tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_full tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_full.v}
    {tb_conv_accel_core_axi_lite_axis_stream_ps_driver tb/tb_conv_accel_core_axi_lite_axis_stream_ps_driver.v}
    {tb_conv_accel_core_axi_lite_axis_stream_backpressure tb/tb_conv_accel_core_axi_lite_axis_stream_backpressure.v}
    {tb_conv_accel_core_axi_lite_full_stream_backpressure tb/tb_conv_accel_core_axi_lite_full_stream_backpressure.v}
    {tb_layer_config_regs tb/tb_layer_config_regs.v}
    {tb_pass_timeline_monitor tb/tb_pass_timeline_monitor.v}
    {tb_coltrace_monitor tb/tb_coltrace_monitor.v}
    {tb_axi_lite_cfg_bridge tb/tb_axi_lite_cfg_bridge.v}
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
    {tb_axis_hwc_tile_cache tb/tb_axis_hwc_tile_cache.v}
    {tb_psum_pingpong_buffer_bram tb/tb_psum_pingpong_buffer_bram.v}
    {tb_psum_stream_feeder tb/tb_psum_stream_feeder.v}
    {tb_psum_column_stream tb/tb_psum_column_stream.v}
    {tb_psum_output_collector tb/tb_psum_output_collector.v}
    {tb_ifm_fill_handshake tb/tb_ifm_fill_handshake.v}
    {tb_window_extract tb/tb_window_extract.v}
    {tb_axis_bias_weight_loader tb/tb_axis_bias_weight_loader.v}
    {tb_axis_batch_stream_loaders tb/tb_axis_batch_stream_loaders.v}
    {tb_axis_batch_stream_errors tb/tb_axis_batch_stream_errors.v}
    {tb_axis_ofm_byte_writer tb/tb_axis_ofm_byte_writer.v}
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

set xvlog [auto_execok xvlog]
set xelab [auto_execok xelab]
set xsim  [auto_execok xsim]
if {$xvlog eq "" || $xelab eq "" || $xsim eq ""} {
    error "xvlog/xelab/xsim not found in PATH"
}

set ran_count 0
foreach test $tests {
    set top [lindex $test 0]
    set tb_file [lindex $test 1]
    set test_kind [lindex $test 2]
    if {[llength $top_filter] == 0 && $test_kind eq "diagnostic"} {
        continue
    }
    if {![selected $top $top_filter]} {
        continue
    }
    incr ran_count

    puts "=== xsim compile $top ==="
    set run_dir [file join $build_dir $top]
    file mkdir $run_dir
    set srcs [concat [abs_files $root $common_files] [abs_files $root [list $tb_file]]]

    set xvlog_log [file join $run_dir xvlog.log]
    set xelab_log [file join $run_dir xelab.log]
    set xsim_log  [file join $run_dir xsim.log]
    set snapshot "${top}_snap"

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
    close $fh
    exec {*}$xvlog -sv -L work -i [file join $root tb] -log $xvlog_log {*}$srcs >@ stdout 2>@ stderr
    exec {*}$xelab -debug typical -top $top -snapshot $snapshot -log $xelab_log >@ stdout 2>@ stderr

    puts "=== xsim run $top ==="
    if {$waves} {
        set wdb [file join $run_dir "${top}.wdb"]
        exec {*}$xsim $snapshot -R -wdb $wdb -log $xsim_log >@ stdout 2>@ stderr
    } else {
        exec {*}$xsim $snapshot -R -log $xsim_log >@ stdout 2>@ stderr
    }

    set fh [open $xsim_log r]
    set log_text [read $fh]
    close $fh
    if {[regexp {\[FAIL\]|Fatal|Error:} $log_text]} {
        error "xsim reported a failure for $top; see $xsim_log"
    }
}

if {$ran_count == 0} {
    error "no xsim test matched -top filter"
}

puts "=== selected xsim regressions passed ==="

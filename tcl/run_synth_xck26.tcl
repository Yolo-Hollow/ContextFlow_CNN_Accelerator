set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
set build_dir [file join $root build_synth_xck26]
file mkdir $build_dir

set top conv_accel_core_axi_lite_axis_stream
set part xck26-sfvc784-2LV-c
set jobs 8
set rows 18
set cols 8
set k_tile 18
set cout_tile 16
set ifm_banks 2
set ifm_fifo_depth 1024
set ifm_fifo_aw 10
set psum_fifo_depth 1024
set psum_fifo_aw 10
set hwc_cache_aw 16
set hwc_cache_depth 43264
set hwc_cache_stripes 4
set hwc_cache_use_uram 1
set tail_cycles 1
set run_name ""
set out_of_context 0

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-top"} {
        incr i
        set top [lindex $argv $i]
    } elseif {$arg eq "-part"} {
        incr i
        set part [lindex $argv $i]
    } elseif {$arg eq "-jobs"} {
        incr i
        set jobs [lindex $argv $i]
    } elseif {$arg eq "-rows"} {
        incr i
        set rows [lindex $argv $i]
    } elseif {$arg eq "-cols"} {
        incr i
        set cols [lindex $argv $i]
    } elseif {$arg eq "-k_tile"} {
        incr i
        set k_tile [lindex $argv $i]
    } elseif {$arg eq "-cout_tile"} {
        incr i
        set cout_tile [lindex $argv $i]
    } elseif {$arg eq "-ifm_banks"} {
        incr i
        set ifm_banks [lindex $argv $i]
    } elseif {$arg eq "-ifm_fifo_depth"} {
        incr i
        set ifm_fifo_depth [lindex $argv $i]
    } elseif {$arg eq "-ifm_fifo_aw"} {
        incr i
        set ifm_fifo_aw [lindex $argv $i]
    } elseif {$arg eq "-psum_fifo_depth"} {
        incr i
        set psum_fifo_depth [lindex $argv $i]
    } elseif {$arg eq "-psum_fifo_aw"} {
        incr i
        set psum_fifo_aw [lindex $argv $i]
    } elseif {$arg eq "-hwc_cache_aw"} {
        incr i
        set hwc_cache_aw [lindex $argv $i]
    } elseif {$arg eq "-hwc_cache_depth"} {
        incr i
        set hwc_cache_depth [lindex $argv $i]
    } elseif {$arg eq "-hwc_cache_stripes"} {
        incr i
        set hwc_cache_stripes [lindex $argv $i]
    } elseif {$arg eq "-hwc_cache_use_uram"} {
        incr i
        set hwc_cache_use_uram [lindex $argv $i]
    } elseif {$arg eq "-tail_cycles"} {
        incr i
        set tail_cycles [lindex $argv $i]
    } elseif {$arg eq "-name"} {
        incr i
        set run_name [lindex $argv $i]
    } elseif {$arg eq "-ooc"} {
        set out_of_context 1
    } else {
        error "unknown argument: $arg"
    }
}

set rtl_files {
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
    systolic/psum_output_collector.v
    systolic/psum_stream_feeder.v
    systolic/psum_column_pingpong_buffer.v
    systolic/psum_column_stream_feeder.v
    systolic/psum_column_output_collector.v
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

proc abs_files {root rels} {
    set out {}
    foreach rel $rels {
        lappend out [file normalize [file join $root $rel]]
    }
    return $out
}

if {$run_name eq ""} {
    set run_name "${top}_r${rows}_c${cols}"
}

if {(1 << $ifm_fifo_aw) != $ifm_fifo_depth} {
    error "IFM_FIFO_DEPTH must equal 2^IFM_FIFO_AW"
}
if {(1 << $psum_fifo_aw) != $psum_fifo_depth} {
    error "PSUM_FIFO_DEPTH must equal 2^PSUM_FIFO_AW"
}

puts "=== synth top=$top part=$part rows=$rows cols=$cols k_tile=$k_tile cout_tile=$cout_tile ifm_banks=$ifm_banks ifm_fifo_depth=$ifm_fifo_depth ifm_fifo_aw=$ifm_fifo_aw psum_fifo_depth=$psum_fifo_depth psum_fifo_aw=$psum_fifo_aw hwc_cache_aw=$hwc_cache_aw hwc_cache_depth=$hwc_cache_depth hwc_cache_stripes=$hwc_cache_stripes hwc_cache_use_uram=$hwc_cache_use_uram tail_cycles=$tail_cycles ooc=$out_of_context ==="
read_verilog -sv [abs_files $root $rtl_files]

if {$out_of_context} {
    synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt -directive default \
        -generic "ROWS=$rows" -generic "COLS=$cols" -generic "K_TILE=$k_tile" \
        -generic "COUT_TILE=$cout_tile" -generic "IFM_BANKS=$ifm_banks" \
        -generic "IFM_FIFO_DEPTH=$ifm_fifo_depth" -generic "IFM_FIFO_AW=$ifm_fifo_aw" \
        -generic "PSUM_FIFO_DEPTH=$psum_fifo_depth" -generic "PSUM_FIFO_AW=$psum_fifo_aw" \
        -generic "HWC_CACHE_AW=$hwc_cache_aw" -generic "HWC_CACHE_DEPTH=$hwc_cache_depth" \
        -generic "HWC_CACHE_STRIPES=$hwc_cache_stripes" \
        -generic "HWC_CACHE_USE_URAM=$hwc_cache_use_uram" \
        -generic "TAIL_CYCLES_CONFIG=$tail_cycles"
} else {
    synth_design -top $top -part $part -flatten_hierarchy rebuilt -directive default \
        -generic "ROWS=$rows" -generic "COLS=$cols" -generic "K_TILE=$k_tile" \
        -generic "COUT_TILE=$cout_tile" -generic "IFM_BANKS=$ifm_banks" \
        -generic "IFM_FIFO_DEPTH=$ifm_fifo_depth" -generic "IFM_FIFO_AW=$ifm_fifo_aw" \
        -generic "PSUM_FIFO_DEPTH=$psum_fifo_depth" -generic "PSUM_FIFO_AW=$psum_fifo_aw" \
        -generic "HWC_CACHE_AW=$hwc_cache_aw" -generic "HWC_CACHE_DEPTH=$hwc_cache_depth" \
        -generic "HWC_CACHE_STRIPES=$hwc_cache_stripes" \
        -generic "HWC_CACHE_USE_URAM=$hwc_cache_use_uram" \
        -generic "TAIL_CYCLES_CONFIG=$tail_cycles"
}

set report_prefix [file join $build_dir $run_name]
write_checkpoint -force "${report_prefix}_synth.dcp"
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file "${report_prefix}_utilization.rpt"
report_utilization -hierarchical -file "${report_prefix}_utilization_hier.rpt"
report_timing_summary -file "${report_prefix}_timing_summary.rpt"

puts "=== synthesis reports ==="
puts "${report_prefix}_utilization.rpt"
puts "${report_prefix}_utilization_hier.rpt"
puts "${report_prefix}_timing_summary.rpt"

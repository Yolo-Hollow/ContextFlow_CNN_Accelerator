set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
set build_dir [file join $root build_xsim]
file mkdir $build_dir

set top_filter {}
set waves 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-top"} {
        incr i
        set top_filter [split [lindex $argv $i] ","]
    } elseif {$arg eq "-waves"} {
        set waves 1
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
    systolic/weight_tile_loader.v
    systolic/psum_pingpong_buffer.v
    systolic/psum_stream_feeder.v
    systolic/psum_drain_writer.v
    systolic/ofm_requant_writer.v
    systolic/ofm_activation.v
    systolic/ofm_writeback.v
    systolic/conv_layer_top_stream.v
    systolic/layer_config_regs.v
    systolic/quant_param_regs.v
    systolic/conv_accel_core.v
    systolic/requant.v
    systolic/leaky_lut.v
    systolic/systolic_top.v
}

set tests {
    {tb_conv_accel_core_realistic_small tb/tb_conv_accel_core_realistic_small.v}
    {tb_layer_scheduler_cout64_fulltile tb/tb_layer_scheduler_cout64_fulltile.v}
    {tb_conv_accel_core_cout64_fulltile tb/tb_conv_accel_core_cout64_fulltile.v}
    {tb_conv_accel_core_cout128_blocks tb/tb_conv_accel_core_cout128_blocks.v}
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

foreach test $tests {
    set top [lindex $test 0]
    set tb_file [lindex $test 1]
    if {![selected $top $top_filter]} {
        continue
    }

    puts "=== xsim compile $top ==="
    set run_dir [file join $build_dir $top]
    file mkdir $run_dir
    set srcs [concat [abs_files $root $common_files] [abs_files $root [list $tb_file]]]

    set xvlog_log [file join $run_dir xvlog.log]
    set xelab_log [file join $run_dir xelab.log]
    set xsim_log  [file join $run_dir xsim.log]
    set snapshot "${top}_snap"

    cd $run_dir
    exec {*}$xvlog -sv -L work -i [file join $root tb] -log $xvlog_log {*}$srcs >@ stdout 2>@ stderr
    exec {*}$xelab -debug typical -top $top -snapshot $snapshot -log $xelab_log >@ stdout 2>@ stderr

    puts "=== xsim run $top ==="
    if {$waves} {
        set wdb [file join $run_dir "${top}.wdb"]
        exec {*}$xsim $snapshot -R -wdb $wdb -log $xsim_log >@ stdout 2>@ stderr
    } else {
        exec {*}$xsim $snapshot -R -log $xsim_log >@ stdout 2>@ stderr
    }
}

puts "=== selected xsim regressions passed ==="

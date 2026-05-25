set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
set build_dir [file join $root build_synth_xck26]

set run_name conv_accel_core_axi_lite_axis_stream_r32_c16
set clk_period 10.000
set clk_src ""

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-name"} {
        incr i
        set run_name [lindex $argv $i]
    } elseif {$arg eq "-clk_period"} {
        incr i
        set clk_period [lindex $argv $i]
    } elseif {$arg eq "-clk_src"} {
        incr i
        set clk_src [lindex $argv $i]
    } else {
        error "unknown argument: $arg"
    }
}

set report_prefix [file join $build_dir $run_name]
set dcp "${report_prefix}_synth.dcp"
if {![file exists $dcp]} {
    error "synth checkpoint not found: $dcp"
}

open_checkpoint $dcp
create_clock -name clk -period $clk_period [get_ports clk]
if {$clk_src ne ""} {
    set_property HD.CLK_SRC $clk_src [get_ports clk]
}
opt_design

write_checkpoint -force "${report_prefix}_opt.dcp"
report_utilization -file "${report_prefix}_opt_utilization.rpt"
report_utilization -hierarchical -file "${report_prefix}_opt_utilization_hier.rpt"
report_timing_summary -file "${report_prefix}_opt_timing_summary.rpt"

puts "=== opt reports generated ==="
puts "${report_prefix}_opt_utilization.rpt"
puts "${report_prefix}_opt_utilization_hier.rpt"
puts "${report_prefix}_opt_timing_summary.rpt"

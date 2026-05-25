set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
set build_dir [file join $root build_synth_xck26]

set top conv_accel_core_axi_lite_axis_stream
set run_name $top
set clk_period 10.000

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-top"} {
        incr i
        set top [lindex $argv $i]
        set run_name $top
    } elseif {$arg eq "-name"} {
        incr i
        set run_name [lindex $argv $i]
    } elseif {$arg eq "-clk_period"} {
        incr i
        set clk_period [lindex $argv $i]
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
report_utilization -file "${report_prefix}_utilization.rpt"
report_utilization -hierarchical -file "${report_prefix}_utilization_hier.rpt"
report_timing_summary -file "${report_prefix}_timing_summary.rpt"

puts "=== synthesis reports refreshed ==="
puts "${report_prefix}_utilization.rpt"
puts "${report_prefix}_utilization_hier.rpt"
puts "${report_prefix}_timing_summary.rpt"

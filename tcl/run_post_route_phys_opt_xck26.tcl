set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
set build_dir [file join $root build_synth_xck26]

set run_name conv_accel_core_axi_lite_axis_stream_r18_c8_b2_ooc
set directive Explore

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-name"} {
        incr i
        set run_name [lindex $argv $i]
    } elseif {$arg eq "-directive"} {
        incr i
        set directive [lindex $argv $i]
    } else {
        error "unknown argument: $arg"
    }
}

set report_prefix [file join $build_dir $run_name]
set dcp "${report_prefix}_routed.dcp"
if {![file exists $dcp]} {
    error "routed checkpoint not found: $dcp"
}

puts "=== post-route physical optimization input=$dcp directive=$directive ==="
open_checkpoint $dcp
phys_opt_design -directive $directive

write_checkpoint -force "${report_prefix}_post_route_phys_opt.dcp"
report_route_status -file "${report_prefix}_post_route_phys_opt_route_status.rpt"
report_utilization -file "${report_prefix}_post_route_phys_opt_utilization.rpt"
report_timing_summary -file "${report_prefix}_post_route_phys_opt_timing_summary.rpt"

puts "=== post-route physical optimization reports generated ==="
puts "${report_prefix}_post_route_phys_opt_route_status.rpt"
puts "${report_prefix}_post_route_phys_opt_utilization.rpt"
puts "${report_prefix}_post_route_phys_opt_timing_summary.rpt"

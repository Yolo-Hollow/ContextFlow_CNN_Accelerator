set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
set build_dir [file join $root build_synth_xck26]

set run_name conv_accel_core_axi_lite_axis_stream_r18_c8_b2
set clk_period 10.000
set clk_src ""
set directive Explore
set post_route_phys_opt 1

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
    } elseif {$arg eq "-directive"} {
        incr i
        set directive [lindex $argv $i]
    } elseif {$arg eq "-no_post_route_phys_opt"} {
        set post_route_phys_opt 0
    } else {
        error "unknown argument: $arg"
    }
}

set report_prefix [file join $build_dir $run_name]
set dcp "${report_prefix}_opt.dcp"
if {![file exists $dcp]} {
    error "opt checkpoint not found: $dcp"
}

puts "=== implementation input=$dcp clock_period=$clk_period directive=$directive ==="
open_checkpoint $dcp
if {[llength [get_clocks -quiet clk]] == 0} {
    create_clock -name clk -period $clk_period [get_ports clk]
}
if {$clk_src ne ""} {
    set_property HD.CLK_SRC $clk_src [get_ports clk]
}

place_design -directive $directive
phys_opt_design -directive $directive
write_checkpoint -force "${report_prefix}_placed.dcp"
report_utilization -file "${report_prefix}_placed_utilization.rpt"
report_timing_summary -file "${report_prefix}_placed_timing_summary.rpt"

route_design -directive $directive
write_checkpoint -force "${report_prefix}_routed.dcp"
report_route_status -file "${report_prefix}_routed_route_status.rpt"
report_utilization -file "${report_prefix}_routed_utilization.rpt"
report_timing_summary -file "${report_prefix}_routed_timing_summary.rpt"

if {$post_route_phys_opt} {
    # On a routed checkpoint phys_opt_design applies post-route optimizations.
    phys_opt_design -directive $directive
    write_checkpoint -force "${report_prefix}_post_route_phys_opt.dcp"
    report_route_status -file "${report_prefix}_post_route_phys_opt_route_status.rpt"
    report_utilization -file "${report_prefix}_post_route_phys_opt_utilization.rpt"
    report_timing_summary -file "${report_prefix}_post_route_phys_opt_timing_summary.rpt"
}

puts "=== implementation reports generated ==="
puts "${report_prefix}_placed_timing_summary.rpt"
puts "${report_prefix}_routed_timing_summary.rpt"
if {$post_route_phys_opt} {
    puts "${report_prefix}_post_route_phys_opt_timing_summary.rpt"
}

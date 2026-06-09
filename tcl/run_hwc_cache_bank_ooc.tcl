set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
set build_dir [file join $root build_synth_xck26]
file mkdir $build_dir

set part xck26-sfvc784-2LV-c
set cache_aw 14
set cache_depth 13312
set cache_stripes 4
set use_uram 1
set run_name hwc_cache_bank_packed72_stripe4_d13312

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-part"} {
        incr i
        set part [lindex $argv $i]
    } elseif {$arg eq "-cache_aw"} {
        incr i
        set cache_aw [lindex $argv $i]
    } elseif {$arg eq "-cache_depth"} {
        incr i
        set cache_depth [lindex $argv $i]
    } elseif {$arg eq "-cache_stripes"} {
        incr i
        set cache_stripes [lindex $argv $i]
    } elseif {$arg eq "-use_uram"} {
        incr i
        set use_uram [lindex $argv $i]
    } elseif {$arg eq "-name"} {
        incr i
        set run_name [lindex $argv $i]
    } else {
        error "unknown argument: $arg"
    }
}

read_verilog -sv [file join $root systolic axis_hwc_tile_cache.v]
synth_design -top axis_hwc_tile_cache_bank -part $part -mode out_of_context \
    -generic "CACHE_AW=$cache_aw" \
    -generic "CACHE_DEPTH=$cache_depth" \
    -generic "CACHE_STRIPES=$cache_stripes" \
    -generic "USE_URAM=$use_uram"

create_clock -name clk -period 10.000 [get_ports clk]
set report_prefix [file join $build_dir $run_name]
write_checkpoint -force "${report_prefix}_synth.dcp"
report_utilization -file "${report_prefix}_utilization.rpt"
report_utilization -hierarchical -file "${report_prefix}_utilization_hier.rpt"
report_timing_summary -file "${report_prefix}_timing_summary.rpt"

puts "=== HWC cache bank OOC complete ==="
puts "${report_prefix}_utilization.rpt"
puts "${report_prefix}_timing_summary.rpt"

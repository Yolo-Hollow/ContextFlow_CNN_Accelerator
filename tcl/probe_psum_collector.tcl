set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]

set enable_tag_check 1
if {[llength $argv] == 1} {
    set enable_tag_check [lindex $argv 0]
} elseif {[llength $argv] != 0} {
    error "usage: probe_psum_collector.tcl ?enable_tag_check?"
}
if {$enable_tag_check != 0 && $enable_tag_check != 1} {
    error "enable_tag_check must be 0 or 1"
}

set build_dir [file join $root build_synth_xck26 collector_probe]
file mkdir $build_dir
read_verilog -sv [file join $root systolic psum_output_collector.v]
synth_design -top psum_output_collector -part xck26-sfvc784-2LV-c \
    -mode out_of_context -flatten_hierarchy rebuilt -directive default \
    -generic COLS=16 -generic PSUM_W=32 -generic ADDR_W=10 \
    -generic CTX_DEPTH=4 -generic CTX_AW=2 -generic EPOCH_W=8 \
    -generic CONTEXT_W=16 -generic TAG_W=10 \
    -generic ENABLE_TAG_CHECK=$enable_tag_check
create_clock -name clk -period 10.000 [get_ports clk]
set prefix [file join $build_dir "tag${enable_tag_check}"]
report_utilization -file "${prefix}_utilization.rpt"
report_timing_summary -file "${prefix}_timing_summary.rpt"
puts "PASS: collector probe tag_check=$enable_tag_check prefix=$prefix"

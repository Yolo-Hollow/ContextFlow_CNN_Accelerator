# Focused 200 MHz post-place resource/timing gate for the two-bank packed OFM
# HWC reorder buffer.  This intentionally uses the same geometry and memory
# mapping as the release system instance:
#
#   vivado -mode batch \
#       -source tcl/run_ofm_hwc_axis_pingpong_ooc_xck26.tcl
#
# Optional overrides are limited to the target part, clock period, and scratch
# build directory.  Signoff limits remain fixed in this script.

set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
source [file join $script_dir build_common.tcl]

set part xck26-sfvc784-2LV-c
set period_ns 5.000
set build_dir [file join $root build_ooc_ofm_hwc_axis_pingpong_xck26]
for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg in {-part -period_ns -build_dir}} {
        if {$i + 1 >= [llength $argv]} {
            error "$arg requires a value"
        }
        incr i
        set value [lindex $argv $i]
        if {$arg eq "-part"} {
            set part $value
        } elseif {$arg eq "-period_ns"} {
            set period_ns $value
        } else {
            set build_dir $value
        }
    } else {
        error "unknown argument: $arg"
    }
}
if {![string is double -strict $period_ns] || $period_ns <= 0.0} {
    error "-period_ns must be a positive number; got '$period_ns'"
}

::conv_accel_build::require_vivado_version 2022.2
set build_dir [::conv_accel_build::require_nonpublication_build_dir \
    $root $build_dir]
file mkdir $build_dir

set prefix [file join $build_dir ofm_hwc_axis_pingpong]
set util_path "${prefix}_utilization.rpt"
set hier_path "${prefix}_utilization_hier.rpt"
set timing_path "${prefix}_timing_summary.rpt"
set paths_path "${prefix}_timing_top100.rpt"
set congestion_path "${prefix}_congestion.rpt"
set internal_none_path "${prefix}_internal_none_fdre_audit.rpt"
set gate_path "${prefix}_gate.txt"
set dcp_path "${prefix}_placed.dcp"
set clock_xdc_path "${prefix}_clock.xdc"

::conv_accel_build::remove_stale_publications $build_dir [list \
    $util_path $hier_path $timing_path $paths_path $congestion_path \
    $internal_none_path $gate_path $dcp_path $clock_xdc_path]

create_project -in_memory -part $part
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]
read_verilog -sv [list \
    [file join $root systolic ofm_hwc_axis_packer.v] \
    [file join $root systolic ofm_hwc_axis_pingpong.v]]

# Make the 5 ns clock visible to synthesis mapping and retiming, not only to
# post-synthesis timing analysis.  This mirrors the canonical full-core OOC
# flow and avoids a misleading frequency-blind focused result.
set clock_xdc [open $clock_xdc_path w]
puts $clock_xdc [format \
    {create_clock -name clk -period %.6f [get_ports {clk}]} $period_ns]
close $clock_xdc
read_xdc -mode out_of_context $clock_xdc_path

synth_design -top ofm_hwc_axis_pingpong -part $part \
    -mode out_of_context -flatten_hierarchy rebuilt -directive default \
    -generic "COUT_TILE=32" \
    -generic "MAX_PIXELS=1024" \
    -generic "MAX_COUT=1024" \
    -generic "BUFFER_DEPTH=4096" \
    -generic "RAM_STYLE=ultra" \
    -generic "PIXEL_INDEX_W=10" \
    -generic "PIXEL_COUNT_W=11" \
    -generic "COUT_W=11"

set constrained_clocks [get_clocks -quiet -of_objects [get_ports clk]]
if {[llength $constrained_clocks] != 1} {
    error "focused OOC clock contract resolved [llength $constrained_clocks] clocks on clk, expected 1"
}
set constrained_period [get_property PERIOD [lindex $constrained_clocks 0]]
if {abs(double($constrained_period) - double($period_ns)) > 0.000001} {
    error "focused OOC clock period=$constrained_period does not match requested $period_ns ns"
}

opt_design
place_design

report_utilization -file $util_path
report_utilization -hierarchical -hierarchical_depth 4 -file $hier_path
report_timing_summary -report_unconstrained -file $timing_path
report_timing -delay_type max -max_paths 100 -nworst 1 \
    -sort_by group -path_type full_clock_expanded -file $paths_path
report_design_analysis -congestion -min_congestion_level 3 \
    -file $congestion_path

# This full-design audit catches internal register launches with no clock even
# when Vivado's ordinary no_clock check is masked by another timed fan-in.
::conv_accel_build::write_ooc_internal_none_fdre_audit \
    $internal_none_path 50

set metrics [::conv_accel_build::metrics_from_reports \
    $util_path $timing_path "" $congestion_path "" $internal_none_path]
set util_text [::conv_accel_build::read_text $util_path]
if {[regexp -line -- \
        {^\|\s*CLB Registers\*?\s*\|\s*([0-9.]+)\s*\|} \
        $util_text -> ff_count]} {
    dict set metrics ff $ff_count
}

set limits [dict create \
    max_lut 3800 \
    max_lut_memory 512 \
    max_ff 1300 \
    max_bram 0 \
    expected_uram 8 \
    max_dsp 5 \
    min_wns 0.0 \
    min_tns 0.0 \
    min_whs 0.0 \
    min_ths 0.0 \
    max_failing_endpoints 0 \
    max_hold_failing_endpoints 0 \
    max_pulse_width_failing_endpoints 0 \
    max_unconstrained_paths 0 \
    max_unclocked_fdre 0 \
    max_ooc_internal_none_fdre_endpoints 0 \
    max_congestion_level 4]

set violations [::conv_accel_build::metric_violations $metrics $limits]
# build_common's generic gate currently has no FF mapping, so keep this one
# focused resource limit explicit while recording it in the same gate report.
if {![dict exists $metrics ff]} {
    lappend violations "missing metric 'ff'"
} elseif {[expr {double([dict get $metrics ff]) >
                  double([dict get $limits max_ff])}]} {
    lappend violations \
        "ff=[dict get $metrics ff] exceeds max_ff=[dict get $limits max_ff]"
}

::conv_accel_build::write_gate_report $gate_path \
    ofm_hwc_axis_pingpong_post_place $metrics $limits $violations

# Preserve the placed design even when a signoff metric fails so the failing
# path remains inspectable.  The gate report, not DCP existence, is the
# authoritative PASS/FAIL result.
write_checkpoint -force $dcp_path
puts "=== OFM HWC ping-pong metrics: $metrics ==="
if {[llength $violations] != 0} {
    error "OFM HWC ping-pong gate failed: [join $violations {; }] (see $gate_path)"
}
puts "PASS: OFM HWC ping-pong post-place gate"

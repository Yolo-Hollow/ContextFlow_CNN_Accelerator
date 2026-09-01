# Focused 200 MHz post-place resource/timing gate for the release tile
# ping-pong materialized-window cache (two 32768-entry banks).  Optional
# overrides are limited to the target part, clock period, and scratch build
# directory; signoff limits remain fixed here.

set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
source [file join $script_dir build_common.tcl]

set part xck26-sfvc784-2LV-c
set period_ns 5.000
set build_dir [file join $root build_materialized_cache_xck26]
set check_only 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg in {-part -period_ns -build_dir}} {
        if {$i + 1 >= [llength $argv] ||
            [string match "-*" [lindex $argv [expr {$i + 1}]]]} {
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
    } elseif {$arg eq "-check_only"} {
        set check_only 1
    } else {
        error "unknown argument: $arg"
    }
}
if {![::conv_accel_build::finite_number $period_ns] || $period_ns <= 0.0} {
    error "-period_ns must be a positive finite number; got '$period_ns'"
}
if {[string trim $part] eq ""} {
    error "-part must not be empty"
}

set build_dir [::conv_accel_build::require_nonpublication_build_dir \
    $root $build_dir]
if {$check_only} {
    puts "PASS: materialized cache focused OOC configuration part=$part period_ns=[format %.6f $period_ns] build_dir=$build_dir"
    return
}

::conv_accel_build::require_vivado_version 2022.2
file mkdir $build_dir
set prefix [file join $build_dir materialized_cache]
set util_path "${prefix}_utilization.rpt"
set hier_path "${prefix}_utilization_hier.rpt"
set timing_path "${prefix}_timing_summary.rpt"
set paths_path "${prefix}_timing_top100.rpt"
set legacy_paths_path "${prefix}_timing_paths.rpt"
set congestion_path "${prefix}_congestion.rpt"
set internal_none_path "${prefix}_internal_none_fdre_audit.rpt"
set gate_path "${prefix}_gate.txt"
set dcp_path "${prefix}_placed.dcp"
set clock_xdc_path "${prefix}_clock.xdc"

::conv_accel_build::remove_stale_publications $build_dir [list \
    $util_path $hier_path $timing_path $paths_path $legacy_paths_path \
    $congestion_path $internal_none_path $gate_path $dcp_path \
    $clock_xdc_path]

create_project -in_memory -part $part
read_verilog -sv [file join $root systolic \
    hwc_materialized_tile_pingpong_cache.v]

# Make the requested period visible to synthesis mapping and retiming.  A
# post-synthesis create_clock would produce a frequency-blind focused result.
set clock_xdc [open $clock_xdc_path w]
puts $clock_xdc [format \
    {create_clock -name clk -period %.6f [get_ports {clk}]} $period_ns]
close $clock_xdc
read_xdc -mode out_of_context $clock_xdc_path

synth_design -top hwc_materialized_tile_pingpong_cache -part $part \
    -mode out_of_context -flatten_hierarchy rebuilt -directive default \
    -generic "BANK_AW=15" -generic "BANK_DEPTH=32768" \
    -generic "CFG_PREVALIDATED=1" \
    -generic "ENABLE_PASS_READY_BITMAP=0"

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

# Catch full-design internal register launches with no source clock even when
# another timed fan-in masks them in Vivado's ordinary no_clock summary.
::conv_accel_build::write_ooc_internal_none_fdre_audit \
    $internal_none_path 50

set metrics [::conv_accel_build::metrics_from_reports \
    $util_path $timing_path "" $congestion_path "" $internal_none_path]
set util_text [::conv_accel_build::read_text $util_path]
set ff_metric_missing 1
if {[regexp -line -- \
        {^\|\s*CLB Registers\*?\s*\|\s*([0-9.]+)\s*\|} \
        $util_text -> ff_count]} {
    # FF is intentionally informational: the design has ample register
    # headroom, while the focused LUT/memory/DSP limits remain fixed.
    dict set metrics ff $ff_count
    set ff_metric_missing 0
}

set limits [dict create \
    max_lut 1800 \
    max_bram 0 \
    expected_uram 32 \
    max_dsp 4 \
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
if {$ff_metric_missing} {
    lappend violations "missing informational metric 'ff'"
}
::conv_accel_build::write_gate_report $gate_path \
    materialized_cache_post_place $metrics $limits $violations

# Retain a failed placed design for diagnosis.  The gate report, rather than
# checkpoint existence, is the authoritative PASS/FAIL result.
write_checkpoint -force $dcp_path
puts "=== materialized cache metrics: $metrics ==="
if {[llength $violations] != 0} {
    error "materialized cache gate failed: [join $violations {; }] (see $gate_path)"
}
puts "PASS: materialized cache post-place resource gate"

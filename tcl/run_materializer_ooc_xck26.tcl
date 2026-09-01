# Focused post-place resource/timing gate for the packed four-row HWC
# materializer.  Run once for each line-store primitive:
#
#   vivado -mode batch -source tcl/run_materializer_ooc_xck26.tcl \
#       -tclargs -variant uram
#   vivado -mode batch -source tcl/run_materializer_ooc_xck26.tcl \
#       -tclargs -variant bram

set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
source [file join $script_dir build_common.tcl]

set variant uram
set part xck26-sfvc784-2LV-c
set period_ns 10.000
for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-variant"} {
        incr i
        set variant [string tolower [lindex $argv $i]]
    } elseif {$arg eq "-part"} {
        incr i
        set part [lindex $argv $i]
    } elseif {$arg eq "-period_ns"} {
        incr i
        set period_ns [lindex $argv $i]
    } else {
        error "unknown argument: $arg"
    }
}
if {$variant ni {uram bram}} {
    error "-variant must be uram or bram"
}

::conv_accel_build::require_vivado_version 2022.2
set use_uram [expr {$variant eq "uram" ? 1 : 0}]
set build_dir [file join $root build_materializer_xck26 $variant]
file mkdir $build_dir
set prefix [file join $build_dir "materializer_${variant}"]
set util_path "${prefix}_utilization.rpt"
set hier_path "${prefix}_utilization_hier.rpt"
set timing_path "${prefix}_timing_summary.rpt"
set paths_path "${prefix}_timing_paths.rpt"
set gate_path "${prefix}_gate.txt"
set dcp_path "${prefix}_placed.dcp"

::conv_accel_build::remove_stale_publications $build_dir [list \
    $util_path $hier_path $timing_path $paths_path $gate_path $dcp_path]

create_project -in_memory -part $part
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]
read_verilog -sv [list \
    [file join $root systolic axis_hwc_window_row_store.v] \
    [file join $root systolic axis_hwc_window_materializer_byte_bram.v]]
synth_design -top axis_hwc_window_materializer_byte_bram -part $part \
    -mode out_of_context -flatten_hierarchy rebuilt -directive default \
    -generic "LINE_STORE_USE_URAM=$use_uram" \
    -generic "CFG_PREVALIDATED=1" \
    -generic "ENABLE_PASS_READY_BITMAP=0"
create_clock -name clk -period $period_ns [get_ports clk]
opt_design
place_design
report_utilization -file $util_path
report_utilization -hierarchical -hierarchical_depth 4 -file $hier_path
report_timing_summary -file $timing_path
report_timing -delay_type max -max_paths 50 -nworst 1 \
    -path_type full_clock_expanded -file $paths_path

set metrics [::conv_accel_build::metrics_from_reports $util_path $timing_path]
set util_text [::conv_accel_build::read_text $util_path]
if {[regexp -line -- \
        {^\|\s*CLB Registers\*?\s*\|\s*([0-9.]+)\s*\|} \
        $util_text -> ff_count]} {
    dict set metrics ff $ff_count
}

set violations {}
foreach key {lut bram uram dsp wns tns ff} {
    if {![dict exists $metrics $key]} {
        lappend violations "missing metric '$key'"
    }
}
if {[llength $violations] == 0} {
    if {$variant eq "uram"} {
        foreach {key expected} {uram 4 bram 0 dsp 0} {
            if {[expr {double([dict get $metrics $key]) != $expected}]} {
                lappend violations "$key=[dict get $metrics $key] expected=$expected"
            }
        }
        foreach {key limit} {lut 7500 ff 3400} {
            if {[expr {double([dict get $metrics $key]) > $limit}]} {
                lappend violations "$key=[dict get $metrics $key] exceeds $limit"
            }
        }
    } else {
        foreach {key expected} {bram 16 uram 0 dsp 0} {
            if {[expr {double([dict get $metrics $key]) != $expected}]} {
                lappend violations "$key=[dict get $metrics $key] expected=$expected"
            }
        }
        if {[expr {double([dict get $metrics lut]) > 9000}]} {
            lappend violations "lut=[dict get $metrics lut] exceeds 9000"
        }
    }
    if {[expr {double([dict get $metrics wns]) < 0.0}]} {
        lappend violations "wns=[dict get $metrics wns] is below 0.0"
    }
    if {[expr {double([dict get $metrics tns]) < 0.0}]} {
        lappend violations "tns=[dict get $metrics tns] is below 0.0"
    }
}

set limits [dict create variant $variant exact_line_uram \
    [expr {$variant eq "uram" ? 4 : 0}] exact_line_bram \
    [expr {$variant eq "bram" ? 16 : 0}] max_lut \
    [expr {$variant eq "uram" ? 7500 : 9000}] exact_dsp 0 \
    min_wns 0.0 min_tns 0.0]
if {$variant eq "uram"} {
    dict set limits max_ff 3400
}
::conv_accel_build::write_gate_report $gate_path \
    "materializer_${variant}_post_place" $metrics $limits $violations

# Always retain the failed design for diagnosis.  The gate report remains the
# authoritative selection signal and the process exits non-zero on failure.
write_checkpoint -force $dcp_path
puts "=== materializer $variant metrics: $metrics ==="
if {[llength $violations] != 0} {
    error "materializer $variant gate failed: [join $violations {; }] (see $gate_path)"
}
puts "PASS: materializer $variant post-place gate"

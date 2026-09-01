# Run the real RTL ABI-v2 ten-layer chain in one XSIM snapshot.

set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
source [file join $script_dir rtl_sources.tcl]
source [file join $script_dir build_common.tcl]

set start_layer 0
set stop_layer 9
set stream_cfg 0xbf
set waves 0
set trace_pixel0 0
set check_only 0
set fast_dsp 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-start_layer"} {
        incr i
        set start_layer [lindex $argv $i]
    } elseif {$arg eq "-stop_layer"} {
        incr i
        set stop_layer [lindex $argv $i]
    } elseif {$arg eq "-stream_cfg"} {
        incr i
        set stream_cfg [expr {[lindex $argv $i]}]
    } elseif {$arg eq "-waves"} {
        set waves 1
    } elseif {$arg eq "-trace_pixel0"} {
        set trace_pixel0 1
    } elseif {$arg eq "-check_only"} {
        set check_only 1
    } elseif {$arg eq "-fast_dsp"} {
        set fast_dsp 1
    } else {
        error "unknown argument: $arg"
    }
}
if {$start_layer < 0 || $stop_layer > 9 || $start_layer > $stop_layer} {
    error "invalid layer range $start_layer..$stop_layer"
}
if {$stream_cfg < 0 || $stream_cfg > 255 || ($stream_cfg & 0x40) != 0} {
    error [format "invalid STREAM_CFG=0x%02x (column bit6 must remain zero)" $stream_cfg]
}

::conv_accel_sources::validate $root
::conv_accel_build::require_vivado_version 2022.2
set provenance [::conv_accel_build::git_provenance $root]
set common_files [::conv_accel_sources::relative_files]
set fast_sim_file [file join $root tb systolic_scalar_lane_dsp48e2_fast_sim.v]
set tb_file [file join $root tb tb_abi_v2_release_ten_layer_chain.v]
if {$fast_dsp && ![file isfile $fast_sim_file]} {
    error "fast DSP simulation helper is missing: $fast_sim_file"
}
if {![file isfile $tb_file]} {
    error "ABI-v2 chain testbench is missing: $tb_file"
}
set fixture_root [file normalize [file join $root build_xsim fixtures]]
::conv_accel_build::require_xsim_fixtures $root
if {$check_only} {
    puts "PASS: ABI-v2 chain manifest, release sources, fixtures and layer range are valid"
    exit 0
}

set run_id "[clock format [clock seconds] -format {%Y%m%d_%H%M%S}]_[pid]"
set run_dir [file join $root build_xsim abi_v2_chain_runs $run_id]
file mkdir $run_dir
set xvlog_log [file join $run_dir xvlog.log]
set xelab_log [file join $run_dir xelab.log]
set xsim_log [file join $run_dir xsim.log]
set run_config [file join $run_dir abi_v2_chain_run_config.vh]
set result_stem [format "abi_v2_chain_l%d_l%d_cfg%02x_%s" \
    $start_layer $stop_layer $stream_cfg $run_id]
set result_json [file join $run_dir "${result_stem}.json"]
set result_junit [file join $run_dir "${result_stem}.junit.xml"]
set canonical_result_json [file join $root build_xsim abi_v2_chain_results.json]
set canonical_result_junit [file join $root build_xsim abi_v2_chain_results.junit.xml]
set canonical_shape_candidate [expr {
    $start_layer == 0 && $stop_layer == 9 && $stream_cfg == 0xbf &&
    !$waves && !$trace_pixel0 && !$fast_dsp
}]
set provenance_stable 1
set snapshot abi_v2_release_ten_layer_chain_snap
set top tb_abi_v2_release_ten_layer_chain
set start_ms [clock milliseconds]

# Vivado 2022.2's Windows xsim launcher splits -testplusarg values at '='.
# Generate a compile-time include instead so paths and layer bounds survive
# batch-file argument parsing unchanged.
set fixture_root_sv [string map {\\ / \" \\\"} $fixture_root]
set fh [open $run_config w]
puts $fh "`ifndef ABI_V2_CHAIN_RUN_CONFIG_VH"
puts $fh "`define ABI_V2_CHAIN_RUN_CONFIG_VH"
puts $fh "`define TB_ABI_V2_FIXTURE_ROOT \"$fixture_root_sv\""
puts $fh "`define TB_ABI_V2_START_LAYER $start_layer"
puts $fh "`define TB_ABI_V2_STOP_LAYER $stop_layer"
puts $fh [format "`define TB_ABI_V2_STREAM_CFG 8'h%02x" $stream_cfg]
puts $fh "`define TB_ABI_V2_TRACE_PIXEL0 $trace_pixel0"
puts $fh "`endif"
close $fh

proc abs_sources {root rels} {
    set result {}
    foreach rel $rels {
        lappend result [file normalize [file join $root $rel]]
    }
    return $result
}

proc json_escape {value} {
    return [string map [list \\ \\\\ \" \\" \n \\n \r \\r \t \\t] $value]
}

proc xml_escape {value} {
    return [string map [list & &amp\; < &lt\; > &gt\; \" &quot\; ' &apos\;] $value]
}

proc atomic_publish {source target} {
    if {![file isfile $source]} {
        error "cannot publish missing result: $source"
    }
    file mkdir [file dirname $target]
    set temporary "${target}.tmp.[pid]"
    if {[file exists $temporary]} {
        file delete -force -- $temporary
    }
    file copy -force -- $source $temporary
    file rename -force -- $temporary $target
}

set old_dir [pwd]
cd $run_dir
set sources [abs_sources $root $common_files]
if {$fast_dsp} {
    lappend sources $fast_sim_file
}
lappend sources $tb_file
set xelab_debug [expr {$waves ? "typical" : "off"}]
set xelab_optimization O2
set xvlog [auto_execok xvlog]
set xelab [auto_execok xelab]
set xsim [auto_execok xsim]
if {$xvlog eq "" || $xelab eq "" || $xsim eq ""} {
    error "xvlog/xelab/xsim not found in PATH"
}
if {[info exists ::env(XILINX_VIVADO)] &&
    [string trim $::env(XILINX_VIVADO)] ne ""} {
    set vivado_install_root [file normalize $::env(XILINX_VIVADO)]
} else {
    set vivado_install_root [file dirname [file dirname \
        [file normalize [lindex $xvlog 0]]]]
}
set glbl_file [file normalize [file join $vivado_install_root \
    data verilog src glbl.v]]
if {![file isfile $glbl_file]} {
    error "Vivado global simulation source is missing: $glbl_file"
}
lappend sources $glbl_file

puts [format "=== ABI-v2 chain compile (layers %d..%d, STREAM_CFG=0x%02x) ===" \
    $start_layer $stop_layer $stream_cfg]
set xvlog_args [list -sv -L work]
if {$fast_dsp} {
    lappend xvlog_args -d CONV_ACCEL_FAST_XSIM_DSP
}
if {[catch {
    exec {*}$xvlog {*}$xvlog_args -i $run_dir -i $root -i [file join $root tb] \
        -log $xvlog_log {*}$sources >@ stdout 2>@ stderr
} message]} {
    cd $old_dir
    error "xvlog failed: $message; log=$xvlog_log"
}
if {[catch {
    exec {*}$xelab --$xelab_optimization -debug $xelab_debug \
        -L xpm -L unisims_ver -top $top -top glbl -snapshot $snapshot \
        -log $xelab_log >@ stdout 2>@ stderr
} message]} {
    cd $old_dir
    error "xelab failed: $message; log=$xelab_log"
}
if {[catch {::conv_accel_build::git_provenance $root} provenance_after_elab]} {
    set provenance_stable 0
} elseif {![::conv_accel_build::git_provenance_matches \
        $provenance $provenance_after_elab]} {
    set provenance_stable 0
}

puts "=== ABI-v2 chain XSIM run (layers $start_layer..$stop_layer) ==="
set xsim_args [list $snapshot -R -onerror quit -onfinish quit -log $xsim_log]
if {$waves} {
    lappend xsim_args -wdb [file join $run_dir ${top}.wdb]
}
set tool_failed 0
set tool_message ""
if {[catch {exec {*}$xsim {*}$xsim_args >@ stdout 2>@ stderr} tool_message]} {
    set tool_failed 1
}
cd $old_dir

set end_provenance [dict create git_root unknown git_sha unknown git_dirty 1]
if {[catch {::conv_accel_build::git_provenance $root} detected_provenance] == 0} {
    set end_provenance $detected_provenance
}
if {![::conv_accel_build::git_provenance_matches \
        $provenance $end_provenance]} {
    set provenance_stable 0
}
set canonical_candidate [expr {
    $canonical_shape_candidate &&
    [::conv_accel_build::git_provenance_is_clean $provenance] &&
    $provenance_stable
}]

set log_text ""
if {[file isfile $xsim_log]} {
    set fh [open $xsim_log r]
    set log_text [read $fh]
    close $fh
}
set pass_count [regexp -all -line {^\[PASS\] tb_abi_v2_release_ten_layer_chain} $log_text]
set fail_count [regexp -all -line {^\[FAIL\]} $log_text]
set passed [expr {!$tool_failed && $pass_count == 1 && $fail_count == 0}]
set elapsed [expr {([clock milliseconds] - $start_ms) / 1000.0}]

set total_line ""
regexp -line {^\[CHAIN_TOTAL\].*$} $log_text total_line
set metrics [dict create]
foreach key {start stop busy feeder context_psum_gap drain_ofm bias_weight unclassified contexts compute_fire ifm_bytes ofm_bytes ofm_beats bias_packets weight_packets bias_bytes weight_bytes} {
    if {[regexp "${key}=([0-9]+)" $total_line -> value]} {
        dict set metrics $key $value
    }
}

# A partial layer run is useful diagnostic evidence, but it must never become
# the canonical ten-layer release result.  Recheck the complete metric
# contract here as well as in the testbench so a truncated/malformed log cannot
# be published merely because it contains a PASS line.
set canonical_metric_violations {}
if {$canonical_candidate} {
    set exact_metrics [dict create \
        start 0 stop 9 contexts 29253 compute_fire 3889197 \
        ifm_bytes 2249728 ofm_bytes 1734616 ofm_beats 216827 \
        bias_packets 483 weight_packets 29253 \
        bias_bytes 61824 weight_bytes 16849728]
    foreach key [dict keys $exact_metrics] {
        if {![dict exists $metrics $key]} {
            lappend canonical_metric_violations "missing $key"
        } elseif {[dict get $metrics $key] != [dict get $exact_metrics $key]} {
            lappend canonical_metric_violations \
                "$key=[dict get $metrics $key] expected=[dict get $exact_metrics $key]"
        }
    }
    set maximum_metrics [dict create \
        busy 7000000 feeder 2000000 context_psum_gap 300000 \
        drain_ofm 600000 bias_weight 200000 unclassified 10000]
    foreach key [dict keys $maximum_metrics] {
        if {![dict exists $metrics $key]} {
            lappend canonical_metric_violations "missing $key"
        } elseif {[dict get $metrics $key] > [dict get $maximum_metrics $key]} {
            lappend canonical_metric_violations \
                "$key=[dict get $metrics $key] exceeds [dict get $maximum_metrics $key]"
        }
    }
    if {[llength $canonical_metric_violations] != 0} {
        set passed 0
        set tool_message "canonical metric gate failed: [join $canonical_metric_violations {; }]"
    }
}
set canonical_publish [expr {$canonical_candidate && $passed}]
set canonical_metric_gate [expr {
    !$canonical_candidate ? "NOT_APPLICABLE" :
    ([llength $canonical_metric_violations] == 0 ? "PASS" : "FAIL")
}]

file mkdir [file dirname $result_json]
set fh [open $result_json w]
puts $fh "\{"
puts $fh "  \"schema_version\": 1,"
puts $fh "  \"status\": \"[expr {$passed ? {PASS} : {FAIL}}]\","
puts $fh "  \"git_root\": \"[json_escape [dict get $provenance git_root]]\","
puts $fh "  \"git_sha\": \"[json_escape [dict get $provenance git_sha]]\","
puts $fh "  \"git_dirty\": [expr {[dict get $provenance git_dirty] ? {true} : {false}}],"
puts $fh "  \"git_root_end\": \"[json_escape [dict get $end_provenance git_root]]\","
puts $fh "  \"git_sha_end\": \"[json_escape [dict get $end_provenance git_sha]]\","
puts $fh "  \"git_dirty_end\": [expr {[dict get $end_provenance git_dirty] ? {true} : {false}}],"
puts $fh "  \"provenance_stable\": [expr {$provenance_stable ? {true} : {false}}],"
puts $fh "  \"vivado_version\": \"[json_escape [version -short]]\","
puts $fh "  \"xelab_optimization\": \"$xelab_optimization\","
puts $fh "  \"fast_dsp_model\": [expr {$fast_dsp ? {true} : {false}}],"
puts $fh "  \"canonical_candidate\": [expr {$canonical_candidate ? {true} : {false}}],"
puts $fh "  \"canonical_metric_gate\": \"$canonical_metric_gate\","
puts $fh "  \"elapsed_seconds\": [format %.3f $elapsed],"
puts $fh "  \"layer_range\": \"$start_layer..$stop_layer\","
puts $fh [format "  \"stream_cfg\": \"0x%02x\"," $stream_cfg]
puts $fh "  \"run_dir\": \"[json_escape [file normalize $run_dir]]\","
puts $fh "  \"xsim_log\": \"[json_escape [file normalize $xsim_log]]\","
puts $fh "  \"metrics\": \{"
set metric_index 0
foreach key [dict keys $metrics] {
    if {$metric_index != 0} { puts $fh "," }
    puts -nonewline $fh "    \"$key\": [dict get $metrics $key]"
    incr metric_index
}
puts $fh ""
puts $fh "  \}"
puts $fh "\}"
close $fh

set fh [open $result_junit w]
puts $fh "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
puts $fh "<testsuite name=\"abi-v2-release-chain\" tests=\"1\" failures=\"[expr {$passed ? 0 : 1}]\" time=\"[format %.3f $elapsed]\">"
puts $fh "  <properties>"
puts $fh "    <property name=\"git.root\" value=\"[xml_escape [dict get $provenance git_root]]\"/>"
puts $fh "    <property name=\"git.sha\" value=\"[xml_escape [dict get $provenance git_sha]]\"/>"
puts $fh "    <property name=\"git.dirty\" value=\"[dict get $provenance git_dirty]\"/>"
puts $fh "    <property name=\"git.root_end\" value=\"[xml_escape [dict get $end_provenance git_root]]\"/>"
puts $fh "    <property name=\"git.sha_end\" value=\"[xml_escape [dict get $end_provenance git_sha]]\"/>"
puts $fh "    <property name=\"git.dirty_end\" value=\"[dict get $end_provenance git_dirty]\"/>"
puts $fh "    <property name=\"provenance.stable\" value=\"$provenance_stable\"/>"
puts $fh "    <property name=\"vivado.version\" value=\"[xml_escape [version -short]]\"/>"
puts $fh "    <property name=\"xelab.optimization\" value=\"$xelab_optimization\"/>"
puts $fh "    <property name=\"fast_dsp.model\" value=\"$fast_dsp\"/>"
puts $fh "    <property name=\"layer.range\" value=\"$start_layer..$stop_layer\"/>"
puts $fh "    <property name=\"canonical.candidate\" value=\"$canonical_candidate\"/>"
puts $fh "    <property name=\"canonical.metric_gate\" value=\"$canonical_metric_gate\"/>"
puts $fh "  </properties>"
puts $fh "  <testcase classname=\"xsim.release\" name=\"ten-layer-chain\" time=\"[format %.3f $elapsed]\">"
if {!$passed} {
    puts $fh "    <failure message=\"XSIM chain failed\">[xml_escape [string range $tool_message 0 2047]]</failure>"
}
puts $fh "    <system-out>[xml_escape [file normalize $xsim_log]]</system-out>"
puts $fh "  </testcase>"
puts $fh "</testsuite>"
close $fh

if {$canonical_publish} {
    atomic_publish $result_json $canonical_result_json
    atomic_publish $result_junit $canonical_result_junit
}

puts "=== ABI-v2 chain result: [expr {$passed ? {PASS} : {FAIL}}] ([format %.3f $elapsed] s) ==="
puts "=== JSON: [file normalize $result_json] ==="
puts "=== JUnit: [file normalize $result_junit] ==="
if {$canonical_publish} {
    puts "=== Canonical JSON: [file normalize $canonical_result_json] ==="
    puts "=== Canonical JUnit: [file normalize $canonical_result_junit] ==="
} else {
    puts "=== Canonical result unchanged (requires layers 0..9, STREAM_CFG=0xbf, no waves/trace/fast-DSP model, and all gates PASS) ==="
}
if {!$passed} {
    error "ABI-v2 chain failed: tool_failed=$tool_failed pass_lines=$pass_count fail_lines=$fail_count log=$xsim_log"
}

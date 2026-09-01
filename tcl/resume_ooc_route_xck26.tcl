# Resume a development OOC route from a previously gated post-place DCP.
#
# This is deliberately not a formal release flow.  Every published artifact is
# marked UNQUALIFIED because synthesis and placement were not freshly executed
# by this invocation.  The source bundle is nevertheless verified strictly so
# a stale, renamed, or cross-profile checkpoint cannot be routed accidentally.

set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
source [file join $script_dir build_common.tcl]

namespace eval ::ooc_route_resume {}

proc ::ooc_route_resume::read_strict_key_values {path label} {
    set values [dict create]
    foreach raw_line [split [::conv_accel_build::read_text $path] "\n"] {
        set line [string trimright $raw_line "\r"]
        if {$line eq ""} {
            continue
        }
        set split_at [string first "=" $line]
        if {$split_at <= 0} {
            error "$label contains a malformed line: $line"
        }
        set key [string range $line 0 [expr {$split_at - 1}]]
        set value [string range $line [expr {$split_at + 1}] end]
        if {[dict exists $values $key]} {
            error "$label contains duplicate key '$key'"
        }
        dict set values $key $value
    }
    return $values
}

proc ::ooc_route_resume::require_value {values key expected label} {
    if {![dict exists $values $key]} {
        error "$label is missing '$key'"
    }
    set actual [dict get $values $key]
    if {$actual ne $expected} {
        error "$label $key='$actual', expected '$expected'"
    }
}

proc ::ooc_route_resume::require_number {values key expected label} {
    if {![dict exists $values $key]} {
        error "$label is missing '$key'"
    }
    set actual [dict get $values $key]
    if {![::conv_accel_build::finite_number $actual] ||
        abs(double($actual) - double($expected)) > 0.000001} {
        error "$label $key='$actual', expected numeric '$expected'"
    }
}

proc ::ooc_route_resume::require_short_output_dir {root build_dir} {
    set build_dir [::conv_accel_build::require_nonpublication_build_dir \
        $root $build_dir]
    set normalized_root [string trimright \
        [string map {\\ /} [file normalize $root]] /]
    set normalized_build [string trimright \
        [string map {\\ /} [file normalize $build_dir]] /]
    set root_prefix "${normalized_root}/"
    if {![string equal -nocase [string range $normalized_build 0 \
            [expr {[string length $root_prefix] - 1}]] $root_prefix]} {
        error "resume build directory must be inside the repository"
    }
    set relative [string range $normalized_build [string length $root_prefix] end]
    if {[string first / $relative] >= 0 ||
        ![regexp -nocase {^build_ooc_route_[a-z0-9_.-]+$} $relative]} {
        error "resume build directory must be a dedicated top-level build_ooc_route_* path"
    }
    if {[string length $relative] > 40} {
        error "resume build directory name is too long ([string length $relative] > 40): $relative"
    }
    return [file normalize $build_dir]
}

proc ::ooc_route_resume::discover_source_stem {source_build_dir requested} {
    if {$requested ne ""} {
        if {[file tail $requested] ne $requested ||
            ![regexp {^[A-Za-z0-9_.-]+$} $requested]} {
            error "-source_stem must be a filename stem without directories"
        }
        return $requested
    }
    set candidates [glob -nocomplain -tails -directory $source_build_dir \
        *_placed.dcp]
    if {[llength $candidates] != 1} {
        error "source build directory must contain exactly one *_placed.dcp when -source_stem is omitted; found [llength $candidates]"
    }
    set tail [lindex $candidates 0]
    return [string range $tail 0 \
        [expr {[string length $tail] - [string length {_placed.dcp}] - 1}]]
}

proc ::ooc_route_resume::verify_single_artifact_manifest {manifest artifact} {
    set records [list]
    foreach raw_line [split [::conv_accel_build::read_text $manifest] "\n"] {
        set line [string trimright $raw_line "\r"]
        if {$line eq ""} {
            continue
        }
        if {![regexp {^([0-9A-Fa-f]{64})  ([^[:space:]]+)$} $line -> \
                digest filename]} {
            error "malformed SHA256 manifest line: $line ($manifest)"
        }
        lappend records [list [string tolower $digest] $filename]
    }
    if {[llength $records] != 1} {
        error "source SHA256 manifest must contain exactly one artifact; found [llength $records]"
    }
    lassign [lindex $records 0] expected_digest manifest_tail
    if {$manifest_tail ne [file tail $artifact]} {
        error "source SHA256 manifest names '$manifest_tail', expected '[file tail $artifact]'"
    }
    set actual_digest [::conv_accel_build::sha256_file $artifact]
    if {$actual_digest ne $expected_digest} {
        error "source placed DCP SHA256 mismatch: actual=$actual_digest expected=$expected_digest"
    }
    return $actual_digest
}

proc ::ooc_route_resume::verify_source_bundle {root source_build_dir \
        source_stem profile development_clock_mhz} {
    if {![file isdirectory $source_build_dir]} {
        error "source build directory not found: $source_build_dir"
    }
    set source_build_dir [file normalize $source_build_dir]
    set source_stem [discover_source_stem $source_build_dir $source_stem]
    set prefix [file join $source_build_dir $source_stem]
    set placed_dcp "${prefix}_placed.dcp"
    set gate_path "${prefix}_gate.txt"
    set metadata_path "${prefix}_build_profile.txt"
    set manifest_path "${prefix}_artifacts.sha256"
    set xdc_path "${prefix}_clock.xdc"
    foreach {label path} [list placed_dcp $placed_dcp gate $gate_path \
            metadata $metadata_path manifest $manifest_path xdc $xdc_path] {
        if {![file isfile $path]} {
            error "source $label not found: $path"
        }
    }

    set placed_sha256 [verify_single_artifact_manifest $manifest_path \
        $placed_dcp]
    set metadata [read_strict_key_values $metadata_path "source metadata"]
    set gate [read_strict_key_values $gate_path "source OOC gate"]
    set defaults [::conv_accel_build::profile_defaults $profile]
    set metadata_profile [::conv_accel_build::frequency_sweep_profile_name \
        $development_clock_mhz]
    set clock_hz [::conv_accel_build::clock_hz_from_mhz \
        $development_clock_mhz]
    set requested_period [::conv_accel_build::clock_period_ns_from_mhz \
        $development_clock_mhz]
    set constrained_period [expr {
        round(double($requested_period) * 1000.0) / 1000.0
    }]
    set post_place_min_wns \
        [::conv_accel_build::development_post_place_min_wns \
            $development_clock_mhz]

    foreach {key expected} [list \
            profile $metadata_profile source_profile $profile \
            development_frequency_sweep 1 implementation_stage post_place \
            out_of_context 1 enforce_gates 1 \
            top conv_accel_core_axi_lite_axis_stream \
            part xck26-sfvc784-2LV-c \
            pl_clock_mhz $development_clock_mhz clock_hz $clock_hz \
            development_post_place_margin_fraction 0.01] {
        require_value $metadata $key $expected "source metadata"
    }
    require_number $metadata clock_period_ns $requested_period \
        "source metadata"
    require_number $metadata constrained_clock_period_ns $constrained_period \
        "source metadata"
    require_number $metadata min_wns $post_place_min_wns "source metadata"

    foreach key {
        rows cols k_tile cout_tile enable_column_psum enable_packed_hwc_ofm
        enable_layer_tile_sequencer enable_layer_long_hwc_ifm
        enable_tagged_context enable_weight_preload
        enable_fast_context_handoff enable_detailed_trace ifm_banks
        ifm_fifo_depth ifm_fifo_aw psum_fifo_depth psum_fifo_aw hwc_cache_aw
        hwc_cache_depth hwc_cache_stripes hwc_cache_use_uram
        ifm_epoch_use_uram materialized_cache_aw materialized_cache_depth
        tail_cycles
    } {
        require_value $metadata $key [dict get $defaults $key] \
            "source metadata"
    }
    foreach {metadata_key default_key} {
        max_lut ooc_max_lut max_logic_lut ooc_max_logic_lut
        max_lut_memory ooc_max_lut_memory
        max_clb_percent ooc_max_clb_percent max_bram ooc_max_bram
        max_uram ooc_max_uram max_dsp ooc_max_dsp min_tns ooc_min_tns
        max_unconstrained_paths ooc_max_unconstrained_paths
        max_unclocked_fdre ooc_max_unclocked_fdre
        max_ooc_internal_none_fdre_endpoints
            ooc_max_internal_none_fdre_endpoints
    } {
        require_value $metadata $metadata_key [dict get $defaults $default_key] \
            "source metadata"
    }
    foreach key {git_root git_sha git_dirty vivado_version
        internal_none_fdre_audit_report ooc_internal_none_fdre_endpoints} {
        if {![dict exists $metadata $key]} {
            error "source metadata is missing '$key'"
        }
    }
    if {![regexp {^[0-9a-f]{40}$} [dict get $metadata git_sha]] ||
        [dict get $metadata git_dirty] ni {0 1}} {
        error "source metadata has invalid Git provenance"
    }
    if {[dict get $metadata vivado_version] ne "2022.2"} {
        error "source metadata Vivado version is not 2022.2"
    }
    require_value $metadata ooc_internal_none_fdre_endpoints 0 \
        "source metadata"
    set audit_tail [dict get $metadata internal_none_fdre_audit_report]
    if {[file tail $audit_tail] ne $audit_tail} {
        error "source metadata internal audit must name a sibling file"
    }
    set audit_path [file join $source_build_dir $audit_tail]
    set audit_metrics [::conv_accel_build::parse_ooc_internal_none_fdre_audit \
        [::conv_accel_build::read_text $audit_path]]
    if {[dict get $audit_metrics ooc_internal_none_fdre_endpoints] != 0} {
        error "source internal-none audit did not pass"
    }

    require_value $gate gate OOC "source OOC gate"
    require_value $gate status PASS "source OOC gate"
    foreach key {
        metric.failing_endpoints metric.hold_failing_endpoints
        metric.pulse_width_failing_endpoints metric.unclocked_fdre
        metric.unconstrained_paths metric.ooc_internal_none_fdre_endpoints
    } {
        require_value $gate $key 0 "source OOC gate"
    }
    require_number $gate limit.min_wns $post_place_min_wns \
        "source OOC gate"
    require_number $gate limit.min_tns 0.0 "source OOC gate"
    if {![dict exists $gate metric.wns] ||
        ![::conv_accel_build::finite_number [dict get $gate metric.wns]] ||
        double([dict get $gate metric.wns]) < double($post_place_min_wns)} {
        error "source OOC gate has invalid or insufficient metric.wns"
    }
    foreach {gate_key default_key} {
        limit.max_lut ooc_max_lut
        limit.max_logic_lut ooc_max_logic_lut
        limit.max_lut_memory ooc_max_lut_memory
        limit.max_clb_percent ooc_max_clb_percent
        limit.max_bram ooc_max_bram limit.max_uram ooc_max_uram
        limit.max_dsp ooc_max_dsp
        limit.max_unconstrained_paths ooc_max_unconstrained_paths
        limit.max_unclocked_fdre ooc_max_unclocked_fdre
        limit.max_ooc_internal_none_fdre_endpoints
            ooc_max_internal_none_fdre_endpoints
    } {
        require_value $gate $gate_key [dict get $defaults $default_key] \
            "source OOC gate"
    }
    set source_gate_metrics [dict create]
    foreach key [dict keys $gate] {
        if {[string match {metric.*} $key]} {
            dict set source_gate_metrics [string range $key 7 end] \
                [dict get $gate $key]
        }
    }
    set source_gate_limits [dict create \
        max_lut [dict get $defaults ooc_max_lut] \
        max_logic_lut [dict get $defaults ooc_max_logic_lut] \
        max_lut_memory [dict get $defaults ooc_max_lut_memory] \
        max_clb_percent [dict get $defaults ooc_max_clb_percent] \
        max_bram [dict get $defaults ooc_max_bram] \
        max_uram [dict get $defaults ooc_max_uram] \
        max_dsp [dict get $defaults ooc_max_dsp] \
        min_wns $post_place_min_wns min_tns 0.0 \
        max_unconstrained_paths \
            [dict get $defaults ooc_max_unconstrained_paths] \
        max_unclocked_fdre [dict get $defaults ooc_max_unclocked_fdre] \
        max_ooc_internal_none_fdre_endpoints \
            [dict get $defaults ooc_max_internal_none_fdre_endpoints]]
    set source_gate_violations [::conv_accel_build::metric_violations \
        $source_gate_metrics $source_gate_limits]
    if {[llength $source_gate_violations] != 0} {
        error "source OOC gate metrics do not satisfy the locked profile: [join $source_gate_violations {; }]"
    }

    set expected_xdc [format \
        {create_clock -name clk -period %.6f [get_ports {clk}]} \
        $constrained_period]
    if {[string trim [::conv_accel_build::read_text $xdc_path]] ne \
        $expected_xdc} {
        error "source clock XDC is not the canonical $constrained_period ns contract"
    }

    return [dict create source_build_dir $source_build_dir \
        source_stem $source_stem placed_dcp $placed_dcp gate_path $gate_path \
        metadata_path $metadata_path manifest_path $manifest_path \
        xdc_path $xdc_path audit_path $audit_path metadata $metadata \
        metadata_profile $metadata_profile defaults $defaults \
        clock_hz $clock_hz constrained_period $constrained_period \
        placed_sha256 $placed_sha256 \
        gate_sha256 [::conv_accel_build::sha256_file $gate_path] \
        metadata_sha256 [::conv_accel_build::sha256_file $metadata_path] \
        manifest_sha256 [::conv_accel_build::sha256_file $manifest_path] \
        xdc_sha256 [::conv_accel_build::sha256_file $xdc_path] \
        audit_sha256 [::conv_accel_build::sha256_file $audit_path]]
}

set source_build_dir ""
set source_stem ""
set build_dir ""
set output_stem ""
set profile ""
set development_clock_mhz ""
set check_only 0

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg in {-source_build_dir -source_stem -build_dir -stem -profile
            -development_clock_mhz}} {
        if {$i + 1 >= [llength $argv]} {
            error "$arg requires a value"
        }
        set value [lindex $argv [incr i]]
        switch -- $arg {
            -source_build_dir { set source_build_dir $value }
            -source_stem { set source_stem $value }
            -build_dir { set build_dir $value }
            -stem { set output_stem $value }
            -profile { set profile $value }
            -development_clock_mhz { set development_clock_mhz $value }
        }
    } elseif {$arg eq "-check_only"} {
        set check_only 1
    } else {
        error "unknown argument: $arg"
    }
}

foreach {option value} [list -source_build_dir $source_build_dir \
        -build_dir $build_dir -stem $output_stem -profile $profile \
        -development_clock_mhz $development_clock_mhz] {
    if {$value eq ""} {
        error "$option is required"
    }
}
if {$profile ne "abi_v2_release_200"} {
    error "resume OOC route requires -profile abi_v2_release_200"
}
set development_clock_mhz \
    [::conv_accel_build::validate_development_clock_mhz \
        $development_clock_mhz]
if {![regexp {^[A-Za-z0-9][A-Za-z0-9_.-]{0,23}$} $output_stem]} {
    error "-stem must be 1..24 filename-safe characters"
}
set build_dir [::ooc_route_resume::require_short_output_dir $root $build_dir]
set source_build_dir [file normalize $source_build_dir]
if {[string equal -nocase [string map {\\ /} $source_build_dir] \
        [string map {\\ /} $build_dir]]} {
    error "source and output build directories must differ"
}
set report_prefix [file join $build_dir "${output_stem}_UNQUALIFIED"]
set longest_output "${report_prefix}_routed_internal_none_fdre_audit.rpt"
if {[string length [file normalize $longest_output]] > 240} {
    error "resume output path exceeds the 240-character safety bound: $longest_output"
}

set source_bundle [::ooc_route_resume::verify_source_bundle $root \
    $source_build_dir $source_stem $profile $development_clock_mhz]
if {$check_only} {
    puts "PASS: UNQUALIFIED OOC route resume preflight profile=[dict get $source_bundle metadata_profile] clock_hz=[dict get $source_bundle clock_hz] source=[dict get $source_bundle placed_dcp] source_sha256=[dict get $source_bundle placed_sha256] build_dir=$build_dir stem=$output_stem"
    exit
}

::conv_accel_build::require_vivado_version 2022.2
file mkdir $build_dir

set routed_util "${report_prefix}_routed_utilization.rpt"
set routed_util_hier "${report_prefix}_routed_utilization_hier.rpt"
set routed_timing "${report_prefix}_routed_timing_summary.rpt"
set routed_top50 "${report_prefix}_routed_timing_top50.rpt"
set routed_route "${report_prefix}_routed_route_status.rpt"
set routed_drc "${report_prefix}_routed_drc.rpt"
set routed_congestion "${report_prefix}_routed_congestion.rpt"
set routed_none "${report_prefix}_routed_internal_none_fdre_audit.rpt"
set routed_gate "${report_prefix}_routed_gate.txt"
set routed_metadata_path \
    "${report_prefix}_routed_build_profile.txt"
set routed_checkpoint "${report_prefix}_routed.dcp"
set routed_manifest "${report_prefix}_routed_artifacts.sha256"
::conv_accel_build::remove_stale_publications $build_dir [list \
    $routed_util $routed_util_hier $routed_timing $routed_top50 \
    $routed_route $routed_drc $routed_congestion $routed_none $routed_gate \
    $routed_metadata_path $routed_checkpoint $routed_manifest]

open_checkpoint [dict get $source_bundle placed_dcp]
set design_object [current_design]
if {[llength $design_object] != 1} {
    error "resumed DCP did not open exactly one current design"
}
set expected_top conv_accel_core_axi_lite_axis_stream
set expected_part xck26-sfvc784-2LV-c
set actual_top [get_property TOP $design_object]
set actual_part [get_property PART $design_object]
if {$actual_top ne $expected_top} {
    error "resumed DCP top='$actual_top', expected '$expected_top'"
}
if {$actual_part ne $expected_part} {
    error "resumed DCP part='$actual_part', expected '$expected_part'"
}
set clock_ports [get_ports -quiet clk]
set constrained_clocks [get_clocks -quiet -of_objects $clock_ports]
if {[llength $clock_ports] != 1 || [llength $constrained_clocks] != 1 ||
    [llength [get_clocks -quiet]] != 1} {
    error "resumed DCP must contain exactly one clk port and one clock"
}
set dcp_period [get_property PERIOD [lindex $constrained_clocks 0]]
if {![::conv_accel_build::finite_number $dcp_period] ||
    abs(double($dcp_period) -
        double([dict get $source_bundle constrained_period])) > 0.000001} {
    error "resumed DCP clock period='$dcp_period', expected [dict get $source_bundle constrained_period] ns"
}

phys_opt_design -directive AggressiveExplore
route_design

report_utilization -file $routed_util
report_utilization -hierarchical -file $routed_util_hier
report_timing_summary -report_unconstrained -file $routed_timing
report_timing -delay_type max -max_paths 50 -sort_by group \
    -file $routed_top50
report_route_status -file $routed_route
# OOC designs must not run bitstream_checks: HDOOC-3 is unconditional there.
report_drc -ruledecks {default} -file $routed_drc
report_design_analysis -congestion -min_congestion_level 3 \
    -file $routed_congestion
set routed_none_metrics \
    [::conv_accel_build::write_ooc_internal_none_fdre_audit \
        $routed_none 50]

set routed_metrics [::conv_accel_build::metrics_from_reports \
    $routed_util $routed_timing $routed_route $routed_congestion "" \
    $routed_none]
set routed_drc_errors 0
set routed_drc_critical_warnings 0
foreach drc_violation [get_drc_violations -quiet] {
    set severity [get_property SEVERITY $drc_violation]
    if {$severity eq "Error"} {
        incr routed_drc_errors
    } elseif {$severity eq "Critical Warning"} {
        incr routed_drc_critical_warnings
    }
}
dict set routed_metrics drc_errors $routed_drc_errors
dict set routed_metrics drc_critical_warnings \
    $routed_drc_critical_warnings
set defaults [dict get $source_bundle defaults]
set routed_limits [dict create \
    max_lut [dict get $defaults ooc_max_lut] \
    max_logic_lut [dict get $defaults ooc_max_logic_lut] \
    max_lut_memory [dict get $defaults ooc_max_lut_memory] \
    max_clb_percent [dict get $defaults ooc_max_clb_percent] \
    max_bram [dict get $defaults ooc_max_bram] \
    max_uram [dict get $defaults ooc_max_uram] expected_uram 48 \
    max_dsp [dict get $defaults ooc_max_dsp] max_congestion_level 4 \
    min_wns 0.0 min_tns 0.0 min_whs 0.0 min_ths 0.0 \
    max_failing_endpoints 0 max_hold_failing_endpoints 0 \
    max_pulse_width_failing_endpoints 0 \
    max_unconstrained_paths [dict get $defaults ooc_max_unconstrained_paths] \
    max_unclocked_fdre [dict get $defaults ooc_max_unclocked_fdre] \
    max_ooc_internal_none_fdre_endpoints \
        [dict get $defaults ooc_max_internal_none_fdre_endpoints] \
    max_route_errors 0 max_drc_errors 0 max_drc_critical_warnings 0]
::conv_accel_build::enforce_report_gate OOC_ROUTE \
    $routed_gate $routed_metrics $routed_limits

set source_metadata [dict get $source_bundle metadata]
dict unset source_metadata profile
set routed_metadata $source_metadata
dict set routed_metadata implementation_stage post_route
dict set routed_metadata development_route 1
dict set routed_metadata development_route_min_wns 0.0
dict set routed_metadata development_route_max_congestion_level 4
dict set routed_metadata route_errors [dict get $routed_metrics route_errors]
dict set routed_metadata drc_errors $routed_drc_errors
dict set routed_metadata drc_critical_warnings \
    $routed_drc_critical_warnings
dict set routed_metadata ooc_internal_none_fdre_endpoints \
    [dict get $routed_none_metrics ooc_internal_none_fdre_endpoints]
dict set routed_metadata qualification_status UNQUALIFIED
dict set routed_metadata formal_release_qualified 0
dict set routed_metadata qualification_reason \
    resumed_from_post_place_checkpoint_without_fresh_synth_or_place
dict set routed_metadata resume_ooc_route 1
dict set routed_metadata resume_fresh_synth 0
dict set routed_metadata resume_fresh_place 0
dict set routed_metadata resume_fresh_route 1
dict set routed_metadata resume_source_build_dir \
    [dict get $source_bundle source_build_dir]
dict set routed_metadata resume_source_stem \
    [dict get $source_bundle source_stem]
foreach key {placed gate metadata manifest xdc audit} {
    dict set routed_metadata "resume_source_${key}_sha256" \
        [dict get $source_bundle "${key}_sha256"]
}
set resume_git [::conv_accel_build::git_provenance $root]
dict set routed_metadata resume_git_root [dict get $resume_git git_root]
dict set routed_metadata resume_git_sha [dict get $resume_git git_sha]
dict set routed_metadata resume_git_dirty [dict get $resume_git git_dirty]
dict set routed_metadata resume_script_sha256 \
    [::conv_accel_build::sha256_file [file normalize [info script]]]
dict set routed_metadata vivado_version [version -short]

# Even after every development gate passes, resumed artifacts remain visibly
# UNQUALIFIED and cannot be confused with the fresh formal release flow.
::conv_accel_build::write_build_metadata $routed_metadata_path \
    [dict get $source_bundle metadata_profile] $routed_metadata
write_checkpoint -force $routed_checkpoint
::conv_accel_build::write_sha256_manifest $routed_manifest \
    [list $routed_gate $routed_metadata_path $routed_checkpoint]

puts "=== UNQUALIFIED OOC route resume complete ==="
puts $routed_timing
puts $routed_top50
puts $routed_route
puts $routed_drc
puts $routed_congestion
puts $routed_none
puts $routed_gate
puts $routed_metadata_path
puts $routed_checkpoint
puts $routed_manifest

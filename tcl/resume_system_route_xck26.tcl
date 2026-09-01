# Resume exactly one 125 MHz full-system development route from the frozen
# managed post-phys-opt checkpoint.
#
# This script is intentionally narrower than build_kv260_system_xck26.tcl.  It
# accepts only the known abi_v2_frequency_sweep_125 project produced from clean
# hardware source commit 13eeca8.  Synthesis, opt_design, place_design, and
# phys_opt_design are never invoked.  Their checkpoints and completion markers
# are hashed/snapshotted before route and must remain unchanged afterwards.
# Even when every gate passes, the resulting bit/XSA remain development-only
# and explicitly UNQUALIFIED for formal release.

set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
source [file join $script_dir build_common.tcl]

namespace eval ::system_route_resume {
    variable source_git_sha \
        13eeca8e6d4b1a0f696df7f75050faf5a08cb2cc
    variable expected_sha256 [dict create \
        xpr 1d5e2662e2c95b81ed32373486da2d9079a4ff92a8cd6838792444278fed1a80 \
        source_metadata 0e8b22f258a0ef922eaf625cd057e7afaca0db5c868f45fbc1e3ffcb1c968a53 \
        source_report_metadata 31afbfe25f467ac61bb017a9dead77c463b515e528d7d724f89a5a8e55980c75 \
        source_failed_place_gate a76efb967d20c3f82be0ef6f2136d14b29ee166a5f29f874ec8104ea1d1d1ca3 \
        synth 2bc7f58322c58ce164e70fcccd6c9d2b5e70baa4b708a9afb8d75e9590136398 \
        opt 74a135849eeadc68eaeb6c0cc0b8f2301e6afa5966242f658560761c2b2ba21f \
        placed 3e9e42c4f055cd91a89e8e171eb8bc64d9947215b94547a4bd5d3b39668d6ff8 \
        physopt 2f0ba04caf15985e68964213337f8fc928c58268c9013064d25fa29f2b416cdf]
}

proc ::system_route_resume::read_strict_key_values {path label} {
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

proc ::system_route_resume::require_value {values key expected label} {
    if {![dict exists $values $key]} {
        error "$label is missing '$key'"
    }
    set actual [dict get $values $key]
    if {$actual ne $expected} {
        error "$label $key='$actual', expected '$expected'"
    }
}

proc ::system_route_resume::require_sha256 {path expected label} {
    if {![file isfile $path]} {
        error "$label is not a file: $path"
    }
    set actual [::conv_accel_build::sha256_file $path]
    if {$actual ne $expected} {
        error "$label SHA256 mismatch: actual=$actual expected=$expected"
    }
    return $actual
}

proc ::system_route_resume::require_exact_source_build_dir {root path} {
    set expected [file normalize \
        [file join $root build_system_abi_v2_frequency_sweep_125]]
    set actual [file normalize $path]
    if {![string equal -nocase [string map {\\ /} $actual] \
            [string map {\\ /} $expected]]} {
        error "system route resume is bound to $expected; got $actual"
    }
    return $actual
}

proc ::system_route_resume::require_locked_profile_defaults {} {
    set defaults [::conv_accel_build::profile_defaults abi_v2_release_200]
    set expected [dict create \
        board_part xilinx.com:kv260_som:part0:1.4 \
        board_connection [list som240_1_connector \
            xilinx.com:kv260_carrier:som240_1_connector:1.3] \
        pl_clock_mhz 200 weight_dma_mm2s_burst 64 \
        rows 18 cols 16 k_tile 18 cout_tile 32 \
        enable_column_psum 0 enable_packed_hwc_ofm 1 \
        enable_layer_tile_sequencer 1 enable_layer_long_hwc_ifm 1 \
        enable_tagged_context 1 enable_weight_preload 1 \
        enable_fast_context_handoff 1 enable_detailed_trace 0 \
        enable_legacy_gpio_status 0 ifm_banks 2 \
        ifm_fifo_depth 1024 ifm_fifo_aw 10 \
        psum_fifo_depth 256 psum_fifo_aw 8 \
        hwc_cache_aw 16 hwc_cache_depth 43264 hwc_cache_stripes 4 \
        hwc_cache_use_uram 1 ifm_epoch_use_uram 1 \
        materialized_cache_aw 15 materialized_cache_depth 32768 \
        tail_cycles 1 system_max_lut 90000 system_max_lut_memory 8000 \
        system_max_clb_percent 85.0 system_place_max_congestion_level 4 \
        system_max_uram 48 system_expected_uram 48 system_max_dsp 720 \
        system_min_tns 0.0 system_min_whs 0.0 system_min_ths 0.0 \
        system_max_failing_endpoints 0 \
        system_max_hold_failing_endpoints 0 \
        system_max_pulse_width_failing_endpoints 0 \
        system_max_unconstrained_paths 0 system_max_unclocked_fdre 0 \
        system_max_accel_none_delay_endpoints 0 \
        system_max_route_errors 0 system_max_drc_errors 0 \
        system_max_drc_critical_warnings 0]
    foreach {key value} $expected {
        if {![dict exists $defaults $key] || [dict get $defaults $key] ne $value} {
            error "current abi_v2_release_200 profile changed $key; route resume requires '$value'"
        }
    }
    return $defaults
}

proc ::system_route_resume::require_design_sources_unchanged {root current_sha} {
    variable source_git_sha
    set git [auto_execok git]
    if {$git eq ""} {
        error "git is required to verify route-resume source equivalence"
    }
    if {[catch {exec {*}$git -C $root merge-base --is-ancestor \
            $source_git_sha $current_sha} message]} {
        error "source hardware commit $source_git_sha is not an ancestor of resume commit $current_sha: $message"
    }
    # These are the inputs capable of changing the synthesized/placed design.
    # Reporting/gate Tcl is deliberately absent because it is the only class
    # allowed to change for this resume.
    set design_paths {
        cal
        com
        systolic
        tcl/rtl_sources.tcl
        tcl/create_ps_dma_bd_xck26.tcl
        tcl/abi_v2_margin_physopt_post.tcl
    }
    if {[catch {exec {*}$git -C $root diff --quiet $source_git_sha -- \
            {*}$design_paths}]} {
        set changed [string trim [exec {*}$git -C $root diff --name-only \
            $source_git_sha -- {*}$design_paths]]
        error "design-affecting sources changed since $source_git_sha: $changed"
    }
}

proc ::system_route_resume::bundle_paths {source_build_dir} {
    set project_name conv_accel_ps_dma_minimal
    set wrapper_top conv_accel_ps_dma_wrapper
    set project_dir [file join $source_build_dir $project_name]
    set runs_dir [file join $project_dir "${project_name}.runs"]
    set synth_dir [file join $runs_dir synth_1]
    set impl_dir [file join $runs_dir impl_1]
    set reports [file join $source_build_dir reports]
    return [dict create \
        source_build_dir $source_build_dir project_name $project_name \
        wrapper_top $wrapper_top project_dir $project_dir \
        reports $reports synth_dir $synth_dir impl_dir $impl_dir \
        xpr [file join $project_dir "${project_name}.xpr"] \
        source_metadata [file join $source_build_dir build_profile.txt] \
        source_report_metadata [file join $reports build_profile.txt] \
        source_failed_place_gate [file join $reports system_place_gate.txt] \
        synth [file join $synth_dir "${wrapper_top}.dcp"] \
        opt [file join $impl_dir "${wrapper_top}_opt.dcp"] \
        placed [file join $impl_dir "${wrapper_top}_placed.dcp"] \
        physopt [file join $impl_dir "${wrapper_top}_physopt.dcp"] \
        routed [file join $impl_dir "${wrapper_top}_routed.dcp"] \
        bit [file join $impl_dir "${wrapper_top}.bit"] \
        xsa [file join $source_build_dir "${project_name}.xsa"] \
        final_manifest [file join $reports system_artifacts.sha256]]
}

proc ::system_route_resume::require_source_metadata {path root} {
    variable source_git_sha
    set metadata [read_strict_key_values $path "source build metadata"]
    set expected [dict create \
        profile abi_v2_frequency_sweep_125 \
        source_profile abi_v2_release_200 \
        development_frequency_sweep 1 \
        project_name conv_accel_ps_dma_minimal bd_name conv_accel_ps_dma \
        part xck26-sfvc784-2LV-c \
        board_part xilinx.com:kv260_som:part0:1.4 \
        board_connection [list som240_1_connector \
            xilinx.com:kv260_carrier:som240_1_connector:1.3] \
        pl_clock_mhz 125 clock_hz 125000000 clock_period_ns 8.000000 \
        rows 18 cols 16 k_tile 18 cout_tile 32 \
        enable_column_psum 0 enable_packed_hwc_ofm 1 \
        enable_layer_tile_sequencer 1 enable_layer_long_hwc_ifm 1 \
        enable_tagged_context 1 enable_weight_preload 1 \
        enable_fast_context_handoff 1 enable_detailed_trace 0 \
        enable_legacy_gpio_status 0 ifm_banks 2 \
        ifm_fifo_depth 1024 ifm_fifo_aw 10 \
        psum_fifo_depth 256 psum_fifo_aw 8 \
        hwc_cache_aw 16 hwc_cache_depth 43264 hwc_cache_stripes 4 \
        hwc_cache_use_uram 1 ifm_epoch_use_uram 1 \
        materialized_cache_aw 15 materialized_cache_depth 32768 \
        tail_cycles 1 weight_dma_mm2s_burst 64 \
        mm2s_dma_count 3 s2mm_dma_count 1 dma_data_width 64 \
        dma_memory_port HP0_HP1_HP2_HP3 \
        dma_memory_ports {HP0 HP1 HP2 HP3} ila_enabled 0 \
        git_sha $source_git_sha git_dirty 0 vivado_version 2022.2]
    foreach {key value} $expected {
        require_value $metadata $key $value "source build metadata"
    }
    if {![dict exists $metadata git_root] ||
        ![string equal -nocase \
            [string map {\\ /} [file normalize [dict get $metadata git_root]]] \
            [string map {\\ /} [file normalize $root]]]} {
        error "source build metadata git_root is not the current repository"
    }
    return $metadata
}

proc ::system_route_resume::require_pre_route_markers {bundle} {
    set marker_paths [dict create \
        synth_end [file join [dict get $bundle synth_dir] .vivado.end.rst] \
        init_begin [file join [dict get $bundle impl_dir] .init_design.begin.rst] \
        init_end [file join [dict get $bundle impl_dir] .init_design.end.rst] \
        opt_begin [file join [dict get $bundle impl_dir] .opt_design.begin.rst] \
        opt_end [file join [dict get $bundle impl_dir] .opt_design.end.rst] \
        place_begin [file join [dict get $bundle impl_dir] .place_design.begin.rst] \
        place_end [file join [dict get $bundle impl_dir] .place_design.end.rst] \
        physopt_begin [file join [dict get $bundle impl_dir] .phys_opt_design.begin.rst] \
        physopt_end [file join [dict get $bundle impl_dir] .phys_opt_design.end.rst]]
    foreach {key path} $marker_paths {
        if {![file isfile $path]} {
            error "frozen pre-route bundle is missing $key marker: $path"
        }
    }
    foreach name {
        .route_design.begin.rst .route_design.end.rst .route_design.error.rst
        .write_bitstream.begin.rst .write_bitstream.end.rst
        .write_bitstream.error.rst
    } {
        set path [file join [dict get $bundle impl_dir] $name]
        if {[file exists $path]} {
            error "route-only resume is one-shot; future-step marker already exists: $path"
        }
    }
    foreach key {routed bit xsa final_manifest} {
        set path [dict get $bundle $key]
        if {[file exists $path]} {
            error "route-only resume refuses to overwrite an existing future artifact: $path"
        }
    }
    return $marker_paths
}

proc ::system_route_resume::verify_source_bundle {root source_build_dir} {
    variable expected_sha256
    set source_build_dir [require_exact_source_build_dir $root $source_build_dir]
    set bundle [bundle_paths $source_build_dir]
    foreach key {xpr source_metadata source_report_metadata
            source_failed_place_gate synth opt placed physopt} {
        require_sha256 [dict get $bundle $key] \
            [dict get $expected_sha256 $key] "frozen $key"
    }
    set metadata [require_source_metadata [dict get $bundle source_metadata] $root]
    dict set bundle source_metadata_values $metadata
    dict set bundle marker_paths [require_pre_route_markers $bundle]
    return $bundle
}

proc ::system_route_resume::snapshot_prior_stages {bundle} {
    set snapshot [dict create]
    foreach key {synth opt placed physopt} {
        set path [dict get $bundle $key]
        dict set snapshot "$key.sha256" [::conv_accel_build::sha256_file $path]
        dict set snapshot "$key.mtime" [file mtime $path]
        dict set snapshot "$key.size" [file size $path]
    }
    foreach {key path} [dict get $bundle marker_paths] {
        dict set snapshot "marker.$key.mtime" [file mtime $path]
        dict set snapshot "marker.$key.size" [file size $path]
    }
    return $snapshot
}

proc ::system_route_resume::require_prior_stages_unchanged {bundle snapshot label} {
    variable expected_sha256
    foreach key {synth opt placed physopt} {
        set path [dict get $bundle $key]
        set actual_sha [require_sha256 $path [dict get $expected_sha256 $key] \
            "$label $key checkpoint"]
        foreach {suffix actual} [list \
                sha256 $actual_sha mtime [file mtime $path] size [file size $path]] {
            set expected [dict get $snapshot "$key.$suffix"]
            if {$actual ne $expected} {
                error "$label changed prior-stage $key $suffix: actual=$actual expected=$expected"
            }
        }
    }
    foreach {key path} [dict get $bundle marker_paths] {
        if {![file isfile $path]} {
            error "$label removed prior-stage marker $path"
        }
        foreach {suffix actual} [list mtime [file mtime $path] size [file size $path]] {
            set expected [dict get $snapshot "marker.$key.$suffix"]
            if {$actual ne $expected} {
                error "$label changed prior-stage marker $key $suffix: actual=$actual expected=$expected"
            }
        }
    }
}

proc ::system_route_resume::assert_no_debug_cores {stage} {
    set debug_cores [get_debug_cores -quiet]
    if {[llength $debug_cores] != 0} {
        error "UNQUALIFIED 125 MHz $stage design contains debug cores: $debug_cores"
    }
}

proc ::system_route_resume::assert_design_identity {stage} {
    set design [current_design]
    if {[llength $design] != 1} {
        error "$stage did not open exactly one current design"
    }
    foreach {property expected} [list \
            TOP conv_accel_ps_dma_wrapper PART xck26-sfvc784-2LV-c] {
        set actual [get_property $property $design]
        if {$actual ne $expected} {
            error "$stage current_design $property='$actual', expected '$expected'"
        }
    }
    set accel [get_cells -quiet -hier -filter {NAME =~ */accel/inst}]
    if {[llength $accel] != 1} {
        error "$stage resolved [llength $accel] accelerator cells; expected one"
    }
    foreach {clock_name expected_period} {clk_pl_0 8.000 clk_pl_1 10.000} {
        set clocks [get_clocks -quiet $clock_name]
        if {[llength $clocks] != 1} {
            error "$stage resolved [llength $clocks] '$clock_name' clocks; expected one"
        }
        set period [get_property PERIOD [lindex $clocks 0]]
        if {![::conv_accel_build::finite_number $period] ||
            abs(double($period) - double($expected_period)) > 0.000001} {
            error "$stage $clock_name period='$period', expected $expected_period ns"
        }
    }
    assert_no_debug_cores $stage
}

proc ::system_route_resume::require_managed_run_step {run_name step artifact} {
    set runs [get_runs -quiet $run_name]
    if {[llength $runs] != 1} {
        error "expected exactly one managed run '$run_name'; found [llength $runs]"
    }
    set run [lindex $runs 0]
    set run_dir [file normalize [get_property DIRECTORY $run]]
    foreach error_marker [list [file join $run_dir ".${step}.error.rst"] \
            [file join $run_dir .vivado.error.rst]] {
        if {[file exists $error_marker]} {
            error "managed run '$run_name' recorded an error: $error_marker"
        }
    }
    foreach end_marker [list [file join $run_dir ".${step}.end.rst"] \
            [file join $run_dir .vivado.end.rst]] {
        if {![file isfile $end_marker]} {
            error "managed run '$run_name' is missing $step completion: $end_marker"
        }
    }
    set needs_refresh [get_property NEEDS_REFRESH $run]
    if {$needs_refresh ne "0"} {
        error "managed run '$run_name' completed $step with NEEDS_REFRESH=$needs_refresh"
    }
    if {![file isfile $artifact] || [file size $artifact] <= 0} {
        error "managed run '$run_name' completed $step without artifact: $artifact"
    }
    puts "Managed run diagnostic: run=$run_name completed_step=$step status={[get_property STATUS $run]} current_step={[get_property CURRENT_STEP $run]}"
    return [file normalize $artifact]
}

proc ::system_route_resume::count_drc_severities {} {
    set errors 0
    set critical_warnings 0
    foreach violation [get_drc_violations -quiet] {
        set severity [get_property SEVERITY $violation]
        if {$severity eq "Error"} {
            incr errors
        } elseif {$severity eq "Critical Warning"} {
            incr critical_warnings
        }
    }
    return [dict create drc_errors $errors \
        drc_critical_warnings $critical_warnings]
}

proc ::system_route_resume::place_limits {} {
    return [dict create \
        max_lut 90000 max_lut_memory 8000 max_clb_percent 85.0 \
        max_uram 48 expected_uram 48 max_dsp 720 min_wns 0.08 min_tns 0.0 \
        max_failing_endpoints 0 max_unconstrained_paths 0 \
        max_unclocked_fdre 0 max_accel_internal_none_fdre_endpoints 0 \
        max_congestion_level 4]
}

proc ::system_route_resume::route_limits {} {
    return [dict create \
        max_lut 90000 max_lut_memory 8000 max_clb_percent 85.0 \
        max_uram 48 expected_uram 48 max_dsp 720 \
        min_wns 0.0 min_tns 0.0 min_whs 0.0 min_ths 0.0 \
        max_failing_endpoints 0 max_hold_failing_endpoints 0 \
        max_pulse_width_failing_endpoints 0 max_unconstrained_paths 0 \
        max_unclocked_fdre 0 max_accel_internal_none_fdre_endpoints 0 \
        max_route_errors 0 max_drc_errors 0 max_drc_critical_warnings 0]
}

set source_build_dir ""
set profile ""
set development_clock_mhz ""
set expected_resume_git_sha ""
set jobs 12
set check_only 0

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg in {-source_build_dir -profile -development_clock_mhz
            -expected_resume_git_sha -jobs}} {
        if {$i + 1 >= [llength $argv]} {
            error "$arg requires a value"
        }
        set value [lindex $argv [incr i]]
        switch -- $arg {
            -source_build_dir { set source_build_dir $value }
            -profile { set profile $value }
            -development_clock_mhz { set development_clock_mhz $value }
            -expected_resume_git_sha { set expected_resume_git_sha $value }
            -jobs { set jobs $value }
        }
    } elseif {$arg eq "-check_only"} {
        set check_only 1
    } else {
        error "unknown argument: $arg"
    }
}

foreach {option value} [list \
        -source_build_dir $source_build_dir -profile $profile \
        -development_clock_mhz $development_clock_mhz \
        -expected_resume_git_sha $expected_resume_git_sha] {
    if {$value eq ""} {
        error "$option is required"
    }
}
if {$profile ne "abi_v2_release_200"} {
    error "system route resume requires -profile abi_v2_release_200"
}
if {$development_clock_mhz ne "125"} {
    error "system route resume is bound to -development_clock_mhz 125"
}
if {![regexp {^[0-9a-f]{40}$} $expected_resume_git_sha]} {
    error "-expected_resume_git_sha must be a lowercase full Git SHA"
}
if {![string is integer -strict $jobs] || $jobs < 1 || $jobs > 32} {
    error "-jobs must be an integer from 1 through 32"
}

::system_route_resume::require_locked_profile_defaults
set resume_start_git [::conv_accel_build::require_clean_git $root]
if {[dict get $resume_start_git git_sha] ne $expected_resume_git_sha} {
    error "resume Git SHA is [dict get $resume_start_git git_sha], expected $expected_resume_git_sha"
}
::system_route_resume::require_design_sources_unchanged $root \
    $expected_resume_git_sha
set bundle [::system_route_resume::verify_source_bundle \
    $root $source_build_dir]
set prior_snapshot [::system_route_resume::snapshot_prior_stages $bundle]

if {$check_only} {
    puts "PASS: UNQUALIFIED 125 MHz full-system route-only resume preflight source_git_sha=$::system_route_resume::source_git_sha resume_git_sha=$expected_resume_git_sha physopt_sha256=[dict get $::system_route_resume::expected_sha256 physopt]"
    exit
}

::conv_accel_build::require_vivado_version 2022.2
set reports [dict get $bundle reports]
file mkdir $reports

# Re-evaluate the corrected post-place gate directly on the exact frozen DCP.
# No physical optimization is permitted in this invocation.
set place_util [file join $reports system_place_utilization.rpt]
set place_util_hier [file join $reports system_place_utilization_hier.rpt]
set place_timing [file join $reports system_place_timing_summary.rpt]
set place_audit [file join $reports \
    system_place_accel_internal_none_fdre_audit.rpt]
set place_congestion [file join $reports system_place_congestion.rpt]
set place_gate [file join $reports system_place_gate.txt]

open_checkpoint [dict get $bundle physopt]
::system_route_resume::assert_design_identity post_place_resume
report_utilization -file $place_util
report_utilization -hierarchical -file $place_util_hier
report_timing_summary -report_unconstrained -file $place_timing
::conv_accel_build::write_system_accel_internal_none_fdre_audit $place_audit
report_design_analysis -congestion -min_congestion_level 3 \
    -file $place_congestion
set place_metrics [::conv_accel_build::metrics_from_reports \
    $place_util $place_timing "" $place_congestion $place_audit]
::conv_accel_build::enforce_report_gate SYSTEM_PLACE_RESUME \
    $place_gate $place_metrics [::system_route_resume::place_limits]
close_project

::system_route_resume::require_prior_stages_unchanged \
    $bundle $prior_snapshot post_place_gate
::conv_accel_build::require_stable_clean_git $root $resume_start_git \
    "125 MHz post-place resume gate"

# Continue the original managed implementation run.  Its completed-step
# markers and DCP hashes above make this a route-only continuation while still
# retaining the original BD project context required by write_hw_platform.
open_project [dict get $bundle xpr]
set impl_runs [get_runs -quiet impl_1]
if {[llength $impl_runs] != 1} {
    error "expected exactly one impl_1 run; found [llength $impl_runs]"
}
set actual_impl_dir [file normalize \
    [get_property DIRECTORY [lindex $impl_runs 0]]]
if {![string equal -nocase [string map {\\ /} $actual_impl_dir] \
        [string map {\\ /} [file normalize [dict get $bundle impl_dir]]]]} {
    error "impl_1 directory changed: $actual_impl_dir"
}
if {[get_property NEEDS_REFRESH [lindex $impl_runs 0]] ne "0"} {
    error "impl_1 needs refresh before route; refusing to rebuild prior stages"
}
::system_route_resume::require_prior_stages_unchanged \
    $bundle $prior_snapshot pre_managed_route

launch_runs impl_1 -to_step route_design -jobs $jobs
wait_on_run impl_1
set routed_dcp [::system_route_resume::require_managed_run_step \
    impl_1 route_design [dict get $bundle routed]]
::system_route_resume::require_prior_stages_unchanged \
    $bundle $prior_snapshot post_managed_route
::conv_accel_build::require_stable_clean_git $root $resume_start_git \
    "125 MHz route-only implementation"

set impl_util [file join $reports system_impl_utilization.rpt]
set impl_util_hier [file join $reports system_impl_utilization_hier.rpt]
set impl_timing [file join $reports system_impl_timing_summary.rpt]
set impl_top50 [file join $reports system_impl_timing_top50.rpt]
set impl_audit [file join $reports \
    system_impl_accel_internal_none_fdre_audit.rpt]
set impl_route [file join $reports system_impl_route_status.rpt]
set impl_drc [file join $reports system_impl_drc.rpt]
set impl_congestion [file join $reports system_impl_congestion.rpt]
set impl_gate [file join $reports system_impl_gate.txt]

open_run impl_1
::system_route_resume::assert_design_identity post_route_resume
report_utilization -file $impl_util
report_utilization -hierarchical -file $impl_util_hier
report_route_status -file $impl_route
report_timing_summary -report_unconstrained -file $impl_timing
report_timing -delay_type max -max_paths 50 -sort_by group \
    -file $impl_top50
::conv_accel_build::write_system_accel_internal_none_fdre_audit $impl_audit
report_drc -ruledecks {default bitstream_checks} -file $impl_drc
report_design_analysis -congestion -min_congestion_level 3 \
    -file $impl_congestion
set impl_metrics [::conv_accel_build::metrics_from_reports \
    $impl_util $impl_timing $impl_route $impl_congestion $impl_audit]
set impl_metrics [dict merge $impl_metrics \
    [::system_route_resume::count_drc_severities]]
::conv_accel_build::enforce_report_gate SYSTEM_IMPL_RESUME \
    $impl_gate $impl_metrics [::system_route_resume::route_limits]
close_design

::system_route_resume::require_prior_stages_unchanged \
    $bundle $prior_snapshot post_route_gate
set routed_sha256 [::conv_accel_build::sha256_file $routed_dcp]
set routed_mtime [file mtime $routed_dcp]
set routed_size [file size $routed_dcp]
::conv_accel_build::require_stable_clean_git $root $resume_start_git \
    "125 MHz post-route gate"

set bit_file [dict get $bundle bit]
set xsa_file [dict get $bundle xsa]
set final_manifest [dict get $bundle final_manifest]
set final_metadata [file join $reports build_profile.txt]
set metadata_temporary [file join $reports \
    "build_profile.route_resume.tmp.[pid]"]

set publication_failed [catch {
    launch_runs impl_1 -to_step write_bitstream -jobs $jobs
    wait_on_run impl_1
    ::system_route_resume::require_managed_run_step \
        impl_1 write_bitstream $bit_file
    ::system_route_resume::require_prior_stages_unchanged \
        $bundle $prior_snapshot post_bitstream
    set routed_after_bit [::conv_accel_build::sha256_file $routed_dcp]
    if {$routed_after_bit ne $routed_sha256 ||
        [file mtime $routed_dcp] != $routed_mtime ||
        [file size $routed_dcp] != $routed_size} {
        error "write_bitstream changed or regenerated the gated routed checkpoint"
    }

    open_run impl_1
    ::system_route_resume::assert_design_identity hardware_publication
    write_hw_platform -fixed -include_bit -force $xsa_file
    close_design
    if {![file isfile $xsa_file] || [file size $xsa_file] <= 0} {
        error "write_hw_platform did not create the expected XSA: $xsa_file"
    }
    set resume_end_git [::conv_accel_build::require_stable_clean_git \
        $root $resume_start_git "125 MHz route-resume publication"]

    set metadata [dict get $bundle source_metadata_values]
    dict unset metadata profile
    # The authoritative source dictionary comes from the clean root-level
    # build metadata, not the aborted reports/build_profile.txt.  Scrub the
    # generic end-of-build keys defensively anyway: the hardware identity is
    # the inherited git_sha/git_dirty pair, while this continuation has its
    # own resume_git_* provenance below.  A pending/dirty value from an
    # interrupted source report must never leak into candidate metadata.
    foreach source_terminal_key {
        git_root_end git_sha_end git_dirty_end provenance_stable
    } {
        if {[dict exists $metadata $source_terminal_key]} {
            dict unset metadata $source_terminal_key
        }
    }
    foreach {key value} [list \
            enforce_gates 1 jobs $jobs synth_only 0 place_only 0 \
            reuse_synth 0 place_min_wns 0.08 min_wns 0.0 min_tns 0.0 \
            min_whs 0.0 min_ths 0.0 max_lut 90000 \
            max_lut_memory 8000 max_clb_percent 85.0 max_uram 48 \
            expected_uram 48 max_dsp 720 \
            place_max_congestion_level 4 max_failing_endpoints 0 \
            max_hold_failing_endpoints 0 \
            max_pulse_width_failing_endpoints 0 \
            max_unconstrained_paths 0 max_unclocked_fdre 0 \
            max_accel_none_delay_endpoints 0 \
            max_accel_internal_none_fdre_endpoints 0 \
            max_route_errors 0 max_drc_errors 0 \
            max_drc_critical_warnings 0 implementation_stage post_route \
            qualification_status UNQUALIFIED formal_release_qualified 0 \
            release_eligible 0 \
            qualification_reason \
                resumed_route_only_without_fresh_synth_opt_place_or_physopt \
            resume_system_route_only 1 resume_managed_route 1 \
            resume_fresh_synth 0 resume_fresh_opt 0 resume_fresh_place 0 \
            resume_fresh_physopt 0 resume_fresh_route 1 \
            resume_prior_stage_hashes_stable 1 \
            resume_design_inputs_equal_source_git 1 \
            resume_place_gate_rechecked 1 resume_route_gate_passed 1 \
            resume_source_git_sha $::system_route_resume::source_git_sha \
            resume_source_build_dir [dict get $bundle source_build_dir] \
            resume_source_xpr_sha256 \
                [dict get $::system_route_resume::expected_sha256 xpr] \
            resume_source_metadata_sha256 \
                [dict get $::system_route_resume::expected_sha256 source_metadata] \
            resume_source_report_metadata_sha256 \
                [dict get $::system_route_resume::expected_sha256 source_report_metadata] \
            resume_source_failed_place_gate_sha256 \
                [dict get $::system_route_resume::expected_sha256 source_failed_place_gate] \
            resume_source_synth_sha256 \
                [dict get $::system_route_resume::expected_sha256 synth] \
            resume_source_opt_sha256 \
                [dict get $::system_route_resume::expected_sha256 opt] \
            resume_source_placed_sha256 \
                [dict get $::system_route_resume::expected_sha256 placed] \
            resume_source_physopt_sha256 \
                [dict get $::system_route_resume::expected_sha256 physopt] \
            resume_routed_sha256 $routed_sha256 \
            resume_place_gate_sha256 \
                [::conv_accel_build::sha256_file $place_gate] \
            resume_route_gate_sha256 \
                [::conv_accel_build::sha256_file $impl_gate] \
            resume_place_accel_internal_none_fdre_endpoints \
                [dict get $place_metrics accel_internal_none_fdre_endpoints] \
            resume_route_accel_internal_none_fdre_endpoints \
                [dict get $impl_metrics accel_internal_none_fdre_endpoints] \
            resume_bit_sha256 [::conv_accel_build::sha256_file $bit_file] \
            resume_xsa_sha256 [::conv_accel_build::sha256_file $xsa_file] \
            resume_git_root [dict get $resume_start_git git_root] \
            resume_git_sha [dict get $resume_start_git git_sha] \
            resume_git_dirty [dict get $resume_start_git git_dirty] \
            resume_git_sha_end [dict get $resume_end_git git_sha] \
            resume_git_dirty_end [dict get $resume_end_git git_dirty] \
            resume_provenance_stable 1 \
            resume_script_sha256 \
                [::conv_accel_build::sha256_file [file normalize [info script]]] \
            resume_vivado_version [version -short]] {
        dict set metadata $key $value
    }
    ::conv_accel_build::write_build_metadata $metadata_temporary \
        abi_v2_frequency_sweep_125 $metadata
    ::conv_accel_build::write_sha256_manifest $final_manifest \
        [list $bit_file $xsa_file]
    file rename -force -- $metadata_temporary $final_metadata
} publication_error publication_options]

if {$publication_failed} {
    catch {close_design}
    catch {close_project}
    ::conv_accel_build::remove_stale_publications \
        [dict get $bundle source_build_dir] \
        [list $bit_file $xsa_file $final_manifest $metadata_temporary]
    return -options $publication_options $publication_error
}

close_project
puts "=== UNQUALIFIED 125 MHz full-system route-only resume complete ==="
puts "Source hardware Git SHA: $::system_route_resume::source_git_sha"
puts "Resume tooling Git SHA: [dict get $resume_start_git git_sha]"
puts "Routed DCP: $routed_dcp"
puts "BIT: $bit_file"
puts "XSA: $xsa_file"
puts "Metadata: $final_metadata"
puts "SHA256 manifest: $final_manifest"

# Shared build profiles, report gates, metadata, and artifact hashing.
# This file intentionally uses only Tcl core commands so it can be checked with
# tclsh without launching Vivado.

namespace eval ::conv_accel_build {
    variable profile_names {
        abi_v2_release
        abi_v2_release_200
        abi_v2_ablation_200_a0
        abi_v2_ablation_200_a1
        abi_v2_ablation_200_a2
        legacy_r18c8_debug
    }
}

proc ::conv_accel_build::profile_names {} {
    variable profile_names
    return $profile_names
}

proc ::conv_accel_build::profile_defaults {name} {
    switch -- $name {
        abi_v2_release -
        abi_v2_release_200 -
        abi_v2_ablation_200_a0 -
        abi_v2_ablation_200_a1 -
        abi_v2_ablation_200_a2 {
            set values [dict create \
                board_part xilinx.com:kv260_som:part0:1.4 \
                board_connection [list som240_1_connector \
                    xilinx.com:kv260_carrier:som240_1_connector:1.3] \
                pl_clock_mhz 100 weight_dma_mm2s_burst 64 \
                rows 18 cols 16 k_tile 18 cout_tile 32 \
                enable_column_psum 0 enable_packed_hwc_ofm 1 \
                enable_layer_tile_sequencer 1 enable_layer_long_hwc_ifm 1 \
                enable_tagged_context 1 enable_weight_preload 1 \
                enable_fast_context_handoff 1 enable_detailed_trace 0 \
                enable_legacy_gpio_status 0 \
                ifm_banks 2 ifm_fifo_depth 1024 ifm_fifo_aw 10 \
                psum_fifo_depth 256 psum_fifo_aw 8 \
                hwc_cache_aw 16 hwc_cache_depth 43264 \
                hwc_cache_stripes 4 hwc_cache_use_uram 1 \
                ifm_epoch_use_uram 1 \
                materialized_cache_aw 15 materialized_cache_depth 32768 \
                tail_cycles 1 enforce_gates 1 \
                ooc_max_lut 83000 ooc_max_logic_lut 72000 \
                ooc_max_lut_memory 8000 ooc_max_clb_percent 85.0 \
                ooc_max_bram 90 ooc_max_uram 48 ooc_max_dsp 720 \
                ooc_min_wns 0.5 ooc_min_tns 0.0 \
                ooc_expected_uram {} ooc_max_congestion_level {} \
                ooc_min_whs {} ooc_min_ths {} \
                ooc_max_failing_endpoints {} \
                ooc_max_hold_failing_endpoints {} \
                ooc_max_pulse_width_failing_endpoints {} \
                ooc_max_unconstrained_paths 0 ooc_max_unclocked_fdre 0 \
                ooc_max_internal_none_fdre_endpoints 0 \
                system_max_lut 90000 system_max_lut_memory 8000 \
                system_max_clb_percent 90.0 \
                system_place_min_wns 0.3 \
                system_place_max_congestion_level 4 \
                system_max_bram {} \
                system_max_uram {} system_expected_uram {} \
                system_max_dsp 720 \
                system_min_wns 0.1 system_min_tns 0.0 \
                system_min_whs 0.0 system_min_ths 0.0 \
                system_max_failing_endpoints 0 \
                system_max_hold_failing_endpoints 0 \
                system_max_pulse_width_failing_endpoints 0 \
                system_max_unconstrained_paths 0 \
                system_max_unclocked_fdre 0 \
                system_max_accel_none_delay_endpoints 0 \
                system_max_route_errors 0 system_max_drc_errors 0 \
                system_max_drc_critical_warnings 0]
            if {$name eq "abi_v2_release_200" ||
                [string match "abi_v2_ablation_200_*" $name]} {
                dict set values pl_clock_mhz 200
                dict set values ooc_min_wns 0.0
                dict set values ooc_expected_uram 48
                dict set values ooc_max_congestion_level 4
                dict set values ooc_min_whs 0.0
                dict set values ooc_min_ths 0.0
                dict set values ooc_max_failing_endpoints 0
                dict set values ooc_max_hold_failing_endpoints 0
                dict set values ooc_max_pulse_width_failing_endpoints 0
                dict set values system_max_clb_percent 85.0
                dict set values system_place_min_wns 0.0
                dict set values system_min_wns 0.0
                dict set values system_max_uram 48
                dict set values system_expected_uram 48
            }
            # Publication-ineligible 200 MHz profiles differ from the r5
            # release in exactly the feature under study.  Tagged context is
            # held constant so A0->A1 isolates the long-HWC materializer,
            # A1->A2 isolates weight preload, and A2->r5 isolates fast
            # context handoff.
            switch -- $name {
                abi_v2_ablation_200_a0 {
                    dict set values enable_layer_long_hwc_ifm 0
                    dict set values enable_weight_preload 0
                    dict set values enable_fast_context_handoff 0
                }
                abi_v2_ablation_200_a1 {
                    dict set values enable_weight_preload 0
                    dict set values enable_fast_context_handoff 0
                }
                abi_v2_ablation_200_a2 {
                    dict set values enable_fast_context_handoff 0
                }
            }
            if {[string match "abi_v2_ablation_200_*" $name]} {
                # Exact URAM equality is a release-topology invariant, not an
                # implementation-quality gate.  In particular A0 removes the
                # materialized-HWC store by construction, so requiring the r5
                # release count would reject the intended ablation.  Preserve
                # the release ceiling while reporting the measured delta.
                dict set values ooc_expected_uram {}
                dict set values system_expected_uram {}
            }
            return $values
        }
        legacy_r18c8_debug {
            # Reproduces the explicitly supported 18x8 byte-address debug
            # path.  Gates are opt-in because historical debug builds predate
            # the ABI-v2 release budgets.
            return [dict create \
                pl_clock_mhz 100 weight_dma_mm2s_burst 8 \
                rows 18 cols 8 k_tile 18 cout_tile 16 \
                enable_column_psum 0 enable_packed_hwc_ofm 0 \
                enable_layer_tile_sequencer 0 enable_layer_long_hwc_ifm 0 \
                enable_tagged_context 0 enable_weight_preload 0 \
                enable_fast_context_handoff 0 enable_detailed_trace 1 \
                enable_legacy_gpio_status 1 \
                ifm_banks 2 ifm_fifo_depth 1024 ifm_fifo_aw 10 \
                psum_fifo_depth 1024 psum_fifo_aw 10 \
                hwc_cache_aw 16 hwc_cache_depth 43264 \
                hwc_cache_stripes 4 hwc_cache_use_uram 1 \
                ifm_epoch_use_uram 0 \
                materialized_cache_aw 15 materialized_cache_depth 32768 \
                tail_cycles 1 enforce_gates 0 \
                ooc_max_lut {} ooc_max_logic_lut {} \
                ooc_max_lut_memory {} ooc_max_clb_percent {} \
                ooc_max_bram {} ooc_max_uram {} \
                ooc_max_dsp {} ooc_min_wns {} ooc_min_tns {} \
                ooc_expected_uram {} ooc_max_congestion_level {} \
                ooc_min_whs {} ooc_min_ths {} \
                ooc_max_failing_endpoints {} \
                ooc_max_hold_failing_endpoints {} \
                ooc_max_pulse_width_failing_endpoints {} \
                ooc_max_unconstrained_paths {} ooc_max_unclocked_fdre {} \
                ooc_max_internal_none_fdre_endpoints {} \
                system_max_lut {} system_max_lut_memory {} \
                system_max_clb_percent {} system_place_min_wns {} \
                system_place_max_congestion_level {} system_max_bram {} \
                system_max_uram {} system_expected_uram {} system_max_dsp {} \
                system_min_wns {} system_min_tns {} \
                system_min_whs {} system_min_ths {} \
                system_max_failing_endpoints {} \
                system_max_hold_failing_endpoints {} \
                system_max_pulse_width_failing_endpoints {} \
                system_max_unconstrained_paths {} \
                system_max_unclocked_fdre {} \
                system_max_accel_none_delay_endpoints {} \
                system_max_route_errors {} system_max_drc_errors {} \
                system_max_drc_critical_warnings {}]
        }
        default {
            error "unknown build profile '$name'; expected one of: [join [profile_names] {, }]"
        }
    }
}

proc ::conv_accel_build::is_abi_v2_release_profile {name} {
    return [expr {$name eq "abi_v2_release" ||
        $name eq "abi_v2_release_200"}]
}

proc ::conv_accel_build::is_abi_v2_ablation_profile {name} {
    return [expr {[string match "abi_v2_ablation_200_*" $name] &&
        $name in [profile_names]}]
}

# Gated profiles share the immutable KV260 topology, 200 MHz implementation
# flow, clean provenance requirement, and report gates.  Only the two formal
# release identities may be consumed by release/candidate tooling.
proc ::conv_accel_build::is_abi_v2_gated_profile {name} {
    return [expr {[is_abi_v2_release_profile $name] ||
        [is_abi_v2_ablation_profile $name]}]
}

proc ::conv_accel_build::is_abi_v2_200_profile {name} {
    return [expr {$name eq "abi_v2_release_200" ||
        [is_abi_v2_ablation_profile $name]}]
}

proc ::conv_accel_build::validate_development_clock_mhz {mhz} {
    if {$mhz ni {125 150 175}} {
        error "development clock must be one of 125, 150, or 175 MHz"
    }
    return $mhz
}

proc ::conv_accel_build::frequency_sweep_profile_name {mhz} {
    validate_development_clock_mhz $mhz
    return "abi_v2_frequency_sweep_${mhz}"
}

proc ::conv_accel_build::clock_hz_from_mhz {mhz} {
    if {![finite_number $mhz] || $mhz <= 0} {
        error "PL clock must be a positive finite MHz value; got '$mhz'"
    }
    set hz [expr {wide(round(double($mhz) * 1000000.0))}]
    if {abs(double($hz) - double($mhz) * 1000000.0) > 0.001} {
        error "PL clock must resolve to an integer number of Hz; got '$mhz' MHz"
    }
    return $hz
}

proc ::conv_accel_build::clock_period_ns_from_mhz {mhz} {
    clock_hz_from_mhz $mhz
    return [expr {1000.0 / double($mhz)}]
}

# Development frequency sweeps use a proportional post-place margin instead
# of the fixed release margin.  Vivado 2022.2 stores periods at 1 ps
# resolution, so derive the one-percent margin from that same quantized period
# used by the generated XDC.  This gate is only an admission criterion for
# further implementation; formal release profiles retain their own limits.
proc ::conv_accel_build::development_post_place_min_wns {mhz} {
    set requested [clock_period_ns_from_mhz $mhz]
    set constrained [expr {round(double($requested) * 1000.0) / 1000.0}]
    return [expr {$constrained * 0.01}]
}

proc ::conv_accel_build::prescan_profile {args} {
    set profile ""
    for {set i 0} {$i < [llength $args]} {incr i} {
        if {[lindex $args $i] ne "-profile"} {
            continue
        }
        if {$i + 1 >= [llength $args]} {
            error "-profile requires a value"
        }
        set candidate [lindex $args [incr i]]
        if {$profile ne "" && $profile ne $candidate} {
            error "conflicting -profile values: $profile and $candidate"
        }
        set profile $candidate
    }
    if {$profile ne ""} {
        profile_defaults $profile
    }
    return $profile
}

proc ::conv_accel_build::apply_profile {name} {
    if {$name eq ""} {
        return
    }
    foreach {key value} [profile_defaults $name] {
        uplevel 1 [list set $key $value]
    }
}

proc ::conv_accel_build::validate_bool {name value} {
    if {$value != 0 && $value != 1} {
        error "$name must be 0 or 1"
    }
}

proc ::conv_accel_build::has_nonempty {args} {
    foreach value $args {
        if {$value ne ""} {
            return 1
        }
    }
    return 0
}

# Return every release-profile field whose effective value no longer matches
# the immutable profile definition.  Build front-ends call this after parsing
# all command-line options, so option order cannot bypass the contract.
proc ::conv_accel_build::locked_value_violations {expected actual keys} {
    set violations [list]
    foreach key $keys {
        if {![dict exists $expected $key]} {
            lappend violations "$key has no profile default"
        } elseif {![dict exists $actual $key]} {
            lappend violations "$key is missing from the effective configuration"
        } elseif {[dict get $actual $key] ne [dict get $expected $key]} {
            lappend violations "$key=[dict get $actual $key] expected=[dict get $expected $key]"
        }
    }
    return $violations
}

proc ::conv_accel_build::finite_number {value} {
    return [expr {[string is double -strict $value] &&
        ![regexp -nocase {(?:nan|inf)} $value]}]
}

# Release gates may be tightened but never removed or relaxed.  Empty profile
# limits are intentionally optional; supplying a finite value adds a gate.
proc ::conv_accel_build::gate_limit_relaxations {baseline actual keys} {
    set relaxations [list]
    foreach key $keys {
        if {![dict exists $baseline $key] || ![dict exists $actual $key]} {
            lappend relaxations "$key is missing"
            continue
        }
        set base [dict get $baseline $key]
        set candidate [dict get $actual $key]
        if {$candidate ne "" && ![finite_number $candidate]} {
            lappend relaxations "$key=$candidate is not a finite number"
            continue
        }
        if {$base eq ""} {
            continue
        }
        if {$candidate eq ""} {
            lappend relaxations "$key disables required limit $base"
            continue
        }
        if {[regexp {(^|_)max_} $key] && $candidate > $base} {
            lappend relaxations "$key=$candidate relaxes maximum $base"
        } elseif {[regexp {(^|_)min_} $key] && $candidate < $base} {
            lappend relaxations "$key=$candidate relaxes minimum $base"
        }
    }
    return $relaxations
}

proc ::conv_accel_build::require_no_violations {label violations} {
    if {[llength $violations] != 0} {
        error "$label contract violation(s): [join $violations {; }]"
    }
}

proc ::conv_accel_build::require_vivado_version {expected} {
    if {[llength [info commands version]] == 0} {
        error "Vivado version command is unavailable"
    }
    set actual [version -short]
    if {![string match "${expected}*" $actual]} {
        error "profiled builds require Vivado $expected; running $actual"
    }
}

proc ::conv_accel_build::require_xsim_fixtures {root} {
    set checker [file join $root tb prepare_xsim_fixtures.py]
    if {![file isfile $checker]} {
        error "XSIM fixture checker is missing: $checker"
    }
    set python_command {}
    if {[info exists ::env(CONV_ACCEL_PYTHON)] &&
        [string trim $::env(CONV_ACCEL_PYTHON)] ne ""} {
        set python_command [list $::env(CONV_ACCEL_PYTHON) -E]
    } elseif {[set launcher [auto_execok py]] ne ""} {
        set python_command [concat $launcher [list -3 -E]]
    } elseif {[set python3 [auto_execok python3]] ne ""} {
        set python_command [concat $python3 [list -E]]
    } elseif {[set python [auto_execok python]] ne ""} {
        set python_command [concat $python [list -E]]
    }
    if {[llength $python_command] == 0} {
        error "python is required to verify repository-local XSIM fixtures"
    }

    # Vivado's launcher prepends its private Python runtime and can export
    # PYTHONHOME/PYTHONPATH values that are incompatible with the selected
    # system interpreter.  Isolate only the checker subprocess, then restore
    # the parent environment unchanged.
    set saved_python_env [dict create]
    foreach name {PYTHONHOME PYTHONPATH} {
        if {[info exists ::env($name)]} {
            dict set saved_python_env $name $::env($name)
            unset ::env($name)
        }
    }
    set failed [catch {
        exec {*}$python_command $checker --check-only 2>@1
    } output]
    foreach name [dict keys $saved_python_env] {
        set ::env($name) [dict get $saved_python_env $name]
    }
    if {$failed} {
        error "XSIM fixture integrity check failed: $output"
    }
    puts [string trim $output]
}

proc ::conv_accel_build::git_provenance {root} {
    set git [auto_execok git]
    if {$git eq ""} {
        error "git is required to record build provenance"
    }
    set normalized_root [file normalize $root]
    if {[catch {exec {*}$git -C $normalized_root rev-parse --show-toplevel} top]} {
        error "cannot identify Git worktree for $normalized_root: $top"
    }
    if {[catch {exec {*}$git -C $normalized_root rev-parse HEAD} sha]} {
        error "cannot identify Git SHA for $normalized_root: $sha"
    }
    if {[catch {exec {*}$git -C $normalized_root status --porcelain=v1 --untracked-files=normal} status]} {
        error "cannot read Git dirty state for $normalized_root: $status"
    }
    return [dict create \
        git_root [file normalize [string trim $top]] \
        git_sha [string trim $sha] \
        git_dirty [expr {[string trim $status] eq "" ? 0 : 1}]]
}

proc ::conv_accel_build::git_provenance_valid {provenance} {
    foreach key {git_root git_sha git_dirty} {
        if {![dict exists $provenance $key]} {
            return 0
        }
    }
    return [expr {
        [string trim [dict get $provenance git_root]] ne "" &&
        [regexp {^[0-9a-f]{40}$} [dict get $provenance git_sha]] &&
        ([dict get $provenance git_dirty] == 0 ||
         [dict get $provenance git_dirty] == 1)
    }]
}

proc ::conv_accel_build::git_provenance_matches {expected actual} {
    if {![git_provenance_valid $expected] ||
        ![git_provenance_valid $actual]} {
        return 0
    }
    return [expr {
        [string equal -nocase [dict get $expected git_root] \
            [dict get $actual git_root]] &&
        [dict get $expected git_sha] eq [dict get $actual git_sha] &&
        [dict get $expected git_dirty] == [dict get $actual git_dirty]
    }]
}

proc ::conv_accel_build::git_provenance_is_clean {provenance} {
    return [expr {
        [git_provenance_valid $provenance] &&
        ![dict get $provenance git_dirty]
    }]
}

proc ::conv_accel_build::require_stable_clean_git {root expected label} {
    set actual [git_provenance $root]
    if {![git_provenance_is_clean $expected] ||
        ![git_provenance_matches $expected $actual]} {
        error "$label Git provenance changed or became dirty: start=$expected current=$actual"
    }
    return $actual
}

proc ::conv_accel_build::require_clean_git {root} {
    set provenance [git_provenance $root]
    if {[dict get $provenance git_dirty]} {
        error "formal abi_v2_release candidates require a clean Git worktree at [dict get $provenance git_sha]"
    }
    return $provenance
}

# Build front-ends never publish directly into the immutable release tree.
# Publication is a separate, post-signoff operation, so no profile (including
# a legacy/debug invocation) may use release/ as scratch project storage.
proc ::conv_accel_build::require_nonpublication_build_dir {root build_dir} {
    set normalized_release [string trimright \
        [string map {\\ /} [file normalize [file join $root release]]] /]
    set normalized_build [string trimright \
        [string map {\\ /} [file normalize $build_dir]] /]
    set release_prefix "${normalized_release}/"
    if {[string equal -nocase $normalized_build $normalized_release] ||
        [string equal -nocase [string range $normalized_build 0 \
            [expr {[string length $release_prefix] - 1}]] $release_prefix]} {
        error "build directory must not overlap the immutable release tree: $normalized_build"
    }
    return [file normalize $build_dir]
}

# Formal ABI-v2 implementation projects live in a dedicated, top-level build
# directory.  Keeping the directory both visibly profile-specific and outside
# release/ prevents a mistyped -build_dir from deleting or overwriting the
# immutable 18x8 bit/XSA artifacts before the new candidate has passed every
# board gate.
proc ::conv_accel_build::require_abi_v2_build_dir {root build_dir} {
    set build_dir [require_nonpublication_build_dir $root $build_dir]
    set normalized_root [string trimright \
        [string map {\\ /} [file normalize $root]] /]
    set normalized_build [string trimright \
        [string map {\\ /} [file normalize $build_dir]] /]
    set root_prefix "${normalized_root}/"

    if {![string equal -nocase [string range $normalized_build 0 \
            [expr {[string length $root_prefix] - 1}]] $root_prefix]} {
        error "abi_v2_release build directory must be inside the repository: $normalized_build"
    }
    set relative [string range $normalized_build [string length $root_prefix] end]
    if {$relative eq "" || [string first / $relative] >= 0} {
        error "abi_v2_release build directory must be a dedicated top-level directory: $normalized_build"
    }
    if {![regexp -nocase {^build_[a-z0-9_.-]*abi_v2_(?:release|ablation)[a-z0-9_.-]*$} \
            $relative]} {
        error "gated ABI-v2 build directory must name release or ablation: $normalized_build"
    }
    if {[regexp -nocase {legacy} $relative]} {
        error "gated ABI-v2 build directory must not name a legacy artifact: $normalized_build"
    }
    return [file normalize $build_dir]
}

proc ::conv_accel_build::require_frequency_sweep_build_dir {root build_dir mhz} {
    validate_development_clock_mhz $mhz
    set build_dir [require_nonpublication_build_dir $root $build_dir]
    set normalized_root [string trimright \
        [string map {\\ /} [file normalize $root]] /]
    set normalized_build [string trimright \
        [string map {\\ /} [file normalize $build_dir]] /]
    set root_prefix "${normalized_root}/"
    if {![string equal -nocase [string range $normalized_build 0 \
            [expr {[string length $root_prefix] - 1}]] $root_prefix]} {
        error "frequency-sweep build directory must be inside the repository"
    }
    set relative [string range $normalized_build [string length $root_prefix] end]
    if {[string first / $relative] >= 0 ||
        ![regexp -nocase \
            "^build_.*abi_v2_frequency_sweep_${mhz}.*$" $relative]} {
        error "frequency-sweep build directory must be a dedicated build_*abi_v2_frequency_sweep_${mhz}* path"
    }
    return [file normalize $build_dir]
}

proc ::conv_accel_build::remove_stale_publications {build_root paths} {
    set normalized_root [string map {\\ /} [file normalize $build_root]]
    set root_prefix "${normalized_root}/"
    foreach path $paths {
        set normalized_path [string map {\\ /} [file normalize $path]]
        if {![string equal -nocase [string range $normalized_path 0 \
                [expr {[string length $root_prefix] - 1}]] $root_prefix]} {
            error "refusing to remove publication outside build directory: $normalized_path"
        }
        if {![file exists $normalized_path]} {
            continue
        }
        if {[file isdirectory $normalized_path]} {
            error "refusing to remove publication directory: $normalized_path"
        }
        puts "Removing stale publication: $normalized_path"
        file delete -force -- $normalized_path
    }
}

proc ::conv_accel_build::read_text {path} {
    if {![file isfile $path]} {
        error "report not found: $path"
    }
    set fh [open $path r]
    set text [read $fh]
    close $fh
    return $text
}

proc ::conv_accel_build::parse_utilization {text} {
    set metrics [dict create]
    foreach {key pattern} {
        lut        {^\|\s*CLB LUTs\*?\s*\|\s*([0-9.]+)\s*\|}
        logic_lut  {^\|\s*LUT as Logic\s*\|\s*([0-9.]+)\s*\|}
        lut_memory {^\|\s*LUT as Memory\s*\|\s*([0-9.]+)\s*\|}
        bram       {^\|\s*Block RAM Tile\s*\|\s*([0-9.]+)\s*\|}
        uram       {^\|\s*URAM\s*\|\s*([0-9.]+)\s*\|}
        dsp        {^\|\s*DSPs\s*\|\s*([0-9.]+)\s*\|}
    } {
        if {[regexp -line -- $pattern $text -> value]} {
            dict set metrics $key $value
        }
    }
    if {[regexp -line -- \
            {^\|\s*CLB\s*\|\s*([0-9.]+)\s*\|[^|]*\|[^|]*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)\s*\|} \
            $text -> used available percent]} {
        dict set metrics clb_sites $used
        dict set metrics clb_available $available
        dict set metrics clb_percent $percent
    }
    return $metrics
}

proc ::conv_accel_build::parse_timing {text} {
    set metrics [dict create]
    if {[regexp -line -- \
            {checking\s+unconstrained_internal_endpoints\s+\(([0-9]+)\)} \
            $text -> count]} {
        dict set metrics unconstrained_paths $count
    }
    if {[regexp -line -- {checking\s+no_clock\s+\(([0-9]+)\)} \
            $text -> count]} {
        # Keep Vivado's structural no_clock check, but do not treat it as a
        # substitute for the scoped infinite-slack path audit below.  A path
        # may have a clocked destination and still originate at an unclocked
        # internal primitive pin.
        dict set metrics unclocked_fdre $count
    }
    set saw_header 0
    foreach line [split $text "\n"] {
        if {[string first "WNS(ns)" $line] >= 0 &&
            [string first "TNS(ns)" $line] >= 0} {
            set saw_header 1
            continue
        }
        if {$saw_header} {
            set fields [regexp -all -inline -- \
                {[-+]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)} $line]
            if {[llength $fields] >= 4} {
                dict set metrics wns [lindex $fields 0]
                dict set metrics tns [lindex $fields 1]
                dict set metrics failing_endpoints [lindex $fields 2]
                if {[llength $fields] >= 12} {
                    dict set metrics whs [lindex $fields 4]
                    dict set metrics ths [lindex $fields 5]
                    dict set metrics hold_failing_endpoints \
                        [lindex $fields 6]
                    dict set metrics pulse_width_failing_endpoints \
                        [lindex $fields 10]
                }
                return $metrics
            }
        }
    }
    return $metrics
}

# Audit a supplied FDRE/D endpoint collection for max-delay paths whose
# startpoint is an internal primitive pin with no source clock.  The endpoint
# collection may be hierarchy-scoped, but all_fanin and get_timing_paths are
# deliberately executed without -cells/-hsc: their timing graph is always the
# complete open design.  This distinction prevents a hierarchy input or an
# implementation-primitive interior pin created by report_timing_summary
# -cells from becoming an artificial (none) startpoint.
#
# Top-level input ports are removed from the -from collection before timing
# paths are requested.  This both permits legal OOC input paths and prevents a
# top port from hiding a second, internal blank-clock source selected for the
# same endpoint.  Hitting any query cap is an error, never an apparent zero.
proc ::conv_accel_build::collect_internal_none_fdre_audit_values {fdre_d_pins \
        {sample_limit 50} {endpoint_batch_size 2048} {path_cap 65536}} {
    foreach {name value allow_zero} [list \
            sample_limit $sample_limit 1 \
            endpoint_batch_size $endpoint_batch_size 0 \
            path_cap $path_cap 0] {
        if {![string is integer -strict $value] ||
            ($allow_zero ? $value < 0 : $value <= 0)} {
            error "$name must be [expr {$allow_zero ? {a non-negative} : {a positive}}] integer; got '$value'"
        }
    }
    if {$path_cap <= $endpoint_batch_size} {
        error "path_cap=$path_cap must exceed endpoint_batch_size=$endpoint_batch_size so truncation remains detectable"
    }

    set fdre_d_count [llength $fdre_d_pins]
    set unexpected_endpoints [filter $fdre_d_pins \
        {CLASS != pin || REF_PIN_NAME != D}]
    if {[llength $unexpected_endpoints] != 0} {
        error "FDRE/D audit received unexpected endpoint objects: $unexpected_endpoints"
    }

    set fanin_start_count 0
    set top_port_start_count 0
    set internal_start_count 0
    set fabric_register_internal_start_count 0
    set non_fabric_internal_start_count 0
    set clocked_internal_start_count 0
    set unclocked_internal_start_count 0
    set timing_path_count 0
    set source_group_upper_bound [expr {[llength [get_clocks]] + 1}]
    set violating_endpoints [dict create]
    set samples [list]

    if {$fdre_d_count != 0} {
        set fanin_starts [all_fanin -flat -trace_arcs timing \
            -startpoints_only -to $fdre_d_pins]
        set fanin_start_count [llength $fanin_starts]
        set top_port_starts [filter $fanin_starts {CLASS == port}]
        set internal_starts [filter $fanin_starts {CLASS != port}]
        set top_port_start_count [llength $top_port_starts]
        set internal_start_count [llength $internal_starts]

        # With -flat, every non-port timing startpoint must be a primitive pin.
        # A hierarchy-boundary pin here would mean the query was not actually
        # full-design and must fail instead of reintroducing the scoped-report
        # false positive.
        set non_pin_internal [filter $internal_starts {CLASS != pin}]
        if {[llength $non_pin_internal] != 0 ||
            $fanin_start_count !=
                ($top_port_start_count + $internal_start_count)} {
            error "FDRE fanin audit encountered unexpected non-port startpoint classes: $non_pin_internal"
        }

        # For a fabric register, all_fanin returns the primitive clock pin as
        # the timing startpoint (for example FDRE/C), not its Q pin.  Limit
        # the supplemental audit to real FD*/LD* sequential primitives.
        # Vivado's expanded DSP/RAM timing models also expose internal nodes
        # such as DSP_A_B_DATA/A2_DATA and RAMC/CLK as apparent flat fan-in
        # startpoints.  Forcing a path from those macro-interior nodes creates
        # an artificial blank STARTPOINT_CLOCK even though check_timing and
        # the natural full-design timing graph see the macro clock correctly.
        # They are therefore recorded and excluded, not treated as launches.
        #
        # Query the clock relationship on each eligible full-design launch
        # pin directly.  Selecting a worst path first and inspecting
        # STARTPOINT_CLOCK afterwards is not safe: a finite-slack path from
        # another clocked source can hide the +inf path from an unclocked
        # source at the same destination.
        set unclocked_internal_starts [list]
        foreach internal_start $internal_starts {
            set start_cells [get_cells -quiet -of_objects $internal_start]
            if {[llength $start_cells] != 1} {
                error "internal startpoint '$internal_start' did not resolve exactly one owner cell"
            }
            set start_ref [get_property REF_NAME $start_cells]
            set start_is_sequential [get_property IS_SEQUENTIAL $start_cells]
            if {$start_is_sequential ne "1" ||
                ![regexp {^(FD|LD)} $start_ref]} {
                incr non_fabric_internal_start_count
                continue
            }
            incr fabric_register_internal_start_count
            set source_clocks [get_clocks -quiet -of_objects $internal_start]
            if {[llength $source_clocks] == 0} {
                lappend unclocked_internal_starts $internal_start
                incr unclocked_internal_start_count
            } else {
                incr clocked_internal_start_count
            }
        }
        if {$fabric_register_internal_start_count !=
            ($clocked_internal_start_count +
             $unclocked_internal_start_count)} {
            error "FDRE fanin clock classification did not cover every fabric-register startpoint"
        }
        if {$internal_start_count !=
            ($fabric_register_internal_start_count +
             $non_fabric_internal_start_count)} {
            error "FDRE fanin owner classification did not cover every internal startpoint"
        }

        if {$unclocked_internal_start_count != 0} {
            for {set first 0} {$first < $fdre_d_count} \
                    {incr first $endpoint_batch_size} {
                set endpoint_batch [list]
                set last [expr {min($fdre_d_count,
                    $first + $endpoint_batch_size)}]
                for {set index $first} {$index < $last} {incr index} {
                    lappend endpoint_batch [lindex $fdre_d_pins $index]
                }

                set paths [get_timing_paths -delay_type max \
                    -sort_by group -nworst 1 -max_paths $path_cap \
                    -from $unclocked_internal_starts -to $endpoint_batch]
                set batch_path_count [llength $paths]
                incr timing_path_count $batch_path_count
                if {$batch_path_count >= $path_cap} {
                    error "FDRE timing query reached max_paths=$path_cap for endpoint batch beginning at $first"
                }

                foreach path $paths {
                    set start_clock [get_property STARTPOINT_CLOCK $path]
                    if {[string trim $start_clock] ne ""} {
                        error "blank-clock timing query returned a path clocked by '$start_clock'"
                    }
                    set endpoint_pin [get_property ENDPOINT_PIN $path]
                    set startpoint_pin [get_property STARTPOINT_PIN $path]
                    if {[llength $endpoint_pin] != 1 ||
                        [llength $startpoint_pin] != 1} {
                        error "blank-clock timing path did not resolve exactly one startpoint and endpoint pin"
                    }
                    set endpoint_name [get_property NAME $endpoint_pin]
                    set startpoint_name [get_property NAME $startpoint_pin]
                    if {$endpoint_name eq "" || $startpoint_name eq ""} {
                        error "blank-clock timing path has an unnamed startpoint or endpoint"
                    }
                    if {[dict exists $violating_endpoints $endpoint_name]} {
                        continue
                    }
                    dict set violating_endpoints $endpoint_name 1
                    if {[llength $samples] < $sample_limit} {
                        lappend samples [list endpoint $endpoint_name \
                            startpoint $startpoint_name \
                            slack [get_property SLACK $path]]
                    }
                }
            }
        }
    }

    return [dict create \
        fdre_d_endpoints $fdre_d_count \
        fanin_startpoints $fanin_start_count \
        top_port_startpoints_excluded $top_port_start_count \
        internal_pin_startpoints $internal_start_count \
        fabric_register_internal_pin_startpoints \
            $fabric_register_internal_start_count \
        non_fabric_internal_pin_startpoints_excluded \
            $non_fabric_internal_start_count \
        clocked_internal_pin_startpoints $clocked_internal_start_count \
        unclocked_internal_pin_startpoints $unclocked_internal_start_count \
        timing_paths_examined $timing_path_count \
        source_group_upper_bound $source_group_upper_bound \
        sample_limit $sample_limit sample_count [llength $samples] \
        internal_none_fdre_endpoints [dict size $violating_endpoints] \
        samples $samples]
}

proc ::conv_accel_build::write_internal_none_fdre_audit_report {report_path \
        audit_name metric_name audit_failed audit_error audit_values} {
    if {![regexp {^[a-z][a-z0-9_]*$} $audit_name] ||
        ![regexp {^[a-z][a-z0-9_]*$} $metric_name]} {
        error "invalid internal-none audit or metric name: audit='$audit_name' metric='$metric_name'"
    }

    file mkdir [file dirname $report_path]
    set report_fh [open $report_path w]
    puts $report_fh "audit=$audit_name"
    puts $report_fh "format_version=1"
    if {$audit_failed} {
        puts $report_fh "status=ERROR"
        puts $report_fh "error=[list $audit_error]"
        close $report_fh
        return
    }

    puts $report_fh "status=COMPLETE"
    foreach key {query_scope endpoint_scope accelerator_cell} {
        if {[dict exists $audit_values $key]} {
            puts $report_fh "$key=[dict get $audit_values $key]"
        }
    }
    foreach key {
        fdre_d_endpoints fanin_startpoints top_port_startpoints_excluded
        internal_pin_startpoints fabric_register_internal_pin_startpoints
        non_fabric_internal_pin_startpoints_excluded
        clocked_internal_pin_startpoints
        unclocked_internal_pin_startpoints timing_paths_examined
        source_group_upper_bound
        sample_limit sample_count
    } {
        puts $report_fh "$key=[dict get $audit_values $key]"
    }
    puts $report_fh "metric.$metric_name=[dict get $audit_values internal_none_fdre_endpoints]"
    set sample_index 0
    foreach sample [dict get $audit_values samples] {
        puts $report_fh "sample.$sample_index=$sample"
        incr sample_index
    }
    close $report_fh
}

# This procedure is defined in the otherwise pure-Tcl common file so focused
# Vivado fixtures can exercise exactly the implementation used by the OOC
# build.  Vivado commands are resolved only when the procedure is invoked.
proc ::conv_accel_build::write_ooc_internal_none_fdre_audit {report_path \
        {sample_limit 50} {endpoint_batch_size 2048} {path_cap 65536}} {
    set audit_failed [catch {
        set fdre_cells [get_cells -quiet -hier -filter {REF_NAME == FDRE}]
        set fdre_d_pins [get_pins -quiet -of_objects $fdre_cells \
            -filter {REF_PIN_NAME == D}]
        set audit_values [collect_internal_none_fdre_audit_values \
            $fdre_d_pins $sample_limit $endpoint_batch_size $path_cap]
        dict set audit_values query_scope full_design
        dict set audit_values endpoint_scope all_fdre_d
    } audit_error audit_options]
    write_internal_none_fdre_audit_report $report_path \
        ooc_internal_none_fdre ooc_internal_none_fdre_endpoints \
        $audit_failed $audit_error \
        [expr {$audit_failed ? [dict create] : $audit_values}]
    if {$audit_failed} {
        return -options $audit_options $audit_error
    }
    return [dict create ooc_internal_none_fdre_endpoints \
        [dict get $audit_values internal_none_fdre_endpoints]]
}

# Resolve the accelerator hierarchy only to select its FDRE/D destinations.
# Fan-in discovery and timing queries stay full-design, so a clocked source in
# the parent PS/DMA/AXI fabric remains a clocked source rather than becoming a
# synthetic boundary (none) path.  An absent/ambiguous hierarchy or an empty
# endpoint set is a hard error and is recorded in the audit before returning.
proc ::conv_accel_build::write_system_accel_internal_none_fdre_audit {
        report_path {accelerator_pattern "*/accel/inst"} {sample_limit 50}
        {endpoint_batch_size 2048} {path_cap 65536}} {
    set audit_failed [catch {
        set accelerator_cells [get_cells -quiet -hier -filter \
            "NAME =~ $accelerator_pattern"]
        if {[llength $accelerator_cells] != 1} {
            error "accelerator FDRE/D audit resolved [llength $accelerator_cells] cells for '$accelerator_pattern'; expected exactly one"
        }
        set accelerator_cell [get_property NAME $accelerator_cells]
        if {$accelerator_cell eq ""} {
            error "accelerator FDRE/D audit resolved an unnamed hierarchy cell"
        }
        set accelerator_fdre_cells [get_cells -quiet -hier -filter \
            "REF_NAME == FDRE && NAME =~ $accelerator_cell/*"]
        set accelerator_fdre_d_pins [get_pins -quiet \
            -of_objects $accelerator_fdre_cells \
            -filter {REF_PIN_NAME == D}]
        if {[llength $accelerator_fdre_d_pins] == 0} {
            error "accelerator FDRE/D audit found no FDRE/D endpoints below '$accelerator_cell'"
        }
        set audit_values [collect_internal_none_fdre_audit_values \
            $accelerator_fdre_d_pins $sample_limit \
            $endpoint_batch_size $path_cap]
        dict set audit_values query_scope full_design
        dict set audit_values endpoint_scope accelerator_fdre_d
        dict set audit_values accelerator_cell $accelerator_cell
    } audit_error audit_options]
    write_internal_none_fdre_audit_report $report_path \
        system_accel_internal_none_fdre \
        accel_internal_none_fdre_endpoints $audit_failed $audit_error \
        [expr {$audit_failed ? [dict create] : $audit_values}]
    if {$audit_failed} {
        return -options $audit_options $audit_error
    }
    return [dict create accel_internal_none_fdre_endpoints \
        [dict get $audit_values internal_none_fdre_endpoints]]
}

proc ::conv_accel_build::parse_ooc_internal_none_fdre_audit {text} {
    set required [dict create \
        audit ooc_internal_none_fdre \
        format_version 1 \
        status COMPLETE]
    set seen [dict create]
    foreach line [split $text "\n"] {
        if {![regexp {^([^=]+)=(.*)$} [string trimright $line "\r"] \
                -> key value]} {
            continue
        }
        if {$key in {audit format_version status
                metric.ooc_internal_none_fdre_endpoints}} {
            if {[dict exists $seen $key]} {
                error "OOC internal-none audit contains duplicate '$key' fields"
            }
            dict set seen $key $value
        }
    }
    foreach {key expected} $required {
        if {![dict exists $seen $key]} {
            error "OOC internal-none audit is missing '$key'"
        }
        if {[dict get $seen $key] ne $expected} {
            error "OOC internal-none audit $key=[dict get $seen $key], expected $expected"
        }
    }
    set metric_key metric.ooc_internal_none_fdre_endpoints
    if {![dict exists $seen $metric_key]} {
        error "OOC internal-none audit is missing '$metric_key'"
    }
    set count [dict get $seen $metric_key]
    if {![string is integer -strict $count] || $count < 0} {
        error "OOC internal-none audit has invalid endpoint count '$count'"
    }
    return [dict create ooc_internal_none_fdre_endpoints $count]
}

proc ::conv_accel_build::parse_system_accel_internal_none_fdre_audit {text} {
    set required [dict create \
        audit system_accel_internal_none_fdre \
        format_version 1 \
        status COMPLETE \
        query_scope full_design \
        endpoint_scope accelerator_fdre_d]
    set metric_key metric.accel_internal_none_fdre_endpoints
    set seen [dict create]
    foreach line [split $text "\n"] {
        if {![regexp {^([^=]+)=(.*)$} [string trimright $line "\r"] \
                -> key value]} {
            continue
        }
        if {$key in {audit format_version status query_scope endpoint_scope
                accelerator_cell} || $key eq $metric_key} {
            if {[dict exists $seen $key]} {
                error "system accelerator internal-none audit contains duplicate '$key' fields"
            }
            dict set seen $key $value
        }
    }
    foreach {key expected} $required {
        if {![dict exists $seen $key]} {
            error "system accelerator internal-none audit is missing '$key'"
        }
        if {[dict get $seen $key] ne $expected} {
            error "system accelerator internal-none audit $key=[dict get $seen $key], expected $expected"
        }
    }
    if {![dict exists $seen accelerator_cell] ||
        [string trim [dict get $seen accelerator_cell]] eq ""} {
        error "system accelerator internal-none audit is missing a non-empty accelerator_cell"
    }
    if {![dict exists $seen $metric_key]} {
        error "system accelerator internal-none audit is missing '$metric_key'"
    }
    set count [dict get $seen $metric_key]
    if {![string is integer -strict $count] || $count < 0} {
        error "system accelerator internal-none audit has invalid endpoint count '$count'"
    }
    return [dict create accel_internal_none_fdre_endpoints $count]
}

proc ::conv_accel_build::parse_route_status {text} {
    if {[regexp {# of nets with routing errors[^:]*:\s*([0-9]+)} \
        $text -> errors]} {
        return [dict create route_errors $errors]
    }
    return [dict create]
}

proc ::conv_accel_build::parse_congestion {text} {
    # report_design_analysis on a routed design contains both the final placer
    # result and a historical "Router Initial Congestion" table.  Only the
    # former describes the implemented placement that the congestion gate is
    # intended to qualify.  Including the latter can turn a final level-4
    # result into a false level-5 failure after route.
    set section_lines [list]
    set in_placer_final 0
    set found_placer_final 0
    foreach line [split $text "\n"] {
        if {[regexp {^\s*[0-9]+\.\s+Placer Final Level Congestion Reporting\s*$} \
                $line]} {
            # The heading appears once in the table of contents and once at
            # the real section.  Reset on each occurrence so the latter wins.
            set found_placer_final 1
            set in_placer_final 1
            set section_lines [list]
            continue
        }
        if {$in_placer_final &&
            [regexp {^\s*[0-9]+\.\s+\S} $line]} {
            set in_placer_final 0
            continue
        }
        if {$in_placer_final} {
            lappend section_lines $line
        }
    }
    if {!$found_placer_final} {
        return [dict create]
    }
    set section_text [join $section_lines "\n"]
    set max_level 0
    set saw_level_row 0
    foreach line $section_lines {
        if {[regexp {^\|\s*(?:North|South|East|West)\s*\|\s*(?:Global|Long|Short)\s*\|\s*([0-9]+)\s*\|} \
                $line -> level]} {
            set saw_level_row 1
            if {$level > $max_level} {
                set max_level $level
            }
        }
    }
    if {!$saw_level_row} {
        # report_design_analysis only emits windows at or above its requested
        # minimum level.  A summary such as "no windows ... above level 3"
        # therefore proves an upper bound of 3, not an exact level of zero.
        # Preserve that conservative bound so a report generated with the
        # Vivado default (level 5) cannot satisfy a <=4 release gate.
        if {[regexp -nocase \
                {No\s+congestion\s+windows\s+are\s+found\s+above\s+level\s+([0-9]+)} \
                $section_text -> reported_floor]} {
            return [dict create congestion_level $reported_floor]
        }
        return [dict create]
    }
    return [dict create congestion_level $max_level]
}

proc ::conv_accel_build::metrics_from_reports {util_path timing_path \
        {route_path ""} {congestion_path ""} \
        {accel_internal_none_audit_path ""} \
        {ooc_internal_none_audit_path ""}} {
    set metrics [parse_utilization [read_text $util_path]]
    set metrics [dict merge $metrics [parse_timing [read_text $timing_path]]]
    if {$route_path ne ""} {
        set metrics [dict merge $metrics [parse_route_status [read_text $route_path]]]
    }
    if {$congestion_path ne ""} {
        set metrics [dict merge $metrics \
            [parse_congestion [read_text $congestion_path]]]
    }
    if {$accel_internal_none_audit_path ne ""} {
        set metrics [dict merge $metrics \
            [parse_system_accel_internal_none_fdre_audit \
                [read_text $accel_internal_none_audit_path]]]
    }
    if {$ooc_internal_none_audit_path ne ""} {
        set metrics [dict merge $metrics \
            [parse_ooc_internal_none_fdre_audit \
                [read_text $ooc_internal_none_audit_path]]]
    }
    return $metrics
}

proc ::conv_accel_build::metric_violations {metrics limits} {
    set violations {}
    foreach {metric limit_key} {
        lut max_lut logic_lut max_logic_lut
        lut_memory max_lut_memory clb_percent max_clb_percent
        bram max_bram uram max_uram dsp max_dsp
        congestion_level max_congestion_level
        failing_endpoints max_failing_endpoints
        hold_failing_endpoints max_hold_failing_endpoints
        pulse_width_failing_endpoints max_pulse_width_failing_endpoints
        unconstrained_paths max_unconstrained_paths
        unclocked_fdre max_unclocked_fdre
        ooc_internal_none_fdre_endpoints
            max_ooc_internal_none_fdre_endpoints
        accel_internal_none_fdre_endpoints
            max_accel_internal_none_fdre_endpoints
        route_errors max_route_errors drc_errors max_drc_errors
        drc_critical_warnings max_drc_critical_warnings
    } {
        if {![dict exists $limits $limit_key] || [dict get $limits $limit_key] eq ""} {
            continue
        }
        if {![dict exists $metrics $metric]} {
            lappend violations "missing metric '$metric'"
        } elseif {[expr {double([dict get $metrics $metric]) >
                         double([dict get $limits $limit_key])}]} {
            lappend violations "$metric=[dict get $metrics $metric] exceeds $limit_key=[dict get $limits $limit_key]"
        }
    }
    foreach {metric limit_key} {uram expected_uram} {
        if {![dict exists $limits $limit_key] ||
            [dict get $limits $limit_key] eq ""} {
            continue
        }
        if {![dict exists $metrics $metric]} {
            lappend violations "missing metric '$metric'"
        } elseif {[expr {double([dict get $metrics $metric]) !=
                         double([dict get $limits $limit_key])}]} {
            lappend violations \
                "$metric=[dict get $metrics $metric] does not equal $limit_key=[dict get $limits $limit_key]"
        }
    }
    foreach {metric limit_key} {
        wns min_wns tns min_tns whs min_whs ths min_ths
    } {
        if {![dict exists $limits $limit_key] || [dict get $limits $limit_key] eq ""} {
            continue
        }
        if {![dict exists $metrics $metric]} {
            lappend violations "missing metric '$metric'"
        } elseif {[expr {double([dict get $metrics $metric]) <
                         double([dict get $limits $limit_key])}]} {
            lappend violations "$metric=[dict get $metrics $metric] is below $limit_key=[dict get $limits $limit_key]"
        }
    }
    return $violations
}

proc ::conv_accel_build::write_gate_report {path label metrics limits violations} {
    file mkdir [file dirname $path]
    set fh [open $path w]
    puts $fh "gate=$label"
    puts $fh "status=[expr {[llength $violations] == 0 ? {PASS} : {FAIL}}]"
    foreach key [lsort [dict keys $metrics]] {
        puts $fh "metric.$key=[dict get $metrics $key]"
    }
    foreach key [lsort [dict keys $limits]] {
        if {[dict get $limits $key] ne ""} {
            puts $fh "limit.$key=[dict get $limits $key]"
        }
    }
    foreach violation $violations {
        puts $fh "violation=$violation"
    }
    close $fh
}

proc ::conv_accel_build::enforce_report_gate {label report_path metrics limits} {
    set violations [metric_violations $metrics $limits]
    write_gate_report $report_path $label $metrics $limits $violations
    if {[llength $violations] != 0} {
        error "$label gate failed: [join $violations {; }] (see $report_path)"
    }
    puts "=== $label gate passed: $report_path ==="
}

proc ::conv_accel_build::sha256_file {path} {
    if {![file isfile $path]} {
        error "artifact not found for SHA256: $path"
    }
    set certutil [auto_execok certutil]
    if {$certutil ne ""} {
        if {![catch {exec {*}[list $certutil -hashfile $path SHA256]} output] &&
            [regexp -nocase {[0-9a-f]{64}} $output digest]} {
            return [string tolower $digest]
        }
    }
    set sha256sum [auto_execok sha256sum]
    if {$sha256sum ne ""} {
        if {![catch {exec {*}[list $sha256sum $path]} output] &&
            [regexp -nocase {^[0-9a-f]{64}} $output digest]} {
            return [string tolower $digest]
        }
    }
    set openssl [auto_execok openssl]
    if {$openssl ne ""} {
        if {![catch {exec {*}[list $openssl dgst -sha256 $path]} output] &&
            [regexp -nocase {[0-9a-f]{64}} $output digest]} {
            return [string tolower $digest]
        }
    }
    error "no usable SHA256 tool found (tried certutil, sha256sum, openssl)"
}

proc ::conv_accel_build::write_sha256_manifest {path artifacts} {
    file mkdir [file dirname $path]
    set entries {}
    foreach artifact $artifacts {
        set normalized [file normalize $artifact]
        set digest [sha256_file $normalized]
        lappend entries [list $digest [file tail $normalized]]
        puts "SHA256 $digest  $normalized"
    }
    set temporary "${path}.tmp.[pid]"
    if {[file exists $temporary]} {
        file delete -force -- $temporary
    }
    set fh ""
    set failed [catch {
        set fh [open $temporary w]
        foreach entry $entries {
            puts $fh "[lindex $entry 0]  [lindex $entry 1]"
        }
        close $fh
        set fh ""
        file rename -force -- $temporary $path
    } message options]
    if {$fh ne ""} {
        catch {close $fh}
    }
    if {$failed} {
        if {[file exists $temporary]} {
            file delete -force -- $temporary
        }
        return -options $options $message
    }
    return $path
}

proc ::conv_accel_build::write_build_metadata {path profile values} {
    file mkdir [file dirname $path]
    set fh [open $path w]
    puts $fh "profile=[expr {$profile eq {} ? {custom_cli} : $profile}]"
    foreach key [lsort [dict keys $values]] {
        puts $fh "$key=[dict get $values $key]"
    }
    close $fh
}

proc ::conv_accel_build::read_build_metadata {path} {
    set values [dict create]
    foreach line [split [read_text $path] "\n"] {
        set split_at [string first "=" $line]
        if {$split_at <= 0} {
            continue
        }
        set key [string range $line 0 [expr {$split_at - 1}]]
        set value [string range $line [expr {$split_at + 1}] end]
        dict set values $key $value
    }
    return $values
}

proc ::conv_accel_build::verify_build_metadata {path profile expected} {
    set actual [read_build_metadata $path]
    set expected_profile [expr {$profile eq "" ? "custom_cli" : $profile}]
    set mismatches {}
    if {![dict exists $actual profile]} {
        lappend mismatches "missing profile"
    } elseif {[dict get $actual profile] ne $expected_profile} {
        lappend mismatches "profile=[dict get $actual profile] expected=$expected_profile"
    }
    foreach key [dict keys $expected] {
        if {![dict exists $actual $key]} {
            lappend mismatches "missing $key"
        } elseif {[dict get $actual $key] ne [dict get $expected $key]} {
            lappend mismatches "$key=[dict get $actual $key] expected=[dict get $expected $key]"
        }
    }
    if {[llength $mismatches] != 0} {
        error "build metadata mismatch for reuse: [join $mismatches {; }] ($path)"
    }
}

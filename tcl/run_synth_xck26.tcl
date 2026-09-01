set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
source [file join $script_dir rtl_sources.tcl]
source [file join $script_dir build_common.tcl]
source [file join $script_dir dsp_cascade_checks.tcl]
set build_dir [file join $root build_synth_xck26]
set build_dir_explicit 0

set top conv_accel_core_axi_lite_axis_stream
set part xck26-sfvc784-2LV-c
set jobs 8
set rows 18
set cols 16
set k_tile 18
set cout_tile 32
set enable_column_psum 0
set enable_packed_hwc_ofm 1
# The OFM-side sequencer/ping-pong path is available for integration builds.
# Keep it off in the release OOC profile until the layer-long IFM cache is
# connected to the same tile ownership handshake.
set enable_layer_tile_sequencer 0
set enable_layer_long_hwc_ifm 0
set enable_tagged_context 0
set enable_weight_preload 0
set enable_fast_context_handoff 0
set enable_detailed_trace 1
set ifm_banks 2
set ifm_fifo_depth 1024
set ifm_fifo_aw 10
set psum_fifo_depth 1024
set psum_fifo_aw 10
set hwc_cache_aw 16
set hwc_cache_depth 43264
set hwc_cache_stripes 4
set hwc_cache_use_uram 1
set ifm_epoch_use_uram 0
set materialized_cache_aw 15
set materialized_cache_depth 32768
set tail_cycles 1
set pl_clock_mhz 100
set run_name ""
set out_of_context 0
set perform_place 0
set perform_route 0
set development_clock_mhz ""
set pl_clock_mhz_explicit 0
set ooc_min_wns_explicit 0
set check_only 0
set disable_post_place_physopt 0
set build_profile [::conv_accel_build::prescan_profile {*}$argv]
set release_profile [::conv_accel_build::is_abi_v2_gated_profile \
    $build_profile]
set enforce_gates 0
set ooc_max_lut ""
set ooc_max_logic_lut ""
set ooc_max_lut_memory ""
set ooc_max_clb_percent ""
set ooc_max_bram ""
set ooc_max_uram ""
set ooc_expected_uram ""
set ooc_max_dsp ""
set ooc_max_congestion_level ""
set ooc_min_wns ""
set ooc_min_tns ""
set ooc_min_whs ""
set ooc_min_ths ""
set ooc_max_failing_endpoints ""
set ooc_max_hold_failing_endpoints ""
set ooc_max_pulse_width_failing_endpoints ""
set ooc_max_unconstrained_paths ""
set ooc_max_unclocked_fdre ""
set ooc_max_internal_none_fdre_endpoints ""
::conv_accel_build::apply_profile $build_profile

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-top"} {
        incr i
        set top [lindex $argv $i]
    } elseif {$arg eq "-build_dir"} {
        incr i
        set build_dir [file normalize [lindex $argv $i]]
        set build_dir_explicit 1
    } elseif {$arg eq "-part"} {
        incr i
        set part [lindex $argv $i]
    } elseif {$arg eq "-jobs"} {
        incr i
        set jobs [lindex $argv $i]
    } elseif {$arg eq "-rows"} {
        incr i
        set rows [lindex $argv $i]
    } elseif {$arg eq "-cols"} {
        incr i
        set cols [lindex $argv $i]
    } elseif {$arg eq "-k_tile"} {
        incr i
        set k_tile [lindex $argv $i]
    } elseif {$arg eq "-cout_tile"} {
        incr i
        set cout_tile [lindex $argv $i]
    } elseif {$arg eq "-enable_packed_hwc_ofm"} {
        incr i
        set enable_packed_hwc_ofm [lindex $argv $i]
    } elseif {$arg eq "-enable_layer_tile_sequencer"} {
        incr i
        set enable_layer_tile_sequencer [lindex $argv $i]
    } elseif {$arg eq "-enable_layer_long_hwc_ifm"} {
        incr i
        set enable_layer_long_hwc_ifm [lindex $argv $i]
    } elseif {$arg eq "-enable_tagged_context"} {
        incr i
        set enable_tagged_context [lindex $argv $i]
    } elseif {$arg eq "-enable_weight_preload"} {
        incr i
        set enable_weight_preload [lindex $argv $i]
    } elseif {$arg eq "-enable_fast_context_handoff"} {
        incr i
        set enable_fast_context_handoff [lindex $argv $i]
    } elseif {$arg eq "-enable_detailed_trace"} {
        incr i
        set enable_detailed_trace [lindex $argv $i]
    } elseif {$arg eq "-ifm_banks"} {
        incr i
        set ifm_banks [lindex $argv $i]
    } elseif {$arg eq "-ifm_fifo_depth"} {
        incr i
        set ifm_fifo_depth [lindex $argv $i]
    } elseif {$arg eq "-ifm_fifo_aw"} {
        incr i
        set ifm_fifo_aw [lindex $argv $i]
    } elseif {$arg eq "-psum_fifo_depth"} {
        incr i
        set psum_fifo_depth [lindex $argv $i]
    } elseif {$arg eq "-psum_fifo_aw"} {
        incr i
        set psum_fifo_aw [lindex $argv $i]
    } elseif {$arg eq "-hwc_cache_aw"} {
        incr i
        set hwc_cache_aw [lindex $argv $i]
    } elseif {$arg eq "-hwc_cache_depth"} {
        incr i
        set hwc_cache_depth [lindex $argv $i]
    } elseif {$arg eq "-hwc_cache_stripes"} {
        incr i
        set hwc_cache_stripes [lindex $argv $i]
    } elseif {$arg eq "-hwc_cache_use_uram"} {
        incr i
        set hwc_cache_use_uram [lindex $argv $i]
    } elseif {$arg eq "-ifm_epoch_use_uram"} {
        incr i
        set ifm_epoch_use_uram [lindex $argv $i]
    } elseif {$arg eq "-materialized_cache_aw"} {
        incr i
        set materialized_cache_aw [lindex $argv $i]
    } elseif {$arg eq "-materialized_cache_depth"} {
        incr i
        set materialized_cache_depth [lindex $argv $i]
    } elseif {$arg eq "-tail_cycles"} {
        incr i
        set tail_cycles [lindex $argv $i]
    } elseif {$arg eq "-pl_clock_mhz"} {
        incr i
        set pl_clock_mhz [lindex $argv $i]
        set pl_clock_mhz_explicit 1
    } elseif {$arg eq "-development_clock_mhz"} {
        incr i
        set development_clock_mhz [lindex $argv $i]
    } elseif {$arg eq "-name"} {
        incr i
        set run_name [lindex $argv $i]
    } elseif {$arg eq "-ooc"} {
        set out_of_context 1
    } elseif {$arg eq "-place"} {
        set perform_place 1
    } elseif {$arg eq "-route"} {
        set perform_place 1
        set perform_route 1
    } elseif {$arg eq "-check_only"} {
        set check_only 1
    } elseif {$arg eq "-disable_post_place_physopt"} {
        set disable_post_place_physopt 1
    } elseif {$arg eq "-profile"} {
        incr i
    } elseif {$arg eq "-enforce_gates"} {
        set enforce_gates 1
    } elseif {$arg eq "-no_gates"} {
        if {$release_profile} {
            error "$build_profile gates are mandatory; -no_gates is forbidden"
        }
        set enforce_gates 0
    } elseif {$arg eq "-max_lut"} {
        incr i
        set ooc_max_lut [lindex $argv $i]
    } elseif {$arg eq "-max_logic_lut"} {
        incr i
        set ooc_max_logic_lut [lindex $argv $i]
    } elseif {$arg eq "-max_lut_memory"} {
        incr i
        set ooc_max_lut_memory [lindex $argv $i]
    } elseif {$arg eq "-max_clb_percent"} {
        incr i
        set ooc_max_clb_percent [lindex $argv $i]
    } elseif {$arg eq "-max_bram"} {
        incr i
        set ooc_max_bram [lindex $argv $i]
    } elseif {$arg eq "-max_uram"} {
        incr i
        set ooc_max_uram [lindex $argv $i]
    } elseif {$arg eq "-max_dsp"} {
        incr i
        set ooc_max_dsp [lindex $argv $i]
    } elseif {$arg eq "-min_wns"} {
        incr i
        set ooc_min_wns [lindex $argv $i]
        set ooc_min_wns_explicit 1
    } elseif {$arg eq "-min_tns"} {
        incr i
        set ooc_min_tns [lindex $argv $i]
    } elseif {$arg eq "-min_whs"} {
        incr i
        set ooc_min_whs [lindex $argv $i]
    } elseif {$arg eq "-min_ths"} {
        incr i
        set ooc_min_ths [lindex $argv $i]
    } elseif {$arg eq "-max_hold_failing_endpoints"} {
        incr i
        set ooc_max_hold_failing_endpoints [lindex $argv $i]
    } elseif {$arg eq "-max_pulse_width_failing_endpoints"} {
        incr i
        set ooc_max_pulse_width_failing_endpoints [lindex $argv $i]
    } elseif {$arg eq "-max_unconstrained_paths"} {
        incr i
        set ooc_max_unconstrained_paths [lindex $argv $i]
    } elseif {$arg eq "-max_unclocked_fdre"} {
        incr i
        set ooc_max_unclocked_fdre [lindex $argv $i]
    } elseif {$arg eq "-max_internal_none_fdre_endpoints"} {
        incr i
        set ooc_max_internal_none_fdre_endpoints [lindex $argv $i]
    } else {
        error "unknown argument: $arg"
    }
}

set frequency_sweep [expr {$development_clock_mhz ne ""}]
set metadata_profile $build_profile
if {$frequency_sweep} {
    if {$build_profile ne "abi_v2_release_200"} {
        error "-development_clock_mhz requires -profile abi_v2_release_200"
    }
    if {$pl_clock_mhz_explicit} {
        error "-development_clock_mhz cannot be combined with -pl_clock_mhz"
    }
    if {!$out_of_context || !$build_dir_explicit} {
        error "development frequency sweep requires -ooc and an explicit -build_dir"
    }
    if {$ooc_min_wns_explicit} {
        error "development frequency sweep derives -min_wns from one percent of the constrained period"
    }
    set pl_clock_mhz [::conv_accel_build::validate_development_clock_mhz \
        $development_clock_mhz]
    set metadata_profile [::conv_accel_build::frequency_sweep_profile_name \
        $development_clock_mhz]
    set build_dir [::conv_accel_build::require_frequency_sweep_build_dir \
        $root $build_dir $development_clock_mhz]
    # A fixed +0.50 ns post-place margin consumes an increasing fraction of
    # the period as frequency rises.  Development sweeps instead require one
    # percent of the actual 1 ps-quantized XDC period.  TNS and all other
    # release-derived safety/resource gates remain unchanged.
    set ooc_min_wns \
        [::conv_accel_build::development_post_place_min_wns $pl_clock_mhz]
    set perform_place 1
}
if {$perform_route && (!$frequency_sweep || !$out_of_context)} {
    error "-route is restricted to an out-of-context development frequency sweep"
}
if {$release_profile && !$out_of_context} {
    error "$build_profile requires an explicit -ooc argument"
}
if {$release_profile} {
    set perform_place 1
}
if {$disable_post_place_physopt &&
    ($build_profile ne "abi_v2_release_200" || !$out_of_context ||
     $frequency_sweep || !$build_dir_explicit)} {
    error "-disable_post_place_physopt is restricted to an explicit-build-dir abi_v2_release_200 OOC diagnostic run"
}

if {$release_profile} {
    if {$top ne "conv_accel_core_axi_lite_axis_stream"} {
        error "$build_profile locks top=conv_accel_core_axi_lite_axis_stream; got $top"
    }
    if {$part ne "xck26-sfvc784-2LV-c"} {
        error "$build_profile locks part=xck26-sfvc784-2LV-c; got $part"
    }
    set release_defaults [::conv_accel_build::profile_defaults $build_profile]
    set release_locked_keys {
        rows cols k_tile cout_tile enable_column_psum
        enable_packed_hwc_ofm enable_layer_tile_sequencer
        enable_layer_long_hwc_ifm enable_tagged_context
        enable_weight_preload enable_fast_context_handoff
        enable_detailed_trace ifm_banks ifm_fifo_depth ifm_fifo_aw
        psum_fifo_depth psum_fifo_aw hwc_cache_aw hwc_cache_depth
        hwc_cache_stripes hwc_cache_use_uram ifm_epoch_use_uram
        materialized_cache_aw materialized_cache_depth tail_cycles
        pl_clock_mhz
    }
    set release_actual [dict create \
        rows $rows cols $cols k_tile $k_tile cout_tile $cout_tile \
        enable_column_psum $enable_column_psum \
        enable_packed_hwc_ofm $enable_packed_hwc_ofm \
        enable_layer_tile_sequencer $enable_layer_tile_sequencer \
        enable_layer_long_hwc_ifm $enable_layer_long_hwc_ifm \
        enable_tagged_context $enable_tagged_context \
        enable_weight_preload $enable_weight_preload \
        enable_fast_context_handoff $enable_fast_context_handoff \
        enable_detailed_trace $enable_detailed_trace \
        ifm_banks $ifm_banks ifm_fifo_depth $ifm_fifo_depth \
        ifm_fifo_aw $ifm_fifo_aw psum_fifo_depth $psum_fifo_depth \
        psum_fifo_aw $psum_fifo_aw hwc_cache_aw $hwc_cache_aw \
        hwc_cache_depth $hwc_cache_depth \
        hwc_cache_stripes $hwc_cache_stripes \
        hwc_cache_use_uram $hwc_cache_use_uram \
        ifm_epoch_use_uram $ifm_epoch_use_uram \
        materialized_cache_aw $materialized_cache_aw \
        materialized_cache_depth $materialized_cache_depth \
        tail_cycles $tail_cycles pl_clock_mhz \
        [expr {$frequency_sweep ? \
            [dict get $release_defaults pl_clock_mhz] : $pl_clock_mhz}]]
    ::conv_accel_build::require_no_violations "$build_profile OOC profile" \
        [::conv_accel_build::locked_value_violations \
            $release_defaults $release_actual $release_locked_keys]
    if {!$enforce_gates} {
        error "$build_profile OOC gates are mandatory"
    }
    set release_gate_keys {
        ooc_max_lut ooc_max_logic_lut ooc_max_lut_memory
        ooc_max_clb_percent ooc_max_bram ooc_max_uram ooc_expected_uram
        ooc_max_dsp ooc_max_congestion_level
        ooc_min_wns ooc_min_tns ooc_min_whs ooc_min_ths
        ooc_max_failing_endpoints ooc_max_hold_failing_endpoints
        ooc_max_pulse_width_failing_endpoints
        ooc_max_unconstrained_paths ooc_max_unclocked_fdre
        ooc_max_internal_none_fdre_endpoints
    }
    if {$frequency_sweep} {
        # The proportional development WNS admission margin is the sole
        # intentional relaxation from the source release profile.
        set wns_gate_index [lsearch -exact $release_gate_keys ooc_min_wns]
        set release_gate_keys [lreplace $release_gate_keys \
            $wns_gate_index $wns_gate_index]
    }
    set release_gates [dict create \
        ooc_max_lut $ooc_max_lut \
        ooc_max_logic_lut $ooc_max_logic_lut \
        ooc_max_lut_memory $ooc_max_lut_memory \
        ooc_max_clb_percent $ooc_max_clb_percent \
        ooc_max_bram $ooc_max_bram \
        ooc_max_uram $ooc_max_uram ooc_expected_uram $ooc_expected_uram \
        ooc_max_dsp $ooc_max_dsp \
        ooc_max_congestion_level $ooc_max_congestion_level \
        ooc_min_wns $ooc_min_wns ooc_min_tns $ooc_min_tns \
        ooc_min_whs $ooc_min_whs ooc_min_ths $ooc_min_ths \
        ooc_max_failing_endpoints $ooc_max_failing_endpoints \
        ooc_max_hold_failing_endpoints \
            $ooc_max_hold_failing_endpoints \
        ooc_max_pulse_width_failing_endpoints \
            $ooc_max_pulse_width_failing_endpoints \
        ooc_max_unconstrained_paths $ooc_max_unconstrained_paths \
        ooc_max_unclocked_fdre $ooc_max_unclocked_fdre \
        ooc_max_internal_none_fdre_endpoints \
            $ooc_max_internal_none_fdre_endpoints]
    ::conv_accel_build::require_no_violations "$build_profile OOC gates" \
        [::conv_accel_build::gate_limit_relaxations \
            $release_defaults $release_gates $release_gate_keys]
}

if {$run_name eq ""} {
    if {$build_profile eq ""} {
        # Preserve the historical filename for old commands.
        set run_name "${top}_r${rows}_c${cols}_cout${cout_tile}_packed${enable_packed_hwc_ofm}"
    } else {
        set run_name "${metadata_profile}_${top}_r${rows}_c${cols}_cout${cout_tile}_packed${enable_packed_hwc_ofm}_seq${enable_layer_tile_sequencer}_long${enable_layer_long_hwc_ifm}_tag${enable_tagged_context}_wpre${enable_weight_preload}_fast${enable_fast_context_handoff}_trace${enable_detailed_trace}_pf${psum_fifo_depth}"
    }
}
if {$build_profile ne ""} {
    append run_name "_eu${ifm_epoch_use_uram}_ooc${out_of_context}"
}

if {$cout_tile != (2 * $cols)} {
    error "COUT_TILE must be 2 * COLS for the current packed-int8 datapath"
}
if {$enable_column_psum != 0} {
    error "release builds require ENABLE_COLUMN_PSUM=0"
}
if {$enable_packed_hwc_ofm != 0 && $enable_packed_hwc_ofm != 1} {
    error "ENABLE_PACKED_HWC_OFM must be 0 or 1"
}
if {$enable_layer_tile_sequencer != 0 &&
    $enable_layer_tile_sequencer != 1} {
    error "ENABLE_LAYER_TILE_SEQUENCER must be 0 or 1"
}
if {$enable_layer_long_hwc_ifm != 0 &&
    $enable_layer_long_hwc_ifm != 1} {
    error "ENABLE_LAYER_LONG_HWC_IFM must be 0 or 1"
}
if {$enable_layer_long_hwc_ifm != 0 &&
    $enable_layer_tile_sequencer == 0} {
    error "ENABLE_LAYER_LONG_HWC_IFM requires ENABLE_LAYER_TILE_SEQUENCER=1"
}
::conv_accel_build::validate_bool ENABLE_TAGGED_CONTEXT $enable_tagged_context
::conv_accel_build::validate_bool ENABLE_WEIGHT_PRELOAD $enable_weight_preload
::conv_accel_build::validate_bool ENABLE_FAST_CONTEXT_HANDOFF \
    $enable_fast_context_handoff
::conv_accel_build::validate_bool ENABLE_DETAILED_TRACE $enable_detailed_trace
::conv_accel_build::validate_bool IFM_EPOCH_USE_URAM $ifm_epoch_use_uram
if {$enable_weight_preload && !$enable_tagged_context} {
    error "ENABLE_WEIGHT_PRELOAD requires ENABLE_TAGGED_CONTEXT=1"
}
if {$enable_fast_context_handoff && !$enable_weight_preload} {
    error "ENABLE_FAST_CONTEXT_HANDOFF requires ENABLE_WEIGHT_PRELOAD=1"
}
if {$ifm_banks < 1 || $ifm_banks > 8} {
    error "IFM_BANKS must fit in the 64-bit IFM AXI-Stream beat"
}
if {(1 << $ifm_fifo_aw) != $ifm_fifo_depth} {
    error "IFM_FIFO_DEPTH must equal 2^IFM_FIFO_AW"
}
if {(1 << $psum_fifo_aw) != $psum_fifo_depth} {
    error "PSUM_FIFO_DEPTH must equal 2^PSUM_FIFO_AW"
}
if {(1 << $materialized_cache_aw) != $materialized_cache_depth} {
    error "MATERIALIZED_CACHE_DEPTH must equal 2^MATERIALIZED_CACHE_AW"
}
if {$enforce_gates && ![::conv_accel_build::has_nonempty \
    $ooc_max_lut $ooc_max_logic_lut $ooc_max_lut_memory \
    $ooc_max_clb_percent $ooc_max_bram $ooc_max_uram \
    $ooc_expected_uram $ooc_max_dsp $ooc_max_congestion_level \
    $ooc_min_wns $ooc_min_tns $ooc_min_whs $ooc_min_ths \
    $ooc_max_failing_endpoints \
    $ooc_max_hold_failing_endpoints \
    $ooc_max_pulse_width_failing_endpoints \
    $ooc_max_unconstrained_paths $ooc_max_unclocked_fdre \
    $ooc_max_internal_none_fdre_endpoints]} {
    error "-enforce_gates requires at least one OOC gate threshold"
}
set clock_hz [::conv_accel_build::clock_hz_from_mhz $pl_clock_mhz]
set clock_period_ns [::conv_accel_build::clock_period_ns_from_mhz \
    $pl_clock_mhz]
# Vivado 2022.2 stores XDC periods at 1 ps resolution.  Keep the exact
# requested period for provenance, but constrain and verify the same rounded
# value that Vivado will retain (notably 6.667 ns at 150 MHz and 5.714 ns at
# 175 MHz).
set constrained_clock_period_ns [expr {
    round(double($clock_period_ns) * 1000.0) / 1000.0
}]
set timing_diagnostic_max_paths [expr {
    [::conv_accel_build::is_abi_v2_200_profile $build_profile] ? 100 : 50
}]

set rtl_abs_files [::conv_accel_sources::absolute_files $root]
set git_provenance [::conv_accel_build::git_provenance $root]
set release_ooc_place $perform_place
set post_place_physopt_enabled [expr {
    [::conv_accel_build::is_abi_v2_200_profile $build_profile] &&
    $out_of_context &&
    !$frequency_sweep && !$disable_post_place_physopt
}]
set post_place_physopt_directive [expr {
    $post_place_physopt_enabled ? {AggressiveExplore} : {disabled}
}]
set implementation_stage [expr {
    $post_place_physopt_enabled ? {post_place_phys_opt} :
    ($release_ooc_place ? {post_place} : {post_synth})
}]
if {$check_only} {
    puts "PASS: OOC build configuration profile=[expr {$build_profile eq {} ? {custom_cli} : $build_profile}] metadata_profile=$metadata_profile name=$run_name rows=$rows cols=$cols cout_tile=$cout_tile tagged=$enable_tagged_context weight_preload=$enable_weight_preload fast_handoff=$enable_fast_context_handoff ifm_epoch_uram=$ifm_epoch_use_uram detailed_trace=$enable_detailed_trace psum_fifo=$psum_fifo_depth clock_hz=$clock_hz ooc=$out_of_context place=$release_ooc_place route=$perform_route gates=$enforce_gates implementation_stage=$implementation_stage post_place_physopt_enabled=$post_place_physopt_enabled post_place_physopt_directive=$post_place_physopt_directive post_place_physopt_forced_off=$disable_post_place_physopt min_wns=$ooc_min_wns min_whs=$ooc_min_whs min_ths=$ooc_min_ths max_failing_endpoints=$ooc_max_failing_endpoints max_hold_failing_endpoints=$ooc_max_hold_failing_endpoints max_pulse_width_failing_endpoints=$ooc_max_pulse_width_failing_endpoints max_congestion_level=$ooc_max_congestion_level expected_uram=$ooc_expected_uram timing_diagnostic_max_paths=$timing_diagnostic_max_paths git_sha=[dict get $git_provenance git_sha] git_dirty=[dict get $git_provenance git_dirty] sources=[llength $rtl_abs_files]"
    exit
}
if {$build_profile ne ""} {
    ::conv_accel_build::require_vivado_version 2022.2
}
file mkdir $build_dir
set report_prefix [file join $build_dir $run_name]
set clock_xdc_path "${report_prefix}_clock.xdc"
set timing_diagnostic_report \
    "${report_prefix}_timing_top${timing_diagnostic_max_paths}.rpt"
set internal_none_fdre_report_path \
    "${report_prefix}_internal_none_fdre_audit.rpt"

# A failed replacement OOC run must not leave an older checkpoint or digest
# looking like the result of the current RTL.  Remove only the exact published
# files for this run name; intermediate Vivado state and other profiles are
# intentionally untouched.
::conv_accel_build::remove_stale_publications $build_dir [list \
    "${report_prefix}_utilization.rpt" \
    "${report_prefix}_utilization_hier.rpt" \
    "${report_prefix}_timing_summary.rpt" \
    "${report_prefix}_timing_top50.rpt" \
    "${report_prefix}_timing_top100.rpt" \
    "${report_prefix}_congestion.rpt" \
    $internal_none_fdre_report_path \
    $clock_xdc_path \
    "${report_prefix}_build_profile.txt" \
    "${report_prefix}_gate.txt" \
    "${report_prefix}_synth.dcp" \
    "${report_prefix}_placed.dcp" \
    "${report_prefix}_routed_utilization.rpt" \
    "${report_prefix}_routed_utilization_hier.rpt" \
    "${report_prefix}_routed_timing_summary.rpt" \
    "${report_prefix}_routed_timing_top50.rpt" \
    "${report_prefix}_routed_route_status.rpt" \
    "${report_prefix}_routed_drc.rpt" \
    "${report_prefix}_routed_congestion.rpt" \
    "${report_prefix}_routed_internal_none_fdre_audit.rpt" \
    "${report_prefix}_routed_build_profile.txt" \
    "${report_prefix}_routed_gate.txt" \
    "${report_prefix}_routed.dcp" \
    "${report_prefix}_routed_artifacts.sha256" \
    "${report_prefix}_artifacts.sha256"]

puts "=== synth profile=[expr {$build_profile eq {} ? {custom_cli} : $build_profile}] top=$top part=$part rows=$rows cols=$cols k_tile=$k_tile cout_tile=$cout_tile enable_column_psum=$enable_column_psum enable_packed_hwc_ofm=$enable_packed_hwc_ofm enable_layer_tile_sequencer=$enable_layer_tile_sequencer enable_layer_long_hwc_ifm=$enable_layer_long_hwc_ifm enable_tagged_context=$enable_tagged_context enable_weight_preload=$enable_weight_preload enable_fast_context_handoff=$enable_fast_context_handoff ifm_epoch_use_uram=$ifm_epoch_use_uram enable_detailed_trace=$enable_detailed_trace ifm_banks=$ifm_banks ifm_fifo_depth=$ifm_fifo_depth ifm_fifo_aw=$ifm_fifo_aw psum_fifo_depth=$psum_fifo_depth psum_fifo_aw=$psum_fifo_aw hwc_cache_aw=$hwc_cache_aw hwc_cache_depth=$hwc_cache_depth materialized_cache_aw=$materialized_cache_aw materialized_cache_depth=$materialized_cache_depth tail_cycles=$tail_cycles ooc=$out_of_context ==="
read_verilog -sv $rtl_abs_files

# OOC synthesis must see the actual target period while it performs mapping
# and retiming.  Loading a build-local OOC XDC before synth_design is the
# non-project equivalent of attaching the clock constraint to the source set;
# creating the clock only after synthesis leaves mapping frequency-blind.
set clock_xdc [open $clock_xdc_path w]
puts $clock_xdc [format \
    {create_clock -name clk -period %.6f [get_ports {clk}]} \
    $constrained_clock_period_ns]
close $clock_xdc
read_xdc -mode out_of_context $clock_xdc_path

set synth_args [list -top $top -part $part -flatten_hierarchy rebuilt -directive default \
    -generic "ROWS=$rows" -generic "COLS=$cols" -generic "K_TILE=$k_tile" \
    -generic "COUT_TILE=$cout_tile" -generic "IFM_BANKS=$ifm_banks" \
    -generic "IFM_FIFO_DEPTH=$ifm_fifo_depth" -generic "IFM_FIFO_AW=$ifm_fifo_aw" \
    -generic "PSUM_FIFO_DEPTH=$psum_fifo_depth" -generic "PSUM_FIFO_AW=$psum_fifo_aw" \
    -generic "HWC_CACHE_AW=$hwc_cache_aw" -generic "HWC_CACHE_DEPTH=$hwc_cache_depth" \
    -generic "HWC_CACHE_STRIPES=$hwc_cache_stripes" \
    -generic "HWC_CACHE_USE_URAM=$hwc_cache_use_uram" \
    -generic "MATERIALIZED_CACHE_AW=$materialized_cache_aw" \
    -generic "MATERIALIZED_CACHE_DEPTH=$materialized_cache_depth" \
    -generic "CLOCK_HZ=$clock_hz" \
    -generic "TAIL_CYCLES_CONFIG=$tail_cycles" \
    -generic "ENABLE_COLUMN_PSUM=$enable_column_psum" \
    -generic "ENABLE_PACKED_HWC_OFM=$enable_packed_hwc_ofm" \
    -generic "ENABLE_LAYER_TILE_SEQUENCER=$enable_layer_tile_sequencer" \
    -generic "ENABLE_LAYER_LONG_HWC_IFM=$enable_layer_long_hwc_ifm" \
    -generic "ENABLE_TAGGED_CONTEXT=$enable_tagged_context" \
    -generic "ENABLE_WEIGHT_PRELOAD=$enable_weight_preload" \
    -generic "ENABLE_FAST_CONTEXT_HANDOFF=$enable_fast_context_handoff" \
    -generic "IFM_EPOCH_USE_URAM=$ifm_epoch_use_uram" \
    -generic "ENABLE_DETAILED_TRACE=$enable_detailed_trace"]
if {$out_of_context} {
    lappend synth_args -mode out_of_context
}
synth_design {*}$synth_args

set constrained_clocks [get_clocks -quiet -of_objects [get_ports clk]]
if {[llength $constrained_clocks] != 1} {
    error "OOC clock contract resolved [llength $constrained_clocks] clocks on clk, expected 1"
}
set constrained_period [get_property PERIOD [lindex $constrained_clocks 0]]
if {abs(double($constrained_period) -
    double($constrained_clock_period_ns)) > 0.000001} {
    error "OOC clock period=$constrained_period does not match constrained [format %.6f $constrained_clock_period_ns] ns (requested [format %.6f $clock_period_ns] ns)"
}

# A release OOC gate includes physical density, so it must be measured after
# placement.  Custom/debug invocations retain the historical synth-only flow.
if {$release_ooc_place} {
    opt_design
    place_design
    if {$post_place_physopt_enabled} {
        # Formal 200 MHz release OOC uses one fixed post-place optimization
        # pass.  Development sweeps retain their separate pre-route pass.
        phys_opt_design -directive $post_place_physopt_directive
    }

    if {$enable_tagged_context != 0} {
        set cascade_array_cells [get_cells -quiet -hier -filter \
            {REF_NAME == systolic_array_dsp_cascade_tagged}]
        if {[llength $cascade_array_cells] != 1} {
            error "release DSP cascade structural gate resolved [llength $cascade_array_cells] array cells, expected 1"
        }
        ::dsp_cascade_checks::check \
            [get_property NAME $cascade_array_cells] $rows $cols 1
    }
}

report_utilization -file "${report_prefix}_utilization.rpt"
report_utilization -hierarchical -file "${report_prefix}_utilization_hier.rpt"
report_timing_summary -report_unconstrained \
    -file "${report_prefix}_timing_summary.rpt"
if {$release_ooc_place} {
    report_timing -delay_type max -max_paths $timing_diagnostic_max_paths \
        -nworst 1 -sort_by group -file $timing_diagnostic_report
    report_design_analysis -congestion -min_congestion_level 3 \
        -file "${report_prefix}_congestion.rpt"
}

set internal_none_fdre_metrics [dict create]
if {$release_ooc_place} {
    # Run after placement and before metadata/gating/checkpoint publication.
    # The helper catches Vivado query errors, emits status=ERROR, and rethrows;
    # a missing, incomplete, or malformed audit therefore cannot publish.
    set internal_none_fdre_metrics \
        [::conv_accel_build::write_ooc_internal_none_fdre_audit \
            $internal_none_fdre_report_path 50]
}

set metadata [dict merge [dict create top $top part $part rows $rows cols $cols \
    k_tile $k_tile cout_tile $cout_tile enable_column_psum $enable_column_psum \
    enable_packed_hwc_ofm $enable_packed_hwc_ofm \
    enable_layer_tile_sequencer $enable_layer_tile_sequencer \
    enable_layer_long_hwc_ifm $enable_layer_long_hwc_ifm \
    enable_tagged_context $enable_tagged_context \
    enable_weight_preload $enable_weight_preload \
    enable_fast_context_handoff $enable_fast_context_handoff \
    enable_detailed_trace $enable_detailed_trace ifm_banks $ifm_banks \
    ifm_fifo_depth $ifm_fifo_depth ifm_fifo_aw $ifm_fifo_aw \
    psum_fifo_depth $psum_fifo_depth psum_fifo_aw $psum_fifo_aw \
    hwc_cache_aw $hwc_cache_aw hwc_cache_depth $hwc_cache_depth \
    hwc_cache_stripes $hwc_cache_stripes \
    hwc_cache_use_uram $hwc_cache_use_uram \
    ifm_epoch_use_uram $ifm_epoch_use_uram \
    materialized_cache_aw $materialized_cache_aw \
    materialized_cache_depth $materialized_cache_depth \
    tail_cycles $tail_cycles pl_clock_mhz $pl_clock_mhz \
    clock_hz $clock_hz clock_period_ns [format %.6f $clock_period_ns] \
    constrained_clock_period_ns \
        [format %.6f $constrained_clock_period_ns] \
    source_profile $build_profile \
    release_eligible [::conv_accel_build::is_abi_v2_release_profile \
        $build_profile] \
    ablation_profile [::conv_accel_build::is_abi_v2_ablation_profile \
        $build_profile] \
    development_frequency_sweep $frequency_sweep \
    development_post_place_margin_fraction \
        [expr {$frequency_sweep ? 0.01 : {not_applicable}}] \
    out_of_context $out_of_context \
    enforce_gates $enforce_gates implementation_stage $implementation_stage \
    post_place_physopt_enabled $post_place_physopt_enabled \
    post_place_physopt_directive $post_place_physopt_directive \
    post_place_physopt_forced_off $disable_post_place_physopt \
    max_lut $ooc_max_lut max_logic_lut $ooc_max_logic_lut \
    max_lut_memory $ooc_max_lut_memory \
    max_clb_percent $ooc_max_clb_percent \
    max_bram $ooc_max_bram max_uram $ooc_max_uram \
    expected_uram $ooc_expected_uram max_dsp $ooc_max_dsp \
    max_congestion_level $ooc_max_congestion_level \
    min_wns $ooc_min_wns min_tns $ooc_min_tns \
    min_whs $ooc_min_whs min_ths $ooc_min_ths \
    max_failing_endpoints $ooc_max_failing_endpoints \
    max_hold_failing_endpoints $ooc_max_hold_failing_endpoints \
    max_pulse_width_failing_endpoints \
        $ooc_max_pulse_width_failing_endpoints \
    max_unconstrained_paths $ooc_max_unconstrained_paths \
    max_unclocked_fdre $ooc_max_unclocked_fdre \
    max_ooc_internal_none_fdre_endpoints \
        $ooc_max_internal_none_fdre_endpoints \
    internal_none_fdre_audit_report \
        [expr {$release_ooc_place ? \
            [file tail $internal_none_fdre_report_path] : {not_run}}] \
    timing_diagnostic_max_paths $timing_diagnostic_max_paths \
    timing_diagnostic_nworst 1 \
    timing_diagnostic_report \
        [expr {$release_ooc_place ? \
            [file tail $timing_diagnostic_report] : {not_run}}] \
    ooc_internal_none_fdre_endpoints \
        [expr {$release_ooc_place ? \
            [dict get $internal_none_fdre_metrics \
                ooc_internal_none_fdre_endpoints] : {not_run}}] \
    vivado_version [version -short]] $git_provenance]
::conv_accel_build::write_build_metadata "${report_prefix}_build_profile.txt" \
    $metadata_profile $metadata

if {$enforce_gates} {
    set internal_none_fdre_gate_report [expr {$release_ooc_place ?
        $internal_none_fdre_report_path : {}}]
    set congestion_gate_report [expr {$release_ooc_place &&
        $ooc_max_congestion_level ne "" ?
        "${report_prefix}_congestion.rpt" : {}}]
    set metrics [::conv_accel_build::metrics_from_reports \
        "${report_prefix}_utilization.rpt" \
        "${report_prefix}_timing_summary.rpt" "" \
        $congestion_gate_report "" \
        $internal_none_fdre_gate_report]
    set limits [dict create max_lut $ooc_max_lut \
        max_logic_lut $ooc_max_logic_lut \
        max_lut_memory $ooc_max_lut_memory \
        max_clb_percent $ooc_max_clb_percent \
        max_bram $ooc_max_bram \
        max_uram $ooc_max_uram expected_uram $ooc_expected_uram \
        max_dsp $ooc_max_dsp \
        max_congestion_level $ooc_max_congestion_level \
        min_wns $ooc_min_wns min_tns $ooc_min_tns \
        min_whs $ooc_min_whs min_ths $ooc_min_ths \
        max_failing_endpoints $ooc_max_failing_endpoints \
        max_hold_failing_endpoints $ooc_max_hold_failing_endpoints \
        max_pulse_width_failing_endpoints \
            $ooc_max_pulse_width_failing_endpoints \
        max_unconstrained_paths $ooc_max_unconstrained_paths \
        max_unclocked_fdre $ooc_max_unclocked_fdre \
        max_ooc_internal_none_fdre_endpoints \
            $ooc_max_internal_none_fdre_endpoints]
    ::conv_accel_build::enforce_report_gate OOC \
        "${report_prefix}_gate.txt" $metrics $limits
}

set checkpoint_path [expr {$release_ooc_place ? \
    "${report_prefix}_placed.dcp" : "${report_prefix}_synth.dcp"}]
write_checkpoint -force $checkpoint_path
::conv_accel_build::write_sha256_manifest \
    "${report_prefix}_artifacts.sha256" [list $checkpoint_path]

if {$perform_route} {
    # Development route is deliberately separate from the formal release
    # profile.  The proportional post-place gate above must pass first; route
    # then requires non-negative timing and all structural/protocol checks.
    phys_opt_design -directive AggressiveExplore
    route_design

    set routed_util "${report_prefix}_routed_utilization.rpt"
    set routed_timing "${report_prefix}_routed_timing_summary.rpt"
    set routed_route "${report_prefix}_routed_route_status.rpt"
    set routed_congestion "${report_prefix}_routed_congestion.rpt"
    set routed_none "${report_prefix}_routed_internal_none_fdre_audit.rpt"
    report_utilization -file $routed_util
    report_utilization -hierarchical \
        -file "${report_prefix}_routed_utilization_hier.rpt"
    report_timing_summary -report_unconstrained -file $routed_timing
    report_timing -delay_type max -max_paths 50 -sort_by group \
        -file "${report_prefix}_routed_timing_top50.rpt"
    report_route_status -file $routed_route
    # HDOOC-3 is an unconditional Error in bitstream_checks for every valid
    # out-of-context design.  OOC route qualification therefore runs the
    # implementation/default deck only; full-system implementation retains
    # default+bitstream_checks in build_kv260_system_xck26.tcl.
    report_drc -ruledecks {default} \
        -file "${report_prefix}_routed_drc.rpt"
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
        set drc_severity [get_property SEVERITY $drc_violation]
        if {$drc_severity eq "Error"} {
            incr routed_drc_errors
        } elseif {$drc_severity eq "Critical Warning"} {
            incr routed_drc_critical_warnings
        }
    }
    dict set routed_metrics drc_errors $routed_drc_errors
    dict set routed_metrics drc_critical_warnings \
        $routed_drc_critical_warnings
    set routed_limits [dict create \
        max_lut $ooc_max_lut max_logic_lut $ooc_max_logic_lut \
        max_lut_memory $ooc_max_lut_memory \
        max_clb_percent $ooc_max_clb_percent \
        max_bram $ooc_max_bram max_uram $ooc_max_uram \
        expected_uram 48 max_dsp $ooc_max_dsp \
        max_congestion_level 4 \
        min_wns 0.0 min_tns 0.0 min_whs 0.0 min_ths 0.0 \
        max_failing_endpoints 0 max_hold_failing_endpoints 0 \
        max_pulse_width_failing_endpoints 0 \
        max_unconstrained_paths $ooc_max_unconstrained_paths \
        max_unclocked_fdre $ooc_max_unclocked_fdre \
        max_ooc_internal_none_fdre_endpoints \
            $ooc_max_internal_none_fdre_endpoints \
        max_route_errors 0 max_drc_errors 0 \
        max_drc_critical_warnings 0]
    ::conv_accel_build::enforce_report_gate OOC_ROUTE \
        "${report_prefix}_routed_gate.txt" $routed_metrics $routed_limits

    set routed_metadata $metadata
    dict set routed_metadata implementation_stage post_route
    dict set routed_metadata development_route 1
    dict set routed_metadata development_route_min_wns 0.0
    dict set routed_metadata development_route_max_congestion_level 4
    dict set routed_metadata route_errors \
        [dict get $routed_metrics route_errors]
    dict set routed_metadata drc_errors $routed_drc_errors
    dict set routed_metadata drc_critical_warnings \
        $routed_drc_critical_warnings
    dict set routed_metadata ooc_internal_none_fdre_endpoints \
        [dict get $routed_none_metrics ooc_internal_none_fdre_endpoints]
    ::conv_accel_build::write_build_metadata \
        "${report_prefix}_routed_build_profile.txt" $metadata_profile \
        $routed_metadata
    set routed_checkpoint "${report_prefix}_routed.dcp"
    write_checkpoint -force $routed_checkpoint
    ::conv_accel_build::write_sha256_manifest \
        "${report_prefix}_routed_artifacts.sha256" \
        [list $checkpoint_path $routed_checkpoint]
}

puts "=== synthesis reports ==="
puts "${report_prefix}_utilization.rpt"
puts "${report_prefix}_utilization_hier.rpt"
puts "${report_prefix}_timing_summary.rpt"
if {$release_ooc_place} {
    puts $timing_diagnostic_report
    puts "timing diagnostic: max_paths=$timing_diagnostic_max_paths nworst=1"
    puts $internal_none_fdre_report_path
}
if {$perform_route} {
    puts "${report_prefix}_routed_timing_summary.rpt"
    puts "${report_prefix}_routed_timing_top50.rpt"
    puts "${report_prefix}_routed_route_status.rpt"
    puts "${report_prefix}_routed_drc.rpt"
    puts "${report_prefix}_routed_congestion.rpt"
    puts "${report_prefix}_routed_internal_none_fdre_audit.rpt"
    puts "${report_prefix}_routed_gate.txt"
}
puts "${report_prefix}_build_profile.txt"
puts $checkpoint_path
puts "${report_prefix}_artifacts.sha256"

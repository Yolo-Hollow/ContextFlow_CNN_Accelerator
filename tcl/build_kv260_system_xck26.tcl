# Build the complete KV260 PS/DMA/accelerator hardware platform in Vivado
# 2022.2.  The generated XSA is the hardware handoff for a later Vitis
# bare-metal smoke-test application.

set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
source [file join $script_dir rtl_sources.tcl]
source [file join $script_dir build_common.tcl]
set build_dir [file join $root build_system_xck26_kv260]
set project_name conv_accel_ps_dma_minimal
set bd_name conv_accel_ps_dma
set board_part xilinx.com:kv260_som:part0:1.4
set board_connection [list som240_1_connector xilinx.com:kv260_carrier:som240_1_connector:1.3]
set rows 18
set cols 16
set k_tile 18
set cout_tile 32
set enable_column_psum 0
set enable_packed_hwc_ofm 1
set enable_layer_tile_sequencer 0
set enable_layer_long_hwc_ifm 0
set enable_tagged_context 0
set enable_weight_preload 0
set enable_fast_context_handoff 0
set enable_detailed_trace 1
set enable_legacy_gpio_status 1
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
set weight_dma_mm2s_burst 8
set development_clock_mhz ""
set pl_clock_mhz_explicit 0
set system_place_min_wns_explicit 0
set system_min_wns_explicit 0
set jobs 8
set synth_only 0
set place_only 0
set reuse_synth 0
set check_only 0
set build_dir_explicit 0
set build_profile [::conv_accel_build::prescan_profile {*}$argv]
set release_profile [::conv_accel_build::is_abi_v2_gated_profile \
    $build_profile]
set enforce_gates 0
set system_max_lut ""
set system_max_lut_memory ""
set system_max_clb_percent ""
set system_place_min_wns ""
set system_place_max_congestion_level ""
set system_max_bram ""
set system_max_uram ""
set system_expected_uram ""
set system_max_dsp ""
set system_min_wns ""
set system_min_tns ""
set system_min_whs ""
set system_min_ths ""
set system_max_failing_endpoints ""
set system_max_hold_failing_endpoints ""
set system_max_pulse_width_failing_endpoints ""
set system_max_unconstrained_paths ""
set system_max_unclocked_fdre ""
set system_max_accel_none_delay_endpoints ""
set system_max_route_errors ""
set system_max_drc_errors ""
set system_max_drc_critical_warnings ""
::conv_accel_build::apply_profile $build_profile

set post_place_gate_step place_design
set post_place_checkpoint_suffix placed
set post_place_physopt_directive disabled
set post_place_physopt_passes 0
set post_place_margin_uncertainty_ns 0.000
set post_place_physopt_hook {}
if {$release_profile} {
    set post_place_gate_step phys_opt_design
    set post_place_checkpoint_suffix physopt
    set post_place_physopt_directive AggressiveExplore
    set post_place_physopt_passes 2
    set post_place_margin_uncertainty_ns 0.450
    set post_place_physopt_hook [file normalize \
        [file join $script_dir abi_v2_margin_physopt_post.tcl]]
    if {![file isfile $post_place_physopt_hook]} {
        error "ABI-v2 margin phys-opt hook is missing: $post_place_physopt_hook"
    }
}

proc assert_abi_v2_release_has_no_debug_cores {profile stage} {
    if {![::conv_accel_build::is_abi_v2_gated_profile $profile]} {
        return
    }
    set debug_cores [get_debug_cores -quiet]
    if {[llength $debug_cores] != 0} {
        error "abi_v2_release $stage design contains debug cores: $debug_cores"
    }
}

# A requested PS clock is not proof of the implemented clock: on K26, a
# nominal 200 MHz PS PL0 request is quantized to about 187.5 MHz.  Resolve the
# clock that actually reaches the accelerator registers and fail closed unless
# its implemented period is the profile target.  This audit is repeated after
# synthesis, post-place physical optimization, and route.
proc assert_abi_v2_release_accel_clock {profile expected_period_ns stage} {
    if {![::conv_accel_build::is_abi_v2_gated_profile $profile]} {
        return [dict create]
    }
    set accelerator_cells [get_cells -quiet -hier -filter \
        {NAME =~ "*/accel/inst"}]
    if {[llength $accelerator_cells] != 1} {
        error "abi_v2_release $stage clock audit resolved [llength $accelerator_cells] accelerator cells; expected exactly one"
    }
    set accelerator_cell [get_property NAME [lindex $accelerator_cells 0]]
    set accelerator_registers [get_cells -quiet -hier -filter \
        "NAME =~ $accelerator_cell/* && (REF_NAME == FDRE || REF_NAME == FDSE)"]
    set accelerator_clock_pins [get_pins -quiet -of_objects \
        $accelerator_registers -filter {REF_PIN_NAME == C}]
    if {[llength $accelerator_clock_pins] == 0} {
        error "abi_v2_release $stage clock audit found no accelerator clock pins"
    }
    set clock_names [list]
    foreach clock_pin $accelerator_clock_pins {
        foreach clock_object [get_clocks -quiet -of_objects $clock_pin] {
            set clock_name [get_property NAME $clock_object]
            if {$clock_name ne "" && [lsearch -exact $clock_names $clock_name] < 0} {
                lappend clock_names $clock_name
            }
        }
    }
    set clock_names [lsort $clock_names]
    if {[llength $clock_names] != 1} {
        error "abi_v2_release $stage accelerator resolves clocks '$clock_names'; expected one"
    }
    set actual_period_ns [get_property PERIOD [get_clocks [lindex $clock_names 0]]]
    set tolerance_ns 0.001
    if {![string is double -strict $actual_period_ns] ||
        abs(double($actual_period_ns) - double($expected_period_ns)) >
            $tolerance_ns} {
        error "abi_v2_release $stage accelerator clock [lindex $clock_names 0] period=$actual_period_ns ns; expected $expected_period_ns +/- $tolerance_ns ns"
    }
    puts "ABI-v2 release clock audit PASS: stage=$stage clock=[lindex $clock_names 0] period_ns=$actual_period_ns expected_ns=$expected_period_ns"
    return [dict create clock_name [lindex $clock_names 0] \
        clock_period_ns $actual_period_ns]
}

# A managed run stopped with -to_step reports the *next* pending step in its
# STATUS/CURRENT_STEP fields.  Validate the completed step by its reset-safe
# run markers and checkpoint instead of matching the misleading STATUS text.
proc require_run_step_checkpoint {run_name step checkpoint_path} {
    set matching_runs [get_runs -quiet $run_name]
    if {[llength $matching_runs] != 1} {
        error "expected exactly one managed run '$run_name'; found [llength $matching_runs]"
    }
    set run [lindex $matching_runs 0]
    set run_dir [file normalize [get_property DIRECTORY $run]]
    set status [get_property STATUS $run]
    set progress [get_property PROGRESS $run]
    set current_step [get_property CURRENT_STEP $run]
    set needs_refresh [get_property NEEDS_REFRESH $run]
    puts "Managed run diagnostic: run=$run_name completed_step=$step status={$status} progress={$progress} current_step={$current_step} needs_refresh={$needs_refresh}"

    foreach error_marker [list \
            [file join $run_dir ".${step}.error.rst"] \
            [file join $run_dir .vivado.error.rst]] {
        if {[file exists $error_marker]} {
            error "managed run '$run_name' recorded an error marker: $error_marker"
        }
    }
    foreach success_marker [list \
            [file join $run_dir ".${step}.end.rst"] \
            [file join $run_dir .vivado.end.rst]] {
        if {![file isfile $success_marker]} {
            error "managed run '$run_name' is missing the $step completion marker: $success_marker"
        }
    }
    if {$needs_refresh ne "0"} {
        error "managed run '$run_name' completed $step with NEEDS_REFRESH=$needs_refresh"
    }
    set normalized_checkpoint [file normalize $checkpoint_path]
    if {![file isfile $normalized_checkpoint]} {
        error "managed run '$run_name' completed $step without its checkpoint: $normalized_checkpoint"
    }
    if {[file size $normalized_checkpoint] <= 0} {
        error "managed run '$run_name' produced an empty checkpoint: $normalized_checkpoint"
    }
    return $normalized_checkpoint
}

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-build_dir"} {
        incr i
        set build_dir [file normalize [lindex $argv $i]]
        set build_dir_explicit 1
    } elseif {$arg eq "-project_name"} {
        incr i
        set project_name [lindex $argv $i]
    } elseif {$arg eq "-bd_name"} {
        incr i
        set bd_name [lindex $argv $i]
    } elseif {$arg eq "-board_part"} {
        incr i
        set board_part [lindex $argv $i]
    } elseif {$arg eq "-board_connection"} {
        incr i
        set board_connection [lindex $argv $i]
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
    } elseif {$arg eq "-enable_legacy_gpio_status"} {
        incr i
        set enable_legacy_gpio_status [lindex $argv $i]
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
    } elseif {$arg eq "-weight_dma_mm2s_burst"} {
        incr i
        set weight_dma_mm2s_burst [lindex $argv $i]
    } elseif {$arg eq "-jobs"} {
        incr i
        set jobs [lindex $argv $i]
    } elseif {$arg eq "-synth_only"} {
        set synth_only 1
    } elseif {$arg eq "-place_only"} {
        set place_only 1
    } elseif {$arg eq "-reuse_synth"} {
        if {$release_profile} {
            error "$build_profile requires fresh synthesis; -reuse_synth is forbidden"
        }
        set reuse_synth 1
    } elseif {$arg eq "-check_only"} {
        set check_only 1
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
        set system_max_lut [lindex $argv $i]
    } elseif {$arg eq "-max_lut_memory"} {
        incr i
        set system_max_lut_memory [lindex $argv $i]
    } elseif {$arg eq "-max_clb_percent"} {
        incr i
        set system_max_clb_percent [lindex $argv $i]
    } elseif {$arg eq "-place_min_wns"} {
        incr i
        set system_place_min_wns [lindex $argv $i]
        set system_place_min_wns_explicit 1
    } elseif {$arg eq "-place_max_congestion_level"} {
        incr i
        set system_place_max_congestion_level [lindex $argv $i]
    } elseif {$arg eq "-max_bram"} {
        incr i
        set system_max_bram [lindex $argv $i]
    } elseif {$arg eq "-max_uram"} {
        incr i
        set system_max_uram [lindex $argv $i]
    } elseif {$arg eq "-expected_uram"} {
        incr i
        set system_expected_uram [lindex $argv $i]
    } elseif {$arg eq "-max_dsp"} {
        incr i
        set system_max_dsp [lindex $argv $i]
    } elseif {$arg eq "-min_wns"} {
        incr i
        set system_min_wns [lindex $argv $i]
        set system_min_wns_explicit 1
    } elseif {$arg eq "-min_tns"} {
        incr i
        set system_min_tns [lindex $argv $i]
    } elseif {$arg eq "-min_whs"} {
        incr i
        set system_min_whs [lindex $argv $i]
    } elseif {$arg eq "-min_ths"} {
        incr i
        set system_min_ths [lindex $argv $i]
    } elseif {$arg eq "-max_failing_endpoints"} {
        incr i
        set system_max_failing_endpoints [lindex $argv $i]
    } elseif {$arg eq "-max_hold_failing_endpoints"} {
        incr i
        set system_max_hold_failing_endpoints [lindex $argv $i]
    } elseif {$arg eq "-max_pulse_width_failing_endpoints"} {
        incr i
        set system_max_pulse_width_failing_endpoints [lindex $argv $i]
    } elseif {$arg eq "-max_unconstrained_paths"} {
        incr i
        set system_max_unconstrained_paths [lindex $argv $i]
    } elseif {$arg eq "-max_unclocked_fdre"} {
        incr i
        set system_max_unclocked_fdre [lindex $argv $i]
    } elseif {$arg eq "-max_accel_none_delay_endpoints"} {
        incr i
        set system_max_accel_none_delay_endpoints [lindex $argv $i]
    } elseif {$arg eq "-max_route_errors"} {
        incr i
        set system_max_route_errors [lindex $argv $i]
    } elseif {$arg eq "-max_drc_errors"} {
        incr i
        set system_max_drc_errors [lindex $argv $i]
    } elseif {$arg eq "-max_drc_critical_warnings"} {
        incr i
        set system_max_drc_critical_warnings [lindex $argv $i]
    } else {
        error "unknown argument: $arg"
    }
}

if {$synth_only && $place_only} {
    error "-synth_only and -place_only are mutually exclusive"
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
    if {!$build_dir_explicit} {
        error "development frequency sweep requires an explicit -build_dir"
    }
    if {$system_place_min_wns_explicit || $system_min_wns_explicit} {
        error "development frequency sweep derives -place_min_wns from one percent of the constrained period and fixes -min_wns at zero"
    }
    set pl_clock_mhz [::conv_accel_build::validate_development_clock_mhz \
        $development_clock_mhz]
    set metadata_profile [::conv_accel_build::frequency_sweep_profile_name \
        $development_clock_mhz]
    # A fixed release margin consumes an increasing fraction of the period as
    # frequency rises.  Development sweeps use one percent of the actual
    # 1 ps-quantized XDC period for post-place admission and require routed
    # timing closure at zero slack.  Every other release-derived gate remains
    # unchanged.
    set system_place_min_wns \
        [::conv_accel_build::development_post_place_min_wns $pl_clock_mhz]
    set system_min_wns 0.0
}

if {$build_profile ne "" && !$build_dir_explicit} {
    set build_dir [file join $root "build_system_xck26_kv260_${build_profile}"]
}
set build_dir [::conv_accel_build::require_nonpublication_build_dir \
    $root $build_dir]

if {$frequency_sweep} {
    set build_dir [::conv_accel_build::require_frequency_sweep_build_dir \
        $root $build_dir $development_clock_mhz]
} elseif {$release_profile} {
    set build_dir [::conv_accel_build::require_abi_v2_build_dir \
        $root $build_dir]
}

# A staged frequency sweep changes the physical PL clock, publication identity,
# and only the two internally derived WNS admission thresholds above.  It
# remains an ABI-v2 release topology with every other release gate and locked
# parameter enforced.
if {$release_profile} {
    if {$project_name ne "conv_accel_ps_dma_minimal"} {
        error "abi_v2_release locks project_name=conv_accel_ps_dma_minimal; got $project_name"
    }
    if {$bd_name ne "conv_accel_ps_dma"} {
        error "abi_v2_release locks bd_name=conv_accel_ps_dma; got $bd_name"
    }
    set release_defaults [::conv_accel_build::profile_defaults $build_profile]
    set release_locked_keys {
        board_part board_connection rows cols k_tile cout_tile
        enable_column_psum enable_packed_hwc_ofm
        enable_layer_tile_sequencer enable_layer_long_hwc_ifm
        enable_tagged_context enable_weight_preload
        enable_fast_context_handoff enable_detailed_trace
        enable_legacy_gpio_status ifm_banks ifm_fifo_depth ifm_fifo_aw
        psum_fifo_depth psum_fifo_aw hwc_cache_aw hwc_cache_depth
        hwc_cache_stripes hwc_cache_use_uram ifm_epoch_use_uram
        materialized_cache_aw materialized_cache_depth tail_cycles
        pl_clock_mhz weight_dma_mm2s_burst
        system_expected_uram
    }
    set release_actual [dict create \
        board_part $board_part \
        board_connection [list {*}$board_connection] \
        rows $rows cols $cols k_tile $k_tile cout_tile $cout_tile \
        enable_column_psum $enable_column_psum \
        enable_packed_hwc_ofm $enable_packed_hwc_ofm \
        enable_layer_tile_sequencer $enable_layer_tile_sequencer \
        enable_layer_long_hwc_ifm $enable_layer_long_hwc_ifm \
        enable_tagged_context $enable_tagged_context \
        enable_weight_preload $enable_weight_preload \
        enable_fast_context_handoff $enable_fast_context_handoff \
        enable_detailed_trace $enable_detailed_trace \
        enable_legacy_gpio_status $enable_legacy_gpio_status \
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
            [dict get $release_defaults pl_clock_mhz] : $pl_clock_mhz}] \
        weight_dma_mm2s_burst $weight_dma_mm2s_burst \
        system_expected_uram $system_expected_uram]
    ::conv_accel_build::require_no_violations "$build_profile system profile" \
        [::conv_accel_build::locked_value_violations \
            $release_defaults $release_actual $release_locked_keys]
    if {!$enforce_gates} {
        error "$build_profile system gates are mandatory"
    }
    if {$system_expected_uram ne "" &&
        $system_max_uram ne $system_expected_uram} {
        error "$build_profile requires max_uram=$system_expected_uram to match the exact URAM contract; got $system_max_uram"
    }
    set release_gate_keys {
        system_max_lut system_max_lut_memory system_max_clb_percent
        system_place_min_wns system_place_max_congestion_level
        system_max_bram system_max_uram system_expected_uram system_max_dsp
        system_min_wns system_min_tns system_min_whs system_min_ths
        system_max_failing_endpoints system_max_hold_failing_endpoints
        system_max_pulse_width_failing_endpoints
        system_max_unconstrained_paths system_max_unclocked_fdre
        system_max_accel_none_delay_endpoints
        system_max_route_errors system_max_drc_errors
        system_max_drc_critical_warnings
    }
    if {$frequency_sweep} {
        # These are the only intentional system-gate relaxations for a staged
        # frequency sweep.  Their values are internally derived above, and
        # explicit command-line overrides are forbidden.
        foreach key {system_place_min_wns system_min_wns} {
            set key_index [lsearch -exact $release_gate_keys $key]
            if {$key_index < 0} {
                error "internal error: frequency-sweep gate key is missing: $key"
            }
            set release_gate_keys [lreplace $release_gate_keys \
                $key_index $key_index]
        }
    }
    set release_gates [dict create \
        system_max_lut $system_max_lut \
        system_max_lut_memory $system_max_lut_memory \
        system_max_clb_percent $system_max_clb_percent \
        system_place_min_wns $system_place_min_wns \
        system_place_max_congestion_level \
        $system_place_max_congestion_level \
        system_max_bram $system_max_bram \
        system_max_uram $system_max_uram \
        system_expected_uram $system_expected_uram \
        system_max_dsp $system_max_dsp \
        system_min_wns $system_min_wns system_min_tns $system_min_tns \
        system_min_whs $system_min_whs system_min_ths $system_min_ths \
        system_max_failing_endpoints $system_max_failing_endpoints \
        system_max_hold_failing_endpoints \
            $system_max_hold_failing_endpoints \
        system_max_pulse_width_failing_endpoints \
            $system_max_pulse_width_failing_endpoints \
        system_max_unconstrained_paths $system_max_unconstrained_paths \
        system_max_unclocked_fdre $system_max_unclocked_fdre \
        system_max_accel_none_delay_endpoints \
            $system_max_accel_none_delay_endpoints \
        system_max_route_errors $system_max_route_errors \
        system_max_drc_errors $system_max_drc_errors \
        system_max_drc_critical_warnings $system_max_drc_critical_warnings]
    ::conv_accel_build::require_no_violations "$build_profile system gates" \
        [::conv_accel_build::gate_limit_relaxations \
            $release_defaults $release_gates $release_gate_keys]
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
::conv_accel_build::validate_bool ENABLE_LEGACY_GPIO_STATUS $enable_legacy_gpio_status
::conv_accel_build::validate_bool IFM_EPOCH_USE_URAM $ifm_epoch_use_uram
if {$enable_weight_preload && !$enable_tagged_context} {
    error "ENABLE_WEIGHT_PRELOAD requires ENABLE_TAGGED_CONTEXT=1"
}
if {$enable_fast_context_handoff && !$enable_weight_preload} {
    error "ENABLE_FAST_CONTEXT_HANDOFF requires ENABLE_WEIGHT_PRELOAD=1"
}
if {$release_profile && $enable_legacy_gpio_status != 0} {
    error "$build_profile statically removes the legacy GPIO/status service"
}
if {$build_profile eq "legacy_r18c8_debug" && $enable_legacy_gpio_status != 1} {
    error "legacy_r18c8_debug requires the legacy GPIO/status service"
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
set clock_hz [::conv_accel_build::clock_hz_from_mhz $pl_clock_mhz]
set clock_period_ns [::conv_accel_build::clock_period_ns_from_mhz \
    $pl_clock_mhz]
if {![string is integer -strict $weight_dma_mm2s_burst] ||
    $weight_dma_mm2s_burst < 2 || $weight_dma_mm2s_burst > 256 ||
    ($weight_dma_mm2s_burst & ($weight_dma_mm2s_burst - 1)) != 0} {
    error "weight DMA MM2S burst must be a power of two from 2 through 256"
}
if {$enforce_gates && ![::conv_accel_build::has_nonempty \
    $system_max_lut $system_max_lut_memory $system_max_clb_percent \
    $system_place_min_wns $system_place_max_congestion_level \
    $system_max_bram $system_max_uram $system_expected_uram $system_max_dsp \
    $system_min_wns $system_min_tns $system_min_whs $system_min_ths \
    $system_max_failing_endpoints $system_max_hold_failing_endpoints \
    $system_max_pulse_width_failing_endpoints \
    $system_max_unconstrained_paths $system_max_unclocked_fdre \
    $system_max_accel_none_delay_endpoints \
    $system_max_route_errors $system_max_drc_errors \
    $system_max_drc_critical_warnings]} {
    error "-enforce_gates requires at least one system gate threshold"
}

set rtl_source_count [::conv_accel_sources::validate $root]
set git_provenance [::conv_accel_build::git_provenance $root]
if {$check_only} {
    puts "PASS: system build configuration profile=[expr {$build_profile eq {} ? {custom_cli} : $build_profile}] metadata_profile=$metadata_profile rows=$rows cols=$cols cout_tile=$cout_tile tagged=$enable_tagged_context weight_preload=$enable_weight_preload fast_handoff=$enable_fast_context_handoff ifm_epoch_uram=$ifm_epoch_use_uram detailed_trace=$enable_detailed_trace legacy_gpio_status=$enable_legacy_gpio_status psum_fifo=$psum_fifo_depth clock_hz=$clock_hz weight_dma_mm2s_burst=$weight_dma_mm2s_burst place_min_wns=$system_place_min_wns route_min_wns=$system_min_wns synth_only=$synth_only place_only=$place_only gates=$enforce_gates git_sha=[dict get $git_provenance git_sha] git_dirty=[dict get $git_provenance git_dirty] sources=$rtl_source_count"
    exit
}
if {$build_profile ne ""} {
    ::conv_accel_build::require_vivado_version 2022.2
}
if {$release_profile} {
    set git_provenance [::conv_accel_build::require_clean_git $root]
}
set build_start_provenance $git_provenance

set wrapper_top "${bd_name}_wrapper"
set report_dir [file join $build_dir reports]
set stale_bit_file [file join $build_dir $project_name \
    "${project_name}.runs" impl_1 "${wrapper_top}.bit"]
::conv_accel_build::remove_stale_publications $build_dir [list \
    $stale_bit_file \
    [file join $build_dir "${project_name}.xsa"] \
    [file join $report_dir system_artifacts.sha256] \
    [file join $report_dir system_place.dcp] \
    [file join $report_dir system_place_artifacts.sha256] \
    [file join $report_dir system_place_utilization.rpt] \
    [file join $report_dir system_place_utilization_hier.rpt] \
    [file join $report_dir system_place_timing_summary.rpt] \
    [file join $report_dir system_place_accel_internal_none_fdre_audit.rpt] \
    [file join $report_dir system_place_accel_timing_summary.rpt] \
    [file join $report_dir system_place_congestion.rpt] \
    [file join $report_dir system_place_gate.txt] \
    [file join $report_dir system_impl_accel_internal_none_fdre_audit.rpt] \
    [file join $report_dir system_impl_accel_timing_summary.rpt] \
    [file join $report_dir system_impl_gate.txt] \
    [file join $report_dir system_synth_artifacts.sha256]]
file mkdir $report_dir

set vivado_version [version -short]
set release_multi_hp $release_profile
if {$release_multi_hp} {
    set dma_memory_port HP0_HP1_HP2_HP3
    set dma_memory_ports {HP0 HP1 HP2 HP3}
} else {
    set dma_memory_port HP0
    set dma_memory_ports {HP0}
}
set metadata [dict merge [dict create \
    project_name $project_name bd_name $bd_name \
    part xck26-sfvc784-2LV-c \
    board_part $board_part board_connection $board_connection \
    rows $rows cols $cols k_tile $k_tile \
    cout_tile $cout_tile enable_column_psum $enable_column_psum \
    enable_packed_hwc_ofm $enable_packed_hwc_ofm \
    enable_layer_tile_sequencer $enable_layer_tile_sequencer \
    enable_layer_long_hwc_ifm $enable_layer_long_hwc_ifm \
    enable_tagged_context $enable_tagged_context \
    enable_weight_preload $enable_weight_preload \
    enable_fast_context_handoff $enable_fast_context_handoff \
    enable_detailed_trace $enable_detailed_trace \
    enable_legacy_gpio_status $enable_legacy_gpio_status \
    ifm_line_words_invalid_value 0 \
    ifm_banks $ifm_banks ifm_fifo_depth $ifm_fifo_depth \
    ifm_fifo_aw $ifm_fifo_aw psum_fifo_depth $psum_fifo_depth \
    psum_fifo_aw $psum_fifo_aw hwc_cache_aw $hwc_cache_aw \
    hwc_cache_depth $hwc_cache_depth hwc_cache_stripes $hwc_cache_stripes \
    hwc_cache_use_uram $hwc_cache_use_uram \
    ifm_epoch_use_uram $ifm_epoch_use_uram \
    materialized_cache_aw $materialized_cache_aw \
    materialized_cache_depth $materialized_cache_depth \
    tail_cycles $tail_cycles pl_clock_mhz $pl_clock_mhz \
    clock_hz $clock_hz clock_period_ns [format %.6f $clock_period_ns] \
    source_profile $build_profile \
    release_eligible [::conv_accel_build::is_abi_v2_release_profile \
        $build_profile] \
    ablation_profile [::conv_accel_build::is_abi_v2_ablation_profile \
        $build_profile] \
    development_frequency_sweep $frequency_sweep \
    weight_dma_mm2s_burst $weight_dma_mm2s_burst \
    mm2s_dma_count 3 s2mm_dma_count 1 dma_data_width 64 \
    dma_memory_port $dma_memory_port dma_memory_ports $dma_memory_ports \
    ila_enabled 0] \
    $git_provenance [dict create vivado_version $vivado_version]]
if {$reuse_synth} {
    set prior_metadata [file join $build_dir build_profile.txt]
    if {[file isfile $prior_metadata]} {
        ::conv_accel_build::verify_build_metadata $prior_metadata \
            $build_profile $metadata
    } elseif {$build_profile ne ""} {
        error "profiled -reuse_synth requires build metadata: $prior_metadata"
    } else {
        puts "WARNING: reusing a legacy project without build metadata: $prior_metadata"
    }
    set project_file [file join $build_dir $project_name "${project_name}.xpr"]
    if {![file exists $project_file]} {
        error "-reuse_synth requested but project does not exist: $project_file"
    }
    open_project $project_file
    set synth_status [get_property STATUS [get_runs synth_1]]
    puts "Reusing synthesis status: $synth_status"
    if {![string match "*Complete*" $synth_status]} {
        error "-reuse_synth requested but synthesis is not complete: $synth_status"
    }
} else {
    # Generate a fresh block-design project with K26 SOM and KV260 carrier
    # Board Flow presets, including the carrier PS peripheral mapping.
    set saved_argv $argv
    # create_ps_dma_bd_xck26.tcl is sourced in this interpreter and applies
    # the source release profile in the global scope.  Preserve the two
    # effective system WNS gates so a development sweep's derived limits are
    # not replaced by the formal 200 MHz limits while generating the BD.
    set saved_system_wns_gates [dict create \
        system_place_min_wns $system_place_min_wns \
        system_min_wns $system_min_wns]
    set argv [list \
        -build_dir $build_dir \
        -project_name $project_name \
        -bd_name $bd_name \
        -board_part $board_part \
        -board_connection $board_connection \
        -rows $rows \
        -cols $cols \
        -k_tile $k_tile \
        -cout_tile $cout_tile \
        -enable_packed_hwc_ofm $enable_packed_hwc_ofm \
        -enable_layer_tile_sequencer $enable_layer_tile_sequencer \
        -enable_layer_long_hwc_ifm $enable_layer_long_hwc_ifm \
        -enable_tagged_context $enable_tagged_context \
        -enable_weight_preload $enable_weight_preload \
        -enable_fast_context_handoff $enable_fast_context_handoff \
        -enable_detailed_trace $enable_detailed_trace \
        -enable_legacy_gpio_status $enable_legacy_gpio_status \
        -ifm_banks $ifm_banks \
        -ifm_fifo_depth $ifm_fifo_depth \
        -ifm_fifo_aw $ifm_fifo_aw \
        -psum_fifo_depth $psum_fifo_depth \
        -psum_fifo_aw $psum_fifo_aw \
        -hwc_cache_aw $hwc_cache_aw \
        -hwc_cache_depth $hwc_cache_depth \
        -hwc_cache_stripes $hwc_cache_stripes \
        -hwc_cache_use_uram $hwc_cache_use_uram \
        -ifm_epoch_use_uram $ifm_epoch_use_uram \
        -materialized_cache_aw $materialized_cache_aw \
        -materialized_cache_depth $materialized_cache_depth \
        -tail_cycles $tail_cycles \
        -weight_dma_mm2s_burst $weight_dma_mm2s_burst \
        -jobs $jobs \
        -generate_targets \
    ]
    if {$build_profile ne ""} {
        lappend argv -profile $build_profile
    }
    if {$frequency_sweep} {
        lappend argv -development_clock_mhz $development_clock_mhz
    } else {
        lappend argv -pl_clock_mhz $pl_clock_mhz
    }
    source [file join $script_dir create_ps_dma_bd_xck26.tcl]
    set argv $saved_argv
    set system_place_min_wns \
        [dict get $saved_system_wns_gates system_place_min_wns]
    set system_min_wns [dict get $saved_system_wns_gates system_min_wns]
    unset saved_system_wns_gates

    set_property top $wrapper_top [current_fileset]
    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1

    puts "=== System synthesis: profile=[expr {$build_profile eq {} ? {custom_cli} : $build_profile}] top=$wrapper_top board=$board_part carrier=$board_connection rows=$rows cols=$cols cout_tile=$cout_tile enable_column_psum=$enable_column_psum enable_packed_hwc_ofm=$enable_packed_hwc_ofm enable_layer_tile_sequencer=$enable_layer_tile_sequencer enable_layer_long_hwc_ifm=$enable_layer_long_hwc_ifm enable_tagged_context=$enable_tagged_context enable_weight_preload=$enable_weight_preload enable_fast_context_handoff=$enable_fast_context_handoff ifm_epoch_use_uram=$ifm_epoch_use_uram enable_detailed_trace=$enable_detailed_trace enable_legacy_gpio_status=$enable_legacy_gpio_status tail_cycles=$tail_cycles jobs=$jobs ==="
    reset_run synth_1
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
    set synth_status [get_property STATUS [get_runs synth_1]]
    puts "Synthesis status: $synth_status"
    if {![string match "*Complete*" $synth_status]} {
        error "system synthesis did not complete: $synth_status"
    }

    open_run synth_1
    assert_abi_v2_release_has_no_debug_cores $build_profile post_synth
    assert_abi_v2_release_accel_clock $metadata_profile $clock_period_ns post_synth
    report_utilization -file [file join $report_dir system_synth_utilization.rpt]
    report_utilization -hierarchical -file [file join $report_dir system_synth_utilization_hier.rpt]
    report_timing_summary -file [file join $report_dir system_synth_timing_summary.rpt]
    close_design
}

if {$reuse_synth} {
    open_run synth_1
    assert_abi_v2_release_has_no_debug_cores $build_profile reused_post_synth
    assert_abi_v2_release_accel_clock $metadata_profile $clock_period_ns reused_post_synth
    report_utilization -file [file join $report_dir system_synth_utilization.rpt]
    report_utilization -hierarchical -file [file join $report_dir system_synth_utilization_hier.rpt]
    report_timing_summary -file [file join $report_dir system_synth_timing_summary.rpt]
    close_design
}

set build_record [dict merge $metadata [dict create \
        git_root_end pending git_sha_end pending git_dirty_end 1 \
        provenance_stable 0 \
        enforce_gates $enforce_gates \
        jobs $jobs synth_only $synth_only place_only $place_only \
        reuse_synth $reuse_synth \
        post_place_gate_step $post_place_gate_step \
        post_place_physopt_directive $post_place_physopt_directive \
        post_place_physopt_passes $post_place_physopt_passes \
        post_place_margin_uncertainty_ns $post_place_margin_uncertainty_ns \
        max_lut $system_max_lut max_lut_memory $system_max_lut_memory \
        max_clb_percent $system_max_clb_percent \
        place_min_wns $system_place_min_wns \
        place_max_congestion_level $system_place_max_congestion_level \
        max_bram $system_max_bram \
        max_uram $system_max_uram expected_uram $system_expected_uram \
        max_dsp $system_max_dsp \
        min_wns $system_min_wns min_tns $system_min_tns \
        min_whs $system_min_whs min_ths $system_min_ths \
        max_failing_endpoints $system_max_failing_endpoints \
        max_hold_failing_endpoints $system_max_hold_failing_endpoints \
        max_pulse_width_failing_endpoints \
            $system_max_pulse_width_failing_endpoints \
        max_unconstrained_paths $system_max_unconstrained_paths \
        max_unclocked_fdre $system_max_unclocked_fdre \
        max_accel_none_delay_endpoints $system_max_accel_none_delay_endpoints \
        max_route_errors $system_max_route_errors \
        max_drc_errors $system_max_drc_errors \
        max_drc_critical_warnings $system_max_drc_critical_warnings]]
::conv_accel_build::write_build_metadata \
    [file join $report_dir build_profile.txt] $metadata_profile $build_record

if {$synth_only} {
    if {$release_profile} {
        set end_git_provenance [::conv_accel_build::require_stable_clean_git \
            $root $build_start_provenance "$build_profile synthesis-only build"]
    } else {
        set end_git_provenance [::conv_accel_build::git_provenance $root]
    }
    set provenance_stable [::conv_accel_build::git_provenance_matches \
        $build_start_provenance $end_git_provenance]
    foreach key {git_root git_sha git_dirty} {
        dict set build_record "${key}_end" [dict get $end_git_provenance $key]
    }
    dict set build_record provenance_stable $provenance_stable
    ::conv_accel_build::write_build_metadata \
        [file join $report_dir build_profile.txt] $metadata_profile $build_record
    set synth_dcp [file join [get_property DIRECTORY [get_runs synth_1]] \
        "${wrapper_top}.dcp"]
    ::conv_accel_build::write_sha256_manifest \
        [file join $report_dir system_synth_artifacts.sha256] [list $synth_dcp]
    puts "=== Synthesis-only build complete ==="
    puts "Reports: $report_dir"
    exit
}

if {$place_only} {
    puts "=== System implementation through the post-place physical gate (route disabled by -place_only) ==="
} else {
    puts "=== System implementation through mandatory post-place gate ==="
}
reset_run impl_1
set impl_run [get_runs impl_1]
if {$release_profile} {
    set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl_run
    set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE \
        $post_place_physopt_directive $impl_run
    set_property STEPS.PHYS_OPT_DESIGN.TCL.POST \
        $post_place_physopt_hook $impl_run
    foreach {property expected} [list \
            STEPS.PHYS_OPT_DESIGN.IS_ENABLED 1 \
            STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE \
                $post_place_physopt_directive] {
        set actual [get_property $property $impl_run]
        if {$actual ne $expected} {
            error "managed implementation property $property=$actual; expected $expected"
        }
    }
    set actual_physopt_hook [file normalize \
        [get_property STEPS.PHYS_OPT_DESIGN.TCL.POST $impl_run]]
    if {$actual_physopt_hook ne $post_place_physopt_hook} {
        error "managed implementation phys-opt hook=$actual_physopt_hook; expected $post_place_physopt_hook"
    }
}
set impl_run_dir [file normalize [get_property DIRECTORY $impl_run]]
set post_place_run_checkpoint [file join $impl_run_dir \
    "${wrapper_top}_${post_place_checkpoint_suffix}.dcp"]
launch_runs impl_1 -to_step $post_place_gate_step -jobs $jobs
wait_on_run impl_1
set post_place_run_checkpoint [require_run_step_checkpoint impl_1 \
    $post_place_gate_step $post_place_run_checkpoint]
open_checkpoint $post_place_run_checkpoint
assert_abi_v2_release_has_no_debug_cores $build_profile post_place
assert_abi_v2_release_accel_clock $metadata_profile $clock_period_ns post_place
set place_util_report [file join $report_dir system_place_utilization.rpt]
set place_timing_report [file join $report_dir system_place_timing_summary.rpt]
set place_accel_internal_none_audit [file join $report_dir \
    system_place_accel_internal_none_fdre_audit.rpt]
set place_congestion_report [file join $report_dir system_place_congestion.rpt]
report_utilization -file $place_util_report
report_utilization -hierarchical \
    -file [file join $report_dir system_place_utilization_hier.rpt]
report_timing_summary -report_unconstrained -file $place_timing_report
::conv_accel_build::write_system_accel_internal_none_fdre_audit \
    $place_accel_internal_none_audit
report_design_analysis -congestion -min_congestion_level 3 \
    -file $place_congestion_report

if {$enforce_gates} {
    set place_metrics [::conv_accel_build::metrics_from_reports \
        $place_util_report $place_timing_report "" $place_congestion_report \
        $place_accel_internal_none_audit]
    set place_limits [dict create max_lut $system_max_lut \
        max_lut_memory $system_max_lut_memory \
        max_clb_percent $system_max_clb_percent \
        max_bram $system_max_bram max_uram $system_max_uram \
        expected_uram $system_expected_uram max_dsp $system_max_dsp \
        min_wns $system_place_min_wns \
        min_tns $system_min_tns \
        max_failing_endpoints $system_max_failing_endpoints \
        max_unconstrained_paths $system_max_unconstrained_paths \
        max_unclocked_fdre $system_max_unclocked_fdre \
        max_accel_internal_none_fdre_endpoints \
            $system_max_accel_none_delay_endpoints \
        max_congestion_level $system_place_max_congestion_level]
    ::conv_accel_build::enforce_report_gate SYSTEM_PLACE \
        [file join $report_dir system_place_gate.txt] \
        $place_metrics $place_limits
}
if {$release_profile} {
    set post_place_provenance [::conv_accel_build::require_stable_clean_git \
        $root $build_start_provenance "$build_profile pre-route build"]
} else {
    set post_place_provenance [::conv_accel_build::git_provenance $root]
}

if {$place_only} {
    set place_dcp [file join $report_dir system_place.dcp]
    set place_manifest [file join $report_dir system_place_artifacts.sha256]
    set place_publication_failed [catch {
        write_checkpoint -force $place_dcp
        close_design
        set provenance_stable [::conv_accel_build::git_provenance_matches \
            $build_start_provenance $post_place_provenance]
        foreach key {git_root git_sha git_dirty} {
            dict set build_record "${key}_end" \
                [dict get $post_place_provenance $key]
        }
        dict set build_record provenance_stable $provenance_stable
        ::conv_accel_build::write_build_metadata \
            [file join $report_dir build_profile.txt] $metadata_profile $build_record
        ::conv_accel_build::write_sha256_manifest $place_manifest \
            [list $place_dcp]
    } place_publication_error place_publication_options]
    if {$place_publication_failed} {
        catch {close_design}
        ::conv_accel_build::remove_stale_publications $build_dir \
            [list $place_dcp $place_manifest]
        return -options $place_publication_options $place_publication_error
    }
    puts "=== Place-only build complete; route and publication remain disabled ==="
    puts "Reports: $report_dir"
    puts "DCP: $place_dcp"
    exit
}
close_design

puts "=== Post-place gates passed; continuing implementation through route ==="
launch_runs impl_1 -to_step route_design -jobs $jobs
wait_on_run impl_1
set post_route_run_checkpoint [require_run_step_checkpoint impl_1 \
    route_design [file join $impl_run_dir "${wrapper_top}_routed.dcp"]]
open_checkpoint $post_route_run_checkpoint
assert_abi_v2_release_has_no_debug_cores $build_profile post_route
assert_abi_v2_release_accel_clock $metadata_profile $clock_period_ns post_route
set impl_util_report [file join $report_dir system_impl_utilization.rpt]
set impl_timing_report [file join $report_dir system_impl_timing_summary.rpt]
set impl_accel_internal_none_audit [file join $report_dir \
    system_impl_accel_internal_none_fdre_audit.rpt]
set impl_route_report [file join $report_dir system_impl_route_status.rpt]
set impl_congestion_report [file join $report_dir system_impl_congestion.rpt]
report_utilization -file $impl_util_report
report_utilization -hierarchical \
    -file [file join $report_dir system_impl_utilization_hier.rpt]
report_route_status -file $impl_route_report
report_timing_summary -report_unconstrained -file $impl_timing_report
::conv_accel_build::write_system_accel_internal_none_fdre_audit \
    $impl_accel_internal_none_audit
report_drc -ruledecks {default bitstream_checks} \
    -file [file join $report_dir system_impl_drc.rpt]
report_design_analysis -congestion -min_congestion_level 3 \
    -file $impl_congestion_report

if {$enforce_gates} {
    set impl_metrics [::conv_accel_build::metrics_from_reports \
        $impl_util_report $impl_timing_report $impl_route_report \
        $impl_congestion_report $impl_accel_internal_none_audit]
    set drc_error_count 0
    set drc_critical_warning_count 0
    foreach drc_violation [get_drc_violations -quiet] {
        set drc_severity [get_property SEVERITY $drc_violation]
        if {$drc_severity eq "Error"} {
            incr drc_error_count
        } elseif {$drc_severity eq "Critical Warning"} {
            incr drc_critical_warning_count
        }
    }
    dict set impl_metrics drc_errors $drc_error_count
    dict set impl_metrics drc_critical_warnings $drc_critical_warning_count
    set impl_limits [dict create max_lut $system_max_lut \
        max_lut_memory $system_max_lut_memory \
        max_clb_percent $system_max_clb_percent \
        max_bram $system_max_bram max_uram $system_max_uram \
        expected_uram $system_expected_uram max_dsp $system_max_dsp \
        min_wns $system_min_wns \
        min_tns $system_min_tns min_whs $system_min_whs \
        min_ths $system_min_ths \
        max_failing_endpoints $system_max_failing_endpoints \
        max_hold_failing_endpoints $system_max_hold_failing_endpoints \
        max_pulse_width_failing_endpoints \
            $system_max_pulse_width_failing_endpoints \
        max_unconstrained_paths $system_max_unconstrained_paths \
        max_unclocked_fdre $system_max_unclocked_fdre \
        max_accel_internal_none_fdre_endpoints \
            $system_max_accel_none_delay_endpoints \
        max_route_errors $system_max_route_errors \
        max_drc_errors $system_max_drc_errors \
        max_drc_critical_warnings $system_max_drc_critical_warnings]
    ::conv_accel_build::enforce_report_gate SYSTEM_IMPL \
        [file join $report_dir system_impl_gate.txt] \
        $impl_metrics $impl_limits
}
if {$release_profile} {
    ::conv_accel_build::require_stable_clean_git \
        $root $build_start_provenance "$build_profile post-route build"
}
close_design

if {[::conv_accel_build::is_abi_v2_ablation_profile $build_profile]} {
    puts "=== Post-route gates passed; emitting non-release ablation BIT/XSA and hashes ==="
} else {
    puts "=== Post-route gates passed; publishing bitstream, XSA, and hashes ==="
}
set xsa_file [file join $build_dir "${project_name}.xsa"]
set bit_file [file join [get_property DIRECTORY [get_runs impl_1]] \
    "${wrapper_top}.bit"]
set final_manifest [file join $report_dir system_artifacts.sha256]
set publication_failed [catch {
    launch_runs impl_1 -to_step write_bitstream -jobs $jobs
    wait_on_run impl_1
    set bit_status [get_property STATUS [get_runs impl_1]]
    puts "Bitstream status: $bit_status"
    if {![string match "*Complete*" $bit_status]} {
        error "system bitstream generation did not complete: $bit_status"
    }
    if {![file isfile $bit_file]} {
        error "write_bitstream completed without the expected artifact: $bit_file"
    }
    open_run impl_1
    write_hw_platform -fixed -include_bit -force $xsa_file
    close_design
    if {$release_profile} {
        set end_git_provenance [::conv_accel_build::require_stable_clean_git \
            $root $build_start_provenance \
            "$build_profile hardware publication"]
    } else {
        set end_git_provenance [::conv_accel_build::git_provenance $root]
    }
    set provenance_stable [::conv_accel_build::git_provenance_matches \
        $build_start_provenance $end_git_provenance]
    foreach key {git_root git_sha git_dirty} {
        dict set build_record "${key}_end" [dict get $end_git_provenance $key]
    }
    dict set build_record provenance_stable $provenance_stable
    ::conv_accel_build::write_build_metadata \
        [file join $report_dir build_profile.txt] $metadata_profile $build_record
    ::conv_accel_build::write_sha256_manifest $final_manifest \
        [list $bit_file $xsa_file]
} publication_error publication_options]
if {$publication_failed} {
    catch {close_design}
    ::conv_accel_build::remove_stale_publications $build_dir [list \
        $bit_file $xsa_file $final_manifest]
    return -options $publication_options $publication_error
}

puts "=== KV260 hardware platform build complete ==="
puts "Project: [file join $build_dir $project_name ${project_name}.xpr]"
puts "Reports: $report_dir"
puts "BIT: $bit_file"
puts "XSA: $xsa_file"

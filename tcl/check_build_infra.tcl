# Pure-Tcl static check for the canonical source manifest, profiles, report
# parsers, and SHA256 helper.  Run with: tclsh tcl/check_build_infra.tcl

set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
source [file join $script_dir rtl_sources.tcl]
source [file join $script_dir build_common.tcl]

proc require_child_tcl_status {expect_pass label script args} {
    set executable [info nameofexecutable]
    if {[string match -nocase {vivado*} \
            [file rootname [file tail $executable]]]} {
        # The static checker is valid both under tclsh and under Vivado.  A
        # Vivado executable needs launcher options before the script, so use a
        # plain Tcl child when available and retain a Vivado-safe fallback.
        set child_tclsh [auto_execok tclsh]
        if {$child_tclsh ne ""} {
            set command [concat $child_tclsh [list $script] $args]
        } else {
            set command [list $executable -mode batch -nojournal -nolog \
                -source $script -tclargs {*}$args]
        }
    } else {
        set command [list $executable $script {*}$args]
    }
    set failed [catch {exec {*}$command 2>@1} output]
    if {$expect_pass && $failed} {
        error "$label unexpectedly failed: $output"
    }
    if {!$expect_pass && !$failed} {
        error "$label unexpectedly passed: $output"
    }
    return $output
}

proc write_test_text {path text} {
    file mkdir [file dirname $path]
    set fh [open $path w]
    puts -nonewline $fh $text
    close $fh
}

set source_count [::conv_accel_sources::validate $root]
if {$source_count < 1} {
    error "canonical RTL manifest is empty"
}

set xsim_script [::conv_accel_build::read_text \
    [file join $script_dir run_xsim_regression.tcl]]
foreach required_text {
    {::conv_accel_build::require_vivado_version 2022.2}
    {::conv_accel_build::require_xsim_fixtures $root}
    {-include_diagnostic}
    {-layer_long_stream_cfg}
    {set effective_layer_long_stream_cfg bf}
    {`define TB_LAYER_LONG_STREAM_CFG 8'h${effective_layer_long_stream_cfg}}
    {layer_long_stream_cfg_overridden}
    {-i $root}
    {set xelab_debug [expr {$waves ? "typical" : "off"}]}
    {set xelab_optimization O2}
    {--$xelab_optimization}
    {-debug $xelab_debug}
    {-L xpm}
    {-L unisims_ver}
    {-top glbl}
    {data verilog src glbl.v}
    {set snapshot xsim_snapshot}
    {xsim_regression_driver_${run_id}.log}
    {dict get $metadata layer_long_stream_cfg}
    {layer_long.stream_cfg}
    {set source_provenance_clean [expr}
    {may not overwrite a canonical regression result}
    {proc atomic_publish {source target}}
    {run_complete 0}
    {release_gate_passed 0}
    {set release_gate_passed [expr}
    {unknown xsim test requested with -top}
    {failures[[:space:]]+detected}
} {
    if {[string first $required_text $xsim_script] < 0} {
        error "XSIM regression script is missing hardening text: $required_text"
    }
}

set xsim_wrapper [::conv_accel_build::read_text \
    [file join $root tb run_all_xsim_regression.ps1]]
foreach required_text {
    {$runTag =}
    {xsim_regression_driver_$runTag.log}
    {regression_reports\$runTag}
    {ConvertFrom-Json}
    {release_gate_passed}
    {canonical result published}
} {
    if {[string first $required_text $xsim_wrapper] < 0} {
        error "XSIM PowerShell wrapper is missing concurrent-log hardening text: $required_text"
    }
}
set xsim_tests [dict create]
foreach line [split $xsim_script "\n"] {
    if {![regexp {^\s*\{(tb_[A-Za-z0-9_]+)\s+(tb/tb_[A-Za-z0-9_]+\.v)(?:\s+diagnostic)?\}\s*$} \
        $line -> top relpath]} {
        continue
    }
    if {[dict exists $xsim_tests $top]} {
        error "duplicate XSIM top entry: $top"
    }
    if {[file rootname [file tail $relpath]] ne $top} {
        error "XSIM top/file mismatch: $top -> $relpath"
    }
    if {![file isfile [file join $root $relpath]]} {
        error "XSIM testbench does not exist: $relpath"
    }
    dict set xsim_tests $top $relpath
}
set tb_files [glob -nocomplain -directory [file join $root tb] tb_*.v]
set standalone_xsim_tests [dict create \
    tb_abi_v2_release_ten_layer_chain \
    [file join $root tcl run_abi_v2_chain_xsim.tcl]]
foreach path $tb_files {
    set top [file rootname [file tail $path]]
    if {![dict exists $xsim_tests $top] &&
        ![dict exists $standalone_xsim_tests $top]} {
        error "testbench missing from XSIM manifest: tb/[file tail $path]"
    }
    if {[dict exists $standalone_xsim_tests $top]} {
        set standalone_script [dict get $standalone_xsim_tests $top]
        if {![file isfile $standalone_script] ||
            [string first "set top $top" \
                [::conv_accel_build::read_text $standalone_script]] < 0} {
            error "standalone XSIM test has no matching runner: $top"
        }
    }
}
set xsim_test_count [dict size $xsim_tests]
set standalone_xsim_test_count [dict size $standalone_xsim_tests]
if {$xsim_test_count + $standalone_xsim_test_count != [llength $tb_files]} {
    error "XSIM gates cover [expr {$xsim_test_count + $standalone_xsim_test_count}] entries for [llength $tb_files] testbench files"
}

# A level-sensitive wait followed by a clock wait is not an AXIS transfer.
# TREADY may pulse between sampling edges, causing a source to advance without
# a real TVALID/TREADY handshake.  Sources must hold their beat and sample
# ready on posedge instead.
foreach path $tb_files {
    set tb_text [::conv_accel_build::read_text $path]
    if {[regexp -nocase \
            {wait\s*\([^\)\r\n]*tready[^\)\r\n]*\)\s*;\s*@\s*\(\s*posedge} \
            $tb_text]} {
        error "unsafe AXIS source handshake in tb/[file tail $path]: wait(tready) followed by @(posedge)"
    }
}
if {![regexp {\{tb_conv_accel_core_axi_lite_axis_stream_r18_c8_smoke\s+tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c8_smoke\.v\s+diagnostic\}} \
    $xsim_script]} {
    error "known-mismatch r18c8 smoke test must remain diagnostic"
}

# Keep the release boundary suite in the mandatory-stress population and lock
# the dimensions that give each wrapper its name.  The large-pixel cases use
# Cin=19 so their active-reset run necessarily owns a partial-PSUM bank.
foreach {top relpath required_tokens} {
    tb_conv_accel_axis_layer_long_release_p1_cin1024
    tb/tb_conv_accel_axis_layer_long_release_p1_cin1024.v {
        {`define TB_LAYER_LONG_CIN_TOTAL 1024}
        {`define TB_LAYER_LONG_FM_H 2}
        {`define TB_LAYER_LONG_FM_W 1}
        {`define TB_LAYER_LONG_TILE_H_MAX 1}
    }
    tb_conv_accel_axis_layer_long_release_p169_odd_cin3
    tb/tb_conv_accel_axis_layer_long_release_p169_odd_cin3.v {
        {`define TB_LAYER_LONG_CIN_TOTAL 3}
        {`define TB_LAYER_LONG_FM_H 26}
        {`define TB_LAYER_LONG_FM_W 13}
        {`define TB_LAYER_LONG_KERNEL_1X1 0}
        {`define TB_LAYER_LONG_TILE_H_MAX 13}
    }
    tb_conv_accel_axis_layer_long_release_p936
    tb/tb_conv_accel_axis_layer_long_release_p936.v {
        {`define TB_LAYER_LONG_CIN_TOTAL 19}
        {`define TB_LAYER_LONG_FM_H 48}
        {`define TB_LAYER_LONG_FM_W 39}
        {`define TB_LAYER_LONG_TILE_H_MAX 24}
    }
    tb_conv_accel_axis_layer_long_release_p1024
    tb/tb_conv_accel_axis_layer_long_release_p1024.v {
        {`define TB_LAYER_LONG_CIN_TOTAL 19}
        {`define TB_LAYER_LONG_FM_H 64}
        {`define TB_LAYER_LONG_FM_W 32}
        {`define TB_LAYER_LONG_TILE_H_MAX 32}
    }
} {
    if {![dict exists $xsim_tests $top] ||
        [dict get $xsim_tests $top] ne $relpath} {
        error "release boundary test is missing from the XSIM manifest: $top"
    }
    set stress_manifest_entry [format "{%s %s diagnostic}" $top $relpath]
    if {[string first $stress_manifest_entry $xsim_script] < 0} {
        error "release boundary test must remain mandatory stress: $top"
    }
    set boundary_text [::conv_accel_build::read_text [file join $root $relpath]]
    foreach token $required_tokens {
        if {[string first $token $boundary_text] < 0} {
            error "release boundary test $top is missing locked text: $token"
        }
    }
}

set release_e2e [::conv_accel_build::read_text \
    [file join $root tb tb_conv_accel_axis_layer_long_two_tile_e2e.v]]
foreach required_text {
    {`include "tail_cycles_override.vh"}
    {`define TB_LAYER_LONG_CIN_TOTAL 37}
    {`define TB_LAYER_LONG_STREAM_CFG 8'hbf}
    {localparam [7:0] RELEASE_STREAM_CFG = `TB_LAYER_LONG_STREAM_CFG;}
    {localparam integer EXPECTED_PSUM_TRANSFERS =}
    {u_psum_owner.wr_fire}
    {u_psum_owner.rd_fire}
    {run_active_datapath_reset_case(3);}
    {run_seed_case(3, 0, 0, 1);}
    {run_seed_case(11, 1, 1, 2);}
    {run_seed_case(29, 2, 1, 3);}
    {u_bank0.scrub_active}
    {u_bank1.scrub_active}
} {
    if {[string first $required_text $release_e2e] < 0} {
        error "release E2E is missing recovery/stress text: $required_text"
    }
}

set ofm_packer [::conv_accel_build::read_text \
    [file join $root systolic ofm_hwc_axis_packer.v]]
foreach required_text {
    {reg scrub_active;}
    {if (!reset_seen) begin}
    {wire committed_wr_en = scrub_active || committed_slot_update;}
    {(state == ST_FREE) && !scrub_active}
} {
    if {[string first $required_text $ofm_packer] < 0} {
        error "packed-OFM reset recovery is missing hardening text: $required_text"
    }
}

set chain_xsim_script [::conv_accel_build::read_text \
    [file join $script_dir run_abi_v2_chain_xsim.tcl]]
foreach required_text {
    {set top tb_abi_v2_release_ten_layer_chain}
    {::conv_accel_build::require_vivado_version 2022.2}
    {::conv_accel_build::require_xsim_fixtures $root}
    {set xelab_debug [expr {$waves ? "typical" : "off"}]}
    {set xelab_optimization O2}
    {--$xelab_optimization}
    {-debug $xelab_debug}
    {-L xpm}
    {-L unisims_ver}
    {-top glbl}
    {data verilog src glbl.v}
    {abi_v2_chain_results.json}
    {abi_v2_chain_results.junit.xml}
    {set canonical_candidate [expr}
    {::conv_accel_build::git_provenance_is_clean $provenance}
    {$provenance_stable}
    {set canonical_publish [expr {$canonical_candidate && $passed}]}
    {proc atomic_publish {source target}}
    {contexts 29253 compute_fire 3889197}
} {
    if {[string first $required_text $chain_xsim_script] < 0} {
        error "standalone ABI-v2 chain runner is missing hardening text: $required_text"
    }
}

set staged_chain_wrapper [::conv_accel_build::read_text \
    [file join $root tb run_abi_v2_staged_conv9_xsim.ps1]]
foreach required_text {
    {Get-OptionalSha256}
    {staged Conv9 runs modified the canonical ten-layer result}
} {
    if {[string first $required_text $staged_chain_wrapper] < 0} {
        error "staged Conv9 wrapper is missing canonical-result protection: $required_text"
    }
}

foreach profile [::conv_accel_build::profile_names] {
    set values [::conv_accel_build::profile_defaults $profile]
    foreach required {
        rows cols cout_tile enable_tagged_context enable_detailed_trace
        enable_legacy_gpio_status ifm_epoch_use_uram psum_fifo_depth
        psum_fifo_aw enforce_gates pl_clock_mhz weight_dma_mm2s_burst
    } {
        if {![dict exists $values $required]} {
            error "profile $profile is missing '$required'"
        }
    }
    if {[dict get $values cout_tile] != 2 * [dict get $values cols]} {
        error "profile $profile violates COUT_TILE=2*COLS"
    }
    if {(1 << [dict get $values psum_fifo_aw]) !=
        [dict get $values psum_fifo_depth]} {
        error "profile $profile has inconsistent PSUM FIFO depth/address width"
    }
    foreach bool_key {
        enable_tagged_context enable_weight_preload
        enable_fast_context_handoff enable_detailed_trace
        enable_legacy_gpio_status ifm_epoch_use_uram
    } {
        ::conv_accel_build::validate_bool $bool_key [dict get $values $bool_key]
    }
    set profile_clock_hz [::conv_accel_build::clock_hz_from_mhz \
        [dict get $values pl_clock_mhz]]
    if {$profile_clock_hz <= 0} {
        error "profile $profile has an invalid PL clock"
    }
}
set release [::conv_accel_build::profile_defaults abi_v2_release]
foreach {key expected} {
    board_part xilinx.com:kv260_som:part0:1.4
    pl_clock_mhz 100 weight_dma_mm2s_burst 64
    rows 18 cols 16 cout_tile 32 enable_packed_hwc_ofm 1
    enable_layer_tile_sequencer 1 enable_layer_long_hwc_ifm 1
    enable_tagged_context 1 enable_weight_preload 1
    enable_fast_context_handoff 1 enable_detailed_trace 0
    enable_legacy_gpio_status 0
    ifm_epoch_use_uram 1
    psum_fifo_depth 256 psum_fifo_aw 8 enforce_gates 1
    ooc_max_lut 83000 ooc_max_logic_lut 72000
    ooc_max_lut_memory 8000 ooc_max_clb_percent 85.0
    ooc_max_bram 90 ooc_max_uram 48
    ooc_max_dsp 720 ooc_min_wns 0.5 ooc_min_tns 0.0
    ooc_expected_uram {} ooc_max_congestion_level {}
    ooc_min_whs {} ooc_min_ths {}
    ooc_max_failing_endpoints {}
    ooc_max_hold_failing_endpoints {}
    ooc_max_pulse_width_failing_endpoints {}
    ooc_max_unconstrained_paths 0 ooc_max_unclocked_fdre 0
    ooc_max_internal_none_fdre_endpoints 0
    system_max_lut 90000
    system_max_lut_memory 8000 system_max_clb_percent 90.0
    system_place_min_wns 0.3 system_place_max_congestion_level 4
    system_max_dsp 720
    system_min_wns 0.1 system_min_tns 0.0
    system_min_whs 0.0 system_min_ths 0.0
    system_max_failing_endpoints 0
    system_max_hold_failing_endpoints 0
    system_max_pulse_width_failing_endpoints 0
    system_max_unconstrained_paths 0 system_max_unclocked_fdre 0
    system_max_accel_none_delay_endpoints 0
    system_max_route_errors 0 system_max_drc_errors 0
    system_max_drc_critical_warnings 0
} {
    if {[dict get $release $key] ne $expected} {
        error "abi_v2_release $key=[dict get $release $key], expected $expected"
    }
}
set release_200 [::conv_accel_build::profile_defaults abi_v2_release_200]
foreach {key expected} {
    pl_clock_mhz 200 weight_dma_mm2s_burst 64
    ooc_min_wns 0.0
    ooc_expected_uram 48 ooc_max_congestion_level 4
    ooc_min_whs 0.0 ooc_min_ths 0.0
    ooc_max_failing_endpoints 0
    ooc_max_hold_failing_endpoints 0
    ooc_max_pulse_width_failing_endpoints 0
    system_max_clb_percent 85.0
    system_place_min_wns 0.0 system_min_wns 0.0
    system_max_uram 48 system_expected_uram 48
} {
    if {[dict get $release_200 $key] ne $expected} {
        error "abi_v2_release_200 $key=[dict get $release_200 $key], expected $expected"
    }
}
foreach key [dict keys $release] {
    if {$key in {pl_clock_mhz ooc_min_wns ooc_expected_uram
            ooc_max_congestion_level ooc_min_whs ooc_min_ths
            ooc_max_failing_endpoints ooc_max_hold_failing_endpoints
            ooc_max_pulse_width_failing_endpoints system_max_clb_percent
            system_place_min_wns system_min_wns system_max_uram
            system_expected_uram}} {
        continue
    }
    if {[dict get $release_200 $key] ne [dict get $release $key]} {
        error "abi_v2_release_200 unexpectedly diverges at $key"
    }
}
foreach {profile expected} {
    abi_v2_release 1
    abi_v2_release_200 1
    abi_v2_ablation_200_a0 0
    abi_v2_ablation_200_a1 0
    abi_v2_ablation_200_a2 0
    legacy_r18c8_debug 0
    {} 0
} {
    if {[::conv_accel_build::is_abi_v2_release_profile $profile] !=
        $expected} {
        error "release-profile classifier rejected '$profile'"
    }
}
foreach profile {abi_v2_ablation_200_a0 abi_v2_ablation_200_a1
        abi_v2_ablation_200_a2} {
    if {![::conv_accel_build::is_abi_v2_ablation_profile $profile] ||
        ![::conv_accel_build::is_abi_v2_gated_profile $profile] ||
        [::conv_accel_build::is_abi_v2_release_profile $profile]} {
        error "ablation profile classifiers reject '$profile'"
    }
    set candidate [::conv_accel_build::profile_defaults $profile]
    foreach key [dict keys $release_200] {
        if {$key in {enable_layer_long_hwc_ifm enable_weight_preload
                enable_fast_context_handoff ooc_expected_uram
                system_expected_uram}} {
            continue
        }
        if {[dict get $candidate $key] ne [dict get $release_200 $key]} {
            error "$profile unexpectedly diverges at $key"
        }
    }
    foreach key {ooc_expected_uram system_expected_uram} {
        if {[dict get $candidate $key] ne {}} {
            error "$profile must report, not prescribe, the ablation URAM count"
        }
    }
}
foreach {profile long_ifm preload handoff} {
    abi_v2_ablation_200_a0 0 0 0
    abi_v2_ablation_200_a1 1 0 0
    abi_v2_ablation_200_a2 1 1 0
} {
    set candidate [::conv_accel_build::profile_defaults $profile]
    foreach {key expected} [list enable_layer_long_hwc_ifm $long_ifm \
            enable_tagged_context 1 enable_weight_preload $preload \
            enable_fast_context_handoff $handoff] {
        if {[dict get $candidate $key] != $expected} {
            error "$profile $key=[dict get $candidate $key], expected $expected"
        }
    }
}
if {[dict get $release board_connection] ne [list som240_1_connector \
    xilinx.com:kv260_carrier:som240_1_connector:1.3]} {
    error "abi_v2_release board_connection is not locked to the KV260 carrier"
}

set release_lock_keys {
    rows cols k_tile cout_tile enable_column_psum enable_packed_hwc_ofm
    enable_layer_tile_sequencer enable_layer_long_hwc_ifm
    enable_tagged_context enable_weight_preload
    enable_fast_context_handoff enable_detailed_trace ifm_banks
    ifm_fifo_depth ifm_fifo_aw psum_fifo_depth psum_fifo_aw
    hwc_cache_aw hwc_cache_depth hwc_cache_stripes hwc_cache_use_uram
    ifm_epoch_use_uram materialized_cache_aw materialized_cache_depth
    tail_cycles pl_clock_mhz weight_dma_mm2s_burst
}
if {[llength [::conv_accel_build::locked_value_violations \
    $release $release $release_lock_keys]] != 0} {
    error "release lock helper rejected the canonical profile"
}
set changed_release $release
dict set changed_release cols 8
if {[llength [::conv_accel_build::locked_value_violations \
    $release $changed_release $release_lock_keys]] != 1} {
    error "release lock helper did not detect a parameter downgrade"
}

set canonical_release_build_dir \
    [file join $root build_system_xck26_kv260_abi_v2_release]
if {[::conv_accel_build::require_abi_v2_build_dir \
        $root $canonical_release_build_dir] ne
    [file normalize $canonical_release_build_dir]} {
    error "ABI-v2 build-directory guard changed the canonical path"
}
set canonical_release_200_build_dir \
    [file join $root build_system_xck26_kv260_abi_v2_release_200]
if {[::conv_accel_build::require_abi_v2_build_dir \
        $root $canonical_release_200_build_dir] ne
    [file normalize $canonical_release_200_build_dir]} {
    error "ABI-v2 build-directory guard rejected the 200 MHz path"
}
foreach forbidden_build_dir [list \
        [file join $root release kv260_hwcreplay_22] \
        [file join $root build_system_xck26_kv260_legacy_r18c8_debug] \
        [file join $root build_legacy_abi_v2_release] \
        [file join $root systolic build_abi_v2_release] \
        [file join [file dirname $root] build_abi_v2_release]] {
    if {![catch {::conv_accel_build::require_abi_v2_build_dir \
            $root $forbidden_build_dir}]} {
        error "ABI-v2 build-directory guard accepted $forbidden_build_dir"
    }
}
foreach forbidden_publication_dir [list \
        [file join $root release] \
        [file join $root release kv260_hwcreplay_22]] {
    if {![catch {::conv_accel_build::require_nonpublication_build_dir \
            $root $forbidden_publication_dir}]} {
        error "publication-directory guard accepted $forbidden_publication_dir"
    }
}
set system_gate_keys {
    system_max_lut system_max_lut_memory system_max_clb_percent
    system_place_min_wns system_place_max_congestion_level
    system_max_bram system_max_uram system_max_dsp
    system_min_wns system_min_tns system_min_whs system_min_ths
    system_max_failing_endpoints system_max_hold_failing_endpoints
    system_max_pulse_width_failing_endpoints
    system_max_unconstrained_paths system_max_unclocked_fdre
    system_max_accel_none_delay_endpoints
    system_max_route_errors system_max_drc_errors
    system_max_drc_critical_warnings
}
set tighter_release $release
dict set tighter_release system_max_lut 89999
dict set tighter_release system_max_lut_memory 7999
dict set tighter_release system_max_clb_percent 89.9
dict set tighter_release system_place_min_wns 0.4
dict set tighter_release system_place_max_congestion_level 3
dict set tighter_release system_min_wns 0.2
dict set tighter_release system_max_bram 120
dict set tighter_release system_max_dsp 719
if {[llength [::conv_accel_build::gate_limit_relaxations \
    $release $tighter_release $system_gate_keys]] != 0} {
    error "release gate helper rejected tighter limits"
}
set relaxed_release $release
dict set relaxed_release system_max_lut 90001
dict set relaxed_release system_max_lut_memory 8001
dict set relaxed_release system_max_clb_percent 90.1
dict set relaxed_release system_place_min_wns 0.299
dict set relaxed_release system_place_max_congestion_level 5
dict set relaxed_release system_min_wns 0.099
dict set relaxed_release system_min_tns -0.001
dict set relaxed_release system_min_whs -0.001
dict set relaxed_release system_min_ths -0.001
dict set relaxed_release system_max_failing_endpoints 1
dict set relaxed_release system_max_hold_failing_endpoints 1
dict set relaxed_release system_max_pulse_width_failing_endpoints 1
dict set relaxed_release system_max_unconstrained_paths 1
dict set relaxed_release system_max_unclocked_fdre 1
dict set relaxed_release system_max_accel_none_delay_endpoints 1
dict set relaxed_release system_max_dsp 721
dict set relaxed_release system_max_route_errors 1
dict set relaxed_release system_max_drc_errors 1
dict set relaxed_release system_max_drc_critical_warnings 1
if {[llength [::conv_accel_build::gate_limit_relaxations \
    $release $relaxed_release $system_gate_keys]] != 19} {
    error "release gate helper did not detect every relaxed limit"
}
set legacy [::conv_accel_build::profile_defaults legacy_r18c8_debug]
foreach {key expected} {
    rows 18 cols 8 cout_tile 16 enable_packed_hwc_ofm 0
    enable_layer_tile_sequencer 0 enable_layer_long_hwc_ifm 0
    enable_tagged_context 0 enable_weight_preload 0
    enable_fast_context_handoff 0 enable_detailed_trace 1
    enable_legacy_gpio_status 1
    ifm_epoch_use_uram 0
    psum_fifo_depth 1024 psum_fifo_aw 10 enforce_gates 0
} {
    if {[dict get $legacy $key] ne $expected} {
        error "legacy_r18c8_debug $key=[dict get $legacy $key], expected $expected"
    }
}
if {[::conv_accel_build::prescan_profile -ooc -profile abi_v2_release] ne
    "abi_v2_release"} {
    error "profile pre-scan did not find abi_v2_release"
}
if {[::conv_accel_build::prescan_profile -ooc \
        -profile abi_v2_release_200] ne "abi_v2_release_200"} {
    error "profile pre-scan did not find abi_v2_release_200"
}
foreach {frequency expected_margin} {
    125 0.08000
    150 0.06667
    175 0.05714
    200 0.05000
} {
    set actual_margin \
        [::conv_accel_build::development_post_place_min_wns $frequency]
    if {abs(double($actual_margin) - double($expected_margin)) > 0.0000001} {
        error "${frequency} MHz development post-place margin=$actual_margin, expected $expected_margin"
    }
}

set synth_script [::conv_accel_build::read_text \
    [file join $script_dir run_synth_xck26.tcl]]
foreach required_text {
    {requires an explicit -ooc argument}
    {gates are mandatory; -no_gates is forbidden}
    {set perform_place 1}
    {set post_place_physopt_enabled [expr}
    {[::conv_accel_build::is_abi_v2_200_profile $build_profile] &&}
    {$out_of_context &&}
    {!$frequency_sweep}
    {!$frequency_sweep && !$disable_post_place_physopt}
    {-disable_post_place_physopt}
    {post_place_physopt_forced_off $disable_post_place_physopt}
    {$post_place_physopt_enabled ? {AggressiveExplore} : {disabled}}
    {phys_opt_design -directive $post_place_physopt_directive}
    {post_place_physopt_enabled $post_place_physopt_enabled}
    {post_place_physopt_directive $post_place_physopt_directive}
    {-generic "CLOCK_HZ=$clock_hz"}
    {set constrained_clock_period_ns [expr}
    {::conv_accel_build::development_post_place_min_wns}
    {development_post_place_margin_fraction}
    {-route is restricted to an out-of-context development frequency sweep}
    {phys_opt_design -directive AggressiveExplore}
    {route_design}
    {report_route_status -file $routed_route}
    {report_drc -ruledecks {default}}
    {::conv_accel_build::enforce_report_gate OOC_ROUTE}
    {max_route_errors 0 max_drc_errors 0}
    {read_xdc -mode out_of_context $clock_xdc_path}
    {get_clocks -quiet -of_objects [get_ports clk]}
    {constrained_clock_period_ns}
    {report_timing -delay_type max -max_paths 50 -sort_by group}
    {set timing_diagnostic_max_paths [expr}
    {[::conv_accel_build::is_abi_v2_200_profile $build_profile] ? 100 : 50}
    {report_timing -delay_type max -max_paths $timing_diagnostic_max_paths}
    {-nworst 1 -sort_by group -file $timing_diagnostic_report}
    {"${report_prefix}_timing_top${timing_diagnostic_max_paths}.rpt"}
    {timing_diagnostic_nworst 1}
    {expected_uram $ooc_expected_uram}
    {max_congestion_level $ooc_max_congestion_level}
    {$congestion_gate_report}
    {-report_unconstrained}
    {::conv_accel_build::write_ooc_internal_none_fdre_audit}
    {max_ooc_internal_none_fdre_endpoints}
    {ooc_internal_none_fdre_endpoints}
    {::conv_accel_build::locked_value_violations}
    {::conv_accel_build::gate_limit_relaxations}
    {_ooc${out_of_context}}
    {::conv_accel_build::remove_stale_publications $build_dir}
    {set git_provenance [::conv_accel_build::git_provenance $root]}
    {vivado_version [version -short]}
    {git_sha}
    {git_dirty}
    {-generic "IFM_EPOCH_USE_URAM=$ifm_epoch_use_uram"}
    {-generic "ENABLE_WEIGHT_PRELOAD=$enable_weight_preload"}
    {-generic "ENABLE_FAST_CONTEXT_HANDOFF=$enable_fast_context_handoff"}
    {enable_weight_preload $enable_weight_preload}
    {enable_fast_context_handoff $enable_fast_context_handoff}
    {ifm_epoch_use_uram $ifm_epoch_use_uram}
} {
    if {[string first $required_text $synth_script] < 0} {
        error "OOC build script is missing hardening text: $required_text"
    }
}
if {[string first {report_drc -ruledecks {default bitstream_checks}} \
        $synth_script] >= 0} {
    error "OOC route must not run the unconditional HDOOC bitstream_checks deck"
}
set read_verilog_pos [string first {read_verilog -sv $rtl_abs_files} \
    $synth_script]
set clock_xdc_pos [string first \
    {read_xdc -mode out_of_context $clock_xdc_path} $synth_script]
set ooc_cleanup_pos [string first \
    {::conv_accel_build::remove_stale_publications $build_dir} $synth_script]
set synth_pos [string first {synth_design {*}$synth_args} $synth_script]
set ooc_place_pos [string first {place_design} $synth_script $synth_pos]
set ooc_physopt_pos [string first \
    {phys_opt_design -directive $post_place_physopt_directive} \
    $synth_script $ooc_place_pos]
set ooc_util_report_pos [string first \
    {report_utilization -file "${report_prefix}_utilization.rpt"} \
    $synth_script $ooc_physopt_pos]
set timing_diagnostic_pos [string first \
    {report_timing -delay_type max -max_paths $timing_diagnostic_max_paths} \
    $synth_script $ooc_util_report_pos]
set congestion_report_pos [string first \
    {report_design_analysis -congestion -min_congestion_level 3} \
    $synth_script $timing_diagnostic_pos]
set gate_pos [string first \
    {::conv_accel_build::enforce_report_gate OOC} $synth_script]
set internal_none_audit_pos [string first \
    {[::conv_accel_build::write_ooc_internal_none_fdre_audit} \
    $synth_script]
set checkpoint_path_pos [string first \
    {set checkpoint_path [expr} $synth_script]
set checkpoint_pos [string first \
    {write_checkpoint -force $checkpoint_path} $synth_script]
set hash_pos [string first \
    {::conv_accel_build::write_sha256_manifest} $synth_script]
set clock_verify_pos [string first \
    {get_clocks -quiet -of_objects [get_ports clk]} $synth_script]
if {$read_verilog_pos < 0 || $clock_xdc_pos < 0 ||
    $clock_verify_pos < 0 || $ooc_cleanup_pos < 0 || $synth_pos < 0 ||
    $ooc_place_pos < 0 || $ooc_physopt_pos < 0 ||
    $ooc_util_report_pos < 0 || $timing_diagnostic_pos < 0 ||
    $congestion_report_pos < 0 || $internal_none_audit_pos < 0 ||
    $gate_pos < 0 || $checkpoint_path_pos < 0 ||
    $checkpoint_pos < 0 || $hash_pos < 0} {
    error "OOC build publication-order check could not find every operation"
}
if {$ooc_cleanup_pos >= $synth_pos} {
    error "stale OOC publications must be removed before synthesis"
}
if {$read_verilog_pos >= $clock_xdc_pos || $clock_xdc_pos >= $synth_pos ||
    $synth_pos >= $clock_verify_pos} {
    error "OOC clock XDC must load after RTL and before synthesis, with the period verified after synthesis"
}
if {$synth_pos >= $ooc_place_pos ||
    $ooc_place_pos >= $ooc_physopt_pos ||
    $ooc_physopt_pos >= $ooc_util_report_pos ||
    $ooc_util_report_pos >= $timing_diagnostic_pos ||
    $timing_diagnostic_pos >= $congestion_report_pos ||
    $congestion_report_pos >= $internal_none_audit_pos ||
    $internal_none_audit_pos >= $gate_pos ||
    $gate_pos >= $checkpoint_path_pos ||
    $checkpoint_path_pos >= $checkpoint_pos || $checkpoint_pos >= $hash_pos} {
    error "formal OOC checkpoint/SHA256 must be published after the gate"
}
set ooc_gate_contract_block [string range $synth_script \
    $internal_none_audit_pos $gate_pos]
foreach required_text {
    {$congestion_gate_report}
    {expected_uram $ooc_expected_uram}
    {max_congestion_level $ooc_max_congestion_level}
    {min_whs $ooc_min_whs min_ths $ooc_min_ths}
    {max_failing_endpoints $ooc_max_failing_endpoints}
    {max_hold_failing_endpoints $ooc_max_hold_failing_endpoints}
    {max_pulse_width_failing_endpoints}
} {
    if {[string first $required_text $ooc_gate_contract_block] < 0} {
        error "formal OOC report gate is missing contract text: $required_text"
    }
}
set route_physopt_pos [string first \
    {phys_opt_design -directive AggressiveExplore} $synth_script $hash_pos]
set route_design_pos [string first {route_design} $synth_script \
    $route_physopt_pos]
set route_report_pos [string first \
    {report_route_status -file $routed_route} $synth_script $route_design_pos]
set route_gate_pos [string first \
    {::conv_accel_build::enforce_report_gate OOC_ROUTE} $synth_script \
    $route_report_pos]
set routed_checkpoint_pos [string first \
    {write_checkpoint -force $routed_checkpoint} $synth_script \
    $route_gate_pos]
if {$route_physopt_pos < 0 || $route_design_pos < 0 ||
    $route_report_pos < 0 || $route_gate_pos < 0 ||
    $routed_checkpoint_pos < 0 || $hash_pos >= $route_physopt_pos ||
    $route_physopt_pos >= $route_design_pos ||
    $route_design_pos >= $route_report_pos ||
    $route_report_pos >= $route_gate_pos ||
    $route_gate_pos >= $routed_checkpoint_pos} {
    error "development OOC route reports/gate/checkpoint are not fail-closed ordered"
}

set resume_script_path [file join $script_dir resume_ooc_route_xck26.tcl]
set resume_script [::conv_accel_build::read_text $resume_script_path]
foreach required_text {
    {verify_single_artifact_manifest}
    {verify_source_bundle}
    {implementation_stage post_place}
    {source_profile $profile}
    {open_checkpoint [dict get $source_bundle placed_dcp]}
    {get_property PART $design_object}
    {get_property TOP $design_object}
    {get_clocks -quiet -of_objects $clock_ports}
    {phys_opt_design -directive AggressiveExplore}
    {route_design}
    {report_drc -ruledecks {default}}
    {::conv_accel_build::write_ooc_internal_none_fdre_audit}
    {::conv_accel_build::enforce_report_gate OOC_ROUTE}
    {qualification_status UNQUALIFIED}
    {formal_release_qualified 0}
    {resume_fresh_synth 0}
    {resume_fresh_place 0}
    {resume_fresh_route 1}
    {_UNQUALIFIED}
    {::conv_accel_build::write_sha256_manifest $routed_manifest}
} {
    if {[string first $required_text $resume_script] < 0} {
        error "OOC route resume script is missing hardening text: $required_text"
    }
}
if {[regexp -line {^\s*(synth_design|place_design)(\s|$)} $resume_script] ||
    [string first {report_drc -ruledecks {default bitstream_checks}} \
        $resume_script] >= 0} {
    error "OOC route resume must not synthesize/place or run bitstream_checks"
}
set resume_open_pos [string first \
    {open_checkpoint [dict get $source_bundle placed_dcp]} $resume_script]
set resume_physopt_pos [string first \
    {phys_opt_design -directive AggressiveExplore} $resume_script \
    $resume_open_pos]
set resume_route_pos [string first {route_design} $resume_script \
    $resume_physopt_pos]
set resume_report_pos [string first \
    {report_utilization -file $routed_util} $resume_script $resume_route_pos]
set resume_audit_pos [string first \
    {[::conv_accel_build::write_ooc_internal_none_fdre_audit} \
    $resume_script $resume_report_pos]
set resume_gate_pos [string first \
    {::conv_accel_build::enforce_report_gate OOC_ROUTE} $resume_script \
    $resume_audit_pos]
set resume_metadata_pos [string first \
    {::conv_accel_build::write_build_metadata $routed_metadata_path} \
    $resume_script $resume_gate_pos]
set resume_checkpoint_pos [string first \
    {write_checkpoint -force $routed_checkpoint} $resume_script \
    $resume_metadata_pos]
set resume_hash_pos [string first \
    {::conv_accel_build::write_sha256_manifest $routed_manifest} \
    $resume_script $resume_checkpoint_pos]
if {$resume_open_pos < 0 || $resume_physopt_pos < 0 ||
    $resume_route_pos < 0 || $resume_report_pos < 0 ||
    $resume_audit_pos < 0 || $resume_gate_pos < 0 ||
    $resume_metadata_pos < 0 || $resume_checkpoint_pos < 0 ||
    $resume_hash_pos < 0 || $resume_open_pos >= $resume_physopt_pos ||
    $resume_physopt_pos >= $resume_route_pos ||
    $resume_route_pos >= $resume_report_pos ||
    $resume_report_pos >= $resume_audit_pos ||
    $resume_audit_pos >= $resume_gate_pos ||
    $resume_gate_pos >= $resume_metadata_pos ||
    $resume_metadata_pos >= $resume_checkpoint_pos ||
    $resume_checkpoint_pos >= $resume_hash_pos} {
    error "OOC resume open/route/report/audit/gate/UNQUALIFIED publication order is not fail-closed"
}

set system_resume_script_path [file join $script_dir \
    resume_system_route_xck26.tcl]
set system_resume_script \
    [::conv_accel_build::read_text $system_resume_script_path]
foreach required_text {
    {13eeca8e6d4b1a0f696df7f75050faf5a08cb2cc}
    {1d5e2662e2c95b81ed32373486da2d9079a4ff92a8cd6838792444278fed1a80}
    {2bc7f58322c58ce164e70fcccd6c9d2b5e70baa4b708a9afb8d75e9590136398}
    {74a135849eeadc68eaeb6c0cc0b8f2301e6afa5966242f658560761c2b2ba21f}
    {3e9e42c4f055cd91a89e8e171eb8bc64d9947215b94547a4bd5d3b39668d6ff8}
    {2f0ba04caf15985e68964213337f8fc928c58268c9013064d25fa29f2b416cdf}
    {require_design_sources_unchanged}
    {require_prior_stages_unchanged}
    {resume Git SHA is}
    {open_checkpoint [dict get $bundle physopt]}
    {::conv_accel_build::write_system_accel_internal_none_fdre_audit $place_audit}
    {::conv_accel_build::enforce_report_gate SYSTEM_PLACE_RESUME}
    {open_project [dict get $bundle xpr]}
    {launch_runs impl_1 -to_step route_design -jobs $jobs}
    {::conv_accel_build::write_system_accel_internal_none_fdre_audit $impl_audit}
    {report_drc -ruledecks {default bitstream_checks}}
    {::conv_accel_build::enforce_report_gate SYSTEM_IMPL_RESUME}
    {launch_runs impl_1 -to_step write_bitstream -jobs $jobs}
    {write_hw_platform -fixed -include_bit -force $xsa_file}
    {qualification_status UNQUALIFIED}
    {formal_release_qualified 0}
    {release_eligible 0}
    {resume_source_git_sha $::system_route_resume::source_git_sha}
    {resume_git_sha [dict get $resume_start_git git_sha]}
    {foreach source_terminal_key}
    {git_root_end git_sha_end git_dirty_end provenance_stable}
    {dict unset metadata $source_terminal_key}
    {resume_fresh_synth 0}
    {resume_fresh_opt 0}
    {resume_fresh_place 0}
    {resume_fresh_physopt 0}
    {resume_fresh_route 1}
    {resume_prior_stage_hashes_stable 1}
    {::conv_accel_build::write_sha256_manifest $final_manifest}
} {
    if {[string first $required_text $system_resume_script] < 0} {
        error "system route-only resume is missing hardening text: $required_text"
    }
}
if {[regexp -line \
        {^\s*(synth_design|opt_design|place_design|phys_opt_design|reset_run)(\s|$)} \
        $system_resume_script]} {
    error "system route-only resume must not synthesize, optimize, place, phys-opt, or reset a run"
}
if {[regexp -all -line \
        {^\s*launch_runs\s+impl_1\s+-to_step\s+route_design(?:\s|$)} \
        $system_resume_script] != 1 ||
    [regexp -all -line \
        {^\s*launch_runs\s+impl_1\s+-to_step\s+write_bitstream(?:\s|$)} \
        $system_resume_script] != 1} {
    error "system resume must launch exactly one managed route and one bitstream step"
}
set system_resume_place_open_pos [string first \
    {open_checkpoint [dict get $bundle physopt]} $system_resume_script]
set system_resume_place_audit_pos [string first \
    {::conv_accel_build::write_system_accel_internal_none_fdre_audit $place_audit} \
    $system_resume_script $system_resume_place_open_pos]
set system_resume_place_gate_pos [string first \
    {::conv_accel_build::enforce_report_gate SYSTEM_PLACE_RESUME} \
    $system_resume_script $system_resume_place_audit_pos]
set system_resume_project_pos [string first \
    {open_project [dict get $bundle xpr]} $system_resume_script \
    $system_resume_place_gate_pos]
set system_resume_route_launch_pos [string first \
    {launch_runs impl_1 -to_step route_design -jobs $jobs} \
    $system_resume_script $system_resume_project_pos]
set system_resume_route_open_pos [string first {open_run impl_1} \
    $system_resume_script $system_resume_route_launch_pos]
set system_resume_route_audit_pos [string first \
    {::conv_accel_build::write_system_accel_internal_none_fdre_audit $impl_audit} \
    $system_resume_script $system_resume_route_open_pos]
set system_resume_route_gate_pos [string first \
    {::conv_accel_build::enforce_report_gate SYSTEM_IMPL_RESUME} \
    $system_resume_script $system_resume_route_audit_pos]
set system_resume_bit_pos [string first \
    {launch_runs impl_1 -to_step write_bitstream -jobs $jobs} \
    $system_resume_script $system_resume_route_gate_pos]
set system_resume_xsa_pos [string first \
    {write_hw_platform -fixed -include_bit -force $xsa_file} \
    $system_resume_script $system_resume_bit_pos]
set system_resume_unqualified_pos [string first \
    {qualification_status UNQUALIFIED} $system_resume_script \
    $system_resume_xsa_pos]
set system_resume_metadata_pos [string first \
    {::conv_accel_build::write_build_metadata $metadata_temporary} \
    $system_resume_script $system_resume_unqualified_pos]
set system_resume_manifest_pos [string first \
    {::conv_accel_build::write_sha256_manifest $final_manifest} \
    $system_resume_script $system_resume_metadata_pos]
set system_resume_publish_pos [string first \
    {file rename -force -- $metadata_temporary $final_metadata} \
    $system_resume_script $system_resume_manifest_pos]
set system_resume_positions [list $system_resume_place_open_pos \
    $system_resume_place_audit_pos $system_resume_place_gate_pos \
    $system_resume_project_pos $system_resume_route_launch_pos \
    $system_resume_route_open_pos $system_resume_route_audit_pos \
    $system_resume_route_gate_pos $system_resume_bit_pos \
    $system_resume_xsa_pos $system_resume_unqualified_pos \
    $system_resume_metadata_pos $system_resume_manifest_pos \
    $system_resume_publish_pos]
set previous_position -1
foreach position $system_resume_positions {
    if {$position < 0 || $position <= $previous_position} {
        error "system route-only resume place/route/gate/bit/XSA/UNQUALIFIED publication order is not fail-closed"
    }
    set previous_position $position
}

set system_script [::conv_accel_build::read_text \
    [file join $script_dir build_kv260_system_xck26.tcl]]
foreach required_text {
    {::conv_accel_build::require_clean_git $root}
    {::conv_accel_build::require_stable_clean_git}
    {requires fresh synthesis; -reuse_synth is forbidden}
    {gates are mandatory; -no_gates is forbidden}
    {abi_v2_release locks project_name=conv_accel_ps_dma_minimal}
    {abi_v2_release locks bd_name=conv_accel_ps_dma}
    {::conv_accel_build::locked_value_violations}
    {::conv_accel_build::gate_limit_relaxations}
    {system_place_min_wns_explicit}
    {system_min_wns_explicit}
    {::conv_accel_build::development_post_place_min_wns $pl_clock_mhz}
    {foreach key {system_place_min_wns system_min_wns}}
    {place_min_wns $system_place_min_wns}
    {min_wns $system_min_wns}
    {assert_abi_v2_release_has_no_debug_cores $build_profile post_synth}
    {assert_abi_v2_release_has_no_debug_cores $build_profile post_place}
    {assert_abi_v2_release_has_no_debug_cores $build_profile post_route}
    {proc assert_abi_v2_release_accel_clock}
    {assert_abi_v2_release_accel_clock $metadata_profile $clock_period_ns post_synth}
    {assert_abi_v2_release_accel_clock $metadata_profile $clock_period_ns post_place}
    {assert_abi_v2_release_accel_clock $metadata_profile $clock_period_ns post_route}
    {foreach clock_pin $accelerator_clock_pins}
    {get_clocks -quiet -of_objects $clock_pin}
    {set tolerance_ns 0.001}
    {get_debug_cores -quiet}
    {::conv_accel_build::remove_stale_publications $build_dir}
    {report_utilization -hierarchical}
    {report_timing_summary -file}
    {report_route_status -file}
    {report_drc -ruledecks {default bitstream_checks}}
    {get_property SEVERITY $drc_violation}
    {dict set impl_metrics drc_critical_warnings}
    {report_design_analysis -congestion}
    {-min_congestion_level 3}
    {proc require_run_step_checkpoint {run_name step checkpoint_path}}
    {[file join $run_dir ".${step}.end.rst"]}
    {[file join $run_dir ".${step}.error.rst"]}
    {[file join $run_dir .vivado.end.rst]}
    {[file join $run_dir .vivado.error.rst]}
    {post_place_gate_step phys_opt_design}
    {post_place_checkpoint_suffix physopt}
    {STEPS.PHYS_OPT_DESIGN.IS_ENABLED}
    {STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE}
    {STEPS.PHYS_OPT_DESIGN.TCL.POST}
    {abi_v2_margin_physopt_post.tcl}
    {launch_runs impl_1 -to_step $post_place_gate_step}
    {open_checkpoint $post_place_run_checkpoint}
    {open_checkpoint $post_route_run_checkpoint}
    {max_failing_endpoints $system_max_failing_endpoints}
    {max_drc_errors $system_max_drc_errors}
    {max_drc_critical_warnings $system_max_drc_critical_warnings}
    {git_sha}
    {git_dirty}
    {vivado_version}
    {mm2s_dma_count 3 s2mm_dma_count 1}
    {set release_multi_hp $release_profile}
    {set dma_memory_ports {HP0 HP1 HP2 HP3}}
    {dma_memory_port $dma_memory_port dma_memory_ports $dma_memory_ports}
    {-enable_weight_preload $enable_weight_preload}
    {-enable_fast_context_handoff $enable_fast_context_handoff}
    {enable_weight_preload $enable_weight_preload}
    {enable_fast_context_handoff $enable_fast_context_handoff}
    {-synth_only and -place_only are mutually exclusive}
    {system_place_artifacts.sha256}
    {-report_unconstrained}
    {::conv_accel_build::write_system_accel_internal_none_fdre_audit}
    {$place_accel_internal_none_audit}
    {$impl_accel_internal_none_audit}
    {max_accel_internal_none_fdre_endpoints}
    {-pl_clock_mhz $pl_clock_mhz}
    {-weight_dma_mm2s_burst $weight_dma_mm2s_burst}
    {set saved_system_wns_gates [dict create}
    {[dict get $saved_system_wns_gates system_place_min_wns]}
    {[dict get $saved_system_wns_gates system_min_wns]}
} {
    if {[string first $required_text $system_script] < 0} {
        error "system build script is missing fail-closed text: $required_text"
    }
}
if {[regexp {report_timing_summary[^\n]*-cells} $system_script] ||
    [string first {report_accel_scoped_timing_summary} $system_script] >= 0} {
    error "system accelerator unconstrained-path gate must not use a hierarchy-scoped timing report"
}
set system_bd_source_pos [string first \
    {source [file join $script_dir create_ps_dma_bd_xck26.tcl]} \
    $system_script]
set system_gate_snapshot_pos [string first \
    {set saved_system_wns_gates [dict create} $system_script]
set system_place_gate_restore_pos [string first \
    {[dict get $saved_system_wns_gates system_place_min_wns]} \
    $system_script $system_bd_source_pos]
set system_route_gate_restore_pos [string first \
    {[dict get $saved_system_wns_gates system_min_wns]} \
    $system_script $system_place_gate_restore_pos]
set system_gate_snapshot_unset_pos [string first \
    {unset saved_system_wns_gates} $system_script \
    $system_route_gate_restore_pos]
if {$system_gate_snapshot_pos < 0 || $system_bd_source_pos < 0 ||
    $system_place_gate_restore_pos < 0 ||
    $system_route_gate_restore_pos < 0 ||
    $system_gate_snapshot_unset_pos < 0 ||
    $system_gate_snapshot_pos >= $system_bd_source_pos ||
    $system_bd_source_pos >= $system_place_gate_restore_pos ||
    $system_place_gate_restore_pos >= $system_route_gate_restore_pos ||
    $system_route_gate_restore_pos >= $system_gate_snapshot_unset_pos} {
    error "system build must restore the effective place/route WNS gates after the global-scope BD generator"
}
set system_build_record_pos [string first \
    {set build_record [dict merge $metadata} $system_script]
set system_metadata_write_pos [string first \
    {::conv_accel_build::write_build_metadata} $system_script \
    $system_build_record_pos]
if {$system_build_record_pos < 0 || $system_metadata_write_pos < 0} {
    error "system build metadata construction/publication is missing"
}
foreach binding {
    {place_min_wns $system_place_min_wns}
    {min_wns $system_min_wns}
} {
    set binding_pos [string first $binding $system_script \
        $system_build_record_pos]
    if {$binding_pos < $system_build_record_pos ||
        $binding_pos > $system_metadata_write_pos} {
        error "system build metadata does not bind the effective WNS gate: $binding"
    }
}
if {[string first {$metadata_profile $build_record} $system_script \
        $system_metadata_write_pos] < 0} {
    error "system build metadata does not publish the effective sweep profile"
}
if {[regexp -all -- {-min_congestion_level 3} $system_script] != 2} {
    error "system build must request congestion reporting from level 3 at both the post-place and post-route gates"
}
if {[regexp -all -- {-min_congestion_level 3} $synth_script] != 2} {
    error "release OOC build must request congestion reporting from level 3 at post-place and development post-route"
}

set margin_physopt_hook_path [file join $script_dir \
    abi_v2_margin_physopt_post.tcl]
if {![file isfile $margin_physopt_hook_path]} {
    error "ABI-v2 margin phys-opt hook is missing: $margin_physopt_hook_path"
}
set margin_physopt_hook [::conv_accel_build::read_text \
    $margin_physopt_hook_path]
foreach required_text {
    {NAME =~ "*/accel/inst"}
    {REF_NAME == FDRE || REF_NAME == FDSE}
    {get_clocks -quiet -of_objects}
    {IS_GENERATED}
    {generated accelerator clock $margin_clock_name period=}
    {expected 5.000 +/- 0.001 ns}
    {set margin_saved_uu [get_property USER_UNCERTAINTY}
    {-from $margin_clock -to $margin_clock}
    {set_clock_uncertainty -setup 0.450 $margin_clock}
    {expected exactly 0.450 ns}
    {phys_opt_design -directive AggressiveExplore}
    {set_clock_uncertainty -setup $margin_saved_uu $margin_clock}
    {expected saved value $margin_saved_uu ns}
    {return -options $margin_options $margin_error}
} {
    if {[string first $required_text $margin_physopt_hook] < 0} {
        error "ABI-v2 margin phys-opt hook is missing fail-closed text: $required_text"
    }
}
foreach forbidden_text {
    {clk_pl_0}
    {clk_out1_}
    {requires initial USER_UNCERTAINTY=0.000 ns}
    {set_clock_uncertainty -setup 0.000}
} {
    if {[string first $forbidden_text $margin_physopt_hook] >= 0} {
        error "ABI-v2 margin phys-opt hook must dynamically resolve the accelerator generated clock; found fixed clock text: $forbidden_text"
    }
}
if {[regexp -line {^\s*(::)?(write_checkpoint|close_design|exit)(\s|$)} \
        $margin_physopt_hook -> _ forbidden_command]} {
    error "ABI-v2 margin phys-opt hook must leave managed-run lifecycle control to Vivado: $forbidden_command"
}
set margin_timing_query_count [regexp -all -- \
    {get_timing_paths\s+-quiet\s+-delay_type\s+max} \
    $margin_physopt_hook]
set margin_scoped_query_count [regexp -all -- \
    {-from\s+\$margin_clock\s+-to\s+\$margin_clock} \
    $margin_physopt_hook]
if {$margin_timing_query_count != 4 ||
    $margin_scoped_query_count != $margin_timing_query_count} {
    error "ABI-v2 margin phys-opt hook must scope all four setup-path audits to the resolved accelerator clock"
}
if {[regexp -all -- \
        {set_clock_uncertainty\s+-setup} $margin_physopt_hook] != 2} {
    error "ABI-v2 margin phys-opt hook must contain exactly one tighten and one restore setup-uncertainty command"
}
if {[regexp -all -- \
        {double\(\$margin_tight(_post)?_uu\) != 0\.450} \
        $margin_physopt_hook] != 2} {
    error "ABI-v2 margin phys-opt hook must verify exact 0.450 ns uncertainty before and after the tightened pass"
}
set margin_resolve_pos [string first \
    {set margin_clock [lindex $margin_clocks 0]} $margin_physopt_hook]
set margin_generated_period_pos [string first \
    {generated accelerator clock $margin_clock_name period=} \
    $margin_physopt_hook $margin_resolve_pos]
set margin_save_pos [string first \
    {set margin_saved_uu [get_property USER_UNCERTAINTY} \
    $margin_physopt_hook $margin_generated_period_pos]
set margin_tighten_pos [string first \
    {set_clock_uncertainty -setup 0.450 $margin_clock} \
    $margin_physopt_hook $margin_save_pos]
set margin_opt_pos [string first \
    {phys_opt_design -directive AggressiveExplore} \
    $margin_physopt_hook $margin_tighten_pos]
set margin_restore_pos [string first \
    {set_clock_uncertainty -setup $margin_saved_uu $margin_clock} \
    $margin_physopt_hook $margin_opt_pos]
set margin_restore_verify_pos [string first \
    {double($margin_restored_uu) != double($margin_saved_uu)} \
    $margin_physopt_hook $margin_restore_pos]
if {!($margin_resolve_pos >= 0 &&
      $margin_resolve_pos < $margin_generated_period_pos &&
      $margin_generated_period_pos < $margin_save_pos &&
      $margin_save_pos < $margin_tighten_pos &&
      $margin_tighten_pos < $margin_opt_pos &&
      $margin_opt_pos < $margin_restore_pos &&
      $margin_restore_pos < $margin_restore_verify_pos)} {
    error "ABI-v2 margin phys-opt hook must resolve, save, tighten, optimize, restore, and verify in order"
}
set clean_pos [string first \
    {::conv_accel_build::require_clean_git $root} $system_script]
set cleanup_pos [string first \
    {::conv_accel_build::remove_stale_publications $build_dir} $system_script]
set physopt_config_pos [string first \
    {set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl_run} \
    $system_script $cleanup_pos]
set place_pos [string first \
    {launch_runs impl_1 -to_step $post_place_gate_step} $system_script]
set place_completion_pos [string first \
    {set post_place_run_checkpoint [require_run_step_checkpoint impl_1} \
    $system_script $place_pos]
set place_open_pos [string first \
    {open_checkpoint $post_place_run_checkpoint} \
    $system_script $place_completion_pos]
set place_report_pos [string first \
    {report_utilization -file $place_util_report} $system_script]
set place_accel_audit_pos [string first \
    {::conv_accel_build::write_system_accel_internal_none_fdre_audit} \
    $system_script $place_report_pos]
set place_gate_pos [string first \
    {::conv_accel_build::enforce_report_gate SYSTEM_PLACE} $system_script]
set pre_route_provenance_pos [string first \
    {"$build_profile pre-route build"} $system_script $place_gate_pos]
set place_dcp_pos [string first \
    {set place_dcp [file join $report_dir system_place.dcp]} \
    $system_script $place_gate_pos]
set place_checkpoint_pos [string first \
    {write_checkpoint -force $place_dcp} $system_script $place_dcp_pos]
set place_hash_pos [string first \
    {::conv_accel_build::write_sha256_manifest $place_manifest} \
    $system_script $place_checkpoint_pos]
set place_complete_pos [string first \
    {=== Place-only build complete; route and publication remain disabled ===} \
    $system_script $place_hash_pos]
set place_exit_pos [string first {    exit} \
    $system_script $place_complete_pos]
set route_pos [string first \
    {launch_runs impl_1 -to_step route_design} $system_script]
set route_completion_pos [string first \
    {set post_route_run_checkpoint [require_run_step_checkpoint impl_1} \
    $system_script $route_pos]
set route_open_pos [string first \
    {open_checkpoint $post_route_run_checkpoint} \
    $system_script $route_completion_pos]
set report_pos [string first \
    {report_utilization -file $impl_util_report} \
    $system_script]
set impl_accel_audit_pos [string first \
    {::conv_accel_build::write_system_accel_internal_none_fdre_audit} \
    $system_script $report_pos]
set system_gate_pos [string first \
    {::conv_accel_build::enforce_report_gate SYSTEM_IMPL} $system_script]
set post_route_provenance_pos [string first \
    {"$build_profile post-route build"} $system_script]
set bitstream_pos [string first \
    {launch_runs impl_1 -to_step write_bitstream} $system_script]
set xsa_pos [string first \
    {write_hw_platform -fixed -include_bit -force $xsa_file} $system_script]
set publication_provenance_pos [string first \
    {"$build_profile hardware publication"} $system_script]
set system_hash_pos [string first \
    {::conv_accel_build::write_sha256_manifest} $system_script $xsa_pos]
foreach {label position} [list clean $clean_pos cleanup $cleanup_pos \
        physopt_config $physopt_config_pos place $place_pos \
        place_completion $place_completion_pos place_open $place_open_pos \
        place_report $place_report_pos \
        place_accel_audit $place_accel_audit_pos \
        place_gate $place_gate_pos pre_route_provenance $pre_route_provenance_pos \
        place_dcp $place_dcp_pos place_checkpoint $place_checkpoint_pos \
        place_hash $place_hash_pos place_complete $place_complete_pos \
        place_exit $place_exit_pos \
        route $route_pos route_completion $route_completion_pos \
        route_open $route_open_pos report $report_pos \
        impl_accel_audit $impl_accel_audit_pos \
        gate $system_gate_pos \
        post_route_provenance $post_route_provenance_pos \
        bitstream $bitstream_pos xsa $xsa_pos \
        publication_provenance $publication_provenance_pos \
        hash $system_hash_pos] {
    if {$position < 0} {
        error "system publication-order check could not find $label"
    }
}
if {!($clean_pos < $cleanup_pos && $cleanup_pos < $physopt_config_pos &&
      $physopt_config_pos < $place_pos &&
      $place_pos < $place_completion_pos &&
      $place_completion_pos < $place_open_pos &&
      $place_open_pos < $place_report_pos &&
      $place_report_pos < $place_accel_audit_pos &&
      $place_accel_audit_pos < $place_gate_pos &&
      $place_gate_pos < $pre_route_provenance_pos &&
      $pre_route_provenance_pos < $place_dcp_pos &&
      $place_dcp_pos < $place_checkpoint_pos &&
      $place_checkpoint_pos < $place_hash_pos &&
      $place_hash_pos < $place_complete_pos &&
      $place_complete_pos < $place_exit_pos && $place_exit_pos < $route_pos &&
      $route_pos < $route_completion_pos &&
      $route_completion_pos < $route_open_pos &&
      $route_open_pos < $report_pos &&
      $report_pos < $impl_accel_audit_pos &&
      $impl_accel_audit_pos < $system_gate_pos &&
      $system_gate_pos < $post_route_provenance_pos &&
      $post_route_provenance_pos < $bitstream_pos &&
      $bitstream_pos < $xsa_pos &&
      $xsa_pos < $publication_provenance_pos &&
      $publication_provenance_pos < $system_hash_pos)} {
    error "system artifacts must pass place and route gates before publication"
}

set bd_script [::conv_accel_build::read_text \
    [file join $script_dir create_ps_dma_bd_xck26.tcl]]
foreach required_text {
    {assert_abi_v2_release_bd_structure}
    {get_property BASE_BOARD_PART [current_project]}
    {get_bd_cells -quiet -hierarchical}
    {get_bd_intf_nets -quiet -of_objects}
    {require_same_bd_clock_net ps/pl_clk0}
    {set use_release_200_clock_wizard}
    {set ps_pl_clock_mhz}
    {CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ}
    {require_bd_frequency_hz}
    {xilinx.com:ip:clk_wiz:* pl_clk_wiz}
    {CONFIG.PRIM_SOURCE {No_buffer}}
    {CONFIG.PRIMITIVE {MMCM}}
    {CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000}}
    {CONFIG.USE_LOCKED {true}}
    {CONFIG.USE_RESET {true}}
    {CONFIG.RESET_TYPE {ACTIVE_LOW}}
    {CONFIG.RESET_PORT {resetn}}
    {[get_bd_pins ps/pl_clk0] [get_bd_pins pl_clk_wiz/clk_in1]}
    {[get_bd_pins ps/pl_resetn0] [get_bd_pins pl_clk_wiz/resetn]}
    {[get_bd_pins pl_clk_wiz/locked] [get_bd_pins rst_pl/dcm_locked]}
    {pl_clock_generator}
    {pl_clock_tolerance_hz}
    {set ctrl_num_mi [expr {$enable_legacy_gpio_status ? 6 : 5}]}
    {if {$enable_legacy_gpio_status}}
    {xilinx.com:ip:axi_gpio:* accel_gpio}
    {xilinx.com:ip:xlconstant:*}
    {ifm_line_words_invalid}
    {CONFIG.CONST_WIDTH {9} CONFIG.CONST_VAL {0}}
    {[get_bd_pins ifm_line_words_invalid/dout]}
    {[get_bd_pins accel/ifm_line_words]}
    {ABI-v2 release BD must not contain the shared mem_sc}
    {CONFIG.PSU__SAXIGP${gp}__DATA_WIDTH 64}
    {dma_bias/M_AXI_MM2S ps/S_AXI_HP0_FPD}
    {dma_weight/M_AXI_MM2S ps/S_AXI_HP1_FPD}
    {dma_ifm/M_AXI_MM2S ps/S_AXI_HP2_FPD}
    {dma_ofm/M_AXI_S2MM ps/S_AXI_HP3_FPD}
    {ps/saxihp1_fpd_aclk}
    {ps/saxihp2_fpd_aclk}
    {ps/saxihp3_fpd_aclk}
    {CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $ps_pl_clock_mhz}
    {CONFIG.CLOCK_HZ $clock_hz}
    {CONFIG.c_mm2s_burst_size}
    {weight_dma_mm2s_burst $weight_dma_mm2s_burst}
    {CONFIG.ENABLE_WEIGHT_PRELOAD $enable_weight_preload}
    {CONFIG.ENABLE_FAST_CONTEXT_HANDOFF $enable_fast_context_handoff}
    {$expected_weight_preload}
    {$expected_fast_handoff}
} {
    if {[string first $required_text $bd_script] < 0} {
        error "BD script is missing release/legacy structure text: $required_text"
    }
}

# The full-chain testbench is deliberately standalone, so statically bind its
# hand-written synthesis parameters back to the canonical release profile.
set chain_tb_text [::conv_accel_build::read_text \
    [file join $root tb tb_abi_v2_release_ten_layer_chain.v]]
set chain_contract [list \
    "localparam integer ROWS = [dict get $release rows];" \
    "localparam integer COLS = [dict get $release cols];" \
    "localparam integer COUT_TILE = [dict get $release cout_tile];" \
    ".IFM_BANKS([dict get $release ifm_banks])" \
    ".IFM_FIFO_DEPTH([dict get $release ifm_fifo_depth])" \
    ".IFM_FIFO_AW([dict get $release ifm_fifo_aw])" \
    ".PSUM_FIFO_DEPTH([dict get $release psum_fifo_depth])" \
    ".PSUM_FIFO_AW([dict get $release psum_fifo_aw])" \
    ".HWC_CACHE_AW([dict get $release hwc_cache_aw])" \
    ".HWC_CACHE_DEPTH([dict get $release hwc_cache_depth])" \
    ".HWC_CACHE_STRIPES([dict get $release hwc_cache_stripes])" \
    ".HWC_CACHE_USE_URAM([dict get $release hwc_cache_use_uram])" \
    ".MATERIALIZED_CACHE_AW([dict get $release materialized_cache_aw])" \
    ".MATERIALIZED_CACHE_DEPTH([dict get $release materialized_cache_depth])" \
    ".ENABLE_COLUMN_PSUM([dict get $release enable_column_psum])" \
    ".ENABLE_PACKED_HWC_OFM([dict get $release enable_packed_hwc_ofm])" \
    ".ENABLE_LAYER_TILE_SEQUENCER([dict get $release enable_layer_tile_sequencer])" \
    ".ENABLE_LAYER_LONG_HWC_IFM([dict get $release enable_layer_long_hwc_ifm])" \
    ".ENABLE_TAGGED_CONTEXT([dict get $release enable_tagged_context])" \
    ".IFM_EPOCH_USE_URAM([dict get $release ifm_epoch_use_uram])" \
    ".ENABLE_DETAILED_TRACE([dict get $release enable_detailed_trace])" \
    ".TAIL_CYCLES_CONFIG([dict get $release tail_cycles])"]
foreach required_text $chain_contract {
    if {[string first $required_text $chain_tb_text] < 0} {
        error "ABI-v2 chain TB diverges from release profile: $required_text"
    }
}

# Exercise the actual post-parse contracts in child tclsh processes.  This
# catches option-order bypasses that static string checks cannot detect.
set synth_script_path [file join $script_dir run_synth_xck26.tcl]
set system_script_path [file join $script_dir build_kv260_system_xck26.tcl]
set bd_script_path [file join $script_dir create_ps_dma_bd_xck26.tcl]
set formal_100_ooc_output [require_child_tcl_status 1 \
    "canonical release OOC" $synth_script_path \
    -check_only -profile abi_v2_release -ooc]
foreach required_text {
    {implementation_stage=post_place}
    {post_place_physopt_enabled=0}
    {post_place_physopt_directive=disabled}
    {timing_diagnostic_max_paths=50}
} {
    if {[string first $required_text $formal_100_ooc_output] < 0} {
        error "formal 100 MHz OOC check-only output is missing: $required_text"
    }
}
set formal_200_ooc_output [require_child_tcl_status 1 \
    "canonical 200 MHz release OOC" \
    $synth_script_path -check_only -profile abi_v2_release_200 -ooc]
foreach required_text {
    {implementation_stage=post_place_phys_opt}
    {post_place_physopt_enabled=1}
    {post_place_physopt_directive=AggressiveExplore}
    {min_wns=0.0}
    {min_whs=0.0}
    {min_ths=0.0}
    {max_failing_endpoints=0}
    {max_hold_failing_endpoints=0}
    {max_pulse_width_failing_endpoints=0}
    {max_congestion_level=4}
    {expected_uram=48}
    {timing_diagnostic_max_paths=100}
} {
    if {[string first $required_text $formal_200_ooc_output] < 0} {
        error "formal 200 MHz OOC check-only output is missing: $required_text"
    }
}
set formal_200_no_physopt_output [require_child_tcl_status 1 \
    "200 MHz release OOC without post-place physopt" \
    $synth_script_path -check_only -profile abi_v2_release_200 -ooc \
    -disable_post_place_physopt -build_dir [file join $root \
        build_ooc_abi_v2_release_200_no_physopt_check]]
foreach required_text {
    {implementation_stage=post_place}
    {post_place_physopt_enabled=0}
    {post_place_physopt_directive=disabled}
    {post_place_physopt_forced_off=1}
    {min_wns=0.0}
    {max_failing_endpoints=0}
} {
    if {[string first $required_text $formal_200_no_physopt_output] < 0} {
        error "no-physopt 200 MHz OOC check-only output is missing: $required_text"
    }
}
foreach frequency {125 150 175} {
    set sweep_ooc_output [require_child_tcl_status 1 \
        "staged ${frequency} MHz placed OOC" \
        $synth_script_path -check_only -profile abi_v2_release_200 -ooc \
        -development_clock_mhz $frequency \
        -build_dir [file join $root \
            "build_ooc_abi_v2_frequency_sweep_${frequency}"]]
    foreach required_text {
        {implementation_stage=post_place}
        {post_place_physopt_enabled=0}
        {post_place_physopt_directive=disabled}
    } {
        if {[string first $required_text $sweep_ooc_output] < 0} {
            error "${frequency} MHz development OOC check-only output is missing: $required_text"
        }
    }
}
set routed_ooc_output [require_child_tcl_status 1 \
    "125 MHz routed OOC development sweep" \
    $synth_script_path -check_only -profile abi_v2_release_200 -ooc \
    -development_clock_mhz 125 -route -build_dir \
    [file join $root build_ooc_abi_v2_frequency_sweep_125_route]]
foreach required_text {
    {route=1}
    {implementation_stage=post_place}
    {post_place_physopt_enabled=0}
    {post_place_physopt_directive=disabled}
} {
    if {[string first $required_text $routed_ooc_output] < 0} {
        error "development route check-only output is missing: $required_text"
    }
}

# Exercise resume preflight with a tiny synthetic bundle.  -check_only performs
# all file/profile/gate/XDC/SHA checks without invoking any Vivado command.
set resume_fixture_dir [file join $root \
    "build_ooc_resume_fixture_[pid]_[clock clicks]"]
set resume_output_dir [file join $root "build_ooc_route_static_[pid]"]
file mkdir $resume_fixture_dir
set resume_fixture_stem fixture
set resume_fixture_prefix [file join $resume_fixture_dir $resume_fixture_stem]
set resume_fixture_dcp "${resume_fixture_prefix}_placed.dcp"
set resume_fixture_gate "${resume_fixture_prefix}_gate.txt"
set resume_fixture_metadata "${resume_fixture_prefix}_build_profile.txt"
set resume_fixture_manifest "${resume_fixture_prefix}_artifacts.sha256"
set resume_fixture_xdc "${resume_fixture_prefix}_clock.xdc"
set resume_fixture_audit "${resume_fixture_prefix}_internal_none_fdre_audit.rpt"
set resume_fixture_dcp_text {synthetic placed DCP fixture}
write_test_text $resume_fixture_dcp $resume_fixture_dcp_text
write_test_text $resume_fixture_xdc \
    {create_clock -name clk -period 8.000000 [get_ports {clk}]
}
write_test_text $resume_fixture_audit {audit=ooc_internal_none_fdre
format_version=1
status=COMPLETE
metric.ooc_internal_none_fdre_endpoints=0
}
set resume_defaults [::conv_accel_build::profile_defaults abi_v2_release_200]
set resume_metadata_values [dict create \
    source_profile abi_v2_release_200 development_frequency_sweep 1 \
    development_post_place_margin_fraction 0.01 \
    implementation_stage post_place out_of_context 1 enforce_gates 1 \
    top conv_accel_core_axi_lite_axis_stream part xck26-sfvc784-2LV-c \
    pl_clock_mhz 125 clock_hz 125000000 clock_period_ns 8.000000 \
    constrained_clock_period_ns 8.000000 min_wns 0.08 min_tns 0.0 \
    git_root [file normalize $root] git_sha [string repeat a 40] git_dirty 1 \
    vivado_version 2022.2 \
    internal_none_fdre_audit_report [file tail $resume_fixture_audit] \
    ooc_internal_none_fdre_endpoints 0]
foreach key {
    rows cols k_tile cout_tile enable_column_psum enable_packed_hwc_ofm
    enable_layer_tile_sequencer enable_layer_long_hwc_ifm
    enable_tagged_context enable_weight_preload enable_fast_context_handoff
    enable_detailed_trace ifm_banks ifm_fifo_depth ifm_fifo_aw
    psum_fifo_depth psum_fifo_aw hwc_cache_aw hwc_cache_depth
    hwc_cache_stripes hwc_cache_use_uram ifm_epoch_use_uram
    materialized_cache_aw materialized_cache_depth tail_cycles
} {
    dict set resume_metadata_values $key [dict get $resume_defaults $key]
}
foreach {metadata_key default_key} {
    max_lut ooc_max_lut max_logic_lut ooc_max_logic_lut
    max_lut_memory ooc_max_lut_memory max_clb_percent ooc_max_clb_percent
    max_bram ooc_max_bram max_uram ooc_max_uram max_dsp ooc_max_dsp
    max_unconstrained_paths ooc_max_unconstrained_paths
    max_unclocked_fdre ooc_max_unclocked_fdre
    max_ooc_internal_none_fdre_endpoints ooc_max_internal_none_fdre_endpoints
} {
    dict set resume_metadata_values $metadata_key \
        [dict get $resume_defaults $default_key]
}
::conv_accel_build::write_build_metadata $resume_fixture_metadata \
    abi_v2_frequency_sweep_125 $resume_metadata_values
set resume_gate_metrics [dict create wns 0.083 tns 0.0 \
    failing_endpoints 0 hold_failing_endpoints 0 \
    pulse_width_failing_endpoints 0 unclocked_fdre 0 \
    unconstrained_paths 0 ooc_internal_none_fdre_endpoints 0 \
    lut 50000 logic_lut 45000 lut_memory 5000 clb_percent 65.0 \
    bram 88 uram 48 dsp 652]
set resume_gate_limits [dict create \
    max_lut [dict get $resume_defaults ooc_max_lut] \
    max_logic_lut [dict get $resume_defaults ooc_max_logic_lut] \
    max_lut_memory [dict get $resume_defaults ooc_max_lut_memory] \
    max_clb_percent [dict get $resume_defaults ooc_max_clb_percent] \
    max_bram [dict get $resume_defaults ooc_max_bram] \
    max_uram [dict get $resume_defaults ooc_max_uram] \
    max_dsp [dict get $resume_defaults ooc_max_dsp] \
    min_wns 0.08 min_tns 0.0 \
    max_unconstrained_paths \
        [dict get $resume_defaults ooc_max_unconstrained_paths] \
    max_unclocked_fdre [dict get $resume_defaults ooc_max_unclocked_fdre] \
    max_ooc_internal_none_fdre_endpoints \
        [dict get $resume_defaults ooc_max_internal_none_fdre_endpoints]]
::conv_accel_build::write_gate_report $resume_fixture_gate OOC \
    $resume_gate_metrics $resume_gate_limits [list]
::conv_accel_build::write_sha256_manifest $resume_fixture_manifest \
    [list $resume_fixture_dcp]
set resume_check_args [list -check_only -profile abi_v2_release_200 \
    -development_clock_mhz 125 -source_build_dir $resume_fixture_dir \
    -build_dir $resume_output_dir -stem static]
require_child_tcl_status 1 "OOC route resume preflight" \
    $resume_script_path {*}$resume_check_args

# Each mutation starts from the passing fixture, so a negative result proves
# the individual fail-closed contract rather than an unrelated missing file.
write_test_text $resume_fixture_dcp "${resume_fixture_dcp_text} tampered"
require_child_tcl_status 0 "OOC route resume rejects DCP SHA mismatch" \
    $resume_script_path {*}$resume_check_args
write_test_text $resume_fixture_dcp $resume_fixture_dcp_text

::conv_accel_build::write_build_metadata $resume_fixture_metadata \
    abi_v2_release $resume_metadata_values
require_child_tcl_status 0 "OOC route resume rejects metadata profile" \
    $resume_script_path {*}$resume_check_args
::conv_accel_build::write_build_metadata $resume_fixture_metadata \
    abi_v2_frequency_sweep_125 $resume_metadata_values

dict set resume_metadata_values implementation_stage post_synth
::conv_accel_build::write_build_metadata $resume_fixture_metadata \
    abi_v2_frequency_sweep_125 $resume_metadata_values
require_child_tcl_status 0 "OOC route resume rejects metadata stage" \
    $resume_script_path {*}$resume_check_args
dict set resume_metadata_values implementation_stage post_place

dict set resume_metadata_values part xczu9eg-ffvb1156-2-e
::conv_accel_build::write_build_metadata $resume_fixture_metadata \
    abi_v2_frequency_sweep_125 $resume_metadata_values
require_child_tcl_status 0 "OOC route resume rejects metadata part" \
    $resume_script_path {*}$resume_check_args
dict set resume_metadata_values part xck26-sfvc784-2LV-c

dict set resume_metadata_values top wrong_top
::conv_accel_build::write_build_metadata $resume_fixture_metadata \
    abi_v2_frequency_sweep_125 $resume_metadata_values
require_child_tcl_status 0 "OOC route resume rejects metadata top" \
    $resume_script_path {*}$resume_check_args
dict set resume_metadata_values top conv_accel_core_axi_lite_axis_stream
::conv_accel_build::write_build_metadata $resume_fixture_metadata \
    abi_v2_frequency_sweep_125 $resume_metadata_values

write_test_text $resume_fixture_xdc \
    {create_clock -name clk -period 7.999000 [get_ports {clk}]
}
require_child_tcl_status 0 "OOC route resume rejects clock XDC" \
    $resume_script_path {*}$resume_check_args
write_test_text $resume_fixture_xdc \
    {create_clock -name clk -period 8.000000 [get_ports {clk}]
}

::conv_accel_build::write_gate_report $resume_fixture_gate OOC \
    $resume_gate_metrics $resume_gate_limits [list {fixture failure}]
require_child_tcl_status 0 "OOC route resume rejects failed source gate" \
    $resume_script_path {*}$resume_check_args
::conv_accel_build::write_gate_report $resume_fixture_gate OOC \
    $resume_gate_metrics $resume_gate_limits [list]
require_child_tcl_status 0 "OOC route resume rejects wrong CLI profile" \
    $resume_script_path -check_only -profile abi_v2_release \
    -development_clock_mhz 125 -source_build_dir $resume_fixture_dir \
    -build_dir $resume_output_dir -stem static
require_child_tcl_status 0 "OOC route resume rejects long output stem" \
    $resume_script_path -check_only -profile abi_v2_release_200 \
    -development_clock_mhz 125 -source_build_dir $resume_fixture_dir \
    -build_dir $resume_output_dir -stem [string repeat x 25]
file delete -force -- $resume_fixture_dir

set sweep_ooc_dir [file join $root build_ooc_abi_v2_frequency_sweep_150]
foreach test_case {
    {-rows 17}
    {-enable_tagged_context 0}
    {-enable_weight_preload 0}
    {-enable_fast_context_handoff 0}
    {-psum_fifo_depth 512 -psum_fifo_aw 9}
    {-max_lut 83001}
    {-no_gates}
} {
    require_child_tcl_status 0 "150 MHz OOC sweep release lock $test_case" \
        $synth_script_path -check_only -profile abi_v2_release_200 -ooc \
        -development_clock_mhz 150 -build_dir $sweep_ooc_dir {*}$test_case
}
require_child_tcl_status 0 "invalid staged OOC clock" $synth_script_path \
    -check_only -profile abi_v2_release_200 -ooc \
    -development_clock_mhz 123 -build_dir $sweep_ooc_dir
require_child_tcl_status 0 "staged OOC rejects explicit WNS override" \
    $synth_script_path -check_only -profile abi_v2_release_200 -ooc \
    -development_clock_mhz 150 -build_dir $sweep_ooc_dir -min_wns 0.2
require_child_tcl_status 0 "staged OOC requires release200" $synth_script_path \
    -check_only -ooc -development_clock_mhz 150 -build_dir $sweep_ooc_dir
require_child_tcl_status 0 "OOC route requires development sweep" \
    $synth_script_path -check_only -profile abi_v2_release_200 -ooc -route
require_child_tcl_status 0 "staged OOC requires dedicated build directory" \
    $synth_script_path -check_only -profile abi_v2_release_200 -ooc \
    -development_clock_mhz 150
foreach test_case {
    {-pl_clock_mhz 199}
    {-pl_clock_mhz 100}
    {-min_wns -0.001}
    {-min_whs -0.001}
    {-min_ths -0.001}
    {-max_hold_failing_endpoints 1}
    {-max_pulse_width_failing_endpoints 1}
    {-no_gates}
} {
    require_child_tcl_status 0 "200 MHz release OOC downgrade $test_case" \
        $synth_script_path -check_only -profile abi_v2_release_200 -ooc \
        {*}$test_case
}
foreach test_case {
    {-rows 17}
    {-cols 8 -cout_tile 16}
    {-enable_tagged_context 0}
    {-enable_weight_preload 0}
    {-enable_fast_context_handoff 0}
    {-ifm_epoch_use_uram 0}
    {-psum_fifo_depth 512 -psum_fifo_aw 9}
    {-no_gates}
    {-max_lut 83001}
    {-max_logic_lut 72001}
    {-max_lut_memory 8001}
    {-max_clb_percent 85.1}
    {-max_uram 49}
    {-expected_uram 47}
    {-max_bram 91}
    {-max_uram 49}
    {-max_dsp 721}
    {-min_wns 0.499}
    {-min_tns -0.001}
} {
    require_child_tcl_status 0 "release OOC downgrade $test_case" \
        $synth_script_path -check_only -profile abi_v2_release -ooc \
        {*}$test_case
}
require_child_tcl_status 1 "tightened release OOC gates" $synth_script_path \
    -check_only -profile abi_v2_release -ooc \
    -max_lut 82999 -max_logic_lut 71999 -max_lut_memory 7999 \
    -max_clb_percent 84.9 -max_bram 89 -max_uram 47 -max_dsp 719 \
    -min_wns 0.6

require_child_tcl_status 1 "canonical release system" $system_script_path \
    -check_only -profile abi_v2_release
set formal_200_system_output [require_child_tcl_status 1 \
    "canonical 200 MHz release system" \
    $system_script_path -check_only -profile abi_v2_release_200]
foreach required_text {
    {metadata_profile=abi_v2_release_200}
    {clock_hz=200000000}
    {place_min_wns=0.0}
    {route_min_wns=0.0}
} {
    if {[string first $required_text $formal_200_system_output] < 0} {
        error "formal 200 MHz system check-only output is missing: $required_text"
    }
}
foreach {profile long_ifm preload handoff} {
    abi_v2_ablation_200_a0 0 0 0
    abi_v2_ablation_200_a1 1 0 0
    abi_v2_ablation_200_a2 1 1 0
} {
    set ablation_output [require_child_tcl_status 1 \
        "$profile 200 MHz non-release system" $system_script_path \
        -check_only -profile $profile \
        -build_dir [file join $root "build_${profile}_check"]]
    foreach required_text [list \
        "metadata_profile=$profile" {clock_hz=200000000} \
        "weight_preload=$preload" "fast_handoff=$handoff" \
        {place_min_wns=0.0} {route_min_wns=0.0}] {
        if {[string first $required_text $ablation_output] < 0} {
            error "$profile check-only output is missing: $required_text"
        }
    }
    set defaults [::conv_accel_build::profile_defaults $profile]
    if {[dict get $defaults enable_layer_long_hwc_ifm] != $long_ifm} {
        error "$profile long-HWC identity is not locked"
    }
    foreach test_case [list \
            [list -enable_layer_long_hwc_ifm [expr {!$long_ifm}]] \
            [list -enable_weight_preload [expr {!$preload}]] \
            [list -enable_fast_context_handoff [expr {!$handoff}]] \
            [list -pl_clock_mhz 199] [list -no_gates]] {
        require_child_tcl_status 0 "$profile immutable ablation lock $test_case" \
            $system_script_path -check_only -profile $profile \
            -build_dir [file join $root "build_${profile}_check"] \
            {*}$test_case
    }
}
foreach {frequency expected_clock_hz expected_place_min_wns} {
    125 125000000 0.08
    150 150000000 0.06667
    175 175000000 0.05714
} {
    set sweep_system_output [require_child_tcl_status 1 \
        "staged ${frequency} MHz full system" \
        $system_script_path -check_only -profile abi_v2_release_200 \
        -development_clock_mhz $frequency \
        -build_dir [file join $root \
            "build_system_abi_v2_frequency_sweep_${frequency}"]]
    foreach required_text [list \
        "metadata_profile=abi_v2_frequency_sweep_${frequency}" \
        "clock_hz=$expected_clock_hz" \
        "place_min_wns=$expected_place_min_wns" \
        {route_min_wns=0.0}] {
        if {[string first $required_text $sweep_system_output] < 0} {
            error "${frequency} MHz system sweep check-only output is missing: $required_text"
        }
    }
}
set sweep_system_dir [file join $root build_system_abi_v2_frequency_sweep_150]
foreach test_case {
    {-rows 17}
    {-enable_tagged_context 0}
    {-enable_weight_preload 0}
    {-enable_fast_context_handoff 0}
    {-weight_dma_mm2s_burst 32}
    {-max_clb_percent 85.1}
    {-place_min_wns 0.06667}
    {-min_wns 0.0}
    {-min_tns -0.001}
    {-max_accel_none_delay_endpoints 1}
    {-max_route_errors 1}
    {-max_drc_errors 1}
    {-max_drc_critical_warnings 1}
    {-no_gates}
    {-reuse_synth}
} {
    require_child_tcl_status 0 "150 MHz system sweep release lock $test_case" \
        $system_script_path -check_only -profile abi_v2_release_200 \
        -development_clock_mhz 150 -build_dir $sweep_system_dir {*}$test_case
}
foreach test_case {
    {-pl_clock_mhz 199}
    {-pl_clock_mhz 100}
    {-weight_dma_mm2s_burst 32}
    {-weight_dma_mm2s_burst 8}
    {-max_clb_percent 85.1}
    {-max_uram 49}
    {-max_uram 47}
    {-expected_uram 49}
    {-expected_uram 47}
    {-place_min_wns -0.001}
    {-min_wns -0.001}
    {-no_gates}
    {-reuse_synth}
} {
    require_child_tcl_status 0 "200 MHz release system downgrade $test_case" \
        $system_script_path -check_only -profile abi_v2_release_200 \
        {*}$test_case
}
require_child_tcl_status 1 "canonical release system place-only" \
    $system_script_path -check_only -profile abi_v2_release -place_only
require_child_tcl_status 0 "mutually exclusive system stops" \
    $system_script_path -check_only -profile abi_v2_release \
    -synth_only -place_only
require_child_tcl_status 1 "explicit canonical release system directory" \
    $system_script_path -check_only -profile abi_v2_release \
    -build_dir [file join $root build_system_xck26_kv260_abi_v2_release]
require_child_tcl_status 0 "legacy system cannot overwrite publication" \
    $system_script_path -check_only -profile legacy_r18c8_debug \
    -build_dir [file join $root release kv260_hwcreplay_22]
foreach test_case {
    {-project_name noncanonical_release_project}
    {-bd_name noncanonical_release_bd}
    {-board_part bad}
    {-board_connection {bad bad}}
    {-rows 17}
    {-cols 8 -cout_tile 16}
    {-enable_packed_hwc_ofm 0}
    {-enable_layer_tile_sequencer 0 -enable_layer_long_hwc_ifm 0}
    {-enable_tagged_context 0}
    {-enable_weight_preload 0}
    {-enable_fast_context_handoff 0}
    {-ifm_epoch_use_uram 0}
    {-psum_fifo_depth 512 -psum_fifo_aw 9}
    {-enable_detailed_trace 1}
    {-enable_legacy_gpio_status 1}
    {-no_gates}
    {-no_gates -enforce_gates}
    {-reuse_synth}
    {-max_lut 90001}
    {-max_lut {}}
    {-max_lut_memory 8001}
    {-max_clb_percent 90.1}
    {-max_dsp 721}
    {-place_min_wns 0.299}
    {-place_max_congestion_level 5}
    {-min_wns 0.099}
    {-min_tns -0.001}
    {-min_whs -0.001}
    {-min_ths -0.001}
    {-max_failing_endpoints 1}
    {-max_hold_failing_endpoints 1}
    {-max_pulse_width_failing_endpoints 1}
    {-max_unconstrained_paths 1}
    {-max_unclocked_fdre 1}
    {-max_accel_none_delay_endpoints 1}
    {-max_route_errors 1}
    {-max_drc_errors 1}
    {-max_drc_critical_warnings 1}
    {-build_dir release/kv260_hwcreplay_22}
    {-build_dir build_system_xck26_kv260_legacy_r18c8_debug}
    {-build_dir build_legacy_abi_v2_release}
    {-build_dir systolic/build_abi_v2_release}
} {
    require_child_tcl_status 0 "release system downgrade $test_case" \
        $system_script_path -check_only -profile abi_v2_release {*}$test_case
}
foreach test_case {
    {-max_lut 89999}
    {-max_lut_memory 7999}
    {-max_clb_percent 89.9}
    {-place_min_wns 0.4}
    {-place_max_congestion_level 3}
    {-min_wns 0.2}
    {-max_bram 120 -max_uram 48 -max_dsp 719}
} {
    require_child_tcl_status 1 "tightened release system gates $test_case" \
        $system_script_path -check_only -profile abi_v2_release {*}$test_case
}
require_child_tcl_status 1 "canonical release BD" $bd_script_path \
    -check_only -profile abi_v2_release
require_child_tcl_status 1 "canonical 200 MHz release BD" $bd_script_path \
    -check_only -profile abi_v2_release_200
foreach frequency {125 150 175} {
    require_child_tcl_status 1 "staged ${frequency} MHz BD" \
        $bd_script_path -check_only -profile abi_v2_release_200 \
        -development_clock_mhz $frequency \
        -build_dir [file join $root \
            "build_bd_abi_v2_frequency_sweep_${frequency}"]
}
set sweep_bd_dir [file join $root build_bd_abi_v2_frequency_sweep_150]
foreach test_case {
    {-project_name noncanonical_release_project}
    {-rows 17}
    {-enable_tagged_context 0}
    {-enable_weight_preload 0}
    {-enable_fast_context_handoff 0}
    {-weight_dma_mm2s_burst 32}
} {
    require_child_tcl_status 0 "150 MHz BD sweep release lock $test_case" \
        $bd_script_path -check_only -profile abi_v2_release_200 \
        -development_clock_mhz 150 -build_dir $sweep_bd_dir {*}$test_case
}
foreach test_case {
    {-pl_clock_mhz 199}
    {-pl_clock_mhz 100}
    {-weight_dma_mm2s_burst 32}
    {-weight_dma_mm2s_burst 8}
} {
    require_child_tcl_status 0 "200 MHz release BD downgrade $test_case" \
        $bd_script_path -check_only -profile abi_v2_release_200 \
        {*}$test_case
}
require_child_tcl_status 1 "explicit canonical release BD directory" \
    $bd_script_path -check_only -profile abi_v2_release \
    -build_dir [file join $root build_bd_xck26_abi_v2_release]
require_child_tcl_status 0 "legacy BD cannot overwrite publication" \
    $bd_script_path -check_only -profile legacy_r18c8_debug \
    -build_dir [file join $root release kv260_hwcreplay_22]
foreach test_case {
    {-project_name noncanonical_release_project}
    {-bd_name noncanonical_release_bd}
    {-board_part bad}
    {-rows 17}
    {-enable_tagged_context 0}
    {-enable_weight_preload 0}
    {-enable_fast_context_handoff 0}
    {-enable_legacy_gpio_status 1}
    {-build_dir release/kv260_hwcreplay_22}
    {-build_dir build_bd_xck26_legacy_r18c8_debug}
    {-build_dir build_legacy_abi_v2_release}
    {-build_dir systolic/build_abi_v2_release}
} {
    require_child_tcl_status 0 "release BD downgrade $test_case" \
        $bd_script_path -check_only -profile abi_v2_release {*}$test_case
}

foreach {relative_path required_text} {
    systolic/conv_accel_core_axi_lite_axis_stream.v
        {.IFM_EPOCH_USE_URAM(IFM_EPOCH_USE_URAM)}
    systolic/conv_accel_core_axi_lite.v
        {.IFM_EPOCH_USE_URAM(IFM_EPOCH_USE_URAM)}
    systolic/conv_accel_core.v
        {.IFM_EPOCH_USE_URAM(IFM_EPOCH_USE_URAM)}
    systolic/conv_layer_top_stream.v
        {.IFM_EPOCH_USE_URAM(IFM_EPOCH_USE_URAM)}
    systolic/systolic_top_feeder.v
        {.USE_URAM(IFM_EPOCH_USE_URAM)}
    tcl/create_ps_dma_bd_xck26.tcl
        {CONFIG.IFM_EPOCH_USE_URAM $ifm_epoch_use_uram}
    tcl/build_kv260_system_xck26.tcl
        {-ifm_epoch_use_uram $ifm_epoch_use_uram}
} {
    set contents [::conv_accel_build::read_text [file join $root $relative_path]]
    if {[string first $required_text $contents] < 0} {
        error "$relative_path does not propagate IFM epoch URAM selection"
    }
}

# Lock the packed-row capacity contract shared by descriptor validation and
# the release datapath.  Conv7 needs ceil(13/2)*ceil(1024/4)=1792 words per
# rolling row; the former 1024-word wrapper override silently truncated the
# eleventh address bit because the materializer is prevalidated in release.
foreach {relative_path required_texts} [list \
    systolic/axis_hwc_window_row_store.v [list \
        {parameter integer DEPTH = 2048} \
        {parameter integer ADDR_W = 11}] \
    systolic/axis_hwc_window_materializer_byte_bram.v [list \
        {parameter integer LINE_BANK_DEPTH = 2048} \
        {(LINE_BANK_DEPTH <= 2) ? 1 : $clog2(LINE_BANK_DEPTH)} \
        {.DEPTH(LINE_BANK_DEPTH), .ADDR_W(LINE_AW)}] \
    systolic/axis_hwc_tile_materialized_replay.v [list \
        {parameter integer LINE_BANK_DEPTH = 2048} \
        {.LINE_BANK_DEPTH(LINE_BANK_DEPTH)}] \
    systolic/conv_accel_core_axi_lite_axis_stream.v [list \
        {parameter integer LAYER_LONG_LINE_BANK_DEPTH = 2048} \
        {.LINE_BANK_DEPTH(LAYER_LONG_LINE_BANK_DEPTH)} \
        {.LAYER_LONG_LINE_BANK_DEPTH(LAYER_LONG_LINE_BANK_DEPTH)}] \
    systolic/conv_accel_core_axi_lite.v [list \
        {parameter integer LAYER_LONG_LINE_BANK_DEPTH = 2048} \
        {.LAYER_LONG_LINE_BANK_DEPTH(LAYER_LONG_LINE_BANK_DEPTH)}] \
    systolic/conv_accel_core.v [list \
        {parameter integer LAYER_LONG_LINE_BANK_DEPTH = 2048} \
        {.LAYER_LONG_LINE_BANK_DEPTH(LAYER_LONG_LINE_BANK_DEPTH)}] \
    systolic/layer_config_regs.v [list \
        {parameter integer LAYER_LONG_LINE_BANK_DEPTH = 2048} \
        {localparam integer LONG_CHANNEL_BANKS = 4} \
        {localparam integer LONG_X_PACK = 2} \
        {reg [8:0]  start_validate_fm_w_q;} \
        {start_validate_fm_w_q <= fm_w;} \
        {(start_validate_fm_w_q + LONG_X_PACK - 1) / LONG_X_PACK} \
        {start_math_cin_word_groups_q * start_math_x_groups_q} \
        {LAYER_LONG_LINE_BANK_DEPTH}] \
    tcl/run_materializer_ooc_xck26.tcl [list \
        {uram 4 bram 0 dsp 0} \
        {bram 16 uram 0 dsp 0} \
        {lut 7500 ff 3400} \
        {min_wns 0.0 min_tns 0.0}]] {
    set contents [::conv_accel_build::read_text [file join $root $relative_path]]
    foreach required_text $required_texts {
        if {[string first $required_text $contents] < 0} {
            error "$relative_path breaks the 2048-word packed-row capacity contract: missing '$required_text'"
        }
    }
}
foreach relative_path {
    systolic/axis_hwc_tile_materialized_replay.v
    systolic/conv_accel_core_axi_lite_axis_stream.v
    systolic/conv_accel_core_axi_lite.v
    systolic/conv_accel_core.v
    systolic/layer_config_regs.v
} {
    set contents [::conv_accel_build::read_text [file join $root $relative_path]]
    if {[regexp {LINE_BANK_DEPTH\s*(?:=|\()\s*1024} $contents] ||
        [string first {LONG_X_BANKS} $contents] >= 0} {
        error "$relative_path retains the obsolete 1024-word/four-x-bank release contract"
    }
}
proc version {arg} {
    if {$arg ne "-short"} {
        error "unexpected version test argument: $arg"
    }
    return 2022.2
}
::conv_accel_build::require_vivado_version 2022.2
rename version {}

set provenance [::conv_accel_build::git_provenance $root]
if {![regexp {^[0-9a-f]{40}$} [dict get $provenance git_sha]] ||
    ([dict get $provenance git_dirty] != 0 &&
     [dict get $provenance git_dirty] != 1)} {
    error "Git provenance helper returned invalid metadata"
}
set clean_provenance [dict create \
    git_root [dict get $provenance git_root] \
    git_sha [dict get $provenance git_sha] git_dirty 0]
if {![::conv_accel_build::git_provenance_is_clean $clean_provenance] ||
    ![::conv_accel_build::git_provenance_matches \
        $clean_provenance $clean_provenance]} {
    error "stable clean Git provenance was rejected"
}
set changed_provenance $clean_provenance
dict set changed_provenance git_sha [string repeat a 40]
if {[dict get $changed_provenance git_sha] eq
    [dict get $clean_provenance git_sha]} {
    dict set changed_provenance git_sha [string repeat b 40]
}
if {[::conv_accel_build::git_provenance_matches \
        $clean_provenance $changed_provenance]} {
    error "Git provenance comparison accepted a changed SHA"
}
dict set changed_provenance git_sha [dict get $clean_provenance git_sha]
dict set changed_provenance git_dirty 1
if {[::conv_accel_build::git_provenance_is_clean $changed_provenance] ||
    [::conv_accel_build::git_provenance_matches \
        $clean_provenance $changed_provenance]} {
    error "Git provenance comparison accepted a dirty transition"
}
if {![catch {::conv_accel_build::remove_stale_publications \
        [file join $root build_publication_guard_test] \
        [list [file join $root outside_publication_guard_test.bit]]}]} {
    error "publication cleanup accepted a target outside its build directory"
}

set metadata_file [file join $root build_synth_xck26 \
    layer_long_byte_bram_r18c16_seq1_recur_valgroups_cacheaddr_prevalidated_build_profile.txt]
if {[file isfile $metadata_file]} {
    set metadata [::conv_accel_build::read_build_metadata $metadata_file]
    if {![dict exists $metadata profile]} {
        error "existing build metadata parser check failed"
    }
}

set sample_util {
| CLB LUTs*                  | 83000 | 0 | 0 | 117120 | 70.87 |
|   LUT as Logic             | 72000 | 0 | 0 | 117120 | 61.48 |
|   LUT as Memory            | 8000  | 0 | 0 | 57600  | 13.89 |
| Block RAM Tile             | 90    | 0 | 0 | 144    | 62.50 |
| URAM                       | 48    | 0 | 0 | 64     | 75.00 |
| DSPs                       | 370   | 0 | 0 | 1248   | 29.65 |
| CLB                        | 12444 | 0 | 0 | 14640  | 85.00 |
}
set sample_timing {
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints
    -------      -------  ---------------------  -------------------
      0.500        0.000                      0               100000
}
set sample_routed_timing {
1. checking no_clock (0)
4. checking unconstrained_internal_endpoints (0)
    WNS(ns) TNS(ns) TNS Failing Endpoints TNS Total Endpoints WHS(ns) THS(ns) THS Failing Endpoints THS Total Endpoints WPWS(ns) TPWS(ns) TPWS Failing Endpoints TPWS Total Endpoints
      0.200   0.000 0 100000 0.011 0.000 0 100000 3.500 0.000 0 100000
}
set routed_metrics [::conv_accel_build::parse_timing $sample_routed_timing]
foreach {metric expected} {
    wns 0.200 tns 0.000 failing_endpoints 0
    whs 0.011 ths 0.000 hold_failing_endpoints 0
    pulse_width_failing_endpoints 0 unclocked_fdre 0 unconstrained_paths 0
} {
    if {[dict get $routed_metrics $metric] ne $expected} {
        error "routed timing parser returned $routed_metrics for $metric"
    }
}
set routed_limits [dict create min_wns 0.2 min_tns 0.0 \
    min_whs 0.0 min_ths 0.0 max_failing_endpoints 0 \
    max_hold_failing_endpoints 0 max_pulse_width_failing_endpoints 0 \
    max_unclocked_fdre 0 max_unconstrained_paths 0]
if {[llength [::conv_accel_build::metric_violations \
        $routed_metrics $routed_limits]] != 0} {
    error "routed timing parser rejected exact setup/hold/pulse boundaries"
}
dict set routed_metrics pulse_width_failing_endpoints 1
set routed_violations [::conv_accel_build::metric_violations \
    $routed_metrics $routed_limits]
if {[llength $routed_violations] != 1 ||
    [string first "pulse_width_failing_endpoints=1" \
        [lindex $routed_violations 0]] < 0} {
    error "pulse-width failing endpoint bypassed routed gate: $routed_violations"
}
set sample_route {
       # of nets with routing errors.......... :           0 :
}
set sample_congestion {
1. Placer Final Level Congestion Reporting
| Direction | Type   | Level | Window |
| North     | Global |     3 | (...)  |
| West      | Short  |     4 | (...)  |
| East      | Long   |     2 | (...)  |
}
set release_200_ooc_metrics [dict merge \
    [::conv_accel_build::parse_utilization $sample_util] \
    [::conv_accel_build::parse_timing $sample_routed_timing] \
    [::conv_accel_build::parse_congestion $sample_congestion]]
set release_200_ooc_limits [dict create \
    expected_uram [dict get $release_200 ooc_expected_uram] \
    max_congestion_level \
        [dict get $release_200 ooc_max_congestion_level] \
    min_wns [dict get $release_200 ooc_min_wns] \
    min_tns [dict get $release_200 ooc_min_tns] \
    min_whs [dict get $release_200 ooc_min_whs] \
    min_ths [dict get $release_200 ooc_min_ths] \
    max_failing_endpoints \
        [dict get $release_200 ooc_max_failing_endpoints] \
    max_hold_failing_endpoints \
        [dict get $release_200 ooc_max_hold_failing_endpoints] \
    max_pulse_width_failing_endpoints \
        [dict get $release_200 ooc_max_pulse_width_failing_endpoints]]
if {[llength [::conv_accel_build::metric_violations \
        $release_200_ooc_metrics $release_200_ooc_limits]] != 0} {
    error "release_200 OOC gate rejected its positive boundary fixture"
}
foreach {metric bad_value expected_fragment} {
    uram 47 {does not equal expected_uram=48}
    congestion_level 5 {congestion_level=5}
    whs -0.001 {whs=-0.001}
    ths -0.001 {ths=-0.001}
    failing_endpoints 1 {failing_endpoints=1}
    hold_failing_endpoints 1 {hold_failing_endpoints=1}
    pulse_width_failing_endpoints 1 {pulse_width_failing_endpoints=1}
} {
    set bad_metrics $release_200_ooc_metrics
    dict set bad_metrics $metric $bad_value
    set violations [::conv_accel_build::metric_violations \
        $bad_metrics $release_200_ooc_limits]
    if {[llength $violations] != 1 ||
        [string first $expected_fragment [lindex $violations 0]] < 0} {
        error "release_200 OOC $metric negative fixture bypassed gate: $violations"
    }
}
foreach metric {
    uram congestion_level whs ths failing_endpoints
    hold_failing_endpoints pulse_width_failing_endpoints
} {
    set violations [::conv_accel_build::metric_violations \
        [dict remove $release_200_ooc_metrics $metric] \
        $release_200_ooc_limits]
    if {[llength $violations] != 1 ||
        [string first "missing metric '$metric'" \
            [lindex $violations 0]] < 0} {
        error "release_200 OOC missing $metric did not fail closed: $violations"
    }
}
set old_routed_accel_none_counterexample {
Design Timing Summary
--------------------------------------------------------------------------------------
Path Group:  (none)
From Clock:
  To Clock:  clk_pl_0

Max Delay         10433 Endpoints
Min Delay         10433 Endpoints
--------------------------------------------------------------------------------------
Max Delay Paths
Slack:                    inf
  Source:                 conv_accel_ps_dma_i/accel/inst/g_layer_long_hwc_ifm.u_layer_long_replay/u_tile_cache/cfg_tile_pixels_math/DSP_A_B_DATA_INST/B2_DATA[11]
  Destination:            conv_accel_ps_dma_i/accel/inst/g_layer_long_hwc_ifm.u_layer_long_replay/u_tile_cache/next_tile_base_q_reg[31]/D
  Path Group:             (none)
}
if {![catch {
        ::conv_accel_build::parse_system_accel_internal_none_fdre_audit \
            $old_routed_accel_none_counterexample}]} {
    error "legacy hierarchy-scoped timing summary was accepted as a live full-design audit"
}

set clean_system_accel_internal_none_audit {
audit=system_accel_internal_none_fdre
format_version=1
status=COMPLETE
query_scope=full_design
endpoint_scope=accelerator_fdre_d
accelerator_cell=conv_accel_ps_dma_i/accel/inst
fdre_d_endpoints=38558
fanin_startpoints=21023
top_port_startpoints_excluded=0
internal_pin_startpoints=21023
timing_paths_examined=38558
source_group_upper_bound=2
sample_limit=50
sample_count=0
metric.accel_internal_none_fdre_endpoints=0
}
set bad_system_accel_internal_none_audit {
audit=system_accel_internal_none_fdre
format_version=1
status=COMPLETE
query_scope=full_design
endpoint_scope=accelerator_fdre_d
accelerator_cell=conv_accel_ps_dma_i/accel/inst
fdre_d_endpoints=38558
sample_limit=50
sample_count=1
metric.accel_internal_none_fdre_endpoints=1
sample.0=endpoint sink_reg/D startpoint rogue_reg/Q
}
set system_accel_internal_none_limits \
    [dict create max_accel_internal_none_fdre_endpoints 0]
set clean_system_accel_internal_none_metrics \
    [::conv_accel_build::parse_system_accel_internal_none_fdre_audit \
        $clean_system_accel_internal_none_audit]
if {[llength [::conv_accel_build::metric_violations \
        $clean_system_accel_internal_none_metrics \
        $system_accel_internal_none_limits]] != 0} {
    error "zero system accelerator internal-none audit did not pass its zero gate"
}
set bad_system_accel_internal_none_metrics \
    [::conv_accel_build::parse_system_accel_internal_none_fdre_audit \
        $bad_system_accel_internal_none_audit]
set bad_system_accel_internal_none_violations \
    [::conv_accel_build::metric_violations \
        $bad_system_accel_internal_none_metrics \
        $system_accel_internal_none_limits]
if {[llength $bad_system_accel_internal_none_violations] != 1 ||
    [string first "accel_internal_none_fdre_endpoints=1" \
        [lindex $bad_system_accel_internal_none_violations 0]] < 0} {
    error "one system accelerator internal-none endpoint bypassed the zero gate: $bad_system_accel_internal_none_violations"
}
set missing_system_accel_internal_none_violations \
    [::conv_accel_build::metric_violations [dict create] \
        $system_accel_internal_none_limits]
if {[llength $missing_system_accel_internal_none_violations] != 1 ||
    [string first "missing metric 'accel_internal_none_fdre_endpoints'" \
        [lindex $missing_system_accel_internal_none_violations 0]] < 0} {
    error "missing system accelerator internal-none metric did not fail closed: $missing_system_accel_internal_none_violations"
}
foreach malformed_system_accel_internal_none_audit [list \
        {audit=system_accel_internal_none_fdre
format_version=1
status=COMPLETE} \
        {audit=system_accel_internal_none_fdre
format_version=1
status=ERROR
query_scope=full_design
endpoint_scope=accelerator_fdre_d
error={fixture failure}}] {
    if {![catch {
            ::conv_accel_build::parse_system_accel_internal_none_fdre_audit \
                $malformed_system_accel_internal_none_audit}]} {
        error "incomplete/error system accelerator internal-none audit parsed as complete"
    }
}

set clean_ooc_internal_none_audit {
audit=ooc_internal_none_fdre
format_version=1
status=COMPLETE
fdre_d_endpoints=20
fanin_startpoints=4
top_port_startpoints_excluded=1
internal_pin_startpoints=3
timing_paths_examined=20
sample_limit=50
sample_count=0
metric.ooc_internal_none_fdre_endpoints=0
}
set bad_ooc_internal_none_audit {
audit=ooc_internal_none_fdre
format_version=1
status=COMPLETE
fdre_d_endpoints=20
sample_limit=50
sample_count=1
metric.ooc_internal_none_fdre_endpoints=1
sample.0=endpoint sink_reg/D startpoint rogue_reg/Q
}
set ooc_internal_none_limits \
    [dict create max_ooc_internal_none_fdre_endpoints 0]
set clean_ooc_internal_none_metrics \
    [::conv_accel_build::parse_ooc_internal_none_fdre_audit \
        $clean_ooc_internal_none_audit]
if {[llength [::conv_accel_build::metric_violations \
        $clean_ooc_internal_none_metrics \
        $ooc_internal_none_limits]] != 0} {
    error "zero OOC internal (none)->FDRE/D audit did not pass its zero gate"
}
set bad_ooc_internal_none_metrics \
    [::conv_accel_build::parse_ooc_internal_none_fdre_audit \
        $bad_ooc_internal_none_audit]
set bad_ooc_internal_none_violations \
    [::conv_accel_build::metric_violations \
        $bad_ooc_internal_none_metrics $ooc_internal_none_limits]
if {[llength $bad_ooc_internal_none_violations] != 1 ||
    [string first "ooc_internal_none_fdre_endpoints=1" \
        [lindex $bad_ooc_internal_none_violations 0]] < 0} {
    error "one OOC internal (none)->FDRE/D endpoint bypassed the zero gate: $bad_ooc_internal_none_violations"
}
set missing_ooc_internal_none_violations \
    [::conv_accel_build::metric_violations [dict create] \
        $ooc_internal_none_limits]
if {[llength $missing_ooc_internal_none_violations] != 1 ||
    [string first "missing metric 'ooc_internal_none_fdre_endpoints'" \
        [lindex $missing_ooc_internal_none_violations 0]] < 0} {
    error "missing OOC internal (none)->FDRE/D metric did not fail closed: $missing_ooc_internal_none_violations"
}
foreach malformed_ooc_internal_none_audit [list \
        {audit=ooc_internal_none_fdre
format_version=1
status=COMPLETE} \
        {audit=ooc_internal_none_fdre
format_version=1
status=ERROR
error={fixture failure}}] {
    if {![catch {::conv_accel_build::parse_ooc_internal_none_fdre_audit \
            $malformed_ooc_internal_none_audit}]} {
        error "incomplete/error OOC internal (none)->FDRE/D audit parsed as complete"
    }
}

set build_common_script [::conv_accel_build::read_text \
    [file join $script_dir build_common.tcl]]
foreach required_text {
    {all_fanin -flat -trace_arcs timing}
    {-startpoints_only -to $fdre_d_pins}
    {filter $fanin_starts {CLASS == port}}
    {filter $fanin_starts {CLASS != port}}
    {filter $internal_starts {CLASS != pin}}
    {get_property IS_SEQUENTIAL $start_cells}
    {regexp {^(FD|LD)} $start_ref}
    {non_fabric_internal_pin_startpoints_excluded}
    {get_clocks -quiet -of_objects $internal_start}
    {set unclocked_internal_starts [list]}
    {-sort_by group -nworst 1 -max_paths $path_cap}
    {-from $unclocked_internal_starts -to $endpoint_batch}
    {get_property STARTPOINT_CLOCK $path}
    {dict exists $violating_endpoints $endpoint_name}
    {metric.ooc_internal_none_fdre_endpoints}
    {write_system_accel_internal_none_fdre_audit}
    {NAME =~ $accelerator_cell/*}
    {query_scope full_design}
    {endpoint_scope accelerator_fdre_d}
    {metric.accel_internal_none_fdre_endpoints}
    {parse_system_accel_internal_none_fdre_audit}
    {status=ERROR}
} {
    if {[string first $required_text $build_common_script] < 0} {
        error "OOC internal (none)->FDRE/D audit is missing fail-closed text: $required_text"
    }
}
set system_accel_none_fixture_path [file join $script_dir \
    test_system_accel_internal_none_fdre_audit.tcl]
if {![file isfile $system_accel_none_fixture_path]} {
    error "system accelerator internal-none Vivado fixture is missing"
}
set system_accel_none_fixture \
    [::conv_accel_build::read_text $system_accel_none_fixture_path]
foreach required_text {
    {system_accel_internal_none_shell accel}
    {system_accel_internal_none_core inst}
    {write_system_accel_internal_none_fdre_audit}
    {accel_internal_none_fdre_endpoints] != 1}
    {create_clock -name rogue_clk}
    {accel_internal_none_fdre_endpoints] != 0}
    {report_timing_summary -report_unconstrained -max_paths 1}
    {-cells $accel_cells}
    {status=ERROR}
    {parse_system_accel_internal_none_fdre_audit}
} {
    if {[string first $required_text $system_accel_none_fixture] < 0} {
        error "system accelerator internal-none fixture is missing proof text: $required_text"
    }
}
set metrics [dict merge \
    [::conv_accel_build::parse_utilization $sample_util] \
    [::conv_accel_build::parse_timing $sample_timing] \
    [::conv_accel_build::parse_route_status $sample_route] \
    [::conv_accel_build::parse_congestion $sample_congestion]]
foreach {metric expected} {
    lut 83000 logic_lut 72000 lut_memory 8000
    bram 90 uram 48 dsp 370
    clb_sites 12444 clb_available 14640 clb_percent 85.00
    wns 0.500 tns 0.000 failing_endpoints 0 route_errors 0
    congestion_level 4
} {
    if {![dict exists $metrics $metric] || [dict get $metrics $metric] ne $expected} {
        error "report parser returned [expr {[dict exists $metrics $metric] ? \
            [dict get $metrics $metric] : {missing}}] for $metric; expected $expected"
    }
}
dict set metrics drc_errors 0
dict set metrics drc_critical_warnings 0
set limits [dict create max_lut 83000 max_logic_lut 72000 \
    max_lut_memory 8000 max_clb_percent 85.0 \
    max_bram 90 max_uram 48 expected_uram 48 max_dsp 370 \
    max_congestion_level 4 \
    min_wns 0.5 min_tns 0.0 max_failing_endpoints 0 \
    max_route_errors 0 max_drc_errors 0 max_drc_critical_warnings 0]
if {[llength [::conv_accel_build::metric_violations $metrics $limits]] != 0} {
    error "gate parser rejected an exact-boundary passing sample"
}
set wrong_uram_metrics $metrics
dict set wrong_uram_metrics uram 47
set wrong_uram_violations [::conv_accel_build::metric_violations \
    $wrong_uram_metrics $limits]
if {[llength $wrong_uram_violations] != 1 ||
    [string first "does not equal expected_uram=48" \
        [lindex $wrong_uram_violations 0]] < 0} {
    error "exact URAM gate accepted the wrong count: $wrong_uram_violations"
}

set no_congestion_above_3 {
1. Placer Final Level Congestion Reporting
No congestion windows are found above level 3
}
set no_congestion_above_5 {
1. Placer Final Level Congestion Reporting
No congestion windows are found above level 5
}
set ambiguous_no_congestion {
1. Placer Final Level Congestion Reporting
No congestion windows are found in this report
}
set routed_final4_initial5 {
1. Placer Final Level Congestion Reporting
| Direction | Type   | Level | Window |
| North     | Long   |     4 | (...)  |
2. Router Initial Congestion
| Direction | Type   | Level | Window |
| North     | Long   |     5 | (...)  |
* No effective congestion windows are found above level 3
}
set routed_final_metrics \
    [::conv_accel_build::parse_congestion $routed_final4_initial5]
if {![dict exists $routed_final_metrics congestion_level] ||
    [dict get $routed_final_metrics congestion_level] != 4} {
    error "historical router-initial level 5 contaminated final placer congestion: $routed_final_metrics"
}
set router_initial_only {
2. Router Initial Congestion
| Direction | Type   | Level | Window |
| North     | Long   |     3 | (...)  |
}
if {[dict exists [::conv_accel_build::parse_congestion \
        $router_initial_only] congestion_level]} {
    error "router-initial-only congestion report did not fail closed"
}
foreach {sample expected} [list \
        $no_congestion_above_3 3 \
        $no_congestion_above_5 5] {
    set parsed [::conv_accel_build::parse_congestion $sample]
    if {![dict exists $parsed congestion_level] ||
        [dict get $parsed congestion_level] != $expected} {
        error "congestion summary parser returned $parsed; expected conservative level $expected"
    }
}
set summary_metrics [dict remove $metrics congestion_level]
set summary_metrics [dict merge $summary_metrics \
    [::conv_accel_build::parse_congestion $no_congestion_above_3]]
if {[llength [::conv_accel_build::metric_violations \
        $summary_metrics $limits]] != 0} {
    error "level-3 congestion summary did not satisfy a level-4 gate"
}
set summary_metrics [dict remove $metrics congestion_level]
set summary_metrics [dict merge $summary_metrics \
    [::conv_accel_build::parse_congestion $no_congestion_above_5]]
set summary_violations [::conv_accel_build::metric_violations \
    $summary_metrics $limits]
if {[llength $summary_violations] != 1 ||
    [string first "congestion_level=5" [lindex $summary_violations 0]] < 0} {
    error "level-5 congestion summary bypassed a level-4 gate: $summary_violations"
}
set summary_metrics [dict remove $metrics congestion_level]
set summary_metrics [dict merge $summary_metrics \
    [::conv_accel_build::parse_congestion $ambiguous_no_congestion]]
set summary_violations [::conv_accel_build::metric_violations \
    $summary_metrics $limits]
if {[llength $summary_violations] != 1 ||
    [string first "missing metric 'congestion_level'" \
        [lindex $summary_violations 0]] < 0} {
    error "ambiguous congestion summary did not fail closed: $summary_violations"
}
foreach {metric over_budget expected_fragment} {
    lut 83001 {lut=83001}
    logic_lut 72001 {logic_lut=72001}
    lut_memory 8001 {lut_memory=8001}
    clb_percent 85.01 {clb_percent=85.01}
    congestion_level 5 {congestion_level=5}
} {
    set over_metrics $metrics
    dict set over_metrics $metric $over_budget
    set violations [::conv_accel_build::metric_violations $over_metrics $limits]
    if {[llength $violations] != 1 ||
        [string first $expected_fragment [lindex $violations 0]] < 0} {
        error "gate parser did not reject over-budget $metric: $violations"
    }
}
dict set metrics drc_critical_warnings 1
set drc_violations [::conv_accel_build::metric_violations $metrics $limits]
if {[llength $drc_violations] != 1 ||
    [string first "drc_critical_warnings=1" [lindex $drc_violations 0]] < 0} {
    error "gate parser did not reject a DRC critical warning"
}

set digest [::conv_accel_build::sha256_file [file join $script_dir rtl_sources.tcl]]
if {![regexp {^[0-9a-f]{64}$} $digest]} {
    error "SHA256 helper returned an invalid digest: $digest"
}

puts "PASS: build infrastructure static checks ($source_count RTL files, $xsim_test_count manifest XSIM tests, $standalone_xsim_test_count standalone XSIM test, [llength [::conv_accel_build::profile_names]] profiles)"

# Build a minimal PS/DMA integration block design for the AXI-Stream
# convolution accelerator.  This script targets Vivado 2022.2 and validates
# the structural design.  An optional SOM-to-carrier board connection causes
# Vivado Board Flow to apply the KV260 carrier PS peripheral preset as well.

set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
source [file join $script_dir rtl_sources.tcl]
source [file join $script_dir build_common.tcl]
set project_name conv_accel_ps_dma_minimal
set bd_name conv_accel_ps_dma
set build_dir [file join $root build_bd_xck26]
set part xck26-sfvc784-2LV-c
set rows 18
set cols 16
set k_tile 18
set cout_tile 32
# Release profile: the legacy column-PSUM implementation is compiled out and
# OFM leaves the accelerator as dense 64-bit HWC beats.  The packed OFM mode
# remains a CLI option so an explicit 18x8 legacy/debug build is still possible.
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
set jobs 8
set board_part ""
set board_connection ""
set generate_targets 0
set check_only 0
set build_dir_explicit 0
set build_profile [::conv_accel_build::prescan_profile {*}$argv]
set release_profile [::conv_accel_build::is_abi_v2_gated_profile \
    $build_profile]
::conv_accel_build::apply_profile $build_profile

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-project_name"} {
        incr i
        set project_name [lindex $argv $i]
    } elseif {$arg eq "-bd_name"} {
        incr i
        set bd_name [lindex $argv $i]
    } elseif {$arg eq "-build_dir"} {
        incr i
        set build_dir [file normalize [lindex $argv $i]]
        set build_dir_explicit 1
    } elseif {$arg eq "-part"} {
        incr i
        set part [lindex $argv $i]
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
    } elseif {$arg eq "-generate_targets"} {
        set generate_targets 1
    } elseif {$arg eq "-check_only"} {
        set check_only 1
    } elseif {$arg eq "-profile"} {
        incr i
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
    if {!$build_dir_explicit} {
        error "development frequency sweep requires an explicit -build_dir"
    }
    set pl_clock_mhz [::conv_accel_build::validate_development_clock_mhz \
        $development_clock_mhz]
    set metadata_profile [::conv_accel_build::frequency_sweep_profile_name \
        $development_clock_mhz]
}
# The K26 PS clock solver cannot synthesize 200 MHz directly from the board
# preset's shared integer-divided PLLs: a 200 MHz request resolves to about
# 187.498 MHz.  Keep the PS PLLs/preset intact and use its stable nominal
# 100 MHz PL clock as the input to a PL MMCM for the formal 200 MHz build.
# Other profiles and development sweeps retain their historical direct clock.
set use_release_200_clock_wizard [expr {
    [::conv_accel_build::is_abi_v2_200_profile $build_profile] &&
    !$frequency_sweep}]
set ps_pl_clock_mhz [expr {$use_release_200_clock_wizard ? 100 : $pl_clock_mhz}]
set release_clock_tolerance_hz 5000
if {$build_profile ne "" && !$build_dir_explicit} {
    set build_dir [file join $root "build_bd_xck26_${build_profile}"]
}
set release_multi_hp $release_profile
if {$release_multi_hp} {
    set dma_memory_port HP0_HP1_HP2_HP3
    set dma_memory_ports {HP0 HP1 HP2 HP3}
} else {
    set dma_memory_port HP0
    set dma_memory_ports {HP0}
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

# A staged frequency sweep changes only the physical PL clock and publication
# identity.  It remains an ABI-v2 release topology, so every other release
# parameter must still be locked to the source profile.
if {$release_profile} {
    if {$project_name ne "conv_accel_ps_dma_minimal"} {
        error "abi_v2_release locks project_name=conv_accel_ps_dma_minimal; got $project_name"
    }
    if {$bd_name ne "conv_accel_ps_dma"} {
        error "abi_v2_release locks bd_name=conv_accel_ps_dma; got $bd_name"
    }
    if {$part ne "xck26-sfvc784-2LV-c"} {
        error "abi_v2_release locks part=xck26-sfvc784-2LV-c; got $part"
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
        weight_dma_mm2s_burst $weight_dma_mm2s_burst]
    ::conv_accel_build::require_no_violations "$build_profile BD profile" \
        [::conv_accel_build::locked_value_violations \
            $release_defaults $release_actual $release_locked_keys]
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

set rtl_abs_files [::conv_accel_sources::absolute_files $root]
set git_provenance [::conv_accel_build::git_provenance $root]
if {$check_only} {
    puts "PASS: BD build configuration profile=[expr {$build_profile eq {} ? {custom_cli} : $build_profile}] metadata_profile=$metadata_profile rows=$rows cols=$cols cout_tile=$cout_tile tagged=$enable_tagged_context weight_preload=$enable_weight_preload fast_handoff=$enable_fast_context_handoff ifm_epoch_uram=$ifm_epoch_use_uram detailed_trace=$enable_detailed_trace legacy_gpio_status=$enable_legacy_gpio_status psum_fifo=$psum_fifo_depth clock_hz=$clock_hz weight_dma_mm2s_burst=$weight_dma_mm2s_burst git_sha=[dict get $git_provenance git_sha] git_dirty=[dict get $git_provenance git_dirty] sources=[llength $rtl_abs_files]"
    exit
}
if {$build_profile ne ""} {
    ::conv_accel_build::require_vivado_version 2022.2
}
set vivado_version [version -short]

proc connect_clock {clk cells} {
    foreach pin $cells {
        connect_bd_net $clk [get_bd_pins $pin]
    }
}

proc connect_resetn {resetn cells} {
    foreach pin $cells {
        connect_bd_net $resetn [get_bd_pins $pin]
    }
}

proc require_bd_property {object property expected} {
    set actual [get_property $property $object]
    if {$actual ne $expected} {
        error "BD property $property=$actual expected=$expected on $object"
    }
}

proc require_same_bd_intf_net {left right} {
    set left_nets [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $left]]
    set right_nets [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $right]]
    if {[llength $left_nets] != 1 || [llength $right_nets] != 1 ||
        [get_property NAME [lindex $left_nets 0]] ne
        [get_property NAME [lindex $right_nets 0]]} {
        error "ABI-v2 release interface endpoints are not directly connected: $left <-> $right"
    }
}

proc require_same_bd_clock_net {source sinks} {
    set source_nets [get_bd_nets -quiet -of_objects [get_bd_pins $source]]
    if {[llength $source_nets] != 1} {
        error "ABI-v2 release clock source $source has [llength $source_nets] nets"
    }
    set source_name [get_property NAME [lindex $source_nets 0]]
    foreach sink $sinks {
        set sink_nets [get_bd_nets -quiet -of_objects [get_bd_pins $sink]]
        if {[llength $sink_nets] != 1 ||
            [get_property NAME [lindex $sink_nets 0]] ne $source_name} {
            error "ABI-v2 release clock $sink is not on $source_name"
        }
    }
}

proc require_bd_frequency_hz {object expected tolerance label} {
    set actual [get_property CONFIG.FREQ_HZ $object]
    if {![string is integer -strict $actual] &&
        ![string is double -strict $actual]} {
        error "$label has non-numeric CONFIG.FREQ_HZ='$actual'"
    }
    if {abs(double($actual) - double($expected)) > double($tolerance)} {
        error "$label frequency is $actual Hz, expected $expected +/- $tolerance Hz"
    }
    return $actual
}

proc assert_abi_v2_release_bd_structure {board_part board_connection \
        clock_cells expected_pl_clock_mhz expected_clock_hz \
        expected_ps_pl_clock_mhz use_clock_wizard clock_source \
        clock_tolerance_hz expected_weight_burst expected_weight_preload \
        expected_fast_handoff} {
    # Vivado replaces BOARD_PART with a composite SOM/carrier VLNV after
    # BOARD_CONNECTIONS is applied.  BASE_BOARD_PART retains the exact SOM
    # identity selected by the release profile.
    set actual_base_board_part [get_property BASE_BOARD_PART [current_project]]
    if {$actual_base_board_part ne $board_part} {
        error "ABI-v2 release project BASE_BOARD_PART=$actual_base_board_part does not match $board_part"
    }
    if {[list {*}[get_property BOARD_CONNECTIONS [current_project]]] ne
        [list {*}$board_connection]} {
        error "ABI-v2 release project BOARD_CONNECTIONS do not match $board_connection"
    }
    set ila_cells [get_bd_cells -quiet -hierarchical \
        -filter {VLNV =~ "xilinx.com:ip:ila:*"}]
    if {[llength $ila_cells] != 0} {
        error "ABI-v2 release BD contains ILA cells: $ila_cells"
    }
    if {[llength [get_bd_cells -quiet accel_gpio]] != 0} {
        error "ABI-v2 release BD contains the legacy accel_gpio service"
    }
    if {[llength [get_bd_cells -quiet ifm_line_words_invalid]] != 1} {
        error "ABI-v2 release BD is missing the invalid line-word constant"
    }

    set dma_cells [list]
    foreach cell [get_bd_cells -quiet -hierarchical \
            -filter {VLNV =~ "xilinx.com:ip:axi_dma:*"}] {
        lappend dma_cells [file tail [get_property NAME $cell]]
    }
    set dma_cells [lsort $dma_cells]
    set expected_dma_cells [lsort {dma_bias dma_weight dma_ifm dma_ofm}]
    if {$dma_cells ne $expected_dma_cells} {
        error "ABI-v2 release requires exactly four named DMA cells; got $dma_cells"
    }
    foreach name {dma_bias dma_weight dma_ifm} {
        set cell [get_bd_cells $name]
        foreach {property expected} {
            CONFIG.c_include_sg 0
            CONFIG.c_include_mm2s 1
            CONFIG.c_include_s2mm 0
            CONFIG.c_m_axi_mm2s_data_width 64
            CONFIG.c_m_axis_mm2s_tdata_width 64
        } {
            require_bd_property $cell $property $expected
        }
    }
    require_bd_property [get_bd_cells dma_weight] \
        CONFIG.c_mm2s_burst_size $expected_weight_burst
    set ofm_cell [get_bd_cells dma_ofm]
    foreach {property expected} {
        CONFIG.c_include_sg 0
        CONFIG.c_include_mm2s 0
        CONFIG.c_include_s2mm 1
        CONFIG.c_m_axi_s2mm_data_width 64
        CONFIG.c_s_axis_s2mm_tdata_width 64
    } {
        require_bd_property $ofm_cell $property $expected
    }
    if {[llength [get_bd_cells -quiet mem_sc]] != 0} {
        error "ABI-v2 release BD must not contain the shared mem_sc"
    }
    foreach {gp hp} {2 0 3 1 4 2 5 3} {
        require_bd_property [get_bd_cells ps] \
            CONFIG.PSU__USE__S_AXI_GP${gp} 1
        require_bd_property [get_bd_cells ps] \
            CONFIG.PSU__SAXIGP${gp}__DATA_WIDTH 64
    }
    foreach {left right} {
        dma_bias/M_AXI_MM2S ps/S_AXI_HP0_FPD
        dma_weight/M_AXI_MM2S ps/S_AXI_HP1_FPD
        dma_ifm/M_AXI_MM2S ps/S_AXI_HP2_FPD
        dma_ofm/M_AXI_S2MM ps/S_AXI_HP3_FPD
    } {
        require_same_bd_intf_net $left $right
    }
    set pl_mhz [get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ \
        [get_bd_cells ps]]
    if {![string is double -strict $pl_mhz] ||
        abs(double($pl_mhz) - double($expected_ps_pl_clock_mhz)) > 0.001} {
        error "ABI-v2 release PS PL clock request is $pl_mhz MHz, expected $expected_ps_pl_clock_mhz MHz"
    }
    if {$use_clock_wizard} {
        if {[llength [get_bd_cells -quiet pl_clk_wiz]] != 1} {
            error "ABI-v2 release 200 MHz design requires exactly one pl_clk_wiz"
        }
        foreach {property expected} {
            CONFIG.PRIM_SOURCE No_buffer
            CONFIG.PRIMITIVE MMCM
            CONFIG.USE_LOCKED true
            CONFIG.USE_RESET true
            CONFIG.RESET_TYPE ACTIVE_LOW
            CONFIG.RESET_PORT resetn
        } {
            require_bd_property [get_bd_cells pl_clk_wiz] $property $expected
        }
        set requested_wiz_mhz [get_property \
            CONFIG.CLKOUT1_REQUESTED_OUT_FREQ [get_bd_cells pl_clk_wiz]]
        if {![string is double -strict $requested_wiz_mhz] ||
            abs(double($requested_wiz_mhz) - double($expected_pl_clock_mhz)) >
                0.001} {
            error "ABI-v2 release clock wizard request is $requested_wiz_mhz MHz, expected $expected_pl_clock_mhz MHz"
        }
        set pl_actual_mhz [get_property \
            CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ \
            [get_bd_cells ps]]
        if {![string is double -strict $pl_actual_mhz] ||
            abs(double($pl_actual_mhz) -
                double($expected_ps_pl_clock_mhz)) >
                (double($clock_tolerance_hz) / 1000000.0)} {
            error "ABI-v2 release PS PL clock actual is $pl_actual_mhz MHz, expected $expected_ps_pl_clock_mhz MHz +/- [expr {double($clock_tolerance_hz) / 1000000.0}] MHz"
        }
        require_bd_frequency_hz [get_bd_pins ps/pl_clk0] \
            [expr {round(double($expected_ps_pl_clock_mhz) * 1000000.0)}] \
            $clock_tolerance_hz "ABI-v2 release PS pl_clk0"
        require_bd_frequency_hz [get_bd_pins pl_clk_wiz/clk_out1] \
            $expected_clock_hz $clock_tolerance_hz \
            "ABI-v2 release generated PL clock"
        require_same_bd_clock_net ps/pl_clk0 {pl_clk_wiz/clk_in1}
        require_same_bd_clock_net ps/pl_resetn0 \
            {pl_clk_wiz/resetn reset_inv/Op1}
        require_same_bd_clock_net pl_clk_wiz/locked {rst_pl/dcm_locked}
    } elseif {[llength [get_bd_cells -quiet pl_clk_wiz]] != 0} {
        error "non-200/direct-clock release design unexpectedly contains pl_clk_wiz"
    }
    require_same_bd_clock_net $clock_source \
        [concat $clock_cells {rst_pl/slowest_sync_clk}]
    require_bd_property [get_bd_cells accel] CONFIG.ENABLE_WEIGHT_PRELOAD \
        $expected_weight_preload
    require_bd_property [get_bd_cells accel] \
        CONFIG.ENABLE_FAST_CONTEXT_HANDOFF $expected_fast_handoff
    require_bd_property [get_bd_cells accel] CONFIG.CLOCK_HZ \
        $expected_clock_hz
}

file mkdir $build_dir
set project_dir [file join $build_dir $project_name]
create_project -force $project_name $project_dir -part $part
if {$board_part ne ""} {
    set_property board_part $board_part [current_project]
}
if {$board_connection ne ""} {
    if {$board_part eq ""} {
        error "-board_connection requires -board_part"
    }
    # Attaching the carrier connector exposes its PS peripheral preset,
    # including the KV260 debug UART, to board automation.
    set_property board_connections $board_connection [current_project]
}
set_property target_language Verilog [current_project]
add_files -norecurse $rtl_abs_files
# Existing RTL uses unpacked array ports and is compiled as SystemVerilog in
# the standalone synthesis and simulation flows.
set_property file_type SystemVerilog [get_files $rtl_abs_files]
set accel_top conv_accel_core_axi_lite_axis_stream
set_property top $accel_top [current_fileset]
update_compile_order -fileset sources_1

# Vivado 2022.2 module references cannot use a SystemVerilog top source.  The
# accelerator's external pins are flat AXI interfaces, so package the verified
# SystemVerilog hierarchy as a local IP for use inside IP Integrator.
set accel_ip_repo [file join $build_dir ip_repo]
set accel_ip_dir [file join $accel_ip_repo $accel_top]
ipx::package_project -root_dir $accel_ip_dir -vendor user.org -library user \
    -taxonomy /UserIP -import_files
set accel_core [ipx::current_core]
set_property name $accel_top $accel_core
set_property display_name "${rows}x${cols} AXI Stream Convolution Accelerator" $accel_core
set_property description "AXI-Lite controlled int8 systolic convolution accelerator" $accel_core
ipx::infer_bus_interfaces xilinx.com:interface:aximm_rtl:1.0 $accel_core
ipx::infer_bus_interfaces xilinx.com:interface:axis_rtl:1.0 $accel_core
ipx::save_core $accel_core
set_property ip_repo_paths $accel_ip_repo [current_project]
update_ip_catalog -rebuild

create_bd_design $bd_name

# Processor and infrastructure.
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* ps
if {$board_part ne ""} {
    apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
        -config {apply_board_preset "1" make_external "FIXED_IO, DDR"} \
        [get_bd_cells ps]
} else {
    puts "WARNING: no -board_part supplied; the PS/DMA structure is valid for review,"
    puts "         but apply the K26 SOM and KV260 carrier presets before bitstream generation."
}
set ps_properties [list \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $ps_pl_clock_mhz \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__USE__S_AXI_GP0 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__USE__S_AXI_GP3 [expr {$release_multi_hp ? 1 : 0}] \
    CONFIG.PSU__USE__S_AXI_GP4 [expr {$release_multi_hp ? 1 : 0}] \
    CONFIG.PSU__USE__S_AXI_GP5 [expr {$release_multi_hp ? 1 : 0}] \
    CONFIG.PSU__USE__IRQ0 {1} \
]
if {$release_multi_hp} {
    lappend ps_properties \
        CONFIG.PSU__SAXIGP2__DATA_WIDTH {64} \
        CONFIG.PSU__SAXIGP3__DATA_WIDTH {64} \
        CONFIG.PSU__SAXIGP4__DATA_WIDTH {64} \
        CONFIG.PSU__SAXIGP5__DATA_WIDTH {64}
}
set_property -dict $ps_properties [get_bd_cells ps]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rst_pl
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:* reset_inv
set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] [get_bd_cells reset_inv]
if {$use_release_200_clock_wizard} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:* pl_clk_wiz
    set_property -dict [list \
        CONFIG.PRIM_SOURCE {No_buffer} \
        CONFIG.PRIMITIVE {MMCM} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
        CONFIG.USE_LOCKED {true} \
        CONFIG.USE_RESET {true} \
        CONFIG.RESET_TYPE {ACTIVE_LOW} \
        CONFIG.RESET_PORT {resetn} \
    ] [get_bd_cells pl_clk_wiz]
}

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* ctrl_sc
set ctrl_num_mi [expr {$enable_legacy_gpio_status ? 6 : 5}]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI $ctrl_num_mi] \
    [get_bd_cells ctrl_sc]
if {!$release_multi_hp} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* mem_sc
    set_property -dict [list CONFIG.NUM_SI {4} CONFIG.NUM_MI {1}] \
        [get_bd_cells mem_sc]
}

# The existing verified RTL is packaged as a local IP, with the XCK26 resource
# point that passed implementation at 100 MHz.
create_bd_cell -type ip -vlnv user.org:user:conv_accel_core_axi_lite_axis_stream:1.0 accel
set_property -dict [list \
    CONFIG.ROWS $rows \
    CONFIG.COLS $cols \
    CONFIG.K_TILE $k_tile \
    CONFIG.COUT_TILE $cout_tile \
    CONFIG.IFM_BANKS $ifm_banks \
    CONFIG.IFM_FIFO_DEPTH $ifm_fifo_depth \
    CONFIG.IFM_FIFO_AW $ifm_fifo_aw \
    CONFIG.PSUM_FIFO_DEPTH $psum_fifo_depth \
    CONFIG.PSUM_FIFO_AW $psum_fifo_aw \
    CONFIG.HWC_CACHE_AW $hwc_cache_aw \
    CONFIG.HWC_CACHE_DEPTH $hwc_cache_depth \
    CONFIG.HWC_CACHE_STRIPES $hwc_cache_stripes \
    CONFIG.HWC_CACHE_USE_URAM $hwc_cache_use_uram \
    CONFIG.IFM_EPOCH_USE_URAM $ifm_epoch_use_uram \
    CONFIG.MATERIALIZED_CACHE_AW $materialized_cache_aw \
    CONFIG.MATERIALIZED_CACHE_DEPTH $materialized_cache_depth \
    CONFIG.CLOCK_HZ $clock_hz \
    CONFIG.TAIL_CYCLES_CONFIG $tail_cycles \
    CONFIG.ENABLE_COLUMN_PSUM $enable_column_psum \
    CONFIG.ENABLE_PACKED_HWC_OFM $enable_packed_hwc_ofm \
    CONFIG.ENABLE_LAYER_TILE_SEQUENCER $enable_layer_tile_sequencer \
    CONFIG.ENABLE_LAYER_LONG_HWC_IFM $enable_layer_long_hwc_ifm \
    CONFIG.ENABLE_TAGGED_CONTEXT $enable_tagged_context \
    CONFIG.ENABLE_WEIGHT_PRELOAD $enable_weight_preload \
    CONFIG.ENABLE_FAST_CONTEXT_HANDOFF $enable_fast_context_handoff \
    CONFIG.ENABLE_DETAILED_TRACE $enable_detailed_trace \
] [get_bd_cells accel]

# Three DDR-to-stream channels supply layer inputs; one stream-to-DDR channel
# captures packed HWC output in the release profile.  An explicitly selected
# legacy build still emits the byte/address-form debug stream.
foreach name {dma_bias dma_weight dma_ifm} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:* $name
    set_property -dict [list \
        CONFIG.c_include_sg {0} \
        CONFIG.c_sg_length_width {26} \
        CONFIG.c_include_mm2s {1} \
        CONFIG.c_include_s2mm {0} \
        CONFIG.c_m_axi_mm2s_data_width {64} \
        CONFIG.c_m_axis_mm2s_tdata_width {64} \
    ] [get_bd_cells $name]
}
set_property -dict [list CONFIG.c_mm2s_burst_size \
    $weight_dma_mm2s_burst] [get_bd_cells dma_weight]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:* dma_ofm
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_include_mm2s {0} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {64} \
] [get_bd_cells dma_ofm]

# The release graph has no software-serviced line feeder, so omit the legacy
# GPIO/status hierarchy and tie its line-word input to the explicitly invalid
# value zero.  The debug profile retains the historical service unchanged.
if {$enable_legacy_gpio_status} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:* accel_gpio
    set_property -dict [list \
        CONFIG.C_IS_DUAL {1} \
        CONFIG.C_GPIO_WIDTH {9} \
        CONFIG.C_ALL_OUTPUTS {1} \
        CONFIG.C_GPIO2_WIDTH {16} \
        CONFIG.C_ALL_INPUTS_2 {1} \
    ] [get_bd_cells accel_gpio]
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:* status_concat
    set_property -dict [list CONFIG.NUM_PORTS {8} CONFIG.IN7_WIDTH {9}] \
        [get_bd_cells status_concat]
} else {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* \
        ifm_line_words_invalid
    set_property -dict [list CONFIG.CONST_WIDTH {9} CONFIG.CONST_VAL {0}] \
        [get_bd_cells ifm_line_words_invalid]
}

# DMA interrupts may be consumed by software after the polling smoke test.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:* irq_concat
set_property -dict [list CONFIG.NUM_PORTS {4}] [get_bd_cells irq_concat]

# AXI-Lite control path from the PS.
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins ctrl_sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M00_AXI] [get_bd_intf_pins accel/s_axi]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M01_AXI] [get_bd_intf_pins dma_bias/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M02_AXI] [get_bd_intf_pins dma_weight/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M03_AXI] [get_bd_intf_pins dma_ifm/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M04_AXI] [get_bd_intf_pins dma_ofm/S_AXI_LITE]
if {$enable_legacy_gpio_status} {
    connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M05_AXI] \
        [get_bd_intf_pins accel_gpio/S_AXI]
}

# Release traffic uses four independent 64-bit PS high-performance ports.  A
# legacy/debug build retains the historical four-to-one SmartConnect graph.
if {$release_multi_hp} {
    connect_bd_intf_net [get_bd_intf_pins dma_bias/M_AXI_MM2S] \
        [get_bd_intf_pins ps/S_AXI_HP0_FPD]
    connect_bd_intf_net [get_bd_intf_pins dma_weight/M_AXI_MM2S] \
        [get_bd_intf_pins ps/S_AXI_HP1_FPD]
    connect_bd_intf_net [get_bd_intf_pins dma_ifm/M_AXI_MM2S] \
        [get_bd_intf_pins ps/S_AXI_HP2_FPD]
    connect_bd_intf_net [get_bd_intf_pins dma_ofm/M_AXI_S2MM] \
        [get_bd_intf_pins ps/S_AXI_HP3_FPD]
} else {
    connect_bd_intf_net [get_bd_intf_pins dma_bias/M_AXI_MM2S] \
        [get_bd_intf_pins mem_sc/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins dma_weight/M_AXI_MM2S] \
        [get_bd_intf_pins mem_sc/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins dma_ifm/M_AXI_MM2S] \
        [get_bd_intf_pins mem_sc/S02_AXI]
    connect_bd_intf_net [get_bd_intf_pins dma_ofm/M_AXI_S2MM] \
        [get_bd_intf_pins mem_sc/S03_AXI]
    connect_bd_intf_net [get_bd_intf_pins mem_sc/M00_AXI] \
        [get_bd_intf_pins ps/S_AXI_HP0_FPD]
}

# AXI-Stream layer movement.
connect_bd_intf_net [get_bd_intf_pins dma_bias/M_AXIS_MM2S] [get_bd_intf_pins accel/bias_s_axis]
connect_bd_intf_net [get_bd_intf_pins dma_weight/M_AXIS_MM2S] [get_bd_intf_pins accel/weight_s_axis]
connect_bd_intf_net [get_bd_intf_pins dma_ifm/M_AXIS_MM2S] [get_bd_intf_pins accel/ifm_s_axis]
connect_bd_intf_net [get_bd_intf_pins accel/ofm_m_axis] [get_bd_intf_pins dma_ofm/S_AXIS_S2MM]

# Single profile-selected PL clock domain and reset.  The formal 200 MHz
# release uses a clock wizard because the K26 PS's nominal 200 MHz request is
# otherwise quantized to about 187.5 MHz by the board preset's shared IOPLL.
if {$use_release_200_clock_wizard} {
    connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins pl_clk_wiz/clk_in1]
    connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins pl_clk_wiz/resetn]
    connect_bd_net [get_bd_pins pl_clk_wiz/locked] [get_bd_pins rst_pl/dcm_locked]
    set pl_clk [get_bd_pins pl_clk_wiz/clk_out1]
    set pl_clock_source pl_clk_wiz/clk_out1
} else {
    set pl_clk [get_bd_pins ps/pl_clk0]
    set pl_clock_source ps/pl_clk0
}
set periph_resetn [get_bd_pins rst_pl/peripheral_aresetn]
connect_bd_net $pl_clk [get_bd_pins rst_pl/slowest_sync_clk]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins reset_inv/Op1]
connect_bd_net [get_bd_pins reset_inv/Res] [get_bd_pins rst_pl/ext_reset_in]
set pl_clock_cells {
    ps/maxihpm0_fpd_aclk
    ps/saxihp0_fpd_aclk
    ctrl_sc/aclk
    accel/clk
    dma_bias/s_axi_lite_aclk
    dma_bias/m_axi_mm2s_aclk
    dma_weight/s_axi_lite_aclk
    dma_weight/m_axi_mm2s_aclk
    dma_ifm/s_axi_lite_aclk
    dma_ifm/m_axi_mm2s_aclk
    dma_ofm/s_axi_lite_aclk
    dma_ofm/m_axi_s2mm_aclk
}
if {$release_multi_hp} {
    lappend pl_clock_cells \
        ps/saxihp1_fpd_aclk \
        ps/saxihp2_fpd_aclk \
        ps/saxihp3_fpd_aclk
} else {
    lappend pl_clock_cells mem_sc/aclk
}
if {$enable_legacy_gpio_status} {
    lappend pl_clock_cells accel_gpio/s_axi_aclk
}
connect_clock $pl_clk $pl_clock_cells
set peripheral_resetn_cells {
    ctrl_sc/aresetn
    dma_bias/axi_resetn
    dma_weight/axi_resetn
    dma_ifm/axi_resetn
    dma_ofm/axi_resetn
}
if {!$release_multi_hp} {
    lappend peripheral_resetn_cells mem_sc/aresetn
}
if {$enable_legacy_gpio_status} {
    lappend peripheral_resetn_cells accel_gpio/s_axi_aresetn
}
connect_resetn $periph_resetn $peripheral_resetn_cells
connect_bd_net [get_bd_pins rst_pl/peripheral_reset] [get_bd_pins accel/rst]

# GPIO channel 1 is software-written fm_w/line_words.  GPIO channel 2 bit map:
# [0]=bias request, [1]=weight request, [2]=IFM line request,
# [3]=OFM FIFO full, [4]=bias error, [5]=weight error, [6]=IFM error,
# [15:7]=requested IFM fy for the line-fill DMA service.
if {$enable_legacy_gpio_status} {
    connect_bd_net [get_bd_pins accel_gpio/gpio_io_o] \
        [get_bd_pins accel/ifm_line_words]
    connect_bd_net [get_bd_pins accel/bias_load_req] [get_bd_pins status_concat/In0]
    connect_bd_net [get_bd_pins accel/weight_load_req] [get_bd_pins status_concat/In1]
    connect_bd_net [get_bd_pins accel/feeder_fill_req] [get_bd_pins status_concat/In2]
    connect_bd_net [get_bd_pins accel/ofm_packet_full] [get_bd_pins status_concat/In3]
    connect_bd_net [get_bd_pins accel/bias_axis_error] [get_bd_pins status_concat/In4]
    connect_bd_net [get_bd_pins accel/weight_axis_error] [get_bd_pins status_concat/In5]
    connect_bd_net [get_bd_pins accel/ifm_axis_error] [get_bd_pins status_concat/In6]
    connect_bd_net [get_bd_pins accel/feeder_fill_fy] [get_bd_pins status_concat/In7]
    connect_bd_net [get_bd_pins status_concat/dout] [get_bd_pins accel_gpio/gpio2_io_i]
} else {
    connect_bd_net [get_bd_pins ifm_line_words_invalid/dout] \
        [get_bd_pins accel/ifm_line_words]
}

connect_bd_net [get_bd_pins dma_bias/mm2s_introut] [get_bd_pins irq_concat/In0]
connect_bd_net [get_bd_pins dma_weight/mm2s_introut] [get_bd_pins irq_concat/In1]
connect_bd_net [get_bd_pins dma_ifm/mm2s_introut] [get_bd_pins irq_concat/In2]
connect_bd_net [get_bd_pins dma_ofm/s2mm_introut] [get_bd_pins irq_concat/In3]
connect_bd_net [get_bd_pins irq_concat/dout] [get_bd_pins ps/pl_ps_irq0]

# Keep DMA address spaces focused on DDR.  The generic assign_bd_address flow
# also considers PS OCM register segments and emits exclusions that do not
# belong to this DDR-based smoke-test path.
if {$release_multi_hp} {
    foreach {dma address_space segment} {
        dma_bias Data_MM2S SAXIGP2/HP0_DDR_LOW
        dma_weight Data_MM2S SAXIGP3/HP1_DDR_LOW
        dma_ifm Data_MM2S SAXIGP4/HP2_DDR_LOW
        dma_ofm Data_S2MM SAXIGP5/HP3_DDR_LOW
    } {
        assign_bd_address -offset 0x00000000 -range 2G \
            -target_address_space [get_bd_addr_spaces ${dma}/${address_space}] \
            [get_bd_addr_segs ps/${segment}]
    }
} else {
    foreach {dma address_space} {
        dma_bias Data_MM2S
        dma_weight Data_MM2S
        dma_ifm Data_MM2S
        dma_ofm Data_S2MM
    } {
        assign_bd_address -offset 0x00000000 -range 2G \
            -target_address_space [get_bd_addr_spaces ${dma}/${address_space}] \
            [get_bd_addr_segs ps/SAXIGP2/HP0_DDR_LOW]
    }
}

assign_bd_address -offset 0xA0000000 -range 4K \
    -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs accel/s_axi/reg0]
if {$enable_legacy_gpio_status} {
    assign_bd_address -offset 0xA0010000 -range 64K \
        -target_address_space [get_bd_addr_spaces ps/Data] \
        [get_bd_addr_segs accel_gpio/S_AXI/Reg]
}
assign_bd_address -offset 0xA0020000 -range 64K \
    -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs dma_bias/S_AXI_LITE/Reg]
assign_bd_address -offset 0xA0030000 -range 64K \
    -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs dma_weight/S_AXI_LITE/Reg]
assign_bd_address -offset 0xA0040000 -range 64K \
    -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs dma_ifm/S_AXI_LITE/Reg]
assign_bd_address -offset 0xA0050000 -range 64K \
    -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs dma_ofm/S_AXI_LITE/Reg]
validate_bd_design
if {$release_profile} {
    assert_abi_v2_release_bd_structure $board_part $board_connection \
        $pl_clock_cells $pl_clock_mhz $clock_hz $ps_pl_clock_mhz \
        $use_release_200_clock_wizard $pl_clock_source \
        $release_clock_tolerance_hz \
        $weight_dma_mm2s_burst $enable_weight_preload \
        $enable_fast_context_handoff
}
set ps_pl_clock_actual_mhz [get_property \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ [get_bd_cells ps]]
set pl_clock_actual_hz [get_property CONFIG.FREQ_HZ $pl_clk]
save_bd_design

set metadata [dict merge [dict create \
    project_name $project_name bd_name $bd_name part $part \
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
    ifm_line_words_invalid_value 0 ctrl_num_mi $ctrl_num_mi \
    ifm_banks $ifm_banks ifm_fifo_depth $ifm_fifo_depth \
    ifm_fifo_aw $ifm_fifo_aw psum_fifo_depth $psum_fifo_depth \
    psum_fifo_aw $psum_fifo_aw hwc_cache_aw $hwc_cache_aw \
    hwc_cache_depth $hwc_cache_depth hwc_cache_stripes $hwc_cache_stripes \
    hwc_cache_use_uram $hwc_cache_use_uram \
    ifm_epoch_use_uram $ifm_epoch_use_uram \
    materialized_cache_aw $materialized_cache_aw \
    materialized_cache_depth $materialized_cache_depth \
    tail_cycles $tail_cycles jobs $jobs generate_targets $generate_targets \
    pl_clock_mhz $pl_clock_mhz clock_hz $clock_hz \
    ps_pl_clock_mhz $ps_pl_clock_mhz \
    ps_pl_clock_actual_mhz $ps_pl_clock_actual_mhz \
    pl_clock_actual_hz $pl_clock_actual_hz \
    pl_clock_generator [expr {$use_release_200_clock_wizard ? \
        {clk_wiz_mmcm} : {ps_direct}}] \
    pl_clock_tolerance_hz $release_clock_tolerance_hz \
    clock_period_ns [format %.6f $clock_period_ns] \
    source_profile $build_profile \
    release_eligible [::conv_accel_build::is_abi_v2_release_profile \
        $build_profile] \
    ablation_profile [::conv_accel_build::is_abi_v2_ablation_profile \
        $build_profile] \
    development_frequency_sweep $frequency_sweep \
    weight_dma_mm2s_burst $weight_dma_mm2s_burst \
    mm2s_dma_count 3 s2mm_dma_count 1 \
    dma_data_width 64 dma_memory_port $dma_memory_port \
    dma_memory_ports $dma_memory_ports ila_enabled 0] \
    $git_provenance [dict create vivado_version $vivado_version]]
::conv_accel_build::write_build_metadata [file join $build_dir build_profile.txt] \
    $metadata_profile $metadata

if {$generate_targets} {
    set bd_file [get_files "${bd_name}.bd"]
    generate_target all $bd_file
    make_wrapper -files $bd_file -top
    add_files -norecurse [file join $project_dir "${project_name}.gen" sources_1 bd $bd_name hdl "${bd_name}_wrapper.v"]
    update_compile_order -fileset sources_1
}

puts "=== Block Design validation complete ==="
puts "Project: [file join $project_dir ${project_name}.xpr]"
puts "BD: [get_files ${bd_name}.bd]"
puts "Profile: [expr {$build_profile eq {} ? {custom_cli} : $build_profile}]"
puts "Accelerator: ROWS=$rows COLS=$cols K_TILE=$k_tile COUT_TILE=$cout_tile ENABLE_COLUMN_PSUM=$enable_column_psum ENABLE_PACKED_HWC_OFM=$enable_packed_hwc_ofm ENABLE_LAYER_TILE_SEQUENCER=$enable_layer_tile_sequencer ENABLE_LAYER_LONG_HWC_IFM=$enable_layer_long_hwc_ifm ENABLE_TAGGED_CONTEXT=$enable_tagged_context ENABLE_WEIGHT_PRELOAD=$enable_weight_preload ENABLE_FAST_CONTEXT_HANDOFF=$enable_fast_context_handoff IFM_EPOCH_USE_URAM=$ifm_epoch_use_uram ENABLE_DETAILED_TRACE=$enable_detailed_trace ENABLE_LEGACY_GPIO_STATUS=$enable_legacy_gpio_status IFM_BANKS=$ifm_banks IFM_FIFO_DEPTH=$ifm_fifo_depth IFM_FIFO_AW=$ifm_fifo_aw PSUM_FIFO_DEPTH=$psum_fifo_depth PSUM_FIFO_AW=$psum_fifo_aw"
puts "Build metadata: [file join $build_dir build_profile.txt]"
puts "Clock: target=$pl_clock_mhz MHz source=[expr {$use_release_200_clock_wizard ? {PS pl_clk0 nominal 100 MHz -> clk_wiz MMCM} : {PS pl_clk0 direct}}] (CLOCK_HZ=$clock_hz)"
puts "For KV260 use -board_part xilinx.com:kv260_som:part0:1.4 with"
puts "  -board_connection {som240_1_connector xilinx.com:kv260_carrier:som240_1_connector:1.3}"
puts "to apply the SOM DDR and carrier PS peripheral presets."

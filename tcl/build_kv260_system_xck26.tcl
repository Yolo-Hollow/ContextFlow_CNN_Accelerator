# Build the complete KV260 PS/DMA/accelerator hardware platform in Vivado
# 2022.2.  The generated XSA is the hardware handoff for a later Vitis
# bare-metal smoke-test application.

set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
set build_dir [file join $root build_system_xck26_kv260]
set project_name conv_accel_ps_dma_minimal
set bd_name conv_accel_ps_dma
set board_part xilinx.com:kv260_som:part0:1.4
set board_connection [list som240_1_connector xilinx.com:kv260_carrier:som240_1_connector:1.3]
set rows 18
set cols 8
set k_tile 18
set cout_tile 16
set ifm_banks 2
set ifm_fifo_depth 1024
set ifm_fifo_aw 10
set psum_fifo_depth 1024
set psum_fifo_aw 10
set hwc_cache_aw 16
set hwc_cache_depth 43264
set hwc_cache_stripes 4
set hwc_cache_use_uram 1
set tail_cycles 1
set jobs 8
set synth_only 0
set reuse_synth 0

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-build_dir"} {
        incr i
        set build_dir [file normalize [lindex $argv $i]]
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
    } elseif {$arg eq "-tail_cycles"} {
        incr i
        set tail_cycles [lindex $argv $i]
    } elseif {$arg eq "-jobs"} {
        incr i
        set jobs [lindex $argv $i]
    } elseif {$arg eq "-synth_only"} {
        set synth_only 1
    } elseif {$arg eq "-reuse_synth"} {
        set reuse_synth 1
    } else {
        error "unknown argument: $arg"
    }
}

set report_dir [file join $build_dir reports]
file mkdir $report_dir

set wrapper_top "${bd_name}_wrapper"
if {$reuse_synth} {
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
        -ifm_banks $ifm_banks \
        -ifm_fifo_depth $ifm_fifo_depth \
        -ifm_fifo_aw $ifm_fifo_aw \
        -psum_fifo_depth $psum_fifo_depth \
        -psum_fifo_aw $psum_fifo_aw \
        -hwc_cache_aw $hwc_cache_aw \
        -hwc_cache_depth $hwc_cache_depth \
        -hwc_cache_stripes $hwc_cache_stripes \
        -hwc_cache_use_uram $hwc_cache_use_uram \
        -tail_cycles $tail_cycles \
        -generate_targets \
    ]
    source [file join $script_dir create_ps_dma_bd_xck26.tcl]
    set argv $saved_argv

    set_property top $wrapper_top [current_fileset]
    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1

    puts "=== System synthesis: top=$wrapper_top board=$board_part carrier=$board_connection tail_cycles=$tail_cycles jobs=$jobs ==="
    reset_run synth_1
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
    set synth_status [get_property STATUS [get_runs synth_1]]
    puts "Synthesis status: $synth_status"
    if {![string match "*Complete*" $synth_status]} {
        error "system synthesis did not complete: $synth_status"
    }

    open_run synth_1
    report_utilization -file [file join $report_dir system_synth_utilization.rpt]
    report_utilization -hierarchical -file [file join $report_dir system_synth_utilization_hier.rpt]
    report_timing_summary -file [file join $report_dir system_synth_timing_summary.rpt]
    close_design
}

if {$synth_only} {
    puts "=== Synthesis-only build complete ==="
    puts "Reports: $report_dir"
    exit
}

puts "=== System implementation and bitstream generation ==="
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "Implementation status: $impl_status"
if {![string match "*Complete*" $impl_status]} {
    error "system implementation did not complete: $impl_status"
}

open_run impl_1
report_utilization -file [file join $report_dir system_impl_utilization.rpt]
report_route_status -file [file join $report_dir system_impl_route_status.rpt]
report_timing_summary -file [file join $report_dir system_impl_timing_summary.rpt]

set xsa_file [file join $build_dir "${project_name}.xsa"]
write_hw_platform -fixed -include_bit -force $xsa_file

puts "=== KV260 hardware platform build complete ==="
puts "Project: [file join $build_dir $project_name ${project_name}.xpr]"
puts "Reports: $report_dir"
puts "XSA: $xsa_file"

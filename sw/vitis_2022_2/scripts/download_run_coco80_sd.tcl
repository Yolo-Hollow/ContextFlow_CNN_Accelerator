# Program the signed r5 image and start one persistent COCO80 SD runner ELF.

set script_dir [file dirname [file normalize [info script]]]
set sw_dir [file dirname $script_dir]
set root [file dirname [file dirname $sw_dir]]
set workspace [file normalize [file join $root build_vitis_2022_2_coco80_r5]]
set bit_file [file normalize [file join $root build_abi_v2_release_r5 \
    conv_accel_ps_dma_minimal conv_accel_ps_dma_minimal.runs impl_1 \
    conv_accel_ps_dma_wrapper.bit]]
set elf ""
set check_only 0

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg in {-workspace -bit_file -elf}} {
        incr i
        if {$i >= [llength $argv]} { error "$arg requires a value" }
        set value [file normalize [lindex $argv $i]]
        if {$arg eq "-workspace"} {
            set workspace $value
        } elseif {$arg eq "-bit_file"} {
            set bit_file $value
        } else {
            set elf $value
        }
    } elseif {$arg eq "-check_only"} {
        set check_only 1
    } else {
        error "unknown argument: $arg"
    }
}

set marker [file join $workspace .coco80_r5_workspace]
set psu_init_tcl [file join $workspace coco80_r5_platform hw psu_init.tcl]
if {![file isfile $marker]} { error "not a COCO80 r5 workspace: $workspace" }
if {![file isfile $bit_file]} { error "r5 bitstream not found: $bit_file" }
if {$elf eq "" || ![file isfile $elf]} { error "COCO80 runner ELF not found: $elf" }
if {![file isfile $psu_init_tcl]} { error "psu_init.tcl not found: $psu_init_tcl" }
if {[file tail $bit_file] ne "conv_accel_ps_dma_wrapper.bit"} {
    error "unexpected r5 bitstream name: $bit_file"
}
if {[string first "coco80_r5_" [file tail $elf]] != 0} {
    error "unexpected COCO80 runner ELF name: $elf"
}
if {$check_only} {
    puts "PASS: COCO80 SD download selection verified"
    puts "Workspace: $workspace"
    puts "Bitstream: $bit_file"
    puts "ELF: $elf"
    exit 0
}

connect -url tcp:127.0.0.1:3121
puts "=== JTAG targets ==="
set a53_targets {}
set target_list ""
for {set attempt 0} {$attempt < 40} {incr attempt} {
    set target_list [targets]
    set a53_targets [targets -filter {name =~ "Cortex-A53 #0"}]
    if {[llength $a53_targets] != 0} {
        break
    }
    after 250
}
puts $target_list
if {[llength $a53_targets] == 0} {
    error "Cortex-A53 #0 target not found"
}

targets -set -nocase -filter {name =~ "*PSU*"}
puts "System reset"
catch {stop}
rst -system
after 3000
source $psu_init_tcl
targets -set -nocase -filter {name =~ "*PSU*"}
puts "Running psu_init"
psu_init
puts "Programming signed r5 PL image: $bit_file"
fpga -file $bit_file
puts "Removing PS-PL isolation and applying reset configuration"
psu_ps_pl_isolation_removal
psu_ps_pl_reset_config
psu_post_config

targets -set -nocase -filter {name =~ "Cortex-A53 #0"}
catch {stop}
rst -processor -clear-registers
after 1000
puts "Downloading persistent COCO80 SD runner: $elf"
dow $elf
puts "Starting COCO80 SD runner"
con

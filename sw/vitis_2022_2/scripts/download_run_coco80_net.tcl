# Program the signed r5 image and start the persistent COCO80 Ethernet runner.

set script_dir [file dirname [file normalize [info script]]]
set sw_dir [file dirname $script_dir]
set root [file dirname [file dirname $sw_dir]]
set workspace [file normalize [file join $root build_vitis_2022_2_coco80_r5_net]]
set bit_file [file normalize [file join $root build_abi_v2_release_r5 \
    conv_accel_ps_dma_minimal conv_accel_ps_dma_minimal.runs impl_1 \
    conv_accel_ps_dma_wrapper.bit]]
set elf ""
set worker_elf [list "" "" ""]
set check_only 0

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg in {-workspace -bit_file -elf -worker1 -worker2 -worker3}} {
        incr i
        if {$i >= [llength $argv]} { error "$arg requires a value" }
        set value [file normalize [lindex $argv $i]]
        if {$arg eq "-workspace"} { set workspace $value
        } elseif {$arg eq "-bit_file"} { set bit_file $value
        } elseif {$arg eq "-elf"} { set elf $value
        } elseif {$arg eq "-worker1"} { lset worker_elf 0 $value
        } elseif {$arg eq "-worker2"} { lset worker_elf 1 $value
        } else { lset worker_elf 2 $value }
    } elseif {$arg eq "-check_only"} {
        set check_only 1
    } else { error "unknown argument: $arg" }
}

set marker [file join $workspace .coco80_r5_net_workspace]
set psu_init_tcl [file join $workspace coco80_r5_net_platform hw psu_init.tcl]
if {![file isfile $marker]} { error "not a COCO80 r5 network workspace: $workspace" }
if {![file isfile $bit_file]} { error "r5 bitstream not found: $bit_file" }
if {$elf eq "" || ![file isfile $elf]} { error "COCO80 network ELF not found: $elf" }
for {set worker 0} {$worker < 3} {incr worker} {
    set path [lindex $worker_elf $worker]
    if {$path eq "" || ![file isfile $path]} {
        error "COCO80 A53 worker [expr {$worker + 1}] ELF not found: $path"
    }
    if {[file tail $path] ne "coco80_r5_worker_[expr {$worker + 1}].elf"} {
        error "unexpected COCO80 worker ELF name: $path"
    }
}
if {![file isfile $psu_init_tcl]} { error "psu_init.tcl not found: $psu_init_tcl" }
if {[file tail $bit_file] ne "conv_accel_ps_dma_wrapper.bit"} {
    error "unexpected r5 bitstream name: $bit_file"
}
if {[file tail $elf] ne "coco80_r5_ethernet.elf"} {
    error "unexpected COCO80 Ethernet ELF name: $elf"
}
if {$check_only} {
    puts "PASS: COCO80 Ethernet download selection verified"
    puts "Workspace: $workspace"
    puts "Bitstream: $bit_file"
    puts "ELF: $elf"
    puts "Workers: $worker_elf"
    exit 0
}

connect -url tcp:127.0.0.1:3121
puts "=== JTAG targets ==="
set a53_targets {}
set target_list ""
for {set attempt 0} {$attempt < 40} {incr attempt} {
    set target_list [targets]
    set a53_targets [targets -filter {name =~ "Cortex-A53 #0"}]
    if {[llength $a53_targets] != 0} { break }
    after 250
}
puts $target_list
if {[llength $a53_targets] == 0} { error "Cortex-A53 #0 target not found" }

targets -set -nocase -filter {name =~ "*PSU*"}
catch {stop}
rst -system
after 3000
source $psu_init_tcl
targets -set -nocase -filter {name =~ "*PSU*"}
psu_init
puts "Programming signed r5 PL image: $bit_file"
fpga -file $bit_file
psu_ps_pl_isolation_removal
psu_ps_pl_reset_config
psu_post_config
targets -set -nocase -filter {name =~ "Cortex-A53 #0"}
catch {stop}
rst -processor -clear-registers
after 1000
puts "Downloading persistent COCO80 Ethernet runner: $elf"
dow $elf
for {set worker 1} {$worker <= 3} {incr worker} {
    targets -set -nocase -filter "name =~ \"Cortex-A53 #$worker\""
    catch {stop}
    rst -processor -clear-registers
    puts "Downloading COCO80 A53 worker $worker: [lindex $worker_elf [expr {$worker - 1}]]"
    dow [lindex $worker_elf [expr {$worker - 1}]]
}
# DDR survives the processor reset used above.  Invalidate the persistent
# mailbox before any worker runs, otherwise a worker can observe the previous
# session's magic/controller_ready, register against that stale session, and
# then lose its registration when A53 #0 clears the mailbox for the new boot.
targets -set -nocase -filter {name =~ "Cortex-A53 #0"}
mwr 0x7D600000 0x00000000
mwr 0x7D600008 0x00000000
# Start the worker cores first.  They immediately initialize their mailbox
# slots and wait for commands, so the primary core can verify all three
# workers without racing the comparatively slow JTAG target switches.
for {set worker 1} {$worker <= 3} {incr worker} {
    targets -set -nocase -filter "name =~ \"Cortex-A53 #$worker\""
    puts "Starting COCO80 A53 worker $worker"
    con
}
targets -set -nocase -filter {name =~ "Cortex-A53 #0"}
puts "Starting COCO80 Ethernet runner (192.168.10.2:5001)"
con

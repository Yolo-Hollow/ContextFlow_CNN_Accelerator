set script_dir [file dirname [file normalize [info script]]]
set sw_dir [file dirname $script_dir]
set root [file dirname [file dirname $sw_dir]]

set workspace [file normalize [file join $root build_vitis_2022_2]]
set hw_dir [file join $workspace conv_accel_kv260_platform hw]
set bit_file [file join $hw_dir conv_accel_ps_dma_minimal.bit]
set psu_init_tcl [file join $hw_dir psu_init.tcl]
set elf [file join $workspace conv_accel_r18_c16_smoke manual_build conv_accel_r18_c8_smoke.elf]
set fast_run 0
set skip_bit 0
set data_file ""
set data_address 0x10000000

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-bit_file"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -bit_file"
        }
        set bit_file [file normalize [lindex $argv $i]]
    } elseif {$arg eq "-elf"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -elf"
        }
        set elf [file normalize [lindex $argv $i]]
    } elseif {$arg eq "-fast"} {
        set fast_run 1
    } elseif {$arg eq "-skip_bit"} {
        set skip_bit 1
    } elseif {$arg eq "-data_file"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -data_file"
        }
        set data_file [file normalize [lindex $argv $i]]
    } elseif {$arg eq "-data_address"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -data_address"
        }
        set data_address [lindex $argv $i]
    } else {
        error "Unknown argument: $arg"
    }
}

if {![file exists $elf]} {
    error "ELF not found: $elf. Run sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 first."
}
if {!$fast_run && !$skip_bit && ![file exists $bit_file]} {
    error "Bitstream not found: $bit_file. Build or select a valid hardware image first."
}
if {!$fast_run && ![file exists $psu_init_tcl]} {
    error "psu_init.tcl not found: $psu_init_tcl. Create the Vitis platform first."
}
if {$data_file ne "" && ![file exists $data_file]} {
    error "DDR data file not found: $data_file"
}

connect -url tcp:127.0.0.1:3121
puts "=== JTAG targets ==="
targets
puts "=== Raw JTAG chain ==="
jtag targets

if {[llength [targets -filter {name =~ "Cortex-A53 #0"}]] == 0} {
    error "Cortex-A53 #0 target not found. hw_server sees no usable KV260 JTAG target."
}

if {!$fast_run} {
    targets -set -nocase -filter {name =~ "*PSU*"}
    puts "System reset"
    catch {stop}
    rst -system
    after 3000

    source $psu_init_tcl
    targets -set -nocase -filter {name =~ "*PSU*"}
    puts "Running psu_init"
    psu_init

    if {$skip_bit} {
        puts "Skipping PL programming; keeping current bitstream"
    } else {
        puts "Programming PL: $bit_file"
        fpga -file $bit_file
    }

    puts "Removing PS-PL isolation"
    psu_ps_pl_isolation_removal
    puts "Applying PS-PL reset config"
    psu_ps_pl_reset_config
    psu_post_config
} else {
    puts "Fast run: keeping current PS/PL init and programmed bitstream"
}

targets -set -nocase -filter {name =~ "Cortex-A53 #0"}
puts "Resetting Cortex-A53 #0"
catch {stop}
rst -processor -clear-registers
after 1000

puts "Downloading ELF: $elf"
dow $elf
if {$data_file ne ""} {
    puts "Downloading DDR data: $data_file -> $data_address"
    dow -data $data_file $data_address
}
puts "Starting program"
con

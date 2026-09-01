set script_dir [file dirname [file normalize [info script]]]
set sw_dir [file dirname $script_dir]
set root [file dirname [file dirname $sw_dir]]

set workspace [file normalize [file join $root build_vitis_2022_2]]
set platform_name conv_accel_kv260_platform
set hw_dir [file join $workspace $platform_name hw]
set bit_file [file join $hw_dir conv_accel_ps_dma_minimal.bit]
set psu_init_tcl [file join $hw_dir psu_init.tcl]
set elf [file join $workspace conv_accel_r18_c16_smoke manual_build conv_accel_r18_c8_smoke.elf]
set abi_version 1
set artifact_manifest ""
set check_only 0
set fast_run 0
set skip_bit 0
set data_file ""
set data_address 0x10000000
set bias_file ""
set bias_address 0x18000000
set weight_file ""
set weight_address 0x18810000

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-bit_file"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -bit_file"
        }
        set bit_file [file normalize [lindex $argv $i]]
    } elseif {$arg eq "-workspace"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -workspace"
        }
        set workspace [file normalize [lindex $argv $i]]
    } elseif {$arg eq "-platform_name"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -platform_name"
        }
        set platform_name [lindex $argv $i]
    } elseif {$arg eq "-abi_version"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -abi_version"
        }
        set abi_version [lindex $argv $i]
    } elseif {$arg eq "-artifact_manifest"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -artifact_manifest"
        }
        set artifact_manifest [file normalize [lindex $argv $i]]
    } elseif {$arg eq "-elf"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -elf"
        }
        set elf [file normalize [lindex $argv $i]]
    } elseif {$arg eq "-fast"} {
        set fast_run 1
    } elseif {$arg eq "-check_only"} {
        set check_only 1
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
    } elseif {$arg eq "-bias_file"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -bias_file"
        }
        set bias_file [file normalize [lindex $argv $i]]
    } elseif {$arg eq "-bias_address"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -bias_address"
        }
        set bias_address [lindex $argv $i]
    } elseif {$arg eq "-weight_file"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -weight_file"
        }
        set weight_file [file normalize [lindex $argv $i]]
    } elseif {$arg eq "-weight_address"} {
        incr i
        if {$i >= [llength $argv]} {
            error "Missing value for -weight_address"
        }
        set weight_address [lindex $argv $i]
    } else {
        error "Unknown argument: $arg"
    }
}

set hw_dir [file join $workspace $platform_name hw]
set psu_init_tcl [file join $hw_dir psu_init.tcl]

if {$abi_version ni {1 2}} {
    error "-abi_version must be 1 or 2"
}
if {$abi_version == 2} {
    if {[string first "abi_v2_candidate" [string tolower [file tail $workspace]]] < 0 ||
        $platform_name ne "conv_accel_abi_v2_candidate_platform" ||
        [file tail $elf] ne "conv_accel_abi_v2_candidate.elf"} {
        error "ABI v2 download requires the isolated candidate workspace/platform/ELF"
    }
    if {$artifact_manifest eq "" || ![file isfile $artifact_manifest]} {
        error "ABI v2 download requires -artifact_manifest"
    }
    if {$bias_file eq "" || ![file isfile $bias_file] ||
        $weight_file eq "" || ![file isfile $weight_file]} {
        error "ABI v2 download requires verified -bias_file and -weight_file packages"
    }
    if {[expr {$bias_address}] != 0x18000000 ||
        [expr {$weight_address}] != 0x18810000} {
        error "ABI v2 parameter packages require bias@0x18000000 and weight@0x18810000"
    }
    if {$fast_run || $skip_bit} {
        error "ABI v2 artifact binding requires programming the verified bitstream; -fast and -skip_bit are forbidden"
    }
    set python [auto_execok python]
    set verifier [file join $script_dir abi_v2_candidate_artifacts.py]
    if {$python eq "" || ![file isfile $verifier]} {
        error "ABI v2 candidate verifier is unavailable"
    }
    set verify_command [list $python $verifier verify \
        --manifest $artifact_manifest --phase run \
        --expect-workspace $workspace --expect-bit $bit_file \
        --expect-elf $elf --expect-bias $bias_file \
        --expect-weight $weight_file]
    if {[catch {exec {*}$verify_command} verify_output]} {
        error "ABI v2 candidate run verification failed: $verify_output"
    }
    puts $verify_output
} elseif {$artifact_manifest ne "" || $bias_file ne "" || $weight_file ne "" ||
          [string first "abi_v2" [string tolower $workspace]] >= 0 ||
          [string first "abi_v2" [string tolower [file tail $elf]]] >= 0} {
    error "ABI v1 download cannot consume ABI v2 candidate artifacts"
}

if {![file exists $elf]} {
    error "ELF not found: $elf. Run sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 first."
}
if {!$fast_run && !$skip_bit && ![file exists $bit_file]} {
    error "Bitstream not found: $bit_file. Build or select a valid hardware image first."
}
if {$check_only} {
    puts "PASS: ABI $abi_version download artifact selection verified"
    puts "Workspace: $workspace"
    puts "ELF: $elf"
    puts "Bitstream: $bit_file"
    if {$abi_version == 2} {
        puts "Bias package: $bias_file -> $bias_address"
        puts "Weight package: $weight_file -> $weight_address"
    }
    exit 0
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
if {$abi_version == 2} {
    puts "Downloading ABI v2 bias package: $bias_file -> $bias_address"
    dow -data $bias_file $bias_address
    puts "Downloading ABI v2 weight package: $weight_file -> $weight_address"
    dow -data $weight_file $weight_address
}
puts "Starting program"
con

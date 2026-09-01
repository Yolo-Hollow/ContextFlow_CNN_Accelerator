# Program r5, download resident CPU-baseline data, run, and capture result.

set mode ""
set workspace ""
set bit_file ""
set elf ""
set params ""
set input ""
set expected ""
set result_file ""
set worker_elf [list "" "" ""]
set timeout_seconds 1800
for {set i 0} {$i < [llength $argv]} {incr i} {
    set key [lindex $argv $i]
    if {$key eq "-mode"} { incr i; set mode [lindex $argv $i]
    } elseif {$key eq "-timeout_seconds"} { incr i; set timeout_seconds [lindex $argv $i]
    } elseif {$key in {-workspace -bit_file -elf -params -input -expected -result -worker1 -worker2 -worker3}} {
        incr i
        if {$i >= [llength $argv]} { error "$key requires a value" }
        set value [file normalize [lindex $argv $i]]
        if {$key eq "-workspace"} { set workspace $value
        } elseif {$key eq "-bit_file"} { set bit_file $value
        } elseif {$key eq "-elf"} { set elf $value
        } elseif {$key eq "-params"} { set params $value
        } elseif {$key eq "-input"} { set input $value
        } elseif {$key eq "-expected"} { set expected $value
        } elseif {$key eq "-result"} { set result_file $value
        } elseif {$key eq "-worker1"} { lset worker_elf 0 $value
        } elseif {$key eq "-worker2"} { lset worker_elf 1 $value
        } else { lset worker_elf 2 $value }
    } else { error "unknown argument: $key" }
}
if {$mode ni {scalar neon4}} { error "-mode must be scalar or neon4" }
foreach path [list $bit_file $elf $params $input $expected] {
    if {![file isfile $path]} { error "required file missing: $path" }
}
if {$result_file eq ""} { error "-result is required" }
if {$mode eq "neon4"} {
    foreach path $worker_elf { if {![file isfile $path]} { error "worker missing: $path" } }
}
set psu_init_tcl [file join $workspace coco80_r5_net_platform hw psu_init.tcl]
if {![file isfile $psu_init_tcl]} { error "psu_init.tcl missing: $psu_init_tcl" }

connect -url tcp:127.0.0.1:3121
set a53 [targets -filter {name =~ "Cortex-A53 #0"}]
if {[llength $a53] == 0} { error "Cortex-A53 #0 not found" }
targets -set -nocase -filter {name =~ "*PSU*"}
catch {stop}
rst -system
after 3000
source $psu_init_tcl
psu_init
puts "Programming signed r5 bitstream"
fpga -file $bit_file
psu_ps_pl_isolation_removal
psu_ps_pl_reset_config
psu_post_config

targets -set -nocase -filter {name =~ "Cortex-A53 #0"}
catch {stop}
rst -processor -clear-registers
after 1000
dow $elf
puts "Downloading resident KCO parameters (0x50000000)"
dow -data $params 0x50000000
puts "Downloading input tensor (0x51200000)"
dow -data $input 0x51200000
puts "Downloading expected raw heads (0x51300000)"
dow -data $expected 0x51300000
mwr 0x53F00000 0x00000000
mwr 0x53F00008 0x00000000

if {$mode eq "neon4"} {
    for {set worker 1} {$worker <= 3} {incr worker} {
        targets -set -nocase -filter "name =~ \"Cortex-A53 #$worker\""
        catch {stop}
        rst -processor -clear-registers
        dow [lindex $worker_elf [expr {$worker - 1}]]
    }
    targets -set -nocase -filter {name =~ "Cortex-A53 #0"}
    mwr 0x7D600000 0x00000000
    mwr 0x7D600008 0x00000000
    for {set worker 1} {$worker <= 3} {incr worker} {
        targets -set -nocase -filter "name =~ \"Cortex-A53 #$worker\""
        con
    }
}
targets -set -nocase -filter {name =~ "Cortex-A53 #0"}
puts "Starting $mode A53 baseline"
con
set deadline [expr {[clock milliseconds] + $timeout_seconds * 1000}]
set status 0
while {[clock milliseconds] < $deadline} {
    after 1000
    set status [mrd -value 0x53F00008]
    if {$status != 0 && $status != 1} { break }
}
if {$status == 0 || $status == 1} { error "$mode baseline timed out with status $status" }
catch {stop}
file mkdir [file dirname $result_file]
# mrd count is in 32-bit words; the result structure is 1216 bytes.
mrd -bin -file $result_file 0x53F00000 304
puts "BASELINE_STATUS=$status"
puts "BASELINE_RESULT=$result_file"
disconnect

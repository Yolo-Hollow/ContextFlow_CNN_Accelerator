connect -url tcp:127.0.0.1:3121
puts "=== JTAG targets ==="
set target_list ""
for {set attempt 0} {$attempt < 40} {incr attempt} {
    set target_list [targets]
    if {[string first "Cortex-A53 #0" $target_list] >= 0} {
        break
    }
    after 250
}
puts $target_list
puts "=== Raw JTAG chain ==="
puts [jtag targets]

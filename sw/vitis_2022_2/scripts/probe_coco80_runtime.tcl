# Read-only runtime snapshot for the persistent COCO80 four-core runner.
# Every core is resumed before the script exits.

connect -url tcp:127.0.0.1:3121
puts "=== COCO80 A53 runtime snapshot ==="
puts [targets]

for {set core 0} {$core < 4} {incr core} {
    targets -set -nocase -filter "name =~ \"Cortex-A53 #$core\""
    puts "--- Cortex-A53 #$core ---"
    if {[catch {stop} stop_message]} {
        puts "STOP_ERROR: $stop_message"
        continue
    }
    after 100
    foreach reg {pc sp r0 r1 r29 r30 cpsr} {
        if {[catch {rrd $reg} value]} {
            puts "$reg: ERROR $value"
        } else {
            puts "$reg: $value"
        }
    }
    catch {con}
}

targets -set -nocase -filter {name =~ "Cortex-A53 #0"}
if {![catch {stop} stop_message]} {
    puts "--- shared mailbox 0x7D600000 ---"
    if {[catch {mrd 0x7D600000 32} value]} {
        puts "MAILBOX_ERROR: $value"
    } else {
        puts $value
    }
    catch {con}
} else {
    puts "MAILBOX_STOP_ERROR: $stop_message"
}

puts "PASS: snapshot complete; runnable cores resumed"

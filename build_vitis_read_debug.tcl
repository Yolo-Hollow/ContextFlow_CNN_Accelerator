connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "Cortex-A53 #0"}
puts "TARGET"
targets
puts "DEBUG_STAGE_READ"
puts [mrd 0x0001c0c0 2]
puts "PC_READ"
puts [rrd pc]
puts [rrd sp]
exit

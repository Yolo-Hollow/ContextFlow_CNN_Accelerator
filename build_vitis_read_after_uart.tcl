connect -url TCP:127.0.0.1:3121
targets
puts "READ_WHILE_RUNNING"
targets -set -filter {name =~ "Cortex-A53 #0"}
catch {stop} stopmsg
puts "STOPMSG=$stopmsg"
puts [mrd 0x0001c0c0 2]
puts [rrd pc]
exit

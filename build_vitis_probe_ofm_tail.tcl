connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "Cortex-A53 #0"}
puts "OFM_AXIS_AROUND_96"
catch {puts [mrd -force 0x0001ddc0 64]} bmsg
puts "BMSG=$bmsg"
puts "OFM_MEM_AROUND_96"
catch {puts [mrd -force 0x0001d618 48]} mmsg
puts "MMSG=$mmsg"
exit

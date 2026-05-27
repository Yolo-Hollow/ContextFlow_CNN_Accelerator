connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "Cortex-A53 #0"}
puts "OFM_AXIS_BUF_64"
catch {puts [mrd -force 0x0001dac0 64]} bmsg
puts "BMSG=$bmsg"
puts "OFM_MEM"
catch {puts [mrd -force 0x0001d5b8 64]} mmsg
puts "MMSG=$mmsg"
puts "GOLDEN"
catch {puts [mrd -force 0x0001cde8 64]} gmsg
puts "GMSG=$gmsg"
exit

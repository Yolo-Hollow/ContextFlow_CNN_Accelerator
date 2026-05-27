connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "Cortex-A53 #0"}
puts "PC"; catch {puts [rrd pc]} pcmsg; puts "PCMSG=$pcmsg"
puts "ACCEL regs"; catch {puts [mrd 0xA0000000 10]} amsg; puts "AMSG=$amsg"
puts "GPIO regs"; catch {puts [mrd 0xA0010000 4]} gmsg; puts "GMSG=$gmsg"
puts "DMA OFM regs"; catch {puts [mrd 0xA0050030 12]} omsg; puts "OMSG=$omsg"
puts "DMA BIAS regs"; catch {puts [mrd 0xA0020000 12]} bmsg; puts "BMSG=$bmsg"
exit

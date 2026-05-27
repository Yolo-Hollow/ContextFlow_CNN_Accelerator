connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "Cortex-A53 #0"}
puts "PC"
catch {puts [rrd pc]} pcmsg
puts "PCMSG=$pcmsg"
puts "DEBUG"
catch {puts [mrd -force 0x0001c0c0 2]} dmsg
puts "DMSG=$dmsg"
puts "ACCEL"
catch {puts [mrd -force 0xA0000000 10]} amsg
puts "AMSG=$amsg"
puts "GPIO"
catch {puts [mrd -force 0xA0010000 4]} gmsg
puts "GMSG=$gmsg"
puts "DMA_WEIGHT"
catch {puts [mrd -force 0xA0030000 12]} wmsg
puts "WMSG=$wmsg"
puts "DMA_IFM"
catch {puts [mrd -force 0xA0040000 12]} imsg
puts "IMSG=$imsg"
puts "DMA_OFM"
catch {puts [mrd -force 0xA0050030 12]} omsg
puts "OMSG=$omsg"
exit

connect -url TCP:127.0.0.1:3121
puts "Targets before:"
puts [targets]
targets -set -filter {name =~ "Cortex-A53 #0"}
puts "Stopping A53..."
catch {stop} stopmsg
puts "STOPMSG=$stopmsg"
puts "Programming PL..."
targets -set -filter {name =~ "PL"}
fpga -file D:/MPSoC/accelerator_systolic/build_vitis_2022_2/conv_accel_kv260_platform/hw/conv_accel_ps_dma_minimal.bit
puts "Downloading ELF..."
targets -set -filter {name =~ "Cortex-A53 #0"}
dow D:/MPSoC/accelerator_systolic/build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_r18_c16_smoke.elf
con
puts "ELF running"
after 12000
catch {stop} stop2
puts "STOP2=$stop2"
puts "DEBUG_STAGE"
catch {puts [mrd 0x0001c0c0 2]} mrdmsg
puts "MRDMSG=$mrdmsg"
catch {puts [rrd pc]} pcmsg
puts "PCMSG=$pcmsg"
exit

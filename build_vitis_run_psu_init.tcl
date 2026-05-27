connect -url TCP:127.0.0.1:3121
puts "Targets before:"
puts [targets]

puts "Programming PL..."
targets -set -filter {name =~ "PL"}
fpga -file D:/MPSoC/accelerator_systolic/build_vitis_2022_2/conv_accel_kv260_platform/hw/conv_accel_ps_dma_minimal.bit

puts "Initializing PS..."
source D:/MPSoC/accelerator_systolic/build_vitis_2022_2/conv_accel_kv260_platform/hw/psu_init.tcl
targets -set -filter {name =~ "PSU"}
psu_init
psu_ps_pl_isolation_removal
psu_ps_pl_reset_config

puts "Resetting A53 #0..."
targets -set -filter {name =~ "Cortex-A53 #0"}
rst -processor
after 1000

puts "Downloading ELF..."
dow D:/MPSoC/accelerator_systolic/build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_r18_c16_smoke.elf
con
puts "ELF running"

after 15000
catch {stop} stopmsg
puts "STOPMSG=$stopmsg"
puts "DEBUG_STAGE"
catch {puts [mrd 0x0001c0c0 2]} mrdmsg
puts "MRDMSG=$mrdmsg"
catch {puts [rrd pc]} pcmsg
puts "PCMSG=$pcmsg"
exit

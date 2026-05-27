connect -url TCP:127.0.0.1:3121
puts "Programming PL..."
targets -set -filter {name =~ "PL"}
fpga -file D:/MPSoC/accelerator_systolic/build_vitis_2022_2/conv_accel_kv260_platform/hw/conv_accel_ps_dma_minimal.bit
puts "Downloading ELF..."
targets -set -filter {name =~ "Cortex-A53 #0"}
catch {stop}
dow D:/MPSoC/accelerator_systolic/build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_r18_c16_smoke.elf
con
puts "ELF running"
after 8000
exit

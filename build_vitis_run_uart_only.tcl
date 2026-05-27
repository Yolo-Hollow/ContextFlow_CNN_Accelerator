connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "PL"}
fpga -file D:/MPSoC/accelerator_systolic/build_vitis_2022_2/conv_accel_kv260_platform/hw/conv_accel_ps_dma_minimal.bit
targets -set -filter {name =~ "Cortex-A53 #0"}
catch {stop}
catch {rst -processor}
after 1000
dow D:/MPSoC/accelerator_systolic/build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_r18_c16_smoke.elf
con
puts "ELF running"
after 5000
exit

connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "Cortex-A53 #0"}
set term_port [jtagterminal -socket]
puts "JTAGTERM_PORT=$term_port"
set term_sock [socket localhost $term_port]
fconfigure $term_sock -blocking 0 -buffering none -translation binary
puts "Programming PL..."
targets -set -filter {name =~ "PL"}
fpga -file D:/MPSoC/accelerator_systolic/build_vitis_2022_2/conv_accel_kv260_platform/hw/conv_accel_ps_dma_minimal.bit
puts "Downloading ELF..."
targets -set -filter {name =~ "Cortex-A53 #0"}
catch {stop}
dow D:/MPSoC/accelerator_systolic/build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_r18_c16_smoke.elf
con
puts "ELF running"
set deadline [expr {[clock milliseconds] + 30000}]
while {[clock milliseconds] < $deadline} {
    after 100
    set data [read $term_sock]
    if {$data ne ""} {
        puts -nonewline $data
        flush stdout
    }
}
close $term_sock
catch {jtagterminal -stop}
exit

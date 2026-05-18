# Vivado xsim script for systolic_fifo testbench
set proj_dir "d:/MPSoC/accelerator_systolic"

set src_files [list "$proj_dir/systolic/systolic_fifo.v"]
set tb_file "$proj_dir/tb/tb_systolic_fifo.v"
set tb_top  "tb_systolic_fifo"

puts "=== xvlog: compiling design sources ==="
if {[catch {exec xvlog -sv -work work {*}$src_files} result]} { puts $result; exit 1 }
puts "=== xvlog: compiling testbench ==="
if {[catch {exec xvlog -sv -work work $tb_file} result]} { puts $result; exit 1 }
puts "=== xelab: elaborating ==="
if {[catch {exec xelab -debug typical -L work -snapshot fifo_tb_snap $tb_top} result]} { puts $result; exit 1 }
puts "=== xsim: running simulation ==="
if {[catch {exec xsim fifo_tb_snap --runall} result]} { puts $result }
puts $result
puts "=== Simulation complete ==="

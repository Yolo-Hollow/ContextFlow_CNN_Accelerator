# Vivado xsim script for systolic_array_32x32 testbench
set proj_dir "d:/MPSoC/accelerator_systolic"

set src_files [list \
    "$proj_dir/cal/cal_mul_int8_x2_dsp.v" \
    "$proj_dir/cal/cal_mul_int8_x2.v" \
    "$proj_dir/com/com_shift_reg.v" \
    "$proj_dir/systolic/systolic_pe.v" \
    "$proj_dir/systolic/systolic_array_32x32.v" \
]

set tb_file "$proj_dir/tb/tb_systolic_array.v"
set tb_top  "tb_systolic_array"

puts "=== xvlog: compiling design sources ==="
foreach f $src_files {
    puts "  $f"
    if {[catch {exec xvlog -sv -work work $f} result]} {
        puts $result
        exit 1
    }
}

puts "=== xvlog: compiling testbench ==="
puts "  $tb_file"
if {[catch {exec xvlog -sv -work work $tb_file} result]} {
    puts $result
    exit 1
}

puts "=== xelab: elaborating ==="
if {[catch {exec xelab -debug typical -L work -snapshot array_tb_snap $tb_top} result]} {
    puts $result
    exit 1
}

puts "=== xsim: running simulation ==="
if {[catch {exec xsim array_tb_snap --runall} result]} {
    puts $result
}
puts $result
puts "=== Simulation complete ==="

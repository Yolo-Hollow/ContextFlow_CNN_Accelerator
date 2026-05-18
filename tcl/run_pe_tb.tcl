# Vivado xsim simulation script for systolic_pe testbench
set proj_dir "d:/MPSoC/accelerator_systolic"

# Source files (order matters for some simulators)
set src_files [list \
    "$proj_dir/cal/cal_mul_int8_x2_dsp.v" \
    "$proj_dir/cal/cal_mul_int8_x2.v" \
    "$proj_dir/systolic/systolic_pe.v" \
]

set tb_file  "$proj_dir/tb/tb_systolic_pe.v"
set tb_top   "tb_systolic_pe"

# ---- Compile ----
puts "=== xvlog: compiling design sources ==="
foreach f $src_files {
    puts "  $f"
    set cmd [list xvlog -sv -work work $f]
    if {[catch {eval exec {*}$cmd} result]} {
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

# ---- Elaborate ----
puts "=== xelab: elaborating ==="
if {[catch {exec xelab -debug typical -L work -snapshot pe_tb_snap $tb_top} result]} {
    puts $result
    exit 1
}

# ---- Simulate ----
puts "=== xsim: running simulation ==="
if {[catch {exec xsim pe_tb_snap --runall} result]} {
    puts $result
}
puts $result
puts "=== Simulation complete ==="

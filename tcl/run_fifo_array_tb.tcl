set proj_dir "d:/MPSoC/accelerator_systolic"
set src_files [list \
    "$proj_dir/cal/cal_mul_int8_x2_dsp.v" \
    "$proj_dir/cal/cal_mul_int8_x2.v" \
    "$proj_dir/systolic/systolic_pe.v" \
    "$proj_dir/systolic/systolic_array_32x32.v" \
    "$proj_dir/systolic/systolic_fifo.v" \
]
set tb_file "$proj_dir/tb/tb_systolic_fifo_array.v"
set tb_top  "tb_systolic_fifo_array"

puts "=== compile ==="
if {[catch {exec xvlog -sv -work work {*}$src_files $tb_file} result]} { puts $result; exit 1 }
puts "=== elaborate ==="
if {[catch {exec xelab -debug typical -L work -snapshot fifo_arr_snap $tb_top} result]} { puts $result; exit 1 }
puts "=== simulate ==="
if {[catch {exec xsim fifo_arr_snap --runall} result]} { puts $result }
puts $result
puts "=== done ==="

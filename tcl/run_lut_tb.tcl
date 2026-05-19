set proj_dir "d:/MPSoC/accelerator_systolic"
set src "$proj_dir/systolic/leaky_lut.v"
set tb  "$proj_dir/tb/tb_leaky_lut.v"
puts "=== compile ==="
if {[catch {exec xvlog -sv -work work $src $tb} r]} { puts $r; exit 1 }
puts "=== elaborate ==="
if {[catch {exec xelab -debug typical -L work -snapshot lut_snap tb_leaky_lut} r]} { puts $r; exit 1 }
puts "=== simulate ==="
if {[catch {exec xsim lut_snap --runall} r]} { puts $r }
puts $r

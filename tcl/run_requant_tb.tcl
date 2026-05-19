set proj_dir "d:/MPSoC/accelerator_systolic"
set src "$proj_dir/systolic/requant.v"
set tb  "$proj_dir/tb/tb_requant.v"
puts "=== compile ==="
if {[catch {exec xvlog -sv -work work $src $tb} r]} { puts $r; exit 1 }
puts "=== elaborate ==="
if {[catch {exec xelab -debug typical -L work -snapshot req_snap tb_requant} r]} { puts $r; exit 1 }
puts "=== simulate ==="
if {[catch {exec xsim req_snap --runall} r]} { puts $r }
puts $r

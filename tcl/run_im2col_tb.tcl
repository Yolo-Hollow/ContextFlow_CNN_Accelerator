set p "d:/MPSoC/accelerator_systolic"
if {[catch {exec xvlog -sv -work work $p/systolic/im2col_addr_gen.v $p/tb/tb_im2col.v} r]} { puts $r; exit 1 }
if {[catch {exec xelab -debug typical -L work -snapshot im_snap tb_im2col} r]} { puts $r; exit 1 }
if {[catch {exec xsim im_snap --runall} r]} { puts $r }
puts $r

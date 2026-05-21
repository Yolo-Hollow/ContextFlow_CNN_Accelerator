set p "d:/MPSoC/accelerator_systolic"
if {[catch {exec xvlog -sv -work work $p/systolic/line_buffer_5bank.v $p/systolic/window_extract.v $p/tb/tb_linebuf.v} r]} { puts $r; exit 1 }
if {[catch {exec xelab -debug typical -L work -snapshot lb_snap tb_linebuf} r]} { puts $r; exit 1 }
if {[catch {exec xsim lb_snap --runall} r]} { puts $r }
puts $r

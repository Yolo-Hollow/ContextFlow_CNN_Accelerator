set p "d:/MPSoC/accelerator_systolic"
set src [list \
    $p/cal/cal_mul_int8_x2_dsp.v $p/cal/cal_mul_int8_x2.v $p/com/com_shift_reg.v \
    $p/systolic/systolic_pe.v $p/systolic/systolic_array_32x32.v $p/systolic/systolic_fifo.v \
    $p/systolic/systolic_ctrl.v $p/systolic/line_buffer_5bank.v $p/systolic/window_extract.v \
    $p/systolic/systolic_top.v]
if {[catch {exec xvlog -sv -work work {*}$src $p/tb/tb_top_dma.v} r]} { puts $r; exit 1 }
puts "=== compile OK ==="
if {[catch {exec xelab -debug typical -L work -snapshot dma_snap tb_top_dma} r]} { puts $r; exit 1 }
puts "=== elaborate OK ==="
if {[catch {exec xsim dma_snap --runall} r]} { puts $r }
puts $r

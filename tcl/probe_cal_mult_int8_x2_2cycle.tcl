set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
set out_dir [file join $root build_synth_xck26 dsp_2cycle_probe]
file mkdir $out_dir

create_project -in_memory -part xck26-sfvc784-2LV-c
read_verilog [file join $root cal cal_mul_int8_x2_2cycle.v]
synth_design -top cal_mult_int8_x2_2cycle -part xck26-sfvc784-2LV-c \
    -mode out_of_context -flatten_hierarchy rebuilt
create_clock -period 10.000 -name clk [get_ports clk]
opt_design
place_design
report_utilization -file [file join $out_dir utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $out_dir timing_summary.rpt]

set dsp_count [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
set ff_count [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set lut_count [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $paths] == 0} {
    error "2-cycle DSP probe has no timed path"
}
set wns [get_property SLACK [lindex $paths 0]]
puts "DSP_2CYCLE_PROBE dsp=$dsp_count ff=$ff_count lut=$lut_count wns=$wns"
if {$dsp_count != 1 || $ff_count > 100 || $lut_count > 24 || $wns < 1.0} {
    error "2-cycle DSP probe gate failed"
}

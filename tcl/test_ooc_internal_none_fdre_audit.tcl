# Focused Vivado counterexample for the production OOC internal
# (none)->FDRE/D audit.  Run with Vivado 2022.2 in batch mode.

set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
source [file join $script_dir build_common.tcl]
::conv_accel_build::require_vivado_version 2022.2

set build_dir [file join $root build_synth_xck26 \
    ooc_internal_none_fdre_fixture]
file mkdir $build_dir
set rtl_path [file join $build_dir fixture.v]
set xdc_path [file join $build_dir fixture.xdc]
set bad_report [file join $build_dir unclocked_rogue_audit.rpt]
set good_report [file join $build_dir clocked_rogue_audit.rpt]

set rtl_fh [open $rtl_path w]
puts $rtl_fh {
module ooc_internal_none_fdre_fixture (
    input  wire clk,
    input  wire rogue_clk,
    input  wire top_input,
    output wire observed
);
    (* DONT_TOUCH = "yes" *) reg rogue_q;
    (* DONT_TOUCH = "yes" *) reg sink_q;

    always @(posedge rogue_clk)
        rogue_q <= top_input;

    // sink_q/D has both a legal top-input (none) startpoint and the internal
    // rogue_q/Q (none) startpoint.  Filtering only after -nworst selection
    // could therefore hide rogue_q/Q behind top_input.
    always @(posedge clk)
        sink_q <= top_input ^ rogue_q;

    assign observed = sink_q;
endmodule
}
close $rtl_fh

set xdc_fh [open $xdc_path w]
puts $xdc_fh {create_clock -name clk -period 10.000 [get_ports {clk}]}
close $xdc_fh

read_verilog $rtl_path
read_xdc -mode out_of_context $xdc_path
synth_design -top ooc_internal_none_fdre_fixture \
    -part xck26-sfvc784-2LV-c -mode out_of_context
opt_design
place_design

set bad_metrics \
    [::conv_accel_build::write_ooc_internal_none_fdre_audit $bad_report 50]
if {[dict get $bad_metrics ooc_internal_none_fdre_endpoints] != 1} {
    error "unclocked internal rogue fixture returned $bad_metrics; expected exactly one endpoint"
}
set bad_text [::conv_accel_build::read_text $bad_report]
if {![regexp {top_port_startpoints_excluded=([1-9][0-9]*)} $bad_text] ||
    [string first {rogue_q_reg/} $bad_text] < 0 ||
    [string first {sink_q_reg/D} $bad_text] < 0} {
    error "counterexample report does not prove simultaneous top-port exclusion and internal rogue detection: $bad_text"
}

create_clock -name rogue_clk -period 12.000 [get_ports {rogue_clk}]
set good_metrics \
    [::conv_accel_build::write_ooc_internal_none_fdre_audit $good_report 50]
if {[dict get $good_metrics ooc_internal_none_fdre_endpoints] != 0} {
    error "clocked internal rogue fixture returned $good_metrics; expected zero endpoints"
}
if {[llength [::conv_accel_build::metric_violations $good_metrics \
        [dict create max_ooc_internal_none_fdre_endpoints 0]]] != 0} {
    error "clocked fixture failed the production zero limit"
}

puts "PASS: OOC internal (none)->FDRE/D audit detects the internal rogue beside a top input, then clears it when clocked"

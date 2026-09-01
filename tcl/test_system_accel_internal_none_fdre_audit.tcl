# Focused Vivado fixture for the production full-system accelerator
# internal-(none)->FDRE/D audit.  It proves that a clocked source outside the
# selected accelerator hierarchy is not converted into a false blank-clock
# startpoint, while a genuinely unclocked register inside the accelerator is
# still detected.  Run with Vivado 2022.2 in batch mode.

set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
source [file join $script_dir build_common.tcl]
::conv_accel_build::require_vivado_version 2022.2

set build_dir [file join $root build_synth_xck26 \
    system_accel_internal_none_fdre_fixture]
file mkdir $build_dir
set rtl_path [file join $build_dir fixture.v]
set xdc_path [file join $build_dir fixture.xdc]
set bad_report [file join $build_dir unclocked_rogue_audit.rpt]
set good_report [file join $build_dir clocked_rogue_audit.rpt]
set error_report [file join $build_dir missing_hierarchy_audit.rpt]
set legacy_scoped_report [file join $build_dir legacy_cells_summary.rpt]

set rtl_fh [open $rtl_path w]
puts $rtl_fh {
module system_accel_internal_none_core (
    input  wire clk,
    input  wire rogue_clk,
    input  wire boundary_input,
    output wire observed
);
    (* DONT_TOUCH = "yes" *) reg rogue_q;
    (* DONT_TOUCH = "yes" *) reg sink_q;

    always @(posedge rogue_clk)
        rogue_q <= boundary_input;

    always @(posedge clk)
        sink_q <= boundary_input ^ rogue_q;

    assign observed = sink_q;
endmodule

module system_accel_internal_none_shell (
    input  wire clk,
    input  wire rogue_clk,
    input  wire boundary_input,
    output wire observed
);
    (* KEEP_HIERARCHY = "yes" *)
    system_accel_internal_none_core inst (
        .clk(clk),
        .rogue_clk(rogue_clk),
        .boundary_input(boundary_input),
        .observed(observed)
    );
endmodule

module system_accel_internal_none_fixture (
    input  wire clk,
    input  wire rogue_clk,
    input  wire top_input,
    output wire observed
);
    // This clocked register intentionally lives above accel/inst.  A
    // report_timing_summary -cells accel/inst query cuts the path at the
    // hierarchy input and can relabel it (none); the production full-design
    // fan-in query must retain boundary_q_reg/Q and its clk relationship.
    (* DONT_TOUCH = "yes" *) reg boundary_q;
    always @(posedge clk)
        boundary_q <= top_input;

    (* KEEP_HIERARCHY = "yes" *)
    system_accel_internal_none_shell accel (
        .clk(clk),
        .rogue_clk(rogue_clk),
        .boundary_input(boundary_q),
        .observed(observed)
    );
endmodule
}
close $rtl_fh

set xdc_fh [open $xdc_path w]
puts $xdc_fh {create_clock -name clk -period 10.000 [get_ports {clk}]}
close $xdc_fh

read_verilog $rtl_path
read_xdc $xdc_path
synth_design -top system_accel_internal_none_fixture \
    -part xck26-sfvc784-2LV-c -flatten_hierarchy none
opt_design
place_design
write_checkpoint -force [file join $build_dir fixture_placed.dcp]

set bad_metrics \
    [::conv_accel_build::write_system_accel_internal_none_fdre_audit \
        $bad_report *accel/inst]
if {[dict get $bad_metrics accel_internal_none_fdre_endpoints] != 1} {
    error "unclocked internal rogue fixture returned $bad_metrics; expected exactly one endpoint"
}
set bad_text [::conv_accel_build::read_text $bad_report]
if {[string first {query_scope=full_design} $bad_text] < 0 ||
    [string first {endpoint_scope=accelerator_fdre_d} $bad_text] < 0 ||
    [string first {accel/inst/rogue_q_reg/} $bad_text] < 0 ||
    [string first {accel/inst/sink_q_reg/D} $bad_text] < 0} {
    error "counterexample report does not prove full-design rogue detection: $bad_text"
}

create_clock -name rogue_clk -period 12.000 [get_ports {rogue_clk}]
set good_metrics \
    [::conv_accel_build::write_system_accel_internal_none_fdre_audit \
        $good_report *accel/inst]
if {[dict get $good_metrics accel_internal_none_fdre_endpoints] != 0} {
    error "clocked internal rogue fixture returned $good_metrics; expected zero endpoints"
}
set parsed_good \
    [::conv_accel_build::parse_system_accel_internal_none_fdre_audit \
        [::conv_accel_build::read_text $good_report]]
if {[llength [::conv_accel_build::metric_violations $parsed_good \
        [dict create max_accel_internal_none_fdre_endpoints 0]]] != 0} {
    error "clocked hierarchy fixture failed the production zero limit"
}

# Preserve a direct regression proof for the discarded implementation: even
# with every internal register clocked, the hierarchy-scoped report can retain
# a synthetic (none) group at accel/inst's input boundary.
set accel_cells [get_cells -quiet -hier -filter {NAME =~ *accel/inst}]
if {[llength $accel_cells] != 1} {
    error "fixture did not preserve exactly one */accel/inst hierarchy"
}
report_timing_summary -report_unconstrained -max_paths 1 \
    -cells $accel_cells -file $legacy_scoped_report
set legacy_text [::conv_accel_build::read_text $legacy_scoped_report]
if {![regexp {Path Group:\s+\(none\)} $legacy_text]} {
    error "fixture did not reproduce the hierarchy-scoped synthetic (none) group"
}

if {![catch {
        ::conv_accel_build::write_system_accel_internal_none_fdre_audit \
            $error_report */missing/inst} missing_error] ||
    [string first {expected exactly one} $missing_error] < 0} {
    error "missing accelerator hierarchy did not fail closed: $missing_error"
}
set error_text [::conv_accel_build::read_text $error_report]
if {[string first {status=ERROR} $error_text] < 0 ||
    ![catch {
        ::conv_accel_build::parse_system_accel_internal_none_fdre_audit \
            $error_text}]} {
    error "failed hierarchy lookup did not leave an unparseable ERROR audit"
}

puts "PASS: full-design accelerator FDRE/D audit ignores a clocked parent boundary, detects a real internal rogue, and fails closed"

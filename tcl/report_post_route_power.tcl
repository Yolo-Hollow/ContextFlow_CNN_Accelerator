# Generate a reproducible vectorless post-route power estimate from a routed DCP.
#
# Usage:
#   vivado -mode batch -notrace -source tcl/report_post_route_power.tcl \
#     -tclargs <routed.dcp> <output_dir>
#
# The estimate deliberately fixes the vectorless assumptions. It is not a
# substitute for a SAIF-based estimate or board-level power measurement.

if {$argc != 2} {
    error "usage: report_post_route_power.tcl <routed.dcp> <output_dir>"
}

set dcp_path [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
if {![file isfile $dcp_path]} {
    error "routed DCP does not exist: $dcp_path"
}
file mkdir $output_dir

set report_path [file join $output_dir system_power_post_route.rpt]
set hierarchy_path [file join $output_dir system_power_post_route_hier.rpt]
set rpx_path [file join $output_dir system_power_post_route.rpx]
set assumptions_path [file join $output_dir system_power_assumptions.txt]
set route_report_path [file join $output_dir system_power_route_status.rpt]

open_checkpoint $dcp_path
report_route_status -file $route_report_path

# Reproducible vectorless assumptions. Clock activity remains constraint-driven;
# the defaults apply to otherwise unannotated data/control nodes. Reset nets are
# deasserted before propagation.
set operating_process typical
set ambient_temp_c 25
set default_toggle_rate_percent 12.5
set default_static_probability 0.5

set_operating_conditions \
    -process $operating_process \
    -ambient_temp $ambient_temp_c
set_switching_activity \
    -default_toggle_rate $default_toggle_rate_percent \
    -default_static_probability $default_static_probability
set_switching_activity -deassert_resets

report_power \
    -name lasa_post_route_power \
    -file $report_path \
    -rpx $rpx_path
report_power \
    -hierarchical_depth 4 \
    -file $hierarchy_path

set out [open $assumptions_path w]
puts $out "format=lasa-post-route-power-assumptions"
puts $out "version=1"
puts $out "vivado_version=[version -short]"
puts $out "dcp=$dcp_path"
puts $out "part=[get_property PART [current_design]]"
puts $out "route_status_report=$route_report_path"
puts $out "operating_grade=device_encoded_commercial"
puts $out "operating_process=$operating_process"
puts $out "ambient_temp_c=$ambient_temp_c"
puts $out "default_toggle_rate_percent=$default_toggle_rate_percent"
puts $out "default_static_probability=$default_static_probability"
puts $out "resets=deasserted"
puts $out "activity_source=vectorless"
puts $out "saif=none"
puts $out "measurement=post_route_estimated"
close $out

puts "POST_ROUTE_POWER_REPORT=$report_path"
puts "POST_ROUTE_POWER_HIER_REPORT=$hierarchy_path"
puts "POST_ROUTE_POWER_RPX=$rpx_path"
puts "POST_ROUTE_POWER_ASSUMPTIONS=$assumptions_path"
puts "POST_ROUTE_POWER_ROUTE_STATUS=$route_report_path"
close_design
exit

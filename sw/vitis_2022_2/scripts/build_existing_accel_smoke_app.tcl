set script_dir [file dirname [file normalize [info script]]]
set sw_dir [file dirname $script_dir]
set root [file dirname [file dirname $sw_dir]]

set workspace [file normalize [file join $root build_vitis_2022_2]]
set app_name conv_accel_r18_c16_smoke

setws $workspace
app build -name $app_name

puts "=== Vitis 2022.2 smoke-test app built ==="
puts "Workspace: $workspace"
puts "Application: $app_name"

set script_dir [file dirname [file normalize [info script]]]
set sw_dir [file dirname $script_dir]
set root [file dirname [file dirname $sw_dir]]

set workspace [file normalize [file join $root build_vitis_2022_2]]
set platform_name conv_accel_kv260_platform
set app_name conv_accel_r18_c16_smoke

setws $workspace

if {![file exists [file join $workspace $platform_name]]} {
    error "Platform project not found: [file join $workspace $platform_name]. Run create_accel_smoke_project.tcl first."
}

if {![file exists [file join $workspace $app_name]]} {
    error "Application project not found: [file join $workspace $app_name]. Run create_accel_smoke_project.tcl first."
}

importsources -name $app_name -path [file join $sw_dir src] -soft-link
app build -name $app_name

puts "=== Vitis 2022.2 smoke-test app imported and built ==="
puts "Workspace: $workspace"
puts "Application: $app_name"
puts "Source: [file join $sw_dir src]"

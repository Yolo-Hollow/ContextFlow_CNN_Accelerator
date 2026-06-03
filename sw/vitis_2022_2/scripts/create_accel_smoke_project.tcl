set script_dir [file dirname [file normalize [info script]]]
set sw_dir [file dirname $script_dir]
set root [file dirname [file dirname $sw_dir]]

set workspace [file normalize [file join $root build_vitis_2022_2]]
set xsa [file normalize [file join $root build_system_xck26_kv260 conv_accel_ps_dma_minimal.xsa]]
set platform_name conv_accel_kv260_platform
set app_name conv_accel_r18_c16_smoke
set proc_name psu_cortexa53_0
set domain_name standalone_domain

if {![file exists $xsa]} {
    error "XSA not found: $xsa. Rebuild hardware with tcl/build_kv260_system_xck26.tcl first."
}

setws $workspace

platform create -name $platform_name -hw $xsa -proc $proc_name -os standalone -arch 64-bit
platform active $platform_name
domain active $domain_name
platform generate

set app_dir [file join $workspace $app_name]
if {![file exists $app_dir]} {
    app create -name $app_name -platform $platform_name -domain $domain_name -template {Empty Application}
    importsources -name $app_name -path [file join $sw_dir src] -soft-link
} else {
    puts "Application already exists, reusing: $app_dir"
}
app build -name $app_name

puts "=== Vitis 2022.2 smoke-test project ready ==="
puts "Workspace: $workspace"
puts "Application: $app_name"
puts "Source: [file join $sw_dir src]"

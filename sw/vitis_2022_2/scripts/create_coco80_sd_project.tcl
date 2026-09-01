# Create a fresh A53 standalone platform with the xilffs library enabled.

set script_dir [file dirname [file normalize [info script]]]
set sw_dir [file dirname $script_dir]
set root [file dirname [file dirname $sw_dir]]
set workspace [file normalize [file join $root build_vitis_2022_2_coco80_r5]]
set xsa [file normalize [file join $root build_abi_v2_release_r5 conv_accel_ps_dma_minimal.xsa]]

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg in {-workspace -xsa}} {
        incr i
        if {$i >= [llength $argv]} { error "$arg requires a value" }
        set value [file normalize [lindex $argv $i]]
        if {$arg eq "-workspace"} { set workspace $value } else { set xsa $value }
    } else {
        error "unknown argument: $arg"
    }
}
if {![file isfile $xsa]} { error "XSA not found: $xsa" }
if {[file exists $workspace]} {
    error "COCO80 workspace must be fresh: $workspace"
}

set platform_name coco80_r5_platform
set domain_name standalone_domain
file mkdir $workspace
setws $workspace
platform create -name $platform_name -hw $xsa -proc psu_cortexa53_0 \
    -os standalone -arch 64-bit
platform active $platform_name
domain active $domain_name
bsp setlib -name xilffs
bsp config use_lfn 2
bsp regenerate
platform generate

set marker [open [file join $workspace .coco80_r5_workspace] w]
puts $marker "profile=coco80_r5_sd"
puts $marker "vitis_version=2022.2"
puts $marker "xsa=$xsa"
puts $marker "platform=$platform_name"
puts $marker "domain=$domain_name"
close $marker
puts "PASS: COCO80 r5 SD platform and xilffs BSP created"
puts "Workspace: $workspace"

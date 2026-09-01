# Create a fresh A53 standalone platform for the COCO80 r5 raw-lwIP runner.

set script_dir [file dirname [file normalize [info script]]]
set sw_dir [file dirname $script_dir]
set root [file dirname [file dirname $sw_dir]]
set workspace [file normalize [file join $root build_vitis_2022_2_coco80_r5_net]]
set xsa [file normalize [file join $root build_abi_v2_release_r5 conv_accel_ps_dma_minimal.xsa]]
set execution_level el3
set requested_ddr_shareability auto

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg in {-workspace -xsa -execution-level -ddr-shareability}} {
        incr i
        if {$i >= [llength $argv]} { error "$arg requires a value" }
        set value [lindex $argv $i]
        if {$arg eq "-workspace"} {
            set workspace [file normalize $value]
        } elseif {$arg eq "-xsa"} {
            set xsa [file normalize $value]
        } elseif {$arg eq "-execution-level"} {
            set execution_level $value
        } else {
            set requested_ddr_shareability $value
        }
    } else {
        error "unknown argument: $arg"
    }
}
if {$execution_level ni {el3 el1}} {
    error "-execution-level must be el3 or el1"
}
if {$requested_ddr_shareability ni {auto outer inner}} {
    error "-ddr-shareability must be auto, outer, or inner"
}
if {![file isfile $xsa]} { error "XSA not found: $xsa" }
if {[file exists $workspace]} { error "COCO80 network workspace must be fresh: $workspace" }

set platform_name coco80_r5_net_platform
set domain_name standalone_domain
file mkdir $workspace
setws $workspace
platform create -name $platform_name -hw $xsa -proc psu_cortexa53_0 \
    -os standalone -arch 64-bit
platform active $platform_name
domain active $domain_name
if {$execution_level eq "el1"} {
    # Vitis 2022.2 otherwise builds an EL3 standalone domain.  The SD
    # chain-loader enters the application at Non-Secure EL1.
    bsp config hypervisor_guest true
}
bsp setlib -name lwip211
bsp config api_mode RAW_API
bsp config no_sys_no_timers true
bsp config lwip_dhcp false
bsp config phy_link_speed CONFIG_LINKSPEED_AUTODETECT
bsp config temac_use_jumbo_frames false
bsp config n_tx_descriptors 256
bsp config n_rx_descriptors 256
bsp config mem_size 1048576
bsp config pbuf_pool_size 1024
bsp config pbuf_pool_bufsize 1700
bsp config memp_n_pbuf 1024
bsp config memp_n_tcp_pcb 8
bsp config memp_n_tcp_pcb_listen 2
bsp config memp_n_tcp_seg 1024
bsp config tcp_wnd 65535
bsp config tcp_snd_buf 65535
bsp config tcp_mss 1460
bsp config lwip_tcp_keepalive true
bsp regenerate

set ddr_shareability inner
if {$execution_level eq "el1"} {
    if {$requested_ddr_shareability eq "auto"} {
        set ddr_shareability outer
    } else {
        set ddr_shareability $requested_ddr_shareability
    }
} elseif {$requested_ddr_shareability eq "outer"} {
    error "EL3 standalone uses the generated Inner Shareable DDR table"
}
if {$execution_level eq "el1" && $ddr_shareability eq "inner"} {
    # The 2022.2 standalone BSP marks normal DDR Outer Shareable for
    # EL1_NONSECURE.  That setting is measurably slower on this four-A53
    # application.  All PL/GEM DMA paths are non-coherent and use explicit
    # cache maintenance, while CPU-shared buffers require the Inner
    # Shareable domain.  Patch only the generated EL1 descriptor and fail
    # closed if Xilinx changes the source template.
    set table [file join $workspace $platform_name psu_cortexa53_0 \
        $domain_name bsp psu_cortexa53_0 libsrc standalone_v8_0 src \
        translation_table.S]
    if {![file isfile $table]} { error "generated translation table missing: $table" }
    set stream [open $table r]
    fconfigure $stream -translation binary
    set text [read $stream]
    close $stream
    set outer "\t.set Memory,\t0x405 | (2 << 8) | (0x0)\t\t/* normal writeback write allocate outer shared read write */"
    set inner "\t.set Memory,\t0x405 | (3 << 8) | (0x0)\t\t/* normal writeback write allocate inner shared read write */"
    set first [string first $outer $text]
    if {$first < 0 || [string first $outer $text [expr {$first + 1}]] >= 0} {
        error "EL1 DDR shareability template changed; refusing to patch"
    }
    set text [string replace $text $first [expr {$first + [string length $outer] - 1}] $inner]
    set stream [open $table w]
    fconfigure $stream -translation binary
    puts -nonewline $stream $text
    close $stream
}
platform generate

set marker [open [file join $workspace .coco80_r5_net_workspace] w]
puts $marker "profile=coco80_r5_ethernet"
puts $marker "vitis_version=2022.2"
puts $marker "xsa=$xsa"
puts $marker "platform=$platform_name"
puts $marker "domain=$domain_name"
puts $marker "execution_level=$execution_level"
puts $marker "ddr_shareability=$ddr_shareability"
puts $marker "runtime_multicore_shareability=inner"
puts $marker "runtime_inference_shareability=inner"
puts $marker "runtime_multicore_granule_bytes=2097152"
puts $marker "ip=192.168.10.2"
puts $marker "port=5001"
puts $marker "chunk_records=128"
close $marker
puts "PASS: COCO80 r5 raw-lwIP platform created"
puts "Workspace: $workspace"

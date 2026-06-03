connect -url tcp:127.0.0.1:3121
targets -set -nocase -filter {name =~ "Cortex-A53 #0"}
catch {stop}
after 500

foreach addr {0xA0000000 0xA0010000 0xA0020000 0xA0030000 0xA0040000 0xA0050000} {
    puts "mrd $addr"
    if {[catch {mrd $addr 4} msg]} {
        puts "ERROR $addr: $msg"
    }
}

puts "=== Accelerator configuration registers ==="
foreach {name addr} {
    ctrl       0xA0000000
    fm_size    0xA0000004
    ofm_size   0xA0000008
    conv       0xA000000C
    k_total    0xA0000010
    cout_total 0xA0000014
    num_pixels 0xA0000018
    act_cfg    0xA000001C
    tile_rows  0xA0000020
    pixel_base 0xA0000024
} {
    puts "$name ($addr)"
    mrd $addr 1
}

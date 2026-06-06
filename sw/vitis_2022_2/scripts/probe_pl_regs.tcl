connect -url tcp:127.0.0.1:3121
targets -set -nocase -filter {name =~ "Cortex-A53 #0"}
catch {stop}
after 500
if {[catch {memmap -addr 0xA0000000 -size 0x01000000 -flags 3} msg]} {
    puts "WARNING: could not add PL MMIO memmap: $msg"
}

foreach addr {0xA0000000 0xA0010000 0xA0020000 0xA0030000 0xA0040000 0xA0050000} {
    puts "mrd $addr"
    if {[catch {mrd $addr 4} msg]} {
        puts "ERROR $addr: $msg"
    } else {
        puts $msg
    }
}

puts "=== OFM DMA S2MM registers ==="
foreach {name addr} {
    s2mm_dmacr  0xA0050030
    s2mm_dmasr  0xA0050034
    s2mm_da     0xA0050048
    s2mm_da_msb 0xA005004C
    s2mm_length 0xA0050058
} {
    puts "$name ($addr)"
    puts [mrd $addr 1]
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
    dbg_expect  0xA0000028
    dbg_core    0xA000002C
    dbg_axis    0xA0000030
    dbg_tlast   0xA0000034
    dbg_last    0xA0000038
    ifm_zp      0xA000003C
    pool_cfg    0xA0000040
    expected    0xA0000044
    quant_addr  0xA0000080
    quant_data  0xA0000084
    lut_addr    0xA0000088
    lut_data    0xA000008C
} {
    puts "$name ($addr)"
    puts [mrd $addr 1]
}

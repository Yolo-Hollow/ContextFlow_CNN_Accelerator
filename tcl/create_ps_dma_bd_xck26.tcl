# Build a minimal PS/DMA integration block design for the AXI-Stream
# convolution accelerator.  This script targets Vivado 2022.2 and validates
# the structural design.  An optional SOM-to-carrier board connection causes
# Vivado Board Flow to apply the KV260 carrier PS peripheral preset as well.

set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
set project_name conv_accel_ps_dma_minimal
set bd_name conv_accel_ps_dma
set build_dir [file join $root build_bd_xck26]
set part xck26-sfvc784-2LV-c
set rows 18
set cols 8
set k_tile 18
set cout_tile 16
set ifm_banks 2
set ifm_fifo_depth 1024
set ifm_fifo_aw 10
set psum_fifo_depth 1024
set psum_fifo_aw 10
set hwc_cache_aw 16
set hwc_cache_depth 43264
set hwc_cache_stripes 4
set hwc_cache_use_uram 1
set tail_cycles 1
set jobs 8
set board_part ""
set board_connection ""
set generate_targets 0

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-project_name"} {
        incr i
        set project_name [lindex $argv $i]
    } elseif {$arg eq "-bd_name"} {
        incr i
        set bd_name [lindex $argv $i]
    } elseif {$arg eq "-build_dir"} {
        incr i
        set build_dir [file normalize [lindex $argv $i]]
    } elseif {$arg eq "-part"} {
        incr i
        set part [lindex $argv $i]
    } elseif {$arg eq "-board_part"} {
        incr i
        set board_part [lindex $argv $i]
    } elseif {$arg eq "-board_connection"} {
        incr i
        set board_connection [lindex $argv $i]
    } elseif {$arg eq "-rows"} {
        incr i
        set rows [lindex $argv $i]
    } elseif {$arg eq "-cols"} {
        incr i
        set cols [lindex $argv $i]
    } elseif {$arg eq "-k_tile"} {
        incr i
        set k_tile [lindex $argv $i]
    } elseif {$arg eq "-cout_tile"} {
        incr i
        set cout_tile [lindex $argv $i]
    } elseif {$arg eq "-ifm_banks"} {
        incr i
        set ifm_banks [lindex $argv $i]
    } elseif {$arg eq "-ifm_fifo_depth"} {
        incr i
        set ifm_fifo_depth [lindex $argv $i]
    } elseif {$arg eq "-ifm_fifo_aw"} {
        incr i
        set ifm_fifo_aw [lindex $argv $i]
    } elseif {$arg eq "-psum_fifo_depth"} {
        incr i
        set psum_fifo_depth [lindex $argv $i]
    } elseif {$arg eq "-psum_fifo_aw"} {
        incr i
        set psum_fifo_aw [lindex $argv $i]
    } elseif {$arg eq "-hwc_cache_aw"} {
        incr i
        set hwc_cache_aw [lindex $argv $i]
    } elseif {$arg eq "-hwc_cache_depth"} {
        incr i
        set hwc_cache_depth [lindex $argv $i]
    } elseif {$arg eq "-hwc_cache_stripes"} {
        incr i
        set hwc_cache_stripes [lindex $argv $i]
    } elseif {$arg eq "-hwc_cache_use_uram"} {
        incr i
        set hwc_cache_use_uram [lindex $argv $i]
    } elseif {$arg eq "-tail_cycles"} {
        incr i
        set tail_cycles [lindex $argv $i]
    } elseif {$arg eq "-jobs"} {
        incr i
        set jobs [lindex $argv $i]
    } elseif {$arg eq "-generate_targets"} {
        set generate_targets 1
    } else {
        error "unknown argument: $arg"
    }
}

if {$cout_tile != (2 * $cols)} {
    error "COUT_TILE must be 2 * COLS for the current packed-int8 datapath"
}
if {$ifm_banks < 1 || $ifm_banks > 8} {
    error "IFM_BANKS must fit in the 64-bit IFM AXI-Stream beat"
}
if {(1 << $ifm_fifo_aw) != $ifm_fifo_depth} {
    error "IFM_FIFO_DEPTH must equal 2^IFM_FIFO_AW"
}
if {(1 << $psum_fifo_aw) != $psum_fifo_depth} {
    error "PSUM_FIFO_DEPTH must equal 2^PSUM_FIFO_AW"
}

set rtl_files {
    cal/cal_mul_int8_x2_dsp.v
    cal/cal_mul_int8_x2.v
    com/com_shift_reg.v
    systolic/systolic_pe.v
    systolic/systolic_array_32x32.v
    systolic/systolic_fifo.v
    systolic/systolic_ctrl.v
    systolic/line_stream_ctrl.v
    systolic/window_stream_ctrl.v
    systolic/line_buffer_5bank.v
    systolic/window_extract.v
    systolic/window_feeder.v
    systolic/systolic_top_feeder.v
    systolic/layer_scheduler_stream.v
    systolic/pass_timeline_monitor.v
    systolic/coltrace_monitor.v
    systolic/weight_tile_loader.v
    systolic/bias_weight_stream_loader.v
    systolic/axis_bias_weight_loader.v
    systolic/ifm_line_stream_loader.v
    systolic/axis_ifm_line_loader.v
    systolic/axis_ifm_vector_loader.v
    systolic/axis_hwc_tile_cache.v
    systolic/psum_pingpong_buffer.v
    systolic/psum_output_collector.v
    systolic/psum_stream_feeder.v
    systolic/psum_column_pingpong_buffer.v
    systolic/psum_column_stream_feeder.v
    systolic/psum_column_output_collector.v
    systolic/psum_drain_writer.v
    systolic/psum_packet_fifo.v
    systolic/ofm_requant_writer.v
    systolic/ofm_activation.v
    systolic/ofm_pooling.v
    systolic/ofm_writeback.v
    systolic/ofm_packet_fifo.v
    systolic/ofm_byte_stream_fifo.v
    systolic/axis_ofm_byte_writer.v
    systolic/conv_layer_top_stream.v
    systolic/layer_config_regs.v
    systolic/quant_param_regs.v
    systolic/axi_lite_cfg_bridge.v
    systolic/conv_accel_core.v
    systolic/conv_accel_core_axi_lite.v
    systolic/conv_accel_core_axi_lite_stream.v
    systolic/conv_accel_core_axi_lite_full_stream.v
    systolic/conv_accel_core_axi_lite_axis_stream.v
    systolic/requant.v
    systolic/leaky_lut.v
    systolic/systolic_top.v
}

proc abs_files {root rels} {
    set files {}
    foreach rel $rels {
        lappend files [file normalize [file join $root $rel]]
    }
    return $files
}

proc connect_clock {clk cells} {
    foreach pin $cells {
        connect_bd_net $clk [get_bd_pins $pin]
    }
}

proc connect_resetn {resetn cells} {
    foreach pin $cells {
        connect_bd_net $resetn [get_bd_pins $pin]
    }
}

file mkdir $build_dir
set project_dir [file join $build_dir $project_name]
create_project -force $project_name $project_dir -part $part
if {$board_part ne ""} {
    set_property board_part $board_part [current_project]
}
if {$board_connection ne ""} {
    if {$board_part eq ""} {
        error "-board_connection requires -board_part"
    }
    # Attaching the carrier connector exposes its PS peripheral preset,
    # including the KV260 debug UART, to board automation.
    set_property board_connections $board_connection [current_project]
}
set_property target_language Verilog [current_project]
set rtl_abs_files [abs_files $root $rtl_files]
add_files -norecurse $rtl_abs_files
# Existing RTL uses unpacked array ports and is compiled as SystemVerilog in
# the standalone synthesis and simulation flows.
set_property file_type SystemVerilog [get_files $rtl_abs_files]
set accel_top conv_accel_core_axi_lite_axis_stream
set_property top $accel_top [current_fileset]
update_compile_order -fileset sources_1

# Vivado 2022.2 module references cannot use a SystemVerilog top source.  The
# accelerator's external pins are flat AXI interfaces, so package the verified
# SystemVerilog hierarchy as a local IP for use inside IP Integrator.
set accel_ip_repo [file join $build_dir ip_repo]
set accel_ip_dir [file join $accel_ip_repo $accel_top]
ipx::package_project -root_dir $accel_ip_dir -vendor user.org -library user \
    -taxonomy /UserIP -import_files
set accel_core [ipx::current_core]
set_property name $accel_top $accel_core
set_property display_name "18x16 AXI Stream Convolution Accelerator" $accel_core
set_property description "AXI-Lite controlled int8 systolic convolution accelerator" $accel_core
ipx::infer_bus_interfaces xilinx.com:interface:aximm_rtl:1.0 $accel_core
ipx::infer_bus_interfaces xilinx.com:interface:axis_rtl:1.0 $accel_core
ipx::save_core $accel_core
set_property ip_repo_paths $accel_ip_repo [current_project]
update_ip_catalog -rebuild

create_bd_design $bd_name

# Processor and infrastructure.
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* ps
if {$board_part ne ""} {
    apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
        -config {apply_board_preset "1" make_external "FIXED_IO, DDR"} \
        [get_bd_cells ps]
} else {
    puts "WARNING: no -board_part supplied; the PS/DMA structure is valid for review,"
    puts "         but apply the K26 SOM and KV260 carrier presets before bitstream generation."
}
set_property -dict [list \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__USE__S_AXI_GP0 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__USE__IRQ0 {1} \
] [get_bd_cells ps]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rst_pl
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:* reset_inv
set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] [get_bd_cells reset_inv]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* ctrl_sc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {6}] [get_bd_cells ctrl_sc]
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* mem_sc
set_property -dict [list CONFIG.NUM_SI {4} CONFIG.NUM_MI {1}] [get_bd_cells mem_sc]

# The existing verified RTL is packaged as a local IP, with the XCK26 resource
# point that passed implementation at 100 MHz.
create_bd_cell -type ip -vlnv user.org:user:conv_accel_core_axi_lite_axis_stream:1.0 accel
set_property -dict [list \
    CONFIG.ROWS $rows \
    CONFIG.COLS $cols \
    CONFIG.K_TILE $k_tile \
    CONFIG.COUT_TILE $cout_tile \
    CONFIG.IFM_BANKS $ifm_banks \
    CONFIG.IFM_FIFO_DEPTH $ifm_fifo_depth \
    CONFIG.IFM_FIFO_AW $ifm_fifo_aw \
    CONFIG.PSUM_FIFO_DEPTH $psum_fifo_depth \
    CONFIG.PSUM_FIFO_AW $psum_fifo_aw \
    CONFIG.HWC_CACHE_AW $hwc_cache_aw \
    CONFIG.HWC_CACHE_DEPTH $hwc_cache_depth \
    CONFIG.HWC_CACHE_STRIPES $hwc_cache_stripes \
    CONFIG.HWC_CACHE_USE_URAM $hwc_cache_use_uram \
    CONFIG.TAIL_CYCLES_CONFIG $tail_cycles \
] [get_bd_cells accel]

# Three DDR-to-stream channels supply layer inputs; one stream-to-DDR channel
# captures the initial byte/address-form OFM debug stream.
foreach name {dma_bias dma_weight dma_ifm} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:* $name
    set_property -dict [list \
        CONFIG.c_include_sg {0} \
        CONFIG.c_sg_length_width {26} \
        CONFIG.c_include_mm2s {1} \
        CONFIG.c_include_s2mm {0} \
        CONFIG.c_m_axi_mm2s_data_width {64} \
        CONFIG.c_m_axis_mm2s_tdata_width {64} \
    ] [get_bd_cells $name]
}
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:* dma_ofm
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_include_mm2s {0} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {64} \
] [get_bd_cells dma_ofm]

# A dual-channel GPIO supplies the current IFM line word count and exposes
# service/error flags plus the requested IFM row to the first bare-metal
# polling program.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:* accel_gpio
set_property -dict [list \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {9} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_GPIO2_WIDTH {16} \
    CONFIG.C_ALL_INPUTS_2 {1} \
] [get_bd_cells accel_gpio]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:* status_concat
set_property -dict [list CONFIG.NUM_PORTS {8} CONFIG.IN7_WIDTH {9}] [get_bd_cells status_concat]

# DMA interrupts may be consumed by software after the polling smoke test.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:* irq_concat
set_property -dict [list CONFIG.NUM_PORTS {4}] [get_bd_cells irq_concat]

# AXI-Lite control path from the PS.
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins ctrl_sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M00_AXI] [get_bd_intf_pins accel/s_axi]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M01_AXI] [get_bd_intf_pins dma_bias/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M02_AXI] [get_bd_intf_pins dma_weight/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M03_AXI] [get_bd_intf_pins dma_ifm/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M04_AXI] [get_bd_intf_pins dma_ofm/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M05_AXI] [get_bd_intf_pins accel_gpio/S_AXI]

# Shared DDR-facing memory traffic through one non-coherent PS high-performance
# port.  The DMA buffers do not need cache-coherent transactions.
connect_bd_intf_net [get_bd_intf_pins dma_bias/M_AXI_MM2S] [get_bd_intf_pins mem_sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins dma_weight/M_AXI_MM2S] [get_bd_intf_pins mem_sc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins dma_ifm/M_AXI_MM2S] [get_bd_intf_pins mem_sc/S02_AXI]
connect_bd_intf_net [get_bd_intf_pins dma_ofm/M_AXI_S2MM] [get_bd_intf_pins mem_sc/S03_AXI]
connect_bd_intf_net [get_bd_intf_pins mem_sc/M00_AXI] [get_bd_intf_pins ps/S_AXI_HP0_FPD]

# AXI-Stream layer movement.
connect_bd_intf_net [get_bd_intf_pins dma_bias/M_AXIS_MM2S] [get_bd_intf_pins accel/bias_s_axis]
connect_bd_intf_net [get_bd_intf_pins dma_weight/M_AXIS_MM2S] [get_bd_intf_pins accel/weight_s_axis]
connect_bd_intf_net [get_bd_intf_pins dma_ifm/M_AXIS_MM2S] [get_bd_intf_pins accel/ifm_s_axis]
connect_bd_intf_net [get_bd_intf_pins accel/ofm_m_axis] [get_bd_intf_pins dma_ofm/S_AXIS_S2MM]

# Single 100 MHz PL clock domain and reset.
set pl_clk [get_bd_pins ps/pl_clk0]
set periph_resetn [get_bd_pins rst_pl/peripheral_aresetn]
connect_bd_net $pl_clk [get_bd_pins rst_pl/slowest_sync_clk]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins reset_inv/Op1]
connect_bd_net [get_bd_pins reset_inv/Res] [get_bd_pins rst_pl/ext_reset_in]
connect_clock $pl_clk {
    ps/maxihpm0_fpd_aclk
    ps/saxihp0_fpd_aclk
    ctrl_sc/aclk
    mem_sc/aclk
    accel/clk
    accel_gpio/s_axi_aclk
    dma_bias/s_axi_lite_aclk
    dma_bias/m_axi_mm2s_aclk
    dma_weight/s_axi_lite_aclk
    dma_weight/m_axi_mm2s_aclk
    dma_ifm/s_axi_lite_aclk
    dma_ifm/m_axi_mm2s_aclk
    dma_ofm/s_axi_lite_aclk
    dma_ofm/m_axi_s2mm_aclk
}
connect_resetn $periph_resetn {
    ctrl_sc/aresetn
    mem_sc/aresetn
    accel_gpio/s_axi_aresetn
    dma_bias/axi_resetn
    dma_weight/axi_resetn
    dma_ifm/axi_resetn
    dma_ofm/axi_resetn
}
connect_bd_net [get_bd_pins rst_pl/peripheral_reset] [get_bd_pins accel/rst]

# GPIO channel 1 is software-written fm_w/line_words.  GPIO channel 2 bit map:
# [0]=bias request, [1]=weight request, [2]=IFM line request,
# [3]=OFM FIFO full, [4]=bias error, [5]=weight error, [6]=IFM error,
# [15:7]=requested IFM fy for the line-fill DMA service.
connect_bd_net [get_bd_pins accel_gpio/gpio_io_o] [get_bd_pins accel/ifm_line_words]
connect_bd_net [get_bd_pins accel/bias_load_req] [get_bd_pins status_concat/In0]
connect_bd_net [get_bd_pins accel/weight_load_req] [get_bd_pins status_concat/In1]
connect_bd_net [get_bd_pins accel/feeder_fill_req] [get_bd_pins status_concat/In2]
connect_bd_net [get_bd_pins accel/ofm_packet_full] [get_bd_pins status_concat/In3]
connect_bd_net [get_bd_pins accel/bias_axis_error] [get_bd_pins status_concat/In4]
connect_bd_net [get_bd_pins accel/weight_axis_error] [get_bd_pins status_concat/In5]
connect_bd_net [get_bd_pins accel/ifm_axis_error] [get_bd_pins status_concat/In6]
connect_bd_net [get_bd_pins accel/feeder_fill_fy] [get_bd_pins status_concat/In7]
connect_bd_net [get_bd_pins status_concat/dout] [get_bd_pins accel_gpio/gpio2_io_i]

connect_bd_net [get_bd_pins dma_bias/mm2s_introut] [get_bd_pins irq_concat/In0]
connect_bd_net [get_bd_pins dma_weight/mm2s_introut] [get_bd_pins irq_concat/In1]
connect_bd_net [get_bd_pins dma_ifm/mm2s_introut] [get_bd_pins irq_concat/In2]
connect_bd_net [get_bd_pins dma_ofm/s2mm_introut] [get_bd_pins irq_concat/In3]
connect_bd_net [get_bd_pins irq_concat/dout] [get_bd_pins ps/pl_ps_irq0]

# Keep DMA address spaces focused on DDR.  The generic assign_bd_address flow
# also considers PS OCM register segments and emits exclusions that do not
# belong to this DDR-based smoke-test path.
assign_bd_address -offset 0x00000000 -range 2G \
    -target_address_space [get_bd_addr_spaces dma_bias/Data_MM2S] \
    [get_bd_addr_segs ps/SAXIGP2/HP0_DDR_LOW]
assign_bd_address -offset 0x00000000 -range 2G \
    -target_address_space [get_bd_addr_spaces dma_weight/Data_MM2S] \
    [get_bd_addr_segs ps/SAXIGP2/HP0_DDR_LOW]
assign_bd_address -offset 0x00000000 -range 2G \
    -target_address_space [get_bd_addr_spaces dma_ifm/Data_MM2S] \
    [get_bd_addr_segs ps/SAXIGP2/HP0_DDR_LOW]
assign_bd_address -offset 0x00000000 -range 2G \
    -target_address_space [get_bd_addr_spaces dma_ofm/Data_S2MM] \
    [get_bd_addr_segs ps/SAXIGP2/HP0_DDR_LOW]

assign_bd_address -offset 0xA0000000 -range 4K \
    -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs accel/s_axi/reg0]
assign_bd_address -offset 0xA0010000 -range 64K \
    -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs accel_gpio/S_AXI/Reg]
assign_bd_address -offset 0xA0020000 -range 64K \
    -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs dma_bias/S_AXI_LITE/Reg]
assign_bd_address -offset 0xA0030000 -range 64K \
    -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs dma_weight/S_AXI_LITE/Reg]
assign_bd_address -offset 0xA0040000 -range 64K \
    -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs dma_ifm/S_AXI_LITE/Reg]
assign_bd_address -offset 0xA0050000 -range 64K \
    -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs dma_ofm/S_AXI_LITE/Reg]
validate_bd_design
save_bd_design

if {$generate_targets} {
    set bd_file [get_files "${bd_name}.bd"]
    generate_target all $bd_file
    make_wrapper -files $bd_file -top
    add_files -norecurse [file join $project_dir "${project_name}.gen" sources_1 bd $bd_name hdl "${bd_name}_wrapper.v"]
    update_compile_order -fileset sources_1
}

puts "=== Block Design validation complete ==="
puts "Project: [file join $project_dir ${project_name}.xpr]"
puts "BD: [get_files ${bd_name}.bd]"
puts "Accelerator: ROWS=$rows COLS=$cols K_TILE=$k_tile COUT_TILE=$cout_tile IFM_BANKS=$ifm_banks IFM_FIFO_DEPTH=$ifm_fifo_depth IFM_FIFO_AW=$ifm_fifo_aw PSUM_FIFO_DEPTH=$psum_fifo_depth PSUM_FIFO_AW=$psum_fifo_aw"
puts "Clock: PS pl_clk0 at 100 MHz"
puts "For KV260 use -board_part xilinx.com:kv260_som:part0:1.4 with"
puts "  -board_connection {som240_1_connector xilinx.com:kv260_carrier:som240_1_connector:1.3}"
puts "to apply the SOM DDR and carrier PS peripheral presets."

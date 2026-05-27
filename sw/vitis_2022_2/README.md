# Vitis 2022.2 r18_c16 smoke test

This bare-metal test mirrors `tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_smoke.v`.

Test shape:

- `ROWS=18`, `COLS=16`, `IFM_BANKS=2`
- `FM=5x5`, `OFM=5x5`
- `Cin=16`, `Cout=20`
- `3x3`, `pad=1`, `stride=1`
- one spatial tile: `tile_oy_base=0`, `tile_ofm_h=2`, `tile_pixel_base=0`

The software generates the same feature, weight, bias, and golden tensors as the RTL
testbench, services the accelerator requests through four AXI DMA channels, parses
the debug OFM stream `{addr[23:0], data[7:0]}`, and compares 200 output bytes.

By default the software uses the already-generated XSA-compatible path:
`USE_GPIO_FILL_FY=0`. In this mode it hardcodes the r18_c16 smoke line request
sequence as `0, 1, 2` for each K pass, so no new XSA is required.

The repository Tcl has also been updated to expose `feeder_fill_fy` in GPIO2
bits `[15:7]`. After rebuilding the XSA, set `USE_GPIO_FILL_FY=1` in
`src/accel_smoke.h` or add it as a compiler define to use the more general path.

From a Vitis 2022.2 command shell:

```powershell
xsct sw/vitis_2022_2/scripts/create_accel_smoke_project.tcl
```

The generated workspace is `build_vitis_2022_2`.

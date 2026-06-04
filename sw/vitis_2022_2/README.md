# Vitis 2022.2 r18_c8 smoke test

This bare-metal test mirrors the current `ROWS=18, COLS=8, IFM_BANKS=2`
KV260 smoke-test profile.
It is an early deterministic smoke test, not the current real-layer runtime.

Test shape:

- `ROWS=18`, `COLS=8`, `IFM_BANKS=2`
- `FM=5x5`, `OFM=5x5`
- `Cin=16`, `Cout=16`
- `3x3`, `pad=1`, `stride=1`
- one spatial tile: `tile_oy_base=0`, `tile_ofm_h=2`, `tile_pixel_base=0`

The software generates the same feature, weight, bias, and golden tensors as the RTL
testbench, services the accelerator requests through four AXI DMA channels, parses
the debug OFM stream `{addr[23:0], data[7:0]}`, and compares 160 output bytes.

The carrier-based hardware export exposes `feeder_fill_fy` in GPIO2 bits
`[15:7]`; the software defaults to `USE_GPIO_FILL_FY=1` and uses that value
when serving IFM line requests.

Current accelerator AXI-Lite configuration also includes indirect quant/LUT
programming registers inside the accelerator address window:

```text
0x80 QUANT_ADDR  [5:0] = quant lane address
0x84 QUANT_DATA  [15:0] mult, [19:16] raw shift, [31:24] output zp
0x88 LUT_ADDR    [7:0] = activation LUT address
0x8c LUT_DATA    [7:0] = activation LUT byte
```

The accelerator also expects software to write `0x44 EXPECTED_BYTES` before
starting a tile; hardware uses this value for OFM stream TLAST/debug counting.

Future real-layer Vitis smoke tests should program these registers before
starting a layer instead of relying on the old top-level quant/LUT pins.

From a Vitis 2022.2 command shell:

```powershell
xsct sw/vitis_2022_2/scripts/create_accel_smoke_project.tcl
```

The generated workspace is `build_vitis_2022_2`.

If the Vitis 2022.2 Eclipse backend stalls while importing or building the app,
the workspace can still be recovered by copying `src/main.c` and
`src/accel_smoke.h` into the generated app `src` directory and using the
generated BSP directly:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1
```

The default manual output path is:

```text
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_r18_c8_smoke.elf
```

The same source can build a small real-data Conv0 crop + pool smoke:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_crop_pool
```

The Conv0 mode embeds the fixture from:

```text
D:/MPSoC/python_prj/rtl_golden/facemask_conv0_crop16x8_pool/xsim_mem
```

and writes real quant/LUT parameters through the accelerator AXI-Lite window.
It is scheduled for the current BD default accelerator configuration:

```text
ROWS=18, COLS=8, IFM_BANKS=2, COUT_TILE=16
```

Its output path is:

```text
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv0_crop_pool_smoke.elf
```

This script uses the carrier-based hardware export:

```text
build_system_xck26_kv260/conv_accel_ps_dma_minimal.xsa
```

That XSA is expected to include the KV260 carrier board preset and the GPIO2
exposure of `feeder_fill_fy`.

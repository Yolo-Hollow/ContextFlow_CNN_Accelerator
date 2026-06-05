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

It can also build a two-spatial-tile Conv0 crop + pool smoke. This mode splits
the same `16x8` conv output into two `tile_ofm_h=4` runs and checks the
reassembled pooled `8x4x16` output against the same embedded golden:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_crop_pool_tiles
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

The tiled mode writes:

```text
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv0_crop_pool_tiles_smoke.elf
```

This script uses the carrier-based hardware export:

```text
build_system_xck26_kv260/conv_accel_ps_dma_minimal.xsa
```

That XSA is expected to include the KV260 carrier board preset and the GPIO2
exposure of `feeder_fill_fy`.

## Software scheduler skeleton

The smoke source now has a small layer descriptor layer:

```text
src/accel_layer_desc.h
src/accel_single_scale_plan.h
src/accel_single_scale_scheduler.h
```

`accel_layer_desc_t` is the per-run descriptor used by the current single-layer
smoke path. It holds shape, tile, pool, quant, LUT, expected byte count, and
golden pointers. `accel_single_scale_plan.h` records the 10-layer single-scale
YOLOv3-tiny plan for the current `ROWS=18, COLS=8, COUT_TILE=16` profile. The
current smoke still runs one descriptor at a time.

At startup the ELF runs a scheduler dry-run over the 10-layer table before it
touches DMA or accelerator registers. The dry-run checks layer chaining, output
shape, COUT blocks, K passes, expected OFM byte counts, and ping-pong feature
buffer assignment. It prints a compact per-layer plan such as `ext->fb0`,
`fb0->fb1`, plus the required external input bytes, feature buffer sizes, and
maximum OFM debug AXIS capture size.

## Board smoke sequence

When the KV260 USB/JTAG/UART link is available, run the real Conv0 crop + pool
smoke and register probe from one script:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8
```

To append the deterministic r18_c8 control-path smoke after Conv0:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -RunDeterministic
```

To run the two-spatial-tile Conv0 smoke instead of the single-tile Conv0 smoke:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -RunConv0Tiles
```

The script starts `hw_server` if needed, probes JTAG, captures serial logs,
downloads the bitstream and ELF, then runs `probe_pl_regs.tcl`. Logs are saved
under:

```text
build_system_xck26_kv260/board_smoke_logs/
```

For fast software-only iteration after the bitstream has already been
programmed and the board has not been power-cycled, use `-FastRun`. This keeps
the current PS/PL initialization and only resets the A53 before downloading the
ELF:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -FastRun
```

If the board was power-cycled, the PL indicator suggests no programmed logic, or
DMA reset stalls at the first MMIO access, rerun the full sequence without
`-FastRun` or `-SkipBit` so the bitstream is programmed again.

The deterministic smoke is kept as a control/DMA/GPIO diagnostic. Core
correctness should be judged first from the real Conv0 crop + pool fixture,
which uses external RTL semantic golden data.

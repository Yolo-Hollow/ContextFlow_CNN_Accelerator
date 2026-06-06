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

To build the first YOLOv3-tiny real-layer board smoke, use the Layer06 tile4
mode:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode layer06_tile4
```

This mode targets the current KV260 `ROWS=18, COLS=8, COUT_TILE=16`
bitstream and verifies the first `tile_ofm_h=4` slice of the real
`52x52x64 -> 52x52x128` Layer06 fixture. It exercises `K_PASSES=32` and
`COUT_BLOCKS=8`, so the software services bias and weight requests using the
inferred `cout_base` for each COUT block. The large IFM/weight/golden arrays
are generated into the Vitis app source directory at manual-build time from:

```text
D:/MPSoC/python_prj/rtl_golden/facemask_layer06_rtl
```

The generated ELF is:

```text
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_layer06_tile4_smoke.elf
```

The full Layer06 spatial-tiles mode reuses the same generated data header and
runs 13 `tile_ofm_h=4` spatial tiles to check the complete `52x52x128` output:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode layer06_tiles
```

The generated ELF is:

```text
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_layer06_tiles_smoke.elf
```

The same Layer06 fixture can also run as the real single-scale `conv3_pool`
stage. In this mode hardware performs:

```text
52x52x64 -> Conv/LUT 52x52x128 -> 2x2/s2 maxpool 26x26x128
```

Build it with:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode layer06_pool_tiles
```

The generated ELF is:

```text
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_layer06_pool_tiles_smoke.elf
```

The next 3x3 stage can be tested as `conv4_pool` without changing RTL:

```text
26x26x128 -> Conv/LUT 26x26x256 -> 2x2/s2 maxpool 13x13x256
```

Build it with:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv4_pool_tiles
```

The generated ELF is:

```text
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv4_pool_tiles_smoke.elf
```

To build the first chained two-layer smoke:

```text
conv3_pool hardware OFM buffer -> conv4_pool hardware IFM stream
```

use:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv3_conv4_chain
```

This mode compares `conv3_pool` against the Layer06 pooled RTL golden, then
uses the actual hardware-produced `26x26x128` buffer as the IFM for
`conv4_pool`. Its `conv4_pool` expected output is generated from that RTL
semantic intermediate buffer, not from the PyTorch `layer07_pooling` bytes.

The generated ELF is:

```text
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv3_conv4_chain_smoke.elf
```

Additional chain modes extend the same runtime through Conv8:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv4_conv5_chain
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv4_chain
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv5_chain
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv6_chain
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv7_chain
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv8_chain
```

The Conv0-to-Conv8 mode executes nine consecutive hardware layers and compares
every layer against a chain-specific RTL semantic golden. Conv5 and Conv6 must
be generated from the preceding output of the same chain; standalone golden
inputs are not interchangeable because earlier RTL-semantic differences
propagate. Conv6 runs `13x13x512 -> 13x13x1024` with `K_TOTAL=4608`,
`K_PASSES=256`, and `COUT_BLOCKS=64`. Conv7 keeps its native 1x1 golden
semantics but runs on hardware as center-only sparse 3x3 with `K_TOTAL=9216`,
`K_PASSES=512`, and `COUT_BLOCKS=16`.
Conv8 is a native 3x3 `13x13x256 -> 13x13x512` layer with
`K_TOTAL=2304`, `K_PASSES=128`, and `COUT_BLOCKS=32`.

The current board-validated hardware export is:

```text
build_system_xck26_kv260_linebuffix/conv_accel_ps_dma_minimal.xsa
```

It includes the FIFO1024/K14 changes and the stale IFM line-buffer row fix.
`run_kv260_smoke_sequence.ps1 -BuildDirName <directory>` selects a specific
hardware build without overwriting an older validated bitstream.

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

To run the Layer06 tile4 smoke:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -RunLayer06Tile4 -CaptureSeconds 300
```

To run the complete Layer06 13-tile smoke after a clean bitstream download or a
known-good tile4 run:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -FastRun -RunLayer06Tiles -CaptureSeconds 2400
```

To run the Layer06 `conv3_pool` 13-tile smoke:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -FastRun -RunLayer06PoolTiles -CaptureSeconds 2400
```

To run the `conv4_pool` 7-tile smoke:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -FastRun -RunConv4PoolTiles -CaptureSeconds 2400
```

To run the chained `conv3_pool -> conv4_pool` smoke:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -FastRun -RunConv3Conv4Chain -CaptureSeconds 3600
```

To run the validated chain modes with the current line-buffer-fix bitstream:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -BuildDirName build_system_xck26_kv260_linebuffix -RunConv4Conv5Chain -CaptureSeconds 3600
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -BuildDirName build_system_xck26_kv260_linebuffix -RunConv0Conv4Chain -CaptureSeconds 3600
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -BuildDirName build_system_xck26_kv260_linebuffix -RunConv0Conv5Chain -CaptureSeconds 5400
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -BuildDirName build_system_xck26_kv260_linebuffix -RunConv0Conv6Chain -CaptureSeconds 7200
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -BuildDirName build_system_xck26_kv260_linebuffix -RunConv0Conv7Chain -CaptureSeconds 9000
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -BuildDirName build_system_xck26_kv260_linebuffix -RunConv0Conv8Chain -CaptureSeconds 10800
```

The Conv0-to-Conv6 chain passed on the line-buffer-fix bitstream on
June 6, 2026. Its UART log is:

```text
build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_211220_conv0_conv6_chain_COM8.log
```

Conv6 compared all `173056` output bytes bit-exactly.

The Conv0-to-Conv7 sparse-3x3 chain also passed on June 6, 2026:

```text
build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_212154_conv0_conv7_chain_COM8.log
```

Conv7 compared all `43264` bytes bit-exactly against its native 1x1 golden.

The Conv0-to-Conv8 chain passed on June 6, 2026:

```text
build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_213159_conv0_conv8_chain_COM8.log
```

Conv8 compared all `86528` bytes bit-exactly. The next runtime stage is the
24-channel detect Conv9 using the same center-only sparse 3x3 emulation used by
Conv7.

Use the full sequence after a board power cycle. `-FastRun` is only appropriate
when the same bitstream is still programmed and the prior accelerator run left
the PL in a known-good idle state.

The script starts `hw_server` if needed, probes JTAG, captures serial logs,
downloads the bitstream and ELF, then runs `probe_pl_regs.tcl`. Logs are saved
under the selected build directory, for example:

```text
build_system_xck26_kv260_linebuffix/board_smoke_logs/
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

If a previous accelerator run failed while `CTRL.bit0` remained busy, do not use
`-FastRun` for the next long test. The smoke runtime now checks this condition
before configuration and asks for a PL reset/bitstream reprogramming instead of
continuing with stale registers.

The deterministic smoke is kept as a control/DMA/GPIO diagnostic. Core
correctness should be judged first from the real Conv0 crop + pool fixture,
which uses external RTL semantic golden data.

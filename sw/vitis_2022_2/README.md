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

Additional chain modes extend the same runtime through the complete Conv9 head:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv4_conv5_chain
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv4_chain
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv5_chain
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv6_chain
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv7_chain
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv8_chain
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv9_chain
```

The Conv0-to-Conv9 mode executes all ten single-scale hardware layers and compares
every layer against a chain-specific RTL semantic golden. Conv5 and Conv6 must
be generated from the preceding output of the same chain; standalone golden
inputs are not interchangeable because earlier RTL-semantic differences
propagate. Conv6 runs `13x13x512 -> 13x13x1024` with `K_TOTAL=4608`,
`K_PASSES=256`, and `COUT_BLOCKS=64`. Legacy builds keep the center-only
sparse 3x3 Conv7 mapping. Batch and DDR builds use the native 1x1 vector path
with `K_TOTAL=1024`, `K_PASSES=57`, and `COUT_BLOCKS=16`.
Conv8 is a native 3x3 `13x13x256 -> 13x13x512` layer with
`K_TOTAL=2304`, `K_PASSES=128`, and `COUT_BLOCKS=32`.
The 24-channel Conv9 head similarly uses native 1x1 in batch/DDR builds with
`K_TOTAL=512`, `K_PASSES=29`, and two COUT blocks. The final K pass and second
COUT block are both partial.

The current board-validated hardware export is:

```text
build_system_xck26_kv260_native1x1/conv_accel_ps_dma_minimal.xsa
```

It includes the FIFO1024/K14 and stale-row fixes, batch AXI input streams,
the native 18-lane 1x1 feeder, packet/performance counters, 26-bit DMA
lengths, and held-request rearm protection.
`run_kv260_smoke_sequence.ps1 -BuildDirName <directory>` selects a specific
hardware build without overwriting an older validated bitstream.

## Batch stream mode

`ACCEL_BATCH_STREAM=1` packs one bias, weight, and IFM AXI stream per spatial
tile. Each input DMA starts once and pauses through AXIS backpressure while the
accelerator consumes fixed-size packets. The IFM path uses two fixed DDR
buffers so software packs tile N+1 while tile N is running. The legacy
per-request mode remains available at compile time.

The batch control registers are:

```text
0x64 STREAM_CFG       bit0 = batch mode
0x68 BIAS_PACKETS     expected packet count
0x6c WEIGHT_PACKETS   expected packet count
0x70 IFM_PACKETS      expected packet count
0x74 BIAS_COMPLETED   completed packet count
0x78 WEIGHT_COMPLETED completed packet count
0x7c IFM_COMPLETED    completed packet count
```

Build and run the fixed batch chain with:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv9_batch_chain
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -BuildDirName build_system_xck26_kv260_batchstream -RunConv0Conv9BatchChain -CaptureSeconds 240
```

The native 1x1 build is bit-exact through Conv9 and matches the RTL-chain
decode golden. IFM batch packing generates one COUT block and copies the
identical stream to the remaining blocks; 3x3 bank-to-channel lookup is also
performed once per K pass. Batch/DDR header generation additionally emits
weights directly in AXI packet order, so DMA reads the ELF read-only arrays
without runtime repacking or a scratch copy. These software-only optimizations
require no PL reprogramming. The deployment-oriented DDR image path runs ten
layers in about `1.179 s`; two images measured `1.178568 s` and `1.178591 s`.
Aggregate IFM packing is about `43.5 ms`, and weight packing is eliminated.
The fixed golden chain is slower because it performs full per-layer output
preservation and comparison and should not be used as deployment timing.

The `wgt64` hardware build keeps the same software ABI and prepacked weight
stream format, but the PL weight loader now writes each 64-bit AXIS beat into
eight byte banks in one cycle.  Build directory
`build_system_xck26_kv260_wgt64` closes timing with `WNS=0.051 ns` and `0`
routing errors.  On the same two-image DDR demo, ten-layer latency is
`0.861417 s` and `0.861422 s`; fixed-chain bit-exact validation and detection
outputs are unchanged.  The aggregate PL weight wait drops from about
`359.1 ms` to `41.9 ms`, with Conv6 weight wait dropping from `213.647 ms` to
`24.904 ms`.

The `stageperf` hardware build adds read-only stage counters without changing
the accelerator data path or software stream ABI:

```text
0xa0 STAGE_BIAS
0xa4 STAGE_WEIGHT
0xa8 STAGE_FEEDER
0xac STAGE_COMPUTE
0xb0 STAGE_DRAIN
0xb4 STAGE_OFM_POST
```

The runtime prints one `STAGEPERF` line per layer and
`tools/demo/summarize_uart_perf.py` reports aggregate stage coverage. The
current `stageperf` build was generated from the active shell Vivado
(`2025.2`) into `build_system_xck26_kv260_stageperf`. It closes timing with
`WNS=0.142 ns`, `TNS=0`, `WHS=0.011 ns`, `THS=0`, and `0` routing errors.
Resources are `CLB LUTs=52301 (44.66%)`, `CLB Registers=45655 (19.49%)`,
`BRAM Tile=45.5 (31.60%)`, and `DSP=177 (14.18%)`. The XSA SHA256 is
`9A15848B42B1BD14B8F15357C529A8137E506BA81A3EAF65A3D1C3851747B24D`; the
bitstream SHA256 is
`8D58887338B815AF99733150AFDA0FAB3B63DE9845DF72946B28F59AB03E8C0C`.

Board validation passed:

```text
build_system_xck26_kv260_stageperf/board_smoke_logs/20260607_234056_conv0_conv9_batch_chain_COM8.log
build_system_xck26_kv260_stageperf/board_smoke_logs/20260607_233758_conv0_conv9_ddr_demo_COM8.log
build_system_xck26_kv260_stageperf/board_smoke_logs/20260607_233930_conv0_conv9_ddr_demo_COM8.log
```

The two DDR demos measured `0.861363 s` and `0.861369 s`. Stage counters cover
essentially all PL busy cycles: `82076244 / 82076548` cycles on the fixed image.
The aggregate split is `bias=29904`, `weight=5617752`, `feeder=22054628`,
`compute_stage=23844930`, `drain=30102432`, and `ofm_post=426598` cycles. This
shows that the largest remaining PL stages are PSUM drain, compute-stage
overhead, and IFM feeder, not the weight-loader path.

The `drainpipe` hardware build pipelines `psum_drain_writer` without changing
the software ABI or OFM debug packet format. The writer now uses 16-bit
internal read/output counters, a one-cycle read-return tracker, and a one-entry
hold register so it can emit one PSUM packet per cycle when downstream is
ready. This also fixes the `num_pixels == 2^PSUM_BUF_AW` boundary that appears
in Conv0 batch tiles (`128` pixels with `AW=7`).

Local validation completed before board bring-up:

```text
tb_psum_drain_writer                         203 pass, 0 fail
tb_layer_config_regs                         70 pass, 0 fail
tb_axi_lite_cfg_bridge                       81 pass, 0 fail
tb_conv_accel_core_axi_lite_axis_stream_native1x1_small 80 pass, 0 fail
tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c8_b2_batch_ext 532 pass, 0 fail
tb_conv_accel_core_axi_lite_axis_stream_conv7_native1x1_ext_tile0 13332 pass, 0 fail
tb_conv_accel_core_axi_lite_axis_stream_conv9_native1x1_ext_tail 332 pass, 0 fail
tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_layer06_ext_tile4 26641 pass, 0 fail
```

The build directory is `build_system_xck26_kv260_drainpipe`. It was generated
from the active shell Vivado (`2025.2`) and closes timing with `WNS=0.348 ns`,
`TNS=0`, `WHS=0.007 ns`, `THS=0`, and `0` routing errors. Resources are
`CLB LUTs=52509 (44.83%)`, `CLB Registers=46731 (19.95%)`,
`BRAM Tile=45.5 (31.60%)`, and `DSP=177 (14.18%)`. The XSA SHA256 is
`A04D7BAA94C1F6F71F457B9EF361887DB042B02744EDBB00E802DA4F4C025634`; the
bitstream SHA256 is
`FF53FB9BB0EA579B37AB7F0D6D59EE66F0A92F4A064E8607B0D4CDEFE416F5FE`.

Board validation passed after reconnecting the KV260 UART and JTAG. A full
programming run with `build_system_xck26_kv260_drainpipe` completed
`conv0_conv9_batch_chain` bit-exact validation and matched the Conv9 decode
golden:

```text
build_system_xck26_kv260_drainpipe/board_smoke_logs/20260608_121308_conv0_conv9_batch_chain_COM8.log
```

Two DDR demos were then run with full bitstream programming. The fixed image
measured `0.645595 s`; the second image measured `0.645720 s`. Detections
remained unchanged. The common PL counter summary was:

```text
busy=60503617 cycles
compute=12.28%
wait=28.62%
stage total=60503313 cycles
stage coverage=100.00%
bias=29904
weight=5617752
feeder=22054628
compute_stage=23844930
drain=8472258
ofm_post=483841
```

Compared with the `stageperf` baseline, `stage_drain_cycles` fell from
`30102432` to `8472258` cycles, about `3.55x`. Total DDR demo latency fell from
about `0.86136 s` to about `0.6456 s`. The new largest PL stages are
`compute_stage` and `feeder`, so the next useful optimization direction is
feeder/compute overlap or reducing feeder-side IFM replay overhead.

The validation commands were:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -BuildDirName build_system_xck26_kv260_drainpipe -RunConv0Conv9BatchChain -CaptureSeconds 240
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_image_demo.ps1 -Image D:\MPSoC\python_prj\facemask\images\maksssksksss0.png -PortName COM8 -BuildDirName build_system_xck26_kv260_drainpipe -CaptureSeconds 240
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_image_demo.ps1 -Image D:\MPSoC\python_prj\facemask\images\maksssksksss1.png -PortName COM8 -BuildDirName build_system_xck26_kv260_drainpipe -CaptureSeconds 240
```

The `subperf_2022_2` hardware build keeps the drainpipe datapath and adds
read-only feeder/compute sub-stage counters. This is the first post-drainpipe
build generated with an explicit Vivado `2022.2` command line instead of the
active shell PATH:

```powershell
C:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -source tcl/build_kv260_system_xck26.tcl -tclargs -build_dir D:/MPSoC/accelerator_systolic/build_system_xck26_kv260_subperf_2022_2 -jobs 12
```

The build closes timing with `WNS=0.302 ns`, `TNS=0`, `WHS=0.010 ns`,
`THS=0`, and `0` routing errors. Resources are `CLB LUTs=52254 (44.62%)`,
`CLB Registers=46452 (19.83%)`, `BRAM Tile=45.5 (31.60%)`, and
`DSP=177 (14.18%)`. XSA SHA256 is
`ECD4AE2294182AD33C40E2A4C1981940581244F41C210A1903391369121D5A64`; bitstream
SHA256 is
`1877EECE3855A6176A7C5C800A1EBA115A21A2E273B9B6E564179600CB779B2A`.

The runtime prints one additional line per layer:

```text
SUBPERF layer=... feed_fill=... feed_push=... feed_fifo_stall=... feed_win_not_ready=... comp_wload=... comp_active=... comp_fire=... comp_ifm_stall=... comp_tail=... version=1
```

`tools/demo/summarize_uart_perf.py` reports aggregate `SUBPERF` totals and
residuals against `STAGEPERF`. Local xsim validation has passed for
configuration register reads, AXI-Lite reads, native1x1, Conv0 batch,
Conv7/Conv9 native1x1, and the r18_c8 Layer06 tile.

Board validation passed with full bitstream programming. The fixed batch chain
remained bit-exact and matched the Conv9 decode golden:

```text
build_system_xck26_kv260_subperf_2022_2/board_smoke_logs/20260608_152628_conv0_conv9_batch_chain_COM8.log
```

Two DDR demos were also run with full programming. The fixed image measured
`0.646852 s`; the second image measured `0.646994 s`; detections remained
unchanged. Logs:

```text
build_system_xck26_kv260_subperf_2022_2/board_smoke_logs/20260608_153010_conv0_conv9_ddr_demo_COM8.log
build_system_xck26_kv260_subperf_2022_2/board_smoke_logs/20260608_152819_conv0_conv9_ddr_demo_COM8.log
```

The fixed-image aggregate counter split is:

```text
busy=60549732 cycles
stage coverage=100.00%
feeder=22100743
compute_stage=23844930
drain=8472258
SUBPERF feed_fill=12119827 feed_push=7432282 feed_fifo_stall=0 feed_win_not_ready=0
SUBPERF comp_wload=881216 comp_active=7432282 comp_fire=7432282 comp_ifm_stall=0 comp_tail=15200976
```

The important reading is that `comp_fire` matches the existing compute counter,
feeder has no FIFO/window stall in this run, and compute-stage overhead is
mostly tail/drain-adjacent pipeline time rather than active MAC issue.

## Native 1x1 mode

`CONV[16]` selects the native 1x1 path. It requires batch mode, stride 1,
padding 0, and a spatial tile no larger than the 1024-entry IFM FIFO. Each
pixel is transported as three full 64-bit beats for lanes 0-7, 8-15, and
16-17. Unused bytes and tail input channels carry the input zero point.

```text
0x90 VECTOR_PACKETS   completed vector packets
0x94 VECTOR_PIXELS    completed 18-lane vectors
0x98 VECTOR_BEATS     accepted IFM AXIS beats
0x9c VECTOR_STALLS    cycles waiting for all IFM FIFOs
```

Build and run the native platform with:

```powershell
C:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -source tcl/build_kv260_system_xck26.tcl -tclargs -build_dir D:/MPSoC/accelerator_systolic/build_system_xck26_kv260_native1x1 -jobs 12
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv9_ddr_demo
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_image_demo.ps1 -Image D:\MPSoC\python_prj\facemask\images\maksssksksss0.png -PortName COM8 -BuildDirName build_system_xck26_kv260_native1x1
```

Build and run the current weight-loader-optimized platform with:

```powershell
C:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -source tcl/build_kv260_system_xck26.tcl -tclargs -build_dir D:/MPSoC/accelerator_systolic/build_system_xck26_kv260_wgt64 -jobs 12
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv9_batch_chain
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -BuildDirName build_system_xck26_kv260_wgt64 -RunConv0Conv9BatchChain -CaptureSeconds 300
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv9_ddr_demo
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_image_demo.ps1 -Image D:\MPSoC\python_prj\facemask\images\maksssksksss0.png -PortName COM8 -BuildDirName build_system_xck26_kv260_wgt64
```

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
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -BuildDirName build_system_xck26_kv260_linebuffix -RunConv0Conv9Chain -CaptureSeconds 12600
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

Conv8 compared all `86528` bytes bit-exactly.

The complete Conv0-to-Conv9 chain passed on June 6, 2026:

```text
build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_214226_conv0_conv9_chain_COM8.log
```

Conv9 compared all `4056` bytes bit-exactly against its native 1x1 golden.
The A53 smoke now decodes the bit-exact tensor only after that comparison,
applies confidence filtering and class-aware NMS, reverses the fixed-image
letterbox, and prints machine-readable `DECODE`/`DET` UART records. The board
script regenerates the RTL-chain decode golden and compares those records
automatically.

The full reprogram-and-run acceptance passed on June 6, 2026:

```text
build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_222542_conv0_conv9_chain_COM8.log
```

It reported one `with_mask` detection with score `0.357321`; Conv9 remained
bit-exact for all `4056` bytes and the UART comparison passed within `0.1`
pixel and `1e-4` score tolerance.

## Runtime image demo

Build the DDR-input ELF once:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 -Mode conv0_conv9_ddr_demo
```

Run an image after a board power cycle. This preprocesses the image, programs
the existing line-buffer-fix bitstream, writes a 64-byte metadata header and
the `416x416x3` RGB HWC tensor to DDR address `0x10000000`, runs inference, and
saves an annotated image:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_image_demo.ps1 -Image D:\MPSoC\python_prj\facemask\images\maksssksksss0.png
```

For later images while the same bitstream remains programmed, reuse the same
ELF with `-FastRun`. No recompilation is needed:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_image_demo.ps1 -Image D:\MPSoC\python_prj\facemask\images\maksssksksss1.png -FastRun
```

Outputs are placed under `demo_output/<timestamp>_<image>/`: the DDR package,
letterbox metadata and preview, UART-derived detection JSON, `performance.json`,
and `detections.png`. The package includes original dimensions, scale/padding,
and an FNV-1a tensor checksum validated by the A53 before inference.

The DDR demo is built with `-O2`. Its runtime caches the IFM bank-to-channel
mapping once per line and prints one machine-readable `PERF` record per layer.
The demo wrapper summarizes those records with
`tools/demo/summarize_uart_perf.py`.

An initial June 7, 2026 full-reprogram measurement used:

```text
build_system_xck26_kv260_linebuffix/board_smoke_logs/20260607_132050_conv0_conv9_ddr_demo_COM8.log
```

The ten layer times summed to `23.699203 s`. This run still emitted extensive
synchronous UART progress logs, so it is retained as a diagnostic result rather
than a clean inference baseline. The largest apparent categories were
`other_us=12.008225 s`, `ofm_parse_us=5.325749 s`,
`ifm_pack_us=2.300888 s`, and `ifm_dma_us=1.625445 s`. The detection still
matched the RTL-chain decode golden.

The DDR demo now builds with `ACCEL_PERF_ONLY=1`, suppressing successful
per-service progress messages while preserving errors, `PERF`, `HWPERF`,
detections, and final status. The clean software baseline on the old
`linebuffix` bitstream was approximately `7.482622 s`.

The performance-counter bitstream is:

```text
build_system_xck26_kv260_perfcount
```

It exposes tile-local PL counters at byte offsets `0x48..0x60` for busy cycles,
external-service waits, and exact systolic-array `compute_fire` cycles. The
full-reprogram board run passed on June 7, 2026:

```text
build_system_xck26_kv260_perfcount/board_smoke_logs/20260607_155114_conv0_conv9_ddr_demo_COM8.log
```

The ten layers took `7.489041 s`. PL counters accumulated `746344195` busy
cycles, `667279241` external-wait cycles (`89.41%`), and `8739328`
compute-fire cycles (`1.17%`). IFM waits alone occupied about `67.73%` of busy
time and weight waits about `21.54%`. The result remained one `with_mask`
detection with score `0.357321`, matching the RTL-chain decode golden.

The measured bottleneck is therefore fine-grained A53 IFM/weight service, not
systolic-array arithmetic. The next hardware/software architecture should batch
or autonomously fetch those streams and overlap transfers with compute. Use
board-side `PERF` and `HWPERF` values for optimization comparisons; PowerShell
wall time additionally includes JTAG setup, downloads, capture, and post-run
probing.

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

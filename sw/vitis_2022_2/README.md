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
0x64 STREAM_CFG       bit0 = batch mode, bit1 = experimental raw-HWC IFM cache, bit2 = experimental early PSUM drain, bit3 = experimental K-pass prefetch, bit4 = experimental partial-PSUM overlap, bit5 = experimental continuous PSUM collector
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

An experimental native `1x1` raw-HWC IFM cache path exists behind
`ACCEL_RAW_HWC_IFM=1` or the manual build script's `-RawHwcIfm` switch. In
that mode software sends one contiguous `uint8` HWC spatial tile over the
existing IFM DMA, while PL centers and replays it for all K passes and COUT
blocks. This path is currently directed-test only; default batch and DDR demos
still use the prepacked IFM stream. Vivado/xsim `2022.2` validation has passed
for Conv7 raw tile0 (`13332/0`) and Conv9 raw tail (`332/0`), while the old
prepacked Conv9 tail remains bit-exact (`332/0`). Default and `-RawHwcIfm`
manual batch-chain builds also compile successfully.

The first board implementation of this path was built as
`D:/MPSoC/b_hwc12_22` after reducing the cache to `HWC_CACHE_AW=12` and using
one synchronous block-RAM bank per lane. It closes timing with `WNS=0.024 ns`
and uses `BRAM Tile=63.5`, `DSP=197`. The XSA SHA256 is
`AADE091C3DC341ADBBF1CE62AFA9A7E65BBABB3C69389762CEE09101E6C0DDF7`; the
bitstream SHA256 is
`85859C3F9B6F30998179E37EAE3D771C6CFC6C168ED802A2C34F7C3E0F7C7361`.
Board DDR demos passed with unchanged detections and measured about
`0.6448 s`, essentially the same as the drainpipe/subperf baseline. The
conclusion is that first-stage raw-HWC for only Conv7/Conv9 is functionally
useful but not a major performance lever; the next optimization is
`comp_tail` reduction rather than expanding raw-HWC to `3x3`.

The follow-up `3x3` raw-HWC cache uses two 72-bit logical banks instead of
replicating one narrow bank per array lane. For each output pixel and channel,
the nine kernel positions occupy one 72-bit word; even and odd channels select
the two banks, so one synchronous read from both banks produces the 18 values
for a K pass. Each bank is split across four depth stripes. With
`HWC_CACHE_DEPTH=13312` and `HWC_CACHE_USE_URAM=1`, Vivado infers eight URAMs
total. The final full-top OOC synthesis at 100 MHz reports `WNS=+1.000 ns`.

The first software opt-in is Conv6 only:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 `
  -Mode conv0_conv9_ddr_demo -RawHwcConv6 -TailCyclesOverride 1
```

For image runs, pass the same options when rebuilding the ELF:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_image_demo.ps1 `
  -Image <image-path> `
  -BuildDirName build_system_xck26_kv260_hwc3x3_uram_tail1_2022_2 `
  -RebuildElf -RawHwcConv6 -TailCyclesOverride 1
```

The RTL and internal `ACCEL_RAW_HWC_3X3` gate are layer-generic rather than
Conv6-specific. Other `3x3` layers can use it when
`tile_pixels * ceil(CIN/2) <= HWC_CACHE_DEPTH`. All current chain tiles satisfy
this limit: Conv0 needs at most 1664 words, Conv1/5/8 need 6656, and
Conv2/3/4/6 use the full 13312 words. They remain disabled until each layer has
dedicated xsim and board bit-exact coverage. This statement currently applies
to the network's `stride=1, pad=1` 3x3 layers; arbitrary stride/pad requires
extending the software layer descriptor and raw-row selection first.

The Vivado `2022.2` system build is
`build_system_xck26_kv260_hwc3x3_uram_tail1_2022_2`. It closes timing at
`WNS=+0.017 ns`, `WHS=+0.010 ns`, with zero routing errors, and uses
`8 URAM`, `45.5 BRAM`, `54214 LUT`, `46902 FF`, and `183 DSP`. Board
programming is still pending: the June 9, 2026 probe found no JTAG targets and
no KV260 UART/COM8. Reconnect testing must therefore start with a full
bitstream program rather than `-FastRun`.

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
SUBPERF layer=... feed_fill=... feed_push=... feed_fifo_stall=... feed_win_not_ready=... comp_wload=... comp_active=... comp_fire=... comp_ifm_stall=... comp_tail=... version=2
TAILSTAT layer=... tail_config=... tail_elapsed=... drain_empty_wait=... drain_empty_sticky=...
RAWSTAT layer=... load_active=... load_unpack=... replay_active=... replay_wait_ready=...
```

`SUBPERF` version 2 keeps the same feeder/compute counters and adds the
tailtrim safety map at byte offsets `0xe0..0xec`: configured tail cycles,
elapsed tail cycles, PSUM-drain FIFO-empty wait cycles, and a sticky
FIFO-empty wait flag. The raw-HWC replay diagnostic map at byte offsets
`0xf0..0xfc` reports cache load-active cycles, beat-unpack cycles, replay-active
cycles, and replay wait-for-ready cycles. `tools/demo/summarize_uart_perf.py`
reports aggregate `SUBPERF`/`TAILSTAT`/`RAWSTAT` totals and residuals against
`STAGEPERF`. Local xsim validation has passed for configuration register reads,
AXI-Lite reads, native1x1, Conv0 batch, Conv7/Conv9 native1x1, and the r18_c8
Layer06 tile.

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

The tailtrim RTL makes the systolic tail wait configurable without changing
AXIS formats, the A53 stream ABI, or the array/PSUM data paths. Default
`TAIL_CYCLES_CONFIG=0` preserves the legacy formula (`138` cycles for
`ROWS=18, COLS=8`). Directed xsim sweeps under Vivado `2022.2` passed with
`tail_cycles=1` for Conv7 raw-HWC tile0 (`13332/0`), Conv0 crop+pool batch
(`532/0`), Conv9 raw-HWC tail (`332/0`), and Layer06 tile4 (`26641/0`).
Following the planned `min_passing + 4` margin, the first implementation build
should use `-tail_cycles 5`:

```powershell
C:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -source tcl/build_kv260_system_xck26.tcl -tclargs -build_dir D:/MPSoC/accelerator_systolic/build_system_xck26_kv260_tailtrim_2022_2 -tail_cycles 5 -jobs 12
```

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

## 2026-06-13 raw-HWC replay diagnostics

Diagnostic RTL adds read-only raw-HWC cache counters at accelerator byte
offsets `0xf0..0xfc`:

```text
0xf0 RAW_LOAD_ACTIVE
0xf4 RAW_LOAD_UNPACK
0xf8 RAW_REPLAY_ACTIVE
0xfc RAW_REPLAY_WAIT_READY
```

The runtime prints one `RAWSTAT` line per layer, and
`tools/demo/summarize_uart_perf.py` aggregates the totals.

The dedicated diagnostic hardware build is:

```text
build_system_xck26_kv260_rawstat_2022_2
```

It was built with `HWC_CACHE_AW=14`, `HWC_CACHE_DEPTH=13312`,
`HWC_CACHE_STRIPES=4`, `HWC_CACHE_USE_URAM=1`, and `TAIL_CYCLES_CONFIG=1`.
Implementation completed with all timing constraints met (`WNS=0.000 ns`,
`TNS=0`, `WHS=0.010 ns`, `THS=0`) and zero routing errors. Final resources
include `45.5` BRAM tiles, `8` URAMs, and `183` DSPs. The generated XSA is:

```text
build_system_xck26_kv260_rawstat_2022_2/conv_accel_ps_dma_minimal.xsa
```

Board validation used full PL programming for the first run:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -BuildDirName build_system_xck26_kv260_rawstat_2022_2 -RunConv0Conv9DdrDemo -RawHwcConv5 -RawHwcConv6 -RawHwcConv8 -InputPackage D:\MPSoC\accelerator_systolic\demo_output\20260608_234008_maksssksksss0\image_package.bin -CaptureSeconds 240
```

The log
`build_system_xck26_kv260_rawstat_2022_2/board_smoke_logs/20260613_193856_conv0_conv9_ddr_demo_COM8.log`
passed with the unchanged `with_mask` detection (`score=0.357321`) and summed
to `544.576 ms`.

A fast-run A/B test then enabled Conv4 as well:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 -PortName COM8 -BuildDirName build_system_xck26_kv260_rawstat_2022_2 -FastRun -RunConv0Conv9DdrDemo -RawHwcConv4 -RawHwcConv5 -RawHwcConv6 -RawHwcConv8 -InputPackage D:\MPSoC\accelerator_systolic\demo_output\20260608_234008_maksssksksss0\image_package.bin -CaptureSeconds 240
```

The log
`build_system_xck26_kv260_rawstat_2022_2/board_smoke_logs/20260613_194053_conv0_conv9_ddr_demo_COM8.log`
passed with the same detection and summed to `549.328 ms`.

The important RAWSTAT result is that `replay_wait_ready=0` for Conv4, Conv5,
Conv6, and Conv8. Conv4 reports `load_active=971792` and
`replay_active=1384448`; Conv6 reports `load_active=1153984` and
`replay_active=5537792`. The raw cache replay is therefore not blocked by IFM
FIFO backpressure. The remaining cost is the serialized
load/replay-before-compute boundary, so the next optimization should overlap
raw-HWC replay with compute after a safe FIFO watermark rather than simply
enabling raw-HWC on earlier 3x3 layers.

## 2026-06-13 raw-HWC replay/compute overlap prototype

The current RTL prototype adds a controlled overlap mode for raw-HWC replay.
`TAIL_CONFIG` at byte offset `0xe0` now packs two fields:

```text
[15:0]  tail_cycles
[31:16] raw_hwc_compute_start_level
```

The low half keeps the previous tail-cycle override behavior. The high half is
the raw-HWC feeder watermark: when nonzero, compute may start after the raw
vector feeder has pushed at least that many pixel vectors into the IFM FIFOs.
PSUM drain still waits until both compute completion and the feeder-done event
have occurred, so output ordering and all DMA/AXIS formats remain unchanged.

The software build script accepts:

```powershell
-RawHwcComputeStartLevel <N>
```

and currently defaults to `0`, keeping the serialized raw-HWC path as the safe
default. Nonzero values enable the experimental overlap path. Local Icarus checks for the configuration registers, scheduler
overlap, and feeder path pass, and the Python image-demo parser test passes in
`conda pytorch_env`.

The scheduler-side fix after the first board timeout latches feeder completion
per pass. This is important because `feeder_done` is a one-cycle pulse: in
overlap mode it can arrive before `compute_done`, and the older scheduler could
miss it and never start PSUM drain. Vivado/xsim `2022.2` now passes
`RawHwcComputeStartLevel=64` for Conv5 tile0, Conv6 tile0, and Conv8 tile0. The
serialized `RawHwcComputeStartLevel=0` path remains the default until the fixed
RTL is rebuilt and board-validated.

The fixed RTL has a 2022.2 implementation in the short external build directory
`D:/MPSoC/b_ovcred_22`. A first attempt in the long in-repo build directory hit
the Windows 260-character checkpoint path limit. The short-path implementation
meets timing (`WNS=+0.155 ns`, `TNS=0`, `WHS=+0.010 ns`, `THS=0`) with `0`
routing errors. Artifact hashes are:

```text
XSA SHA256       E5A1FB0BB1509C9D090CEF6781AB31185B17AEA08794ECA8AD5FBD53C8C02B8A
bitstream SHA256 4ABDD8736868B8571417AFC8D1B9E56D63D9EFD6898F69CCF982B2077FCC66CC
```

The first hardware build for this prototype is:

```text
build_system_xck26_kv260_hwcoverlap_2022_2
```

It uses the same URAM raw-HWC cache parameters as the prior 3x3 build and
`TAIL_CYCLES_CONFIG=1`. Vivado `2022.2` implementation met timing with
`WNS=+0.143 ns`, `TNS=0`, `WHS=+0.010 ns`, `THS=0`, and zero routing errors.
Final resources are `54145` LUT, `47037` FF, `45.5` BRAM, `8` URAM, and `183`
DSP. The XSA SHA256 is
`010D703591D7F1322E474ABEDEBDED956EE237B50C5D2B0B8B406C0C1F487B26`; the
bitstream SHA256 is
`2567A1C61D98D2A1F53CF17D1D6E552E7E5D8AEA15106AD43A23D48DE0ED2A14`.

Board validation with full programming shows the serialized control value
`-RawHwcComputeStartLevel 0` passes the fixed-image DDR demo at `544.490 ms`.
The nonzero overlap candidates tested so far, `64` and `1024`, both timeout at
Conv5 tile0. Debug registers for the `1024` run show only one vector packet and
52 compute fires completed while raw-HWC load/replay was still active, so the
original simple total-push watermark implementation was not safe without the
per-pass feeder completion latch.

After adding the feeder completion latch, the credit-fix bitstream in
`D:/MPSoC/b_ovcred_22` passes board validation for the fixed `maksssksksss0`
DDR package:

```text
RawHwcComputeStartLevel=64  PASS  total=542.448 ms  log=20260613_221152_conv0_conv9_ddr_demo_COM8.log
RawHwcComputeStartLevel=0   PASS  total=544.415 ms  log=20260613_221401_conv0_conv9_ddr_demo_COM8.log
```

The detection result is unchanged (`with_mask`, score `0.357321`). The timeout
is fixed, but the measured speedup is only about `1.97 ms`, so this overlap
knob is functional but not yet a major performance lever.

## 2026-06-13 PSUM drain sub-performance counters

The current RTL adds a diagnostic-only `DRAINPERF` line to split the PSUM drain
stage into smaller causes. This does not change the DMA packet formats, raw-HWC
tile format, prepacked IFM format, weight stream format, quantization path, or
OFM output order.

The AXI-Lite config address path is now 9-bit wide at the top-level wrapper.
Existing offsets below `0x100` are unchanged, and the new read-only offsets are:

```text
0x100 DRAIN_READ_FIRE
0x104 DRAIN_PACKET_FIRE
0x108 DRAIN_READY_STALL
0x10c DRAIN_INTERNAL_FULL
0x110 DRAINPERF_VERSION
```

Runtime output now includes:

```text
DRAINPERF layer=... read_fire=... packet_fire=... ready_stall=... internal_full=... empty_wait=... version=...
```

`tools/demo/summarize_uart_perf.py` parses this line and reports drain residual
cycles. Before board use, rebuild the Vivado 2022.2 system so the BD/IP wrapper
sees the widened AXI-Lite address port.

The first 2022.2 drainperf bitstream was built in `D:/MPSoC/b_drainperf_22`
with the same URAM raw-HWC cache parameters and `TAIL_CYCLES_CONFIG=1`.
Full-programming board validation passed for `Conv5/6/8 raw-HWC` and
`RawHwcComputeStartLevel=64`:

```text
DDR demo    PASS  total=543.006 ms  log=20260613_231413_conv0_conv9_ddr_demo_COM8.log
Batch chain PASS  RTL golden and YOLO decode matched  log=20260613_231623_conv0_conv9_batch_chain_COM8.log
```

The new counters show that Conv5/6/8 drain bubbles are dominated by
`empty_wait`, while `ready_stall` and `internal_full` are zero for those backend
layers. The next performance work should therefore inspect PSUM availability
and drain scheduling rather than OFM downstream backpressure.

## 2026-06-14 experimental early PSUM drain

`-EarlyDrain` enables `ACCEL_EARLY_DRAIN=1`, which sets `STREAM_CFG[2]` for
the experimental ELF variant. Default builds leave this bit at `0`.

Early drain lets the scheduler start `psum_drain_writer` after the current pass
has begun producing PSUM packets, instead of waiting for compute completion.
The scheduler still waits for feeder completion, compute completion, and drain
completion before advancing to the next K/COUT block, so the optimization does
not change packet formats, layer order, DMA usage, or quantization semantics.

Validation summary:

```text
Icarus: tb_layer_config_regs, tb_axi_lite_cfg_bridge,
        tb_layer_scheduler_early_drain, tb_layer_scheduler_overlap,
        tb_psum_drain_writer PASS
xsim 2022.2: Conv5/Conv6/Conv8 raw-HWC tile0,
             RawHwcComputeStartLevel=64, EarlyDrain PASS
Vivado 2022.2 build: D:/MPSoC/b_earlydrain_22
Timing: WNS=+0.181 ns, TNS=0, WHS=+0.010 ns, THS=0
Resources: 54437 LUT, 47179 FF, 45.5 BRAM, 8 URAM, 183 DSP
```

Board validation on `COM8`:

```text
DDR demo maksssksksss0  PASS  total=520.446 ms  log=20260614_000915_conv0_conv9_ddr_demo_COM8.log
DDR demo maksssksksss1  PASS  total=520.505 ms  log=20260614_001239_conv0_conv9_ddr_demo_COM8.log
Batch chain             PASS  RTL golden + YOLO decode  log=20260614_001057_conv0_conv9_batch_chain_COM8.log
```

Compared with the `b_drainperf_22` baseline (`543.006 ms`), early drain saves
about `22.6 ms`. Conv5/6/8 still report the same `DRAINPERF empty_wait`
components, so the gain comes from overlap/hiding rather than faster PSUM FIFO
production. This is useful but not a complete solution for the remaining
feeder/compute/drain serialization bottleneck.

## 2026-06-14 experimental K-pass prefetch

`-PassPrefetch` enables `ACCEL_PASS_PREFETCH=1`, which sets `STREAM_CFG[3]`
only for raw-HWC layers. Default builds leave this bit at `0`.

The first RTL prototype prefetches the next K pass inside the same COUT block.
It keeps the current execution pass and the raw-HWC replay pass separate:
compute/PSUM/final-pass logic still uses the current execution K pass, while
the raw-HWC cache may replay `feeder_pass_base_k` for the next K pass. The
prefetch path never crosses COUT blocks and never starts next-pass compute until
the current pass drain has finished.

Runtime output now includes:

```text
PREFETCHPERF layer=... start=... weight_done=... feed_done=... hit=... miss=... stall=... version=...
```

New read-only byte offsets:

```text
0x114 PREFETCH_START
0x118 PREFETCH_WEIGHT_DONE
0x11c PREFETCH_FEED_DONE
0x120 PREFETCH_HIT
0x124 PREFETCH_MISS
0x128 PREFETCH_STALL
0x12c PREFETCHPERF_VERSION
```

Local validation summary:

```text
Icarus: tb_layer_config_regs, tb_axi_lite_cfg_bridge,
        tb_layer_scheduler_pass_prefetch PASS
xsim 2022.2: Conv5/Conv6/Conv8 raw-HWC tile0,
             RawHwcComputeStartLevel=64, EarlyDrain, PassPrefetch PASS
Python: tb/test_kv260_image_demo.py PASS
```

One important implementation detail is that `systolic_top` now uses an explicit
weight-read budget: the compute start cycle consumes the first vector and the
following load cycles consume exactly `COLS-1` more vectors. This prevents the
array from reading into a prefetched next-pass weight tile while also avoiding
the earlier under-read case.

The prefetch trigger is intentionally conservative in this prototype, so it
overlaps mainly the drain / pass-boundary window. The `D:/MPSoC/b_passprefetch_22`
2022.2 bitstream meets timing (`WNS=+0.280 ns`, `TNS=0`, `WHS=+0.011 ns`,
`THS=0`), and its SHA256 is
`7439BDAEDAD63F1F0628400EFD1989A4A937CE64796E09E42902647B877CC14A`.

Board validation on `COM8` passed:

```text
Batch chain             PASS  RTL golden + YOLO decode  log=20260615_000328_conv0_conv9_batch_chain_COM8.log
DDR demo maksssksksss0  PASS  total=386.649 ms          log=20260615_000527_conv0_conv9_ddr_demo_COM8.log
DDR demo maksssksksss1  PASS  total=386.637 ms          log=20260615_000700_conv0_conv9_ddr_demo_COM8.log
```

`PREFETCHPERF` reports `start=97792`, `weight_done=97792`,
`feed_done=97792`, `hit=97792`, `miss=0`, and `stall=0` across the full DDR
demo. Compared with the previous early-drain baseline (`520.446 ms`), this
saves about `133.8 ms`; compared with the drainperf baseline (`543.006 ms`), it
saves about `156.4 ms`.

## 2026-06-15 experimental partial-PSUM overlap

`-PsumStreamOverlap` defines `ACCEL_PSUM_STREAM_OVERLAP=1` and sets
`STREAM_CFG[4]` for the selected raw-HWC Conv5/6/8 layers. Default ELFs leave
the bit clear.

The mode allows the next K-pass compute to start after the previous pass has
written a conservative lead of partial-PSUM pixels, rather than waiting for
the complete partial drain. Ping-pong PSUM banks and per-bank available counts
guard read-after-write ordering. The external DMA, weight, raw-HWC, OFM, and
quantization formats are unchanged.

Runtime output adds:

```text
PSUMOVLPERF layer=... start=... hit=... wait_psum=... underflow=... version=...
```

Read-only byte offsets are `0x130` through `0x140` for start, hit, wait,
underflow, and version. Local Icarus scheduler/config tests pass. Vivado/xsim
`2022.2` external-golden tests pass for Conv5, Conv6, and Conv8 raw-HWC tile0
with overlap64, early drain, pass prefetch, and partial-PSUM overlap enabled;
each reports `854 pass, 0 fail`. The batch-chain and DDR-demo experimental
ELFs also build successfully.

The Vivado `2022.2` implementation is available at
`D:/MPSoC/b_psumovl_22`. It meets timing with `WNS=+0.038 ns`, `TNS=0`,
`WHS=+0.010 ns`, and `THS=0`; route status has zero errors. Resources are
`78900 LUT`, `48294 FF`, `31 BRAM`, `8 URAM`, and `183 DSP`.

The partial-PSUM overlap prototype currently has a significant storage cost:
the concurrent ping-pong PSUM buffer maps to about `23616` LUTs instead of the
previous `14 BRAM` implementation. The bitstream is suitable for board
validation, but this mapping should be revisited if the measured performance
gain does not justify the extra LUT use and reduced timing margin.

```text
bit SHA256 A4D3C5796631A8F5DDC6B1948824D0DE7340ED452EE31E67C91084A0F2C0B4E3
xsa SHA256 4482BA0C2C932DD6F52E8856157C23DA4195C38B794BFADA42FEC04EE4C9F8EB
```

Board validation has not yet been performed.

## 2026-06-15 experimental continuous PSUM collector

`-ContinuousPsum` defines `ACCEL_CONTINUOUS_PSUM=1` and sets
`STREAM_CFG[5]` for selected raw-HWC layers. Default ELFs leave the bit clear.

The mode replaces non-final pass drain with a continuous collector. The
collector receives one pass context before compute starts, groups the per-column
PSUM FIFO outputs into pixel packets, writes non-final packets directly to the
selected ping-pong PSUM bank, and forwards final packets to the existing
requant / activation / OFM path. DMA streams, raw-HWC tile layout, OFM packet
format, and quantization are unchanged.

Build the experimental DDR demo with:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 `
  -Mode conv0_conv9_ddr_demo `
  -RawHwcConv5 -RawHwcConv6 -RawHwcConv8 `
  -RawHwcComputeStartLevel 64 `
  -EarlyDrain -PassPrefetch -PsumStreamOverlap -ContinuousPsum `
  -TailCyclesOverride 1
```

The batch-chain mode accepts the same switches with
`-Mode conv0_conv9_batch_chain`.

Runtime output adds:

```text
COLLECTPERF layer=... packet_fire=... partial_write=... final_write=...
            context_push=... context_pop=... context_full_stall=...
            column_empty_wait=... version=...
```

Read-only byte offsets are:

```text
0x144 COLLECT_PACKET_FIRE
0x148 COLLECT_PARTIAL_WRITE
0x14c COLLECT_FINAL_WRITE
0x150 COLLECT_CONTEXT_PUSH
0x154 COLLECT_CONTEXT_POP
0x158 COLLECT_CONTEXT_FULL_STALL
0x15c COLLECT_COLUMN_EMPTY_WAIT
0x160 COLLECTPERF_VERSION
```

Local validation completed so far:

```text
Icarus selected regression PASS
xsim 2022.2 module-level collector / BRAM / scheduler / config tests PASS
xsim 2022.2 Conv5/Conv6/Conv8 raw-HWC tile0 continuous PSUM PASS, 854/0 each
Vitis 2022.2 batch-chain and DDR-demo experimental ELFs build
```

Vivado `2022.2` implementation completed in `D:/MPSoC/b_psumcollector_22`.
Final timing/resource summary:

```text
WNS=+0.212 ns, TNS=0, WHS=+0.010 ns, THS=0
routing errors=0
LUT=56618, FF=48993, BRAM=63, URAM=8, DSP=183
LUT as Memory=16570
bit SHA256=9E27106EA86106164C522A1F9AE3FAB646D9041D90D59C4E2DF4071C8F939186
XSA SHA256=973E7C98E137589D5C53FAE40DE2450F6F26E4BF4B77B220489F9494C4799B66
```

The first `b_psumcollector_22` board run failed on Conv5 tail tile 3. The fix
clears stale per-bank partial-PSUM availability credit when a non-final
continuous-collector pass starts writing a reused ping-pong bank. After the
fix, the validated hardware build is:

```text
build dir: D:/MPSoC/b_psumcollector_fix3_22
WNS=+0.165 ns, TNS=0, WHS=+0.010 ns, THS=0
routing errors=0
LUT=56442, FF=49000, BRAM=63, URAM=8, DSP=183
LUT as Memory=16530
bit SHA256=1E0255EA61AEBF28C01DC72386B398ABAE000193EA840C217CAAD5BC6437248D
XSA SHA256=40424070EDC08B05BDA56FE2295A2D5F3520E4F425559E2693F9B49185E1562A
```

Board validation:

```text
20260615_081758_conv0_conv9_batch_chain_COM8.log PASS
20260615_082040_conv0_conv9_ddr_demo_COM8.log   PASS, total=0.371271 s
20260615_082302_conv0_conv9_ddr_demo_COM8.log   PASS, total=0.371314 s
```

The two DDR demo detections remain stable:

```text
maksssksksss0: with_mask score=0.357321
maksssksksss1: with_mask score=0.295050
```

`COLLECTPERF context_full_stall=0`, `PSUMOVLPERF underflow=0`, and the
prefetch/psum-overlap hit rates are `100%` on the continuous-collector layers.
The measured gain over the previous `b_psumovl_credit1_22` baseline
(`~374.36 ms`) is small but positive; the main value of this step is that the
partial-PSUM RAM now maps cleanly into BRAM and the continuous collector is
board-proven.

## 2026-06-15 pass-level timeline diagnostics

The pass timeline monitor is diagnostic-only. It is intended to explain the
remaining gap between true `compute_fire` cycles and the larger
`STAGE_COMPUTE`, `STAGE_FEEDER`, and `COLLECT_COLUMN_EMPTY_WAIT` counters in
the continuous-PSUM build. It does not change DMA formats, raw-HWC layout, OFM
packet order, quantization, or scheduler behavior.

New read-only offsets are:

```text
0x164 PASSTRACE_SELECT              bit31 enable, [23:16] COUT block, [15:0] K pass
0x168 PASS_COUNT
0x16c PASS_START_TO_FIRST_FIRE
0x170 PASS_FIRST_TO_LAST_FIRE
0x174 PASS_LAST_FIRE_TO_DONE
0x178 PASS_COLLECT_FIRST_WAIT
0x17c PASS_COLLECT_COLUMN_EMPTY
0x180 PASS_REPLAY_DURING_COMPUTE
0x184 PASS_COMPUTE_IDLE_STAGE
0x188 PASSTRACE_WEIGHT_DONE
0x18c PASSTRACE_FEED_START
0x190 PASSTRACE_FEED_READY
0x194 PASSTRACE_FEED_DONE
0x198 PASSTRACE_COMPUTE_START
0x19c PASSTRACE_FIRST_FIRE
0x1a0 PASSTRACE_LAST_FIRE
0x1a4 PASSTRACE_COMPUTE_DONE
0x1a8 PASSTRACE_COLLECT_FIRST
0x1ac PASSTRACE_COLLECT_LAST
0x1b0 PASSTRACE_PASS_DONE
0x1b4 PASSPERF_VERSION              bit31 trace_valid, [30:0] version
```

The runtime prints one aggregate line per layer:

```text
PASSPERF layer=... pass_count=... start_to_first=... fire_span=...
         tail=... collect_wait=... collect_empty=...
         replay_during_compute=... compute_idle=... version=...
```

To enable a selected timestamp trace in the generated ELF, add
`-TilePerfTrace` and choose the pass:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 `
  -Mode conv0_conv9_ddr_demo `
  -RawHwcConv5 -RawHwcConv6 -RawHwcConv8 `
  -RawHwcComputeStartLevel 64 `
  -EarlyDrain -PassPrefetch -PsumStreamOverlap -ContinuousPsum `
  -TilePerfTrace -PassTraceCoutBlock 0 -PassTraceKPass 0 `
  -TailCyclesOverride 1
```

When a selected pass is observed, the runtime also prints:

```text
PASSTRACE layer=... tile=... cout_block=... k_pass=...
          weight_done=... feed_start=... feed_ready=... feed_done=...
          compute_start=... first_fire=... last_fire=... compute_done=...
          collect_first=... collect_last=... pass_done=... version=...
```

`tools/demo/summarize_uart_perf.py` parses both lines and reports pass averages,
compute utilization inside `STAGE_COMPUTE`, and fire density over the
first-to-last-fire span.

The first diagnostic hardware build is:

```text
build dir: D:/MPSoC/b_passtrace_22
Vivado:    2022.2
WNS=+0.193 ns, TNS=0, WHS=+0.010 ns, THS=0
routing errors=0
CLB LUTs=57197, CLB Registers=49838
LUT as Memory=16641
BRAM Tile=63, URAM=8, DSP=184
bit SHA256=7712344B10C36969552A9547B1CED9F834C6381B3209316D9E0001DFDA4F4B04
XSA SHA256=99F09A6ACC6E9D3DE287DDD8AB7BA05080F4CF887E477745D8359B9D3D076AD8
```

The build is ready for full-program board validation. It should be compared
against the validated `D:/MPSoC/b_psumcollector_fix3_22` baseline.

The fixed diagnostic build is:

```text
build dir: D:/MPSoC/b_passtrace_fix2_22
Vivado:    2022.2
WNS=+0.113 ns, TNS=0, WHS=+0.010 ns, THS=0
routing errors=0
CLB LUTs=57226, CLB Registers=49831
LUT as Memory=16638
BRAM Tile=63, URAM=8, DSP=184
bit SHA256=3DC26E405921DCF04057CFFC8E8997D0A3481D4EBFF9585551B34A26FE7D2FBE
XSA SHA256=258458C60231AE5D62CE1E4E0F9BB7D73C8F8043FEB2A0D440DF24C2ABC660AA
```

Board validation:

```text
batch-chain: 20260615_230847_conv0_conv9_batch_chain_COM8.log
DDR image0:  20260615_231105_conv0_conv9_ddr_demo_COM8.log
DDR image1:  20260615_231547_conv0_conv9_ddr_demo_COM8.log
```

Both DDR images pass detection. The selected Conv5/Conv6/Conv8 tile0 traces are
valid for `cout_block=0`, `k_pass=0`. The trace-enabled ELF prints many
`TILEPERF` lines, so its wall-clock `total_us` is inflated by UART output; use
hardware counters and `PASSPERF`/`PASSTRACE` for diagnosis rather than treating
that run as a speed baseline.

## 2026-06-15 column-level PSUM trace

The targeted column trace reuses the selected `PASSTRACE` pass and exposes one
column at a time:

```text
0x1b8 COLTRACE_CTRL               bit31 valid, [4:0] selected column
0x1bc COLTRACE_FIRST_WR
0x1c0 COLTRACE_LAST_WR
0x1c4 COLTRACE_WR_COUNT
0x1c8 COLTRACE_EMPTY_WAIT
0x1cc COLTRACE_MISSING_MASK_OR
0x1d0 COLTRACE_MISSING_MASK_FIRST
0x1d4 COLTRACE_MISSING_MASK_LAST
0x1d8 COLTRACE_VERSION
```

The runtime prints:

```text
COLTRACE layer=... tile=... cout_block=... k_pass=... col=...
         first_wr=... last_wr=... wr_count=... empty_wait=...
         missing_or=... missing_first=... missing_last=...
         version=... valid=...
```

Vivado/xsim `2022.2` passes Conv5/Conv6/Conv8 tile0 with this trace enabled.
For the selected 52-pixel pass, every column produces 52 consecutive writes.
Column start times are separated by four cycles and empty-wait rises from 99
cycles on column 0 to 127 cycles on column 7. This is deterministic systolic
column propagation, not random FIFO starvation or a slow collector write path.

No collector-only phase compensation is planned: a full packet still requires
the last column. The next low-risk experiment is a larger raw-HWC spatial tile
for Conv5/Conv8; Conv6 already fills the current cache and needs a per-column
partial-PSUM streaming redesign or a larger cache for further improvement.

## Backend full-tile HWC cache experiment

`-BackendFullTile` is an experimental Vitis/runtime switch for the enlarged
materialized 3x3 raw-HWC cache build. It keeps the existing stream formats and
raw-HWC cache semantics, but schedules Conv5, Conv6, and Conv8 as one 13x13
spatial tile instead of `4,4,4,1`.

The matching hardware build must use:

```text
HWC_CACHE_AW=16
HWC_CACHE_DEPTH=43264
HWC_CACHE_STRIPES=4
HWC_CACHE_USE_URAM=1
```

Capacity:

```text
Conv5/8: 13*13*ceil(256/2) = 21632 materialized words
Conv6:   13*13*ceil(512/2) = 43264 materialized words
```

Build the DDR demo variant with:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 `
  -Mode conv0_conv9_ddr_demo `
  -RawHwcConv5 -RawHwcConv6 -RawHwcConv8 `
  -EarlyDrain -PassPrefetch -PsumStreamOverlap -ContinuousPsum `
  -BackendFullTile -TailCyclesOverride 1
```

The batch-chain mode accepts the same switches. Variant aliases use short tags
to avoid Windows path-length failures. The generated DDR demo alias is:

```text
conv_accel_conv0_conv9_ddr_demo_rhwc_c5_c6_c8_ed_pf_pso_cps_full_smoke.elf
```

The image demo script also forwards the same switches to the build/run scripts,
for example:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/run_kv260_image_demo.ps1 `
  -Image D:\MPSoC\python_prj\facemask\images\maksssksksss0.png `
  -BuildDirName D:\MPSoC\b_hwcfulltile_22 `
  -RawHwcConv5 -RawHwcConv6 -RawHwcConv8 `
  -EarlyDrain -PassPrefetch -PsumStreamOverlap -ContinuousPsum `
  -BackendFullTile -TailCyclesOverride 1
```

Local validation completed before synthesis:

```text
Python tb/test_kv260_image_demo.py PASS
Vitis 2022.2 DDR full-tile ELF build PASS
xsim Conv5 full 13x13 raw-HWC tile PASS, 2726/0
xsim Conv6 full 13x13 raw-HWC tile PASS, 2726/0
xsim Conv8 full 13x13 raw-HWC tile PASS, 2726/0
```

The matching hardware implementation is:

```text
build dir: D:/MPSoC/b_hwcfulltile_22
Vivado:    2022.2
WNS=+0.177 ns, TNS=0, WHS=+0.009 ns, THS=0
routing errors=0
CLB LUTs=58903, CLB Registers=50915
LUT as Memory=16551
BRAM Tile=63, URAM=24, DSP=184
bit SHA256=633839A78242AAB9F5AA575B48C6A9A17FDE574944A4E5ED7640B88301ACE15F
XSA SHA256=AC2228EC28291BD4239AA887E529B2BEA6562A3E86CD322699CC5135F237E43D
```

Use full programming for the first board run; do not use `-FastRun` until this
bitstream has passed batch-chain once.

Board validation for `D:/MPSoC/b_hwcfulltile_22` is complete:

```text
batch-chain full programming:
  PASS, UART detections match decode golden count=1
  log=D:/MPSoC/b_hwcfulltile_22/board_smoke_logs/20260616_125655_conv0_conv9_batch_chain_COM8.log

DDR demo maksssksksss0.png:
  total=335.564 ms
  detection=with_mask score=0.357321
  log=D:/MPSoC/b_hwcfulltile_22/board_smoke_logs/20260616_125932_conv0_conv9_ddr_demo_COM8.log

DDR demo maksssksksss1.png:
  total=335.779 ms
  detection=with_mask score=0.295050
  log=D:/MPSoC/b_hwcfulltile_22/board_smoke_logs/20260616_130105_conv0_conv9_ddr_demo_COM8.log
```

This is about `35.6 ms` faster than the previous `~371.3 ms` baseline. The
remaining counters show that the backend full-tile cache reduced spatial tile
fixed overhead, but array utilization is still limited by pass-internal
feeder/compute/collector timing rather than by DDR transfer or software packing.

## During-compute next-pass prefetch

`-DuringComputePrefetch` is an experimental runtime/build switch. It defines
`ACCEL_DURING_COMPUTE_PREFETCH=1` and sets `STREAM_CFG[7]` for selected
raw-HWC layers. Default ELFs leave the bit clear.

The mode is intentionally conservative. While the current K pass is computing,
the scheduler may stage the next K pass weight stream and raw-HWC replay data
behind the active pass, but it does not overwrite active PE weights and does not
start the next compute early. The next compute still waits for the current-pass
dependency rules, including PSUM/collector conditions.

Build the experimental DDR demo with:

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 `
  -Mode conv0_conv9_ddr_demo `
  -RawHwcConv5 -RawHwcConv6 -RawHwcConv8 `
  -RawHwcComputeStartLevel 64 `
  -EarlyDrain -PassPrefetch -DuringComputePrefetch `
  -PsumStreamOverlap -ContinuousPsum -ColumnPsum `
  -BackendFullTile -TailCyclesOverride 1
```

Local validation before synthesis:

```text
Icarus selected scheduler/config regression PASS
xsim Conv5 full 13x13 raw-HWC tile PASS, 2726/0
xsim Conv6 full 13x13 raw-HWC tile PASS, 2726/0
xsim Conv8 full 13x13 raw-HWC tile PASS, 2726/0
```

The generated DDR demo alias for this command is:

```text
conv_accel_conv0_conv9_ddr_demo_rhwc_c5_c6_c8_ed_pf_dcpf_pso_cps_col_full_smoke.elf
```

The matching 2022.2 hardware implementation is:

```text
build dir: D:/MPSoC/b_kprefetch_22
WNS=+0.092 ns, TNS=0, WHS=+0.010 ns, THS=0
routing errors=0
CLB LUTs=84480, CLB Registers=53260
LUT as Memory=35502
BRAM Tile=63, URAM=24, DSP=184
bit SHA256=83219E2150352795B21DC52062FB74FAD3E55CE2DE3075BD3DBD8A71DA765D5A
XSA SHA256=BB36996E2AE900061779F82943CAA7D4D128B4A72A80D801E14D03D05294CA63
```

The next meaningful check is a same-schedule board A/B against the current
`b_hwcfulltile_colpsum_22` baseline. Acceptance should focus on whether Conv6
`compute_idle` and total DDR demo latency drop; if the gain is below about
`10 ms`, the remaining bubble is more likely raw-HWC replay throughput or a
deeper compute-stage boundary rather than late next-pass staging.

Board validation for `D:/MPSoC/b_kprefetch_22` is complete:

```text
batch-chain full programming:
  PASS, UART detections match decode golden count=1
  log=D:/MPSoC/b_kprefetch_22/board_smoke_logs/20260616_193348_conv0_conv9_batch_chain_COM8.log

DDR demo maksssksksss0.png:
  total=288.002 ms
  detection=with_mask score=0.357321
  log=D:/MPSoC/b_kprefetch_22/board_smoke_logs/20260616_193623_conv0_conv9_ddr_demo_COM8.log

DDR demo maksssksksss1.png:
  total=287.993 ms
  detection=with_mask score=0.295050
  log=D:/MPSoC/b_kprefetch_22/board_smoke_logs/20260616_193752_conv0_conv9_ddr_demo_COM8.log
```

This saves about `42.8 ms` versus the previous `~330.8 ms` baseline. The new
cycle-bound summary is:

```text
HW busy=247.184 ms
compute_fire=74.323 ms, util=30.07%
feeder=99.913 ms
compute_stage=121.022 ms
compute_idle=46.699 ms
drain=16.467 ms
```

`PREFETCHPERF hit=24448, miss=0`, `PSUMOVLPERF underflow=0`, and
`COLLECTPERF context_full_stall=0`. The remaining opportunity is no longer late
next-pass staging alone; it is split between backend replay/compute idle and
front-end feeder/fill time.

### Conv3 Raw-HWC Large-Tile Experiment

`-RawHwcConv3` was added as an opt-in experiment for the same
`D:/MPSoC/b_kprefetch_22` bitstream. The current cache can hold a Conv3
materialized tile, but during-compute prefetch also needs the next pass vectors
to fit in the IFM FIFO. A `26`-row Conv3 tile has `52*26=1352` vectors and
deadlocks with `IFM_FIFO_DEPTH=1024`, so the software schedule uses
`18/18/16` rows (`52*18=936` vectors max).

Functional result:

```text
batch-chain with RawHwcConv3/4/5/6/8: PASS
DDR maksssksksss0.png: PASS, 286.653 ms
DDR maksssksksss1.png: PASS, 286.646 ms
```

This is slower than the validated RawHwcConv4/5/6/8 configuration
(`282.951 ms`). Keep `-RawHwcConv3` as a diagnostic switch; it is not the
recommended runtime setting.

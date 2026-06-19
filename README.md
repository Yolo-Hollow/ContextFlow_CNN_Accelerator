# KV260 Systolic YOLOv3-tiny Accelerator

This repository contains a Verilog RTL accelerator, bare-metal Vitis software,
testbenches, scripts, and the final handoff hardware artifacts for a simplified
single-scale YOLOv3-tiny face-mask detection flow on the AMD/Xilinx KV260.

## Current Handoff Baseline

The handoff mainline is the stable raw-HWC replay design used by:

```text
D:/MPSoC/b_hwcreplay_22
```

Measured board result on the fixed DDR image demo:

```text
total latency ~= 280.340 ms
detection     = with_mask, score 0.357321
toolchain     = Vivado/Vitis 2022.2
target        = KV260 / xck26-sfvc784-2LV-c
```

The later IFM ping-pong / double-staging experiments are intentionally not part
of the default mainline because board validation did not converge. They are kept
on branch `experiment-ifm-pingpong-debug-current` for reference.

## Repository Layout

```text
cal/                     DSP/int8 multiplier helpers
com/                     common RTL helpers
systolic/                accelerator RTL
tb/                      Verilog and Python regression tests
tcl/                     Vivado/xsim build and simulation scripts
sw/vitis_2022_2/         bare-metal runtime, scheduler, and board scripts
tools/                   golden-data, UART log, and demo analysis tools
docs/                    design notes, dataflow/register docs, test plans
golden/                  policy for curated golden data
release/kv260_hwcreplay_22/
                         final XSA and bitstream for handoff
2022_Peking_University_Master_Thesis_Template_iofu728_pkuthss_/
                         thesis source and latest PDF
```

## Final Hardware Artifacts

The final handoff artifacts are tracked under:

```text
release/kv260_hwcreplay_22/conv_accel_ps_dma_minimal.xsa
release/kv260_hwcreplay_22/conv_accel_ps_dma_wrapper.bit
```

SHA256:

```text
conv_accel_ps_dma_minimal.xsa
  5CCDCDB264ED9F7F29531C08108617547CA88E7C5F9A4A4A089C6A1D74FF9753

conv_accel_ps_dma_wrapper.bit
  C9CBC381F7906B5ECF206C7CA256276FE30943EAE5A22D0573D1FA244F8EC3D8
```

The default build scripts are configured for the same stable hardware profile:

```text
ROWS=18
COLS=8
COUT_TILE=16
IFM_BANKS=2
HWC_CACHE_AW=16
HWC_CACHE_DEPTH=43264
HWC_CACHE_STRIPES=4
HWC_CACHE_USE_URAM=1
TAIL_CYCLES=1
```

## Build

Use Vivado 2022.2 explicitly:

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' `
  -mode batch `
  -source tcl\build_kv260_system_xck26.tcl `
  -tclargs -build_dir D:/MPSoC/build_repro_hwcreplay_22 -jobs 12
```

The generated XSA can then be used by the Vitis 2022.2 software flow in
`sw/vitis_2022_2/`.

## Software and Board Smoke Tests

Build the main single-scale DDR demo ELF:

```powershell
powershell -ExecutionPolicy Bypass `
  -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 `
  -Mode conv0_conv9_ddr_demo
```

Run the fixed-image DDR demo on the board:

```powershell
powershell -ExecutionPolicy Bypass `
  -File sw/vitis_2022_2/scripts/run_kv260_image_demo.ps1 `
  -Image D:\MPSoC\python_prj\facemask\images\maksssksksss0.png `
  -PortName COM8 `
  -BuildDirName D:\MPSoC\b_hwcreplay_22 `
  -CaptureSeconds 240
```

Run the RTL-golden batch-chain smoke:

```powershell
powershell -ExecutionPolicy Bypass `
  -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 `
  -PortName COM8 `
  -BuildDirName D:\MPSoC\b_hwcreplay_22 `
  -RunConv0Conv9BatchChain `
  -CaptureSeconds 240
```

## RTL Simulation

Run the short xsim regression:

```powershell
powershell -ExecutionPolicy Bypass -File tb/run_short_xsim_regression.ps1
```

Run a targeted xsim test:

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' `
  -mode batch `
  -source tcl\run_xsim_regression.tcl `
  -tclargs -top tb_conv_accel_core_axi_lite_axis_stream_conv6_3x3_raw_hwc_fulltile_cout16
```

Many real-data tests depend on external golden data under
`D:/MPSoC/python_prj/rtl_golden/`. The repository keeps generation scripts under
`tools/golden/`, but does not track the full dataset, model weights, or large
golden dumps.

## Thesis PDF

The latest thesis PDF is:

```text
2022_Peking_University_Master_Thesis_Template_iofu728_pkuthss_/main.pdf
```

## Notes for Future Work

The current stable design already includes raw-HWC replay, pass prefetch,
PSUM overlap, column PSUM, and a large URAM HWC cache. The main remaining gap is
that the measured `compute_fire` time is still much lower than total PL busy
time. Future optimization should focus on structurally reducing K-pass boundary
overhead rather than re-enabling the unsafe IFM ping-pong/during-compute
prefetch experiments directly.

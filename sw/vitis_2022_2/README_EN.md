# ContextFlow Vitis 2022.2 Runtime

**Language / 语言: [中文](README.md) | English**

This directory contains the A53 bare-metal runtime, project generators, JTAG launchers, and SD cold-boot support for KV260/XCK26. The current contract is ABI v2 with `ROWS=18`, `COLS=16`, and `COUT_TILE=32`, including raw-HWC IFM, packed-HWC OFM, layer-long DMA, and epoch-tagged context control.

The release hardware is under `release/contextflow_34p9/` and identifies the 200 MHz `abi_v2_release_200` build. Launchers verify the SHA-256 identities of the bitstream, XSA, ELF, and runner manifest and reject mismatched combinations.

## Layout

```text
src/                    Bare-metal runtime, network execution, and platform code
scripts/                Project generation, runner builds, JTAG launch, and signoff
boot/coco80_el1/        QSPI/U-Boot SD cold-boot packaging and helpers
```

## Environment

```powershell
conda activate pytorch_env
& 'C:\Xilinx\Vitis\2022.2\bin\xsct.bat' -version
& 'C:\Xilinx\Vivado\2022.2\bin\hw_server.bat'
```

The default installations are `C:\Xilinx\Vitis\2022.2` and `C:\Xilinx\Vivado\2022.2`. JTAG flows require `hw_server` on TCP 3121. UART capture scripts require an explicit host-specific COM port.

## JTAG network runner

Create an EL3 platform for the persistent JTAG-started service:

```powershell
& 'C:\Xilinx\Vitis\2022.2\bin\xsct.bat' `
  sw\vitis_2022_2\scripts\create_coco80_net_project.tcl `
  -workspace <fresh-network-workspace> `
  -xsa release\contextflow_34p9\conv_accel_ps_dma_minimal.xsa `
  -execution-level el3
```

Build the runner with `build_coco80_net_runner.ps1`, supplying the hardware, parameter package, quantization manifest, and FP32/INT8 evaluation summaries. Use PowerShell help for its complete parameter list:

```powershell
Get-Help sw\vitis_2022_2\scripts\build_coco80_net_runner.ps1 -Detailed
```

Then download and run the hash-bound bitstream and ELF:

```powershell
powershell -ExecutionPolicy Bypass -File `
  sw\vitis_2022_2\scripts\run_coco80_net_board.ps1 `
  -Workspace <fresh-network-workspace> `
  -RunnerManifest <coco80_r5_ethernet.manifest.json> `
  -BitFile release\contextflow_34p9\conv_accel_ps_dma_wrapper.bit
```

The service listens on `192.168.10.2:5001` by default. A model that does not satisfy the release accuracy gate requires the explicit `-AllowNonReleaseDeployment` integration path, and its manifest remains `release_eligible=false`.

## SD filesystem runner

Create the standalone platform with `xilffs`:

```powershell
& 'C:\Xilinx\Vitis\2022.2\bin\xsct.bat' `
  sw\vitis_2022_2\scripts\create_coco80_sd_project.tcl `
  -workspace <fresh-sd-workspace> `
  -xsa release\contextflow_34p9\conv_accel_ps_dma_minimal.xsa
```

Use `build_coco80_sd_runner.ps1` to build an `accuracy`, `product`, `performance`, or `conformance` runner. A prepared card can first be exercised through JTAG with `run_coco80_sd_board.ps1`. See the [COCO80 deployment guide](../../tools/coco80/README_EN.md) for card preparation and data binding.

## SD power-on cold boot

Create the network platform with `-execution-level el1`, build the EL1 runner, and package it:

```powershell
powershell -ExecutionPolicy Bypass -File `
  sw\vitis_2022_2\boot\coco80_el1\package_sd_boot.ps1 `
  -BuildDirectory <EL1-network-build> `
  -BitFile release\contextflow_34p9\conv_accel_ps_dma_wrapper.bit `
  -OutputDirectory <sd-boot-package> `
  -Python (Get-Command python).Source
```

Copy the generated contents to the FAT boot partition. KV260 QSPI U-Boot chain-loads the bitstream and EL1 application. PL and GEM DMA remain non-coherent and use explicit cache maintenance.

## ABI v2 signoff entry points

```text
scripts/build_abi_v2_candidate.ps1
scripts/run_abi_v2_board_functional.ps1
scripts/run_abi_v2_board_signoff.ps1
scripts/run_abi_v2_board_performance_125.ps1
scripts/run_abi_v2_board_soak.ps1
```

Formal 200 MHz functional qualification runs `0x2B -> 0x3B -> 0x3F -> 0xBF` with separately bound workspaces and ELFs. Performance uses `0xBF`; soak checks DMA, protocol, counter, timeout, and thermal conditions continuously.

Run host-side software tests with:

```powershell
powershell -ExecutionPolicy Bypass -File tb\run_sw_host_tests.ps1
```

See the repository [Quick Start and Reproduction](../../README_EN.md#quick-start-and-reproduction) for the shortest complete board flow.

# ContextFlow: A Replay-Enabled Context-Pipelined Accelerator for Quantized CNNs

**Language / 语言: [中文](README.md) | English**

ContextFlow is a complete INT8 CNN inference system for the AMD/Xilinx Kria KV260 (XCK26). It uses a fixed `18x16` dual-output systolic array and addresses two system-level costs of folded convolution: repeated transfer of the same HWC input across output-channel blocks and idle bubbles between adjacent folded execution contexts.

The current 200 MHz release runs the complete dual-scale YOLOv3-tiny network with a measured resident mean latency of **34.943 ms**, **28.618 FPS**, **165.588 effective GOPS** in PL, and **71.87%** array utilization.

Latest preprint: [ContexFlow_preprint_thesis.pdf](output/pdf/ContexFlow_preprint_thesis.pdf)

## Core Ideas

A fixed-size array executes a long-reduction convolution as multiple reduction passes `p` and output-channel blocks `q`. ContextFlow reorganizes this folded sequence in space and time.

### 1. On-chip vector generation and cross-output-block replay

- Each compact spatial HWC tile is read from DDR once.
- A kernel-adaptive router directly packs `1x1` inputs or gathers nine taps for `3x3` inputs.
- Every reduction pass produces an array-ready 18-element vector and writes it into an on-chip vector bank indexed by `p`.
- The same `V[p]` sequence is replayed across output-channel blocks `q`; only the selected weight block `W[q]` changes.
- The vector cache is released or overwritten only after the final reader, preserving input reuse on chip.

### 2. Context pipelining for folded execution

- One `(layer, tile, q, p)` folded execution is treated as a context.
- Prepare, Execute, and Retire cover input/weight preparation, array computation, and PSUM or final-result commitment.
- Preparation of the next context, computation of the current context, and retirement of the previous context overlap on independent paths.
- Dual-bank weight storage, packet-level PSUM feedback, credit flow control, and resource-ownership checks support direct handoff.
- When the input vector, weight, PSUM, and destination identity are ready, array ownership transfers without a global idle cycle.

## Hardware/Software System

```text
DDR: compact HWC IFM / weights / bias
        |
        v
ARM Cortex-A53 bare-metal runtime
  descriptors / DMA / cache maintenance / network control
        |
        v
IFM DMA + Weight DMA + Bias DMA
        |
        v
ContextFlow PL
  HWC materializer -> vector banks -> replay selector
                   -> 18x16 systolic array
                   -> PSUM feedback / requant / activation / pooling
        |
        v
OFM DMA -> DDR feature buffers -> dual-scale YOLO decode
```

The PS manages network descriptors, four DMA channels, inter-layer tensors, and detection post-processing. The PL performs HWC vector generation, weight preparation, array execution, PSUM handling, requantization, activation, pooling, and output organization. The complete network contains 13 PL convolution layers; pooling, nearest-neighbor upsampling, concatenation, and branch connections are coordinated by the PS.

## Current Release Results

### Performance

| Metric | Result |
| --- | ---: |
| Platform / clock | XCK26/KV260 / 200 MHz |
| Resident mean latency | **34.943 ms** |
| Resident P95 | **34.965 ms** |
| Throughput | **28.618 FPS** |
| PL mean latency | **33.607 ms** |
| Effective throughput | **165.588 GOPS** |
| Array utilization | **71.87%** |
| Sample | 3 independent runs, each with 20 warmups + 1000 timed images |

The final controlled-ablation stage reports `34.978 ms`; it has a different measurement scope and must not replace the complete resident mean above. The ablation also shows that on-chip vector generation and replay reduces IFM DMA traffic by **19.67x** and provides a **2.020x** resident-inference speedup over the serialized baseline.

### Model accuracy

| Model | COCO val2017 images | AP / AP50 |
| --- | ---: | ---: |
| FP32-416 | 5000 | 17.494% / 33.493% |
| INT8-416 | 5000 | 14.304% / 30.212% |

### Correctness and stability

- 2,816 integer-node records from 128 images and 22 nodes match the reference implementation byte for byte.
- Board execution of the complete network on 5000 COCO val2017 images matches the offline product path at the metric level.
- The 3000 timed images have zero output CRC mismatches.
- A ten-minute soak test passes with 13,184 records, zero protocol errors, and zero unexpected reconnects.

### Board inference examples

These results were produced by the complete INT8 dual-scale YOLOv3-tiny network running on the KV260 with the demo threshold `confidence=0.25`. They illustrate board inference in a crowded scene, a dense same-class scene, and a multi-class scene; the COCO val2017 table above remains the authoritative accuracy result.

| Crowded scene (COCO 36494) | Dense same-class scene (COCO 148957) | Multi-class scene (COCO 41872) |
| :---: | :---: | :---: |
| ![KV260 crowded-scene board detection](docs/assets/results/board_demo_000000036494.jpg) | ![KV260 donut board detection](docs/assets/results/board_demo_000000148957.jpg) | ![KV260 multi-class board detection](docs/assets/results/board_demo_000000041872.jpg) |

### Implementation cost

| Resource or timing metric | Result |
| --- | ---: |
| LUTs | 56,949 |
| DSPs | 650 (576 in the array) |
| BRAMs | 94 |
| URAMs | 48 |
| WNS / TNS | +0.004 ns / 0 ns |
| Post-route tool-estimated on-chip power | 4.008 W |

Canonical measurements and hashes are recorded in the [34.9 ms release manifest](docs/contextflow_34p9_release_manifest_EN.md) and the [machine-readable evidence snapshot](paper/lasa_journal_cn/data/evidence_snapshot.json). Power is a post-route vectorless tool estimate, not a board power measurement.

## Repository Structure

```text
.
├── cal/                              DSP and INT8 MAC primitives
├── com/                              Common RTL pipeline modules
├── systolic/                         Array, vector replay, PSUM, and context-pipeline RTL
├── sw/
│   └── vitis_2022_2/
│       ├── src/                      KV260 bare-metal inference runtime
│       ├── scripts/                  Project generation, deployment, and board scripts
│       └── boot/coco80_el1/          EL1/SD cold-boot support
├── tb/                               RTL, software, and end-to-end regression tests
├── tcl/                              Vivado build, implementation, and signoff scripts
├── tools/
│   ├── coco80/                       Quantization, dataset, deployment, and evaluation
│   ├── demo/                         Board functional and performance demos
│   ├── golden/                       Scheduling and integer-semantic reference models
│   └── power/                        Power-report parsing
├── repro/                            Reproduction entry points and compact data packages
├── docs/                             Release manifest, implementation, and evidence docs
│   └── assets/results/               Board inference examples used by the README
├── paper/
│   └── lasa_journal_cn/              Frozen experimental data and publication evidence
├── release/
│   └── contextflow_34p9/             34.943 ms XSA, bitstream, and checksums
└── output/
    └── pdf/
        └── ContexFlow_preprint_thesis.pdf   Current preprint
```

## Environment

- Windows 10/11 and PowerShell 5 or later
- AMD/Xilinx Vivado 2022.2
- AMD/Xilinx Vitis 2022.2
- Conda environment `pytorch_env`
- Kria KV260, JTAG, and UART; network deployment also requires Ethernet

```powershell
conda activate pytorch_env
python --version
```

Default tool locations:

```text
C:\Xilinx\Vivado\2022.2
C:\Xilinx\Vitis\2022.2
```

> **Path substitution:** `C:\Xilinx\...` denotes the default tool installation and `E:\COCO80_R5` is an example SD-card drive. Replace them with the actual absolute paths or drive letter on your host. Angle-bracket values such as `<workspace>` and `<quantization_manifest.json>` are placeholders; replace the complete value and remove the brackets before running a command. Relative paths such as `release\...` and `tools\...` assume the repository root as the working directory.

## Quick Start and Reproduction

Run the commands below from the repository root. Activate `pytorch_env` and verify the bundled hardware artifacts first:

```powershell
conda activate pytorch_env
Get-FileHash release\contextflow_34p9\conv_accel_ps_dma_minimal.xsa -Algorithm SHA256
Get-FileHash release\contextflow_34p9\conv_accel_ps_dma_wrapper.bit -Algorithm SHA256
```

The expected SHA-256 values are `42d761b1cc77f1a7988d40dd71f0a1c7e1987a057bc457c7d5b55613637e3030` and `1ac606a279d60290935f32c5bc1a028b017d6cca4f22e623bd0bbb4baa3a613e`, respectively.

### JTAG startup

Start Vivado `hw_server`, then create an EL3 network platform from the bundled XSA. Use a fresh Vitis directory for `<workspace>`:

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\hw_server.bat'

& 'C:\Xilinx\Vitis\2022.2\bin\xsct.bat' `
  sw\vitis_2022_2\scripts\create_coco80_net_project.tcl `
  -workspace <workspace> `
  -xsa release\contextflow_34p9\conv_accel_ps_dma_minimal.xsa `
  -execution-level el3
```

Build the network runner as described in the [COCO80 tooling guide](tools/coco80/README_EN.md), then download the bitstream and ELF over JTAG and keep the board service running:

```powershell
powershell -ExecutionPolicy Bypass -File `
  sw\vitis_2022_2\scripts\run_coco80_net_board.ps1 `
  -Workspace <workspace> `
  -RunnerManifest <coco80_r5_ethernet.manifest.json> `
  -BitFile release\contextflow_34p9\conv_accel_ps_dma_wrapper.bit
```

The board listens on `192.168.10.2:5001`. Configure the host adapter as `192.168.10.1/24` and confirm the link with `ping 192.168.10.2`.

### SD-card cold boot

Use a card of at least 16 GB. The following commands populate the `COCO80_R5` data directory; they do not format the card. Replace `E:` with the mounted drive:

```powershell
python -m tools.coco80.sd_deploy prepare-card `
  --card E:\COCO80_R5 `
  --bit release\contextflow_34p9\conv_accel_ps_dma_wrapper.bit `
  --xsa release\contextflow_34p9\conv_accel_ps_dma_minimal.xsa `
  --source-root .

python -m tools.coco80.sd_deploy install `
  --card E:\COCO80_R5 `
  --parameter-package <coco80_parameters.c8pa> `
  --quantization-manifest <quantization_manifest.json>

python -m tools.coco80.sd_deploy verify --card E:\COCO80_R5
```

A true power-on boot also needs an EL1 network runner and boot package. After building the EL1 runner, run:

```powershell
powershell -ExecutionPolicy Bypass -File `
  sw\vitis_2022_2\boot\coco80_el1\package_sd_boot.ps1 `
  -BuildDirectory <EL1-network-build> `
  -BitFile release\contextflow_34p9\conv_accel_ps_dma_wrapper.bit `
  -OutputDirectory <sd-boot-package> `
  -Python (Get-Command python).Source
```

Copy the package contents to the FAT boot partition. KV260 QSPI U-Boot then loads the bitstream and EL1 application. See the [SD deployment guide](tools/coco80/README_EN.md) and [Vitis runtime guide](sw/vitis_2022_2/README_EN.md) for the complete directory layout, input registration, and boot checks.

### WebUI inference test

Start the Ethernet board service through JTAG or SD boot, then run on the host:

```powershell
powershell -ExecutionPolicy Bypass -File tools\coco80\run_inference_app.ps1 `
  -RunnerManifest <coco80_r5_ethernet.manifest.json> `
  -QuantizationManifest <quantization_manifest.json> `
  -OpenBrowser
```

The browser opens `http://127.0.0.1:8088/` by default. The WebUI sends images to the KV260 for complete INT8 inference and records inputs, raw outputs, detections, and run metadata; it does not silently fall back to host inference. See the [WebUI inference guide](tools/coco80/INFERENCE_APP_EN.md).

## Build and Verification

### RTL regression

XSIM is the authoritative RTL regression and signoff simulator:

```powershell
powershell -ExecutionPolicy Bypass -File tb/run_short_xsim_regression.ps1
powershell -ExecutionPolicy Bypass -File tb/run_all_xsim_regression.ps1
```

Full-layer tests, randomized AXIS backpressure, and the `18x16` packed-OFM path are driven by `tb/run_large_xsim_regression.ps1` and `tcl/run_xsim_regression.tcl`. Icarus remains a lightweight module smoke tool and is not a release gate.

### 200 MHz KV260 hardware

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\build_kv260_system_xck26.tcl -tclargs `
  -profile abi_v2_release_200 -jobs 12
```

The profile derives the OOC clock, PS `pl_clk0`, accelerator `CLOCK_HZ`, and build metadata from one release identity. Lowering the clock, changing burst settings, or relaxing a release gate creates a different build and cannot replace the frozen result.

### Vitis runtime and board signoff

Primary entry points:

```text
sw/vitis_2022_2/scripts/build_abi_v2_candidate.ps1
sw/vitis_2022_2/scripts/run_abi_v2_board_functional.ps1
sw/vitis_2022_2/scripts/run_abi_v2_board_performance_125.ps1
sw/vitis_2022_2/scripts/run_abi_v2_board_soak.ps1
sw/vitis_2022_2/scripts/run_coco80_net_board.ps1
sw/vitis_2022_2/scripts/run_coco80_sd_board.ps1
```

See the [COCO80 tooling guide](tools/coco80/README_EN.md) for preparation, quantization, network protocol, and evaluation; the [Vitis runtime guide](sw/vitis_2022_2/README_EN.md) for the bare-metal project and board flow; and the [Vivado/XSIM guide](tcl/README_EN.md) for build profiles and signoff gates.

## Upstream and Attribution

The early model and deployment flow refer to [adamgallas/fpga_accelerator_yolov3tiny](https://github.com/adamgallas/fpga_accelerator_yolov3tiny). The files `cal/cal_mul_int8_x2.v` and `cal/cal_mul_int8_x2_dsp.v` derive from that Apache-2.0 project's dual-INT8 DSP multiplication design. Beyond those identified modules, this repository redesigns the KV260/XCK26 array, HWC vector generation/replay, folded context pipeline, PSUM management, DMA/Vitis runtime, and full verification flow. Please preserve the repository and upstream license and citation requirements when using or redistributing the project.

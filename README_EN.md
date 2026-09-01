# ContextFlow: A Replay-Enabled Context-Pipelined Accelerator for Quantized CNNs

**Language / 语言: English | [中文](README.md)**

ContextFlow is a complete INT8 CNN inference system for the AMD/Xilinx Kria KV260 (XCK26). It uses a fixed `18x16` dual-output systolic array and addresses two system-level costs of folded convolution: repeated transfer of the same HWC input across output-channel blocks and idle bubbles between adjacent folded execution contexts.

The current 200 MHz release runs the complete dual-scale YOLOv3-tiny network with a measured resident mean latency of **34.943 ms**, **28.618 FPS**, **165.588 effective GOPS** in PL, and **71.87%** array utilization.

Latest preprint: [ContexFlow_preprint_thesis.pdf](output/pdf/ContexFlow_preprint_thesis.pdf)

> The final preprint PDF is tracked as a standalone artifact. Its LaTeX authoring project and local build directory are intentionally excluded from the release commits.

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

### Implementation cost

| Resource or timing metric | Result |
| --- | ---: |
| LUTs | 56,949 |
| DSPs | 650 (576 in the array) |
| BRAMs | 94 |
| URAMs | 48 |
| WNS / TNS | +0.004 ns / 0 ns |
| Post-route tool-estimated on-chip power | 4.008 W |

Canonical measurements and hashes are recorded in the [34.9 ms release manifest](docs/contextflow_34p9_release_manifest.md) and the [machine-readable evidence snapshot](paper/lasa_journal_cn/data/evidence_snapshot.json). Power is a post-route vectorless tool estimate, not a board power measurement.

## Repository Structure

```text
cal/                     DSP and INT8 MAC primitives
com/                     Common RTL pipeline modules
systolic/                Array, vector replay, PSUM, and context-pipeline RTL
sw/vitis_2022_2/
  src/                   KV260 bare-metal inference runtime
  scripts/               Project generation, deployment, board, and measurement scripts
  boot/coco80_el1/       EL1/SD boot support
tb/                      RTL, software, and end-to-end regression tests
tcl/                     Vivado project, synthesis, implementation, and signoff scripts
tools/
  coco80/                Quantization, dataset, deployment, protocol, and evaluation tools
  demo/                  Board functional and performance demos
  golden/                Scheduling and integer-semantic reference models
  power/                 Power-report parsing
repro/                   Reproducibility entry points and compact data packages
docs/                    Release manifest, implementation notes, and evidence boundaries
paper/lasa_journal_cn/   Frozen experimental data, tables, and publication evidence
release/                 Historical hardware handoff; not the current 34.943 ms design
output/pdf/
  ContexFlow_preprint_thesis.pdf
                         Current preprint; only the final PDF is tracked
```

The core release content is split into reviewable commit groups: RTL, software runtime, reproducibility/board evidence, the frozen 34.9 ms documentation, and the standalone preprint PDF. Vivado/Vitis build directories, `tmp/`, local result captures, the LaTeX authoring project, and historical PDF previews are excluded.

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

## Build and Verification Entry Points

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

See [tools/coco80/README.md](tools/coco80/README.md) for COCO80 preparation, quantization, network protocol, and evaluation; [sw/vitis_2022_2/README.md](sw/vitis_2022_2/README.md) for the bare-metal project and board flow; and [tcl/README.md](tcl/README.md) for Vivado profiles and signoff gates.

## Release Boundaries

- This branch contains reviewable RTL, software, tests, scripts, evidence summaries, and the preprint.
- The frozen XSA and bitstream are identified by SHA-256 but are not bundled because of artifact size and delivery policy.
- `release/kv260_hwcreplay_22/` is a historical approximately 280.340 ms raw-HWC replay handoff, not the 34.943 ms ContextFlow hardware.
- The `paper/contextflow_journal_cn/` LaTeX project and its `build/` directory are excluded; only the final preprint PDF is tracked.
- INT8 accuracy is approximately 3.19 AP points below FP32. The repository reports this result directly and does not claim zero accuracy loss.

## Upstream and Attribution

The early model and deployment flow refer to [adamgallas/fpga_accelerator_yolov3tiny](https://github.com/adamgallas/fpga_accelerator_yolov3tiny). The files `cal/cal_mul_int8_x2.v` and `cal/cal_mul_int8_x2_dsp.v` derive from that Apache-2.0 project's dual-INT8 DSP multiplication design. Beyond those identified modules, this repository redesigns the KV260/XCK26 array, HWC vector generation/replay, folded context pipeline, PSUM management, DMA/Vitis runtime, and full verification flow. Please preserve the repository and upstream license and citation requirements when using or redistributing the project.

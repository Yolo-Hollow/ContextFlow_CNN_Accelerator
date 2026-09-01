# Vivado/XSIM Build and Verification Infrastructure

**Language / 语言: [中文](README.md) | English**

This directory provides the ContextFlow RTL manifest, XSIM regressions, XCK26 OOC synthesis, KV260 Block Design generation, complete implementation, and signoff gates. The current release profile is the 200 MHz `abi_v2_release_200` configuration: an 18x16 array, 32-channel output block, tagged context, URAM IFM epoch banks, 256-entry result FIFOs, and `STREAM_CFG=0xBF`.

> **Path substitution:** `C:\Xilinx\Vivado\2022.2` in the commands is the default installation. If Vivado is installed elsewhere, replace it with the actual absolute path to `vivado.bat`. Relative `tcl\...` and `tb\...` paths assume the repository root as the working directory.

## Tool and source contracts

- Formal simulation, synthesis, and implementation use Vivado/XSIM 2022.2.
- `rtl_sources.tcl` is the authoritative manifest for RTL under `cal/`, `com/`, and `systolic/`; missing, duplicate, or unregistered sources fail closed.
- `run_xsim_regression.tcl` defines component tests, while `run_abi_v2_chain_xsim.tcl` is the ten-layer ABI v2 system gate.
- Regression reports record the start/end Git identities and dirty state. Source changes during a run prevent canonical publication.

## RTL regression

```powershell
powershell -ExecutionPolicy Bypass -File tb\run_short_xsim_regression.ps1
powershell -ExecutionPolicy Bypass -File tb\run_all_xsim_regression.ps1
powershell -ExecutionPolicy Bypass -File tb\run_large_xsim_regression.ps1
```

Only a complete no-wave run from a clean commit can update canonical JSON/JUnit results. Targeted, wave-enabled, interrupted, and failed runs remain isolated.

## Build profiles

### `abi_v2_release_200`

This profile locks the XCK26/KV260 target and BD topology, 200 MHz OOC and PS clocks, 18x16/COUT32 layer-long packed-HWC path, tagged context, 48 URAMs, 256-entry result FIFOs, weight-DMA MM2S burst length 64, and all OOC/post-place/post-route resource, timing, congestion, route, and DRC gates.

Command-line options cannot weaken the profile; numerical thresholds may only be tightened. The release profile rejects `-no_gates`, `-reuse_synth`, and build paths under `release/` or source subdirectories.

### `abi_v2_release`

This is the corresponding 100 MHz ABI v2 configuration for lower-frequency verification. It is not the hardware used for the 34.943 ms result.

## 200 MHz OOC synthesis

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\run_synth_xck26.tcl -tclargs `
  -profile abi_v2_release_200 -ooc
```

The DCP and SHA-256 manifest are published only after the OOC gate passes, so a failed run cannot expose an older checkpoint as its output.

## Complete KV260 implementation

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\build_kv260_system_xck26.tcl -tclargs `
  -profile abi_v2_release_200 -jobs 12
```

The flow performs synthesis, placement, physical optimization, routing, timing/DRC gates, and export of the bitstream and bit-inclusive XSA. `-place_only` stops after the post-place resource/timing/congestion gate and does not export release hardware.

## Signoff coverage

The complete implementation checks LUT, LUT memory, CLB, BRAM, URAM, and DSP use; setup WNS/TNS; hold and pulse-width; accelerator-scoped unconstrained `(none)` endpoints; congestion, route errors, DRC errors and critical warnings; and artifact/profile/tool/Git provenance.

See [`release/contextflow_34p9/`](../release/contextflow_34p9/README_EN.md) for the frozen artifacts and the [release manifest](../docs/contextflow_34p9_release_manifest_EN.md) for canonical evidence.

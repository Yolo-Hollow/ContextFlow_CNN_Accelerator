# KV260 COCO80 upload inference app

This local web tool accepts a user image, creates the exact reduced-u8 C8IN
package, sends it to the persistent KV260 Ethernet runner, validates all
response CRCs and artifact bindings, and displays board detections plus the
extended per-image timing record.  It never falls back to host inference.

## 1. Start the persistent board service

Power on the KV260, connect JTAG and Ethernet, start `hw_server`, and download
the currently built r5 multicore Ethernet runner:

```powershell
& powershell -ExecutionPolicy Bypass -File `
  sw\vitis_2022_2\scripts\run_coco80_net_board.ps1 `
  -Workspace build_vitis_2022_2_coco80_r5_net `
  -RunnerManifest build_vitis_2022_2_coco80_r5_net\coco80_net_manual_build\coco80_r5_ethernet.manifest.json `
  -BitFile build_abi_v2_release_r5\conv_accel_ps_dma_minimal\conv_accel_ps_dma_minimal.runs\impl_1\conv_accel_ps_dma_wrapper.bit `
  -AllowNonReleaseDeployment
```

The board must listen on `192.168.10.2:5001`.  Configure the host Ethernet
adapter as `192.168.10.1/24` and verify `ping 192.168.10.2` first.

For a QSPI/U-Boot SD chain-load build, create the standalone workspace as
Non-Secure EL1 explicitly:

```powershell
& C:\Xilinx\Vitis\2022.2\bin\xsct.bat `
  sw\vitis_2022_2\scripts\create_coco80_net_project.tcl `
  -workspace build_vitis_2022_2_coco80_r5_net_el1 `
  -xsa build_abi_v2_release_r5\conv_accel_ps_dma_minimal.xsa `
  -execution-level el1
```

The EL1 cold-boot build deliberately enters the C runtime with the Xilinx
Outer Shareable DDR table.  After the firmware has enabled SMPEN, the runner
changes only isolated 2 MiB blocks covering the input chunks, parameter image,
and shared inference workspace to Inner Shareable.  Worker cores apply the
same workspace mapping before publishing ready.  This deferred mapping keeps
the QSPI/U-Boot chain-load path reliable while retaining the faster DMA and
four-core tensor-operator memory domains.
PL and GEM DMA remain non-coherent and use explicit cache maintenance.  Pass
`-ddr-shareability inner` only for diagnostic/JTAG work; it is not the SD
cold-boot default.

## 2. Start the web app

```powershell
& powershell -ExecutionPolicy Bypass -File tools\coco80\run_inference_app.ps1 -OpenBrowser
```

Open <http://127.0.0.1:8088/> if the browser is not opened automatically.
The defaults intentionally bind the current epoch1 parameter/quantization
package and the r5 200 MHz BIT/XSA.  Explicit path arguments can be supplied
to the PowerShell wrapper after another model has completed its own board
qualification.

## Modes and timing

- **Demo** uses board-side `confidence=0.25`, `IoU=0.45`, single-label NMS.
- **Accuracy** uses `confidence=0.001`, `IoU=0.65`, multi-label NMS; a higher
  local display threshold can keep the visualization readable.
- **Resident** is quantized input already in DDR through the complete 13-conv
  DAG and A53 detections.
- **PL** is the sum of the 13 accelerator dispatches.
- **A53** includes tensor operations and decode/NMS.
- **Network session** is host wall time and also includes the fail-closed
  HELLO/parameter transfer for this one-image session.  It is not a model
  latency measurement.

Every successful request is archived below
`results/coco80/inference_app/runs/<request-id>/`, including the uploaded
source, C8IN index/shard, raw board detection package, extended timing record,
visualization, result JSON, and SHA256 references.

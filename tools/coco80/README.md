# COCO80 YOLOv3-tiny on the r5 accelerator

This directory is the fail-closed host side of the full, dual-head COCO80
deployment. It does not modify the r5 RTL or bitstream. Large models, COCO
archives, generated quantization fixtures, SD images, and evaluation results
remain outside Git; every such artifact is bound by SHA256 manifests.

The canonical graph is `model_spec.json`. It contains thirteen PL convolution
dispatches. All max-pooling, the padded stride-one pool, nearest upsample,
route requantization/concat, and decode/NMS are A53 tensor operations. The
fixed PL tile heights are validated independently by `hardware_plan.py`.

## Reproducible order

1. Clone `ultralytics/yolov3` tag `v9.5.0` and verify commit
   `8eb4cde090022af73db12cfa725ec4bf01d49c0e`.
2. Download the v9.5.0 `yolov3-tiny.pt` asset and verify SHA256
   `74fb61c9593f563fc8c87a6d792cfe127632e402440acd9c142a396813946280`.
3. Download/extract COCO train2017, val2017, official annotations, and
   Ultralytics YOLO labels. Build `assets.json` with `make_asset_manifest.py`.
4. Build the deterministic 1024 calibration / 512 holdout split with seed
   `20260814` using `calibration.py`.
5. Freeze the 128-image board conformance set and its 16-image full-node
   golden subset with `conformance.py`; the selector covers all 80 classes and
   240 class/area strata plus empty, crowded, wide, tall, and square images.
6. Run `official640.py`, then the fixed-square FP32 baseline with
   `evaluate.py --mode fp32`.
7. Calibrate PTQ, export the canonical quant manifest and layer binaries,
   package them with `parameter_package.py`, and evaluate with
   `evaluate.py --mode ptq`.
8. Invoke `qat.py` only when the PTQ delta exceeds 1.0 AP50:95 point or
   2.0 AP50 points. QAT is capped at twenty epochs, uses no AMP, and retains
   the same frozen per-tensor hardware domains.
9. Generate SD images and run the persistent Vitis application. Compare the
   board integer nodes byte-for-byte with `ptq_runner.py` exact-mode goldens.

Accuracy always uses confidence 0.001, class-aware multi-label NMS IoU 0.65,
`max_nms=30000`, and `max_det=300`. The independent demo configuration uses
0.25/0.45 and is never accepted for mAP signoff.

## SD card contract

The bare-metal application mounts the first FAT volume and requires this
layout. Filenames and directory names are part of the on-card ABI.

```text
COCO80_R5/
  ARTIFACT/r5.bit
  ARTIFACT/r5.xsa
  PARAM/coco80_parameters.c8pa
  INPUT/input_index.bin
  INPUT/in_0000.bin
  INPUT/in_0001.bin
  INPUT/in_0002.bin
  OUTPUT/ACCURACY/
  OUTPUT/PRODUCT/
  OUTPUT/PERF/
  OUTPUT/CONFORM/
  MANIFEST/card_manifest.json
```

The 5000-image input set occupies about 2.60 GB. The final parameter package
is exactly 18,682,508 bytes. A full raw-head accuracy run adds about 1.08 GB,
and the 128-image, 22-node conformance run adds about 1.08 GB. A 16 GB card is
the practical minimum; 32 GB is recommended so accuracy, conformance, and
performance outputs can coexist. No individual file exceeds the FAT32 4 GiB
limit.

Card preparation never formats the device and never overwrites a different
existing file. For a card mounted as `E:`:

```powershell
$python='D:\MPSoC\coco80_assets\venv\Scripts\python.exe'
$bit='build_abi_v2_release_r5\conv_accel_ps_dma_minimal\conv_accel_ps_dma_minimal.runs\impl_1\conv_accel_ps_dma_wrapper.bit'
$xsa='build_abi_v2_release_r5\conv_accel_ps_dma_minimal.xsa'
& $python -m tools.coco80.sd_deploy prepare-card --card E:\COCO80_R5 --bit $bit --xsa $xsa --source-root .
& $python -m tools.coco80.sd_deploy register-inputs --card E:\COCO80_R5 --input-manifest E:\COCO80_R5\INPUT\input_index.json
& $python -m tools.coco80.sd_deploy verify --card E:\COCO80_R5
```

The first `register-inputs` command is intentionally only a staging action. It
sets the card state to `INPUTS_PROVISIONAL` and `verify` reports
`runnable=false`. Input tensors must be regenerated with the selected PTQ/QAT
manifest's exact `m0` input scale and zero point; a structural shard set made
with a placeholder scale is never accepted as a final board input.

After calibration and checkpoint selection, bind the regenerated inputs and
install the real parameter package as one fail-closed operation:

```powershell
$quant='<selected-quant-root>\quantization_manifest.json'
$package='<selected-package-root>\coco80_parameters.c8pa'
& $python -m tools.coco80.sd_deploy register-inputs `
  --card E:\COCO80_R5 `
  --input-manifest E:\COCO80_R5\INPUT\input_index.json `
  --quantization-manifest $quant
& $python -m tools.coco80.sd_deploy install `
  --card E:\COCO80_R5 `
  --parameter-package $package `
  --quantization-manifest $quant
& $python -m tools.coco80.sd_deploy verify --card E:\COCO80_R5
```

Do not populate `PARAM/` with a test fixture. `install` re-hashes the package,
index, and every input shard, then cross-checks the package's m0 quantization
and checkpoint binding before changing the card state to `DATA_READY`; only
that state reports `runnable=true`.

## Vitis persistent runner

Create the reusable A53 standalone platform once. The Tcl creates only the
platform and `xilffs` BSP; application code is compiled directly with the
checked-in linker script so the build does not depend on the Vitis Eclipse
empty-application service.

```powershell
& 'C:\Xilinx\Vitis\2022.2\bin\xsct.bat' `
  sw\vitis_2022_2\scripts\create_coco80_sd_project.tcl `
  -workspace D:\MPSoC\accelerator_systolic\build_vitis_2022_2_coco80_r5 `
  -xsa D:\MPSoC\accelerator_systolic\build_abi_v2_release_r5\conv_accel_ps_dma_minimal.xsa
```

The workspace must be fresh. A release ELF is then built from a clean Git
tree and is cryptographically bound to the signed r5 BIT/XSA, quantization
manifest, parameter manifest, and exact SD parameter package:

```powershell
& powershell -ExecutionPolicy Bypass -File sw\vitis_2022_2\scripts\build_coco80_sd_runner.ps1 `
  -Workspace D:\MPSoC\accelerator_systolic\build_vitis_2022_2_coco80_r5 `
  -BitFile $bit -Xsa $xsa `
  -ParameterManifest <coco80_parameter_manifest.json> `
  -QuantizationManifest <quantization_manifest.json> `
  -SdParameterPackage <coco80_parameters.c8pa> `
  -TrainingSummary <qat-summary.json> `
  -Fp32EvaluationSummary <fp32-deploy416-summary.json> `
  -Int8EvaluationSummary <int8-deploy416-summary.json> `
  -Mode accuracy -ImageLimit 5000
```

The build is fail-closed on the deployment accuracy budget. An intentionally
non-release integration build additionally requires
`-AllowNonReleaseDeployment` and a QAT summary already marked
`deployment_override=true`; every ELF manifest then records
`release_eligible=false`, the three summary hashes, and both AP deltas.

The modes are `accuracy`, `product`, `performance`, and `conformance`.
Accuracy writes both raw heads for every image; product writes A53 detections;
performance performs 20 warmups and writes timing records without raw dumps;
conformance is limited to 128 images and writes all 22 integer tensors plus
the raw heads. Output data and indexes are first written as `.partial` and are
renamed only after all inputs and counters pass.

Host validation must use `validate_board_output_index` and, for conformance,
`validate_board_node_index` from `tools.coco80.sd_pack`. These validators check
record order, offsets, lengths, CRC chains, mode, image count, and the complete
22-node tensor sequence before any result is admitted to mAP or byte-exact
comparison.

After moving the prepared SD card from the host reader into the board, start
the selected runner through JTAG. A non-release model requires the explicit
override at both build and run time:

```powershell
& powershell -ExecutionPolicy Bypass -File `
  sw\vitis_2022_2\scripts\run_coco80_sd_board.ps1 `
  -Workspace D:\MPSoC\accelerator_systolic\build_vitis_2022_2_coco80_r5 `
  -RunnerManifest <coco80_r5_conformance.manifest.json> `
  -BitFile $bit -AllowNonReleaseDeployment
```

The launcher re-hashes the ELF and signed r5 BIT and rejects an unmarked
failed-accuracy build. `hw_server` must already be listening on TCP port 3121.

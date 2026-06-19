# Reproducible Vitis Inference Package

This directory is the minimal deployment-data package required to build and
validate the Conv0-to-Conv9 Vitis application without the external
`D:/MPSoC/python_prj` training project.

## Contents

```text
model/
  00_conv0_pool/ ... 09_head_detect_conv9_1x1/
images/
  maksssksksss0.png
expected/
  conv9_golden_ofm_u8_hwc.bin
  decode_golden.json
SHA256SUMS
```

Each layer directory contains:

```text
manifest.json
ifm_u8_hwc.bin
weight_raw_oihw_s8.bin
bias_i32.bin
activation_lut_u8.bin
golden_ofm_u8_hwc.bin
```

The Vitis header generator reads the weight, bias, activation LUT, and golden
output. The IFM files support standalone/directed layer builds; only Conv0 IFM
is embedded by the normal Conv0-to-Conv9 chain build.

## Build the Conv0-to-Conv9 ELF

After generating the Vitis BSP/platform described in the repository README:

```powershell
powershell -ExecutionPolicy Bypass `
  -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 `
  -Mode conv0_conv9_ddr_demo
```

The script defaults to this directory. Use `-ReproRoot <path>` only when
testing another deployment package.

## Prepare the Fixed DDR Image

```powershell
python tools/demo/prepare_ddr_image.py `
  repro/images/maksssksksss0.png `
  demo_output/image_package.bin
```

The prepared 416x416 HWC RGB tensor must match:

```text
model/00_conv0_pool/ifm_u8_hwc.bin
```

## Verify the Final Detection Golden

```powershell
python tools/golden/yolo_single_scale_decode.py `
  --input repro/expected/conv9_golden_ofm_u8_hwc.bin `
  --output repro/expected/decode_golden.json
```

Expected result: one `with_mask` detection with score approximately
`0.357321`.

## Provenance

The package was curated from the quantized face-mask project formerly located
at `D:/MPSoC/python_prj`. It intentionally excludes training code, the full
dataset, PyTorch checkpoints, intermediate PSUM dumps, and redundant xsim text
memories. `SHA256SUMS` records the exact files included in this handoff.

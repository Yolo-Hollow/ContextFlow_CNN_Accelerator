# Golden Generation Tools

These scripts generate software and RTL-semantic golden data used by the RTL
testbenches.

Default external data root:

```text
D:/MPSoC/python_prj
```

Override the root with either:

```powershell
$env:PYTHON_PRJ = "D:\MPSoC\python_prj"
```

or a script argument:

```powershell
C:\Users\hp\.conda\envs\pytorch_env\python.exe tools\golden\export_rtl_layer06_golden.py --project D:\MPSoC\python_prj
```

Scripts default to writing full generated data back to the external
`python_prj/rtl_golden` directory. Do not write large layer dumps into this repo
unless they are intentionally curated as small regression fixtures.

## Single-scale RTL semantic export

The current offline network-prep path is described by:

```text
tools/golden/single_scale_yolov3tiny_layers.json
```

It fixes the KV260 baseline array to:

```text
ROWS=18, COLS=8, IFM_BANKS=2, COUT_TILE=16
```

The layer list covers the single low-resolution YOLOv3-tiny path from Conv0
through the 13x13 detection head. COUT values above 16 are expected to run as
multiple COUT blocks. Decode, threshold, and NMS run software-side.

Generate RTL semantic metadata and binaries for all listed layers:

```powershell
C:\Users\hp\.conda\envs\pytorch_env\python.exe tools\golden\export_rtl_single_scale_golden.py --project D:\MPSoC\python_prj
```

Generate only manifests, useful for quick shape/quant checks:

```powershell
C:\Users\hp\.conda\envs\pytorch_env\python.exe tools\golden\export_rtl_single_scale_golden.py --project D:\MPSoC\python_prj --metadata-only
```

Limit export to selected infer indices or names:

```powershell
C:\Users\hp\.conda\envs\pytorch_env\python.exe tools\golden\export_rtl_single_scale_golden.py --layers 3,6,head_detect_conv9_1x1
```

Verify that the JSON layer spec and Vitis C scheduler plan still match:

```powershell
python tools\golden\verify_single_scale_schedule.py
```

The verifier recalculates shape transitions, K passes, COUT blocks, feature
buffer sizes, spatial tile counts, and maximum OFM AXIS capture sizes. It should
match the scheduler dry-run summary printed by the Vitis smoke ELF.

## Single-scale YOLO decode

Generate the decode golden directly from the RTL-semantic Conv9 HWC tensor:

```powershell
python tools\golden\yolo_single_scale_decode.py
```

The decoder uses P5/32 anchors, the Conv9 output quantization, confidence
threshold `0.25`, and class-aware NMS IoU `0.45`. It writes
`decode_golden.json` beside the external Conv9 tensor. Run the Python/C host
regression with:

```powershell
python tb\test_yolo_decode.py
```

The board smoke script regenerates this golden and compares the machine-readable
UART `DECODE`/`DET` lines automatically.

The exporter writes per-layer `manifest.json` files with shape, quant,
`sat_count`, expected bytes, K/COUT scheduling counts, and PyTorch-reference
mismatch statistics when a comparable PyTorch layer output exists. The RTL
semantic golden uses:

```text
ifm_s8 = saturate_s8(ifm_u8 - input_zero_point)
psum = conv_accumulator + int32_bias
requant = round(psum * mult / 2^(raw_shift + 15)) + output_zp
ofm = activation_lut[requant]
```

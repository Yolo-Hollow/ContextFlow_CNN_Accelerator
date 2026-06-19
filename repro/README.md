# Vitis 推理复现数据包

本目录提供构建和验证 Conv0 至 Conv9 Vitis 应用所需的最小部署数据，不依赖
原先位于 `D:/MPSoC/python_prj` 的完整训练工程。

## 目录内容

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

每个网络层目录包含：

```text
manifest.json
ifm_u8_hwc.bin
weight_raw_oihw_s8.bin
bias_i32.bin
activation_lut_u8.bin
golden_ofm_u8_hwc.bin
```

Vitis 头文件生成器读取权重、bias、激活 LUT 和 golden 输出。IFM 文件用于
独立层或定向测试；正常的 Conv0 至 Conv9 串行构建仅嵌入 Conv0 的 IFM，
其余层输入由上一层硬件输出提供。

## 构建 Conv0 至 Conv9 ELF

先按照仓库根 README 的说明生成 Vitis BSP/platform，然后执行：

```powershell
powershell -ExecutionPolicy Bypass `
  -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 `
  -Mode conv0_conv9_ddr_demo
```

构建脚本默认读取本目录。只有在验证另一份部署数据包时，才需要通过
`-ReproRoot <path>` 指定其他路径。

## 准备固定 DDR 图片

```powershell
python tools/demo/prepare_ddr_image.py `
  repro/images/maksssksksss0.png `
  demo_output/image_package.bin
```

预处理得到的 `416x416` HWC RGB tensor 应与下列文件完全一致：

```text
model/00_conv0_pool/ifm_u8_hwc.bin
```

## 验证最终检测 Golden

```powershell
python tools/golden/yolo_single_scale_decode.py `
  --input repro/expected/conv9_golden_ofm_u8_hwc.bin `
  --output repro/expected/decode_golden.json
```

期望结果为一个类别为 `with_mask`、置信度约为 `0.357321` 的检测框。

## 数据来源

本数据包由量化口罩检测工程导出的部署数据整理而成。为控制仓库规模，其中
不包含训练代码、完整数据集、PyTorch checkpoint、中间 PSUM dump 和重复的
xsim 文本 memory。`SHA256SUMS` 记录了本交付数据包中全部文件的精确校验值。

# R5 加速器上的 COCO80 YOLOv3-tiny

**语言 / Language：中文 | [English](README_EN.md)**

本目录提供完整双检测头 COCO80 部署所需的主机工具，包括数据清单、校准与量化、参数打包、SD 卡部署、板端结果校验和网络协议。大模型、COCO 数据集、生成的量化产物、SD 镜像与评估结果不写入仓库，而是通过 SHA-256 清单绑定。

权威网络描述为 `model_spec.json`。网络包含 13 次 PL 卷积调度；池化、带填充的步长 1 池化、最近邻上采样、route 重量化与拼接，以及 decode/NMS 均由 A53 执行。固定 PL 分块高度由 `hardware_plan.py` 独立校验。

## 环境与数据准备

使用项目指定的 Conda 环境：

```powershell
conda activate pytorch_env
python --version
```

建议按以下顺序准备模型和数据：

1. 获取 `ultralytics/yolov3` 的 `v9.5.0` 标签，确认提交为 `8eb4cde090022af73db12cfa725ec4bf01d49c0e`。
2. 下载 `yolov3-tiny.pt`，确认 SHA-256 为 `74fb61c9593f563fc8c87a6d792cfe127632e402440acd9c142a396813946280`。
3. 准备 COCO train2017、val2017、官方 annotations 和 Ultralytics 标签，并用 `make_asset_manifest.py` 生成 `assets.json`。
4. 用 `calibration.py` 和种子 `20260814` 固定 1024 张校准集与 512 张 holdout 集。
5. 用 `conformance.py` 固定 128 张板端一致性集合及其中 16 张全节点 golden 子集。
6. 运行 `official640.py`，再用 `evaluate.py --mode fp32` 建立固定尺寸 FP32 基线。
7. 完成 PTQ、导出量化清单和逐层参数，并用 `parameter_package.py` 生成参数包；随后执行 `evaluate.py --mode ptq`。
8. 仅在 PTQ 相对基线下降超过 1.0 AP 或 2.0 AP50 时运行 `qat.py`。
9. 生成板端输入，在持久化 Vitis runner 上执行，并用 `ptq_runner.py` 的 exact 模式逐字节校验整数节点。

精度评估固定使用置信度 `0.001`、类别感知 multi-label NMS、IoU `0.65`、`max_nms=30000` 和 `max_det=300`。演示模式的 `0.25/0.45` 阈值不能用于 mAP 签核。

## SD 卡数据目录

裸机程序挂载第一个 FAT 分区，并使用以下固定 ABI：

```text
COCO80_R5/
  ARTIFACT/r5.bit
  ARTIFACT/r5.xsa
  PARAM/coco80_parameters.c8pa
  INPUT/input_index.bin
  INPUT/in_0000.bin
  INPUT/in_0001.bin
  ...
  OUTPUT/ACCURACY/
  OUTPUT/PRODUCT/
  OUTPUT/PERF/
  OUTPUT/CONFORM/
  MANIFEST/card_manifest.json
```

5000 张输入约占 2.60 GB，参数包为 18,682,508 字节。建议使用 32 GB SD 卡，以便同时保存 accuracy、conformance 和 performance 结果；最低建议容量为 16 GB。

部署工具不会格式化 SD 卡，也不会覆盖内容不同的同名文件。以 `E:` 为例：

```powershell
python -m tools.coco80.sd_deploy prepare-card `
  --card E:\COCO80_R5 `
  --bit release\contextflow_34p9\conv_accel_ps_dma_wrapper.bit `
  --xsa release\contextflow_34p9\conv_accel_ps_dma_minimal.xsa `
  --source-root .

python -m tools.coco80.sd_deploy register-inputs `
  --card E:\COCO80_R5 `
  --input-manifest E:\COCO80_R5\INPUT\input_index.json `
  --quantization-manifest <quantization_manifest.json>

python -m tools.coco80.sd_deploy install `
  --card E:\COCO80_R5 `
  --parameter-package <coco80_parameters.c8pa> `
  --quantization-manifest <quantization_manifest.json>

python -m tools.coco80.sd_deploy verify --card E:\COCO80_R5
```

输入必须用最终选定量化清单中 `m0` 的输入 scale 和 zero point 重新生成。只有交叉校验参数包、量化清单和全部输入分片后，卡片状态才会成为 `DATA_READY`，此时 `verify` 才报告 `runnable=true`。

## 持久化 Vitis runner

SD 文件系统 runner 使用单独的 A53 standalone 平台：

```powershell
& 'C:\Xilinx\Vitis\2022.2\bin\xsct.bat' `
  sw\vitis_2022_2\scripts\create_coco80_sd_project.tcl `
  -workspace <fresh-sd-workspace> `
  -xsa release\contextflow_34p9\conv_accel_ps_dma_minimal.xsa
```

随后构建与硬件、量化清单和参数包绑定的 runner：

```powershell
powershell -ExecutionPolicy Bypass -File `
  sw\vitis_2022_2\scripts\build_coco80_sd_runner.ps1 `
  -Workspace <fresh-sd-workspace> `
  -BitFile release\contextflow_34p9\conv_accel_ps_dma_wrapper.bit `
  -Xsa release\contextflow_34p9\conv_accel_ps_dma_minimal.xsa `
  -ParameterManifest <coco80_parameter_manifest.json> `
  -QuantizationManifest <quantization_manifest.json> `
  -SdParameterPackage <coco80_parameters.c8pa> `
  -TrainingSummary <training-summary.json> `
  -Fp32EvaluationSummary <fp32-summary.json> `
  -Int8EvaluationSummary <int8-summary.json> `
  -Mode performance
```

可用模式为 `accuracy`、`product`、`performance` 和 `conformance`。构建与启动脚本会重新计算 ELF、bitstream、量化清单和参数包哈希；未满足模型门禁的集成构建必须显式使用 `-AllowNonReleaseDeployment`，且清单会记录 `release_eligible=false`。

JTAG、SD 冷启动和 WebUI 的最短操作流程见仓库根目录[快速启动与复现](../../README.md#快速启动与复现)。WebUI 的详细说明见[上传推理工具](INFERENCE_APP.md)。

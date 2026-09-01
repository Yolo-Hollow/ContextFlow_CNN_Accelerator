# KV260 COCO80 WebUI 推理工具

**语言 / Language：中文 | [English](INFERENCE_APP_EN.md)**

该本地 WebUI 接收用户图片，生成与硬件 ABI 一致的 reduced-u8 C8IN 输入包，将其发送到 KV260 持久化以太网 runner，校验响应 CRC 和产物绑定，并显示板端检测结果及单图时延分解。工具不会回退为主机推理。

## 1. 启动板端服务

连接 KV260 的 JTAG 与以太网，启动 `hw_server`，然后下载当前网络 runner：

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\hw_server.bat'

powershell -ExecutionPolicy Bypass -File `
  sw\vitis_2022_2\scripts\run_coco80_net_board.ps1 `
  -Workspace <network-workspace> `
  -RunnerManifest <coco80_r5_ethernet.manifest.json> `
  -BitFile release\contextflow_34p9\conv_accel_ps_dma_wrapper.bit
```

板端监听 `192.168.10.2:5001`。主机网卡应配置为 `192.168.10.1/24`，启动 WebUI 前先执行：

```powershell
ping 192.168.10.2
```

使用 QSPI/U-Boot 的 SD 冷启动时，网络 runner 必须构建为 Non-Secure EL1：

```powershell
& 'C:\Xilinx\Vitis\2022.2\bin\xsct.bat' `
  sw\vitis_2022_2\scripts\create_coco80_net_project.tcl `
  -workspace <el1-network-workspace> `
  -xsa release\contextflow_34p9\conv_accel_ps_dma_minimal.xsa `
  -execution-level el1
```

## 2. 启动 WebUI

```powershell
conda activate pytorch_env
powershell -ExecutionPolicy Bypass -File tools\coco80\run_inference_app.ps1 `
  -RunnerManifest <coco80_r5_ethernet.manifest.json> `
  -QuantizationManifest <quantization_manifest.json> `
  -OpenBrowser
```

如果浏览器没有自动打开，请访问 <http://127.0.0.1:8088/>。更换模型后必须显式提供该模型完成板端验证后生成的 runner 和量化清单。

## 模式与时延含义

- **Demo**：板端使用 `confidence=0.25`、`IoU=0.45` 和 single-label NMS。
- **Accuracy**：使用 `confidence=0.001`、`IoU=0.65` 和 multi-label NMS；显示阈值可单独提高。
- **Resident**：量化输入已在 DDR 中，从完整 13 层卷积 DAG 到 A53 检测结果的时间。
- **PL**：13 次加速器调度时间之和。
- **A53**：张量操作以及 decode/NMS 时间。
- **Network session**：主机端墙钟时间，包含连接、HELLO 与参数传输，不能作为模型推理延迟。

每次成功请求都会保存到 `results/coco80/inference_app/runs/<request-id>/`，包括上传原图、C8IN 索引和分片、板端原始检测包、时延记录、可视化结果、JSON 元数据及 SHA-256 引用。

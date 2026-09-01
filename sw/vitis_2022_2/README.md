# ContextFlow Vitis 2022.2 运行时

**语言 / Language：中文 | [English](README_EN.md)**

本目录包含 KV260/XCK26 的 A53 裸机运行时、工程生成脚本、JTAG 下载工具和 SD 冷启动支持。当前接口为 ABI v2：`ROWS=18`、`COLS=16`、`COUT_TILE=32`，支持 raw-HWC IFM、packed-HWC OFM、layer-long DMA 和带 epoch 的上下文控制。

发布硬件位于 `release/contextflow_34p9/`，对应 200 MHz `abi_v2_release_200`。启动脚本会校验 bitstream、XSA、ELF 和 runner manifest 的 SHA-256，不接受身份不匹配的组合。

> **路径替换说明：** `C:\Xilinx\...` 是默认工具安装路径，所有 `<...>` 内容均为工作区、清单、构建目录或输出目录占位符。请替换为本机实际绝对路径并去掉尖括号。仓库内相对路径要求从仓库根目录执行；UART 的 `COMx` 也必须替换为实际串口号。

## 目录

```text
src/                    裸机运行时、网络执行与平台适配代码
scripts/                Vitis 工程生成、runner 构建、JTAG 下载及签核脚本
boot/coco80_el1/        QSPI/U-Boot SD 冷启动打包工具和启动辅助代码
```

## 环境

```powershell
conda activate pytorch_env
& 'C:\Xilinx\Vitis\2022.2\bin\xsct.bat' -version
& 'C:\Xilinx\Vivado\2022.2\bin\hw_server.bat'
```

示例采用默认工具路径 `C:\Xilinx\Vitis\2022.2` 和 `C:\Xilinx\Vivado\2022.2`；若安装位置不同，应使用实际路径。JTAG 流程要求 `hw_server` 监听 TCP 3121；UART 采集脚本中的串口号必须按主机实际情况显式指定。

## JTAG 网络 runner

### 1. 创建平台

EL3 平台适用于 JTAG 启动的持久化网络服务：

```powershell
& 'C:\Xilinx\Vitis\2022.2\bin\xsct.bat' `
  sw\vitis_2022_2\scripts\create_coco80_net_project.tcl `
  -workspace <fresh-network-workspace> `
  -xsa release\contextflow_34p9\conv_accel_ps_dma_minimal.xsa `
  -execution-level el3
```

工作区必须是新目录；脚本会写入 `.coco80_r5_net_workspace` 标记，后续构建和启动据此检查工作区类型与 XSA 身份。

### 2. 构建 runner

`build_coco80_net_runner.ps1` 使用仓库源码直接生成 ELF 和哈希绑定的 `coco80_r5_ethernet.manifest.json`。构建时需提供硬件、参数包、量化清单以及 FP32/INT8 评估摘要；具体参数可执行：

```powershell
Get-Help sw\vitis_2022_2\scripts\build_coco80_net_runner.ps1 -Detailed
```

模型未通过发布精度门禁时，只能使用显式的 `-AllowNonReleaseDeployment` 构建集成测试 runner，且输出清单会保留 `release_eligible=false`。

### 3. 下载并运行

```powershell
powershell -ExecutionPolicy Bypass -File `
  sw\vitis_2022_2\scripts\run_coco80_net_board.ps1 `
  -Workspace <fresh-network-workspace> `
  -RunnerManifest <coco80_r5_ethernet.manifest.json> `
  -BitFile release\contextflow_34p9\conv_accel_ps_dma_wrapper.bit
```

该命令重新计算 bitstream 和 ELF 哈希，完成 PS 初始化、PL 配置和应用下载。服务默认监听 `192.168.10.2:5001`。

## SD 文件系统 runner

创建带 `xilffs` 的 standalone 平台：

```powershell
& 'C:\Xilinx\Vitis\2022.2\bin\xsct.bat' `
  sw\vitis_2022_2\scripts\create_coco80_sd_project.tcl `
  -workspace <fresh-sd-workspace> `
  -xsa release\contextflow_34p9\conv_accel_ps_dma_minimal.xsa
```

随后使用 `build_coco80_sd_runner.ps1` 构建 `accuracy`、`product`、`performance` 或 `conformance` runner。将准备好的 SD 卡插入板端后，可先通过 JTAG 启动并检查文件系统路径：

```powershell
powershell -ExecutionPolicy Bypass -File `
  sw\vitis_2022_2\scripts\run_coco80_sd_board.ps1 `
  -Workspace <fresh-sd-workspace> `
  -RunnerManifest <coco80_r5_performance.manifest.json> `
  -BitFile release\contextflow_34p9\conv_accel_ps_dma_wrapper.bit
```

SD 卡数据准备见 [COCO80 部署说明](../../tools/coco80/README.md)。

## SD 上电冷启动

冷启动网络 runner 使用 Non-Secure EL1 平台：

```powershell
& 'C:\Xilinx\Vitis\2022.2\bin\xsct.bat' `
  sw\vitis_2022_2\scripts\create_coco80_net_project.tcl `
  -workspace <fresh-el1-network-workspace> `
  -xsa release\contextflow_34p9\conv_accel_ps_dma_minimal.xsa `
  -execution-level el1
```

完成 EL1 runner 构建后生成启动包：

```powershell
powershell -ExecutionPolicy Bypass -File `
  sw\vitis_2022_2\boot\coco80_el1\package_sd_boot.ps1 `
  -BuildDirectory <EL1-network-build> `
  -BitFile release\contextflow_34p9\conv_accel_ps_dma_wrapper.bit `
  -OutputDirectory <sd-boot-package> `
  -Python (Get-Command python).Source
```

将生成目录中的文件复制到 FAT 启动分区。KV260 的 QSPI U-Boot 会链式加载 bitstream、设备树辅助信息和 EL1 应用。PL 与 GEM DMA 使用显式 cache maintenance；冷启动默认 DDR shareability 设置不应替换为仅供 JTAG 诊断的选项。

## ABI v2 签核入口

软件和板端验证的主要脚本为：

```text
scripts/build_abi_v2_candidate.ps1
scripts/run_abi_v2_board_functional.ps1
scripts/run_abi_v2_board_signoff.ps1
scripts/run_abi_v2_board_performance_125.ps1
scripts/run_abi_v2_board_soak.ps1
```

正式 200 MHz 功能验证按 `0x2B -> 0x3B -> 0x3F -> 0xBF` 顺序执行，每个阶段使用独立且绑定的工作区/ELF。性能 runner 默认采用 `0xBF`，soak runner 持续检查 DMA、协议、计数器、超时和温度条件。

主机侧软件测试：

```powershell
powershell -ExecutionPolicy Bypass -File tb\run_sw_host_tests.ps1
```

完整系统的最短启动流程见仓库根目录[快速启动与复现](../../README.md#快速启动与复现)。

# ContextFlow：基于重放与上下文流水的量化 CNN 加速器

**语言 / Language：中文 | [English](README_EN.md)**

ContextFlow 是面向 AMD/Xilinx Kria KV260（XCK26）的完整 INT8 CNN 推理系统。项目以固定规模 `18×16` 双输出脉动阵列为计算核心，围绕折叠卷积执行中的两个系统级瓶颈展开：同一 HWC 输入随输出通道块切换被重复搬运，以及相邻折叠上下文之间的执行空泡。

当前发布版本在 200 MHz 下完成双尺度 YOLOv3-tiny 的常驻推理，实测平均延迟为 **34.943 ms**，吞吐率为 **28.618 FPS**，PL 有效吞吐率为 **165.588 GOPS**，阵列利用率为 **71.87%**。

最新预印本：[ContexFlow_preprint_thesis.pdf](output/pdf/ContexFlow_preprint_thesis.pdf)

> 预印本 PDF 作为单独文件追踪；其 LaTeX 工程与本地编译目录不包含在发布提交中。

## 核心思路

固定规模阵列执行长规约卷积时，需要沿规约维拆分为多个 `p` 轮次，并沿输出通道拆分为多个 `q` 块。ContextFlow 从空间和时间两个维度重新组织这一折叠序列。

### 1. 片上向量生成与跨输出通道块重放

- 每个紧凑 HWC 空间分块只从 DDR 读取一次。
- 片上 kernel-adaptive router 将输入直接打包为 `1×1` 向量，或按九个 tap 收集为 `3×3` 向量。
- 每个规约轮次生成 18 元素、阵列可直接消费的向量，并按 `p` 写入片上向量 bank。
- 相同的 `V[p]` 序列在不同输出通道块 `q` 之间重放，仅切换对应权重块 `W[q]`。
- 最后一个读取者完成后才释放或覆盖向量缓存，从而把输入复用保留在片上。

### 2. 面向折叠执行的上下文流水

- 将一次 `(layer, tile, q, p)` 折叠执行定义为一个上下文。
- Prepare、Execute 和 Retire 分别完成输入/权重准备、阵列计算以及 PSUM 或最终结果提交。
- 下一上下文的准备、当前上下文的计算和前一上下文的退休在独立通路上重叠。
- 双 bank 权重缓存、分组 PSUM 反馈、credit 流控和资源所有权检查共同支持直接切换。
- 当输入向量、权重、PSUM 和目标身份均就绪时，阵列所有权直接交接，不插入全局空闲周期。

## 软硬件系统

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

PS 负责网络描述、四路 DMA、层间张量与检测后处理；PL 负责 HWC 向量生成、权重准备、阵列执行、PSUM、量化、激活、池化和输出组织。完整网络包含 13 个 PL 卷积，池化、最近邻上采样、拼接和分支连接由 PS 配合完成。

## 当前发布结果

### 性能

| 指标 | 结果 |
| --- | ---: |
| 平台 / 频率 | XCK26/KV260 / 200 MHz |
| 常驻推理平均延迟 | **34.943 ms** |
| 常驻推理 P95 | **34.965 ms** |
| 吞吐率 | **28.618 FPS** |
| PL 平均延迟 | **33.607 ms** |
| 有效吞吐率 | **165.588 GOPS** |
| 阵列利用率 | **71.87%** |
| 样本 | 3 次独立运行，每次 20 次预热 + 1000 张计时图像 |

受控五级消融的最终阶段为 `34.978 ms`，它与上表的完整常驻推理均值属于不同测量范围，不应互相替代。消融结果还表明，片上向量生成与重放使 IFM DMA 流量降低 **19.67 倍**，并使常驻推理相对串行基线获得 **2.020 倍**加速。

### 模型精度

| 模型 | COCO val2017 图像数 | AP / AP50 |
| --- | ---: | ---: |
| FP32-416 | 5000 | 17.494% / 33.493% |
| INT8-416 | 5000 | 14.304% / 30.212% |

### 正确性与稳定性

- 128 张图像、22 个整数节点，共 2,816 条节点记录与参考实现逐字节一致。
- 板端完整网络对 5000 张 COCO val2017 图像的指标与离线产品路径一致。
- 3000 张计时图像无输出 CRC 错误。
- 10 分钟 soak 测试通过：13,184 条记录、0 协议错误、0 意外重连。

### 实现代价

| 资源或时序 | 数值 |
| --- | ---: |
| LUT | 56,949 |
| DSP | 650（其中阵列 576） |
| BRAM | 94 |
| URAM | 48 |
| WNS / TNS | +0.004 ns / 0 ns |
| 布局后工具估算片上功耗 | 4.008 W |

正式测量与哈希见 [34.9 ms 发布清单](docs/contextflow_34p9_release_manifest.md) 和 [机器可读证据快照](paper/lasa_journal_cn/data/evidence_snapshot.json)。功耗为布局布线后的 vectorless 工具估算，并非板端实测功耗。

## 仓库结构

```text
cal/                     DSP 与 INT8 MAC 基础单元
com/                     通用 RTL 流水模块
systolic/                ContextFlow 阵列、向量重放、PSUM 与上下文流水 RTL
sw/vitis_2022_2/
  src/                   KV260 裸机推理运行时
  scripts/               工程生成、部署、上板与测量脚本
  boot/coco80_el1/       EL1/SD 启动支持
tb/                      RTL、软件与端到端回归测试
tcl/                     Vivado 工程、综合、实现和签核脚本
tools/
  coco80/                量化、数据集、部署、协议与评估工具
  demo/                  板端功能和性能演示
  golden/                调度与整数语义参考模型
  power/                 功耗报告解析
repro/                   可复现实验入口与小型数据包
docs/                    发布清单、实现说明和证据边界
paper/lasa_journal_cn/   冻结的实验数据、表格与论文证据源
release/                 历史硬件交付物；不代表当前 34.943 ms 实现
output/pdf/
  ContexFlow_preprint_thesis.pdf
                         当前预印本，仅追踪最终 PDF
```

核心发布内容按可审查的提交分组：RTL、软件运行时、复现与上板证据、34.9 ms 文档冻结，以及单独追踪的预印本 PDF。Vivado/Vitis 构建目录、`tmp/`、本地结果抓取、论文 LaTeX 工程和历史 PDF 预览均不进入提交。

## 环境

- Windows 10/11 与 PowerShell 5 或更高版本
- AMD/Xilinx Vivado 2022.2
- AMD/Xilinx Vitis 2022.2
- Conda 环境 `pytorch_env`
- Kria KV260、JTAG 与 UART；网络部署流程还需要可用以太网连接

```powershell
conda activate pytorch_env
python --version
```

工具链默认路径为：

```text
C:\Xilinx\Vivado\2022.2
C:\Xilinx\Vitis\2022.2
```

## 构建与验证入口

### RTL 回归

XSIM 是正式 RTL 回归与签核仿真器：

```powershell
powershell -ExecutionPolicy Bypass -File tb/run_short_xsim_regression.ps1
powershell -ExecutionPolicy Bypass -File tb/run_all_xsim_regression.ps1
```

大型完整层、随机 AXIS 背压和 18×16 packed-OFM 测试由 `tb/run_large_xsim_regression.ps1` 与 `tcl/run_xsim_regression.tcl` 驱动。Icarus 仅用于轻量模块 smoke，不作为发布门禁。

### 200 MHz KV260 硬件

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\build_kv260_system_xck26.tcl -tclargs `
  -profile abi_v2_release_200 -jobs 12
```

该 profile 统一约束 OOC 时钟、PS `pl_clk0`、加速器 `CLOCK_HZ` 和构建 metadata。降低频率、修改 burst 或放宽发布 gate 会生成不同身份的构建，不能替代冻结结果。

### Vitis 运行时与板端签核

主要入口位于：

```text
sw/vitis_2022_2/scripts/build_abi_v2_candidate.ps1
sw/vitis_2022_2/scripts/run_abi_v2_board_functional.ps1
sw/vitis_2022_2/scripts/run_abi_v2_board_performance_125.ps1
sw/vitis_2022_2/scripts/run_abi_v2_board_soak.ps1
sw/vitis_2022_2/scripts/run_coco80_net_board.ps1
sw/vitis_2022_2/scripts/run_coco80_sd_board.ps1
```

COCO80 数据准备、量化、网络协议和结果评估见 [tools/coco80/README.md](tools/coco80/README.md)，裸机工程与上板流程见 [sw/vitis_2022_2/README.md](sw/vitis_2022_2/README.md)，Vivado profile 和签核门禁见 [tcl/README.md](tcl/README.md)。

## 发布边界

- 当前分支包含可审查的 RTL、软件、测试、脚本、证据摘要与预印本。
- 冻结结果对应的 XSA 和 bitstream 以 SHA-256 标识，但因体积和交付策略未包含在本分支。
- `release/kv260_hwcreplay_22/` 是约 280.340 ms 的历史 raw-HWC replay 交付物，不是 34.943 ms ContextFlow 硬件。
- `paper/contextflow_journal_cn/` 的 LaTeX 工程和 `build/` 不进入本次发布；只追踪最终预印本 PDF。
- INT8 精度相对 FP32 存在约 3.19 AP 点损失；仓库如实保留该结果，不将其描述为无精度损失。

## 上游与许可说明

项目早期模型和部署流程参考了 [adamgallas/fpga_accelerator_yolov3tiny](https://github.com/adamgallas/fpga_accelerator_yolov3tiny)。其中 `cal/cal_mul_int8_x2.v` 和 `cal/cal_mul_int8_x2_dsp.v` 源自该 Apache-2.0 项目的双 INT8 DSP 乘法设计。除此之外，本仓库围绕 KV260/XCK26 重构了阵列、HWC 向量化与重放、折叠上下文流水、PSUM 管理、DMA/Vitis 运行时以及完整验证流程。使用和再分发时请同时遵守仓库与上游项目的许可和引用要求。

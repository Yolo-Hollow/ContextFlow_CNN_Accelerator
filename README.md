# LASA：面向边缘 AI 部署的 MPSoC 层自适应脉动阵列加速器

LASA（Layer-Adaptive Systolic Accelerator）是一套面向 AMD/Xilinx Kria
KV260 的 YOLOv3-tiny INT8 推理系统。项目覆盖 Verilog RTL、Vivado Block
Design、Vitis 裸机运行时、量化模型部署数据、RTL/板级验证工具以及可直接使用的
XSA 和 bitstream，形成了从 DDR 图像输入、PS/PL 协同调度、十层卷积计算到
YOLO 检测结果解析的完整实现。

项目对应论文《LASA：面向边缘 AI 部署的 MPSoC 层自适应脉动阵列加速器设计》，
论文全文见 [Thesis.pdf](Thesis.pdf)。

## 项目成果

LASA 面向真实网络推理中的非计算开销进行设计，而不只追求乘加阵列的峰值吞吐。
系统以统一的层描述和硬件数据通路执行单尺度 YOLOv3-tiny Conv0--Conv9，主要成果
包括：

- 实现 `ROWS=18`、`COLS=8` 的双输出通道 INT8 脉动阵列，每次并行计算
  `COUT_TILE=16` 个输出通道，使用 INT32 partial sum。
- 在同一阵列中原生支持 `1x1` 和 `3x3` 卷积，避免将 `1x1` 检测头映射为
  稀疏 `3x3` 所产生的无效 K pass。
- 实现输入零点校正、定点 requant、逐通道参数、activation LUT 和可旁路的
  `2x2/stride2` max-pooling。
- 建立 KCS 三维分块模型，将卷积统一表示为 K pass、输出通道块和空间 tile。
- 通过 BSD（Batched Streaming Dataflow）减少 PS 服务和 DMA 启动开销。
- 通过 OCRR（On-Chip Reorder and Replay）在 URAM 中缓存 raw-HWC 数据，完成
  `1x1/3x3` 片上重排、重放和后端 full-tile 调度。
- 通过 OPF-P（Overlapped PSUM Feedback and Prefetch）重叠 partial-PSUM 反馈、
  drain 和下一 K pass 的数据准备。
- 建立模块仿真、真实层外部 golden、Conv0--Conv9 板级 bit-exact 和真实图片
  DDR demo 组成的验证闭环。

## 系统结构

```text
DDR image / model data
        |
        v
ARM Cortex-A53 bare-metal runtime
  layer descriptor / AXI-Lite / DMA / cache maintenance
        |
        v
Bias DMA + Weight DMA + IFM DMA
        |
        v
LASA programmable logic
  loader -> HWC cache/replay -> systolic array -> PSUM
         -> requant -> activation -> pooling -> OFM writer
        |
        v
OFM DMA -> DDR feature buffer -> next layer / YOLO decode
```

PS 负责网络层描述、DMA 调度、层间 feature buffer、输出重排和 YOLO decode；
PL 负责卷积、部分和累加、量化、激活、池化与输出数据流。四路 AXI DMA 分别用于
bias、weight、IFM 和 OFM，AXI-Lite 用于配置层参数和读取性能计数器。

![LASA 在 KV260 上进行端到端推理](./上板推理实物图.jpeg)

*LASA 在 Kria KV260 上运行单尺度 Yolov3_tiny 推理并由主机显示检测结果。*

## 实验结果

论文实验使用 KV260/XCK26、Vivado/Vitis 2022.2 和 100 MHz 主时钟。最终论文
配置完成 Conv0--Conv9 batch-chain bit-exact 验证，并在两张 DDR 图片上获得稳定
检测结果：

| 指标 | 结果 |
| --- | ---: |
| 论文 DDR demo 端到端延迟 | 约 288 ms |
| PL hardware busy | 247.184 ms |
| 阵列有效 `compute_fire` | 74.323 ms |
| A53 单核 INT8 软件基线 | 2540.175 ms |
| 相对 A53 软件加速比 | 8.82x |
| 相对早期 1.18 s 硬件链路 | 约 4.1x |

论文推荐实现的布局布线结果为：

| 资源或时序 | 数值 |
| --- | ---: |
| CLB LUT | 84,480 |
| CLB Register | 53,260 |
| BRAM Tile | 63 |
| URAM | 24 |
| DSP | 184 |
| WNS | +0.092 ns |
| TNS | 0 ns |
| Routing error | 0 |

仓库同时发布经过完整板级验证的 `kv260_hwcreplay_22` 硬件产物。固定图片 DDR
demo 的实测延迟约为 `280.340 ms`，输出一个 `with_mask` 检测，置信度约
`0.357321`。该发布产物用于开源复现；论文表格中的 `288 ms` 来自论文所采用的
实验构建和日志，两者均使用相同的 `18x8` 阵列与 2022.2 工具链。

![固定测试图的口罩检测结果](./识别结果.png)

*固定 DDR 测试图的检测输出：`with_mask`，置信度约为 `0.357`。*

## 仓库结构

```text
cal/                     DSP 和 INT8 乘法辅助模块
com/                     通用 RTL 模块
systolic/                LASA 加速器 RTL
tb/                      Verilog testbench 与 Python 回归测试
tcl/                     XSIM、Vivado 综合及 KV260 系统构建脚本
sw/vitis_2022_2/         Vitis 2022.2 裸机运行时和上板脚本
tools/golden/             RTL semantic golden 与网络导出工具
tools/demo/               图片预处理和 UART 性能分析工具
docs/                    架构、寄存器、验证方法和历史开发资料
golden/                  小型 RTL 回归数据及版本管理说明
repro/                   十层部署参数、测试图片和期望输出
release/kv260_hwcreplay_22/
                         可发布的 XSA 与 bitstream
Thesis.pdf               项目论文
```

详细硬件数据流和寄存器定义见
[docs/hardware_dataflow_and_registers.md](docs/hardware_dataflow_and_registers.md)，
验证范围见 [docs/rtl_test_plan.md](docs/rtl_test_plan.md)。

## 环境要求

- Windows 10/11 与 PowerShell 5 或更高版本
- AMD/Xilinx Vivado 2022.2
- AMD/Xilinx Vitis 2022.2
- Python 3.9 或兼容版本
- Kria KV260 开发板、JTAG 和 115200 baud UART
- 可选：Icarus Verilog，用于部分轻量级 RTL 测试

工程脚本显式使用 `C:\Xilinx\Vivado\2022.2` 和
`C:\Xilinx\Vitis\2022.2`。若工具安装在其他位置，需要修改相应 PowerShell/Tcl
脚本中的工具路径。

## 获取与校验复现数据

`repro/` 已包含构建 Conv0--Conv9 Vitis 应用所需的量化权重、INT32 bias、激活
LUT、逐层 golden、固定测试图和 YOLO decode 期望结果，不依赖完整训练工程。

```powershell
Get-FileHash repro\images\maksssksksss0.png -Algorithm SHA256
Get-Content repro\SHA256SUMS
```

数据包结构和重新生成检测 golden 的方法见 [repro/README.md](repro/README.md)。

## RTL 仿真

运行日常短回归：

```powershell
powershell -ExecutionPolicy Bypass -File tb/run_short_xsim_regression.ps1
```

运行指定的 XSIM 顶层测试，例如 Conv6 的 `3x3` raw-HWC full-tile 测试：

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' `
  -mode batch `
  -source tcl\run_xsim_regression.tcl `
  -tclargs -top tb_conv_accel_core_axi_lite_axis_stream_conv6_3x3_raw_hwc_fulltile_cout16
```

testbench 覆盖 AXI-Lite 配置、AXI-Stream 背压、weight/IFM loader、原生
`1x1/3x3`、PSUM、requant、activation、pooling 和真实层数据流。大型完整层测试
使用 XSIM，日常回归使用较小的定向用例控制运行时间。

## 构建 KV260 硬件

使用 Vivado 2022.2 从 RTL 和 Tcl 重新生成 Block Design、bitstream 和 XSA：

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' `
  -mode batch `
  -source tcl\build_kv260_system_xck26.tcl `
  -tclargs -build_dir D:/MPSoC/build_lasa_kv260 -jobs 12
```

默认主配置为：

```text
ROWS=18
COLS=8
COUT_TILE=16
IFM_BANKS=2
HWC_CACHE_AW=16
HWC_CACHE_DEPTH=43264
HWC_CACHE_STRIPES=4
HWC_CACHE_USE_URAM=1
TAIL_CYCLES=1
```

若不需要重新实现，可直接使用：

```text
release/kv260_hwcreplay_22/conv_accel_ps_dma_minimal.xsa
release/kv260_hwcreplay_22/conv_accel_ps_dma_wrapper.bit
```

文件哈希记录在 [release/kv260_hwcreplay_22/README.md](release/kv260_hwcreplay_22/README.md)。

## 构建 Vitis 裸机程序

首先使用生成的 XSA 创建或更新 Vitis platform/BSP：

```powershell
& 'C:\Xilinx\Vitis\2022.2\bin\xsct.bat' `
  sw/vitis_2022_2/scripts/create_accel_smoke_project.tcl
```

然后构建十层 DDR 图片演示：

```powershell
powershell -ExecutionPolicy Bypass `
  -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 `
  -Mode conv0_conv9_ddr_demo
```

构建脚本默认从 `repro/model/` 读取网络参数，并生成硬件消费顺序的预打包权重。
更完整的构建模式和 ELF 输出位置见
[sw/vitis_2022_2/README.md](sw/vitis_2022_2/README.md)。

## KV260 上板运行

首次运行应完整配置 PL。将 `COM8` 和构建目录替换为本机实际 UART 端口与
Vivado build 目录：

```powershell
powershell -ExecutionPolicy Bypass `
  -File sw/vitis_2022_2/scripts/run_kv260_image_demo.ps1 `
  -Image repro\images\maksssksksss0.png `
  -PortName COM8 `
  -BuildDirName D:\MPSoC\build_lasa_kv260 `
  -CaptureSeconds 240
```

运行 Conv0--Conv9 逐层 RTL semantic golden 比较：

```powershell
powershell -ExecutionPolicy Bypass `
  -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 `
  -PortName COM8 `
  -BuildDirName D:\MPSoC\build_lasa_kv260 `
  -RunConv0Conv9BatchChain `
  -CaptureSeconds 240
```

脚本会完成硬件配置、ELF 下载、UART 日志采集和检测结果比较。固定测试图的期望
结果位于 `repro/expected/decode_golden.json`。

## 验证方法

项目使用三层验证保证结果可追踪：

1. 模块级 RTL 测试检查握手、背压、地址、K pass 和量化边界。
2. 真实层 XSIM 将 RTL 输出逐字节与外部 RTL semantic golden 比较。
3. KV260 batch-chain 对 Conv0--Conv9 每层输出进行 bit-exact 检查，DDR demo
   进一步验证动态图像输入、层间缓冲和 YOLO decode。

需要注意，后级卷积的 golden 必须由同一条 RTL semantic chain 生成。前级的量化、
激活和池化结果会传播到后级，因此 standalone 层输入不能直接替代链式中间结果。

## 上游项目与致谢

本项目的重要参考之一是 Adam Gallas 等人公开的
[fpga_accelerator_yolov3tiny](https://github.com/adamgallas/fpga_accelerator_yolov3tiny)
项目。该项目提供了完整的 YOLOv3-tiny FPGA 部署示例，其 Python 软件工程中的
口罩检测推理模型、网络训练流程和 INT8 量化方法为本项目的模型准备与量化数据
生成提供了基础。本仓库 `repro/` 中用于复现实验的部署参数和测试数据，源自在该
软件流程基础上完成的模型导出与 RTL 语义整理。

RTL 方面，本项目使用了上游工程的双 INT8 DSP 乘法实现，相关文件为：

- [`cal/cal_mul_int8_x2.v`](cal/cal_mul_int8_x2.v)
- [`cal/cal_mul_int8_x2_dsp.v`](cal/cal_mul_int8_x2_dsp.v)

这两个模块利用一个 DSP 数据通路并行得到两组 INT8 乘积，是 LASA 双输出 lane
PE 的基础计算原语。除上述明确列出的乘法模块外，LASA 面向 KV260/XCK26 重新
设计并实现了层自适应 PE/阵列互连与 RTL 数据通路、KCS 分块、BSD 批量流、
OCRR 片上重排重放、OPF-P 部分和反馈与预取、AXI DMA 系统集成、Vitis 裸机
调度以及 Conv0--Conv9 bit-exact 验证体系。两者的目标平台、整体硬件结构、
调度方式和性能优化路径并不相同。

上游项目采用
[Apache License 2.0](https://github.com/adamgallas/fpga_accelerator_yolov3tiny/blob/main/LICENSE)，
并给出了以下相关论文：

> Xiang Chen, Jindong Li, and Yong Zhao, “Hardware Resource and Computational
> Density Efficient CNN Accelerator Design Based on FPGA,” ICTA 2021.

感谢原作者公开模型训练、量化、软硬件工程和实验资料，为本项目的研究与实现提供
了重要参考。使用或再分发源自上游项目的代码与数据时，请同时遵守其许可证和引用
要求。

## 论文

论文 PDF 位于 [Thesis.pdf](Thesis.pdf)，系统介绍了：

- LASA 层自适应脉动阵列架构；
- KCS 三维分块执行模型；
- BSD、OCRR 和 OPF-P 数据流优化；
- Vitis 运行时、AXI-Lite 配置和性能计数器；
- Conv0--Conv9 正确性验证、端到端性能消融及资源时序结果。

使用本项目开展研究、课程设计或复现实验时，可引用论文题目和本仓库提交版本。

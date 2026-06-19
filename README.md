# KV260 脉动阵列 YOLOv3-tiny 加速器

本仓库包含面向 AMD/Xilinx KV260 的 Verilog RTL 加速器、Vitis 裸机软件、
测试平台、自动化脚本，以及简化版单尺度 YOLOv3-tiny 口罩检测流程的最终
硬件交付产物。

## 当前交付基线

当前主线采用经过稳定上板验证的 raw-HWC replay 设计，对应构建目录：

```text
D:/MPSoC/b_hwcreplay_22
```

固定 DDR 图片测试的板级结果如下：

```text
总延时       ~= 280.340 ms
检测结果     = with_mask，置信度 0.357321
工具链       = Vivado/Vitis 2022.2
目标器件     = KV260 / xck26-sfvc784-2LV-c
```

后续 IFM ping-pong 和双 staging 实验由于未能完成稳定上板验证，未合入默认
主线。相关代码保留在 `experiment-ifm-pingpong-debug-current` 分支中，仅供参考。

## 仓库结构

```text
cal/                     DSP/int8 乘法辅助模块
com/                     公共 RTL 模块
systolic/                加速器 RTL 源码
tb/                      Verilog 与 Python 回归测试
tcl/                     Vivado/xsim 构建和仿真脚本
sw/vitis_2022_2/         裸机运行时、调度器和上板脚本
tools/                   golden 数据、UART 日志和演示分析工具
docs/                    设计说明、数据流、寄存器和测试计划
docs/historical_progress.md
                         早期设计与阶段性实验日志
golden/                  小型回归 golden 数据的版本管理规则
repro/                   最小模型数据、测试图片和期望输出
release/kv260_hwcreplay_22/
                         最终交付的 XSA 与 bitstream
Thesis.pdf               最新论文 PDF
```

## 最终硬件产物

最终交付文件位于：

```text
release/kv260_hwcreplay_22/conv_accel_ps_dma_minimal.xsa
release/kv260_hwcreplay_22/conv_accel_ps_dma_wrapper.bit
```

SHA256：

```text
conv_accel_ps_dma_minimal.xsa
  5CCDCDB264ED9F7F29531C08108617547CA88E7C5F9A4A4A089C6A1D74FF9753

conv_accel_ps_dma_wrapper.bit
  C9CBC381F7906B5ECF206C7CA256276FE30943EAE5A22D0573D1FA244F8EC3D8
```

默认构建脚本使用与交付硬件一致的参数：

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

## 硬件构建

显式使用 Vivado 2022.2：

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' `
  -mode batch `
  -source tcl\build_kv260_system_xck26.tcl `
  -tclargs -build_dir D:/MPSoC/build_repro_hwcreplay_22 -jobs 12
```

生成的 XSA 可供 `sw/vitis_2022_2/` 中的 Vitis 2022.2 软件流程使用。

## 软件构建与上板测试

构建单尺度十层 DDR 演示 ELF：

```powershell
powershell -ExecutionPolicy Bypass `
  -File sw/vitis_2022_2/scripts/manual_build_accel_smoke.ps1 `
  -Mode conv0_conv9_ddr_demo
```

在开发板上运行固定图片 DDR 测试：

```powershell
powershell -ExecutionPolicy Bypass `
  -File sw/vitis_2022_2/scripts/run_kv260_image_demo.ps1 `
  -Image repro\images\maksssksksss0.png `
  -PortName COM8 `
  -BuildDirName D:\MPSoC\b_hwcreplay_22 `
  -CaptureSeconds 240
```

运行逐层 RTL golden 批处理链测试：

```powershell
powershell -ExecutionPolicy Bypass `
  -File sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1 `
  -PortName COM8 `
  -BuildDirName D:\MPSoC\b_hwcreplay_22 `
  -RunConv0Conv9BatchChain `
  -CaptureSeconds 240
```

## RTL 仿真

运行短回归：

```powershell
powershell -ExecutionPolicy Bypass -File tb/run_short_xsim_regression.ps1
```

运行指定的 xsim 测试：

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' `
  -mode batch `
  -source tcl\run_xsim_regression.tcl `
  -tclargs -top tb_conv_accel_core_axi_lite_axis_stream_conv6_3x3_raw_hwc_fulltile_cout16
```

Conv0 至 Conv9 的 Vitis 构建、固定图片 DDR 演示和最终检测解码均使用
`repro/` 中的交付数据包，不依赖原始训练工程。完整模型重新导出和少数历史
定向 RTL 测试仍需外部源数据。生成脚本保留在 `tools/golden/`，完整数据集和
PyTorch checkpoint 不纳入本交付仓库。

## 论文 PDF

最新论文 PDF 位于仓库根目录：

```text
Thesis.pdf
```

## 后续工作

当前稳定设计已包含 raw-HWC replay、pass prefetch、PSUM overlap、column PSUM
和大容量 URAM HWC cache。实测 `compute_fire` 时间仍显著小于 PL 总 busy 时间，
后续优化应重点减少 K-pass 边界的结构性固定开销，不应直接重新启用尚未证明
安全的 IFM ping-pong 或 during-compute prefetch 实验路径。

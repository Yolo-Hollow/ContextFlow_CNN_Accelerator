# Systolic Accelerator 当前状态与后续计划

> 最后更新：2026-06-19

本文档作为当前项目的主入口，只记录当前 RTL 状态、已验证内容、已知限制和后续路线。早期设计记录和按日期整理的阶段性实验过程统一保存在 `historical_progress.md`。

## 主线交接说明

用于项目交接的 RTL/TB/Tcl 主线已恢复到 `D:/MPSoC/b_hwcreplay_22` 使用的稳定 raw-HWC replay 基线；固定 DDR 图片测试的延时约为 `280.34 ms`。后续 IFM ping-pong 和双 staging 实验保留在 `experiment-ifm-pingpong-debug-current` 分支中，但由于未能完成稳定上板验证，不属于默认构建和回归路径。

默认硬件配置如下：

```text
ROWS=18, COLS=8, COUT_TILE=16, IFM_BANKS=2
HWC_CACHE_AW=16, HWC_CACHE_DEPTH=43264, HWC_CACHE_STRIPES=4
HWC_CACHE_USE_URAM=1, TAIL_CYCLES=1
```
## 1. 当前目标

当前目标是实现一个面向简化 YOLOv3-tiny 推理流程的整数卷积加速器。当前 RTL 主链路已经覆盖：

- 流式 IFM 输入；
- 输入零点减法与 signed int8 饱和截位；
- line buffer 与 3x3 window 提取；
- weight-stationary systolic array；
- K 维多 pass 累加；
- 输出通道分块调度；
- requant、activation LUT 和 OFM 写回；
- AXI-Lite 配置和 AXIS/full-stream 测试封装。

近期网络目标还不是完整双尺度 YOLOv3-tiny，而是先完成低分辨率单尺度检测头，概念结构为：

```text
Conv/Pool backbone
  -> Conv 3x3 512 -> 1024
  -> Conv 1x1 1024 -> 256
  -> Conv 3x3 256 -> 512
  -> Conv 1x1 512 -> 3 * (classes + 5)
  -> software box decode
```

对三分类口罩模型，最终检测层输出通道数为：

```text
3 * (3 + 5) = 24
```

当前单尺度候选调度先按低分辨率检测头展开：

| Task | Operation | IFM C | OFM C | Conv | Pool | Notes |
|---:|---|---:|---:|---|---|---|
| 0 | Conv + Pool | 8 | 16 | 3x3/s1/p1 | 2x2/s2 | 输入预处理后补齐到硬件 IFM bank |
| 1 | Conv + Pool | 16 | 32 | 3x3/s1/p1 | 2x2/s2 | backbone downsample |
| 2 | Conv + Pool | 32 | 64 | 3x3/s1/p1 | 2x2/s2 | backbone downsample |
| 3 | Conv + Pool | 64 | 128 | 3x3/s1/p1 | 2x2/s2 | backbone downsample |
| 4 | Conv + Pool | 128 | 256 | 3x3/s1/p1 | 2x2/s2 | backbone downsample |
| 5 | Conv + optional Pool | 256 | 512 | 3x3/s1/p1 | TBD | 原 YOLOv3-tiny 末端 pool 语义需按选定模型确认 |
| 6 | Conv | 512 | 1024 | 3x3/s1/p1 | bypass | low-resolution head |
| 7 | Conv | 1024 | 256 | 1x1/s1/p0 | bypass | channel reduction |
| 8 | Conv | 256 | 512 | 3x3/s1/p1 | bypass | detect pre-head |
| 9 | Conv | 512 | 24 | 1x1/s1/p0 | bypass | 3 anchors * (3 classes + 5) |

YOLO box decode、threshold 和 NMS 先继续放在软件端。

## 2. 当前 RTL 状态

当前已经验证的主数据流为：

```text
IFM stream
  -> input zero-point centering
  -> line buffer
  -> window extraction
  -> IFM FIFO
  -> systolic array
  -> PSUM feedback / drain
  -> requant
  -> activation
  -> OFM writer
```

当前硬件语义：

- 外部 IFM 是 `uint8 activation`。
- 内部 IFM 是中心化后的 signed int8：
  `ifm_s8 = saturate_s8(ifm_u8 - input_zero_point)`。
- padding 越界值是内部 signed zero。
- weight 是 signed int8。
- 累加路径是 int32 PSUM 加 int32 bias。
- requant 使用软件导出的 raw shift，并在 RTL 内部补上定点乘数的小数位：
  `effective_shift = raw_shift + 15`。
- activation 支持 bypass/ReLU/LUT。
- pooling 位于 activation 之后、OFM writer 之前；第一版支持 bypass 和 `2x2` uint8 maxpool stride-2。
- OFM 写回使用 HWC layout。

当前 AXI-Lite 系统顶层已经把真实层运行所需的量化参数和 activation LUT 配置并入 accelerator 自身的 AXI-Lite 地址空间，不再在 BD 中暴露零散的 `quant_wr_*` / `act_lut_wr_*` 顶层端口：

```text
0x80 QUANT_ADDR  [5:0] = quant lane address
0x84 QUANT_DATA  [15:0] mult, [19:16] raw shift, [31:24] output zp
0x88 LUT_ADDR    [7:0] = activation LUT address
0x8c LUT_DATA    [7:0] = activation LUT byte
```

`conv_accel_core` 仍保留 legacy 直接 quant/LUT 编程端口，供非系统 wrapper 和单元测试使用；面向 BD/Vitis 的 `conv_accel_core_axi_lite_axis_stream` 只通过 AXI-Lite 写入这些配置。

## 3. Layer06 真实数据验证

当前最强的真实数据流验证是 YOLOv3-tiny 中间层规模：

```text
52 x 52 x 64 -> 52 x 52 x 128
ROWS = 18
COLS = 16
IFM_BANKS = 2
COUT_TILE = COLS * 2 = 32
```

调度关系：

- `K_TOTAL = 64 * 3 * 3 = 576`。
- `K pass = 576 / 18 = 32`。
- `COUT block = 128 / 32 = 4`。
- 整层空间 tile 下共有 `32 * 4 = 128` 个调度块。
- 完整 OFM 输出字节数为 `52 * 52 * 128 = 346112`。

RTL 仿真当前对比的是 RTL semantic golden，而不是直接对比 PyTorch 导出的 layer output。RTL semantic golden 使用与硬件一致的整数语义：

```text
ifm_s8 = saturate_s8(ifm_u8 - input_zero_point)
psum = sum(ifm_s8 * weight_s8) + int32_bias
q = round(psum * mult / 2^(raw_shift + 15)) + output_zp
ofm = activation_lut[q]
```

当前 RTL semantic golden 与 PyTorch reference 的软件对比结果：

- mismatch：`129 / 346112` bytes；
- 最大绝对差值：`3`；
- mismatch 样本平均绝对差值：约 `1.49`；
- 全部字节平均绝对差值：约 `0.00055`。

这部分差异目前归因于 RTL 使用 int32 bias，而 PyTorch quantized conv 接近 float-bias 语义。RTL 仿真的 pass/fail 标准应以 RTL semantic golden 为准，PyTorch reference 作为模型级 sanity check。

## 4. 已通过测试

requant 与输入零点修正后，以下 xsim 回归已经通过：

- `tb_requant`：覆盖 `effective_shift = raw_shift + 15`、正负数、round、zero-point 和饱和。
- `tb_ofm_requant_writer`：覆盖多 lane requant packet 输出和 output backpressure。
- `tb_conv_accel_core_realistic_small`：确定性端到端卷积数据流。
- `tb_conv_accel_core_spatial_multitile`：spatial tile 地址拼接。
- `tb_conv_accel_core_axi_lite_axis_stream_smoke`：AXI-Lite + AXIS smoke path。
- `tb_conv_accel_core_axi_lite_axis_stream_input_zp`：顶层非零 input zero-point directed test。
- `tb_conv_accel_core_axi_lite_full_stream_input_zp`：full-stream 非零 input zero-point directed test。
- `tb_ofm_pooling`：activation 后 packet-level pooling 单元测试。
- `tb_conv_accel_core_pooling`：core 内部 `Conv -> Requant -> Activation -> Pool -> OFM` directed test。
- `tb_conv_accel_core_axi_lite_axis_stream_pooling`：pool-enabled AXIS 顶层 TLAST/debug byte counter directed test。
- `tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_ext`：真实 Conv0 crop 的 `Conv -> LUT -> Pool -> OFM AXIS` external golden test。
- `tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c8_b2_ext`：同一份真实 Conv0 crop + pool golden，在当前 BD 默认阵列配置 `ROWS=18, COLS=8, IFM_BANKS=2` 下通过。
- `tb_conv_accel_core_axi_lite_quant_lut`：AXI-Lite 间接写读 `QUANT_ADDR/DATA` 和 `LUT_ADDR/DATA`，并检查 legacy quant/LUT 端口兼容性。
- `tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_layer06_ext_tile4`：模型 `layer06_Conv` / 单尺度 `conv3_pool` 的 conv-only 首 tile，在当前 KV260 配置 `ROWS=18, COLS=8, COUT_TILE=16` 下通过。
- `tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_layer06_pool_ext_tile4`：同一真实层打开 activation 后 `2x2/s2` pooling，验证 `52x52x64 -> 52x52x128 -> 26x26x128` 的首个 pooled tile。
- `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_tile4`：Layer06 小 tile 真实 golden。
- `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_tiles`：Layer06 多 spatial tile。
- `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_full`：完整 `52x52x64 -> 52x52x128` 层。

`full_fifo256` 保留为 diagnostic/stress test，不进入默认快速回归。它适合观察长时间运行进度、FIFO 行为和 backpressure 风险。

## 5. BD 与 Vitis 当前状态

当前 BD 仍采用 KV260 最小 PS/DMA 结构：

```text
PS M_AXI_HPM0_FPD
  -> SmartConnect control path
  -> accelerator AXI-Lite / GPIO / 4x AXI DMA control

4x AXI DMA
  bias   DDR -> AXIS
  weight DDR -> AXIS
  IFM    DDR -> AXIS
  OFM    AXIS -> DDR
```

已完成的 BD 侧更新：

- accelerator IP 重新封装后，BD 中不再需要给 quant/LUT 裸端口绑常量 0。
- `tcl/create_ps_dma_bd_xck26.tcl -generate_targets` 已通过 BD validate 和 wrapper generation。
- 当前 validate 是结构检查；真正上板仍需要带 KV260 SOM/carrier preset 重新生成 bitstream 和 XSA。

Vitis 侧当前有多种可构建 smoke ELF：

```text
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_r18_c8_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv0_crop_pool_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv0_crop_pool_tiles_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_layer06_tile4_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_layer06_tiles_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_layer06_pool_tiles_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv4_pool_tiles_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv3_conv4_chain_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv4_conv5_chain_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv0_conv4_chain_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv0_conv5_chain_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv0_conv6_chain_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv0_conv7_chain_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv0_conv8_chain_smoke.elf
build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/conv_accel_conv0_conv9_chain_smoke.elf
```

`conv_accel_r18_c8_smoke.elf` 是旧 deterministic smoke 的更新版，会显式通过 AXI-Lite 写入 identity quant、identity LUT 和 `EXPECTED_BYTES`。`conv_accel_conv0_crop_pool_smoke.elf` 使用真实 Conv0 crop + pool fixture，按当前 BD 默认配置调度：

```text
ROWS=18
COLS=8
IFM_BANKS=2
COUT_TILE=16
```

该 Conv0 fixture 来自外部 golden：

```text
D:/MPSoC/python_prj/rtl_golden/facemask_conv0_crop16x8_pool/xsim_mem
```

小型 fixture 已转为 `sw/vitis_2022_2/src/conv0_crop_pool_data.h`，因此 Vitis smoke 构建不再依赖运行时访问外部 `.mem` 文件。

Layer06 系列 ELF 使用 `sw/vitis_2022_2/scripts/generate_layer06_tile4_header.py` 在 manual build 阶段从外部 `D:/MPSoC/python_prj/rtl_golden/facemask_layer06_rtl` 生成大数组 header。`layer06_tiles` 验证 conv-only 完整 `52x52x128` 输出；`layer06_pool_tiles` 验证单尺度 `conv3_pool`，即 `52x52x64 -> 52x52x128 -> 26x26x128`。

`conv4_pool_tiles` 使用 `sw/vitis_2022_2/scripts/generate_single_scale_layer_header.py` 从外部 `D:/MPSoC/python_prj/rtl_golden/facemask_single_scale_rtl/04_conv4_pool` 生成大数组 header，用于验证下一层 `26x26x128 -> 26x26x256 -> 13x13x256`。该模式仍是单层 smoke，但覆盖了从 `conv3_pool` 输出形状进入下一层 3x3 卷积的调度规模。

`conv3_conv4_chain` 是当前第一条真正的两层串接 smoke：先运行 `conv3_pool` 并把硬件 OFM debug packet 重排成 `26x26x128` feature buffer，再把该 buffer 作为 `conv4_pool` 的 IFM 输入。该模式的 Conv4 expected output 来自新的 chain golden `D:/MPSoC/python_prj/rtl_golden/facemask_chain_conv3_conv4_rtl/04_conv4_pool`，而不是 PyTorch `layer07_pooling` 中间层。

当前最长的链式 smoke 是 `conv0_conv9_chain`，连续执行全部 10 个单尺度硬件卷积层，并在每层结束后将硬件 OFM packet 重排为下一层 IFM。Conv7 和 Conv9 的原生算子是 1x1，硬件使用仅中心位置非零的稀疏 3x3 权重等价执行。Conv9 expected output 来自 `D:/MPSoC/python_prj/rtl_golden/facemask_chain_conv0_conv9_rtl/09_head_detect_conv9_1x1`。下游 golden 必须使用同一条 RTL semantic 链的上游输出生成，不能与 standalone/single-scale golden 混用。

## 6. 已知限制和风险

- 当前 RTL 还不是完整 YOLOv3-tiny 推理系统。
- pooling 第一版已经作为 activation 后、OFM writer 前的可选输出侧后处理模块接入，当前支持 bypass 和 `2x2` uint8 maxpool stride-2。
- pool 打开时，`OFM_SIZE/NUM_PIXELS/TILE_OFM_H` 描述 pool 前 conv output tile，`TILE_PIXEL_BASE` 按最终 pool 后 OFM 地址空间配置。
- 当前验证重点已从卷积数据流、量化语义和写回正确性推进到单尺度检测后处理。
- Vitis runtime 已覆盖 Conv0 到 Conv9 的完整 10 层单尺度卷积链，并在 Conv9 bit-exact 比较通过后，对 `13x13x24` 检测张量执行 YOLO decode、置信度筛选、class-aware NMS 和逆 letterbox。
- 当前 OFM AXIS 仍输出 `{addr[23:0], data[7:0]}` debug packet。它适合验证和软件重排，但不是长期高效的连续 HWC DMA 写回格式。
- 当前 IFM 行填充仍由 PS 轮询 GPIO request 后启动 IFM DMA 服务，尚未实现硬件 DDR reader。
- RTL semantic golden 是硬件 bit-exact 仿真的标准；PyTorch reference 只能作为模型级参考。
- `ifm_u8 - input_zero_point` 饱和到 signed int8 是当前正式硬件近似。Layer06 当前 `sat_count=0`，但后续每层 golden export 都应统计 saturation count。

## 7. 仓库结构与外部数据

当前仓库继续作为 RTL 主工程，核心目录为：

```text
systolic/        RTL 源码
tb/              testbench
tcl/             xsim/Vivado 脚本
docs/            项目文档和测试计划
sw/vitis_2022_2/ 最小 Vitis smoke/runtime 工程
tools/golden/    RTL golden 生成脚本
golden/          小型、稳定、人工筛选后的回归 golden
```

完整 `python_prj` 不直接并入当前仓库。它包含训练/检测工程、数据集、模型权重和大型 golden dump，当前仍作为外部数据根使用：

```text
D:/MPSoC/python_prj
```

`tools/golden/` 中的脚本默认从该外部路径读取模型、权重、数据和已导出的中间层文件，也可以通过 `PYTHON_PRJ` 环境变量或 `--project` 参数覆盖。完整 layer golden 默认继续输出到外部 `python_prj/rtl_golden/`，避免把大文件误提交到 RTL 仓库。

## 8. 后续计划

### RTL 主线

1. 按单尺度网络调度确认是否需要 stride-1 或特殊 pooling。
2. 继续保持无 pooling 路径的默认 ABI 兼容。
3. 评估是否把 OFM debug stream 迁移为连续 HWC OFM AXIS burst，以降低软件重排和 DDR 带宽开销。

### 网络验证主线

1. 保持完整 10 层链式回归及 `13x13x24` HWC/anchor 布局检查。
2. 保持软件 YOLO decode、置信度筛选和 class-aware NMS 回归。
3. 使用更多真实图像输入完成端到端检测结果对照。
4. 评估真实图片加载、批量验证和后处理性能优化。

### 系统集成主线

1. 继续以 `build_system_xck26_kv260_linebuffix` 作为当前板级基线，新增 RTL 后再生成独立命名的构建目录。
2. 每次板子重新上电后完整烧录 bitstream，再运行最长可用链式 smoke 回归。
3. 保留 `probe_pl_regs.tcl` 对 accelerator、DMA、GPIO 和 quant/LUT MMIO 的检查。
4. 等 10 层调度和 buffer ABI 稳定后，再加入 SD 卡或 host-side 参数加载。

## 9. 当前默认策略

- RTL 仿真器使用 xsim。
- pass/fail 使用 RTL semantic golden。
- PyTorch reference 用作模型级对照。
- 完整 Layer06 回归作为 targeted/nightly test。
- 小规模确定性测试和小 tile 真实数据测试作为日常回归。
- 论文、Vitis、workspace 和 RTL 改动分开提交，避免互相混杂。

## 10. 单尺度 Pipeline 准备状态

离线网络级准备和 KV260 上板 smoke 已经推进到以下状态：

- 当前 KV260 日常基线固定为 `ROWS=18, COLS=8, IFM_BANKS=2, COUT_TILE=16`。
- 单尺度 layer list 已固化在 `tools/golden/single_scale_yolov3tiny_layers.json`，覆盖 Conv0 到 13x13 单尺度检测头的 10 个硬件卷积候选层。
- 多层 RTL semantic golden exporter 已加入 `tools/golden/export_rtl_single_scale_golden.py`，默认输出到外部 `D:/MPSoC/python_prj/rtl_golden/facemask_single_scale_rtl`，不把大 binary dump 写入 RTL 仓库。
- 单尺度调度 cross-check 已加入 `tools/golden/verify_single_scale_schedule.py`，用于对齐 JSON layer spec 与 Vitis C plan，并复算 shape、K pass、COUT block、feature buffer、spatial tile、schedule block 和最大 AXIS capture。
- Vitis smoke 已加入 descriptor/scheduler dry-run：`accel_layer_desc_t` 描述单层运行参数，`accel_single_scale_plan` 记录 10 层单尺度调度表，`accel_single_scale_scheduler.h` 在启动时检查 shape 链接、K pass、COUT block、expected bytes 和 ping-pong feature buffer 分配；实际板级 runtime 已完成 Conv0->Conv9 十层连续调度。JSON layer spec 使用 `hardware_kernel/hardware_pad` 显式区分原生 1x1 语义和稀疏 3x3 硬件映射。
- 短回归入口为 `tb/run_short_xsim_regression.ps1`，核心通过标准优先使用 Conv0 crop + pool r18_c8 external golden；r18_c8 deterministic 作为控制面/诊断 smoke，不再单独代表核心正确性。
- 板子恢复后的入口为 `sw/vitis_2022_2/scripts/run_kv260_smoke_sequence.ps1`，流程为 JTAG probe -> bit/ELF download -> UART capture -> PL register probe；默认先跑真实 Conv0 crop + pool，若需要追加旧 deterministic 诊断则使用 `-RunDeterministic`。
- 板子未断电且 PL 已确认烧录后，软件端迭代可使用 `run_kv260_smoke_sequence.ps1 -FastRun`，该路径保留当前 PS/PL 初始化，只 reset A53 并下载 ELF；若重新上电、PL 指示灯异常或 DMA reset 卡在首个 MMIO 访问，应改用完整 bitstream 烧录流程。

已完成的离线验证：

- `export_rtl_single_scale_golden.py --metadata-only` 已对 10 层全部跑通，全部 `sat_count=0`。
- `verify_single_scale_schedule.py` 已通过，当前摘要为 `layers=10, ext_in=519168, fb0=692224, fb1=346112, max_axis=5537792, max_tile_axis=851968, tiles=112, blocks=568`。
- 单尺度检测头映射已修正为 `1.model.20.m.1.weight`，输出 shape 为 `13x13x24`，预计输出 `4056` bytes。
- 三个 Vitis manual ELF 构建通过：`conv_accel_r18_c8_smoke.elf`、`conv_accel_conv0_crop_pool_smoke.elf` 和 `conv_accel_conv0_crop_pool_tiles_smoke.elf`。
- 三个 ELF 启动路径均已接入 10 层 scheduler dry-run，编译期覆盖 deterministic、Conv0 crop + pool 单 tile、Conv0 crop + pool 两 spatial tile 三种模式。
- `tb/run_short_xsim_regression.ps1` 已通过。
- 2026-06-04 上板 deterministic r18_c8 smoke 已复现 mismatch；同配置 xsim 在对齐 `mult=32767, shift=0, zp=0` 后可复现 raw psum mismatch，因此该 fixture 暂作为诊断项处理。
- 2026-06-04 离线复跑 `tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c8_b2_ext` 通过，结果为 `529 pass, 0 fail`，说明当前 r18_c8 真实 Conv0 crop + pool external-golden 路径仍可作为核心正确性依据。
- 2026-06-04 KV260 重新上电后完整烧录 bitstream 并运行 `conv_accel_conv0_crop_pool_smoke.elf` 通过，日志为 `build_system_xck26_kv260/board_smoke_logs/20260604_211655_conv0_crop_pool_COM8.log`；OFM debug 计数为 `expected=512, core_wr=512, axis_wr=512, tlast=1, last_end=512`，软件解析 `512/512` bytes，golden 对比 `0 mismatch`。
- 2026-06-04 `-FastRun` 软件迭代路径已验证通过，日志为 `build_system_xck26_kv260/board_smoke_logs/20260604_213526_conv0_crop_pool_COM8.log`；硬件 debug counter 绝对值会跨 fast run 累加，但软件已打印并校验本次 delta：`core_wr=512, axis_wr=512, tlast=1, last_end=512`。
- 2026-06-05 KV260 完整烧录后运行 `conv_accel_conv0_crop_pool_tiles_smoke.elf`，随后用 `-FastRun -RunConv0Tiles` 复测通过，日志为 `build_system_xck26_kv260/board_smoke_logs/20260605_230557_conv0_crop_pool_tiles_COM8.log`；两个 tile 均为 `expected=256` bytes，delta 均为 `core_wr=256, axis_wr=256, tlast=1, last_end=256`，OFM packet 地址在第二 tile 从 `addr=256` 开始，最终 `ofm full compare=512 bytes` 且 golden 对比 `0 mismatch`。由于 `pad=1, kernel=3`，两个 `tile_ofm_h=4` tile 分别需要 5 条物理 IFM 行/每 K pass，因此总服务计数为 `bias=2, weight=4, ifm=20`。
- 2026-06-06 新增并通过 `tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_layer06_ext_tile4`，在当前 KV260 参数 `ROWS=18, COLS=8, COUT_TILE=16` 下验证真实 Layer06 `52x52x64 -> 52x52x128` 的首个 `tile_ofm_h=4` tile，xsim 结果为 `26641 pass, 0 fail`。
- 2026-06-06 首次上板运行 `conv_accel_layer06_tile4_smoke.elf` 时，卷积和前 1 个 COUT block 服务正常，但 OFM FIFO 在 `gpio2=0x208` 处堵塞。根因确认为 AXI DMA 默认 `C_SG_LENGTH_WIDTH=14`，无法承载 Layer06 tile4 所需的 `26624 * 8 = 212992` bytes OFM debug AXIS capture。
- 2026-06-06 已将 BD 中四个 AXI DMA 的 `c_sg_length_width` 提升为 `23` 并重新生成 KV260 bitstream/XSA；实现报告 `WNS=1.105 ns, TNS=0`，route status 无 routing error，资源为 `CLB LUTs=50764 (43.34%)`, `CLB Registers=44083 (18.82%)`, `BRAM Tile=28.5 (19.79%)`, `DSP=177 (14.18%)`。
- 2026-06-06 新 bitstream 上运行 `conv_accel_layer06_tile4_smoke.elf` 通过，日志为 `build_system_xck26_kv260/board_smoke_logs/20260606_113535_layer06_tile4_COM8.log`；服务计数为 `bias=8, weight=256, ifm=1280`，OFM debug delta 为 `core_wr=26624, axis_wr=26624, tlast=1, last_end=26624`，软件解析 `26624/26624` bytes，golden 对比 `0 mismatch`。
- 2026-06-06 新 bitstream 下用 `-FastRun -RunConv0Tiles` 复测 Conv0 multi-tile 仍通过，日志为 `build_system_xck26_kv260/board_smoke_logs/20260606_114612_conv0_crop_pool_tiles_COM8.log`，说明 DMA length width 改动未破坏既有 Conv0 上板基线。
- 2026-06-06 已实现并上板通过 `conv_accel_layer06_tiles_smoke.elf`，把真实 Layer06 `52x52x64 -> 52x52x128` 拆成 13 个 `tile_ofm_h=4` spatial tile 完整拼回；日志为 `build_system_xck26_kv260/board_smoke_logs/20260606_125905_layer06_tiles_COM8.log`，13 个 tile 均为 `core_wr=26624, axis_wr=26624, tlast=1, last_end=26624` delta，总服务计数为 `bias=104, weight=3328, ifm=19456`，最终 `ofm full compare=346112 bytes` 且 golden 对比 `0 mismatch`。
- 2026-06-06 已补齐单尺度 `conv3_pool` 的离线验证入口：`tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_layer06_pool_ext_tile4` 通过，结果为 `6673 pass, 0 fail`；该测试使用同一份真实 Layer06 conv/LUT 输出生成 `golden_pool2x2s2_u8_hwc.mem`，检查首个 `tile_ofm_h=4` conv tile 的 pooled 输出 `26*2*128=6656` bytes。
- 2026-06-06 已新增 `conv_accel_layer06_pool_tiles_smoke.elf` 构建模式，用于在不改 RTL 的前提下上板验证完整 `52x52x64 -> 52x52x128 -> 26x26x128`，13 个 conv spatial tile 的 pool 后完整输出应为 `86528` bytes。
- 2026-06-06 KV260 完整烧录后运行 `conv_accel_layer06_pool_tiles_smoke.elf` 通过，日志为 `build_system_xck26_kv260/board_smoke_logs/20260606_134340_layer06_pool_tiles_COM8.log`；最后一个 tile delta 为 `core_wr=6656, axis_wr=6656, tlast=1, last_end=6656`，总服务计数为 `bias=104, weight=3328, ifm=19456`，最终 `ofm full compare=86528 bytes` 且 golden 对比 `0 mismatch`。
- 2026-06-06 `run_kv260_smoke_sequence.ps1` 已改为串口捕获看到 `PASS:` 或 `FAIL:` 后提前收尾，避免长测试失败后仍等待整个 `CaptureSeconds`；Vitis runtime 也已在配置前检查 `CTRL.bit0`，若上一次失败残留 busy 状态则直接要求重新烧录/复位 PL，避免 stale register 导致误判。
- 2026-06-06 已导出单尺度 `conv4_pool` RTL semantic golden，路径为 `D:/MPSoC/python_prj/rtl_golden/facemask_single_scale_rtl/04_conv4_pool`；该层为 `26x26x128 -> 26x26x256 -> 13x13x256`，`K_PASSES=64`，`COUT_BLOCKS=16`，输出 `43264` bytes，`sat_count=0`，与 PyTorch reference mismatch 为 `20` bytes。
- 2026-06-06 已新增并通过 `tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_conv4_pool_ext_tile4`，首个 `tile_ofm_h=4` conv tile 的 pool 后输出为 `13*2*256=6656` bytes，xsim 结果为 `6673 pass, 0 fail`，elapsed about `00:01:31`。
- 2026-06-06 已新增 `conv_accel_conv4_pool_tiles_smoke.elf` 构建模式并构建通过；完整上板测试入口为 `run_kv260_smoke_sequence.ps1 -FastRun -RunConv4PoolTiles -CaptureSeconds 2400`。
- 2026-06-06 KV260 `-FastRun -RunConv4PoolTiles` 上板通过，日志为 `build_system_xck26_kv260/board_smoke_logs/20260606_140410_conv4_pool_tiles_COM8.log`；7 个 spatial tile 中前 6 个输出 `6656` bytes，最后一个 2-row 尾 tile 输出 `3328` bytes，总服务计数为 `bias=112, weight=7168, ifm=38912`，最终 `ofm full compare=43264 bytes` 且 golden 对比 `0 mismatch`。
- 2026-06-06 已新增链式 `conv_accel_conv3_conv4_chain_smoke.elf`。首次上板用 standalone Conv4 golden 对比时在 `byte=4415` 失败，说明真实层间测试不能继续使用 PyTorch 中间层作为 Conv4 golden 输入。已用 `conv3_pool` RTL semantic 输出 `golden_pool2x2s2_u8_hwc.bin` 重新生成 chain Conv4 golden。
- 2026-06-06 KV260 `-FastRun -RunConv3Conv4Chain` 上板通过，日志为 `build_system_xck26_kv260/board_smoke_logs/20260606_141427_conv3_conv4_chain_COM8.log`；`conv3_pool full compare=86528 bytes`，随后硬件生成的 `26x26x128` buffer 被直接作为 `conv4_pool` 输入，最终 `conv4_pool full compare=43264 bytes` 且 golden 对比 `0 mismatch`。
- 2026-06-06 已完成下一版 RTL 的 Conv0/Conv7 能力扩展：IFM FIFO 和 PSUM FIFO 默认深度从 `256` 增至 `1024`，地址宽度从 `8` 增至 `10`；`K_TOTAL`/`pass_base_k` 数据通路从 `13` 位增至 `14` 位，可表示 Conv7 采用稀疏 3x3 模拟 1x1 时所需的 `K_TOTAL=1024*3*3=9216`。
- 2026-06-06 `generate_single_scale_layer_header.py` 已加入 `--emulate-1x1-as-3x3`：把原生 1x1 权重展开为仅 3x3 中心位置非零的 KCO 数据，并输出 native/hardware kernel、padding 和 K total 宏。定向 Python 测试已通过。
- 2026-06-06 完整 Conv0 `tile_ofm_h=2` 仿真在扩大 IFM FIFO 后曾停在 PSUM drain；进一步确认当前数据流在计算完成后才统一 drain，因此 PSUM FIFO 同样需要容纳整个 tile。两类 FIFO 均扩大到 1024 后，计算和 drain 可以完整推进。
- 2026-06-06 长 Conv0 仿真进一步暴露 `psum_drain_writer` 的 AXIS 风格握手错误：旧实现会在 `packet_valid` 尚未经历可见的 `valid && ready` 握手时提前推进地址，只有下游产生回压时才会出现重复包或丢包。现已改为保持 `packet_valid/addr/data`，直到真实握手完成再推进；五拍回压定向测试结果为 `17 pass, 0 fail`。
- 2026-06-06 下一版关键离线回归全部通过：完整 Conv0 full-width tile2 为 `3345 pass, 0 fail`，K=9216 调度为 `512 pass, 0 fail`，配置寄存器为 `39/0`，AXI-Lite bridge 为 `67/0`，window extract 为 `165/0`，OFM packet FIFO 为 `196/0`，OFM byte FIFO 为 `36/0`。长测试已加入阶段、数据量和周期心跳日志，便于区分正常计算与死锁。
- 2026-06-06 FIFO/K 位宽/握手修改已完成 KV260 综合、实现、bitstream 和含 bit XSA 导出，独立构建目录为 `build_system_xck26_kv260_fifo1024_k14`。最终 signoff 为 `WNS=0.205 ns, TNS=0, WHS=0.012 ns, THS=0`，route status 为 `82447 fully routed nets, 0 routing errors`。
- 新实现资源为 `CLB LUTs=50246 (42.90%)`、`CLB Registers=44577 (19.03%)`、`BRAM Tile=45.5 (31.60%)`、`DSP=177 (14.18%)`。相对上一版，BRAM 从 `28.5` 增至 `45.5` tiles，LUT 从 `50764` 降至 `50246`，寄存器从 `44083` 增至 `44577`，DSP 不变；时序余量从 `1.105 ns` 降至 `0.205 ns`，但仍满足全部约束。
- FIFO1024/K14 初版 XSA 为 `build_system_xck26_kv260_fifo1024_k14/conv_accel_ps_dma_minimal.xsa`，SHA256 为 `E6C53E4F2EF69A499B5AA237D549F841EB0DEFCFF12BC9137495489D5757ECBC`；实现目录中的 bitstream SHA256 为 `E0863298A244D167B004F39D1A95D0ABB197F78976E45C8E3A2555A4C46A09B4`。该版本随后在 Conv5 tail 验证中暴露 stale line-buffer row 问题，已由后续 `linebuffix` 版本取代。
- 2026-06-06 Conv5 bottom-tail 定向仿真暴露 line buffer 只按 `fy` 标记有效行、未排除上一 K pass 同 `fy` stale row 的问题。`line_buffer_5bank.v` 已在新行写入/advance 时清除其它同 `fy` valid，`tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_conv5_ext_tail_cout16` 修复后为 `227 pass, 0 fail`，并确认 IFM loader 与 feeder window 数据正确。
- 2026-06-06 stale-row 修复后的 KV260 构建目录为 `build_system_xck26_kv260_linebuffix`。实现 signoff 为 `WNS=0.812 ns, TNS=0, WHS=0.010 ns, THS=0`，route status 为 `81692 fully routed nets, 0 routing errors`；资源为 `CLB LUTs=50244 (42.90%)`、`CLB Registers=44051 (18.81%)`、`BRAM Tile=45.5 (31.60%)`、`DSP=177 (14.18%)`。XSA SHA256 为 `2CF40E651FDFF9EBD138DC7EE710C6EE91F2317E23686DA4A721E0909051693A`，bitstream SHA256 为 `152B96EC577FFF908585F8CF81DA5CEDA2C2C5DB2A69D0BC2F56F7C461ED531A`。
- 2026-06-06 `conv4_pool -> conv5` 完整重新烧录上板通过，日志为 `build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_204007_conv4_conv5_chain_COM8.log`；Conv5 `K_TOTAL=2304`、`128` 个 K pass、`32` 个 COUT block，底部 `oy=12, h=1` tail tile 正常，最终 `conv5 full compare=86528 bytes`。
- 2026-06-06 `conv0_pool -> conv4_pool` 在同一 linebuffix bitstream 上完整重新烧录回归通过，日志为 `build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_204216_conv0_conv4_chain_COM8.log`。
- 2026-06-06 `conv0_pool -> conv5` 六层连续上板通过，日志为 `build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_205041_conv0_conv5_chain_COM8.log`；逐层 full compare 为 Conv0 `692224`、Conv1 `346112`、Conv2 `173056`、Conv3 `86528`、Conv4 `43264`、Conv5 `86528` bytes，全部 bit-exact。
- Conv0->Conv5 初次测试曾因 Conv5 使用另一条 standalone Conv4 输出生成的 golden 而出现 mismatch。链式验证必须使用同一硬件语义链的上游输出重新生成下游 golden；当前 Conv5 chain golden 位于 `D:/MPSoC/python_prj/rtl_golden/facemask_chain_conv0_conv5_rtl`。
- 2026-06-06 已使用 `pytorch_env` 和同链 Conv5 输出生成 Conv6 RTL semantic golden，路径为 `D:/MPSoC/python_prj/rtl_golden/facemask_chain_conv0_conv6_rtl/06_head_conv6_3x3`；该层为 `13x13x512 -> 13x13x1024`，`K_TOTAL=4608`、`256` 个 K pass、`64` 个 COUT block、输出 `173056` bytes，`sat_count=0`。
- 2026-06-06 `conv0_pool -> conv6` 七层连续完整烧录上板通过，日志为 `build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_211220_conv0_conv6_chain_COM8.log`。Conv6 四个 spatial tile 的总服务计数为 `bias=256, weight=65536, ifm=311296`，最后一个 `oy=12, h=1` tail 输出 `13312` bytes，最终 `conv6 full compare=173056 bytes`，全链逐层 bit-exact。
- 2026-06-06 已使用同链 Conv6 输出生成 Conv7 原生 1x1 RTL semantic golden，并通过 `--emulate-1x1-as-3x3` 生成中心稀疏 3x3 KCO 权重。展开后权重为 `9216x256`，硬件执行 `512` 个 K pass、`16` 个 COUT block；原生 golden 输出为 `13x13x256 = 43264` bytes，`sat_count=0`。
- 2026-06-06 `conv0_pool -> conv7` 八层连续完整烧录上板通过，日志为 `build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_212154_conv0_conv7_chain_COM8.log`。Conv7 四个 spatial tile 的总服务计数为 `bias=64, weight=32768, ifm=155648`，最后一个 `oy=12, h=1` tail 输出 `3328` bytes，最终 `conv7_sparse3x3 full compare=43264 bytes`，证明中心稀疏 3x3 与原生 1x1 golden bit-exact 等价。
- 2026-06-06 已使用同链 Conv7 输出生成 Conv8 RTL semantic golden，路径为 `D:/MPSoC/python_prj/rtl_golden/facemask_chain_conv0_conv8_rtl/08_head_conv8_3x3`；该层为 `13x13x256 -> 13x13x512`，`K_TOTAL=2304`、`128` 个 K pass、`32` 个 COUT block、输出 `86528` bytes，`sat_count=0`。
- 2026-06-06 `conv0_pool -> conv8` 九层连续完整烧录上板通过，日志为 `build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_213159_conv0_conv8_chain_COM8.log`。Conv8 四个 spatial tile 的总服务计数为 `bias=128, weight=16384, ifm=77824`，最后一个 `oy=12, h=1` tail 输出 `6656` bytes，最终 `conv8 full compare=86528 bytes`，全链逐层 bit-exact。
- 2026-06-06 已使用同链 Conv8 输出生成 Conv9 原生 1x1 RTL semantic golden，并通过 `--emulate-1x1-as-3x3` 生成中心稀疏 3x3 权重。硬件映射为 `K_TOTAL=4608`、`256` 个 K pass、`2` 个 COUT block，最终张量为 `13x13x24 = 4056` bytes，`sat_count=0`。
- 2026-06-06 `conv0_pool -> conv9` 完整 10 层链在 KV260 上完整烧录通过，日志为 `build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_214226_conv0_conv9_chain_COM8.log`。Conv9 四个 spatial tile 的总服务计数为 `bias=8, weight=2048, ifm=9728`；第二个 COUT block 仅含 8 个有效通道，最后一个 `oy=12, h=1` tail 输出 `312` bytes，最终 `conv9_detect_sparse3x3 full compare=4056 bytes`，完整 10 层逐层 bit-exact。
- 2026-06-06 已新增 `tools/golden/yolo_single_scale_decode.py`，直接读取同链 Conv9 `golden_ofm_u8_hwc.bin`，按 `channel=anchor*8+value`、P5/32 anchors、Conv9 反量化参数完成 decode，并输出独立的 RTL-chain `decode_golden.json`。默认阈值为 confidence `0.25`、class-aware NMS IoU `0.45`。
- 2026-06-06 已新增无 Xilinx 依赖的 `yolo_decode.c/.h`，使用固定 507 项候选区和单精度 `expf`，支持模型坐标裁剪、固定图像 `512x366` 的逆 letterbox、稳定 UART 数值格式。`tb/test_yolo_decode.py` 同时覆盖 Python 映射/NMS、C 边界测试和 Python/C 同张量一致性，测试通过。
- 2026-06-06 Conv8 与带后处理的 Conv9 ELF 均重新构建通过，调度 cross-check 保持 `layers=10` 且 Conv9 输出 `4056` bytes。
- 2026-06-06 使用 `build_system_xck26_kv260_linebuffix` 完整重新烧录并完成 Conv0->Conv9 + 后处理验收，最终日志为 `build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_222542_conv0_conv9_chain_COM8.log`。十层仍逐层 bit-exact，Conv9 `full compare=4056 bytes`；UART 输出 1 个 `with_mask`，score `0.357321`，原图坐标约为 `(193.435638,112.213531)-(228.543060,164.534409)`，自动比对在 `0.1` pixel / `1e-4` score 容差内通过。
- 2026-06-06 已新增 `conv0_conv9_ddr_demo` 运行模式。图片包固定写入 DDR `0x10000000`，包含 64-byte 元数据头和 `416x416x3` RGB HWC 量化张量；A53 在运行前校验 magic、版本、尺寸和 FNV-1a checksum。动态模式保留硬件服务计数与 AXIS 长度检查，但跳过只适用于固定图的逐层 golden compare。
- 2026-06-06 固定图 DDR 等价回归通过：包内 `519168` bytes 与原 Conv0 输入逐字节一致，完整重新烧录日志为 `build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_224438_conv0_conv9_ddr_demo_COM8.log`；最终 ELF 复测日志为 `build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_225823_conv0_conv9_ddr_demo_COM8.log`，检测与原 RTL-chain decode golden 完全一致。
- 2026-06-06 已新增 `run_kv260_image_demo.ps1`，自动执行图片 letterbox/量化、JTAG DDR 写入、同一 ELF 推理、UART 解析和 Pillow 绘框。第二张 `400x156` 图片在不重新编译 ELF、不重新烧 bitstream的 `-FastRun` 路径通过，日志为 `build_system_xck26_kv260_linebuffix/board_smoke_logs/20260606_225007_conv0_conv9_ddr_demo_COM8.log`，输出 1 个 `with_mask`，score `0.295050`。
- 2026-06-07 已修复 A53 IFM 软件打包热点：每条 IFM 行只计算一次 bank-to-channel 映射，不再在每个 x/bank 元素上重复扫描 `cin`；`conv0_conv9_ddr_demo` 改用 `-O2` 构建。运行时新增逐层 `XTime` 计数，覆盖 bias/weight/IFM pack、DMA、握手同步、OFM DMA/解析及其余时间。
- 2026-06-07 使用 `build_system_xck26_kv260_linebuffix` 完整重新烧录并运行固定图，日志为 `build_system_xck26_kv260_linebuffix/board_smoke_logs/20260607_132050_conv0_conv9_ddr_demo_COM8.log`。检测结果继续与 RTL-chain decode golden 一致；十层板端累计为 `23.699203 s`。分类汇总为 `other=12.008225 s (50.67%)`、`ofm_parse=5.325749 s (22.47%)`、`ifm_pack=2.300888 s (9.71%)`、`ifm_dma=1.625445 s (6.86%)`、`weight_pack=0.798576 s (3.37%)`，其余 DMA/同步约 `1.64 s`。
- 已新增 `tools/demo/summarize_uart_perf.py`，`run_kv260_image_demo.ps1` 会自动生成 `performance.json`。历史旧版同图串口窗口约 `254 s`，与本次板端计时口径不同，但足以确认原软件打包是主要异常开销；后续性能比较应统一以 `PERF` 行为准。
- 上述 `23.699203 s` 包含大量同步 UART 进度输出，不能作为纯推理基线。DDR demo 已增加 `ACCEL_PERF_ONLY` 模式，只保留错误、`PERF`、`HWPERF`、检测和最终状态记录；在旧 `linebuffix` bitstream 上测得无详细日志基线约 `7.482622 s`。
- 2026-06-07 新增 PL tile 级性能计数器，寄存器 `0x48..0x60` 分别记录 busy、任意外部等待、bias/weight/IFM/OFM 等待和阵列 `compute_fire` 周期。小型寄存器测试为 `43 pass, 0 fail`，AXI-Lite bridge 为 `67 pass, 0 fail`；真实 Conv0 external-golden 使用 xsim 为 `529 pass, 0 fail`，完整 `run_short_xsim_regression.ps1` 通过。
- 性能计数版独立构建目录为 `build_system_xck26_kv260_perfcount`。实现签核为 `WNS=0.232 ns, TNS=0, WHS=0.010 ns, THS=0`，route status 为 `82721 fully routed nets, 0 routing errors`；资源为 `CLB LUTs=50663 (43.26%)`、`CLB Registers=44732 (19.10%)`、`BRAM Tile=45.5 (31.60%)`、`DSP=177 (14.18%)`。XSA SHA256 为 `3622309CBCE1F26CD65769211F74AD998E94A0C07483E7E2C9E03DECF8127455`，bitstream SHA256 为 `CD29B177F85EADD8A85C015CAA1861FB338D8D3C382A28534711F6578550D890`。
- 2026-06-07 完整重新烧录性能计数版并运行固定图通过，日志为 `build_system_xck26_kv260_perfcount/board_smoke_logs/20260607_155114_conv0_conv9_ddr_demo_COM8.log`，汇总位于 `demo_output/20260607_155113_maksssksksss0/performance.json`。检测仍为 1 个 `with_mask`，score `0.357321`，坐标和 RTL-chain decode golden 一致；十层 `PERF` 总计 `7.489041 s`。
- 同次运行 PL 累计 `746344195` busy cycles，其中任意外部等待 `667279241` cycles，即 `89.41%`；阵列有效 `compute_fire` 为 `8739328` cycles，仅占 `1.17%`。IFM 等待 `505499633` cycles，约占 busy 的 `67.73%`；weight 等待 `160782718` cycles，约占 `21.54%`；bias 与 OFM 等待合计低于 `0.15%`。在 100 MHz 下，PL busy 约 `7.463 s`，其中外部服务等待约 `6.673 s`，阵列有效计算约 `0.087 s`。
- 软件侧主要耗时为 `ifm_pack=2.297323 s (30.68%)`、`control=1.660113 s (22.17%)`、`ifm_dma=1.622857 s (21.67%)`、`weight_pack=0.804914 s (10.75%)`、`ifm_sync=0.401887 s (5.37%)`、`weight_dma=0.363073 s (4.85%)` 和 `weight_sync=0.311704 s (4.16%)`。数据证明当前瓶颈不是阵列算力，而是 A53 以细粒度 DMA/GPIO 请求逐次向 PL 分发 IFM 和权重。
- 当前可靠板级边界是完整 Conv0->Conv9 单尺度卷积链、A53 decode/NMS、运行时 JTAG DDR 图片加载和主机可视化。下一阶段不应先扩大阵列；优先把 IFM/weight 服务改为描述符驱动的批量传输、双缓冲或 PL 自主 DDR 读取，使下一批数据与阵列计算重叠，并以 `HWPERF` 的 wait/compute 比例作为验收指标。
- 2026-06-07 已完成 AXI batch stream 与 A53 IFM 双缓冲。新增 `STREAM_CFG` 和三类 expected/completed packet 寄存器；batch 模式中 bias、weight、IFM 各 tile 只启动一次 DMA，packet 边界由固定长度恢复，整条流只在最后一拍使用 TLAST。legacy 单包路径继续保留用于 A/B 回归。
- 首次上板时 Conv0 tile0 停在 IFM `3/6` packet。计数器确认 weight 已提前消费 `2/2` packet，根因是 loader 在同一次保持高电平的请求完成后立即重入。bias、weight、IFM loader 已增加“请求撤销后才能重新武装”的保护；held-high 单测为 `12 pass, 0 fail`，真实 Conv0 batch xsim 为 `532 pass, 0 fail`。
- 当前板级硬件基线为 `build_system_xck26_kv260_batchstream`。实现签核为 `WNS=0.396 ns, TNS=0, WHS=0.010 ns, THS=0`，`0 routing errors`；资源为 `CLB LUTs=50577 (43.18%)`、`CLB Registers=45004 (19.21%)`、`BRAM Tile=45.5 (31.60%)`、`DSP=177 (14.18%)`。XSA SHA256 为 `3123F4C73CF5FF174ACE58212A302F0C96A0E14F2294BA595B9376D6A487234A`，bitstream SHA256 为 `9DDD49DCC8DD83F5E46DDD0B28230963068EF9F832E2A49E583C2A495DE3CBCA`。
- 2026-06-07 完整重新烧录后，batch Conv0->Conv9 固定链逐层 bit-exact，Conv9 `4056` bytes 零 mismatch，UART detection 与 RTL-chain decode golden 一致。日志为 `build_system_xck26_kv260_batchstream/board_smoke_logs/20260607_175823_conv0_conv9_batch_chain_COM8.log`。
- 2026-06-07 在 batchstream 基线上加入原生 18-lane 1x1 feeder。`CONV[16]` 选择该模式，IFM 每像素固定使用三个 64-bit beat，直接写入 18 路 IFM FIFO；3x3 line-buffer 路径保持不变。非法的 legacy/stride/pad/tile-depth 组合会在启动时置配置错误。
- Conv7 已恢复原生 `K_TOTAL=1024, K_PASSES=57`，Conv9 恢复 `K_TOTAL=512, K_PASSES=29`。legacy ELF 仍使用中心稀疏 3x3，batch/DDR ELF 使用原生 KCO 和 `COUT block -> K pass -> tile pixel -> three beats` IFM 流。
- xsim 回归通过：native1x1 小型端到端 `80/0`、Conv0 batch 3x3 `532/0`、真实 Conv7 tile0 `13332/0`、Conv9 尾 tile `332/0`。Conv9 测试同时覆盖最后不足 18 输入通道和第二个不满 16 输出通道的 block。
- 新硬件基线为 `build_system_xck26_kv260_native1x1`。Vivado 2022.2 实现签核为 `WNS=0.496 ns, TNS=0, WHS=0.010 ns, THS=0`，`0 routing errors`；资源为 `CLB LUTs=51064 (43.60%)`、`CLB Registers=45423 (19.39%)`、`BRAM Tile=45.5 (31.60%)`、`DSP=177 (14.18%)`。XSA SHA256 为 `C9DEB010AFAFF1F3CA1DC147A60901C729CF4F98AF5C92FB3238847D7848E9B9`，bitstream SHA256 为 `4A17D41438EF3BAE1046CD4695DF89BA11BA337FEEF93C6CE77B95C3CCC23DE8`。
- 完整重新烧录后的固定链日志为 `build_system_xck26_kv260_native1x1/board_smoke_logs/20260607_194436_conv0_conv9_batch_chain_COM8.log`。Conv0->Conv9 逐层 bit-exact，Conv7 `43264` bytes、Conv9 `4056` bytes 均零 mismatch，检测仍为 `with_mask`、score `0.357321`。
- DDR demo 固定图十层延时为 `1.919672 s`，Conv7 为 `48.380 ms`，Conv9 为 `3.392 ms`。Conv7 vector 统计为 `3648 packets, 154128 pixels, 462384 beats, 0 stall`；Conv9 为 `232 packets, 9802 pixels, 29406 beats, 0 stall`。日志为 `build_system_xck26_kv260_native1x1/board_smoke_logs/20260607_194803_conv0_conv9_ddr_demo_COM8.log`。
- 第二张 `400x156` 动态图片延时为 `1.919409 s`，与固定图相差约 `0.014%`；输出 1 个 `with_mask`，score `0.295050`。日志为 `build_system_xck26_kv260_native1x1/board_smoke_logs/20260607_194941_conv0_conv9_ddr_demo_COM8.log`。
- 2026-06-07 完成纯软件 IFM batch 打包优化：每个 tile 只提取第一个 COUT block 的 IFM 流，其余 block 使用连续 64-bit 复制；3x3 bank-to-channel 映射降为每个 K pass 计算一次。Python 测试确认新旧 3x3/native1x1 流逐字节相同，固定 Conv0->Conv9 batch 链继续逐层 bit-exact，无需重新烧录 PL。
- 优化后固定图十层延时为 `1.340404 s`，IFM pack 从 `1.224793 s` 降至 `43.351 ms`（约 `28.3x`），Conv6 从 `1.162454 s` 降至 `662.747 ms`。第二张图为 `1.340376 s`，差异约 `0.002%`；检测类别、坐标和置信度均不变。日志分别为 `build_system_xck26_kv260_native1x1/board_smoke_logs/20260607_201131_conv0_conv9_ddr_demo_COM8.log` 与 `20260607_201313_conv0_conv9_ddr_demo_COM8.log`。
- 新的墙钟主项为 PL 执行轮询 `control=0.940 s` 和 weight pack `0.158 s`；IFM pack 仅占约 `3.2%`。下一阶段应优先降低 PL weight/IFM wait 与非 compute 周期，或缓存预打包 weight，而不是继续微调 IFM 软件循环。
- 2026-06-07 完成离线 weight 预打包：batch/DDR header 直接按 `COUT block -> K pass -> 18 lanes -> 16 channels` 输出最终 AXI packet 字节序，运行时DMA直接读取ELF只读数组，不再生成或复制weight scratch流；legacy构建仍生成原KCO权重。固定batch链继续逐层bit-exact，无需重新烧录PL。
- 离线weight后固定图十层为 `1.178568 s`，第二张图为 `1.178591 s`，差异约 `0.002%`；`weight_pack_us` 从约 `157.9 ms` 降至 `0`，IFM pack保持约 `43.5 ms`，检测结果不变。日志为 `build_system_xck26_kv260_native1x1/board_smoke_logs/20260607_202932_conv0_conv9_ddr_demo_COM8.log` 与 `20260607_203058_conv0_conv9_ddr_demo_COM8.log`。
- 2026-06-07 已完成 PL 端 64-bit 并行 weight 解包。`axis_bias_weight_loader` 保持原 AXIS weight ABI 和预打包字节序不变，每个 64-bit beat 直接写入 `weight_tile_loader` 的 8 个 byte bank；旧 single-byte tile 写口保留用于 legacy testbench。xsim 单测 `tb_weight_tile_loader` 为 `39 pass, 0 fail`，`tb_axis_bias_weight_loader` 为 `56 pass, 0 fail`；native1x1 端到端小测仍为 `80 pass, 0 fail`。旧 r18_c8 signed-pattern AXIS smoke 在当前 IFM uint8-zero-point 语义下会把负值饱和成 127，继续只作为诊断项，不作为本优化的正确性门禁。
- 新硬件构建目录为 `build_system_xck26_kv260_wgt64`。Vivado 2022.2 实现签核为 `WNS=0.051 ns, TNS=0, WHS=0.002 ns, THS=0`，route status 为 `85275 fully routed nets, 0 routing errors`；资源为 `CLB LUTs=51678 (44.12%)`、`CLB Registers=45389 (19.38%)`、`BRAM Tile=45.5 (31.60%)`、`DSP=177 (14.18%)`。XSA SHA256 为 `9015CD10B6770A26A114DDB10E8DD4E57B4EA13C0205A6335F93309C39F7D225`，bitstream SHA256 为 `4DE8BC99ADBE32976AD8331F2A1A2DD49F70906260135D576B24596BD6458F02`。
- `wgt64` bitstream 完整重新烧录后，固定 batch Conv0->Conv9 链逐层 bit-exact，检测仍与 decode golden 一致；日志为 `build_system_xck26_kv260_wgt64/board_smoke_logs/20260607_220340_conv0_conv9_batch_chain_COM8.log`。DDR demo 固定图十层为 `0.861417 s`，第二张图为 `0.861422 s`，检测类别、坐标和置信度不变；日志为 `20260607_220555_conv0_conv9_ddr_demo_COM8.log` 与 `20260607_220740_conv0_conv9_ddr_demo_COM8.log`。
- 相比离线 weight 基线，`wgt64` 总延时从 `1.178568 s` 降到 `0.861417 s`，约 `1.37x`；PL busy cycles 从 `113846355` 降到 `82125586`，wait 占比从 `42.79%` 降到 `20.71%`，compute 占比从 `6.53%` 升到 `9.05%`。总 weight wait 从约 `359.1 ms` 降到约 `41.9 ms`，Conv6 weight wait 从 `213.647 ms` 降到 `24.904 ms`。当前剩余主瓶颈转为 PL 非 compute 调度/IFM wait/PSUM drain 以及软件端约 `43 ms` IFM pack；下一优先级可评估 double weight buffer、HWC IFM tile cache 或 OFM 连续 HWC 写回。
- 2026-06-07 已新增 `stageperf` 阶段计数版，在不改变数据路径和 AXIS/AXI-Lite 软件 ABI 的前提下，新增只读寄存器 `0xa0..0xb4`，分别统计 bias、weight、feeder、compute stage、PSUM drain 和 OFM post 阶段周期；软件端新增逐层 `STAGEPERF` UART 行，`summarize_uart_perf.py` 已能汇总阶段覆盖率。
- `stageperf` 构建目录为 `build_system_xck26_kv260_stageperf`。本次构建实际使用当前 shell PATH 下的 Vivado `2025.2`；实现签核为 `WNS=0.142 ns, TNS=0, WHS=0.011 ns, THS=0`，route status 为 `86341 fully routed nets, 0 routing errors`；资源为 `CLB LUTs=52301 (44.66%)`、`CLB Registers=45655 (19.49%)`、`BRAM Tile=45.5 (31.60%)`、`DSP=177 (14.18%)`。XSA SHA256 为 `9A15848B42B1BD14B8F15357C529A8137E506BA81A3EAF65A3D1C3851747B24D`，bitstream SHA256 为 `8D58887338B815AF99733150AFDA0FAB3B63DE9845DF72946B28F59AB03E8C0C`。
- `stageperf` bitstream 完整重新烧录后，Conv0->Conv9 batch chain 逐层 bit-exact，日志为 `build_system_xck26_kv260_stageperf/board_smoke_logs/20260607_234056_conv0_conv9_batch_chain_COM8.log`。两张 DDR demo 分别为 `0.861363 s` 与 `0.861369 s`，检测结果保持不变；日志为 `20260607_233758_conv0_conv9_ddr_demo_COM8.log` 与 `20260607_233930_conv0_conv9_ddr_demo_COM8.log`。
- 固定图阶段计数总和为 `82076244` cycles，覆盖 `82076548` busy cycles，覆盖率约 `100.00%`。阶段拆分为：`bias=29904`、`weight=5617752`、`feeder=22054628`、`compute_stage=23844930`、`drain=30102432`、`ofm_post=426598` cycles。由此确认剩余 PL 主耗时已经不是 weight loader，而是 PSUM drain、compute-stage 固定开销和 IFM feeder；下一步优化应优先评估 drain/compute overlap、feeder/IFM tile cache 或更深层的数据流重叠。
- batch DDR demo 的十层推理在两张图片上分别为 `2.866963 s` 和 `2.866821 s`，均低于 `4.0 s`；PL `wait_any` 从 `89.41%` 降至 `43.40%`，DMA 启动汇总降为 bias/weight/IFM/OFM 各 `304` 次。当前最大软件耗时为 `ifm_pack=2.098 s`，下一步应优化 IFM 布局转换或引入 PL 自主 HWC reader，而不是继续优化 DMA 控制。
- 两张动态图均在同一 bitstream 和 ELF 上通过，输出位于 `demo_output/batchstream_maksssksksss0` 与 `demo_output/batchstream_maksssksksss1`。第二张图片通过 JTAG DDR 替换输入，无需重新编译 ELF。

## 11. 历史开发记录

早期架构设计、阶段性实验、性能诊断和已放弃方案统一归档在：

```text
docs/historical_progress.md
```

历史文档用于追溯设计演进，不代表当前默认硬件配置或正式回归路径。

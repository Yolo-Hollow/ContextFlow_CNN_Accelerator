# Systolic Accelerator 当前状态与后续计划

> 最后更新：2026-06-12

本文档作为当前项目的主入口。旧版 `accelerator_systolic.md` 保留早期设计记录和阶段性实验过程；本文档只记录当前 RTL 状态、已验证内容、已知限制和后续路线。

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

## 11. 2026-06-08 drainpipe status

- Implemented pipelined `psum_drain_writer` with unchanged software ABI and unchanged OFM debug packet format. The writer now uses 16-bit internal read/output counters, a one-cycle PSUM read-return tracker, and a one-entry hold register, so it can emit one PSUM packet per cycle when downstream is ready.
- Fixed the `num_pixels == 2^PSUM_BUF_AW` boundary exposed by Conv0 batch tiles (`128` pixels with `AW=7`). Packet addresses still use the low `AW` bits; internal completion counters no longer truncate the tile length to zero.
- Updated partial-PSUM consumers in `conv_layer_top_stream` to use `drain_packet_valid && drain_packet_ready`, and updated the shared realistic testbench to count drain packet handshakes instead of the removed internal drain FSM state.
- Local validation passed: `tb_psum_drain_writer` `203/0`, `tb_layer_config_regs` `70/0`, `tb_axi_lite_cfg_bridge` `81/0`, native1x1 small `80/0`, Conv0 crop+pool batch `532/0`, Conv7 native1x1 tile0 `13332/0`, Conv9 native1x1 tail `332/0`, and r18_c8 Layer06 tile4 `26641/0`.
- New hardware build directory is `build_system_xck26_kv260_drainpipe`. It was generated with Vivado `2025.2` from the active shell. Implementation timing is `WNS=0.348 ns, TNS=0, WHS=0.007 ns, THS=0`; route status is `87410 fully routed nets, 0 routing errors`. Resources are `CLB LUTs=52509 (44.83%)`, `CLB Registers=46731 (19.95%)`, `BRAM Tile=45.5 (31.60%)`, and `DSP=177 (14.18%)`. XSA SHA256 is `A04D7BAA94C1F6F71F457B9EF361887DB042B02744EDBB00E802DA4F4C025634`; bitstream SHA256 is `FF53FB9BB0EA579B37AB7F0D6D59EE66F0A92F4A064E8607B0D4CDEFE416F5FE`.
- Board validation passed after reconnecting UART/JTAG. Full programming with `build_system_xck26_kv260_drainpipe` ran Conv0->Conv9 batch chain bit-exact and matched the Conv9 decode golden; log: `build_system_xck26_kv260_drainpipe/board_smoke_logs/20260608_121308_conv0_conv9_batch_chain_COM8.log`. Two DDR demos were also run with full bitstream programming: fixed image `0.645595 s`, second image `0.645720 s`, with unchanged detections; logs: `20260608_121502_conv0_conv9_ddr_demo_COM8.log` and `20260608_121709_conv0_conv9_ddr_demo_COM8.log`.
- Drainpipe reduced `stage_drain_cycles` from the `stageperf` baseline `30102432` cycles to `8472258` cycles, about `3.55x`; total PL busy dropped to `60503617` cycles and DDR demo latency dropped from about `0.86136 s` to about `0.6456 s`. Stage coverage remains `100.00%`, with `bias=29904`, `weight=5617752`, `feeder=22054628`, `compute_stage=23844930`, `drain=8472258`, `ofm_post=483841` cycles. The new largest PL stages are `compute_stage` and `feeder`, so the next optimization target should shift away from PSUM drain toward feeder/compute overlap or reducing IFM replay overhead.

## 12. 2026-06-08 subperf_2022_2 status

- Project flow is now explicitly pinned to Vivado/Vitis `2022.2` for the reproducible main line. Hardware builds should call `C:\Xilinx\Vivado\2022.2\bin\vivado.bat`; Vitis/XSCT flows should call `C:\Xilinx\Vitis\2022.2\bin\xsct.bat`. The earlier `stageperf` and `drainpipe` Vivado `2025.2` builds remain useful performance references, but are not the formal reproducible baseline.
- Added read-only sub-stage counters at byte offsets `0xb8..0xdc` without changing AXI stream formats, DMA descriptors, layer scheduling, or the main datapath. The new map is `FEED_FILL_WAIT`, `FEED_PUSH`, `FEED_FIFO_STALL`, `FEED_WIN_NOT_READY`, `COMP_WLOAD`, `COMP_ACTIVE`, `COMP_FIRE`, `COMP_IFM_STALL`, `COMP_TAIL`, and `SUBPERF_VERSION`.
- Runtime now prints one `SUBPERF` UART line per layer. `tools/demo/summarize_uart_perf.py` parses these lines and reports feeder/compute sub-stage totals plus residuals against `STAGEPERF`.
- Local validation passed with Vivado `2022.2`: `tb_layer_config_regs` `81/0`, `tb_axi_lite_cfg_bridge` `87/0`, native1x1 small `80/0`, Conv0 crop+pool batch `532/0`, Conv7 native1x1 tile0 `13332/0`, Conv9 native1x1 tail `332/0`, and r18_c8 Layer06 tile4 `26641/0`. `tb/test_kv260_image_demo.py` also covers `SUBPERF` parser aggregation and residual accounting.
- New hardware build directory is `build_system_xck26_kv260_subperf_2022_2`. It was generated with explicit Vivado `2022.2` and closes timing with `WNS=0.302 ns`, `TNS=0`, `WHS=0.010 ns`, `THS=0`, and `0` routing errors. Resources are `CLB LUTs=52254 (44.62%)`, `CLB Registers=46452 (19.83%)`, `BRAM Tile=45.5 (31.60%)`, and `DSP=177 (14.18%)`. The route report shows `86870 fully routed nets`.
- The subperf XSA SHA256 is `ECD4AE2294182AD33C40E2A4C1981940581244F41C210A1903391369121D5A64`; the bitstream SHA256 is `1877EECE3855A6176A7C5C800A1EBA115A21A2E273B9B6E564179600CB779B2A`.
- Board validation passed with full bitstream programming. Conv0->Conv9 batch chain remained bit-exact and matched the Conv9 decode golden; log: `build_system_xck26_kv260_subperf_2022_2/board_smoke_logs/20260608_152628_conv0_conv9_batch_chain_COM8.log`. Two DDR demos were then run with full programming: fixed image `0.646852 s`, second image `0.646994 s`, with unchanged detections; logs: `20260608_153010_conv0_conv9_ddr_demo_COM8.log` and `20260608_152819_conv0_conv9_ddr_demo_COM8.log`.
- Fixed-image aggregate counters were: `busy=60549732`, `compute=12.27%`, `wait=28.67%`, `stage coverage=100.00%`, `bias=29904`, `weight=5617752`, `feeder=22100743`, `compute_stage=23844930`, `drain=8472258`, and `ofm_post=483841` cycles. `SUBPERF` reported `feed_fill=12119827`, `feed_push=7432282`, `feed_fifo_stall=0`, `feed_win_not_ready=0`, `comp_wload=881216`, `comp_active=7432282`, `comp_fire=7432282`, `comp_ifm_stall=0`, `comp_tail=15200976`, `feed_residual=2548634`, and `comp_residual=330456` cycles. `comp_fire` matches the existing compute counter, confirming the new sub-counter wiring.
- The key conclusion is that the feeder path is not blocked by FIFO/window readiness in this run; feeder time is dominated by line/vector fill and useful push. Compute-stage time is dominated by `comp_tail`, not active MAC issue. The next optimization should therefore focus on reducing pass/tile tail overhead or overlapping feeder/compute/tail phases, rather than increasing FIFO depth.

## 13. 2026-06-08 raw HWC IFM cache prototype

- Added an experimental `raw_hwc_mode` under `STREAM_CFG[1]`; `STREAM_CFG[0]` remains batch-stream mode. The default remains `raw_hwc_mode=0`, so existing prepacked IFM streams and board-validated flows are unchanged.
- Added `axis_hwc_tile_cache` for native `1x1` only. In raw mode, the IFM DMA sends one raw `uint8` HWC spatial tile. The PL cache centers bytes with `input_zero_point`, stores them as internal signed int8, and replays 18-lane vectors by `pass_base_k` for each K pass/COUT block. The cache layout is `bank = channel % 18`, `addr = pixel * ceil(cin/18) + channel/18`. The implementation was adjusted to `HWC_CACHE_AW=12` and one synchronous block-RAM bank per lane after Vivado rejected the earlier larger 2-D register-array form; `4096` entries per bank are enough for the tested `13x4x1024` Conv7 tile and `13x1x512` Conv9 tail.
- xsim status: `tb_axis_hwc_tile_cache` `112/0`, `tb_layer_config_regs` `83/0`, `tb_axi_lite_cfg_bridge` `89/0`, `tb_conv_accel_core_axi_lite_axis_stream_native1x1_small` `80/0`, legacy `tb_conv_accel_core_axi_lite_axis_stream_conv9_native1x1_ext_tail` `332/0`, raw-mode `tb_conv_accel_core_axi_lite_axis_stream_conv9_native1x1_raw_hwc_ext_tail` `332/0`, and raw-mode `tb_conv_accel_core_axi_lite_axis_stream_conv7_native1x1_raw_hwc_ext_tile0` `13332/0` all pass under Vivado/xsim `2022.2`. Conv7 raw tile0 loads `6656` 64-bit raw-HWC beats with `raw_stalls=0`; Conv9 tail loads `832` beats with `raw_stalls=0`.
- Software status: `manual_build_accel_smoke.ps1` now has a non-default `-RawHwcIfm` switch. With `ACCEL_RAW_HWC_IFM=1`, native `1x1` batch IFM packing emits one contiguous raw HWC tile and writes `STREAM_CFG=batch|raw_hwc`; default builds do not set this flag. `tb/test_batch_stream_packing.py`, `tb/test_generate_single_scale_layer_header.py`, and `tb/test_kv260_image_demo.py` pass. Both default `conv0_conv9_batch_chain` and `conv0_conv9_batch_chain -RawHwcIfm` manual Vitis builds complete with the existing unused legacy function warning only.
- Implementation/board status: the AW12 block-RAM raw-HWC build was implemented in the short external directory `D:/MPSoC/b_hwc12_22` with explicit Vivado `2022.2`. Timing closes narrowly (`WNS=0.024 ns`, `TNS=0`, `WHS=0.010 ns`, `THS=0`) with `89981` fully routed nets and `0` routing errors. Resources are `CLB LUTs=54655 (46.67%)`, `CLB Registers=46817 (19.99%)`, `BRAM Tile=63.5 (44.10%)`, and `DSP=197 (15.79%)`. XSA SHA256 is `AADE091C3DC341ADBBF1CE62AFA9A7E65BBABB3C69389762CEE09101E6C0DDF7`; bitstream SHA256 is `85859C3F9B6F30998179E37EAE3D771C6CFC6C168ED802A2C34F7C3E0F7C7361`.
- Board validation passed for the experimental `1x1` raw-HWC mode. The useful DDR demo runs in `D:/MPSoC/b_hwc12_22/board_smoke_logs/20260608_191300_conv0_conv9_ddr_demo_COM8.log` and `20260608_191431_conv0_conv9_ddr_demo_COM8.log` were both about `0.6448 s` with unchanged detections and `0` vector stalls. Raw-HWC reduced the software IFM packing component slightly, but did not materially improve end-to-end latency because only Conv7/Conv9 use this first-stage `1x1` cache and the dominant PL cost remains `comp_tail=15200976` cycles. Therefore raw-HWC remains experimental and should not be expanded to `3x3` until the tail overhead is reduced.

## 14. 2026-06-08 tailtrim implementation status

- Implemented first-stage `tailtrim` without changing AXIS data formats, A53 runtime stream ABI, the systolic array, weight/IFM FIFO formats, or OFM packet order. `systolic_ctrl` now has a parameter/runtime-selected tail count; `TAIL_CYCLES_CONFIG=0` preserves the previous `ROWS*5 + COLS*4 + 16` formula (`138` cycles for the current 18x8 build).
- Added the AXI-Lite runtime override at word offset `0x38` and read-only safety counters at byte offsets `0xe0..0xec`: configured tail cycles, elapsed tail cycles, PSUM-drain FIFO-empty wait cycles, and FIFO-empty sticky. Runtime emits one `TAILSTAT` line per layer, and `tools/demo/summarize_uart_perf.py` aggregates it. `SUBPERF_VERSION` is now `2`.
- `run_xsim_regression.tcl` supports `-tail_cycles N` through a generated simulation include, avoiding fragile xsim plusarg syntax on Windows. `build_kv260_system_xck26.tcl`, `create_ps_dma_bd_xck26.tcl`, and `run_synth_xck26.tcl` pass `TAIL_CYCLES_CONFIG` into the hardware build.
- Local validation with Vivado/xsim `2022.2`: `tb_layer_config_regs` `89/0`, `tb_axi_lite_cfg_bridge` `91/0`, Conv9 raw-HWC tail swept through `138, 96, 64, 48, 32, 24, 16, 12, 8, 4, 3, 2, 1` with `332/0` at every value, and `tail_cycles=1` also passed Conv7 raw-HWC tile0 (`13332/0`), Conv0 crop+pool batch (`532/0`), and r18_c16 Layer06 tile4 (`26641/0`).
- Current implementation recommendation is `TAIL_CYCLES_CONFIG=5` (`min_passing + 4` margin) for the first independent build directory `build_system_xck26_kv260_tailtrim_2022_2`. Board validation must still rerun full programming, Conv0->Conv9 batch bit-exact, both DDR demo images, and compare `TAILSTAT`/`SUBPERF` against the `subperf_2022_2` baseline.

## 15. 2026-06-09 packed 3x3 raw-HWC tile cache

- Extended `axis_hwc_tile_cache` beyond native `1x1` to a parameterized `3x3` mode. The default remains `raw_hwc_mode=0`, so the board-validated prepacked IFM path is unchanged unless software explicitly sets `STREAM_CFG[1]`.
- Replaced the initial 18-bank/global-K replication prototype with two logical 72-bit banks. For `3x3`, each address stores a packed nine-byte window for one channel: `group=channel%2`, `byte=kernel_pos`, `addr=(channel/2)*tile_pixels+output_pixel`. Reading both groups returns the 18 values required by one array K pass. Padding and out-of-range window positions are generated as centered signed zero in PL.
- Each logical 72-bit bank is split into four depth stripes so Vivado can infer shallow, non-cascaded URAMs. The Conv6 build uses `HWC_CACHE_AW=14`, `HWC_CACHE_DEPTH=13312`, `HWC_CACHE_STRIPES=4`, and `HWC_CACHE_USE_URAM=1`. The final full-top OOC run maps the cache to exactly `8 URAM`, reports `39.5 BRAM`, `183 DSP`, and closes at `WNS=+1.000 ns` at 100 MHz.
- The raw loader accepts clamped full-width HWC rows once per spatial tile, tracks input x/y explicitly, and scatters each byte into the affected packed windows. Replay also uses explicit output x/y counters, avoiding runtime division/modulo timing paths. The cache capacity requirement for `3x3` is `tile_pixels * ceil(CIN/2) <= HWC_CACHE_DEPTH`.
- Bare-metal layer metadata now has an explicit `raw_hwc_mode` field. `-RawHwcConv6` enables the new path only for Conv6, sends each spatial tile's physical HWC rows once, checks cache capacity, and keeps `-RawHwcIfm` independent for Conv7/Conv9 native `1x1`.
- Vivado/xsim `2022.2` validation passes: cache unit test `259/0`; Conv6 top tile0, first COUT block and all 256 K passes `854/0`; Conv6 bottom `tile_h=1` tile3 `230/0`; Conv7 native `1x1` raw-HWC `13334/0`; and legacy prepacked Conv5 tail `227/0`. Raw Conv6 batch-chain and DDR-demo ELF builds pass with `tail_cycles=1`; the prepacked batch-chain build also remains available for A/B comparison. Host tests for batch packing, native/sparse weight layouts, and the image demo all pass in `conda pytorch_env`.
- The hardware is not keyed to Conv6 and can be enabled for the other current-network `3x3, stride=1, pad=1` layers. The internal software gate is the generic `ACCEL_RAW_HWC_3X3`; `-RawHwcConv6` currently marks only Conv6's layer metadata. All current 3x3 layer tiles fit the 13312-word cache: Conv0 `1664`, Conv1/5/8 `6656`, and Conv2/3/4/6 `13312` words at maximum. Each additional layer still requires xsim and board bit-exact validation before its `raw_hwc_mode` is enabled. Arbitrary stride/pad use is not yet a software-level promise because the current chain descriptors and raw-row selection retain the network's fixed `stride=1, pad=1` semantics.
- Independent build directory: `build_system_xck26_kv260_hwc3x3_uram_tail1_2022_2`, linked to the successful short-path Vivado 2022.2 build. With `TAIL_CYCLES_CONFIG=1`, full implementation closes at `WNS=+0.017 ns`, `TNS=0`, `WHS=+0.010 ns`, and `THS=0`, with `89791` fully routed nets and zero routing errors. Final resources are `54214 LUT`, `46902 FF`, `45.5 BRAM`, `8 URAM`, and `183 DSP`.
- Final artifact hashes are: bitstream `A172432642A3D102AA9355ECC939D249CB79C885B969E07200FB2CCB75BBD591`; XSA `0BD7E3C31E0FDD19FB65F8AC768776D52829F7B4C010B9EC049CC51A74BC8E77`.
- Board validation is pending external connectivity. On June 9, 2026, XSCT reported an empty JTAG chain and Windows exposed no KV260 UART/COM8, so the new bitstream could not be programmed. The first reconnect run must use full programming, not `-FastRun`, then execute raw Conv6 batch-chain, prepacked A/B, and two DDR images.

## 16. 2026-06-12 3x3 raw-HWC cache expansion to Conv5/Conv8

- Extended the bare-metal raw-HWC selection from Conv6-only to explicit per-layer switches: `-RawHwcConv5`, `-RawHwcConv6`, `-RawHwcConv8`, plus `-RawHwc3x3All` for the currently enabled backend 3x3 layers. Default builds still leave `raw_hwc_mode=0`, so the prepacked path remains the fallback.
- `manual_build_accel_smoke.ps1` now emits variant ELF aliases such as `conv_accel_conv0_conv9_batch_chain_raw_hwc_conv6_conv8_smoke.elf` and `conv_accel_conv0_conv9_batch_chain_raw_hwc_conv5_conv6_conv8_smoke.elf`. `run_kv260_smoke_sequence.ps1` accepts the same raw-HWC switches and downloads the matching alias for batch-chain or DDR-demo runs.
- Added lightweight xsim wrappers for Conv5 and Conv8 raw-HWC tile0/tile3 with `COUT_TOTAL=16`. `tb/make_single_scale_xsim_mem.py` gained `--cout-limit` so these small tests emit correctly sliced KCO weights, bias, and HWC golden tensors instead of truncating a full-COUT stream in the wrong order.
- Vivado/xsim `2022.2` validation passed for the four new tests: `tb_conv_accel_core_axi_lite_axis_stream_conv8_3x3_raw_hwc_ext_tile0_cout16`, `...conv8...tile3...`, `...conv5...tile0...`, and `...conv5...tile3...`. The first failed attempt exposed the missing `--cout-limit` support rather than a cache datapath error; after regenerating sliced mem files all four were bit-exact.
- Board validation passed with the existing `build_system_xck26_kv260_hwc3x3_uram_tail1_2022_2` bitstream and `-FastRun` ELF swaps. `Conv6+Conv8` raw-HWC passed Conv0->Conv9 bit-exact and YOLO decode golden comparison; log: `board_smoke_logs/20260612_195828_conv0_conv9_batch_chain_COM8.log`. `Conv5+Conv6+Conv8` raw-HWC also passed; log: `board_smoke_logs/20260612_195954_conv0_conv9_batch_chain_COM8.log`.
- A fixed-image DDR demo with `Conv5+Conv6+Conv8` raw-HWC completed successfully and kept the same detection (`with_mask`, score `0.357321`); log: `board_smoke_logs/20260612_200200_conv0_conv9_ddr_demo_COM8.log`. The ten-layer `PERF total_us` sum was `544.118 ms`.
- Layer-level effect in the bit-exact smoke is as expected: Conv5 IFM pack+DMA dropped from about `3.827 ms` to `0.031 ms`, Conv8 from about `3.819 ms` to `0.033 ms`, and both report `VECTORSTAT packets=4`, `beats=7904`, `fifo_stall_cycles=0`. Conv6 remains raw-HWC with `packets=4`, `beats=15808`, `fifo_stall_cycles=0`.
- The main remaining backend-layer costs are not software IFM packing anymore. In the DDR demo, Conv5 and Conv8 are about `59.17 ms` each and Conv6 about `222.07 ms`; their `control_us` values still dominate because PL feeder/replay, weight, compute, and drain stages remain serialized inside each tile. The next optimization target should therefore be PL-side overlap/replay/drain scheduling rather than more A53 packing work for these three layers.

## 17. 2026-06-12 Conv4 raw-HWC cache validation and expansion stop point

- Added a verified `-RawHwcConv4` path for the existing `build_system_xck26_kv260_hwc3x3_uram_tail1_2022_2` bitstream. The switch is non-default and can be combined with `-RawHwcConv5`, `-RawHwcConv6`, and `-RawHwcConv8`. `-RawHwc3x3All` now covers the currently validated backend set `Conv4/5/6/8`; Conv3 and earlier layers remain disabled until their own validation is complete.
- Conv4 uses the full-chain dynamic tile shape, not the old standalone `conv4_tiles[7]` shape. The active schedule is four pre-pool conv tiles with `tile_ofm_h=8,8,8,2`; the largest tile requires `26*8*ceil(128/2)=13312` cache words, exactly matching the current HWC cache capacity.
- `tb/make_single_scale_xsim_mem.py` now reshapes golden output using `shape.final_ofm_hwc` when present. This fixes pooled layers such as Conv4, whose golden is `13x13x256` even though the conv output shape is `26x26x256`.
- Added Conv4 raw-HWC xsim wrappers for the largest tile and bottom tile: `tb_conv_accel_core_axi_lite_axis_stream_conv4_3x3_raw_hwc_ext_tile0_cout16` and `...tile3_cout16`. Both passed under Vivado/xsim `2022.2`: tile0 `854 pass, 0 fail`, tile3 `230 pass, 0 fail`.
- A first xsim attempt used an IFM FIFO depth of `128` and stalled at replay pixel `128`. The actual board build has `IFM_FIFO_DEPTH=1024`, and the Conv4 wrapper was corrected to `256` for the lightweight test. This was a testbench capacity error, not a cache datapath error.
- Board bit-exact validation passed with `Conv4+Conv5+Conv6+Conv8` raw-HWC enabled. Log: `build_system_xck26_kv260_hwc3x3_uram_tail1_2022_2/board_smoke_logs/20260612_204228_conv0_conv9_batch_chain_COM8.log`. Conv9 decode still matches the RTL-chain golden detection.
- Fixed-image DDR demo also passed with unchanged detection (`with_mask`, score `0.357321`). Log: `build_system_xck26_kv260_hwc3x3_uram_tail1_2022_2/board_smoke_logs/20260612_204403_conv0_conv9_ddr_demo_COM8.log`. Ten-layer `PERF total_us` sum was `548.925 ms`.
- Conv4 software IFM work was eliminated as intended: baseline `Conv5/6/8` raw run had Conv4 `ifm_pack_us=2602`, `ifm_dma_us=421`; the Conv4 raw run reduced this to `ifm_pack_us=42`, `ifm_dma_us=12`. However, Conv4 `control_us` increased from `32662` to `41107`, and layer total rose from `37.201 ms` to `42.008 ms`. End-to-end latency therefore worsened slightly from `544.118 ms` to `548.925 ms`.
- A Conv3 raw-HWC attempt was started but not kept in the formal switches. The lightweight xsim progressed through cache load and the first K pass (`compute_fire=416`) but then stopped making progress in the compute stage. Because this path was not bit-exact validated, the Conv3 switch and diagnostic wrapper were removed from the committed surface.
- Current conclusion: raw-HWC cache is functionally extendable beyond Conv6, and Conv4/5/6/8 are now verified. But expanding to earlier pooled 3x3 layers is not automatically a performance win because PL replay/control cost can exceed the A53 packing saved. The next high-value direction is to reduce or overlap PL feeder/replay/compute/drain stages before enabling Conv3/2/1/0.

## 18. 2026-06-13 raw-HWC replay diagnostic status

- Rebuilt the default `conv0_conv9_ddr_demo` ELF and reran full bitstream programming on the unchanged `build_system_xck26_kv260_hwc3x3_uram_tail1_2022_2` hardware to capture a true prepacked baseline for the fixed image package. Log: `build_system_xck26_kv260_hwc3x3_uram_tail1_2022_2/board_smoke_logs/20260613_182559_conv0_conv9_ddr_demo_COM8.log`. The run passed with the unchanged `with_mask` detection and summed `PERF total_us=576.336 ms`.
- Comparable fixed-image totals on the same bitstream are now: pure prepacked `576.336 ms`, `Conv5/6/8 raw-HWC` `544.118 ms`, and `Conv4/5/6/8 raw-HWC` `548.925 ms`. This confirms that backend raw-HWC is useful overall, but Conv4 raw-HWC alone adds PL replay/control cost.
- RTL review confirmed the current scheduler boundary is strictly serialized: `layer_scheduler_stream` waits in `ST_FEED_WAIT` for `feeder_done` before issuing `compute_start`. In raw/vector mode, `systolic_top_feeder` keeps `vector_fill_req` asserted until `vector_packet_done`, so cache replay fills the IFM FIFO before compute begins.
- Added read-only raw-HWC diagnostic counters at byte offsets `0xf0..0xfc`: `RAW_LOAD_ACTIVE`, `RAW_LOAD_UNPACK`, `RAW_REPLAY_ACTIVE`, and `RAW_REPLAY_WAIT_READY`. The runtime now prints a `RAWSTAT` line per layer, and `tools/demo/summarize_uart_perf.py` aggregates it.
- These counters are diagnostic only and do not change AXIS formats, DDR scratch layout, layer scheduling, replay data order, compute, drain, or OFM output. The next hardware build should use them to decide whether replay/compute overlap is safe and worthwhile.
- Local validation so far: `tb_layer_config_regs` `93/0`, `tb_axis_hwc_tile_cache` `259/0`, `tb_axis_ifm_vector_loader` `14/0`, and `tb_conv_accel_core_axi_lite_quant_lut` `20/0` all pass under Icarus. Vivado/xsim `2022.2` passes Conv4 raw-HWC tile0 (`854/0`) and Conv6 raw-HWC tile0 (`854/0`) with `tail_cycles=1`. Default `conv0_conv9_ddr_demo`, `Conv5/6/8 raw-HWC`, and `Conv4/5/6/8 raw-HWC` ELF builds pass with the existing unused legacy `run_one_tile` warning. In `conda pytorch_env`, direct script tests pass for `test_kv260_image_demo.py`, `test_batch_stream_packing.py`, and `test_generate_single_scale_layer_header.py`; YOLO decode C unit and host decode comparison also pass when gcc is run outside `conda run`. The environment does not currently have the `pytest` package installed.
- Built and programmed a dedicated diagnostic bitstream in `build_system_xck26_kv260_rawstat_2022_2` using Vivado `2022.2`, `HWC_CACHE_AW=14`, `HWC_CACHE_DEPTH=13312`, `HWC_CACHE_STRIPES=4`, `HWC_CACHE_USE_URAM=1`, and `TAIL_CYCLES_CONFIG=1`. Final implementation completed with `0` routing errors and all timing constraints met (`WNS=0.000 ns`, `TNS=0`, `WHS=0.010 ns`, `THS=0`). Final resources are `45.5 BRAM`, `8 URAM`, and `183 DSP`; the XSA is `build_system_xck26_kv260_rawstat_2022_2/conv_accel_ps_dma_minimal.xsa`.
- Board validation passed after full bitstream programming for `Conv5/6/8 raw-HWC` with the fixed `maksssksksss0` DDR package. Log: `build_system_xck26_kv260_rawstat_2022_2/board_smoke_logs/20260613_193856_conv0_conv9_ddr_demo_COM8.log`. The detection remained `with_mask` with score `0.357321`, and the ten-layer sum was `544.576 ms`, matching the previous `544.118 ms` baseline within normal run-to-run variation.
- A fast-run A/B test with `Conv4/5/6/8 raw-HWC` also passed. Log: `build_system_xck26_kv260_rawstat_2022_2/board_smoke_logs/20260613_194053_conv0_conv9_ddr_demo_COM8.log`. The ten-layer sum was `549.328 ms`, again matching the previous `548.925 ms` result.
- RAWSTAT confirms the Conv4 slowdown mechanism. In the `Conv4/5/6/8` run, Conv4 software IFM work was reduced to `ifm_pack_us=52` and `ifm_dma_us=12`, but the raw cache path reported `load_active=971792`, `load_unpack=958464`, `replay_active=1384448`, and `replay_wait_ready=0` cycles. Conv4 `feeder_cycles` rose to `2376396` and the layer total was `41.988 ms`.
- For Conv6, the same run reported `load_active=1153984`, `load_unpack=1138176`, `replay_active=5537792`, and `replay_wait_ready=0` cycles. This shows the current raw-HWC cost is not IFM FIFO backpressure; replay is successfully pushing data, but it is still serialized ahead of compute by the scheduler boundary.
- Next implementation direction: keep `Conv5/6/8 raw-HWC` as the useful backend baseline, keep `Conv4 raw-HWC` as a diagnostic switch, and implement a controlled raw-HWC replay/compute overlap. The intended change is to let compute start once the IFM FIFO has a safe watermark while replay continues filling, preserving packet order and all current A53/AXIS interfaces.

## 19. 2026-06-13 raw-HWC replay/compute overlap prototype

- Added a configurable raw-HWC overlap watermark to `TAIL_CONFIG`: byte offset `0xe0`, low half `[15:0]` remains the tail-cycle override and high half `[31:16]` is `raw_hwc_compute_start_level`. After board testing, the default hardware/software value is now `0`, which disables overlap and restores the fully serialized scheduler boundary. Nonzero values remain experimental.
- `systolic_top_feeder` now reports `feeder_compute_ready` in raw/vector mode after it has pushed at least the configured number of pixel vectors into the IFM FIFOs. `layer_scheduler_stream` can issue `compute_start` once that watermark is reached, but it still blocks `psum_drain_start` until both `compute_done` and the feeder-done event have been observed. This preserves the existing PSUM drain/output order while allowing replay and compute to overlap.
- The top-level wrappers pass the watermark through the existing configuration path; no DMA format, layer descriptor, prepacked IFM format, raw-HWC tile format, OFM packet format, or quantization semantic changes are introduced.
- Runtime/build support has a new `-RawHwcComputeStartLevel` option in `manual_build_accel_smoke.ps1` and matching `ACCEL_RAW_HWC_COMPUTE_START_LEVEL` macro handling. Existing raw-HWC switches (`-RawHwcConv4/5/6/8`) remain opt-in.
- Local validation: `tb_layer_config_regs`, `tb_axi_lite_cfg_bridge`, `tb_layer_scheduler_stream`, `tb_layer_scheduler_overlap`, `tb_systolic_top_feeder_singlepass`, and `tb_systolic_top_feeder_multipass_stream` all pass under Icarus. The overlap check now covers both orderings: compute finishing before feeder-done, and feeder-done arriving before compute completion.
- The Icarus regression driver now treats simulator `FATAL` or `[FAIL]` output as a real failure, fixing a false-pass condition seen while developing `tb_layer_scheduler_overlap`.
- Synthesized and implemented a dedicated Vivado `2022.2` build in `build_system_xck26_kv260_hwcoverlap_2022_2` with `HWC_CACHE_AW=14`, `HWC_CACHE_DEPTH=13312`, `HWC_CACHE_STRIPES=4`, `HWC_CACHE_USE_URAM=1`, and `TAIL_CYCLES_CONFIG=1`. Implementation completed with all timing constraints met: `WNS=+0.143 ns`, `TNS=0`, `WHS=+0.010 ns`, `THS=0`, and `0` routing errors. Final resource use is `54145 LUT`, `47037 FF`, `45.5 BRAM`, `8 URAM`, and `183 DSP`.
- Artifact hashes: XSA `010D703591D7F1322E474ABEDEBDED956EE237B50C5D2B0B8B406C0C1F487B26`; bitstream `2567A1C61D98D2A1F53CF17D1D6E552E7E5D8AEA15106AD43A23D48DE0ED2A14`.
- Board validation on `COM8` with full PL programming found that the first `RawHwcComputeStartLevel=64` RTL was not safe: Conv0-4 completed, then Conv5 raw-HWC tile0 timed out with `CTRL=0x00000001`. Rebuilding only the ELF with `RawHwcComputeStartLevel=0` on the same bitstream passed the fixed-image DDR demo with unchanged `with_mask` detection and total `PERF total_us=544.490 ms`, matching the serialized raw-HWC baseline.
- A second nonzero test with `RawHwcComputeStartLevel=1024` also timed out at Conv5 tile0. Debug reads while stuck showed `TAIL_CONFIG=0x04000001`, `VECTOR_PACKETS=1`, `VECTOR_PIXELS=52`, `COMP_FIRE=52`, `STAGE_DRAIN=0`, `RAW_REPLAY_ACTIVE=104`, and `RAW_LOAD_ACTIVE` still accumulating. The most likely control-plane issue is that overlap mode let compute start early, but `layer_scheduler_stream` only sampled the one-cycle `feeder_done` pulse in `ST_COMP_WAIT`; if feeder-done arrived before compute-done, the scheduler never started PSUM drain.
- Scheduler fix in progress: `layer_scheduler_stream` now latches a per-pass `feeder_done_seen` event and drains once both `compute_done` and the feeder completion event have been observed. Vivado/xsim `2022.2` passes with `-raw_hwc_compute_start_level 64` for Conv5 tile0 (`tb_conv_accel_core_axi_lite_axis_stream_conv5_3x3_raw_hwc_overlap64_ext_tile0_cout16`, `854/0`), Conv6 tile0 (`854/0`), and Conv8 tile0 (`854/0`).
- The first long-path build directory `build_system_xck26_kv260_hwcoverlap_credit_2022_2` hit the Windows 260-character path limit while writing OOC IP checkpoints. Rebuilding the same RTL in the short external directory `D:/MPSoC/b_ovcred_22` with Vivado `2022.2` passed synthesis, implementation, and bitstream generation. Timing closes with `WNS=+0.155 ns`, `TNS=0`, `WHS=+0.010 ns`, `THS=0`, and `0` routing errors over `89920` fully routed nets. Resource use is `54095 LUT`, `47035 FF`, `45.5 BRAM`, `8 URAM`, and `183 DSP`.
- Credit-fix artifact hashes: XSA `E5A1FB0BB1509C9D090CEF6781AB31185B17AEA08794ECA8AD5FBD53C8C02B8A`; bitstream `4ABDD8736868B8571417AFC8D1B9E56D63D9EFD6898F69CCF982B2077FCC66CC`.
- Board validation with the credit-fix bitstream passed for `Conv5/6/8 raw-HWC` on the fixed `maksssksksss0` DDR package. Full programming with `RawHwcComputeStartLevel=64` completed without the previous Conv5 tile0 timeout; log `D:/MPSoC/b_ovcred_22/board_smoke_logs/20260613_221152_conv0_conv9_ddr_demo_COM8.log`. The detection stayed `with_mask` score `0.357321`, `compute_wait_ifm=0`, `RAWSTAT replay_wait_ready=0`, and the ten-layer total was `542.448 ms`.
- Control run on the same bitstream with `RawHwcComputeStartLevel=0` also passed; log `D:/MPSoC/b_ovcred_22/board_smoke_logs/20260613_221401_conv0_conv9_ddr_demo_COM8.log`. Total was `544.415 ms`, so overlap64 is functionally safe after the latch fix but only improves this image by about `1.97 ms` (`0.36%`). The final generated raw-HWC Conv5/6/8 DDR-demo ELF alias was rebuilt with `RawHwcComputeStartLevel=64`.
- Current conclusion: the latch fix resolves the observed deadlock and makes nonzero overlap board-safe for this backend raw-HWC set. The performance gain is too small to make this the next major optimization path by itself; follow-up should inspect why `drain_empty_wait` remains large and whether a stronger replay/compute/drain overlap or PSUM/OFM scheduling change can reduce the dominant drain-side bubbles.

## 20. 2026-06-13 PSUM drain sub-performance counters

- Raw-HWC replay/compute overlap is no longer the immediate optimization focus.
  The useful backend configuration remains `Conv5/6/8 raw-HWC`; the
  credit-fixed `RawHwcComputeStartLevel=64` path is functional, but the fixed
  image gain is only about `1.97 ms`.
- Added a drain observability pass without changing PSUM, OFM, DMA, AXIS, or
  quantization semantics. `psum_drain_writer` now exports FIFO read fire,
  downstream packet fire, downstream ready stall, and internal output/skid-full
  wait pulses. The existing `DRAIN_EMPTY_WAIT` counter remains the FIFO-empty
  component.
- The AXI-Lite config address path was widened from 8-bit byte addresses to
  9-bit byte addresses so the register map can extend past `0xff`. The bridge
  now maps AXI byte address `[8:2]` to internal `cfg_addr[6:0]`. A normal
  Vivado/BD rebuild is required before board use.
- New read-only byte offsets:

```text
0x100 DRAIN_READ_FIRE
0x104 DRAIN_PACKET_FIRE
0x108 DRAIN_READY_STALL
0x10c DRAIN_INTERNAL_FULL
0x110 DRAINPERF_VERSION
```

- Vitis runtime prints one `DRAINPERF` line per layer and accumulates the same
  fields in `TILEPERF`. `tools/demo/summarize_uart_perf.py` parses the new
  line and reports:

```text
drain_residual = STAGE_DRAIN
               - packet_fire
               - ready_stall
               - internal_full
               - empty_wait
```

- Local validation completed so far: `tb_layer_config_regs`,
  `tb_axi_lite_cfg_bridge`, `tb_psum_drain_writer`, and
  `tb_layer_scheduler_overlap` pass under Icarus; Python tests pass for batch
  stream packing, single-scale header generation, and UART performance parsing;
  the `conv0_conv9_ddr_demo` ELF rebuild passes; Vivado/xsim `2022.2` passes
  `tb_conv_accel_core_axi_lite_quant_lut` and
  `tb_conv_accel_core_axi_lite_axis_stream_conv5_3x3_raw_hwc_overlap64_ext_tile0_cout16`
  (`854/0`).
- Known diagnostic caveat: some older direct-core/top Icarus benches still have
  legacy expectation mismatches unrelated to the new drain counters. The next
  hardware step is a 2022.2 rebuild and board run to capture real `DRAINPERF`
  lines on the current `Conv5/6/8 raw-HWC` baseline.
- A dedicated Vivado `2022.2` implementation for this counter build completed
  in the short external directory `D:/MPSoC/b_drainperf_22` with
  `HWC_CACHE_AW=14`, `HWC_CACHE_DEPTH=13312`, `HWC_CACHE_STRIPES=4`,
  `HWC_CACHE_USE_URAM=1`, and `TAIL_CYCLES_CONFIG=1`. Timing closes with
  `WNS=+0.271 ns`, `TNS=0`, `WHS=+0.010 ns`, and `THS=0`; route status reports
  `90284` fully routed nets and `0` routing errors. Final resources are
  `54476 LUT`, `47194 FF`, `45.5 BRAM`, `8 URAM`, and `183 DSP`.
- Drainperf artifact hashes: XSA
  `BDEDEF2226F57FC047B8F0931DA51ADD56EEE31DA879093FDD5C4721A523960D`; bitstream
  `67C8BFD169DF83FF346963BC1BE20E60D31CEF57ED75816EFAEBE55784DB1147`.
- Board validation passed on `COM8` with full programming of the drainperf
  bitstream and `Conv5/6/8 raw-HWC`, `RawHwcComputeStartLevel=64`. Fixed-image
  DDR demo log:
  `D:/MPSoC/b_drainperf_22/board_smoke_logs/20260613_231413_conv0_conv9_ddr_demo_COM8.log`.
  The dynamic inference run completed successfully with total
  `PERF total_us=543.006 ms`.
- A fast-run `conv0->conv9` batch-chain on the same programmed bitstream also
  passed RTL-golden bit-exact and YOLO decode comparison. Log:
  `D:/MPSoC/b_drainperf_22/board_smoke_logs/20260613_231623_conv0_conv9_batch_chain_COM8.log`.
- The new board counters explain the backend drain cost. For the DDR demo,
  total `STAGE_DRAIN=16073864` cycles and `DRAINPERF` reports
  `read_fire=7432282`, `packet_fire=7432282`, `ready_stall=489216`,
  `internal_full=483756`, `empty_wait=7601606`, and residual `67004` cycles.
  For the raw-HWC backend layers specifically, Conv5/Conv6/Conv8 have
  `ready_stall=0` and `internal_full=0`; their drain bubbles are dominated by
  `empty_wait` (`1208320`, `4833280`, and `1208320` cycles). This points away
  from OFM downstream backpressure and toward PSUM availability / drain-start
  scheduling as the next optimization target.

## 21. 2026-06-14 experimental early PSUM drain

- Added an opt-in early-drain scheduler mode under `STREAM_CFG[2]`. The default
  remains `0`, preserving the board-validated serialized behavior. Vitis build
  scripts expose this as `-EarlyDrain`, which defines `ACCEL_EARLY_DRAIN=1` and
  sets the stream config bit only for experimental ELF variants.
- The scheduler can now start `psum_drain_writer` while compute is still in
  progress once the current pass has begun producing PSUM data. It still waits
  for feeder completion, compute completion, and drain completion before moving
  to the next K/COUT block, so early drain never crosses a pass boundary.
- Local validation: Icarus passes `tb_layer_config_regs`,
  `tb_axi_lite_cfg_bridge`, `tb_layer_scheduler_early_drain`,
  `tb_layer_scheduler_overlap`, and `tb_psum_drain_writer`. Vivado/xsim
  `2022.2` passes Conv5/Conv6/Conv8 raw-HWC tile0 with
  `RawHwcComputeStartLevel=64` and early drain enabled; each reports
  `854 pass, 0 fail`.
- The 2022.2 implementation is in `D:/MPSoC/b_earlydrain_22` using
  `HWC_CACHE_AW=14`, `HWC_CACHE_DEPTH=13312`, `HWC_CACHE_STRIPES=4`,
  `HWC_CACHE_USE_URAM=1`, and `TAIL_CYCLES_CONFIG=1`. Timing closes with
  `WNS=+0.181 ns`, `TNS=0`, `WHS=+0.010 ns`, and `THS=0`. Final resources are
  `54437 LUT`, `47179 FF`, `45.5 BRAM`, `8 URAM`, and `183 DSP`.
- Artifact hashes: XSA
  `5765F4A5E962FC0BBB86B57CFD06A7B6FB6BC06E210F275172ABD7D1F9D5AF2B`; bitstream
  `00E2C5DC49005C83D4DB0514BF93B67D9264A973F007B8AC3F2C8F8A42BA2FFE`.
- Board validation passed on `COM8`. Full-programming DDR demo for
  `maksssksksss0` passed with unchanged `with_mask` detection and total
  `PERF total_us=520.446 ms`; log
  `D:/MPSoC/b_earlydrain_22/board_smoke_logs/20260614_000915_conv0_conv9_ddr_demo_COM8.log`.
  A second-image FastRun DDR demo for `maksssksksss1` passed at
  `520.505 ms`; log
  `D:/MPSoC/b_earlydrain_22/board_smoke_logs/20260614_001239_conv0_conv9_ddr_demo_COM8.log`.
  The batch-chain FastRun also passed RTL golden and YOLO decode comparison;
  log `D:/MPSoC/b_earlydrain_22/board_smoke_logs/20260614_001057_conv0_conv9_batch_chain_COM8.log`.
- Compared with the `b_drainperf_22` baseline (`543.006 ms`), early drain saves
  about `22.6 ms` on the fixed image. Per-layer Conv5/6/8 `DRAINPERF empty_wait`
  remains `1208320/4833280/1208320` cycles, so this optimization mainly hides
  part of the drain wait under compute rather than making PSUM production faster.
  The remaining bottleneck is still feeder/compute/drain serialization around
  PSUM availability.

## 22. 2026-06-14 experimental K-pass prefetch

- Added an opt-in next-K prefetch mode under `STREAM_CFG[3]`. Default remains
  `0`; the board-validated early-drain path is unchanged unless software builds
  an experimental ELF with `-PassPrefetch`.
- The first implementation targets the current useful backend path only:
  `Conv5/6/8 raw-HWC`, `RawHwcComputeStartLevel=64`, and `-EarlyDrain`.
  It does not change DMA packet formats, raw-HWC tile layout, OFM packet order,
  quantization, or layer schedule.
- The scheduler now has separate execution and feeder pass indices. Compute,
  PSUM, final-pass decisions, and debug current-pass reporting still use the
  current execution K pass, while raw-HWC replay can use `feeder_pass_base_k`
  for the next K pass. Prefetch never crosses a COUT-block boundary and never
  starts next-pass compute before the current pass drain has completed.
- Correctness fix: `systolic_top` now reads exactly one weight vector per
  compute start plus `COLS-1` additional load cycles. This prevents the array
  from accidentally consuming the first prefetched weight word as the tail of
  the current pass, while also avoiding the earlier under-read case.
- Added read-only `PREFETCHPERF` counters at byte offsets `0x114..0x12c`:
  start, weight_done, feed_done, hit, miss, stall, and version. The Vitis
  runtime prints `PREFETCHPERF layer=...`, and the UART summarizer parses these
  counters.
- Local validation completed with Vivado/xsim `2022.2`: Conv5, Conv6, and Conv8
  raw-HWC tile0 pass with `RawHwcComputeStartLevel=64`, `-EarlyDrain`, and
  `-PassPrefetch` enabled; each reports `854 pass, 0 fail`. The same Conv5
  top test also passes with prefetch disabled, preserving the control path.
  Icarus passes `tb_layer_config_regs`, `tb_axi_lite_cfg_bridge`, and
  `tb_layer_scheduler_pass_prefetch`; `tb/test_kv260_image_demo.py` also passes.
- Experimental Vitis ELFs were rebuilt for the intended backend set
  `Conv5/6/8 raw-HWC + EarlyDrain + PassPrefetch`; the generated aliases are
  `conv_accel_conv0_conv9_batch_chain_raw_hwc_conv5_conv6_conv8_early_drain_pass_prefetch_smoke.elf`
  and
  `conv_accel_conv0_conv9_ddr_demo_raw_hwc_conv5_conv6_conv8_early_drain_pass_prefetch_smoke.elf`.
- A full Vivado `2022.2` implementation completed in `D:/MPSoC/b_passprefetch_22`
  with `HWC_CACHE_AW=14`, `HWC_CACHE_DEPTH=13312`, `HWC_CACHE_STRIPES=4`,
  `HWC_CACHE_USE_URAM=1`, and `TAIL_CYCLES_CONFIG=1`. Timing closes with
  `WNS=+0.280 ns`, `TNS=0`, `WHS=+0.011 ns`, and `THS=0`; route status reports
  `90913` fully routed nets and `0` routing errors. Final resources are
  `54547 LUT`, `47416 FF`, `45.5 BRAM`, `8 URAM`, and `183 DSP`.
- Pass-prefetch artifact hashes: XSA
  `FDF43E9679CD46DB7DE64B9EFF0E6626002D541B67A61F292F4F28B1D3AD5E7C`; bitstream
  `7439BDAEDAD63F1F0628400EFD1989A4A937CE64796E09E42902647B877CC14A`.
  Board validation passed on `COM8`.
- Full-programming batch-chain validation passed with unchanged RTL-golden and
  YOLO decode result. Log:
  `D:/MPSoC/b_passprefetch_22/board_smoke_logs/20260615_000328_conv0_conv9_batch_chain_COM8.log`.
- Fixed-image DDR demo validation passed for two images:

  ```text
  maksssksksss0  PASS  total=386.649 ms  log=20260615_000527_conv0_conv9_ddr_demo_COM8.log
  maksssksksss1  PASS  total=386.637 ms  log=20260615_000700_conv0_conv9_ddr_demo_COM8.log
  ```

  Detections remain stable (`with_mask` on both images). `PREFETCHPERF` reports
  `start=97792`, `weight_done=97792`, `feed_done=97792`, `hit=97792`,
  `miss=0`, and `stall=0` for the full ten-layer run, meaning every enabled
  backend prefetch was ready at the pass boundary.
- Compared with the previous `b_earlydrain_22` fixed-image baseline
  (`520.446 ms`), pass prefetch saves about `133.8 ms`. Compared with
  `b_drainperf_22` (`543.006 ms`), the total saving is about `156.4 ms`.
  The current ten-layer hardware busy total is about `34.76M cycles`, with
  `compute_fire=7.43M cycles` (`21.38%` of busy).
- Current limitation: the safe prefetch trigger is conservative and starts
  after the current compute pass completes, so it overlaps mainly the drain /
  pass-boundary window rather than the whole compute-active interval. Even with
  this conservative trigger, the measured gain is large enough to keep this
  direction. The next question is whether to start prefetch earlier during
  compute, or to move to larger overlap such as double PSUM buffering /
  COUT-block-level pipeline.

## 23. 2026-06-15 experimental partial-PSUM stream overlap

- Added opt-in `STREAM_CFG[4] = psum_stream_overlap_enable`; reset/default
  remains `0`. Vitis exposes the experiment through `-PsumStreamOverlap`.
- The first implementation targets Conv5/6/8 raw-HWC with overlap64, early
  drain, and pass prefetch. It does not change DMA streams, raw-HWC layout,
  OFM packet order, quantization, or the software layer schedule.
- Partial PSUM storage now uses explicit ping-pong banks. For non-final K
  passes, the next compute may begin after the preceding drain has produced a
  conservative lead. Per-bank available counters stop the PSUM feeder before
  it can overtake the writer.
- Scheduler robustness was tightened so a previous drain's one-cycle done
  pulse is latched in every FSM state, including prefetch commit and compute
  start. The overlap unit test deliberately places a done pulse in that
  transition and passes.
- Added `PSUMOVLPERF` counters at byte offsets `0x130..0x140`: start, hit,
  wait_psum, underflow, and version. UART printing and
  `tools/demo/summarize_uart_perf.py` parsing are implemented.
- Local validation:

  ```text
  Icarus: scheduler overlap/prefetch/early-drain tests PASS
  xsim 2022.2: Conv5/Conv6/Conv8 raw-HWC tile0 PASS, 854/0 each
  Python: UART performance parser test PASS
  Vitis 2022.2: batch-chain and DDR-demo experimental ELFs build
  ```

- Vivado `2022.2` synthesis and implementation completed in
  `D:/MPSoC/b_psumovl_22` with the current production parameters:
  `ROWS=18`, `COLS=8`, `IFM_BANKS=2`, `HWC_CACHE_AW=14`,
  `HWC_CACHE_DEPTH=13312`, `HWC_CACHE_STRIPES=4`,
  `HWC_CACHE_USE_URAM=1`, and `TAIL_CYCLES_CONFIG=1`.
- Final implementation meets all timing constraints:
  `WNS=+0.038 ns`, `TNS=0`, `WHS=+0.010 ns`, and `THS=0`.
  Route status reports `110035` fully routed nets and `0` routing errors.
- Final resources are `78900 LUT`, `48294 FF`, `31 BRAM`, `8 URAM`, and
  `183 DSP`. Compared with `b_passprefetch_22`, LUT use increases by `24353`
  and BRAM use falls from `45.5` to `31`. Hierarchical synthesis attributes
  most of this change to `u_pp`: the concurrent-read/write PSUM ping-pong
  buffer is implemented as about `23616` LUTs instead of the previous
  `14 BRAM` mapping. The design fits, but this is an important architecture
  cost and leaves only `+0.038 ns` final setup margin.
- Artifact hashes:

  ```text
  bit A4D3C5796631A8F5DDC6B1948824D0DE7340ED452EE31E67C91084A0F2C0B4E3
  xsa 4482BA0C2C932DD6F52E8856157C23DA4195C38B794BFADA42FEC04EE4C9F8EB
  ```

- Board validation is still pending. The current measured board baseline
  remains `b_passprefetch_22` at about `386.64 ms`. The next acceptance step
  is full programming, batch-chain bit-exact validation, and two-image DDR
  demo measurement. If the measured gain is small, the LUT-heavy PSUM storage
  should be redesigned as explicit dual-bank BRAM before keeping this mode.

## 24. 2026-06-15 experimental continuous PSUM collector

- Added opt-in `STREAM_CFG[5] = continuous_psum_enable`; reset/default remains
  `0`, preserving the current board-validated pass-prefetch / partial-overlap
  path unless software explicitly builds with `-ContinuousPsum`.
- The prototype targets the same backend path as the previous overlap work:
  Conv5/Conv6/Conv8 raw-HWC with `RawHwcComputeStartLevel=64`, `-EarlyDrain`,
  `-PassPrefetch`, and `-PsumStreamOverlap`. It does not change DMA packet
  formats, raw-HWC tile layout, OFM packet order, quantization, or the software
  layer schedule.
- Added `psum_output_collector`. The scheduler pushes one pass context at each
  compute start. The collector consumes per-column PSUM FIFOs, groups one full
  `COLS*2` PSUM packet per pixel, and keeps running across pass boundaries.
  Non-final packets write partial sums directly into the ping-pong PSUM RAM;
  final packets continue through the existing requant / activation / OFM path.
- The ping-pong partial-PSUM storage has been rewritten as explicit dual banks
  split into 64-bit lanes with `ram_style="block"`. This is intended to move
  the heavy concurrent PSUM storage away from LUT memory in the next
  implementation.
- Added read-only `COLLECTPERF` counters at byte offsets `0x144..0x160`:
  packet_fire, partial_write, final_write, context_push, context_pop,
  context_full_stall, column_empty_wait, and version. Vitis prints
  `COLLECTPERF layer=...`, and `tools/demo/summarize_uart_perf.py` parses the
  line.
- Local validation completed so far:

  ```text
  Icarus: tb_conv_layer_top_stream, tb_conv_accel_core,
          tb_layer_config_regs, tb_axi_lite_cfg_bridge,
          tb_layer_scheduler_continuous_psum,
          tb_layer_scheduler_pass_prefetch,
          tb_layer_scheduler_psum_overlap,
          tb_psum_output_collector,
          tb_psum_pingpong_buffer_bram PASS

  xsim 2022.2: module-level collector / BRAM / scheduler / config tests PASS
  xsim 2022.2: Conv5 raw-HWC tile0 continuous PSUM PASS, 854/0
  xsim 2022.2: Conv6 raw-HWC tile0 continuous PSUM PASS, 854/0
  xsim 2022.2: Conv8 raw-HWC tile0 continuous PSUM PASS, 854/0
  Vitis 2022.2: batch-chain and DDR-demo experimental ELFs build
  Python: UART performance parser COLLECTPERF parsing PASS
  ```

- Important correctness fix during this prototype: ping-pong RAM writes now use
  the selected drain/collector packet's `wr_bank`. The continuous collector
  carries its own pass-context bank, while the legacy path still uses the
  scheduler drain bank.
- Vivado `2022.2` synthesis and implementation completed in
  `D:/MPSoC/b_psumcollector_22` with the current production parameters:
  `ROWS=18`, `COLS=8`, `IFM_BANKS=2`, `HWC_CACHE_AW=14`,
  `HWC_CACHE_DEPTH=13312`, `HWC_CACHE_STRIPES=4`,
  `HWC_CACHE_USE_URAM=1`, and `TAIL_CYCLES_CONFIG=1`.
- Final implementation meets timing:
  `WNS=+0.212 ns`, `TNS=0`, `WHS=+0.010 ns`, and `THS=0`.
  Route status reports `94545` fully routed nets and `0` routing errors.
- Final resources are `56618 LUT`, `48993 FF`, `63 BRAM`, `8 URAM`, and
  `183 DSP`. `LUT as Memory` is `16570` (`5500` distributed RAM and `11070`
  shift-register LUTs). This is a large improvement over the previous
  `b_psumovl_22` result (`78900 LUT`, `31 BRAM`, and a LUT-heavy `u_pp`),
  but it does not yet meet the aggressive `<8000` LUT-memory target. The
  rewritten ping-pong PSUM buffer is now reported as `32` BRAM with only about
  `513` LUT, so the remaining LUT-memory cost is mainly outside the partial
  PSUM RAM.
- Artifact hashes:

  ```text
  bit 9E27106EA86106164C522A1F9AE3FAB646D9041D90D59C4E2DF4071C8F939186
  xsa 973E7C98E137589D5C53FAE40DE2450F6F26E4BF4B77B220489F9494C4799B66
  ```

- The first board validation of `D:/MPSoC/b_psumcollector_22` exposed a real
  correctness bug in Conv5 tail tile 3:

  ```text
  conv5 mismatch_count=5303 max_abs_diff=34 total=86528
  first mismatch byte=79873 pixel=156 oy=12 ox=0 oc=1 got=19 exp=17
  ```

  The failure reproduced in xsim only with `continuous_psum_enable=1`; the
  same tail tile passed with continuous PSUM disabled. Root cause: the
  per-bank partial-PSUM availability counters could retain stale credit when a
  non-final continuous-collector pass reused a ping-pong bank. The next pass
  could therefore read old partial data before the collector wrote the first
  packet of the new context.
- Fixed by clearing the selected PSUM availability counter at each non-final
  compute start in continuous mode. Additional protection wires the collector's
  active context bank back into the scheduler so the scheduler can avoid
  starting a next pass that would collide with an active collector context.
- Re-validation after the fix:

  ```text
  xsim 2022.2 Conv5 tile0 continuous PSUM PASS, 854/0
  xsim 2022.2 Conv5 tile3 continuous PSUM PASS, 230/0
  xsim 2022.2 Conv6 tile0 continuous PSUM PASS, 854/0
  xsim 2022.2 Conv6 tile3 continuous PSUM PASS, 230/0
  xsim 2022.2 Conv8 tile0 continuous PSUM PASS, 854/0
  xsim 2022.2 Conv8 tile3 continuous PSUM PASS, 230/0
  Icarus selected regression PASS
  ```
- Vivado `2022.2` implementation of the fixed design completed in
  `D:/MPSoC/b_psumcollector_fix3_22`. The Vivado batch run had to use
  `C:/Xilinx/Vivado/2022.2/scripts/ipintegrator` as working directory to avoid
  a Vivado 2022.2 BD rule initialization issue observed when launching from
  the repository directory.
- Final fixed implementation meets timing:

  ```text
  WNS=+0.165 ns, TNS=0, WHS=+0.010 ns, THS=0
  routing errors=0
  LUT=56442, FF=49000, BRAM=63, URAM=8, DSP=183
  LUT as Memory=16530
  bit SHA256=1E0255EA61AEBF28C01DC72386B398ABAE000193EA840C217CAAD5BC6437248D
  XSA SHA256=40424070EDC08B05BDA56FE2295A2D5F3520E4F425559E2693F9B49185E1562A
  ```
- Fixed board validation passed:

  ```text
  build: D:/MPSoC/b_psumcollector_fix3_22
  batch-chain log: 20260615_081758_conv0_conv9_batch_chain_COM8.log
  DDR image0 log:  20260615_082040_conv0_conv9_ddr_demo_COM8.log
  DDR image1 log:  20260615_082302_conv0_conv9_ddr_demo_COM8.log
  batch-chain: PASS, RTL golden and YOLO decode match
  image0: PASS, with_mask score=0.357321
  image1: PASS, with_mask score=0.295050
  DDR image0 total=0.371271 s
  DDR image1 total=0.371314 s
  ```

  `COLLECTPERF` reports `context_full_stall=0`, `PREFETCHPERF` hit rate is
  `100%`, and `PSUMOVLPERF underflow=0`. Relative to the previous
  `b_psumovl_credit1_22` board baseline of about `374.36 ms`, the fixed
  continuous collector is functionally correct but only slightly faster
  (`~371.3 ms`). The collector mainly removes the explicit final drain stage
  for raw-HWC Conv5/6/8, while the dominant remaining time is still
  `compute_stage` plus feeder/replay activity.

## 25. 2026-06-15 pass-level timeline diagnostic

- Continuous PSUM collector is now treated as a correct but not decisive
  optimization. The measured DDR demo remains around `0.3713 s`; true
  `compute_fire` is still much lower than `STAGE_COMPUTE`, and
  `COLLECT_COLUMN_EMPTY_WAIT` remains large. The next step is therefore
  observability, not another speculative datapath rewrite.
- Added a diagnostic-only `pass_timeline_monitor`. It observes existing
  scheduler, feeder, compute, raw-HWC replay, and collector events but does not
  feed back into control. External DMA streams, raw-HWC cache format, OFM
  packets, quantization, layer schedule, and `STREAM_CFG` behavior are
  unchanged.
- New aggregate `PASSPERF` counters report pass count, compute-start to first
  fire latency, first-fire to last-fire span, last-fire to compute-done tail,
  compute-start to first collector packet latency, collector column-empty wait,
  raw replay active during compute, and compute-stage idle cycles.
- New optional `PASSTRACE` capture records layer-local timestamps for one
  selected `cout_block/k_pass`: weight done, feeder start/ready/done, compute
  start, first/last compute fire, compute done, collector first/last packet,
  and pass done.
- Register additions use byte offsets `0x164..0x1b4`; the register map is
  documented in `docs/hardware_dataflow_and_registers.md`. Vitis runtime prints
  `PASSPERF` every layer and, when built with `-TilePerfTrace`, prints
  `PASSTRACE` samples.
- Local validation completed:

  ```text
  Icarus: tb_pass_timeline_monitor PASS, 22/0
  Icarus: tb_layer_config_regs PASS, 158/0
  Icarus: tb_conv_layer_top_stream PASS, 184/0
  Icarus: tb_conv_accel_core PASS, 93/0
  Python: tb/test_kv260_image_demo.py PASS
  Vitis 2022.2: experimental DDR ELF with PASSPERF/PASSTRACE printing builds
  ```

- `tools/demo/summarize_uart_perf.py` now parses `PASSPERF` and `PASSTRACE`.
  It reports pass averages, compute utilization inside `STAGE_COMPUTE`, and
  fire density over the first-to-last-fire span.
- Vivado `2022.2` implementation completed in `D:/MPSoC/b_passtrace_22`.
  The first build attempt exposed a Tcl source-list issue: the new
  `pass_timeline_monitor.v` file must be included in both the BD/IP-packaging
  source list and the standalone synthesis list. The Tcl lists have been fixed.
  Final signoff is:

  ```text
  WNS=+0.193 ns, TNS=0, WHS=+0.010 ns, THS=0
  routing errors=0
  CLB LUTs=57197, CLB Registers=49838
  LUT as Memory=16641
  BRAM Tile=63, URAM=8, DSP=184
  bit SHA256=7712344B10C36969552A9547B1CED9F834C6381B3209316D9E0001DFDA4F4B04
  XSA SHA256=99F09A6ACC6E9D3DE287DDD8AB7BA05080F4CF887E477745D8359B9D3D076AD8
  ```

- The first board run of `b_passtrace_22` passed batch-chain, but the selected
  trace did not remain valid for the raw-HWC continuous layers. The monitor was
  then fixed by tracking selected trace lifetime separately from the current
  compute lifetime, so next-pass compute fires cannot overwrite a trace before
  the collector pops the selected pass context.
- Vivado `2022.2` implementation of the fixed build completed in
  `D:/MPSoC/b_passtrace_fix2_22`:

  ```text
  WNS=+0.113 ns, TNS=0, WHS=+0.010 ns, THS=0
  route errors=0
  CLB LUTs=57226, CLB Registers=49831
  LUT as Memory=16638, BRAM Tile=63, URAM=8, DSP=184
  bit SHA256=3DC26E405921DCF04057CFFC8E8997D0A3481D4EBFF9585551B34A26FE7D2FBE
  XSA SHA256=258458C60231AE5D62CE1E4E0F9BB7D73C8F8043FEB2A0D440DF24C2ABC660AA
  ```

- Board validation of `b_passtrace_fix2_22`:

  ```text
  batch-chain log: 20260615_230847_conv0_conv9_batch_chain_COM8.log
  DDR image0 log:  20260615_231105_conv0_conv9_ddr_demo_COM8.log
  DDR image1 log:  20260615_231547_conv0_conv9_ddr_demo_COM8.log
  batch-chain: PASS, RTL golden and YOLO decode match
  image0: with_mask score=0.357321
  image1: with_mask score=0.295050
  ```

- `PASSTRACE` is now captured for Conv5/Conv6/Conv8 tile0, `cout_block=0`,
  `k_pass=0`. The three samples show the same structure: compute starts 9 cycles
  before first fire, compute fires over a 52-cycle window for a 52-pixel tile,
  but collector first packet appears about 112 cycles after compute done. The
  aggregate `PASSPERF` counters still show the dominant unexplained bubble as
  collector column-empty / compute-idle time:

  ```text
  COLLECTPERF column_empty_wait=11628928
  PASSPERF compute_idle=11907808
  PASSPERF avg_start_to_first=9.00
  PASSPERF avg_collect_wait=1.50
  ```

- `tools/demo/summarize_uart_perf.py` was hardened to split UART logs where
  `TILEPERF`, `PERF`, `PASSPERF`, or `PASSTRACE` records are concatenated. The
  trace-enabled ELF prints many tile lines, so wall-clock `total_us` is inflated
  by UART output and should not be used as the performance baseline. The
  hardware cycle counters remain the useful source for this diagnostic run.

## 26. 2026-06-15 column-level PSUM trace result

- Added a targeted `coltrace_monitor` after the pass-level trace identified
  collector column-empty behavior as the remaining unexplained bubble. The
  monitor observes each column's PSUM FIFO writes and the collector missing
  mask for one selected pass. It is diagnostic-only and does not feed back into
  scheduler or datapath control.
- New offsets `0x1b8..0x1d8` expose selected-column first/last write timestamp,
  write count, empty-wait count, missing-column masks, trace-valid, and version.
  Vitis prints one `COLTRACE` line per column, and
  `tools/demo/summarize_uart_perf.py` ranks columns by empty-wait cycles.
- Local validation completed:

  ```text
  Icarus: tb_coltrace_monitor PASS
  Icarus: tb_psum_output_collector PASS
  Icarus: tb_pass_timeline_monitor PASS, 23/0
  Icarus: tb_layer_config_regs PASS, 169/0
  Icarus: tb_conv_layer_top_stream PASS, 184/0
  Icarus: tb_conv_accel_core PASS, 93/0
  Python: tb/test_kv260_image_demo.py PASS
  xsim 2022.2: Conv5/Conv6/Conv8 raw-HWC tile0 PASS
  Vitis 2022.2: trace-enabled DDR ELF builds
  ```

- Conv5, Conv6, and Conv8 show the same selected-pass pattern. Every column
  writes exactly 52 consecutive pixels, but column start times are separated
  by a fixed four-cycle phase:

  ```text
  col0 first=152127 last=152178 writes=52 empty_wait=99
  col1 first=152131 last=152182 writes=52 empty_wait=103
  col2 first=152135 last=152186 writes=52 empty_wait=107
  col3 first=152139 last=152190 writes=52 empty_wait=111
  col4 first=152143 last=152194 writes=52 empty_wait=115
  col5 first=152147 last=152198 writes=52 empty_wait=119
  col6 first=152151 last=152202 writes=52 empty_wait=123
  col7 first=152155 last=152206 writes=52 empty_wait=127
  ```

- This result confirms fixed systolic column propagation rather than random
  FIFO starvation or collector throughput loss. A collector-only reorder or
  holding register cannot make the last column arrive earlier, so the planned
  speculative phase-compensation datapath change is stopped.
- The practical next choices are now narrower:
  - Low risk: increase Conv5/Conv8 raw-HWC spatial tile height from 4 to 8.
    Their current cache limit supports 104 pixels, reducing each layer from four
    spatial tiles to two. The fixed per-pass latency estimate suggests roughly
    `10.4 ms` potential per layer, about `20.8 ms` combined.
  - Higher value: redesign partial PSUM storage/consumption as per-column
    streaming so next-K compute can follow the four-cycle column wave instead of
    waiting for a fully assembled `COLS*2` packet. Conv6 remains the main target
    because its current 52-pixel tile already fills the 13312-word HWC cache and
    cannot be enlarged without more cache capacity.
- No board build is justified for the diagnostic alone before choosing one of
  these data-path changes. The validated `b_passtrace_fix2_22` build remains the
  board baseline.

## 27. 2026-06-16 backend full-tile HWC cache experiment

- The next optimization path is to spend more of the available xck26 URAM on the
  existing 3x3 raw-HWC cache, rather than changing the cache data semantics.
  The current 3x3 cache is a materialized window cache. Its capacity check is:

  ```text
  required_words = tile_pixels * ceil(CIN / IFM_BANKS)
  IFM_BANKS      = 2
  ```

- A new experimental build/runtime option `BackendFullTile` raises the intended
  cache configuration to:

  ```text
  HWC_CACHE_AW=16
  HWC_CACHE_DEPTH=43264
  HWC_CACHE_STRIPES=4
  HWC_CACHE_USE_URAM=1
  ```

  This fits the full 13x13 backend 3x3 tiles:

  ```text
  Conv5/8: 169 * ceil(256/2) = 21632 words
  Conv6:   169 * ceil(512/2) = 43264 words
  ```

- Software now supports `-BackendFullTile` for batch-chain and DDR-demo builds.
  With this switch, Conv5, Conv6, and Conv8 use one spatial tile of height 13
  instead of the previous `4,4,4,1` schedule. Conv7 and Conv9 are intentionally
  left unchanged for the first experiment so the measured difference is mainly
  attributable to backend 3x3 tile-size amortization.
- Local validation so far:

  ```text
  Vitis 2022.2 DDR ELF build with BackendFullTile: PASS
  xsim Conv5 full 13x13 raw-HWC tile: PASS, 2726/0
  xsim Conv6 full 13x13 raw-HWC tile: PASS, 2726/0
  xsim Conv8 full 13x13 raw-HWC tile: PASS, 2726/0
  Python tb/test_kv260_image_demo.py: PASS
  ```

- A combined full-tile xsim run with all overlap switches enabled was attempted
  for Conv6, but the xsim process stopped progressing after design load and was
  terminated. The non-overlap full-tile tests validate the enlarged cache
  address/capacity path; the full overlap combination still needs board-level
  validation after the 2022.2 implementation build.
- Next hardware build target:

  ```text
  D:/MPSoC/b_hwcfulltile_22
  ```

- The 2022.2 implementation build completed successfully:

  ```text
  build dir: D:/MPSoC/b_hwcfulltile_22
  Vivado:    2022.2
  WNS=+0.177 ns, TNS=0, WHS=+0.009 ns, THS=0
  route errors=0, fully routed nets=104277
  CLB LUTs=58903, CLB Registers=50915
  LUT as Memory=16551
  BRAM Tile=63, URAM=24, DSP=184
  bit SHA256=633839A78242AAB9F5AA575B48C6A9A17FDE574944A4E5ED7640B88301ACE15F
  XSA SHA256=AC2228EC28291BD4239AA887E529B2BEA6562A3E86CD322699CC5135F237E43D
  ```

  This confirms the larger cache maps to 24 URAMs and still closes timing at
  100 MHz.

- Board validation completed with full programming:

  ```text
  batch-chain:
    log=D:/MPSoC/b_hwcfulltile_22/board_smoke_logs/20260616_125655_conv0_conv9_batch_chain_COM8.log
    result=PASS, UART detections match decode golden count=1

  DDR demo image maksssksksss0.png:
    log=D:/MPSoC/b_hwcfulltile_22/board_smoke_logs/20260616_125932_conv0_conv9_ddr_demo_COM8.log
    total=335.564 ms
    detection=with_mask score=0.357321

  DDR demo image maksssksksss1.png:
    log=D:/MPSoC/b_hwcfulltile_22/board_smoke_logs/20260616_130105_conv0_conv9_ddr_demo_COM8.log
    total=335.779 ms
    detection=with_mask score=0.295050
  ```

  The result improves the previous approximately `371.3 ms` board baseline by
  about `35.6 ms` while preserving detection output. The full-tile experiment is
  therefore a useful optimization, but the remaining performance counters still
  show substantial pass-internal overhead:

  ```text
  HW busy ~= 29.58M cycles
  compute_fire = 7.43M cycles, 25.12% of HW busy
  feeder       ~= 10.21M cycles
  compute_stage~= 16.23M cycles
  drain        ~= 2.01M cycles
  column_empty_wait ~= 3.12M cycles
  ```

  This validates the URAM-capacity direction for amortizing spatial-tile fixed
  costs, but it does not remove the deeper array-utilization issue. The next
  optimization should target pass-internal feeder/compute/collector structure,
  not further materialized-cache expansion unless front-end layers are also
  moved to larger raw-HWC tiles.

## 28. 2026-06-16 column-level partial-PSUM streaming foundation

- After the backend full-tile result, the remaining bottleneck is no longer
  dominated by spatial-tile startup. The current continuous PSUM path still
  stores and reloads partial sums as one full `COLS*2` packet per pixel:

  ```text
  array column FIFOs
      -> psum_output_collector waits until all columns are non-empty
      -> full packet write to psum_pingpong_buffer
      -> psum_stream_feeder reads full packet
      -> systolic_top skews each column by pc*4 cycles
  ```

  This preserves correctness, but it still pays the fixed column wave inside
  every K pass and prevents the next pass from consuming early columns as soon
  as they are available.

- The next structural direction is therefore column-level partial-PSUM
  streaming. The first step implemented here is deliberately not connected to
  the board path yet. It adds independently testable building blocks:

  ```text
  systolic/psum_column_pingpong_buffer.v
  systolic/psum_column_stream_feeder.v
  tb/tb_psum_column_stream.v
  ```

- `psum_column_pingpong_buffer` splits the partial-PSUM ping-pong storage by
  output column. Each column can be written and read independently, with the
  same two-bank pass-to-pass ownership model.
- `psum_column_stream_feeder` recreates the existing `pc*4` column skew by
  delaying the read request for each column, rather than reading a full packet
  and delaying the data afterward. This is the key interface shape needed for a
  future collector that can write column results as soon as each column FIFO
  produces them.
- Local validation:

  ```text
  tb_psum_column_stream   PASS, 32 pass / 0 fail
  tb_psum_stream_feeder   PASS, 32 pass / 0 fail
  tb_psum_output_collector PASS
  ```

- The next implementation step is to add an opt-in top-level mode, likely a new
  `STREAM_CFG` experiment bit, that routes non-final continuous-PSUM writes
  into the column buffer and uses the column feeder for later K passes. The
  first target should be a small Conv5/6/8 raw-HWC tile xsim, not immediate
  synthesis, because this touches the data presented to the systolic array top
  row.

## 29. 2026-06-16 column-PSUM A/B and true bottleneck update

- A same-bitstream A/B run was completed on
  `D:/MPSoC/b_hwcfulltile_colpsum_22`, using the same DDR image and the same
  backend full-tile schedule. The only runtime difference was `ColumnPsum=0`
  versus `ColumnPsum=1`.

  ```text
  ColumnPsum=0:
    log=D:/MPSoC/b_hwcfulltile_colpsum_22/board_smoke_logs/20260616_165023_conv0_conv9_ddr_demo_COM8.log
    total=330.777 ms
    busy=29.207286M cycles
    collect column_empty_wait=3.263920M cycles

  ColumnPsum=1:
    log=D:/MPSoC/b_hwcfulltile_colpsum_22/board_smoke_logs/20260616_165142_conv0_conv9_ddr_demo_COM8.log
    total=330.798 ms
    busy=29.207313M cycles
    collect column_empty_wait=0.018288M cycles
  ```

- This proves that the column-PSUM path is functionally active and that it
  removes almost all collector column-empty wait, but that wait was not on the
  current end-to-end critical path. The total runtime is unchanged within
  measurement noise.

- A cycle-bound analysis script was added:

  ```text
  tools/demo/analyze_cycle_bound.py
  ```

  Running it on the `ColumnPsum=1` log shows:

  ```text
  total=330.798 ms
  HW busy=292.073 ms
  compute_fire=74.323 ms, util=25.45%
  feeder=91.835 ms
  compute_stage=175.733 ms
  compute_idle=101.410 ms
  drain=15.227 ms
  collect_empty=0.183 ms
  ```

- The largest remaining opportunity is therefore not the collector. It is the
  pass transaction boundary around `ST_COMP_WAIT`. Conv6 alone contributes the
  largest gap:

  ```text
  conv6 busy=94.072 ms
  conv6 compute_fire=27.689 ms
  conv6 compute_stage=85.490 ms
  conv6 compute_idle=57.801 ms
  conv6 feed_fill=63.600 ms
  ```

- Interpretation: once the array enters its fire window, `fire_span` density is
  effectively full. The bubble is not low PE throughput inside the window; it
  is pass-level waiting before/after that window. Current scheduler prefetch is
  still conservative: `prefetch_start_now` waits for `compute_done` and the
  feeder completion event before starting next-pass weight/feed work. This
  means next-pass preparation is mostly paid after current-pass compute, where
  it is counted as compute-stage idle.

- Important diagnostic correction: when `ColumnPsum=1`, the
  `PSUMOVLPERF underflow` register must report the column PSUM stream
  underflow, not the legacy full-packet PSUM feeder underflow. The RTL
  diagnostic mux has been corrected so future logs do not report a misleading
  legacy underflow count while the column path is active.

- Next optimization target: **safe during-compute next-pass preparation**.
  The goal is not to overwrite PE weights early. Instead, the next pass should
  be prefetched into decoupling queues or buffers while the current pass is
  computing:

  ```text
  current pass compute uses current PE weights and current IFM FIFO data
  next pass weight is filled into its staging FIFO/buffer, not loaded into PEs
  next pass IFM replay is appended behind current-pass IFM data when FIFO
  credits make it safe
  after current compute completes, only the short PE weight-load/switch remains
  ```

  This respects the single active PE weight context while targeting the
  approximately `101 ms` compute-stage idle that remains after full-tile,
  pass-prefetch, early-drain, PSUM overlap, and column-PSUM experiments.

## 30. 2026-06-16 during-compute next-pass prefetch implementation

- The safe staging experiment described above has been implemented as
  `STREAM_CFG[7] = during_compute_prefetch_enable`. The default value remains
  `0`, so existing board-validated ELFs and prepacked IFM paths are unchanged.

- The new mode only changes next-pass preparation timing. It allows the
  scheduler to start next-K weight staging and raw-HWC replay after the current
  pass compute has started and the current feeder/replay transaction has
  completed. It does not load the next weights into active PEs during the
  current compute, and it does not start the next pass compute before the
  existing dependency checks pass.

- Software support was added through the `-DuringComputePrefetch` switch in the
  Vitis build/run scripts. The switch defines
  `ACCEL_DURING_COMPUTE_PREFETCH=1` and sets `STREAM_CFG[7]` only for raw-HWC
  layers.

- Local validation completed:

  ```text
  Icarus selected scheduler/config regression PASS
  tb_layer_scheduler_during_compute_prefetch PASS
  tb_layer_config_regs PASS, 173/0
  tb_axi_lite_cfg_bridge PASS, 99/0

  xsim Conv5 full 13x13 raw-HWC tile PASS, 2726/0
  xsim Conv6 full 13x13 raw-HWC tile PASS, 2726/0
  xsim Conv8 full 13x13 raw-HWC tile PASS, 2726/0
  ```

- The next step is not more RTL speculation; it is a 2022.2 implementation and
  board A/B against the current `b_hwcfulltile_colpsum_22` baseline. If total
  DDR demo latency drops by at least about `20 ms`, this confirms that late
  next-pass staging was on the critical path. If it drops by less than `10 ms`,
  the remaining compute idle should be investigated as raw-HWC replay throughput
  or a deeper compute-stage handoff issue.

- 2022.2 implementation completed:

  ```text
  build dir: D:/MPSoC/b_kprefetch_22
  WNS=+0.092 ns, TNS=0
  WHS=+0.010 ns, THS=0
  routing errors=0
  CLB LUTs=84480, CLB Registers=53260
  LUT as Memory=35502
  BRAM Tile=63, URAM=24, DSP=184
  bit SHA256=83219E2150352795B21DC52062FB74FAD3E55CE2DE3075BD3DBD8A71DA765D5A
  XSA SHA256=BB36996E2AE900061779F82943CAA7D4D128B4A72A80D801E14D03D05294CA63
  ```

- The matching Vitis ELFs also build with the short variant alias:

  ```text
  conv_accel_conv0_conv9_batch_chain_rhwc_c5_c6_c8_ed_pf_dcpf_pso_cps_col_full_smoke.elf
  conv_accel_conv0_conv9_ddr_demo_rhwc_c5_c6_c8_ed_pf_dcpf_pso_cps_col_full_smoke.elf
  ```

  The next validation step is full programming of `b_kprefetch_22`, then
  batch-chain and two-image DDR demo A/B against the `~330.8 ms` baseline.

- Board validation completed:

  ```text
  batch-chain full programming:
    PASS, UART detections match decode golden count=1
    log=D:/MPSoC/b_kprefetch_22/board_smoke_logs/20260616_193348_conv0_conv9_batch_chain_COM8.log

  DDR demo maksssksksss0.png:
    total=288.002 ms
    detection=with_mask score=0.357321
    log=D:/MPSoC/b_kprefetch_22/board_smoke_logs/20260616_193623_conv0_conv9_ddr_demo_COM8.log

  DDR demo maksssksksss1.png:
    total=287.993 ms
    detection=with_mask score=0.295050
    log=D:/MPSoC/b_kprefetch_22/board_smoke_logs/20260616_193752_conv0_conv9_ddr_demo_COM8.log
  ```

- Compared with the previous `b_hwcfulltile_colpsum_22` baseline of about
  `330.8 ms`, during-compute next-pass prefetch saves about `42.8 ms`. This
  confirms that late next-pass staging was on the critical path.

- Updated cycle-bound summary for the new board run:

  ```text
  total=288.002 ms
  HW busy=247.184 ms
  compute_fire=74.323 ms, util=30.07%
  feeder=99.913 ms
  compute_stage=121.022 ms
  compute_idle=46.699 ms
  drain=16.467 ms
  collect_empty=0.163 ms
  psum_underflow=0
  ```

- The remaining largest layer-level gaps are:

  ```text
  conv6 compute_idle=30.401 ms, feed_fill=63.600 ms
  conv5 compute_idle= 7.623 ms, feed_fill=17.873 ms
  conv8 compute_idle= 7.623 ms, feed_fill=17.873 ms
  ```

  Because Conv0-4 still spend significant time in feeder/fill and do not yet
  use the backend full-tile raw-HWC path, the next performance direction should
  compare front-end raw-HWC/full-tile feasibility against a deeper replay/compute
  overlap design for Conv5/6/8.

- Follow-up front-end raw-HWC experiment:

  ```text
  switch set:
    -RawHwcConv3 -RawHwcConv4 -RawHwcConv5 -RawHwcConv6 -RawHwcConv8
    -RawHwcComputeStartLevel 64
    -EarlyDrain -PassPrefetch -DuringComputePrefetch
    -PsumStreamOverlap -ContinuousPsum -ColumnPsum
    -BackendFullTile

  generated aliases:
    conv_accel_conv0_conv9_batch_chain_rhwc_c3_c4_c5_c6_c8_ed_pf_dcpf_pso_cps_col_full_smoke.elf
    conv_accel_conv0_conv9_ddr_demo_rhwc_c3_c4_c5_c6_c8_ed_pf_dcpf_pso_cps_col_full_smoke.elf
  ```

  A first attempt used Conv3 `26` output rows per tile. It deadlocked because
  `52*26=1352` vectors exceed the current `IFM_FIFO_DEPTH=1024` staging space
  used by during-compute prefetch. The software schedule was reduced to
  `18/18/16` Conv3 rows, so the largest tile is `52*18=936` vectors and fits
  the FIFO while still reducing Conv3 from seven tiles to three.

  Board validation with the same `D:/MPSoC/b_kprefetch_22` bitstream:

  ```text
  batch-chain full programming:
    PASS, UART detections match decode golden count=1
    log=D:/MPSoC/b_kprefetch_22/board_smoke_logs/20260616_205214_conv0_conv9_batch_chain_COM8.log

  DDR demo maksssksksss0.png:
    PASS, total=286.653 ms
    log=D:/MPSoC/b_kprefetch_22/board_smoke_logs/20260616_205356_conv0_conv9_ddr_demo_COM8.log

  DDR demo maksssksksss1.png:
    PASS, total=286.646 ms
    log=D:/MPSoC/b_kprefetch_22/board_smoke_logs/20260616_205521_conv0_conv9_ddr_demo_COM8.log
  ```

  This is functional but not a performance win versus the validated
  Conv4/5/6/8 configuration (`282.951 ms`). Conv3 raw-HWC reduces the tile
  count, but the materialized 3x3 raw loader pays a large load/unpack cost at
  width 52, and Conv3 `compute_idle` rises from about `0.215 ms` to
  `7.255 ms`. Therefore `-RawHwcConv3` remains an opt-in diagnostic switch, not
  the recommended default. The next useful optimization should not be more
  materialized-cache expansion for Conv3; it should target the remaining
  Conv6/Conv4/Conv5/Conv8 compute-stage bubbles or a more efficient raw feature
  cache/replay format.

## 26. 2026-06-16 raw-HWC replay throughput optimization

- RTL review of the `b_kprefetch_22` board logs showed that the large
  `compute_stage - compute_fire` bubble is not primarily inside the PE compute
  controller. For Conv6, `comp_active=2,770,944` is almost equal to
  `comp_fire=2,768,896`, while `PASSPERF compute_idle=3,040,064` and
  `replay_active_during_compute=1,670,528`. This points at raw-HWC replay and
  scheduler staging rather than arithmetic throughput.
- The raw-HWC cache replay path was still effectively a two-cycle vector
  source. It issued the next URAM read only after the current vector handshake,
  then waited another cycle before asserting `vector_valid`. This matched the
  board counters: Conv6 `feed_push=2,768,896`, but
  `RAWSTAT replay_active=5,537,792`.
- `axis_hwc_tile_cache` has been changed to issue the next replay read whenever
  the output register is empty or will be consumed in the current cycle. The
  output pixel metadata is latched with the synchronous URAM read, so the cache
  can present one vector per cycle when `vector_ready=1`. The AXIS input format,
  materialized 3x3 cache layout, output vector format, quantization semantics,
  and scheduler interface are unchanged.
- Validation so far:

  ```text
  Icarus tb_axis_hwc_tile_cache:
    261 pass, 0 fail
    includes a fast-replay assertion that ready-high replay completes in
    about num_pixels cycles instead of the old two-cycle cadence

  Vivado/xsim 2022.2 tb_axis_hwc_tile_cache:
    261 pass, 0 fail

  Vivado/xsim 2022.2 Conv6 full 13x13 raw-HWC tile:
    tb_conv_accel_core_axi_lite_axis_stream_conv6_3x3_raw_hwc_fulltile_cout16
    2726 pass, 0 fail
  ```

- Expected board effect: this should reduce the backend raw-HWC replay cost for
  Conv5/6/8 and Conv4. Conv6 alone has roughly `2.77M` excess replay-active
  cycles versus one-cycle replay, so the first board target is a meaningful
  drop in `RAWSTAT replay_active`, `SUBPERF feed_fill`, and Conv6
  `compute_idle`. If timing still closes, this is the next bitstream to compare
  against the current `Conv4/5/6/8` raw-HWC `282.951 ms` run.

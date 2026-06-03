# Systolic Accelerator 当前状态与后续计划

> 最后更新：2026-06-03

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
- `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_tile4`：Layer06 小 tile 真实 golden。
- `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_tiles`：Layer06 多 spatial tile。
- `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_full`：完整 `52x52x64 -> 52x52x128` 层。

`full_fifo256` 保留为 diagnostic/stress test，不进入默认快速回归。它适合观察长时间运行进度、FIFO 行为和 backpressure 风险。

## 5. 已知限制和风险

- 当前 RTL 还不是完整 YOLOv3-tiny 推理系统。
- pooling 第一版已经作为 activation 后、OFM writer 前的可选输出侧后处理模块接入，当前支持 bypass 和 `2x2` uint8 maxpool stride-2。
- pool 打开时，`OFM_SIZE/NUM_PIXELS/TILE_OFM_H` 描述 pool 前 conv output tile，`TILE_PIXEL_BASE` 按最终 pool 后 OFM 地址空间配置。
- 当前验证重点是卷积数据流、量化语义和写回正确性，不覆盖 YOLO decode/NMS。
- 旧 Vitis 最小系统验证已经不代表当前 RTL 状态，后续需要重新建立软件运行时。
- RTL semantic golden 是硬件 bit-exact 仿真的标准；PyTorch reference 只能作为模型级参考。
- `ifm_u8 - input_zero_point` 饱和到 signed int8 是当前正式硬件近似。Layer06 当前 `sat_count=0`，但后续每层 golden export 都应统计 saturation count。

## 6. 仓库结构与外部数据

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

## 7. 后续计划

### RTL 主线

1. 按单尺度网络调度确认是否需要 stride-1 或特殊 pooling。
2. 继续保持无 pooling 路径的默认 ABI 兼容。

### 网络验证主线

1. 固化单尺度检测网络的 layer list 和 buffer 调度。
2. 为每一层导出 RTL semantic golden。
3. 按层验证 convolution/pooling 输出。
4. 编写软件层调度器，按顺序配置 RTL 并管理中间 feature buffer。
5. YOLO box decode 和 threshold 先保留在软件端。

### 系统集成主线

1. 等 RTL 层语义稳定后再恢复 Vitis 工程。
2. 先实现一个只运行单层的最小 PS runtime。
3. 再扩展到多层单尺度 pipeline。
4. 等寄存器和 buffer ABI 稳定后，再加入 SD 卡或 host-side 参数加载。

## 8. 当前默认策略

- RTL 仿真器使用 xsim。
- pass/fail 使用 RTL semantic golden。
- PyTorch reference 用作模型级对照。
- 完整 Layer06 回归作为 targeted/nightly test。
- 小规模确定性测试和小 tile 真实数据测试作为日常回归。
- 论文、Vitis、workspace 和 RTL 改动分开提交，避免互相混杂。

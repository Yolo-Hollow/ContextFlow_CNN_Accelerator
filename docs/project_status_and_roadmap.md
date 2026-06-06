# Systolic Accelerator 当前状态与后续计划

> 最后更新：2026-06-06

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

## 6. 已知限制和风险

- 当前 RTL 还不是完整 YOLOv3-tiny 推理系统。
- pooling 第一版已经作为 activation 后、OFM writer 前的可选输出侧后处理模块接入，当前支持 bypass 和 `2x2` uint8 maxpool stride-2。
- pool 打开时，`OFM_SIZE/NUM_PIXELS/TILE_OFM_H` 描述 pool 前 conv output tile，`TILE_PIXEL_BASE` 按最终 pool 后 OFM 地址空间配置。
- 当前验证重点是卷积数据流、量化语义和写回正确性，不覆盖 YOLO decode/NMS。
- Vitis 最小系统 runtime 目前只覆盖旧 deterministic smoke 和一个真实 Conv0 crop + pool smoke，不代表完整网络 runtime。
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

1. 固化单尺度检测网络的 layer list 和 buffer 调度。
2. 为每一层导出 RTL semantic golden。
3. 按层验证 convolution/pooling 输出。
4. 编写软件层调度器，按顺序配置 RTL 并管理中间 feature buffer。
5. YOLO box decode 和 threshold 先保留在软件端。

### 系统集成主线

1. 用 KV260 board preset 重新生成包含当前 RTL 的 bitstream/XSA。
2. 先用 `probe_pl_regs.tcl` 验证 accelerator、DMA、GPIO 和 `0xA0000080..0xA000008c` quant/LUT MMIO 地址可访问。
3. 上板优先运行 `conv_accel_conv0_crop_pool_smoke.elf`，确认真实 Conv0 crop + pool 的 quant/LUT、pool、OFM debug stream 和软件 golden 对比。
4. 如需控制面诊断，再运行 `conv_accel_r18_c8_smoke.elf`，观察旧 deterministic PS/DMA/GPIO 通路和 raw psum mismatch。
5. 可选增加 AXI VIP BD smoke，目标只验证 BD 地址映射和控制面，不重复 RTL 大规模 golden 验证。
6. 再扩展到多层单尺度 pipeline。
7. 等寄存器和 buffer ABI 稳定后，再加入 SD 卡或 host-side 参数加载。

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
- Vitis smoke 已加入 descriptor/scheduler dry-run：`accel_layer_desc_t` 描述单层运行参数，`accel_single_scale_plan` 记录 10 层单尺度调度表，`accel_single_scale_scheduler.h` 在启动时检查 shape 链接、K pass、COUT block、expected bytes 和 ping-pong feature buffer 分配；当前 smoke 已覆盖单 tile Conv0 和两 spatial tile Conv0 crop + pool。
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

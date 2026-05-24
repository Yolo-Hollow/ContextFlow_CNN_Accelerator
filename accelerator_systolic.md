# Systolic Accelerator 设计与验证文档

> 最后更新：2026-05-24

本文档记录 `accelerator_systolic/` 当前已经完成的工作、已验证的设计语义、存在的问题，以及后续推进计划。目标是在权重固定式卷积脉动阵列架构下，完成可部署简化 YOLOv3-tiny 的卷积加速 IP。

---

## 1. 当前目标

参考项目 `fpga_accelerator_yolov3tiny-main/` 已经完成了一个卷积加速器 IP，并通过简化 YOLOv3-tiny 任务进行了部署测试。本项目当前目标不是直接复刻参考项目，而是在以下架构假设下重新推进：

- 使用 weight-stationary 脉动阵列作为核心计算单元。
- 将卷积展开为分块 GEMM：

```text
OFM[p, cout] = bias[cout] + sum_k IFM[p, k] * W[k, cout]
k = cin * kh * kw
p = oy * ofm_w + ox
```

- 固定当前验证粒度：

| 维度 | Tile | 含义 |
|---|---:|---|
| `K_TILE` | 32 | 32 个 unfolded `(cin, ky, kx)` 输入 lane，对应 32 个 PE row |
| `COUT_TILE` | 64 | 32 个 PE column，每列计算 2 个输出通道 |
| `P_TILE` | stream | 当前先按输出像素窗口逐点流式输入 |

当前设计的核心计算语义是：

1. 第一个 K tile：`psum_top` 注入 bias。
2. 中间 K tile：`psum_top` 注入上一轮 partial sum。
3. 最后 K tile：输出完整 PSUM，再进入 requant / activation / writeback。
4. 多 Cout block：每 64 个输出通道为一组，更换权重后复用 IFM 流。

`PSUM_W` 当前固定为 32 bit。原因是 YOLO 风格大层可能出现 `Cin=512/1024, Kh=3, Kw=3` 的长累加链，在逐层量化范围没有完成之前，32 bit 是更稳妥的默认值。

---

## 2. 当前架构

```text
DDR / DMA
  |
  v
Line Buffer
  - 5 bank
  - 3 physical line
  - 每 line 3 份读副本，对应 kx=0/1/2 并行读取
  |
  v
Window Extract
  - 根据 oy, ox, stride, pad, pass_base_k 生成 32 lane IFM
  - 根据 line_fy / line_valid 判断窗口是否 ready
  |
  v
IFM FIFO x 32
  - 当前默认深度 256
  - row r 的 read enable 通过 r*5 周期 stagger 对齐阵列传播
  |
  v
32 x 32 Systolic Array
  - weight-stationary
  - 每个 PE 支持两个 int8 weight 输出
  - 每列产生两个 Cout
  |
  v
PSUM FIFO x 32
  |
  v
Requant
  |
  v
LeakyReLU LUT
  |
  v
DDR / output buffer
```

---

## 3. 已完成工作

### 3.1 数学模型与分块语义

已经锁定当前验证模型：

- 阵列执行 `P x K` 乘 `K x Cout` 的分块 GEMM。
- `K_TILE=32`。
- `COUT_TILE=64`。
- `P` 维度先按窗口逐点流式处理。
- K 方向多 pass 的 `psum_top` 语义已经明确：
  - `is_first_pass=1, use_ext_psum=0`：注入 bias。
  - `use_ext_psum=1`：注入上一轮 partial sum。
  - 否则注入 0。

### 3.2 计算核心

| 模块 | 文件 | 当前状态 |
|---|---|---|
| int8 双权重 PE | `systolic/systolic_pe.v` | 已验证 signed int8 乘法、双权重输出、valid 传播、psum 累加 |
| 小阵列验证 | `tb/tb_systolic_array_small.v` | 已通过 2x/4x 风格的小规模确定性 case |
| 32x32 阵列 | `systolic/systolic_array_32x32.v` | 已接入 valid-based 数据传播 |
| 顶层计算控制 | `systolic/systolic_ctrl.v` | 已加入 `num_pixels` 和 conservative drain done |
| 顶层集成 | `systolic/systolic_top.v` | 已支持手动 IFM FIFO 与 DMA/line-buffer 两种输入模式 |

### 3.3 IFM 倾斜输入

当前 IFM stagger 方式：

- `compute_active` 直接驱动 row 0 的 IFM FIFO read enable。
- row `r` 的 read enable 由 `com_shift_reg #(DEPTH=r*5)` 延迟得到。
- 这样 IFM 水平方向输入与 PSUM 垂直方向传播对齐。

这一部分已经通过：

- PE 单元测试。
- 小阵列测试。
- `systolic_top` multipass 测试。

### 3.4 partial sum 注入与多 K tile

已经完成：

- bias 注入。
- external psum 注入。
- `K=64/96` 风格的多 K tile 累加验证。
- partial sum 原始值比较。

相关 testbench：

- `tb/tb_systolic_top_multipass.v`
- `tb/tb_layer_scheduler_small.v`

### 3.5 多 Cout block 语义

当前已经在模型和调度计划中明确：

- 一个 Cout block 对应 64 个输出通道。
- `Cout > 64` 时更换权重块。
- IFM 数据在不同 Cout block 间复用。
- 输出写回不同 OFM 通道范围。

目前还没有完成完整 `Cout=128` 的专用 RTL testbench，这是后续计划中的一个独立验证点。

### 3.6 line buffer 与 window extract

已经完成并修正：

- `line_buffer_5bank.v`
  - 5 bank。
  - 3 physical line。
  - 每行 3 份读副本，支持 `kx=0/1/2` 并行读。
  - 新增 `line_fy_out`、`line_valid_out`、`wr_ptr_out`。
  - `line_advance` 后才将当前 physical line 标记为 valid。

- `window_extract.v`
  - 使用 runtime `fm_h/fm_w/stride/pad/oy/ox/pass_base_k`。
  - 修正了早期 `rd_x=ox/ox+1/ox+2` 与真实 `fx=ox*stride+kx-pad` 不一致的问题。
  - 新增 `window_ready`。
  - 对 padding 区域输出 0。
  - 只有需要的输入行都在 line buffer 中时，`ifm_valid` 才有效。

已覆盖：

- `3x3 pad=1 stride=1`
- `3x3 stride=2`
- `1x1` 相关窗口语义的基础映射
- 边界 padding
- 连续写入 row0/1/2/3/4 后滑动读取 oy0/1/2

### 3.7 连续流控制

为了满足连续流要求，已经新增两个独立控制器。

#### `line_stream_ctrl.v`

负责输出行级调度：

```text
fill row 0
fill row 1
fill row 2
compute oy 0
prefetch row 3
compute oy 1
prefetch row 4
compute oy 2
done
```

特点：

- 保守策略：当前输出行计算完成后才预取下一行。
- 避免 line buffer 覆盖当前窗口仍然需要的 physical line。
- 使用 `fill_req/fill_done` 与 `compute_start/compute_done` 握手。
- 已通过带延迟应答的独立 testbench。

#### `window_stream_ctrl.v`

负责单个输出行内部的 `ox` 连续发射：

- 接收 `start_oy` 与 `ofm_w`。
- 维护稳定的 `oy/ox`。
- 当 `window_ready && !ifm_fifo_full_any` 时产生 `ifm_push`。
- 如果窗口未 ready 或 IFM FIFO full，则保持 `ox` 不变。
- `ifm_push` 为组合 accept 信号，便于在采样边沿使用当前稳定的 `oy/ox`。

该模块是后续 window feeder 的基础。

---

## 4. 当前测试与回归

统一回归脚本：

```powershell
powershell -ExecutionPolicy Bypass -File tb\run_iverilog_regression.ps1
```

当前已纳入回归的 testbench：

| Testbench | 目的 |
|---|---|
| `tb_tiling_model` | 分块 GEMM / pass 语义模型 |
| `tb_systolic_pe` | 单 PE signed int8、双权重、valid、psum |
| `tb_systolic_array_small` | 小阵列确定性验证 |
| `tb_systolic_top_multipass` | 顶层多 K tile partial sum feedback |
| `tb_window_top_singlepass` | line buffer + window + top 单 pass |
| `tb_layer_scheduler_small` | 小层 K tile 调度、空间遍历、psum feedback |
| `tb_line_stream_ctrl` | 连续流行级调度 |
| `tb_window_stream_ctrl` | 输出行内部窗口发射与背压 |
| `tb_window_extract` | stride/pad/window/lane 映射 |
| `tb_linebuf_stream` | 行缓存连续滑动更新 |
| `tb_requant` | requant 饱和、valid 链 |

最近一次完整回归结果：

```text
all selected Icarus regressions passed
```

---

## 5. 最近提交节点

| Commit | 内容 |
|---|---|
| `3d64d46` | 添加 systolic tiling 回归测试，`PSUM_W` 提升到 32 bit |
| `e2db82d` | 添加 top multipass psum feedback 测试 |
| `8b0a9f9` | 为 stagger shift register 添加 reset |
| `eb1850f` | 使用 `num_pixels` 和 done pulse 约束 systolic compute |
| `c44169d` | 添加 window 到 top 的 single pass 测试 |
| `2ab9aee` | 添加 small layer scheduler regression |
| `128d5bc` | 添加 line readiness，修正 streaming window 行有效性 |
| `35db91f` | 添加 line stream scheduler control |
| `07e243b` | 添加 window stream control |

---

## 6. 当前可行性评估

当前思路总体可行，原因是几个高风险语义已经被拆开并通过了独立验证：

- PE 与阵列的 signed int8 乘累加语义已经验证。
- IFM stagger 与 valid 传播已经验证。
- K tile 多 pass partial sum feedback 已经验证。
- line buffer 与 window extract 的 stride/pad/边界映射已经修正并验证。
- 连续流下 line readiness 和窗口发射背压已经开始形成独立控制边界。

但还不能认为卷积 IP 层级已经完成，原因是：

- 目前仍缺少正式的 `window_feeder` 集成模块。
- `line_stream_ctrl` 和 `window_stream_ctrl` 尚未接入 `systolic_top`。
- 多 Cout block 的真实调度还没有专用回归。
- PSUM FIFO 到 requant/activation/writeback 的完整层级链路尚未形成统一 testbench。
- AXI-Lite 配置、AXI-Stream DMA、PS 调度尚未开始对接。

---

## 7. 已知问题与风险

### 7.1 line buffer 预取策略偏保守

当前 `line_stream_ctrl` 为了保证正确性，采用“当前输出行完成后再预取下一行”的策略。这能避免覆盖当前窗口需要的物理行，但吞吐率不是最优。

后续可以在 window feeder 验证稳定后，再考虑更激进的边计算边预取策略。

### 7.2 顶层 `systolic_top` 还缺少统一 window feeder 接口

当前 `systolic_top` 仍然直接接收外部 `oy/ox`，并用 `compute_active || ctrl_pre_write` 作为 window 到 IFM FIFO 的写入条件。这在测试中可控，但不适合作为最终连续流架构。

后续应该将：

- line fill 调度
- window ready 检查
- `ox` 递增
- IFM FIFO 背压

整合到单独的 window feeder 或 layer scheduler 中。

### 7.3 IFM FIFO 深度需要结合真实层参数复核

当前 `IFM_FIFO_DEPTH=256`。这个深度对当前小型回归足够，但真实层中需要分析：

- 阵列 drain latency。
- window feeder 写入速度。
- DMA 行填充暂停。
- 多 K tile 与多 Cout block 复用方式。

### 7.4 `PSUM_W=32` 仍需逐层量化范围分析

32 bit 当前是正确优先的选择。后续如果要优化资源，可以根据 YOLOv3-tiny 每层的 `Cin * Kh * Kw`、输入量化范围、权重量化范围和 bias 范围，判断是否能降到 24 bit 或 28 bit。

---

## 8. 后续计划

### Step A：集成 window feeder

新增一个小顶层模块，例如 `window_feeder.v`：

- 接入 `line_buffer_5bank`。
- 接入 `window_extract`。
- 接入 `line_stream_ctrl`。
- 接入 `window_stream_ctrl`。
- 输出：
  - `ifm_data[255:0]`
  - `ifm_push`
  - `busy`
  - `done`

对应 testbench：

- `tb_window_feeder.v`
- 输入 `5x5 Cin=5 Kh=3 Kw=3 stride=1 pad=0`
- 验证完整 `ofm_h * ofm_w` 的窗口流。
- 覆盖 window stall 和 IFM FIFO full stall。

### Step B：将 window feeder 接入 `systolic_top`

目标：

- 不再由 testbench 手动驱动 `oy/ox`。
- `systolic_top` 内部由 window feeder 产生 IFM FIFO 写入。
- 阵列 `num_pixels` 与 window feeder 的输出窗口数量保持一致。

验证：

- 先复用 `tb_window_top_singlepass`。
- 再扩展到 `5x5 Cin=5 Cout=64 Kh=3 Kw=3` 的完整单 pass。

### Step C：多 K tile + window feeder

目标：

- 使用真实 line buffer/window feeder 生成 IFM。
- 跑 `K=45` 或 `K=64/96` 的多 pass。
- pass0 注入 bias。
- pass1/pass2 注入 previous partial sum。

验证：

- 对比 Python golden convolution。
- 同时检查 raw PSUM 与 requant 后 INT8。

### Step D：多 Cout block

新增 `Cout=128` 回归：

- 分两个 64 通道块。
- 同一 IFM 流复用。
- 更换 weight block。
- 输出写回不同 channel range。

这是从“单阵列块正确”走向“层级调度正确”的关键一步。

### Step E：完整单层调度

选一个真实风格缩小层，例如：

- `Cin=16`
- `Cout=32/64`
- `H/W` 使用缩小尺寸而不是直接上 208
- `Kh=3, Kw=3`

验证内容：

- K 分块。
- Cout 分块。
- 空间像素遍历。
- final pass 判定。
- requant / activation / writeback。

完成这一步后，才能认为卷积 IP 层级基本可用。

### Step F：YOLOv3-tiny 代表层验证

先验证 2 到 3 个代表层：

- 首层。
- `26 -> 13` 附近的 stride/downsample 层。
- `13x13 Cin=512/1024` 大通道层。

再串联参考项目采用的简化单尺度 YOLO 流程。

### Step G：系统接口对接

最后再进入：

- AXI-Lite 配置寄存器。
- AXI-Stream DMA。
- PS 端调度。
- 与参考项目部署流程对接。

---

## 9. 当前结论

当前项目已经从“计算核心是否正确”推进到“连续流窗口供应是否正确”的阶段。现在最重要的下一步不是直接做最终 top 或 YOLO 部署，而是把 `line_stream_ctrl + window_stream_ctrl + line_buffer + window_extract` 合并成可独立验证的 window feeder。

只要 window feeder 通过完整窗口流回归，后续再接 `systolic_top` 的成功率会明显高于直接做顶层大仿真。

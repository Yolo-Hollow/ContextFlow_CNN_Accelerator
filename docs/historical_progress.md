# Systolic Accelerator 历史开发记录

> 最后更新：2026-06-19

> 本文档归档项目早期设计说明和阶段性实验日志，仅用于追溯设计演进。当前有效状态以 `project_status_and_roadmap.md` 为准。

## 第一阶段：早期设计与验证记录

本文档记录 `accelerator_systolic/` 当前的卷积脉动阵列 IP 设计状态、已验证语义、分块策略、测试结果和后续计划。目标是在 weight-stationary 脉动阵列架构下，完成可部署简化 YOLOv3-tiny 的卷积加速 IP。

---

## 1. 当前目标

参考项目 `fpga_accelerator_yolov3tiny-main/` 已经实现了一个卷积加速器 IP，并完成简化 YOLOv3-tiny 测试。本项目当前采用重新设计的方式推进：

- 使用 weight-stationary systolic array 作为核心计算单元。
- 将卷积转化为分块 GEMM：

```text
OFM[p, cout] = bias[cout] + sum_k IFM[p, k] * W[k, cout]
k = cin * kh * kw
p = oy * ofm_w + ox
```

- 当前固定验证粒度：

| 维度 | Tile | 含义 |
|---|---:|---|
| `K_TILE` | 32 | 32 个 unfolded `(cin, ky, kx)` 输入 lane，对应 32 个 PE row |
| `COUT_TILE` | `COLS * 2`，典型为 64 | 32 个 PE column，每列计算 2 个输出通道 |
| `P_TILE` | stream / spatial tile | 输出像素按窗口流式处理，可按输出行分块 |

当前计算语义：

1. 第一个 K tile 注入 bias。
2. 中间 K tile 注入上一轮 partial sum。
3. 最后 K tile 输出完整 PSUM，进入 requant / activation / writeback。
4. `Cout > COUT_TILE` 时按输出通道 block 分多次计算，每个 block 更换权重，复用 IFM。
5. 大尺寸 OFM 可按输出行分多个 spatial tile 执行，每个 tile 写回全局 OFM 的不同地址范围。

Requant 语义：

- 软件配置中的 `shift` 是由 `frexp` 生成的 raw shift。
- 软件配置中的 `mult = round(base * 2^15)`，因此 RTL 实际使用 `effective_shift = shift + 15`。
- RTL golden 采用整数 bias：`psum = conv_accumulator + int32_bias`。这与 PyTorch quantized conv 的 float-bias 语义可能存在少量 1 LSB 级差异，但更适合硬件整数推理。

`PSUM_W` 当前保持 32 bit。原因是 YOLO 风格的大通道层可能出现 `Cin=512/1024, Kh=3, Kw=3` 的长累加链，在逐层量化范围分析完成前，32 bit 是更稳妥的默认值。

---

## 2. 当前架构

```text
DDR / DMA / testbench source
  |
  v
Line Buffer
  - 5 bank
  - 3 physical lines
  - 每行支持 kx=0/1/2 三列并行读取
  |
  v
Window Extract
  - 根据 oy, ox, stride, pad, pass_base_k 生成 32-lane IFM
  - 根据 line_fy / line_valid 判断窗口是否 ready
  |
  v
Window Feeder
  - line_stream_ctrl 负责输出行级调度和行请求
  - window_stream_ctrl 负责单行内 ox 推进和 IFM FIFO 背压
  |
  v
IFM FIFO x 32
  - row r 的 read enable 通过 r*5 周期 stagger 对齐阵列传播
  |
  v
32 x 32 Systolic Array
  - weight-stationary
  - 每个 PE 支持 1 个 IFM 和 2 个 int8 weight
  - 每列产生 2 个 Cout
  |
  v
PSUM FIFO x 32
  |
  v
PSUM drain / ping-pong feedback
  |
  v
Requant / Activation
  |
  v
OFM writeback
  - HWC layout
  - 支持 spatial tile 的 pixel_base 偏移
```

---

## 3. 分块策略

### 3.1 K 分块

- `K_TOTAL = Cin * Kh * Kw`
- 每次计算 `K_TILE=32` 个 unfolded 输入 lane。
- `K_TOTAL > 32` 时分多个 K pass。
- pass0 使用 bias。
- pass1/pass2/... 使用上一轮 partial sum。
- final pass 输出完整 PSUM，并进行后处理。

### 3.2 Cout 分块

- `COUT_TILE = COLS * 2`。
- 当前典型配置 `COLS=32`，因此 `COUT_TILE=64`。
- `Cout > 64` 时，按 `cout_base = 0, 64, 128...` 分 block。
- 每个 Cout block 重新加载对应权重 tile。
- IFM 窗口流在不同 Cout block 间复用。
- OFM writeback 根据 `cout_base + lane` 写入不同输出通道范围。

### 3.3 Spatial 分块

为支持大尺寸特征图，当前加入了按输出行分块的 spatial tile 配置：

| 配置 | 含义 |
|---|---|
| `tile_oy_base` | 当前 tile 的全局输出起始行 |
| `tile_ofm_h` | 当前 tile 覆盖的输出行数，0 表示整张 OFM 高度 |
| `tile_pixel_base` | 当前 tile 在 HWC OFM 中的全局 pixel 起始下标，通常为 `tile_oy_base * ofm_w` |
| `num_pixels` | 当前 tile 的输出像素数，通常为 `tile_ofm_h * ofm_w` |

OFM 写回地址：

```text
wr_addr = (tile_pixel_base + local_pixel) * cout_total + (cout_base + channel)
```

这样不需要在片上保存整张 OFM。每个 spatial tile 完成后可以直接写回全局输出缓冲。

---

## 4. 配置寄存器

当前 `layer_config_regs.v` 的本地配置寄存器如下：

| 地址 | 名称 | 字段 |
|---:|---|---|
| `0x00` | CTRL/STATUS | 写 bit0 产生 start 脉冲，写 bit1 清除 done；读 bit0 为 busy，读 bit1 为 done_sticky |
| `0x01` | FM_SIZE | `[8:0]=fm_h`, `[24:16]=fm_w` |
| `0x02` | OFM_SIZE | `[8:0]=ofm_h`, `[24:16]=ofm_w` |
| `0x03` | CONV | `[1:0]=stride`, `[9:8]=pad` |
| `0x04` | K_TOTAL | `[10:0]=k_total` |
| `0x05` | COUT_TOTAL | `[10:0]=cout_total` |
| `0x06` | NUM_PIXELS | `[15:0]=num_pixels` |
| `0x07` | ACT_CFG | `[1:0]=activation_mode`, 0=旁路，1=ReLU，2=Leaky LUT |
| `0x08` | TILE_ROWS | `[8:0]=tile_oy_base`, `[24:16]=tile_ofm_h` |
| `0x09` | PIXEL_BASE | `[23:0]=tile_pixel_base` |

这些寄存器目前仍是本地简化接口：

```verilog
cfg_wr_en
cfg_addr
cfg_wdata
cfg_rd_en
cfg_rdata
```

后续可以直接封装成 AXI-Lite slave。

---

## 5. 已完成模块

| 模块 | 文件 | 当前状态 |
|---|---|---|
| PE | `systolic/systolic_pe.v` | 已验证 signed int8、双权重、valid 延迟、psum 累加 |
| 阵列 | `systolic/systolic_array_32x32.v` | 已接入 valid-based 数据传播 |
| 顶层计算 | `systolic/systolic_top.v` | 支持手动 IFM FIFO 与 feeder 输入路径 |
| IFM FIFO | `systolic/systolic_fifo.v` | 已用于 32 lane 输入 FIFO |
| 行缓存 | `systolic/line_buffer_5bank.v` | 5 bank、3 physical lines、行有效标记 |
| 窗口抽取 | `systolic/window_extract.v` | 支持 stride/pad/pass_base_k，padding 输出 0 |
| 行调度 | `systolic/line_stream_ctrl.v` | 支持 `tile_oy_base/tile_ofm_h` 的行请求 |
| 行内窗口流 | `systolic/window_stream_ctrl.v` | 支持 window ready 和 IFM FIFO 背压 |
| 窗口 feeder | `systolic/window_feeder.v` | 已集成 line buffer、window extract、两级控制 |
| feeder 顶层 | `systolic/systolic_top_feeder.v` | 已接入 systolic_top |
| 层调度 | `systolic/layer_scheduler_stream.v` | 支持 K pass 与 Cout block 调度 |
| 权重加载 | `systolic/weight_tile_loader.v` | 支持 weight tile 装载到阵列 FIFO |
| PSUM ping-pong | `systolic/psum_pingpong_buffer.v` | 支持 partial sum feedback |
| PSUM 流注入 | `systolic/psum_stream_feeder.v` | 支持倾斜注入 partial sum |
| PSUM drain | `systolic/psum_drain_writer.v` | 支持从 PSUM FIFO 收集输出包 |
| requant | `systolic/ofm_requant_writer.v` / `systolic/requant.v` | 已接入输出后处理路径 |
| activation | `systolic/ofm_activation.v` / `systolic/leaky_lut.v` | 支持 bypass/ReLU/Leaky LUT |
| OFM writeback | `systolic/ofm_writeback.v` | 支持 `pixel_base` 全局写回 |
| 卷积层流顶层 | `systolic/conv_layer_top_stream.v` | 已串联 feeder、scheduler、psum、requant、activation、writeback |
| 配置 wrapper | `systolic/conv_accel_core.v` | 已接入本地配置寄存器和量化寄存器 |
| AXI-Lite 配置桥 | `systolic/axi_lite_cfg_bridge.v` | 已将 AXI-Lite 读写转换为本地 `cfg_*` 配置总线 |

---

## 6. 当前验证结果

### 6.1 Icarus 关键回归

最近通过的关键 Icarus 测试：

```text
tb_layer_config_regs:                  20 pass, 0 fail
tb_line_stream_ctrl:                   11 pass, 0 fail
tb_line_stream_ctrl_tile:              11 pass, 0 fail
tb_window_feeder:                      300 pass, 0 fail
tb_window_feeder_pad1:                 832 pass, 0 fail
tb_window_feeder_stride2:              139 pass, 0 fail
tb_ofm_writeback:                      22 pass, 0 fail
tb_systolic_top_feeder_singlepass:     73 pass, 0 fail
tb_systolic_top_feeder_multipass_stream: 288 pass, 0 fail
tb_systolic_top_feeder_cout_blocks:    144 pass, 0 fail
```

`tb_line_stream_ctrl_tile` 专门验证：

- `tile_oy_base=2`
- `tile_ofm_h=3`
- `stride=1`
- `pad=1`

预期只请求 IFM 行 `1..5`，不会从第 0 行开始无效填充。

### 6.2 XSIM 长回归

当前使用 Vivado XSIM 运行较长测试：

```powershell
vivado -mode batch -source tcl\run_xsim_regression.tcl
```

最近通过结果：

```text
tb_conv_accel_core_realistic_small:     1163 pass, 0 fail
tb_layer_scheduler_cout64_fulltile:     84 pass, 0 fail
tb_conv_accel_core_cout64_fulltile:     75 pass, 0 fail
tb_conv_accel_core_cout128_blocks:      139 pass, 0 fail
tb_conv_accel_core_spatial_tile:        443 pass, 0 fail
tb_conv_accel_core_spatial_multitile:   1163 pass, 0 fail
tb_conv_accel_core_ps_driver:           1163 pass, 0 fail
tb_axi_lite_cfg_bridge:                 37 pass, 0 fail
```

其中：

- `tb_conv_accel_core_cout64_fulltile` 验证完整 64 输出通道 tile。
- `tb_conv_accel_core_cout128_blocks` 验证 `Cout=128`，分两个 Cout block。
- `tb_conv_accel_core_spatial_tile` 验证非零 `tile_oy_base` 的单个空间 tile。
- `tb_conv_accel_core_spatial_multitile` 将 `8x8` OFM 分为 `3+3+2` 行三次启动，最终拼接出完整 OFM。
- `tb_conv_accel_core_ps_driver` 固化 PS-style 调度契约，检查 start/done/clear、bias/weight/line fill 服务次数。
- `tb_axi_lite_cfg_bridge` 验证 AXI-Lite 到本地配置总线的读写转换、`WSTRB` byte merge、start pulse 和 done clear。

---

## 7. 当前设计结论

当前项目已经从“单个计算核正确”推进到“卷积层核心数据流基本闭环”：

- K tile 多 pass 已验证。
- Cout block 已验证到 `Cout=128`。
- line buffer + window extract 的 stride/pad/padding 映射已验证。
- partial sum ping-pong feedback 已验证。
- requant / activation / writeback 已接入。
- spatial tile 已验证单 tile 和多 tile 拼接。
- PS-style layer driver 已覆盖多 spatial tile、多 K pass、多 Cout block 的软件调度顺序。

因此，按当前思路继续推进是可行的。但现在还不能直接认为是完整可部署 IP，原因是外部系统接口和 PS 调度契约尚未固化。

---

## 8. 当前风险与待确认点

### 8.1 AXI 接口尚未实现

当前配置接口仍是本地寄存器风格，数据输入输出也还是 testbench 驱动模型。后续需要封装：

- AXI-Lite 配置寄存器接口。
- 权重/偏置加载接口。
- IFM 行填充接口。
- OFM 写回接口。

### 8.2 DMA 调度契约需要固化

在进入 AXI 前，需要先明确 PS/DMA 视角的协议：

- 何时响应 `bias_load_req`。
- 何时响应 `weight_load_req`。
- 何时响应 `feeder_fill_req`。
- 每个 spatial tile 如何配置 `num_pixels/tile_oy_base/tile_ofm_h/tile_pixel_base`。
- 多 Cout block 时权重如何重新载入。
- 多 K pass 时 partial sum buffer 如何保持与回灌。

### 8.3 缓存深度仍需结合目标平台复核

当前 FIFO/PSUM buffer 深度对测试用例足够，但面向 XCK26/Kria K26 部署时，需要结合 BRAM/URAM/DSP/LUT 资源和目标吞吐重新估算：

- IFM FIFO 深度。
- PSUM ping-pong buffer 深度。
- OFM packet FIFO 深度。
- weight tile buffer 容量。

### 8.4 资源优化尚未开始

目前优先保证正确性。后续可能需要评估：

- `PSUM_W=32` 是否可降到 24/28 bit。
- 阵列规模是否固定 32x32，或在 XCK26 上采用更小阵列。
- `COUT_TILE=64` 对资源和带宽是否最优。

---

## 9. PS 调度契约

当前已通过 `tb_conv_accel_core_ps_driver` 固化第一版 PS-style layer driver。该 driver 不引入 AXI 时序，只模拟未来 PS 软件和 DMA 服务端应完成的调度动作：

1. 初始化 quant 参数。
2. 写 layer-level 配置寄存器。
3. 对每个 spatial tile 写 `num_pixels/tile_oy_base/tile_ofm_h/tile_pixel_base`。
4. 写 `CTRL.start` 启动当前 tile。
5. 响应 `bias_load_req`，按 `current_cout_base` 写入当前 Cout block 的 bias。
6. 响应 `weight_load_req`，按 `current_cout_base/current_pass_base_k` 写入当前 weight tile。
7. 响应 `feeder_fill_req`，按 `feeder_fill_fy/current_pass_base_k` 写入当前 K pass 需要的 IFM 行。
8. 轮询 `done_sticky`。
9. 写 `CTRL.clear_done` 清除 done，再启动下一个 spatial tile。
10. 最后检查全局 OFM memory 与 golden convolution 一致。

当前契约检查：

| 检查项 | 期望 |
|---|---|
| tile start 次数 | `TILE_COUNT` |
| done seen 次数 | `TILE_COUNT` |
| done clear 次数 | `TILE_COUNT` |
| bias service 次数 | `TILE_COUNT * COUT_BLOCKS` |
| weight service 次数 | `TILE_COUNT * COUT_BLOCKS * K_PASSES` |
| line fill service 次数 | 大于 0，并由 feeder 按窗口需要发起 |

`tb_conv_accel_core_ps_driver` 当前配置：

```text
FM/OFM:      8x8
Cin:         16
K_TOTAL:     16 * 3 * 3 = 144
K_PASSES:    5
COLS:        4
COUT_TILE:   8
Cout:        18
COUT_BLOCKS: 3
Spatial:     3 tiles, rows 3 + 3 + 2
```

这一步完成后，AXI 接口的工作可以理解为把这些 testbench task 翻译成 AXI-Lite/AXI-Stream 或 memory-mapped DMA 事务。

---

## 10. 下一步计划

### Step A：继续文档化软件调度契约

需要明确每次 layer/tile 启动前 PS 必须配置：

- `fm_h/fm_w`
- `ofm_h/ofm_w`
- `stride/pad`
- `k_total`
- `cout_total`
- `num_pixels`
- `tile_oy_base`
- `tile_ofm_h`
- `tile_pixel_base`
- `activation_mode`
- quant 参数
- Leaky LUT 参数

### Step B：AXI-Lite 配置接口

当前已新增 `axi_lite_cfg_bridge.v`，完成 AXI-Lite 到 `cfg_*` 本地配置总线的第一版转换。下一步应将它接到 `conv_accel_core` 的配置端口，并新增 AXI-Lite 版本的 PS driver testbench，用 AXI-Lite transaction 替代当前直接调用 `cfg_write` 的 task。

### Step C：数据搬运接口

在配置接口稳定后，再分别设计：

- bias load stream 或 memory-mapped load。
- weight tile stream 或 memory-mapped load。
- IFM line fill DMA 接口。
- OFM writeback DMA 接口。

### Step D：YOLOv3-tiny 代表层测试

优先选择 2 到 3 个代表层：

- 首层。
- `26 -> 13` 附近的 stride/downsample 层。
- `13x13 Cin=512/1024` 大通道层。

先做缩小版参数验证，再逐步靠近真实网络。

---

## 11. 当前建议

下一步不建议马上写完整 AXI 数据接口。更稳妥的路线是：

1. 继续完善 PS 调度契约文档。
2. 将 `axi_lite_cfg_bridge` 接到 `conv_accel_core` 顶层配置端口。
3. 用 AXI-Lite testbench 替代当前 `cfg_*` task。
4. 最后接 DMA/AXI-Stream 数据路径。

这样可以避免把调度语义问题和总线时序问题混在一起调试。

---

## 12. 2026-05-25 AXI-Lite 配置路径更新

本轮已经完成第一版 AXI-Lite 配置路径闭环：

- 新增 `systolic/axi_lite_cfg_bridge.v`，将 AXI-Lite read/write 转换为本地 `cfg_*` 配置总线。
- 新增 `systolic/conv_accel_core_axi_lite.v`，在不改变计算 datapath 的前提下，用 AXI-Lite 替代 `conv_accel_core` 的本地 layer 配置端口。
- 新增 `tb/tb_axi_lite_cfg_bridge.v`，覆盖普通读写、AW/W 分离到达、`WSTRB` byte merge、start pulse、done sticky/clear。
- 新增 `tb/tb_conv_accel_core_axi_lite_ps_driver.v`，用 AXI-Lite transaction 执行与 `tb_conv_accel_core_ps_driver` 相同的 PS-style spatial tile 调度。

当前通过的关键 XSIM 结果：

```text
tb_conv_accel_core_axi_lite_ps_driver: 1163 pass, 0 fail
tb_conv_accel_core_ps_driver:          1163 pass, 0 fail
tb_axi_lite_cfg_bridge:                37 pass, 0 fail
```

调试中确认过一个重要 testbench 细节：AXI master task 不能在 `RVALID/BVALID` 出现后的同一个半周期立即撤销 `RREADY/BREADY`，否则 bridge 可能没有在上升沿采样到 response handshake，导致后续读事务因为旧 `RVALID` 未清而卡住。当前 testbench 已修正为让 `RREADY/BREADY` 至少跨过一个上升沿。

因此，配置路径目前已经从“本地寄存器 task”推进到“AXI-Lite 配置 wrapper + PS-style 调度仿真”。下一步可以开始固化数据搬运侧接口，优先顺序建议为：

1. bias/weight tile load 的 memory-mapped 或 stream 协议。
2. IFM line fill DMA 服务协议。
3. OFM writeback 到外部 memory 的 DMA/AXI master 接口。
4. 真实 YOLOv3-tiny 代表层的端到端 PS 调度脚本。

---

## 13. 2026-05-25 Bias/Weight Stream Load 更新

在 AXI-Lite 配置路径通过后，本轮继续把 bias/weight 数据搬运从 testbench 的直接写端口推进到 ready/valid stream 协议。

新增模块：

- `systolic/bias_weight_stream_loader.v`
  - 输入 `bias_load_req` 后，拉高 `bias_s_ready`，按 lane 顺序接收 `COUT_TILE` 个 bias word。
  - 输出 `bias_wr_en/bias_wr_addr/bias_wr_data`，写入现有 bias 注入路径。
  - 输入 `weight_load_req` 后，拉高 `weight_s_ready`，按 `row * COUT_TILE + cout_lane` 顺序接收一个完整 weight tile。
  - 输出 `wgt_tile_wr_en/wgt_tile_wr_addr/wgt_tile_wr_data`，写入现有 `weight_tile_loader` 的 tile buffer。

- `systolic/conv_accel_core_axi_lite_stream.v`
  - 保留 AXI-Lite 配置端口。
  - 将原本外露的 `bias_wr_*` 和 `wgt_tile_wr_*` 直接写端口替换为 bias/weight stream 端口。
  - IFM line fill 和 OFM writeback 仍暂时保持现有本地端口，后续再逐步 DMA 化。

新增验证：

```text
tb_bias_weight_stream_loader:                 70 pass, 0 fail
tb_conv_accel_core_axi_lite_stream_ps_driver: 1163 pass, 0 fail
```

其中 `tb_conv_accel_core_axi_lite_stream_ps_driver` 覆盖：

- AXI-Lite 配置 layer/tile 参数。
- bias 通过 ready/valid stream 注入。
- weight tile 通过 ready/valid stream 注入。
- 3 个 spatial tile：`3 + 3 + 2` 输出行。
- `Cin=16, K_TOTAL=144, K_PASSES=5`。
- `Cout=18, COUT_TILE=8, COUT_BLOCKS=3`。
- 最终 OFM 与 golden convolution 对比一致。

调试中确认了一个重要 stream 时序规则：PS/DMA 服务端必须先等待 `bias_s_ready/weight_s_ready` 有效，再发送第一个 word。不能在 `*_load_req` 刚出现时就提前覆盖第一个数据，否则 loader 进入 busy 的第一个上升沿还不会采样该 word，可能导致 tile 少收一个元素。

下一步建议开始做 IFM line fill DMA 协议：

1. 将当前 `feeder_fill_req/feeder_fill_fy` 固化为 line-fill request。
2. 定义一行 IFM 数据的 stream 顺序：`x=0..fm_w-1`，每个 x 写 5 个 bank。
3. 用 ready/valid 或 burst-style 接口替代当前 testbench 直接驱动的 `dma_bank_wr_en/dma_wr_x/dma_wr_fy/dma_wr_data/dma_line_advance`。
4. 新增 line-fill stream loader 单测，再接入 `conv_accel_core_axi_lite_stream` 级长测试。

---

## 14. 2026-05-25 IFM/OFM Stream 与 Full-Stream 顶层更新

本轮已经将数据搬运接口继续从 bias/weight 推进到 IFM line fill 和 OFM stream writeback，形成第一版 DMA-facing 顶层：

- `systolic/ifm_line_stream_loader.v`
- `systolic/ofm_byte_stream_fifo.v`
- `systolic/ofm_packet_fifo.v`
- `systolic/psum_packet_fifo.v`
- `systolic/conv_accel_core_axi_lite_full_stream.v`

当前 full-stream 顶层包含：

```text
AXI-Lite config
  + bias stream
  + weight stream
  + IFM line fill stream
  + OFM byte stream
```

### 14.1 IFM 行填充流

`ifm_line_stream_loader` 将 PS/DMA 侧的一行 IFM stream 转换为现有 line buffer 写接口。

外部 IFM stream 的数据语义是 `uint8 activation`。进入 line buffer 前，
loader 会使用配置寄存器 `0x0f` 的 `input_zero_point[7:0]` 做中心化：

```text
centered = ifm_u8 - input_zero_point
if centered > 127:  ifm_s8 = 127
if centered < -128: ifm_s8 = -128
else:               ifm_s8 = centered[7:0]
```

line buffer 仍然只存 8 bit，但语义是 two's-complement signed int8 centered IFM。
窗口越界 padding 仍是内部 signed 0；未被当前 K pass 使用的 stream bank 应发送
`input_zero_point`，这样写入 line buffer 后也是内部 0。

协议语义：

```text
line_stream_ctrl/window_feeder:
  feeder_fill_req = 1
  feeder_fill_fy  = requested input feature row

PS/DMA source:
  wait(ifm_line_s_ready)
  send x = 0..fm_w-1
  each beat carries 5 bank bytes
```

接口：

```verilog
input  [8:0] ifm_line_words;
output       ifm_line_s_ready;
input        ifm_line_s_valid;
input  [7:0] ifm_line_s_data [0:4];
input  [7:0] input_zero_point;
```

内部转换为：

```verilog
dma_bank_wr_en
dma_wr_x
dma_wr_fy
dma_wr_data[0:4]
dma_line_advance
```

已经修正的关键问题：

- `line_stream_ctrl` 在 `fill_done` 当拍只登记已完成行，不再同时继续发旧的 `fill_req/fill_fy`。
- 这样避免 PS/DMA 侧误服务上一行请求，造成“新 fy 地址 + 旧行数据”的错配。

### 14.2 OFM 输出流程

当前 OFM 输出链路为：

```text
PSUM FIFO
  -> psum_drain_writer
  -> final PSUM packet FIFO
  -> requant
  -> requant OFM packet FIFO
  -> activation
  -> activation OFM packet FIFO
  -> ofm_writeback
  -> OFM byte stream FIFO
  -> DMA/PS
```

`ofm_writeback` 将一个 `COUT_TILE` 宽的 OFM packet 展开为 byte stream，地址布局为 HWC：

```text
wr_addr = (tile_pixel_base + local_pixel) * cout_total
        + (cout_base + lane)
```

这意味着：

- 不需要在片上保存整张 OFM。
- 每个 spatial tile 结束后可以直接写回全局输出缓冲。
- `Cout > COUT_TILE` 时，不同 `cout_base` 写到同一 pixel 的不同 channel 范围。

full-stream 顶层对外提供 OFM stream：

```verilog
output                  ofm_m_valid;
input                   ofm_m_ready;
output [OFM_ADDR_W-1:0] ofm_m_addr;
output [7:0]            ofm_m_data;
```

同时保留 testbench 观察口：

```verilog
ofm_mem_wr_en
ofm_mem_wr_addr
ofm_mem_wr_data
```

该观察口等价于 `ofm_m_valid && ofm_m_ready` 时发生的一次 byte 写事件。

### 14.3 OFM ready/valid 背压链

当前已经将 ready/valid 语义从 OFM stream 侧往前推进到后处理链：

- `ofm_byte_stream_fifo` 支持 `ofm_m_valid/ofm_m_ready`。
- `ofm_writeback` 增加 `wr_ready`。
- `ofm_packet_fifo` 缓冲 activation 后的 OFM packet。
- `ofm_activation` 增加 `in_ready/out_ready`，下游不 ready 时保持输出。
- `psum_packet_fifo` 缓冲 final PSUM packet。
- `psum_drain_writer` 增加 `packet_ready`，后处理链不 ready 时不会继续读 PSUM FIFO。
- requant 后增加 OFM packet FIFO，并通过 `almost_full` 为 requant 固定流水线预留飞行中 packet 空间。

当前背压能力定位：

- 已验证可承受短 burst 型 OFM DMA ready 拉低。
- 仍不建议将 `ofm_m_ready` 长时间拉低作为正常工作模式。
- 若系统 DMA 可能长时间停收，应继续增加 FIFO 深度或设计真正的 AXI master writeback，并在调度层限制后处理链积压。

### 14.4 新增验证结果

新增或更新的关键测试：

```text
tb_ifm_line_stream_loader:                         61 pass, 0 fail
tb_ofm_packet_fifo:                                39 pass, 0 fail
tb_ofm_byte_stream_fifo:                            7 pass, 0 fail
tb_conv_accel_core_axi_lite_full_stream_ps_driver: 1165 pass, 0 fail
tb_conv_accel_core_axi_lite_full_stream_backpressure: 1165 pass, 0 fail
```

其中 full-stream backpressure 测试覆盖：

- AXI-Lite 配置。
- bias/weight stream 加载。
- IFM line stream 填充。
- 3 个 spatial tile：`3 + 3 + 2` 输出行。
- `Cin=16, K_TOTAL=144, K_PASSES=5`。
- `Cout=18, COUT_TILE=8, COUT_BLOCKS=3`。
- OFM stream ready 短暂停顿。
- 最终 OFM 与 golden convolution 一致。

---

## 15. 下一步：正式 AXI-Stream 打包协议

当前接口是“DMA-facing ready/valid stream”，还不是完整 AXI-Stream。下一步应将 stream 端口规范化为 AXI-Stream 风格，重点先确定打包协议，而不是马上写复杂 AXI DMA 控制器。

### 15.1 推荐 TDATA 位宽

面向 Zynq UltraScale+ MPSoC/Kria K26，建议优先采用：

```text
TDATA = 64 bit 或 128 bit
```

原因：

- 32 bit 最容易调试，但带宽偏低。
- 64 bit 可以自然打包 8 个 INT8，PS 侧也容易构造。
- 128 bit 更适合高带宽 DMA，但 IFM line 的 5-bank beat 需要 padding 或重新组织。

建议实现顺序：

1. 先实现 64-bit AXI-Stream 包装。
2. testbench 验证稳定后，再扩展到 128-bit。

### 15.2 Bias stream 打包

当前 bias 数据宽度为 `PSUM_W=32`。建议：

```text
64-bit TDATA:
  beat contains 2 bias words
  word0 = TDATA[31:0]
  word1 = TDATA[63:32]
```

每个 Cout block 需要：

```text
ceil(COUT_TILE / 2) beats
```

`TLAST` 建议在一个 bias block 的最后一个 beat 拉高。

### 15.3 Weight stream 打包

当前 weight 为 INT8，顺序为：

```text
for k_lane = 0..K_TILE-1:
  for cout_lane = 0..COUT_TILE-1:
    send weight[k_lane][cout_lane]
```

64-bit TDATA 建议：

```text
beat contains 8 int8 weights
```

每个 weight tile 需要：

```text
K_TILE * COUT_TILE / 8 beats
```

对于当前典型 `K_TILE=32, COUT_TILE=64`：

```text
32 * 64 / 8 = 256 beats
```

`TLAST` 建议在一个 weight tile 的最后一个 beat 拉高。

### 15.4 IFM 行数据流打包

当前 IFM line loader 的逻辑 beat 是：

```text
one x position = 5 bank bytes
```

64-bit TDATA 建议直接打包为：

```text
TDATA[7:0]    = bank0
TDATA[15:8]   = bank1
TDATA[23:16]  = bank2
TDATA[31:24]  = bank3
TDATA[39:32]  = bank4
TDATA[63:40]  = reserved/padding 0
```

每行需要：

```text
fm_w beats
```

`TLAST` 建议在一行最后一个 x 拉高。这样 `feeder_fill_fy` 对应一次 line DMA transaction，PS 调度简单，line buffer 更新边界也清晰。

### 15.5 OFM 数据流打包

当前 OFM 输出是 byte + address：

```verilog
ofm_m_valid
ofm_m_ready
ofm_m_addr
ofm_m_data
```

正式 AXI-Stream 有两种路线：

#### 路线 A：保留 byte stream，PS/DMA 按 HWC 顺序写

优点：

- 最接近当前实现。
- 验证简单。
- 每个 byte 都携带或隐含地址，调试直观。

缺点：

- 带宽低。
- 真正接 AXI DMA 时不希望每个 byte 都传地址。

#### 路线 B：按连续 HWC 地址打包 64-bit/128-bit

推荐作为最终路线。

做法：

- `ofm_writeback` 保证输出地址单调递增或按 block 内可预测顺序。
- `ofm_axis_packer` 收集连续 byte，打包成 64-bit 或 128-bit。
- `TKEEP` 标记最后一个 beat 的有效 byte。
- `TLAST` 在一个 spatial tile 或一个 Cout block 结束时拉高。

建议下一步先实现路线 A 的 AXI-Stream wrapper，用于验证接口时序；随后实现路线 B 的打包优化。

### 15.6 下一阶段任务清单

推荐工作顺序：

1. 新增 `axis_ifm_line_loader`：AXI-Stream 64-bit 输入，解包到 `ifm_line_stream_loader`。
2. 新增 `axis_bias_weight_loader`：AXI-Stream 64-bit 输入，分别服务 bias 和 weight tile。
3. 新增 `axis_ofm_byte_writer`：先将当前 OFM byte stream 封装为 AXI-Stream 输出。
4. 新增 AXI-Stream testbench，覆盖 `TVALID/TREADY/TLAST/TKEEP`。
5. 将 `conv_accel_core_axi_lite_full_stream` 升级为正式 AXI-Lite + AXI-Stream 顶层。
6. 跑一次 Vivado synthesis，获得 XCK26 资源与时序初步数据。

---

## 16. 2026-05-25 AXI-Stream 边界模块进展

已经完成第一批 64-bit AXI-Stream 边界模块，先作为独立 wrapper 验证协议，不改变核心计算链路。

### 16.1 IFM AXI-Stream 行加载器

新增：

```text
systolic/axis_ifm_line_loader.v
tb/tb_axis_ifm_line_loader.v
```

功能：

- `TDATA[39:0]` 解包为 5 个 IFM bank byte。
- 解包后的 byte 是外部 uint8 activation，写 line buffer 前会减 `input_zero_point`
  并饱和到 signed int8。
- `TKEEP[4:0]` 必须为 `5'b11111`。
- `TLAST` 必须只在一行最后一个 x beat 拉高。
- 输出仍复用原来的 `dma_bank_wr_en/dma_wr_x/dma_wr_fy/dma_wr_data/dma_line_advance`。

### 16.2 Bias/Weight AXI-Stream 加载器

新增：

```text
systolic/axis_bias_weight_loader.v
tb/tb_axis_bias_weight_loader.v
```

功能：

- bias：64-bit beat 解包为两个 32-bit bias。
- weight：64-bit beat 解包为 8 个 INT8 weight。
- 对每个 load transaction 检查 `TKEEP/TLAST`。
- 输出直接生成 `bias_wr_en/bias_wr_addr/bias_wr_data` 和 `wgt_tile_wr_en/wgt_tile_wr_addr/wgt_tile_wr_data`。

注意：

- testbench 中 AXI 发送任务必须在看到 `TREADY` 后继续保持 `TVALID` 跨过一个 `posedge clk`，否则当 `TREADY` 在 `posedge` 后才变高时会错过真正握手。
- 这类握手细节后续接入更大顶层时也必须保留。

### 16.3 OFM 调试 AXI-Stream 写出模块

新增：

```text
systolic/axis_ofm_byte_writer.v
tb/tb_axis_ofm_byte_writer.v
```

当前采用调试友好的 route A：

```text
TDATA[OFM_ADDR_W-1:0]  = OFM byte address
TDATA[OFM_ADDR_W +: 8] = OFM byte data
TKEEP                  = addr+data 有效 byte mask
TLAST                  = byte_last passthrough
```

这个模块不是最终高带宽写回格式，而是用于先把现有 `ofm_m_valid/ofm_m_ready/ofm_m_addr/ofm_m_data` 接口封装成标准 AXI-Stream。最终仍建议实现 route B：连续 HWC byte 打包为 64-bit/128-bit burst。

### 16.4 当前验证

已通过的新增 AXI-Stream 边界测试：

```text
tb_axis_ifm_line_loader:    55 pass, 0 fail
tb_axis_bias_weight_loader: 72 pass, 0 fail
tb_axis_ofm_byte_writer:    11 pass, 0 fail
```

同时重新验证了原始 bus-agnostic loader：

```text
tb_ifm_line_stream_loader:     61 pass, 0 fail
tb_bias_weight_stream_loader:  70 pass, 0 fail
```

短回归全量运行本次在 180 秒工具超时前未完成，后续建议拆分批次运行或用 Vivado xsim Tcl 回归来获得更稳定的长测试结果。

### 16.5 下一步

已经将这些 AXI-Stream wrapper 接入新的正式顶层：

```text
conv_accel_core_axi_lite_axis_stream.v
```

该顶层包含：

- AXI-Lite 配置接口。
- AXI-Stream Bias 输入。
- AXI-Stream Weight 输入。
- AXI-Stream IFM 行输入。
- AXI-Stream OFM 调试输出。

实现方式：

- 不再套用 `conv_accel_core_axi_lite_full_stream`，避免 loader 嵌套。
- 直接实例化 `conv_accel_core_axi_lite`。
- `axis_bias_weight_loader` 直接驱动 bias SRAM 写口和 weight tile 写口。
- `axis_ifm_line_loader` 直接驱动 line buffer DMA 写口。
- core 的 OFM byte write 先进入 `ofm_byte_stream_fifo`，再由 `axis_ofm_byte_writer` 封装为 AXI-Stream。

新增验证：

```text
tb_conv_accel_core_axi_lite_axis_stream_smoke: 51 pass, 0 fail
```

该 smoke 测试覆盖：

- AXI-Lite 配置。
- AXI-Stream bias/weight/IFM 输入。
- AXI-Stream OFM debug 输出路径。
- 小尺寸卷积与 golden 对比。

当前 AXI 边界回归：

```text
tb_axis_ifm_line_loader:                      55 pass, 0 fail
tb_axis_bias_weight_loader:                   72 pass, 0 fail
tb_axis_ofm_byte_writer:                      11 pass, 0 fail
tb_conv_accel_core_axi_lite_axis_stream_smoke: 51 pass, 0 fail
```

较大的 3-tile AXI PS-driver 已经改用 Vivado xsim Tcl 跑通：

```text
tb_conv_accel_core_axi_lite_axis_stream_ps_driver: 1163 pass, 0 fail
```

该测试的 xsim 仿真结束时间为 `307160 ns`，覆盖 3 个 spatial tile、多个 K pass、多个 Cout block，以及 AXI-Lite + AXI-Stream 输入输出边界。

### 16.6 OFM TLAST 更新

AXI 顶层已经增加 OFM `TLAST` 生成逻辑。

生成方式：

- AXI 顶层旁路监听 AXI-Lite 写配置。
- 写 `COUT_TOTAL` 时保存 `cfg_cout_total`。
- 写 `NUM_PIXELS` 时保存 `cfg_num_pixels`。
- 写 CTRL.start 时锁存：

```text
ofm_expected_bytes = cfg_num_pixels * cfg_cout_total
```

- OFM debug stream 每成功发送一个 byte 递增计数。
- 当 `ofm_byte_count == ofm_expected_bytes - 1` 时，在该 byte 上拉高 `ofm_m_axis_tlast`。
- 因此当前 `TLAST` 语义是：**一个 spatial tile 的最后一个 OFM byte**。

该语义适合当前 PS 调度模型：每个 tile 单独 start，PS/DMA 能用 `TLAST` 判定本 tile 输出事务结束。

更新后的验证：

```text
tb_conv_accel_core_axi_lite_axis_stream_smoke:     53 pass, 0 fail
tb_conv_accel_core_axi_lite_axis_stream_ps_driver: 1165 pass, 0 fail
```

新增检查项：

- 每个 spatial tile 恰好产生一个 OFM `TLAST`。
- bias/weight/IFM 三路 AXI-Stream 协议错误标志均保持为 0。

下一步：

1. 开始准备 Vivado synthesis 工程脚本，先拿 XCK26 资源和 Fmax 初值。
2. 在 synthesis 前再跑一次包含 smoke + 3-tile AXI 长测的 xsim 回归。
3. 后续将 OFM debug stream 优化为连续 HWC 64-bit/128-bit burst stream。

---

## 17. 2026-05-25 XCK26 综合初步结果

已经新增综合脚本：

```text
tcl/run_synth_xck26.tcl
tcl/report_synth_xck26.tcl
tcl/run_opt_report_xck26.tcl
```

目标器件：

```text
xck26-sfvc784-2LV-c
```

### 17.1 32x32 阵列结果

参数：

```text
ROWS=32
COLS=32
K_TILE=32
COUT_TILE=64
```

综合成功，但资源明显超过 XCK26：

```text
CLB LUTs:       230531 / 117120 = 196.83%
CLB Registers: 202296 / 234240 = 86.36%
BRAM Tile:          89 / 144    = 61.81%
DSP48E2:          1155 / 1248   = 92.55%
```

100 MHz 综合后建立时间：

```text
WNS = +1.809 ns
TNS = 0
```

判断：

- 默认 32x32/COUT_TILE=64 版本不适合直接落到 XCK26。
- 主要瓶颈是 LUT，DSP 也已经接近上限。
- `Bonded IOB` 超限是当前仿真顶层把 AXI-Lite/AXI-Stream 展成裸顶层端口导致的 OOC 现象，真正封装成 IP 并接 AXI interconnect 后不应按封装 IO 数理解。

### 17.2 16x16 阵列候选

参数：

```text
ROWS=16
COLS=16
K_TILE=16
COUT_TILE=32
```

综合结果：

```text
CLB LUTs:        70996 / 117120 = 60.62%
CLB Registers:  55879 / 234240 = 23.86%
BRAM Tile:        44.5 / 144    = 30.90%
DSP48E2:           323 / 1248   = 25.88%
```

100 MHz 综合后建立时间：

```text
WNS = +2.144 ns
TNS = 0
```

判断：

- 16x16 是比较稳妥的 XCK26 可落地资源点。
- 代价是 `K_TILE` 从 32 降到 16，多通道卷积的 K pass 数翻倍。

### 17.3 32x16 阵列候选

用户提出的思路是保留 32 行 K_TILE，同时把物理列数降到 16。由于每个 PE 支持双 INT8 输出，16 列物理阵列对应 32 个输出通道 lane：

```text
ROWS=32
COLS=16
K_TILE=32
COUT_TILE=32
```

功能验证：

```text
tb_conv_accel_core_axi_lite_axis_stream_r32_c16_smoke: 213 pass, 0 fail
```

综合结果：

```text
CLB LUTs:       123878 / 117120 = 105.77%
CLB Registers: 102766 / 234240 = 43.87%
BRAM Tile:        44.5 / 144    = 30.90%
DSP48E2:           579 / 1248   = 46.39%
```

100 MHz 综合后建立时间：

```text
WNS = +1.873 ns
TNS = 0
```

`opt_design` 后：

```text
CLB LUTs:       123893 / 117120 = 105.78%
CLB Registers: 102776 / 234240 = 43.88%
DSP48E2:           579 / 1248   = 46.39%
```

判断：

- 32x16 的计算语义成立：`K_TILE=32`，`COUT_TILE=32`。
- 相比 16x16，它保留了每个 K pass 的 32 输入 lane，性能更接近原始设计。
- 当前 RTL 下 LUT 仍略超 XCK26，约 5.8%。
- 这是一个值得优化的目标点，但还不能直接认为可落地。

### 17.4 18x16 阵列实现结果

进一步选择折中的 `18x16` 配置，并将行缓冲 bank 数同步缩减为 2：

```text
ROWS=18
COLS=16
K_TILE=18
COUT_TILE=32
IFM_BANKS=2
```

功能验证：

```text
tb_conv_accel_core_axi_lite_axis_stream_r18_c16_smoke: 213 pass, 0 fail
```

由于 AXI 顶层作为裸芯片顶层时展开为 `504` 个 I/O，超过 XCK26 `sfvc784` 封装的 `468` 个用户 I/O，物理实现使用 OOC IP 评估流程，并为 OOC 时钟端口指定 `HD.CLK_SRC=BUFGCE_X0Y0`。

route 后物理优化结果：

```text
CLB LUTs:        73075 / 117120 = 62.39%
CLB Registers:   61738 / 234240 = 26.36%
BRAM Tile:        44.5 / 144    = 30.90%
DSP48E2:           355 / 1248   = 28.45%

WNS = +0.262 ns
TNS =  0.000 ns
WHS = +0.011 ns
THS =  0.000 ns
```

路由状态：

```text
fully routed nets:       118309
nets with routing errors:     0
```

判断：

- `18x16` 在 XCK26 上能够完成路由并满足 100 MHz 核心内部时序约束。
- 它比 `16x16` 增加有限的 LUT/DSP 开销，同时比 `32x16` 避免 LUT 超容。
- hold 裕量仅 `+0.011 ns`，完整 Block Design 集成后仍需结合真实 AXI 互连和时钟位置复核系统级时序。

### 17.5 下一步资源优化方向

优先级建议：

1. 将 `com_shift_reg`/valid skew 中的大量 SRL 和分布式 RAM 优化为更轻的 valid 计数或集中式延迟控制。
2. 检查 `systolic_array` 内部双 INT8 DSP 封装是否产生过多旁路 LUT，重点看 `u_array`，32x16 下其 LUT 约 90k。
3. 将 activation LUT、packet FIFO、OFM debug writer 做成可裁剪配置，综合性能评估时先关闭 Leaky LUT 或改成共享 LUT。
4. 尝试 `ROWS=32,COLS=14,K_TILE=32,COUT_TILE=28` 或 `ROWS=32,COLS=12,K_TILE=32,COUT_TILE=24`，寻找不超 LUT 的 K_TILE=32 资源点。
5. 后续再做真正 IP 封装，避免裸顶层 AXI 端口导致 OOC IOB 数超限。

## 18. 2026-05-27 PS/DMA Block Design 脚本

为第一次上板验证新增最小系统集成脚本：

```text
tcl/create_ps_dma_bd_xck26.tcl
```

该脚本以 `conv_accel_core_axi_lite_axis_stream` 的 `ROWS=18, COLS=16,
K_TILE=18, COUT_TILE=32, IFM_BANKS=2` 配置打包为本地自定义 IP，
在 Vivado 2022.2 中建立如下数据通路：

```text
PS M_AXI_HPM0_FPD -> SmartConnect -> accelerator AXI-Lite / 4x DMA AXI-Lite / GPIO

DDR <- PS S_AXI_HP0_FPD <- SmartConnect <- 3x DMA MM2S + 1x DMA S2MM

DMA bias MM2S   -> bias_s_axis
DMA weight MM2S -> weight_s_axis
DMA IFM MM2S    -> ifm_s_axis
ofm_m_axis      -> DMA OFM S2MM
```

DMA 缓冲区不要求与 CPU cache 保持硬件一致性，因此数据通路选用非一致性的
`S_AXI_HP0_FPD`，软件在启动 DMA 前后负责必要的 cache flush/invalidate。

第一版使用 AXI GPIO 的通道 1 写入 `ifm_line_words`，通道 2 读取请求和错误状态：

| GPIO2 bit | 信号 |
|---:|---|
| 0 | `bias_load_req` |
| 1 | `weight_load_req` |
| 2 | `feeder_fill_req` |
| 3 | `ofm_packet_full` |
| 4 | `bias_axis_error` |
| 5 | `weight_axis_error` |
| 6 | `ifm_axis_error` |
| `15:7` | `feeder_fill_fy`，PS 启动 IFM DMA 时选择的 DDR 行号 |

`feeder_fill_req` 与 `feeder_fill_fy` 必须一起提供给软件：PS 检测到
`feeder_fill_req=1` 后读取 `[15:7]`，根据该行号计算 IFM DDR 地址，
然后启动一行长度的 MM2S transaction。仅由软件假定请求顺序会使驱动依赖
当前调度器行为，无法可靠覆盖 padding、stride 或后续流水调度变化。

初版 AXI-Lite 地址分配如下：

| 基地址 | 外设 |
|---:|---|
| `0xA000_0000` | 加速核配置寄存器，4 KB |
| `0xA001_0000` | AXI GPIO，64 KB |
| `0xA002_0000` | bias DMA，64 KB |
| `0xA003_0000` | weight DMA，64 KB |
| `0xA004_0000` | IFM DMA，64 KB |
| `0xA005_0000` | OFM DMA，64 KB |

量化寄存器复位值本身为单位量化，激活配置可选择 bypass，因此首次
PS/DMA smoke test 将 `quant_wr_*` 与 `act_lut_wr_*` 固定为 0。后续若需要
验证真实量化/LUT，应将这些配置端口一并纳入 AXI-Lite 寄存器映射。

脚本默认执行结构验证：

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\create_ps_dma_bd_xck26.tcl
```

增加 `-generate_targets` 参数会一并生成 BD HDL wrapper 与 IP 输出目标。

Vivado 2022.2 中查询到的 KV260 SOM board part 为：

```text
xilinx.com:kv260_som:part0:1.2
xilinx.com:kv260_som:part0:1.3
xilinx.com:kv260_som:part0:1.4
```

`kv260_som` 只描述 SOM 本体和 DDR/FIXED_IO。载板文件
`xilinx.com:kv260_carrier:1.3` 已安装，但它不是独立的 `board_part`；
需要通过 `BOARD_CONNECTIONS` 将其 SOM240 接口连接到所选 SOM。这样
PS board automation 会同时应用载板 preset，包括板载调试串口
`UART1 / MIO 36..37`、SD1、USB0 和 ENET3：

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\create_ps_dma_bd_xck26.tcl `
  -tclargs -board_part xilinx.com:kv260_som:part0:1.4 `
  -board_connection {som240_1_connector xilinx.com:kv260_carrier:som240_1_connector:1.3} `
  -generate_targets
```

## 19. KV260 系统综合与硬件平台导出

在 BD 结构验证通过后，使用以下脚本自动执行完整 Vivado 硬件构建：

```text
tcl/build_kv260_system_xck26.tcl
```

默认流程包括：

```text
创建带 K26 SOM 与 KV260 carrier Board Flow preset 的 BD 工程
-> 生成 HDL wrapper 和 IP 输出目标
-> Run Synthesis
-> Run Implementation / Generate Bitstream
-> 输出系统级 utilization / timing / route status 报告
-> 导出包含 bitstream 的 XSA
```

执行命令：

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\build_kv260_system_xck26.tcl
```

若只需快速复核系统综合资源，可追加 `-tclargs -synth_only`；若已经完成综合并
只需继续实现和导出，可在同一 `-build_dir` 上追加 `-tclargs -reuse_synth`。
完整流程产生的
`.xsa` 才是后续 Vitis 裸机 DMA 验证工程的硬件平台输入。

# 第二阶段：2026-06-08 至 2026-06-18 开发日志

以下内容从原项目状态文档迁入，并按实验目标重新整理为中文。模块名、寄存器名、构建目录、日志字段和测试输出保持原始形式。

## 11. 2026-06-08 PSUM Drain 流水化

- 将 `psum_drain_writer` 从多状态串行结构改为带保持寄存器的流水结构，下游 ready 时可达到每周期一个 PSUM packet。
- 修复 `num_pixels == 2^PSUM_BUF_AW` 时内部计数截断为零的问题，地址仍使用低 `AW` 位，完成计数改用更宽位宽。
- 单元测试、native 1x1、Conv0、Conv7、Conv9 和 Layer06 定向测试全部通过。
- 上板后固定图片延时由约 `0.86136 s` 降至约 `0.64560 s`，`stage_drain_cycles` 从 `30102432` 降至 `8472258`，约改善 `3.55x`。

## 12. 2026-06-08 统一 2022.2 工具链与子阶段计数

- 正式流程固定使用 Vivado/Vitis `2022.2`，Vivado 入口为 `C:/Xilinx/Vivado/2022.2/bin/vivado.bat`。
- 新增 `FEED_FILL_WAIT`、`FEED_PUSH`、`COMP_ACTIVE`、`COMP_FIRE`、`COMP_TAIL` 等只读计数，并由 UART 输出 `SUBPERF`。
- `build_system_xck26_kv260_subperf_2022_2` 实现通过，`WNS=0.302 ns`、`WHS=0.010 ns`、routing error 为 `0`。
- 板级计数确认 feeder 没有被 FIFO/window ready 阻塞，compute 阶段的大头来自 `comp_tail`，而不是有效 MAC 发射。

## 13. 2026-06-08 原始 HWC IFM Cache 原型

- 在 `STREAM_CFG[1]` 增加实验性 `raw_hwc_mode`，默认值保持 `0`。
- 第一版只支持 native `1x1`，DMA 发送原始 uint8 HWC tile，PL 完成 zero-point centering，并按 18 lane replay。
- Conv7 与 Conv9 的 xsim 和上板验证通过，但整网延时仍约 `0.6448 s`，收益很小。
- 结论是仅优化两个 1x1 层不足以改变总延时，主要问题仍是 3x3 后端和 pass 固定开销。

## 14. 2026-06-08 Tail 周期裁剪

- 将 `systolic_ctrl` 的固定 tail 公式改为可配置 `TAIL_CYCLES_CONFIG`，`0` 保持旧公式，非零值用于实验。
- 新增 `TAILSTAT` 计数，区分配置值、实际 tail、drain FIFO empty wait 和 sticky 状态。
- `TAIL_CYCLES=5` 与随后使用的 `TAIL_CYCLES=1` 均完成 RTL 验证，显著减少每个 pass 的固定尾部气泡。

## 15. 2026-06-09 3x3 Raw-HWC 缓存

- 将 raw-HWC cache 扩展到 materialized 3x3 window 数据，保持 DMA、量化和 OFM 格式不变。
- 使用 `HWC_CACHE_STRIPES=4` 和 URAM 存储，解决大规模 cache 的综合资源问题。
- Conv5、Conv6 和 Conv8 的定向仿真通过，为后续后端 raw-HWC 调度提供基础。

## 16. 2026-06-12 扩展至 Conv5 与 Conv8

- 将 3x3 raw-HWC 模式用于 Conv5、Conv6、Conv8，并保留旧 prepacked 路径作为对照。
- 软件 IFM 打包和 DMA 传输明显下降，但 replay 仍在 compute 之前串行执行，因此端到端收益受限。
- 这一阶段确认 cache 本身功能正确，下一问题转向 replay、compute 和 PSUM 阶段的重叠。

## 17. 2026-06-12 Conv4 扩展停止点

- Conv4 raw-HWC 功能可以通过定向测试，但在整网中增加 cache load/replay 成本，延时反而上升。
- Conv4 的空间尺寸和 pass 数较大，单 replay engine 的串行开销抵消了软件打包收益。
- 因此正式后端暂时保留 Conv5/6/8 raw-HWC，Conv4 仅作为诊断开关。

## 18. 2026-06-13 Raw-HWC Replay 诊断

- 新增 `RAWSTAT`，统计 cache load、unpack、replay active、replay ready wait 和 compute wait IFM。
- Conv6 观测到 `load_active=1153984`、`load_unpack=1138176`、`replay_active=5537792`、`replay_wait_ready=0`。
- 数据说明瓶颈不是 IFM FIFO backpressure，而是 scheduler 将 replay 与 compute 串行化。
- `build_system_xck26_kv260_rawstat_2022_2` 上板通过，固定图片总延时约 `544.576 ms`。

## 19. 2026-06-13 Replay 与 Compute 重叠原型

- 在 `TAIL_CONFIG[31:16]` 增加 `raw_hwc_compute_start_level`，达到水位后允许 compute 提前启动。
- 初版 `64` 和 `1024` 水位均在 Conv5 tile0 timeout，原因是 scheduler 丢失早到的单周期 `feeder_done`。
- 增加 `feeder_done_seen` 后死锁消失，`RawHwcComputeStartLevel=64` 上板通过。
- 修复后的总延时约 `542.448 ms`，相对串行基线只改善约 `1.97 ms`，因此该方向不再作为主要优化目标。

## 20. 2026-06-13 PSUM Drain 子计数

- 新增 `DRAINPERF`，区分 FIFO read fire、packet fire、ready stall、内部 full wait 和 empty wait。
- 固定图片总 `STAGE_DRAIN=16073864`，其中 `empty_wait=7601606`，Conv5/6/8 的 ready stall 与 internal full 均为零。
- 结论是 drain 气泡来自 PSUM 尚未产生，而不是 OFM 下游背压。
- 对应实现目录为 `D:/MPSoC/b_drainperf_22`，上板总延时约 `543.006 ms`。

## 21. 2026-06-14 提前 Drain

- 在 `STREAM_CFG[2]` 增加实验性 `early_drain_enable`，默认关闭。
- 当前 pass 开始产生 PSUM 后即可启动 drain，但进入下一 pass 前仍等待 feeder、compute 和 drain 全部完成。
- Conv5/6/8 定向 xsim 和整网板测通过，延时由约 `543 ms` 降至约 `520 ms`。
- 该优化证明 compute 与 drain 可以安全重叠，但尚未消除 K-pass 边界。

## 22. 2026-06-14 K-pass 预取

- 在 `STREAM_CFG[3]` 增加 `pass_prefetch_enable`，当前 pass 执行期间预取下一 K pass 的 weight 和 raw-HWC IFM。
- prefetch 不跨 COUT block，也不提前启动下一 pass compute。
- Conv5/6/8 的 `PREFETCH hit` 接近 100%，miss 和 stall 为零。
- 两张固定图片 DDR demo 约为 `386.64 ms`，相比 early-drain 基线取得明显结构性收益。

## 23. 2026-06-15 Partial-PSUM 数据流重叠

- 在 `STREAM_CFG[4]` 增加 partial-PSUM overlap，使下一 K pass 在上一 pass 的 PSUM 已写入足够 lead 后提前启动。
- 第一版使用保守 lead，并加入 underflow sticky 保护。
- 上板结果约 `374.36 ms`，功能正确但收益低于预期，说明整包 partial-PSUM 边界不是唯一大头。

## 24. 2026-06-15 连续 PSUM 收集器

- 引入连续 output collector 和 pass-context FIFO，使 non-final pass 的 PSUM 直接写入 ping-pong bank，final pass 才进入 OFM 后处理。
- 同时尝试将宽 PSUM 存储映射到 BRAM，减少 LUT memory。
- 功能与整网 golden 均通过，但 DDR demo 仅改善至约 `371.3 ms`。
- 结论是 collector 不是主要关键路径，继续堆叠 drain 优化意义有限。

## 25. 2026-06-15 Pass 时间线诊断

- 新增选定 pass 的时间线，记录 weight done、feed、compute first/last fire、collector 与 pass done。
- 诊断显示 `compute_fire` 约 `74.32 ms`，远小于 compute stage 和 feeder 总时间。
- next-pass weight/feed 已大量命中，剩余气泡集中在 pass 内 replay 节奏和 compute 边界。

## 26. 2026-06-15 列级 PSUM 跟踪

- 对 8 个输出列记录首写、末写、写入数量和 collector 缺列 mask。
- 各列写入数量和相位关系正常，column-empty wait 主要是阵列输出波前的固有现象。
- Column PSUM A/B 对端到端延时几乎没有影响，因此列聚合并非真实主瓶颈。

## 27. 2026-06-16 后端 Full-Tile HWC 缓存

- 将 `HWC_CACHE_DEPTH` 扩到 `43264`、地址宽度扩到 `16`，Conv5/6/8 可使用完整 `13x13` spatial tile。
- URAM 使用量仍在 xck26 预算内，Conv5/6/8 从四个空间 tile 减为一个。
- 上板延时约降至 `335.564 ms`，主要收益来自减少重复支付 tile/pass 固定开销。
- 该优化有效但属于摊薄固定成本，并未消除固定成本本身。

## 28. 2026-06-16 列级 Partial-PSUM 基础

- 实现列级 partial-PSUM streaming 的基础模块，尝试让每列 PSUM 更早进入下一 pass。
- xsim 功能验证通过，但 A/B 板测与 full-tile 基线基本相同。
- 结果说明该路径的等待已被其他阶段覆盖，不应继续把 column collector 当作主优化目标。

## 29. 2026-06-16 列级 PSUM A/B 与瓶颈更新

- ColumnPsum 关闭和开启的结果都约为 `330.8 ms`，确认改动没有进入端到端关键路径。
- `compute_stage - compute_fire` 仍约为 `101 ms`，Conv6 单层约占 `57.8 ms`。
- 后续目标转为 `last_fire -> next_first_fire` 的 K-pass 边界空洞，而不是扩大 COUT 或继续调整 collector。

## 30. 2026-06-16 计算期间下一 Pass 预取

- 在 `STREAM_CFG[7]` 增加 `during_compute_prefetch_enable`，仅提前准备下一 pass，不提前改写 active PE 权重。
- Conv5/6/8 full-tile xsim 均通过，2022.2 实现也完成 timing closure。
- 与后续 fast replay 组合后，Conv4 上板出现 byte mismatch；根因是下一 pass IFM 写入与当前 pass 共用 FIFO，缺少 epoch/bank 隔离。
- 该开关因此标记为不安全，不属于当前默认回归路径。

## 31. 2026-06-16 Raw-HWC Replay 吞吐优化

- 审查发现旧 replay engine 每个 vector 约需两周期，Conv6 的 `feed_push=2768896`，而 `replay_active=5537792`。
- 将 cache 改为 output register 消费时立即发起下一次同步 URAM 读，ready 持续为高时可达到每周期一个 vector。
- 单元测试和 Conv6 full-tile xsim 通过；与不安全 DCPF 组合会产生数据错位，因此正式主线只保留 fast replay 本身。
- 稳定 `b_hwcreplay_22` 板级结果约为 `280.340 ms`，成为当前交付基线。

## 32. 2026-06-17 A53 INT8 CPU 基线

- 新增不使用 PL、DMA 和 AXI-Lite 的 Cortex-A53 单尺度 CPU 对照实现，执行 Conv0 至 Conv9、YOLO decode、阈值和 NMS。
- 将权重布局改为 KCO 并复用 centered IFM 后，纯 C 实现从约 `50.33 s` 降至约 `2.54 s`。
- 手写 NEON 版本约 `2.78 s`，慢于标量 KCO 实现，因此不作为默认路径。
- 所有层 `golden_mismatch=0`，PL 加速器相对优化后的 A53 基线仍有约 `9x` 的端到端优势。

## 33. 2026-06-18 Replay 延时诊断

- 后续 64K URAM 和 IFM ping-pong 实验在 Conv4 full-tile 上出现首批输出 mismatch，而历史 `b_hwcfulltile_22` 可以通过。
- 增加 `HWC_REPLAY_PIPELINE_ENABLE`、`CACHE_EXTRA_READ_LATENCY` 和 `HWC_REPLAY_EXTRA_WAIT_CYCLES` 以区分 replay 协议与 URAM 读延迟。
- xsim 能覆盖快慢 replay，但仍无法稳定复现全部板级错误，说明问题涉及综合后 cache geometry、striping 或 FIFO/pass 控制组合。

## 34. 2026-06-18 板级 Replay 与时序诊断

- 保守 replay、额外等待一周期、关闭 IFM ping-pong 的 100 MHz 构建仍在 Conv4 tile0 失败：

  ```text
  build_dir=D:/b/rlw1
  mismatch_count=16195
  max_abs_diff=46
  total=43264
  ```

- 将同一结构降至 80 MHz 后 timing margin 大幅增加，但 mismatch 完全不变：

  ```text
  build_dir=D:/b/rlw80
  WNS=2.117 ns
  mismatch_count=16195
  max_abs_diff=46
  ```

- 因此错误不是简单的 100 MHz 时序裕量、快 replay 发读频率或 ping-pong FIFO 导致。
- 最终决定回退到已稳定验证的 `b_hwcreplay_22` 主线，将 IFM 双 staging/ping-pong 实验保留在独立分支，不纳入交付版本。

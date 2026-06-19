# Systolic Accelerator 历史开发记录

> 本文档归档项目早期设计说明和阶段性实验日志，仅用于追溯设计演进。当前有效状态以 `project_status_and_roadmap.md` 为准。

## 第一阶段：早期设计与验证记录

> 最后更新：2026-05-25

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
| `0x00` | CTRL/STATUS | write bit0=start pulse, bit1=clear done; read bit0=busy, bit1=done_sticky |
| `0x01` | FM_SIZE | `[8:0]=fm_h`, `[24:16]=fm_w` |
| `0x02` | OFM_SIZE | `[8:0]=ofm_h`, `[24:16]=ofm_w` |
| `0x03` | CONV | `[1:0]=stride`, `[9:8]=pad` |
| `0x04` | K_TOTAL | `[10:0]=k_total` |
| `0x05` | COUT_TOTAL | `[10:0]=cout_total` |
| `0x06` | NUM_PIXELS | `[15:0]=num_pixels` |
| `0x07` | ACT_CFG | `[1:0]=activation_mode`, 0=bypass, 1=ReLU, 2=Leaky LUT |
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

### 14.1 IFM line fill stream

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

### 15.4 IFM line stream 打包

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

### 15.5 OFM stream 打包

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

### 16.1 IFM AXI-Stream line loader

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

### 16.2 Bias/weight AXI-Stream loader

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

### 16.3 OFM debug AXI-Stream writer

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
- AXI-Stream bias input。
- AXI-Stream weight input。
- AXI-Stream IFM line input。
- AXI-Stream OFM debug output。

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

100 MHz post-synth setup timing：

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

100 MHz post-synth setup timing：

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

100 MHz post-synth setup timing：

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

以下内容从原项目状态文档迁入，保留当时的实验结论、性能数据和失败路径。

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

- A first board attempt enabled `-DuringComputePrefetch` together with fast
  replay. The batch-chain failed at the first raw-HWC backend layer
  (`conv4_pool`) with byte mismatches. This was reproduced in xsim with the full
  experimental switch set. Bisecting the switches showed:

  ```text
  Conv4 raw-HWC tile0, fast replay, tail=1 only:
    854 pass, 0 fail

  Conv4 raw-HWC tile0, fast replay, EarlyDrain + PassPrefetch +
  PsumStreamOverlap + ContinuousPsum + ColumnPsum, without DuringComputePrefetch:
    854 pass, 0 fail

  Conv4 raw-HWC tile0, same switches plus DuringComputePrefetch:
    first mismatch at pixel39, 101 fail
  ```

  Therefore `DuringComputePrefetch` is not part of the safe replay-throughput
  board configuration. The likely issue is the earlier staging of next-pass IFM
  vectors into the same FIFO once replay can run at one vector per cycle. It
  should be debugged separately before being re-enabled.

- Expected board effect: this should reduce the backend raw-HWC replay cost for
  Conv5/6/8 and Conv4. Conv6 alone has roughly `2.77M` excess replay-active
  cycles versus one-cycle replay, so the first board target is a meaningful
  drop in `RAWSTAT replay_active`, `SUBPERF feed_fill`, and Conv6
  `compute_idle`. The recommended board switch set for this comparison is
  `RawHwcConv4/5/6/8 + EarlyDrain + PassPrefetch + PsumStreamOverlap +
  ContinuousPsum + ColumnPsum + BackendFullTile + TailCyclesOverride=1`, with
  `DuringComputePrefetch` disabled. If timing still closes, this is the next
  bitstream to compare against the current `Conv4/5/6/8` raw-HWC `282.951 ms`
  run.

## 27. 2026-06-17 optimized single-core A53 INT8 CPU baseline

- A CPU-only single-scale YOLOv3-tiny baseline was added for Cortex-A53 board
  comparison. It runs Conv0 through Conv9, software YOLO decode, thresholding,
  class-aware NMS, and DET printing without using the PL accelerator, AXI DMA,
  AXI-Lite registers, `STREAM_CFG`, or hardware tile scheduling.
- The baseline is built as an independent Vitis bare-metal ELF:

  ```powershell
  powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_cpu_yolo_baseline.ps1
  ```

  The output ELF is:

  ```text
  build_vitis_2022_2/conv_accel_r18_c16_smoke/manual_build/cpu_yolo_baseline.elf
  ```

- The implementation uses the same RTL-semantic chain golden data and
  `yolo_decode.c`. The generated CPU data header stores weights in KCO layout
  (`[ci][ky][kx][out_channel]`), so each output pixel reuses one centered IFM
  value while accumulating all output channels. This replaced the first
  correctness-oriented OIHW loop that recomputed each output channel
  independently.
- Board validation on `COM8`:

  ```text
  original simple C baseline:  CPU_TOTAL ~= 50.33 s
  cache + -O3 only:            CPU_TOTAL ~= 49.97 s
  KCO scalar optimized C:      CPU_TOTAL ~=  2.52 s
  current default A53 build:   CPU_TOTAL ~=  2.54 s
  optional NEON attempt:       CPU_TOTAL ~=  2.78 s
  ```

  The hand-written NEON row-accumulate path is kept behind the optional
  `-UseNeon` build switch but is not the default because it was slower on A53
  than the optimized scalar KCO loop.
- Current default board result:

  ```text
  log=build_vitis_2022_2/cpu_yolo_board_logs/20260617_114841_cpu_yolo_kco_scalar_a53_COM8.log
  CPU_TOTAL us=2540175
  layer_us=2506628
  decode_us=19530
  all CPU_LAYER golden_mismatch=0
  DET with_mask score=0.357321
  compare_yolo_uart.py PASS, count=1
  ```

- The largest remaining CPU layer is still Conv6:

  ```text
  head_conv6_3x3 us=887010
  ```

  This optimized single-core A53 INT8 baseline is now the recommended software
  baseline for PL speedup comparisons. Further CPU optimization should target a
  proper blocked microkernel or multi-core A53 execution rather than the tested
  simple NEON accumulator.

## 28. 2026-06-18 raw-HWC replay latency diagnosis

- Conv4 full-tile board failure has been narrowed away from ping-pong IFM FIFO,
  tail cycles, and software input packaging:

  ```text
  New 64K URAM bit with IFM_PINGPONG_FIFO_ENABLE=0:
    Conv4 still fails at the first output bytes.

  Same ELF on historical b_hwcfulltile_22 URAM bit:
    Conv4 full compare passes.
  ```

  This means raw-HWC URAM itself is not the problem. The likely hardware-side
  suspect is the fast raw-HWC replay path added after the historical passing
  bitstream, or its interaction with the current cache geometry/synthesis.

- `axis_hwc_tile_cache` now has diagnostic replay parameters:

  ```text
  HWC_REPLAY_PIPELINE_ENABLE
    1: current fast replay, can issue/read every cycle.
    0: legacy conservative replay, waits for read data before vector_valid.

  CACHE_EXTRA_READ_LATENCY
    Simulation/diagnostic data-path delay injection for the cache bank output.

  HWC_REPLAY_EXTRA_WAIT_CYCLES
    Wait-only replay valid delay for legacy mode. This is the safer hardware
    knob if an implemented URAM path presents data later than the RTL wrapper
    assumed, because it does not insert an extra data-path register.
  ```

  The parameters are connected through `conv_accel_core_axi_lite_axis_stream`
  and the xsim/Vivado build scripts.

- RTL xsim results:

  ```text
  tb_axis_hwc_tile_cache, fast replay, latency0:
    261 pass, 0 fail

  tb_axis_hwc_tile_cache, fast replay, CACHE_EXTRA_READ_LATENCY=1:
    expected failure, first replay vector reads stale/zero data
    227 pass, 34 fail

  tb_axis_hwc_tile_cache, legacy replay, CACHE_EXTRA_READ_LATENCY=1:
    261 pass, 0 fail

  tb_axis_hwc_tile_cache, legacy replay, HWC_REPLAY_EXTRA_WAIT_CYCLES=1:
    261 pass, 0 fail
  ```

- Conv4 exact RTL xsim results, using full-tile COUT256, COLS=8, URAM=1, and
  IFM ping-pong disabled:

  ```text
  fast replay, latency0:
    43286 pass, 0 fail

  fast replay, CACHE_EXTRA_READ_LATENCY=1:
    expected failure
    first compare failures start at tile0 pixel0 cout0
    25243 pass, 18043 fail

  legacy replay, CACHE_EXTRA_READ_LATENCY=1:
    43286 pass, 0 fail
  ```

- Interpretation: ordinary RTL simulation still passes because the cache model
  is a one-cycle synchronous memory. Once one extra read-data cycle is injected,
  the fast replay path immediately misaligns vector data and metadata; the
  legacy replay path covers it. The next board diagnostic should therefore
  synthesize a conservative replay bitstream, preferably first with
  `HWC_REPLAY_PIPELINE_ENABLE=0` and, if needed, a second wait-only variant with
  `HWC_REPLAY_EXTRA_WAIT_CYCLES=1`.

## 29. 2026-06-18 board replay/timing diagnostic follow-up

- Built and tested the conservative replay diagnostic bitstream:

  ```text
  build_dir: D:/b/rlw1
  HWC_CACHE_DEPTH=65536
  HWC_CACHE_STRIPES=4
  HWC_CACHE_USE_URAM=1
  HWC_REPLAY_PIPELINE_ENABLE=0
  HWC_REPLAY_EXTRA_WAIT_CYCLES=1
  IFM_PINGPONG_FIFO_ENABLE=0
  PL clock: 100 MHz
  ```

  Implementation completed and met timing:

  ```text
  WNS=0.033 ns
  WHS=0.010 ns
  route errors=0
  URAM=32/64
  BRAM tile=63/144
  DSP=184
  ```

  Board result on COM8 still failed at Conv4 tile0:

  ```text
  log=D:/b/rlw1/board_smoke_logs/20260618_041228_conv0_conv9_batch_chain_COM8.log
  conv4_pool batch tile[0] oy=0 h=26 b=16 w=1024 i=1
  conv4_pool mismatch[0] byte=1 pixel=0 oy=0 ox=0 oc=1 got=15 exp=17
  conv4_pool mismatch_count=16195 max_abs_diff=46 total=43264
  ```

- To separate logic from marginal 100 MHz timing, built the same conservative
  replay design at 80 MHz:

  ```text
  build_dir: D:/b/rlw80
  PL clock: 80 MHz
  HWC_REPLAY_PIPELINE_ENABLE=0
  HWC_REPLAY_EXTRA_WAIT_CYCLES=1
  IFM_PINGPONG_FIFO_ENABLE=0
  ```

  Implementation margin improved substantially:

  ```text
  WNS=2.117 ns
  WHS=0.011 ns
  route errors=0
  ```

  Board result remained the same:

  ```text
  log=D:/b/rlw80/board_smoke_logs/20260618_045815_conv0_conv9_batch_chain_COM8.log
  conv4_pool batch tile[0] oy=0 h=26 b=16 w=1024 i=1
  conv4_pool mismatch[0] byte=1 pixel=0 oy=0 ox=0 oc=1 got=15 exp=17
  conv4_pool mismatch_count=16195 max_abs_diff=46 total=43264
  ```

- Conclusion: the board failure is not explained by fast replay issuing one
  read per cycle, not fixed by adding a replay wait cycle, not caused by
  ping-pong IFM FIFO, and not likely to be a simple 100 MHz timing-margin issue.
  The next highest-value debug path is to diff the current raw-HWC/vector IFM
  RTL against the historical passing `b_hwcfulltile_22` design, with emphasis on
  cache addressing/striping, vector IFM FIFO semantics, and Conv4 full-tile
  COUT256 pass control. Add board-visible Conv4 tile0 signatures before compare
  exits, because the current failure exits before RAWSTAT/PASSPERF for Conv4 is
  printed.

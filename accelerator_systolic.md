# Systolic Accelerator 设计与验证文档

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

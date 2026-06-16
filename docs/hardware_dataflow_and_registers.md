# Systolic Accelerator 硬件数据流与寄存器说明

> 本文档根据 `systolic/` 当前 RTL 编写，重点说明面向 BD/Vitis 的
> `conv_accel_core_axi_lite_axis_stream` 顶层数据流、主要实现方式和
> AXI-Lite 寄存器配置语义。

## 1. 顶层定位

当前系统级 RTL 顶层是：

```text
conv_accel_core_axi_lite_axis_stream
  -> conv_accel_core_axi_lite
    -> axi_lite_cfg_bridge
    -> conv_accel_core
      -> layer_config_regs
      -> quant_param_regs
      -> conv_layer_top_stream
```

`conv_accel_core_axi_lite_axis_stream` 提供一个 AXI-Lite 控制口和四类
64-bit AXI-Stream 数据口：

```text
bias   AXIS in   DDR/PS -> accelerator
weight AXIS in   DDR/PS -> accelerator
IFM    AXIS in   DDR/PS -> accelerator
OFM    AXIS out  accelerator -> DDR/PS
```

AXI-Lite 只负责配置、状态和性能计数。卷积运行时需要的软件侧或 DMA
按硬件请求提供 bias、weight 和 IFM stream，并接收 OFM debug stream。

当前常用 KV260 配置为：

```text
ROWS=18
COLS=8
COUT_TILE=COLS*2=16
IFM_BANKS=2
AXIS_W=64
```

代码仍保持参数化，早期默认参数中可见 `ROWS=32/COLS=32/IFM_BANKS=5`，
但实际板级构建由 Vivado/Tcl 参数覆盖。

## 2. 核心数值语义

硬件按整数卷积语义工作：

```text
external IFM: uint8 activation
internal IFM: signed int8
weight:       signed int8
psum:         int32
bias:         int32
OFM:          8-bit byte stream
```

IFM 进入硬件后先做输入零点中心化：

```text
ifm_s8 = saturate_s8(ifm_u8 - input_zero_point)
```

padding 越界位置使用内部 signed zero，也就是数值 `0`，不是外部
`input_zero_point` 字节。3x3 line path、native 1x1 vector path 和 raw-HWC
cache path 都遵守这个语义。

最终 PSUM 进入 requant 时使用每个输出 lane 的量化参数：

```text
q = round(psum * mult / 2^(raw_shift + 15)) + output_zp
q_sat = saturate_s8(q)
```

这里 `mult` 是软件按 15 个小数位导出的定点乘数，所以 RTL 内部实际右移
`raw_shift + 15`。随后可选 activation 和 pooling，再写回 HWC 地址空间。

## 3. 一次 tile 的总体数据流

主数据流在 `conv_layer_top_stream` 内完成：

```text
AXIS/control
  -> bias/weight/IFM loaders
  -> layer scheduler
  -> weight tile loader
  -> IFM feeder
  -> systolic_top
  -> psum_drain_writer
  -> psum ping-pong buffer or final packet FIFO
  -> requant
  -> activation
  -> optional pooling
  -> HWC byte writeback
  -> OFM byte FIFO
  -> AXIS OFM debug packets
```

调度顺序由 `layer_scheduler_stream` 控制：

```text
for cout_base in COUT_TILE:
  load one bias block
  for pass_base_k in K_TILE:
    load one weight tile
    fill/replay IFM tile
    run systolic compute
    drain PSUM
```

当前板级构建中 `K_TILE` 与 `ROWS` 对齐，每个 K pass 一次向阵列输入
`ROWS` 个 K-lane。
`COUT_TILE=COLS*2`，每列 PE 同时处理两个输出通道。因此一个调度块覆盖：

```text
num_pixels spatial pixels
ROWS K lanes
COLS*2 output channels
```

若不是最后一个 K pass，`psum_drain_writer` 把 partial PSUM 写入
`psum_pingpong_buffer`；下一 pass 通过 `psum_stream_feeder` 读回并重新送入
systolic array 顶部。最后一个 K pass 的 drain packet 进入 requant/activation
输出链路。

## 4. Bias 与 Weight 输入路径

### 4.1 Bias AXIS 格式

`axis_bias_weight_loader` 接收 bias stream。每个 64-bit beat 包含两个
little-endian int32 bias：

```text
TDATA[31:0]  = bias[even]
TDATA[63:32] = bias[odd]
```

每个 COUT block 需要 `COUT_TILE` 个 bias。硬件将其写入内部 bias buffer，
地址为 lane index。

### 4.2 Weight AXIS 格式

weight stream 每个 64-bit beat 包含 8 个 int8 weight：

```text
TDATA[n*8 +: 8] = weight byte n, n=0..7
```

外部存储顺序为：

```text
tile_mem[row * COUT_TILE + cout_lane]
  = W[k_base + row][cout_base + cout_lane]
```

`axis_bias_weight_loader` 直接使用 64-bit beat 写 `weight_tile_loader` 的
8 个 byte bank。`weight_tile_loader` 再按阵列列格式吐给每个 row 的
weight FIFO：

```text
cycle c:
  row r -> { W[r][2*c+1], W[r][2*c] }
```

因此 `COLS` 个周期完成一个 weight tile 装载。

### 4.3 TLAST/TKEEP 检查

bias 和 weight loader 都检查 `TKEEP` 与 `TLAST`：

- 非末 beat 要求有效 byte 全开；
- 末 beat 按剩余有效 byte 计算期望 `TKEEP`；
- batch 模式下只有最后一个 packet 的最后 beat 应有 `TLAST`；
- sticky error 汇总到顶层 `bias_axis_error`、`weight_axis_error`。

## 5. IFM 输入路径

IFM 有三种路径，由 `CONV.bit16` 和 `STREAM_CFG.bit1` 选择。

### 5.1 3x3 line/window 路径

默认 3x3 路径如下：

```text
IFM AXIS
  -> axis_ifm_line_loader
  -> ifm_line_stream_loader
  -> line_buffer_5bank
  -> window_extract
  -> IFM FIFOs
  -> systolic array
```

IFM line stream 每个 beat 携带同一个 x 位置下的多个 bank：

```text
TDATA[ 7: 0] = bank0
TDATA[15: 8] = bank1
TDATA[23:16] = bank2
TDATA[31:24] = bank3
TDATA[39:32] = bank4
TDATA[63:40] = don't care
```

实际工程若 `IFM_BANKS=2`，只检查低 2 个 byte。`TKEEP[BANKS-1:0]`
必须为 1。

`window_feeder` 内部包含：

```text
line_stream_ctrl
  -> 请求当前 output row 所需的 physical input rows
window_stream_ctrl
  -> 遍历 oy/ox，等待 window_ready 和 IFM FIFO 空间
window_extract
  -> 根据 pass_base_k 展开 ROWS 个 K-lane
```

`window_extract` 对每个 lane 计算：

```text
global_k = pass_base_k + lane
channel  = global_k / 9
kernel   = global_k % 9
ky       = kernel / 3
kx       = kernel % 3
bank     = channel % IFM_BANKS
```

再根据 `oy/ox/stride/pad` 从 3-line buffer 读出对应字节。越界或未命中的
位置输出内部 signed zero。

### 5.2 Native 1x1 vector 路径

`CONV.bit16=1` 选择 native 1x1 path。该模式要求：

```text
STREAM_CFG.bit0 = 1
stride = 1
pad = 0
num_pixels <= IFM_FIFO_DEPTH
```

若配置不满足，`CTRL.STATUS.config_error` 置位且不会启动。

`axis_ifm_vector_loader` 将每个 pixel 的 18 个 lane 用 3 个 64-bit beat
传入：

```text
beat0: lanes 0..7
beat1: lanes 8..15
beat2: lanes 16..17, upper bytes ignored
```

loader 在内部对每个 byte 做 `input_zero_point` 中心化，再把 18-lane vector
写入 IFM FIFO。该路径主要服务 Conv7/Conv9 这类原生 1x1 层，避免用稀疏
3x3 权重模拟 1x1 时的无效 K pass。

### 5.3 Raw-HWC tile cache 路径

`STREAM_CFG.bit1=1` 选择实验性的 raw-HWC IFM cache。此时 IFM DMA 发送
raw `uint8` HWC tile，PL 侧缓存并按 pass replay 成 18-lane vector。

1x1 raw-HWC cache 布局：

```text
group = (channel % 18) / 9
byte  = channel % 9
addr  = (channel / 18) * tile_pixels + pixel
```

3x3 raw-HWC cache 布局：

```text
group = channel % 2
byte  = kernel_pos
addr  = (channel / 2) * tile_pixels + output_pixel
```

3x3 模式会把输入 HWC row scatter 到对应 output pixel 的 9 个 kernel
位置。padding 和越界位置在 replay 时输出 signed zero。当前实现使用两个
72-bit logical bank，可通过 `HWC_CACHE_STRIPES` 和 `HWC_CACHE_USE_URAM`
控制 stripe/URAM 推断。

raw-HWC 是 opt-in 路径，默认 `STREAM_CFG.bit1=0` 时不影响已验证的
prepacked IFM stream。

## 6. Systolic Array 与 PSUM 路径

`systolic_top` 包含：

```text
IFM FIFO per row
weight FIFO per row
32x32-style parameterized systolic_array
PSUM FIFO per output column pair
systolic_ctrl
```

`systolic_ctrl` 的状态为：

```text
IDLE -> WEIGHT_LOAD -> COMPUTE -> DRAIN -> IDLE
```

`WEIGHT_LOAD` 持续 `COLS` 个周期，把每列的双输出通道 weight 装入 PE。
`COMPUTE` 阶段每当 IFM FIFO lane0 非空就发出 `compute_fire`，共运行
`num_pixels` 次。IFM read enable 按 row 方向 stagger，匹配阵列内部
valid 传播。`DRAIN` 阶段等待 systolic tail，默认公式为：

```text
ROWS*5 + COLS*4 + 16
```

如果 `TAIL_CONFIG` 非零，则运行时配置覆盖默认 tail cycles；如果综合参数
`TAIL_CYCLES_CONFIG` 非零，则作为默认值。该机制用于 tailtrim 实验。
同一寄存器的高 16 位用于 raw-HWC replay/compute overlap 水位；非零时允许
raw/vector feeder 预填到该 pixel-vector 数量后启动 compute。

PSUM 输入分三种：

- 第一个 K pass：使用 bias buffer 作为顶端 PSUM；
- 中间 pass：从 `psum_pingpong_buffer` 读 partial PSUM；
- legacy/测试路径仍保留外部 PSUM 接口，但当前主链路使用 stream feedback。

`psum_drain_writer` 从 array 底部 PSUM FIFO 读出每个 pixel 的
`COLS*2` 个 int32 PSUM。非 final pass 写回 ping-pong buffer，final pass
进入 OFM 后处理。

## 7. OFM 后处理与写回

final PSUM 后处理顺序为：

```text
psum_packet_fifo
  -> ofm_requant_writer
  -> ofm_packet_fifo
  -> ofm_activation
  -> ofm_pooling
  -> ofm_packet_fifo
  -> ofm_writeback
  -> ofm_byte_stream_fifo
  -> axis_ofm_byte_writer
```

`ofm_requant_writer` 对每个 packet 的 `COLS*2` lane 并行实例化 requant。
每个 lane 使用 `quant_param_regs` 中对应的 `mult/shift/zp`。

activation 模式：

```text
0 = bypass
1 = signed int8 ReLU, negative clamp to 0
2 = LUT, 256-entry byte lookup
```

pooling 当前支持：

```text
pool_enable=0: bypass
pool_enable=1, pool_stride=2: uint8 2x2 maxpool stride-2
```

pooling 位于 activation 之后。pool 打开时，输入 packet 地址仍是 pool 前
conv output pixel index，pool 输出地址变为 pooled pixel index。

`ofm_writeback` 使用 HWC 地址：

```text
wr_addr = (tile_pixel_base + packet_pixel) * cout_total
          + (packet_cout_base + lane)
```

当前系统顶层随后把每个 OFM byte 包成 debug AXIS packet：

```text
TDATA[OFM_ADDR_W-1:0]  = byte address
TDATA[OFM_ADDR_W +: 8] = byte data
TKEEP                  = all ones
TLAST                  = expected byte count reached
```

这一路格式便于软件按地址重排和 bit-exact 验证。长期若追求带宽效率，可用
连续 HWC burst packer 替换。

## 8. AXI-Lite 地址映射规则

`axi_lite_cfg_bridge` 使用 byte address `[7:2]` 作为内部 word address。
因此 RTL 注释中的 word offset `0x20` 对应 AXI-Lite byte offset `0x80`。

所有寄存器均为 32-bit。除特别说明外，配置寄存器只在 accelerator idle
时接受写入；运行中写入会被忽略。`CTRL` 写 start 时若 idle 且配置合法，
会清零性能计数并启动一次 tile/layer 调度。

## 9. 控制与层参数寄存器

| Byte offset | Name | R/W | Bit field | 作用 |
|---:|---|---|---|---|
| `0x00` | `CTRL/STATUS` | R/W | W bit0=start, W bit1=clear; R bit0=busy, bit1=done_sticky, bit2=config_error | 启动、清状态、读 busy/done/error |
| `0x04` | `FM_SIZE` | R/W | `[8:0]=fm_h`, `[24:16]=fm_w` | 输入 feature map 尺寸 |
| `0x08` | `OFM_SIZE` | R/W | `[8:0]=ofm_h`, `[24:16]=ofm_w` | pool 前 conv output 尺寸 |
| `0x0c` | `CONV` | R/W | `[1:0]=stride`, `[9:8]=pad`, `bit16=kernel_1x1` | 卷积 stride/pad 与 native 1x1 选择 |
| `0x10` | `K_TOTAL` | R/W | `[13:0]=k_total` | K 维总长度；3x3 为 `Cin*9`，1x1 为 `Cin` |
| `0x14` | `COUT_TOTAL` | R/W | `[10:0]=cout_total` | 本层总输出通道 |
| `0x18` | `NUM_PIXELS` | R/W | `[15:0]=num_pixels` | 当前 spatial tile 的 conv output pixel 数 |
| `0x1c` | `ACT_CFG` | R/W | `[1:0]=activation_mode` | 0 bypass，1 ReLU，2 LUT |
| `0x20` | `TILE_ROWS` | R/W | `[8:0]=tile_oy_base`, `[24:16]=tile_ofm_h` | 当前 tile 起始输出行与高度；`tile_ofm_h=0` 表示 full `ofm_h` |
| `0x24` | `PIXEL_BASE` | R/W | `[23:0]=tile_pixel_base` | 当前 tile 在最终 OFM HWC 空间中的 pixel base |
| `0x3c` | `IFM_ZP` | R/W | `[7:0]=input_zero_point` | IFM uint8 到 signed int8 的零点 |
| `0x40` | `POOL_CFG` | R/W | `bit0=pool_enable`, `[3:2]=pool_stride` | 当前支持 bypass 或 2x2 stride-2 maxpool |
| `0x44` | `EXPECTED_BYTES` | R/W | `[31:0]` | 当前 tile 期望 OFM byte 数，用于 TLAST/debug |
| `0xe0` | `TAIL_CONFIG` | R/W | `[15:0]=tail_cycles`, `[31:16]=raw_hwc_compute_start_level` | 运行时 tail cycle override 与 raw-HWC replay/compute overlap 水位；低 16 位为 0 时使用默认 tail 值，高 16 位为 0 时关闭 overlap |

native 1x1 配置检查：

```text
kernel_1x1=1 时必须满足：
  stream_batch_mode=1
  stride=1
  pad=0
  num_pixels <= IFM_FIFO_DEPTH
```

不满足时 `config_error=1`，start 不会进入主调度。

## 10. Quant/LUT 寄存器

这些寄存器由 `conv_accel_core` 额外实现。byte offset 为：

| Byte offset | Name | R/W | Bit field | 作用 |
|---:|---|---|---|---|
| `0x80` | `QUANT_ADDR` | R/W | `[5:0]=lane_addr` | 选择要访问的 output lane |
| `0x84` | `QUANT_DATA` | R/W | `[15:0]=mult`, `[19:16]=raw_shift`, `[31:24]=output_zp` | 写/读当前 lane 的 requant 参数 |
| `0x88` | `LUT_ADDR` | R/W | `[7:0]=lut_addr` | 选择 activation LUT 地址 |
| `0x8c` | `LUT_DATA` | R/W | `[7:0]=lut_byte` | 写/读当前 LUT byte |

`QUANT_DATA` 只配置当前 COUT tile 的 lane 参数。软件切换 `cout_base`
对应的 layer/tile 前，应按当前 output channel block 写入对应 lane 的
量化参数。LUT 是 256-entry byte table，mode 2 时每个 lane 以当前 requant
输出 byte 为地址查表。

复位后的 shadow 行为：

- quant 参数初始化为占位值 `mult=1, raw_shift=0, output_zp=0`，真实层运行前
  软件应显式写入每个 lane 的参数；
- LUT shadow 初始化为 identity `lut[i]=i`；
- 系统 wrapper 中 legacy direct quant/LUT port 被绑为 0，BD/Vitis 应通过
  AXI-Lite 间接寄存器编程。

## 11. Stream 配置与计数寄存器

| Byte offset | Name | R/W | Bit field | 作用 |
|---:|---|---|---|---|
| `0x64` | `STREAM_CFG` | R/W | `bit0=batch_mode`, `bit1=raw_hwc_mode`, `bit2=early_drain_enable`, `bit3=pass_prefetch_enable`, `bit4=psum_stream_overlap_enable`, `bit5=continuous_psum_enable` | Select batch stream, raw-HWC cache, early drain, next-K prefetch, experimental partial-PSUM overlap, and experimental continuous PSUM collector |
| `0x68` | `BIAS_PACKETS` | R/W | `[31:0]` | 当前 tile 期望 bias packet 数 |
| `0x6c` | `WEIGHT_PACKETS` | R/W | `[31:0]` | 当前 tile 期望 weight packet 数 |
| `0x70` | `IFM_PACKETS` | R/W | `[31:0]` | 当前 tile 期望 IFM packet 数 |
| `0x74` | `BIAS_DONE` | R | `[31:0]` | 已完成 bias packet 数 |
| `0x78` | `WEIGHT_DONE` | R | `[31:0]` | 已完成 weight packet 数 |
| `0x7c` | `IFM_DONE` | R | `[31:0]` | 已完成 IFM packet 数 |
| `0x90` | `VECTOR_PACKETS` | R | `[31:0]` | native/raw vector packet 数 |
| `0x94` | `VECTOR_PIXELS` | R | `[31:0]` | native/raw replay 到核心的 pixel vector 数 |
| `0x98` | `VECTOR_BEATS` | R | `[31:0]` | native/raw IFM AXIS 接收 beat 数 |
| `0x9c` | `VECTOR_STALLS` | R | `[31:0]` | vector valid 但 IFM FIFO 无法接收的周期 |

`STREAM_CFG` 在 start 时作为 `stream_reset` 源头之一，用来清 completed
packet 计数，并在 raw-HWC 模式下触发 cache load 状态初始化。
`TAIL_CONFIG[31:16]` 是实验性的 raw-HWC replay/compute overlap 水位。
当该字段非零时，scheduler 可在 raw/vector feeder 已经向 IFM FIFO push
至少该数量的 pixel vector 后启动 compute；PSUM drain 仍会等待 compute 完成
且 feeder done 事件已经发生。当前软件默认使用 `0` 关闭 overlap；非零水位
仍是实验路径，`64` 和 `1024` 已在 Conv5 tile0 上板测试中暴露 timeout。

`IFM_DONE` 在系统顶层根据当前模式复用：

```text
raw_hwc_mode ? raw_hwc_completed_packets :
kernel_1x1  ? vector_completed_packets :
               line_completed_packets
```

## 12. Debug 与性能计数寄存器

### 12.1 OFM debug 计数

| Byte offset | Name | R/W | 作用 |
|---:|---|---|---|
| `0x28` | `DBG_EXPECTED` | R | 当前期望 OFM byte 数 |
| `0x2c` | `DBG_CORE_WR` | R | core writeback 被 OFM byte FIFO 接收的 byte 数 |
| `0x30` | `DBG_AXIS_WR` | R | OFM AXIS 下游握手 byte packet 数 |
| `0x34` | `DBG_TLASTS` | R | OFM AXIS TLAST 握手次数 |
| `0x38` | `DBG_LAST_END` | R | 最近一次 TLAST 时累计 AXIS packet count |

注意：`DBG_LAST_END` 与 `TAIL_CONFIG` 在不同视图下有地址别名问题。
内部 word offset `0x0e` 对应 byte `0x38` 是 `DBG_LAST_END`；
内部 word offset `0x38` 对应 byte `0xe0` 才是 `TAIL_CONFIG`。

### 12.2 顶层性能计数

| Byte offset | Name | R/W | 作用 |
|---:|---|---|---|
| `0x48` | `PERF_BUSY` | R | 当前 tile/layer busy 周期 |
| `0x4c` | `PERF_WAIT_ANY` | R | busy 中任意外部服务等待周期 |
| `0x50` | `PERF_WAIT_BIAS` | R | bias request 等待周期 |
| `0x54` | `PERF_WAIT_WEIGHT` | R | weight request 等待周期 |
| `0x58` | `PERF_WAIT_IFM` | R | IFM feeder fill request 等待周期 |
| `0x5c` | `PERF_WAIT_OFM` | R | OFM backpressure 等待周期 |
| `0x60` | `PERF_COMPUTE` | R | systolic array 接收一个 output pixel 的周期数 |

这些计数在合法 start 时清零，运行期间按周期累加。

### 12.3 Stage/Sub-stage 计数

| Byte offset | Name | R/W | 作用 |
|---:|---|---|---|
| `0xa0` | `STAGE_BIAS` | R | scheduler bias phase 周期 |
| `0xa4` | `STAGE_WEIGHT` | R | scheduler weight phase 周期 |
| `0xa8` | `STAGE_FEEDER` | R | scheduler IFM feeder phase 周期 |
| `0xac` | `STAGE_COMPUTE` | R | scheduler compute phase 周期 |
| `0xb0` | `STAGE_DRAIN` | R | scheduler PSUM drain phase 周期 |
| `0xb4` | `STAGE_OFM_POST` | R | scheduler done 后 OFM 后处理排空周期 |
| `0xb8` | `FEED_FILL_WAIT` | R | feeder 等待外部填充/向量 replay 周期 |
| `0xbc` | `FEED_PUSH` | R | feeder 成功向 IFM FIFO push 周期 |
| `0xc0` | `FEED_FIFO_STALL` | R | feeder 因 IFM FIFO full 停顿周期 |
| `0xc4` | `FEED_WIN_NOT_READY` | R | 3x3 feeder 等待 window ready 周期 |
| `0xc8` | `COMP_WLOAD` | R | systolic core weight-load 周期 |
| `0xcc` | `COMP_ACTIVE` | R | systolic core compute active 周期 |
| `0xd0` | `COMP_FIRE` | R | 与 `PERF_COMPUTE` 相同，接受 output pixel 周期 |
| `0xd4` | `COMP_IFM_STALL` | R | compute active 但 IFM FIFO 空的周期 |
| `0xd8` | `COMP_TAIL` | R | systolic tail/drain wait 周期 |
| `0xdc` | `SUBPERF_VERSION` | R | 当前固定为 2 |
| `0xe4` | `TAIL_ELAPSED` | R | `COMP_TAIL` alias |
| `0xe8` | `DRAIN_EMPTY_WAIT` | R | PSUM drain 等待 FIFO data 周期 |
| `0xec` | `DRAIN_EMPTY_STICKY` | R | 是否出现过 PSUM drain FIFO empty wait |

这些寄存器用于定位瓶颈。当前代码中 feeder stall/window-not-ready、compute
tail、drain empty 等计数已经接到硬件路径，Vitis runtime 可打印
`STAGEPERF`、`SUBPERF` 和 `TAILSTAT` 行。

## 13. 推荐的软件配置顺序

每个 tile/layer 建议按以下顺序配置：

1. 确认 `CTRL.STATUS.busy=0`。若上一轮失败且 busy 未清，重新复位或重烧 PL。
2. 写 `FM_SIZE`、`OFM_SIZE`、`CONV`、`K_TOTAL`、`COUT_TOTAL`、`NUM_PIXELS`。
3. 写 `TILE_ROWS`、`PIXEL_BASE`、`IFM_ZP`、`ACT_CFG`、`POOL_CFG`。
4. 写 `EXPECTED_BYTES`。
5. 对当前 COUT block 写 `QUANT_ADDR/QUANT_DATA`；若 activation mode 2，写 LUT。
6. 若使用 batch stream，写 `STREAM_CFG` 和 `BIAS/WEIGHT/IFM_PACKETS`。
7. 若使用 tailtrim，写 `TAIL_CONFIG`。
8. 启动 OFM S2MM DMA，再准备 bias/weight/IFM MM2S DMA。
9. 写 `CTRL.bit0=1` 启动。
10. 软件根据 request 或 batch stream 协议服务 bias/weight/IFM，等待 done/TLAST。
11. 读取 debug/perf 计数，比较 `DBG_AXIS_WR`、`DBG_TLASTS`、`*_DONE` 与期望值。

对于 raw-HWC cache，软件必须先按当前 layer/tile 的 HWC cache 协议发送完整
raw tile；硬件在 `stream_reset` 后重新进入 load 状态，之后每个 K pass 通过
`fill_req` replay vector。

## 14. 2026-06-13 DRAINPERF addendum

The AXI-Lite configuration path now uses 9-bit byte addresses. The bridge maps
AXI byte address `[8:2]` to the internal 7-bit `cfg_addr[6:0]`. Existing byte
offsets below `0x100` keep their previous values, but the top-level AXI-Lite
address ports are now `[8:0]`; rebuild the Vivado block design before board
use.

Additional read-only drain sub-performance registers:

| Byte offset | Name | R/W | Meaning |
|---:|---|---|---|
| `0x100` | `DRAIN_READ_FIRE` | R | PSUM drain FIFO read request handshakes |
| `0x104` | `DRAIN_PACKET_FIRE` | R | Drain packets accepted by the downstream OFM path |
| `0x108` | `DRAIN_READY_STALL` | R | Drain cycles stalled by downstream backpressure |
| `0x10c` | `DRAIN_INTERNAL_FULL` | R | Drain cycles blocked by the internal output/skid register |
| `0x110` | `DRAINPERF_VERSION` | R | Current fixed value: `1` |

The existing `0xe8 DRAIN_EMPTY_WAIT` counter remains the FIFO-empty component.
Runtime software prints these fields as `DRAINPERF`, and the summarizer reports
the residual:

```text
STAGE_DRAIN - packet_fire - ready_stall - internal_full - empty_wait
```

## 15. 当前设计边界

- 当前 OFM AXIS 是 debug byte packet 格式，不是连续 HWC burst。
- native 1x1 只承诺 batch mode、stride 1、pad 0、tile 不超过 IFM FIFO。
- raw-HWC 仍是 opt-in 实验路径；默认 prepacked IFM stream 不受影响。
- pooling 目前只实现 bypass 和 uint8 2x2 stride-2 maxpool。
- pass/fail 应以 RTL semantic golden 为准，PyTorch reference 只适合作模型级 sanity check。
- 大型 golden 数据不在本仓库，仍按 `golden/README.md` 放在外部 `D:/MPSoC/python_prj/rtl_golden/`。

## 16. 2026-06-14 early-drain addendum

`STREAM_CFG[2]` is an experimental early PSUM drain enable. Reset/default value
is `0`, and the validated default software flow keeps it disabled unless the
Vitis build is explicitly generated with `-EarlyDrain`.

When enabled, `layer_scheduler_stream` may issue `psum_drain_start` before the
current compute pass has fully completed, once the pass has started producing
PSUM data. The scheduler still requires all three conditions before advancing
to the next pass:

```text
feeder_done_seen && compute_done_seen && drain_done_seen
```

Therefore early drain does not change packet address order, OFM packet format,
DMA streams, raw-HWC tile format, or quantization semantics. It only overlaps
part of PSUM FIFO drain wait with the tail of the current compute pass.

Board validation for `D:/MPSoC/b_earlydrain_22` passed on `COM8` with
`Conv5/6/8 raw-HWC`, `RawHwcComputeStartLevel=64`, and `-EarlyDrain`:

```text
maksssksksss0 DDR demo  PASS  total=520.446 ms
maksssksksss1 DDR demo  PASS  total=520.505 ms
batch-chain             PASS  RTL golden and YOLO decode
```

Compared with the prior `b_drainperf_22` baseline (`543.006 ms`), the observed
fixed-image gain is about `22.6 ms`. Conv5/6/8 `DRAINPERF empty_wait` values are
still unchanged, so the improvement is overlap/hiding rather than faster PSUM
production.

## 17. 2026-06-14 K-pass prefetch addendum

`STREAM_CFG[3]` is an experimental next-K-pass prefetch enable. Reset/default
value is `0`, and software only sets it for experimental builds generated with
`-PassPrefetch`. Hardware ignores the bit for non-raw-HWC layers.

When enabled, the scheduler may prepare the next K pass while the current pass
is still completing. The design keeps two pass indices:

```text
exec_pass_base_k   -> compute, PSUM, final-pass decisions, debug current pass
feeder_pass_base_k -> raw-HWC replay address generation
```

The first prototype is intentionally conservative:

- only prefetches within the same COUT block;
- does not prefetch bias;
- does not start next-pass compute until current-pass drain is complete;
- falls back to waiting if next-pass weight or IFM replay is not ready.

The weight stream format is unchanged. Internally, `systolic_top` now consumes
exactly one weight vector on compute start plus `COLS-1` additional vectors
during weight-load cycles. This keeps the current pass from over-reading into
the prefetched next-pass weight tile.

Additional read-only prefetch counters:

| Byte offset | Name | R/W | Meaning |
|---:|---|---|---|
| `0x114` | `PREFETCH_START` | R | Next-pass prefetch start pulses |
| `0x118` | `PREFETCH_WEIGHT_DONE` | R | Prefetched weight-load completions |
| `0x11c` | `PREFETCH_FEED_DONE` | R | Prefetched raw-HWC replay completions |
| `0x120` | `PREFETCH_HIT` | R | Pass-boundary transitions that found prefetch ready |
| `0x124` | `PREFETCH_MISS` | R | Pass-boundary transitions that still had to wait |
| `0x128` | `PREFETCH_STALL` | R | Cycles spent waiting for pending prefetch work |
| `0x12c` | `PREFETCHPERF_VERSION` | R | Current fixed value: `1` |

Runtime software prints these fields as `PREFETCHPERF`. Local Vivado/xsim
`2022.2` validation passes Conv5/Conv6/Conv8 raw-HWC tile0 with
`RawHwcComputeStartLevel=64`, early drain, and pass prefetch enabled.

## 18. 2026-06-15 partial-PSUM stream overlap addendum

`STREAM_CFG[4]` enables experimental partial-PSUM overlap. It is effective only
with raw-HWC mode and next-K prefetch enabled. Reset and normal software builds
keep the bit at `0`.

For a non-final K pass, the current drain writes partial sums into one
ping-pong bank while the next pass reads the other bank. The scheduler may
start the next compute after a conservative drain lead is available. Per-bank
available counters prevent the PSUM reader from overtaking the writer; a
blocked reader deasserts compute-ready rather than reading unwritten data.
Drain completion is latched independently of scheduler state so a one-cycle
done pulse cannot be lost during prefetch commit.

Additional read-only counters:

| Byte offset | Name | R/W | Meaning |
|---:|---|---|---|
| `0x130` | `PSUMOVL_START` | R | Partial-PSUM overlap transitions |
| `0x134` | `PSUMOVL_HIT` | R | Transitions that met prefetch and PSUM lead conditions |
| `0x138` | `PSUMOVL_WAIT_PSUM` | R | Cycles waiting for the conservative PSUM lead |
| `0x13c` | `PSUMOVL_UNDERFLOW` | R | Sticky/count indication that a reader reached unavailable data |
| `0x140` | `PSUMOVLPERF_VERSION` | R | Current fixed value: `1` |

Vivado/xsim `2022.2` external-golden tests pass for Conv5, Conv6, and Conv8
raw-HWC tile0 with overlap64, early drain, pass prefetch, and partial-PSUM
overlap enabled.

The first Vivado `2022.2` implementation in `D:/MPSoC/b_psumovl_22` meets
timing (`WNS=+0.038 ns`, `WHS=+0.010 ns`) with zero routing errors. The
concurrent PSUM ping-pong memory currently maps to about `23616` LUTs rather
than the previous `14 BRAM` storage, increasing total LUT use to `78900`.
Board validation remains pending, and a later revision should restore explicit
BRAM mapping if the measured overlap gain does not justify this resource cost.

## 19. 2026-06-15 continuous PSUM collector addendum

`STREAM_CFG[5]` enables the experimental continuous PSUM collector. Reset and
normal software builds keep this bit clear. Vitis exposes the experiment with
`-ContinuousPsum`.

In this mode, the scheduler submits one pass context before compute starts.
`psum_output_collector` consumes the per-column PSUM FIFOs, groups a full
`COLS*2` packet per pixel, and keeps the collector active across consecutive
pass contexts. Non-final packets write directly into the selected partial-PSUM
ping-pong bank; final packets continue into the existing requant, activation,
pool, and OFM writeback path.

The external AXIS/DMA formats, raw-HWC tile layout, OFM packet format,
quantization semantics, and layer schedule are unchanged. The mode currently
targets the same backend set as the previous overlap experiments:
Conv5/Conv6/Conv8 raw-HWC with overlap64, early drain, pass prefetch, and
partial-PSUM overlap.

Additional read-only collector counters:

| Byte offset | Name | R/W | Meaning |
|---:|---|---|---|
| `0x144` | `COLLECT_PACKET_FIRE` | R | Collector packets accepted downstream |
| `0x148` | `COLLECT_PARTIAL_WRITE` | R | Non-final packets written to partial PSUM RAM |
| `0x14c` | `COLLECT_FINAL_WRITE` | R | Final packets sent to OFM post-processing |
| `0x150` | `COLLECT_CONTEXT_PUSH` | R | Pass contexts accepted by the collector FIFO |
| `0x154` | `COLLECT_CONTEXT_POP` | R | Completed pass contexts |
| `0x158` | `COLLECT_CONTEXT_FULL_STALL` | R | Cycles with scheduler context valid but collector FIFO full |
| `0x15c` | `COLLECT_COLUMN_EMPTY_WAIT` | R | Cycles waiting for one or more PSUM column FIFOs |
| `0x160` | `COLLECTPERF_VERSION` | R | Current fixed value: `1` |

Runtime software prints these fields as:

```text
COLLECTPERF layer=... packet_fire=... partial_write=... final_write=...
            context_push=... context_pop=... context_full_stall=...
            column_empty_wait=... version=...
```

Local validation has passed under Icarus and Vivado/xsim `2022.2`, including
Conv5, Conv6, and Conv8 raw-HWC tile0/tile3 external-golden tests with
continuous PSUM enabled. The first board build exposed a Conv5 tail-tile
mismatch caused by stale per-bank partial-PSUM availability credit when a
ping-pong bank was reused. The fix clears the selected bank credit on each
non-final continuous collector compute start.

The fixed `D:/MPSoC/b_psumcollector_fix3_22` Vivado `2022.2` implementation is
complete: `WNS=+0.165 ns`, `TNS=0`, `WHS=+0.010 ns`, `THS=0`, `0` routing
errors, `56442 LUT`, `49000 FF`, `63 BRAM`, `8 URAM`, and `183 DSP`. The
bitstream hash is
`1E0255EA61AEBF28C01DC72386B398ABAE000193EA840C217CAAD5BC6437248D`, and the
XSA hash is
`40424070EDC08B05BDA56FE2295A2D5F3520E4F425559E2693F9B49185E1562A`.

Board validation passes:

```text
batch-chain: PASS, 20260615_081758_conv0_conv9_batch_chain_COM8.log
DDR image0:  PASS, 0.371271 s, 20260615_082040_conv0_conv9_ddr_demo_COM8.log
DDR image1:  PASS, 0.371314 s, 20260615_082302_conv0_conv9_ddr_demo_COM8.log
```

`COLLECTPERF context_full_stall=0`, `PSUMOVLPERF underflow=0`, and
`PREFETCHPERF` hit rate is `100%` on the continuous-collector backend layers.
The measured gain over the previous `b_psumovl_credit1_22` baseline is small
but positive; the dominant remaining cycles are still compute-stage and
feeder/replay activity.

## 20. 2026-06-15 pass timeline diagnostic addendum

The pass timeline monitor is a diagnostic-only block. It does not feed back
into scheduler control, DMA handshakes, raw-HWC cache replay, PSUM storage, OFM
format, or quantization. Its purpose is to explain why the continuous PSUM
collector build still reports much more `STAGE_COMPUTE` and
`COLLECT_COLUMN_EMPTY_WAIT` time than true `compute_fire` time.

The monitor observes existing pass events:

```text
weight_done
feed_start/feed_ready/feed_done
compute_start/compute_fire/compute_done
collector_packet_fire/collector_context_done
raw_replay_active
stage_compute
```

Per-layer aggregate counters are cleared on layer start and held after layer
done:

| Byte offset | Name | R/W | Meaning |
|---:|---|---|---|
| `0x164` | `PASSTRACE_SELECT` | R/W | bit31 trace enable, `[23:16]` COUT block, `[15:0]` K pass |
| `0x168` | `PASS_COUNT` | R | Completed pass contexts seen by the monitor |
| `0x16c` | `PASS_START_TO_FIRST_FIRE` | R | Sum of compute-start to first compute-fire latency |
| `0x170` | `PASS_FIRST_TO_LAST_FIRE` | R | Sum of first-fire to last-fire spans |
| `0x174` | `PASS_LAST_FIRE_TO_DONE` | R | Sum of last-fire to compute-done tail latency |
| `0x178` | `PASS_COLLECT_FIRST_WAIT` | R | Sum of compute-start to first collector packet latency |
| `0x17c` | `PASS_COLLECT_COLUMN_EMPTY` | R | Collector column-empty wait cycles |
| `0x180` | `PASS_REPLAY_DURING_COMPUTE` | R | Raw-HWC replay-active cycles during compute stage |
| `0x184` | `PASS_COMPUTE_IDLE_STAGE` | R | Compute-stage cycles without `compute_fire` |

The optional trace window records layer-local timestamps for one selected pass:

| Byte offset | Name | R/W | Meaning |
|---:|---|---|---|
| `0x188` | `PASSTRACE_WEIGHT_DONE` | R | Selected pass weight-done timestamp |
| `0x18c` | `PASSTRACE_FEED_START` | R | Selected pass feeder-start timestamp |
| `0x190` | `PASSTRACE_FEED_READY` | R | Selected pass first feeder-ready timestamp |
| `0x194` | `PASSTRACE_FEED_DONE` | R | Selected pass feeder-done timestamp |
| `0x198` | `PASSTRACE_COMPUTE_START` | R | Selected pass compute-start timestamp |
| `0x19c` | `PASSTRACE_FIRST_FIRE` | R | Selected pass first compute-fire timestamp |
| `0x1a0` | `PASSTRACE_LAST_FIRE` | R | Selected pass last compute-fire timestamp |
| `0x1a4` | `PASSTRACE_COMPUTE_DONE` | R | Selected pass compute-done timestamp |
| `0x1a8` | `PASSTRACE_COLLECT_FIRST` | R | Selected pass first collector packet timestamp |
| `0x1ac` | `PASSTRACE_COLLECT_LAST` | R | Selected pass last collector packet timestamp |
| `0x1b0` | `PASSTRACE_PASS_DONE` | R | Selected pass context completion timestamp |
| `0x1b4` | `PASSPERF_VERSION` | R | bit31 trace-valid, `[30:0]` fixed version `1` |

Runtime software prints aggregate lines as:

```text
PASSPERF layer=... pass_count=... start_to_first=... fire_span=...
         tail=... collect_wait=... collect_empty=...
         replay_during_compute=... compute_idle=... version=...
```

When tracing is enabled at build time with `-TilePerfTrace`, it also prints:

```text
PASSTRACE layer=... tile=... cout_block=... k_pass=...
          weight_done=... feed_start=... feed_ready=... feed_done=...
          compute_start=... first_fire=... last_fire=... compute_done=...
          collect_first=... collect_last=... pass_done=... version=...
```

The intended first use is Conv5/Conv6/Conv8 raw-HWC with overlap64, early drain,
pass prefetch, partial-PSUM overlap, and continuous PSUM enabled. If
`start_to_first_fire` or `compute_idle_stage` dominates, the next work should
focus on compute-start and array input cadence. If `fire_span` has low density,
the issue is inside the active compute window. If `collect_column_empty`
dominates, the next work should inspect per-column PSUM output alignment and
collector aggregation.

The first Vivado `2022.2` implementation for this diagnostic build completed in
`D:/MPSoC/b_passtrace_22` with timing met (`WNS=+0.193 ns`, `TNS=0`,
`WHS=+0.010 ns`, `THS=0`) and `0` routing errors. The exported artifacts are:

```text
bit SHA256=7712344B10C36969552A9547B1CED9F834C6381B3209316D9E0001DFDA4F4B04
XSA SHA256=99F09A6ACC6E9D3DE287DDD8AB7BA05080F4CF887E477745D8359B9D3D076AD8
```

The first board run showed that a selected trace could be overwritten by the
next pass before the continuous collector popped the selected context. The
monitor now tracks the selected trace lifetime separately from the current
compute lifetime. The fixed implementation is:

```text
build dir: D:/MPSoC/b_passtrace_fix2_22
WNS=+0.113 ns, TNS=0, WHS=+0.010 ns, THS=0
routing errors=0
CLB LUTs=57226, CLB Registers=49831
LUT as Memory=16638, BRAM Tile=63, URAM=8, DSP=184
bit SHA256=3DC26E405921DCF04057CFFC8E8997D0A3481D4EBFF9585551B34A26FE7D2FBE
XSA SHA256=258458C60231AE5D62CE1E4E0F9BB7D73C8F8043FEB2A0D440DF24C2ABC660AA
```

KV260 validation passed batch-chain and two DDR images:

```text
batch-chain: 20260615_230847_conv0_conv9_batch_chain_COM8.log
image0:      20260615_231105_conv0_conv9_ddr_demo_COM8.log
image1:      20260615_231547_conv0_conv9_ddr_demo_COM8.log
```

The selected Conv5/Conv6/Conv8 tile0 traces are valid. For `cout_block=0`,
`k_pass=0`, compute begins nine cycles before the first compute fire, the
52-pixel tile fires over a 52-cycle span, and the first collector packet appears
about 112 cycles after compute done. The aggregate counters point toward
collector column-empty / compute-idle behavior as the next item to explain:

```text
COLLECTPERF column_empty_wait=11628928
PASSPERF compute_idle=11907808
PASSPERF avg_start_to_first=9.00
PASSPERF avg_collect_wait=1.50
```

## 21. 2026-06-15 column-level PSUM trace addendum

`coltrace_monitor` is a diagnostic-only block attached to the PSUM FIFO write
side and the continuous collector wait side. It does not feed back into the
array, scheduler, FIFO, collector, or AXI control paths. The selected pass is
the same `cout_block/k_pass` selected by `PASSTRACE_SELECT`.

The column trace registers are:

| Byte offset | Name | R/W | Meaning |
|---:|---|---|---|
| `0x1b8` | `COLTRACE_CTRL` | R/W | bit31 trace valid, `[4:0]` selected column |
| `0x1bc` | `COLTRACE_FIRST_WR` | R | First PSUM FIFO write timestamp for the selected column |
| `0x1c0` | `COLTRACE_LAST_WR` | R | Last selected-pass PSUM FIFO write timestamp |
| `0x1c4` | `COLTRACE_WR_COUNT` | R | Selected-pass PSUM FIFO writes for the selected column |
| `0x1c8` | `COLTRACE_EMPTY_WAIT` | R | Collector wait cycles while the selected column was empty |
| `0x1cc` | `COLTRACE_MISSING_MASK_OR` | R | OR of all missing-column masks during the selected pass |
| `0x1d0` | `COLTRACE_MISSING_MASK_FIRST` | R | First missing-column mask |
| `0x1d4` | `COLTRACE_MISSING_MASK_LAST` | R | Last missing-column mask |
| `0x1d8` | `COLTRACE_VERSION` | R | Current fixed value: `1` |

The runtime selects each column after layer completion and prints:

```text
COLTRACE layer=... tile=... cout_block=... k_pass=... col=...
         first_wr=... last_wr=... wr_count=... empty_wait=...
         missing_or=... missing_first=... missing_last=...
         version=... valid=...
```

Vivado/xsim `2022.2` external-golden tests for Conv5, Conv6, and Conv8 tile0
all pass with the trace enabled. Their selected 52-pixel pass has the same
column timing:

```text
column  first write  last write  writes  empty wait
0       152127       152178      52      99
1       152131       152182      52      103
2       152135       152186      52      107
3       152139       152190      52      111
4       152143       152194      52      115
5       152147       152198      52      119
6       152151       152202      52      123
7       152155       152206      52      127
```

This is a deterministic four-cycle phase shift per array column. Each column
then produces one result per cycle for all 52 pixels. The collector is not
seeing random starvation, lost packets, unequal packet counts, or downstream
backpressure. `missing_first=0xff` and `missing_last=0x80` are consistent with
the array filling from column 0 toward column 7.

The important consequence is that a collector-only phase compensation cannot
recover the full `COLLECT_COLUMN_EMPTY_WAIT` count: a complete `COLS*2` packet
still depends on the latest column. The 28-cycle first-to-last-column skew is
only part of the 127-cycle first-packet latency. Further optimization must
either amortize the fixed pass startup over larger spatial tiles, or change
partial-PSUM consumption so the next pass can consume per-column results
without waiting for a fully assembled packet.
## 2026-06-16 backend full-tile HWC cache note

The current 3x3 raw-HWC cache is still the materialized 3x3 window cache. It is
not yet a pure raw feature-map cache with a new address generator. The cache
capacity requirement is therefore expressed in materialized words:

```text
required_words = tile_pixels * ceil(CIN / IFM_BANKS)
IFM_BANKS      = 2
```

The experimental backend full-tile configuration is:

```text
HWC_CACHE_AW=16
HWC_CACHE_DEPTH=43264
HWC_CACHE_STRIPES=4
HWC_CACHE_USE_URAM=1
```

This keeps the existing DMA/AXIS format, weight format, OFM packet format,
quantization, and replay semantics unchanged. It only increases the cache depth
so Conv5, Conv6, and Conv8 can use one 13x13 spatial tile:

```text
Conv5/8: 169 * ceil(256/2) = 21632 words
Conv6:   169 * ceil(512/2) = 43264 words
```

The first software switch is `-BackendFullTile`. It is intentionally
non-default and should be paired with a hardware build whose cache parameters
match the values above. The old four-tile backend schedule remains the safe
path when the switch is not set.
## During-Compute Next-Pass Prefetch

`STREAM_CFG[7]` is an experimental `during_compute_prefetch_enable` bit.
Reset/default software leaves it at `0`.

When this bit is set together with raw-HWC mode and pass prefetch, the scheduler
may start staging the next K pass while the current pass is still in compute.
This is deliberately only staging:

```text
current pass:
  PE weights and IFM FIFO entries are consumed by the active compute

next pass:
  weight stream may be accepted into the weight staging path
  raw-HWC replay may append IFM vectors behind current-pass FIFO data
  next compute does not start until the current pass dependency rules are met
```

The bit does not allow PE weights to be overwritten during the current compute,
does not start the next compute early, and does not change DMA stream formats,
raw-HWC tile layout, OFM packet order, quantization, or layer scheduling visible
to software. If the current feeder/replay has not completed before compute,
the optimization naturally falls back to the old pass-prefetch timing.

`STREAM_CFG` readback at AXI-Lite offset `0x19` is:

```text
bit0 batch stream
bit1 raw-HWC mode
bit2 early drain
bit3 pass prefetch
bit4 psum stream overlap
bit5 continuous PSUM
bit6 column PSUM
bit7 during-compute next-pass prefetch
```

The first validation target is the backend full-tile raw-HWC path for Conv5,
Conv6, and Conv8. Existing prepacked IFM paths and default board-validated
ELFs leave this bit clear.

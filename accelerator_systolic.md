# Systolic Accelerator — 设计与实现文档

> 最后更新: 2026-05-24

---

## 一、整体架构

```
DDR (AXI-Stream)
  │
  ▼
Line Buffer (5 bank × 3 line × 3 read port)
  │  每拍 DMA 写 5 bank × 8-bit
  │  窗口提取器每拍读 45 值 → 选 32 值 → 256-bit
  │
  ▼
IFM FIFO (32 × 8-bit, 深 256)
  │  错开注入: Row r 延迟 r×5 拍
  │
  ▼
┌──────────────────────────────────────────┐
│        32×32 Systolic Array               │
│  ┌──────┐  valid-based compute           │
│  │ ctrl │  IDLE → WEIGHT_LOAD → COMPUTE   │
│  └──────┘                                │
│  psum_top ← bias_buf / ext / 0           │
│  PE 内部: DSP48E2 (INT8×2) + valid 传播   │
└──────────────┬───────────────────────────┘
               │
               ▼
PSUM FIFO (32 × 48-bit, 深 256)
  │  valid_v_bot → wr_en
  │
  ▼
requant (乘 mult + 移 shift + zp + clamp)
  │  2 拍流水线, INT8 输出
  │
  ▼
LeakyReLU LUT (256×8-bit)
  │  组合读
  │
  ▼
DDR (AXI-Stream 写回)
```

### 数据流

```
DDR → DMA(40-bit/拍) → Line Buffer(5bank×3line) → Window Extract → IFM FIFO(32路)
  → Array(32×32) → PSUM FIFO(32路) → requant → LUT → DDR
```

---

## 二、已完成模块

| 模块 | 文件 | 测试 | 说明 |
|------|------|------|------|
| PE | `systolic_pe.v` | 78/78 | 双权重 DSP + valid 传播 (水平4拍/垂直5拍) |
| 32×32 阵列 | `systolic_array_32x32.v` | 320/320 | valid 链 + 列并行权重加载 |
| FIFO | `systolic_fifo.v` | 45/45 | 空满保护, 同时读写 |
| 阵列控制 | `systolic_ctrl.v` | — | IDLE→WEIGHT_LOAD→COMPUTE |
| 顶层 | `systolic_top.v` | 4160/4160 | FIFO+阵列+valid+偏置集成 |
| requant | `requant.v` | 14/14 | 乘 mult + 移 shift + zp + clamp, 2拍流水线 |
| LeakyReLU LUT | `leaky_lut.v` | 260/260 | 256×8-bit 分布式 RAM, 组合读 |
| 偏置注入 | `bias_buf` in top | 4160/4160 | 64×24-bit bias buffer + psum_top mux |
| 外部 psum_top | `psuma_top_ext` in top | 64/64 | 多轮累加注入 |
| im2col 计数器 | `im2col_addr_gen.v` | 66/66 | 顺序像素计数 (用于预排好的 IFM) |
| 行缓存 | `line_buffer_5bank.v` | 11/11 | 5 bank × 3 line × 3 读口, 环行覆盖 |
| 窗口提取器 | `window_extract.v` | 11/11 | pass_base_k → row → (ch,ker) → 32 IFM 值 |

### 全部测试汇总

```
PE          78/78    ✅
阵列         320/320   ✅
FIFO        45/45    ✅
顶层(集成)   4160/4160 ✅
requant     14/14    ✅
LUT         260/260  ✅
偏置注入     4160/4160 ✅ (含 ext psum_top 64/64)
im2col      66/66    ✅
行缓存+窗口   11/11    ✅
───────────────────────
Total       5114/5114 ✅
```

---

## 三、行缓存 + 窗口提取器设计

### 行缓存规格

| 参数 | 值 |
|------|-----|
| Bank 数量 | 5 (每 Pass 最多 5 通道) |
| 每 bank 行数 | 3 (3×3 核) |
| 每行深度 | FM_W (最大 416) |
| 读口数 | 3 (独立 x 地址, 对应 kx=0,1,2) |
| 每读口位宽 | 120-bit (5 bank × 3 line × 8-bit) |
| 三读口合计 | 45 值 = 360-bit |
| 实现 | 每 line 3 BRAM 副本 → 45 BRAM18 总计 (XCK26 占 16%) |

### 行缓存接口

```verilog
// DMA 写 (40-bit/拍)
input  [4:0]  bank_wr_en,       // 5 bank 写使能
input  [8:0]  wr_x,             // 列地址
input  [7:0]  wr_data [0:4],   // 5 bank × 8-bit
input  [9:0]  wr_fy,            // IFM 行号
input         line_advance,     // 行切换脉冲

// 窗口读 (360-bit/拍)
input  [8:0]  rd_x0, rd_x1, rd_x2,  // kx=0,1,2 的列地址
output [7:0]  rd_data [0:4][0:2][0:2], // [bank][line][kx]
output [9:0]  line_fy_out [0:2]     // 物理行→IFM行号映射
```

### 窗口提取器接口

```verilog
input  [8:0]  oy, ox,            // 输出像素位置
input  [10:0] pass_base_k,       // Pass 起始 kernel 索引
input  [7:0]  lb_data [0:4][0:2][0:2], // 行缓存输出
input  [9:0]  line_fy [0:2],     // 行号映射
output [255:0] ifm_data,          // 32 IFM 值 → IFM FIFO
output        ifm_valid
```

### 窗口提取逻辑

```verilog
for row = 0..31:
    global_k = pass_base_k + row
    ch       = global_k / 9
    ker      = global_k % 9
    ky       = ker / 3
    kx       = ker % 3
    bank     = ch % 5
    fy       = oy*stride + ky - pad
    fx       = ox*stride + kx - pad
    line_idx = (line_fy[0]==fy)? 0 : (line_fy[1]==fy)? 1 : 2

    if (in_bounds): value = lb_data[bank][line_idx][kx]
    else:           value = 0  // padding
```

---

## 四、Pass 分块策略

### 行分块 (IFM 通道)

```
每 Pass: 3 全通道 (27行) + 部分通道 (5行) = 32 行
3×3 核 = 9 kernel 位置/通道

Pass 1 (base=0):  ch0×9 + ch1×9 + ch2×9 + ch3×5 = 32
Pass 2 (base=32): ch3×4 + ch4×9 + ch5×9 + ch6×9 + ch7×1 = 32
Pass 3 (base=64): ch7×8 + ch8×9 + ch9×9 + ch10×6 = 32

每 Pass 消耗 32 kernel 位置 → base += 32
DDR 每 Pass 重发: 5 通道 × FM_H × FM_W 字节
```

### 列分块 (OFM 通道)

```
32 列 × 2 OFM/列 = 64 OFM 通道并行

OFM[0..63]   完成 → PSUM → requant → LUT → DDR
OFM[64..127] 开始 → 换 WGT → IFM 重遍历 → PSUM 复用
```

---

## 五、存储调度 FSM (待实现)

```
                          ┌─────────────┐
               layer_start │    IDLE     │
              ────────────►│             │
                           └──────┬──────┘
                                  │
                    ┌─────────────┴─────────────────┐
                    │  FILL_IFM_A + FILL_WGT_A      │
                    │  (IFM[0..31], WGT 对应 OFM 块) │
                    └─────────────┬─────────────────┘
                                  │ bank_A_ready
                                  ▼
              ┌──────────────────────────────────────────┐
              │              LAUNCH_A                    │
              │  start → 阵列 WEIGHT_LOAD + COMPUTE      │
              │  psum_top = bias (第一轮)                │
              │  → PSUM 写入 PSUM_FIFO_A                 │
              └────────┬─────────────┬───────────────────┘
                       │             │
          ┌────────────┘             └────────────┐
          ▼                                       ▼
 ┌─────────────────────┐             ┌──────────────────────┐
 │  FILL_IFM_B+WGT_B   │             │   WAIT_COMPUTE_A     │
 └──────────┬──────────┘             └────────────┬─────────┘
            │                                     │
            │ bank_B_ready + compute_A_done        │
            └──────────────┬──────────────────────┘
                           ▼
                      LAUNCH_B (psum_top = PSUM_FIFO_A 输出)
                           │
                           ▼
                      ┌─────────┐
                      │ifm_done?│── 否 ──► LAUNCH_A (循环)
                      └────┬─────┘
                           │ 是
                           ▼
                        DRAIN_PSUM → 后处理 → DDR
```


---

## 六、关键设计决策

| 决策 | 选择 | 原因 |
|------|------|------|
| 阵列架构 | Weight-stationary 脉动阵列 | 权重复用, 减少 BRAM 读取 |
| IFM 注入 | 5 bank 行缓存 + DDR 重发 | 不膨胀存储, 带宽充足 |
| 行缓存读口 | 3 副本 (45 BRAM18) | 3×3 核需同时读 3 列 |
| 窗口提取 | 组合逻辑 mux | 无延迟, 每拍 1 像素 |
| 3×3 核映射 | 每通道 9 行, 3 通道/Pass + 部分 | 最大化阵列利用率 |
| PSUM 写使能 | 阵列底部 valid 信号 | 无需魔法数字, 自动对齐 |
| 量化 | post-PSUM requant | 中间轮 24-bit 精度保持 |
| 激活 | LUT 查表 | 256 条目覆盖全部 INT8 值 |
| 偏置 | psum_top mux (Pass 1) | 和部分和共用注入口 |

### 与参考项目 (Angel-Eye) 的主要区别

| 要点 | 参考项目 | 本设计 |
|------|---------|--------|
| 阵列架构 | 单引擎时分复用 | 32×32 脉动阵列 |
| 计算并行度 | 8 IFM × 8 OFM | 32 IFM × 64 OFM |
| PSUM 控制 | 魔法数字计时器 | valid 传播自定时 |
| IFM 路径 | AXI-Stream 直连 | 行缓存 + 窗口提取器 |
| 通道分块 | 无 (只用单尺度) | 5 bank 多 Pass |
| 量化位置 | PE 内部 | PSUM FIFO 出口 |

# RTL 测试计划与检查项

> 当前交付基线：`ROWS=18`、`COLS=8`、Vivado/xsim 2022.2、稳定 `b_hwcreplay_22` 数据流。

## 1. 总体策略

测试按风险从模块到系统分为四层：

1. 模块单元测试：握手、边界、饱和、计数和 backpressure；
2. 小规模顶层 directed test：验证 scheduler 与数据流组合；
3. 外部 RTL semantic golden：验证真实量化层 byte-exact；
4. KV260 板级链路：验证 DMA、AXI-Lite、软件调度和最终 YOLO decode。

共同检查项：

- 只在 `valid && ready` 时推进；
- backpressure 下 payload、地址和 TLAST 保持稳定；
- 输出数量、顺序和地址连续；
- `bias/weight/ifm_axis_error=0`；
- 量化、LUT、Pooling 与 golden byte-exact；
- first mismatch 打印 pixel、channel、address、RTL 和 golden。

## 2. AXIS 顶层测试

### `tb_conv_accel_core_axi_lite_axis_stream_smoke`

验证 AXI-Lite 配置、Bias/Weight/IFM AXIS 输入、阵列计算、OFM 输出和 done/TLAST 的最小闭环。

### `tb_conv_accel_core_axi_lite_axis_stream_ps_driver`

模拟 PS 软件按 request 驱动 Bias、Weight 和 IFM，检查请求顺序、packet 数、busy/done 和错误标志。

### `tb_conv_accel_core_axi_lite_axis_stream_backpressure`

在 OFM 输出侧插入固定 stall，要求 `m_axis_ofm_tvalid`、`tdata`、`tlast` 在等待期间保持稳定，恢复后无丢包或重复。

### `tb_conv_accel_core_axi_lite_full_stream_backpressure`

对 full-stream wrapper 执行同样的 backpressure 检查，并覆盖内部 packet FIFO 到 byte stream 的转换。

### 阵列参数化 Smoke

| 测试 | 配置 | 用途 |
|---|---|---|
| `tb_conv_accel_core_axi_lite_axis_stream_r16_c16_smoke` | 16x16 | 旧阵列参数兼容性 |
| `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_smoke` | 18x16 | 两通道 3x3 K-pass 结构 |
| `tb_conv_accel_core_axi_lite_axis_stream_r32_c16_smoke` | 32x16 | 较大 ROWS 参数化边界 |

这些测试保留为参数化回归，不代表当前交付配置；当前正式配置是 18x8。

### 输入 Zero-Point 顶层测试

- `tb_conv_accel_core_axi_lite_axis_stream_input_zp`
- `tb_conv_accel_core_axi_lite_full_stream_input_zp`

外部 IFM 发送 uint8 activation，RTL 在写入 line buffer 前执行：

```text
ifm_s8 = saturate_s8(ifm_u8 - input_zero_point)
```

定向值覆盖：

```text
zp=36, input=36  -> 0
zp=36, input=22  -> -14
zp=36, input=86  -> 50
zp=36, input=255 -> 127
zp=200,input=0   -> -128
```

AXI-Lite `0x0f` 配置 zero-point；window、MAC、requant、OFM、TLAST 和 debug counter 必须继续匹配 signed-IFM golden。

## 3. 关键模块测试

### `tb_ofm_activation`

检查 bypass、ReLU、LUT、valid/ready 流水和输出 backpressure。输入停顿时不得重复消费，输出停顿时数据必须保持。

### `tb_ofm_requant_writer`

检查 int32 PSUM、int32 Bias、Q15 multiplier、`effective_shift=shift+15`、rounding、output zero-point 和 uint8 饱和。

### `tb_ofm_writeback`

检查 packet 地址、channel 打包、最终 pass 标志、OFM byte 顺序、TLAST 和 backpressure。

### `tb_axi_lite_cfg_bridge`

检查 AW/W 独立握手、WSTRB merge、读写响应、非法地址和 busy freeze。

### `tb_layer_config_regs`

覆盖 layer 参数、quant/LUT、stream 配置、性能计数、start 清零、done 后保持和只读寄存器。

### IFM Loader

- `tb_axis_ifm_line_loader`：AXIS line packet、TKEEP/TLAST、短包/长包和 zero-point；
- `tb_ifm_line_stream_loader`：多 bank line fill、DMA 写地址、饱和和 done；
- `tb_axis_hwc_tile_cache`：HWC load、18-lane bank、CIN tail、raw replay 和 fast replay。

### OFM Pooling

- `tb_ofm_pooling`：bypass、2x2 maxpool stride2、奇偶边界和 backpressure；
- `tb_conv_accel_core_pooling`：Conv、Activation、Pooling 模块级串联；
- `tb_conv_accel_core_axi_lite_axis_stream_pooling`：配置和 AXIS 顶层串联；
- `tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_ext`：真实 Conv0 crop+pool golden。

## 4. Layer06 真实数据测试

Layer06 代表 `52x52x64 -> 52x52x128` 的多通道 3x3 卷积，用于验证 K/COUT 分块和 partial PSUM。

| 测试 | 主要覆盖内容 |
|---|---|
| `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_tile4` | 18x16 外部 golden 小 tile |
| `tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_layer06_ext_tile4` | 当前 18x8 主配置 |
| `tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_layer06_pool_ext_tile4` | Conv+Activation+Pool |
| `tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_conv4_pool_ext_tile4` | 后续 Conv+Pool 真实数据 |
| `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tile4_fifo16_backpressure` | 小 OFM FIFO 和 backpressure |
| `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_tiles` | 顶部、中部、底部 tile |
| `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_full` | 完整层输出 |

检查输出 byte-exact、数量、TLAST、debug counter 和 AXIS error。`full_fifo256` 只作诊断，不纳入短回归。

## 5. 层间与板级调度测试

### KV260 `conv3_pool -> conv4_pool`

验证连续两层配置、DMA buffer 切换、上一层 Pooling 输出作为下一层 IFM，以及第二层输出与 golden 一致。

### Conv0 至 Conv9 Batch Chain

要求每层 RTL golden comparison 通过，最终 Conv9 tensor 经软件 decode 后与 `repro/expected/decode_golden.json` 一致。

### 固定图片 DDR Demo

使用：

```text
repro/images/maksssksksss0.png
```

当前稳定基线输出一个 `with_mask` 检测，score 约 `0.357321`，十层 PL 推理约 `280.340 ms`。

## 6. Raw-HWC 与后端 Full-Tile 测试

### Conv6 3x3 Raw-HWC

- `tb_conv_accel_core_axi_lite_axis_stream_conv6_3x3_raw_hwc_ext_tile0_cout16`
- `tb_conv_accel_core_axi_lite_axis_stream_conv6_3x3_raw_hwc_ext_tile3_cout16`

检查 raw load byte 数、replay packet 数、OFM 数量、TLAST、AXIS error 和 byte-exact 输出。

### 后端 Full-Tile

覆盖 Conv5、Conv6、Conv8 完整 `13x13` spatial tile。Conv6 是容量上界：

```text
169 * ceil(512/2) = 43264 words
```

旧 4-tile 调度继续作为对照。Full-tile 模式不得改变 AXIS/DMA、Weight、OFM 或量化语义。

### Conv3 Raw-HWC 大 Tile A/B

26-row tile 超过 `IFM_FIFO_DEPTH=1024`；`18/18/16` 三 tile 可以运行，但慢于正式 Conv4/5/6/8 配置，因此仅作为诊断项。

## 7. PSUM 与性能诊断测试

### 连续 PSUM Collector

- `tb_psum_output_collector`：context FIFO、column skew、partial/final packet 和 context-full stall；
- `tb_psum_pingpong_buffer_bram`：独立 bank 读写与同步读延迟；
- `tb_layer_scheduler_continuous_psum`：context handoff 和关闭时 fallback。

Conv5/6/8 tile0 当前为 `854 pass, 0 fail`，tile3 为 `230 pass, 0 fail`；板级 `context_full_stall=0`、underflow 为 `0`。

### Pass 时间线

- `tb_pass_timeline_monitor` 验证聚合计数和选定 pass 时间戳；
- 配置测试覆盖 `0x164..0x1b4`；
- UART parser 覆盖 `PASSPERF` 与 `PASSTRACE`。

代表样本为 `compute_start -> first_fire = 9` cycles，52-pixel pass 的 fire span 为 52 cycles。

### 列级 PSUM 跟踪

- `tb_coltrace_monitor` 验证 first/last write、write count、empty wait 和 missing mask；
- 配置测试覆盖 `0x1b8..0x1d8`；
- Conv5/6/8 要求八列均满足 `wr_count == num_pixels`。

实测 column `n` 相对 column 0 固定晚 `4*n` cycles，这是阵列传播相位，不是随机 starvation。

## 8. 实验路径测试边界

### 计算期间下一 Pass 预取

`STREAM_CFG[7]` 只允许准备下一 K pass，不应覆盖 active PE Weight 或提前启动 compute。该路径与 fast replay 共用 IFM FIFO 时在 Conv4 上板出现 byte mismatch，正式回归禁止启用。

### IFM Ping-Pong 与双 Staging

相关实验多次在 Conv4/Conv5 板级链路失败，尚无能够完全复现板级卡点的顶层仿真。代码保留在实验分支，不属于当前交付主线。

## 9. Cortex-A53 INT8 CPU 基线

构建：

```powershell
powershell -ExecutionPolicy Bypass -File sw/vitis_2022_2/scripts/manual_build_cpu_yolo_baseline.ps1
```

检查每层 `CPU_LAYER golden_mismatch=0`，UART `DET` 与 Conv9 decode golden 一致。默认 KCO 标量 C 约 `2.54 s`，可选 NEON 约 `2.78 s`。

## 10. 回归命令

单个 xsim 顶层：

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' `
  -mode batch `
  -source tcl\run_xsim_regression.tcl `
  -tclargs -top tb_conv_accel_core_axi_lite_axis_stream_backpressure
```

短回归：

```powershell
powershell -ExecutionPolicy Bypass -File tb/run_short_xsim_regression.ps1
```

多个顶层必须逐个传入 `-top`，不要在同一个 `-top` 参数后直接排列多个模块名。

## 11. 当前仍未覆盖的风险

- 尚无形式验证和综合后门级仿真；
- 长时间随机 AXIS backpressure 覆盖仍有限；
- 随机量化参数、LUT 和 zero-point 扫描不足；
- FIFO 深度与 DDR/DMA 最大 stall 的关系仍需系统级压力测试；
- 实验性 replay/compute overlap 和 IFM staging 缺少可稳定复现板级失败的仿真；
- 完整网络只验证当前单尺度口罩检测配置，未覆盖通用 YOLOv3-tiny 双尺度结构。

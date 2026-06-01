# RTL Test Plan and Checks

本文档记录当前 RTL 回归测试的思路、数据来源、检查项和覆盖边界。当前测试以可复现的 directed pattern 为主，重点验证卷积主数据流、AXI/stream 握手、配置保护和 OFM 后处理链路。

## 总体思路

顶层测试不读取外部图片或权重文件，而是在 testbench 内部用固定公式生成 IFM、weight 和 bias，然后用同一组数据计算 golden convolution。输出端按 pixel/channel 逐项比较，另用计数器检查关键握手和事件数量。

主路径覆盖：

```text
AXI-Lite config
  -> bias/weight/IFM AXIS or stream input
  -> IFM line buffer/window feeder
  -> systolic compute
  -> PSUM drain / ping-pong partial sum
  -> requant
  -> activation
  -> OFM writeback
  -> OFM AXIS/full-stream sink
```

顶层 golden 数据生成：

- IFM: `feat[ch][y][x] = ((ch * 3 + y * 5 + x * 2) % 9) - 4`
- Weight: `weight[k][co] = ((k * 2 + co * 3) % 7) - 3`
- Bias: `bias[co] = co - 9`
- Golden: 遍历 `K_TOTAL`，按 `stride/pad` 计算 3x3 convolution，再做 `clamp8`
- Quant: 当前顶层配置为 identity，`mult=1, shift=0, zp=0`

## 顶层测试

### `tb_conv_accel_core_axi_lite_axis_stream_smoke`

目的：

- 验证 AXI-Lite + bias/weight/IFM AXIS + OFM AXIS 的最小端到端主链路。
- 使用 5x5 feature map、`COLS=2`、`COUT_TOTAL=4`、单 tile。

检查项：

- AXI-Lite 配置写入和启动完成。
- bias/weight/IFM stream 服务次数符合预期。
- IFM window feeder、compute fire、PSUM write 数量符合预期。
- OFM byte 写入数量为 `num_pixels * cout_total`。
- OFM AXIS `TLAST` 数量和 debug 计数正确。
- 输出逐 pixel、逐 channel 与 golden 对比。
- bias/weight/IFM AXIS `TKEEP/TLAST` error 为 0。

当前结果：

- `57 pass, 0 fail`

### `tb_conv_accel_core_axi_lite_axis_stream_ps_driver`

目的：

- 验证更接近 PS 驱动方式的 AXI-Lite + 全 AXIS 顶层。
- 覆盖 8x8 feature map、3 个 spatial tile、`COUT_TOTAL=18`。
- 覆盖 `K_TOTAL > ROWS` 的多 K pass，以及 `COUT_TOTAL > COUT_TILE` 的多 COUT block。

检查项：

- 3 个 tile 的 start/done/clear 流程。
- 每个 tile 的 bias/weight/line fill 服务次数。
- 多 K pass partial sum 累加和最终输出。
- 多 COUT block 的 `cout_base` 切换和最后 block mask。
- 每个 tile 的 OFM `TLAST`。
- 所有 tile 输出拼接到 HWC 地址后与 golden 对比。

当前结果：

- `1169 pass, 0 fail`

### `tb_conv_accel_core_axi_lite_axis_stream_backpressure`

目的：

- 在 AXI OFM 输出端主动拉低 `m_axis_tready`，验证 OFM AXIS 背压链路。
- 与 PS driver 场景同样覆盖 8x8、3 tile、multi-pass 和 multi-COUT。

检查项：

- 确认 OFM ready stall 真的被触发。
- 背压期间不丢 byte、不重复 byte、不提前 `TLAST`。
- `debug_core_wr_count`、`debug_axis_wr_count`、`debug_tlast_count` 和 `debug_last_tlast_index` 正确。
- 背压后最终 HWC 输出仍与 golden 一致。

当前结果：

- `1170 pass, 0 fail`

### `tb_conv_accel_core_axi_lite_full_stream_backpressure`

目的：

- 验证 full-stream wrapper 的 OFM ready 背压。
- 覆盖 8x8、3 tile、multi-pass 和 multi-COUT。

检查项：

- 确认 OFM ready stall 真的被触发。
- IFM full-stream line loader 写入 bank 数据正确。
- 背压后 OFM 写回数量和最终 golden 对比正确。

当前结果：

- `1166 pass, 0 fail`

### `tb_conv_accel_core_axi_lite_axis_stream_r16_c16_smoke`

目的：

- 验证 `ROWS=16, COLS=16` 参数化场景。
- 强化不同 array shape 下的 K pass、COUT tile 和 stream 连接。

检查项：

- 输出数量、服务次数、AXIS debug 计数。
- Golden 输出逐项对比。

当前结果：

- `217 pass, 0 fail`

### `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_smoke`

目的：

- 验证非 9/16/32 整齐关系的 `ROWS=18, COLS=16`。
- 使用 `IFM_BANKS=2`，覆盖不同 IFM bank 映射。

检查项：

- K pass 与 bank/channel 映射。
- 输出数量、AXIS debug 计数、golden 对比。

当前结果：

- `217 pass, 0 fail`

### `tb_conv_accel_core_axi_lite_axis_stream_r32_c16_smoke`

目的：

- 验证 `ROWS=32, COLS=16` 参数化场景。
- 覆盖较宽 ROWS 下的 feeder 到 systolic FIFO stagger。

检查项：

- 输出数量、服务次数、AXIS debug 计数。
- Golden 输出逐项对比。

当前结果：

- `217 pass, 0 fail`

## 关键模块测试

### `tb_ofm_activation`

目的：

- 验证 activation 模块在 bypass、ReLU、LUT 模式下的数据和 metadata 对齐。
- 验证 back-to-back packet 与下游 backpressure。

检查项：

- `out_addr`、`out_cout_base`、`out_channel_valid` 与 data 同周期对齐。
- full-throughput 连续 3 packet 不错位。
- `out_ready=0` 时保持输出稳定，`in_ready=0`。
- LUT 模式按写入 LUT 转换。

当前结果：

- `204 pass, 0 fail`

### `tb_ofm_requant_writer`

目的：

- 验证 PSUM packet 到 INT8 OFM packet 的 requant 流水。
- 验证连续 packet 下 metadata 和 quantized data 对齐。

检查项：

- signed multiply、round、shift、zero-point、saturation 与 testbench golden 一致。
- back-to-back packet 输出顺序正确。
- packet 地址、`cout_base`、channel mask 不错位。

当前结果：

- `44 pass, 0 fail`

### `tb_ofm_writeback`

目的：

- 验证 OFM packet 展开成 HWC byte write。
- 验证最后 lane 同周期 push 时 `busy` 不提前掉低。

检查项：

- 地址公式：`(pixel_base + pixel_idx) * cout_total + (cout_base + lane)`。
- channel mask 屏蔽无效 lane。
- `wr_ready=0` 时保持 lane，恢复后继续写。
- final-lane same-cycle push 后 `busy` 保持，后续 packet 不丢。

当前结果：

- `24 pass, 0 fail`

### `tb_axi_lite_cfg_bridge`

目的：

- 验证 AXI-Lite bridge 写/读握手、partial write 和 busy 保护。

检查项：

- AW/W 同时到达、分离到达、W-first 到达。
- CTRL partial write 不把 status 位错误合并成 start/clear side effect。
- `layer_busy=1` 时 start 被忽略，配置寄存器冻结。
- idle 后 start 和配置写入正常生效。

当前结果：

- `46 pass, 0 fail`

### `tb_layer_config_regs`

目的：

- 验证配置寄存器本体的 busy freeze 和 start/done 行为。

检查项：

- busy 时 FM/K/activation/tile/pixel 配置不被改写。
- busy 时 start pulse 被忽略。
- busy 时 clear done 仍可工作。
- idle 时配置和 start 正常接受。

当前结果：

- `31 pass, 0 fail`

### `tb_axis_ifm_line_loader`

目的：

- 验证 IFM line AXIS loader 的行写入协议。

检查项：

- `fill_req` 后 ready 拉高。
- 一行 `fm_w` 个 beat，每 beat 写所有 bank。
- `TKEEP` 和 `TLAST` 错误检测。
- `fm_w=0` 时不进入活跃状态，不误写。

当前结果：

- `58 pass, 0 fail`

## 回归命令

单个 xsim 顶层：

```powershell
vivado -mode batch -source tcl/run_xsim_regression.tcl -tclargs -top tb_conv_accel_core_axi_lite_axis_stream_backpressure
```

多个顶层建议用 PowerShell 循环逐个传入 `-top`：

```powershell
$tops = @(
  'tb_conv_accel_core_axi_lite_axis_stream_ps_driver',
  'tb_conv_accel_core_axi_lite_axis_stream_backpressure',
  'tb_conv_accel_core_axi_lite_full_stream_backpressure'
)
foreach ($top in $tops) {
  vivado -mode batch -source tcl/run_xsim_regression.tcl -tclargs -top $top
  if ($LASTEXITCODE -ne 0) { throw "xsim failed for $top" }
}
```

## 当前仍未覆盖的风险

- 顶层数据仍是 deterministic directed pattern，不是大规模随机 workload。
- OFM 背压目前是固定长度 stall，不是长时间随机 `tready` 抖动。
- Quant 顶层仍使用 identity 参数，尚未在完整顶层覆盖复杂 `mult/shift/zp` 组合。
- 当前没有综合后门级仿真，也没有形式验证。
- FIFO 深度与实际 DMA/DDR 最大 stall 的关系仍需要结合系统时序和带宽评估。

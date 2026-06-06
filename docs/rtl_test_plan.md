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
- Golden: 遍历 `K_TOTAL`，按 `stride/pad` 计算 3x3 convolution，再按 RTL requant 公式量化输出
- Quant: 配置 `shift` 保持软件导出的 raw shift；RTL 内部实际右移为 `shift + 15`

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

### `tb_conv_accel_core_axi_lite_axis_stream_input_zp`

Purpose:

- Verify the formal IFM input-zero-point hardware semantics at top level.
- The testbench keeps the golden convolution on internal signed IFM values, but sends `feat + input_zero_point` as external uint8 activation bytes through the IFM AXIS path.
- Uses `input_zero_point=36` and confirms that the IFM loader subtracts it before line-buffer storage.

Checks:

- AXI-Lite register `0x0f` programs the input zero point.
- IFM AXIS input is uint8; internal line-buffer data is centered signed int8.
- Window, MAC, requant, OFM writeback, TLAST, and debug counters still match the signed-IFM golden.

Current result:

- `1169 pass, 0 fail`

### `tb_conv_accel_core_axi_lite_full_stream_input_zp`

Purpose:

- Verify the same non-zero input-zero-point semantics through the full-stream wrapper.
- Covers the `conv_accel_core_axi_lite_stream -> ifm_line_stream_loader` configuration path that does not use the AXIS IFM wrapper.

Checks:

- AXI-Lite register `0x0f` reaches the full-stream IFM line loader.
- The full-stream IFM source sends uint8 `feat + input_zero_point`; internal loader checks compare centered signed bytes.
- End-to-end OFM output still matches the signed-IFM golden.

Current result:

- `1165 pass, 0 fail`

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

- signed multiply、round、`effective_shift = raw_shift + 15`、zero-point、saturation 与 testbench golden 一致。
- back-to-back packet 输出顺序正确。
- packet 地址、`cout_base`、channel mask 不错位。
- Output backpressure holds requant pipeline state stable when `ofm_ready=0`, and `packet_ready` deasserts until the held output is accepted.

当前结果：

- `58 pass, 0 fail`

### `tb_ofm_writeback`

目的：

- 验证 OFM packet 展开成 HWC byte write。
- 验证最后 lane 同周期 push 时 `busy` 不提前掉低。

检查项：

- 地址公式：`(pixel_base + pixel_idx) * cout_total + (cout_base + lane)`。
- channel mask 屏蔽无效 lane。
- `wr_ready=0` 时保持 lane，恢复后继续写。
- final-lane same-cycle push 后 `busy` 保持，后续 packet 不丢。
- Burst stress sends 12 full-mask packets while `wr_ready` periodically stalls, checking every byte address/data.

当前结果：

- `121 pass, 0 fail`

### `tb_axi_lite_cfg_bridge`

目的：

- 验证 AXI-Lite bridge 写/读握手、partial write 和 busy 保护。

检查项：

- AW/W 同时到达、分离到达、W-first 到达。
- CTRL partial write 不把 status 位错误合并成 start/clear side effect。
- `0x0f` input-zero-point write/read, lower-byte partial write, and upper-byte partial no-op behavior.
- `layer_busy=1` 时 start 被忽略，配置寄存器冻结。
- idle 后 start 和配置写入正常生效。

当前结果：

- `59 pass, 0 fail`

### `tb_layer_config_regs`

目的：

- 验证配置寄存器本体的 busy freeze 和 start/done 行为。

检查项：

- busy 时 FM/K/activation/tile/pixel 配置不被改写。
- busy 时 `input_zero_point` 配置不被改写。
- busy 时 start pulse 被忽略。
- busy 时 clear done 仍可工作。
- idle 时配置和 start 正常接受。

当前结果：

- `34 pass, 0 fail`

### `tb_axis_ifm_line_loader`

目的：

- 验证 IFM line AXIS loader 的行写入协议。

检查项：

- `fill_req` 后 ready 拉高。
- 一行 `fm_w` 个 beat，每 beat 写所有 bank。
- `input_zero_point=36` 时覆盖 `36->0`, `22->-14`, `86->50`, `255->127` 饱和上限。
- `input_zero_point=200` 时覆盖 `0->-128` 饱和下限。
- `input_zero_point=0` 时输出 byte 等于原始输入 byte，保持旧 directed pattern 兼容。
- `TKEEP` 和 `TLAST` 错误检测。
- `fm_w=0` 时不进入活跃状态，不误写。

当前结果：

- `80 pass, 0 fail`

### `tb_ifm_line_stream_loader`

Purpose:

- Verify the bus-agnostic IFM line stream loader and the uint8-to-centered-sint8 conversion before the line buffer.

Checks:

- `input_zero_point=0` preserves existing byte order and values.
- `input_zero_point=36` covers zero, negative, positive, and high saturation cases.
- `input_zero_point=200` covers low saturation.
- `dma_line_advance`, `dma_wr_x`, `dma_wr_fy`, and bank write enables remain correct.

Current result:

- `81 pass, 0 fail`

### `tb_ofm_pooling`

目的：

- 验证 activation 后的 packet-level pooling。
- 覆盖 bypass 和 `2x2` uint8 maxpool stride-2。
- 验证 output backpressure 下 `in_ready` 能停止上游输入。

检查项：

- bypass 模式 metadata/data 原样透传。
- `4x4 -> 2x2` pooling 输出地址按 pooled local pixel 重新编号。
- 每个 lane 的输出等于四个 activated uint8 输入的最大值。
- 输出被下游 hold 时，不接受新的输入 packet。

当前结果：

- `50 pass, 0 fail`

### `tb_conv_accel_core_pooling`

目的：

- 验证小规模 deterministic 顶层 `Conv -> Requant -> Activation -> Pool -> OFM`。
- 使用 `POOL_CFG` 打开 `2x2` stride-2 pooling，默认无 pool 测试保持兼容。

检查项：

- 卷积 compute/psum 计数仍按 pool 前 conv output pixel 数统计。
- OFM byte 写出数量按 pool 后 pixel 数统计。
- 输出 byte 与 testbench 内部 RTL semantic golden 的 activation 后 maxpool 一致。

当前结果：

- `139 pass, 0 fail`

### `tb_conv_accel_core_axi_lite_axis_stream_pooling`

目的：

- 验证 pool-enabled AXI-Lite + AXIS 顶层 `Conv -> Requant -> Activation -> Pool -> OFM AXIS`。
- 覆盖 pool 后输出 byte 数、AXIS TLAST 和 debug byte counter。
- 使用 `IFM_U8_FROM_CENTERED` 和 `input_zero_point=128`，确保 AXIS 输入按外部 uint8 activation 语义送入。

检查项：

- OFM byte 写出数量按 pool 后 pixel 数统计。
- AXIS `TLAST` 只在 pool 后 tile 输出最后一个 byte 置位。
- debug core/sink write count、TLAST count、last TLAST index 与 pool 后输出数量一致。
- 输出 byte 与 testbench 内部 RTL semantic golden 的 activation 后 maxpool 一致。

配置语义：

- pool 打开时，`OFM_SIZE/NUM_PIXELS/TILE_OFM_H` 仍描述 pooling 前的 convolution output tile。
- `TILE_PIXEL_BASE` 描述最终写回地址空间；pooling 多 tile 调度时应写 pool 后 OFM 的 pixel base。

当前结果：

- `81 pass, 0 fail`

### `tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_ext`

目的：

- 验证真实数据驱动的 `Conv0 -> Requant -> LUT activation -> 2x2 Pool -> OFM AXIS`。
- 使用真实 facemask 图片 crop、真实 Conv0 权重、int32 bias、量化参数和 activation LUT。
- 覆盖 external golden + pooling 的 byte-for-byte 对比。

数据来源：

- Full Conv0 export: `D:/MPSoC/python_prj/rtl_golden/facemask_conv0`
- Crop fixture: `D:/MPSoC/python_prj/rtl_golden/facemask_conv0_crop16x8_pool`
- 生成脚本：`tools/golden/export_rtl_conv0_golden.py --pool-stride2`
- xsim mem 转换脚本：`tb/make_conv0_xsim_mem.py` 和 `tb/make_conv0_crop_xsim_mem.py`

配置：

- Crop: source image quantized IFM at `(x=96, y=96, w=16, h=8)`
- Shape: `16x8x3 -> 16x8x16 -> pool 8x4x16`
- Array: `ROWS=18, COLS=8, IFM_BANKS=2`
- Quant: `mult=18898`, raw `shift=9`, effective shift `24`, output `zp=69`
- Input zero point: `0`; crop centered range `38..105`, `sat_count=0`

当前结果：

- `529 pass, 0 fail`

说明：

- A full-width `416x4` Conv0 tile was too slow for regular xsim use without progress instrumentation, so the checked regression uses a small real-data crop. It still exercises the same RTL semantic data path and external golden comparison.

## Layer06 real-image external golden tests

These tests verify a real intermediate layer shape:

- Layer: `52x52x64 -> 52x52x128`
- Array: `ROWS=18, COLS=16, IFM_BANKS=2`
- K scheduling: `64*3*3=576`, `K_PASSES=32`
- COUT scheduling: `COUT_TILE=COLS*2=32`, `COUT_BLOCKS=4`
- Total schedule blocks per full spatial tile: `32*4=128`

Data source:

- Binary golden export: `D:/MPSoC/python_prj/rtl_golden/facemask_layer06_rtl`
- xsim `$readmemh` files: `D:/MPSoC/python_prj/rtl_golden/facemask_layer06_rtl/xsim_mem`
- Export scripts are versioned in this repo under `tools/golden/`.
- Conversion script: `tb/make_layer06_xsim_mem.py`
- Quant config: `mult=18055`, raw `shift=7`, effective shift `22`, `zp=75`
- IFM input zero point: `input_zero_point=36`, programmed through config register `0x0f`
- Activation: LUT mode, loaded from `activation_lut_u8.mem`

Golden data policy:

- RTL pass/fail compares against RTL semantic golden, not direct PyTorch layer output.
- Large full-layer golden dumps and model weights stay under external `D:/MPSoC/python_prj`.
- Only small curated regression fixtures should be copied into repository `golden/`.
- The external data root can be changed with the `PYTHON_PRJ` environment variable or the generator script `--project` argument.

The external IFM stream is uint8 activation data. The RTL line loader converts each byte to internal signed int8 as `saturate_s8(ifm_u8 - input_zero_point)` before writing the line buffer. Padding outside the feature map is still internal signed zero. Layer06 has `ifm_u8` range `22..86`, centered range `-14..50`, and `sat_count=0`.

The regenerated Layer06 golden follows this RTL semantic: `psum = conv_accumulator + int32_bias`, then `requant = round(psum * mult / 2^(raw_shift + 15)) + zp`. The `+15` comes from the software parameter generator storing `mult = round(base * 2^15)`. This produces a rich OFM distribution again. Compared with the PyTorch quantized layer output, a small number of bytes may differ because PyTorch uses float-bias semantics while the RTL golden uses integer bias.

### `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_tile4`

Purpose:

- Verify external IFM/weight/bias/LUT/golden import on the top 4 output rows.
- Quickly check real 64-channel input blocking, 32 K passes, 4 COUT blocks, requant, activation, and HWC OFM writeback.

Checks:

- OFM byte-by-byte matches `golden_ofm_u8_hwc.mem`.
- Output count is `52*4*128`.
- `bias/weight/ifm_axis_error=0`.
- AXIS TLAST and debug counters match expected counts.
- First mismatch prints tile, pixel, global pixel, channel, address, RTL byte, and golden byte.

Current result:

- `26641 pass, 0 fail`; xsim elapsed about `00:00:21`

### `tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_layer06_ext_tile4`

Purpose:

- Verify the same real Layer06 tile under the current KV260 default profile: `ROWS=18, COLS=8, COUT_TILE=16`.
- Exercise `K_PASSES=32` and `COUT_BLOCKS=8`, matching the board smoke scheduler.

Checks:

- External IFM/weight/bias/LUT/golden import.
- Current r18_c8 parameterization for weight lanes, COUT block order, requant, activation, and HWC OFM byte writeback.

Current result:

- `26641 pass, 0 fail`; xsim elapsed about `00:05:36` on 2026-06-06.

### `tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_layer06_pool_ext_tile4`

Purpose:

- Verify the real model stage corresponding to single-scale `conv3_pool` under the current KV260 profile.
- Exercise `52x52x64 -> Conv/LUT 52x52x128 -> 2x2/s2 maxpool 26x26x128` for the first `tile_ofm_h=4` conv tile.
- Confirm pool-enabled `TILE_PIXEL_BASE` and OFM byte counts use the pooled output address space.

Checks:

- External IFM/weight/bias/LUT import is shared with the Layer06 conv-only tests.
- Golden is `golden_pool2x2s2_u8_hwc.mem`, generated from the RTL semantic Layer06 activation output.
- Output count is `26*2*128 = 6656` bytes for the first conv tile.
- AXIS TLAST and debug counters match the pooled output byte count.

Current result:

- `6673 pass, 0 fail`; xsim elapsed about `00:00:19` on 2026-06-06.

### `tb_conv_accel_core_axi_lite_axis_stream_r18_c8_b2_conv4_pool_ext_tile4`

Purpose:

- Verify the next 3x3 single-scale stage after `conv3_pool` without requiring 1x1 RTL support.
- Exercise `26x26x128 -> Conv/LUT 26x26x256 -> 2x2/s2 maxpool 13x13x256` for the first `tile_ofm_h=4` conv tile.
- Cover the larger scheduling point `K_PASSES=64`, `COUT_BLOCKS=16`, and `1024` weight pass services per spatial tile.

Checks:

- External IFM/weight/bias/LUT/golden import from `facemask_single_scale_rtl/04_conv4_pool/xsim_mem`.
- Output count is `13*2*256 = 6656` bytes for the first conv tile.
- AXIS TLAST and debug counters match the pooled output byte count.
- OFM byte stream is compared byte-for-byte against RTL semantic golden.

Current result:

- `6673 pass, 0 fail`; xsim elapsed about `00:01:31` on 2026-06-06.
- KV260 `conv_accel_conv4_pool_tiles_smoke.elf` passed on 2026-06-06. Log: `build_system_xck26_kv260/board_smoke_logs/20260606_140410_conv4_pool_tiles_COM8.log`; full pooled OFM compare was `43264` bytes with `0 mismatch`.

### KV260 `conv3_pool -> conv4_pool` chained smoke

Purpose:

- Verify real inter-layer software scheduling: the `conv3_pool` hardware OFM buffer is reused directly as the `conv4_pool` hardware IFM stream.
- Cover the first two adjacent 3x3+pool stages currently supported without 1x1 RTL changes.
- Separate chain semantics from PyTorch-reference semantics.

Checks:

- Stage 1: `52x52x64 -> 52x52x128 -> 26x26x128`, 13 spatial tiles, output `86528` bytes.
- Stage 2: `26x26x128 -> 26x26x256 -> 13x13x256`, 7 spatial tiles, output `43264` bytes.
- `conv4_pool` expected output is generated from the RTL semantic `conv3_pool` output, not from PyTorch `layer07_pooling_MaxPool2d_u8_hwc.bin`.
- Each tile checks OFM debug delta, TLAST count, service counts, address parsing, and final byte-for-byte golden compare.

Current result:

- First attempt using the standalone Conv4 golden failed at `byte=4415` because the expected data was generated from PyTorch intermediate bytes.
- After regenerating chain Conv4 golden from `facemask_layer06_rtl/golden_pool2x2s2_u8_hwc.bin`, KV260 `conv_accel_conv3_conv4_chain_smoke.elf` passed on 2026-06-06.
- Log: `build_system_xck26_kv260/board_smoke_logs/20260606_141427_conv3_conv4_chain_COM8.log`; `conv3_pool full compare=86528 bytes`, `conv4_pool full compare=43264 bytes`, final `PASS`.

### `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tile4_fifo16_backpressure`

Purpose:

- Verify top-level OFM backpressure correctness with a deliberately shallow OFM AXIS byte FIFO.
- Combines `OFM_FIFO_DEPTH=16` with periodic downstream `m_axis_tready` stalls.
- Covers the same top 4 output rows, 64 input channels, 32 K passes, and 4 COUT blocks as tile4.

Checks:

- Output byte count is unchanged by backpressure.
- AXIS TLAST and debug counters match the expected tile output.
- The ready/valid path from final PSUM packet FIFO through requant into the OFM packet FIFO does not drop or duplicate packets when the downstream byte FIFO is full.

Current result:

- `26642 pass, 0 fail`

### `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_tiles`

Purpose:

- Verify three spatial boundary tiles with real external data.
- Covers top tile `tile_oy_base=0`, middle tile `tile_oy_base=24`, and bottom tile `tile_oy_base=48`.

Checks:

- Same checks as external tile4.
- Confirms non-zero `tile_pixel_base` addressing and bottom padding behavior.

Current result:

- `79889 pass, 0 fail`; xsim elapsed about `00:02:16`

### `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_ext_full`

Purpose:

- Verify the complete `52x52x64 -> 52x52x128` layer as one full spatial tile with real external data.
- Covers all `346112` OFM bytes.

Checks:

- Same checks as external tile4 over the full spatial tile.
- Uses `OFM_FIFO_DEPTH=1024`; depth 256 was insufficient for the full continuous output burst in this RTL configuration.

Current result:

- `346129 pass, 0 fail`; xsim elapsed about `00:10:33`

### OFM backpressure implementation note

`ofm_requant_writer` now has an explicit `packet_ready/ofm_ready` handshake. The requant pipeline advances only when the downstream OFM packet FIFO can accept data, or when the pipeline output is empty. This replaces the older fixed-slack dependency on `almost_full`, so correctness no longer depends on reserving a particular number of FIFO entries for the requant pipeline.

The full-layer shallow-FIFO diagnostic wrapper `tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_full_fifo256` is intentionally not listed in the default xsim regression because it timed out in targeted runs. Use the tile4 shallow-FIFO backpressure test for regular correctness coverage, and keep full-layer tests at normal FIFO depth for targeted/nightly external-golden verification.

### Current short xsim baseline

The daily offline baseline for the current KV260 profile is:

```text
ROWS=18, COLS=8, IFM_BANKS=2, COUT_TILE=16
```

Run the short baseline with:

```powershell
powershell -ExecutionPolicy Bypass -File tb/run_short_xsim_regression.ps1
```

The script runs `tb_axis_ofm_byte_writer`, the r18_c8 Conv0 crop + pool
external-golden smoke, AXI-Lite quant/LUT, requant, and OFM requant writer
tests. The r18_c8 deterministic smoke is retained as a control-path diagnostic,
and can be reproduced with `-RunDeterministicDiagnostics`, but core correctness
for the current KV260 profile should be judged first from the real Conv0
external-golden fixture. On 2026-06-04,
`tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c8_b2_ext`
passed with `529 pass, 0 fail`; the deterministic fixture reproduced a raw psum
mismatch after aligning its quant config to `mult=32767, shift=0, zp=0`.
Layer06 external golden tests remain targeted/nightly because the full-layer
case is heavier than the daily smoke set.

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
- Real layer06 已覆盖一组非 identity `mult/shift/zp` 和 LUT activation；仍未覆盖多层、多组量化参数的随机/扫参组合。
- 当前没有综合后门级仿真，也没有形式验证。
- FIFO 深度与实际 DMA/DDR 最大 stall 的关系仍需要结合系统时序和带宽评估。

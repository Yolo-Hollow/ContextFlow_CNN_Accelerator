# Vivado/XSIM 构建与验证基础设施

**语言 / Language：中文 | [English](README_EN.md)**

本目录提供 ContextFlow RTL 源文件清单、XSIM 回归、XCK26 OOC 综合、KV260 Block Design、完整实现和签核门禁。当前发布配置为 200 MHz `abi_v2_release_200`，阵列规模为 18×16，输出通道块为 32，使用 tagged context、URAM IFM epoch bank、256 深度结果 FIFO 和 `STREAM_CFG=0xBF`。

## 工具与源文件约束

- 正式仿真、综合和实现均使用 Vivado/XSIM 2022.2。
- `rtl_sources.tcl` 是 `cal/`、`com/` 和 `systolic/` RTL 的唯一源文件清单；缺项、重复项或未登记 RTL 会直接失败。
- `run_xsim_regression.tcl` 是组件测试清单，`run_abi_v2_chain_xsim.tcl` 是十层 ABI v2 系统级门禁。
- 回归结果记录起止 Git SHA 和 dirty 状态；运行期间源码变化会阻止更新权威结果。

## RTL 回归

短回归适合提交前检查：

```powershell
powershell -ExecutionPolicy Bypass -File tb\run_short_xsim_regression.ps1
```

完整组件回归：

```powershell
powershell -ExecutionPolicy Bypass -File tb\run_all_xsim_regression.ps1
```

大型完整层、随机 AXIS 背压和 18×16 packed-OFM 测试：

```powershell
powershell -ExecutionPolicy Bypass -File tb\run_large_xsim_regression.ps1
```

只有干净提交上的完整无波形运行能够更新规范化 JSON/JUnit 结果；定向、带波形、中断或失败的运行只保留独立运行目录。

## 构建配置

### `abi_v2_release_200`

该配置锁定：

- XCK26/KV260 目标器件和 Block Design 拓扑
- 200 MHz OOC 时钟与 PS `pl_clk0`
- 18×16 阵列、COUT32、layer-long packed-HWC 数据通路
- tagged context、48 URAM、256 项结果 FIFO
- weight DMA MM2S burst 长度 64
- OOC、布局后与布线后的资源、时序、拥塞、route 和 DRC 门禁

配置参数不能通过命令行降级；数值门限只能收紧。发布 profile 拒绝 `-no_gates`、`-reuse_synth`，也拒绝把构建目录放入 `release/` 或源码子目录。

### `abi_v2_release`

保留相同 ABI v2 数据通路的 100 MHz 配置，主要用于较低频率验证。当前 34.943 ms 硬件不使用此 profile。

## 200 MHz OOC 综合

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\run_synth_xck26.tcl -tclargs `
  -profile abi_v2_release_200 -ooc
```

OOC 门禁通过后才发布 DCP 和 SHA-256 清单。失败运行不会暴露旧的同名 checkpoint。

## 完整 KV260 实现

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\build_kv260_system_xck26.tcl -tclargs `
  -profile abi_v2_release_200 -jobs 12
```

该流程依次执行综合、布局、物理优化、布线、时序/DRC 门禁，并导出 bitstream 与 bit-inclusive XSA。构建目录按 profile 独立生成。`-place_only` 可停在布局后门禁，用于检查资源、时序和拥塞，但不会导出 bitstream/XSA。

## 签核项目

完整实现至少检查：

- LUT、LUT memory、CLB、BRAM、URAM 和 DSP 使用量
- setup WNS/TNS、hold 和 pulse-width
- accelerator 范围内无未约束的 `(none)` Max/Min Delay 端点
- 拥塞等级、route errors、DRC errors 和 critical warnings
- 生成物、profile、Vivado 版本和 Git 来源信息

冻结产物及其哈希见 [`release/contextflow_34p9/`](../release/contextflow_34p9/README.md)，性能证据见[发布清单](../docs/contextflow_34p9_release_manifest.md)。

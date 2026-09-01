# ContextFlow 34.943 ms KV260 硬件

**语言 / Language：中文 | [English](README_EN.md)**

本目录包含仓库完整双尺度 YOLOv3-tiny 结果所使用的 200 MHz XCK26/KV260 签核硬件。

| 产物 | SHA-256 |
| --- | --- |
| `conv_accel_ps_dma_minimal.xsa` | `42d761b1cc77f1a7988d40dd71f0a1c7e1987a057bc457c7d5b55613637e3030` |
| `conv_accel_ps_dma_wrapper.bit` | `1ac606a279d60290935f32c5bc1a028b017d6cca4f22e623bd0bbb4baa3a613e` |

硬件身份为 `abi_v2_release_200`：200 MHz、18×16 阵列，每个折叠输出通道块包含 32 个输出通道。

JTAG、SD 卡冷启动和 WebUI 推理方法见仓库[中文快速启动指南](../../README.md#快速启动与复现)，权威测量记录见[中文发布清单](../../docs/contextflow_34p9_release_manifest.md)。

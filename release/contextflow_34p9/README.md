# ContextFlow 34.943 ms KV260 hardware

This directory contains the signed 200 MHz XCK26/KV260 hardware used for the complete dual-scale YOLOv3-tiny result reported by this repository.

| Artifact | SHA-256 |
| --- | --- |
| `conv_accel_ps_dma_minimal.xsa` | `42d761b1cc77f1a7988d40dd71f0a1c7e1987a057bc457c7d5b55613637e3030` |
| `conv_accel_ps_dma_wrapper.bit` | `1ac606a279d60290935f32c5bc1a028b017d6cca4f22e623bd0bbb4baa3a613e` |

Hardware identity: `abi_v2_release_200`, 200 MHz, 18x16 array, 32 output channels per folded block.

Use the repository [Chinese README](../../README.md#快速启动与复现) or [English README](../../README_EN.md#quick-start-and-reproduction) for JTAG startup, SD-card cold boot, and WebUI inference instructions. Canonical measurements are recorded in the [release manifest](../../docs/contextflow_34p9_release_manifest.md).

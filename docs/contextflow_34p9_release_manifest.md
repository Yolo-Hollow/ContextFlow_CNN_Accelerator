# ContextFlow 34.9 ms 发布清单

**语言 / Language：中文 | [English](contextflow_34p9_release_manifest_EN.md)**

## 基准性能结果

本文档采用完整常驻推理测量作为主要结果：

- 常驻推理平均延迟：**34.942764 ms**，正文取 **34.943 ms**
- 常驻推理 P95：**34.964939 ms**
- 吞吐率：**28.618 FPS**
- PL 平均延迟：**33.607297 ms**
- 有效吞吐率：**165.588 GOPS**
- 阵列利用率：**71.87%**
- 测量规模：3 次独立运行，每次 20 次预热和 1000 张计时图像

机器可读的权威来源为 `repro/evidence/contextflow_34p9_evidence.json`。

以下相近数值采用不同测量范围，不能替代上述主要结果：

- **34.978146 ms** 是 `repro/evidence/contextflow_ablation.json` 中 `0xBF` 受控消融的最后阶段。

## 硬件身份

机器可读证据记录的是 200 MHz `abi_v2_release_200` 实现：

- XSA SHA-256：`42d761b1cc77f1a7988d40dd71f0a1c7e1987a057bc457c7d5b55613637e3030`
- bitstream SHA-256：`1ac606a279d60290935f32c5bc1a028b017d6cca4f22e623bd0bbb4baa3a613e`

对应文件位于 `release/contextflow_34p9/`：

- `conv_accel_ps_dma_minimal.xsa`
- `conv_accel_ps_dma_wrapper.bit`

## 证据位置

性能、消融和同板 CPU 证据位于 `repro/evidence/`。最终预印本位于 `output/pdf/ContexFlow_preprint_thesis.pdf`。

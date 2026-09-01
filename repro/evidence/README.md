# ContextFlow 冻结证据

**语言 / Language：中文 | [English](README_EN.md)**

本目录保存公开发布所需的机器可读证据，不包含论文 LaTeX 工程、生成表格或内部开发日志。

| 文件 | 内容 | SHA-256 |
| --- | --- | --- |
| `contextflow_34p9_evidence.json` | 200 MHz 硬件身份、精度、正确性、3×1000 性能、稳定性与功耗摘要 | `edab9989710a1863a6b821af81801e444a36894d641e97f7628f79a433257fdf` |
| `contextflow_ablation.json` | `0x2B/0x3B/0x3F/0xBF` 受控消融及层级对照 | `a9483de37eef526035b49b3bd2aced1ca45640cbc1634e9ee11183b25862d7c0` |
| `kv260_cpu_baseline.json` | KV260 四核 Cortex-A53 NEON 同板参考结果 | `2d8d82bba346e48772990a59475160271347e530dca2a431315d3eee20de2703` |

主要发布口径为 `contextflow_34p9_evidence.json` 中的完整常驻推理结果：平均延迟 34.943 ms、28.618 FPS、165.588 GOPS 和 71.87% 阵列利用率。消融中的 34.978 ms 采用不同测量范围，不能替代主要结果。

# ContextFlow Frozen Evidence

**Language / 语言: [中文](README.md) | English**

This directory contains the machine-readable evidence needed by the public release. It excludes LaTeX authoring projects, generated paper tables, and internal development logs.

| File | Contents | SHA-256 |
| --- | --- | --- |
| `contextflow_34p9_evidence.json` | 200 MHz hardware identity, accuracy, correctness, 3x1000 performance, stability, and power summary | `edab9989710a1863a6b821af81801e444a36894d641e97f7628f79a433257fdf` |
| `contextflow_ablation.json` | Controlled `0x2B/0x3B/0x3F/0xBF` ablation and layer-level comparisons | `a9483de37eef526035b49b3bd2aced1ca45640cbc1634e9ee11183b25862d7c0` |
| `kv260_cpu_baseline.json` | Same-board four-core Cortex-A53 NEON reference | `2d8d82bba346e48772990a59475160271347e530dca2a431315d3eee20de2703` |

The headline release scope is the complete resident inference result in `contextflow_34p9_evidence.json`: 34.943 ms mean latency, 28.618 FPS, 165.588 GOPS, and 71.87% array utilization. The 34.978 ms ablation value has a different measurement scope and does not replace the headline result.

# LASA 中文期刊长文工程

本目录是 LASA 新版期刊论文的独立、可复现中文初稿。它与本机
`Master_Thesis_Template/` 中的旧 100 MHz、18x8、单尺度毕业论文材料隔离，
不会把旧结果误写入新版摘要或最终性能表。

## 当前状态

- 已绑定 r5、200 MHz、18x16/COUT32 的正式实现报告。
- 已绑定 128 张逐节点 byte-exact、5000 张 raw-head 与 A53 product COCO 评测、
  3x1000 性能和 600 s 稳定性结果。
- 当前部署的 epoch-1 INT8 模型用于功能与硬件正确性论证；其精度未达到
  模型发布门限，论文不会将量化包装为创新或无损量化。
- 受控消融、同板 CPU 基线和公开 artifact 自检仍是投稿冻结前硬条件。
  正文和表格会明确标记这些缺口。

## 生成证据与编译

在仓库根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File paper/lasa_journal_cn/build.ps1
```

脚本会：

1. 运行 `scripts/collect_evidence.py`，重新读取仓库内正式报告和外部 COCO
   评测摘要；
2. 生成 LaTeX 表格和 `generated/evidence_manifest.json`；
3. 运行投稿冻结审计的 draft 模式，核对来源/生成文件 SHA256、九张图、
   参考文献数量和摘要禁用表述；
4. 用 XeLaTeX/BibTeX 编译；
5. 将稳定输出复制到 `output/pdf/LASA_journal_cn_draft.pdf`。

如果外部 COCO 结果目录不可用，生成器会使用已冻结的
`data/evidence_snapshot.json`，并在 evidence manifest 中将来源标为
`snapshot`，不会静默伪装成现场重读结果。

严格投稿冻结检查使用：

```powershell
python paper/lasa_journal_cn/scripts/check_submission_freeze.py `
  --paper-root paper/lasa_journal_cn
```

该命令当前应当 fail-close，并列出尚未完成的四类硬门禁。只有这些状态全部
由可重算证据更新为 `PASS` 后，才允许移除首页“内部证据稿”标识。

## 目录

- `main.tex`：期刊稿入口。
- `sections/`：九节正文。
- `figures/`：九张矢量示意图的 TikZ 源。
- `scripts/collect_evidence.py`：报告/JSON 到表格的唯一数据入口。
- `scripts/check_submission_freeze.py`：证据完整性与投稿冻结硬门禁。
- `data/evidence_snapshot.json`：当前已核验结果快照及来源哈希/路径。
- `generated/`：由脚本生成且可审计的表格和证据清单。
- `references.bib`：论文参考文献库。
- `SUBMISSION_FREEZE_CHECKLIST.md`：投稿冻结门禁。

## 数据口径

- MAC 计数：2.782480896 GMAC；按乘加等于两次运算报告 5.564961792 GOP。
- 阵列理论峰值：576 MAC/cycle x 200 MHz = 115.2 GMAC/s = 230.4 GOPS。
- 主性能口径：3 次独立运行，每次 20 warmup + 1000 timed。
- `resident` 不含 SD、TCP 和 UART；`pipeline` 包含当前网络分块传输开销。
- 已从正式 routed DCP 提取 Vivado `post-route estimated` 功耗：整芯片
  4.008 W（动态 3.695 W、静态 0.313 W），在 25 ℃ 环境假设下估算结温
  34.3 ℃。该结果采用 vectorless 12.5% toggle rate、0.5 static probability，
  未加载 SAIF，置信度为 Medium；它不是板级实测功耗。

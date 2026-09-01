# LASA 学术叙事版

本目录是面向学术阅读的独立稿件。`paper/lasa_journal_cn` 继续作为内部证据稿，
保存实验状态、复现说明和完整工程证据；本目录只引用其中已验证的数值宏和
参考文献，不显示项目管理状态或构建协议。

构建命令：

```powershell
powershell -ExecutionPolicy Bypass -File paper/lasa_journal_cn_academic/build.ps1
```

输出固定为 `output/pdf/LASA_journal_cn_academic_twocolumn.pdf`。构建后检查：

- 16--18 页双栏版式；
- 无期刊身份信息和工程状态词；
- 两项贡献、核心公式和关键实验数字均可从 PDF 文本检索；
- 引用只包含正文实际使用的文献。

正式插图当前以带图题的占位框表示，设计说明见
`notes/visual_briefs.md`。搁置实验见 `notes/deferred_experiments.md`，二者均不
进入 PDF。

# LASA 中性双栏期刊版式预览

本目录把 `paper/lasa_journal_cn` 中的 LASA 中文长文排入
`D:\paper\CHINESE_JC_Template` 提供的双栏版式。它只借用模板的 A4 页面、字号、
页边距、栏宽、标题层级、图表和 GB/T 7714 参考文献格式，不呈现模板原刊的刊名、
卷期、DOI、收稿信息、版权声明、作者履历或英文 Background 等身份元素。

正文、图、表和证据数据仍以 `paper/lasa_journal_cn` 为唯一来源；这里不复制
一套容易失步的正文。后续修改原稿后，重新构建即可得到同步预览。

## 构建

在仓库根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File paper/lasa_journal_cn_cjc_preview/build.ps1
```

构建脚本会：

1. 检查原模板和 LASA 正文依赖；
2. 运行原稿的 draft evidence audit；
3. 通过 `TEXINPUTS/BSTINPUTS` 直接使用指定模板中的 `CjC.cls`、样式和
   `gbt7714-numerical.bst`；
4. 使用 XeLaTeX 编译；
5. 检查 PDF 文本中不存在原刊身份信息；
6. 将稳定文件写入
   `output/pdf/LASA_journal_cn_neutral_twocolumn_preview.pdf`。

构建依赖 MiKTeX 的 `sttools` 包所提供的正式 `flushend.sty`。正文采用双栏，
首屏题名与中英文摘要跨双栏，宽图和宽表继续使用双栏浮动体，末页由
`flushend` 平衡栏高。

缺少该依赖时，可先执行：

```powershell
miktex packages update-package-database
miktex packages install sttools
```

这是一份内部排版预览，不代表向任何期刊投稿或获得其授权/接收。

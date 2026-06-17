# LaTeXMK 配置：强制使用 XeLaTeX + BibTeX
$xelatex = 'xelatex -interaction=nonstopmode -synctex=1 %O %S';
$bibtex = 'bibtex %O %S';
$pdf_mode = 5;
$postscript_mode = 0;
$dvi_mode = 0;

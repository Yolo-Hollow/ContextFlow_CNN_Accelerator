param(
    [string]$TemplateRoot = 'D:\paper\CHINESE_JC_Template'
)

$ErrorActionPreference = 'Stop'
$PaperRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $PaperRoot '..\..')).Path
$EvidenceRoot = Join-Path $RepoRoot 'paper\lasa_journal_cn'
$BuildDir = Join-Path $PaperRoot 'build'
$OutputDir = Join-Path $RepoRoot 'output\pdf'
$FinalPdf = Join-Path $OutputDir 'LASA_journal_cn_academic_twocolumn.pdf'

foreach ($required in @(
    (Join-Path $TemplateRoot 'CjC.cls'),
    (Join-Path $TemplateRoot 'picins.sty'),
    (Join-Path $TemplateRoot 'gbt7714-numerical.bst'),
    (Join-Path $EvidenceRoot 'references.bib'),
    (Join-Path $EvidenceRoot 'generated\evidence_macros.tex'),
    (Join-Path $PaperRoot 'main.tex')
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required input is missing: $required"
    }
}

New-Item -ItemType Directory -Force -Path $BuildDir,$OutputDir | Out-Null
Copy-Item -LiteralPath (Join-Path $EvidenceRoot 'references.bib') `
    -Destination (Join-Path $BuildDir 'references.bib') -Force
Copy-Item -LiteralPath (Join-Path $PaperRoot 'references_academic.bib') `
    -Destination (Join-Path $BuildDir 'references_academic.bib') -Force

$oldTexInputs = $env:TEXINPUTS
$oldBstInputs = $env:BSTINPUTS
$env:TEXINPUTS = "$TemplateRoot;$PaperRoot;$EvidenceRoot;$oldTexInputs"
$env:BSTINPUTS = "$TemplateRoot;$oldBstInputs"

Push-Location $PaperRoot
try {
    & latexmk -xelatex -interaction=nonstopmode -halt-on-error `
        "-outdir=$BuildDir" main.tex
    if ($LASTEXITCODE -ne 0) { throw 'Academic manuscript LaTeX build failed.' }
} finally {
    Pop-Location
    $env:TEXINPUTS = $oldTexInputs
    $env:BSTINPUTS = $oldBstInputs
}

Copy-Item -LiteralPath (Join-Path $BuildDir 'main.pdf') -Destination $FinalPdf -Force
& python (Join-Path $PaperRoot 'scripts\check_academic_pdf.py') `
    --paper-root $PaperRoot --pdf $FinalPdf
if ($LASTEXITCODE -ne 0) { throw 'Academic manuscript audit failed.' }

$item = Get-Item -LiteralPath $FinalPdf
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $FinalPdf).Hash.ToLowerInvariant()
Write-Output "PDF=$FinalPdf"
Write-Output "BYTES=$($item.Length)"
Write-Output "SHA256=$hash"

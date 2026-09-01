param(
    [string]$TemplateRoot = 'D:\paper\CHINESE_JC_Template'
)

$ErrorActionPreference = 'Stop'
$PreviewRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $PreviewRoot '..\..')).Path
$SourceRoot = Join-Path $RepoRoot 'paper\lasa_journal_cn'
$BuildDir = Join-Path $PreviewRoot 'build'
$OutputDir = Join-Path $RepoRoot 'output\pdf'
$MainTex = Join-Path $PreviewRoot 'main.tex'

foreach ($required in @(
    (Join-Path $TemplateRoot 'CjC.cls'),
    (Join-Path $TemplateRoot 'picins.sty'),
    (Join-Path $TemplateRoot 'gbt7714-numerical.bst'),
    (Join-Path $SourceRoot 'main.tex'),
    (Join-Path $SourceRoot 'references.bib'),
    $MainTex
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required source is missing: $required"
    }
}

& python (Join-Path $SourceRoot 'scripts\check_submission_freeze.py') `
    --paper-root $SourceRoot --draft
if ($LASTEXITCODE -ne 0) { throw 'Canonical LASA draft audit failed.' }

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Copy-Item -LiteralPath (Join-Path $SourceRoot 'references.bib') `
    -Destination (Join-Path $BuildDir 'references.bib') -Force

$oldTexInputs = $env:TEXINPUTS
$oldBstInputs = $env:BSTINPUTS
$env:TEXINPUTS = "$TemplateRoot;$PreviewRoot;$oldTexInputs"
$env:BSTINPUTS = "$TemplateRoot;$oldBstInputs"

Push-Location $PreviewRoot
try {
    & latexmk -xelatex -interaction=nonstopmode -halt-on-error `
        "-outdir=$BuildDir" main.tex
    if ($LASTEXITCODE -ne 0) { throw 'Neutral CjC-layout LaTeX build failed.' }
} finally {
    Pop-Location
    $env:TEXINPUTS = $oldTexInputs
    $env:BSTINPUTS = $oldBstInputs
}

$BuiltPdf = Join-Path $BuildDir 'main.pdf'
$FinalPdf = Join-Path $OutputDir 'LASA_journal_cn_neutral_twocolumn_preview.pdf'
Copy-Item -LiteralPath $BuiltPdf -Destination $FinalPdf -Force

& python (Join-Path $PreviewRoot 'scripts\check_preview_pdf.py') $FinalPdf
if ($LASTEXITCODE -ne 0) { throw 'Neutral publication-identity PDF audit failed.' }

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $FinalPdf).Hash.ToLowerInvariant()
$size = (Get-Item -LiteralPath $FinalPdf).Length
Write-Output "PDF=$FinalPdf"
Write-Output "BYTES=$size"
Write-Output "SHA256=$hash"

param(
    [switch]$SkipEvidence
)

$ErrorActionPreference = 'Stop'
$PaperRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $PaperRoot '..\..')).Path
$BuildDir = Join-Path $PaperRoot 'build'
$OutputDir = Join-Path $RepoRoot 'output\pdf'

if (-not $SkipEvidence) {
    & python (Join-Path $PaperRoot 'scripts\collect_evidence.py') `
        --repo-root $RepoRoot `
        --paper-root $PaperRoot
    if ($LASTEXITCODE -ne 0) { throw 'Evidence generation failed.' }
}

& python (Join-Path $PaperRoot 'scripts\check_submission_freeze.py') `
    --paper-root $PaperRoot --draft
if ($LASTEXITCODE -ne 0) { throw 'Draft evidence audit failed.' }

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Push-Location $PaperRoot
try {
    & latexmk -xelatex -interaction=nonstopmode -halt-on-error `
        "-outdir=$BuildDir" main.tex
    if ($LASTEXITCODE -ne 0) { throw 'LaTeX build failed.' }
} finally {
    Pop-Location
}

$BuiltPdf = Join-Path $BuildDir 'main.pdf'
$FinalPdf = Join-Path $OutputDir 'LASA_journal_cn_draft.pdf'
Copy-Item -LiteralPath $BuiltPdf -Destination $FinalPdf -Force
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $FinalPdf).Hash.ToLowerInvariant()
$size = (Get-Item -LiteralPath $FinalPdf).Length
Write-Output "PDF=$FinalPdf"
Write-Output "BYTES=$size"
Write-Output "SHA256=$hash"

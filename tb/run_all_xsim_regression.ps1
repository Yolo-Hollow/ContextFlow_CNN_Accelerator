param(
    [string] $Vivado = "C:\Xilinx\Vivado\2022.2\bin\vivado.bat",
    [string] $Python = "python",
    [switch] $IncludeDiagnostics,
    [switch] $NormalOnly,
    [switch] $CheckOnly,
    [switch] $Waves,
    [string[]] $Top
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

if (-not (Test-Path -LiteralPath $Vivado)) {
    throw "Vivado launcher not found: $Vivado"
}
if ($NormalOnly -and $IncludeDiagnostics) {
    throw "-NormalOnly and -IncludeDiagnostics are mutually exclusive"
}

$tclArgs = @()
# run_all means the complete 160-pass plus one-exact-xfail release gate.  The
# legacy -IncludeDiagnostics switch remains accepted for command compatibility.
if (-not $NormalOnly) {
    $tclArgs += "-include_diagnostic"
}
if ($CheckOnly) {
    $tclArgs += "-check_only"
}
if ($Waves) {
    $tclArgs += "-waves"
}
if ($Top.Count -gt 0) {
    $tclArgs += "-top"
    $tclArgs += ($Top -join ",")
}

$buildDir = Join-Path $root "build_xsim"
$runTag = "{0}_{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss_fff"), $PID
$reportDir = Join-Path $buildDir "regression_reports\$runTag"
$resultJson = Join-Path $reportDir "regression_results.json"
$resultJunit = Join-Path $reportDir "regression_results.junit.xml"
# Vivado keeps Tee-Object's destination open for the whole regression.  Give
# every invocation its own driver log so a read-only manifest check or a
# targeted diagnostic can run while a long release regression is active.
$driverLog = Join-Path $buildDir "xsim_regression_driver_$runTag.log"
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$tclArgs += @(
    "-result_json", $resultJson,
    "-result_junit", $resultJunit,
    "-driver_log", $driverLog
)

Push-Location $root
try {
    if (-not $CheckOnly) {
        & $Python tb/prepare_xsim_fixtures.py
        if ($LASTEXITCODE -ne 0) {
            throw "XSIM fixture generation failed"
        }
    }
    & $Vivado -mode batch -source tcl/run_xsim_regression.tcl `
        -tclargs @tclArgs 2>&1 | Tee-Object -FilePath $driverLog
    $vivadoExitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($vivadoExitCode -ne 0) {
    Write-Host "XSIM JSON: $resultJson"
    Write-Host "XSIM JUnit: $resultJunit"
    Write-Host "XSIM driver log: $driverLog"
    throw "XSIM regression completed with failures"
}

if ($CheckOnly) {
    Write-Host "=== XSIM manifest check passed ==="
} else {
    if (-not (Test-Path -LiteralPath $resultJson)) {
        throw "XSIM completed without its per-run JSON result: $resultJson"
    }
    $runResult = Get-Content -LiteralPath $resultJson -Raw | ConvertFrom-Json
    if ($runResult.release_gate_passed -eq $true) {
        Write-Host "=== full XSIM release regression passed and canonical result published ==="
        Write-Host "Canonical JSON: $(Join-Path $buildDir 'regression_results.json')"
        Write-Host "Canonical JUnit: $(Join-Path $buildDir 'regression_results.junit.xml')"
    } else {
        Write-Host "=== selected XSIM regression passed; canonical result unchanged ==="
    }
    Write-Host "XSIM JSON: $resultJson"
    Write-Host "XSIM JUnit: $resultJunit"
    Write-Host "XSIM driver log: $driverLog"
}

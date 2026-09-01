param(
    [string]$Vivado = "C:\Xilinx\Vivado\2022.2\bin\vivado.bat",
    [ValidateRange(0, 9)] [int]$StartLayer = 0,
    [ValidateRange(0, 9)] [int]$StopLayer = 9,
    [ValidateSet("03", "0B", "2B", "3B", "3F", "BF")]
    [string]$StreamCfg = "BF",
    [switch]$TracePixel0,
    [switch]$Waves,
    [switch]$FastDsp,
    [switch]$CheckOnly,
    [switch]$SkipFixtureGeneration
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

if ($StartLayer -gt $StopLayer) {
    throw "StartLayer must be <= StopLayer"
}
if (-not (Test-Path -LiteralPath $Vivado)) {
    throw "Vivado 2022.2 launcher not found: $Vivado"
}

if ($SkipFixtureGeneration) {
    & python "$PSScriptRoot\prepare_xsim_fixtures.py" --check-only
} else {
    & python "$PSScriptRoot\prepare_xsim_fixtures.py"
}
if ($LASTEXITCODE -ne 0) {
    throw "repository-local XSIM fixture preparation failed"
}

$TclArgs = @(
    "-start_layer", $StartLayer,
    "-stop_layer", $StopLayer,
    "-stream_cfg", "0x$StreamCfg"
)
if ($Waves) {
    $TclArgs += "-waves"
}
if ($FastDsp) {
    $TclArgs += "-fast_dsp"
}
if ($TracePixel0) {
    $TclArgs += "-trace_pixel0"
}
if ($CheckOnly) {
    $TclArgs += "-check_only"
}

Push-Location $RepoRoot
try {
    & $Vivado -mode batch -source tcl/run_abi_v2_chain_xsim.tcl `
        -tclargs @TclArgs
    if ($LASTEXITCODE -ne 0) {
        throw "ABI-v2 release chain XSIM failed"
    }
} finally {
    Pop-Location
}

if ($CheckOnly) {
    Write-Host "ABI-v2 release chain preflight passed"
} else {
    Write-Host "ABI-v2 release chain XSIM passed for layers $StartLayer..$StopLayer"
}

param(
    [string]$Vivado = "C:\Xilinx\Vivado\2022.2\bin\vivado.bat",
    [switch]$IncludeEndpoints
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Runner = Join-Path $PSScriptRoot "run_abi_v2_chain_xsim.ps1"
$CanonicalJson = Join-Path $Root "build_xsim\abi_v2_chain_results.json"
$CanonicalJunit = Join-Path $Root "build_xsim\abi_v2_chain_results.junit.xml"
$Configs = if ($IncludeEndpoints) {
    @("03", "0B", "2B", "3B", "3F", "BF")
} else {
    @("0B", "2B", "3B", "3F")
}

function Get-OptionalSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return "ABSENT"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

$CanonicalJsonBefore = Get-OptionalSha256 $CanonicalJson
$CanonicalJunitBefore = Get-OptionalSha256 $CanonicalJunit

Push-Location $Root
try {
    foreach ($Config in $Configs) {
        Write-Host "=== Conv9 staged ABI v2 XSIM STREAM_CFG=0x$Config ==="
        & powershell -NoProfile -ExecutionPolicy Bypass -File $Runner `
            -Vivado $Vivado -StartLayer 9 -StopLayer 9 `
            -StreamCfg $Config -SkipFixtureGeneration
        if ($LASTEXITCODE -ne 0) {
            throw "Conv9 staged ABI v2 XSIM failed at STREAM_CFG=0x$Config"
        }
    }
} finally {
    Pop-Location
}
$CanonicalJsonAfter = Get-OptionalSha256 $CanonicalJson
$CanonicalJunitAfter = Get-OptionalSha256 $CanonicalJunit
if ($CanonicalJsonBefore -ne $CanonicalJsonAfter -or
    $CanonicalJunitBefore -ne $CanonicalJunitAfter) {
    throw "staged Conv9 runs modified the canonical ten-layer result"
}
Write-Host "PASS: staged ABI v2 Conv9 XSIM configs=$($Configs -join ',')"
Write-Host "Canonical ten-layer JSON/JUnit remained unchanged"

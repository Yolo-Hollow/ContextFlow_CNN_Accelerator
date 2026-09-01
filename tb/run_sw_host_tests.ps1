param(
    [string]$Compiler = "gcc"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Include = Join-Path $Root "sw\vitis_2022_2\src"
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) "accelerator_systolic_sw_host_tests"
New-Item -ItemType Directory -Force $OutputRoot | Out-Null

$Tests = @(
    "test_accel_abi_v2.c",
    "test_accel_runtime_v2.c"
)

foreach ($Test in $Tests) {
    $Source = Join-Path $PSScriptRoot $Test
    $Exe = Join-Path $OutputRoot (([System.IO.Path]::GetFileNameWithoutExtension($Test)) + ".exe")
    & $Compiler -std=c11 -Wall -Wextra -Werror -I $Include $Source -o $Exe
    if ($LASTEXITCODE -ne 0) {
        throw "Host compile failed: $Test"
    }
    & $Exe
    if ($LASTEXITCODE -ne 0) {
        throw "Host test failed: $Test"
    }
}

python -m unittest (Join-Path $PSScriptRoot "test_generate_abi_v2_parameter_package.py")
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 parameter package test failed"
}

python -m unittest (Join-Path $PSScriptRoot "test_abi_v2_candidate_artifacts.py")
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 candidate artifact binding test failed"
}

python -m unittest (Join-Path $PSScriptRoot "test_abi_v2_board_signoff.py")
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 board signoff parser test failed"
}

python -m unittest (Join-Path $PSScriptRoot "test_abi_v2_board_functional.py")
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 development functional parser test failed"
}

python -m unittest (Join-Path $PSScriptRoot "test_abi_v2_board_performance.py")
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 development performance parser test failed"
}

python -m unittest (Join-Path $PSScriptRoot "test_abi_v2_board_soak.py")
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 board soak parser test failed"
}

Write-Host "PASS: all ABI v2 software host tests"

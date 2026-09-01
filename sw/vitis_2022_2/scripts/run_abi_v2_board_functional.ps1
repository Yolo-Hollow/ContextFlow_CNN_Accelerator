param(
    [Parameter(Mandatory = $true)]
    [string]$PortName,
    [int]$BaudRate = 115200,
    [int]$CaptureSeconds = 300,
    [string]$Workspace = "",
    [string]$ArtifactManifest = "",
    [string]$BitFile = "",
    [string]$Elf = "",
    [string]$ParameterPackageDir = "",
    [string]$OutputDir = "",
    [ValidateSet(125000000, 200000000)]
    [long]$ExpectedClockHz = 125000000,
    [ValidateSet("0x2B", "0x3B", "0x3F", "0xBF")]
    [string]$ExpectedStreamCfg = "0xBF"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SwDir = Split-Path -Parent $ScriptDir
$Root = Split-Path -Parent (Split-Path -Parent $SwDir)
$IsRelease200 = $ExpectedClockHz -eq 200000000
$ExpectedProfile = if ($IsRelease200) {
    "abi_v2_release_200"
} else {
    "abi_v2_frequency_sweep_125"
}
$ExpectedReleaseEligible = $IsRelease200
$ExpectedStreamCfgValue = [Convert]::ToInt32($ExpectedStreamCfg.Substring(2), 16)
$StreamCfgTag = $ExpectedStreamCfg.Substring(2).ToLowerInvariant()
$HardwareBuild = if ($IsRelease200) {
    $null
} else {
    Join-Path $Root "build_system_abi_v2_frequency_sweep_125"
}

if (!$IsRelease200 -and $ExpectedStreamCfgValue -ne 0xBF) {
    throw "125 MHz development functional requires ExpectedStreamCfg=0xBF"
}
if ($IsRelease200 -and $ExpectedStreamCfgValue -notin @(0x2B, 0x3B, 0x3F, 0xBF)) {
    throw "200 MHz release functional requires staged STREAM_CFG=0x2B/0x3B/0x3F/0xBF"
}

if ([string]::IsNullOrWhiteSpace($Workspace)) {
    if ($IsRelease200) {
        throw "200 MHz release functional requires an explicit hash-bound Workspace"
    }
    $Workspace = Join-Path $Root "build_vitis_2022_2_abi_v2_candidate_125_functional"
}
if ([string]::IsNullOrWhiteSpace($ArtifactManifest)) {
    $ArtifactManifest = Join-Path $Workspace "abi_v2_candidate_manifest.json"
}
if ([string]::IsNullOrWhiteSpace($BitFile)) {
    if ($IsRelease200) {
        throw "200 MHz release functional requires an explicit r5 BitFile"
    }
    $BitFile = Join-Path $HardwareBuild "conv_accel_ps_dma_minimal\conv_accel_ps_dma_minimal.runs\impl_1\conv_accel_ps_dma_wrapper.bit"
}
if ([string]::IsNullOrWhiteSpace($Elf)) {
    $Elf = Join-Path $Workspace "conv_accel_abi_v2_candidate\manual_build\conv_accel_abi_v2_candidate.elf"
}
if ([string]::IsNullOrWhiteSpace($ParameterPackageDir)) {
    $ParameterPackageDir = Join-Path $Root "build_abi_v2_parameters"
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    if ($IsRelease200) {
        throw "200 MHz release functional requires an explicit OutputDir"
    }
    $OutputDir = Join-Path $HardwareBuild "board_functional_logs"
}

$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$ArtifactManifest = [System.IO.Path]::GetFullPath($ArtifactManifest)
$BitFile = [System.IO.Path]::GetFullPath($BitFile)
$Elf = [System.IO.Path]::GetFullPath($Elf)
$ParameterPackageDir = [System.IO.Path]::GetFullPath($ParameterPackageDir)
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$BiasFile = Join-Path $ParameterPackageDir "abi_v2_bias_cout32.bin"
$WeightFile = Join-Path $ParameterPackageDir "abi_v2_weight_cout32.bin"
$Xsct = "C:\Xilinx\Vitis\2022.2\bin\xsct.bat"
$DownloadTcl = Join-Path $ScriptDir "download_run_accel_smoke.tcl"
$Verifier = Join-Path $ScriptDir "abi_v2_candidate_artifacts.py"
$FunctionalParser = Join-Path $Root "tools\demo\abi_v2_board_functional.py"

foreach ($Required in @(
    $ArtifactManifest, $BitFile, $Elf, $BiasFile, $WeightFile,
    $Xsct, $DownloadTcl, $Verifier, $FunctionalParser
)) {
    if (!(Test-Path -LiteralPath $Required -PathType Leaf)) {
        throw "Required functional input not found: $Required"
    }
}
if ($CaptureSeconds -le 0 -or $BaudRate -le 0) {
    throw "CaptureSeconds and BaudRate must be positive"
}
$AvailablePorts = [System.IO.Ports.SerialPort]::GetPortNames()
if ($PortName -notin $AvailablePorts) {
    throw "UART port $PortName is not present; available ports: $($AvailablePorts -join ', ')"
}
$HwServerListener = Get-NetTCPConnection -LocalPort 3121 -State Listen `
    -ErrorAction SilentlyContinue
if ($null -eq $HwServerListener) {
    throw "hw_server must already be listening on tcp:127.0.0.1:3121"
}

& python $Verifier verify --manifest $ArtifactManifest --phase run `
    --expect-workspace $Workspace --expect-bit $BitFile --expect-elf $Elf `
    --expect-bias $BiasFile --expect-weight $WeightFile `
    --expect-clock-hz $ExpectedClockHz
if ($LASTEXITCODE -ne 0) {
    throw "Functional artifact verification failed"
}
$Candidate = Get-Content -LiteralPath $ArtifactManifest -Raw | ConvertFrom-Json
if ($Candidate.state -ne "complete" -or
    $Candidate.release_eligible -ne $ExpectedReleaseEligible -or
    $Candidate.hardware.profile -ne $ExpectedProfile -or
    $Candidate.hardware.release_eligible -ne $ExpectedReleaseEligible -or
    $Candidate.hardware.clock_hz -ne $ExpectedClockHz -or
    $Candidate.runtime.clock_hz -ne $ExpectedClockHz -or
    $Candidate.software.long_stream_runtime_enabled -ne 1 -or
    $Candidate.software.stream_cfg -ne $ExpectedStreamCfgValue -or
    $Candidate.software.performance_mode -ne $false -or
    $Candidate.software.benchmark_runs -ne 0 -or
    $Candidate.software.clock_hz -ne $ExpectedClockHz -or
    $Candidate.software.run_mode -ne "functional" -or
    $Candidate.software.soak_seconds -ne 0 -or
    $Candidate.software.soak_temp_limit_millic -ne 0) {
    throw "Candidate manifest does not match the requested staged functional identity"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Log = Join-Path $OutputDir "${Stamp}_abi_v2_${ExpectedClockHz}hz_stream${StreamCfgTag}_functional_${PortName}.log"
$Json = Join-Path $OutputDir "${Stamp}_abi_v2_${ExpectedClockHz}hz_stream${StreamCfgTag}_functional_${PortName}.json"

$Reader = {
    param($PortName, $BaudRate, $CaptureSeconds, $Log)
    $port = New-Object System.IO.Ports.SerialPort $PortName,$BaudRate,None,8,one
    $port.ReadTimeout = 200
    $window = ""
    try {
        $port.Open()
        $port.DiscardInBuffer()
        $deadline = (Get-Date).AddSeconds($CaptureSeconds)
        while ((Get-Date) -lt $deadline) {
            $text = $port.ReadExisting()
            if ($text.Length -ne 0) {
                Add-Content -LiteralPath $Log -Value $text -NoNewline
                $window += $text
                if ($window.Length -gt 8192) {
                    $window = $window.Substring($window.Length - 8192)
                }
                if ($window -match "PASS: ABI v2 ten-layer four-DMA dispatch complete" -or
                    $window -match "FAIL:") {
                    Start-Sleep -Milliseconds 500
                    $tail = $port.ReadExisting()
                    if ($tail.Length -ne 0) {
                        Add-Content -LiteralPath $Log -Value $tail -NoNewline
                    }
                    return
                }
            }
            Start-Sleep -Milliseconds 50
        }
    } finally {
        if ($port.IsOpen) {
            $port.Close()
        }
    }
}

$Capture = Start-Job -ScriptBlock $Reader -ArgumentList @(
    $PortName, $BaudRate, $CaptureSeconds, $Log
)
Start-Sleep -Seconds 2
$XsctExit = -1
try {
    & $Xsct $DownloadTcl `
        -abi_version 2 `
        -workspace $Workspace `
        -platform_name conv_accel_abi_v2_candidate_platform `
        -artifact_manifest $ArtifactManifest `
        -bit_file $BitFile `
        -elf $Elf `
        -bias_file $BiasFile `
        -weight_file $WeightFile
    $XsctExit = $LASTEXITCODE
    Wait-Job -Job $Capture -Timeout ($CaptureSeconds + 10) | Out-Null
    if ($Capture.State -ne "Completed") {
        Stop-Job -Job $Capture
        throw "UART capture timed out before functional PASS/FAIL"
    }
    Receive-Job -Job $Capture | Out-Null
} finally {
    Remove-Job -Job $Capture -Force -ErrorAction SilentlyContinue
}
if ($XsctExit -ne 0) {
    throw "Functional XSCT download/run failed with exit code $XsctExit"
}

& python $FunctionalParser $Log --artifact-manifest $ArtifactManifest `
    --expected-clock-hz $ExpectedClockHz `
    --expected-stream-cfg $ExpectedStreamCfg `
    --json-out $Json
if ($LASTEXITCODE -ne 0) {
    throw "Staged functional gates failed; see $Log"
}
Write-Host "PASS: ABI v2 staged functional clock_hz=$ExpectedClockHz stream_cfg=$ExpectedStreamCfg"
Write-Host "UART log: $Log"
Write-Host "Result JSON: $Json"

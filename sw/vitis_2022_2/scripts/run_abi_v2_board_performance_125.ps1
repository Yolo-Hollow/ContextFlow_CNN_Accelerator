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
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"
$ExpectedClockHz = 125000000
$ExpectedRuns = 30
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SwDir = Split-Path -Parent $ScriptDir
$Root = Split-Path -Parent (Split-Path -Parent $SwDir)
$HardwareBuild = Join-Path $Root "build_system_abi_v2_frequency_sweep_125"

if ([string]::IsNullOrWhiteSpace($Workspace)) {
    $Workspace = Join-Path $Root "b125_perf_abi_v2_candidate"
}
if ([string]::IsNullOrWhiteSpace($ArtifactManifest)) {
    $ArtifactManifest = Join-Path $Workspace "abi_v2_candidate_manifest.json"
}
if ([string]::IsNullOrWhiteSpace($BitFile)) {
    $BitFile = Join-Path $HardwareBuild "conv_accel_ps_dma_minimal\conv_accel_ps_dma_minimal.runs\impl_1\conv_accel_ps_dma_wrapper.bit"
}
if ([string]::IsNullOrWhiteSpace($Elf)) {
    $Elf = Join-Path $Workspace "conv_accel_abi_v2_candidate\manual_build\conv_accel_abi_v2_candidate.elf"
}
if ([string]::IsNullOrWhiteSpace($ParameterPackageDir)) {
    $ParameterPackageDir = Join-Path $Root "build_abi_v2_parameters"
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $HardwareBuild "board_performance_logs"
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
$PerformanceParser = Join-Path $Root "tools\demo\abi_v2_board_performance.py"

foreach ($Required in @(
    $ArtifactManifest, $BitFile, $Elf, $BiasFile, $WeightFile,
    $Xsct, $DownloadTcl, $Verifier, $PerformanceParser
)) {
    if (!(Test-Path -LiteralPath $Required -PathType Leaf)) {
        throw "Required 125 MHz performance input not found: $Required"
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
    throw "125 MHz performance artifact verification failed"
}
$Candidate = Get-Content -LiteralPath $ArtifactManifest -Raw | ConvertFrom-Json
if ($Candidate.state -ne "complete" -or
    $Candidate.release_eligible -ne $false -or
    $Candidate.hardware.profile -ne "abi_v2_frequency_sweep_125" -or
    $Candidate.hardware.release_eligible -ne $false -or
    $Candidate.runtime.clock_hz -ne $ExpectedClockHz -or
    $Candidate.software.long_stream_runtime_enabled -ne 1 -or
    $Candidate.software.stream_cfg -ne 191 -or
    $Candidate.software.performance_mode -ne $true -or
    $Candidate.software.benchmark_runs -ne $ExpectedRuns -or
    $Candidate.software.clock_hz -ne $ExpectedClockHz -or
    $Candidate.software.run_mode -ne "benchmark" -or
    $Candidate.software.soak_seconds -ne 0 -or
    $Candidate.software.soak_temp_limit_millic -ne 0) {
    throw "Runner requires a non-release 125 MHz BF performance candidate with exactly 30 measured runs"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Log = Join-Path $OutputDir "${Stamp}_abi_v2_125mhz_performance30_${PortName}.log"
$Json = Join-Path $OutputDir "${Stamp}_abi_v2_125mhz_performance30_${PortName}.json"

$Reader = {
    param($PortName, $BaudRate, $CaptureSeconds, $Log, $ExpectedRuns)
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
                if ($window -match "ABI_V2_RUN_END index=$ExpectedRuns warmup=0") {
                    Start-Sleep -Milliseconds 500
                    $tail = $port.ReadExisting()
                    if ($tail.Length -ne 0) {
                        Add-Content -LiteralPath $Log -Value $tail -NoNewline
                    }
                    return
                }
                if ($window -match "FAIL:") {
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
    $PortName, $BaudRate, $CaptureSeconds, $Log, $ExpectedRuns
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
        throw "UART capture timed out before ABI_V2_RUN_END index=$ExpectedRuns"
    }
    Receive-Job -Job $Capture | Out-Null
} finally {
    Remove-Job -Job $Capture -Force -ErrorAction SilentlyContinue
}
if ($XsctExit -ne 0) {
    throw "125 MHz performance XSCT download/run failed with exit code $XsctExit"
}

& python $PerformanceParser $Log --artifact-manifest $ArtifactManifest `
    --json-out $Json
if ($LASTEXITCODE -ne 0) {
    throw "125 MHz development performance validation failed; see $Log"
}
Write-Host "PASS: ABI v2 125 MHz development performance measured (non-release only)"
Write-Host "UART log: $Log"
Write-Host "Result JSON: $Json"

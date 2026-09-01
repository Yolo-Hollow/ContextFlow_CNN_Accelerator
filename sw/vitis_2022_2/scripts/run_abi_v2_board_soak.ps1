param(
    [string]$PortName = "COM8",
    [int]$BaudRate = 115200,
    [int]$CaptureSeconds = 750,
    [string]$Workspace = "",
    [string]$ArtifactManifest = "",
    [string]$BitFile = "",
    [string]$Elf = "",
    [string]$ParameterPackageDir = "",
    [string]$OutputDir = "",
    [ValidateRange(600, 86400)]
    [int]$ExpectedSeconds = 600,
    [ValidateSet(100000000, 200000000)]
    [long]$ExpectedClockHz = 200000000,
    [int]$TempLimitMilliC = 85000,
    [int]$MaxProgressGapMs = 15000
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SwDir = Split-Path -Parent $ScriptDir
$Root = Split-Path -Parent (Split-Path -Parent $SwDir)
$HardwareProfile = if ($ExpectedClockHz -eq 200000000) {
    "abi_v2_release_200"
} else {
    "abi_v2_release"
}
$HardwareBuild = Join-Path $Root "build_system_xck26_kv260_$HardwareProfile"

if ([string]::IsNullOrWhiteSpace($Workspace)) {
    $Workspace = Join-Path $Root "build_vitis_2022_2_abi_v2_candidate_soak"
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
    $OutputDir = Join-Path $HardwareBuild "board_soak_logs"
}

$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$ArtifactManifest = [System.IO.Path]::GetFullPath($ArtifactManifest)
$BitFile = [System.IO.Path]::GetFullPath($BitFile)
$Elf = [System.IO.Path]::GetFullPath($Elf)
$ParameterPackageDir = [System.IO.Path]::GetFullPath($ParameterPackageDir)
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
if ((Split-Path -Leaf $Workspace).ToLowerInvariant() -notlike "*soak*") {
    throw "Board soak requires an isolated workspace whose basename contains soak: $Workspace"
}
$BiasFile = Join-Path $ParameterPackageDir "abi_v2_bias_cout32.bin"
$WeightFile = Join-Path $ParameterPackageDir "abi_v2_weight_cout32.bin"
$Xsct = "C:\Xilinx\Vitis\2022.2\bin\xsct.bat"
$DownloadTcl = Join-Path $ScriptDir "download_run_accel_smoke.tcl"
$Verifier = Join-Path $ScriptDir "abi_v2_candidate_artifacts.py"
$SoakParser = Join-Path $Root "tools\demo\abi_v2_board_soak.py"

foreach ($Required in @(
    $ArtifactManifest, $BitFile, $Elf, $BiasFile, $WeightFile,
    $Xsct, $DownloadTcl, $Verifier, $SoakParser
)) {
    if (!(Test-Path -LiteralPath $Required -PathType Leaf)) {
        throw "Required ABI v2 board-soak input not found: $Required"
    }
}
if ($CaptureSeconds -lt $ExpectedSeconds + 60) {
    throw "CaptureSeconds must provide at least 60 seconds beyond ExpectedSeconds"
}
if ($TempLimitMilliC -ne 85000) {
    throw "The signed soak contract requires a strict 85000 mC limit"
}
if ($MaxProgressGapMs -le 0) {
    throw "MaxProgressGapMs must be positive"
}

& python $Verifier verify --manifest $ArtifactManifest --phase run `
    --expect-workspace $Workspace --expect-bit $BitFile --expect-elf $Elf `
    --expect-bias $BiasFile --expect-weight $WeightFile `
    --expect-clock-hz $ExpectedClockHz
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 soak artifact verification failed"
}
$Candidate = Get-Content -LiteralPath $ArtifactManifest -Raw | ConvertFrom-Json
if ($Candidate.state -ne "complete" -or
    $Candidate.software.long_stream_runtime_enabled -ne 1 -or
    $Candidate.software.stream_cfg -ne 191 -or
    $Candidate.software.performance_mode -ne $true -or
    $Candidate.software.benchmark_runs -ne 0 -or
    $Candidate.software.run_mode -ne "soak" -or
    $Candidate.software.soak_seconds -ne $ExpectedSeconds -or
    $Candidate.software.soak_temp_limit_millic -ne $TempLimitMilliC -or
    $Candidate.software.clock_hz -ne $ExpectedClockHz) {
    throw "Board soak requires a complete hash-bound soak ELF with matching duration, temperature, and clock contracts"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Log = Join-Path $OutputDir "${Stamp}_abi_v2_${ExpectedSeconds}s_soak_${PortName}.log"
$Json = Join-Path $OutputDir "${Stamp}_abi_v2_${ExpectedSeconds}s_soak_${PortName}.json"

$Reader = {
    param($PortName, $BaudRate, $CaptureSeconds, $Log)
    $port = New-Object System.IO.Ports.SerialPort $PortName,$BaudRate,None,8,one
    $port.ReadTimeout = 200
    $window = ""
    try {
        $port.Open()
        $deadline = (Get-Date).AddSeconds($CaptureSeconds)
        while ((Get-Date) -lt $deadline) {
            $text = $port.ReadExisting()
            if ($text.Length -ne 0) {
                Add-Content -LiteralPath $Log -Value $text -NoNewline
                $window += $text
                if ($window.Length -gt 8192) {
                    $window = $window.Substring($window.Length - 8192)
                }
                if ($window -match "PASS: ABI v2 soak complete" -or
                    $window -match "FAIL: ABI v2 soak") {
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
$XsctArgs = @(
    $DownloadTcl,
    "-abi_version", "2",
    "-workspace", $Workspace,
    "-platform_name", "conv_accel_abi_v2_candidate_platform",
    "-artifact_manifest", $ArtifactManifest,
    "-bit_file", $BitFile,
    "-elf", $Elf,
    "-bias_file", $BiasFile,
    "-weight_file", $WeightFile
)

try {
    & $Xsct @XsctArgs
    $XsctExit = $LASTEXITCODE
    Wait-Job -Job $Capture -Timeout ($CaptureSeconds + 10) | Out-Null
    if ($Capture.State -ne "Completed") {
        Stop-Job -Job $Capture
        throw "UART capture timed out before the soak completion record"
    }
    Receive-Job -Job $Capture | Out-Null
} finally {
    Remove-Job -Job $Capture -Force -ErrorAction SilentlyContinue
}
if ($XsctExit -ne 0) {
    throw "ABI v2 soak XSCT download/run failed with exit code $XsctExit"
}

& python $SoakParser $Log --json-out $Json `
    --expected-seconds $ExpectedSeconds `
    --expected-clock-hz $ExpectedClockHz `
    --temp-limit-millic $TempLimitMilliC `
    --max-progress-gap-ms $MaxProgressGapMs
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 board soak gates failed; see $Log"
}
Write-Host "PASS: ABI v2 KV260 $ExpectedSeconds-second board soak"
Write-Host "UART log: $Log"
Write-Host "Result JSON: $Json"

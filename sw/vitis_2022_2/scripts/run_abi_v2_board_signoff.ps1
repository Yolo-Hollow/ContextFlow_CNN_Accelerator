param(
    [string]$PortName = "COM8",
    [int]$BaudRate = 115200,
    [int]$CaptureSeconds = 900,
    [string]$Workspace = "",
    [string]$ArtifactManifest = "",
    [string]$BitFile = "",
    [string]$Elf = "",
    [string]$ParameterPackageDir = "",
    [string]$ImageFile = "",
    [string]$OutputDir = "",
    [ValidateSet(30, 100)]
    [int]$ExpectedRuns = 100,
    [int]$MaxUsExclusive = 30000,
    [int]$P95UsExclusive = 30000,
    [int]$MaxBusyCycles = 5400000,
    [int]$MaxBusyUs = 30000,
    [int]$MaxUnhiddenUs = 2500,
    [ValidateSet(100000000, 200000000)]
    [long]$ExpectedClockHz = 200000000
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
    $Workspace = Join-Path $Root "build_vitis_2022_2_abi_v2_candidate"
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
    $OutputDir = Join-Path $HardwareBuild "board_signoff_logs"
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
$SignoffParser = Join-Path $Root "tools\demo\abi_v2_board_signoff.py"

foreach ($Required in @(
    $ArtifactManifest, $BitFile, $Elf, $BiasFile, $WeightFile,
    $Xsct, $DownloadTcl, $SignoffParser
)) {
    if (!(Test-Path -LiteralPath $Required -PathType Leaf)) {
        throw "Required ABI v2 board-signoff input not found: $Required"
    }
}
if (![string]::IsNullOrWhiteSpace($ImageFile)) {
    $ImageFile = [System.IO.Path]::GetFullPath($ImageFile)
    if (!(Test-Path -LiteralPath $ImageFile -PathType Leaf)) {
        throw "DDR image package not found: $ImageFile"
    }
}
if ($CaptureSeconds -le 0) {
    throw "CaptureSeconds must be positive"
}

$Candidate = Get-Content -LiteralPath $ArtifactManifest -Raw | ConvertFrom-Json
if ($Candidate.state -ne "complete" -or
    $Candidate.software.long_stream_runtime_enabled -ne 1 -or
    $Candidate.software.stream_cfg -ne 191 -or
    $Candidate.software.performance_mode -ne $true -or
    $Candidate.software.benchmark_runs -ne $ExpectedRuns) {
    throw "Board signoff requires a complete 0xBF performance candidate with $ExpectedRuns timed runs"
}
$ClockHz = $Candidate.runtime.clock_hz
if ($null -eq $ClockHz -and $Candidate.hardware.profile -eq "abi_v2_release") {
    $ClockHz = 100000000
}
$ClockHz = [long]$ClockHz
$SoftwareClockHz = $Candidate.software.clock_hz
if ($null -eq $SoftwareClockHz -and
    $Candidate.hardware.profile -eq "abi_v2_release") {
    $SoftwareClockHz = 100000000
}
if ($ClockHz -ne $ExpectedClockHz -or
    [long]$SoftwareClockHz -ne $ClockHz) {
    throw "Board signoff candidate clock identity is missing or inconsistent"
}
foreach ($Gate in @(
    $MaxUsExclusive, $P95UsExclusive, $MaxBusyCycles, $MaxBusyUs,
    $MaxUnhiddenUs
)) {
    if ($Gate -le 0) {
        throw "Board signoff timing gates must be positive"
    }
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Log = Join-Path $OutputDir "${Stamp}_abi_v2_lt${MaxUsExclusive}us_${PortName}.log"
$Json = Join-Path $OutputDir "${Stamp}_abi_v2_lt${MaxUsExclusive}us_${PortName}.json"

$Reader = {
    param($PortName, $BaudRate, $CaptureSeconds, $Log, $ExpectedRuns)
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
                $window = ($window + $text)
                if ($window.Length -gt 4096) {
                    $window = $window.Substring($window.Length - 4096)
                }
                if ($window -match "ABI_V2_RUN_END index=$ExpectedRuns warmup=0") {
                    Start-Sleep -Milliseconds 500
                    $tail = $port.ReadExisting()
                    if ($tail.Length -ne 0) {
                        Add-Content -LiteralPath $Log -Value $tail -NoNewline
                    }
                    return
                }
                if ($window -match "FAIL: ABI v2 benchmark") {
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
if (![string]::IsNullOrWhiteSpace($ImageFile)) {
    $XsctArgs += @("-data_file", $ImageFile, "-data_address", "0x10000000")
}

try {
    & $Xsct @XsctArgs
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
    throw "ABI v2 XSCT download/run failed with exit code $XsctExit"
}

& python $SignoffParser $Log --json-out $Json `
    --expected-runs $ExpectedRuns `
    --max-us-exclusive $MaxUsExclusive --p95-us-exclusive $P95UsExclusive `
    --max-busy-cycles $MaxBusyCycles `
    --max-busy-us $MaxBusyUs --max-unhidden-us $MaxUnhiddenUs `
    --expected-clock-hz $ClockHz
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 board signoff gates failed; see $Log"
}
Write-Host "PASS: ABI v2 KV260 <$MaxUsExclusive us board signoff"
Write-Host "UART log: $Log"
Write-Host "Result JSON: $Json"

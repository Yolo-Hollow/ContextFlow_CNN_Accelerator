param(
    [Parameter(Mandatory = $true)]
    [string]$Image,
    [string]$PortName = "COM8",
    [int]$CaptureSeconds = 420,
    [string]$BuildDirName = "build_system_xck26_kv260_linebuffix",
    [string]$OutputDir,
    [switch]$FastRun,
    [switch]$RebuildElf,
    [switch]$RawHwcIfm,
    [switch]$RawHwcConv3,
    [switch]$RawHwcConv4,
    [switch]$RawHwcConv5,
    [switch]$RawHwcConv6,
    [switch]$RawHwcConv8,
    [switch]$RawHwc3x3All,
    [switch]$EarlyDrain,
    [switch]$PassPrefetch,
    [switch]$DuringComputePrefetch,
    [switch]$PsumStreamOverlap,
    [switch]$ContinuousPsum,
    [switch]$ColumnPsum,
    [switch]$BackendFullTile,
    [int]$RawHwcComputeStartLevel = 0,
    [int]$TailCyclesOverride = 0
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SwDir = Split-Path -Parent $ScriptDir
$Root = Split-Path -Parent (Split-Path -Parent $SwDir)
$Python = "C:\Users\hp\.conda\envs\pytorch_env\python.exe"
$ImagePath = (Resolve-Path -LiteralPath $Image).Path
$Stem = [System.IO.Path]::GetFileNameWithoutExtension($ImagePath)
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"

if (!$OutputDir) {
    $OutputDir = Join-Path $Root "demo_output\$Stamp`_$Stem"
}
New-Item -ItemType Directory -Force $OutputDir | Out-Null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path

$Package = Join-Path $OutputDir "image_package.bin"
$Metadata = Join-Path $OutputDir "image_metadata.json"
$Preview = Join-Path $OutputDir "letterbox_preview.png"
$Visualization = Join-Path $OutputDir "detections.png"
$DetectionsJson = Join-Path $OutputDir "detections.json"
$PerformanceJson = Join-Path $OutputDir "performance.json"
$PrepareScript = Join-Path $Root "tools\demo\prepare_ddr_image.py"
$VisualizeScript = Join-Path $Root "tools\demo\visualize_uart_detections.py"
$PerfScript = Join-Path $Root "tools\demo\summarize_uart_perf.py"
$BuildScript = Join-Path $ScriptDir "manual_build_accel_smoke.ps1"
$RunScript = Join-Path $ScriptDir "run_kv260_smoke_sequence.ps1"
$Elf = Join-Path $Root "build_vitis_2022_2\conv_accel_r18_c16_smoke\manual_build\conv_accel_conv0_conv9_ddr_demo_smoke.elf"
if ([System.IO.Path]::IsPathRooted($BuildDirName)) {
    $DemoBuildDir = $BuildDirName
} else {
    $DemoBuildDir = Join-Path $Root $BuildDirName
}
$LogDir = Join-Path $DemoBuildDir "board_smoke_logs"

& $Python $PrepareScript $ImagePath --package $Package --metadata $Metadata --preview $Preview
if ($LASTEXITCODE -ne 0) {
    throw "Image preprocessing failed"
}

if ($RebuildElf -or !(Test-Path $Elf)) {
    $BuildArgs = @{
        Mode = "conv0_conv9_ddr_demo"
        RawHwcComputeStartLevel = $RawHwcComputeStartLevel
        TailCyclesOverride = $TailCyclesOverride
    }
    if ($RawHwcIfm) {
        $BuildArgs.RawHwcIfm = $true
    }
    if ($RawHwcConv3) {
        $BuildArgs.RawHwcConv3 = $true
    }
    if ($RawHwcConv4) {
        $BuildArgs.RawHwcConv4 = $true
    }
    if ($RawHwcConv5) {
        $BuildArgs.RawHwcConv5 = $true
    }
    if ($RawHwcConv6) {
        $BuildArgs.RawHwcConv6 = $true
    }
    if ($RawHwcConv8) {
        $BuildArgs.RawHwcConv8 = $true
    }
    if ($RawHwc3x3All) {
        $BuildArgs.RawHwc3x3All = $true
    }
    if ($EarlyDrain) {
        $BuildArgs.EarlyDrain = $true
    }
    if ($PassPrefetch) {
        $BuildArgs.PassPrefetch = $true
    }
    if ($DuringComputePrefetch) {
        $BuildArgs.DuringComputePrefetch = $true
    }
    if ($PsumStreamOverlap) {
        $BuildArgs.PsumStreamOverlap = $true
    }
    if ($ContinuousPsum) {
        $BuildArgs.ContinuousPsum = $true
    }
    if ($ColumnPsum) {
        $BuildArgs.ColumnPsum = $true
    }
    if ($BackendFullTile) {
        $BuildArgs.BackendFullTile = $true
    }
    & $BuildScript @BuildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "DDR demo ELF build failed"
    }
}

$RunArgs = @{
    PortName = $PortName
    CaptureSeconds = $CaptureSeconds
    RunConv0Conv9DdrDemo = $true
    InputPackage = $Package
    BuildDirName = $BuildDirName
    RawHwcComputeStartLevel = $RawHwcComputeStartLevel
}
if ($FastRun) {
    $RunArgs.FastRun = $true
}
if ($RawHwcIfm) {
    $RunArgs.RawHwcIfm = $true
}
if ($RawHwcConv3) {
    $RunArgs.RawHwcConv3 = $true
}
if ($RawHwcConv4) {
    $RunArgs.RawHwcConv4 = $true
}
if ($RawHwcConv5) {
    $RunArgs.RawHwcConv5 = $true
}
if ($RawHwcConv6) {
    $RunArgs.RawHwcConv6 = $true
}
if ($RawHwcConv8) {
    $RunArgs.RawHwcConv8 = $true
}
if ($RawHwc3x3All) {
    $RunArgs.RawHwc3x3All = $true
}
if ($EarlyDrain) {
    $RunArgs.EarlyDrain = $true
}
if ($PassPrefetch) {
    $RunArgs.PassPrefetch = $true
}
if ($DuringComputePrefetch) {
    $RunArgs.DuringComputePrefetch = $true
}
if ($PsumStreamOverlap) {
    $RunArgs.PsumStreamOverlap = $true
}
if ($ContinuousPsum) {
    $RunArgs.ContinuousPsum = $true
}
if ($ColumnPsum) {
    $RunArgs.ColumnPsum = $true
}
if ($BackendFullTile) {
    $RunArgs.BackendFullTile = $true
}
$RunStart = Get-Date
& $RunScript @RunArgs
if ($LASTEXITCODE -ne 0) {
    throw "KV260 image inference failed"
}

$Log = Get-ChildItem $LogDir -Filter "*_conv0_conv9_ddr_demo_$PortName.log" |
    Where-Object { $_.LastWriteTime -ge $RunStart } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if (!$Log) {
    throw "Could not find the UART log for this image run"
}
$LogText = Get-Content -LiteralPath $Log.FullName -Raw
if ($LogText -notmatch "PASS: conv0_pool -> conv9 chained smoke dynamic image inference complete") {
    throw "UART log does not contain the dynamic image inference PASS marker: $($Log.FullName)"
}

& $Python $VisualizeScript $ImagePath $Log.FullName --output $Visualization --json $DetectionsJson
if ($LASTEXITCODE -ne 0) {
    throw "Detection visualization failed"
}
& $Python $PerfScript $Log.FullName --json $PerformanceJson
if ($LASTEXITCODE -ne 0) {
    throw "Performance summary failed"
}

Write-Host "Image demo complete"
Write-Host "  UART log: $($Log.FullName)"
Write-Host "  Detection JSON: $DetectionsJson"
Write-Host "  Performance JSON: $PerformanceJson"
Write-Host "  Visualization: $Visualization"

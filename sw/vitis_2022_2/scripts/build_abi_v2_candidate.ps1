param(
    [string]$Workspace = "",
    [string]$Xsa = "",
    [string]$BitFile = "",
    [string]$HardwareMetadata = "",
    [string]$HardwareShaManifest = "",
    [string]$ParameterPackageDir = "",
    [string]$ReproRoot = "",
    [ValidateSet("0x2B", "0x3B", "0x3F", "0xBF")]
    [string]$StreamCfg = "0xBF",
    [switch]$Performance,
    [ValidateSet(30, 100)]
    [int]$BenchmarkRuns = 100,
    [switch]$Soak,
    [ValidateRange(600, 86400)]
    [int]$SoakSeconds = 600,
    [ValidateSet(100000000, 125000000, 200000000)]
    [long]$ExpectedClockHz = 100000000,
    [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
if (($Performance -or $Soak) -and $StreamCfg -ne "0xBF") {
    throw "ABI v2 performance candidate requires -StreamCfg 0xBF"
}
if (!$Performance -and !$Soak -and $PSBoundParameters.ContainsKey("BenchmarkRuns")) {
    throw "-BenchmarkRuns requires -Performance"
}
if ($Soak -and $PSBoundParameters.ContainsKey("BenchmarkRuns")) {
    throw "-Soak cannot be combined with finite -BenchmarkRuns"
}
if (!$Soak -and $PSBoundParameters.ContainsKey("SoakSeconds")) {
    throw "-SoakSeconds requires -Soak"
}
if ($ExpectedClockHz -eq 125000000 -and $Soak) {
    throw "125 MHz frequency-sweep candidates cannot be used for soak"
}
if ($ExpectedClockHz -eq 125000000 -and
    $Performance -and
    (!$PSBoundParameters.ContainsKey("BenchmarkRuns") -or
     $BenchmarkRuns -ne 30)) {
    throw "125 MHz development performance requires exactly 30 measured runs"
}
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SwDir = Split-Path -Parent $ScriptDir
$Root = Split-Path -Parent (Split-Path -Parent $SwDir)
$HardwareProfile = switch ($ExpectedClockHz) {
    100000000 { "abi_v2_release" }
    125000000 { "abi_v2_frequency_sweep_125" }
    200000000 { "abi_v2_release_200" }
}
$HardwareBuild = if ($ExpectedClockHz -eq 125000000) {
    Join-Path $Root "build_system_abi_v2_frequency_sweep_125"
} else {
    Join-Path $Root "build_system_xck26_kv260_$HardwareProfile"
}

if ([string]::IsNullOrWhiteSpace($Workspace)) {
    $Workspace = Join-Path $Root $(if ($ExpectedClockHz -eq 125000000) {
        if ($Performance) {
            "b125_perf_abi_v2_candidate"
        } else {
            "build_vitis_2022_2_abi_v2_candidate_125_functional"
        }
    } elseif ($Soak) {
        "build_vitis_2022_2_abi_v2_candidate_soak"
    } else {
        "build_vitis_2022_2_abi_v2_candidate"
    })
}
if ([string]::IsNullOrWhiteSpace($Xsa)) {
    $Xsa = Join-Path $HardwareBuild "conv_accel_ps_dma_minimal.xsa"
}
if ([string]::IsNullOrWhiteSpace($BitFile)) {
    $BitFile = Join-Path $HardwareBuild "conv_accel_ps_dma_minimal\conv_accel_ps_dma_minimal.runs\impl_1\conv_accel_ps_dma_wrapper.bit"
}
if ([string]::IsNullOrWhiteSpace($HardwareMetadata)) {
    $HardwareMetadata = Join-Path $HardwareBuild "reports\build_profile.txt"
}
if ([string]::IsNullOrWhiteSpace($HardwareShaManifest)) {
    $HardwareShaManifest = Join-Path $HardwareBuild "reports\system_artifacts.sha256"
}
if ([string]::IsNullOrWhiteSpace($ParameterPackageDir)) {
    $ParameterPackageDir = Join-Path $Root "build_abi_v2_parameters"
}
if ([string]::IsNullOrWhiteSpace($ReproRoot)) {
    $ReproRoot = Join-Path $Root "repro"
}

$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$Xsa = [System.IO.Path]::GetFullPath($Xsa)
$BitFile = [System.IO.Path]::GetFullPath($BitFile)
$HardwareMetadata = [System.IO.Path]::GetFullPath($HardwareMetadata)
$HardwareShaManifest = [System.IO.Path]::GetFullPath($HardwareShaManifest)
$ParameterPackageDir = [System.IO.Path]::GetFullPath($ParameterPackageDir)
$ReproRoot = [System.IO.Path]::GetFullPath($ReproRoot)
$RepositoryReproRoot = [System.IO.Path]::GetFullPath((Join-Path $Root "repro"))
if ((Split-Path -Leaf $Workspace).ToLowerInvariant() -notlike "*abi_v2_candidate*") {
    throw "Candidate workspace basename must contain abi_v2_candidate: $Workspace"
}
$WorkspaceLeaf = (Split-Path -Leaf $Workspace).ToLowerInvariant()
if ($Soak -and $WorkspaceLeaf -notlike "*soak*") {
    throw "Soak ELF requires an isolated candidate workspace whose basename contains soak: $Workspace"
}
if (!$Soak -and $WorkspaceLeaf -like "*soak*") {
    throw "Finite/functional candidates cannot reuse a soak workspace: $Workspace"
}
if ($ExpectedClockHz -eq 125000000 -and $Performance -and
    $WorkspaceLeaf -notlike "*perf*") {
    throw "125 MHz performance requires an isolated workspace whose basename contains perf: $Workspace"
}
if ($ExpectedClockHz -eq 125000000 -and !$Performance -and
    $WorkspaceLeaf -like "*perf*") {
    throw "125 MHz functional candidate cannot reuse a performance workspace: $Workspace"
}
if ($ReproRoot -ne $RepositoryReproRoot) {
    throw "ABI v2 candidate model input must be the repository repro directory: $RepositoryReproRoot"
}

$RuntimeHeader = Join-Path $SwDir "src\accel_smoke.h"
$RuntimeReadyMatch = Select-String -Path $RuntimeHeader -Pattern '^#define ACCEL_V2_LONG_STREAM_RUNTIME_READY 0$'
if ($null -eq $RuntimeReadyMatch) {
    throw "Candidate stage requires ACCEL_V2_LONG_STREAM_RUNTIME_READY=0"
}
foreach ($Item in @($Xsa, $BitFile, $HardwareMetadata, $HardwareShaManifest)) {
    if (!(Test-Path -PathType Leaf $Item)) {
        throw "Required ABI v2 hardware artifact not found: $Item"
    }
}

$Python = "python"
$Generator = Join-Path $ScriptDir "generate_abi_v2_parameter_package.py"
$Verifier = Join-Path $ScriptDir "abi_v2_candidate_artifacts.py"
$ParameterManifest = Join-Path $ParameterPackageDir "abi_v2_parameter_manifest.json"
if (!(Test-Path -PathType Leaf $ParameterManifest)) {
    & $Python $Generator --model-root (Join-Path $ReproRoot "model") --output-dir $ParameterPackageDir
    if ($LASTEXITCODE -ne 0) {
        throw "ABI v2 parameter-package generation failed"
    }
}

New-Item -ItemType Directory -Force $Workspace | Out-Null
$CandidateManifest = Join-Path $Workspace "abi_v2_candidate_manifest.json"
if (Test-Path -PathType Leaf $CandidateManifest) {
    & $Python $Verifier verify --manifest $CandidateManifest --phase build `
        --expect-workspace $Workspace --expect-xsa $Xsa --expect-bit $BitFile `
        --expect-parameter-manifest $ParameterManifest `
        --expect-clock-hz $ExpectedClockHz
} else {
    & $Python $Verifier bind --manifest $CandidateManifest --workspace $Workspace `
        --xsa $Xsa --bit $BitFile --hardware-metadata $HardwareMetadata `
        --hardware-sha-manifest $HardwareShaManifest `
        --parameter-manifest $ParameterManifest
}
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 candidate build-input binding failed"
}
& $Python $Verifier verify --manifest $CandidateManifest --phase build `
    --expect-workspace $Workspace --expect-xsa $Xsa --expect-bit $BitFile `
    --expect-parameter-manifest $ParameterManifest `
    --expect-clock-hz $ExpectedClockHz
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 candidate pre-build verification failed"
}
$Candidate = Get-Content -Raw $CandidateManifest | ConvertFrom-Json
$ClockHz = $Candidate.runtime.clock_hz
if ($null -eq $ClockHz -and $Candidate.hardware.profile -eq "abi_v2_release") {
    $ClockHz = 100000000
}
$ClockHz = [long]$ClockHz
if ($ClockHz -notin @(100000000, 125000000, 200000000)) {
    throw "ABI v2 candidate manifest has unsupported clock_hz=$ClockHz"
}
if ($ClockHz -ne $ExpectedClockHz) {
    throw "ABI v2 candidate clock_hz=$ClockHz, expected $ExpectedClockHz"
}
$ReleaseEligible = if ($null -eq $Candidate.release_eligible -and
    $Candidate.hardware.profile -in @("abi_v2_release", "abi_v2_release_200")) {
    $true
} else {
    [bool]$Candidate.release_eligible
}
$HardwareReleaseEligible = if ($null -eq $Candidate.hardware.release_eligible -and
    $Candidate.hardware.profile -in @("abi_v2_release", "abi_v2_release_200")) {
    $true
} else {
    [bool]$Candidate.hardware.release_eligible
}
if ($ExpectedClockHz -eq 125000000) {
    if ($ReleaseEligible -or
        $Candidate.hardware.profile -ne "abi_v2_frequency_sweep_125" -or
        $HardwareReleaseEligible) {
        throw "125 MHz candidate must remain explicitly non-release-eligible"
    }
} elseif (!$ReleaseEligible -or !$HardwareReleaseEligible) {
    throw "Formal release hardware lost its release-eligible identity"
}

if ($CheckOnly) {
    Write-Host "PASS: ABI v2 candidate build inputs are bound and verified"
    Write-Host "Workspace: $Workspace"
    Write-Host "Manifest: $CandidateManifest"
    Write-Host "ClockHz: $ClockHz"
    Write-Host "RunMode: $(if ($Soak) { 'soak' } elseif ($Performance) { 'benchmark' } else { 'functional' })"
    Write-Host "BenchmarkRuns: $(if ($Performance -and !$Soak) { $BenchmarkRuns } else { 0 })"
    Write-Host "SoakSeconds: $(if ($Soak) { $SoakSeconds } else { 0 })"
    exit 0
}

$Xsct = "C:\Xilinx\Vitis\2022.2\bin\xsct.bat"
if (!(Test-Path -PathType Leaf $Xsct)) {
    throw "Vitis 2022.2 XSCT not found: $Xsct"
}
$CreateProject = Join-Path $ScriptDir "create_abi_v2_candidate_project.tcl"
& $Xsct $CreateProject -workspace $Workspace -xsa $Xsa `
    -manifest $CandidateManifest
if ($LASTEXITCODE -ne 0) {
    throw "Vitis ABI v2 candidate project creation failed"
}

$ManualBuild = Join-Path $ScriptDir "manual_build_accel_smoke.ps1"
$ManualArgs = @(
    "-ExecutionPolicy", "Bypass", "-File", $ManualBuild,
    "-Mode", "conv0_conv9_batch_chain", "-RuntimeAbiVersion", "2",
    "-V2StreamCfg", $StreamCfg, "-EnableV2LongStreamRuntime",
    "-V2ClockHz", "$ClockHz",
    "-WorkspacePath", $Workspace,
    "-ApplicationName", "conv_accel_abi_v2_candidate",
    "-PlatformName", "conv_accel_abi_v2_candidate_platform",
    "-OutputElfName", "conv_accel_abi_v2_candidate.elf",
    "-ParameterPackageDir", $ParameterPackageDir,
    "-CandidateArtifactManifest", $CandidateManifest,
    "-ReproRoot", $ReproRoot
)
if ($Soak) {
    $ManualArgs += @("-V2Performance", "-V2SoakSeconds", "$SoakSeconds")
} elseif ($Performance) {
    $ManualArgs += @("-V2Performance", "-V2BenchmarkRuns", "$BenchmarkRuns")
}
& powershell @ManualArgs
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 candidate ELF build failed"
}

$Elf = Join-Path $Workspace "conv_accel_abi_v2_candidate\manual_build\conv_accel_abi_v2_candidate.elf"
$FinalizeArgs = @(
    $Verifier, "finalize", "--manifest", $CandidateManifest,
    "--elf", $Elf, "--stream-cfg", $StreamCfg,
    "--clock-hz", "$ClockHz"
)
if ($Soak) {
    $FinalizeArgs += @(
        "--performance", "--soak-seconds", "$SoakSeconds",
        "--soak-temp-limit-millic", "85000"
    )
} elseif ($Performance) {
    $FinalizeArgs += @("--performance", "--benchmark-runs", "$BenchmarkRuns")
}
& $Python @FinalizeArgs
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 candidate final artifact binding failed"
}
& $Python $Verifier verify --manifest $CandidateManifest --phase run `
    --expect-workspace $Workspace --expect-xsa $Xsa --expect-bit $BitFile `
    --expect-elf $Elf
if ($LASTEXITCODE -ne 0) {
    throw "ABI v2 candidate post-build verification failed"
}

Write-Host "PASS: ABI v2 candidate ELF and unified SHA256 manifest built"
Write-Host "ELF: $Elf"
Write-Host "Manifest: $CandidateManifest"

param(
    [string]$Project = "D:\MPSoC\python_prj",
    [switch]$OmitGolden,
    [switch]$UseNeon
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SwDir = Split-Path -Parent $ScriptDir
$Root = Split-Path -Parent (Split-Path -Parent $SwDir)

$Workspace = Join-Path $Root "build_vitis_2022_2"
$AppDir = Join-Path $Workspace "conv_accel_r18_c16_smoke"
$AppSrcDir = Join-Path $AppDir "src"
$ManualBuildDir = Join-Path $AppDir "manual_build"
$BspRoot = Join-Path $Workspace "conv_accel_kv260_platform\export\conv_accel_kv260_platform\sw\conv_accel_kv260_platform\standalone_domain"
$BspInclude = Join-Path $BspRoot "bspinclude\include"
$BspLib = Join-Path $BspRoot "bsplib\lib"
$Gcc = "C:\Xilinx\Vitis\2022.2\gnu\aarch64\nt\aarch64-none\bin\aarch64-none-elf-gcc.exe"
$Python = "python"

if (!(Test-Path $Gcc)) {
    throw "Vitis 2022.2 AArch64 GCC not found: $Gcc"
}
if (!(Test-Path $AppSrcDir)) {
    throw "Application source directory not found: $AppSrcDir"
}
if (!(Test-Path $BspInclude) -or !(Test-Path $BspLib)) {
    throw "Generated BSP include/lib not found. Run create_accel_smoke_project.tcl first."
}

New-Item -ItemType Directory -Force $ManualBuildDir | Out-Null
Copy-Item -Path `
    (Join-Path $SwDir "src\cpu_yolo_baseline.c"), `
    (Join-Path $SwDir "src\cpu_yolo_baseline.h"), `
    (Join-Path $SwDir "src\yolo_decode.c"), `
    (Join-Path $SwDir "src\yolo_decode.h") `
    -Destination $AppSrcDir -Force

$HeaderArgs = @(
    (Join-Path $ScriptDir "generate_cpu_yolo_baseline_header.py"),
    (Join-Path $AppSrcDir "cpu_yolo_data.h"),
    "--project",
    $Project
)
if ($OmitGolden) {
    $HeaderArgs += "--omit-golden"
}
& $Python @HeaderArgs
if ($LASTEXITCODE -ne 0) {
    throw "Failed to generate cpu_yolo_data.h"
}

$MainObj = Join-Path $ManualBuildDir "cpu_yolo_baseline.o"
$DecodeObj = Join-Path $ManualBuildDir "cpu_yolo_decode.o"
$Elf = Join-Path $ManualBuildDir "cpu_yolo_baseline.elf"
$LinkerScript = Join-Path $AppSrcDir "lscript.ld"

$Defines = @("-DARMA53_64")
if ($UseNeon) {
    $Defines += "-DACCEL_CPU_YOLO_USE_NEON=1"
}
$CpuFlags = @("-mcpu=cortex-a53")

& $Gcc -Wall -O3 -g3 @CpuFlags -c @Defines -I $BspInclude -I $AppSrcDir `
    (Join-Path $AppSrcDir "cpu_yolo_baseline.c") -o $MainObj
if ($LASTEXITCODE -ne 0) {
    throw "Failed to compile cpu_yolo_baseline.c"
}

& $Gcc -Wall -O3 -g3 @CpuFlags -c @Defines -I $BspInclude -I $AppSrcDir `
    (Join-Path $AppSrcDir "yolo_decode.c") -o $DecodeObj
if ($LASTEXITCODE -ne 0) {
    throw "Failed to compile yolo_decode.c"
}

& $Gcc -o $Elf $MainObj $DecodeObj "-Wl,--start-group,-lxil,-lm,-lgcc,-lc,--end-group" `
    -n "-Wl,--gc-sections" -L $BspLib -T $LinkerScript
if ($LASTEXITCODE -ne 0) {
    throw "Failed to link $Elf"
}

Write-Host "Built $Elf"

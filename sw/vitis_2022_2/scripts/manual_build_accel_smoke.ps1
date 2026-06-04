param(
    [ValidateSet("r18_c8", "conv0_crop_pool")]
    [string]$Mode = "r18_c8"
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
Copy-Item -Path (Join-Path $SwDir "src\main.c"), (Join-Path $SwDir "src\accel_smoke.h"), (Join-Path $SwDir "src\conv0_crop_pool_data.h") -Destination $AppSrcDir -Force

$Obj = Join-Path $ManualBuildDir "main_$Mode.o"
$Elf = Join-Path $ManualBuildDir "conv_accel_${Mode}_smoke.elf"
$LinkerScript = Join-Path $AppSrcDir "lscript.ld"
$Defines = @()
if ($Mode -eq "conv0_crop_pool") {
    $Defines += "-DACCEL_SMOKE_REAL_CONV0_CROP_POOL=1"
}

& $Gcc -Wall -O0 -g3 -c -DARMA53_64 @Defines -I $BspInclude -I $AppSrcDir (Join-Path $AppSrcDir "main.c") -o $Obj
& $Gcc -o $Elf $Obj "-Wl,--start-group,-lxil,-lgcc,-lc,--end-group" -n "-Wl,--gc-sections" -L $BspLib -T $LinkerScript

Write-Host "Built $Elf"

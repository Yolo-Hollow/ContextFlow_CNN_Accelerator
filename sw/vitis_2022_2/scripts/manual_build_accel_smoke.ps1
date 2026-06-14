param(
    [ValidateSet("r18_c8", "conv0_crop_pool", "conv0_crop_pool_tiles", "layer06_tile4", "layer06_tiles", "layer06_pool_tiles", "conv4_pool_tiles", "conv3_conv4_chain", "conv4_conv5_chain", "conv0_conv4_chain", "conv0_conv5_chain", "conv0_conv6_chain", "conv0_conv7_chain", "conv0_conv8_chain", "conv0_conv9_chain", "conv0_conv9_batch_chain", "conv0_conv9_ddr_demo")]
    [string]$Mode = "r18_c8",
    [switch]$RawHwcIfm,
    [switch]$RawHwcConv4,
    [switch]$RawHwcConv5,
    [switch]$RawHwcConv6,
    [switch]$RawHwcConv8,
    [switch]$RawHwc3x3All,
    [switch]$EarlyDrain,
    [switch]$PassPrefetch,
    [switch]$PsumStreamOverlap,
    [switch]$TilePerfTrace,
    [int]$RawHwcComputeStartLevel = 0,
    [int]$TailCyclesOverride = 0
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
    (Join-Path $SwDir "src\main.c"), `
    (Join-Path $SwDir "src\main_conv3_conv4_chain.c"), `
    (Join-Path $SwDir "src\accel_smoke.h"), `
    (Join-Path $SwDir "src\accel_layer_desc.h"), `
    (Join-Path $SwDir "src\accel_single_scale_plan.h"), `
    (Join-Path $SwDir "src\accel_single_scale_scheduler.h"), `
    (Join-Path $SwDir "src\yolo_decode.c"), `
    (Join-Path $SwDir "src\yolo_decode.h"), `
    (Join-Path $SwDir "src\conv0_crop_pool_data.h") `
    -Destination $AppSrcDir -Force

$Obj = Join-Path $ManualBuildDir "main_$Mode.o"
$DecodeObj = Join-Path $ManualBuildDir "yolo_decode_$Mode.o"
$Elf = Join-Path $ManualBuildDir "conv_accel_${Mode}_smoke.elf"
$LinkerScript = Join-Path $AppSrcDir "lscript.ld"
$Defines = @()
if ($TailCyclesOverride -ne 0) {
    $Defines += "-DACCEL_TAIL_CYCLES_OVERRIDE=$TailCyclesOverride"
}
$Defines += "-DACCEL_RAW_HWC_COMPUTE_START_LEVEL=$RawHwcComputeStartLevel"
if ($TilePerfTrace) {
    $Defines += "-DACCEL_TILE_PERF_TRACE=1"
}
if ($EarlyDrain) {
    $Defines += "-DACCEL_EARLY_DRAIN=1"
}
if ($PassPrefetch) {
    $Defines += "-DACCEL_PASS_PREFETCH=1"
}
if ($PsumStreamOverlap) {
    $Defines += "-DACCEL_PSUM_STREAM_OVERLAP=1"
}
$Source = Join-Path $AppSrcDir "main.c"
if ($Mode -eq "conv0_crop_pool" -or $Mode -eq "conv0_crop_pool_tiles") {
    $Defines += "-DACCEL_SMOKE_REAL_CONV0_CROP_POOL=1"
}
if ($Mode -eq "conv0_crop_pool_tiles") {
    $Defines += "-DACCEL_SMOKE_CONV0_CROP_POOL_TILES=1"
}
if ($Mode -eq "layer06_tile4" -or $Mode -eq "layer06_tiles" -or $Mode -eq "layer06_pool_tiles") {
    if ($Mode -eq "layer06_tile4") {
        $Defines += "-DACCEL_SMOKE_LAYER06_TILE4=1"
    }
    if ($Mode -eq "layer06_tiles") {
        $Defines += "-DACCEL_SMOKE_LAYER06_TILES=1"
    }
    if ($Mode -eq "layer06_pool_tiles") {
        $Defines += "-DACCEL_SMOKE_LAYER06_POOL_TILES=1"
    }
    & $Python (Join-Path $ScriptDir "generate_layer06_tile4_header.py") (Join-Path $AppSrcDir "layer06_tile4_data.h")
}
if ($Mode -eq "conv4_pool_tiles") {
    $Defines += "-DACCEL_SMOKE_CONV4_POOL_TILES=1"
    & $Python `
        (Join-Path $ScriptDir "generate_single_scale_layer_header.py") `
        "D:\MPSoC\python_prj\rtl_golden\facemask_single_scale_rtl\04_conv4_pool" `
        (Join-Path $AppSrcDir "conv4_pool_data.h") `
        --prefix conv4_pool
}
if ($Mode -eq "conv3_conv4_chain") {
    $Source = Join-Path $AppSrcDir "main_conv3_conv4_chain.c"
    & $Python (Join-Path $ScriptDir "generate_layer06_tile4_header.py") (Join-Path $AppSrcDir "layer06_tile4_data.h")
    & $Python `
        (Join-Path $ScriptDir "generate_single_scale_layer_header.py") `
        "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv3_conv4_rtl\04_conv4_pool" `
        (Join-Path $AppSrcDir "conv4_pool_data.h") `
        --prefix conv4_pool
}
if ($Mode -eq "conv4_conv5_chain") {
    $Source = Join-Path $AppSrcDir "main_conv3_conv4_chain.c"
    $Defines += "-DACCEL_CHAIN_CONV4_CONV5=1"
    & $Python `
        (Join-Path $ScriptDir "generate_single_scale_layer_header.py") `
        "D:\MPSoC\python_prj\rtl_golden\facemask_single_scale_rtl\04_conv4_pool" `
        (Join-Path $AppSrcDir "conv4_pool_data.h") `
        --prefix conv4_pool
    & $Python `
        (Join-Path $ScriptDir "generate_single_scale_layer_header.py") `
        "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv4_conv5_rtl\05_conv5_pool_like_tiny" `
        (Join-Path $AppSrcDir "conv5_pool_data.h") `
        --prefix conv5_pool
}
if ($Mode -eq "conv0_conv4_chain") {
    $Source = Join-Path $AppSrcDir "main_conv3_conv4_chain.c"
    $Defines += "-DACCEL_CHAIN_CONV0_CONV4=1"
    $ChainRoot = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv4_rtl"
    $Layers = @(
        @{ Dir = "00_conv0_pool"; Prefix = "conv0_pool"; OmitIfm = $false },
        @{ Dir = "01_conv1_pool"; Prefix = "conv1_pool"; OmitIfm = $true },
        @{ Dir = "02_conv2_pool"; Prefix = "conv2_pool"; OmitIfm = $true },
        @{ Dir = "03_conv3_pool"; Prefix = "conv3_pool"; OmitIfm = $true },
        @{ Dir = "04_conv4_pool"; Prefix = "conv4_pool"; OmitIfm = $true }
    )
    foreach ($Layer in $Layers) {
        $Args = @(
            (Join-Path $ScriptDir "generate_single_scale_layer_header.py"),
            (Join-Path $ChainRoot $Layer.Dir),
            (Join-Path $AppSrcDir "$($Layer.Prefix)_data.h"),
            "--prefix",
            $Layer.Prefix
        )
        if ($Layer.OmitIfm) {
            $Args += "--omit-ifm"
        }
        & $Python @Args
    }
}
if ($Mode -eq "conv0_conv5_chain") {
    $Source = Join-Path $AppSrcDir "main_conv3_conv4_chain.c"
    $Defines += "-DACCEL_CHAIN_CONV0_CONV5=1"
    $ChainRoot = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv4_rtl"
    $Layers = @(
        @{ Dir = "00_conv0_pool"; Prefix = "conv0_pool"; OmitIfm = $false },
        @{ Dir = "01_conv1_pool"; Prefix = "conv1_pool"; OmitIfm = $true },
        @{ Dir = "02_conv2_pool"; Prefix = "conv2_pool"; OmitIfm = $true },
        @{ Dir = "03_conv3_pool"; Prefix = "conv3_pool"; OmitIfm = $true },
        @{ Dir = "04_conv4_pool"; Prefix = "conv4_pool"; OmitIfm = $true }
    )
    foreach ($Layer in $Layers) {
        $Args = @(
            (Join-Path $ScriptDir "generate_single_scale_layer_header.py"),
            (Join-Path $ChainRoot $Layer.Dir),
            (Join-Path $AppSrcDir "$($Layer.Prefix)_data.h"),
            "--prefix",
            $Layer.Prefix
        )
        if ($Layer.OmitIfm) {
            $Args += "--omit-ifm"
        }
        & $Python @Args
    }
    & $Python `
        (Join-Path $ScriptDir "generate_single_scale_layer_header.py") `
        "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv5_rtl\05_conv5_pool_like_tiny" `
        (Join-Path $AppSrcDir "conv5_pool_data.h") `
        --prefix conv5_pool `
        --omit-ifm
}
if ($Mode -eq "conv0_conv6_chain") {
    $Source = Join-Path $AppSrcDir "main_conv3_conv4_chain.c"
    $Defines += "-DACCEL_CHAIN_CONV0_CONV6=1"
    $BackboneRoot = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv4_rtl"
    $Layers = @(
        @{ Root = $BackboneRoot; Dir = "00_conv0_pool"; Prefix = "conv0_pool"; OmitIfm = $false },
        @{ Root = $BackboneRoot; Dir = "01_conv1_pool"; Prefix = "conv1_pool"; OmitIfm = $true },
        @{ Root = $BackboneRoot; Dir = "02_conv2_pool"; Prefix = "conv2_pool"; OmitIfm = $true },
        @{ Root = $BackboneRoot; Dir = "03_conv3_pool"; Prefix = "conv3_pool"; OmitIfm = $true },
        @{ Root = $BackboneRoot; Dir = "04_conv4_pool"; Prefix = "conv4_pool"; OmitIfm = $true },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv5_rtl"; Dir = "05_conv5_pool_like_tiny"; Prefix = "conv5_pool"; OmitIfm = $true },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv6_rtl"; Dir = "06_head_conv6_3x3"; Prefix = "conv6"; OmitIfm = $true }
    )
    foreach ($Layer in $Layers) {
        $Args = @(
            (Join-Path $ScriptDir "generate_single_scale_layer_header.py"),
            (Join-Path $Layer.Root $Layer.Dir),
            (Join-Path $AppSrcDir "$($Layer.Prefix)_data.h"),
            "--prefix",
            $Layer.Prefix
        )
        if ($Layer.OmitIfm) {
            $Args += "--omit-ifm"
        }
        & $Python @Args
    }
}
if ($Mode -eq "conv0_conv7_chain") {
    $Source = Join-Path $AppSrcDir "main_conv3_conv4_chain.c"
    $Defines += "-DACCEL_CHAIN_CONV0_CONV7=1"
    $BackboneRoot = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv4_rtl"
    $Layers = @(
        @{ Root = $BackboneRoot; Dir = "00_conv0_pool"; Prefix = "conv0_pool"; OmitIfm = $false; Emulate1x1 = $false },
        @{ Root = $BackboneRoot; Dir = "01_conv1_pool"; Prefix = "conv1_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = $BackboneRoot; Dir = "02_conv2_pool"; Prefix = "conv2_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = $BackboneRoot; Dir = "03_conv3_pool"; Prefix = "conv3_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = $BackboneRoot; Dir = "04_conv4_pool"; Prefix = "conv4_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv5_rtl"; Dir = "05_conv5_pool_like_tiny"; Prefix = "conv5_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv6_rtl"; Dir = "06_head_conv6_3x3"; Prefix = "conv6"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv7_rtl"; Dir = "07_head_conv7_1x1"; Prefix = "conv7"; OmitIfm = $true; Emulate1x1 = $true }
    )
    foreach ($Layer in $Layers) {
        $Args = @(
            (Join-Path $ScriptDir "generate_single_scale_layer_header.py"),
            (Join-Path $Layer.Root $Layer.Dir),
            (Join-Path $AppSrcDir "$($Layer.Prefix)_data.h"),
            "--prefix",
            $Layer.Prefix
        )
        if ($Layer.OmitIfm) {
            $Args += "--omit-ifm"
        }
        if ($Layer.Emulate1x1) {
            $Args += "--emulate-1x1-as-3x3"
        }
        & $Python @Args
    }
}
if ($Mode -eq "conv0_conv8_chain") {
    $Source = Join-Path $AppSrcDir "main_conv3_conv4_chain.c"
    $Defines += "-DACCEL_CHAIN_CONV0_CONV8=1"
    $BackboneRoot = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv4_rtl"
    $Layers = @(
        @{ Root = $BackboneRoot; Dir = "00_conv0_pool"; Prefix = "conv0_pool"; OmitIfm = $false; Emulate1x1 = $false },
        @{ Root = $BackboneRoot; Dir = "01_conv1_pool"; Prefix = "conv1_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = $BackboneRoot; Dir = "02_conv2_pool"; Prefix = "conv2_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = $BackboneRoot; Dir = "03_conv3_pool"; Prefix = "conv3_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = $BackboneRoot; Dir = "04_conv4_pool"; Prefix = "conv4_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv5_rtl"; Dir = "05_conv5_pool_like_tiny"; Prefix = "conv5_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv6_rtl"; Dir = "06_head_conv6_3x3"; Prefix = "conv6"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv7_rtl"; Dir = "07_head_conv7_1x1"; Prefix = "conv7"; OmitIfm = $true; Emulate1x1 = $true },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv8_rtl"; Dir = "08_head_conv8_3x3"; Prefix = "conv8"; OmitIfm = $true; Emulate1x1 = $false }
    )
    foreach ($Layer in $Layers) {
        $Args = @(
            (Join-Path $ScriptDir "generate_single_scale_layer_header.py"),
            (Join-Path $Layer.Root $Layer.Dir),
            (Join-Path $AppSrcDir "$($Layer.Prefix)_data.h"),
            "--prefix",
            $Layer.Prefix
        )
        if ($Layer.OmitIfm) {
            $Args += "--omit-ifm"
        }
        if ($Layer.Emulate1x1) {
            $Args += "--emulate-1x1-as-3x3"
        }
        & $Python @Args
    }
}
if ($Mode -eq "conv0_conv9_chain" -or $Mode -eq "conv0_conv9_batch_chain" -or $Mode -eq "conv0_conv9_ddr_demo") {
    $Source = Join-Path $AppSrcDir "main_conv3_conv4_chain.c"
    $Defines += "-DACCEL_CHAIN_CONV0_CONV9=1"
if ($Mode -eq "conv0_conv9_batch_chain" -or $Mode -eq "conv0_conv9_ddr_demo") {
    $Defines += "-DACCEL_BATCH_STREAM=1"
    $Defines += "-DACCEL_NATIVE_1X1=1"
    $Defines += "-DACCEL_PREPACKED_WEIGHT=1"
    if ($RawHwcIfm) {
        $Defines += "-DACCEL_RAW_HWC_IFM=1"
    }
    $EnableRawHwcConv4 = $RawHwcConv4 -or $RawHwc3x3All
    $EnableRawHwcConv5 = $RawHwcConv5 -or $RawHwc3x3All
    $EnableRawHwcConv6 = $RawHwcConv6 -or $RawHwc3x3All
    $EnableRawHwcConv8 = $RawHwcConv8 -or $RawHwc3x3All
    if ($EnableRawHwcConv4 -or $EnableRawHwcConv5 -or $EnableRawHwcConv6 -or $EnableRawHwcConv8) {
        $Defines += "-DACCEL_RAW_HWC_3X3=1"
        $Defines += "-DACCEL_HWC_CACHE_DEPTH=13312"
    }
    if ($EnableRawHwcConv4) {
        $Defines += "-DACCEL_RAW_HWC_CONV4=1"
    }
    if ($EnableRawHwcConv5) {
        $Defines += "-DACCEL_RAW_HWC_CONV5=1"
    }
    if ($EnableRawHwcConv6) {
        $Defines += "-DACCEL_RAW_HWC_CONV6=1"
    }
    if ($EnableRawHwcConv8) {
        $Defines += "-DACCEL_RAW_HWC_CONV8=1"
    }
}
    if ($Mode -eq "conv0_conv9_ddr_demo") {
        $Defines += "-DACCEL_CHAIN_CONV0_CONV9_DDR=1"
        $Defines += "-DACCEL_PERF_ONLY=1"
    }
    $BackboneRoot = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv4_rtl"
    $Layers = @(
        @{ Root = $BackboneRoot; Dir = "00_conv0_pool"; Prefix = "conv0_pool"; OmitIfm = $false; Emulate1x1 = $false },
        @{ Root = $BackboneRoot; Dir = "01_conv1_pool"; Prefix = "conv1_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = $BackboneRoot; Dir = "02_conv2_pool"; Prefix = "conv2_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = $BackboneRoot; Dir = "03_conv3_pool"; Prefix = "conv3_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = $BackboneRoot; Dir = "04_conv4_pool"; Prefix = "conv4_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv5_rtl"; Dir = "05_conv5_pool_like_tiny"; Prefix = "conv5_pool"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv6_rtl"; Dir = "06_head_conv6_3x3"; Prefix = "conv6"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv7_rtl"; Dir = "07_head_conv7_1x1"; Prefix = "conv7"; OmitIfm = $true; Emulate1x1 = !($Mode -eq "conv0_conv9_batch_chain" -or $Mode -eq "conv0_conv9_ddr_demo") },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv8_rtl"; Dir = "08_head_conv8_3x3"; Prefix = "conv8"; OmitIfm = $true; Emulate1x1 = $false },
        @{ Root = "D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv9_rtl"; Dir = "09_head_detect_conv9_1x1"; Prefix = "conv9"; OmitIfm = $true; Emulate1x1 = !($Mode -eq "conv0_conv9_batch_chain" -or $Mode -eq "conv0_conv9_ddr_demo") }
    )
    foreach ($Layer in $Layers) {
        $Args = @(
            (Join-Path $ScriptDir "generate_single_scale_layer_header.py"),
            (Join-Path $Layer.Root $Layer.Dir),
            (Join-Path $AppSrcDir "$($Layer.Prefix)_data.h"),
            "--prefix",
            $Layer.Prefix
        )
        if ($Layer.OmitIfm) {
            $Args += "--omit-ifm"
        }
        if ($Layer.Emulate1x1) {
            $Args += "--emulate-1x1-as-3x3"
        }
        if ($Mode -eq "conv0_conv9_batch_chain" -or $Mode -eq "conv0_conv9_ddr_demo") {
            $Args += "--prepack-weight-stream"
        }
        & $Python @Args
    }
}

$Optimization = if ($Mode -eq "conv0_conv9_ddr_demo" -or $Mode -eq "conv0_conv9_batch_chain") { "-O2" } else { "-O0" }
& $Gcc -Wall $Optimization -g3 -c -DARMA53_64 @Defines -I $BspInclude -I $AppSrcDir $Source -o $Obj
if ($LASTEXITCODE -ne 0) {
    throw "Failed to compile $Source"
}
$Objects = @($Obj)
$Libraries = "-Wl,--start-group,-lxil,-lgcc,-lc,--end-group"
if ($Mode -eq "conv0_conv9_chain" -or $Mode -eq "conv0_conv9_batch_chain" -or $Mode -eq "conv0_conv9_ddr_demo") {
    & $Gcc -Wall $Optimization -g3 -c -DARMA53_64 -I $BspInclude -I $AppSrcDir `
        (Join-Path $AppSrcDir "yolo_decode.c") -o $DecodeObj
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile yolo_decode.c"
    }
    $Objects += $DecodeObj
    $Libraries = "-Wl,--start-group,-lxil,-lm,-lgcc,-lc,--end-group"
}
& $Gcc -o $Elf @Objects $Libraries -n "-Wl,--gc-sections" -L $BspLib -T $LinkerScript
if ($LASTEXITCODE -ne 0) {
    throw "Failed to link $Elf"
}

Write-Host "Built $Elf"

if ($Mode -eq "conv0_conv9_batch_chain" -or $Mode -eq "conv0_conv9_ddr_demo") {
    $VariantTags = @()
    if ($RawHwcIfm) {
        $VariantTags += "raw_hwc_1x1"
    }
    if ($RawHwcConv4 -or $RawHwc3x3All) {
        $VariantTags += "conv4"
    }
    if ($RawHwcConv5 -or $RawHwc3x3All) {
        $VariantTags += "conv5"
    }
    if ($RawHwcConv6 -or $RawHwc3x3All) {
        $VariantTags += "conv6"
    }
    if ($RawHwcConv8 -or $RawHwc3x3All) {
        $VariantTags += "conv8"
    }
    if ($EarlyDrain) {
        $VariantTags += "early_drain"
    }
    if ($PassPrefetch) {
        $VariantTags += "pass_prefetch"
    }
    if ($PsumStreamOverlap) {
        $VariantTags += "psum_stream_overlap"
    }
    if ($VariantTags.Count -gt 0) {
        $VariantName = "raw_hwc_" + ($VariantTags -join "_")
        $VariantElf = Join-Path $ManualBuildDir "conv_accel_${Mode}_${VariantName}_smoke.elf"
        Copy-Item -Path $Elf -Destination $VariantElf -Force
        Write-Host "Built variant alias $VariantElf"
    }
}

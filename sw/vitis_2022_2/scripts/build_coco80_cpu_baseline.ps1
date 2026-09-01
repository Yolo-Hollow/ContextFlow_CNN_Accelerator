param(
    [string]$Workspace = 'D:\MPSoC\accelerator_systolic\build_vitis_2022_2_coco80_r5_net',
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [ValidateRange(0,8)][int]$Warmups = 1,
    [ValidateRange(1,8)][int]$Samples = 3
)

$ErrorActionPreference='Stop'
$ScriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$SrcDir=[System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..\src'))
$Root=[System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..\..\..'))
$Workspace=[System.IO.Path]::GetFullPath($Workspace)
$PackageDirectory=[System.IO.Path]::GetFullPath($PackageDirectory)
$OutputDirectory=[System.IO.Path]::GetFullPath($OutputDirectory)
$Gcc='C:\Xilinx\Vitis\2022.2\gnu\aarch64\nt\aarch64-none\bin\aarch64-none-elf-gcc.exe'
$PlatformName='coco80_r5_net_platform'
$BspRoot=Join-Path $Workspace "$PlatformName\export\$PlatformName\sw\$PlatformName\standalone_domain"
$BspInclude=Join-Path $BspRoot 'bspinclude\include'
$BspLib=Join-Path $BspRoot 'bsplib\lib'
$Linker=Join-Path $SrcDir 'coco80_a53.ld'
$Generated=Join-Path $PackageDirectory 'coco80_cpu_generated.h'
foreach($Path in @($Gcc,$BspInclude,$BspLib,$Linker,$Generated)){
    if(!(Test-Path -LiteralPath $Path)){throw "required baseline build input missing: $Path"}
}
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null

$Common=@('-std=gnu11','-O3','-g','-mcpu=cortex-a53','-Wall','-Wextra','-Werror',
    '-ffunction-sections','-fdata-sections','-DARMA53_64',
    "-DC8_CPU_BASELINE_WARMUPS=$($Warmups)U","-DC8_CPU_BASELINE_SAMPLES=$($Samples)U",
    '-I',$PackageDirectory,'-I',$SrcDir,'-I',$BspInclude)
function Compile([string]$Source,[string]$Object,[string[]]$Extra){
    & $Gcc @Common @Extra -c (Join-Path $SrcDir $Source) -o $Object
    if($LASTEXITCODE -ne 0){throw "compile failed: $Source -> $Object"}
}
function Link([string]$Elf,[string[]]$Objects,[string]$LinkerScript){
    & $Gcc -mcpu=cortex-a53 -o $Elf @Objects '-Wl,--start-group' -lxil -lm -lgcc -lc `
        '-Wl,--end-group' '-Wl,--gc-sections' -L $BspLib -T $LinkerScript
    if($LASTEXITCODE -ne 0){throw "link failed: $Elf"}
}

$ScalarDir=Join-Path $OutputDirectory 'scalar'
$NeonDir=Join-Path $OutputDirectory 'neon4'
New-Item -ItemType Directory -Force $ScalarDir,$NeonDir | Out-Null
$ScalarObjects=@()
foreach($Spec in @(
    @('main_coco80_cpu_baseline.c','main.o'),
    @('coco80_cpu_conv.c','conv.o'),
    @('coco80_tensor_ops.c','tensor.o'),
    @('coco80_decode.c','decode.o')
)){
    $Object=Join-Path $ScalarDir $Spec[1]
    Compile $Spec[0] $Object @('-DC8_CPU_BASELINE_MODE=1U','-fno-tree-vectorize','-fno-tree-slp-vectorize')
    $ScalarObjects += $Object
}
$ScalarElf=Join-Path $ScalarDir 'coco80_cpu_scalar.elf'
Link $ScalarElf $ScalarObjects $Linker

$NeonObjects=@()
foreach($Spec in @(
    @('main_coco80_cpu_baseline.c','main.o'),
    @('coco80_cpu_conv.c','conv.o'),
    @('coco80_tensor_ops.c','tensor.o'),
    @('coco80_multicore.c','multicore.o'),
    @('coco80_decode.c','decode.o')
)){
    $Object=Join-Path $NeonDir $Spec[1]
    Compile $Spec[0] $Object @('-DC8_CPU_BASELINE_MODE=4U','-DCOCO80_CPU_USE_NEON','-DCOCO80_MC_ENABLE_CPU_CONV')
    $NeonObjects += $Object
}
$NeonElf=Join-Path $NeonDir 'coco80_cpu_neon4.elf'
Link $NeonElf $NeonObjects $Linker

$BaseLinkerText=Get-Content -Raw -LiteralPath $Linker
$Origins=@('0x7D000000','0x7D200000','0x7D400000')
$Workers=@()
for($Worker=1;$Worker -le 3;$Worker++){
    $Main=Join-Path $NeonDir "worker_$($Worker)_main.o"
    Compile 'main_coco80_worker.c' $Main @(
        "-DC8_WORKER_ID=$Worker",'-DC8_CPU_BASELINE_MODE=4U',
        '-DCOCO80_CPU_USE_NEON','-DCOCO80_MC_ENABLE_CPU_CONV')
    $WorkerLinker=Join-Path $NeonDir "worker_$Worker.ld"
    $Text=$BaseLinkerText.Replace(
        'psu_ddr_0_MEM_0 : ORIGIN = 0x0, LENGTH = 0x7FF00000',
        "psu_ddr_0_MEM_0 : ORIGIN = $($Origins[$Worker-1]), LENGTH = 0x00100000")
    if($Text -eq $BaseLinkerText){throw 'worker linker replacement failed'}
    [System.IO.File]::WriteAllText($WorkerLinker,$Text,(New-Object System.Text.UTF8Encoding($false)))
    $Elf=Join-Path $NeonDir "coco80_cpu_worker_$Worker.elf"
    Link $Elf @($Main,(Join-Path $NeonDir 'multicore.o'),(Join-Path $NeonDir 'tensor.o'),(Join-Path $NeonDir 'conv.o')) $WorkerLinker
    $Workers += $Elf
}

$Artifacts=@($ScalarElf,$NeonElf)+$Workers
$Manifest=[ordered]@{
    format='kv260-coco80-a53-cpu-baseline-build';version=1
    git_sha=(& git -C $Root rev-parse HEAD).Trim()
    git_dirty=[bool](& git -C $Root status --porcelain)
    warmups=$Warmups;samples=$Samples
    package_manifest_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $PackageDirectory 'coco80_cpu_baseline_package.json')).Hash.ToLowerInvariant()
    artifacts=@($Artifacts | ForEach-Object {[ordered]@{
        path=$_;bytes=(Get-Item -LiteralPath $_).Length
        sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant()
    }})
}
$ManifestPath=Join-Path $OutputDirectory 'coco80_cpu_baseline_build.json'
$Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestPath -Encoding utf8
Write-Host "PASS: scalar $ScalarElf"
Write-Host "PASS: neon4 $NeonElf"
Write-Host "Manifest: $ManifestPath"

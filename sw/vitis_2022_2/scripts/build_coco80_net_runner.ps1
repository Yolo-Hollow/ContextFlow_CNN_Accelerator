param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$BitFile,
    [Parameter(Mandatory=$true)][string]$Xsa,
    [Parameter(Mandatory=$true)][string]$ParameterManifest,
    [Parameter(Mandatory=$true)][string]$QuantizationManifest,
    [Parameter(Mandatory=$true)][string]$ParameterPackage,
    [Parameter(Mandatory=$true)][string]$TrainingSummary,
    [Parameter(Mandatory=$true)][string]$Fp32EvaluationSummary,
    [Parameter(Mandatory=$true)][string]$Int8EvaluationSummary,
    [string]$BuildDirectory,
    [switch]$AllowNonReleaseDeployment,
    [switch]$DevelopmentBuild,
    [ValidateSet('', 'abi_v2_release_200', 'abi_v2_ablation_200_a0',
        'abi_v2_ablation_200_a1', 'abi_v2_ablation_200_a2')]
    [string]$AblationProfile='',
    [ValidateSet('0x29','0x2B','0x3B','0x3F','0xBF')]
    [string]$AblationStreamCfg='0xBF',
    [ValidateSet('','m0','m13','m14','m16','m19','p4_detect','p5_detect')]
    [string]$AblationRepresentativeLayer='',
    [ValidateSet('','sparse3x3','tile')]
    [string]$AblationSecondary='',
    [string]$HardwareMetadata,
    [string]$HardwareShaManifest
)

$ErrorActionPreference='Stop'
$ScriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$SwDir=Split-Path -Parent $ScriptDir
$Root=[System.IO.Path]::GetFullPath((Join-Path $SwDir '..\..'))
$Workspace=[System.IO.Path]::GetFullPath($Workspace)
$BitFile=[System.IO.Path]::GetFullPath($BitFile)
$Xsa=[System.IO.Path]::GetFullPath($Xsa)
$ParameterManifest=[System.IO.Path]::GetFullPath($ParameterManifest)
$QuantizationManifest=[System.IO.Path]::GetFullPath($QuantizationManifest)
$ParameterPackage=[System.IO.Path]::GetFullPath($ParameterPackage)
$TrainingSummary=[System.IO.Path]::GetFullPath($TrainingSummary)
$Fp32EvaluationSummary=[System.IO.Path]::GetFullPath($Fp32EvaluationSummary)
$Int8EvaluationSummary=[System.IO.Path]::GetFullPath($Int8EvaluationSummary)
$IsAblation=![string]::IsNullOrWhiteSpace($AblationProfile)
$IsRepresentative=![string]::IsNullOrWhiteSpace($AblationRepresentativeLayer)
if($IsAblation){
    if($AblationProfile -eq 'abi_v2_ablation_200_a0' -and !$IsRepresentative){
        throw 'A0 has no raw-HWC materializer; use the representative-layer prepacked runner'
    }
    if([string]::IsNullOrWhiteSpace($HardwareMetadata) -or
       [string]::IsNullOrWhiteSpace($HardwareShaManifest)){
        throw 'ablation runner requires -HardwareMetadata and -HardwareShaManifest'
    }
    $HardwareMetadata=[System.IO.Path]::GetFullPath($HardwareMetadata)
    $HardwareShaManifest=[System.IO.Path]::GetFullPath($HardwareShaManifest)
}elseif($AblationStreamCfg -ne '0xBF' -or $IsRepresentative){
    throw 'staged STREAM_CFG values require an explicit -AblationProfile'
}
$RepresentativeLayers=@{
    m0=@(0,0);m13=@(6,0);m14=@(7,0);m16=@(9,0);m19=@(10,0);
    p4_detect=@(11,0);p5_detect=@(12,0)
}
if($IsRepresentative){
    $RepresentativeLayerIndex=[int]$RepresentativeLayers[$AblationRepresentativeLayer][0]
    $RepresentativeInputMode=if($AblationProfile -eq 'abi_v2_ablation_200_a0'){1}else{0}
    $ExpectedRepresentativeCfg=if($RepresentativeInputMode -eq 1){'0x29'}else{'0x2B'}
    if($AblationStreamCfg -ne $ExpectedRepresentativeCfg){
        throw "representative $AblationProfile requires STREAM_CFG=$ExpectedRepresentativeCfg"
    }
}else{
    $RepresentativeLayerIndex=0
    $RepresentativeInputMode=0
}
$RepresentativeOverrideMode=0
$RepresentativeOverrideTileH=0
$RepresentativeOverrideKernel=0
if(![string]::IsNullOrWhiteSpace($AblationSecondary)){
    if(!$IsRepresentative -or $AblationProfile -ne 'abi_v2_release_200'){
        throw 'secondary ablations require an A3 representative runner'
    }
    if($AblationSecondary -eq 'sparse3x3'){
        $Map=@{m14=4;m16=13;p4_detect=8;p5_detect=8}
        if(!$Map.ContainsKey($AblationRepresentativeLayer)){
            throw 'native1x1 secondary ablation supports m14/m16/P4/P5 only'
        }
        $RepresentativeOverrideMode=1
        $RepresentativeOverrideTileH=$Map[$AblationRepresentativeLayer]
        $RepresentativeOverrideKernel=3
    }else{
        $Map=@{m13=4;m19=3}
        if(!$Map.ContainsKey($AblationRepresentativeLayer)){
            throw 'tile secondary ablation supports m13/m19 only'
        }
        $RepresentativeOverrideMode=2
        $RepresentativeOverrideTileH=$Map[$AblationRepresentativeLayer]
        $RepresentativeOverrideKernel=3
    }
}
$Python='D:\MPSoC\coco80_assets\venv\Scripts\python.exe'
$Gcc='C:\Xilinx\Vitis\2022.2\gnu\aarch64\nt\aarch64-none\bin\aarch64-none-elf-gcc.exe'
$PlatformName='coco80_r5_net_platform'
$BuildDir=if([string]::IsNullOrWhiteSpace($BuildDirectory)){
    Join-Path $Workspace 'coco80_net_manual_build'
}else{
    [System.IO.Path]::GetFullPath($BuildDirectory)
}
$SrcDir=Join-Path $SwDir 'src'
$BspRoot=Join-Path $Workspace "$PlatformName\export\$PlatformName\sw\$PlatformName\standalone_domain"
$BspInclude=Join-Path $BspRoot 'bspinclude\include'
$BspLib=Join-Path $BspRoot 'bsplib\lib'
$Linker=Join-Path $SrcDir 'coco80_a53.ld'

foreach($Path in @(
    $BitFile,$Xsa,$ParameterManifest,$QuantizationManifest,$ParameterPackage,
    $TrainingSummary,$Fp32EvaluationSummary,$Int8EvaluationSummary,$Python,$Gcc,$Linker
)) {
    if(!(Test-Path -LiteralPath $Path -PathType Leaf)){throw "required file missing: $Path"}
}
if($IsAblation){
    foreach($Path in @($HardwareMetadata,$HardwareShaManifest)){
        if(!(Test-Path -LiteralPath $Path -PathType Leaf)){
            throw "required ablation hardware evidence missing: $Path"
        }
    }
}
if(!(Test-Path -LiteralPath (Join-Path $Workspace '.coco80_r5_net_workspace') -PathType Leaf)){
    throw 'workspace is not a COCO80 r5 Ethernet workspace'
}
$WorkspaceMarker=Join-Path $Workspace '.coco80_r5_net_workspace'
$MarkerFields=@{}
foreach($Line in Get-Content -LiteralPath $WorkspaceMarker){
    $Parts=$Line -split '=',2
    if($Parts.Count -eq 2){$MarkerFields[$Parts[0]]=$Parts[1]}
}
$BspConfig=Join-Path $BspInclude 'bspconfig.h'
$TranslationTable=Join-Path $Workspace "$PlatformName\psu_cortexa53_0\standalone_domain\bsp\psu_cortexa53_0\libsrc\standalone_v8_0\src\translation_table.S"
foreach($Path in @($BspConfig,$TranslationTable)){
    if(!(Test-Path -LiteralPath $Path -PathType Leaf)){throw "BSP execution-domain file missing: $Path"}
}
$BspConfigText=Get-Content -Raw -LiteralPath $BspConfig
$TableText=Get-Content -Raw -LiteralPath $TranslationTable
$El1Nonsecure=$BspConfigText -match '(?m)^#define\s+EL1_NONSECURE\s+1\s*$'
$El1Branch=[regex]::Match($TableText,'(?s)#if\s+EL1_NONSECURE(?<Body>.*?)#else')
if(!$El1Branch.Success){throw 'cannot locate the EL1 DDR descriptor in translation_table.S'}
$DdrShareability=if(!$El1Nonsecure){
    # EL3 standalone uses the generated inner-shareable descriptor.  The
    # EL1_NONSECURE conditional contains both descriptors, so parsing only
    # its first branch would invert the EL3 result.
    'inner'
}elseif($El1Branch.Groups['Body'].Value -match '0x405\s*\|\s*\(3\s*<<\s*8\)'){
    'inner'
}else{
    'outer'
}
$ExecutionLevel=if($El1Nonsecure){'el1'}else{'el3'}
if($ExecutionLevel -eq 'el1' -and $DdrShareability -notin @('outer','inner')){
    throw 'EL1 network runner DDR descriptor is neither Outer nor Inner Shareable'
}
if($MarkerFields.ContainsKey('execution_level') -and $MarkerFields['execution_level'] -ne $ExecutionLevel){
    throw 'workspace marker execution level differs from the generated BSP'
}
if($MarkerFields.ContainsKey('ddr_shareability') -and $MarkerFields['ddr_shareability'] -ne $DdrShareability){
    throw 'workspace marker DDR shareability differs from the generated BSP'
}
if($MarkerFields.ContainsKey('runtime_multicore_shareability') -and
   $MarkerFields['runtime_multicore_shareability'] -ne 'inner'){
    throw 'workspace marker runtime multicore shareability must be inner'
}
$MmuHeader=Join-Path $BspInclude 'xil_mmu.h'
if(!(Test-Path -LiteralPath $MmuHeader -PathType Leaf) -or
   !((Get-Content -Raw -LiteralPath $MmuHeader) -match '(?m)^#define\s+NORM_WB_CACHE\s+0x705UL')){
    throw 'BSP does not define the required 0x705 Inner Shareable write-back attribute'
}
if(!(Test-Path -LiteralPath (Join-Path $BspLib 'liblwip4.a') -PathType Leaf)){
    throw 'lwip211 raw IPv4 library is not enabled in the network BSP'
}
$LwipOpts=Join-Path $BspInclude 'lwipopts.h'
if(!(Test-Path -LiteralPath $LwipOpts -PathType Leaf)) { throw 'lwipopts.h is missing' }
$Lwip=Get-Content -Raw -LiteralPath $LwipOpts
foreach($Contract in @(
    '#define NO_SYS 1','#define NO_SYS_NO_TIMERS 1','#define LWIP_DHCP 0',
    '#define TCP_MSS 1460','#define TCP_WND 65535','#define TCP_SND_BUF 65535'
)) {
    if(!$Lwip.Contains($Contract)){throw "lwIP BSP contract mismatch: $Contract"}
}
$Dirty=& git -C $Root status --porcelain
if($LASTEXITCODE -ne 0){throw 'cannot read Git provenance'}
if($Dirty -and !$DevelopmentBuild){throw 'COCO80 network release ELF requires a clean Git worktree'}

$BitSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $BitFile).Hash.ToLowerInvariant()
$XsaSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $Xsa).Hash.ToLowerInvariant()
if($IsAblation){
    $Hardware=@{}
    foreach($Line in Get-Content -LiteralPath $HardwareMetadata){
        $Parts=$Line -split '=',2
        if($Parts.Count -eq 2){$Hardware[$Parts[0]]=$Parts[1]}
    }
    if($Hardware['profile'] -ne $AblationProfile -or
       $Hardware['clock_hz'] -ne '200000000' -or
       $Hardware['git_dirty'] -ne '0' -or
       $Hardware['git_dirty_end'] -ne '0' -or
       $Hardware['provenance_stable'] -ne '1'){
        throw 'ablation hardware metadata is not a clean stable 200 MHz build'
    }
    if($AblationProfile -ne 'abi_v2_release_200' -and
       ($Hardware['release_eligible'] -ne '0' -or
        $Hardware['ablation_profile'] -ne '1')){
        throw 'dedicated ablation hardware is not marked publication-ineligible'
    }
    $HashLines=Get-Content -LiteralPath $HardwareShaManifest
    if(!($HashLines -match "^$BitSha\s+") -or
       !($HashLines -match "^$XsaSha\s+")){
        throw 'BIT/XSA hashes do not match the selected hardware manifest'
    }
}else{
    if($BitSha -ne '1ac606a279d60290935f32c5bc1a028b017d6cca4f22e623bd0bbb4baa3a613e'){
        throw "BIT is not the signed-off r5 artifact: $BitSha"
    }
    if($XsaSha -ne '42d761b1cc77f1a7988d40dd71f0a1c7e1987a057bc457c7d5b55613637e3030'){
        throw "XSA is not the signed-off r5 artifact: $XsaSha"
    }
}
$ParameterSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $ParameterPackage).Hash.ToLowerInvariant()
$QuantSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $QuantizationManifest).Hash.ToLowerInvariant()
$Training=Get-Content -Raw -LiteralPath $TrainingSummary | ConvertFrom-Json
$Fp32=Get-Content -Raw -LiteralPath $Fp32EvaluationSummary | ConvertFrom-Json
$Int8=Get-Content -Raw -LiteralPath $Int8EvaluationSummary | ConvertFrom-Json
if($Training.format -ne 'kv260-coco80-hardware-constrained-qat' -or $Training.version -ne 1){
    throw 'unsupported QAT training summary'
}
if($Fp32.format -ne 'kv260-coco80-deploy416-evaluation' -or $Fp32.mode -ne 'fp32' -or $Fp32.images -ne 5000){
    throw 'FP32 summary is not the full deploy416 validation baseline'
}
if($Int8.format -ne 'kv260-coco80-deploy416-evaluation' -or $Int8.mode -ne 'ptq' -or $Int8.images -ne 5000){
    throw 'INT8 summary is not a full deploy416 validation run'
}
if($Training.artifacts.qat_quant_manifest_sha256 -ne $QuantSha -or $Int8.artifacts.quant_manifest_sha256 -ne $QuantSha){
    throw 'training/evaluation summaries are not bound to the selected quantization manifest'
}
$DeltaAp=[double]$Fp32.coco.metrics.AP50_95-[double]$Int8.coco.metrics.AP50_95
$DeltaAp50=[double]$Fp32.coco.metrics.AP50-[double]$Int8.coco.metrics.AP50
$AccuracyPass=($DeltaAp -le 0.01 -and $DeltaAp50 -le 0.02)
$ReleaseEligible=([bool]$Training.release_eligible -and $Training.status -eq 'PASS' -and $AccuracyPass)
if(!$ReleaseEligible){
    if(!$AllowNonReleaseDeployment){
        throw ('accuracy gate failed; pass -AllowNonReleaseDeployment only for epoch1 integration')
    }
    if(!$Training.deployment_override -or $Training.status -ne 'FAIL'){
        throw 'non-release deployment requires an explicitly overridden failed QAT summary'
    }
}

New-Item -ItemType Directory -Force $BuildDir | Out-Null
$Header=Join-Path $BuildDir 'coco80_generated_config.h'
& $Python -m tools.coco80.vitis_headers --parameter-manifest $ParameterManifest `
    --quantization-manifest $QuantizationManifest --sd-parameter-package $ParameterPackage `
    --bit-sha256 $BitSha --xsa-sha256 $XsaSha --output $Header
if($LASTEXITCODE -ne 0){throw 'generated runtime header failed'}
$GeneratedHeaderText=Get-Content -Raw -LiteralPath $Header
$RuntimeMatch=[regex]::Match(
    $GeneratedHeaderText,
    'static const coco80_accel_generated_config_t coco80_runtime_config = \{\s*(?:\d+U,\s*){11}(?<Software>\d+)U,\s*(?<Hardware>\d+)U,'
)
if(!$RuntimeMatch.Success){throw 'cannot extract software/hardware build CRCs from generated config'}
$SoftwareBuildCrc=[uint32]::Parse($RuntimeMatch.Groups['Software'].Value)
$HardwareBuildCrc=[uint32]::Parse($RuntimeMatch.Groups['Hardware'].Value)
$NetHeader=Join-Path $BuildDir 'coco80_net_build_config.h'
$NetConfig=@"
#ifndef COCO80_NET_BUILD_CONFIG_H
#define COCO80_NET_BUILD_CONFIG_H
#define COCO80_NET_EXPECTED_PARAMETER_SHA256_HEX "$ParameterSha"
#define COCO80_NET_STATIC_BOARD_IP "192.168.10.2"
#define COCO80_NET_STATIC_HOST_IP "192.168.10.1"
#define COCO80_NET_TCP_PORT 5001U
#define COCO80_NET_CHUNK_RECORDS_BUILD 128U
#define COCO80_NET_NON_RELEASE_BUILD 1U
#define COCO80_NET_INITIAL_DDR_SHAREABILITY_$($DdrShareability.ToUpperInvariant()) 1U
#define COCO80_NET_RUNTIME_MULTICORE_INNER_SHAREABLE 1U
#define COCO80_NET_RUNTIME_INFERENCE_INNER_SHAREABLE 1U
#define COCO80_NET_ABLATION_BUILD $([int]$IsAblation)U
#define COCO80_NET_ABLATION_STREAM_CONFIG $AblationStreamCfg`U
#define COCO80_NET_ABLATION_REPRESENTATIVE $([int]$IsRepresentative)U
#define COCO80_NET_ABLATION_LAYER_INDEX $RepresentativeLayerIndex`U
#define COCO80_NET_ABLATION_INPUT_MODE $RepresentativeInputMode`U
#define COCO80_NET_ABLATION_OVERRIDE_MODE $RepresentativeOverrideMode`U
#define COCO80_NET_ABLATION_OVERRIDE_TILE_H $RepresentativeOverrideTileH`U
#define COCO80_NET_ABLATION_OVERRIDE_KERNEL $RepresentativeOverrideKernel`U
#endif
"@
[System.IO.File]::WriteAllText($NetHeader,$NetConfig,(New-Object System.Text.UTF8Encoding($false)))

$Sources=@(
    'main_coco80_net.c','coco80_net_platform.c','coco80_net_protocol.c',
    'coco80_accel.c','coco80_tensor_ops.c','coco80_multicore.c','coco80_decode.c',
    'coco80_sd_protocol.c','coco80_sd_index.c'
)
$Objects=@()
foreach($Name in $Sources){
    $Source=Join-Path $SrcDir $Name
    $Object=Join-Path $BuildDir ($Name -replace '\.c$','.o')
    $AblationDefine=if($IsAblation){'-DCOCO80_ABLATION_RUNTIME=1'}else{'-DCOCO80_ABLATION_RUNTIME=0'}
    $A0Define=if($AblationProfile -eq 'abi_v2_ablation_200_a0'){
        '-DCOCO80_ABLATION_VARIANT_A0=1'
    }else{'-DCOCO80_ABLATION_VARIANT_A0=0'}
    & $Gcc -std=gnu11 -O2 -g -mcpu=cortex-a53 -Wall -Wextra -Werror -ffunction-sections -fdata-sections `
        -DARMA53_64 $AblationDefine $A0Define `
        -I $BuildDir -I $SrcDir -I $BspInclude -c $Source -o $Object
    if($LASTEXITCODE -ne 0){throw "compile failed: $Name"}
    $Objects += $Object
}
$Elf=Join-Path $BuildDir 'coco80_r5_ethernet.elf'
& $Gcc -mcpu=cortex-a53 -o $Elf @Objects '-Wl,--start-group' -llwip4 -lxil -lm -lgcc -lc `
    '-Wl,--end-group' '-Wl,--gc-sections' -L $BspLib -T $Linker
if($LASTEXITCODE -ne 0){throw 'COCO80 Ethernet ELF link failed'}

$WorkerOrigins=@('0x7D000000','0x7D200000','0x7D400000')
$Workers=@()
$BaseLinkerText=Get-Content -Raw -LiteralPath $Linker
for($WorkerId=1;$WorkerId -le 3;$WorkerId++){
    $WorkerMain=Join-Path $BuildDir "main_coco80_worker_$WorkerId.o"
    & $Gcc -std=gnu11 -O2 -g -mcpu=cortex-a53 -Wall -Wextra -Werror -ffunction-sections -fdata-sections `
        -DARMA53_64 "-DC8_WORKER_ID=$WorkerId" -I $BuildDir -I $SrcDir -I $BspInclude `
        -c (Join-Path $SrcDir 'main_coco80_worker.c') -o $WorkerMain
    if($LASTEXITCODE -ne 0){throw "compile failed: A53 worker $WorkerId"}
    $WorkerLinker=Join-Path $BuildDir "coco80_worker_$WorkerId.ld"
    $WorkerLinkerText=$BaseLinkerText.Replace(
        'psu_ddr_0_MEM_0 : ORIGIN = 0x0, LENGTH = 0x7FF00000',
        "psu_ddr_0_MEM_0 : ORIGIN = $($WorkerOrigins[$WorkerId-1]), LENGTH = 0x00100000"
    )
    if($WorkerLinkerText -eq $BaseLinkerText){throw 'worker linker origin replacement failed'}
    [System.IO.File]::WriteAllText(
        $WorkerLinker,$WorkerLinkerText,(New-Object System.Text.UTF8Encoding($false)))
    $WorkerElf=Join-Path $BuildDir "coco80_r5_worker_$WorkerId.elf"
    & $Gcc -mcpu=cortex-a53 -o $WorkerElf $WorkerMain `
        (Join-Path $BuildDir 'coco80_multicore.o') `
        (Join-Path $BuildDir 'coco80_tensor_ops.o') `
        '-Wl,--start-group' -lxil -lm -lgcc -lc '-Wl,--end-group' `
        '-Wl,--gc-sections' -L $BspLib -T $WorkerLinker
    if($LASTEXITCODE -ne 0){throw "worker link failed: A53 #$WorkerId"}
    $Workers += [ordered]@{
        core=$WorkerId;origin=$WorkerOrigins[$WorkerId-1];path=$WorkerElf
        bytes=(Get-Item -LiteralPath $WorkerElf).Length
        sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $WorkerElf).Hash.ToLowerInvariant()
    }
}

$ElfSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $Elf).Hash.ToLowerInvariant()
$Manifest=[ordered]@{
    format='kv260-coco80-ethernet-runner';version=1
    git_sha=(& git -C $Root rev-parse HEAD).Trim();git_dirty=[bool]$Dirty
    development_build=[bool]$DevelopmentBuild
    ablation=[ordered]@{
        enabled=$IsAblation;hardware_profile=$AblationProfile
        stream_config=$AblationStreamCfg
        representative=$IsRepresentative
        representative_layer=$AblationRepresentativeLayer
        secondary_experiment=$AblationSecondary
        representative_override_mode=$RepresentativeOverrideMode
        representative_override_tile_h=$RepresentativeOverrideTileH
        representative_override_kernel=$RepresentativeOverrideKernel
        representative_layer_index=$RepresentativeLayerIndex
        representative_input_mode=$RepresentativeInputMode
        hardware_metadata_sha256=$(if($IsAblation){(Get-FileHash -Algorithm SHA256 -LiteralPath $HardwareMetadata).Hash.ToLowerInvariant()}else{$null})
        hardware_manifest_sha256=$(if($IsAblation){(Get-FileHash -Algorithm SHA256 -LiteralPath $HardwareShaManifest).Hash.ToLowerInvariant()}else{$null})
    }
    release_eligible=$ReleaseEligible;deployment_override=(!$ReleaseEligible)
    network=[ordered]@{
        board_ip='192.168.10.2';host_ip='192.168.10.1';prefix=24;tcp_port=5001;mtu=1500
        chunk_records=$(if($IsRepresentative){1}else{128})
        input_chunk_bytes=66469888;representative=$IsRepresentative
    }
    execution_domain=[ordered]@{
        level=$ExecutionLevel;initial_ddr_shareability=$DdrShareability
        multicore_workspace_shareability='inner';inference_buffer_shareability='inner';tlb_granule_bytes=2097152
        workspace_marker_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $WorkspaceMarker).Hash.ToLowerInvariant()
        libxil_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $BspLib 'libxil.a')).Hash.ToLowerInvariant()
    }
    bit=[ordered]@{path=$BitFile;sha256=$BitSha}
    xsa=[ordered]@{path=$Xsa;sha256=$XsaSha}
    parameter_package=[ordered]@{path=$ParameterPackage;bytes=(Get-Item -LiteralPath $ParameterPackage).Length;sha256=$ParameterSha}
    parameter_manifest_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $ParameterManifest).Hash.ToLowerInvariant()
    quantization_manifest_sha256=$QuantSha
    software_build_crc32=$SoftwareBuildCrc
    hardware_build_crc32=$HardwareBuildCrc
    lwipopts_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $LwipOpts).Hash.ToLowerInvariant()
    elf=[ordered]@{path=$Elf;bytes=(Get-Item -LiteralPath $Elf).Length;sha256=$ElfSha}
    multicore=[ordered]@{worker_count=3;mailbox='0x7D600000';workers=$Workers}
    accuracy=[ordered]@{fp32_ap50_95=[double]$Fp32.coco.metrics.AP50_95;fp32_ap50=[double]$Fp32.coco.metrics.AP50;int8_ap50_95=[double]$Int8.coco.metrics.AP50_95;int8_ap50=[double]$Int8.coco.metrics.AP50;delta_ap50_95_points=100*$DeltaAp;delta_ap50_points=100*$DeltaAp50;gate_pass=$AccuracyPass}
}
$ManifestPath=Join-Path $BuildDir 'coco80_r5_ethernet.manifest.json'
$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ManifestPath -Encoding utf8
Write-Host "PASS: $Elf"
Write-Host "Manifest: $ManifestPath"

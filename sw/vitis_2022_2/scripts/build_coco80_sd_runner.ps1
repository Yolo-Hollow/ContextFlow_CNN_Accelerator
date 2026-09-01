param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$BitFile,
    [Parameter(Mandatory=$true)][string]$Xsa,
    [Parameter(Mandatory=$true)][string]$ParameterManifest,
    [Parameter(Mandatory=$true)][string]$QuantizationManifest,
    [Parameter(Mandatory=$true)][string]$SdParameterPackage,
    [Parameter(Mandatory=$true)][string]$TrainingSummary,
    [Parameter(Mandatory=$true)][string]$Fp32EvaluationSummary,
    [Parameter(Mandatory=$true)][string]$Int8EvaluationSummary,
    [string]$BuildDirectory,
    [switch]$AllowNonReleaseDeployment,
    [ValidateSet('', 'abi_v2_ablation_200_a1', 'abi_v2_ablation_200_a2')]
    [string]$AblationProfile='',
    [ValidateSet('0x2B')][string]$AblationStreamCfg='0x2B',
    [string]$HardwareMetadata,
    [string]$HardwareShaManifest,
    [ValidateSet('accuracy','product','performance','conformance')][string]$Mode='accuracy',
    [ValidateRange(1,5000)][int]$ImageLimit=5000,
    [ValidateRange(0,1000)][int]$PerformanceWarmup=20
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
$SdParameterPackage=[System.IO.Path]::GetFullPath($SdParameterPackage)
$TrainingSummary=[System.IO.Path]::GetFullPath($TrainingSummary)
$Fp32EvaluationSummary=[System.IO.Path]::GetFullPath($Fp32EvaluationSummary)
$Int8EvaluationSummary=[System.IO.Path]::GetFullPath($Int8EvaluationSummary)
$IsAblation=![string]::IsNullOrWhiteSpace($AblationProfile)
$HardwareMetadata=if($IsAblation){[System.IO.Path]::GetFullPath($HardwareMetadata)}else{''}
$HardwareShaManifest=if($IsAblation){[System.IO.Path]::GetFullPath($HardwareShaManifest)}else{''}
$Python='D:\MPSoC\coco80_assets\venv\Scripts\python.exe'
$Gcc='C:\Xilinx\Vitis\2022.2\gnu\aarch64\nt\aarch64-none\bin\aarch64-none-elf-gcc.exe'
$PlatformName='coco80_r5_platform'
$BuildDir=if([string]::IsNullOrWhiteSpace($BuildDirectory)){
    Join-Path $Workspace 'coco80_manual_build'
}else{[System.IO.Path]::GetFullPath($BuildDirectory)}
$SrcDir=Join-Path $SwDir 'src'
$BspRoot=Join-Path $Workspace "$PlatformName\export\$PlatformName\sw\$PlatformName\standalone_domain"
$BspInclude=Join-Path $BspRoot 'bspinclude\include'
$BspLib=Join-Path $BspRoot 'bsplib\lib'
$BspXparameters=Join-Path $BspInclude 'xparameters.h'
$Linker=Join-Path $SrcDir 'coco80_a53.ld'

foreach($Path in @(
    $BitFile,$Xsa,$ParameterManifest,$QuantizationManifest,$SdParameterPackage,
    $TrainingSummary,$Fp32EvaluationSummary,$Int8EvaluationSummary,
    $Python,$Gcc,$Linker
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
if($Mode -eq 'conformance' -and $ImageLimit -gt 128){
    throw 'conformance mode is limited to 128 images because it dumps all 22 tensors'
}
if($Mode -eq 'performance' -and $ImageLimit + $PerformanceWarmup -gt 5000){
    throw 'performance timed images plus warmups must not exceed the 5000-image input index'
}
if(!(Test-Path -LiteralPath (Join-Path $Workspace '.coco80_r5_workspace') -PathType Leaf)){
    throw 'workspace is not a COCO80 r5 workspace'
}
if(!(Test-Path -LiteralPath (Join-Path $BspLib 'libxilffs.a') -PathType Leaf)){
    throw 'xilffs is not enabled in the COCO80 BSP'
}
if(!(Test-Path -LiteralPath $BspXparameters -PathType Leaf) -or
   !((Get-Content -Raw -LiteralPath $BspXparameters) -match '(?m)^#define FILE_SYSTEM_USE_LFN 2\s*$')){
    throw 'COCO80 BSP must enable xilffs use_lfn=2 for the versioned SD path contract'
}
$Dirty=& git -C $Root status --porcelain
if($LASTEXITCODE -ne 0 -or $Dirty){throw 'COCO80 release ELF requires a clean Git worktree'}

New-Item -ItemType Directory -Force $BuildDir | Out-Null
$Header=Join-Path $BuildDir 'coco80_generated_config.h'
$BitSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $BitFile).Hash.ToLowerInvariant()
$XsaSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $Xsa).Hash.ToLowerInvariant()
if($IsAblation){
    $Meta=@{}
    foreach($Line in Get-Content -LiteralPath $HardwareMetadata){
        $Parts=$Line -split '=',2
        if($Parts.Count -ne 2 -or !$Parts[0] -or $Meta.ContainsKey($Parts[0])){
            throw 'ablation hardware metadata is malformed'
        }
        $Meta[$Parts[0]]=$Parts[1]
    }
    $ExpectedPreload=if($AblationProfile -eq 'abi_v2_ablation_200_a2'){'1'}else{'0'}
    $Expected=@{
        profile=$AblationProfile;clock_hz='200000000';ablation_profile='1'
        release_eligible='0';enable_layer_long_hwc_ifm='1';enable_tagged_context='1'
        enable_weight_preload=$ExpectedPreload;enable_fast_context_handoff='0'
        enforce_gates='1';git_dirty='0';git_dirty_end='0';provenance_stable='1'
    }
    foreach($Key in $Expected.Keys){
        if($Meta[$Key] -ne $Expected[$Key]){
            throw "ablation hardware metadata mismatch: $Key=$($Meta[$Key]) expected=$($Expected[$Key])"
        }
    }
    $Gate=Join-Path (Split-Path -Parent $HardwareMetadata) 'system_impl_gate.txt'
    if(!(Test-Path -LiteralPath $Gate -PathType Leaf) -or
       !((Get-Content -Raw -LiteralPath $Gate) -match '(?m)^status=PASS\s*$')){
        throw 'ablation hardware lacks a formal SYSTEM_IMPL PASS gate'
    }
    $Hashes=@{}
    foreach($Line in Get-Content -LiteralPath $HardwareShaManifest){
        $Parts=$Line -split '\s+',2
        if($Parts.Count -ne 2){throw 'ablation hardware SHA manifest is malformed'}
        $Hashes[[System.IO.Path]::GetFileName($Parts[1].Trim())]=$Parts[0].ToLowerInvariant()
    }
    if($Hashes[[System.IO.Path]::GetFileName($BitFile)] -ne $BitSha -or
       $Hashes[[System.IO.Path]::GetFileName($Xsa)] -ne $XsaSha){
        throw 'ablation hardware SHA manifest does not bind BIT/XSA'
    }
}else{
    if($BitSha -ne '1ac606a279d60290935f32c5bc1a028b017d6cca4f22e623bd0bbb4baa3a613e'){
        throw "BIT is not the signed-off r5 artifact: $BitSha"
    }
    if($XsaSha -ne '42d761b1cc77f1a7988d40dd71f0a1c7e1987a057bc457c7d5b55613637e3030'){
        throw "XSA is not the signed-off r5 artifact: $XsaSha"
    }
}
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
        throw ('accuracy gate failed (delta AP50:95={0:N3} points, delta AP50={1:N3} points); use the explicit non-release deployment override only for integration work' -f (100*$DeltaAp),(100*$DeltaAp50))
    }
    if(!$Training.deployment_override -or $Training.status -ne 'FAIL'){
        throw 'non-release deployment requires an explicitly overridden failed QAT summary'
    }
}
& $Python -m tools.coco80.vitis_headers --parameter-manifest $ParameterManifest `
    --quantization-manifest $QuantizationManifest --sd-parameter-package $SdParameterPackage `
    --bit-sha256 $BitSha --xsa-sha256 $XsaSha --output $Header
if($LASTEXITCODE -ne 0){throw 'generated runtime header failed'}

$ModeValue=@{accuracy=0;product=1;performance=2;conformance=0}[$Mode]
$Conformance=if($Mode -eq 'conformance'){1}else{0}
$Sources=@(
    'main_coco80_sd.c','coco80_accel.c','coco80_tensor_ops.c','coco80_decode.c',
    'coco80_sd_protocol.c','coco80_sd_index.c'
)
$Objects=@()
foreach($Name in $Sources){
    $Source=Join-Path $SrcDir $Name
    $Object=Join-Path $BuildDir ($Name -replace '\.c$','.o')
    $AblationDefine=if($IsAblation){'-DCOCO80_ABLATION_RUNTIME=1'}else{'-DCOCO80_ABLATION_RUNTIME=0'}
    $AblationStreamDefine=if($IsAblation){
        "-DCOCO80_SD_ABLATION_STREAM_CONFIG=$AblationStreamCfg"
    }else{'-DCOCO80_SD_ABLATION_STREAM_CONFIG=0xBF'}
    & $Gcc -std=c11 -O2 -g -Wall -Wextra -Werror -ffunction-sections -fdata-sections `
        -DARMA53_64 "-DCOCO80_BOARD_MODE=$ModeValue" `
        "-DCOCO80_BOARD_IMAGE_LIMIT=$ImageLimit" `
        "-DCOCO80_BOARD_PERF_WARMUP=$PerformanceWarmup" `
        "-DCOCO80_BOARD_CONFORMANCE=$Conformance" $AblationDefine $AblationStreamDefine `
        -I $BuildDir -I $SrcDir -I $BspInclude -c $Source -o $Object
    if($LASTEXITCODE -ne 0){throw "compile failed: $Name"}
    $Objects += $Object
}
$Elf=Join-Path $BuildDir "coco80_r5_$Mode.elf"
& $Gcc -o $Elf @Objects '-Wl,--start-group' -lxilffs -lxil -lm -lgcc -lc `
    '-Wl,--end-group' '-Wl,--gc-sections' -L $BspLib -T $Linker
if($LASTEXITCODE -ne 0){throw 'COCO80 ELF link failed'}

$Manifest=[ordered]@{
    format='kv260-coco80-vitis-elf';version=1;mode=$Mode;image_limit=$ImageLimit
    performance_warmup=$PerformanceWarmup;git_sha=(& git -C $Root rev-parse HEAD).Trim()
    bit_sha256=$BitSha;xsa_sha256=$XsaSha
    parameter_manifest_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $ParameterManifest).Hash.ToLowerInvariant()
    quantization_manifest_sha256=$QuantSha
    sd_parameter_package_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $SdParameterPackage).Hash.ToLowerInvariant()
    release_eligible=$ReleaseEligible
    deployment_override=(!$ReleaseEligible)
    ablation=[ordered]@{
        enabled=$IsAblation;hardware_profile=$AblationProfile
        stream_config=$(if($IsAblation){$AblationStreamCfg}else{'0xBF'})
        hardware_metadata_sha256=$(if($IsAblation){(Get-FileHash -Algorithm SHA256 -LiteralPath $HardwareMetadata).Hash.ToLowerInvariant()}else{$null})
        hardware_sha_manifest_sha256=$(if($IsAblation){(Get-FileHash -Algorithm SHA256 -LiteralPath $HardwareShaManifest).Hash.ToLowerInvariant()}else{$null})
    }
    accuracy=[ordered]@{
        fp32_summary_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $Fp32EvaluationSummary).Hash.ToLowerInvariant()
        int8_summary_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $Int8EvaluationSummary).Hash.ToLowerInvariant()
        training_summary_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $TrainingSummary).Hash.ToLowerInvariant()
        fp32_ap50_95=[double]$Fp32.coco.metrics.AP50_95
        fp32_ap50=[double]$Fp32.coco.metrics.AP50
        int8_ap50_95=[double]$Int8.coco.metrics.AP50_95
        int8_ap50=[double]$Int8.coco.metrics.AP50
        delta_ap50_95_points=100*$DeltaAp
        delta_ap50_points=100*$DeltaAp50
        gate_pass=$AccuracyPass
    }
    elf=[ordered]@{path=$Elf;bytes=(Get-Item -LiteralPath $Elf).Length;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $Elf).Hash.ToLowerInvariant()}
}
$ManifestPath=Join-Path $BuildDir "coco80_r5_$Mode.manifest.json"
$Manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ManifestPath -Encoding utf8
Write-Host "PASS: $Elf"

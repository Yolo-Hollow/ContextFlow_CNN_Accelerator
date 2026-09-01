param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$RunnerManifest,
    [Parameter(Mandatory=$true)][string]$BitFile,
    [switch]$AllowNonReleaseDeployment,
    [switch]$AllowAblationHardware,
    [switch]$CheckOnly
)

$ErrorActionPreference='Stop'
$ScriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$Workspace=[System.IO.Path]::GetFullPath($Workspace)
$RunnerManifest=[System.IO.Path]::GetFullPath($RunnerManifest)
$BitFile=[System.IO.Path]::GetFullPath($BitFile)
$Xsct='C:\Xilinx\Vitis\2022.2\bin\xsct.bat'
$DownloadTcl=Join-Path $ScriptDir 'download_run_coco80_sd.tcl'

foreach($Path in @($RunnerManifest,$BitFile,$Xsct,$DownloadTcl)){
    if(!(Test-Path -LiteralPath $Path -PathType Leaf)){throw "required file missing: $Path"}
}
if(!(Test-Path -LiteralPath (Join-Path $Workspace '.coco80_r5_workspace') -PathType Leaf)){
    throw 'workspace is not a COCO80 r5 workspace'
}
$Manifest=Get-Content -Raw -LiteralPath $RunnerManifest | ConvertFrom-Json
if($Manifest.format -ne 'kv260-coco80-vitis-elf' -or $Manifest.version -ne 1){
    throw 'unsupported COCO80 runner manifest'
}
if(!$Manifest.release_eligible){
    if(!$AllowNonReleaseDeployment -or !$Manifest.deployment_override -or $Manifest.accuracy.gate_pass){
        throw 'non-release runner requires the explicit deployment override and a failed accuracy gate'
    }
}
$Elf=[System.IO.Path]::GetFullPath([string]$Manifest.elf.path)
if(!(Test-Path -LiteralPath $Elf -PathType Leaf)){throw "runner ELF missing: $Elf"}
$ElfHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $Elf).Hash.ToLowerInvariant()
$BitHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $BitFile).Hash.ToLowerInvariant()
if((Get-Item -LiteralPath $Elf).Length -ne [long]$Manifest.elf.bytes -or $ElfHash -ne $Manifest.elf.sha256){
    throw 'runner ELF differs from its manifest'
}
if($BitHash -ne $Manifest.bit_sha256){
    throw 'bitstream differs from the runner manifest'
}
$IsAblation=[bool]$Manifest.ablation.enabled
if($IsAblation){
    if(!$AllowAblationHardware -or
       $Manifest.ablation.hardware_profile -notin @('abi_v2_ablation_200_a1','abi_v2_ablation_200_a2') -or
       $Manifest.ablation.stream_config -ne '0x2B' -or
       [string]::IsNullOrWhiteSpace([string]$Manifest.ablation.hardware_metadata_sha256) -or
       [string]::IsNullOrWhiteSpace([string]$Manifest.ablation.hardware_sha_manifest_sha256)){
        throw 'ablation SD runner requires explicit A1/A2 non-release authorization'
    }
}elseif($BitHash -ne '1ac606a279d60290935f32c5bc1a028b017d6cca4f22e623bd0bbb4baa3a613e'){
    throw 'bitstream is not the signed-off r5 artifact'
}

$Arguments=@($DownloadTcl,'-workspace',$Workspace,'-bit_file',$BitFile,'-elf',$Elf)
if($CheckOnly){$Arguments += '-check_only'}
elseif(!(Test-NetConnection -ComputerName 127.0.0.1 -Port 3121 -InformationLevel Quiet)){
    throw 'hw_server is not listening on tcp:3121'
}
& $Xsct @Arguments
if($LASTEXITCODE -ne 0){throw 'COCO80 SD runner download failed'}
Write-Host "PASS: COCO80 $($Manifest.mode) runner selected (release_eligible=$($Manifest.release_eligible))"

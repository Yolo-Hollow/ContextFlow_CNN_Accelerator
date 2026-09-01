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
$DownloadTcl=Join-Path $ScriptDir 'download_run_coco80_net.tcl'
foreach($Path in @($RunnerManifest,$BitFile,$Xsct,$DownloadTcl)){
    if(!(Test-Path -LiteralPath $Path -PathType Leaf)){throw "required file missing: $Path"}
}
if(!(Test-Path -LiteralPath (Join-Path $Workspace '.coco80_r5_net_workspace') -PathType Leaf)){
    throw 'workspace is not a COCO80 r5 Ethernet workspace'
}
$Manifest=Get-Content -Raw -LiteralPath $RunnerManifest | ConvertFrom-Json
if($Manifest.format -ne 'kv260-coco80-ethernet-runner' -or $Manifest.version -ne 1){
    throw 'unsupported COCO80 Ethernet runner manifest'
}
if(!$Manifest.release_eligible){
    if(!$AllowNonReleaseDeployment -or !$Manifest.deployment_override -or $Manifest.accuracy.gate_pass){
        throw 'non-release Ethernet runner requires the explicit failed-model deployment override'
    }
}
$Elf=[System.IO.Path]::GetFullPath([string]$Manifest.elf.path)
if(!(Test-Path -LiteralPath $Elf -PathType Leaf)){throw "runner ELF missing: $Elf"}
$ElfHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $Elf).Hash.ToLowerInvariant()
$BitHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $BitFile).Hash.ToLowerInvariant()
if((Get-Item -LiteralPath $Elf).Length -ne [long]$Manifest.elf.bytes -or $ElfHash -ne $Manifest.elf.sha256){
    throw 'Ethernet runner ELF differs from its manifest'
}
$IsAblation=[bool]$Manifest.ablation.enabled
$DedicatedAblation=$IsAblation -and
    ([string]$Manifest.ablation.hardware_profile -match '^abi_v2_ablation_200_a[0-2]$')
if($BitHash -ne $Manifest.bit.sha256){
    throw 'bitstream differs from the runner manifest'
}
if($DedicatedAblation){
    if(!$AllowAblationHardware){
        throw 'dedicated ablation hardware requires -AllowAblationHardware'
    }
}elseif($AllowAblationHardware){
    throw '-AllowAblationHardware was supplied for a non-ablation runner'
}elseif($BitHash -ne '1ac606a279d60290935f32c5bc1a028b017d6cca4f22e623bd0bbb4baa3a613e'){
    throw 'bitstream is not the signed-off r5 artifact'
}
if($Manifest.network.board_ip -ne '192.168.10.2' -or $Manifest.network.tcp_port -ne 5001){
    throw 'Ethernet runner manifest uses an unexpected address/port'
}
$Workers=@($Manifest.multicore.workers)
if($Manifest.multicore.worker_count -ne 3 -or $Manifest.multicore.mailbox -ne '0x7D600000' -or $Workers.Count -ne 3){
    throw 'Ethernet runner manifest lacks the fixed three-worker A53 contract'
}
$Arguments=@($DownloadTcl,'-workspace',$Workspace,'-bit_file',$BitFile,'-elf',$Elf)
for($Index=0;$Index -lt 3;$Index++){
    $Worker=$Workers[$Index]
    $WorkerPath=[System.IO.Path]::GetFullPath([string]$Worker.path)
    if($Worker.core -ne ($Index+1) -or !(Test-Path -LiteralPath $WorkerPath -PathType Leaf)){
        throw "A53 worker $($Index+1) identity/path is invalid"
    }
    $WorkerHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $WorkerPath).Hash.ToLowerInvariant()
    if((Get-Item -LiteralPath $WorkerPath).Length -ne [long]$Worker.bytes -or $WorkerHash -ne $Worker.sha256){
        throw "A53 worker $($Index+1) differs from its manifest"
    }
    $Arguments += "-worker$($Index+1)", $WorkerPath
}
if($CheckOnly){$Arguments += '-check_only'}
elseif(!(Test-NetConnection -ComputerName 127.0.0.1 -Port 3121 -InformationLevel Quiet)){
    throw 'hw_server is not listening on tcp:3121'
}
& $Xsct @Arguments
if($LASTEXITCODE -ne 0){throw 'COCO80 Ethernet runner download failed'}
Write-Host "PASS: COCO80 Ethernet runner selected (release_eligible=$($Manifest.release_eligible))"

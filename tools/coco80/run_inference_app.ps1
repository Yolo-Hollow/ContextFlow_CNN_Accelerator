param(
    [string]$RunnerManifest='build_vitis_2022_2_coco80_r5_net\coco80_net_manual_build\coco80_r5_ethernet.manifest.json',
    [string]$QuantizationManifest='D:\MPSoC\coco80_runs\r5_coco80_20260816\qat_epoch1_deployment\quant\quantization_manifest.json',
    [string]$OutputRoot='results\coco80\inference_app',
    [string]$BoardIp='192.168.10.2',
    [int]$BoardPort=5001,
    [string]$ListenHost='127.0.0.1',
    [int]$WebPort=8088,
    [switch]$OpenBrowser
)

$ErrorActionPreference='Stop'
$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Python='C:\Users\hp\.conda\envs\pytorch_env\python.exe'
$ResolveFromRepo={param([string]$Path)
    if([System.IO.Path]::IsPathRooted($Path)){return [System.IO.Path]::GetFullPath($Path)}
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}
$RunnerManifest=& $ResolveFromRepo $RunnerManifest
$QuantizationManifest=& $ResolveFromRepo $QuantizationManifest
$OutputRoot=& $ResolveFromRepo $OutputRoot
foreach($Path in @($Python,$RunnerManifest,$QuantizationManifest)){
    if(!(Test-Path -LiteralPath $Path -PathType Leaf)){throw "required file missing: $Path"}
}
$Arguments=@(
    '-m','tools.coco80.inference_app',
    '--runner-manifest',[System.IO.Path]::GetFullPath($RunnerManifest),
    '--quantization-manifest',[System.IO.Path]::GetFullPath($QuantizationManifest),
    '--output-root',$OutputRoot,
    '--board-ip',$BoardIp,'--board-port',$BoardPort,
    '--host',$ListenHost,'--port',$WebPort,
    '--allow-development'
)
if($OpenBrowser){$Arguments += '--open-browser'}
Push-Location $RepoRoot
try { & $Python @Arguments }
finally { Pop-Location }

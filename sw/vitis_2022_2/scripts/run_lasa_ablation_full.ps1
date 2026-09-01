param(
    [ValidateSet('a1','a2','a3')][string]$Variant,
    [ValidateSet('0x2B','0x3B','0x3F','0xBF')][string]$StreamCfg,
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$BitFile,
    [Parameter(Mandatory=$true)][string]$Xsa,
    [Parameter(Mandatory=$true)][string]$HardwareMetadata,
    [Parameter(Mandatory=$true)][string]$HardwareShaManifest,
    [Parameter(Mandatory=$true)][string]$PowerReport,
    [Parameter(Mandatory=$true)][string]$PowerAssumptions,
    [Parameter(Mandatory=$true)][string]$ParameterManifest,
    [Parameter(Mandatory=$true)][string]$QuantizationManifest,
    [Parameter(Mandatory=$true)][string]$ParameterPackage,
    [Parameter(Mandatory=$true)][string]$TrainingSummary,
    [Parameter(Mandatory=$true)][string]$Fp32EvaluationSummary,
    [Parameter(Mandatory=$true)][string]$Int8EvaluationSummary,
    [Parameter(Mandatory=$true)][string]$InputIndexJson,
    [Parameter(Mandatory=$true)][string]$ModelSpec,
    [Parameter(Mandatory=$true)][string]$OutputRoot,
    [ValidateRange(0,1000000)][int]$StartRecord=0,
    [ValidateRange(1,128)][int]$ChunkRecords=128,
    [ValidateRange(1,10)][int]$Sessions=3,
    [ValidateRange(1,1000)][int]$Warmup=20,
    [ValidateRange(1,100000)][int]$Timed=1000,
    [switch]$CheckOnly
)

$ErrorActionPreference='Stop'
$ScriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$Root=[System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..\..\..'))
$Python='D:\MPSoC\coco80_assets\venv\Scripts\python.exe'
$BuildRunner=Join-Path $ScriptDir 'build_coco80_net_runner.ps1'
$RunBoard=Join-Path $ScriptDir 'run_coco80_net_board.ps1'
$Profile=if($Variant -eq 'a3'){'abi_v2_release_200'}else{"abi_v2_ablation_200_$Variant"}
if($Variant -in @('a1','a2') -and $StreamCfg -ne '0x2B'){
    throw 'A1/A2 full-network experiments are fixed to STREAM_CFG=0x2B'
}

$Paths=@(
    'Workspace','BitFile','Xsa','HardwareMetadata','HardwareShaManifest','PowerReport','PowerAssumptions',
    'ParameterManifest','QuantizationManifest','ParameterPackage','TrainingSummary',
    'Fp32EvaluationSummary','Int8EvaluationSummary','InputIndexJson','ModelSpec','OutputRoot'
)
foreach($name in $Paths){
    Set-Variable -Name $name -Value ([System.IO.Path]::GetFullPath((Get-Variable $name -ValueOnly)))
}
foreach($path in @(
    $BitFile,$Xsa,$HardwareMetadata,$HardwareShaManifest,$PowerReport,$PowerAssumptions,$ParameterManifest,
    $QuantizationManifest,$ParameterPackage,$TrainingSummary,$Fp32EvaluationSummary,
    $Int8EvaluationSummary,$InputIndexJson,$ModelSpec,$BuildRunner,$RunBoard,$Python
)){
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw "required file missing: $path"}
}
if(!(Test-Path -LiteralPath $Workspace -PathType Container)){throw "workspace missing: $Workspace"}

$CaseRoot=Join-Path $OutputRoot "$Variant`_$($StreamCfg.Substring(2).ToLowerInvariant())"
$BuildDir=Join-Path $CaseRoot 'software'
$ManifestPath=Join-Path $CaseRoot 'ablation_manifest.json'
$SamplesPath=Join-Path $CaseRoot 'ablation_samples.csv'
if((Test-Path -LiteralPath $CaseRoot) -and !$CheckOnly){throw "fresh case directory exists: $CaseRoot"}
if(!$CheckOnly){New-Item -ItemType Directory -Path $CaseRoot|Out-Null}

$BuildArgs=@{
    Workspace=$Workspace;BitFile=$BitFile;Xsa=$Xsa;ParameterManifest=$ParameterManifest
    QuantizationManifest=$QuantizationManifest;ParameterPackage=$ParameterPackage
    TrainingSummary=$TrainingSummary;Fp32EvaluationSummary=$Fp32EvaluationSummary
    Int8EvaluationSummary=$Int8EvaluationSummary;BuildDirectory=$BuildDir
    AllowNonReleaseDeployment=$true;AblationProfile=$Profile
    AblationStreamCfg=$StreamCfg;HardwareMetadata=$HardwareMetadata
    HardwareShaManifest=$HardwareShaManifest
}
if(!$CheckOnly){& $BuildRunner @BuildArgs}
if(!$CheckOnly -and $LASTEXITCODE -ne 0){throw 'ablation Ethernet ELF build failed'}
$RunnerManifest=Join-Path $BuildDir 'coco80_r5_ethernet.manifest.json'

$ManifestArgs=@(
    '-m','tools.coco80.ablation','manifest','--variant',$Variant,
    '--stream-config',$StreamCfg,'--experiment','full','--sessions',[string]$Sessions,
    '--case-label',"$Variant`_$($StreamCfg.Substring(2).ToLowerInvariant())",
    '--warmup',[string]$Warmup,'--timed',[string]$Timed,
    '--hardware-metadata',$HardwareMetadata,'--hardware-sha-manifest',$HardwareShaManifest,
    '--power-report',$PowerReport,'--power-assumptions',$PowerAssumptions,
    '--bit',$BitFile,'--xsa',$Xsa,'--model-spec',$ModelSpec,
    '--parameter-manifest',$ParameterManifest,'--input-index',$InputIndexJson,
    '--output',$ManifestPath
)
if(!$CheckOnly){& $Python @ManifestArgs}
if(!$CheckOnly -and $LASTEXITCODE -ne 0){throw 'ablation manifest creation failed'}

$TimingArgs=@()
for($session=1;$session -le $Sessions;$session++){
    $SessionDir=Join-Path $CaseRoot "session_$session"
    if(!$CheckOnly){
        $BoardArgs=@{
            Workspace=$Workspace;RunnerManifest=$RunnerManifest;BitFile=$BitFile
            AllowNonReleaseDeployment=$true
        }
        if($Variant -ne 'a3'){$BoardArgs.AllowAblationHardware=$true}
        & $RunBoard @BoardArgs
        if($LASTEXITCODE -ne 0){throw "session $session JTAG launch failed"}
        $ready=$false
        for($attempt=0;$attempt -lt 120 -and !$ready;$attempt++){
            try{
                $client=New-Object Net.Sockets.TcpClient
                $async=$client.BeginConnect('192.168.10.2',5001,$null,$null)
                $ready=$async.AsyncWaitHandle.WaitOne(1000,$false) -and $client.Connected
                $client.Close()
            }catch{$ready=$false}
            if(!$ready){Start-Sleep -Seconds 1}
        }
        if(!$ready){throw "session $session board TCP service did not become ready"}
        & $Python -m tools.coco80.net_runner `
            --runner-manifest $RunnerManifest --quantization-manifest $QuantizationManifest `
            --input-index-json $InputIndexJson --output-dir $SessionDir --mode timing-demo `
            --start-record $StartRecord --record-count ($Warmup+$Timed) `
            --warmup-records $Warmup --chunk-records $ChunkRecords --allow-development
        if($LASTEXITCODE -ne 0){throw "session $session network performance run failed"}
    }
    $TimingArgs+=@('--timing',(Join-Path $SessionDir 'extended_timing.bin'),'--session',[string]$session)
}

if(!$CheckOnly){
    & $Python -m tools.coco80.ablation samples --manifest $ManifestPath @TimingArgs --output $SamplesPath
    if($LASTEXITCODE -ne 0){throw 'ablation sample extraction failed'}
    Write-Host "PASS: $Variant/$StreamCfg sessions=$Sessions warmup=$Warmup timed=$Timed"
}else{
    Write-Host "PASS: full-network ablation invocation check variant=$Variant stream=$StreamCfg"
}

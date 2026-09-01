param(
    [ValidateSet('a0','a1','a2','a3')][string]$Variant,
    [ValidateSet('m0','m13','m14','m16','m19','p4_detect','p5_detect')][string]$Layer,
    [ValidateSet('correctness','performance')][string]$Mode,
    [ValidateSet('representative','native1x1','tile')][string]$Experiment='representative',
    [ValidateSet('release','sparse3x3','small_tile')][string]$Configuration='release',
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
    [Parameter(Mandatory=$true)][string]$SelectionIndexBin,
    [Parameter(Mandatory=$true)][string]$ModelSpec,
    [Parameter(Mandatory=$true)][string]$OutputRoot,
    [ValidateRange(0,10)][int]$Sessions=0,
    [switch]$CheckOnly
)

$ErrorActionPreference='Stop'
$ScriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$Root=[System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..\..\..'))
$Python='D:\MPSoC\coco80_assets\venv\Scripts\python.exe'
$BuildRunner=Join-Path $ScriptDir 'build_coco80_net_runner.ps1'
$RunBoard=Join-Path $ScriptDir 'run_coco80_net_board.ps1'
$Profile=if($Variant -eq 'a3'){'abi_v2_release_200'}else{"abi_v2_ablation_200_$Variant"}
$StreamCfg=if($Variant -eq 'a0'){'0x29'}else{'0x2B'}
$Secondary=''
if($Experiment -eq 'representative'){
    if($Layer -notin @('m0','m13','m19','p4_detect') -or $Configuration -ne 'release'){
        throw 'primary representative experiment requires m0/m13/m19/P4 and release configuration'
    }
    $CaseLabel=$Variant
}elseif($Experiment -eq 'native1x1'){
    if($Variant -ne 'a3' -or $Layer -notin @('m14','m16','p4_detect','p5_detect') -or
       $Configuration -notin @('release','sparse3x3')){
        throw 'native1x1 requires A3, a native 1x1 layer, and release/sparse3x3'
    }
    if($Configuration -eq 'sparse3x3'){$Secondary='sparse3x3'}
    $CaseLabel=$Configuration
}else{
    if($Variant -ne 'a3' -or $Layer -notin @('m13','m19') -or
       $Configuration -notin @('release','small_tile')){
        throw 'tile experiment requires A3, m13/m19, and release/small_tile'
    }
    if($Configuration -eq 'small_tile'){$Secondary='tile'}
    if($Layer -eq 'm13'){$CaseLabel=if($Secondary){'tile_h4'}else{'tile_h8'}}
    else{$CaseLabel=if($Secondary){'tile_h3'}else{'tile_h6'}}
}
$ExpectedSessions=if($Mode -eq 'correctness'){1}else{3}
if($Sessions -eq 0){$Sessions=$ExpectedSessions}
if($Sessions -ne $ExpectedSessions){throw "$Mode requires exactly $ExpectedSessions session(s)"}
$Warmup=if($Mode -eq 'correctness'){0}else{20}
$Timed=if($Mode -eq 'correctness'){128}else{100}
$Records=$Warmup+$Timed
$HostSecondary=if([string]::IsNullOrWhiteSpace($Secondary)){'none'}else{$Secondary}

foreach($Name in @(
    'Workspace','BitFile','Xsa','HardwareMetadata','HardwareShaManifest','PowerReport','PowerAssumptions',
    'ParameterManifest','QuantizationManifest','ParameterPackage','TrainingSummary',
    'Fp32EvaluationSummary','Int8EvaluationSummary','InputIndexJson',
    'SelectionIndexBin','ModelSpec','OutputRoot'
)){
    Set-Variable -Name $Name -Value ([System.IO.Path]::GetFullPath((Get-Variable $Name -ValueOnly)))
}
foreach($Path in @(
    $BitFile,$Xsa,$HardwareMetadata,$HardwareShaManifest,$PowerReport,$PowerAssumptions,$ParameterManifest,
    $QuantizationManifest,$ParameterPackage,$TrainingSummary,$Fp32EvaluationSummary,
    $Int8EvaluationSummary,$InputIndexJson,$SelectionIndexBin,$ModelSpec,
    $BuildRunner,$RunBoard,$Python
)){
    if(!(Test-Path -LiteralPath $Path -PathType Leaf)){throw "required file missing: $Path"}
}
if(!(Test-Path -LiteralPath $Workspace -PathType Container)){throw "workspace missing: $Workspace"}

$CaseRoot=Join-Path $OutputRoot "$Experiment`_$Variant`_$Layer`_$CaseLabel`_$Mode"
$BuildDir=Join-Path $CaseRoot 'software'
$ManifestPath=Join-Path $CaseRoot 'ablation_manifest.json'
$SamplesPath=Join-Path $CaseRoot 'ablation_samples.csv'
if((Test-Path -LiteralPath $CaseRoot) -and !$CheckOnly){throw "fresh case exists: $CaseRoot"}
if(!$CheckOnly){New-Item -ItemType Directory -Path $CaseRoot|Out-Null}

$BuildArgs=@{
    Workspace=$Workspace;BitFile=$BitFile;Xsa=$Xsa;ParameterManifest=$ParameterManifest
    QuantizationManifest=$QuantizationManifest;ParameterPackage=$ParameterPackage
    TrainingSummary=$TrainingSummary;Fp32EvaluationSummary=$Fp32EvaluationSummary
    Int8EvaluationSummary=$Int8EvaluationSummary;BuildDirectory=$BuildDir
    AllowNonReleaseDeployment=$true;AblationProfile=$Profile
    AblationStreamCfg=$StreamCfg;AblationRepresentativeLayer=$Layer
    AblationSecondary=$Secondary
    HardwareMetadata=$HardwareMetadata;HardwareShaManifest=$HardwareShaManifest
}
if(!$CheckOnly){& $BuildRunner @BuildArgs}
if(!$CheckOnly -and $LASTEXITCODE -ne 0){throw 'representative ELF build failed'}
$RunnerManifest=Join-Path $BuildDir 'coco80_r5_ethernet.manifest.json'

if(!$CheckOnly){
    & $Python -m tools.coco80.ablation manifest --variant $Variant `
        --stream-config $StreamCfg --experiment $Experiment --case-label $CaseLabel --layers $Layer `
        --sessions $Sessions --warmup $Warmup --timed $Timed `
        --hardware-metadata $HardwareMetadata `
        --hardware-sha-manifest $HardwareShaManifest --bit $BitFile --xsa $Xsa `
        --power-report $PowerReport --power-assumptions $PowerAssumptions `
        --model-spec $ModelSpec --parameter-manifest $ParameterManifest `
        --input-index $SelectionIndexBin --output $ManifestPath
    if($LASTEXITCODE -ne 0){throw 'representative ablation manifest failed'}
}

$TimingArgs=@()
for($Session=1;$Session -le $Sessions;$Session++){
    $SessionDir=Join-Path $CaseRoot "session_$Session"
    if(!$CheckOnly){
        $BoardArgs=@{
            Workspace=$Workspace;RunnerManifest=$RunnerManifest;BitFile=$BitFile
            AllowNonReleaseDeployment=$true
        }
        if($Variant -ne 'a3'){$BoardArgs.AllowAblationHardware=$true}
        & $RunBoard @BoardArgs
        if($LASTEXITCODE -ne 0){throw "session $Session JTAG launch failed"}
        $Ready=$false
        for($Attempt=0;$Attempt -lt 120 -and !$Ready;$Attempt++){
            try{
                $Client=New-Object Net.Sockets.TcpClient
                $Async=$Client.BeginConnect('192.168.10.2',5001,$null,$null)
                $Ready=$Async.AsyncWaitHandle.WaitOne(1000,$false) -and $Client.Connected
                $Client.Close()
            }catch{$Ready=$false}
            if(!$Ready){Start-Sleep -Seconds 1}
        }
        if(!$Ready){throw "session $Session board TCP service did not become ready"}
        & $Python -m tools.coco80.ablation_representative_runner `
            --runner-manifest $RunnerManifest `
            --quantization-manifest $QuantizationManifest `
            --input-index-json $InputIndexJson --selection-index-bin $SelectionIndexBin `
            --model-spec $ModelSpec --layer $Layer --mode $Mode `
            --secondary $HostSecondary `
            --record-count $Records --output-dir $SessionDir
        if($LASTEXITCODE -ne 0){throw "session $Session representative run failed"}
    }
    $TimingArgs+=@('--timing',(Join-Path $SessionDir 'extended_timing.bin'),
                   '--session',[string]$Session)
}

if(!$CheckOnly){
    & $Python -m tools.coco80.ablation samples --manifest $ManifestPath `
        @TimingArgs --output $SamplesPath
    if($LASTEXITCODE -ne 0){throw 'representative sample extraction failed'}
    Write-Host "PASS: $Experiment $Variant/$Layer/$CaseLabel/$Mode records=$Records sessions=$Sessions"
}else{
    Write-Host "PASS: $Experiment invocation check $Variant/$Layer/$CaseLabel/$Mode"
}

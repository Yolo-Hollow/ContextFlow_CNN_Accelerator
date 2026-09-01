param(
    [ValidateSet('a0','a1','a2','all')]
    [string]$Variant='all',
    [ValidateRange(1,32)][int]$Jobs=12,
    [switch]$CheckOnly
)

$ErrorActionPreference='Stop'
$ScriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$Root=[System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..\..\..'))
$Vivado='C:\Xilinx\Vivado\2022.2\bin\vivado.bat'
$BuildScript=Join-Path $Root 'tcl\build_kv260_system_xck26.tcl'
$PowerScript=Join-Path $Root 'tcl\report_post_route_power.tcl'
$Variants=if($Variant -eq 'all'){@('a0','a1','a2')}else{@($Variant)}

function Require-CleanSource {
    $status=@(& git -C $Root status --porcelain=v1 --untracked-files=all)
    if($LASTEXITCODE -ne 0 -or $status.Count -ne 0){
        throw "formal ablation build requires a completely clean source worktree"
    }
    $eda=@(Get-Process vivado,xsim,xelab,xvlog,xvhdl -ErrorAction SilentlyContinue)
    if($eda.Count -ne 0){
        throw "formal ablation build refuses to share the machine with EDA processes: $($eda.Id -join ',')"
    }
}

function Read-KeyValue([string]$Path) {
    $values=@{}
    foreach($line in Get-Content -LiteralPath $Path){
        $parts=$line -split '=',2
        if($parts.Count -ne 2 -or $values.ContainsKey($parts[0])){
            throw "malformed metadata: $Path"
        }
        $values[$parts[0]]=$parts[1]
    }
    return $values
}

function Verify-Build([string]$Name,[string]$Profile,[string]$Directory) {
    $reports=Join-Path $Directory 'reports'
    $metadataPath=Join-Path $reports 'build_profile.txt'
    $gatePath=Join-Path $reports 'system_impl_gate.txt'
    $hashPath=Join-Path $reports 'system_artifacts.sha256'
    $xsaPath=Join-Path $Directory 'conv_accel_ps_dma_minimal.xsa'
    $bitPath=Join-Path $Directory 'conv_accel_ps_dma_minimal\conv_accel_ps_dma_minimal.runs\impl_1\conv_accel_ps_dma_wrapper.bit'
    $powerPath=Join-Path $reports 'system_power_post_route.rpt'
    $powerAssumptions=Join-Path $reports 'system_power_assumptions.txt'
    foreach($path in @($metadataPath,$gatePath,$hashPath,$xsaPath,$bitPath,$powerPath,$powerAssumptions)){
        if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw "missing formal artifact: $path"}
    }
    $metadata=Read-KeyValue $metadataPath
    $expected=@{
        profile=$Profile;clock_hz='200000000';rows='18';cols='16';cout_tile='32';
        enable_tagged_context='1';enforce_gates='1';release_eligible='0';
        ablation_profile='1';git_dirty='0';git_dirty_end='0';provenance_stable='1'
    }
    $features=@{a0=@('0','0','0');a1=@('1','0','0');a2=@('1','1','0')}[$Name]
    $expected.enable_layer_long_hwc_ifm=$features[0]
    $expected.enable_weight_preload=$features[1]
    $expected.enable_fast_context_handoff=$features[2]
    foreach($key in $expected.Keys){
        if($metadata[$key] -ne $expected[$key]){
            throw "$Name metadata $key=$($metadata[$key]), expected=$($expected[$key])"
        }
    }
    if(!((Get-Content -Raw -LiteralPath $gatePath) -match '(?m)^status=PASS$')){
        throw "$Name did not pass SYSTEM_IMPL"
    }
    $assumptions=Read-KeyValue $powerAssumptions
    if($assumptions.measurement -ne 'post_route_estimated' -or
       $assumptions.activity_source -ne 'vectorless' -or
       $assumptions.default_toggle_rate_percent -ne '12.5' -or
       $assumptions.default_static_probability -ne '0.5'){
        throw "$Name power estimate does not use the common vectorless assumptions"
    }
    $bitSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $bitPath).Hash.ToLowerInvariant()
    $xsaSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $xsaPath).Hash.ToLowerInvariant()
    $hashText=Get-Content -Raw -LiteralPath $hashPath
    if($hashText -notmatch "(?m)^$bitSha\s+conv_accel_ps_dma_wrapper\.bit$" -or
       $hashText -notmatch "(?m)^$xsaSha\s+conv_accel_ps_dma_minimal\.xsa$"){
        throw "$Name artifact hashes do not close against system_artifacts.sha256"
    }
    $summary=[ordered]@{
        format='kv260-lasa-ablation-hardware';version=1;status='PASS';variant=$Name
        profile=$Profile;git_sha=$metadata.git_sha;clock_hz=200000000
        bit=[ordered]@{path=$bitPath;bytes=(Get-Item $bitPath).Length;sha256=$bitSha}
        xsa=[ordered]@{path=$xsaPath;bytes=(Get-Item $xsaPath).Length;sha256=$xsaSha}
        reports=[ordered]@{
            metadata=$metadataPath;system_impl_gate=$gatePath;sha_manifest=$hashPath
            power=[ordered]@{path=$powerPath;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $powerPath).Hash.ToLowerInvariant()}
            power_assumptions=[ordered]@{path=$powerAssumptions;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $powerAssumptions).Hash.ToLowerInvariant()}
        }
    }
    $summaryPath=Join-Path $reports 'ablation_hardware_summary.json'
    [System.IO.File]::WriteAllText(
        $summaryPath,($summary|ConvertTo-Json -Depth 6),
        (New-Object System.Text.UTF8Encoding($false)))
    return $summary
}

if(!(Test-Path -LiteralPath $Vivado -PathType Leaf)){throw "Vivado 2022.2 is missing: $Vivado"}
Require-CleanSource
$results=@()
$failures=@()
foreach($name in $Variants){
    $profile="abi_v2_ablation_200_$name"
    $directory=Join-Path $Root "build_abi_v2_ablation_200_$name"
    if($CheckOnly){
        & $Vivado -mode batch -notrace -nojournal -nolog -source $BuildScript -tclargs `
            -profile $profile -build_dir $directory -jobs $Jobs -check_only
        if($LASTEXITCODE -ne 0){throw "$name check-only failed"}
        if(Test-Path -LiteralPath $directory){throw "$name check-only created its build directory"}
        continue
    }
    if(Test-Path -LiteralPath $directory){
        throw "fresh build directory already exists: $directory"
    }
    $log=Join-Path $Root "v200_ablation_$name.log"
    $journal=Join-Path $Root "v200_ablation_$name.jou"
    if((Test-Path -LiteralPath $log) -or (Test-Path -LiteralPath $journal)){
        throw "fresh Vivado log/journal already exists for $name"
    }
    & $Vivado -mode batch -notrace -log $log -journal $journal -source $BuildScript -tclargs `
        -profile $profile -build_dir $directory -jobs $Jobs
    if($LASTEXITCODE -ne 0){
        $reportDir=Join-Path $directory 'reports'
        $gatePath=$null
        foreach($candidate in @('system_impl_gate.txt','system_place_gate.txt','system_synth_gate.txt')){
            $probe=Join-Path $reportDir $candidate
            if(Test-Path -LiteralPath $probe -PathType Leaf){$gatePath=$probe;break}
        }
        $profilePath=Join-Path $reportDir 'build_profile.txt'
        $failure=[ordered]@{
            format='kv260-lasa-ablation-hardware';version=1;status='FAIL'
            variant=$name;profile=$profile;reason='formal implementation failed'
            git_sha=(& git -C $Root rev-parse HEAD).Trim()
            release_eligible=$false;bit_xsa_published=$false
            gate=$(if($gatePath){[ordered]@{
                path=[System.IO.Path]::GetFullPath($gatePath)
                bytes=(Get-Item -LiteralPath $gatePath).Length
                sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $gatePath).Hash.ToLowerInvariant()
            }}else{$null})
            build_profile=$(if(Test-Path -LiteralPath $profilePath -PathType Leaf){[ordered]@{
                path=[System.IO.Path]::GetFullPath($profilePath)
                bytes=(Get-Item -LiteralPath $profilePath).Length
                sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $profilePath).Hash.ToLowerInvariant()
            }}else{$null})
            log=[ordered]@{
                path=[System.IO.Path]::GetFullPath($log)
                bytes=(Get-Item -LiteralPath $log).Length
                sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $log).Hash.ToLowerInvariant()
            }
            journal=[ordered]@{
                path=[System.IO.Path]::GetFullPath($journal)
                bytes=(Get-Item -LiteralPath $journal).Length
                sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $journal).Hash.ToLowerInvariant()
            }
        }
        $failures+=$failure
        if(Test-Path -LiteralPath $reportDir -PathType Container){
            [System.IO.File]::WriteAllText(
                (Join-Path $reportDir 'ablation_hardware_failure.json'),
                ($failure|ConvertTo-Json -Depth 4),
                (New-Object System.Text.UTF8Encoding($false)))
        }
        Write-Warning "$name stopped fail-closed at its formal implementation gate"
        continue
    }
    $routed=Join-Path $directory 'conv_accel_ps_dma_minimal\conv_accel_ps_dma_minimal.runs\impl_1\conv_accel_ps_dma_wrapper_routed.dcp'
    $powerLog=Join-Path $Root "v200_ablation_$name`_power.log"
    $powerJournal=Join-Path $Root "v200_ablation_$name`_power.jou"
    if(!(Test-Path -LiteralPath $routed -PathType Leaf)){throw "$name routed DCP is missing"}
    if((Test-Path -LiteralPath $powerLog) -or (Test-Path -LiteralPath $powerJournal)){
        throw "fresh power log/journal already exists for $name"
    }
    & $Vivado -mode batch -notrace -log $powerLog -journal $powerJournal -source $PowerScript -tclargs `
        $routed (Join-Path $directory 'reports')
    if($LASTEXITCODE -ne 0){throw "$name post-route power estimate failed"}
    $results+=Verify-Build $name $profile $directory
    Require-CleanSource
}

if($CheckOnly){
    Write-Host "PASS: ablation hardware check-only variants=$($Variants -join ',')"
}else{
    [ordered]@{passed=$results;failed=$failures}|ConvertTo-Json -Depth 8
    if($failures.Count -ne 0){throw "one or more ablation variants failed formal gates: $($failures.variant -join ',')"}
}

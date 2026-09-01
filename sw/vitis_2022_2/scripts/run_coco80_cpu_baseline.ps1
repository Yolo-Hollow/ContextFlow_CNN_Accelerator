param(
    [Parameter(Mandatory=$true)][ValidateSet('scalar','neon4')][string]$Mode,
    [Parameter(Mandatory=$true)][ValidateRange(1,99)][int]$Repetition,
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [Parameter(Mandatory=$true)][string]$BuildDirectory,
    [Parameter(Mandatory=$true)][string]$ResultDirectory,
    [string]$Workspace = 'D:\MPSoC\accelerator_systolic\build_vitis_2022_2_coco80_r5_net'
)
$ErrorActionPreference='Stop'
$ScriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$Root=[System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..\..\..'))
$Xsct='C:\Xilinx\Vitis\2022.2\bin\xsct.bat'
$Tcl=Join-Path $ScriptDir 'download_run_coco80_cpu_baseline.tcl'
$Bit=Join-Path $Root 'build_abi_v2_release_r5\conv_accel_ps_dma_minimal\conv_accel_ps_dma_minimal.runs\impl_1\conv_accel_ps_dma_wrapper.bit'
$PackageDirectory=[System.IO.Path]::GetFullPath($PackageDirectory)
$BuildDirectory=[System.IO.Path]::GetFullPath($BuildDirectory)
$ResultDirectory=[System.IO.Path]::GetFullPath($ResultDirectory)
$Params=Join-Path $PackageDirectory 'coco80_cpu_params_kco.bin'
$Input=Join-Path $PackageDirectory 'coco80_cpu_input_u8.bin'
$Expected=Join-Path $PackageDirectory 'coco80_cpu_expected_heads_u8.bin'
$ModeDir=if($Mode -eq 'scalar'){'scalar'}else{'neon4'}
$Elf=Join-Path $BuildDirectory "$ModeDir\coco80_cpu_$Mode.elf"
$Result=Join-Path $ResultDirectory ("{0}_rep{1:D2}.bin" -f $Mode,$Repetition)
$Args=@($Tcl,'-mode',$Mode,'-workspace',$Workspace,'-bit_file',$Bit,
    '-elf',$Elf,'-params',$Params,'-input',$Input,'-expected',$Expected,
    '-result',$Result,'-timeout_seconds','1800')
if($Mode -eq 'neon4'){
    foreach($Worker in 1..3){$Args += @("-worker$Worker",(Join-Path $BuildDirectory "neon4\coco80_cpu_worker_$Worker.elf"))}
}
New-Item -ItemType Directory -Force $ResultDirectory | Out-Null
& $Xsct @Args
if($LASTEXITCODE -ne 0){throw "$Mode repetition $Repetition failed"}
if(!(Test-Path -LiteralPath $Result -PathType Leaf) -or
   (Get-Item -LiteralPath $Result).Length -lt 1216){
    throw "$Mode repetition $Repetition did not produce a complete result record"
}
$Bytes=[System.IO.File]::ReadAllBytes($Result)
$Magic=[BitConverter]::ToUInt32($Bytes,0)
$Status=[BitConverter]::ToInt32($Bytes,8)
if($Magic -ne 0x42433843 -or $Status -ne 2){
    throw "$Mode repetition $Repetition result failed: magic=0x$($Magic.ToString('x8')) status=$Status"
}
Write-Host "PASS: $Result"

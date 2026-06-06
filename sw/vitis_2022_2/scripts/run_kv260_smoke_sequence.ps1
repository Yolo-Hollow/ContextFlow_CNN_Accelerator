param(
    [string]$PortName = "COM8",
    [int]$BaudRate = 115200,
    [int]$CaptureSeconds = 90,
    [switch]$SkipBit,
    [switch]$FastRun,
    [switch]$RunConv0Tiles,
    [switch]$RunLayer06Tile4,
    [switch]$RunLayer06Tiles,
    [switch]$RunLayer06PoolTiles,
    [switch]$RunConv4PoolTiles,
    [switch]$RunConv3Conv4Chain,
    [switch]$RunConv4Conv5Chain,
    [switch]$RunConv0Conv4Chain,
    [switch]$RunConv0Conv5Chain,
    [switch]$RunDeterministic,
    [string]$BuildDirName = "build_system_xck26_kv260"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SwDir = Split-Path -Parent $ScriptDir
$Root = Split-Path -Parent (Split-Path -Parent $SwDir)
$Xsct = "C:\Xilinx\Vitis\2022.2\bin\xsct.bat"
$HwServer = "C:\Xilinx\Vivado\2022.2\bin\hw_server.bat"
$BuildDir = Join-Path $Root $BuildDirName
$LogDir = Join-Path $BuildDir "board_smoke_logs"
$BitFile = Join-Path $BuildDir "conv_accel_ps_dma_minimal\conv_accel_ps_dma_minimal.runs\impl_1\conv_accel_ps_dma_wrapper.bit"
$DetElf = Join-Path $Root "build_vitis_2022_2\conv_accel_r18_c16_smoke\manual_build\conv_accel_r18_c8_smoke.elf"
$Conv0Elf = Join-Path $Root "build_vitis_2022_2\conv_accel_r18_c16_smoke\manual_build\conv_accel_conv0_crop_pool_smoke.elf"
$Conv0TilesElf = Join-Path $Root "build_vitis_2022_2\conv_accel_r18_c16_smoke\manual_build\conv_accel_conv0_crop_pool_tiles_smoke.elf"
$Layer06Tile4Elf = Join-Path $Root "build_vitis_2022_2\conv_accel_r18_c16_smoke\manual_build\conv_accel_layer06_tile4_smoke.elf"
$Layer06TilesElf = Join-Path $Root "build_vitis_2022_2\conv_accel_r18_c16_smoke\manual_build\conv_accel_layer06_tiles_smoke.elf"
$Layer06PoolTilesElf = Join-Path $Root "build_vitis_2022_2\conv_accel_r18_c16_smoke\manual_build\conv_accel_layer06_pool_tiles_smoke.elf"
$Conv4PoolTilesElf = Join-Path $Root "build_vitis_2022_2\conv_accel_r18_c16_smoke\manual_build\conv_accel_conv4_pool_tiles_smoke.elf"
$Conv3Conv4ChainElf = Join-Path $Root "build_vitis_2022_2\conv_accel_r18_c16_smoke\manual_build\conv_accel_conv3_conv4_chain_smoke.elf"
$Conv4Conv5ChainElf = Join-Path $Root "build_vitis_2022_2\conv_accel_r18_c16_smoke\manual_build\conv_accel_conv4_conv5_chain_smoke.elf"
$Conv0Conv4ChainElf = Join-Path $Root "build_vitis_2022_2\conv_accel_r18_c16_smoke\manual_build\conv_accel_conv0_conv4_chain_smoke.elf"
$Conv0Conv5ChainElf = Join-Path $Root "build_vitis_2022_2\conv_accel_r18_c16_smoke\manual_build\conv_accel_conv0_conv5_chain_smoke.elf"
$DownloadTcl = Join-Path $ScriptDir "download_run_accel_smoke.tcl"
$ProbeTcl = Join-Path $ScriptDir "probe_pl_regs.tcl"
$JtagProbeTcl = Join-Path $ScriptDir "probe_jtag_targets.tcl"

New-Item -ItemType Directory -Force $LogDir | Out-Null
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"

function Ensure-Tool($Path, $Name) {
    if (!(Test-Path $Path)) {
        throw "$Name not found: $Path"
    }
}

function Start-HwServer {
    $existing = Get-Process hw_server -ErrorAction SilentlyContinue
    if ($existing) {
        return
    }
    Start-Process -FilePath $HwServer -ArgumentList @("-s", "TCP::3121") -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 5
}

function Start-SerialCapture($Name) {
    $log = Join-Path $LogDir "$Stamp`_$Name`_$PortName.log"
    $reader = {
        param($PortName, $BaudRate, $CaptureSeconds, $Log)
        Add-Content -LiteralPath $Log -Value "=== capture $PortName $(Get-Date) ===`r`n"
        $port = New-Object System.IO.Ports.SerialPort $PortName,$BaudRate,None,8,one
        $port.ReadTimeout = 200
        try {
            $port.Open()
            $deadline = (Get-Date).AddSeconds($CaptureSeconds)
            while ((Get-Date) -lt $deadline) {
                $text = $port.ReadExisting()
                if ($text.Length -gt 0) {
                    Add-Content -LiteralPath $Log -Value $text -NoNewline
                    if ($text -match "PASS:|FAIL:") {
                        $drainDeadline = (Get-Date).AddSeconds(2)
                        while ((Get-Date) -lt $drainDeadline) {
                            Start-Sleep -Milliseconds 100
                            $more = $port.ReadExisting()
                            if ($more.Length -gt 0) {
                                Add-Content -LiteralPath $Log -Value $more -NoNewline
                            }
                        }
                        break
                    }
                }
                Start-Sleep -Milliseconds 100
            }
        } catch {
            Add-Content -LiteralPath $Log -Value "ERROR: $($_.Exception.Message)`r`n"
        } finally {
            if ($port.IsOpen) {
                $port.Close()
            }
        }
    }
    return @{
        Job = Start-Job -ScriptBlock $reader -ArgumentList $PortName,$BaudRate,$CaptureSeconds,$log
        Log = $log
    }
}

function Run-Smoke($Name, $Elf, [bool]$ProgramBit, [bool]$UseFastRun) {
    Ensure-Tool $Elf "$Name ELF"
    $capture = Start-SerialCapture $Name
    Start-Sleep -Seconds 2
    $args = @($DownloadTcl, "-elf", $Elf, "-bit_file", $BitFile)
    if ($UseFastRun) {
        $args += "-fast"
    } elseif (!$ProgramBit) {
        $args += "-skip_bit"
    }
    & $Xsct @args
    $xsctExit = $LASTEXITCODE
    Wait-Job $capture.Job | Out-Null
    Receive-Job $capture.Job | Out-Null
    if ($xsctExit -ne 0) {
        throw "$Name XSCT failed with exit code $xsctExit. Serial log: $($capture.Log)"
    }
    Write-Host "$Name serial log: $($capture.Log)"
}

Ensure-Tool $Xsct "XSCT"
Ensure-Tool $HwServer "hw_server"
Ensure-Tool $DownloadTcl "download script"
Ensure-Tool $ProbeTcl "probe script"
Ensure-Tool $JtagProbeTcl "JTAG probe script"
if (!$SkipBit -and !$FastRun) {
    Ensure-Tool $BitFile "bitstream"
}

Write-Host "Available COM ports: $([string]::Join(', ', [System.IO.Ports.SerialPort]::getportnames()))"
Start-HwServer
& $Xsct $JtagProbeTcl | Tee-Object -FilePath (Join-Path $LogDir "$Stamp`_jtag_probe.log")
if ($RunConv0Conv5Chain) {
    Run-Smoke "conv0_conv5_chain" $Conv0Conv5ChainElf (!$SkipBit -and !$FastRun) $FastRun
    & $Xsct $ProbeTcl | Tee-Object -FilePath (Join-Path $LogDir "$Stamp`_pl_probe_after_conv0_conv5_chain.log")
} elseif ($RunConv0Conv4Chain) {
    Run-Smoke "conv0_conv4_chain" $Conv0Conv4ChainElf (!$SkipBit -and !$FastRun) $FastRun
    & $Xsct $ProbeTcl | Tee-Object -FilePath (Join-Path $LogDir "$Stamp`_pl_probe_after_conv0_conv4_chain.log")
} elseif ($RunConv4Conv5Chain) {
    Run-Smoke "conv4_conv5_chain" $Conv4Conv5ChainElf (!$SkipBit -and !$FastRun) $FastRun
    & $Xsct $ProbeTcl | Tee-Object -FilePath (Join-Path $LogDir "$Stamp`_pl_probe_after_conv4_conv5_chain.log")
} elseif ($RunConv3Conv4Chain) {
    Run-Smoke "conv3_conv4_chain" $Conv3Conv4ChainElf (!$SkipBit -and !$FastRun) $FastRun
    & $Xsct $ProbeTcl | Tee-Object -FilePath (Join-Path $LogDir "$Stamp`_pl_probe_after_conv3_conv4_chain.log")
} elseif ($RunConv4PoolTiles) {
    Run-Smoke "conv4_pool_tiles" $Conv4PoolTilesElf (!$SkipBit -and !$FastRun) $FastRun
    & $Xsct $ProbeTcl | Tee-Object -FilePath (Join-Path $LogDir "$Stamp`_pl_probe_after_conv4_pool_tiles.log")
} elseif ($RunLayer06PoolTiles) {
    Run-Smoke "layer06_pool_tiles" $Layer06PoolTilesElf (!$SkipBit -and !$FastRun) $FastRun
    & $Xsct $ProbeTcl | Tee-Object -FilePath (Join-Path $LogDir "$Stamp`_pl_probe_after_layer06_pool_tiles.log")
} elseif ($RunLayer06Tiles) {
    Run-Smoke "layer06_tiles" $Layer06TilesElf (!$SkipBit -and !$FastRun) $FastRun
    & $Xsct $ProbeTcl | Tee-Object -FilePath (Join-Path $LogDir "$Stamp`_pl_probe_after_layer06_tiles.log")
} elseif ($RunLayer06Tile4) {
    Run-Smoke "layer06_tile4" $Layer06Tile4Elf (!$SkipBit -and !$FastRun) $FastRun
    & $Xsct $ProbeTcl | Tee-Object -FilePath (Join-Path $LogDir "$Stamp`_pl_probe_after_layer06_tile4.log")
} elseif ($RunConv0Tiles) {
    Run-Smoke "conv0_crop_pool_tiles" $Conv0TilesElf (!$SkipBit -and !$FastRun) $FastRun
    & $Xsct $ProbeTcl | Tee-Object -FilePath (Join-Path $LogDir "$Stamp`_pl_probe_after_conv0_tiles.log")
} else {
    Run-Smoke "conv0_crop_pool" $Conv0Elf (!$SkipBit -and !$FastRun) $FastRun
    & $Xsct $ProbeTcl | Tee-Object -FilePath (Join-Path $LogDir "$Stamp`_pl_probe_after_conv0.log")
}

if ($RunDeterministic) {
    Run-Smoke "r18_c8" $DetElf $false $FastRun
    & $Xsct $ProbeTcl | Tee-Object -FilePath (Join-Path $LogDir "$Stamp`_pl_probe_after_r18_c8.log")
}

Write-Host "=== KV260 smoke sequence complete ==="

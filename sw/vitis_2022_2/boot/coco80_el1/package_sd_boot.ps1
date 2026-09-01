param(
    [Parameter(Mandatory = $true)][string]$BuildDirectory,
    [Parameter(Mandatory = $true)][string]$BitFile,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$Python = "python"
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..\..\..")).Path
$build = [System.IO.Path]::GetFullPath($BuildDirectory)
$bit = [System.IO.Path]::GetFullPath($BitFile)
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
$boot = Join-Path $output "COCO80_R5\BOOT"
$objcopy = "C:\Xilinx\Vitis\2022.2\gnu\aarch64\nt\aarch64-none\bin\aarch64-none-elf-objcopy.exe"

$mainElf = Join-Path $build "coco80_net_manual_build\coco80_r5_ethernet.elf"
$runnerManifest = Join-Path $build "coco80_net_manual_build\coco80_r5_ethernet.manifest.json"
$workerElfs = 1..3 | ForEach-Object {
    Join-Path $build "coco80_net_manual_build\coco80_r5_worker_$_.elf"
}
$shim = Join-Path $build "boot_shims\el2_to_el1.bin"
$workerShim = Join-Path $build "boot_shims\worker_el2_to_el1.bin"
foreach ($path in @($bit, $mainElf, $runnerManifest, $shim, $workerShim) + $workerElfs + @($objcopy)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required SD boot artifact is missing: $path"
    }
}
if (Test-Path -LiteralPath $output) {
    throw "SD boot package output must be fresh: $output"
}
$runner = Get-Content -Raw -LiteralPath $runnerManifest | ConvertFrom-Json
$head = (& git -C $root rev-parse HEAD).Trim()
$dirty = & git -C $root status --porcelain
if ($LASTEXITCODE -ne 0 -or $dirty -or $runner.git_dirty -or
    $runner.git_sha -ne $head -or $runner.execution_domain.level -ne "el1" -or
    $runner.execution_domain.initial_ddr_shareability -ne "outer" -or
    $runner.execution_domain.inference_buffer_shareability -ne "inner") {
    throw "Runner manifest is not a clean deferred-Inner EL1 artifact at current HEAD"
}

New-Item -ItemType Directory -Path $boot -Force | Out-Null
Copy-Item -LiteralPath $bit -Destination (Join-Path $boot "conv_accel_ps_dma_wrapper.bit") -Force
Copy-Item -LiteralPath $shim -Destination (Join-Path $boot "el2_to_el1.bin") -Force
Copy-Item -LiteralPath $workerShim -Destination (Join-Path $boot "worker_el2_to_el1.bin") -Force
Copy-Item -LiteralPath $runnerManifest -Destination (Join-Path $boot "coco80_r5_ethernet.manifest.json") -Force

$coreBin = Join-Path $boot "core0_el1.bin"
& $objcopy -O binary $mainElf $coreBin
if ($LASTEXITCODE -ne 0) { throw "objcopy failed for Core0 ELF" }
for ($index = 1; $index -le 3; ++$index) {
    $destination = Join-Path $boot "worker$($index)_el1.bin"
    & $objcopy -O binary $workerElfs[$index - 1] $destination
    if ($LASTEXITCODE -ne 0) { throw "objcopy failed for worker $index ELF" }
}

function Hex-Size([string]$Path) {
    return "{0:x}" -f (Get-Item -LiteralPath $Path).Length
}
$bitSize = Hex-Size (Join-Path $boot "conv_accel_ps_dma_wrapper.bit")
$coreSize = Hex-Size $coreBin
$workerSizes = 1..3 | ForEach-Object { Hex-Size (Join-Path $boot "worker$($_)_el1.bin") }
$shimSize = Hex-Size (Join-Path $boot "el2_to_el1.bin")
$workerShimSize = Hex-Size (Join-Path $boot "worker_el2_to_el1.bin")

$commands = @"
# KV260 COCO80 r5 deferred-Inner EL1 chain-loader
echo "COCO80 r5: QSPI U-Boot -> SD chain-load"
if test -z "`${devtype}"; then echo "COCO80 BOOT ERROR: devtype"; reset; fi
if test "`${devtype}" != "mmc"; then echo "COCO80 BOOT ERROR: not MMC"; reset; fi
if test -z "`${devnum}"; then echo "COCO80 BOOT ERROR: devnum"; reset; fi
if test -z "`${distro_bootpart}"; then echo "COCO80 BOOT ERROR: bootpart"; reset; fi
setenv c8dev "`${devnum}:`${distro_bootpart}"
setenv c8base "COCO80_R5/BOOT"

echo "COCO80 r5: programming PL"
if fatload `${devtype} `${c8dev} 0x10000000 `${c8base}/conv_accel_ps_dma_wrapper.bit; then
    if test 0x`${filesize} -ne 0x$bitSize; then echo "COCO80 BOOT ERROR: BIT size"; reset; fi
else
    echo "COCO80 BOOT ERROR: cannot load BIT"; reset
fi
if fpga loadb 0 0x10000000 `${filesize}; then echo "COCO80 r5: PL configured"; else reset; fi

mw.l 0x00000000 0 0x0000c000
if fatload `${devtype} `${c8dev} 0x00000000 `${c8base}/core0_el1.bin; then
    if test 0x`${filesize} -ne 0x$coreSize; then echo "COCO80 BOOT ERROR: Core0 size"; reset; fi
else
    echo "COCO80 BOOT ERROR: cannot load Core0"; reset
fi

mw.l 0x7d000000 0 0x00040000
mw.l 0x7d200000 0 0x00040000
mw.l 0x7d400000 0 0x00040000
mw.l 0x7d600000 0 4
if fatload `${devtype} `${c8dev} 0x7d000000 `${c8base}/worker1_el1.bin; then if test 0x`${filesize} -ne 0x$($workerSizes[0]); then reset; fi; else reset; fi
if fatload `${devtype} `${c8dev} 0x7d200000 `${c8base}/worker2_el1.bin; then if test 0x`${filesize} -ne 0x$($workerSizes[1]); then reset; fi; else reset; fi
if fatload `${devtype} `${c8dev} 0x7d400000 `${c8base}/worker3_el1.bin; then if test 0x`${filesize} -ne 0x$($workerSizes[2]); then reset; fi; else reset; fi
if fatload `${devtype} `${c8dev} 0x7c000000 `${c8base}/el2_to_el1.bin; then if test 0x`${filesize} -ne 0x$shimSize; then reset; fi; else reset; fi
mw.l 0x7c100000 0 0x00000100
if fatload `${devtype} `${c8dev} 0x7c100000 `${c8base}/worker_el2_to_el1.bin; then if test 0x`${filesize} -ne 0x$workerShimSize; then reset; fi; else reset; fi

echo "COCO80 r5: releasing A53 workers"
if cpu 1 release 0x7c100000; then true; else reset; fi
if cpu 2 release 0x7c100000; then true; else reset; fi
if cpu 3 release 0x7c100000; then true; else reset; fi
echo "COCO80 r5: entering Core0 at EL1; server 192.168.10.2:5001"
go 0x7c000000
echo "COCO80 BOOT ERROR: Core0 returned"
reset
"@ -replace "`r`n", "`n"
$bootCmd = Join-Path $output "boot.cmd"
[System.IO.File]::WriteAllText($bootCmd, $commands, [System.Text.UTF8Encoding]::new($false))
$bootScr = Join-Path $output "boot.scr"
& $Python -m tools.coco80.uboot_script --input $bootCmd --output $bootScr --name "KV260 COCO80 r5 boot"
if ($LASTEXITCODE -ne 0) { throw "boot.scr generation failed" }
& $Python -m tools.coco80.uboot_script --input $bootCmd --output $bootScr --verify
if ($LASTEXITCODE -ne 0) { throw "boot.scr verification failed" }

$files = Get-ChildItem -LiteralPath $output -Recurse -File |
    Where-Object { $_.Name -ne "boot_package_manifest.json" } |
    Sort-Object FullName |
    ForEach-Object {
        $relative = $_.FullName.Substring($output.Length).TrimStart("\", "/")
        [ordered]@{
            path = $relative.Replace("\", "/")
            bytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
$manifest = [ordered]@{
    format = "kv260-coco80-r5-sd-boot"
    version = 3
    git_sha = $head
    git_dirty = $false
    runner_manifest_sha256 = (Get-FileHash -LiteralPath $runnerManifest -Algorithm SHA256).Hash.ToLowerInvariant()
    files = @($files)
}
$manifestPath = Join-Path $output "boot_package_manifest.json"
[System.IO.File]::WriteAllText(
    $manifestPath,
    (($manifest | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Output ($manifest | ConvertTo-Json -Depth 6)

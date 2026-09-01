param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"

$scriptRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
$toolRoot = "C:\Xilinx\Vitis\2022.2\gnu\aarch64\nt\aarch64-none\bin"
$assembler = Join-Path $toolRoot "aarch64-none-elf-as.exe"
$linker = Join-Path $toolRoot "aarch64-none-elf-ld.exe"
$objcopy = Join-Path $toolRoot "aarch64-none-elf-objcopy.exe"

foreach ($tool in @($assembler, $linker, $objcopy)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Required Vitis 2022.2 tool is missing: $tool"
    }
}

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

$specs = @(
    @{ Name = "el2_to_el1"; Address = "0x7c000000" },
    @{ Name = "worker_el2_to_el1"; Address = "0x7c100000" }
)

$results = foreach ($spec in $specs) {
    $source = Join-Path $scriptRoot ($spec.Name + ".S")
    $object = Join-Path $outputRoot ($spec.Name + ".o")
    $elf = Join-Path $outputRoot ($spec.Name + ".elf")
    $binary = Join-Path $outputRoot ($spec.Name + ".bin")

    & $assembler -march=armv8-a -o $object $source
    if ($LASTEXITCODE -ne 0) { throw "Assembler failed for $source" }
    $textArgument = "-Ttext=$($spec.Address)"
    & $linker $textArgument --entry=_start --build-id=none -o $elf $object
    if ($LASTEXITCODE -ne 0) { throw "Linker failed for $source" }
    & $objcopy -O binary $elf $binary
    if ($LASTEXITCODE -ne 0) { throw "objcopy failed for $source" }

    [pscustomobject]@{
        name = $spec.Name
        address = $spec.Address
        bytes = (Get-Item -LiteralPath $binary).Length
        sha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
        binary = $binary
    }
}

$results | ConvertTo-Json -Depth 3

param(
    [string]$Vivado = "C:\Xilinx\Vivado\2022.2\bin\vivado.bat",
    [switch]$RunDeterministicDiagnostics
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Tops = @(
    "tb_axis_ofm_byte_writer",
    "tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c8_b2_ext",
    "tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c8_b2_batch_ext",
    "tb_conv_accel_core_axi_lite_quant_lut",
    "tb_requant",
    "tb_ofm_requant_writer"
)

foreach ($Top in $Tops) {
    Write-Host "=== xsim short regression: $Top ==="
    & $Vivado -mode batch -source tcl/run_xsim_regression.tcl -tclargs -top $Top
    if ($LASTEXITCODE -ne 0) {
        throw "xsim failed for $Top"
    }
}

Write-Host "=== short xsim regression passed ==="

if ($RunDeterministicDiagnostics) {
    $DiagTops = @(
        "tb_conv_accel_core_axi_lite_axis_stream_r18_c8_smoke"
    )
    foreach ($Top in $DiagTops) {
        Write-Host "=== xsim deterministic diagnostic: $Top ==="
        & $Vivado -mode batch -source tcl/run_xsim_regression.tcl -tclargs -top $Top
        if ($LASTEXITCODE -eq 0) {
            Write-Warning "deterministic diagnostic unexpectedly passed: $Top"
        } else {
            Write-Host "deterministic diagnostic reproduced the known mismatch: $Top"
        }
    }
}

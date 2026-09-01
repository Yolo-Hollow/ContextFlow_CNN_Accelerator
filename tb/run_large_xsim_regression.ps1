param(
    [string]$Vivado = "C:\Xilinx\Vivado\2022.2\bin\vivado.bat",
    [string[]]$Top = @(
        "tb_conv_accel_axis_layer_long_two_tile_e2e",
        "tb_conv_accel_core_axi_lite_axis_stream_r18_c16_packed_ofm_tail",
        "tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_full"
    )
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Vivado)) {
    throw "Vivado launcher not found: $Vivado"
}

foreach ($TestTop in $Top) {
    Write-Host "=== xsim large regression: $TestTop ==="
    & $Vivado -mode batch -source tcl/run_xsim_regression.tcl `
        -tclargs -top $TestTop
    if ($LASTEXITCODE -ne 0) {
        throw "xsim failed for $TestTop"
    }
}

Write-Host "=== all selected large XSIM regressions passed ==="

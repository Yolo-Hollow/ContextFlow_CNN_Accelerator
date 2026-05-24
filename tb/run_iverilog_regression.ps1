$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$outDir = Join-Path $root "build_iverilog"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$common = @(
    "cal/cal_mul_int8_x2_dsp.v",
    "cal/cal_mul_int8_x2.v",
    "com/com_shift_reg.v",
    "systolic/systolic_pe.v",
    "systolic/systolic_array_32x32.v",
    "systolic/systolic_fifo.v",
    "systolic/systolic_ctrl.v",
    "systolic/line_stream_ctrl.v",
    "systolic/window_stream_ctrl.v",
    "systolic/line_buffer_5bank.v",
    "systolic/window_extract.v",
    "systolic/window_feeder.v",
    "systolic/requant.v",
    "systolic/leaky_lut.v",
    "systolic/systolic_top.v"
)

$tests = @(
    @{ Top = "tb_tiling_model"; Files = @("tb/tb_tiling_model.v") },
    @{ Top = "tb_systolic_pe"; Files = @("tb/tb_systolic_pe.v") },
    @{ Top = "tb_systolic_array_small"; Files = @("tb/tb_systolic_array_small.v") },
    @{ Top = "tb_systolic_top_multipass"; Files = @("tb/tb_systolic_top_multipass.v") },
    @{ Top = "tb_window_top_singlepass"; Files = @("tb/tb_window_top_singlepass.v") },
    @{ Top = "tb_layer_scheduler_small"; Files = @("tb/tb_layer_scheduler_small.v") },
    @{ Top = "tb_line_stream_ctrl"; Files = @("tb/tb_line_stream_ctrl.v") },
    @{ Top = "tb_window_stream_ctrl"; Files = @("tb/tb_window_stream_ctrl.v") },
    @{ Top = "tb_window_feeder"; Files = @("tb/tb_window_feeder.v") },
    @{ Top = "tb_window_feeder_stride2"; Files = @("tb/tb_window_feeder_stride2.v") },
    @{ Top = "tb_window_extract"; Files = @("tb/tb_window_extract.v") },
    @{ Top = "tb_linebuf_stream"; Files = @("tb/tb_linebuf_stream.v") },
    @{ Top = "tb_requant"; Files = @("tb/tb_requant.v") }
)

foreach ($test in $tests) {
    $top = $test.Top
    $vvp = Join-Path $outDir "$top.vvp"
    $srcs = @()
    foreach ($f in $common + $test.Files) {
        $srcs += (Join-Path $root $f)
    }

    Write-Host "=== compile $top ==="
    & iverilog -g2012 -s $top -o $vvp @srcs
    if ($LASTEXITCODE -ne 0) { throw "iverilog failed for $top" }

    Write-Host "=== run $top ==="
    & vvp $vvp
    if ($LASTEXITCODE -ne 0) { throw "vvp failed for $top" }
}

Write-Host "=== all selected Icarus regressions passed ==="

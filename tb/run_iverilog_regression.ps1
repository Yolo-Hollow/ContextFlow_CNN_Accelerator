param(
    [string[]] $Top = @(),
    [switch] $IncludeLong
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$outDir = Join-Path $root "build_iverilog"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$tailOverride = Join-Path $outDir "tail_cycles_override.vh"
if (-not (Test-Path $tailOverride)) {
    [System.IO.File]::WriteAllText($tailOverride, "")
}

$common = @(
    "cal/cal_mul_int8_x2_dsp.v",
    "cal/cal_mul_int8_x2.v",
    "com/com_shift_reg.v",
    "systolic/systolic_pe.v",
    "systolic/systolic_pe_tagged.v",
    "systolic/systolic_array_32x32.v",
    "systolic/systolic_array_tagged.v",
    "systolic/systolic_array_dsp_cascade_tagged.v",
    "tb/systolic_scalar_lane_dsp48e2_fast_sim.v",
    "systolic/systolic_fifo.v",
    "systolic/systolic_ctrl.v",
    "systolic/systolic_ctrl_tagged.v",
    "systolic/line_stream_ctrl.v",
    "systolic/window_stream_ctrl.v",
    "systolic/line_buffer_5bank.v",
    "systolic/window_extract.v",
    "systolic/window_feeder.v",
    "systolic/ifm_vector_epoch_buffer.v",
    "systolic/ifm_context_epoch_frontend.v",
    "systolic/context_lifecycle_queue.v",
    "systolic/context_event_fifo.v",
    "systolic/systolic_top_tagged.v",
    "systolic/systolic_top_feeder.v",
    "systolic/layer_scheduler_stream.v",
    "systolic/layer_tile_sequencer.v",
    "systolic/pass_timeline_monitor.v",
    "systolic/coltrace_monitor.v",
    "systolic/compute_pipe_telemetry.v",
    "systolic/weight_tile_loader.v",
    "systolic/bias_weight_stream_loader.v",
    "systolic/axis_bias_weight_loader.v",
    "systolic/ifm_line_stream_loader.v",
    "systolic/axis_ifm_line_loader.v",
    "systolic/axis_ifm_vector_loader.v",
    "systolic/axis_hwc_tile_cache.v",
    "systolic/axis_hwc_window_materializer.v",
    "systolic/axis_hwc_window_materializer_bram.v",
    "tb/xpm_memory_tdpram_iverilog.v",
    "systolic/axis_hwc_window_row_store.v",
    "systolic/axis_hwc_window_materializer_byte_bram.v",
    "systolic/hwc_materialized_tile_pingpong_cache.v",
    "systolic/axis_hwc_tile_materialized_replay.v",
    "systolic/hwc_materialized_vector_cache.v",
    "systolic/axis_hwc_materialized_replay.v",
    "systolic/psum_pingpong_buffer.v",
    "systolic/psum_bank_owner_scoreboard.v",
    "systolic/psum_output_collector.v",
    "systolic/psum_stream_feeder.v",
    "systolic/psum_drain_writer.v",
    "systolic/psum_packet_fifo.v",
    "systolic/ofm_requant_writer.v",
    "systolic/ofm_activation.v",
    "systolic/ofm_pooling.v",
    "systolic/ofm_writeback.v",
    "systolic/ofm_packet_fifo.v",
    "systolic/ofm_byte_stream_fifo.v",
    "systolic/axis_ofm_byte_writer.v",
    "systolic/ofm_hwc_axis_packer.v",
    "systolic/ofm_hwc_axis_pingpong.v",
    "systolic/conv_layer_top_stream.v",
    "systolic/layer_config_regs.v",
    "systolic/quant_param_regs.v",
    "systolic/axi_lite_cfg_bridge.v",
    "systolic/conv_accel_core.v",
    "systolic/conv_accel_core_axi_lite.v",
    "systolic/conv_accel_core_axi_lite_stream.v",
    "systolic/conv_accel_core_axi_lite_full_stream.v",
    "systolic/conv_accel_core_axi_lite_axis_stream.v",
    "systolic/requant.v",
    "systolic/leaky_lut.v",
    "systolic/systolic_top.v"
)

$tests = @(
    @{ Top = "tb_tiling_model"; Files = @("tb/tb_tiling_model.v") },
    @{ Top = "tb_systolic_pe"; Files = @("tb/tb_systolic_pe.v") },
    @{ Top = "tb_systolic_pe_tagged"; Files = @("tb/tb_systolic_pe_tagged.v") },
    @{ Top = "tb_systolic_pe_shadow_weight"; Files = @("systolic/systolic_pe_shadow_weight.v", "tb/tb_systolic_pe_shadow_weight.v") },
    @{ Top = "tb_systolic_array_small"; Files = @("tb/tb_systolic_array_small.v") },
    @{ Top = "tb_systolic_top_multipass"; Files = @("tb/tb_systolic_top_multipass.v") },
    @{ Top = "tb_systolic_result_tagged_fifo"; Files = @("tb/tb_systolic_result_tagged_fifo.v") },
    @{ Top = "tb_systolic_top_tagged"; Files = @("tb/tb_systolic_top_tagged.v") },
    @{ Top = "tb_systolic_top_tagged_two_context_interleave"; Files = @("tb/tb_systolic_top_tagged_two_context_interleave.v") },
    @{ Top = "tb_window_top_singlepass"; Files = @("tb/tb_window_top_singlepass.v") },
    @{ Top = "tb_systolic_top_feeder_singlepass"; Files = @("tb/tb_systolic_top_feeder_singlepass.v") },
    @{ Top = "tb_systolic_top_feeder_multipass_pingpong"; Files = @("tb/tb_systolic_top_feeder_multipass_pingpong.v") },
    @{ Top = "tb_systolic_top_feeder_multipass_stream"; Files = @("tb/tb_systolic_top_feeder_multipass_stream.v") },
    @{ Top = "tb_systolic_top_feeder_cout_blocks"; Files = @("tb/tb_systolic_top_feeder_cout_blocks.v") },
    @{ Top = "tb_conv_layer_top_stream"; Files = @("tb/tb_conv_layer_top_stream.v") },
    @{ Top = "tb_conv_layer_top_stream_tagged"; Files = @("tb/tb_conv_layer_top_stream_tagged.v") },
    @{ Top = "tb_conv_accel_core"; Files = @("tb/tb_conv_accel_core.v") },
    @{ Top = "tb_conv_accel_core_layer_tile_sequence"; Files = @("tb/tb_conv_accel_core_layer_tile_sequence.v") },
    @{ Top = "tb_layer_config_regs"; Files = @("tb/tb_layer_config_regs.v") },
    @{ Top = "tb_layer_long_descriptor_validation"; Files = @("tb/tb_layer_long_descriptor_validation.v") },
    @{ Top = "tb_pass_timeline_monitor"; Files = @("tb/tb_pass_timeline_monitor.v") },
    @{ Top = "tb_coltrace_monitor"; Files = @("tb/tb_coltrace_monitor.v") },
    @{ Top = "tb_axi_lite_cfg_bridge"; Files = @("tb/tb_axi_lite_cfg_bridge.v") },
    @{ Top = "tb_quant_param_regs"; Files = @("tb/tb_quant_param_regs.v") },
    @{ Top = "tb_layer_scheduler_stream"; Files = @("tb/tb_layer_scheduler_stream.v") },
    @{ Top = "tb_layer_tile_sequencer"; Files = @("tb/tb_layer_tile_sequencer.v") },
    @{ Top = "tb_layer_scheduler_pass_prefetch"; Files = @("tb/tb_layer_scheduler_pass_prefetch.v") },
    @{ Top = "tb_layer_scheduler_during_compute_prefetch"; Files = @("tb/tb_layer_scheduler_during_compute_prefetch.v") },
    @{ Top = "tb_layer_scheduler_psum_overlap"; Files = @("tb/tb_layer_scheduler_psum_overlap.v") },
    @{ Top = "tb_layer_scheduler_continuous_psum"; Files = @("tb/tb_layer_scheduler_continuous_psum.v") },
    @{ Top = "tb_layer_scheduler_overlap"; Files = @("tb/tb_layer_scheduler_overlap.v") },
    @{ Top = "tb_layer_scheduler_early_drain"; Files = @("tb/tb_layer_scheduler_early_drain.v") },
    @{ Top = "tb_layer_scheduler_small"; Files = @("tb/tb_layer_scheduler_small.v") },
    @{ Top = "tb_weight_tile_loader"; Files = @("tb/tb_weight_tile_loader.v") },
    @{ Top = "tb_bias_weight_stream_loader"; Files = @("tb/tb_bias_weight_stream_loader.v") },
    @{ Top = "tb_axis_bias_weight_loader"; Files = @("tb/tb_axis_bias_weight_loader.v") },
    @{ Top = "tb_axis_batch_stream_loaders"; Files = @("tb/tb_axis_batch_stream_loaders.v") },
    @{ Top = "tb_axis_batch_stream_errors"; Files = @("tb/tb_axis_batch_stream_errors.v") },
    @{ Top = "tb_ifm_line_stream_loader"; Files = @("tb/tb_ifm_line_stream_loader.v") },
    @{ Top = "tb_axis_ifm_line_loader"; Files = @("tb/tb_axis_ifm_line_loader.v") },
    @{ Top = "tb_axis_ifm_vector_loader"; Files = @("tb/tb_axis_ifm_vector_loader.v") },
    @{ Top = "tb_axis_hwc_window_materializer"; Files = @("tb/tb_axis_hwc_window_materializer.v") },
    @{ Top = "tb_hwc_materialized_vector_cache"; Files = @("tb/tb_hwc_materialized_vector_cache.v") },
    @{ Top = "tb_hwc_materialized_tile_pingpong_cache"; Files = @("tb/tb_hwc_materialized_tile_pingpong_cache.v") },
    @{ Top = "tb_axis_hwc_materialized_replay"; Files = @("tb/tb_axis_hwc_materialized_replay.v") },
    @{ Top = "tb_conv_accel_axis_layer_long_ifm"; Files = @("tb/tb_conv_accel_axis_layer_long_ifm.v") },
    @{ Top = "tb_conv_accel_axis_layer_long_two_tile_e2e"; Files = @("tb/tb_conv_accel_axis_layer_long_two_tile_e2e.v") },
    @{ Top = "tb_ifm_vector_epoch_buffer"; Files = @("tb/tb_ifm_vector_epoch_buffer.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_native1x1_small"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_native1x1_small.v") },
    @{ Top = "tb_psum_pingpong_buffer"; Files = @("tb/tb_psum_pingpong_buffer.v") },
    @{ Top = "tb_psum_bank_ready_cut_equiv"; Files = @("tb/tb_psum_bank_ready_cut_equiv.v") },
    @{ Top = "tb_psum_bank_owner_scoreboard"; Files = @("tb/tb_psum_bank_owner_scoreboard.v") },
    @{ Top = "tb_ifm_context_epoch_frontend"; Files = @("tb/tb_ifm_context_epoch_frontend.v") },
    @{ Top = "tb_context_lifecycle_queue"; Files = @("tb/tb_context_lifecycle_queue.v") },
    @{ Top = "tb_context_event_fifo"; Files = @("tb/tb_context_event_fifo.v") },
    @{ Top = "tb_psum_pingpong_buffer_bram"; Files = @("tb/tb_psum_pingpong_buffer_bram.v") },
    @{ Top = "tb_psum_output_collector"; Files = @("tb/tb_psum_output_collector.v") },
    @{ Top = "tb_psum_output_collector_identity"; Files = @("tb/tb_psum_output_collector_identity.v") },
    @{ Top = "tb_psum_stream_feeder"; Files = @("tb/tb_psum_stream_feeder.v") },
    @{ Top = "tb_psum_drain_writer"; Files = @("tb/tb_psum_drain_writer.v") },
    @{ Top = "tb_ofm_requant_writer"; Files = @("tb/tb_ofm_requant_writer.v") },
    @{ Top = "tb_ofm_activation"; Files = @("tb/tb_ofm_activation.v") },
    @{ Top = "tb_ofm_pooling"; Files = @("tb/tb_ofm_pooling.v") },
    @{ Top = "tb_ofm_writeback"; Files = @("tb/tb_ofm_writeback.v") },
    @{ Top = "tb_ofm_packet_fifo"; Files = @("tb/tb_ofm_packet_fifo.v") },
    @{ Top = "tb_ofm_byte_stream_fifo"; Files = @("tb/tb_ofm_byte_stream_fifo.v") },
    @{ Top = "tb_axis_ofm_byte_writer"; Files = @("tb/tb_axis_ofm_byte_writer.v") },
    @{ Top = "tb_ofm_hwc_axis_packer"; Files = @("tb/tb_ofm_hwc_axis_packer.v") },
    @{ Top = "tb_ofm_hwc_axis_pingpong"; Files = @("tb/tb_ofm_hwc_axis_pingpong.v") },
    @{ Top = "tb_line_stream_ctrl"; Files = @("tb/tb_line_stream_ctrl.v") },
    @{ Top = "tb_line_stream_ctrl_tile"; Files = @("tb/tb_line_stream_ctrl_tile.v") },
    @{ Top = "tb_window_stream_ctrl"; Files = @("tb/tb_window_stream_ctrl.v") },
    @{ Top = "tb_window_feeder"; Files = @("tb/tb_window_feeder.v") },
    @{ Top = "tb_window_feeder_stride2"; Files = @("tb/tb_window_feeder_stride2.v") },
    @{ Top = "tb_window_feeder_pad1"; Files = @("tb/tb_window_feeder_pad1.v") },
    @{ Top = "tb_window_extract"; Files = @("tb/tb_window_extract.v") },
    @{ Top = "tb_linebuf_stream"; Files = @("tb/tb_linebuf_stream.v") },
    @{ Top = "tb_requant"; Files = @("tb/tb_requant.v") }
)

$longTests = @(
    @{ Top = "tb_conv_layer_top_stream_tagged_overlap"; Files = @("tb/tb_conv_layer_top_stream_tagged_overlap.v") },
    @{ Top = "tb_conv_accel_core_realistic_small"; Files = @("tb/tb_conv_accel_core_realistic_small.v") },
    @{ Top = "tb_conv_accel_core_pooling"; Files = @("tb/tb_conv_accel_core_pooling.v") },
    @{ Top = "tb_layer_scheduler_cout64_fulltile"; Files = @("tb/tb_layer_scheduler_cout64_fulltile.v") },
    @{ Top = "tb_conv_accel_core_spatial_tile"; Files = @("tb/tb_conv_accel_core_spatial_tile.v") },
    @{ Top = "tb_conv_accel_core_spatial_multitile"; Files = @("tb/tb_conv_accel_core_spatial_multitile.v") },
    @{ Top = "tb_conv_accel_core_ps_driver"; Files = @("tb/tb_conv_accel_core_ps_driver.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_ps_driver"; Files = @("tb/tb_conv_accel_core_axi_lite_ps_driver.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_stream_ps_driver"; Files = @("tb/tb_conv_accel_core_axi_lite_stream_ps_driver.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_full_stream_ps_driver"; Files = @("tb/tb_conv_accel_core_axi_lite_full_stream_ps_driver.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_smoke"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_smoke.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_r16_c16_smoke"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_r16_c16_smoke.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_r18_c16_smoke"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_smoke.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_r18_c8_smoke"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c8_smoke.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_r32_c16_smoke"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_r32_c16_smoke.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_pooling"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_pooling.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_ext"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_ext.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c8_b2_ext"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_conv0_crop_pool_r18_c8_b2_ext.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tile4"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tile4.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tiles"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_tiles.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_backpressure"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_backpressure.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_full"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_r18_c16_b2_layer06_full.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_ps_driver"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_ps_driver.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_axis_stream_backpressure"; Files = @("tb/tb_conv_accel_core_axi_lite_axis_stream_backpressure.v") },
    @{ Top = "tb_conv_accel_core_axi_lite_full_stream_backpressure"; Files = @("tb/tb_conv_accel_core_axi_lite_full_stream_backpressure.v") }
)

if ($IncludeLong) {
    $tests += $longTests
}

if ($Top.Count -gt 0) {
    $allTests = $tests + $longTests
    $topNames = @()
    foreach ($entry in $Top) {
        $topNames += ($entry -split "," | Where-Object { $_ -ne "" })
    }
    $selected = @()
    foreach ($name in $topNames) {
        $match = $allTests | Where-Object { $_.Top -eq $name }
        if ($null -eq $match) { throw "unknown test top: $name" }
        $selected += $match
    }
    $tests = $selected
}

foreach ($test in $tests) {
    $top = $test.Top
    $vvp = Join-Path $outDir "$top.vvp"
    $srcs = @()
    foreach ($f in $common + $test.Files) {
        $srcs += (Join-Path $root $f)
    }

    Write-Host "=== compile $top ==="
    & iverilog -g2012 -DCONV_ACCEL_FAST_XSIM_DSP -I $outDir -I (Join-Path $root "tb") -s $top -o $vvp @srcs
    if ($LASTEXITCODE -ne 0) { throw "iverilog failed for $top" }

    Write-Host "=== run $top ==="
    $runOutput = & vvp $vvp 2>&1
    $runCode = $LASTEXITCODE
    $runOutput | ForEach-Object { Write-Host $_ }
    $runText = $runOutput -join "`n"
    if ($runCode -ne 0 -or $runText -match "(?m)(FATAL|\[FAIL\])") {
        throw "vvp failed for $top"
    }
}

Write-Host "=== all selected Icarus regressions passed ==="

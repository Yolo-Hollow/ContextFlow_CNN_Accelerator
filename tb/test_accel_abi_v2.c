#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "accel_single_scale_scheduler.h"

static int failures;

static void check(int condition, const char *message)
{
    if (!condition) {
        ++failures;
        printf("FAIL: %s\n", message);
    }
}

int main(void)
{
    accel_single_scale_layer_schedule_t schedule[ACCEL_SINGLE_SCALE_LAYER_COUNT];
    accel_single_scale_schedule_summary_t summary;
    accel_layer_desc_v2_t descriptor;
    accel_capability_t capability;
    accel_single_scale_layer_plan_t invalid_layer;
    accel_single_scale_layer_schedule_t invalid_schedule;
    uint32_t release_capability = ACCEL_RELEASE_CAPABILITY;
    uint32_t i;
    int rc;

    check(sizeof(descriptor) == 80U, "v2 layer descriptor is exactly 20 words");
    check(ACCEL_LAYER_DESC_REG == 0x1e8U &&
          ACCEL_IFM_TOTAL_BYTES_REG == 0x1ecU &&
          ACCEL_OFM_TOTAL_BYTES_REG == 0x1f0U,
          "v2 RTL descriptor register offsets");
    check(ACCEL_OFM_AXIS_BEATS_REG == 0x030U &&
          ACCEL_PACKED_OFM_BYTES_REG == 0x1f4U &&
          ACCEL_PACKED_OFM_STALL_CYCLES_REG == 0x1f8U &&
          ACCEL_DATAPATH_ERRORS_REG == 0x1fcU,
          "packed OFM telemetry register offsets");
    check(ACCEL_PACKED_OFM_VALID_CYCLES(216827U, 1234U) == 218061U,
          "packed OFM valid-cycle derivation");
    check(ACCEL_PERF_UNCLASSIFIED == 0x1e4U,
          "unclassified busy telemetry register offset");
    check(ACCEL_CONTEXT_TELEMETRY_VERSION_REG == 0x200U &&
          ACCEL_CONTEXT_ALLOC_COUNT_REG == 0x204U &&
          ACCEL_CONTEXT_INPUT_ISSUED_COUNT_REG == 0x208U &&
          ACCEL_CONTEXT_ARRAY_RETIRED_COUNT_REG == 0x20cU &&
          ACCEL_CONTEXT_COLLECTOR_DONE_COUNT_REG == 0x210U &&
          ACCEL_CONTEXT_GAP_CYCLES_REG == 0x214U &&
          ACCEL_CONTEXT_IFM_OWNER_STALL_CYCLES_REG == 0x218U &&
          ACCEL_CONTEXT_WEIGHT_OWNER_STALL_CYCLES_REG == 0x21cU &&
          ACCEL_CONTEXT_PSUM_CREDIT_STALL_CYCLES_REG == 0x220U &&
          ACCEL_CONTEXT_EPOCH_MISMATCH_COUNT_REG == 0x224U &&
          ACCEL_CONTEXT_MISMATCH_COUNT_REG == 0x228U &&
          ACCEL_CONTEXT_IFM_UNDERFLOW_COUNT_REG == 0x22cU &&
          ACCEL_CONTEXT_PSUM_UNDERFLOW_COUNT_REG == 0x230U &&
          ACCEL_CONTEXT_FIFO_DROP_COUNT_REG == 0x234U &&
          ACCEL_CONTEXT_BANK_OVERWRITE_COUNT_REG == 0x238U &&
          ACCEL_CONTEXT_FULL_STALL_CYCLES_REG == 0x23cU &&
          ACCEL_DATAPATH_RESET_COUNT_REG == 0x240U &&
          ACCEL_CONTEXT_TELEMETRY_VERSION == 2U,
          "tagged-context telemetry register map");
    check(ACCEL_CTRL_START_MASK == 0x1U &&
          ACCEL_CTRL_CLEAR_STATUS_MASK == 0x2U &&
          ACCEL_CTRL_DATAPATH_RESET_MASK == 0x4U &&
          ACCEL_CTRL_RESET_ACTIVE_MASK == 0x8U,
          "recoverable CTRL write/read masks");
    check(ACCEL_ERROR_VECTOR_EPOCH == 0x00080000U &&
          ACCEL_ERROR_VECTOR_OVERFLOW == 0x00100000U &&
          ACCEL_ERROR_VECTOR_PROTOCOL == 0x00200000U &&
          ACCEL_ERROR_WEIGHT_OWNERSHIP == 0x00400000U &&
          ACCEL_ERROR_WEIGHT_EPOCH == 0x00800000U &&
          ACCEL_ERROR_CONTEXT_MISMATCH == 0x01000000U &&
          ACCEL_ERROR_CONTEXT_DROP == 0x02000000U &&
          ACCEL_ERROR_OUTPUT_CREDIT == 0x04000000U &&
          ACCEL_ERROR_ARRAY_RETIREMENT == 0x08000000U &&
          ACCEL_ERROR_PSUM_TAG == 0x40000000U,
          "tagged-context datapath error bits");
    check(ACCEL_ERROR_PACKED_OFM_PROTOCOL == 0x80000000U,
          "packed OFM protocol error bit");
    capability = accel_capability_decode(release_capability);
    check(capability.rows == 18U, "capability ROWS decode");
    check(capability.cols == 16U, "capability COLS decode");
    check(capability.cout_tile == 32U, "capability COUT_TILE decode");
    check(accel_abi_v2_validate(2U, release_capability,
                                ACCEL_CAP_V2_REQUIRED_FLAGS) == ACCEL_ABI_OK,
          "release capability validates");
    check(accel_abi_v2_validate(0U, 0U,
                                ACCEL_CAP_V2_REQUIRED_FLAGS) == ACCEL_ABI_ERR_VERSION,
          "undecoded v1 registers fail closed");
    check(accel_abi_v2_validate(2U,
                                ACCEL_CAPABILITY_PACK(18U, 8U, 16U, 0U),
                                ACCEL_CAP_V2_REQUIRED_FLAGS) == ACCEL_ABI_ERR_COLS,
          "18x8 bitstream is rejected by v2 runtime");
    check(accel_abi_v2_validate(2U,
                                ACCEL_CAPABILITY_PACK(18U, 16U, 32U,
                                                      ACCEL_CAP_FLAG_HWC_IFM),
                                ACCEL_CAP_V2_REQUIRED_FLAGS) == ACCEL_ABI_ERR_FLAGS,
          "missing packed/long-stream flags are rejected");

    memset(schedule, 0, sizeof(schedule));
    memset(&summary, 0, sizeof(summary));
    rc = accel_single_scale_dry_run(schedule, ACCEL_SINGLE_SCALE_LAYER_COUNT, &summary);
    check(rc == 0, "18x16 ten-layer dry run succeeds");
    check(summary.layer_count == 10U, "ten layers scheduled");
    check(summary.total_ifm_bytes == 2249728U, "unique IFM traffic is exact");
    check(summary.total_output_bytes == 1734616U, "OFM payload is exact");
    check(summary.total_packed_ofm_beats == 216827U, "packed OFM beat count is exact");
    check(summary.ifm_dma_starts == 10U && summary.ofm_dma_starts == 10U,
          "one IFM and OFM DMA start per layer");
    check(ACCEL_SINGLE_SCALE_PSUM_BUF_AW == 10U &&
          ACCEL_SINGLE_SCALE_PSUM_BUF_DEPTH == 1024U,
          "PSUM geometry is the 10-bit/1024-entry RTL profile");
    check(ACCEL_SINGLE_SCALE_PACKED_REORDER_DEPTH == 4096U,
          "packed HWC reorder depth is fixed at 4096 entries");
    check(schedule[0].max_tile_ofm_h == 2U && schedule[0].max_tile_pixels == 832U,
          "Conv0 tile fits the 1024-entry PSUM address space");
    check(schedule[1].max_tile_ofm_h == 4U && schedule[1].max_tile_pixels == 832U,
          "Conv1 tile fits the 1024-entry PSUM address space");
    check(schedule[7].max_tile_ofm_h == 13U && schedule[7].tile_count == 1U,
          "Conv7 uses one full 13x13 tile");
    check(schedule[9].max_tile_ofm_h == 13U && schedule[9].tile_count == 1U,
          "Conv9 uses one full 13x13 tile");
    check(schedule[6].plan->cout_blocks == 32U,
          "Conv6 uses 32 COUT32 blocks");
    check(schedule[9].plan->cout_blocks == 1U,
          "Conv9 tail fits one COUT32 block");
    check(summary.max_tile_reorder_entries == 3328U,
          "Conv6 is the 3328-entry packed reorder high-water mark");
    check(summary.max_tile_axis_bytes == 106496U,
          "Conv6 is the 106496-byte packed tile high-water mark");
    check(summary.total_spatial_tiles == 292U &&
          summary.total_schedule_blocks == 483U,
          "buffer-safe tiling produces the exact spatial/context counts");
    check(summary.total_bias_stream_packets == 483U &&
          summary.total_weight_stream_packets == 29253U,
          "layer-long parameter packet totals are exact");
    check(summary.total_bias_stream_bytes == 61824U &&
          summary.total_weight_stream_bytes == 16849728U,
          "layer-long repeated parameter bytes are exact");
    check(ACCEL_SINGLE_SCALE_TOTAL_COMPUTE_FIRE == 3889197U,
          "ten-layer compute-fire total is exact");
    check(summary.max_layer_bias_stream_bytes == 26624U &&
          summary.max_layer_weight_stream_bytes == 9437184U,
          "layer-long parameter scratch high-water marks are exact");
    check(schedule[6].weight_stream_bytes == 9437184U &&
          schedule[6].weight_stream_bytes > (8U * 1024U * 1024U),
          "Conv6 weight stream requires the 20 MiB scratch path");

    for (i = 0U; i < ACCEL_SINGLE_SCALE_LAYER_COUNT; ++i) {
        uint32_t last_tile_h = schedule[i].conv_h -
            ((schedule[i].tile_count - 1U) * schedule[i].max_tile_ofm_h);
        check(schedule[i].max_tile_pixels <= ACCEL_SINGLE_SCALE_PSUM_BUF_DEPTH,
              "every pre-pool tile fits PSUM storage");
        check(schedule[i].max_tile_reorder_entries <=
                  ACCEL_SINGLE_SCALE_PACKED_REORDER_DEPTH,
              "every packed tile span fits reorder storage");
        if (schedule[i].plan->pool_enable != 0U) {
            check((schedule[i].max_tile_ofm_h % schedule[i].plan->pool_stride) == 0U &&
                  (last_tile_h % schedule[i].plan->pool_stride) == 0U,
                  "pooled regular and tail tile heights are stride aligned");
        }
    }

    invalid_layer = accel_single_scale_plan[0];
    invalid_layer.tile_h_max = 4U;
    rc = accel_single_scale_make_layer_schedule(&invalid_layer, 0U, 0, &invalid_schedule);
    check(rc == -32, "scheduler rejects a pre-pool tile beyond 1024 pixels");

    invalid_layer = accel_single_scale_plan[6];
    invalid_layer.tile_h_max = 13U;
    rc = accel_single_scale_make_layer_schedule(&invalid_layer, 6U, &schedule[5],
                                                &invalid_schedule);
    check(rc == -33, "scheduler rejects a packed tile span beyond 4096 entries");

    invalid_layer = accel_single_scale_plan[0];
    invalid_layer.tile_h_max = 1U;
    rc = accel_single_scale_make_layer_schedule(&invalid_layer, 0U, 0, &invalid_schedule);
    check(rc == -30, "scheduler rejects a pool tile not aligned to its stride");

    memset(&descriptor, 0xa5, sizeof(descriptor));
    rc = accel_single_scale_make_layer_desc_v2(&schedule[9], &descriptor);
    check(rc == 0, "v2 descriptor materialization succeeds");
    check(descriptor.abi_version == 2U && descriptor.layer_last == 1U,
          "last-layer descriptor carries ABI and layer_last");
    check(descriptor.tile_h_max == 13U && descriptor.ifm_total_bytes == 86528U &&
          descriptor.ofm_total_bytes == 4056U,
          "last-layer descriptor carries tile and byte totals");
    check(descriptor.act_mode == 2U && descriptor.input_zero_point == 11U,
          "last-layer descriptor carries numeric input configuration");
    check((descriptor.flags & ACCEL_LAYER_DESC_V2_FLAG_KERNEL_1X1) != 0U,
          "native 1x1 descriptor flag");

    if (failures != 0) {
        printf("FAIL: %d ABI v2 checks failed\n", failures);
        return 1;
    }
    printf("PASS: ABI v2 capability, descriptor, and 18x16 schedule\n");
    return 0;
}

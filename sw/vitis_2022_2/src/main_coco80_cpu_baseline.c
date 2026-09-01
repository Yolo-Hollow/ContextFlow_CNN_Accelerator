#include "coco80_cpu_baseline.h"
#include "coco80_cpu_conv.h"
#include "coco80_cpu_generated.h"
#include "coco80_decode.h"
#include "coco80_multicore.h"
#include "coco80_tensor_ops.h"

#include "xil_cache.h"
#include "xtime_l.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifndef C8_CPU_BASELINE_MODE
#define C8_CPU_BASELINE_MODE 1U
#endif
#ifndef C8_CPU_BASELINE_WARMUPS
#define C8_CPU_BASELINE_WARMUPS 1U
#endif
#ifndef C8_CPU_BASELINE_SAMPLES
#define C8_CPU_BASELINE_SAMPLES 3U
#endif

#define C8_PARAM_BASE ((uint8_t *)(uintptr_t)0x50000000U)
#define C8_INPUT_BASE ((uint8_t *)(uintptr_t)0x51200000U)
#define C8_EXPECTED_BASE ((uint8_t *)(uintptr_t)0x51300000U)
#define C8_SLOT0 ((uint8_t *)(uintptr_t)0x52000000U)
#define C8_SLOT1 ((uint8_t *)(uintptr_t)0x52400000U)
#define C8_ROUTE_M8 ((uint8_t *)(uintptr_t)0x52800000U)
#define C8_ROUTE_M15 ((uint8_t *)(uintptr_t)0x52900000U)
#define C8_CONCAT18 ((uint8_t *)(uintptr_t)0x52A00000U)
#define C8_P4 ((uint8_t *)(uintptr_t)0x52B00000U)
#define C8_P5 ((uint8_t *)(uintptr_t)0x52C00000U)
#define C8_CANDIDATES ((coco80_candidate_t *)(uintptr_t)0x52D00000U)
#define C8_DETECTIONS ((coco80_detection_t *)(uintptr_t)0x52E00000U)
#define C8_SHARED_BASE ((void *)(uintptr_t)0x50000000U)
#define C8_SHARED_BYTES 0x04000000U

#define C8_P4_BYTES (26U * 26U * 255U)
#define C8_P5_BYTES (13U * 13U * 255U)
#define C8_HEAD_BYTES (C8_P4_BYTES + C8_P5_BYTES)

#if C8_CPU_BASELINE_MODE == 4U
static coco80_mc_controller_t c8_controller;
#endif

static __attribute__((noinline)) coco80_cpu_baseline_result_t *c8_result_address(void)
{
    volatile uintptr_t address = COCO80_CPU_BASELINE_RESULT_ADDRESS;
    return (coco80_cpu_baseline_result_t *)address;
}

static uint64_t c8_now(void)
{
    XTime value;
    XTime_GetTime(&value);
    return (uint64_t)value;
}

static uint64_t c8_decode_now(void *opaque)
{
    (void)opaque;
    return c8_now();
}

static uint32_t c8_crc32_update(uint32_t crc, const uint8_t *data, uint32_t bytes)
{
    uint32_t i;
    crc = ~crc;
    for (i = 0U; i < bytes; ++i) {
        uint32_t value = (crc ^ data[i]) & 0xFFU;
        uint32_t bit;
        for (bit = 0U; bit < 8U; ++bit)
            value = (value >> 1U) ^ (0xEDB88320U & (0U - (value & 1U)));
        crc = (crc >> 8U) ^ value;
    }
    return ~crc;
}

static int c8_conv(uint32_t index, const uint8_t *ifm, uint8_t *ofm)
{
    const coco80_cpu_layer_t *layer = &coco80_cpu_layers[index];
    const int8_t *weight = (const int8_t *)(C8_PARAM_BASE + layer->weight_offset);
    const int32_t *bias = (const int32_t *)(const void *)(C8_PARAM_BASE + layer->bias_offset);
    const uint8_t *lut = C8_PARAM_BASE + layer->lut_offset;
#if C8_CPU_BASELINE_MODE == 4U
    return coco80_mc_cpu_conv_kco(
        &c8_controller, ifm, ofm, weight, bias, lut, layer);
#else
    return coco80_cpu_conv_kco_range(
        ifm, ofm, weight, bias, lut, layer, 0U, layer->ofm_c);
#endif
}

static int c8_pool_s2(
    uint8_t *source_data, uint32_t h, uint32_t w, uint32_t c,
    uint8_t *destination_data)
{
    coco80_hwc_u8_t source = {h, w, c, h * w * c, source_data};
    coco80_hwc_u8_t destination = {
        h / 2U, w / 2U, c, (h / 2U) * (w / 2U) * c, destination_data};
#if C8_CPU_BASELINE_MODE == 4U
    return coco80_mc_pool_s2(&c8_controller, &source, &destination);
#else
    return coco80_maxpool2x2_s2(&source, &destination);
#endif
}

static int c8_special_pool(uint8_t *source_data, uint8_t *destination_data)
{
    coco80_hwc_u8_t source = {13U, 13U, 512U, 13U * 13U * 512U, source_data};
    coco80_hwc_u8_t destination = source;
    destination.data = destination_data;
#if C8_CPU_BASELINE_MODE == 4U
    return coco80_mc_pool_s1_pad(
        &c8_controller, &source,
        (uint8_t)coco80_cpu_layers[5].output_zero_point, &destination);
#else
    return coco80_maxpool2x2_s1_pad_right_bottom(
        &source, (uint8_t)coco80_cpu_layers[5].output_zero_point, &destination);
#endif
}

static int c8_concat(uint8_t *small_data, uint8_t *destination_data)
{
    coco80_hwc_u8_t small = {13U, 13U, 128U, 13U * 13U * 128U, small_data};
    coco80_hwc_u8_t route = {26U, 26U, 256U, 26U * 26U * 256U, C8_ROUTE_M8};
    coco80_hwc_u8_t destination = {
        26U, 26U, 384U, 26U * 26U * 384U, destination_data};
#if C8_CPU_BASELINE_MODE == 4U
    return coco80_mc_nearest_requant_concat(
        &c8_controller, &small, &route,
        COCO80_CPU_ROUTE_INPUT_ZERO_POINT,
        COCO80_CPU_ROUTE_OUTPUT_ZERO_POINT,
        COCO80_CPU_ROUTE_MULTIPLIER, COCO80_CPU_ROUTE_SHIFT, &destination);
#else
    return coco80_nearest2x_requant_concat(
        &small, &route, COCO80_CPU_ROUTE_INPUT_ZERO_POINT,
        COCO80_CPU_ROUTE_OUTPUT_ZERO_POINT,
        COCO80_CPU_ROUTE_MULTIPLIER, COCO80_CPU_ROUTE_SHIFT, &destination);
#endif
}

static int c8_run_network(
    uint64_t layer_ticks[13], uint64_t *conv_ticks, uint64_t *tensor_ticks,
    uint64_t *decode_ticks, uint32_t *detection_count)
{
    uint64_t start;
    int rc;
#define C8_CONV(index, src, dst) do { \
    start = c8_now(); rc = c8_conv((index), (src), (dst)); \
    layer_ticks[(index)] = c8_now() - start; *conv_ticks += layer_ticks[(index)]; \
    if (rc != 0) return COCO80_CPU_BASELINE_ERR_COMPUTE; \
} while (0)
#define C8_TENSOR(expr) do { \
    uint64_t c8_start = c8_now(); rc = (expr); *tensor_ticks += c8_now() - c8_start; \
    if (rc != 0) return COCO80_CPU_BASELINE_ERR_COMPUTE; \
} while (0)
    C8_CONV(0U, C8_INPUT_BASE, C8_SLOT0);
    C8_TENSOR(c8_pool_s2(C8_SLOT0, 416U, 416U, 16U, C8_SLOT1));
    C8_CONV(1U, C8_SLOT1, C8_SLOT0);
    C8_TENSOR(c8_pool_s2(C8_SLOT0, 208U, 208U, 32U, C8_SLOT1));
    C8_CONV(2U, C8_SLOT1, C8_SLOT0);
    C8_TENSOR(c8_pool_s2(C8_SLOT0, 104U, 104U, 64U, C8_SLOT1));
    C8_CONV(3U, C8_SLOT1, C8_SLOT0);
    C8_TENSOR(c8_pool_s2(C8_SLOT0, 52U, 52U, 128U, C8_SLOT1));
    C8_CONV(4U, C8_SLOT1, C8_ROUTE_M8);
    C8_TENSOR(c8_pool_s2(C8_ROUTE_M8, 26U, 26U, 256U, C8_SLOT1));
    C8_CONV(5U, C8_SLOT1, C8_SLOT0);
    C8_TENSOR(c8_special_pool(C8_SLOT0, C8_SLOT1));
    C8_CONV(6U, C8_SLOT1, C8_SLOT0);
    C8_CONV(7U, C8_SLOT0, C8_SLOT1);
    C8_CONV(8U, C8_SLOT1, C8_ROUTE_M15);
    C8_CONV(9U, C8_SLOT1, C8_SLOT0);
    C8_TENSOR(c8_concat(C8_SLOT0, C8_CONCAT18));
    C8_CONV(10U, C8_CONCAT18, C8_SLOT0);
    C8_CONV(11U, C8_SLOT0, C8_P4);
    C8_CONV(12U, C8_ROUTE_M15, C8_P5);
#undef C8_CONV
#undef C8_TENSOR
    {
        coco80_quantized_head_t heads[2];
        coco80_letterbox_t letterbox;
        coco80_decode_config_t config;
        coco80_decode_workspace_t workspace;
        coco80_decode_result_t result;
        coco80_decode_timing_t timing;
        heads[0].data = C8_P4; heads[0].bytes = C8_P4_BYTES;
        heads[0].scale = COCO80_CPU_P4_SCALE;
        heads[0].zero_point = COCO80_CPU_P4_ZERO_POINT;
        heads[1].data = C8_P5; heads[1].bytes = C8_P5_BYTES;
        heads[1].scale = COCO80_CPU_P5_SCALE;
        heads[1].zero_point = COCO80_CPU_P5_ZERO_POINT;
        letterbox.original_width = COCO80_CPU_ORIGINAL_WIDTH;
        letterbox.original_height = COCO80_CPU_ORIGINAL_HEIGHT;
        letterbox.scale = COCO80_CPU_LETTERBOX_SCALE;
        letterbox.pad_x = COCO80_CPU_PAD_X;
        letterbox.pad_y = COCO80_CPU_PAD_Y;
        coco80_decode_config_demo(&config);
        workspace.candidates = C8_CANDIDATES;
        workspace.capacity = COCO80_TOTAL_ANCHORS;
        memset(&timing, 0, sizeof(timing));
        start = c8_now();
        rc = coco80_decode_dual_head_profiled(
            heads, &letterbox, &config, &workspace, C8_DETECTIONS,
            COCO80_ACCURACY_MAX_DETECTIONS, &result,
            c8_decode_now, NULL, &timing);
        *decode_ticks = c8_now() - start;
        if (rc != COCO80_DECODE_OK) return COCO80_CPU_BASELINE_ERR_DECODE;
        *detection_count = result.detection_count;
    }
    return 0;
}

static int c8_verify_heads(coco80_cpu_baseline_result_t *result)
{
    uint32_t index;
    uint32_t crc = c8_crc32_update(0U, C8_P4, C8_P4_BYTES);
    crc = c8_crc32_update(crc, C8_P5, C8_P5_BYTES);
    result->actual_heads_crc32 = crc;
    result->mismatch_bytes = 0U;
    result->first_mismatch_offset = UINT32_MAX;
    for (index = 0U; index < C8_P4_BYTES; ++index) {
        if (C8_P4[index] != C8_EXPECTED_BASE[index]) {
            if (result->mismatch_bytes == 0U) result->first_mismatch_offset = index;
            result->mismatch_bytes += 1U;
        }
    }
    for (index = 0U; index < C8_P5_BYTES; ++index) {
        if (C8_P5[index] != C8_EXPECTED_BASE[C8_P4_BYTES + index]) {
            if (result->mismatch_bytes == 0U)
                result->first_mismatch_offset = C8_P4_BYTES + index;
            result->mismatch_bytes += 1U;
        }
    }
    return result->mismatch_bytes == 0U &&
        crc == COCO80_CPU_EXPECTED_HEADS_CRC32 ? 0 :
        COCO80_CPU_BASELINE_ERR_MISMATCH;
}

int main(void)
{
    coco80_cpu_baseline_result_t *result = c8_result_address();
    uint32_t run;
    int rc = 0;
    Xil_ICacheEnable();
    Xil_DCacheEnable();
    memset(result, 0, sizeof(*result));
    result->magic = COCO80_CPU_BASELINE_MAGIC;
    result->version = COCO80_CPU_BASELINE_VERSION;
    result->status = COCO80_CPU_BASELINE_RUNNING;
    result->mode = C8_CPU_BASELINE_MODE;
    result->tick_hz = COUNTS_PER_SECOND;
    result->warmup_runs = C8_CPU_BASELINE_WARMUPS;
    result->timed_runs = C8_CPU_BASELINE_SAMPLES;
    result->image_id = COCO80_CPU_IMAGE_ID;
    Xil_DCacheFlushRange((UINTPTR)result, sizeof(*result));
    Xil_DCacheInvalidateRange((UINTPTR)C8_PARAM_BASE, COCO80_CPU_PARAM_BYTES);
    Xil_DCacheInvalidateRange((UINTPTR)C8_INPUT_BASE, 416U * 416U * 3U);
    Xil_DCacheInvalidateRange((UINTPTR)C8_EXPECTED_BASE, C8_HEAD_BYTES);
    result->parameter_crc32 = c8_crc32_update(0U, C8_PARAM_BASE, COCO80_CPU_PARAM_BYTES);
    result->input_crc32 = c8_crc32_update(0U, C8_INPUT_BASE, 416U * 416U * 3U);
    result->expected_heads_crc32 = c8_crc32_update(0U, C8_EXPECTED_BASE, C8_HEAD_BYTES);
    if (result->parameter_crc32 != COCO80_CPU_PARAM_CRC32 ||
        result->input_crc32 != COCO80_CPU_INPUT_CRC32 ||
        result->expected_heads_crc32 != COCO80_CPU_EXPECTED_HEADS_CRC32) {
        rc = COCO80_CPU_BASELINE_ERR_CRC;
        goto done;
    }
#if C8_CPU_BASELINE_MODE == 4U
    rc = coco80_mc_controller_initialize(
        &c8_controller, (uint64_t)COUNTS_PER_SECOND * 600U,
        C8_SHARED_BASE, C8_SHARED_BYTES);
    if (rc != 0) { rc = COCO80_CPU_BASELINE_ERR_MULTICORE; goto done; }
#endif
    for (run = 0U; run < C8_CPU_BASELINE_WARMUPS + C8_CPU_BASELINE_SAMPLES; ++run) {
        uint64_t layers[13] = {0U};
        uint64_t conv = 0U, tensor = 0U, decode = 0U;
        uint64_t start = c8_now();
        uint64_t run_total;
        uint32_t detections = 0U;
        uint32_t sample;
        rc = c8_run_network(layers, &conv, &tensor, &decode, &detections);
        run_total = c8_now() - start;
        if (rc != 0) goto done;
        rc = c8_verify_heads(result);
        if (rc != 0) goto done;
        result->detection_count = detections;
#if C8_CPU_BASELINE_WARMUPS != 0U
        if (run < C8_CPU_BASELINE_WARMUPS) continue;
#endif
        sample = run - C8_CPU_BASELINE_WARMUPS;
        result->total_ticks[sample] = run_total;
        result->conv_ticks[sample] = conv;
        result->tensor_ticks[sample] = tensor;
        result->decode_ticks[sample] = decode;
        memcpy(result->layer_ticks[sample], layers, sizeof(layers));
        Xil_DCacheFlushRange((UINTPTR)result, sizeof(*result));
    }
    rc = COCO80_CPU_BASELINE_PASS;
done:
    result->status = rc;
    Xil_DCacheFlushRange((UINTPTR)result, sizeof(*result));
    for (;;) __asm__ volatile("wfe");
}

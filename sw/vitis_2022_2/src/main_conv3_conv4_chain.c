#include "accel_smoke.h"
#if ACCEL_CHAIN_CONV0_CONV4 || ACCEL_CHAIN_CONV0_CONV5 || ACCEL_CHAIN_CONV0_CONV6 || ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
#include "conv0_pool_data.h"
#include "conv1_pool_data.h"
#include "conv2_pool_data.h"
#include "conv3_pool_data.h"
#include "conv4_pool_data.h"
#if ACCEL_CHAIN_CONV0_CONV5 || ACCEL_CHAIN_CONV0_CONV6 || ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
#include "conv5_pool_data.h"
#endif
#if ACCEL_CHAIN_CONV0_CONV6 || ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
#include "conv6_data.h"
#endif
#if ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
#include "conv7_data.h"
#endif
#if ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
#include "conv8_data.h"
#endif
#if ACCEL_CHAIN_CONV0_CONV9
#include "conv9_data.h"
#include "yolo_decode.h"
#if ACCEL_PREPACKED_WEIGHT
#if !CONV0_POOL_WEIGHT_PREPACKED || !CONV1_POOL_WEIGHT_PREPACKED || \
    !CONV2_POOL_WEIGHT_PREPACKED || !CONV3_POOL_WEIGHT_PREPACKED || \
    !CONV4_POOL_WEIGHT_PREPACKED || !CONV5_POOL_WEIGHT_PREPACKED || \
    !CONV6_WEIGHT_PREPACKED || !CONV7_WEIGHT_PREPACKED || \
    !CONV8_WEIGHT_PREPACKED || !CONV9_WEIGHT_PREPACKED
#error "ACCEL_PREPACKED_WEIGHT requires prepacked headers for every layer"
#endif
#endif
#endif
#else
#include "conv4_pool_data.h"
#if ACCEL_CHAIN_CONV4_CONV5
#include "conv5_pool_data.h"
#else
#include "layer06_tile4_data.h"
#endif
#endif

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_types.h"
#include "xtime_l.h"

#ifndef ACCEL_TAIL_CYCLES_OVERRIDE
#define ACCEL_TAIL_CYCLES_OVERRIDE 0
#endif
#ifndef ACCEL_RAW_HWC_IFM
#define ACCEL_RAW_HWC_IFM 0
#endif
#ifndef ACCEL_RAW_HWC_3X3
#define ACCEL_RAW_HWC_3X3 0
#endif
#ifndef ACCEL_RAW_HWC_CONV3
#define ACCEL_RAW_HWC_CONV3 0
#endif
#ifndef ACCEL_RAW_HWC_CONV4
#define ACCEL_RAW_HWC_CONV4 0
#endif
#ifndef ACCEL_RAW_HWC_CONV5
#define ACCEL_RAW_HWC_CONV5 0
#endif
#ifndef ACCEL_RAW_HWC_CONV6
#define ACCEL_RAW_HWC_CONV6 0
#endif
#ifndef ACCEL_RAW_HWC_CONV8
#define ACCEL_RAW_HWC_CONV8 0
#endif
#ifndef ACCEL_HWC_CACHE_DEPTH
#define ACCEL_HWC_CACHE_DEPTH 4096U
#endif
#ifndef ACCEL_BACKEND_FULL_TILE
#define ACCEL_BACKEND_FULL_TILE 0
#endif

#define UART0_BASE            0xFF000000U
#define UART1_BASE            0xFF010000U
#define UART_SR_OFFSET        0x2CU
#define UART_FIFO_OFFSET      0x30U
#define UART_SR_TXFULL        0x10U

#define CHAIN_ROWS            18U
#define CHAIN_COLS            8U
#define CHAIN_IFM_BANKS       2U
#define CHAIN_COUT_TILE       (CHAIN_COLS * 2U)
#define CHAIN_KH              3U
#define CHAIN_KW              3U

#if ACCEL_BATCH_STREAM
#define BATCH_BIAS_ADDR       0x18000000U
#define BATCH_BIAS_CAPACITY   0x00010000U
#define BATCH_WEIGHT_ADDR     0x18010000U
#define BATCH_WEIGHT_CAPACITY 0x00800000U
#define BATCH_IFM0_ADDR       0x18810000U
#define BATCH_IFM1_ADDR       0x19C10000U
#define BATCH_IFM_CAPACITY    0x01400000U
#define BATCH_SCRATCH_END     0x1B010000U
#endif

#if ACCEL_CHAIN_CONV0_CONV9_DDR
#define IMAGE_PACKAGE_ADDR    0x10000000U
#define IMAGE_PACKAGE_MAGIC   0x4F4C4F59U
#define IMAGE_PACKAGE_VERSION 1U
#define IMAGE_PACKAGE_HEADER_BYTES 64U

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t header_bytes;
    uint32_t tensor_bytes;
    uint32_t original_w;
    uint32_t original_h;
    float scale;
    float pad_x;
    float pad_y;
    uint32_t tensor_checksum;
    uint8_t reserved[24];
} image_package_header_t;

typedef char image_package_header_size_must_be_64[
    (sizeof(image_package_header_t) == IMAGE_PACKAGE_HEADER_BYTES) ? 1 : -1];
static const image_package_header_t *image_package;
#endif

#if ACCEL_CHAIN_CONV0_CONV9
#define CHAIN_SMOKE_NAME      "conv0_pool -> conv9 chained smoke"
#define MAX_FM_W              416U
#if ACCEL_BACKEND_FULL_TILE
#define MAX_TILE_OFM_BYTES    (13U * 13U * 1024U)
#else
#define MAX_TILE_OFM_BYTES    (13U * 4U * 1024U)
#endif
#elif ACCEL_CHAIN_CONV0_CONV8
#define CHAIN_SMOKE_NAME      "conv0_pool -> conv8 chained smoke"
#define MAX_FM_W              416U
#if ACCEL_BACKEND_FULL_TILE
#define MAX_TILE_OFM_BYTES    (13U * 13U * 1024U)
#else
#define MAX_TILE_OFM_BYTES    (13U * 4U * 1024U)
#endif
#elif ACCEL_CHAIN_CONV0_CONV7
#define CHAIN_SMOKE_NAME      "conv0_pool -> conv7 chained smoke"
#define MAX_FM_W              416U
#if ACCEL_BACKEND_FULL_TILE
#define MAX_TILE_OFM_BYTES    (13U * 13U * 1024U)
#else
#define MAX_TILE_OFM_BYTES    (13U * 4U * 1024U)
#endif
#elif ACCEL_CHAIN_CONV0_CONV6
#define CHAIN_SMOKE_NAME      "conv0_pool -> conv6 chained smoke"
#define MAX_FM_W              416U
#if ACCEL_BACKEND_FULL_TILE
#define MAX_TILE_OFM_BYTES    (13U * 13U * 1024U)
#else
#define MAX_TILE_OFM_BYTES    (13U * 4U * 1024U)
#endif
#elif ACCEL_CHAIN_CONV0_CONV5
#define CHAIN_SMOKE_NAME      "conv0_pool -> conv5 chained smoke"
#define MAX_FM_W              416U
#if ACCEL_BACKEND_FULL_TILE
#define MAX_TILE_OFM_BYTES    (13U * 13U * 512U)
#else
#define MAX_TILE_OFM_BYTES    (13U * 4U * 512U)
#endif
#elif ACCEL_CHAIN_CONV0_CONV4
#define CHAIN_SMOKE_NAME      "conv0_pool -> conv4_pool chained smoke"
#define MAX_FM_W              416U
#define MAX_TILE_OFM_BYTES    (52U * 4U * 64U)
#elif ACCEL_CHAIN_CONV4_CONV5
#define CHAIN_SMOKE_NAME      "conv4_pool -> conv5 chained smoke"
#define MAX_FM_W              52U
#if ACCEL_BACKEND_FULL_TILE
#define MAX_TILE_OFM_BYTES    (13U * 13U * 512U)
#else
#define MAX_TILE_OFM_BYTES    (13U * 4U * 512U)
#endif
#else
#define CHAIN_SMOKE_NAME      "conv3_pool -> conv4_pool chained smoke"
#define MAX_FM_W              52U
#define MAX_TILE_OFM_BYTES    (13U * 2U * 256U)
#endif

typedef struct {
    const char *name;
    uint32_t tile_oy_base;
    uint32_t tile_ofm_h;
    uint32_t tile_pixel_base;
    uint32_t tile_pixels;
    uint32_t expected_ofm_bytes;
} chain_tile_t;

typedef struct {
    const char *name;
    uint32_t fm_w;
    uint32_t fm_h;
    uint32_t ofm_w;
    uint32_t ofm_h;
    uint32_t cin;
    uint32_t cout_total;
    uint32_t k_total;
    uint32_t k_passes;
    uint32_t cout_blocks;
    uint32_t input_zero_point;
    uint32_t quant_mult;
    uint32_t quant_shift;
    uint32_t quant_zp;
    uint32_t pool_enable;
    uint32_t pool_stride;
    uint32_t total_output_pixels;
    uint32_t total_expected_ofm_bytes;
    const uint8_t *ifm_u8;
    const int8_t *weight_s8;
    const int32_t *bias_i32;
    const uint8_t *activation_lut_u8;
    const uint8_t *golden_ofm_u8;
    uint8_t *ofm_u8;
    const chain_tile_t *tiles;
    uint32_t tile_count;
    uint32_t dynamic_tile_ofm_h;
    uint32_t kernel_1x1;
    uint32_t raw_hwc_mode;
} chain_layer_t;

static uint64_t bias_buf[CHAIN_COUT_TILE / 2U] __attribute__((aligned(64)));
static uint64_t weight_buf[(CHAIN_ROWS * CHAIN_COUT_TILE) / 8U] __attribute__((aligned(64)));
static uint64_t ifm_buf[MAX_FM_W] __attribute__((aligned(64)));
static uint64_t ofm_axis_buf[MAX_TILE_OFM_BYTES] __attribute__((aligned(64)));
#if ACCEL_CHAIN_CONV0_CONV4 || ACCEL_CHAIN_CONV0_CONV5 || ACCEL_CHAIN_CONV0_CONV6 || ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
static uint8_t feature_buffer0[208U * 208U * 16U] __attribute__((aligned(64)));
static uint8_t feature_buffer1[104U * 104U * 32U] __attribute__((aligned(64)));
#if ACCEL_CHAIN_CONV0_CONV9
static yolo_detection_t yolo_detections[YOLO_MAX_CANDIDATES];
#endif
#elif ACCEL_CHAIN_CONV4_CONV5
static uint8_t conv4_ofm[13U * 13U * 256U] __attribute__((aligned(64)));
static uint8_t conv5_ofm[13U * 13U * 512U] __attribute__((aligned(64)));
#else
static uint8_t conv3_ofm[26U * 26U * 128U] __attribute__((aligned(64)));
static uint8_t conv4_ofm[13U * 13U * 256U] __attribute__((aligned(64)));
#endif
volatile uint32_t debug_stage = 0;
volatile uint32_t debug_value = 0;

typedef struct {
    XTime layer_total;
    XTime dma_reset;
    XTime configure;
    XTime clear;
    XTime tile_total;
    XTime bias_pack;
    XTime bias_dma;
    XTime bias_sync;
    XTime weight_pack;
    XTime weight_dma;
    XTime weight_sync;
    XTime ifm_pack;
    XTime ifm_dma;
    XTime ifm_sync;
    XTime ofm_dma;
    XTime ofm_parse;
    XTime compare;
    XTime cache;
    uint64_t hw_busy_cycles;
    uint64_t hw_wait_cycles;
    uint64_t hw_wait_bias_cycles;
    uint64_t hw_wait_weight_cycles;
    uint64_t hw_wait_ifm_cycles;
    uint64_t hw_wait_ofm_cycles;
    uint64_t hw_compute_cycles;
    uint64_t hw_stage_bias_cycles;
    uint64_t hw_stage_weight_cycles;
    uint64_t hw_stage_feeder_cycles;
    uint64_t hw_stage_compute_cycles;
    uint64_t hw_stage_drain_cycles;
    uint64_t hw_stage_ofm_post_cycles;
    uint64_t hw_feed_fill_wait_cycles;
    uint64_t hw_feed_push_cycles;
    uint64_t hw_feed_fifo_stall_cycles;
    uint64_t hw_feed_win_not_ready_cycles;
    uint64_t hw_comp_wload_cycles;
    uint64_t hw_comp_active_cycles;
    uint64_t hw_comp_fire_cycles;
    uint64_t hw_comp_ifm_stall_cycles;
    uint64_t hw_comp_tail_cycles;
    uint64_t hw_subperf_version;
    uint64_t hw_tail_config_cycles;
    uint64_t hw_raw_compute_start_level;
    uint64_t hw_tail_elapsed_cycles;
    uint64_t hw_drain_empty_wait_cycles;
    uint64_t hw_drain_empty_sticky;
    uint64_t hw_drain_read_fire_cycles;
    uint64_t hw_drain_packet_fire_cycles;
    uint64_t hw_drain_ready_stall_cycles;
    uint64_t hw_drain_internal_full_cycles;
    uint64_t hw_drainperf_version;
    uint64_t hw_prefetch_start_cycles;
    uint64_t hw_prefetch_weight_done_cycles;
    uint64_t hw_prefetch_feed_done_cycles;
    uint64_t hw_prefetch_hit_cycles;
    uint64_t hw_prefetch_miss_cycles;
    uint64_t hw_prefetch_stall_cycles;
    uint64_t hw_prefetchperf_version;
    uint64_t hw_psumovl_start_cycles;
    uint64_t hw_psumovl_hit_cycles;
    uint64_t hw_psumovl_wait_psum_cycles;
    uint64_t hw_psumovl_underflow_cycles;
    uint64_t hw_psumovlperf_version;
    uint64_t hw_collect_packet_fire_cycles;
    uint64_t hw_collect_partial_write_cycles;
    uint64_t hw_collect_final_write_cycles;
    uint64_t hw_collect_context_push_cycles;
    uint64_t hw_collect_context_pop_cycles;
    uint64_t hw_collect_context_full_stall_cycles;
    uint64_t hw_collect_column_empty_wait_cycles;
    uint64_t hw_collectperf_version;
    uint64_t hw_pass_count;
    uint64_t hw_pass_start_to_first_fire_cycles;
    uint64_t hw_pass_first_to_last_fire_cycles;
    uint64_t hw_pass_last_fire_to_done_cycles;
    uint64_t hw_pass_collect_first_wait_cycles;
    uint64_t hw_pass_collect_column_empty_cycles;
    uint64_t hw_pass_replay_during_compute_cycles;
    uint64_t hw_pass_compute_idle_stage_cycles;
    uint64_t hw_passperf_version;
    uint64_t vector_packets;
    uint64_t vector_pixels;
    uint64_t vector_beats;
    uint64_t vector_fifo_stall_cycles;
    uint64_t raw_load_active_cycles;
    uint64_t raw_load_unpack_cycles;
    uint64_t raw_replay_active_cycles;
    uint64_t raw_replay_wait_ready_cycles;
    uint32_t dma_bias_starts;
    uint32_t dma_weight_starts;
    uint32_t dma_ifm_starts;
    uint32_t dma_ofm_starts;
} layer_perf_t;

static layer_perf_t layer_perf;

#if !ACCEL_CHAIN_CONV4_CONV5 && !ACCEL_CHAIN_CONV0_CONV4 && !ACCEL_CHAIN_CONV0_CONV5 && !ACCEL_CHAIN_CONV0_CONV6 && !ACCEL_CHAIN_CONV0_CONV7 && !ACCEL_CHAIN_CONV0_CONV8 && !ACCEL_CHAIN_CONV0_CONV9
static const chain_tile_t conv3_tiles[13] = {
    {"conv3_tile0", 0U, 4U, 0U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile1", 4U, 4U, 1U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile2", 8U, 4U, 2U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile3", 12U, 4U, 3U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile4", 16U, 4U, 4U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile5", 20U, 4U, 5U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile6", 24U, 4U, 6U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile7", 28U, 4U, 7U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile8", 32U, 4U, 8U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile9", 36U, 4U, 9U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile10", 40U, 4U, 10U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile11", 44U, 4U, 11U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile12", 48U, 4U, 12U * 52U, 52U * 4U, 26U * 2U * 128U},
};
#endif

#if !ACCEL_CHAIN_CONV0_CONV4 && !ACCEL_CHAIN_CONV0_CONV5 && !ACCEL_CHAIN_CONV0_CONV6 && !ACCEL_CHAIN_CONV0_CONV7 && !ACCEL_CHAIN_CONV0_CONV8 && !ACCEL_CHAIN_CONV0_CONV9
static const chain_tile_t conv4_tiles[7] = {
    {"conv4_tile0", 0U, 4U, 0U * 26U, 26U * 4U, 13U * 2U * 256U},
    {"conv4_tile1", 4U, 4U, 1U * 26U, 26U * 4U, 13U * 2U * 256U},
    {"conv4_tile2", 8U, 4U, 2U * 26U, 26U * 4U, 13U * 2U * 256U},
    {"conv4_tile3", 12U, 4U, 3U * 26U, 26U * 4U, 13U * 2U * 256U},
    {"conv4_tile4", 16U, 4U, 4U * 26U, 26U * 4U, 13U * 2U * 256U},
    {"conv4_tile5", 20U, 4U, 5U * 26U, 26U * 4U, 13U * 2U * 256U},
    {"conv4_tile6", 24U, 2U, 6U * 26U, 26U * 2U, 13U * 1U * 256U},
};
#endif

#if ACCEL_CHAIN_CONV4_CONV5 || ACCEL_CHAIN_CONV0_CONV5 || ACCEL_CHAIN_CONV0_CONV6 || ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
#if ACCEL_BACKEND_FULL_TILE
static const chain_tile_t conv5_tiles[1] = {
    {"conv5_fulltile", 0U, 13U, 0U * 13U, 13U * 13U, 13U * 13U * 512U},
};
#else
static const chain_tile_t conv5_tiles[4] = {
    {"conv5_tile0", 0U, 4U, 0U * 13U, 13U * 4U, 13U * 4U * 512U},
    {"conv5_tile1", 4U, 4U, 4U * 13U, 13U * 4U, 13U * 4U * 512U},
    {"conv5_tile2", 8U, 4U, 8U * 13U, 13U * 4U, 13U * 4U * 512U},
    {"conv5_tile3", 12U, 1U, 12U * 13U, 13U * 1U, 13U * 1U * 512U},
};
#endif
#endif

#if ACCEL_CHAIN_CONV0_CONV6 || ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
#if ACCEL_BACKEND_FULL_TILE
static const chain_tile_t conv6_tiles[1] = {
    {"conv6_fulltile", 0U, 13U, 0U * 13U, 13U * 13U, 13U * 13U * 1024U},
};
#else
static const chain_tile_t conv6_tiles[4] = {
    {"conv6_tile0", 0U, 4U, 0U * 13U, 13U * 4U, 13U * 4U * 1024U},
    {"conv6_tile1", 4U, 4U, 4U * 13U, 13U * 4U, 13U * 4U * 1024U},
    {"conv6_tile2", 8U, 4U, 8U * 13U, 13U * 4U, 13U * 4U * 1024U},
    {"conv6_tile3", 12U, 1U, 12U * 13U, 13U * 1U, 13U * 1U * 1024U},
};
#endif
#endif

#if ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
static const chain_tile_t conv7_tiles[4] = {
    {"conv7_tile0", 0U, 4U, 0U * 13U, 13U * 4U, 13U * 4U * 256U},
    {"conv7_tile1", 4U, 4U, 4U * 13U, 13U * 4U, 13U * 4U * 256U},
    {"conv7_tile2", 8U, 4U, 8U * 13U, 13U * 4U, 13U * 4U * 256U},
    {"conv7_tile3", 12U, 1U, 12U * 13U, 13U * 1U, 13U * 1U * 256U},
};
#endif

#if ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
#if ACCEL_BACKEND_FULL_TILE
static const chain_tile_t conv8_tiles[1] = {
    {"conv8_fulltile", 0U, 13U, 0U * 13U, 13U * 13U, 13U * 13U * 512U},
};
#else
static const chain_tile_t conv8_tiles[4] = {
    {"conv8_tile0", 0U, 4U, 0U * 13U, 13U * 4U, 13U * 4U * 512U},
    {"conv8_tile1", 4U, 4U, 4U * 13U, 13U * 4U, 13U * 4U * 512U},
    {"conv8_tile2", 8U, 4U, 8U * 13U, 13U * 4U, 13U * 4U * 512U},
    {"conv8_tile3", 12U, 1U, 12U * 13U, 13U * 1U, 13U * 1U * 512U},
};
#endif
#endif

#if ACCEL_CHAIN_CONV0_CONV9
static const chain_tile_t conv9_tiles[4] = {
    {"conv9_tile0", 0U, 4U, 0U * 13U, 13U * 4U, 13U * 4U * 24U},
    {"conv9_tile1", 4U, 4U, 4U * 13U, 13U * 4U, 13U * 4U * 24U},
    {"conv9_tile2", 8U, 4U, 8U * 13U, 13U * 4U, 13U * 4U * 24U},
    {"conv9_tile3", 12U, 1U, 12U * 13U, 13U * 1U, 13U * 1U * 24U},
};
#endif

#if ACCEL_CHAIN_CONV0_CONV4 || ACCEL_CHAIN_CONV0_CONV5 || ACCEL_CHAIN_CONV0_CONV6 || ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
static chain_layer_t conv0_layer = {
    "conv0_pool",
    416U, 416U, 416U, 416U,
    3U, 16U, 3U * 9U, 2U, 1U,
    0U, 18898U, 9U, 69U,
    1U, 2U,
    208U * 208U, 208U * 208U * 16U,
#if ACCEL_CHAIN_CONV0_CONV9_DDR
    (const uint8_t *)(UINTPTR)(IMAGE_PACKAGE_ADDR + IMAGE_PACKAGE_HEADER_BYTES),
#else
    conv0_pool_ifm_u8,
#endif
    conv0_pool_weight_s8,
    conv0_pool_bias_i32,
    conv0_pool_activation_lut_u8,
    conv0_pool_golden_ofm_u8,
    feature_buffer0,
    0,
    208U,
    2U,
};

static chain_layer_t conv1_layer = {
    "conv1_pool",
    208U, 208U, 208U, 208U,
    16U, 32U, 16U * 9U, 8U, 2U,
    13U, 18333U, 7U, 101U,
    1U, 2U,
    104U * 104U, 104U * 104U * 32U,
    feature_buffer0,
    conv1_pool_weight_s8,
    conv1_pool_bias_i32,
    conv1_pool_activation_lut_u8,
    conv1_pool_golden_ofm_u8,
    feature_buffer1,
    0,
    52U,
    4U,
};

static chain_layer_t conv2_layer = {
    "conv2_pool",
    104U, 104U, 104U, 104U,
    32U, 64U, 32U * 9U, 16U, 4U,
    36U, 21260U, 7U, 101U,
    1U, 2U,
    52U * 52U, 52U * 52U * 64U,
    feature_buffer1,
    conv2_pool_weight_s8,
    conv2_pool_bias_i32,
    conv2_pool_activation_lut_u8,
    conv2_pool_golden_ofm_u8,
    feature_buffer0,
    0,
    13U,
    8U,
};

static chain_layer_t conv3_layer = {
    "conv3_pool",
    52U, 52U, 52U, 52U,
    64U, 128U, 64U * 9U, 32U, 8U,
    36U, 18055U, 7U, 75U,
    1U, 2U,
    26U * 26U, 26U * 26U * 128U,
    feature_buffer0,
    conv3_pool_weight_s8,
    conv3_pool_bias_i32,
    conv3_pool_activation_lut_u8,
    conv3_pool_golden_ofm_u8,
    feature_buffer1,
    0,
#if ACCEL_BACKEND_FULL_TILE
    3U,
    18U,
#else
    7U,
    8U,
#endif
    0U,
    ACCEL_RAW_HWC_CONV3,
};

static chain_layer_t conv4_layer = {
    "conv4_pool",
    26U, 26U, 26U, 26U,
    128U, 256U, 128U * 9U, 64U, 16U,
    16U, 18831U, 7U, 73U,
    1U, 2U,
    13U * 13U, 13U * 13U * 256U,
    feature_buffer1,
    conv4_pool_weight_s8,
    conv4_pool_bias_i32,
    conv4_pool_activation_lut_u8,
    conv4_pool_golden_ofm_u8,
    feature_buffer0,
    0,
#if ACCEL_BACKEND_FULL_TILE
    1U,
    26U,
#else
    4U,
    8U,
#endif
    0U,
    ACCEL_RAW_HWC_CONV4,
};

#if ACCEL_CHAIN_CONV0_CONV5 || ACCEL_CHAIN_CONV0_CONV6 || ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
static chain_layer_t conv5_layer = {
    "conv5",
    13U, 13U, 13U, 13U,
    256U, 512U, 256U * 9U, 128U, 32U,
    15U, 16863U, 7U, 82U,
    0U, 0U,
    13U * 13U, 13U * 13U * 512U,
    feature_buffer0,
    conv5_pool_weight_s8,
    conv5_pool_bias_i32,
    conv5_pool_activation_lut_u8,
    conv5_pool_golden_ofm_u8,
    feature_buffer1,
    conv5_tiles,
#if ACCEL_BACKEND_FULL_TILE
    1U,
#else
    4U,
#endif
    0U,
    0U,
    ACCEL_RAW_HWC_CONV5,
};
#endif

#if ACCEL_CHAIN_CONV0_CONV6 || ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
static chain_layer_t conv6_layer = {
    "conv6",
    13U, 13U, 13U, 13U,
    512U, 1024U, 512U * 9U, 256U, 64U,
    19U, 26505U, 9U, 85U,
    0U, 0U,
    13U * 13U, 13U * 13U * 1024U,
    feature_buffer1,
    conv6_weight_s8,
    conv6_bias_i32,
    conv6_activation_lut_u8,
    conv6_golden_ofm_u8,
    feature_buffer0,
    conv6_tiles,
#if ACCEL_BACKEND_FULL_TILE
    1U,
#else
    4U,
#endif
    0U,
    0U,
    ACCEL_RAW_HWC_CONV6,
};
#endif

#if ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
static chain_layer_t conv7_layer = {
    ACCEL_NATIVE_1X1 ? "conv7_native1x1" : "conv7_sparse3x3",
    13U, 13U, 13U, 13U,
    1024U, 256U, CONV7_HW_K_TOTAL,
    (CONV7_HW_K_TOTAL + CHAIN_ROWS - 1U) / CHAIN_ROWS, 16U,
    21U, 28217U, 7U, 69U,
    0U, 0U,
    13U * 13U, 13U * 13U * 256U,
    feature_buffer0,
    conv7_weight_s8,
    conv7_bias_i32,
    conv7_activation_lut_u8,
    conv7_golden_ofm_u8,
    feature_buffer1,
    conv7_tiles,
    4U,
    0U,
    ACCEL_NATIVE_1X1,
    0U,
};
#endif

#if ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
static chain_layer_t conv8_layer = {
    "conv8",
    13U, 13U, 13U, 13U,
    256U, 512U, 256U * 9U, 128U, 32U,
    13U, 22396U, 8U, 63U,
    0U, 0U,
    13U * 13U, 13U * 13U * 512U,
    feature_buffer1,
    conv8_weight_s8,
    conv8_bias_i32,
    conv8_activation_lut_u8,
    conv8_golden_ofm_u8,
    feature_buffer0,
    conv8_tiles,
#if ACCEL_BACKEND_FULL_TILE
    1U,
#else
    4U,
#endif
    0U,
    0U,
    ACCEL_RAW_HWC_CONV8,
};
#endif

#if ACCEL_CHAIN_CONV0_CONV9
static chain_layer_t conv9_layer = {
    ACCEL_NATIVE_1X1 ? "conv9_detect_native1x1" : "conv9_detect_sparse3x3",
    13U, 13U, 13U, 13U,
    512U, 24U, CONV9_HW_K_TOTAL,
    (CONV9_HW_K_TOTAL + CHAIN_ROWS - 1U) / CHAIN_ROWS, 2U,
    11U, 23304U, 8U, 80U,
    0U, 0U,
    13U * 13U, 13U * 13U * 24U,
    feature_buffer0,
    conv9_weight_s8,
    conv9_bias_i32,
    conv9_activation_lut_u8,
    conv9_golden_ofm_u8,
    feature_buffer1,
    conv9_tiles,
    4U,
    0U,
    ACCEL_NATIVE_1X1,
    0U,
};
#endif

static chain_layer_t *chain_layers[] = {
    &conv0_layer,
    &conv1_layer,
    &conv2_layer,
    &conv3_layer,
    &conv4_layer,
#if ACCEL_CHAIN_CONV0_CONV5 || ACCEL_CHAIN_CONV0_CONV6 || ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
    &conv5_layer,
#endif
#if ACCEL_CHAIN_CONV0_CONV6 || ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
    &conv6_layer,
#endif
#if ACCEL_CHAIN_CONV0_CONV7 || ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
    &conv7_layer,
#endif
#if ACCEL_CHAIN_CONV0_CONV8 || ACCEL_CHAIN_CONV0_CONV9
    &conv8_layer,
#endif
#if ACCEL_CHAIN_CONV0_CONV9
    &conv9_layer,
#endif
};
#elif ACCEL_CHAIN_CONV4_CONV5
static chain_layer_t stage0_layer = {
    "conv4_pool",
    26U, 26U, 26U, 26U,
    128U, 256U, 128U * 9U, 64U, 16U,
    16U, 18831U, 7U, 73U,
    1U, 2U,
    13U * 13U, 13U * 13U * 256U,
    conv4_pool_ifm_u8,
    conv4_pool_weight_s8,
    conv4_pool_bias_i32,
    conv4_pool_activation_lut_u8,
    conv4_pool_golden_ofm_u8,
    conv4_ofm,
    conv4_tiles,
    7U,
    0U,
};

static chain_layer_t stage1_layer = {
    "conv5",
    13U, 13U, 13U, 13U,
    256U, 512U, 256U * 9U, 128U, 32U,
    15U, 16863U, 7U, 82U,
    0U, 0U,
    13U * 13U, 13U * 13U * 512U,
    conv4_ofm,
    conv5_pool_weight_s8,
    conv5_pool_bias_i32,
    conv5_pool_activation_lut_u8,
    conv5_pool_golden_ofm_u8,
    conv5_ofm,
    conv5_tiles,
    4U,
    0U,
};
static chain_layer_t *chain_layers[] = {&stage0_layer, &stage1_layer};
#else
static chain_layer_t stage0_layer = {
    "conv3_pool",
    52U, 52U, 52U, 52U,
    64U, 128U, 64U * 9U, 32U, 8U,
    36U, 18055U, 7U, 75U,
    1U, 2U,
    26U * 26U, 26U * 26U * 128U,
    layer06_tile4_ifm_u8,
    layer06_tile4_weight_s8,
    layer06_tile4_bias_i32,
    layer06_tile4_activation_lut_u8,
    layer06_pool_golden_ofm_u8,
    conv3_ofm,
    conv3_tiles,
    13U,
    0U,
};

static chain_layer_t stage1_layer = {
    "conv4_pool",
    26U, 26U, 26U, 26U,
    128U, 256U, 128U * 9U, 64U, 16U,
    16U, 18831U, 7U, 73U,
    1U, 2U,
    13U * 13U, 13U * 13U * 256U,
    conv3_ofm,
    conv4_pool_weight_s8,
    conv4_pool_bias_i32,
    conv4_pool_activation_lut_u8,
    conv4_pool_golden_ofm_u8,
    conv4_ofm,
    conv4_tiles,
    7U,
    0U,
};
static chain_layer_t *chain_layers[] = {&stage0_layer, &stage1_layer};
#endif

static void uart_putc_one(uint32_t base, char c)
{
    for (uint32_t i = 0; i < 100000U; ++i) {
        if ((Xil_In32(base + UART_SR_OFFSET) & UART_SR_TXFULL) == 0U) {
            Xil_Out32(base + UART_FIFO_OFFSET, (uint32_t)c);
            return;
        }
    }
}

static void uart_putc_all(char c)
{
    if (c == '\n') {
        uart_putc_all('\r');
    }
    uart_putc_one(UART0_BASE, c);
    uart_putc_one(UART1_BASE, c);
}

static void uart_puts_all(const char *s)
{
    while (*s != '\0') {
        uart_putc_all(*s++);
    }
}

static void log_printf(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    uart_puts_all(buf);
}

#define xil_printf(...) log_printf(__VA_ARGS__)

#if ACCEL_PERF_ONLY
#define trace_printf(...) do { } while (0)
#else
#define trace_printf(...) xil_printf(__VA_ARGS__)
#endif

static inline void wr32(uint32_t base, uint32_t off, uint32_t v)
{
    Xil_Out32(base + off, v);
}

static inline uint32_t rd32(uint32_t base, uint32_t off)
{
    return Xil_In32(base + off);
}

static void accel_write_reg(uint32_t off, uint32_t v)
{
    wr32(ACCEL_BASE_ADDR, off, v);
}

static uint32_t accel_read_reg(uint32_t off)
{
    return rd32(ACCEL_BASE_ADDR, off);
}

static int program_quant_tile(const chain_layer_t *layer)
{
    uint32_t packed = ACCEL_QUANT_PACK(layer->quant_mult, layer->quant_shift, layer->quant_zp);
    for (uint32_t lane = 0U; lane < CHAIN_COUT_TILE; ++lane) {
        accel_write_reg(ACCEL_QUANT_ADDR, lane);
        accel_write_reg(ACCEL_QUANT_DATA, packed);
        if (accel_read_reg(ACCEL_QUANT_DATA) != packed) {
            xil_printf("%s quant readback mismatch lane=%lu\r\n", layer->name, (unsigned long)lane);
            return -1;
        }
    }
    return 0;
}

static int program_activation_lut(const chain_layer_t *layer)
{
    for (uint32_t idx = 0U; idx < 256U; ++idx) {
        uint32_t data = layer->activation_lut_u8[idx];
        accel_write_reg(ACCEL_LUT_ADDR, idx);
        accel_write_reg(ACCEL_LUT_DATA, data);
        if ((accel_read_reg(ACCEL_LUT_DATA) & 0xffU) != data) {
            xil_printf("%s lut readback mismatch idx=%lu\r\n", layer->name, (unsigned long)idx);
            return -1;
        }
    }
    return 0;
}

static int pass_needs_ch(const chain_layer_t *layer, uint32_t k_base, uint32_t ch)
{
    return (ch < layer->cin) && (k_base < (ch + 1U) * 9U) && ((k_base + CHAIN_ROWS) > ch * 9U);
}

static int channel_for_bank(const chain_layer_t *layer, uint32_t k_base, uint32_t bank)
{
    for (uint32_t ch = 0U; ch < layer->cin; ++ch) {
        if (pass_needs_ch(layer, k_base, ch) && ((ch % CHAIN_IFM_BANKS) == bank)) {
            return (int)ch;
        }
    }
    return -1;
}

static void pack_bias_to(const chain_layer_t *layer, uint32_t cout_base, uint64_t *dst)
{
    for (uint32_t i = 0U; i < CHAIN_COUT_TILE; i += 2U) {
        uint32_t lo_co = cout_base + i;
        uint32_t hi_co = cout_base + i + 1U;
        uint32_t lo = (lo_co < layer->cout_total) ? (uint32_t)layer->bias_i32[lo_co] : 0U;
        uint32_t hi = (hi_co < layer->cout_total) ? (uint32_t)layer->bias_i32[hi_co] : 0U;
        dst[i / 2U] = ((uint64_t)hi << 32) | lo;
    }
}

static void pack_bias(const chain_layer_t *layer, uint32_t cout_base)
{
    pack_bias_to(layer, cout_base, bias_buf);
}

static void pack_weight_to(
    const chain_layer_t *layer,
    uint32_t k_base,
    uint32_t cout_base,
    uint64_t *dst)
{
    uint32_t lane = 0U;
    uint64_t word = 0U;
    uint32_t out = 0U;
    for (uint32_t kk = 0U; kk < CHAIN_ROWS; ++kk) {
        for (uint32_t cc = 0U; cc < CHAIN_COUT_TILE; ++cc) {
            uint32_t gk = k_base + kk;
            uint32_t co = cout_base + cc;
            uint8_t v = 0U;
            if (gk < layer->k_total && co < layer->cout_total) {
                v = (uint8_t)layer->weight_s8[gk * layer->cout_total + co];
            }
            word |= ((uint64_t)v) << (lane * 8U);
            if (lane == 7U) {
                dst[out++] = word;
                word = 0U;
                lane = 0U;
            } else {
                ++lane;
            }
        }
    }
}

static void pack_weight(const chain_layer_t *layer, uint32_t k_base, uint32_t cout_base)
{
    pack_weight_to(layer, k_base, cout_base, weight_buf);
}

static void pack_ifm_line_to(
    const chain_layer_t *layer,
    int fy,
    uint32_t k_base,
    uint64_t *dst)
{
    int channel[CHAIN_IFM_BANKS];

    for (uint32_t b = 0U; b < CHAIN_IFM_BANKS; ++b) {
        channel[b] = channel_for_bank(layer, k_base, b);
    }
    const uint8_t *row = layer->ifm_u8 + (uint32_t)fy * layer->fm_w * layer->cin;
    for (uint32_t x = 0U; x < layer->fm_w; ++x) {
        uint64_t word = 0U;
        for (uint32_t b = 0U; b < CHAIN_IFM_BANKS; ++b) {
            int ch = channel[b];
            uint8_t v = (ch >= 0) ? row[x * layer->cin + (uint32_t)ch] : 0U;
            word |= ((uint64_t)v) << (b * 8U);
        }
        dst[x] = word;
    }
}

static void pack_ifm_line_channels_to(
    const chain_layer_t *layer,
    int fy,
    const int channel[CHAIN_IFM_BANKS],
    uint64_t *dst)
{
    const uint8_t *row = layer->ifm_u8 + (uint32_t)fy * layer->fm_w * layer->cin;

    for (uint32_t x = 0U; x < layer->fm_w; ++x) {
        uint64_t word = 0U;
        for (uint32_t b = 0U; b < CHAIN_IFM_BANKS; ++b) {
            int ch = channel[b];
            uint8_t v = (ch >= 0) ? row[x * layer->cin + (uint32_t)ch] : 0U;
            word |= ((uint64_t)v) << (b * 8U);
        }
        dst[x] = word;
    }
}

static void copy_u64_words(uint64_t *dst, const uint64_t *src, uint32_t words)
{
    for (uint32_t i = 0U; i < words; ++i) {
        dst[i] = src[i];
    }
}

static void pack_ifm_line(const chain_layer_t *layer, int fy, uint32_t k_base)
{
    pack_ifm_line_to(layer, fy, k_base, ifm_buf);
}

static void dma_reset_named(const char *name, uint32_t base, uint32_t cr_off, uint32_t sr_off)
{
    trace_printf("dma reset: %s\r\n", name);
    wr32(base, cr_off, DMA_DMACR_RESET);
    for (uint32_t i = 0U; i < 1000000U; ++i) {
        if ((rd32(base, cr_off) & DMA_DMACR_RESET) == 0U) {
            break;
        }
    }
    wr32(base, sr_off, 0x00007000U);
}

static void dma_reset_all(void)
{
    dma_reset_named("bias", DMA_BIAS_BASE_ADDR, DMA_MM2S_DMACR, DMA_MM2S_DMASR);
    dma_reset_named("weight", DMA_WEIGHT_BASE_ADDR, DMA_MM2S_DMACR, DMA_MM2S_DMASR);
    dma_reset_named("ifm", DMA_IFM_BASE_ADDR, DMA_MM2S_DMACR, DMA_MM2S_DMASR);
    dma_reset_named("ofm", DMA_OFM_BASE_ADDR, DMA_S2MM_DMACR, DMA_S2MM_DMASR);
}

static int dma_wait(uint32_t base, uint32_t sr_off, const char *name)
{
    for (uint32_t i = 0U; i < 50000000U; ++i) {
        uint32_t sr = rd32(base, sr_off);
        if ((sr & DMA_DMASR_IOC_IRQ) != 0U) {
            wr32(base, sr_off, DMA_DMASR_IOC_IRQ);
            return 0;
        }
        if ((sr & DMA_DMASR_ERR_MASK) != 0U) {
            xil_printf("%s DMA error dmasr=0x%08lx\r\n", name, (unsigned long)sr);
            return -1;
        }
    }
    xil_printf("%s DMA timeout dmasr=0x%08lx\r\n", name, (unsigned long)rd32(base, sr_off));
    return -1;
}

static void dma_start_mm2s(uint32_t base, const void *buf, uint32_t bytes)
{
    UINTPTR addr = (UINTPTR)buf;
    Xil_DCacheFlushRange(addr, bytes);
    wr32(base, DMA_MM2S_DMACR, DMA_DMACR_RUNSTOP);
    wr32(base, DMA_MM2S_SA, (uint32_t)addr);
    wr32(base, DMA_MM2S_SA_MSB, (uint32_t)(addr >> 32));
    wr32(base, DMA_MM2S_LENGTH, bytes);
}

static void dma_start_s2mm(uint32_t base, void *buf, uint32_t bytes)
{
    UINTPTR addr = (UINTPTR)buf;
    Xil_DCacheFlushRange(addr, bytes);
    wr32(base, DMA_S2MM_DMACR, DMA_DMACR_RUNSTOP);
    wr32(base, DMA_S2MM_DA, (uint32_t)addr);
    wr32(base, DMA_S2MM_DA_MSB, (uint32_t)(addr >> 32));
    wr32(base, DMA_S2MM_LENGTH, bytes);
}

static int status_fill_fy(uint32_t status)
{
    return (int)((status & ST_FILL_FY_MASK) >> ST_FILL_FY_SHIFT);
}

static int wait_gpio_deassert(uint32_t mask)
{
    for (uint32_t i = 0U; i < 10000000U; ++i) {
        if ((rd32(GPIO_BASE_ADDR, GPIO2_DATA) & mask) == 0U) {
            return 0;
        }
    }
    xil_printf("GPIO request did not deassert mask=0x%08lx status=0x%08lx\r\n",
               (unsigned long)mask, (unsigned long)rd32(GPIO_BASE_ADDR, GPIO2_DATA));
    return -1;
}

static int wait_ifm_request_advance(uint32_t serviced_status)
{
    uint32_t serviced_fy = serviced_status & ST_FILL_FY_MASK;
    for (uint32_t i = 0U; i < 10000000U; ++i) {
        uint32_t st = rd32(GPIO_BASE_ADDR, GPIO2_DATA);
        if ((st & ST_IFM_REQ) == 0U) {
            return 0;
        }
        if ((st & ST_FILL_FY_MASK) != serviced_fy) {
            return 0;
        }
    }
    xil_printf("IFM request did not advance fy=%d status=0x%08lx\r\n",
               status_fill_fy(serviced_status), (unsigned long)rd32(GPIO_BASE_ADDR, GPIO2_DATA));
    return -1;
}

static int layer_uses_raw_hwc(const chain_layer_t *layer)
{
    if (!ACCEL_BATCH_STREAM) {
        return 0;
    }
    if (ACCEL_RAW_HWC_IFM && layer->kernel_1x1) {
        return 1;
    }
    return ACCEL_RAW_HWC_3X3 && layer->raw_hwc_mode;
}

static uint32_t expected_ifm_services_for_tile(const chain_layer_t *layer, const chain_tile_t *tile)
{
    if (layer_uses_raw_hwc(layer)) {
        (void)tile;
        return 1U;
    }

    if (layer->kernel_1x1) {
        return layer->k_passes * layer->cout_blocks;
    }

    int first_fy = (int)tile->tile_oy_base - 1;
    int last_fy = (int)tile->tile_oy_base + (int)tile->tile_ofm_h;
    if (first_fy < 0) {
        first_fy = 0;
    }
    if (last_fy >= (int)layer->fm_h) {
        last_fy = (int)layer->fm_h - 1;
    }
    if (last_fy < first_fy) {
        return 0U;
    }
    return (uint32_t)(last_fy - first_fy + 1) * layer->k_passes * layer->cout_blocks;
}

#if ACCEL_BATCH_STREAM
typedef struct {
    uint64_t *words;
    uint32_t bytes;
    uint32_t packets;
} batch_ifm_stream_t;

static int batch_check_layout(void)
{
    if (BATCH_BIAS_ADDR + BATCH_BIAS_CAPACITY != BATCH_WEIGHT_ADDR ||
        BATCH_WEIGHT_ADDR + BATCH_WEIGHT_CAPACITY != BATCH_IFM0_ADDR ||
        BATCH_IFM0_ADDR + BATCH_IFM_CAPACITY != BATCH_IFM1_ADDR ||
        BATCH_IFM1_ADDR + BATCH_IFM_CAPACITY != BATCH_SCRATCH_END) {
        xil_printf("batch scratch layout overlap\r\n");
        return -1;
    }
#if ACCEL_CHAIN_CONV0_CONV9_DDR
    if (IMAGE_PACKAGE_ADDR + IMAGE_PACKAGE_HEADER_BYTES + 416U * 416U * 3U > BATCH_BIAS_ADDR) {
        xil_printf("batch scratch overlaps image package\r\n");
        return -1;
    }
#endif
    return 0;
}

static int pack_batch_bias_stream(const chain_layer_t *layer, uint32_t *bytes_out)
{
    uint64_t *dst = (uint64_t *)(UINTPTR)BATCH_BIAS_ADDR;
    const uint32_t packet_bytes = CHAIN_COUT_TILE * sizeof(int32_t);
    const uint32_t total_bytes = layer->cout_blocks * packet_bytes;
    if (total_bytes > BATCH_BIAS_CAPACITY) {
        xil_printf("%s batch bias overflow bytes=%lu cap=%lu\r\n",
                   layer->name, (unsigned long)total_bytes,
                   (unsigned long)BATCH_BIAS_CAPACITY);
        return -1;
    }
    for (uint32_t cb = 0U; cb < layer->cout_blocks; ++cb) {
        pack_bias_to(layer, cb * CHAIN_COUT_TILE, dst);
        dst += packet_bytes / sizeof(uint64_t);
    }
    *bytes_out = total_bytes;
    return 0;
}

static int prepare_batch_weight_stream(
    const chain_layer_t *layer,
    const void **stream_out,
    uint32_t *bytes_out)
{
    const uint32_t packet_bytes = CHAIN_ROWS * CHAIN_COUT_TILE;
    const uint32_t total_packets = layer->cout_blocks * layer->k_passes;
    const uint32_t total_bytes = total_packets * packet_bytes;
    if (total_bytes > BATCH_WEIGHT_CAPACITY) {
        xil_printf("%s batch weight overflow bytes=%lu cap=%lu\r\n",
                   layer->name, (unsigned long)total_bytes,
                   (unsigned long)BATCH_WEIGHT_CAPACITY);
        return -1;
    }
#if ACCEL_PREPACKED_WEIGHT
    *stream_out = layer->weight_s8;
    *bytes_out = total_bytes;
    return 0;
#else
    uint64_t *dst = (uint64_t *)(UINTPTR)BATCH_WEIGHT_ADDR;
    for (uint32_t cb = 0U; cb < layer->cout_blocks; ++cb) {
        uint32_t cout_base = cb * CHAIN_COUT_TILE;
        for (uint32_t kp = 0U; kp < layer->k_passes; ++kp) {
            pack_weight_to(layer, kp * CHAIN_ROWS, cout_base, dst);
            dst += packet_bytes / sizeof(uint64_t);
        }
    }
    *stream_out = (const void *)(UINTPTR)BATCH_WEIGHT_ADDR;
    *bytes_out = total_bytes;
    return 0;
#endif
}

static int pack_batch_ifm_stream(
    const chain_layer_t *layer,
    const chain_tile_t *tile,
    uint32_t address,
    batch_ifm_stream_t *stream)
{
    uint64_t *stream_base = (uint64_t *)(UINTPTR)address;
    uint64_t *dst = stream_base;
    int first_fy = (int)tile->tile_oy_base - 1;
    int last_fy = (int)tile->tile_oy_base + (int)tile->tile_ofm_h;
    uint32_t packets;
    uint32_t total_bytes;

    if (layer_uses_raw_hwc(layer)) {
        const uint8_t *src;
        uint32_t cache_words_per_pixel =
            layer->kernel_1x1 ?
            ((layer->cin + CHAIN_ROWS - 1U) / CHAIN_ROWS) :
            ((layer->cin + 1U) / 2U);
        uint32_t required_cache_words =
            tile->tile_pixels * cache_words_per_pixel;

        packets = 1U;
        if (required_cache_words > ACCEL_HWC_CACHE_DEPTH) {
            xil_printf(
                "%s raw HWC cache overflow words=%lu cap=%lu\r\n",
                layer->name, (unsigned long)required_cache_words,
                (unsigned long)ACCEL_HWC_CACHE_DEPTH);
            return -1;
        }
        if (layer->kernel_1x1) {
            first_fy = (int)tile->tile_oy_base;
            last_fy = first_fy + (int)tile->tile_ofm_h - 1;
        } else {
            first_fy = (int)tile->tile_oy_base - 1;
            last_fy = (int)tile->tile_oy_base + (int)tile->tile_ofm_h;
            if (first_fy < 0) {
                first_fy = 0;
            }
            if (last_fy >= (int)layer->fm_h) {
                last_fy = (int)layer->fm_h - 1;
            }
        }
        total_bytes =
            (uint32_t)(last_fy - first_fy + 1) * layer->fm_w * layer->cin;
        if (total_bytes > BATCH_IFM_CAPACITY) {
            xil_printf("%s raw HWC IFM overflow bytes=%lu cap=%lu\r\n",
                       layer->name, (unsigned long)total_bytes,
                       (unsigned long)BATCH_IFM_CAPACITY);
            return -1;
        }
        src = layer->ifm_u8 +
              (uint32_t)first_fy * layer->fm_w * layer->cin;
        memcpy((void *)(UINTPTR)address, src, total_bytes);
        stream->words = (uint64_t *)(UINTPTR)address;
        stream->bytes = total_bytes;
        stream->packets = packets;
        return 0;
    }

    if (layer->kernel_1x1) {
        packets = expected_ifm_services_for_tile(layer, tile);
        total_bytes = packets * tile->tile_pixels * 3U * sizeof(uint64_t);
        if (total_bytes > BATCH_IFM_CAPACITY) {
            xil_printf("%s native 1x1 IFM overflow bytes=%lu cap=%lu\r\n",
                       layer->name, (unsigned long)total_bytes,
                       (unsigned long)BATCH_IFM_CAPACITY);
            return -1;
        }

        for (uint32_t kp = 0U; kp < layer->k_passes; ++kp) {
            uint32_t k_base = kp * CHAIN_ROWS;
            for (uint32_t oy = 0U; oy < tile->tile_ofm_h; ++oy) {
                uint32_t y = tile->tile_oy_base + oy;
                for (uint32_t x = 0U; x < layer->fm_w; ++x) {
                    const uint8_t *pixel =
                        layer->ifm_u8 + (y * layer->fm_w + x) * layer->cin;
                    for (uint32_t beat = 0U; beat < 3U; ++beat) {
                        uint64_t word = 0U;
                        for (uint32_t byte = 0U; byte < 8U; ++byte) {
                            uint32_t lane = beat * 8U + byte;
                            uint32_t ch = k_base + lane;
                            uint8_t value =
                                (lane < CHAIN_ROWS && ch < layer->cin) ?
                                pixel[ch] : (uint8_t)layer->input_zero_point;
                            word |= (uint64_t)value << (byte * 8U);
                        }
                        *dst++ = word;
                    }
                }
            }
        }
        uint32_t words_per_cout_block =
            layer->k_passes * tile->tile_pixels * 3U;
        for (uint32_t cb = 1U; cb < layer->cout_blocks; ++cb) {
            copy_u64_words(
                stream_base + cb * words_per_cout_block,
                stream_base,
                words_per_cout_block);
        }
        stream->words = (uint64_t *)(UINTPTR)address;
        stream->bytes = total_bytes;
        stream->packets = packets;
        return 0;
    }

    if (first_fy < 0) {
        first_fy = 0;
    }
    if (last_fy >= (int)layer->fm_h) {
        last_fy = (int)layer->fm_h - 1;
    }
    packets = expected_ifm_services_for_tile(layer, tile);
    total_bytes = packets * layer->fm_w * sizeof(uint64_t);
    if (total_bytes > BATCH_IFM_CAPACITY) {
        xil_printf("%s batch IFM overflow bytes=%lu cap=%lu\r\n",
                   layer->name, (unsigned long)total_bytes,
                   (unsigned long)BATCH_IFM_CAPACITY);
        return -1;
    }

    uint32_t physical_rows = (uint32_t)(last_fy - first_fy + 1);
    for (uint32_t kp = 0U; kp < layer->k_passes; ++kp) {
        uint32_t k_base = kp * CHAIN_ROWS;
        int channel[CHAIN_IFM_BANKS];
        for (uint32_t b = 0U; b < CHAIN_IFM_BANKS; ++b) {
            channel[b] = channel_for_bank(layer, k_base, b);
        }
        for (int fy = first_fy; fy <= last_fy; ++fy) {
            pack_ifm_line_channels_to(layer, fy, channel, dst);
            dst += layer->fm_w;
        }
    }
    uint32_t words_per_cout_block =
        layer->k_passes * physical_rows * layer->fm_w;
    for (uint32_t cb = 1U; cb < layer->cout_blocks; ++cb) {
        copy_u64_words(
            stream_base + cb * words_per_cout_block,
            stream_base,
            words_per_cout_block);
    }
    stream->words = (uint64_t *)(UINTPTR)address;
    stream->bytes = total_bytes;
    stream->packets = packets;
    return 0;
}
#endif

static int service_bias(const chain_layer_t *layer, uint32_t cout_base)
{
    XTime begin;
    XTime end;

    XTime_GetTime(&begin);
    pack_bias(layer, cout_base);
    XTime_GetTime(&end);
    layer_perf.bias_pack += end - begin;

    XTime_GetTime(&begin);
    dma_start_mm2s(DMA_BIAS_BASE_ADDR, bias_buf, sizeof(bias_buf));
    ++layer_perf.dma_bias_starts;
    if (dma_wait(DMA_BIAS_BASE_ADDR, DMA_MM2S_DMASR, "bias MM2S") != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.bias_dma += end - begin;

    XTime_GetTime(&begin);
    if (wait_gpio_deassert(ST_BIAS_REQ) != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.bias_sync += end - begin;
    return 0;
}

static int service_weight(const chain_layer_t *layer, uint32_t *next_k_pass, uint32_t *active_k_base, uint32_t cout_base)
{
    uint32_t k_base = (*next_k_pass) * CHAIN_ROWS;
    XTime begin;
    XTime end;

    *active_k_base = k_base;
    XTime_GetTime(&begin);
    pack_weight(layer, k_base, cout_base);
    XTime_GetTime(&end);
    layer_perf.weight_pack += end - begin;

    XTime_GetTime(&begin);
    dma_start_mm2s(DMA_WEIGHT_BASE_ADDR, weight_buf, sizeof(weight_buf));
    ++layer_perf.dma_weight_starts;
    if (dma_wait(DMA_WEIGHT_BASE_ADDR, DMA_MM2S_DMASR, "weight MM2S") != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.weight_dma += end - begin;

    *next_k_pass = (*next_k_pass + 1U) % layer->k_passes;
    XTime_GetTime(&begin);
    if (wait_gpio_deassert(ST_WEIGHT_REQ) != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.weight_sync += end - begin;
    return 0;
}

static int service_ifm(const chain_layer_t *layer, uint32_t status, uint32_t active_k_base)
{
    int fy = status_fill_fy(status);
    XTime begin;
    XTime end;

    if (fy < 0 || fy >= (int)layer->fm_h) {
        xil_printf("%s bad feeder fy=%d status=0x%08lx\r\n", layer->name, fy, (unsigned long)status);
        return -1;
    }
    XTime_GetTime(&begin);
    pack_ifm_line(layer, fy, active_k_base);
    XTime_GetTime(&end);
    layer_perf.ifm_pack += end - begin;

    XTime_GetTime(&begin);
    dma_start_mm2s(DMA_IFM_BASE_ADDR, ifm_buf, layer->fm_w * sizeof(ifm_buf[0]));
    ++layer_perf.dma_ifm_starts;
    if (dma_wait(DMA_IFM_BASE_ADDR, DMA_MM2S_DMASR, "ifm MM2S") != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.ifm_dma += end - begin;
    return 0;
}

static uint64_t ticks_to_us(XTime ticks)
{
    uint64_t seconds = ticks / COUNTS_PER_SECOND;
    uint64_t remainder = ticks % COUNTS_PER_SECOND;
    return seconds * 1000000ULL + (remainder * 1000000ULL) / COUNTS_PER_SECOND;
}

static void print_layer_perf(const chain_layer_t *layer)
{
    XTime tile_service =
        layer_perf.bias_pack + layer_perf.bias_dma + layer_perf.bias_sync +
        layer_perf.weight_pack + layer_perf.weight_dma + layer_perf.weight_sync +
        layer_perf.ifm_pack + layer_perf.ifm_dma + layer_perf.ifm_sync +
        layer_perf.ofm_dma + layer_perf.ofm_parse;
    XTime tile_control =
        (layer_perf.tile_total > tile_service) ? layer_perf.tile_total - tile_service : 0U;
    XTime measured =
        layer_perf.dma_reset + layer_perf.configure + layer_perf.clear +
        tile_service + tile_control + layer_perf.compare + layer_perf.cache;
    XTime other = (layer_perf.layer_total > measured) ? layer_perf.layer_total - measured : 0U;

    xil_printf(
        "PERF layer=%s total_us=%llu "
        "reset_us=%llu config_us=%llu clear_us=%llu control_us=%llu "
        "bias_pack_us=%llu bias_dma_us=%llu bias_sync_us=%llu "
        "weight_pack_us=%llu weight_dma_us=%llu weight_sync_us=%llu "
        "ifm_pack_us=%llu ifm_dma_us=%llu ifm_sync_us=%llu "
        "ofm_dma_us=%llu ofm_parse_us=%llu compare_us=%llu cache_us=%llu "
        "other_us=%llu\r\n",
        layer->name,
        (unsigned long long)ticks_to_us(layer_perf.layer_total),
        (unsigned long long)ticks_to_us(layer_perf.dma_reset),
        (unsigned long long)ticks_to_us(layer_perf.configure),
        (unsigned long long)ticks_to_us(layer_perf.clear),
        (unsigned long long)ticks_to_us(tile_control),
        (unsigned long long)ticks_to_us(layer_perf.bias_pack),
        (unsigned long long)ticks_to_us(layer_perf.bias_dma),
        (unsigned long long)ticks_to_us(layer_perf.bias_sync),
        (unsigned long long)ticks_to_us(layer_perf.weight_pack),
        (unsigned long long)ticks_to_us(layer_perf.weight_dma),
        (unsigned long long)ticks_to_us(layer_perf.weight_sync),
        (unsigned long long)ticks_to_us(layer_perf.ifm_pack),
        (unsigned long long)ticks_to_us(layer_perf.ifm_dma),
        (unsigned long long)ticks_to_us(layer_perf.ifm_sync),
        (unsigned long long)ticks_to_us(layer_perf.ofm_dma),
        (unsigned long long)ticks_to_us(layer_perf.ofm_parse),
        (unsigned long long)ticks_to_us(layer_perf.compare),
        (unsigned long long)ticks_to_us(layer_perf.cache),
        (unsigned long long)ticks_to_us(other));

    uint64_t nonwait_cycles =
        (layer_perf.hw_busy_cycles > layer_perf.hw_wait_cycles) ?
        layer_perf.hw_busy_cycles - layer_perf.hw_wait_cycles : 0U;
    uint64_t compute_permille =
        (layer_perf.hw_busy_cycles != 0U) ?
        (layer_perf.hw_compute_cycles * 1000U) / layer_perf.hw_busy_cycles : 0U;
    xil_printf(
        "HWPERF layer=%s busy_cycles=%llu wait_cycles=%llu nonwait_cycles=%llu "
        "compute_cycles=%llu "
        "bias_wait_cycles=%llu weight_wait_cycles=%llu ifm_wait_cycles=%llu "
        "ofm_wait_cycles=%llu compute_permille=%llu\r\n",
        layer->name,
        (unsigned long long)layer_perf.hw_busy_cycles,
        (unsigned long long)layer_perf.hw_wait_cycles,
        (unsigned long long)nonwait_cycles,
        (unsigned long long)layer_perf.hw_compute_cycles,
        (unsigned long long)layer_perf.hw_wait_bias_cycles,
        (unsigned long long)layer_perf.hw_wait_weight_cycles,
        (unsigned long long)layer_perf.hw_wait_ifm_cycles,
        (unsigned long long)layer_perf.hw_wait_ofm_cycles,
        (unsigned long long)compute_permille);
    xil_printf(
        "STAGEPERF layer=%s bias_cycles=%llu weight_cycles=%llu "
        "feeder_cycles=%llu compute_stage_cycles=%llu drain_cycles=%llu "
        "ofm_post_cycles=%llu\r\n",
        layer->name,
        (unsigned long long)layer_perf.hw_stage_bias_cycles,
        (unsigned long long)layer_perf.hw_stage_weight_cycles,
        (unsigned long long)layer_perf.hw_stage_feeder_cycles,
        (unsigned long long)layer_perf.hw_stage_compute_cycles,
        (unsigned long long)layer_perf.hw_stage_drain_cycles,
        (unsigned long long)layer_perf.hw_stage_ofm_post_cycles);
    xil_printf(
        "SUBPERF layer=%s feed_fill=%llu feed_push=%llu feed_fifo_stall=%llu "
        "feed_win_not_ready=%llu comp_wload=%llu comp_active=%llu "
        "comp_fire=%llu comp_ifm_stall=%llu comp_tail=%llu version=%llu\r\n",
        layer->name,
        (unsigned long long)layer_perf.hw_feed_fill_wait_cycles,
        (unsigned long long)layer_perf.hw_feed_push_cycles,
        (unsigned long long)layer_perf.hw_feed_fifo_stall_cycles,
        (unsigned long long)layer_perf.hw_feed_win_not_ready_cycles,
        (unsigned long long)layer_perf.hw_comp_wload_cycles,
        (unsigned long long)layer_perf.hw_comp_active_cycles,
        (unsigned long long)layer_perf.hw_comp_fire_cycles,
        (unsigned long long)layer_perf.hw_comp_ifm_stall_cycles,
        (unsigned long long)layer_perf.hw_comp_tail_cycles,
        (unsigned long long)layer_perf.hw_subperf_version);
    xil_printf(
        "TAILSTAT layer=%s tail_config=%llu raw_start_level=%llu "
        "tail_elapsed=%llu drain_empty_wait=%llu drain_empty_sticky=%llu\r\n",
        layer->name,
        (unsigned long long)layer_perf.hw_tail_config_cycles,
        (unsigned long long)layer_perf.hw_raw_compute_start_level,
        (unsigned long long)layer_perf.hw_tail_elapsed_cycles,
        (unsigned long long)layer_perf.hw_drain_empty_wait_cycles,
        (unsigned long long)layer_perf.hw_drain_empty_sticky);
    xil_printf(
        "DRAINPERF layer=%s read_fire=%llu packet_fire=%llu "
        "ready_stall=%llu internal_full=%llu empty_wait=%llu version=%llu\r\n",
        layer->name,
        (unsigned long long)layer_perf.hw_drain_read_fire_cycles,
        (unsigned long long)layer_perf.hw_drain_packet_fire_cycles,
        (unsigned long long)layer_perf.hw_drain_ready_stall_cycles,
        (unsigned long long)layer_perf.hw_drain_internal_full_cycles,
        (unsigned long long)layer_perf.hw_drain_empty_wait_cycles,
        (unsigned long long)layer_perf.hw_drainperf_version);
    xil_printf(
        "PREFETCHPERF layer=%s start=%llu weight_done=%llu feed_done=%llu "
        "hit=%llu miss=%llu stall=%llu version=%llu\r\n",
        layer->name,
        (unsigned long long)layer_perf.hw_prefetch_start_cycles,
        (unsigned long long)layer_perf.hw_prefetch_weight_done_cycles,
        (unsigned long long)layer_perf.hw_prefetch_feed_done_cycles,
        (unsigned long long)layer_perf.hw_prefetch_hit_cycles,
        (unsigned long long)layer_perf.hw_prefetch_miss_cycles,
        (unsigned long long)layer_perf.hw_prefetch_stall_cycles,
        (unsigned long long)layer_perf.hw_prefetchperf_version);
    xil_printf(
        "PSUMOVLPERF layer=%s start=%llu hit=%llu wait_psum=%llu "
        "underflow=%llu version=%llu\r\n",
        layer->name,
        (unsigned long long)layer_perf.hw_psumovl_start_cycles,
        (unsigned long long)layer_perf.hw_psumovl_hit_cycles,
        (unsigned long long)layer_perf.hw_psumovl_wait_psum_cycles,
        (unsigned long long)layer_perf.hw_psumovl_underflow_cycles,
        (unsigned long long)layer_perf.hw_psumovlperf_version);
    xil_printf(
        "COLLECTPERF layer=%s packet_fire=%llu partial_write=%llu "
        "final_write=%llu context_push=%llu context_pop=%llu "
        "context_full_stall=%llu column_empty_wait=%llu version=%llu\r\n",
        layer->name,
        (unsigned long long)layer_perf.hw_collect_packet_fire_cycles,
        (unsigned long long)layer_perf.hw_collect_partial_write_cycles,
        (unsigned long long)layer_perf.hw_collect_final_write_cycles,
        (unsigned long long)layer_perf.hw_collect_context_push_cycles,
        (unsigned long long)layer_perf.hw_collect_context_pop_cycles,
        (unsigned long long)layer_perf.hw_collect_context_full_stall_cycles,
        (unsigned long long)layer_perf.hw_collect_column_empty_wait_cycles,
        (unsigned long long)layer_perf.hw_collectperf_version);
    xil_printf(
        "PASSPERF layer=%s pass_count=%llu start_to_first=%llu "
        "fire_span=%llu tail=%llu collect_wait=%llu collect_empty=%llu "
        "replay_during_compute=%llu compute_idle=%llu version=%llu\r\n",
        layer->name,
        (unsigned long long)layer_perf.hw_pass_count,
        (unsigned long long)layer_perf.hw_pass_start_to_first_fire_cycles,
        (unsigned long long)layer_perf.hw_pass_first_to_last_fire_cycles,
        (unsigned long long)layer_perf.hw_pass_last_fire_to_done_cycles,
        (unsigned long long)layer_perf.hw_pass_collect_first_wait_cycles,
        (unsigned long long)layer_perf.hw_pass_collect_column_empty_cycles,
        (unsigned long long)layer_perf.hw_pass_replay_during_compute_cycles,
        (unsigned long long)layer_perf.hw_pass_compute_idle_stage_cycles,
        (unsigned long long)layer_perf.hw_passperf_version);
    xil_printf(
        "DMASTAT layer=%s bias_starts=%lu weight_starts=%lu ifm_starts=%lu ofm_starts=%lu\r\n",
        layer->name,
        (unsigned long)layer_perf.dma_bias_starts,
        (unsigned long)layer_perf.dma_weight_starts,
        (unsigned long)layer_perf.dma_ifm_starts,
        (unsigned long)layer_perf.dma_ofm_starts);
    xil_printf(
        "VECTORSTAT layer=%s packets=%llu pixels=%llu beats=%llu fifo_stall_cycles=%llu\r\n",
        layer->name,
        (unsigned long long)layer_perf.vector_packets,
        (unsigned long long)layer_perf.vector_pixels,
        (unsigned long long)layer_perf.vector_beats,
        (unsigned long long)layer_perf.vector_fifo_stall_cycles);
    xil_printf(
        "RAWSTAT layer=%s load_active=%llu load_unpack=%llu "
        "replay_active=%llu replay_wait_ready=%llu compute_wait_ifm=%llu\r\n",
        layer->name,
        (unsigned long long)layer_perf.raw_load_active_cycles,
        (unsigned long long)layer_perf.raw_load_unpack_cycles,
        (unsigned long long)layer_perf.raw_replay_active_cycles,
        (unsigned long long)layer_perf.raw_replay_wait_ready_cycles,
        (unsigned long long)layer_perf.hw_comp_ifm_stall_cycles);
}

static void print_coltrace(
    const chain_layer_t *layer,
    uint32_t tile_index)
{
#if ACCEL_TILE_PERF_TRACE && ACCEL_PASS_TRACE_ENABLE
    for (uint32_t col = 0U; col < COLS; ++col) {
        wr32(ACCEL_BASE_ADDR, ACCEL_COLTRACE_CTRL, col);
        uint32_t ctrl = rd32(ACCEL_BASE_ADDR, ACCEL_COLTRACE_CTRL);
        if ((ctrl >> 31) == 0U) {
            return;
        }
        xil_printf(
            "COLTRACE layer=%s tile=%lu cout_block=%lu k_pass=%lu col=%lu "
            "first_wr=%lu last_wr=%lu wr_count=%lu empty_wait=%lu "
            "missing_or=%lu missing_first=%lu missing_last=%lu "
            "version=%lu valid=1\r\n",
            layer->name,
            (unsigned long)tile_index,
            (unsigned long)ACCEL_PASS_TRACE_COUT_BLOCK,
            (unsigned long)ACCEL_PASS_TRACE_K_PASS,
            (unsigned long)col,
            (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_COLTRACE_FIRST_WR),
            (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_COLTRACE_LAST_WR),
            (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_COLTRACE_WR_COUNT),
            (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_COLTRACE_EMPTY_WAIT),
            (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_COLTRACE_MISSING_OR),
            (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_COLTRACE_MISSING_FIRST),
            (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_COLTRACE_MISSING_LAST),
            (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_COLTRACE_VERSION));
    }
#else
    (void)layer;
    (void)tile_index;
#endif
}

static void clear_ofm(uint8_t *ofm, uint32_t bytes)
{
    for (uint32_t i = 0U; i < bytes; ++i) {
        ofm[i] = 0xeeU;
    }
}

static int parse_ofm_tile(const chain_layer_t *layer, const chain_tile_t *tile)
{
    Xil_DCacheInvalidateRange((UINTPTR)ofm_axis_buf, tile->expected_ofm_bytes * OFM_AXIS_BEAT_BYTES);
#if !ACCEL_PERF_ONLY
    for (uint32_t i = 0U; i < 4U && i < tile->expected_ofm_bytes; ++i) {
        uint32_t raw = (uint32_t)(ofm_axis_buf[i] & 0xffffffffULL);
        trace_printf("%s raw[%lu] addr=%lu data=%u\r\n",
                     tile->name, (unsigned long)i,
                     (unsigned long)(raw & 0x00ffffffU),
                     (unsigned)((raw >> 24) & 0xffU));
    }
#endif
    for (uint32_t i = 0U; i < tile->expected_ofm_bytes; ++i) {
        uint32_t raw = (uint32_t)(ofm_axis_buf[i] & 0xffffffffULL);
        uint32_t addr = raw & 0x00ffffffU;
        uint8_t data = (uint8_t)((raw >> 24) & 0xffU);
        if (addr >= layer->total_expected_ofm_bytes) {
            xil_printf("%s bad OFM packet index=%lu addr=%lu data=%u\r\n",
                       tile->name, (unsigned long)i, (unsigned long)addr, data);
            return -1;
        }
        layer->ofm_u8[addr] = data;
    }
    trace_printf("%s ofm parsed=%lu expected=%lu\r\n",
                 tile->name, (unsigned long)tile->expected_ofm_bytes,
                 (unsigned long)tile->expected_ofm_bytes);
    return 0;
}

static int compare_layer_ofm(const chain_layer_t *layer)
{
#if ACCEL_CHAIN_CONV0_CONV9_DDR
    trace_printf("%s generated=%lu bytes (dynamic input, fixed golden compare skipped)\r\n",
                 layer->name, (unsigned long)layer->total_expected_ofm_bytes);
    return 0;
#else
    uint32_t mismatch_count = 0U;
    uint32_t max_abs_diff = 0U;
    uint32_t final_w = layer->pool_enable ? (layer->ofm_w / layer->pool_stride) : layer->ofm_w;
    for (uint32_t i = 0U; i < layer->total_expected_ofm_bytes; ++i) {
        if (layer->ofm_u8[i] != layer->golden_ofm_u8[i]) {
            int diff = (int)layer->ofm_u8[i] - (int)layer->golden_ofm_u8[i];
            uint32_t abs_diff = (diff < 0) ? (uint32_t)(-diff) : (uint32_t)diff;
            uint32_t pixel = i / layer->cout_total;
            uint32_t oc = i % layer->cout_total;
            uint32_t oy = (final_w == 0U) ? 0U : (pixel / final_w);
            uint32_t ox = (final_w == 0U) ? 0U : (pixel % final_w);
            if (abs_diff > max_abs_diff) {
                max_abs_diff = abs_diff;
            }
            if (mismatch_count < 8U) {
                xil_printf("%s mismatch[%lu] byte=%lu pixel=%lu oy=%lu ox=%lu oc=%lu got=%u exp=%u diff=%d\r\n",
                           layer->name, (unsigned long)mismatch_count, (unsigned long)i,
                           (unsigned long)pixel, (unsigned long)oy, (unsigned long)ox,
                           (unsigned long)oc, (unsigned)layer->ofm_u8[i],
                           (unsigned)layer->golden_ofm_u8[i], diff);
            }
            ++mismatch_count;
        }
    }
    if (mismatch_count != 0U) {
        xil_printf("%s mismatch_count=%lu max_abs_diff=%lu total=%lu\r\n",
                   layer->name, (unsigned long)mismatch_count,
                   (unsigned long)max_abs_diff,
                   (unsigned long)layer->total_expected_ofm_bytes);
        return -1;
    }
    xil_printf("%s full compare=%lu bytes\r\n",
               layer->name, (unsigned long)layer->total_expected_ofm_bytes);
    return 0;
#endif
}

static int run_one_tile(const chain_layer_t *layer, const chain_tile_t *tile, uint32_t tile_index,
                        uint32_t *total_bias, uint32_t *total_weight, uint32_t *total_ifm)
{
    uint32_t k_pass = 0U;
    uint32_t active_k_base = 0U;
    uint32_t bias_services = 0U;
    uint32_t weight_services = 0U;
    uint32_t ifm_services = 0U;
    uint32_t dbg_core_base;
    uint32_t dbg_axis_base;
    uint32_t dbg_tlast_base;
    uint32_t dbg_last_base;
    XTime begin;
    XTime end;
    XTime tile_begin;
    XTime tile_end;

    trace_printf("%s tile[%lu] oy=%lu h=%lu pixel_base=%lu expected=%lu\r\n",
                 layer->name, (unsigned long)tile_index,
                 (unsigned long)tile->tile_oy_base, (unsigned long)tile->tile_ofm_h,
                 (unsigned long)tile->tile_pixel_base, (unsigned long)tile->expected_ofm_bytes);
    XTime_GetTime(&tile_begin);

    wr32(ACCEL_BASE_ADDR, ACCEL_NUM_PIXELS, tile->tile_pixels);
    wr32(ACCEL_BASE_ADDR, ACCEL_TILE_ROWS, (tile->tile_ofm_h << 16) | tile->tile_oy_base);
    wr32(ACCEL_BASE_ADDR, ACCEL_PIXEL_BASE, tile->tile_pixel_base);
    wr32(ACCEL_BASE_ADDR, ACCEL_EXPECTED_BYTES, tile->expected_ofm_bytes);

    dbg_core_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_CORE_WR);
    dbg_axis_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_AXIS_WR);
    dbg_tlast_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_TLASTS);
    dbg_last_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_LAST_END);

    XTime_GetTime(&begin);
    dma_start_s2mm(DMA_OFM_BASE_ADDR, ofm_axis_buf, tile->expected_ofm_bytes * OFM_AXIS_BEAT_BYTES);
    ++layer_perf.dma_ofm_starts;
    XTime_GetTime(&end);
    layer_perf.ofm_dma += end - begin;
    wr32(ACCEL_BASE_ADDR, ACCEL_CTRL, 1U);

    int done_seen = 0;
    for (uint32_t loops = 0U; loops < 80000000U; ++loops) {
        uint32_t ctrl = rd32(ACCEL_BASE_ADDR, ACCEL_CTRL);
        uint32_t st = rd32(GPIO_BASE_ADDR, GPIO2_DATA);
        debug_value = st;

        if ((st & ST_ERROR_MASK) != 0U) {
            xil_printf("%s AXIS protocol error gpio2=0x%08lx\r\n", layer->name, (unsigned long)st);
            return -1;
        }
        if ((st & ST_BIAS_REQ) != 0U) {
            uint32_t cout_base = (bias_services % layer->cout_blocks) * CHAIN_COUT_TILE;
            if (service_bias(layer, cout_base) != 0) {
                return -1;
            }
            ++bias_services;
            continue;
        }
        if ((st & ST_WEIGHT_REQ) != 0U) {
            uint32_t cout_base = ((weight_services / layer->k_passes) % layer->cout_blocks) * CHAIN_COUT_TILE;
            if ((weight_services % layer->k_passes) == 0U) {
                trace_printf("%s tile[%lu] weight block=%lu cout_base=%lu\r\n",
                             layer->name, (unsigned long)tile_index,
                             (unsigned long)(weight_services / layer->k_passes),
                             (unsigned long)cout_base);
            }
            if (service_weight(layer, &k_pass, &active_k_base, cout_base) != 0) {
                return -1;
            }
            ++weight_services;
            continue;
        }
        if ((st & ST_IFM_REQ) != 0U) {
            if ((ifm_services % (layer->k_passes * 5U)) == 0U) {
                trace_printf("%s tile[%lu] ifm progress=%lu fy=%d k_base=%lu\r\n",
                             layer->name, (unsigned long)tile_index,
                             (unsigned long)ifm_services, status_fill_fy(st),
                             (unsigned long)active_k_base);
            }
            if (service_ifm(layer, st, active_k_base) != 0) {
                return -1;
            }
            XTime_GetTime(&begin);
            if (wait_ifm_request_advance(st) != 0) {
                return -1;
            }
            XTime_GetTime(&end);
            layer_perf.ifm_sync += end - begin;
            ++ifm_services;
            continue;
        }
        if (((ctrl & 0x2U) != 0U) && ((ctrl & 0x1U) == 0U)) {
            done_seen = 1;
            break;
        }
    }
    if (!done_seen) {
        xil_printf("%s accelerator timeout tile=%lu ctrl=0x%08lx gpio2=0x%08lx\r\n",
                   layer->name, (unsigned long)tile_index,
                   (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_CTRL),
                   (unsigned long)rd32(GPIO_BASE_ADDR, GPIO2_DATA));
        return -1;
    }
    XTime_GetTime(&begin);
    if (dma_wait(DMA_OFM_BASE_ADDR, DMA_S2MM_DMASR, "ofm S2MM") != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.ofm_dma += end - begin;

    uint32_t dbg_core_delta = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_CORE_WR) - dbg_core_base;
    uint32_t dbg_axis_delta = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_AXIS_WR) - dbg_axis_base;
    uint32_t dbg_tlast_delta = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_TLASTS) - dbg_tlast_base;
    uint32_t dbg_last_delta = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_LAST_END) - dbg_last_base;
    trace_printf("%s tile[%lu] debug delta core=%lu axis=%lu tlast=%lu last=%lu\r\n",
                 layer->name, (unsigned long)tile_index,
                 (unsigned long)dbg_core_delta, (unsigned long)dbg_axis_delta,
                 (unsigned long)dbg_tlast_delta, (unsigned long)dbg_last_delta);
    if (dbg_core_delta != tile->expected_ofm_bytes ||
        dbg_axis_delta != tile->expected_ofm_bytes ||
        dbg_tlast_delta != 1U ||
        dbg_last_delta != tile->expected_ofm_bytes) {
        xil_printf("%s unexpected OFM debug delta\r\n", layer->name);
        return -1;
    }

    uint32_t tile_busy = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_BUSY);
    uint32_t tile_wait = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_WAIT_ANY);
    uint32_t tile_wait_bias = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_WAIT_BIAS);
    uint32_t tile_wait_weight = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_WAIT_WEIGHT);
    uint32_t tile_wait_ifm = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_WAIT_IFM);
    uint32_t tile_wait_ofm = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_WAIT_OFM);
    uint32_t tile_compute = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_COMPUTE);
    uint32_t tile_stage_bias = rd32(ACCEL_BASE_ADDR, ACCEL_STAGE_BIAS);
    uint32_t tile_stage_weight = rd32(ACCEL_BASE_ADDR, ACCEL_STAGE_WEIGHT);
    uint32_t tile_stage_feeder = rd32(ACCEL_BASE_ADDR, ACCEL_STAGE_FEEDER);
    uint32_t tile_stage_compute = rd32(ACCEL_BASE_ADDR, ACCEL_STAGE_COMPUTE);
    uint32_t tile_stage_drain = rd32(ACCEL_BASE_ADDR, ACCEL_STAGE_DRAIN);
    uint32_t tile_stage_ofm_post = rd32(ACCEL_BASE_ADDR, ACCEL_STAGE_OFM_POST);
    uint32_t tile_feed_fill = rd32(ACCEL_BASE_ADDR, ACCEL_FEED_FILL_WAIT);
    uint32_t tile_feed_push = rd32(ACCEL_BASE_ADDR, ACCEL_FEED_PUSH);
    uint32_t tile_feed_fifo_stall = rd32(ACCEL_BASE_ADDR, ACCEL_FEED_FIFO_STALL);
    uint32_t tile_feed_win_not_ready = rd32(ACCEL_BASE_ADDR, ACCEL_FEED_WIN_NOT_READY);
    uint32_t tile_comp_wload = rd32(ACCEL_BASE_ADDR, ACCEL_COMP_WLOAD);
    uint32_t tile_comp_active = rd32(ACCEL_BASE_ADDR, ACCEL_COMP_ACTIVE);
    uint32_t tile_comp_fire = rd32(ACCEL_BASE_ADDR, ACCEL_COMP_FIRE);
    uint32_t tile_comp_ifm_stall = rd32(ACCEL_BASE_ADDR, ACCEL_COMP_IFM_STALL);
    uint32_t tile_comp_tail = rd32(ACCEL_BASE_ADDR, ACCEL_COMP_TAIL);
    uint32_t tile_subperf_version = rd32(ACCEL_BASE_ADDR, ACCEL_SUBPERF_VERSION);
    uint32_t tile_tail_config = rd32(ACCEL_BASE_ADDR, ACCEL_TAIL_CONFIG);
    uint32_t tile_raw_start_level = (tile_tail_config >> 16) & 0xffffU;
    tile_tail_config &= 0xffffU;
    uint32_t tile_tail_elapsed = rd32(ACCEL_BASE_ADDR, ACCEL_TAIL_ELAPSED);
    uint32_t tile_drain_empty_wait = rd32(ACCEL_BASE_ADDR, ACCEL_DRAIN_EMPTY_WAIT);
    uint32_t tile_drain_empty_sticky = rd32(ACCEL_BASE_ADDR, ACCEL_DRAIN_EMPTY_STICKY);
    uint32_t tile_drain_read_fire = rd32(ACCEL_BASE_ADDR, ACCEL_DRAIN_READ_FIRE);
    uint32_t tile_drain_packet_fire = rd32(ACCEL_BASE_ADDR, ACCEL_DRAIN_PACKET_FIRE);
    uint32_t tile_drain_ready_stall = rd32(ACCEL_BASE_ADDR, ACCEL_DRAIN_READY_STALL);
    uint32_t tile_drain_internal_full = rd32(ACCEL_BASE_ADDR, ACCEL_DRAIN_INTERNAL_FULL);
    uint32_t tile_drainperf_version = rd32(ACCEL_BASE_ADDR, ACCEL_DRAINPERF_VERSION);
    uint32_t tile_prefetch_start = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCH_START);
    uint32_t tile_prefetch_weight_done = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCH_WEIGHT_DONE);
    uint32_t tile_prefetch_feed_done = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCH_FEED_DONE);
    uint32_t tile_prefetch_hit = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCH_HIT);
    uint32_t tile_prefetch_miss = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCH_MISS);
    uint32_t tile_prefetch_stall = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCH_STALL);
    uint32_t tile_prefetchperf_version = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCHPERF_VERSION);
    uint32_t tile_psumovl_start = rd32(ACCEL_BASE_ADDR, ACCEL_PSUMOVL_START);
    uint32_t tile_psumovl_hit = rd32(ACCEL_BASE_ADDR, ACCEL_PSUMOVL_HIT);
    uint32_t tile_psumovl_wait_psum = rd32(ACCEL_BASE_ADDR, ACCEL_PSUMOVL_WAIT_PSUM);
    uint32_t tile_psumovl_underflow = rd32(ACCEL_BASE_ADDR, ACCEL_PSUMOVL_UNDERFLOW);
    uint32_t tile_psumovlperf_version = rd32(ACCEL_BASE_ADDR, ACCEL_PSUMOVLPERF_VERSION);
    uint32_t tile_collect_packet_fire = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_PACKET_FIRE);
    uint32_t tile_collect_partial_write = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_PARTIAL_WRITE);
    uint32_t tile_collect_final_write = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_FINAL_WRITE);
    uint32_t tile_collect_context_push = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_CONTEXT_PUSH);
    uint32_t tile_collect_context_pop = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_CONTEXT_POP);
    uint32_t tile_collect_context_full_stall = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_CONTEXT_FULL_STALL);
    uint32_t tile_collect_column_empty_wait = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_COLUMN_EMPTY_WAIT);
    uint32_t tile_collectperf_version = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECTPERF_VERSION);
    uint32_t tile_pass_count = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_COUNT);
    uint32_t tile_pass_start_to_first = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_START_TO_FIRST_FIRE);
    uint32_t tile_pass_first_to_last = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_FIRST_TO_LAST_FIRE);
    uint32_t tile_pass_last_to_done = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_LAST_FIRE_TO_DONE);
    uint32_t tile_pass_collect_first_wait = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_COLLECT_FIRST_WAIT);
    uint32_t tile_pass_collect_column_empty = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_COLLECT_COLUMN_EMPTY);
    uint32_t tile_pass_replay_during_compute = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_REPLAY_DURING_COMPUTE);
    uint32_t tile_pass_compute_idle = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_COMPUTE_IDLE_STAGE);
    uint32_t tile_trace_weight_done = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_WEIGHT_DONE);
    uint32_t tile_trace_feed_start = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_FEED_START);
    uint32_t tile_trace_feed_ready = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_FEED_READY);
    uint32_t tile_trace_feed_done = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_FEED_DONE);
    uint32_t tile_trace_compute_start = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_COMPUTE_START);
    uint32_t tile_trace_first_fire = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_FIRST_FIRE);
    uint32_t tile_trace_last_fire = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_LAST_FIRE);
    uint32_t tile_trace_compute_done = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_COMPUTE_DONE);
    uint32_t tile_trace_collect_first = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_COLLECT_FIRST);
    uint32_t tile_trace_collect_last = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_COLLECT_LAST);
    uint32_t tile_trace_pass_done = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_PASS_DONE);
    uint32_t tile_passperf_version_raw = rd32(ACCEL_BASE_ADDR, ACCEL_PASSPERF_VERSION);
    uint32_t tile_pass_trace_valid = tile_passperf_version_raw >> 31;
    uint32_t tile_passperf_version = tile_passperf_version_raw & 0x7fffffffU;
    uint32_t tile_vector_packets = rd32(ACCEL_BASE_ADDR, ACCEL_VECTOR_PACKETS);
    uint32_t tile_vector_pixels = rd32(ACCEL_BASE_ADDR, ACCEL_VECTOR_PIXELS);
    uint32_t tile_vector_beats = rd32(ACCEL_BASE_ADDR, ACCEL_VECTOR_BEATS);
    uint32_t tile_vector_stalls = rd32(ACCEL_BASE_ADDR, ACCEL_VECTOR_STALLS);
    uint32_t tile_raw_load_active = rd32(ACCEL_BASE_ADDR, ACCEL_RAW_LOAD_ACTIVE);
    uint32_t tile_raw_load_unpack = rd32(ACCEL_BASE_ADDR, ACCEL_RAW_LOAD_UNPACK);
    uint32_t tile_raw_replay_active = rd32(ACCEL_BASE_ADDR, ACCEL_RAW_REPLAY_ACTIVE);
    uint32_t tile_raw_replay_wait_ready = rd32(ACCEL_BASE_ADDR, ACCEL_RAW_REPLAY_WAIT_READY);

#if ACCEL_TILE_PERF_TRACE
    xil_printf(
        "TILEPERF layer=%s tile=%lu oy=%lu h=%lu pixels=%lu "
        "packets_b=%lu packets_w=%lu packets_i=%lu busy=%lu wait=%lu "
        "wait_b=%lu wait_w=%lu wait_i=%lu wait_o=%lu compute=%lu "
        "stage_b=%lu stage_w=%lu stage_f=%lu stage_c=%lu stage_d=%lu stage_o=%lu "
        "feed_fill=%lu feed_push=%lu feed_fifo_stall=%lu feed_win_not_ready=%lu "
        "comp_wload=%lu comp_active=%lu comp_fire=%lu comp_ifm_stall=%lu comp_tail=%lu "
        "tail_cfg=%lu raw_start_level=%lu tail_elapsed=%lu "
        "drain_empty_wait=%lu drain_empty_sticky=%lu "
        "drain_read_fire=%lu drain_packet_fire=%lu drain_ready_stall=%lu "
        "drain_internal_full=%lu drainperf_version=%lu "
        "vector_packets=%lu vector_pixels=%lu vector_beats=%lu vector_stalls=%lu "
        "raw_load_active=%lu raw_load_unpack=%lu raw_replay_active=%lu "
        "raw_replay_wait_ready=%lu "
        "pass_count=%lu pass_start_to_first=%lu pass_fire_span=%lu "
        "pass_tail=%lu pass_collect_wait=%lu pass_collect_empty=%lu "
        "pass_replay_compute=%lu pass_compute_idle=%lu passperf_version=%lu "
        "subperf_version=%lu\r\n",
        layer->name,
        (unsigned long)tile_index,
        (unsigned long)tile->tile_oy_base,
        (unsigned long)tile->tile_ofm_h,
        (unsigned long)tile->tile_pixels,
        1UL,
        1UL,
        1UL,
        (unsigned long)tile_busy,
        (unsigned long)tile_wait,
        (unsigned long)tile_wait_bias,
        (unsigned long)tile_wait_weight,
        (unsigned long)tile_wait_ifm,
        (unsigned long)tile_wait_ofm,
        (unsigned long)tile_compute,
        (unsigned long)tile_stage_bias,
        (unsigned long)tile_stage_weight,
        (unsigned long)tile_stage_feeder,
        (unsigned long)tile_stage_compute,
        (unsigned long)tile_stage_drain,
        (unsigned long)tile_stage_ofm_post,
        (unsigned long)tile_feed_fill,
        (unsigned long)tile_feed_push,
        (unsigned long)tile_feed_fifo_stall,
        (unsigned long)tile_feed_win_not_ready,
        (unsigned long)tile_comp_wload,
        (unsigned long)tile_comp_active,
        (unsigned long)tile_comp_fire,
        (unsigned long)tile_comp_ifm_stall,
        (unsigned long)tile_comp_tail,
        (unsigned long)tile_tail_config,
        (unsigned long)tile_raw_start_level,
        (unsigned long)tile_tail_elapsed,
        (unsigned long)tile_drain_empty_wait,
        (unsigned long)tile_drain_empty_sticky,
        (unsigned long)tile_drain_read_fire,
        (unsigned long)tile_drain_packet_fire,
        (unsigned long)tile_drain_ready_stall,
        (unsigned long)tile_drain_internal_full,
        (unsigned long)tile_drainperf_version,
        (unsigned long)tile_vector_packets,
        (unsigned long)tile_vector_pixels,
        (unsigned long)tile_vector_beats,
        (unsigned long)tile_vector_stalls,
        (unsigned long)tile_raw_load_active,
        (unsigned long)tile_raw_load_unpack,
        (unsigned long)tile_raw_replay_active,
        (unsigned long)tile_raw_replay_wait_ready,
        (unsigned long)tile_pass_count,
        (unsigned long)tile_pass_start_to_first,
        (unsigned long)tile_pass_first_to_last,
        (unsigned long)tile_pass_last_to_done,
        (unsigned long)tile_pass_collect_first_wait,
        (unsigned long)tile_pass_collect_column_empty,
        (unsigned long)tile_pass_replay_during_compute,
        (unsigned long)tile_pass_compute_idle,
        (unsigned long)tile_passperf_version,
        (unsigned long)tile_subperf_version);
    if ((tile_pass_trace_valid != 0U) &&
        layer_uses_raw_hwc(layer) &&
        (tile_index == 0U)) {
        xil_printf(
            "PASSTRACE layer=%s tile=%lu cout_block=%lu k_pass=%lu "
            "weight_done=%lu feed_start=%lu feed_ready=%lu feed_done=%lu "
            "compute_start=%lu first_fire=%lu last_fire=%lu compute_done=%lu "
            "collect_first=%lu collect_last=%lu pass_done=%lu version=%lu\r\n",
            layer->name,
            (unsigned long)tile_index,
            (unsigned long)ACCEL_PASS_TRACE_COUT_BLOCK,
            (unsigned long)ACCEL_PASS_TRACE_K_PASS,
            (unsigned long)tile_trace_weight_done,
            (unsigned long)tile_trace_feed_start,
            (unsigned long)tile_trace_feed_ready,
            (unsigned long)tile_trace_feed_done,
            (unsigned long)tile_trace_compute_start,
            (unsigned long)tile_trace_first_fire,
            (unsigned long)tile_trace_last_fire,
            (unsigned long)tile_trace_compute_done,
            (unsigned long)tile_trace_collect_first,
            (unsigned long)tile_trace_collect_last,
            (unsigned long)tile_trace_pass_done,
            (unsigned long)tile_passperf_version);
        print_coltrace(layer, tile_index);
    }
#endif

    layer_perf.hw_busy_cycles += tile_busy;
    layer_perf.hw_wait_cycles += tile_wait;
    layer_perf.hw_wait_bias_cycles += tile_wait_bias;
    layer_perf.hw_wait_weight_cycles += tile_wait_weight;
    layer_perf.hw_wait_ifm_cycles += tile_wait_ifm;
    layer_perf.hw_wait_ofm_cycles += tile_wait_ofm;
    layer_perf.hw_compute_cycles += tile_compute;
    layer_perf.hw_stage_bias_cycles += tile_stage_bias;
    layer_perf.hw_stage_weight_cycles += tile_stage_weight;
    layer_perf.hw_stage_feeder_cycles += tile_stage_feeder;
    layer_perf.hw_stage_compute_cycles += tile_stage_compute;
    layer_perf.hw_stage_drain_cycles += tile_stage_drain;
    layer_perf.hw_stage_ofm_post_cycles += tile_stage_ofm_post;
    layer_perf.hw_feed_fill_wait_cycles += tile_feed_fill;
    layer_perf.hw_feed_push_cycles += tile_feed_push;
    layer_perf.hw_feed_fifo_stall_cycles += tile_feed_fifo_stall;
    layer_perf.hw_feed_win_not_ready_cycles += tile_feed_win_not_ready;
    layer_perf.hw_comp_wload_cycles += tile_comp_wload;
    layer_perf.hw_comp_active_cycles += tile_comp_active;
    layer_perf.hw_comp_fire_cycles += tile_comp_fire;
    layer_perf.hw_comp_ifm_stall_cycles += tile_comp_ifm_stall;
    layer_perf.hw_comp_tail_cycles += tile_comp_tail;
    layer_perf.hw_subperf_version = tile_subperf_version;
    layer_perf.hw_tail_config_cycles = tile_tail_config;
    layer_perf.hw_raw_compute_start_level = tile_raw_start_level;
    layer_perf.hw_tail_elapsed_cycles += tile_tail_elapsed;
    layer_perf.hw_drain_empty_wait_cycles += tile_drain_empty_wait;
    layer_perf.hw_drain_empty_sticky |= tile_drain_empty_sticky;
    layer_perf.hw_drain_read_fire_cycles += tile_drain_read_fire;
    layer_perf.hw_drain_packet_fire_cycles += tile_drain_packet_fire;
    layer_perf.hw_drain_ready_stall_cycles += tile_drain_ready_stall;
    layer_perf.hw_drain_internal_full_cycles += tile_drain_internal_full;
    layer_perf.hw_drainperf_version = tile_drainperf_version;
    layer_perf.hw_prefetch_start_cycles += tile_prefetch_start;
    layer_perf.hw_prefetch_weight_done_cycles += tile_prefetch_weight_done;
    layer_perf.hw_prefetch_feed_done_cycles += tile_prefetch_feed_done;
    layer_perf.hw_prefetch_hit_cycles += tile_prefetch_hit;
    layer_perf.hw_prefetch_miss_cycles += tile_prefetch_miss;
    layer_perf.hw_prefetch_stall_cycles += tile_prefetch_stall;
    layer_perf.hw_prefetchperf_version = tile_prefetchperf_version;
    layer_perf.hw_psumovl_start_cycles += tile_psumovl_start;
    layer_perf.hw_psumovl_hit_cycles += tile_psumovl_hit;
    layer_perf.hw_psumovl_wait_psum_cycles += tile_psumovl_wait_psum;
    layer_perf.hw_psumovl_underflow_cycles += tile_psumovl_underflow;
    layer_perf.hw_psumovlperf_version = tile_psumovlperf_version;
    layer_perf.hw_collect_packet_fire_cycles += tile_collect_packet_fire;
    layer_perf.hw_collect_partial_write_cycles += tile_collect_partial_write;
    layer_perf.hw_collect_final_write_cycles += tile_collect_final_write;
    layer_perf.hw_collect_context_push_cycles += tile_collect_context_push;
    layer_perf.hw_collect_context_pop_cycles += tile_collect_context_pop;
    layer_perf.hw_collect_context_full_stall_cycles += tile_collect_context_full_stall;
    layer_perf.hw_collect_column_empty_wait_cycles += tile_collect_column_empty_wait;
    layer_perf.hw_collectperf_version = tile_collectperf_version;
    layer_perf.hw_pass_count += tile_pass_count;
    layer_perf.hw_pass_start_to_first_fire_cycles += tile_pass_start_to_first;
    layer_perf.hw_pass_first_to_last_fire_cycles += tile_pass_first_to_last;
    layer_perf.hw_pass_last_fire_to_done_cycles += tile_pass_last_to_done;
    layer_perf.hw_pass_collect_first_wait_cycles += tile_pass_collect_first_wait;
    layer_perf.hw_pass_collect_column_empty_cycles += tile_pass_collect_column_empty;
    layer_perf.hw_pass_replay_during_compute_cycles += tile_pass_replay_during_compute;
    layer_perf.hw_pass_compute_idle_stage_cycles += tile_pass_compute_idle;
    layer_perf.hw_passperf_version = tile_passperf_version;
    layer_perf.vector_packets += tile_vector_packets;
    layer_perf.vector_pixels += tile_vector_pixels;
    layer_perf.vector_beats += tile_vector_beats;
    layer_perf.vector_fifo_stall_cycles += tile_vector_stalls;
    layer_perf.raw_load_active_cycles += tile_raw_load_active;
    layer_perf.raw_load_unpack_cycles += tile_raw_load_unpack;
    layer_perf.raw_replay_active_cycles += tile_raw_replay_active;
    layer_perf.raw_replay_wait_ready_cycles += tile_raw_replay_wait_ready;

    wr32(ACCEL_BASE_ADDR, ACCEL_CTRL, 2U);
    trace_printf("%s tile[%lu] services bias=%lu weight=%lu ifm=%lu\r\n",
                 layer->name, (unsigned long)tile_index,
                 (unsigned long)bias_services, (unsigned long)weight_services,
                 (unsigned long)ifm_services);

    uint32_t expected_ifm = expected_ifm_services_for_tile(layer, tile);
    if (bias_services != layer->cout_blocks ||
        weight_services != (layer->cout_blocks * layer->k_passes) ||
        ifm_services != expected_ifm) {
        xil_printf("%s unexpected service counts got b=%lu w=%lu i=%lu exp_i=%lu\r\n",
                   layer->name, (unsigned long)bias_services,
                   (unsigned long)weight_services, (unsigned long)ifm_services,
                   (unsigned long)expected_ifm);
        return -1;
    }

    *total_bias += bias_services;
    *total_weight += weight_services;
    *total_ifm += ifm_services;
    XTime_GetTime(&begin);
    if (parse_ofm_tile(layer, tile) != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.ofm_parse += end - begin;
    XTime_GetTime(&tile_end);
    layer_perf.tile_total += tile_end - tile_begin;
    return 0;
}

#if ACCEL_BATCH_STREAM
static int run_one_tile_batch(
    const chain_layer_t *layer,
    const chain_tile_t *tile,
    uint32_t tile_index,
    uint32_t bias_bytes,
    const void *weight_stream,
    uint32_t weight_bytes,
    const batch_ifm_stream_t *ifm_stream,
    const chain_tile_t *next_tile,
    uint32_t next_ifm_address,
    batch_ifm_stream_t *next_ifm_stream,
    uint32_t *total_bias,
    uint32_t *total_weight,
    uint32_t *total_ifm)
{
    uint32_t expected_bias = layer->cout_blocks;
    uint32_t expected_weight = layer->cout_blocks * layer->k_passes;
    uint32_t expected_ifm = expected_ifm_services_for_tile(layer, tile);
    uint32_t dbg_core_base;
    uint32_t dbg_axis_base;
    uint32_t dbg_tlast_base;
    uint32_t dbg_last_base;
    XTime begin;
    XTime end;
    XTime tile_begin;
    XTime tile_end;

    if (ifm_stream->packets != expected_ifm) {
        xil_printf("%s batch IFM packet mismatch prepared=%lu expected=%lu\r\n",
                   layer->name, (unsigned long)ifm_stream->packets,
                   (unsigned long)expected_ifm);
        return -1;
    }

    trace_printf("%s batch tile[%lu] oy=%lu h=%lu b=%lu w=%lu i=%lu\r\n",
                 layer->name, (unsigned long)tile_index,
                 (unsigned long)tile->tile_oy_base,
                 (unsigned long)tile->tile_ofm_h,
                 (unsigned long)expected_bias,
                 (unsigned long)expected_weight,
                 (unsigned long)expected_ifm);
    XTime_GetTime(&tile_begin);

    wr32(ACCEL_BASE_ADDR, ACCEL_NUM_PIXELS, tile->tile_pixels);
    wr32(ACCEL_BASE_ADDR, ACCEL_TILE_ROWS, (tile->tile_ofm_h << 16) | tile->tile_oy_base);
    wr32(ACCEL_BASE_ADDR, ACCEL_PIXEL_BASE, tile->tile_pixel_base);
    wr32(ACCEL_BASE_ADDR, ACCEL_EXPECTED_BYTES, tile->expected_ofm_bytes);
    wr32(ACCEL_BASE_ADDR, ACCEL_STREAM_BIAS_PACKETS, expected_bias);
    wr32(ACCEL_BASE_ADDR, ACCEL_STREAM_WEIGHT_PACKETS, expected_weight);
    wr32(ACCEL_BASE_ADDR, ACCEL_STREAM_IFM_PACKETS, expected_ifm);

    dbg_core_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_CORE_WR);
    dbg_axis_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_AXIS_WR);
    dbg_tlast_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_TLASTS);
    dbg_last_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_LAST_END);

    XTime_GetTime(&begin);
    dma_start_s2mm(DMA_OFM_BASE_ADDR, ofm_axis_buf, tile->expected_ofm_bytes * OFM_AXIS_BEAT_BYTES);
    ++layer_perf.dma_ofm_starts;
    XTime_GetTime(&end);
    layer_perf.ofm_dma += end - begin;

    XTime_GetTime(&begin);
    dma_start_mm2s(DMA_BIAS_BASE_ADDR, (const void *)(UINTPTR)BATCH_BIAS_ADDR, bias_bytes);
    ++layer_perf.dma_bias_starts;
    XTime_GetTime(&end);
    layer_perf.bias_dma += end - begin;
    XTime_GetTime(&begin);
    dma_start_mm2s(DMA_WEIGHT_BASE_ADDR, weight_stream, weight_bytes);
    ++layer_perf.dma_weight_starts;
    XTime_GetTime(&end);
    layer_perf.weight_dma += end - begin;
    XTime_GetTime(&begin);
    dma_start_mm2s(DMA_IFM_BASE_ADDR, ifm_stream->words, ifm_stream->bytes);
    ++layer_perf.dma_ifm_starts;
    XTime_GetTime(&end);
    layer_perf.ifm_dma += end - begin;

    wr32(ACCEL_BASE_ADDR, ACCEL_CTRL, 1U);

    if (next_tile != 0) {
        XTime_GetTime(&begin);
        if (pack_batch_ifm_stream(
                layer, next_tile, next_ifm_address, next_ifm_stream) != 0) {
            return -1;
        }
        XTime_GetTime(&end);
        layer_perf.ifm_pack += end - begin;
    }

    int done_seen = 0;
    for (uint32_t loops = 0U; loops < 80000000U; ++loops) {
        uint32_t ctrl = rd32(ACCEL_BASE_ADDR, ACCEL_CTRL);
        uint32_t st = rd32(GPIO_BASE_ADDR, GPIO2_DATA);
        debug_value = st;
        if ((st & ST_ERROR_MASK) != 0U) {
            xil_printf("%s batch AXIS protocol error gpio2=0x%08lx\r\n",
                       layer->name, (unsigned long)st);
            return -1;
        }
        if (((ctrl & 0x2U) != 0U) && ((ctrl & 0x1U) == 0U)) {
            done_seen = 1;
            break;
        }
    }
    if (!done_seen) {
        xil_printf("%s batch accelerator timeout tile=%lu ctrl=0x%08lx gpio2=0x%08lx\r\n",
                   layer->name, (unsigned long)tile_index,
                   (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_CTRL),
                   (unsigned long)rd32(GPIO_BASE_ADDR, GPIO2_DATA));
        return -1;
    }

    XTime_GetTime(&begin);
    if (dma_wait(DMA_BIAS_BASE_ADDR, DMA_MM2S_DMASR, "batch bias MM2S") != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.bias_sync += end - begin;
    XTime_GetTime(&begin);
    if (dma_wait(DMA_WEIGHT_BASE_ADDR, DMA_MM2S_DMASR, "batch weight MM2S") != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.weight_sync += end - begin;
    XTime_GetTime(&begin);
    if (dma_wait(DMA_IFM_BASE_ADDR, DMA_MM2S_DMASR, "batch IFM MM2S") != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.ifm_sync += end - begin;
    XTime_GetTime(&begin);
    if (dma_wait(DMA_OFM_BASE_ADDR, DMA_S2MM_DMASR, "ofm S2MM") != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.ofm_dma += end - begin;

    uint32_t actual_bias = rd32(ACCEL_BASE_ADDR, ACCEL_STREAM_BIAS_DONE);
    uint32_t actual_weight = rd32(ACCEL_BASE_ADDR, ACCEL_STREAM_WEIGHT_DONE);
    uint32_t actual_ifm = rd32(ACCEL_BASE_ADDR, ACCEL_STREAM_IFM_DONE);
    if (actual_bias != expected_bias ||
        actual_weight != expected_weight ||
        actual_ifm != expected_ifm) {
        xil_printf("%s batch packet mismatch got b=%lu w=%lu i=%lu expected b=%lu w=%lu i=%lu\r\n",
                   layer->name,
                   (unsigned long)actual_bias,
                   (unsigned long)actual_weight,
                   (unsigned long)actual_ifm,
                   (unsigned long)expected_bias,
                   (unsigned long)expected_weight,
                   (unsigned long)expected_ifm);
        return -1;
    }

    uint32_t dbg_core_delta = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_CORE_WR) - dbg_core_base;
    uint32_t dbg_axis_delta = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_AXIS_WR) - dbg_axis_base;
    uint32_t dbg_tlast_delta = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_TLASTS) - dbg_tlast_base;
    uint32_t dbg_last_delta = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_LAST_END) - dbg_last_base;
    if (dbg_core_delta != tile->expected_ofm_bytes ||
        dbg_axis_delta != tile->expected_ofm_bytes ||
        dbg_tlast_delta != 1U ||
        dbg_last_delta != tile->expected_ofm_bytes) {
        xil_printf("%s batch unexpected OFM debug delta core=%lu axis=%lu tlast=%lu last=%lu\r\n",
                   layer->name,
                   (unsigned long)dbg_core_delta,
                   (unsigned long)dbg_axis_delta,
                   (unsigned long)dbg_tlast_delta,
                   (unsigned long)dbg_last_delta);
        return -1;
    }

    uint32_t tile_busy = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_BUSY);
    uint32_t tile_wait = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_WAIT_ANY);
    uint32_t tile_wait_bias = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_WAIT_BIAS);
    uint32_t tile_wait_weight = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_WAIT_WEIGHT);
    uint32_t tile_wait_ifm = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_WAIT_IFM);
    uint32_t tile_wait_ofm = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_WAIT_OFM);
    uint32_t tile_compute = rd32(ACCEL_BASE_ADDR, ACCEL_PERF_COMPUTE);
    uint32_t tile_stage_bias = rd32(ACCEL_BASE_ADDR, ACCEL_STAGE_BIAS);
    uint32_t tile_stage_weight = rd32(ACCEL_BASE_ADDR, ACCEL_STAGE_WEIGHT);
    uint32_t tile_stage_feeder = rd32(ACCEL_BASE_ADDR, ACCEL_STAGE_FEEDER);
    uint32_t tile_stage_compute = rd32(ACCEL_BASE_ADDR, ACCEL_STAGE_COMPUTE);
    uint32_t tile_stage_drain = rd32(ACCEL_BASE_ADDR, ACCEL_STAGE_DRAIN);
    uint32_t tile_stage_ofm_post = rd32(ACCEL_BASE_ADDR, ACCEL_STAGE_OFM_POST);
    uint32_t tile_feed_fill = rd32(ACCEL_BASE_ADDR, ACCEL_FEED_FILL_WAIT);
    uint32_t tile_feed_push = rd32(ACCEL_BASE_ADDR, ACCEL_FEED_PUSH);
    uint32_t tile_feed_fifo_stall = rd32(ACCEL_BASE_ADDR, ACCEL_FEED_FIFO_STALL);
    uint32_t tile_feed_win_not_ready = rd32(ACCEL_BASE_ADDR, ACCEL_FEED_WIN_NOT_READY);
    uint32_t tile_comp_wload = rd32(ACCEL_BASE_ADDR, ACCEL_COMP_WLOAD);
    uint32_t tile_comp_active = rd32(ACCEL_BASE_ADDR, ACCEL_COMP_ACTIVE);
    uint32_t tile_comp_fire = rd32(ACCEL_BASE_ADDR, ACCEL_COMP_FIRE);
    uint32_t tile_comp_ifm_stall = rd32(ACCEL_BASE_ADDR, ACCEL_COMP_IFM_STALL);
    uint32_t tile_comp_tail = rd32(ACCEL_BASE_ADDR, ACCEL_COMP_TAIL);
    uint32_t tile_subperf_version = rd32(ACCEL_BASE_ADDR, ACCEL_SUBPERF_VERSION);
    uint32_t tile_tail_config = rd32(ACCEL_BASE_ADDR, ACCEL_TAIL_CONFIG);
    uint32_t tile_raw_start_level = (tile_tail_config >> 16) & 0xffffU;
    tile_tail_config &= 0xffffU;
    uint32_t tile_tail_elapsed = rd32(ACCEL_BASE_ADDR, ACCEL_TAIL_ELAPSED);
    uint32_t tile_drain_empty_wait = rd32(ACCEL_BASE_ADDR, ACCEL_DRAIN_EMPTY_WAIT);
    uint32_t tile_drain_empty_sticky = rd32(ACCEL_BASE_ADDR, ACCEL_DRAIN_EMPTY_STICKY);
    uint32_t tile_drain_read_fire = rd32(ACCEL_BASE_ADDR, ACCEL_DRAIN_READ_FIRE);
    uint32_t tile_drain_packet_fire = rd32(ACCEL_BASE_ADDR, ACCEL_DRAIN_PACKET_FIRE);
    uint32_t tile_drain_ready_stall = rd32(ACCEL_BASE_ADDR, ACCEL_DRAIN_READY_STALL);
    uint32_t tile_drain_internal_full = rd32(ACCEL_BASE_ADDR, ACCEL_DRAIN_INTERNAL_FULL);
    uint32_t tile_drainperf_version = rd32(ACCEL_BASE_ADDR, ACCEL_DRAINPERF_VERSION);
    uint32_t tile_prefetch_start = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCH_START);
    uint32_t tile_prefetch_weight_done = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCH_WEIGHT_DONE);
    uint32_t tile_prefetch_feed_done = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCH_FEED_DONE);
    uint32_t tile_prefetch_hit = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCH_HIT);
    uint32_t tile_prefetch_miss = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCH_MISS);
    uint32_t tile_prefetch_stall = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCH_STALL);
    uint32_t tile_prefetchperf_version = rd32(ACCEL_BASE_ADDR, ACCEL_PREFETCHPERF_VERSION);
    uint32_t tile_psumovl_start = rd32(ACCEL_BASE_ADDR, ACCEL_PSUMOVL_START);
    uint32_t tile_psumovl_hit = rd32(ACCEL_BASE_ADDR, ACCEL_PSUMOVL_HIT);
    uint32_t tile_psumovl_wait_psum = rd32(ACCEL_BASE_ADDR, ACCEL_PSUMOVL_WAIT_PSUM);
    uint32_t tile_psumovl_underflow = rd32(ACCEL_BASE_ADDR, ACCEL_PSUMOVL_UNDERFLOW);
    uint32_t tile_psumovlperf_version = rd32(ACCEL_BASE_ADDR, ACCEL_PSUMOVLPERF_VERSION);
    uint32_t tile_collect_packet_fire = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_PACKET_FIRE);
    uint32_t tile_collect_partial_write = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_PARTIAL_WRITE);
    uint32_t tile_collect_final_write = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_FINAL_WRITE);
    uint32_t tile_collect_context_push = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_CONTEXT_PUSH);
    uint32_t tile_collect_context_pop = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_CONTEXT_POP);
    uint32_t tile_collect_context_full_stall = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_CONTEXT_FULL_STALL);
    uint32_t tile_collect_column_empty_wait = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECT_COLUMN_EMPTY_WAIT);
    uint32_t tile_collectperf_version = rd32(ACCEL_BASE_ADDR, ACCEL_COLLECTPERF_VERSION);
    uint32_t tile_pass_count = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_COUNT);
    uint32_t tile_pass_start_to_first = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_START_TO_FIRST_FIRE);
    uint32_t tile_pass_first_to_last = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_FIRST_TO_LAST_FIRE);
    uint32_t tile_pass_last_to_done = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_LAST_FIRE_TO_DONE);
    uint32_t tile_pass_collect_first_wait = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_COLLECT_FIRST_WAIT);
    uint32_t tile_pass_collect_column_empty = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_COLLECT_COLUMN_EMPTY);
    uint32_t tile_pass_replay_during_compute = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_REPLAY_DURING_COMPUTE);
    uint32_t tile_pass_compute_idle = rd32(ACCEL_BASE_ADDR, ACCEL_PASS_COMPUTE_IDLE_STAGE);
    uint32_t tile_trace_weight_done = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_WEIGHT_DONE);
    uint32_t tile_trace_feed_start = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_FEED_START);
    uint32_t tile_trace_feed_ready = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_FEED_READY);
    uint32_t tile_trace_feed_done = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_FEED_DONE);
    uint32_t tile_trace_compute_start = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_COMPUTE_START);
    uint32_t tile_trace_first_fire = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_FIRST_FIRE);
    uint32_t tile_trace_last_fire = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_LAST_FIRE);
    uint32_t tile_trace_compute_done = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_COMPUTE_DONE);
    uint32_t tile_trace_collect_first = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_COLLECT_FIRST);
    uint32_t tile_trace_collect_last = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_COLLECT_LAST);
    uint32_t tile_trace_pass_done = rd32(ACCEL_BASE_ADDR, ACCEL_TRACE_PASS_DONE);
    uint32_t tile_passperf_version_raw = rd32(ACCEL_BASE_ADDR, ACCEL_PASSPERF_VERSION);
    uint32_t tile_pass_trace_valid = tile_passperf_version_raw >> 31;
    uint32_t tile_passperf_version = tile_passperf_version_raw & 0x7fffffffU;
    uint32_t tile_vector_packets = rd32(ACCEL_BASE_ADDR, ACCEL_VECTOR_PACKETS);
    uint32_t tile_vector_pixels = rd32(ACCEL_BASE_ADDR, ACCEL_VECTOR_PIXELS);
    uint32_t tile_vector_beats = rd32(ACCEL_BASE_ADDR, ACCEL_VECTOR_BEATS);
    uint32_t tile_vector_stalls = rd32(ACCEL_BASE_ADDR, ACCEL_VECTOR_STALLS);
    uint32_t tile_raw_load_active = rd32(ACCEL_BASE_ADDR, ACCEL_RAW_LOAD_ACTIVE);
    uint32_t tile_raw_load_unpack = rd32(ACCEL_BASE_ADDR, ACCEL_RAW_LOAD_UNPACK);
    uint32_t tile_raw_replay_active = rd32(ACCEL_BASE_ADDR, ACCEL_RAW_REPLAY_ACTIVE);
    uint32_t tile_raw_replay_wait_ready = rd32(ACCEL_BASE_ADDR, ACCEL_RAW_REPLAY_WAIT_READY);

#if ACCEL_TILE_PERF_TRACE
    xil_printf(
        "TILEPERF layer=%s tile=%lu oy=%lu h=%lu pixels=%lu "
        "packets_b=%lu packets_w=%lu packets_i=%lu busy=%lu wait=%lu "
        "wait_b=%lu wait_w=%lu wait_i=%lu wait_o=%lu compute=%lu "
        "stage_b=%lu stage_w=%lu stage_f=%lu stage_c=%lu stage_d=%lu stage_o=%lu "
        "feed_fill=%lu feed_push=%lu feed_fifo_stall=%lu feed_win_not_ready=%lu "
        "comp_wload=%lu comp_active=%lu comp_fire=%lu comp_ifm_stall=%lu comp_tail=%lu "
        "tail_cfg=%lu raw_start_level=%lu tail_elapsed=%lu "
        "drain_empty_wait=%lu drain_empty_sticky=%lu "
        "drain_read_fire=%lu drain_packet_fire=%lu drain_ready_stall=%lu "
        "drain_internal_full=%lu drainperf_version=%lu "
        "vector_packets=%lu vector_pixels=%lu vector_beats=%lu vector_stalls=%lu "
        "raw_load_active=%lu raw_load_unpack=%lu raw_replay_active=%lu "
        "raw_replay_wait_ready=%lu "
        "pass_count=%lu pass_start_to_first=%lu pass_fire_span=%lu "
        "pass_tail=%lu pass_collect_wait=%lu pass_collect_empty=%lu "
        "pass_replay_compute=%lu pass_compute_idle=%lu passperf_version=%lu "
        "subperf_version=%lu\r\n",
        layer->name,
        (unsigned long)tile_index,
        (unsigned long)tile->tile_oy_base,
        (unsigned long)tile->tile_ofm_h,
        (unsigned long)tile->tile_pixels,
        (unsigned long)actual_bias,
        (unsigned long)actual_weight,
        (unsigned long)actual_ifm,
        (unsigned long)tile_busy,
        (unsigned long)tile_wait,
        (unsigned long)tile_wait_bias,
        (unsigned long)tile_wait_weight,
        (unsigned long)tile_wait_ifm,
        (unsigned long)tile_wait_ofm,
        (unsigned long)tile_compute,
        (unsigned long)tile_stage_bias,
        (unsigned long)tile_stage_weight,
        (unsigned long)tile_stage_feeder,
        (unsigned long)tile_stage_compute,
        (unsigned long)tile_stage_drain,
        (unsigned long)tile_stage_ofm_post,
        (unsigned long)tile_feed_fill,
        (unsigned long)tile_feed_push,
        (unsigned long)tile_feed_fifo_stall,
        (unsigned long)tile_feed_win_not_ready,
        (unsigned long)tile_comp_wload,
        (unsigned long)tile_comp_active,
        (unsigned long)tile_comp_fire,
        (unsigned long)tile_comp_ifm_stall,
        (unsigned long)tile_comp_tail,
        (unsigned long)tile_tail_config,
        (unsigned long)tile_raw_start_level,
        (unsigned long)tile_tail_elapsed,
        (unsigned long)tile_drain_empty_wait,
        (unsigned long)tile_drain_empty_sticky,
        (unsigned long)tile_drain_read_fire,
        (unsigned long)tile_drain_packet_fire,
        (unsigned long)tile_drain_ready_stall,
        (unsigned long)tile_drain_internal_full,
        (unsigned long)tile_drainperf_version,
        (unsigned long)tile_vector_packets,
        (unsigned long)tile_vector_pixels,
        (unsigned long)tile_vector_beats,
        (unsigned long)tile_vector_stalls,
        (unsigned long)tile_raw_load_active,
        (unsigned long)tile_raw_load_unpack,
        (unsigned long)tile_raw_replay_active,
        (unsigned long)tile_raw_replay_wait_ready,
        (unsigned long)tile_pass_count,
        (unsigned long)tile_pass_start_to_first,
        (unsigned long)tile_pass_first_to_last,
        (unsigned long)tile_pass_last_to_done,
        (unsigned long)tile_pass_collect_first_wait,
        (unsigned long)tile_pass_collect_column_empty,
        (unsigned long)tile_pass_replay_during_compute,
        (unsigned long)tile_pass_compute_idle,
        (unsigned long)tile_passperf_version,
        (unsigned long)tile_subperf_version);
    if ((tile_pass_trace_valid != 0U) &&
        layer_uses_raw_hwc(layer) &&
        (tile_index == 0U)) {
        xil_printf(
            "PASSTRACE layer=%s tile=%lu cout_block=%lu k_pass=%lu "
            "weight_done=%lu feed_start=%lu feed_ready=%lu feed_done=%lu "
            "compute_start=%lu first_fire=%lu last_fire=%lu compute_done=%lu "
            "collect_first=%lu collect_last=%lu pass_done=%lu version=%lu\r\n",
            layer->name,
            (unsigned long)tile_index,
            (unsigned long)ACCEL_PASS_TRACE_COUT_BLOCK,
            (unsigned long)ACCEL_PASS_TRACE_K_PASS,
            (unsigned long)tile_trace_weight_done,
            (unsigned long)tile_trace_feed_start,
            (unsigned long)tile_trace_feed_ready,
            (unsigned long)tile_trace_feed_done,
            (unsigned long)tile_trace_compute_start,
            (unsigned long)tile_trace_first_fire,
            (unsigned long)tile_trace_last_fire,
            (unsigned long)tile_trace_compute_done,
            (unsigned long)tile_trace_collect_first,
            (unsigned long)tile_trace_collect_last,
            (unsigned long)tile_trace_pass_done,
            (unsigned long)tile_passperf_version);
        print_coltrace(layer, tile_index);
    }
#endif

    layer_perf.hw_busy_cycles += tile_busy;
    layer_perf.hw_wait_cycles += tile_wait;
    layer_perf.hw_wait_bias_cycles += tile_wait_bias;
    layer_perf.hw_wait_weight_cycles += tile_wait_weight;
    layer_perf.hw_wait_ifm_cycles += tile_wait_ifm;
    layer_perf.hw_wait_ofm_cycles += tile_wait_ofm;
    layer_perf.hw_compute_cycles += tile_compute;
    layer_perf.hw_stage_bias_cycles += tile_stage_bias;
    layer_perf.hw_stage_weight_cycles += tile_stage_weight;
    layer_perf.hw_stage_feeder_cycles += tile_stage_feeder;
    layer_perf.hw_stage_compute_cycles += tile_stage_compute;
    layer_perf.hw_stage_drain_cycles += tile_stage_drain;
    layer_perf.hw_stage_ofm_post_cycles += tile_stage_ofm_post;
    layer_perf.hw_feed_fill_wait_cycles += tile_feed_fill;
    layer_perf.hw_feed_push_cycles += tile_feed_push;
    layer_perf.hw_feed_fifo_stall_cycles += tile_feed_fifo_stall;
    layer_perf.hw_feed_win_not_ready_cycles += tile_feed_win_not_ready;
    layer_perf.hw_comp_wload_cycles += tile_comp_wload;
    layer_perf.hw_comp_active_cycles += tile_comp_active;
    layer_perf.hw_comp_fire_cycles += tile_comp_fire;
    layer_perf.hw_comp_ifm_stall_cycles += tile_comp_ifm_stall;
    layer_perf.hw_comp_tail_cycles += tile_comp_tail;
    layer_perf.hw_subperf_version = tile_subperf_version;
    layer_perf.hw_tail_config_cycles = tile_tail_config;
    layer_perf.hw_raw_compute_start_level = tile_raw_start_level;
    layer_perf.hw_tail_elapsed_cycles += tile_tail_elapsed;
    layer_perf.hw_drain_empty_wait_cycles += tile_drain_empty_wait;
    layer_perf.hw_drain_empty_sticky |= tile_drain_empty_sticky;
    layer_perf.hw_drain_read_fire_cycles += tile_drain_read_fire;
    layer_perf.hw_drain_packet_fire_cycles += tile_drain_packet_fire;
    layer_perf.hw_drain_ready_stall_cycles += tile_drain_ready_stall;
    layer_perf.hw_drain_internal_full_cycles += tile_drain_internal_full;
    layer_perf.hw_drainperf_version = tile_drainperf_version;
    layer_perf.hw_prefetch_start_cycles += tile_prefetch_start;
    layer_perf.hw_prefetch_weight_done_cycles += tile_prefetch_weight_done;
    layer_perf.hw_prefetch_feed_done_cycles += tile_prefetch_feed_done;
    layer_perf.hw_prefetch_hit_cycles += tile_prefetch_hit;
    layer_perf.hw_prefetch_miss_cycles += tile_prefetch_miss;
    layer_perf.hw_prefetch_stall_cycles += tile_prefetch_stall;
    layer_perf.hw_prefetchperf_version = tile_prefetchperf_version;
    layer_perf.hw_psumovl_start_cycles += tile_psumovl_start;
    layer_perf.hw_psumovl_hit_cycles += tile_psumovl_hit;
    layer_perf.hw_psumovl_wait_psum_cycles += tile_psumovl_wait_psum;
    layer_perf.hw_psumovl_underflow_cycles += tile_psumovl_underflow;
    layer_perf.hw_psumovlperf_version = tile_psumovlperf_version;
    layer_perf.hw_collect_packet_fire_cycles += tile_collect_packet_fire;
    layer_perf.hw_collect_partial_write_cycles += tile_collect_partial_write;
    layer_perf.hw_collect_final_write_cycles += tile_collect_final_write;
    layer_perf.hw_collect_context_push_cycles += tile_collect_context_push;
    layer_perf.hw_collect_context_pop_cycles += tile_collect_context_pop;
    layer_perf.hw_collect_context_full_stall_cycles += tile_collect_context_full_stall;
    layer_perf.hw_collect_column_empty_wait_cycles += tile_collect_column_empty_wait;
    layer_perf.hw_collectperf_version = tile_collectperf_version;
    layer_perf.hw_pass_count += tile_pass_count;
    layer_perf.hw_pass_start_to_first_fire_cycles += tile_pass_start_to_first;
    layer_perf.hw_pass_first_to_last_fire_cycles += tile_pass_first_to_last;
    layer_perf.hw_pass_last_fire_to_done_cycles += tile_pass_last_to_done;
    layer_perf.hw_pass_collect_first_wait_cycles += tile_pass_collect_first_wait;
    layer_perf.hw_pass_collect_column_empty_cycles += tile_pass_collect_column_empty;
    layer_perf.hw_pass_replay_during_compute_cycles += tile_pass_replay_during_compute;
    layer_perf.hw_pass_compute_idle_stage_cycles += tile_pass_compute_idle;
    layer_perf.hw_passperf_version = tile_passperf_version;
    layer_perf.vector_packets += tile_vector_packets;
    layer_perf.vector_pixels += tile_vector_pixels;
    layer_perf.vector_beats += tile_vector_beats;
    layer_perf.vector_fifo_stall_cycles += tile_vector_stalls;
    layer_perf.raw_load_active_cycles += tile_raw_load_active;
    layer_perf.raw_load_unpack_cycles += tile_raw_load_unpack;
    layer_perf.raw_replay_active_cycles += tile_raw_replay_active;
    layer_perf.raw_replay_wait_ready_cycles += tile_raw_replay_wait_ready;

    wr32(ACCEL_BASE_ADDR, ACCEL_CTRL, 2U);
    *total_bias += actual_bias;
    *total_weight += actual_weight;
    *total_ifm += actual_ifm;

    XTime_GetTime(&begin);
    if (parse_ofm_tile(layer, tile) != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.ofm_parse += end - begin;
    XTime_GetTime(&tile_end);
    layer_perf.tile_total += tile_end - tile_begin;
    return 0;
}
#endif

static int configure_layer(const chain_layer_t *layer)
{
    if ((rd32(ACCEL_BASE_ADDR, ACCEL_CTRL) & 0x1U) != 0U) {
        xil_printf("%s accelerator busy before config ctrl=0x%08lx\r\n",
                   layer->name, (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_CTRL));
        return -1;
    }
    wr32(ACCEL_BASE_ADDR, ACCEL_CTRL, 2U);
    wr32(GPIO_BASE_ADDR, GPIO_DATA, layer->fm_w);
    wr32(ACCEL_BASE_ADDR, ACCEL_FM_SIZE, (layer->fm_w << 16) | layer->fm_h);
    wr32(ACCEL_BASE_ADDR, ACCEL_OFM_SIZE, (layer->ofm_w << 16) | layer->ofm_h);
    wr32(
        ACCEL_BASE_ADDR,
        ACCEL_CONV,
        layer->kernel_1x1 ? (ACCEL_CONV_KERNEL_1X1 | 1U) : 0x00000101U);
    wr32(ACCEL_BASE_ADDR, ACCEL_K_TOTAL, layer->k_total);
    wr32(ACCEL_BASE_ADDR, ACCEL_COUT_TOTAL, layer->cout_total);
    wr32(ACCEL_BASE_ADDR, ACCEL_ACT_CFG, 2U);
    wr32(ACCEL_BASE_ADDR, ACCEL_IFM_ZP, layer->input_zero_point);
    wr32(ACCEL_BASE_ADDR, ACCEL_POOL_CFG, (layer->pool_stride << 2) | layer->pool_enable);
    wr32(
        ACCEL_BASE_ADDR,
        ACCEL_TAIL_CONFIG,
        ((ACCEL_RAW_HWC_COMPUTE_START_LEVEL & 0xffffU) << 16) |
        (ACCEL_TAIL_CYCLES_OVERRIDE & 0xffffU));
    wr32(
        ACCEL_BASE_ADDR,
        ACCEL_STREAM_CFG,
        ACCEL_BATCH_STREAM ?
            (ACCEL_STREAM_CFG_BATCH |
             (layer_uses_raw_hwc(layer) ?
              ACCEL_STREAM_CFG_RAW_HWC : 0U) |
             (ACCEL_EARLY_DRAIN ? ACCEL_STREAM_CFG_EARLY_DRAIN : 0U) |
             ((ACCEL_PASS_PREFETCH && layer_uses_raw_hwc(layer)) ?
              ACCEL_STREAM_CFG_PASS_PREFETCH : 0U) |
             ((ACCEL_PSUM_STREAM_OVERLAP && layer_uses_raw_hwc(layer)) ?
              ACCEL_STREAM_CFG_PSUM_STREAM_OVERLAP : 0U) |
             ((ACCEL_CONTINUOUS_PSUM && layer_uses_raw_hwc(layer)) ?
              ACCEL_STREAM_CFG_CONTINUOUS_PSUM : 0U) |
             ((ACCEL_COLUMN_PSUM && layer_uses_raw_hwc(layer)) ?
              ACCEL_STREAM_CFG_COLUMN_PSUM : 0U) |
             ((ACCEL_DURING_COMPUTE_PREFETCH && layer_uses_raw_hwc(layer)) ?
              ACCEL_STREAM_CFG_DURING_COMPUTE_PREFETCH : 0U)) :
            0U);
    wr32(
        ACCEL_BASE_ADDR,
        ACCEL_PASSTRACE_SELECT,
        (ACCEL_PASS_TRACE_ENABLE ? 0x80000000U : 0U) |
        ((ACCEL_PASS_TRACE_COUT_BLOCK & 0xffU) << 16) |
        (ACCEL_PASS_TRACE_K_PASS & 0xffffU));
    wr32(ACCEL_BASE_ADDR, ACCEL_COLTRACE_CTRL, 0U);
    if (program_quant_tile(layer) != 0) {
        return -1;
    }
    return program_activation_lut(layer);
}

static const chain_tile_t *get_layer_tile(
    const chain_layer_t *layer,
    uint32_t index,
    chain_tile_t *dynamic_tile)
{
    if (layer->tiles != 0) {
        return &layer->tiles[index];
    }

    uint32_t tile_oy_base = index * layer->dynamic_tile_ofm_h;
    uint32_t tile_ofm_h = layer->ofm_h - tile_oy_base;
    uint32_t final_w = layer->pool_enable ? layer->ofm_w / layer->pool_stride : layer->ofm_w;
    uint32_t final_oy_base = layer->pool_enable ? tile_oy_base / layer->pool_stride : tile_oy_base;
    uint32_t final_tile_h;
    if (tile_ofm_h > layer->dynamic_tile_ofm_h) {
        tile_ofm_h = layer->dynamic_tile_ofm_h;
    }
    final_tile_h = layer->pool_enable ? tile_ofm_h / layer->pool_stride : tile_ofm_h;
    dynamic_tile->name = layer->name;
    dynamic_tile->tile_oy_base = tile_oy_base;
    dynamic_tile->tile_ofm_h = tile_ofm_h;
    dynamic_tile->tile_pixel_base = final_oy_base * final_w;
    dynamic_tile->tile_pixels = layer->ofm_w * tile_ofm_h;
    dynamic_tile->expected_ofm_bytes = final_w * final_tile_h * layer->cout_total;
    return dynamic_tile;
}

static int run_layer(chain_layer_t *layer)
{
    uint32_t total_bias = 0U;
    uint32_t total_weight = 0U;
    uint32_t total_ifm = 0U;
    XTime layer_begin;
    XTime layer_end;
    XTime begin;
    XTime end;

    trace_printf("\r\n=== run %s ===\r\n", layer->name);
    for (uint32_t i = 0U; i < sizeof(layer_perf); ++i) {
        ((uint8_t *)&layer_perf)[i] = 0U;
    }
    XTime_GetTime(&layer_begin);
    XTime_GetTime(&begin);
    dma_reset_all();
    XTime_GetTime(&end);
    layer_perf.dma_reset += end - begin;
    XTime_GetTime(&begin);
    if (configure_layer(layer) != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.configure += end - begin;
    XTime_GetTime(&begin);
    clear_ofm(layer->ofm_u8, layer->total_expected_ofm_bytes);
    XTime_GetTime(&end);
    layer_perf.clear += end - begin;
#if ACCEL_BATCH_STREAM
    uint32_t batch_bias_bytes;
    const void *batch_weight_stream;
    uint32_t batch_weight_bytes;
    batch_ifm_stream_t current_ifm_stream;
    batch_ifm_stream_t next_ifm_stream;
    chain_tile_t first_tile_storage;
    const chain_tile_t *first_tile =
        get_layer_tile(layer, 0U, &first_tile_storage);

    XTime_GetTime(&begin);
    if (pack_batch_bias_stream(layer, &batch_bias_bytes) != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.bias_pack += end - begin;
    XTime_GetTime(&begin);
    if (prepare_batch_weight_stream(
            layer, &batch_weight_stream, &batch_weight_bytes) != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.weight_pack += end - begin;
    XTime_GetTime(&begin);
    if (pack_batch_ifm_stream(
            layer, first_tile, BATCH_IFM0_ADDR, &current_ifm_stream) != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.ifm_pack += end - begin;

    for (uint32_t i = 0U; i < layer->tile_count; ++i) {
        chain_tile_t tile_storage;
        chain_tile_t next_tile_storage;
        const chain_tile_t *tile = get_layer_tile(layer, i, &tile_storage);
        const chain_tile_t *next_tile =
            (i + 1U < layer->tile_count) ?
            get_layer_tile(layer, i + 1U, &next_tile_storage) : 0;
        uint32_t next_ifm_address =
            (current_ifm_stream.words == (uint64_t *)(UINTPTR)BATCH_IFM0_ADDR) ?
            BATCH_IFM1_ADDR : BATCH_IFM0_ADDR;
        if (run_one_tile_batch(
                layer, tile, i,
                batch_bias_bytes, batch_weight_stream, batch_weight_bytes,
                &current_ifm_stream,
                next_tile, next_ifm_address, &next_ifm_stream,
                &total_bias, &total_weight, &total_ifm) != 0) {
            return -1;
        }
        if (next_tile != 0) {
            current_ifm_stream = next_ifm_stream;
        }
    }
#else
    for (uint32_t i = 0U; i < layer->tile_count; ++i) {
        chain_tile_t dynamic_tile;
        const chain_tile_t *tile = get_layer_tile(layer, i, &dynamic_tile);
        if (run_one_tile(layer, tile, i, &total_bias, &total_weight, &total_ifm) != 0) {
            return -1;
        }
    }
#endif
    trace_printf("%s total services bias=%lu weight=%lu ifm=%lu\r\n",
                 layer->name, (unsigned long)total_bias,
                 (unsigned long)total_weight, (unsigned long)total_ifm);
    XTime_GetTime(&begin);
    if (compare_layer_ofm(layer) != 0) {
        return -1;
    }
    XTime_GetTime(&end);
    layer_perf.compare += end - begin;
    XTime_GetTime(&begin);
    Xil_DCacheFlushRange((UINTPTR)layer->ofm_u8, layer->total_expected_ofm_bytes);
    XTime_GetTime(&end);
    layer_perf.cache += end - begin;
    XTime_GetTime(&layer_end);
    layer_perf.layer_total = layer_end - layer_begin;
    print_layer_perf(layer);
    return 0;
}

#if ACCEL_CHAIN_CONV0_CONV9
#if ACCEL_CHAIN_CONV0_CONV9_DDR
static uint32_t image_tensor_checksum(const uint8_t *data, uint32_t bytes)
{
    uint32_t hash = 2166136261U;
    for (uint32_t i = 0U; i < bytes; ++i) {
        hash ^= data[i];
        hash *= 16777619U;
    }
    return hash;
}

static int validate_image_package(void)
{
    const uint8_t *tensor;
    uint32_t checksum;

    Xil_DCacheInvalidateRange(
        (UINTPTR)IMAGE_PACKAGE_ADDR,
        IMAGE_PACKAGE_HEADER_BYTES + 416U * 416U * 3U);
    image_package = (const image_package_header_t *)(UINTPTR)IMAGE_PACKAGE_ADDR;
    if (image_package->magic != IMAGE_PACKAGE_MAGIC ||
        image_package->version != IMAGE_PACKAGE_VERSION ||
        image_package->header_bytes != IMAGE_PACKAGE_HEADER_BYTES ||
        image_package->tensor_bytes != 416U * 416U * 3U ||
        image_package->original_w == 0U ||
        image_package->original_h == 0U ||
        image_package->scale <= 0.0f) {
        xil_printf(
            "IMAGE_PACKAGE invalid magic=0x%08lx version=%lu header=%lu tensor=%lu "
            "original=%lux%lu\r\n",
            (unsigned long)image_package->magic,
            (unsigned long)image_package->version,
            (unsigned long)image_package->header_bytes,
            (unsigned long)image_package->tensor_bytes,
            (unsigned long)image_package->original_w,
            (unsigned long)image_package->original_h);
        return -1;
    }
    tensor = (const uint8_t *)(UINTPTR)(IMAGE_PACKAGE_ADDR + image_package->header_bytes);
    checksum = image_tensor_checksum(tensor, image_package->tensor_bytes);
    if (checksum != image_package->tensor_checksum) {
        xil_printf("IMAGE_PACKAGE checksum got=0x%08lx expected=0x%08lx\r\n",
                   (unsigned long)checksum,
                   (unsigned long)image_package->tensor_checksum);
        return -1;
    }
    conv0_layer.ifm_u8 = tensor;
    xil_printf(
        "IMAGE_PACKAGE ready addr=0x%08lx tensor=%lu original=%lux%lu "
        "checksum=0x%08lx first=%u,%u,%u\r\n",
        (unsigned long)IMAGE_PACKAGE_ADDR,
        (unsigned long)image_package->tensor_bytes,
        (unsigned long)image_package->original_w,
        (unsigned long)image_package->original_h,
        (unsigned long)checksum,
        (unsigned)tensor[0],
        (unsigned)tensor[1],
        (unsigned)tensor[2]);
    return 0;
}
#endif

static int decode_and_print_conv9(void)
{
    int detection_count = yolo_decode_single_scale(
        feature_buffer1,
        0.25f,
        0.45f,
        yolo_detections,
        YOLO_MAX_CANDIDATES);
    if (detection_count < 0) {
        xil_printf("YOLO decode error=%d\r\n", detection_count);
        return -1;
    }

    xil_printf("DECODE count=%d\r\n", detection_count);
    for (int i = 0; i < detection_count; ++i) {
        yolo_detection_t original_detection;
        char score[24];
        char model_x1[24];
        char model_y1[24];
        char model_x2[24];
        char model_y2[24];
        char original_x1[24];
        char original_y1[24];
        char original_x2[24];
        char original_y2[24];

        yolo_inverse_letterbox(
            &yolo_detections[i],
#if ACCEL_CHAIN_CONV0_CONV9_DDR
            (float)image_package->original_w,
            (float)image_package->original_h,
            image_package->scale,
            image_package->pad_x,
            image_package->pad_y,
#else
            512.0f,
            366.0f,
            0.8125f,
            0.0f,
            59.0f,
#endif
            &original_detection);
        yolo_format_fixed6(yolo_detections[i].score, score, sizeof(score));
        yolo_format_fixed6(yolo_detections[i].x1, model_x1, sizeof(model_x1));
        yolo_format_fixed6(yolo_detections[i].y1, model_y1, sizeof(model_y1));
        yolo_format_fixed6(yolo_detections[i].x2, model_x2, sizeof(model_x2));
        yolo_format_fixed6(yolo_detections[i].y2, model_y2, sizeof(model_y2));
        yolo_format_fixed6(original_detection.x1, original_x1, sizeof(original_x1));
        yolo_format_fixed6(original_detection.y1, original_y1, sizeof(original_y1));
        yolo_format_fixed6(original_detection.x2, original_x2, sizeof(original_x2));
        yolo_format_fixed6(original_detection.y2, original_y2, sizeof(original_y2));
        xil_printf(
            "DET index=%d class=%lu name=%s score=%s "
            "model_x1=%s model_y1=%s model_x2=%s model_y2=%s "
            "orig_x1=%s orig_y1=%s orig_x2=%s orig_y2=%s\r\n",
            i,
            (unsigned long)yolo_detections[i].class_id,
            yolo_class_name(yolo_detections[i].class_id),
            score,
            model_x1,
            model_y1,
            model_x2,
            model_y2,
            original_x1,
            original_y1,
            original_x2,
            original_y2);
    }
    return 0;
}
#endif

int main(void)
{
    xil_printf("\r\n%s\r\n", CHAIN_SMOKE_NAME);
#if ACCEL_BATCH_STREAM
    if (batch_check_layout() != 0) {
        xil_printf("FAIL: batch scratch layout invalid\r\n");
        return -1;
    }
#endif
#if ACCEL_CHAIN_CONV0_CONV9_DDR
    if (validate_image_package() != 0) {
        xil_printf("FAIL: DDR image package validation failed\r\n");
        return -1;
    }
#endif
    wr32(GPIO_BASE_ADDR, GPIO_TRI, 0x00000000U);
    wr32(GPIO_BASE_ADDR, GPIO2_TRI, 0x0000ffffU);

    for (uint32_t i = 0U; i < (sizeof(chain_layers) / sizeof(chain_layers[0])); ++i) {
        if (run_layer(chain_layers[i]) != 0) {
            xil_printf("FAIL: %s chained stage failed\r\n", chain_layers[i]->name);
            return -1;
        }
    }
#if ACCEL_CHAIN_CONV0_CONV9
    if (decode_and_print_conv9() != 0) {
        xil_printf("FAIL: Conv9 YOLO decode failed\r\n");
        return -1;
    }
#endif
#if ACCEL_CHAIN_CONV0_CONV9_DDR
    xil_printf("PASS: %s dynamic image inference complete\r\n", CHAIN_SMOKE_NAME);
#else
    xil_printf("PASS: %s matches RTL golden\r\n", CHAIN_SMOKE_NAME);
#endif
    return 0;
}

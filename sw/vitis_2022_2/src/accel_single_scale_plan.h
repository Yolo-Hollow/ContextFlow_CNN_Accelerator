#ifndef ACCEL_SINGLE_SCALE_PLAN_H
#define ACCEL_SINGLE_SCALE_PLAN_H

#include "accel_abi_v2.h"

#include <stdint.h>

#define ACCEL_SINGLE_SCALE_ABI_VERSION ACCEL_ABI_VERSION_V2
#define ACCEL_SINGLE_SCALE_ROWS       ACCEL_RELEASE_ROWS
#define ACCEL_SINGLE_SCALE_COLS       ACCEL_RELEASE_COLS
#define ACCEL_SINGLE_SCALE_IFM_BANKS  2U
#define ACCEL_SINGLE_SCALE_COUT_TILE  ACCEL_RELEASE_COUT_TILE
#define ACCEL_SINGLE_SCALE_LAYER_COUNT 10U
#define ACCEL_SINGLE_SCALE_MAX_TILE_OFM_H 13U
#define ACCEL_SINGLE_SCALE_PSUM_BUF_AW 10U
#define ACCEL_SINGLE_SCALE_PSUM_BUF_DEPTH 1024U
#define ACCEL_SINGLE_SCALE_PACKED_REORDER_DEPTH 4096U
#define ACCEL_SINGLE_SCALE_TOTAL_IFM_BYTES 2249728U
#define ACCEL_SINGLE_SCALE_TOTAL_OFM_BYTES 1734616U
#define ACCEL_SINGLE_SCALE_TOTAL_OFM_BEATS 216827U
#define ACCEL_SINGLE_SCALE_TOTAL_BIAS_PACKETS 483U
#define ACCEL_SINGLE_SCALE_TOTAL_WEIGHT_PACKETS 29253U
#define ACCEL_SINGLE_SCALE_TOTAL_BIAS_STREAM_BYTES 61824U
#define ACCEL_SINGLE_SCALE_TOTAL_WEIGHT_STREAM_BYTES 16849728U
#define ACCEL_SINGLE_SCALE_TOTAL_COMPUTE_FIRE 3889197U
#define ACCEL_SINGLE_SCALE_MAX_LAYER_BIAS_STREAM_BYTES 26624U
#define ACCEL_SINGLE_SCALE_MAX_LAYER_WEIGHT_STREAM_BYTES 9437184U

#if ACCEL_SINGLE_SCALE_PSUM_BUF_DEPTH != (1U << ACCEL_SINGLE_SCALE_PSUM_BUF_AW)
#error "single-scale PSUM depth must match its address width"
#endif

typedef struct {
    const char *name;
    uint8_t model_index;
    uint8_t infer_index;
    uint16_t fm_w;
    uint16_t fm_h;
    uint16_t cin;
    uint16_t cout_total;
    uint8_t kernel;
    uint8_t stride;
    uint8_t pad;
    uint8_t pool_enable;
    uint8_t pool_stride;
    uint32_t conv_pixels;
    uint32_t final_pixels;
    uint32_t expected_ofm_bytes;
    uint32_t k_total;
    uint32_t k_passes;
    uint32_t cout_blocks;
    uint32_t act_mode;
    uint32_t input_zero_point;
    uint32_t tile_h_max;
    uint32_t ifm_total_bytes;
    uint32_t ofm_total_bytes;
    uint32_t layer_last;
} accel_single_scale_layer_plan_t;

static const accel_single_scale_layer_plan_t accel_single_scale_plan[ACCEL_SINGLE_SCALE_LAYER_COUNT] = {
    {"conv0_pool", 0, 0, 416, 416, 3, 16, 3, 1, 1, 1, 2, 173056, 43264, 692224, 27, 2, 1, 2, 0, 2, 519168, 692224, 0},
    {"conv1_pool", 2, 1, 208, 208, 16, 32, 3, 1, 1, 1, 2, 43264, 10816, 346112, 144, 8, 1, 2, 13, 4, 692224, 346112, 0},
    {"conv2_pool", 4, 2, 104, 104, 32, 64, 3, 1, 1, 1, 2, 10816, 2704, 173056, 288, 16, 2, 2, 36, 8, 346112, 173056, 0},
    {"conv3_pool", 6, 3, 52, 52, 64, 128, 3, 1, 1, 1, 2, 2704, 676, 86528, 576, 32, 4, 2, 36, 8, 173056, 86528, 0},
    {"conv4_pool", 8, 4, 26, 26, 128, 256, 3, 1, 1, 1, 2, 676, 169, 43264, 1152, 64, 8, 2, 16, 8, 86528, 43264, 0},
    {"conv5_pool_like_tiny", 10, 5, 13, 13, 256, 512, 3, 1, 1, 0, 0, 169, 169, 86528, 2304, 128, 16, 2, 15, 8, 43264, 86528, 0},
    {"head_conv6_3x3", 13, 6, 13, 13, 512, 1024, 3, 1, 1, 0, 0, 169, 169, 173056, 4608, 256, 32, 2, 19, 8, 86528, 173056, 0},
    {"head_conv7_1x1", 14, 7, 13, 13, 1024, 256, 1, 1, 0, 0, 0, 169, 169, 43264, 1024, 57, 8, 2, 21, 13, 173056, 43264, 0},
    {"head_conv8_3x3", 15, 8, 13, 13, 256, 512, 3, 1, 1, 0, 0, 169, 169, 86528, 2304, 128, 16, 2, 13, 8, 43264, 86528, 0},
    {"head_detect_conv9_1x1", 20, 9, 13, 13, 512, 24, 1, 1, 0, 0, 0, 169, 169, 4056, 512, 29, 1, 2, 11, 13, 86528, 4056, 1},
};

#endif

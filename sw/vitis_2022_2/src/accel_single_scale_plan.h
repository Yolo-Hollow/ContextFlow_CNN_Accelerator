#ifndef ACCEL_SINGLE_SCALE_PLAN_H
#define ACCEL_SINGLE_SCALE_PLAN_H

#include <stdint.h>

#define ACCEL_SINGLE_SCALE_ROWS       18U
#define ACCEL_SINGLE_SCALE_COLS       8U
#define ACCEL_SINGLE_SCALE_IFM_BANKS  2U
#define ACCEL_SINGLE_SCALE_COUT_TILE  (ACCEL_SINGLE_SCALE_COLS * 2U)
#define ACCEL_SINGLE_SCALE_LAYER_COUNT 10U
#define ACCEL_SINGLE_SCALE_MAX_TILE_OFM_H 8U

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
} accel_single_scale_layer_plan_t;

static const accel_single_scale_layer_plan_t accel_single_scale_plan[ACCEL_SINGLE_SCALE_LAYER_COUNT] = {
    {"conv0_pool", 0, 0, 416, 416, 3, 16, 3, 1, 1, 1, 2, 173056, 43264, 692224, 27, 2, 1},
    {"conv1_pool", 2, 1, 208, 208, 16, 32, 3, 1, 1, 1, 2, 43264, 10816, 346112, 144, 8, 2},
    {"conv2_pool", 4, 2, 104, 104, 32, 64, 3, 1, 1, 1, 2, 10816, 2704, 173056, 288, 16, 4},
    {"conv3_pool", 6, 3, 52, 52, 64, 128, 3, 1, 1, 1, 2, 2704, 676, 86528, 576, 32, 8},
    {"conv4_pool", 8, 4, 26, 26, 128, 256, 3, 1, 1, 1, 2, 676, 169, 43264, 1152, 64, 16},
    {"conv5_pool_like_tiny", 10, 5, 13, 13, 256, 512, 3, 1, 1, 0, 0, 169, 169, 86528, 2304, 128, 32},
    {"head_conv6_3x3", 13, 6, 13, 13, 512, 1024, 3, 1, 1, 0, 0, 169, 169, 173056, 4608, 256, 64},
    {"head_conv7_1x1", 14, 7, 13, 13, 1024, 256, 1, 1, 0, 0, 0, 169, 169, 43264, 1024, 57, 16},
    {"head_conv8_3x3", 15, 8, 13, 13, 256, 512, 3, 1, 1, 0, 0, 169, 169, 86528, 2304, 128, 32},
    {"head_detect_conv9_1x1", 20, 9, 13, 13, 512, 24, 1, 1, 0, 0, 0, 169, 169, 4056, 512, 29, 2},
};

#endif

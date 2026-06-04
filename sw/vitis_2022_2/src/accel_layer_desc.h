#ifndef ACCEL_LAYER_DESC_H
#define ACCEL_LAYER_DESC_H

#include <stdint.h>

typedef struct {
    const char *name;
    uint32_t fm_w;
    uint32_t fm_h;
    uint32_t ofm_w;
    uint32_t ofm_h;
    uint32_t cin;
    uint32_t cout_total;
    uint32_t k_total;
    uint32_t conv_stride;
    uint32_t conv_pad;
    uint32_t act_mode;
    uint32_t input_zero_point;
    uint32_t pool_enable;
    uint32_t pool_stride;
    uint32_t tile_oy_base;
    uint32_t tile_ofm_h;
    uint32_t tile_pixel_base;
    uint32_t tile_pixels;
    uint32_t expected_output_pixels;
    uint32_t expected_ofm_bytes;
    uint16_t quant_mult;
    uint8_t quant_shift;
    uint8_t quant_zp;
    const uint8_t *activation_lut;
    const uint8_t *golden_ofm_u8;
} accel_layer_desc_t;

typedef struct {
    const accel_layer_desc_t *layer;
    void *bias_buf;
    uint32_t bias_bytes;
    void *weight_buf;
    uint32_t weight_bytes;
    void *ifm_buf;
    uint32_t ifm_bytes;
    void *ofm_axis_buf;
    uint32_t ofm_axis_bytes;
} accel_layer_runtime_t;

#endif

#ifndef ACCEL_LAYER_DESC_H
#define ACCEL_LAYER_DESC_H

#include "accel_abi_v2.h"

#include <stdint.h>

typedef struct {
    const char *name;
    uint32_t abi_version;
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
    uint32_t tile_h_max;
    uint32_t ifm_total_bytes;
    uint32_t ofm_total_bytes;
    uint32_t layer_last;
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

/*
 * Pointer-free, fixed-width layer descriptor for ABI v2.  This is the
 * canonical software layout to use when the descriptor transport is wired to
 * RTL; the current v1 smoke runtime continues to use accel_layer_desc_t.
 */
#define ACCEL_LAYER_DESC_V2_FLAG_KERNEL_1X1 (1U << 0)
#define ACCEL_LAYER_DESC_V2_FLAG_HWC_IFM     (1U << 1)
#define ACCEL_LAYER_DESC_V2_FLAG_HWC_OFM     (1U << 2)
#define ACCEL_LAYER_DESC_V2_WORDS            20U

typedef struct {
    uint32_t abi_version;
    uint32_t flags;
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
    uint32_t tile_h_max;
    uint32_t ifm_total_bytes;
    uint32_t ofm_total_bytes;
    uint32_t layer_last;
    uint32_t reserved0;
} accel_layer_desc_v2_t;

typedef char accel_layer_desc_v2_size_must_be_80[
    (sizeof(accel_layer_desc_v2_t) == (ACCEL_LAYER_DESC_V2_WORDS * sizeof(uint32_t))) ? 1 : -1];

#endif

#ifndef COCO80_TENSOR_OPS_H
#define COCO80_TENSOR_OPS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    COCO80_TENSOR_OK = 0,
    COCO80_TENSOR_ERR_ARGUMENT = -1,
    COCO80_TENSOR_ERR_SHAPE = -2,
    COCO80_TENSOR_ERR_CAPACITY = -3,
    COCO80_TENSOR_ERR_QUANT = -4
};

typedef struct {
    uint32_t height;
    uint32_t width;
    uint32_t channels;
    uint32_t bytes;
    uint8_t *data;
} coco80_hwc_u8_t;

int coco80_maxpool2x2_s2(
    const coco80_hwc_u8_t *source,
    coco80_hwc_u8_t *destination);

int coco80_maxpool2x2_s2_channel_range(
    const coco80_hwc_u8_t *source,
    coco80_hwc_u8_t *destination,
    uint32_t channel_begin,
    uint32_t channel_end);

int coco80_maxpool2x2_s1_pad_right_bottom(
    const coco80_hwc_u8_t *source,
    uint8_t pad_value,
    coco80_hwc_u8_t *destination);

int coco80_maxpool2x2_s1_pad_right_bottom_channel_range(
    const coco80_hwc_u8_t *source,
    uint8_t pad_value,
    coco80_hwc_u8_t *destination,
    uint32_t channel_begin,
    uint32_t channel_end);

int coco80_nearest2x_requant_concat(
    const coco80_hwc_u8_t *small,
    const coco80_hwc_u8_t *route,
    int32_t route_input_zero_point,
    int32_t output_zero_point,
    uint32_t multiplier,
    uint32_t shift,
    coco80_hwc_u8_t *destination);

int coco80_nearest2x_requant_concat_pixel_range(
    const coco80_hwc_u8_t *small,
    const coco80_hwc_u8_t *route,
    int32_t route_input_zero_point,
    int32_t output_zero_point,
    uint32_t multiplier,
    uint32_t shift,
    coco80_hwc_u8_t *destination,
    uint32_t pixel_begin,
    uint32_t pixel_end);

int coco80_nearest2x(
    const coco80_hwc_u8_t *source,
    coco80_hwc_u8_t *destination);

int coco80_requant_concat(
    const coco80_hwc_u8_t *upsampled,
    const coco80_hwc_u8_t *route,
    int32_t route_input_zero_point,
    int32_t output_zero_point,
    uint32_t multiplier,
    uint32_t shift,
    coco80_hwc_u8_t *destination);

#ifdef __cplusplus
}
#endif

#endif

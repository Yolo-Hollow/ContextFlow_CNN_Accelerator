#ifndef COCO80_CPU_CONV_H
#define COCO80_CPU_CONV_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define COCO80_CPU_LAYER_COUNT 13U
#define COCO80_CPU_MAX_CHANNELS 1024U

typedef struct {
    const char *name;
    uint32_t ifm_h, ifm_w, ifm_c;
    uint32_t ofm_h, ofm_w, ofm_c;
    uint32_t kernel, stride, pad;
    uint32_t input_zero_point, output_zero_point;
    uint32_t quant_mult, quant_shift;
    uint32_t weight_offset, weight_bytes;
    uint32_t bias_offset, bias_bytes;
    uint32_t lut_offset, lut_bytes;
} coco80_cpu_layer_t;

enum {
    COCO80_CPU_OK = 0,
    COCO80_CPU_ERR_ARGUMENT = -301,
    COCO80_CPU_ERR_RANGE = -302,
    COCO80_CPU_ERR_QUANT = -303
};

int coco80_cpu_conv_kco_range(
    const uint8_t *ifm,
    uint8_t *ofm,
    const int8_t *weight_kco,
    const int32_t *bias_i32,
    const uint8_t *activation_lut_u8,
    const coco80_cpu_layer_t *layer,
    uint32_t channel_begin,
    uint32_t channel_end);

#ifdef __cplusplus
}
#endif

#endif

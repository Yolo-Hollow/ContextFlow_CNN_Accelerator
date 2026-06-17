#ifndef CPU_YOLO_BASELINE_H
#define CPU_YOLO_BASELINE_H

#include <stdint.h>

#define CPU_YOLO_LAYER_COUNT 10U
#define CPU_YOLO_MODEL_W 416U
#define CPU_YOLO_MODEL_H 416U
#define CPU_YOLO_MODEL_C 3U
#define CPU_YOLO_INPUT_BYTES (CPU_YOLO_MODEL_W * CPU_YOLO_MODEL_H * CPU_YOLO_MODEL_C)
#define CPU_YOLO_MAX_CONV_BYTES (416U * 416U * 16U)
#define CPU_YOLO_MAX_FINAL_BYTES (208U * 208U * 16U)
#define CPU_YOLO_CONV9_BYTES (13U * 13U * 24U)

typedef struct {
    const char *name;
    uint16_t ifm_h;
    uint16_t ifm_w;
    uint16_t ifm_c;
    uint16_t conv_h;
    uint16_t conv_w;
    uint16_t ofm_h;
    uint16_t ofm_w;
    uint16_t ofm_c;
    uint8_t kernel;
    uint8_t stride;
    uint8_t pad;
    uint8_t pool_enable;
    uint8_t pool_stride;
    uint8_t input_zero_point;
    uint8_t output_zero_point;
    uint16_t quant_mult;
    uint8_t quant_shift;
    const int8_t *weight_s8_kco;
    uint32_t weight_count;
    const int32_t *bias_i32;
    uint32_t bias_count;
    const uint8_t *activation_lut_u8;
    const uint8_t *golden_ofm_u8;
    uint32_t golden_bytes;
} cpu_yolo_layer_t;

extern const uint8_t cpu_yolo_input_u8[CPU_YOLO_INPUT_BYTES];
extern const cpu_yolo_layer_t cpu_yolo_layers[CPU_YOLO_LAYER_COUNT];

#endif

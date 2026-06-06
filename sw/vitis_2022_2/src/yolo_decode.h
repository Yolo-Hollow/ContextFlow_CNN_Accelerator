#ifndef YOLO_DECODE_H
#define YOLO_DECODE_H

#include <stdint.h>

#define YOLO_GRID_W 13U
#define YOLO_GRID_H 13U
#define YOLO_ANCHOR_COUNT 3U
#define YOLO_CLASS_COUNT 3U
#define YOLO_VALUES_PER_ANCHOR 8U
#define YOLO_CHANNELS (YOLO_ANCHOR_COUNT * YOLO_VALUES_PER_ANCHOR)
#define YOLO_TENSOR_BYTES (YOLO_GRID_W * YOLO_GRID_H * YOLO_CHANNELS)
#define YOLO_MAX_CANDIDATES (YOLO_GRID_W * YOLO_GRID_H * YOLO_ANCHOR_COUNT)

typedef struct {
    float x1;
    float y1;
    float x2;
    float y2;
    float score;
    uint32_t class_id;
    uint32_t source_index;
} yolo_detection_t;

int yolo_decode_single_scale(
    const uint8_t tensor[YOLO_TENSOR_BYTES],
    float confidence_threshold,
    float iou_threshold,
    yolo_detection_t *detections,
    uint32_t max_detections);

uint32_t yolo_class_aware_nms(
    yolo_detection_t *detections,
    uint32_t detection_count,
    float iou_threshold,
    uint32_t max_detections);

void yolo_inverse_letterbox(
    const yolo_detection_t *model_detection,
    float original_w,
    float original_h,
    float scale,
    float pad_x,
    float pad_y,
    yolo_detection_t *original_detection);

void yolo_format_fixed6(float value, char *buffer, uint32_t buffer_size);

const char *yolo_class_name(uint32_t class_id);

#endif

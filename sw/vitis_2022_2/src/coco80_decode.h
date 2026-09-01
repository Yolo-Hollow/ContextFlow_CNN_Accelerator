#ifndef COCO80_DECODE_H
#define COCO80_DECODE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define COCO80_MODEL_WIDTH 416U
#define COCO80_MODEL_HEIGHT 416U
#define COCO80_CLASS_COUNT 80U
#define COCO80_VALUES_PER_ANCHOR 85U
#define COCO80_ANCHORS_PER_HEAD 3U
#define COCO80_HEAD_COUNT 2U

#define COCO80_P4_GRID_WIDTH 26U
#define COCO80_P4_GRID_HEIGHT 26U
#define COCO80_P5_GRID_WIDTH 13U
#define COCO80_P5_GRID_HEIGHT 13U
#define COCO80_HEAD_CHANNELS \
    (COCO80_ANCHORS_PER_HEAD * COCO80_VALUES_PER_ANCHOR)
#define COCO80_P4_ANCHOR_COUNT \
    (COCO80_P4_GRID_WIDTH * COCO80_P4_GRID_HEIGHT * COCO80_ANCHORS_PER_HEAD)
#define COCO80_P5_ANCHOR_COUNT \
    (COCO80_P5_GRID_WIDTH * COCO80_P5_GRID_HEIGHT * COCO80_ANCHORS_PER_HEAD)
#define COCO80_TOTAL_ANCHORS (COCO80_P4_ANCHOR_COUNT + COCO80_P5_ANCHOR_COUNT)
#define COCO80_P4_TENSOR_BYTES \
    (COCO80_P4_GRID_WIDTH * COCO80_P4_GRID_HEIGHT * COCO80_HEAD_CHANNELS)
#define COCO80_P5_TENSOR_BYTES \
    (COCO80_P5_GRID_WIDTH * COCO80_P5_GRID_HEIGHT * COCO80_HEAD_CHANNELS)

#define COCO80_ACCURACY_MAX_NMS 30000U
#define COCO80_ACCURACY_MAX_DETECTIONS 300U

typedef enum {
    COCO80_DECODE_OK = 0,
    COCO80_DECODE_ERR_ARGUMENT = -1,
    COCO80_DECODE_ERR_CONFIG = -2,
    COCO80_DECODE_ERR_HEAD = -3,
    COCO80_DECODE_ERR_WORKSPACE = -4,
    COCO80_DECODE_ERR_OUTPUT = -5,
    COCO80_DECODE_ERR_LETTERBOX = -6
} coco80_decode_status_t;

/*
 * A raw head is packed HWC uint8.  For each pixel, channels are ordered as
 * anchor * 85 + value, where value is x, y, w, h, objectness, class[0..79].
 * heads[0] is P4/16 (26x26x255); heads[1] is P5/32 (13x13x255).
 */
typedef struct {
    const uint8_t *data;
    uint32_t bytes;
    float scale;
    int32_t zero_point;
} coco80_quantized_head_t;

typedef struct {
    uint32_t original_width;
    uint32_t original_height;
    float scale;
    float pad_x;
    float pad_y;
} coco80_letterbox_t;

typedef struct {
    float confidence_threshold;
    float iou_threshold;
    uint32_t max_nms;
    uint32_t max_detections;
    uint8_t multi_label;
    uint8_t reserved[3];
} coco80_decode_config_t;

/* Public so callers can place the workspace in a chosen DDR region. */
typedef struct {
    float x1;
    float y1;
    float x2;
    float y2;
    float score;
    uint32_t source_index;
    uint16_t class_id;
    uint8_t head_id;
    uint8_t anchor_id;
} coco80_candidate_t;

typedef struct {
    coco80_candidate_t *candidates;
    uint32_t capacity;
} coco80_decode_workspace_t;

typedef struct {
    float model_x1;
    float model_y1;
    float model_x2;
    float model_y2;
    float original_x1;
    float original_y1;
    float original_x2;
    float original_y2;
    float score;
    uint32_t class_id;
    uint32_t coco_category_id;
    uint32_t source_index;
    uint32_t head_id;
    uint32_t anchor_id;
    uint32_t grid_x;
    uint32_t grid_y;
} coco80_detection_t;

typedef struct {
    uint32_t anchors_scanned;
    uint32_t qualifying_candidates;
    uint32_t nms_input_candidates;
    uint32_t detection_count;
    uint32_t nms_comparisons;
    uint8_t topk_truncated;
    uint8_t reserved[3];
} coco80_decode_result_t;

typedef uint64_t (*coco80_decode_ticks_fn)(void *opaque);

typedef struct {
    uint64_t candidate_ticks;
    uint64_t sort_ticks;
    uint64_t nms_ticks;
} coco80_decode_timing_t;

void coco80_decode_config_accuracy(coco80_decode_config_t *config);
void coco80_decode_config_demo(coco80_decode_config_t *config);

/*
 * Required coco80_candidate_t elements, not bytes.  Single-label profiles
 * are capped at 2535 elements even when their serialized max_nms is 30000.
 */
uint32_t coco80_decode_workspace_elements(const coco80_decode_config_t *config);
uint32_t coco80_to_coco91_category(uint32_t class_id);

int coco80_decode_dual_head(
    const coco80_quantized_head_t heads[COCO80_HEAD_COUNT],
    const coco80_letterbox_t *letterbox,
    const coco80_decode_config_t *config,
    coco80_decode_workspace_t *workspace,
    coco80_detection_t *detections,
    uint32_t detection_capacity,
    coco80_decode_result_t *result);

int coco80_decode_dual_head_profiled(
    const coco80_quantized_head_t heads[COCO80_HEAD_COUNT],
    const coco80_letterbox_t *letterbox,
    const coco80_decode_config_t *config,
    coco80_decode_workspace_t *workspace,
    coco80_detection_t *detections,
    uint32_t detection_capacity,
    coco80_decode_result_t *result,
    coco80_decode_ticks_fn ticks,
    void *ticks_opaque,
    coco80_decode_timing_t *timing);

#ifdef __cplusplus
}
#endif

#endif

#include "yolo_decode.h"

#include <math.h>
#include <stdio.h>

#define YOLO_OUTPUT_SCALE 0.28766438364982605f
#define YOLO_OUTPUT_ZERO_POINT 80
#define YOLO_STRIDE 32.0f
#define YOLO_MODEL_SIZE 416.0f

static const float yolo_anchors[YOLO_ANCHOR_COUNT][2] = {
    {81.0f, 82.0f},
    {135.0f, 169.0f},
    {344.0f, 319.0f},
};

static const char *const yolo_class_names[YOLO_CLASS_COUNT] = {
    "with_mask",
    "without_mask",
    "mask_weared_incorrect",
};

static yolo_detection_t yolo_candidates[YOLO_MAX_CANDIDATES];

static float yolo_clip(float value, float low, float high)
{
    if (value < low) {
        return low;
    }
    if (value > high) {
        return high;
    }
    return value;
}

static float yolo_sigmoid(float value)
{
    if (value >= 0.0f) {
        float z = expf(-value);
        return 1.0f / (1.0f + z);
    }
    {
        float z = expf(value);
        return z / (1.0f + z);
    }
}

static float yolo_box_iou(const yolo_detection_t *a, const yolo_detection_t *b)
{
    float inter_x1 = (a->x1 > b->x1) ? a->x1 : b->x1;
    float inter_y1 = (a->y1 > b->y1) ? a->y1 : b->y1;
    float inter_x2 = (a->x2 < b->x2) ? a->x2 : b->x2;
    float inter_y2 = (a->y2 < b->y2) ? a->y2 : b->y2;
    float inter_w = inter_x2 - inter_x1;
    float inter_h = inter_y2 - inter_y1;
    float inter;
    float area_a;
    float area_b;
    float union_area;

    if (inter_w < 0.0f) {
        inter_w = 0.0f;
    }
    if (inter_h < 0.0f) {
        inter_h = 0.0f;
    }
    inter = inter_w * inter_h;
    area_a = (a->x2 - a->x1) * (a->y2 - a->y1);
    area_b = (b->x2 - b->x1) * (b->y2 - b->y1);
    union_area = area_a + area_b - inter;
    return (union_area <= 0.0f) ? 0.0f : inter / union_area;
}

static int yolo_detection_before(const yolo_detection_t *a, const yolo_detection_t *b)
{
    if (a->score > b->score) {
        return 1;
    }
    if (a->score < b->score) {
        return 0;
    }
    return a->source_index < b->source_index;
}

static void yolo_sort_detections(yolo_detection_t *detections, uint32_t count)
{
    uint32_t i;
    for (i = 1U; i < count; ++i) {
        yolo_detection_t value = detections[i];
        uint32_t j = i;
        while (j > 0U && yolo_detection_before(&value, &detections[j - 1U])) {
            detections[j] = detections[j - 1U];
            --j;
        }
        detections[j] = value;
    }
}

uint32_t yolo_class_aware_nms(
    yolo_detection_t *detections,
    uint32_t detection_count,
    float iou_threshold,
    uint32_t max_detections)
{
    uint32_t read_index;
    uint32_t kept = 0U;

    yolo_sort_detections(detections, detection_count);
    for (read_index = 0U; read_index < detection_count && kept < max_detections; ++read_index) {
        uint32_t accepted_index;
        int suppressed = 0;
        for (accepted_index = 0U; accepted_index < kept; ++accepted_index) {
            if (detections[read_index].class_id == detections[accepted_index].class_id &&
                yolo_box_iou(&detections[read_index], &detections[accepted_index]) > iou_threshold) {
                suppressed = 1;
                break;
            }
        }
        if (!suppressed) {
            detections[kept++] = detections[read_index];
        }
    }
    return kept;
}

int yolo_decode_single_scale(
    const uint8_t tensor[YOLO_TENSOR_BYTES],
    float confidence_threshold,
    float iou_threshold,
    yolo_detection_t *detections,
    uint32_t max_detections)
{
    uint32_t gy;
    uint32_t gx;
    uint32_t anchor_id;
    uint32_t candidate_count = 0U;

    if (tensor == 0 || detections == 0 || max_detections == 0U) {
        return -1;
    }

    for (gy = 0U; gy < YOLO_GRID_H; ++gy) {
        for (gx = 0U; gx < YOLO_GRID_W; ++gx) {
            uint32_t pixel_base = (gy * YOLO_GRID_W + gx) * YOLO_CHANNELS;
            for (anchor_id = 0U; anchor_id < YOLO_ANCHOR_COUNT; ++anchor_id) {
                uint32_t base = pixel_base + anchor_id * YOLO_VALUES_PER_ANCHOR;
                float probability[YOLO_VALUES_PER_ANCHOR];
                float objectness;
                float best_class_probability;
                float score;
                float center_x;
                float center_y;
                float width;
                float height;
                uint32_t value_index;
                uint32_t class_id = 0U;

                for (value_index = 0U; value_index < YOLO_VALUES_PER_ANCHOR; ++value_index) {
                    float logit = ((float)tensor[base + value_index] -
                                   (float)YOLO_OUTPUT_ZERO_POINT) * YOLO_OUTPUT_SCALE;
                    probability[value_index] = yolo_sigmoid(logit);
                }
                objectness = probability[4];
                if (objectness <= confidence_threshold) {
                    continue;
                }
                best_class_probability = probability[5];
                for (value_index = 1U; value_index < YOLO_CLASS_COUNT; ++value_index) {
                    if (probability[5U + value_index] > best_class_probability) {
                        best_class_probability = probability[5U + value_index];
                        class_id = value_index;
                    }
                }
                score = objectness * best_class_probability;
                if (score <= confidence_threshold) {
                    continue;
                }
                if (candidate_count >= YOLO_MAX_CANDIDATES) {
                    return -2;
                }

                center_x = (probability[0] * 2.0f - 0.5f + (float)gx) * YOLO_STRIDE;
                center_y = (probability[1] * 2.0f - 0.5f + (float)gy) * YOLO_STRIDE;
                width = probability[2] * 2.0f;
                width = width * width * yolo_anchors[anchor_id][0];
                height = probability[3] * 2.0f;
                height = height * height * yolo_anchors[anchor_id][1];

                yolo_candidates[candidate_count].x1 =
                    yolo_clip(center_x - width * 0.5f, 0.0f, YOLO_MODEL_SIZE);
                yolo_candidates[candidate_count].y1 =
                    yolo_clip(center_y - height * 0.5f, 0.0f, YOLO_MODEL_SIZE);
                yolo_candidates[candidate_count].x2 =
                    yolo_clip(center_x + width * 0.5f, 0.0f, YOLO_MODEL_SIZE);
                yolo_candidates[candidate_count].y2 =
                    yolo_clip(center_y + height * 0.5f, 0.0f, YOLO_MODEL_SIZE);
                yolo_candidates[candidate_count].score = score;
                yolo_candidates[candidate_count].class_id = class_id;
                yolo_candidates[candidate_count].source_index =
                    (gy * YOLO_GRID_W + gx) * YOLO_ANCHOR_COUNT + anchor_id;
                ++candidate_count;
            }
        }
    }

    {
        uint32_t detection_count = yolo_class_aware_nms(
            yolo_candidates, candidate_count, iou_threshold, max_detections);
        uint32_t detection_index;
        for (detection_index = 0U; detection_index < detection_count; ++detection_index) {
            detections[detection_index] = yolo_candidates[detection_index];
        }
        return (int)detection_count;
    }
}

void yolo_inverse_letterbox(
    const yolo_detection_t *model_detection,
    float original_w,
    float original_h,
    float scale,
    float pad_x,
    float pad_y,
    yolo_detection_t *original_detection)
{
    *original_detection = *model_detection;
    original_detection->x1 = yolo_clip((model_detection->x1 - pad_x) / scale, 0.0f, original_w);
    original_detection->y1 = yolo_clip((model_detection->y1 - pad_y) / scale, 0.0f, original_h);
    original_detection->x2 = yolo_clip((model_detection->x2 - pad_x) / scale, 0.0f, original_w);
    original_detection->y2 = yolo_clip((model_detection->y2 - pad_y) / scale, 0.0f, original_h);
}

void yolo_format_fixed6(float value, char *buffer, uint32_t buffer_size)
{
    int negative = value < 0.0f;
    double magnitude = negative ? -(double)value : (double)value;
    uint64_t scaled = (uint64_t)(magnitude * 1000000.0 + 0.5);
    uint64_t integer_part = scaled / 1000000U;
    uint64_t fractional_part = scaled % 1000000U;
    snprintf(
        buffer,
        buffer_size,
        negative ? "-%llu.%06llu" : "%llu.%06llu",
        (unsigned long long)integer_part,
        (unsigned long long)fractional_part);
}

const char *yolo_class_name(uint32_t class_id)
{
    return (class_id < YOLO_CLASS_COUNT) ? yolo_class_names[class_id] : "unknown";
}

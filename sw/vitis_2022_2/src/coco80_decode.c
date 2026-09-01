#include "coco80_decode.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

typedef char coco80_float_size_check[sizeof(float) == 4U ? 1 : -1];
typedef char coco80_candidate_size_check[
    sizeof(coco80_candidate_t) == 28U ? 1 : -1];

typedef struct {
    uint32_t width;
    uint32_t height;
    float stride;
    float anchors[COCO80_ANCHORS_PER_HEAD][2];
    uint32_t source_base;
    uint32_t expected_bytes;
} coco80_head_geometry_t;

static const coco80_head_geometry_t coco80_geometry[COCO80_HEAD_COUNT] = {
    {
        COCO80_P4_GRID_WIDTH,
        COCO80_P4_GRID_HEIGHT,
        16.0f,
        {{10.0f, 14.0f}, {23.0f, 27.0f}, {37.0f, 58.0f}},
        0U,
        COCO80_P4_TENSOR_BYTES,
    },
    {
        COCO80_P5_GRID_WIDTH,
        COCO80_P5_GRID_HEIGHT,
        32.0f,
        {{81.0f, 82.0f}, {135.0f, 169.0f}, {344.0f, 319.0f}},
        COCO80_P4_ANCHOR_COUNT,
        COCO80_P5_TENSOR_BYTES,
    },
};

static const uint8_t coco80_to_coco91[COCO80_CLASS_COUNT] = {
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
    11, 13, 14, 15, 16, 17, 18, 19, 20, 21,
    22, 23, 24, 25, 27, 28, 31, 32, 33, 34,
    35, 36, 37, 38, 39, 40, 41, 42, 43, 44,
    46, 47, 48, 49, 50, 51, 52, 53, 54, 55,
    56, 57, 58, 59, 60, 61, 62, 63, 64, 65,
    67, 70, 72, 73, 74, 75, 76, 77, 78, 79,
    80, 81, 82, 84, 85, 86, 87, 88, 89, 90,
};

static float coco80_sigmoid(float value)
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

static float coco80_dequant_sigmoid(uint8_t value, const coco80_quantized_head_t *head)
{
    return coco80_sigmoid(((float)value - (float)head->zero_point) * head->scale);
}

static float coco80_clip(float value, float low, float high)
{
    if (value < low) {
        return low;
    }
    if (value > high) {
        return high;
    }
    return value;
}

/* Strict total order used for top-K, final sort, and deterministic ties. */
static int coco80_candidate_better(
    const coco80_candidate_t *left,
    const coco80_candidate_t *right)
{
    if (left->score > right->score) {
        return 1;
    }
    if (left->score < right->score) {
        return 0;
    }
    if (left->source_index < right->source_index) {
        return 1;
    }
    if (left->source_index > right->source_index) {
        return 0;
    }
    return left->class_id < right->class_id;
}

static int coco80_candidate_worse(
    const coco80_candidate_t *left,
    const coco80_candidate_t *right)
{
    return coco80_candidate_better(right, left);
}

static void coco80_swap_candidate(coco80_candidate_t *a, coco80_candidate_t *b)
{
    coco80_candidate_t value = *a;
    *a = *b;
    *b = value;
}

/* The online top-K heap keeps its worst candidate at index zero. */
static void coco80_heap_sift_up(coco80_candidate_t *heap, uint32_t index)
{
    while (index > 0U) {
        uint32_t parent = (index - 1U) / 2U;
        if (!coco80_candidate_worse(&heap[index], &heap[parent])) {
            break;
        }
        coco80_swap_candidate(&heap[index], &heap[parent]);
        index = parent;
    }
}

static void coco80_heap_sift_down(
    coco80_candidate_t *heap,
    uint32_t count,
    uint32_t index)
{
    for (;;) {
        uint32_t left = index * 2U + 1U;
        uint32_t right = left + 1U;
        uint32_t worse = index;
        if (left < count && coco80_candidate_worse(&heap[left], &heap[worse])) {
            worse = left;
        }
        if (right < count && coco80_candidate_worse(&heap[right], &heap[worse])) {
            worse = right;
        }
        if (worse == index) {
            break;
        }
        coco80_swap_candidate(&heap[index], &heap[worse]);
        index = worse;
    }
}

static void coco80_offer_candidate(
    coco80_candidate_t *heap,
    uint32_t capacity,
    uint32_t *count,
    const coco80_candidate_t *candidate)
{
    if (*count < capacity) {
        heap[*count] = *candidate;
        coco80_heap_sift_up(heap, *count);
        ++(*count);
    } else if (coco80_candidate_better(candidate, &heap[0])) {
        heap[0] = *candidate;
        coco80_heap_sift_down(heap, *count, 0U);
    }
}

/* A worst-first heap sort produces the required best-first array. */
static void coco80_sort_best_first(coco80_candidate_t *heap, uint32_t count)
{
    uint32_t end = count;
    while (end > 1U) {
        --end;
        coco80_swap_candidate(&heap[0], &heap[end]);
        coco80_heap_sift_down(heap, end, 0U);
    }
}

static float coco80_box_iou(
    const coco80_candidate_t *candidate,
    const coco80_detection_t *accepted)
{
    /*
     * Match the canonical host's torchvision NMS arithmetic exactly.  The
     * host separates classes by adding class_id * 7680 to every coordinate
     * before computing IoU.  The offset cancels algebraically, but its
     * float32 rounding is observable for high class IDs at the IoU boundary.
     * Keeping the same arithmetic here prevents a board/host keep-set split.
     */
    float class_offset = (float)candidate->class_id * 7680.0f;
    float candidate_x1 = candidate->x1 + class_offset;
    float candidate_y1 = candidate->y1 + class_offset;
    float candidate_x2 = candidate->x2 + class_offset;
    float candidate_y2 = candidate->y2 + class_offset;
    float accepted_x1 = accepted->model_x1 + class_offset;
    float accepted_y1 = accepted->model_y1 + class_offset;
    float accepted_x2 = accepted->model_x2 + class_offset;
    float accepted_y2 = accepted->model_y2 + class_offset;
    float inter_x1 = candidate_x1 > accepted_x1 ? candidate_x1 : accepted_x1;
    float inter_y1 = candidate_y1 > accepted_y1 ? candidate_y1 : accepted_y1;
    float inter_x2 = candidate_x2 < accepted_x2 ? candidate_x2 : accepted_x2;
    float inter_y2 = candidate_y2 < accepted_y2 ? candidate_y2 : accepted_y2;
    float inter_w = inter_x2 - inter_x1;
    float inter_h = inter_y2 - inter_y1;
    float area_a;
    float area_b;
    float inter;
    float union_area;

    if (inter_w < 0.0f) {
        inter_w = 0.0f;
    }
    if (inter_h < 0.0f) {
        inter_h = 0.0f;
    }
    inter = inter_w * inter_h;
    area_a = (candidate_x2 - candidate_x1) * (candidate_y2 - candidate_y1);
    area_b = (accepted_x2 - accepted_x1) * (accepted_y2 - accepted_y1);
    union_area = area_a + area_b - inter;
    return union_area > 0.0f ? inter / union_area : 0.0f;
}

static int coco80_valid_config(const coco80_decode_config_t *config)
{
    return config != NULL &&
        isfinite(config->confidence_threshold) &&
        isfinite(config->iou_threshold) &&
        config->confidence_threshold >= 0.0f &&
        config->confidence_threshold <= 1.0f &&
        config->iou_threshold >= 0.0f &&
        config->iou_threshold <= 1.0f &&
        config->max_nms > 0U &&
        config->max_nms <= COCO80_ACCURACY_MAX_NMS &&
        config->max_detections > 0U &&
        config->max_detections <= COCO80_ACCURACY_MAX_DETECTIONS &&
        config->max_detections <= config->max_nms &&
        config->multi_label <= 1U &&
        config->reserved[0] == 0U &&
        config->reserved[1] == 0U &&
        config->reserved[2] == 0U;
}

static int coco80_valid_letterbox(const coco80_letterbox_t *letterbox)
{
    float resized_width;
    float resized_height;
    float covered_width;
    float covered_height;

    if (letterbox == NULL ||
        letterbox->original_width == 0U || letterbox->original_height == 0U ||
        !isfinite(letterbox->scale) || letterbox->scale <= 0.0f ||
        !isfinite(letterbox->pad_x) || letterbox->pad_x < 0.0f ||
        !isfinite(letterbox->pad_y) || letterbox->pad_y < 0.0f) {
        return 0;
    }
    resized_width = (float)letterbox->original_width * letterbox->scale;
    resized_height = (float)letterbox->original_height * letterbox->scale;
    if (!isfinite(resized_width) || !isfinite(resized_height) ||
        resized_width < 0.5f || resized_height < 0.5f ||
        resized_width > (float)COCO80_MODEL_WIDTH + 0.5f ||
        resized_height > (float)COCO80_MODEL_HEIGHT + 0.5f ||
        fabsf(letterbox->pad_x - floorf(letterbox->pad_x)) > 1e-4f ||
        fabsf(letterbox->pad_y - floorf(letterbox->pad_y)) > 1e-4f ||
        letterbox->pad_x > (float)COCO80_MODEL_WIDTH * 0.5f ||
        letterbox->pad_y > (float)COCO80_MODEL_HEIGHT * 0.5f ||
        (resized_width < (float)COCO80_MODEL_WIDTH - 0.5f &&
         resized_height < (float)COCO80_MODEL_HEIGHT - 0.5f)) {
        return 0;
    }
    /*
     * Python round() uses ties-to-even while C's common round idioms do not.
     * Validate centered integer padding through covered extent so valid .5
     * resize cases are accepted without silently accepting an off-centre box.
     */
    covered_width = resized_width + letterbox->pad_x * 2.0f;
    covered_height = resized_height + letterbox->pad_y * 2.0f;
    return covered_width >= (float)COCO80_MODEL_WIDTH - 1.5f &&
        covered_width <= (float)COCO80_MODEL_WIDTH + 0.5f &&
        covered_height >= (float)COCO80_MODEL_HEIGHT - 1.5f &&
        covered_height <= (float)COCO80_MODEL_HEIGHT + 0.5f;
}

static void coco80_make_candidate(
    coco80_candidate_t *candidate,
    const float sigmoid_lut[256],
    const coco80_head_geometry_t *geometry,
    const uint8_t *values,
    float score,
    uint32_t source_index,
    uint32_t head_id,
    uint32_t anchor_id,
    uint32_t grid_x,
    uint32_t grid_y,
    uint32_t class_id)
{
    float center_x =
        (sigmoid_lut[values[0]] * 2.0f - 0.5f + (float)grid_x) *
        geometry->stride;
    float center_y =
        (sigmoid_lut[values[1]] * 2.0f - 0.5f + (float)grid_y) *
        geometry->stride;
    float width = sigmoid_lut[values[2]] * 2.0f;
    float height = sigmoid_lut[values[3]] * 2.0f;
    width = width * width * geometry->anchors[anchor_id][0];
    height = height * height * geometry->anchors[anchor_id][1];

    candidate->x1 = center_x - width * 0.5f;
    candidate->y1 = center_y - height * 0.5f;
    candidate->x2 = center_x + width * 0.5f;
    candidate->y2 = center_y + height * 0.5f;
    candidate->score = score;
    candidate->source_index = source_index;
    candidate->class_id = (uint16_t)class_id;
    candidate->head_id = (uint8_t)head_id;
    candidate->anchor_id = (uint8_t)anchor_id;
}

static void coco80_write_detection(
    coco80_detection_t *output,
    const coco80_candidate_t *candidate,
    const coco80_letterbox_t *letterbox)
{
    const coco80_head_geometry_t *geometry = &coco80_geometry[candidate->head_id];
    uint32_t local_source = candidate->source_index - geometry->source_base;
    uint32_t pixel = local_source -
        (uint32_t)candidate->anchor_id * geometry->width * geometry->height;

    output->model_x1 = candidate->x1;
    output->model_y1 = candidate->y1;
    output->model_x2 = candidate->x2;
    output->model_y2 = candidate->y2;
    output->original_x1 = coco80_clip(
        (candidate->x1 - letterbox->pad_x) / letterbox->scale,
        0.0f,
        (float)letterbox->original_width);
    output->original_y1 = coco80_clip(
        (candidate->y1 - letterbox->pad_y) / letterbox->scale,
        0.0f,
        (float)letterbox->original_height);
    output->original_x2 = coco80_clip(
        (candidate->x2 - letterbox->pad_x) / letterbox->scale,
        0.0f,
        (float)letterbox->original_width);
    output->original_y2 = coco80_clip(
        (candidate->y2 - letterbox->pad_y) / letterbox->scale,
        0.0f,
        (float)letterbox->original_height);
    output->score = candidate->score;
    output->class_id = candidate->class_id;
    output->coco_category_id = coco80_to_coco91[candidate->class_id];
    output->source_index = candidate->source_index;
    output->head_id = candidate->head_id;
    output->anchor_id = candidate->anchor_id;
    output->grid_x = pixel % geometry->width;
    output->grid_y = pixel / geometry->width;
}

void coco80_decode_config_accuracy(coco80_decode_config_t *config)
{
    if (config == NULL) {
        return;
    }
    memset(config, 0, sizeof(*config));
    config->confidence_threshold = 0.001f;
    config->iou_threshold = 0.65f;
    config->max_nms = COCO80_ACCURACY_MAX_NMS;
    config->max_detections = COCO80_ACCURACY_MAX_DETECTIONS;
    config->multi_label = 1U;
}

void coco80_decode_config_demo(coco80_decode_config_t *config)
{
    if (config == NULL) {
        return;
    }
    memset(config, 0, sizeof(*config));
    config->confidence_threshold = 0.25f;
    config->iou_threshold = 0.45f;
    /* Keep the serialized policy identical to the canonical host profile. */
    config->max_nms = COCO80_ACCURACY_MAX_NMS;
    config->max_detections = COCO80_ACCURACY_MAX_DETECTIONS;
    config->multi_label = 0U;
}

uint32_t coco80_decode_workspace_elements(const coco80_decode_config_t *config)
{
    if (!coco80_valid_config(config)) {
        return 0U;
    }
    /* A single-label head can emit at most one candidate per anchor. */
    if (config->multi_label == 0U && config->max_nms > COCO80_TOTAL_ANCHORS) {
        return COCO80_TOTAL_ANCHORS;
    }
    return config->max_nms;
}

uint32_t coco80_to_coco91_category(uint32_t class_id)
{
    return class_id < COCO80_CLASS_COUNT ? coco80_to_coco91[class_id] : 0U;
}

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
    coco80_decode_timing_t *timing)
{
    float sigmoid_lut[COCO80_HEAD_COUNT][256];
    uint32_t heap_count = 0U;
    uint32_t qualifying_count = 0U;
    uint32_t head_id;
    uint32_t detection_count = 0U;
    uint32_t nms_comparisons = 0U;
    uint32_t heap_capacity;
    uint64_t phase_start = 0U;

    if (result != NULL) {
        memset(result, 0, sizeof(*result));
    }
    if (timing != NULL) {
        memset(timing, 0, sizeof(*timing));
    }
    if (heads == NULL || workspace == NULL || result == NULL ||
        ((ticks == NULL) != (timing == NULL))) {
        return COCO80_DECODE_ERR_ARGUMENT;
    }
    if (!coco80_valid_config(config)) {
        return COCO80_DECODE_ERR_CONFIG;
    }
    if (!coco80_valid_letterbox(letterbox)) {
        return COCO80_DECODE_ERR_LETTERBOX;
    }
    heap_capacity = coco80_decode_workspace_elements(config);
    if (workspace->candidates == NULL || workspace->capacity < heap_capacity) {
        return COCO80_DECODE_ERR_WORKSPACE;
    }
    if (detections == NULL || detection_capacity < config->max_detections) {
        return COCO80_DECODE_ERR_OUTPUT;
    }

    for (head_id = 0U; head_id < COCO80_HEAD_COUNT; ++head_id) {
        const coco80_quantized_head_t *head = &heads[head_id];
        if (head->data == NULL ||
            head->bytes != coco80_geometry[head_id].expected_bytes ||
            !isfinite(head->scale) || head->scale <= 0.0f ||
            head->zero_point < 0 || head->zero_point > 255) {
            return COCO80_DECODE_ERR_HEAD;
        }
    }

    if (ticks != NULL) {
        phase_start = ticks(ticks_opaque);
    }

    /*
     * A quantized head has only 256 distinct logits.  Build each head's table
     * with the exact scalar routine previously used in the inner loops, then
     * replace roughly 200k expf calls per image with byte-indexed loads.  This
     * is a pure common-subexpression elimination: every float value, strict
     * threshold comparison, tie-break and NMS operation remains unchanged.
     */
    for (head_id = 0U; head_id < COCO80_HEAD_COUNT; ++head_id) {
        uint32_t value;
        for (value = 0U; value < 256U; ++value) {
            sigmoid_lut[head_id][value] =
                coco80_dequant_sigmoid((uint8_t)value, &heads[head_id]);
        }
    }

    for (head_id = 0U; head_id < COCO80_HEAD_COUNT; ++head_id) {
        const coco80_quantized_head_t *head = &heads[head_id];
        const coco80_head_geometry_t *geometry = &coco80_geometry[head_id];
        const float *head_sigmoid_lut = sigmoid_lut[head_id];
        uint32_t grid_y;
        for (grid_y = 0U; grid_y < geometry->height; ++grid_y) {
            uint32_t grid_x;
            for (grid_x = 0U; grid_x < geometry->width; ++grid_x) {
                uint32_t anchor_id;
                for (anchor_id = 0U; anchor_id < COCO80_ANCHORS_PER_HEAD; ++anchor_id) {
                    uint32_t pixel_anchor_index =
                        (grid_y * geometry->width + grid_x) * COCO80_ANCHORS_PER_HEAD +
                        anchor_id;
                    /* Match PyTorch [anchor, y, x] flattening for stable ties. */
                    uint32_t local_source =
                        anchor_id * geometry->width * geometry->height +
                        grid_y * geometry->width + grid_x;
                    uint32_t source_index = geometry->source_base + local_source;
                    uint32_t base = pixel_anchor_index * COCO80_VALUES_PER_ANCHOR;
                    const uint8_t *values = &head->data[base];
                    float objectness = head_sigmoid_lut[values[4]];

                    if (!(objectness > config->confidence_threshold)) {
                        continue;
                    }

                    if (config->multi_label != 0U) {
                        uint32_t class_id;
                        coco80_candidate_t candidate;
                        int box_decoded = 0;
                        for (class_id = 0U; class_id < COCO80_CLASS_COUNT; ++class_id) {
                            float class_probability =
                                head_sigmoid_lut[values[5U + class_id]];
                            float score = objectness * class_probability;
                            if (score > config->confidence_threshold) {
                                if (!box_decoded) {
                                    coco80_make_candidate(
                                        &candidate,
                                        head_sigmoid_lut,
                                        geometry,
                                        values,
                                        score,
                                        source_index,
                                        head_id,
                                        anchor_id,
                                        grid_x,
                                        grid_y,
                                        class_id);
                                    box_decoded = 1;
                                } else {
                                    candidate.score = score;
                                    candidate.class_id = (uint16_t)class_id;
                                }
                                ++qualifying_count;
                                coco80_offer_candidate(
                                    workspace->candidates,
                                    heap_capacity,
                                    &heap_count,
                                    &candidate);
                            }
                        }
                    } else {
                        uint32_t class_id;
                        uint32_t best_class = 0U;
                        float best_probability = head_sigmoid_lut[values[5]];
                        for (class_id = 1U; class_id < COCO80_CLASS_COUNT; ++class_id) {
                            float class_probability =
                                head_sigmoid_lut[values[5U + class_id]];
                            if (class_probability > best_probability) {
                                best_probability = class_probability;
                                best_class = class_id;
                            }
                        }
                        {
                            float score = objectness * best_probability;
                            if (score > config->confidence_threshold) {
                                coco80_candidate_t candidate;
                                coco80_make_candidate(
                                    &candidate,
                                    head_sigmoid_lut,
                                    geometry,
                                    values,
                                    score,
                                    source_index,
                                    head_id,
                                    anchor_id,
                                    grid_x,
                                    grid_y,
                                    best_class);
                                ++qualifying_count;
                                coco80_offer_candidate(
                                    workspace->candidates,
                                    heap_capacity,
                                    &heap_count,
                                    &candidate);
                            }
                        }
                    }
                }
            }
        }
    }

    if (ticks != NULL) {
        uint64_t phase_end = ticks(ticks_opaque);
        timing->candidate_ticks = phase_end - phase_start;
        phase_start = phase_end;
    }

    coco80_sort_best_first(workspace->candidates, heap_count);
    if (ticks != NULL) {
        uint64_t phase_end = ticks(ticks_opaque);
        timing->sort_ticks = phase_end - phase_start;
        phase_start = phase_end;
    }
    {
        uint32_t read_index;
        for (read_index = 0U;
             read_index < heap_count && detection_count < config->max_detections;
             ++read_index) {
            const coco80_candidate_t *candidate = &workspace->candidates[read_index];
            uint32_t accepted_index;
            int suppressed = 0;
            for (accepted_index = 0U; accepted_index < detection_count; ++accepted_index) {
                if ((uint32_t)candidate->class_id == detections[accepted_index].class_id) {
                    ++nms_comparisons;
                    if (coco80_box_iou(candidate, &detections[accepted_index]) >
                        config->iou_threshold) {
                        suppressed = 1;
                        break;
                    }
                }
            }
            if (!suppressed) {
                coco80_write_detection(
                    &detections[detection_count], candidate, letterbox);
                ++detection_count;
            }
        }
    }

    if (ticks != NULL) {
        timing->nms_ticks = ticks(ticks_opaque) - phase_start;
    }

    result->anchors_scanned = COCO80_TOTAL_ANCHORS;
    result->qualifying_candidates = qualifying_count;
    result->nms_input_candidates = heap_count;
    result->detection_count = detection_count;
    result->nms_comparisons = nms_comparisons;
    result->topk_truncated = qualifying_count > heap_capacity ? 1U : 0U;
    return COCO80_DECODE_OK;
}

int coco80_decode_dual_head(
    const coco80_quantized_head_t heads[COCO80_HEAD_COUNT],
    const coco80_letterbox_t *letterbox,
    const coco80_decode_config_t *config,
    coco80_decode_workspace_t *workspace,
    coco80_detection_t *detections,
    uint32_t detection_capacity,
    coco80_decode_result_t *result)
{
    return coco80_decode_dual_head_profiled(
        heads, letterbox, config, workspace, detections,
        detection_capacity, result, NULL, NULL, NULL);
}

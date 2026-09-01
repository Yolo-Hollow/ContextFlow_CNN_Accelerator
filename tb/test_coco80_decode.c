#include "coco80_decode.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            return 1; \
        } \
    } while (0)

static uint8_t p4_tensor[COCO80_P4_TENSOR_BYTES];
static uint8_t p5_tensor[COCO80_P5_TENSOR_BYTES];
static coco80_candidate_t candidate_workspace[COCO80_ACCURACY_MAX_NMS];
static coco80_detection_t detections[COCO80_ACCURACY_MAX_DETECTIONS];

static int close_float(float left, float right, float tolerance)
{
    return fabsf(left - right) <= tolerance;
}

static uint8_t *anchor_values(
    uint8_t *tensor,
    uint32_t width,
    uint32_t grid_x,
    uint32_t grid_y,
    uint32_t anchor_id)
{
    uint32_t source =
        (grid_y * width + grid_x) * COCO80_ANCHORS_PER_HEAD + anchor_id;
    return &tensor[source * COCO80_VALUES_PER_ANCHOR];
}

static void set_anchor(
    uint8_t *tensor,
    uint32_t width,
    uint32_t grid_x,
    uint32_t grid_y,
    uint32_t anchor_id,
    uint8_t objectness,
    uint32_t class_id,
    uint8_t class_value,
    int second_class,
    uint32_t second_class_id)
{
    uint8_t *values = anchor_values(
        tensor, width, grid_x, grid_y, anchor_id);
    values[0] = 128U;
    values[1] = 128U;
    values[2] = 150U;
    values[3] = 150U;
    values[4] = objectness;
    values[5U + class_id] = class_value;
    if (second_class) {
        values[5U + second_class_id] = class_value;
    }
}

static int test_accuracy_decode(void)
{
    coco80_quantized_head_t heads[COCO80_HEAD_COUNT];
    coco80_letterbox_t letterbox;
    coco80_decode_config_t config;
    coco80_decode_workspace_t workspace;
    coco80_decode_result_t result;
    uint32_t source_a =
        2U * COCO80_P4_GRID_WIDTH * COCO80_P4_GRID_HEIGHT +
        10U * COCO80_P4_GRID_WIDTH + 10U;
    uint32_t source_p5 = COCO80_P4_ANCHOR_COUNT +
        1U * COCO80_P5_GRID_WIDTH + 1U;
    int status;

    memset(p4_tensor, 0, sizeof(p4_tensor));
    memset(p5_tensor, 0, sizeof(p5_tensor));
    set_anchor(
        p4_tensor, COCO80_P4_GRID_WIDTH, 10U, 10U, 2U,
        200U, 3U, 190U, 1, 7U);
    set_anchor(
        p4_tensor, COCO80_P4_GRID_WIDTH, 11U, 10U, 2U,
        190U, 3U, 180U, 0, 0U);
    set_anchor(
        p5_tensor, COCO80_P5_GRID_WIDTH, 1U, 1U, 0U,
        180U, 10U, 170U, 0, 0U);

    heads[0].data = p4_tensor;
    heads[0].bytes = sizeof(p4_tensor);
    heads[0].scale = 0.1f;
    heads[0].zero_point = 128;
    heads[1].data = p5_tensor;
    heads[1].bytes = sizeof(p5_tensor);
    heads[1].scale = 0.1f;
    heads[1].zero_point = 128;
    letterbox.original_width = 800U;
    letterbox.original_height = 600U;
    letterbox.scale = 0.52f;
    letterbox.pad_x = 0.0f;
    letterbox.pad_y = 52.0f;
    workspace.candidates = candidate_workspace;
    workspace.capacity = COCO80_ACCURACY_MAX_NMS;

    coco80_decode_config_accuracy(&config);
    CHECK(close_float(config.confidence_threshold, 0.001f, 1e-8f));
    CHECK(close_float(config.iou_threshold, 0.65f, 1e-8f));
    CHECK(config.multi_label == 1U);
    CHECK(config.max_nms == 30000U);
    CHECK(config.max_detections == 300U);
    CHECK(coco80_decode_workspace_elements(&config) == 30000U);

    status = coco80_decode_dual_head(
        heads,
        &letterbox,
        &config,
        &workspace,
        detections,
        COCO80_ACCURACY_MAX_DETECTIONS,
        &result);
    CHECK(status == COCO80_DECODE_OK);
    CHECK(result.anchors_scanned == 2535U);
    CHECK(result.qualifying_candidates == 4U);
    CHECK(result.nms_input_candidates == 4U);
    CHECK(result.detection_count == 3U);
    CHECK(result.topk_truncated == 0U);

    /* Equal-score, same-source classes use class_id as the final tie break. */
    CHECK(detections[0].source_index == source_a);
    CHECK(detections[0].class_id == 3U);
    CHECK(detections[1].source_index == source_a);
    CHECK(detections[1].class_id == 7U);
    CHECK(detections[2].source_index == source_p5);
    CHECK(detections[2].class_id == 10U);
    CHECK(detections[0].coco_category_id == 4U);
    CHECK(detections[2].coco_category_id == 11U);
    CHECK(detections[0].head_id == 0U && detections[0].anchor_id == 2U);
    CHECK(detections[0].grid_x == 10U && detections[0].grid_y == 10U);
    CHECK(detections[2].head_id == 1U && detections[2].anchor_id == 0U);
    CHECK(detections[2].grid_x == 1U && detections[2].grid_y == 1U);

    CHECK(close_float(
        detections[0].original_x1,
        (detections[0].model_x1 - letterbox.pad_x) / letterbox.scale,
        1e-4f));
    CHECK(close_float(
        detections[0].original_y1,
        (detections[0].model_y1 - letterbox.pad_y) / letterbox.scale,
        1e-4f));
    CHECK(detections[0].original_x1 >= 0.0f && detections[0].original_x2 <= 800.0f);
    CHECK(detections[0].original_y1 >= 0.0f && detections[0].original_y2 <= 600.0f);
    return 0;
}

static int test_demo_and_topk(void)
{
    coco80_quantized_head_t heads[COCO80_HEAD_COUNT];
    coco80_letterbox_t letterbox;
    coco80_decode_config_t config;
    coco80_decode_workspace_t workspace;
    coco80_decode_result_t result;
    int status;

    heads[0].data = p4_tensor;
    heads[0].bytes = sizeof(p4_tensor);
    heads[0].scale = 0.1f;
    heads[0].zero_point = 128;
    heads[1].data = p5_tensor;
    heads[1].bytes = sizeof(p5_tensor);
    heads[1].scale = 0.1f;
    heads[1].zero_point = 128;
    letterbox.original_width = COCO80_MODEL_WIDTH;
    letterbox.original_height = COCO80_MODEL_HEIGHT;
    letterbox.scale = 1.0f;
    letterbox.pad_x = 0.0f;
    letterbox.pad_y = 0.0f;
    workspace.candidates = candidate_workspace;
    workspace.capacity = COCO80_ACCURACY_MAX_NMS;

    coco80_decode_config_demo(&config);
    CHECK(close_float(config.confidence_threshold, 0.25f, 1e-8f));
    CHECK(close_float(config.iou_threshold, 0.45f, 1e-8f));
    CHECK(config.multi_label == 0U);
    CHECK(config.max_nms == COCO80_ACCURACY_MAX_NMS);
    CHECK(coco80_decode_workspace_elements(&config) == COCO80_TOTAL_ANCHORS);
    status = coco80_decode_dual_head(
        heads, &letterbox, &config, &workspace,
        detections, COCO80_ACCURACY_MAX_DETECTIONS, &result);
    CHECK(status == COCO80_DECODE_OK);
    CHECK(result.qualifying_candidates == 3U);
    CHECK(result.detection_count == 2U);
    CHECK(detections[0].class_id == 3U); /* class 3 wins the class 3/7 tie. */

    /* Python round(208.5) is ties-to-even: 832x417 becomes 416x208. */
    letterbox.original_width = 832U;
    letterbox.original_height = 417U;
    letterbox.scale = 0.5f;
    letterbox.pad_x = 0.0f;
    letterbox.pad_y = 104.0f;
    status = coco80_decode_dual_head(
        heads, &letterbox, &config, &workspace,
        detections, COCO80_ACCURACY_MAX_DETECTIONS, &result);
    CHECK(status == COCO80_DECODE_OK);

    coco80_decode_config_accuracy(&config);
    config.max_nms = 3U;
    config.max_detections = 3U;
    config.iou_threshold = 1.0f;
    workspace.capacity = 3U;
    status = coco80_decode_dual_head(
        heads, &letterbox, &config, &workspace,
        detections, 3U, &result);
    CHECK(status == COCO80_DECODE_OK);
    CHECK(result.qualifying_candidates == 4U);
    CHECK(result.nms_input_candidates == 3U);
    CHECK(result.detection_count == 3U);
    CHECK(result.topk_truncated == 1U);
    CHECK(detections[0].class_id == 3U);
    CHECK(detections[1].class_id == 7U);
    CHECK(detections[2].class_id == 3U);

    workspace.capacity = 2U;
    CHECK(coco80_decode_dual_head(
        heads, &letterbox, &config, &workspace,
        detections, 3U, &result) == COCO80_DECODE_ERR_WORKSPACE);
    workspace.capacity = 3U;
    heads[1].bytes--;
    CHECK(coco80_decode_dual_head(
        heads, &letterbox, &config, &workspace,
        detections, 3U, &result) == COCO80_DECODE_ERR_HEAD);
    return 0;
}

static int test_torchvision_class_offset_boundary(void)
{
    coco80_quantized_head_t heads[COCO80_HEAD_COUNT];
    coco80_letterbox_t letterbox;
    coco80_decode_config_t config;
    coco80_decode_workspace_t workspace;
    coco80_decode_result_t result;
    uint8_t *first;
    uint8_t *second;

    memset(p4_tensor, 0, sizeof(p4_tensor));
    memset(p5_tensor, 0, sizeof(p5_tensor));
    first = anchor_values(p4_tensor, COCO80_P4_GRID_WIDTH, 14U, 4U, 1U);
    second = anchor_values(p4_tensor, COCO80_P4_GRID_WIDTH, 14U, 4U, 2U);

    /*
     * Real image 885 boundary pair.  Direct-coordinate float32 IoU is
     * 0.650147, while torchvision's class-56 offset arithmetic produces
     * 0.649446.  The canonical host therefore keeps both candidates.
     */
    first[0] = 94U; first[1] = 94U; first[2] = 96U; first[3] = 89U;
    first[4] = 78U; first[5U + 56U] = 89U;
    second[0] = 93U; second[1] = 93U; second[2] = 94U; second[3] = 87U;
    second[4] = 70U; second[5U + 56U] = 86U;

    heads[0].data = p4_tensor;
    heads[0].bytes = sizeof(p4_tensor);
    heads[0].scale = 0.20063039660453796f;
    heads[0].zero_point = 93;
    heads[1].data = p5_tensor;
    heads[1].bytes = sizeof(p5_tensor);
    heads[1].scale = 0.2127869874238968f;
    heads[1].zero_point = 91;
    letterbox.original_width = COCO80_MODEL_WIDTH;
    letterbox.original_height = COCO80_MODEL_HEIGHT;
    letterbox.scale = 1.0f;
    letterbox.pad_x = 0.0f;
    letterbox.pad_y = 0.0f;
    workspace.candidates = candidate_workspace;
    workspace.capacity = COCO80_ACCURACY_MAX_NMS;
    coco80_decode_config_accuracy(&config);

    CHECK(coco80_decode_dual_head(
        heads, &letterbox, &config, &workspace,
        detections, COCO80_ACCURACY_MAX_DETECTIONS, &result) == COCO80_DECODE_OK);
    CHECK(result.qualifying_candidates == 2U);
    CHECK(result.detection_count == 2U);
    CHECK(detections[0].source_index == 794U);
    CHECK(detections[1].source_index == 1470U);
    CHECK(detections[0].class_id == 56U && detections[1].class_id == 56U);
    return 0;
}

static int test_mapping_and_validation(void)
{
    coco80_decode_config_t config;
    CHECK(coco80_to_coco91_category(0U) == 1U);
    CHECK(coco80_to_coco91_category(11U) == 13U);
    CHECK(coco80_to_coco91_category(79U) == 90U);
    CHECK(coco80_to_coco91_category(80U) == 0U);

    coco80_decode_config_accuracy(&config);
    config.max_nms = COCO80_ACCURACY_MAX_NMS + 1U;
    CHECK(coco80_decode_workspace_elements(&config) == 0U);
    return 0;
}

int main(void)
{
    CHECK(sizeof(coco80_candidate_t) == 28U);
    CHECK(COCO80_P4_TENSOR_BYTES == 172380U);
    CHECK(COCO80_P5_TENSOR_BYTES == 43095U);
    CHECK(COCO80_TOTAL_ANCHORS == 2535U);
    CHECK(test_accuracy_decode() == 0);
    CHECK(test_demo_and_topk() == 0);
    CHECK(test_torchvision_class_offset_boundary() == 0);
    CHECK(test_mapping_and_validation() == 0);
    printf("PASS: COCO80 dual-head decode/NMS host tests\n");
    return 0;
}

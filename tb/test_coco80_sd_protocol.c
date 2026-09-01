#include "coco80_sd_protocol.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            return 1; \
        } \
    } while (0)

#define INPUT_PAYLOAD_BYTES (COCO80_MODEL_WIDTH * COCO80_MODEL_HEIGHT * 3U)
#define INPUT_PACKAGE_BYTES (COCO80_SD_HEADER_BYTES + INPUT_PAYLOAD_BYTES)
#define PARAMETER_PAYLOAD_BYTES 64U
#define PARAMETER_PACKAGE_BYTES (COCO80_SD_HEADER_BYTES + PARAMETER_PAYLOAD_BYTES)
#define RAW_HEAD_PAYLOAD_BYTES (COCO80_P4_TENSOR_BYTES + COCO80_P5_TENSOR_BYTES)
#define RAW_HEAD_PACKAGE_BYTES (COCO80_SD_HEADER_BYTES + RAW_HEAD_PAYLOAD_BYTES)
#define TEST_DETECTION_COUNT 2U
#define DETECTION_PAYLOAD_BYTES \
    (TEST_DETECTION_COUNT * COCO80_SD_DETECTION_RECORD_BYTES)
#define DETECTION_PACKAGE_BYTES (COCO80_SD_HEADER_BYTES + DETECTION_PAYLOAD_BYTES)
#define RESULT_DETECTION_BYTES \
    (TEST_DETECTION_COUNT * COCO80_SD_DETECTION_RECORD_BYTES)
#define RESULT_TIMING_BYTES 16U
#define RESULT_PAYLOAD_BYTES (RESULT_DETECTION_BYTES + RESULT_TIMING_BYTES)
#define RESULT_PACKAGE_BYTES (COCO80_SD_HEADER_BYTES + RESULT_PAYLOAD_BYTES)

static uint8_t input_package[INPUT_PACKAGE_BYTES];
static uint8_t parameter_package[PARAMETER_PACKAGE_BYTES];
static uint8_t raw_head_package[RAW_HEAD_PACKAGE_BYTES];
static uint8_t detection_package[DETECTION_PACKAGE_BYTES];
static uint8_t result_package[RESULT_PACKAGE_BYTES];

static void fill_pattern(uint8_t *data, uint32_t bytes, uint8_t seed)
{
    uint32_t index;
    for (index = 0U; index < bytes; ++index) {
        data[index] = (uint8_t)(seed + index * 17U + index / 13U);
    }
}

static void init_common(
    coco80_sd_common_t *common,
    uint32_t magic,
    uint32_t payload_bytes)
{
    memset(common, 0, sizeof(*common));
    common->magic = magic;
    common->header_bytes = COCO80_SD_HEADER_BYTES;
    common->payload_offset = COCO80_SD_HEADER_BYTES;
    common->payload_bytes = payload_bytes;
}

static int build_input(void)
{
    coco80_sd_input_header_t header;
    uint32_t index;
    memset(input_package, 0, sizeof(input_package));
    memset(&header, 0, sizeof(header));
    init_common(&header.common, COCO80_SD_MAGIC_INPUT, INPUT_PAYLOAD_BYTES);
    header.image_id = 42U;
    header.model_width = COCO80_MODEL_WIDTH;
    header.model_height = COCO80_MODEL_HEIGHT;
    header.channels = 3U;
    header.original_width = 640U;
    header.original_height = 480U;
    header.tensor_layout = COCO80_SD_TENSOR_LAYOUT_HWC;
    header.tensor_dtype = COCO80_SD_TENSOR_DTYPE_UINT8;
    header.input_scale_f32 = coco80_sd_float_to_bits(1.0f / 127.0f);
    header.input_zero_point = 0U;
    header.letterbox_scale_f32 = coco80_sd_float_to_bits(0.65f);
    header.pad_x_f32 = coco80_sd_float_to_bits(0.0f);
    header.pad_y_f32 = coco80_sd_float_to_bits(52.0f);
    header.row_stride_bytes = COCO80_MODEL_WIDTH * 3U;
    for (index = 0U; index < 8U; ++index) {
        header.source_sha256[index] = 0x10203040U + index;
    }
    memcpy(input_package, &header, sizeof(header));
    fill_pattern(
        input_package + COCO80_SD_HEADER_BYTES,
        INPUT_PAYLOAD_BYTES,
        0x11U);
    for (index = 0U; index < INPUT_PAYLOAD_BYTES; ++index) {
        input_package[COCO80_SD_HEADER_BYTES + index] &= 0x7fU;
    }
    return coco80_sd_seal_package(input_package, sizeof(input_package));
}

static int build_parameters(void)
{
    coco80_sd_parameter_header_t header;
    uint32_t index;
    uint32_t offset = COCO80_SD_HEADER_BYTES;
    memset(parameter_package, 0, sizeof(parameter_package));
    memset(&header, 0, sizeof(header));
    init_common(
        &header.common, COCO80_SD_MAGIC_PARAMETERS, PARAMETER_PAYLOAD_BYTES);
    header.model_width = COCO80_MODEL_WIDTH;
    header.model_height = COCO80_MODEL_HEIGHT;
    header.class_count = COCO80_CLASS_COUNT;
    header.layer_count = COCO80_SD_PARAMETER_LAYER_COUNT;
    header.weights.offset = offset;
    header.weights.bytes = 16U;
    offset += 16U;
    header.biases.offset = offset;
    header.biases.bytes = 16U;
    offset += 16U;
    header.activation_luts.offset = offset;
    header.activation_luts.bytes = 16U;
    offset += 16U;
    header.quantization.offset = offset;
    header.quantization.bytes = 16U;
    for (index = 0U; index < 8U; ++index) {
        header.model_sha256[index] = 0xA0B0C000U + index;
    }
    fill_pattern(
        parameter_package + COCO80_SD_HEADER_BYTES,
        PARAMETER_PAYLOAD_BYTES,
        0x22U);
    header.weights.crc32 = coco80_sd_crc32(
        parameter_package + header.weights.offset, header.weights.bytes);
    header.biases.crc32 = coco80_sd_crc32(
        parameter_package + header.biases.offset, header.biases.bytes);
    header.activation_luts.crc32 = coco80_sd_crc32(
        parameter_package + header.activation_luts.offset,
        header.activation_luts.bytes);
    header.quantization.crc32 = coco80_sd_crc32(
        parameter_package + header.quantization.offset,
        header.quantization.bytes);
    memcpy(parameter_package, &header, sizeof(header));
    return coco80_sd_seal_package(parameter_package, sizeof(parameter_package));
}

static int build_raw_heads(void)
{
    coco80_sd_raw_head_header_t header;
    uint32_t input_crc = coco80_sd_crc32(input_package, sizeof(input_package));
    uint32_t parameter_crc = coco80_sd_crc32(
        parameter_package, sizeof(parameter_package));
    memset(raw_head_package, 0, sizeof(raw_head_package));
    memset(&header, 0, sizeof(header));
    init_common(&header.common, COCO80_SD_MAGIC_RAW_HEADS, RAW_HEAD_PAYLOAD_BYTES);
    header.model_width = COCO80_MODEL_WIDTH;
    header.model_height = COCO80_MODEL_HEIGHT;
    header.class_count = COCO80_CLASS_COUNT;
    header.values_per_anchor = COCO80_VALUES_PER_ANCHOR;
    header.anchors_per_head = COCO80_ANCHORS_PER_HEAD;
    header.head_count = COCO80_HEAD_COUNT;
    header.p4.width = COCO80_P4_GRID_WIDTH;
    header.p4.height = COCO80_P4_GRID_HEIGHT;
    header.p4.channels = COCO80_HEAD_CHANNELS;
    header.p4.offset = COCO80_SD_HEADER_BYTES;
    header.p4.bytes = COCO80_P4_TENSOR_BYTES;
    header.p4.scale_f32 = coco80_sd_float_to_bits(0.25f);
    header.p4.zero_point = 85U;
    header.p5.width = COCO80_P5_GRID_WIDTH;
    header.p5.height = COCO80_P5_GRID_HEIGHT;
    header.p5.channels = COCO80_HEAD_CHANNELS;
    header.p5.offset = COCO80_SD_HEADER_BYTES + COCO80_P4_TENSOR_BYTES;
    header.p5.bytes = COCO80_P5_TENSOR_BYTES;
    header.p5.scale_f32 = coco80_sd_float_to_bits(0.125f);
    header.p5.zero_point = 80U;
    header.input_package_crc32 = input_crc;
    header.parameter_package_crc32 = parameter_crc;
    fill_pattern(
        raw_head_package + COCO80_SD_HEADER_BYTES,
        RAW_HEAD_PAYLOAD_BYTES,
        0x33U);
    header.p4.crc32 = coco80_sd_crc32(
        raw_head_package + header.p4.offset, header.p4.bytes);
    header.p5.crc32 = coco80_sd_crc32(
        raw_head_package + header.p5.offset, header.p5.bytes);
    memcpy(raw_head_package, &header, sizeof(header));
    return coco80_sd_seal_package(raw_head_package, sizeof(raw_head_package));
}

static int build_detections(void)
{
    coco80_sd_detection_header_t header;
    coco80_sd_detection_record_t records[TEST_DETECTION_COUNT];
    uint32_t index;
    memset(detection_package, 0, sizeof(detection_package));
    memset(&header, 0, sizeof(header));
    memset(records, 0, sizeof(records));
    init_common(
        &header.common, COCO80_SD_MAGIC_DETECTIONS, DETECTION_PAYLOAD_BYTES);
    header.image_id = 42U;
    header.detection_count = TEST_DETECTION_COUNT;
    header.record_bytes = COCO80_SD_DETECTION_RECORD_BYTES;
    header.max_nms = COCO80_ACCURACY_MAX_NMS;
    header.max_detections = COCO80_ACCURACY_MAX_DETECTIONS;
    header.class_count = COCO80_CLASS_COUNT;
    header.coordinate_space = COCO80_SD_COORDINATES_ORIGINAL_XYXY;
    header.raw_head_package_crc32 = coco80_sd_crc32(
        raw_head_package, sizeof(raw_head_package));
    header.input_package_crc32 = coco80_sd_crc32(
        input_package, sizeof(input_package));
    header.records.offset = COCO80_SD_HEADER_BYTES;
    header.records.bytes = sizeof(records);
    header.confidence_threshold_f32 = coco80_sd_float_to_bits(0.001f);
    header.iou_threshold_f32 = coco80_sd_float_to_bits(0.65f);
    header.multi_label = 1U;
    header.nms_kind = COCO80_SD_NMS_CLASS_AWARE;
    header.decode_config_crc32 = 0x12345678U;
    header.preprocess_crc32 = 0x87654321U;
    for (index = 0U; index < TEST_DETECTION_COUNT; ++index) {
        float index_f = (float)index;
        records[index].image_id = 42U;
        records[index].x1_f32 = coco80_sd_float_to_bits(10.0f + index_f);
        records[index].y1_f32 = coco80_sd_float_to_bits(20.0f + index_f);
        records[index].x2_f32 = coco80_sd_float_to_bits(30.0f + index_f);
        records[index].y2_f32 = coco80_sd_float_to_bits(40.0f + index_f);
        records[index].score_f32 = coco80_sd_float_to_bits(0.9f - index_f * 0.1f);
        records[index].class_id = index;
        records[index].coco_category_id = coco80_to_coco91_category(index);
        records[index].source_index = 100U + index;
        records[index].head_id = 0U;
        records[index].anchor_id = 0U;
        records[index].grid_x = 22U + index;
        records[index].grid_y = 3U;
    }
    memcpy(
        detection_package + COCO80_SD_HEADER_BYTES,
        records,
        sizeof(records));
    header.records.crc32 = coco80_sd_crc32(
        detection_package + header.records.offset, header.records.bytes);
    memcpy(detection_package, &header, sizeof(header));
    return coco80_sd_seal_package(detection_package, sizeof(detection_package));
}

static int build_result(void)
{
    coco80_sd_result_header_t header;
    memset(result_package, 0, sizeof(result_package));
    memset(&header, 0, sizeof(header));
    init_common(&header.common, COCO80_SD_MAGIC_RESULT, RESULT_PAYLOAD_BYTES);
    header.run_id_low = 0x89ABCDEFU;
    header.run_id_high = 0x01234567U;
    header.image_count = 1U;
    header.detection_count = TEST_DETECTION_COUNT;
    header.status = COCO80_SD_RESULT_SUCCESS;
    header.error_code = 0U;
    header.clock_hz = 200000000U;
    header.detections.offset = COCO80_SD_HEADER_BYTES;
    header.detections.bytes = RESULT_DETECTION_BYTES;
    header.timings.offset = COCO80_SD_HEADER_BYTES + RESULT_DETECTION_BYTES;
    header.timings.bytes = RESULT_TIMING_BYTES;
    header.input_package_crc32 = coco80_sd_crc32(
        input_package, sizeof(input_package));
    header.parameter_package_crc32 = coco80_sd_crc32(
        parameter_package, sizeof(parameter_package));
    header.raw_head_package_crc32 = coco80_sd_crc32(
        raw_head_package, sizeof(raw_head_package));
    header.detection_package_crc32 = coco80_sd_crc32(
        detection_package, sizeof(detection_package));
    header.software_build_crc32 = 0x11112222U;
    header.hardware_build_crc32 = 0x33334444U;
    memcpy(
        result_package + header.detections.offset,
        detection_package + COCO80_SD_HEADER_BYTES,
        RESULT_DETECTION_BYTES);
    fill_pattern(
        result_package + header.timings.offset,
        RESULT_TIMING_BYTES,
        0x44U);
    header.detections.crc32 = coco80_sd_crc32(
        result_package + header.detections.offset, header.detections.bytes);
    header.timings.crc32 = coco80_sd_crc32(
        result_package + header.timings.offset, header.timings.bytes);
    memcpy(result_package, &header, sizeof(header));
    return coco80_sd_seal_package(result_package, sizeof(result_package));
}

static int build_pipeline(void)
{
    CHECK(build_input() == COCO80_SD_OK);
    CHECK(build_parameters() == COCO80_SD_OK);
    CHECK(build_raw_heads() == COCO80_SD_OK);
    CHECK(build_detections() == COCO80_SD_OK);
    CHECK(build_result() == COCO80_SD_OK);
    return 0;
}

static int validate_pipeline(void)
{
    return coco80_sd_validate_pipeline(
        input_package,
        sizeof(input_package),
        parameter_package,
        sizeof(parameter_package),
        raw_head_package,
        sizeof(raw_head_package),
        detection_package,
        sizeof(detection_package),
        result_package,
        sizeof(result_package));
}

static int validate_pipeline_prevalidated_parameters(uint32_t parameter_crc32)
{
    return coco80_sd_validate_pipeline_prevalidated_parameters(
        input_package,
        sizeof(input_package),
        parameter_crc32,
        raw_head_package,
        sizeof(raw_head_package),
        detection_package,
        sizeof(detection_package),
        result_package,
        sizeof(result_package));
}

static int test_valid_pipeline(void)
{
    coco80_sd_input_header_t input_header;
    coco80_sd_raw_head_header_t raw_header;
    coco80_sd_detection_header_t detection_header;
    coco80_sd_result_header_t result_header;
    uint32_t parameter_crc;
    CHECK(build_pipeline() == 0);
    CHECK(coco80_sd_validate_input(
        input_package, sizeof(input_package), &input_header) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_parameters(
        parameter_package, sizeof(parameter_package), NULL) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_raw_heads(
        raw_head_package, sizeof(raw_head_package), &raw_header) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_detections(
        detection_package, sizeof(detection_package), &detection_header) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_result(
        result_package, sizeof(result_package), &result_header) == COCO80_SD_OK);
    CHECK(validate_pipeline() == COCO80_SD_OK);
    parameter_crc = coco80_sd_crc32(parameter_package, sizeof(parameter_package));
    CHECK(parameter_crc != 0U);
    CHECK(validate_pipeline_prevalidated_parameters(parameter_crc) == COCO80_SD_OK);
    CHECK(validate_pipeline_prevalidated_parameters(0U) ==
          COCO80_SD_ERR_HASH_REFERENCE);
    CHECK(validate_pipeline_prevalidated_parameters(parameter_crc ^ 1U) ==
          COCO80_SD_ERR_LINK);
    CHECK(input_header.image_id == 42U);
    CHECK(raw_header.p4.bytes == COCO80_P4_TENSOR_BYTES);
    CHECK(raw_header.p5.bytes == COCO80_P5_TENSOR_BYTES);
    CHECK(detection_header.detection_count == TEST_DETECTION_COUNT);
    CHECK(result_header.detection_count == TEST_DETECTION_COUNT);
    return 0;
}

static int test_corruption_and_bounds(void)
{
    coco80_sd_input_header_t input_header;
    coco80_sd_parameter_header_t parameter_header;
    coco80_sd_raw_head_header_t raw_header;
    coco80_sd_detection_header_t detection_header;
    coco80_sd_result_header_t result_header;

    CHECK(build_pipeline() == 0);
    input_package[COCO80_SD_HEADER_BYTES + 7U] ^= 0x80U;
    CHECK(coco80_sd_validate_input(
        input_package, sizeof(input_package), NULL) == COCO80_SD_ERR_PAYLOAD_CRC);
    input_package[COCO80_SD_HEADER_BYTES + 7U] ^= 0x80U;
    CHECK(coco80_sd_validate_input(
        input_package, sizeof(input_package), NULL) == COCO80_SD_OK);
    input_package[COCO80_SD_HEADER_BYTES + 7U] = 128U;
    CHECK(coco80_sd_seal_package(
        input_package, sizeof(input_package)) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_input(
        input_package, sizeof(input_package), NULL) == COCO80_SD_ERR_QUANT_RANGE);
    CHECK(build_input() == COCO80_SD_OK);
    CHECK(coco80_sd_validate_input(
        input_package, sizeof(input_package) + 1U, NULL) ==
        COCO80_SD_ERR_TOTAL_SIZE);

    input_package[offsetof(coco80_sd_input_header_t, image_id)] ^= 1U;
    CHECK(coco80_sd_validate_input(
        input_package, sizeof(input_package), NULL) == COCO80_SD_ERR_HEADER_CRC);
    input_package[offsetof(coco80_sd_input_header_t, image_id)] ^= 1U;

    CHECK(build_input() == COCO80_SD_OK);
    memcpy(&input_header, input_package, sizeof(input_header));
    input_header.original_width = 832U;
    input_header.original_height = 417U;
    input_header.letterbox_scale_f32 = coco80_sd_float_to_bits(0.5f);
    input_header.pad_x_f32 = coco80_sd_float_to_bits(0.0f);
    input_header.pad_y_f32 = coco80_sd_float_to_bits(104.0f);
    memcpy(input_package, &input_header, sizeof(input_header));
    CHECK(coco80_sd_seal_package(
        input_package, sizeof(input_package)) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_input(
        input_package, sizeof(input_package), NULL) == COCO80_SD_OK);

    CHECK(build_parameters() == COCO80_SD_OK);
    memcpy(&parameter_header, parameter_package, sizeof(parameter_header));
    parameter_header.biases.offset = parameter_header.weights.offset;
    parameter_header.biases.crc32 = parameter_header.weights.crc32;
    memcpy(parameter_package, &parameter_header, sizeof(parameter_header));
    CHECK(coco80_sd_seal_package(
        parameter_package, sizeof(parameter_package)) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_parameters(
        parameter_package, sizeof(parameter_package), NULL) == COCO80_SD_ERR_OVERLAP);

    CHECK(build_parameters() == COCO80_SD_OK);
    memcpy(&parameter_header, parameter_package, sizeof(parameter_header));
    memset(parameter_header.model_sha256, 0, sizeof(parameter_header.model_sha256));
    memcpy(parameter_package, &parameter_header, sizeof(parameter_header));
    CHECK(coco80_sd_seal_package(
        parameter_package, sizeof(parameter_package)) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_parameters(
        parameter_package, sizeof(parameter_package), NULL) ==
        COCO80_SD_ERR_HASH_REFERENCE);

    CHECK(build_parameters() == COCO80_SD_OK);
    memcpy(&parameter_header, parameter_package, sizeof(parameter_header));
    --parameter_header.weights.bytes;
    parameter_header.weights.crc32 = coco80_sd_crc32(
        parameter_package + parameter_header.weights.offset,
        parameter_header.weights.bytes);
    memcpy(parameter_package, &parameter_header, sizeof(parameter_header));
    CHECK(coco80_sd_seal_package(
        parameter_package, sizeof(parameter_package)) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_parameters(
        parameter_package, sizeof(parameter_package), NULL) == COCO80_SD_ERR_BOUNDS);

    CHECK(build_pipeline() == 0);
    memcpy(&raw_header, raw_head_package, sizeof(raw_header));
    raw_header.p5.offset = RAW_HEAD_PACKAGE_BYTES - 1U;
    memcpy(raw_head_package, &raw_header, sizeof(raw_header));
    CHECK(coco80_sd_seal_package(
        raw_head_package, sizeof(raw_head_package)) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_raw_heads(
        raw_head_package, sizeof(raw_head_package), NULL) == COCO80_SD_ERR_BOUNDS);

    CHECK(build_pipeline() == 0);
    memcpy(&detection_header, detection_package, sizeof(detection_header));
    detection_header.input_package_crc32 ^= 1U;
    memcpy(detection_package, &detection_header, sizeof(detection_header));
    CHECK(coco80_sd_seal_package(
        detection_package, sizeof(detection_package)) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_detections(
        detection_package, sizeof(detection_package), NULL) == COCO80_SD_OK);
    CHECK(validate_pipeline() == COCO80_SD_ERR_LINK);

    CHECK(build_detections() == COCO80_SD_OK);
    memcpy(&detection_header, detection_package, sizeof(detection_header));
    detection_header.confidence_threshold_f32 = coco80_sd_float_to_bits(0.25f);
    detection_header.iou_threshold_f32 = coco80_sd_float_to_bits(0.45f);
    detection_header.multi_label = 0U;
    detection_header.max_nms = COCO80_ACCURACY_MAX_NMS;
    memcpy(detection_package, &detection_header, sizeof(detection_header));
    CHECK(coco80_sd_seal_package(
        detection_package, sizeof(detection_package)) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_detections(
        detection_package, sizeof(detection_package), NULL) == COCO80_SD_OK);

    detection_header.confidence_threshold_f32 = coco80_sd_float_to_bits(0.1f);
    memcpy(detection_package, &detection_header, sizeof(detection_header));
    CHECK(coco80_sd_seal_package(
        detection_package, sizeof(detection_package)) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_detections(
        detection_package, sizeof(detection_package), NULL) == COCO80_SD_ERR_FORMAT);

    CHECK(build_detections() == COCO80_SD_OK);
    {
        coco80_sd_detection_record_t record;
        memcpy(
            &record,
            detection_package + COCO80_SD_HEADER_BYTES,
            sizeof(record));
        record.class_id = COCO80_CLASS_COUNT;
        record.coco_category_id = 0U;
        memcpy(
            detection_package + COCO80_SD_HEADER_BYTES,
            &record,
            sizeof(record));
        memcpy(&detection_header, detection_package, sizeof(detection_header));
        detection_header.records.crc32 = coco80_sd_crc32(
            detection_package + detection_header.records.offset,
            detection_header.records.bytes);
        memcpy(detection_package, &detection_header, sizeof(detection_header));
        CHECK(coco80_sd_seal_package(
            detection_package, sizeof(detection_package)) == COCO80_SD_OK);
        CHECK(coco80_sd_validate_detections(
            detection_package, sizeof(detection_package), NULL) ==
            COCO80_SD_ERR_FORMAT);
    }

    CHECK(build_detections() == COCO80_SD_OK);
    {
        coco80_sd_detection_record_t record;
        memcpy(
            &record,
            detection_package + COCO80_SD_HEADER_BYTES +
                COCO80_SD_DETECTION_RECORD_BYTES,
            sizeof(record));
        record.score_f32 = coco80_sd_float_to_bits(0.95f);
        memcpy(
            detection_package + COCO80_SD_HEADER_BYTES +
                COCO80_SD_DETECTION_RECORD_BYTES,
            &record,
            sizeof(record));
        memcpy(&detection_header, detection_package, sizeof(detection_header));
        detection_header.records.crc32 = coco80_sd_crc32(
            detection_package + detection_header.records.offset,
            detection_header.records.bytes);
        memcpy(detection_package, &detection_header, sizeof(detection_header));
        CHECK(coco80_sd_seal_package(
            detection_package, sizeof(detection_package)) == COCO80_SD_OK);
        CHECK(coco80_sd_validate_detections(
            detection_package, sizeof(detection_package), NULL) ==
            COCO80_SD_ERR_FORMAT);
    }

    CHECK(build_pipeline() == 0);
    result_package[COCO80_SD_HEADER_BYTES + 1U] ^= 0x40U;
    memcpy(&result_header, result_package, sizeof(result_header));
    result_header.detections.crc32 = coco80_sd_crc32(
        result_package + result_header.detections.offset,
        result_header.detections.bytes);
    memcpy(result_package, &result_header, sizeof(result_header));
    CHECK(coco80_sd_seal_package(
        result_package, sizeof(result_package)) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_result(
        result_package, sizeof(result_package), NULL) == COCO80_SD_OK);
    CHECK(validate_pipeline() == COCO80_SD_ERR_LINK);

    CHECK(build_pipeline() == 0);
    {
        coco80_sd_detection_record_t record;
        memcpy(
            &record,
            detection_package + COCO80_SD_HEADER_BYTES,
            sizeof(record));
        record.x2_f32 = coco80_sd_float_to_bits(641.0f);
        memcpy(
            detection_package + COCO80_SD_HEADER_BYTES,
            &record,
            sizeof(record));
        memcpy(&detection_header, detection_package, sizeof(detection_header));
        detection_header.records.crc32 = coco80_sd_crc32(
            detection_package + detection_header.records.offset,
            detection_header.records.bytes);
        memcpy(detection_package, &detection_header, sizeof(detection_header));
        CHECK(coco80_sd_seal_package(
            detection_package, sizeof(detection_package)) == COCO80_SD_OK);
        CHECK(build_result() == COCO80_SD_OK);
        CHECK(coco80_sd_validate_detections(
            detection_package, sizeof(detection_package), NULL) == COCO80_SD_OK);
        CHECK(validate_pipeline() == COCO80_SD_ERR_LINK);
    }

    CHECK(build_pipeline() == 0);
    memcpy(&result_header, result_package, sizeof(result_header));
    result_header.image_count = 0xFFFFFFFFU;
    result_header.detection_count = 0x40000000U;
    result_header.detections.bytes = 0U;
    result_header.timings.offset = COCO80_SD_HEADER_BYTES;
    memcpy(result_package, &result_header, sizeof(result_header));
    CHECK(coco80_sd_seal_package(
        result_package, sizeof(result_package)) == COCO80_SD_OK);
    CHECK(coco80_sd_validate_result(
        result_package, sizeof(result_package), NULL) == COCO80_SD_ERR_FORMAT);
    return 0;
}

int main(void)
{
    static const char known_crc_input[] = "123456789";
    CHECK(sizeof(coco80_sd_input_header_t) == COCO80_SD_HEADER_BYTES);
    CHECK(sizeof(coco80_sd_parameter_header_t) == COCO80_SD_HEADER_BYTES);
    CHECK(sizeof(coco80_sd_raw_head_header_t) == COCO80_SD_HEADER_BYTES);
    CHECK(sizeof(coco80_sd_detection_header_t) == COCO80_SD_HEADER_BYTES);
    CHECK(sizeof(coco80_sd_result_header_t) == COCO80_SD_HEADER_BYTES);
    CHECK(sizeof(coco80_sd_detection_record_t) == COCO80_SD_DETECTION_RECORD_BYTES);
    CHECK(coco80_sd_crc32(known_crc_input, 9U) == 0xCBF43926U);
    CHECK(test_valid_pipeline() == 0);
    CHECK(test_corruption_and_bounds() == 0);
    printf("PASS: COCO80 SD protocol host tests\n");
    return 0;
}

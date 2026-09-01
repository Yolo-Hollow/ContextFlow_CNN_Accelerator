#include "coco80_sd_protocol.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#if defined(__ARM_FEATURE_CRC32)
#include <arm_acle.h>
#endif

typedef char coco80_sd_common_size_check[
    sizeof(coco80_sd_common_t) == 32U ? 1 : -1];
typedef char coco80_sd_float_size_check[sizeof(float) == 4U ? 1 : -1];
typedef char coco80_sd_input_size_check[
    sizeof(coco80_sd_input_header_t) == COCO80_SD_HEADER_BYTES ? 1 : -1];
typedef char coco80_sd_parameter_size_check[
    sizeof(coco80_sd_parameter_header_t) == COCO80_SD_HEADER_BYTES ? 1 : -1];
typedef char coco80_sd_raw_head_size_check[
    sizeof(coco80_sd_raw_head_header_t) == COCO80_SD_HEADER_BYTES ? 1 : -1];
typedef char coco80_sd_detection_header_size_check[
    sizeof(coco80_sd_detection_header_t) == COCO80_SD_HEADER_BYTES ? 1 : -1];
typedef char coco80_sd_detection_record_size_check[
    sizeof(coco80_sd_detection_record_t) == COCO80_SD_DETECTION_RECORD_BYTES ? 1 : -1];
typedef char coco80_sd_result_size_check[
    sizeof(coco80_sd_result_header_t) == COCO80_SD_HEADER_BYTES ? 1 : -1];

#if !defined(__ARM_FEATURE_CRC32)
static uint32_t c8_crc32_table[256];
static uint32_t c8_crc32_table_ready;

static void c8_crc32_initialize(void)
{
    uint32_t value;
    if (c8_crc32_table_ready != 0U) {
        return;
    }
    for (value = 0U; value < 256U; ++value) {
        uint32_t crc = value;
        uint32_t bit;
        for (bit = 0U; bit < 8U; ++bit) {
            crc = (crc >> 1U) ^
                ((0U - (crc & 1U)) & 0xEDB88320U);
        }
        c8_crc32_table[value] = crc;
    }
    c8_crc32_table_ready = 1U;
}
#endif

uint32_t coco80_sd_crc32_extend_state(
    uint32_t state, const void *data, uint32_t bytes)
{
    const uint8_t *input = (const uint8_t *)data;
    if (data == NULL && bytes != 0U) {
        return 0U;
    }
#if defined(__ARM_FEATURE_CRC32)
    while (bytes >= sizeof(uint64_t)) {
        uint64_t value;
        memcpy(&value, input, sizeof(value));
        state = __crc32d(state, value);
        input += sizeof(value);
        bytes -= sizeof(value);
    }
    if (bytes >= sizeof(uint32_t)) {
        uint32_t value;
        memcpy(&value, input, sizeof(value));
        state = __crc32w(state, value);
        input += sizeof(value);
        bytes -= sizeof(value);
    }
    if (bytes >= sizeof(uint16_t)) {
        uint16_t value;
        memcpy(&value, input, sizeof(value));
        state = __crc32h(state, value);
        input += sizeof(value);
        bytes -= sizeof(value);
    }
    if (bytes != 0U) {
        state = __crc32b(state, *input);
    }
#else
    {
        uint32_t index;
    c8_crc32_initialize();
    for (index = 0U; index < bytes; ++index) {
        state = (state >> 8U) ^
            c8_crc32_table[(state ^ input[index]) & 0xFFU];
    }
    }
#endif
    return state;
}

uint32_t coco80_sd_crc32(const void *data, uint32_t bytes)
{
    return coco80_sd_crc32_extend_state(0xFFFFFFFFU, data, bytes) ^
        0xFFFFFFFFU;
}

uint32_t coco80_sd_header_crc32(const void *header, uint32_t header_bytes)
{
    const uint8_t *input = (const uint8_t *)header;
    const uint32_t crc_offset = (uint32_t)offsetof(coco80_sd_common_t, header_crc32);
    const uint32_t zero = 0U;
    uint32_t crc = 0xFFFFFFFFU;

    if (header == NULL || header_bytes < sizeof(coco80_sd_common_t)) {
        return 0U;
    }
    crc = coco80_sd_crc32_extend_state(crc, input, crc_offset);
    crc = coco80_sd_crc32_extend_state(crc, &zero, sizeof(zero));
    crc = coco80_sd_crc32_extend_state(
        crc, input + crc_offset + sizeof(uint32_t),
        header_bytes - crc_offset - sizeof(uint32_t));
    return crc ^ 0xFFFFFFFFU;
}

uint32_t coco80_sd_float_to_bits(float value)
{
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

float coco80_sd_bits_to_float(uint32_t value)
{
    float result;
    memcpy(&result, &value, sizeof(result));
    return result;
}

static int coco80_sd_range_valid(uint32_t offset, uint32_t bytes, uint32_t total)
{
    return offset <= total && bytes <= total - offset;
}

static int coco80_sd_ranges_overlap(
    uint32_t left_offset,
    uint32_t left_bytes,
    uint32_t right_offset,
    uint32_t right_bytes)
{
    if (left_bytes == 0U || right_bytes == 0U) {
        return 0;
    }
    return left_offset < right_offset + right_bytes &&
        right_offset < left_offset + left_bytes;
}

static int coco80_sd_hash_nonzero(const uint32_t hash[8])
{
    uint32_t index;
    uint32_t value = 0U;
    for (index = 0U; index < 8U; ++index) {
        value |= hash[index];
    }
    return value != 0U;
}

static int coco80_sd_valid_letterbox_geometry(
    const coco80_sd_input_header_t *header,
    float letterbox_scale,
    float pad_x,
    float pad_y)
{
    float resized_width = (float)header->original_width * letterbox_scale;
    float resized_height = (float)header->original_height * letterbox_scale;
    float covered_width;
    float covered_height;

    if (!isfinite(resized_width) || !isfinite(resized_height) ||
        resized_width < 0.5f || resized_height < 0.5f ||
        resized_width > (float)COCO80_MODEL_WIDTH + 0.5f ||
        resized_height > (float)COCO80_MODEL_HEIGHT + 0.5f ||
        fabsf(pad_x - floorf(pad_x)) > 1e-4f ||
        fabsf(pad_y - floorf(pad_y)) > 1e-4f ||
        pad_x > (float)COCO80_MODEL_WIDTH * 0.5f ||
        pad_y > (float)COCO80_MODEL_HEIGHT * 0.5f ||
        (resized_width < (float)COCO80_MODEL_WIDTH - 0.5f &&
         resized_height < (float)COCO80_MODEL_HEIGHT - 0.5f)) {
        return 0;
    }
    covered_width = resized_width + pad_x * 2.0f;
    covered_height = resized_height + pad_y * 2.0f;
    return covered_width >= (float)COCO80_MODEL_WIDTH - 1.5f &&
        covered_width <= (float)COCO80_MODEL_WIDTH + 0.5f &&
        covered_height >= (float)COCO80_MODEL_HEIGHT - 1.5f &&
        covered_height <= (float)COCO80_MODEL_HEIGHT + 0.5f;
}

static int coco80_sd_validate_common(
    const void *package,
    uint32_t package_bytes,
    uint32_t expected_magic,
    uint32_t expected_header_bytes,
    coco80_sd_common_t *common_out)
{
    const uint8_t *bytes = (const uint8_t *)package;
    coco80_sd_common_t common;
    uint32_t header_crc;
    uint32_t payload_crc;

    if (package == NULL || package_bytes < sizeof(common)) {
        return COCO80_SD_ERR_ARGUMENT;
    }
    memcpy(&common, package, sizeof(common));
    if (common.magic != expected_magic) {
        return COCO80_SD_ERR_MAGIC;
    }
    if (common.version != COCO80_SD_PROTOCOL_VERSION) {
        return COCO80_SD_ERR_VERSION;
    }
    if (common.header_bytes != expected_header_bytes ||
        common.header_bytes < sizeof(common)) {
        return COCO80_SD_ERR_HEADER_SIZE;
    }
    if (common.total_bytes < common.header_bytes ||
        common.total_bytes != package_bytes) {
        return COCO80_SD_ERR_TOTAL_SIZE;
    }
    if (common.payload_offset != common.header_bytes ||
        !coco80_sd_range_valid(
            common.payload_offset, common.payload_bytes, common.total_bytes) ||
        common.payload_offset + common.payload_bytes != common.total_bytes) {
        return COCO80_SD_ERR_BOUNDS;
    }
    header_crc = coco80_sd_header_crc32(package, common.header_bytes);
    if (header_crc != common.header_crc32) {
        return COCO80_SD_ERR_HEADER_CRC;
    }
    payload_crc = coco80_sd_crc32(
        bytes + common.payload_offset, common.payload_bytes);
    if (payload_crc != common.payload_crc32) {
        return COCO80_SD_ERR_PAYLOAD_CRC;
    }
    if (common_out != NULL) {
        *common_out = common;
    }
    return COCO80_SD_OK;
}

static int coco80_sd_validate_section(
    const uint8_t *package,
    const coco80_sd_common_t *common,
    const coco80_sd_section_t *section,
    int allow_empty)
{
    uint32_t payload_end = common->payload_offset + common->payload_bytes;

    if (section->bytes == 0U) {
        if (!allow_empty || section->offset < common->payload_offset ||
            section->offset > payload_end || section->crc32 != 0U) {
            return COCO80_SD_ERR_BOUNDS;
        }
        return COCO80_SD_OK;
    }
    if (section->offset < common->payload_offset ||
        !coco80_sd_range_valid(section->offset, section->bytes, payload_end)) {
        return COCO80_SD_ERR_BOUNDS;
    }
    if (coco80_sd_crc32(package + section->offset, section->bytes) != section->crc32) {
        return COCO80_SD_ERR_SECTION_CRC;
    }
    return COCO80_SD_OK;
}

static int coco80_sd_validate_head_section(
    const uint8_t *package,
    const coco80_sd_common_t *common,
    const coco80_sd_head_section_t *section,
    uint32_t width,
    uint32_t height,
    uint32_t expected_bytes)
{
    coco80_sd_section_t generic;
    float scale = coco80_sd_bits_to_float(section->scale_f32);

    if (section->width != width || section->height != height ||
        section->channels != COCO80_HEAD_CHANNELS ||
        section->bytes != expected_bytes ||
        !isfinite(scale) || scale <= 0.0f || section->zero_point > 255U) {
        return COCO80_SD_ERR_SHAPE;
    }
    generic.offset = section->offset;
    generic.bytes = section->bytes;
    generic.crc32 = section->crc32;
    return coco80_sd_validate_section(package, common, &generic, 0);
}

int coco80_sd_seal_package(void *package, uint32_t total_bytes)
{
    uint8_t *bytes = (uint8_t *)package;
    coco80_sd_common_t common;

    if (package == NULL || total_bytes < sizeof(common)) {
        return COCO80_SD_ERR_ARGUMENT;
    }
    memcpy(&common, package, sizeof(common));
    if (common.magic == 0U || common.header_bytes < sizeof(common) ||
        common.header_bytes > total_bytes) {
        return COCO80_SD_ERR_HEADER_SIZE;
    }
    common.version = COCO80_SD_PROTOCOL_VERSION;
    common.total_bytes = total_bytes;
    if (common.payload_offset != common.header_bytes ||
        !coco80_sd_range_valid(common.payload_offset, common.payload_bytes, total_bytes) ||
        common.payload_offset + common.payload_bytes != total_bytes) {
        return COCO80_SD_ERR_BOUNDS;
    }
    common.payload_crc32 = coco80_sd_crc32(
        bytes + common.payload_offset, common.payload_bytes);
    common.header_crc32 = 0U;
    memcpy(package, &common, sizeof(common));
    common.header_crc32 = coco80_sd_header_crc32(package, common.header_bytes);
    memcpy(package, &common, sizeof(common));
    return COCO80_SD_OK;
}

int coco80_sd_validate_input(
    const void *package,
    uint32_t package_bytes,
    coco80_sd_input_header_t *header_out)
{
    coco80_sd_input_header_t header;
    coco80_sd_common_t common;
    float input_scale;
    float letterbox_scale;
    float pad_x;
    float pad_y;
    uint32_t expected_bytes = COCO80_MODEL_WIDTH * COCO80_MODEL_HEIGHT * 3U;
    int status = coco80_sd_validate_common(
        package,
        package_bytes,
        COCO80_SD_MAGIC_INPUT,
        sizeof(header),
        &common);
    if (status != COCO80_SD_OK) {
        return status;
    }
    memcpy(&header, package, sizeof(header));
    input_scale = coco80_sd_bits_to_float(header.input_scale_f32);
    letterbox_scale = coco80_sd_bits_to_float(header.letterbox_scale_f32);
    pad_x = coco80_sd_bits_to_float(header.pad_x_f32);
    pad_y = coco80_sd_bits_to_float(header.pad_y_f32);

    if (header.model_width != COCO80_MODEL_WIDTH ||
        header.model_height != COCO80_MODEL_HEIGHT ||
        header.channels != 3U ||
        header.image_id == 0U ||
        header.original_width == 0U || header.original_height == 0U ||
        common.payload_bytes != expected_bytes ||
        header.row_stride_bytes != COCO80_MODEL_WIDTH * 3U) {
        return COCO80_SD_ERR_SHAPE;
    }
    if (header.tensor_layout != COCO80_SD_TENSOR_LAYOUT_HWC ||
        header.tensor_dtype != COCO80_SD_TENSOR_DTYPE_UINT8 ||
        !isfinite(input_scale) || input_scale <= 0.0f ||
        header.input_zero_point > 255U ||
        !isfinite(letterbox_scale) || letterbox_scale <= 0.0f ||
        !isfinite(pad_x) || pad_x < 0.0f ||
        !isfinite(pad_y) || pad_y < 0.0f ||
        header.reserved[0] != 0U || header.reserved[1] != 0U) {
        return COCO80_SD_ERR_FORMAT;
    }
    if (!coco80_sd_valid_letterbox_geometry(
            &header, letterbox_scale, pad_x, pad_y)) {
        return COCO80_SD_ERR_SHAPE;
    }
    if (!coco80_sd_hash_nonzero(header.source_sha256)) {
        return COCO80_SD_ERR_HASH_REFERENCE;
    }
    {
        const uint8_t *tensor = (const uint8_t *)package + common.payload_offset;
        uint32_t index;
        for (index = 0U; index < expected_bytes; ++index) {
            if (tensor[index] > COCO80_SD_INPUT_QUANT_MAX) {
                return COCO80_SD_ERR_QUANT_RANGE;
            }
        }
    }
    if (header_out != NULL) {
        *header_out = header;
    }
    return COCO80_SD_OK;
}

int coco80_sd_validate_parameters(
    const void *package,
    uint32_t package_bytes,
    coco80_sd_parameter_header_t *header_out)
{
    const uint8_t *bytes = (const uint8_t *)package;
    coco80_sd_parameter_header_t header;
    coco80_sd_common_t common;
    const coco80_sd_section_t *sections[4];
    uint32_t left;
    int status = coco80_sd_validate_common(
        package,
        package_bytes,
        COCO80_SD_MAGIC_PARAMETERS,
        sizeof(header),
        &common);
    if (status != COCO80_SD_OK) {
        return status;
    }
    memcpy(&header, package, sizeof(header));
    if (header.model_width != COCO80_MODEL_WIDTH ||
        header.model_height != COCO80_MODEL_HEIGHT ||
        header.class_count != COCO80_CLASS_COUNT ||
        header.layer_count != COCO80_SD_PARAMETER_LAYER_COUNT) {
        return COCO80_SD_ERR_SHAPE;
    }
    if (!coco80_sd_hash_nonzero(header.model_sha256)) {
        return COCO80_SD_ERR_HASH_REFERENCE;
    }
    sections[0] = &header.weights;
    sections[1] = &header.biases;
    sections[2] = &header.activation_luts;
    sections[3] = &header.quantization;
    for (left = 0U; left < 4U; ++left) {
        uint32_t right;
        status = coco80_sd_validate_section(bytes, &common, sections[left], 0);
        if (status != COCO80_SD_OK) {
            return status;
        }
        for (right = left + 1U; right < 4U; ++right) {
            if (coco80_sd_ranges_overlap(
                    sections[left]->offset,
                    sections[left]->bytes,
                    sections[right]->offset,
                    sections[right]->bytes)) {
                return COCO80_SD_ERR_OVERLAP;
            }
        }
    }
    if (header.weights.offset != common.payload_offset ||
        header.biases.offset != header.weights.offset + header.weights.bytes ||
        header.activation_luts.offset !=
            header.biases.offset + header.biases.bytes ||
        header.quantization.offset !=
            header.activation_luts.offset + header.activation_luts.bytes ||
        header.quantization.offset + header.quantization.bytes !=
            common.total_bytes) {
        return COCO80_SD_ERR_BOUNDS;
    }
    if (header_out != NULL) {
        *header_out = header;
    }
    return COCO80_SD_OK;
}

int coco80_sd_validate_raw_heads(
    const void *package,
    uint32_t package_bytes,
    coco80_sd_raw_head_header_t *header_out)
{
    const uint8_t *bytes = (const uint8_t *)package;
    coco80_sd_raw_head_header_t header;
    coco80_sd_common_t common;
    int status = coco80_sd_validate_common(
        package,
        package_bytes,
        COCO80_SD_MAGIC_RAW_HEADS,
        sizeof(header),
        &common);
    if (status != COCO80_SD_OK) {
        return status;
    }
    memcpy(&header, package, sizeof(header));
    if (header.model_width != COCO80_MODEL_WIDTH ||
        header.model_height != COCO80_MODEL_HEIGHT ||
        header.class_count != COCO80_CLASS_COUNT ||
        header.values_per_anchor != COCO80_VALUES_PER_ANCHOR ||
        header.anchors_per_head != COCO80_ANCHORS_PER_HEAD ||
        header.head_count != COCO80_HEAD_COUNT) {
        return COCO80_SD_ERR_SHAPE;
    }
    status = coco80_sd_validate_head_section(
        bytes,
        &common,
        &header.p4,
        COCO80_P4_GRID_WIDTH,
        COCO80_P4_GRID_HEIGHT,
        COCO80_P4_TENSOR_BYTES);
    if (status != COCO80_SD_OK) {
        return status;
    }
    status = coco80_sd_validate_head_section(
        bytes,
        &common,
        &header.p5,
        COCO80_P5_GRID_WIDTH,
        COCO80_P5_GRID_HEIGHT,
        COCO80_P5_TENSOR_BYTES);
    if (status != COCO80_SD_OK) {
        return status;
    }
    if (coco80_sd_ranges_overlap(
            header.p4.offset, header.p4.bytes, header.p5.offset, header.p5.bytes)) {
        return COCO80_SD_ERR_OVERLAP;
    }
    if (header.p4.offset != common.payload_offset ||
        header.p5.offset != header.p4.offset + header.p4.bytes ||
        header.p5.offset + header.p5.bytes != common.total_bytes) {
        return COCO80_SD_ERR_BOUNDS;
    }
    if (header.input_package_crc32 == 0U ||
        header.parameter_package_crc32 == 0U) {
        return COCO80_SD_ERR_HASH_REFERENCE;
    }
    if (header_out != NULL) {
        *header_out = header;
    }
    return COCO80_SD_OK;
}

int coco80_sd_validate_detections(
    const void *package,
    uint32_t package_bytes,
    coco80_sd_detection_header_t *header_out)
{
    const uint8_t *bytes = (const uint8_t *)package;
    coco80_sd_detection_header_t header;
    coco80_sd_common_t common;
    float confidence;
    float iou;
    uint32_t expected_bytes;
    int accuracy_profile;
    int demo_profile;
    int status = coco80_sd_validate_common(
        package,
        package_bytes,
        COCO80_SD_MAGIC_DETECTIONS,
        sizeof(header),
        &common);
    if (status != COCO80_SD_OK) {
        return status;
    }
    memcpy(&header, package, sizeof(header));
    if (header.record_bytes != COCO80_SD_DETECTION_RECORD_BYTES ||
        header.max_nms == 0U ||
        header.max_nms > COCO80_ACCURACY_MAX_NMS ||
        header.max_detections == 0U ||
        header.max_detections > COCO80_ACCURACY_MAX_DETECTIONS ||
        header.max_detections > header.max_nms ||
        header.detection_count > header.max_detections ||
        header.class_count != COCO80_CLASS_COUNT || header.image_id == 0U) {
        return COCO80_SD_ERR_SHAPE;
    }
    expected_bytes = header.detection_count * header.record_bytes;
    if (header.records.bytes != expected_bytes) {
        return COCO80_SD_ERR_SHAPE;
    }
    if (header.records.offset != common.payload_offset ||
        header.records.bytes != common.payload_bytes) {
        return COCO80_SD_ERR_BOUNDS;
    }
    status = coco80_sd_validate_section(bytes, &common, &header.records, 1);
    if (status != COCO80_SD_OK) {
        return status;
    }
    confidence = coco80_sd_bits_to_float(header.confidence_threshold_f32);
    iou = coco80_sd_bits_to_float(header.iou_threshold_f32);
    accuracy_profile =
        fabsf(confidence - 0.001f) <= 1e-8f &&
        fabsf(iou - 0.65f) <= 1e-7f &&
        header.multi_label == 1U &&
        header.max_nms == COCO80_ACCURACY_MAX_NMS &&
        header.max_detections == COCO80_ACCURACY_MAX_DETECTIONS;
    demo_profile =
        fabsf(confidence - 0.25f) <= 1e-8f &&
        fabsf(iou - 0.45f) <= 1e-7f &&
        header.multi_label == 0U &&
        header.max_nms == COCO80_ACCURACY_MAX_NMS &&
        header.max_detections == COCO80_ACCURACY_MAX_DETECTIONS;
    if (header.coordinate_space != COCO80_SD_COORDINATES_ORIGINAL_XYXY ||
        !isfinite(confidence) || confidence < 0.0f || confidence > 1.0f ||
        !isfinite(iou) || iou < 0.0f || iou > 1.0f ||
        header.multi_label > 1U ||
        header.nms_kind != COCO80_SD_NMS_CLASS_AWARE ||
        (!accuracy_profile && !demo_profile)) {
        return COCO80_SD_ERR_FORMAT;
    }
    if (header.raw_head_package_crc32 == 0U ||
        header.input_package_crc32 == 0U ||
        header.decode_config_crc32 == 0U ||
        header.preprocess_crc32 == 0U) {
        return COCO80_SD_ERR_HASH_REFERENCE;
    }
    {
        uint32_t index;
        for (index = 0U; index < 6U; ++index) {
            if (header.reserved[index] != 0U) {
                return COCO80_SD_ERR_FORMAT;
            }
        }
    }
    {
        uint32_t index;
        float previous_score = 0.0f;
        uint32_t previous_source = 0U;
        uint32_t previous_class = 0U;
        int have_previous = 0;
        for (index = 0U; index < header.detection_count; ++index) {
            coco80_sd_detection_record_t record;
            float x1;
            float y1;
            float x2;
            float y2;
            float score;
            uint32_t expected_source;
            uint32_t grid_width;
            uint32_t grid_height;
            uint32_t source_base;
            uint32_t reserved_index;
            memcpy(
                &record,
                bytes + header.records.offset + index * header.record_bytes,
                sizeof(record));
            x1 = coco80_sd_bits_to_float(record.x1_f32);
            y1 = coco80_sd_bits_to_float(record.y1_f32);
            x2 = coco80_sd_bits_to_float(record.x2_f32);
            y2 = coco80_sd_bits_to_float(record.y2_f32);
            score = coco80_sd_bits_to_float(record.score_f32);
            if (record.image_id != header.image_id ||
                !isfinite(x1) || !isfinite(y1) ||
                !isfinite(x2) || !isfinite(y2) ||
                !isfinite(score) || x1 < 0.0f || y1 < 0.0f ||
                x2 < x1 || y2 < y1 ||
                !(score > confidence) || score > 1.0f ||
                record.class_id >= COCO80_CLASS_COUNT ||
                record.coco_category_id !=
                    coco80_to_coco91_category(record.class_id) ||
                record.head_id >= COCO80_HEAD_COUNT ||
                record.anchor_id >= COCO80_ANCHORS_PER_HEAD) {
                return COCO80_SD_ERR_FORMAT;
            }
            if (record.head_id == 0U) {
                grid_width = COCO80_P4_GRID_WIDTH;
                grid_height = COCO80_P4_GRID_HEIGHT;
                source_base = 0U;
            } else {
                grid_width = COCO80_P5_GRID_WIDTH;
                grid_height = COCO80_P5_GRID_HEIGHT;
                source_base = COCO80_P4_ANCHOR_COUNT;
            }
            expected_source = source_base +
                record.anchor_id * grid_width * grid_height +
                record.grid_y * grid_width + record.grid_x;
            if (record.grid_x >= grid_width || record.grid_y >= grid_height ||
                record.source_index != expected_source) {
                return COCO80_SD_ERR_FORMAT;
            }
            if (have_previous &&
                (score > previous_score ||
                 (score == previous_score &&
                  (record.source_index < previous_source ||
                   (record.source_index == previous_source &&
                    record.class_id < previous_class))))) {
                return COCO80_SD_ERR_FORMAT;
            }
            for (reserved_index = 0U; reserved_index < 3U; ++reserved_index) {
                if (record.reserved[reserved_index] != 0U) {
                    return COCO80_SD_ERR_FORMAT;
                }
            }
            previous_score = score;
            previous_source = record.source_index;
            previous_class = record.class_id;
            have_previous = 1;
        }
    }
    if (header_out != NULL) {
        *header_out = header;
    }
    return COCO80_SD_OK;
}

int coco80_sd_validate_result(
    const void *package,
    uint32_t package_bytes,
    coco80_sd_result_header_t *header_out)
{
    const uint8_t *bytes = (const uint8_t *)package;
    coco80_sd_result_header_t header;
    coco80_sd_common_t common;
    int status = coco80_sd_validate_common(
        package,
        package_bytes,
        COCO80_SD_MAGIC_RESULT,
        sizeof(header),
        &common);
    if (status != COCO80_SD_OK) {
        return status;
    }
    memcpy(&header, package, sizeof(header));
    if (header.image_count == 0U ||
        (header.status != COCO80_SD_RESULT_SUCCESS &&
         header.status != COCO80_SD_RESULT_FAILURE) ||
        (header.status == COCO80_SD_RESULT_SUCCESS && header.error_code != 0U) ||
        (header.status == COCO80_SD_RESULT_FAILURE && header.error_code == 0U) ||
        header.clock_hz == 0U || header.result_flags != 0U ||
        (header.run_id_low == 0U && header.run_id_high == 0U) ||
        (uint64_t)header.detection_count >
            (uint64_t)header.image_count * COCO80_ACCURACY_MAX_DETECTIONS ||
        (uint64_t)header.detections.bytes !=
            (uint64_t)header.detection_count *
                COCO80_SD_DETECTION_RECORD_BYTES) {
        return COCO80_SD_ERR_FORMAT;
    }
    status = coco80_sd_validate_section(bytes, &common, &header.detections, 1);
    if (status != COCO80_SD_OK) {
        return status;
    }
    status = coco80_sd_validate_section(bytes, &common, &header.timings, 1);
    if (status != COCO80_SD_OK) {
        return status;
    }
    if (coco80_sd_ranges_overlap(
            header.detections.offset,
            header.detections.bytes,
            header.timings.offset,
            header.timings.bytes)) {
        return COCO80_SD_ERR_OVERLAP;
    }
    if (header.detections.offset != common.payload_offset ||
        header.timings.offset !=
            header.detections.offset + header.detections.bytes ||
        header.timings.offset + header.timings.bytes != common.total_bytes) {
        return COCO80_SD_ERR_BOUNDS;
    }
    if (header.input_package_crc32 == 0U ||
        header.parameter_package_crc32 == 0U ||
        header.raw_head_package_crc32 == 0U ||
        header.detection_package_crc32 == 0U ||
        header.software_build_crc32 == 0U ||
        header.hardware_build_crc32 == 0U) {
        return COCO80_SD_ERR_HASH_REFERENCE;
    }
    {
        uint32_t index;
        for (index = 0U; index < 4U; ++index) {
            if (header.reserved[index] != 0U) {
                return COCO80_SD_ERR_FORMAT;
            }
        }
    }
    if (header_out != NULL) {
        *header_out = header;
    }
    return COCO80_SD_OK;
}

static int coco80_sd_validate_pipeline_links(
    const coco80_sd_input_header_t *input_header,
    uint32_t input_crc,
    uint32_t parameter_crc,
    const coco80_sd_raw_head_header_t *raw_header,
    uint32_t raw_crc,
    const void *detection_package,
    const coco80_sd_detection_header_t *detection_header,
    uint32_t detection_crc,
    const void *result_package,
    const coco80_sd_result_header_t *result_header)
{
    if (parameter_crc == 0U ||
        raw_header->input_package_crc32 != input_crc ||
        raw_header->parameter_package_crc32 != parameter_crc ||
        detection_header->input_package_crc32 != input_crc ||
        detection_header->raw_head_package_crc32 != raw_crc ||
        result_header->input_package_crc32 != input_crc ||
        result_header->parameter_package_crc32 != parameter_crc ||
        result_header->raw_head_package_crc32 != raw_crc ||
        result_header->detection_package_crc32 != detection_crc) {
        return COCO80_SD_ERR_LINK;
    }
    if (detection_header->image_id != input_header->image_id ||
        result_header->image_count != 1U ||
        result_header->detection_count != detection_header->detection_count ||
        result_header->detections.bytes != detection_header->records.bytes ||
        result_header->detections.crc32 != detection_header->records.crc32 ||
        memcmp(
            (const uint8_t *)result_package + result_header->detections.offset,
            (const uint8_t *)detection_package + detection_header->records.offset,
            detection_header->records.bytes) != 0) {
        return COCO80_SD_ERR_LINK;
    }
    {
        uint32_t index;
        for (index = 0U; index < detection_header->detection_count; ++index) {
            coco80_sd_detection_record_t record;
            float x2;
            float y2;
            memcpy(
                &record,
                (const uint8_t *)detection_package +
                    detection_header->records.offset +
                    index * detection_header->record_bytes,
                sizeof(record));
            x2 = coco80_sd_bits_to_float(record.x2_f32);
            y2 = coco80_sd_bits_to_float(record.y2_f32);
            if (x2 > (float)input_header->original_width ||
                y2 > (float)input_header->original_height) {
                return COCO80_SD_ERR_LINK;
            }
        }
    }
    return COCO80_SD_OK;
}

int coco80_sd_validate_pipeline_prevalidated_parameters(
    const void *input_package,
    uint32_t input_bytes,
    uint32_t parameter_package_crc32,
    const void *raw_head_package,
    uint32_t raw_head_bytes,
    const void *detection_package,
    uint32_t detection_bytes,
    const void *result_package,
    uint32_t result_bytes)
{
    coco80_sd_input_header_t input_header;
    coco80_sd_raw_head_header_t raw_header;
    coco80_sd_detection_header_t detection_header;
    coco80_sd_result_header_t result_header;
    uint32_t input_crc;
    uint32_t raw_crc;
    uint32_t detection_crc;
    int status;

    if (parameter_package_crc32 == 0U) {
        return COCO80_SD_ERR_HASH_REFERENCE;
    }
    status = coco80_sd_validate_input(input_package, input_bytes, &input_header);
    if (status != COCO80_SD_OK) return status;
    status = coco80_sd_validate_raw_heads(raw_head_package, raw_head_bytes, &raw_header);
    if (status != COCO80_SD_OK) return status;
    status = coco80_sd_validate_detections(
        detection_package, detection_bytes, &detection_header);
    if (status != COCO80_SD_OK) return status;
    status = coco80_sd_validate_result(result_package, result_bytes, &result_header);
    if (status != COCO80_SD_OK) return status;

    input_crc = coco80_sd_crc32(input_package, input_header.common.total_bytes);
    raw_crc = coco80_sd_crc32(raw_head_package, raw_header.common.total_bytes);
    detection_crc = coco80_sd_crc32(
        detection_package, detection_header.common.total_bytes);
    return coco80_sd_validate_pipeline_links(
        &input_header, input_crc, parameter_package_crc32,
        &raw_header, raw_crc,
        detection_package, &detection_header, detection_crc,
        result_package, &result_header);
}

int coco80_sd_validate_pipeline(
    const void *input_package,
    uint32_t input_bytes,
    const void *parameter_package,
    uint32_t parameter_bytes,
    const void *raw_head_package,
    uint32_t raw_head_bytes,
    const void *detection_package,
    uint32_t detection_bytes,
    const void *result_package,
    uint32_t result_bytes)
{
    coco80_sd_input_header_t input_header;
    coco80_sd_parameter_header_t parameter_header;
    coco80_sd_raw_head_header_t raw_header;
    coco80_sd_detection_header_t detection_header;
    coco80_sd_result_header_t result_header;
    uint32_t input_crc;
    uint32_t parameter_crc;
    uint32_t raw_crc;
    uint32_t detection_crc;
    int status;

    status = coco80_sd_validate_input(input_package, input_bytes, &input_header);
    if (status != COCO80_SD_OK) return status;
    status = coco80_sd_validate_parameters(
        parameter_package, parameter_bytes, &parameter_header);
    if (status != COCO80_SD_OK) return status;
    status = coco80_sd_validate_raw_heads(raw_head_package, raw_head_bytes, &raw_header);
    if (status != COCO80_SD_OK) return status;
    status = coco80_sd_validate_detections(
        detection_package, detection_bytes, &detection_header);
    if (status != COCO80_SD_OK) return status;
    status = coco80_sd_validate_result(result_package, result_bytes, &result_header);
    if (status != COCO80_SD_OK) return status;

    input_crc = coco80_sd_crc32(input_package, input_header.common.total_bytes);
    parameter_crc = coco80_sd_crc32(
        parameter_package, parameter_header.common.total_bytes);
    raw_crc = coco80_sd_crc32(raw_head_package, raw_header.common.total_bytes);
    detection_crc = coco80_sd_crc32(
        detection_package, detection_header.common.total_bytes);
    return coco80_sd_validate_pipeline_links(
        &input_header, input_crc, parameter_crc,
        &raw_header, raw_crc,
        detection_package, &detection_header, detection_crc,
        result_package, &result_header);
}

#ifndef COCO80_SD_PROTOCOL_H
#define COCO80_SD_PROTOCOL_H

#include <stdint.h>

#include "coco80_decode.h"

#ifdef __cplusplus
extern "C" {
#endif

#define COCO80_SD_PROTOCOL_VERSION 1U
#define COCO80_SD_HEADER_BYTES 128U
#define COCO80_SD_DETECTION_RECORD_BYTES 64U
#define COCO80_SD_PARAMETER_LAYER_COUNT 13U
#define COCO80_SD_INPUT_QUANT_MAX 127U

#define COCO80_SD_FOURCC(a, b, c, d) \
    ((uint32_t)(uint8_t)(a) | ((uint32_t)(uint8_t)(b) << 8) | \
     ((uint32_t)(uint8_t)(c) << 16) | ((uint32_t)(uint8_t)(d) << 24))

#define COCO80_SD_MAGIC_INPUT COCO80_SD_FOURCC('C', '8', 'I', 'N')
#define COCO80_SD_MAGIC_PARAMETERS COCO80_SD_FOURCC('C', '8', 'P', 'A')
#define COCO80_SD_MAGIC_RAW_HEADS COCO80_SD_FOURCC('C', '8', 'R', 'H')
#define COCO80_SD_MAGIC_DETECTIONS COCO80_SD_FOURCC('C', '8', 'D', 'T')
#define COCO80_SD_MAGIC_RESULT COCO80_SD_FOURCC('C', '8', 'R', 'S')

#define COCO80_SD_TENSOR_LAYOUT_HWC 1U
#define COCO80_SD_TENSOR_DTYPE_UINT8 1U
#define COCO80_SD_COORDINATES_ORIGINAL_XYXY 1U
#define COCO80_SD_NMS_CLASS_AWARE 1U

#define COCO80_SD_RESULT_SUCCESS 0U
#define COCO80_SD_RESULT_FAILURE 1U

typedef enum {
    COCO80_SD_OK = 0,
    COCO80_SD_ERR_ARGUMENT = -1,
    COCO80_SD_ERR_MAGIC = -2,
    COCO80_SD_ERR_VERSION = -3,
    COCO80_SD_ERR_HEADER_SIZE = -4,
    COCO80_SD_ERR_TOTAL_SIZE = -5,
    COCO80_SD_ERR_BOUNDS = -6,
    COCO80_SD_ERR_HEADER_CRC = -7,
    COCO80_SD_ERR_PAYLOAD_CRC = -8,
    COCO80_SD_ERR_SHAPE = -9,
    COCO80_SD_ERR_FORMAT = -10,
    COCO80_SD_ERR_SECTION_CRC = -11,
    COCO80_SD_ERR_OVERLAP = -12,
    COCO80_SD_ERR_HASH_REFERENCE = -13,
    COCO80_SD_ERR_LINK = -14,
    COCO80_SD_ERR_QUANT_RANGE = -15
} coco80_sd_status_t;

/* All wire fields are little-endian uint32 values. */
typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t header_bytes;
    uint32_t total_bytes;
    uint32_t payload_offset;
    uint32_t payload_bytes;
    uint32_t payload_crc32;
    uint32_t header_crc32;
} coco80_sd_common_t;

typedef struct {
    uint32_t offset;
    uint32_t bytes;
    uint32_t crc32;
} coco80_sd_section_t;

typedef struct {
    coco80_sd_common_t common;
    uint32_t image_id;
    uint32_t model_width;
    uint32_t model_height;
    uint32_t channels;
    uint32_t original_width;
    uint32_t original_height;
    uint32_t tensor_layout;
    uint32_t tensor_dtype;
    uint32_t input_scale_f32;
    uint32_t input_zero_point;
    uint32_t letterbox_scale_f32;
    uint32_t pad_x_f32;
    uint32_t pad_y_f32;
    uint32_t row_stride_bytes;
    uint32_t source_sha256[8];
    uint32_t reserved[2];
} coco80_sd_input_header_t;

typedef struct {
    coco80_sd_common_t common;
    uint32_t model_width;
    uint32_t model_height;
    uint32_t class_count;
    uint32_t layer_count;
    coco80_sd_section_t weights;
    coco80_sd_section_t biases;
    coco80_sd_section_t activation_luts;
    coco80_sd_section_t quantization;
    uint32_t model_sha256[8];
} coco80_sd_parameter_header_t;

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t channels;
    uint32_t offset;
    uint32_t bytes;
    uint32_t scale_f32;
    uint32_t zero_point;
    uint32_t crc32;
} coco80_sd_head_section_t;

typedef struct {
    coco80_sd_common_t common;
    uint32_t model_width;
    uint32_t model_height;
    uint32_t class_count;
    uint32_t values_per_anchor;
    uint32_t anchors_per_head;
    uint32_t head_count;
    coco80_sd_head_section_t p4;
    coco80_sd_head_section_t p5;
    uint32_t input_package_crc32;
    uint32_t parameter_package_crc32;
} coco80_sd_raw_head_header_t;

/* Fixed 64-byte record. Floating-point values are stored as IEEE-754 bits. */
typedef struct {
    uint32_t image_id;
    uint32_t x1_f32;
    uint32_t y1_f32;
    uint32_t x2_f32;
    uint32_t y2_f32;
    uint32_t score_f32;
    uint32_t class_id;
    uint32_t coco_category_id;
    uint32_t source_index;
    uint32_t head_id;
    uint32_t anchor_id;
    uint32_t grid_x;
    uint32_t grid_y;
    uint32_t reserved[3];
} coco80_sd_detection_record_t;

typedef struct {
    coco80_sd_common_t common;
    uint32_t image_id;
    uint32_t detection_count;
    uint32_t record_bytes;
    uint32_t max_nms;
    uint32_t max_detections;
    uint32_t class_count;
    uint32_t coordinate_space;
    uint32_t raw_head_package_crc32;
    uint32_t input_package_crc32;
    coco80_sd_section_t records;
    uint32_t confidence_threshold_f32;
    uint32_t iou_threshold_f32;
    uint32_t multi_label;
    uint32_t nms_kind;
    uint32_t decode_config_crc32;
    uint32_t preprocess_crc32;
    uint32_t reserved[6];
} coco80_sd_detection_header_t;

typedef struct {
    coco80_sd_common_t common;
    uint32_t run_id_low;
    uint32_t run_id_high;
    uint32_t image_count;
    uint32_t detection_count;
    uint32_t status;
    uint32_t error_code;
    uint32_t clock_hz;
    uint32_t result_flags;
    coco80_sd_section_t detections;
    coco80_sd_section_t timings;
    uint32_t input_package_crc32;
    uint32_t parameter_package_crc32;
    uint32_t raw_head_package_crc32;
    uint32_t detection_package_crc32;
    uint32_t software_build_crc32;
    uint32_t hardware_build_crc32;
    uint32_t reserved[4];
} coco80_sd_result_header_t;

uint32_t coco80_sd_crc32(const void *data, uint32_t bytes);
uint32_t coco80_sd_crc32_extend_state(
    uint32_t state, const void *data, uint32_t bytes);
uint32_t coco80_sd_header_crc32(const void *header, uint32_t header_bytes);
uint32_t coco80_sd_float_to_bits(float value);
float coco80_sd_bits_to_float(uint32_t value);

/*
 * Seal a fully populated package.  The caller must set magic, header_bytes,
 * payload_offset, and payload_bytes first.  This function fills version,
 * total_bytes, payload_crc32, and header_crc32.  Per-section CRC fields must be
 * populated before sealing.
 */
int coco80_sd_seal_package(void *package, uint32_t total_bytes);

int coco80_sd_validate_input(
    const void *package,
    uint32_t package_bytes,
    coco80_sd_input_header_t *header_out);
int coco80_sd_validate_parameters(
    const void *package,
    uint32_t package_bytes,
    coco80_sd_parameter_header_t *header_out);
int coco80_sd_validate_raw_heads(
    const void *package,
    uint32_t package_bytes,
    coco80_sd_raw_head_header_t *header_out);
int coco80_sd_validate_detections(
    const void *package,
    uint32_t package_bytes,
    coco80_sd_detection_header_t *header_out);
int coco80_sd_validate_result(
    const void *package,
    uint32_t package_bytes,
    coco80_sd_result_header_t *header_out);

/*
 * Validate every package plus the CRC reference chain between packages.
 * This single-image pipeline also requires matching image/count metadata and
 * an exact copy of the detection records in the result package.
 */
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
    uint32_t result_bytes);

/*
 * Validate a single-image chain against a parameter package that was already
 * fully validated and hashed when a persistent session was initialized.
 * The supplied CRC remains part of every raw/result link check, but the large
 * immutable parameter payload is not rescanned for each image.
 */
int coco80_sd_validate_pipeline_prevalidated_parameters(
    const void *input_package,
    uint32_t input_bytes,
    uint32_t parameter_package_crc32,
    const void *raw_head_package,
    uint32_t raw_head_bytes,
    const void *detection_package,
    uint32_t detection_bytes,
    const void *result_package,
    uint32_t result_bytes);

#ifdef __cplusplus
}
#endif

#endif

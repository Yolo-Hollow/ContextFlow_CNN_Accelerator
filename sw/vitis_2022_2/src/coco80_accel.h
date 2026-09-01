#ifndef COCO80_ACCEL_H
#define COCO80_ACCEL_H

#include "accel_runtime_v2.h"
#include "coco80_decode.h"
#include "coco80_sd_protocol.h"
#include "coco80_tensor_ops.h"

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define COCO80_ACCEL_LAYER_COUNT 13U
#define COCO80_ACCEL_CONFIG_MAGIC COCO80_SD_FOURCC('C', '8', 'C', 'F')
#define COCO80_ACCEL_CONFIG_VERSION 1U
#define COCO80_ACCEL_PARAMETER_ALIGNMENT 64U
#define COCO80_ACCEL_RELEASE_STREAM_CONFIG 0xBFU
#define COCO80_ACCEL_A0_PREPACKED_STREAM_CONFIG 0x29U

#define COCO80_ACCEL_INPUT_PACKAGE_BYTES \
    (COCO80_SD_HEADER_BYTES + COCO80_MODEL_WIDTH * COCO80_MODEL_HEIGHT * 3U)
#define COCO80_ACCEL_RAW_PACKAGE_BYTES \
    (COCO80_SD_HEADER_BYTES + COCO80_P4_TENSOR_BYTES + COCO80_P5_TENSOR_BYTES)
#define COCO80_ACCEL_DETECTION_PACKAGE_BYTES \
    (COCO80_SD_HEADER_BYTES + \
     COCO80_ACCURACY_MAX_DETECTIONS * COCO80_SD_DETECTION_RECORD_BYTES)
#define COCO80_ACCEL_TIMING_RECORD_BYTES 64U
#define COCO80_ACCEL_LAYER_TELEMETRY_BYTES 128U
#define COCO80_ACCEL_EXTENDED_TIMING_BYTES 1984U
#define COCO80_ACCEL_RESULT_PACKAGE_BYTES \
    (COCO80_ACCEL_DETECTION_PACKAGE_BYTES + COCO80_ACCEL_TIMING_RECORD_BYTES)
#define COCO80_ACCEL_WORKSPACE_BYTES 5093824U

typedef enum {
    COCO80_ACCEL_MODE_ACCURACY = 0,
    COCO80_ACCEL_MODE_PRODUCT = 1,
    COCO80_ACCEL_MODE_PERFORMANCE = 2
} coco80_accel_mode_t;

typedef enum {
    COCO80_ACCEL_OUTPUT_RAW = 0,
    COCO80_ACCEL_OUTPUT_DETECTIONS = 1,
    COCO80_ACCEL_OUTPUT_TIMING = 2
} coco80_accel_output_kind_t;

typedef enum {
    COCO80_ACCEL_DECODE_ACCURACY = 0,
    COCO80_ACCEL_DECODE_DEMO = 1
} coco80_accel_decode_profile_t;

typedef enum {
    COCO80_ACCEL_LAYER_INPUT_RAW_HWC = 0,
    COCO80_ACCEL_LAYER_INPUT_A0_PREPACKED = 1
} coco80_accel_layer_input_mode_t;

typedef struct {
    uint32_t output_kind;
    uint32_t decode_profile;
} coco80_accel_infer_options_t;

typedef enum {
    COCO80_ACCEL_OK = 0,
    COCO80_ACCEL_ERR_ARGUMENT = -200,
    COCO80_ACCEL_ERR_PLAN = -201,
    COCO80_ACCEL_ERR_CONFIG = -202,
    COCO80_ACCEL_ERR_WORKSPACE = -203,
    COCO80_ACCEL_ERR_PARAMETER = -204,
    COCO80_ACCEL_ERR_PARAMETER_CRC = -205,
    COCO80_ACCEL_ERR_ABI = -206,
    COCO80_ACCEL_ERR_CLOCK = -207,
    COCO80_ACCEL_ERR_RECOVERY = -208,
    COCO80_ACCEL_ERR_INPUT = -209,
    COCO80_ACCEL_ERR_DISPATCH = -210,
    COCO80_ACCEL_ERR_COUNTER = -211,
    COCO80_ACCEL_ERR_TENSOR = -212,
    COCO80_ACCEL_ERR_DECODE = -213,
    COCO80_ACCEL_ERR_PACKAGE = -214
} coco80_accel_status_t;

/*
 * Pointer-free generated layer binding.  The generated parameter package
 * stores this exact 60-byte table in its quantization section.  Offsets are
 * relative to the corresponding bias/weight/LUT section, never raw DDR
 * addresses, so the package can be relocated safely.
 */
typedef struct {
    uint32_t bias_offset;
    uint32_t bias_bytes;
    uint32_t weight_offset;
    uint32_t weight_bytes;
    uint32_t bias_packets;
    uint32_t weight_packets;
    uint32_t input_scale_f32;
    uint32_t input_zero_point;
    uint32_t output_scale_f32;
    uint32_t output_zero_point;
    uint32_t quant_multiplier;
    uint32_t quant_shift;
    uint32_t quant_zero_point;
    uint32_t activation_lut_offset;
    uint32_t activation_lut_crc32;
} coco80_accel_layer_binding_t;

/*
 * Generated configuration-header contract.
 *
 * config_crc32 is CRC32/IEEE over little-endian uint32 values in this order:
 * magic through hardware_build_crc32, plan_sha256[8], model_sha256[8], then
 * all 15 uint32 fields of layers[0..12].  config_crc32 and the native pointer
 * itself are deliberately excluded.  The board refuses any mismatch before
 * touching DMA or accelerator state.
 */
typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t layer_count;
    uint32_t expected_clock_hz;
    uint32_t stream_config;
    uint32_t parameter_package_bytes;
    uint32_t parameter_package_crc32;
    uint32_t route_input_zero_point;
    uint32_t route_output_zero_point;
    uint32_t route_multiplier;
    uint32_t route_shift;
    uint32_t software_build_crc32;
    uint32_t hardware_build_crc32;
    uint32_t plan_sha256[8];
    uint32_t model_sha256[8];
    uint32_t config_crc32;
    const coco80_accel_layer_binding_t *layers;
} coco80_accel_generated_config_t;

typedef struct {
    const char *name;
    uint16_t fm_h;
    uint16_t fm_w;
    uint16_t cin;
    uint16_t cout;
    uint8_t kernel;
    uint8_t pad;
    uint8_t tile_h;
    uint8_t pool_stride;
    uint32_t k_total;
    uint32_t k_passes;
    uint32_t cout_blocks;
    uint32_t tile_count;
    uint32_t ifm_bytes;
    uint32_t ofm_bytes;
    uint32_t bias_bytes;
    uint32_t weight_bytes;
    uint32_t bias_packets;
    uint32_t weight_packets;
    uint32_t max_tile_pixels;
} coco80_accel_layer_plan_t;

enum coco80_accel_representative_override_mode {
    COCO80_ACCEL_REP_OVERRIDE_NONE = 0,
    COCO80_ACCEL_REP_OVERRIDE_SPARSE_3X3 = 1,
    COCO80_ACCEL_REP_OVERRIDE_TILE = 2
};

typedef struct {
    uint32_t mode;
    uint32_t tile_h;
    uint32_t kernel;
    const void *bias_data;
    uint32_t bias_bytes;
    uint32_t bias_packets;
    const void *weight_data;
    uint32_t weight_bytes;
    uint32_t weight_packets;
} coco80_accel_representative_override_t;

typedef struct {
    uint32_t layer_count;
    uint32_t total_ifm_bytes;
    uint32_t total_ofm_bytes;
    uint32_t total_bias_bytes;
    uint32_t total_weight_bytes;
    uint32_t total_contexts;
    uint32_t max_ifm_bytes;
    uint32_t max_ofm_bytes;
} coco80_accel_plan_summary_t;

typedef struct {
    uint64_t total_ticks;
    uint64_t pl_ticks;
    uint64_t a53_ticks;
    uint64_t decode_ticks;
    uint32_t tick_hz;
    uint32_t layer_count;
    uint32_t mode;
    uint32_t image_id;
    uint32_t detection_count;
    uint32_t sequence;
    uint32_t pl_dispatches;
    uint32_t reserved;
} coco80_accel_timing_record_t;

enum coco80_accel_a53_op {
    COCO80_ACCEL_A53_POOL1 = 0,
    COCO80_ACCEL_A53_POOL3,
    COCO80_ACCEL_A53_POOL5,
    COCO80_ACCEL_A53_POOL7,
    COCO80_ACCEL_A53_POOL9,
    COCO80_ACCEL_A53_POOL12,
    COCO80_ACCEL_A53_UPSAMPLE17,
    COCO80_ACCEL_A53_REQUANT_CONCAT18,
    COCO80_ACCEL_A53_P5_COPY,
    COCO80_ACCEL_A53_RESERVED,
    COCO80_ACCEL_A53_OP_COUNT
};

#define COCO80_ACCEL_EXTENDED_TIMING_MAGIC \
    COCO80_SD_FOURCC('C', '8', 'T', '3')
#define COCO80_ACCEL_EXTENDED_TIMING_VERSION 3U

typedef struct {
    uint32_t ifm_dma_bytes;
    uint32_t bias_dma_bytes;
    uint32_t weight_dma_bytes;
    uint32_t ofm_dma_bytes;
    uint32_t expected_contexts;
    uint32_t context_alloc;
    uint32_t context_input_issued;
    uint32_t context_array_retired;
    uint32_t context_collector_done;
    uint32_t context_gap_cycles;
    uint32_t ifm_owner_stall_cycles;
    uint32_t weight_owner_stall_cycles;
    uint32_t psum_credit_stall_cycles;
    uint32_t stage_weight_cycles;
    uint32_t stage_feeder_cycles;
    uint32_t stage_compute_cycles;
    uint32_t stage_drain_cycles;
    uint32_t compute_fire;
    uint32_t compute_idle_cycles;
    uint32_t raw_load_active_cycles;
    uint32_t raw_replay_active_cycles;
    uint32_t raw_replay_wait_cycles;
    uint32_t prefetch_hit;
    uint32_t prefetch_miss;
    uint32_t prefetch_stall_cycles;
    uint32_t psum_overlap_hit;
    uint32_t psum_overlap_wait_cycles;
    uint32_t psum_overlap_underflow;
    uint32_t drain_ready_stall_cycles;
    uint32_t drain_internal_full_cycles;
    uint32_t collector_full_stall_cycles;
    uint32_t collector_empty_wait_cycles;
} coco80_accel_layer_telemetry_t;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t bytes;
    uint32_t image_id;
    uint32_t sequence;
    uint32_t tick_hz;
    uint32_t output_kind;
    uint32_t decode_profile;
    uint64_t total_ticks;
    uint64_t pl_ticks;
    uint64_t a53_ticks;
    uint64_t decode_ticks;
    uint64_t candidate_ticks;
    uint64_t sort_ticks;
    uint64_t nms_ticks;
    uint64_t pl_layer_ticks[COCO80_ACCEL_LAYER_COUNT];
    uint64_t a53_op_ticks[COCO80_ACCEL_A53_OP_COUNT];
    uint32_t detection_count;
    uint32_t pl_dispatches;
    uint32_t status;
    uint32_t output_crc32;
    uint32_t stream_config;
    uint32_t telemetry_layer_count;
    uint32_t telemetry_record_bytes;
    uint32_t reserved_v3[5];
    coco80_accel_layer_telemetry_t
        layer_telemetry[COCO80_ACCEL_LAYER_COUNT];
} coco80_accel_extended_timing_t;

typedef uint64_t (*coco80_accel_ticks_fn)(void *opaque);
typedef int (*coco80_accel_tensor_hook_fn)(
    void *opaque, uint32_t tensor_id, const void *data, uint32_t bytes);

typedef struct {
    void *opaque;
    int (*pool_s2)(
        void *opaque, const coco80_hwc_u8_t *source,
        coco80_hwc_u8_t *destination);
    int (*pool_s1_pad)(
        void *opaque, const coco80_hwc_u8_t *source, uint8_t pad_value,
        coco80_hwc_u8_t *destination);
    int (*nearest_requant_concat)(
        void *opaque, const coco80_hwc_u8_t *small,
        const coco80_hwc_u8_t *route, int32_t input_zero_point,
        int32_t output_zero_point, uint32_t multiplier, uint32_t shift,
        coco80_hwc_u8_t *destination);
} coco80_accel_tensor_backend_t;

enum coco80_accel_tensor_id {
    COCO80_ACCEL_TENSOR_INPUT = 0,
    COCO80_ACCEL_TENSOR_M0, COCO80_ACCEL_TENSOR_POOL1,
    COCO80_ACCEL_TENSOR_M2, COCO80_ACCEL_TENSOR_POOL3,
    COCO80_ACCEL_TENSOR_M4, COCO80_ACCEL_TENSOR_POOL5,
    COCO80_ACCEL_TENSOR_M6, COCO80_ACCEL_TENSOR_POOL7,
    COCO80_ACCEL_TENSOR_M8, COCO80_ACCEL_TENSOR_POOL9,
    COCO80_ACCEL_TENSOR_M10, COCO80_ACCEL_TENSOR_POOL12,
    COCO80_ACCEL_TENSOR_M13, COCO80_ACCEL_TENSOR_M14,
    COCO80_ACCEL_TENSOR_M15, COCO80_ACCEL_TENSOR_M16,
    COCO80_ACCEL_TENSOR_UPSAMPLE17, COCO80_ACCEL_TENSOR_CONCAT18,
    COCO80_ACCEL_TENSOR_M19, COCO80_ACCEL_TENSOR_P4,
    COCO80_ACCEL_TENSOR_P5, COCO80_ACCEL_TENSOR_COUNT
};

/* Caller-owned arena, partitioned once and then reused for every image. */
typedef struct {
    uint8_t *arena;
    uint32_t arena_bytes;
    uint8_t *slot0;
    uint8_t *slot1;
    uint8_t *route_m8;
    uint8_t *route_m15;
    uint8_t *concat18;
    uint8_t *raw_package;
    uint8_t *detection_package;
    uint8_t *result_package;
    coco80_candidate_t *decode_candidates;
    coco80_detection_t *detections;
} coco80_accel_workspace_t;

typedef struct {
    uint32_t image_id;
    uint32_t detection_count;
    const void *raw_head_package;
    uint32_t raw_head_package_bytes;
    const void *detection_package;
    uint32_t detection_package_bytes;
    const void *result_package;
    uint32_t result_package_bytes;
    coco80_accel_timing_record_t timing;
    coco80_accel_extended_timing_t extended_timing;
} coco80_accel_output_t;

typedef struct {
    int status;
    int detail;
    uint32_t layer_index;
    accel_v2_layer_report_t layer_report;
} coco80_accel_failure_t;

typedef struct {
    accel_v2_runtime_t runtime;
    coco80_accel_ticks_fn ticks;
    void *ticks_opaque;
    coco80_accel_tensor_hook_fn tensor_hook;
    void *tensor_hook_opaque;
    coco80_accel_tensor_backend_t tensor_backend;
    uint32_t tick_hz;
    const coco80_accel_generated_config_t *config;
    const uint8_t *parameter_package;
    const uint8_t *bias_image;
    const uint8_t *weight_image;
    const uint8_t *activation_luts;
    coco80_accel_workspace_t *workspace;
    uint32_t parameter_package_crc32;
    uint32_t sequence;
    uint32_t stream_config;
    uint8_t initialized;
    uint8_t reserved[3];
    coco80_accel_failure_t failure;
} coco80_accel_runner_t;

uint32_t coco80_accel_workspace_bytes(void);
int coco80_accel_workspace_init(
    coco80_accel_workspace_t *workspace,
    void *arena,
    uint32_t arena_bytes);

const coco80_accel_layer_plan_t *coco80_accel_plan(uint32_t layer_index);
int coco80_accel_plan_summary(coco80_accel_plan_summary_t *summary);
uint32_t coco80_accel_config_crc32(
    const coco80_accel_generated_config_t *config);
int coco80_accel_validate_config(
    const coco80_accel_generated_config_t *config);

int coco80_accel_initialize(
    coco80_accel_runner_t *runner,
    const accel_v2_runtime_t *runtime,
    coco80_accel_ticks_fn ticks,
    void *ticks_opaque,
    uint32_t tick_hz,
    const coco80_accel_generated_config_t *config,
    const void *parameter_package,
    uint32_t parameter_package_bytes,
    coco80_accel_workspace_t *workspace);

int coco80_accel_set_tensor_hook(
    coco80_accel_runner_t *runner,
    coco80_accel_tensor_hook_fn hook,
    void *opaque);

int coco80_accel_set_tensor_backend(
    coco80_accel_runner_t *runner,
    const coco80_accel_tensor_backend_t *backend);

/* Publication-ineligible experiment software may select a safe staged
 * runtime schedule without changing the generated model/parameter binding. */
int coco80_accel_set_ablation_stream_config(
    coco80_accel_runner_t *runner, uint32_t stream_config);

/*
 * Publication-ineligible representative-layer entry point.
 *
 * RAW_HWC uses the selected materialize-capable bitstream.  The A0 mode is
 * compiled only for the dedicated no-materializer hardware and consumes one
 * exact legacy stream ordered by tile, output block, and K-pass.  Both modes
 * use the normal generated parameter package and produce packed HWC bytes.
 */
int coco80_accel_run_representative_layer(
    coco80_accel_runner_t *runner,
    uint32_t layer_index,
    coco80_accel_layer_input_mode_t input_mode,
    const void *ifm,
    uint32_t ifm_bytes,
    void *ofm,
    uint32_t ofm_bytes,
    uint32_t image_id,
    const coco80_accel_representative_override_t *override,
    coco80_accel_extended_timing_t *timing);

int coco80_accel_infer_package(
    coco80_accel_runner_t *runner,
    const void *input_package,
    uint32_t input_package_bytes,
    coco80_accel_mode_t mode,
    coco80_accel_output_t *output);

int coco80_accel_infer_package_ex(
    coco80_accel_runner_t *runner,
    const void *input_package,
    uint32_t input_package_bytes,
    const coco80_accel_infer_options_t *options,
    coco80_accel_output_t *output);

#ifdef __cplusplus
}
#endif

#endif

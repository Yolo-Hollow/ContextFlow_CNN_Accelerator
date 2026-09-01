#include "coco80_accel.h"

#include "coco80_tensor_ops.h"

#include <limits.h>
#include <math.h>
#include <stddef.h>
#include <string.h>

typedef char coco80_accel_float_must_be_32_bits[sizeof(float) == 4U ? 1 : -1];
typedef char coco80_accel_binding_must_be_60_bytes[
    sizeof(coco80_accel_layer_binding_t) == 60U ? 1 : -1];
typedef char coco80_accel_timing_must_be_64_bytes[
    sizeof(coco80_accel_timing_record_t) == COCO80_ACCEL_TIMING_RECORD_BYTES ? 1 : -1];
typedef char coco80_accel_layer_telemetry_must_be_128_bytes[
    sizeof(coco80_accel_layer_telemetry_t) ==
        COCO80_ACCEL_LAYER_TELEMETRY_BYTES ? 1 : -1];
typedef char coco80_accel_extended_timing_must_be_1984_bytes[
    sizeof(coco80_accel_extended_timing_t) ==
        COCO80_ACCEL_EXTENDED_TIMING_BYTES ? 1 : -1];

#define C8_ALIGN 64U
#define C8_SLOT0_BYTES 2768896U
#define C8_SLOT1_BYTES 692224U
#define C8_ROUTE_M8_BYTES 173056U
#define C8_ROUTE_M15_BYTES 86528U
#define C8_CONCAT18_BYTES 259584U
#define C8_CANDIDATE_BYTES \
    (COCO80_ACCURACY_MAX_NMS * (uint32_t)sizeof(coco80_candidate_t))
#define C8_DETECTIONS_BYTES \
    (COCO80_ACCURACY_MAX_DETECTIONS * (uint32_t)sizeof(coco80_detection_t))
#define C8_BIAS_IMAGE_BYTES 64256U
#define C8_WEIGHT_IMAGE_BYTES 18614016U
#define C8_LUT_IMAGE_BYTES (COCO80_ACCEL_LAYER_COUNT * 256U)
#define C8_BINDING_IMAGE_BYTES \
    (COCO80_ACCEL_LAYER_COUNT * (uint32_t)sizeof(coco80_accel_layer_binding_t))
#define C8_ALIGN_UP_CONST(value) \
    (((value) + (C8_ALIGN - 1U)) & ~(C8_ALIGN - 1U))

typedef char coco80_accel_workspace_size_must_match[
    C8_SLOT0_BYTES + C8_SLOT1_BYTES + C8_ROUTE_M8_BYTES +
        C8_ROUTE_M15_BYTES + C8_CONCAT18_BYTES +
        C8_ALIGN_UP_CONST(COCO80_ACCEL_RAW_PACKAGE_BYTES) +
        C8_ALIGN_UP_CONST(COCO80_ACCEL_DETECTION_PACKAGE_BYTES) +
        C8_ALIGN_UP_CONST(COCO80_ACCEL_RESULT_PACKAGE_BYTES) +
        C8_ALIGN_UP_CONST(C8_CANDIDATE_BYTES) +
        C8_ALIGN_UP_CONST(C8_DETECTIONS_BYTES) ==
            COCO80_ACCEL_WORKSPACE_BYTES ? 1 : -1];
typedef char coco80_accel_p5_scratch_must_fit[
    C8_SLOT1_BYTES >= COCO80_P5_TENSOR_BYTES ? 1 : -1];

static const uint32_t c8_plan_sha256[8] = {
    0x3b78e5f7U, 0xd842a5deU, 0x14f43067U, 0xcd32f64dU,
    0xe91c44d2U, 0xe299b483U, 0xef6a9d96U, 0x2810cc79U
};

static const coco80_accel_layer_plan_t c8_plan[COCO80_ACCEL_LAYER_COUNT] = {
    {"m0", 416U, 416U, 3U, 16U, 3U, 1U, 2U, 2U,
     27U, 2U, 1U, 208U, 519168U, 692224U, 26624U, 239616U, 208U, 416U, 832U},
    {"m2", 208U, 208U, 16U, 32U, 3U, 1U, 4U, 2U,
     144U, 8U, 1U, 52U, 692224U, 346112U, 6656U, 239616U, 52U, 416U, 832U},
    {"m4", 104U, 104U, 32U, 64U, 3U, 1U, 8U, 2U,
     288U, 16U, 2U, 13U, 346112U, 173056U, 3328U, 239616U, 26U, 416U, 832U},
    {"m6", 52U, 52U, 64U, 128U, 3U, 1U, 8U, 2U,
     576U, 32U, 4U, 7U, 173056U, 86528U, 3584U, 516096U, 28U, 896U, 416U},
    {"m8", 26U, 26U, 128U, 256U, 3U, 1U, 13U, 0U,
     1152U, 64U, 8U, 2U, 86528U, 173056U, 2048U, 589824U, 16U, 1024U, 338U},
    {"m10", 13U, 13U, 256U, 512U, 3U, 1U, 13U, 0U,
     2304U, 128U, 16U, 1U, 43264U, 86528U, 2048U, 1179648U, 16U, 2048U, 169U},
    {"m13", 13U, 13U, 512U, 1024U, 3U, 1U, 8U, 0U,
     4608U, 256U, 32U, 2U, 86528U, 173056U, 8192U, 9437184U, 64U, 16384U, 104U},
    {"m14", 13U, 13U, 1024U, 256U, 1U, 0U, 13U, 0U,
     1024U, 57U, 8U, 1U, 173056U, 43264U, 1024U, 262656U, 8U, 456U, 169U},
    {"m15", 13U, 13U, 256U, 512U, 3U, 1U, 13U, 0U,
     2304U, 128U, 16U, 1U, 43264U, 86528U, 2048U, 1179648U, 16U, 2048U, 169U},
    {"m16", 13U, 13U, 256U, 128U, 1U, 0U, 13U, 0U,
     256U, 15U, 4U, 1U, 43264U, 21632U, 512U, 34560U, 4U, 60U, 169U},
    {"m19", 26U, 26U, 384U, 256U, 3U, 1U, 6U, 0U,
     3456U, 192U, 8U, 5U, 259584U, 173056U, 5120U, 4423680U, 40U, 7680U, 156U},
    {"p4_detect", 26U, 26U, 256U, 255U, 1U, 0U, 13U, 0U,
     256U, 15U, 8U, 2U, 173056U, 172380U, 2048U, 138240U, 16U, 240U, 338U},
    {"p5_detect", 13U, 13U, 512U, 255U, 1U, 0U, 13U, 0U,
     512U, 29U, 8U, 1U, 86528U, 43095U, 1024U, 133632U, 8U, 232U, 169U}
};

static uint32_t c8_align_up(uint32_t value)
{
    return (value + (C8_ALIGN - 1U)) & ~(C8_ALIGN - 1U);
}

uint32_t coco80_accel_workspace_bytes(void)
{
    return COCO80_ACCEL_WORKSPACE_BYTES;
}

int coco80_accel_workspace_init(
    coco80_accel_workspace_t *workspace, void *arena, uint32_t arena_bytes)
{
    uint8_t *cursor;
    if (workspace == NULL || arena == NULL ||
        (((uintptr_t)arena) & (C8_ALIGN - 1U)) != 0U ||
        arena_bytes < coco80_accel_workspace_bytes()) {
        return COCO80_ACCEL_ERR_WORKSPACE;
    }
    memset(workspace, 0, sizeof(*workspace));
    workspace->arena = (uint8_t *)arena;
    workspace->arena_bytes = arena_bytes;
    cursor = workspace->arena;
#define C8_ALLOC(field, bytes) do { workspace->field = cursor; cursor += c8_align_up(bytes); } while (0)
    C8_ALLOC(slot0, C8_SLOT0_BYTES);
    C8_ALLOC(slot1, C8_SLOT1_BYTES);
    C8_ALLOC(route_m8, C8_ROUTE_M8_BYTES);
    C8_ALLOC(route_m15, C8_ROUTE_M15_BYTES);
    C8_ALLOC(concat18, C8_CONCAT18_BYTES);
    C8_ALLOC(raw_package, COCO80_ACCEL_RAW_PACKAGE_BYTES);
    C8_ALLOC(detection_package, COCO80_ACCEL_DETECTION_PACKAGE_BYTES);
    C8_ALLOC(result_package, COCO80_ACCEL_RESULT_PACKAGE_BYTES);
    workspace->decode_candidates = (coco80_candidate_t *)cursor;
    cursor += c8_align_up(C8_CANDIDATE_BYTES);
    workspace->detections = (coco80_detection_t *)cursor;
    cursor += c8_align_up(C8_DETECTIONS_BYTES);
#undef C8_ALLOC
    if ((uint32_t)(cursor - workspace->arena) != coco80_accel_workspace_bytes()) {
        memset(workspace, 0, sizeof(*workspace));
        return COCO80_ACCEL_ERR_WORKSPACE;
    }
    return COCO80_ACCEL_OK;
}

const coco80_accel_layer_plan_t *coco80_accel_plan(uint32_t layer_index)
{
    return layer_index < COCO80_ACCEL_LAYER_COUNT ? &c8_plan[layer_index] : NULL;
}

int coco80_accel_plan_summary(coco80_accel_plan_summary_t *summary)
{
    uint32_t index;
    if (summary == NULL) {
        return COCO80_ACCEL_ERR_ARGUMENT;
    }
    memset(summary, 0, sizeof(*summary));
    summary->layer_count = COCO80_ACCEL_LAYER_COUNT;
    for (index = 0U; index < COCO80_ACCEL_LAYER_COUNT; ++index) {
        const coco80_accel_layer_plan_t *plan = &c8_plan[index];
        uint32_t contexts = plan->tile_count * plan->cout_blocks * plan->k_passes;
        summary->total_ifm_bytes += plan->ifm_bytes;
        summary->total_ofm_bytes += plan->ofm_bytes;
        summary->total_bias_bytes += plan->bias_bytes;
        summary->total_weight_bytes += plan->weight_bytes;
        summary->total_contexts += contexts;
        if (plan->ifm_bytes > summary->max_ifm_bytes) summary->max_ifm_bytes = plan->ifm_bytes;
        if (plan->ofm_bytes > summary->max_ofm_bytes) summary->max_ofm_bytes = plan->ofm_bytes;
    }
    if (summary->total_ifm_bytes != 2725632U ||
        summary->total_ofm_bytes != 2270515U ||
        summary->total_bias_bytes != C8_BIAS_IMAGE_BYTES ||
        summary->total_weight_bytes != C8_WEIGHT_IMAGE_BYTES ||
        summary->total_contexts != 32316U ||
        summary->max_ifm_bytes != 692224U ||
        summary->max_ofm_bytes != 692224U) {
        return COCO80_ACCEL_ERR_PLAN;
    }
    return COCO80_ACCEL_OK;
}

static uint32_t c8_crc_word(uint32_t crc, uint32_t value)
{
    uint32_t byte_index;
    crc = ~crc;
    for (byte_index = 0U; byte_index < 4U; ++byte_index) {
        uint32_t bit;
        crc ^= (value >> (byte_index * 8U)) & 0xffU;
        for (bit = 0U; bit < 8U; ++bit) {
            crc = (crc >> 1U) ^ ((0U - (crc & 1U)) & 0xedb88320U);
        }
    }
    return ~crc;
}

uint32_t coco80_accel_config_crc32(const coco80_accel_generated_config_t *config)
{
    uint32_t crc = 0U;
    uint32_t index;
    const uint32_t *scalar;
    if (config == NULL || config->layers == NULL) return 0U;
    scalar = &config->magic;
    for (index = 0U; index < 13U; ++index) crc = c8_crc_word(crc, scalar[index]);
    for (index = 0U; index < 8U; ++index) crc = c8_crc_word(crc, config->plan_sha256[index]);
    for (index = 0U; index < 8U; ++index) crc = c8_crc_word(crc, config->model_sha256[index]);
    for (index = 0U; index < COCO80_ACCEL_LAYER_COUNT; ++index) {
        uint32_t field;
        const uint32_t *binding = (const uint32_t *)&config->layers[index];
        for (field = 0U; field < 15U; ++field) crc = c8_crc_word(crc, binding[field]);
    }
    return crc;
}

static int c8_hash_nonzero(const uint32_t value[8])
{
    uint32_t index, any = 0U;
    for (index = 0U; index < 8U; ++index) any |= value[index];
    return any != 0U;
}

int coco80_accel_validate_config(const coco80_accel_generated_config_t *config)
{
    static const uint8_t upstream[COCO80_ACCEL_LAYER_COUNT] = {
        0xffU, 0U, 1U, 2U, 3U, 4U, 5U, 6U, 7U, 7U, 9U, 10U, 8U
    };
    uint32_t bias_offset = 0U, weight_offset = 0U, index;
    coco80_accel_plan_summary_t summary;
    if (config == NULL || config->layers == NULL ||
        config->magic != COCO80_ACCEL_CONFIG_MAGIC ||
        config->version != COCO80_ACCEL_CONFIG_VERSION ||
        config->layer_count != COCO80_ACCEL_LAYER_COUNT ||
        config->expected_clock_hz == 0U ||
        config->stream_config != COCO80_ACCEL_RELEASE_STREAM_CONFIG ||
        (config->stream_config & ACCEL_STREAM_CFG_COLUMN_PSUM) != 0U ||
        (config->stream_config & (ACCEL_STREAM_CFG_BATCH |
          ACCEL_STREAM_CFG_RAW_HWC | ACCEL_STREAM_CFG_CONTINUOUS_PSUM)) !=
         (ACCEL_STREAM_CFG_BATCH | ACCEL_STREAM_CFG_RAW_HWC |
          ACCEL_STREAM_CFG_CONTINUOUS_PSUM) ||
        config->parameter_package_bytes !=
            COCO80_SD_HEADER_BYTES + C8_WEIGHT_IMAGE_BYTES + C8_BIAS_IMAGE_BYTES +
            C8_LUT_IMAGE_BYTES + C8_BINDING_IMAGE_BYTES ||
        config->parameter_package_crc32 == 0U ||
        config->route_input_zero_point > 255U ||
        config->route_output_zero_point > 255U ||
        config->route_multiplier == 0U || config->route_multiplier > INT32_MAX ||
        config->route_shift == 0U || config->route_shift > 30U ||
        config->software_build_crc32 == 0U ||
        config->hardware_build_crc32 == 0U ||
        !c8_hash_nonzero(config->model_sha256) ||
        memcmp(config->plan_sha256, c8_plan_sha256, sizeof(c8_plan_sha256)) != 0 ||
        config->config_crc32 == 0U ||
        config->config_crc32 != coco80_accel_config_crc32(config) ||
        coco80_accel_plan_summary(&summary) != COCO80_ACCEL_OK) {
        return COCO80_ACCEL_ERR_CONFIG;
    }
    for (index = 0U; index < COCO80_ACCEL_LAYER_COUNT; ++index) {
        const coco80_accel_layer_plan_t *plan = &c8_plan[index];
        const coco80_accel_layer_binding_t *binding = &config->layers[index];
        float input_scale = coco80_sd_bits_to_float(binding->input_scale_f32);
        float output_scale = coco80_sd_bits_to_float(binding->output_scale_f32);
        if (binding->bias_offset != bias_offset ||
            binding->bias_bytes != plan->bias_bytes ||
            binding->weight_offset != weight_offset ||
            binding->weight_bytes != plan->weight_bytes ||
            binding->bias_packets != plan->bias_packets ||
            binding->weight_packets != plan->weight_packets ||
            !isfinite(input_scale) || input_scale <= 0.0f ||
            !isfinite(output_scale) || output_scale <= 0.0f ||
            binding->input_zero_point > 255U ||
            binding->output_zero_point > 255U ||
            binding->quant_multiplier == 0U || binding->quant_multiplier > 65535U ||
            binding->quant_shift > 15U || binding->quant_zero_point > 255U ||
            binding->activation_lut_offset != index * 256U ||
            binding->activation_lut_crc32 == 0U ||
            (binding->bias_offset & (COCO80_ACCEL_PARAMETER_ALIGNMENT - 1U)) != 0U ||
            (binding->weight_offset & (COCO80_ACCEL_PARAMETER_ALIGNMENT - 1U)) != 0U) {
            return COCO80_ACCEL_ERR_CONFIG;
        }
        if (upstream[index] != 0xffU) {
            const coco80_accel_layer_binding_t *source = &config->layers[upstream[index]];
            if (binding->input_scale_f32 != source->output_scale_f32 ||
                binding->input_zero_point != source->output_zero_point) {
                return COCO80_ACCEL_ERR_CONFIG;
            }
        }
        bias_offset += binding->bias_bytes;
        weight_offset += binding->weight_bytes;
    }
    if (bias_offset != C8_BIAS_IMAGE_BYTES || weight_offset != C8_WEIGHT_IMAGE_BYTES ||
        config->route_input_zero_point != config->layers[4].output_zero_point ||
        config->route_output_zero_point != config->layers[9].output_zero_point) {
        return COCO80_ACCEL_ERR_CONFIG;
    }
    return COCO80_ACCEL_OK;
}

static int c8_fail(coco80_accel_runner_t *runner, int status, int detail,
                   uint32_t layer, const accel_v2_layer_report_t *report)
{
    if (runner != NULL) {
        runner->failure.status = status;
        runner->failure.detail = detail;
        runner->failure.layer_index = layer;
        if (report != NULL) runner->failure.layer_report = *report;
    }
    return status;
}

int coco80_accel_initialize(
    coco80_accel_runner_t *runner, const accel_v2_runtime_t *runtime,
    coco80_accel_ticks_fn ticks, void *ticks_opaque, uint32_t tick_hz,
    const coco80_accel_generated_config_t *config,
    const void *parameter_package, uint32_t parameter_package_bytes,
    coco80_accel_workspace_t *workspace)
{
    coco80_sd_parameter_header_t header;
    const uint8_t *bytes = (const uint8_t *)parameter_package;
    uint32_t full_crc, index;
    int rc;
    if (runner == NULL) return COCO80_ACCEL_ERR_ARGUMENT;
    memset(runner, 0, sizeof(*runner));
    if (!accel_v2_runtime_valid(runtime) || ticks == NULL || tick_hz == 0U ||
        config == NULL || parameter_package == NULL || workspace == NULL ||
        workspace->arena == NULL ||
        workspace->arena_bytes < coco80_accel_workspace_bytes()) {
        return c8_fail(runner, COCO80_ACCEL_ERR_ARGUMENT, 0, UINT32_MAX, NULL);
    }
    rc = coco80_accel_validate_config(config);
    if (rc != COCO80_ACCEL_OK) return c8_fail(runner, rc, 0, UINT32_MAX, NULL);
    if (parameter_package_bytes != config->parameter_package_bytes) {
        return c8_fail(runner, COCO80_ACCEL_ERR_PARAMETER, -1, UINT32_MAX, NULL);
    }
    full_crc = coco80_sd_crc32(parameter_package, parameter_package_bytes);
    if (full_crc == 0U || full_crc != config->parameter_package_crc32) {
        return c8_fail(runner, COCO80_ACCEL_ERR_PARAMETER_CRC, 0, UINT32_MAX, NULL);
    }
    rc = coco80_sd_validate_parameters(parameter_package, parameter_package_bytes, &header);
    if (rc != COCO80_SD_OK) {
        return c8_fail(runner, COCO80_ACCEL_ERR_PARAMETER, rc, UINT32_MAX, NULL);
    }
    if (header.weights.bytes != C8_WEIGHT_IMAGE_BYTES ||
        header.biases.bytes != C8_BIAS_IMAGE_BYTES ||
        header.activation_luts.bytes != C8_LUT_IMAGE_BYTES ||
        header.quantization.bytes != C8_BINDING_IMAGE_BYTES ||
        memcmp(header.model_sha256, config->model_sha256, sizeof(header.model_sha256)) != 0 ||
        memcmp(bytes + header.quantization.offset, config->layers,
               C8_BINDING_IMAGE_BYTES) != 0) {
        return c8_fail(runner, COCO80_ACCEL_ERR_PARAMETER, -2, UINT32_MAX, NULL);
    }
    for (index = 0U; index < COCO80_ACCEL_LAYER_COUNT; ++index) {
        const coco80_accel_layer_binding_t *binding = &config->layers[index];
        if (binding->activation_lut_offset + 256U > header.activation_luts.bytes ||
            coco80_sd_crc32(bytes + header.activation_luts.offset +
                binding->activation_lut_offset, 256U) != binding->activation_lut_crc32) {
            return c8_fail(runner, COCO80_ACCEL_ERR_PARAMETER_CRC,
                           (int)index + 1, index, NULL);
        }
    }
    rc = accel_abi_v2_validate(
        runtime->read32(runtime->opaque, runtime->accel_base, ACCEL_ABI_VERSION_REG),
        runtime->read32(runtime->opaque, runtime->accel_base, ACCEL_CAPABILITY_REG),
#if defined(COCO80_ABLATION_VARIANT_A0) && COCO80_ABLATION_VARIANT_A0 == 1
        ACCEL_CAP_FLAG_PACKED_HWC_OFM | ACCEL_CAP_FLAG_EPOCH_CONTEXT);
#else
        ACCEL_CAP_V2_REQUIRED_FLAGS);
#endif
    if (rc != ACCEL_ABI_OK) return c8_fail(runner, COCO80_ACCEL_ERR_ABI, rc, UINT32_MAX, NULL);
    if (runtime->read32(runtime->opaque, runtime->accel_base, ACCEL_CLOCK_HZ) !=
        config->expected_clock_hz) {
        return c8_fail(runner, COCO80_ACCEL_ERR_CLOCK, 0, UINT32_MAX, NULL);
    }
    rc = accel_v2_runtime_recover(runtime);
    if (rc != ACCEL_V2_RUN_OK) {
        return c8_fail(runner, COCO80_ACCEL_ERR_RECOVERY, rc, UINT32_MAX, NULL);
    }
    runner->runtime = *runtime;
    runner->ticks = ticks;
    runner->ticks_opaque = ticks_opaque;
    runner->tick_hz = tick_hz;
    runner->config = config;
    runner->parameter_package = bytes;
    runner->weight_image = bytes + header.weights.offset;
    runner->bias_image = bytes + header.biases.offset;
    runner->activation_luts = bytes + header.activation_luts.offset;
    runner->workspace = workspace;
    runner->parameter_package_crc32 = full_crc;
    runner->stream_config = config->stream_config;
    runner->initialized = 1U;
    return COCO80_ACCEL_OK;
}

int coco80_accel_set_tensor_hook(
    coco80_accel_runner_t *runner, coco80_accel_tensor_hook_fn hook, void *opaque)
{
    if (runner == NULL || !runner->initialized) return COCO80_ACCEL_ERR_ARGUMENT;
    runner->tensor_hook = hook;
    runner->tensor_hook_opaque = opaque;
    return COCO80_ACCEL_OK;
}

int coco80_accel_set_tensor_backend(
    coco80_accel_runner_t *runner,
    const coco80_accel_tensor_backend_t *backend)
{
    if (runner == NULL || !runner->initialized || backend == NULL ||
        backend->pool_s2 == NULL || backend->pool_s1_pad == NULL ||
        backend->nearest_requant_concat == NULL) {
        return COCO80_ACCEL_ERR_ARGUMENT;
    }
    runner->tensor_backend = *backend;
    return COCO80_ACCEL_OK;
}

int coco80_accel_set_ablation_stream_config(
    coco80_accel_runner_t *runner, uint32_t stream_config)
{
#if !defined(COCO80_ABLATION_RUNTIME) || COCO80_ABLATION_RUNTIME != 1
    (void)runner;
    (void)stream_config;
    return COCO80_ACCEL_ERR_CONFIG;
#else
    if (runner == NULL || !runner->initialized ||
        (stream_config != 0x2bU && stream_config != 0x3bU &&
         stream_config != 0x3fU && stream_config != 0xbfU
#if defined(COCO80_ABLATION_VARIANT_A0) && COCO80_ABLATION_VARIANT_A0 == 1
         && stream_config != COCO80_ACCEL_A0_PREPACKED_STREAM_CONFIG
#endif
        )) {
        return COCO80_ACCEL_ERR_ARGUMENT;
    }
    runner->stream_config = stream_config;
    return COCO80_ACCEL_OK;
#endif
}

static int c8_hook(coco80_accel_runner_t *runner, uint32_t tensor_id,
                   const void *data, uint32_t bytes)
{
    int rc;
    if (runner->tensor_hook == NULL) return COCO80_ACCEL_OK;
    if (tensor_id >= COCO80_ACCEL_TENSOR_COUNT || data == NULL || bytes == 0U)
        return c8_fail(runner, COCO80_ACCEL_ERR_TENSOR, -1000,
                       UINT32_MAX, NULL);
    rc = runner->tensor_hook(runner->tensor_hook_opaque, tensor_id, data, bytes);
    if (rc != 0) return c8_fail(runner, COCO80_ACCEL_ERR_TENSOR, rc,
                                UINT32_MAX, NULL);
    return COCO80_ACCEL_OK;
}

typedef struct {
    coco80_accel_runner_t *runner;
    uint32_t layer;
    const coco80_accel_layer_plan_t *plan;
    const coco80_accel_layer_binding_t *binding;
    uint32_t stream_config;
    uint32_t ifm_bytes;
    uint32_t ifm_packets;
} c8_program_cookie_t;

static void c8_wr(coco80_accel_runner_t *runner, uint32_t reg, uint32_t value)
{
    runner->runtime.write32(runner->runtime.opaque,
        runner->runtime.accel_base, reg, value);
}

static uint32_t c8_rd(coco80_accel_runner_t *runner, uint32_t reg)
{
    return runner->runtime.read32(runner->runtime.opaque,
        runner->runtime.accel_base, reg);
}

static int c8_program_layer(void *opaque)
{
    c8_program_cookie_t *cookie = (c8_program_cookie_t *)opaque;
    coco80_accel_runner_t *runner = cookie->runner;
    const coco80_accel_layer_plan_t *plan = cookie->plan;
    const coco80_accel_layer_binding_t *binding = cookie->binding;
    uint32_t descriptor = plan->tile_h |
        (cookie->layer + 1U == COCO80_ACCEL_LAYER_COUNT ? ACCEL_LAYER_DESC_LAST_MASK : 0U);
    uint32_t conv = (plan->kernel == 1U ? ACCEL_CONV_KERNEL_1X1 : 0U) |
        ((uint32_t)plan->pad << 8U) | 1U;
    uint32_t packed = ACCEL_QUANT_PACK(binding->quant_multiplier,
        binding->quant_shift, binding->quant_zero_point);
    uint32_t index;
    if ((c8_rd(runner, ACCEL_CTRL) & ACCEL_CTRL_BUSY_MASK) != 0U) return -1;
    c8_wr(runner, ACCEL_FM_SIZE, ((uint32_t)plan->fm_w << 16U) | plan->fm_h);
    c8_wr(runner, ACCEL_OFM_SIZE, ((uint32_t)plan->fm_w << 16U) | plan->fm_h);
    c8_wr(runner, ACCEL_CONV, conv);
    c8_wr(runner, ACCEL_K_TOTAL, plan->k_total);
    c8_wr(runner, ACCEL_COUT_TOTAL, plan->cout);
    c8_wr(runner, ACCEL_NUM_PIXELS, plan->max_tile_pixels);
    c8_wr(runner, ACCEL_ACT_CFG, 2U);
    c8_wr(runner, ACCEL_TILE_ROWS, (uint32_t)plan->tile_h << 16U);
    c8_wr(runner, ACCEL_PIXEL_BASE, 0U);
    c8_wr(runner, ACCEL_IFM_ZP, binding->input_zero_point);
    c8_wr(runner, ACCEL_POOL_CFG,
          plan->pool_stride == 0U ? 0U : ((uint32_t)plan->pool_stride << 2U) | 1U);
    c8_wr(runner, ACCEL_EXPECTED_BYTES, plan->ofm_bytes);
    c8_wr(runner, ACCEL_STREAM_CFG, cookie->stream_config);
    c8_wr(runner, ACCEL_STREAM_BIAS_PACKETS, binding->bias_packets);
    c8_wr(runner, ACCEL_STREAM_WEIGHT_PACKETS, binding->weight_packets);
    c8_wr(runner, ACCEL_STREAM_IFM_PACKETS, cookie->ifm_packets);
    c8_wr(runner, ACCEL_TAIL_CONFIG, 0U);
    c8_wr(runner, ACCEL_PASSTRACE_SELECT, 0U);
    c8_wr(runner, ACCEL_COLTRACE_CTRL, 0U);
    c8_wr(runner, ACCEL_LAYER_DESC_REG, descriptor);
    c8_wr(runner, ACCEL_IFM_TOTAL_BYTES_REG, cookie->ifm_bytes);
    c8_wr(runner, ACCEL_OFM_TOTAL_BYTES_REG, plan->ofm_bytes);
    if (c8_rd(runner, ACCEL_LAYER_DESC_REG) != descriptor ||
        c8_rd(runner, ACCEL_IFM_TOTAL_BYTES_REG) != cookie->ifm_bytes ||
        c8_rd(runner, ACCEL_OFM_TOTAL_BYTES_REG) != plan->ofm_bytes) return -2;
    for (index = 0U; index < ACCEL_RELEASE_COUT_TILE; ++index) {
        c8_wr(runner, ACCEL_QUANT_ADDR, index);
        c8_wr(runner, ACCEL_QUANT_DATA, packed);
        if (c8_rd(runner, ACCEL_QUANT_DATA) != packed) return -3;
    }
    for (index = 0U; index < 256U; ++index) {
        uint32_t value = runner->activation_luts[binding->activation_lut_offset + index];
        c8_wr(runner, ACCEL_LUT_ADDR, index);
        c8_wr(runner, ACCEL_LUT_DATA, value);
        if ((c8_rd(runner, ACCEL_LUT_DATA) & 0xffU) != value) return -4;
    }
    return 0;
}

static int c8_validate_counters(
    coco80_accel_runner_t *runner,
    const coco80_accel_layer_plan_t *plan,
    const coco80_accel_layer_binding_t *binding,
    uint32_t ifm_bytes, uint32_t ifm_packets, int raw_hwc,
    uint32_t *mismatch_mask)
{
    uint32_t ifm_beats = (ifm_bytes + OFM_AXIS_BEAT_BYTES - 1U) / OFM_AXIS_BEAT_BYTES;
    uint32_t ofm_beats = (plan->ofm_bytes + OFM_AXIS_BEAT_BYTES - 1U) / OFM_AXIS_BEAT_BYTES;
    uint32_t conv_packets = (uint32_t)plan->fm_h * plan->fm_w * plan->cout_blocks;
    uint32_t output_h = plan->pool_stride == 0U ?
        plan->fm_h : (uint32_t)plan->fm_h / plan->pool_stride;
    uint32_t output_w = plan->pool_stride == 0U ?
        plan->fm_w : (uint32_t)plan->fm_w / plan->pool_stride;
    uint32_t packets = output_h * output_w * plan->cout_blocks;
    uint32_t fires = conv_packets * plan->k_passes;
    uint32_t mask = 0U;
    if (c8_rd(runner, ACCEL_DATAPATH_ERRORS_REG) != 0U) mask |= 1U << 0;
    if (c8_rd(runner, ACCEL_PACKED_OFM_BYTES_REG) != plan->ofm_bytes) mask |= 1U << 1;
    if (c8_rd(runner, ACCEL_OFM_AXIS_BEATS_REG) != ofm_beats) mask |= 1U << 2;
    if (raw_hwc) {
        if (c8_rd(runner, ACCEL_VECTOR_BEATS) != ifm_beats) mask |= 1U << 3;
    } else if (c8_rd(runner, ACCEL_STREAM_IFM_DONE) != ifm_packets) {
        mask |= 1U << 3;
    }
    if (c8_rd(runner, ACCEL_STREAM_BIAS_DONE) != binding->bias_packets) mask |= 1U << 4;
    if (c8_rd(runner, ACCEL_STREAM_WEIGHT_DONE) != binding->weight_packets) mask |= 1U << 5;
    if (c8_rd(runner, ACCEL_COMP_FIRE) != fires) mask |= 1U << 6;
    if (c8_rd(runner, ACCEL_DBG_CORE_WR) != packets) mask |= 1U << 7;
    if (c8_rd(runner, ACCEL_DBG_TLASTS) != 1U) mask |= 1U << 8;
    if (c8_rd(runner, ACCEL_DBG_LAST_END) != ofm_beats) mask |= 1U << 9;
    if (c8_rd(runner, ACCEL_PREFETCH_MISS) != 0U) mask |= 1U << 10;
    if (c8_rd(runner, ACCEL_PSUMOVL_UNDERFLOW) != 0U) mask |= 1U << 11;
    if (mismatch_mask != NULL) *mismatch_mask = mask;
    if (mask != 0U) return COCO80_ACCEL_ERR_COUNTER;
    return COCO80_ACCEL_OK;
}

static void c8_capture_layer_telemetry(
    coco80_accel_runner_t *runner,
    const accel_v2_layer_transfer_t *transfer,
    const accel_v2_layer_report_t *report,
    coco80_accel_layer_telemetry_t *value)
{
    memset(value, 0, sizeof(*value));
    value->ifm_dma_bytes = transfer->ifm_bytes;
    value->bias_dma_bytes = transfer->bias_bytes;
    value->weight_dma_bytes = transfer->weight_bytes;
    value->ofm_dma_bytes = transfer->ofm_bytes;
    value->expected_contexts = transfer->expected_contexts;
    value->context_alloc = report->delta.alloc;
    value->context_input_issued = report->delta.input_issued;
    value->context_array_retired = report->delta.array_retired;
    value->context_collector_done = report->delta.collector_done;
    value->context_gap_cycles = report->delta.context_gap;
    value->ifm_owner_stall_cycles = report->delta.ifm_owner_stall;
    value->weight_owner_stall_cycles = report->delta.weight_owner_stall;
    value->psum_credit_stall_cycles = report->delta.psum_credit_stall;
    value->stage_weight_cycles = c8_rd(runner, ACCEL_STAGE_WEIGHT);
    value->stage_feeder_cycles = c8_rd(runner, ACCEL_STAGE_FEEDER);
    value->stage_compute_cycles = c8_rd(runner, ACCEL_STAGE_COMPUTE);
    value->stage_drain_cycles = c8_rd(runner, ACCEL_STAGE_DRAIN);
    value->compute_fire = c8_rd(runner, ACCEL_COMP_FIRE);
    value->compute_idle_cycles = c8_rd(
        runner, ACCEL_PASS_COMPUTE_IDLE_STAGE);
    value->raw_load_active_cycles = c8_rd(runner, ACCEL_RAW_LOAD_ACTIVE);
    value->raw_replay_active_cycles = c8_rd(
        runner, ACCEL_RAW_REPLAY_ACTIVE);
    value->raw_replay_wait_cycles = c8_rd(
        runner, ACCEL_RAW_REPLAY_WAIT_READY);
    value->prefetch_hit = c8_rd(runner, ACCEL_PREFETCH_HIT);
    value->prefetch_miss = c8_rd(runner, ACCEL_PREFETCH_MISS);
    value->prefetch_stall_cycles = c8_rd(runner, ACCEL_PREFETCH_STALL);
    value->psum_overlap_hit = c8_rd(runner, ACCEL_PSUMOVL_HIT);
    value->psum_overlap_wait_cycles = c8_rd(
        runner, ACCEL_PSUMOVL_WAIT_PSUM);
    value->psum_overlap_underflow = c8_rd(
        runner, ACCEL_PSUMOVL_UNDERFLOW);
    value->drain_ready_stall_cycles = c8_rd(
        runner, ACCEL_DRAIN_READY_STALL);
    value->drain_internal_full_cycles = c8_rd(
        runner, ACCEL_DRAIN_INTERNAL_FULL);
    value->collector_full_stall_cycles = c8_rd(
        runner, ACCEL_COLLECT_CONTEXT_FULL_STALL);
    value->collector_empty_wait_cycles = c8_rd(
        runner, ACCEL_COLLECT_COLUMN_EMPTY_WAIT);
}

static int c8_dispatch_bound(coco80_accel_runner_t *runner, uint32_t layer,
                       const coco80_accel_layer_plan_t *plan,
                       const coco80_accel_layer_binding_t *binding,
                       const void *bias_data, const void *weight_data,
                       const void *ifm, uint32_t ifm_bytes,
                       uint32_t ifm_packets, uint32_t stream_config,
                       int raw_hwc, void *ofm, uint64_t *pl_ticks,
                       coco80_accel_extended_timing_t *extended)
{
    accel_v2_layer_transfer_t transfer;
    accel_v2_layer_report_t report;
    c8_program_cookie_t cookie;
    uint32_t counter_mismatch = 0U;
    uint64_t start, end;
    int rc;
    memset(&transfer, 0, sizeof(transfer));
    if (plan == NULL || binding == NULL || bias_data == NULL ||
        weight_data == NULL) return COCO80_ACCEL_ERR_ARGUMENT;
    cookie.runner = runner; cookie.layer = layer;
    cookie.plan = plan; cookie.binding = binding;
    cookie.stream_config = stream_config;
    cookie.ifm_bytes = ifm_bytes;
    cookie.ifm_packets = ifm_packets;
    transfer.bias_data = bias_data;
    transfer.bias_bytes = binding->bias_bytes;
    transfer.weight_data = weight_data;
    transfer.weight_bytes = binding->weight_bytes;
    transfer.ifm_data = ifm; transfer.ifm_bytes = ifm_bytes;
    transfer.ofm_data = ofm; transfer.ofm_bytes = plan->ofm_bytes;
    transfer.expected_contexts = plan->tile_count * plan->cout_blocks * plan->k_passes;
    transfer.program_layer = c8_program_layer; transfer.program_opaque = &cookie;
    start = runner->ticks(runner->ticks_opaque);
    rc = accel_v2_dispatch_layer(&runner->runtime, &transfer, &report);
    end = runner->ticks(runner->ticks_opaque);
    *pl_ticks += end - start;
    extended->pl_layer_ticks[layer] += end - start;
    if (rc != ACCEL_V2_RUN_OK) {
        return c8_fail(runner, COCO80_ACCEL_ERR_DISPATCH, rc, layer, &report);
    }
    c8_capture_layer_telemetry(
        runner, &transfer, &report, &extended->layer_telemetry[layer]);
    rc = c8_validate_counters(
        runner, plan, binding, ifm_bytes, ifm_packets, raw_hwc,
        &counter_mismatch);
    if (rc != COCO80_ACCEL_OK) {
        int recovery = accel_v2_runtime_recover(&runner->runtime);
        report.recovery_result = recovery;
        return c8_fail(runner, rc, (int)counter_mismatch, layer, &report);
    }
    return COCO80_ACCEL_OK;
}

static int c8_dispatch(coco80_accel_runner_t *runner, uint32_t layer,
                       const void *ifm, uint32_t ifm_bytes,
                       uint32_t ifm_packets, uint32_t stream_config,
                       int raw_hwc, void *ofm, uint64_t *pl_ticks,
                       coco80_accel_extended_timing_t *extended)
{
    const coco80_accel_layer_binding_t *binding = &runner->config->layers[layer];
    return c8_dispatch_bound(
        runner, layer, &c8_plan[layer], binding,
        runner->bias_image + binding->bias_offset,
        runner->weight_image + binding->weight_offset,
        ifm, ifm_bytes, ifm_packets, stream_config, raw_hwc, ofm,
        pl_ticks, extended);
}

static int c8_representative_layer(uint32_t layer)
{
    return layer == 0U || layer == 6U || layer == 7U || layer == 9U ||
        layer == 10U || layer == 11U || layer == 12U;
}

static int c8_representative_override_plan(
    uint32_t layer_index,
    const coco80_accel_representative_override_t *override,
    const coco80_accel_layer_binding_t *base_binding,
    coco80_accel_layer_plan_t *plan,
    coco80_accel_layer_binding_t *binding)
{
    const coco80_accel_layer_plan_t *base = &c8_plan[layer_index];
    uint64_t materialized, packed, bias_bytes, weight_bytes;
    uint32_t expected_tile_h, expected_kernel;
    if (override == NULL || base_binding == NULL || plan == NULL || binding == NULL ||
        override->bias_data == NULL || override->weight_data == NULL) {
        return COCO80_ACCEL_ERR_ARGUMENT;
    }
    *plan = *base;
    *binding = *base_binding;
    if (override->mode == COCO80_ACCEL_REP_OVERRIDE_SPARSE_3X3) {
        if (base->kernel != 1U ||
            (layer_index != 7U && layer_index != 9U &&
             layer_index != 11U && layer_index != 12U)) {
            return COCO80_ACCEL_ERR_CONFIG;
        }
        if (layer_index == 7U) expected_tile_h = 4U;
        else if (layer_index == 11U || layer_index == 12U) expected_tile_h = 8U;
        else expected_tile_h = base->tile_h;
        expected_kernel = 3U;
        plan->kernel = 3U;
        plan->pad = 1U;
    } else if (override->mode == COCO80_ACCEL_REP_OVERRIDE_TILE) {
        if ((layer_index == 6U && override->tile_h != 4U) ||
            (layer_index == 10U && override->tile_h != 3U) ||
            (layer_index != 6U && layer_index != 10U)) {
            return COCO80_ACCEL_ERR_CONFIG;
        }
        expected_tile_h = override->tile_h;
        expected_kernel = base->kernel;
    } else {
        return COCO80_ACCEL_ERR_CONFIG;
    }
    if (override->tile_h != expected_tile_h ||
        override->kernel != expected_kernel || expected_tile_h == 0U ||
        expected_tile_h > base->fm_h) {
        return COCO80_ACCEL_ERR_CONFIG;
    }
    plan->tile_h = (uint8_t)expected_tile_h;
    plan->k_total = (uint32_t)plan->cin * plan->kernel * plan->kernel;
    plan->k_passes = (plan->k_total + 17U) / 18U;
    plan->tile_count = ((uint32_t)plan->fm_h + plan->tile_h - 1U) /
        plan->tile_h;
    plan->max_tile_pixels = (uint32_t)plan->fm_w * plan->tile_h;
    plan->bias_packets = plan->tile_count * plan->cout_blocks;
    plan->weight_packets = plan->bias_packets * plan->k_passes;
    bias_bytes = (uint64_t)plan->bias_packets * 128U;
    weight_bytes = (uint64_t)plan->weight_packets * 576U;
    materialized = (uint64_t)plan->max_tile_pixels * plan->k_passes;
    packed = (uint64_t)plan->max_tile_pixels * plan->cout_blocks;
    if (plan->max_tile_pixels > 1024U || materialized > 32768U ||
        packed > 4096U || bias_bytes > UINT32_MAX || weight_bytes > UINT32_MAX ||
        override->bias_packets != plan->bias_packets ||
        override->weight_packets != plan->weight_packets ||
        override->bias_bytes != (uint32_t)bias_bytes ||
        override->weight_bytes != (uint32_t)weight_bytes) {
        return COCO80_ACCEL_ERR_PLAN;
    }
    plan->bias_bytes = override->bias_bytes;
    plan->weight_bytes = override->weight_bytes;
    binding->bias_bytes = override->bias_bytes;
    binding->weight_bytes = override->weight_bytes;
    binding->bias_packets = override->bias_packets;
    binding->weight_packets = override->weight_packets;
    return COCO80_ACCEL_OK;
}

#if defined(COCO80_ABLATION_VARIANT_A0) && COCO80_ABLATION_VARIANT_A0 == 1
static int c8_a0_stream_geometry(
    const coco80_accel_layer_plan_t *plan,
    uint32_t *bytes,
    uint32_t *packets)
{
    uint32_t base_y;
    uint64_t total_bytes = 0U;
    uint64_t total_packets = 0U;
    if (plan == NULL || bytes == NULL || packets == NULL) {
        return COCO80_ACCEL_ERR_ARGUMENT;
    }
    for (base_y = 0U; base_y < plan->fm_h; base_y += plan->tile_h) {
        uint32_t active_h = plan->fm_h - base_y;
        if (active_h > plan->tile_h) active_h = plan->tile_h;
        if (plan->kernel == 1U) {
            uint64_t tile_packets =
                (uint64_t)plan->k_passes * plan->cout_blocks;
            total_packets += tile_packets;
            total_bytes += tile_packets * active_h * plan->fm_w * 24U;
        } else {
            uint32_t first_y = base_y > plan->pad ? base_y - plan->pad : 0U;
            uint32_t last_y = base_y + active_h - 1U + plan->pad;
            uint64_t tile_packets;
            if (last_y >= plan->fm_h) last_y = plan->fm_h - 1U;
            tile_packets = (uint64_t)(last_y - first_y + 1U) *
                plan->k_passes * plan->cout_blocks;
            total_packets += tile_packets;
            total_bytes += tile_packets * plan->fm_w * OFM_AXIS_BEAT_BYTES;
        }
    }
    if (total_bytes == 0U || total_bytes > UINT32_MAX ||
        total_packets == 0U || total_packets > UINT32_MAX) {
        return COCO80_ACCEL_ERR_PLAN;
    }
    *bytes = (uint32_t)total_bytes;
    *packets = (uint32_t)total_packets;
    return COCO80_ACCEL_OK;
}
#endif

int coco80_accel_run_representative_layer(
    coco80_accel_runner_t *runner, uint32_t layer_index,
    coco80_accel_layer_input_mode_t input_mode,
    const void *ifm, uint32_t ifm_bytes, void *ofm, uint32_t ofm_bytes,
    uint32_t image_id,
    const coco80_accel_representative_override_t *override,
    coco80_accel_extended_timing_t *timing)
{
    const coco80_accel_layer_plan_t *plan;
    const coco80_accel_layer_binding_t *binding;
    const void *bias_data;
    const void *weight_data;
    coco80_accel_layer_plan_t custom_plan;
    coco80_accel_layer_binding_t custom_binding;
    uint32_t expected_ifm_bytes;
    uint32_t expected_ifm_packets;
    uint32_t stream_config;
    int raw_hwc;
    int rc;
    if (runner == NULL || !runner->initialized || ifm == NULL || ofm == NULL ||
        timing == NULL || image_id == 0U || !c8_representative_layer(layer_index)) {
        return COCO80_ACCEL_ERR_ARGUMENT;
    }
    plan = &c8_plan[layer_index];
    binding = &runner->config->layers[layer_index];
    bias_data = runner->bias_image + binding->bias_offset;
    weight_data = runner->weight_image + binding->weight_offset;
    if (override != NULL) {
        rc = c8_representative_override_plan(
            layer_index, override, binding, &custom_plan, &custom_binding);
        if (rc != COCO80_ACCEL_OK) return rc;
        plan = &custom_plan;
        binding = &custom_binding;
        bias_data = override->bias_data;
        weight_data = override->weight_data;
    }
    if (ofm_bytes != plan->ofm_bytes) return COCO80_ACCEL_ERR_ARGUMENT;
    if (input_mode == COCO80_ACCEL_LAYER_INPUT_RAW_HWC) {
#if defined(COCO80_ABLATION_VARIANT_A0) && COCO80_ABLATION_VARIANT_A0 == 1
        return COCO80_ACCEL_ERR_CONFIG;
#else
        expected_ifm_bytes = plan->ifm_bytes;
        expected_ifm_packets = 1U;
        stream_config = runner->stream_config;
        raw_hwc = 1;
#endif
    } else if (input_mode == COCO80_ACCEL_LAYER_INPUT_A0_PREPACKED) {
#if !defined(COCO80_ABLATION_VARIANT_A0) || COCO80_ABLATION_VARIANT_A0 != 1
        return COCO80_ACCEL_ERR_CONFIG;
#else
        rc = c8_a0_stream_geometry(
            plan, &expected_ifm_bytes, &expected_ifm_packets);
        if (rc != COCO80_ACCEL_OK) return rc;
        stream_config = COCO80_ACCEL_A0_PREPACKED_STREAM_CONFIG;
        raw_hwc = 0;
#endif
    } else {
        return COCO80_ACCEL_ERR_ARGUMENT;
    }
    if (ifm_bytes != expected_ifm_bytes) return COCO80_ACCEL_ERR_ARGUMENT;
    memset(timing, 0, sizeof(*timing));
    timing->magic = COCO80_ACCEL_EXTENDED_TIMING_MAGIC;
    timing->version = COCO80_ACCEL_EXTENDED_TIMING_VERSION;
    timing->bytes = COCO80_ACCEL_EXTENDED_TIMING_BYTES;
    timing->image_id = image_id;
    timing->sequence = ++runner->sequence;
    timing->tick_hz = runner->tick_hz;
    timing->output_kind = COCO80_ACCEL_OUTPUT_RAW;
    timing->decode_profile = COCO80_ACCEL_DECODE_DEMO;
    timing->stream_config = stream_config;
    timing->telemetry_layer_count = COCO80_ACCEL_LAYER_COUNT;
    timing->telemetry_record_bytes = COCO80_ACCEL_LAYER_TELEMETRY_BYTES;
    rc = c8_dispatch_bound(
        runner, layer_index, plan, binding, bias_data, weight_data,
        ifm, ifm_bytes, expected_ifm_packets,
        stream_config, raw_hwc, ofm, &timing->pl_ticks, timing);
    if (rc != COCO80_ACCEL_OK) return rc;
    timing->total_ticks = timing->pl_ticks;
    timing->pl_dispatches = 1U;
    timing->output_crc32 = coco80_sd_crc32(ofm, ofm_bytes);
    if (timing->output_crc32 == 0U) return COCO80_ACCEL_ERR_PACKAGE;
    return COCO80_ACCEL_OK;
}

static coco80_hwc_u8_t c8_tensor(uint8_t *data, uint32_t h, uint32_t w, uint32_t c)
{
    coco80_hwc_u8_t tensor;
    tensor.height = h; tensor.width = w; tensor.channels = c;
    tensor.bytes = h * w * c; tensor.data = data;
    return tensor;
}

static int c8_pool_s2(uint8_t *source, uint32_t h, uint32_t w, uint32_t c,
                      uint8_t *destination)
{
    coco80_hwc_u8_t input = c8_tensor(source, h, w, c);
    coco80_hwc_u8_t output = c8_tensor(destination, h / 2U, w / 2U, c);
    return coco80_maxpool2x2_s2(&input, &output);
}

static uint32_t c8_decode_config_crc(const coco80_decode_config_t *config)
{
    uint32_t words[5];
    words[0] = coco80_sd_float_to_bits(config->confidence_threshold);
    words[1] = coco80_sd_float_to_bits(config->iou_threshold);
    words[2] = config->max_nms; words[3] = config->max_detections;
    words[4] = config->multi_label;
    return coco80_sd_crc32(words, sizeof(words));
}

static int c8_make_packages(coco80_accel_runner_t *runner,
                            const void *input_package,
                            const coco80_sd_input_header_t *input,
                            uint32_t input_crc, coco80_accel_mode_t mode,
                            const coco80_decode_config_t *decode_config,
                            const coco80_decode_result_t *decode_result,
                            const coco80_accel_timing_record_t *timing,
                            coco80_accel_output_t *output)
{
    coco80_accel_workspace_t *ws = runner->workspace;
    coco80_sd_raw_head_header_t *raw = (coco80_sd_raw_head_header_t *)ws->raw_package;
    coco80_sd_detection_header_t *det = (coco80_sd_detection_header_t *)ws->detection_package;
    coco80_sd_result_header_t *result = (coco80_sd_result_header_t *)ws->result_package;
    uint32_t records_bytes = decode_result->detection_count * COCO80_SD_DETECTION_RECORD_BYTES;
    uint32_t det_bytes = COCO80_SD_HEADER_BYTES + records_bytes;
    uint32_t result_bytes = det_bytes + COCO80_ACCEL_TIMING_RECORD_BYTES;
    uint32_t index, raw_crc, det_crc;
    int rc;
    memset(raw, 0, COCO80_SD_HEADER_BYTES);
    raw->common.magic = COCO80_SD_MAGIC_RAW_HEADS;
    raw->common.header_bytes = COCO80_SD_HEADER_BYTES;
    raw->common.payload_offset = COCO80_SD_HEADER_BYTES;
    raw->common.payload_bytes = COCO80_P4_TENSOR_BYTES + COCO80_P5_TENSOR_BYTES;
    raw->model_width = COCO80_MODEL_WIDTH; raw->model_height = COCO80_MODEL_HEIGHT;
    raw->class_count = COCO80_CLASS_COUNT; raw->values_per_anchor = COCO80_VALUES_PER_ANCHOR;
    raw->anchors_per_head = COCO80_ANCHORS_PER_HEAD; raw->head_count = COCO80_HEAD_COUNT;
    raw->p4.width = COCO80_P4_GRID_WIDTH; raw->p4.height = COCO80_P4_GRID_HEIGHT;
    raw->p4.channels = COCO80_HEAD_CHANNELS; raw->p4.offset = COCO80_SD_HEADER_BYTES;
    raw->p4.bytes = COCO80_P4_TENSOR_BYTES;
    raw->p4.scale_f32 = runner->config->layers[11].output_scale_f32;
    raw->p4.zero_point = runner->config->layers[11].output_zero_point;
    raw->p4.crc32 = coco80_sd_crc32(ws->raw_package + raw->p4.offset, raw->p4.bytes);
    raw->p5.width = COCO80_P5_GRID_WIDTH; raw->p5.height = COCO80_P5_GRID_HEIGHT;
    raw->p5.channels = COCO80_HEAD_CHANNELS; raw->p5.offset = raw->p4.offset + raw->p4.bytes;
    raw->p5.bytes = COCO80_P5_TENSOR_BYTES;
    raw->p5.scale_f32 = runner->config->layers[12].output_scale_f32;
    raw->p5.zero_point = runner->config->layers[12].output_zero_point;
    raw->p5.crc32 = coco80_sd_crc32(ws->raw_package + raw->p5.offset, raw->p5.bytes);
    raw->input_package_crc32 = input_crc;
    raw->parameter_package_crc32 = runner->parameter_package_crc32;
    rc = coco80_sd_seal_package(raw, COCO80_ACCEL_RAW_PACKAGE_BYTES);
    if (rc != COCO80_SD_OK ||
        coco80_sd_validate_raw_heads(raw, COCO80_ACCEL_RAW_PACKAGE_BYTES, NULL) != COCO80_SD_OK)
        return COCO80_ACCEL_ERR_PACKAGE;
    raw_crc = coco80_sd_crc32(raw, COCO80_ACCEL_RAW_PACKAGE_BYTES);

    memset(det, 0, COCO80_SD_HEADER_BYTES);
    det->common.magic = COCO80_SD_MAGIC_DETECTIONS;
    det->common.header_bytes = COCO80_SD_HEADER_BYTES;
    det->common.payload_offset = COCO80_SD_HEADER_BYTES;
    det->common.payload_bytes = records_bytes;
    det->image_id = input->image_id; det->detection_count = decode_result->detection_count;
    det->record_bytes = COCO80_SD_DETECTION_RECORD_BYTES;
    det->max_nms = decode_config->max_nms; det->max_detections = decode_config->max_detections;
    det->class_count = COCO80_CLASS_COUNT;
    det->coordinate_space = COCO80_SD_COORDINATES_ORIGINAL_XYXY;
    det->raw_head_package_crc32 = raw_crc; det->input_package_crc32 = input_crc;
    det->records.offset = COCO80_SD_HEADER_BYTES; det->records.bytes = records_bytes;
    det->confidence_threshold_f32 = coco80_sd_float_to_bits(decode_config->confidence_threshold);
    det->iou_threshold_f32 = coco80_sd_float_to_bits(decode_config->iou_threshold);
    det->multi_label = decode_config->multi_label; det->nms_kind = COCO80_SD_NMS_CLASS_AWARE;
    det->decode_config_crc32 = c8_decode_config_crc(decode_config);
    det->preprocess_crc32 = input_crc;
    for (index = 0U; index < decode_result->detection_count; ++index) {
        const coco80_detection_t *source = &ws->detections[index];
        coco80_sd_detection_record_t record;
        memset(&record, 0, sizeof(record));
        record.image_id = input->image_id;
        record.x1_f32 = coco80_sd_float_to_bits(source->original_x1);
        record.y1_f32 = coco80_sd_float_to_bits(source->original_y1);
        record.x2_f32 = coco80_sd_float_to_bits(source->original_x2);
        record.y2_f32 = coco80_sd_float_to_bits(source->original_y2);
        record.score_f32 = coco80_sd_float_to_bits(source->score);
        record.class_id = source->class_id; record.coco_category_id = source->coco_category_id;
        record.source_index = source->source_index; record.head_id = source->head_id;
        record.anchor_id = source->anchor_id; record.grid_x = source->grid_x; record.grid_y = source->grid_y;
        memcpy(ws->detection_package + COCO80_SD_HEADER_BYTES +
               index * sizeof(record), &record, sizeof(record));
    }
    det->records.crc32 = coco80_sd_crc32(ws->detection_package + det->records.offset, records_bytes);
    if (coco80_sd_seal_package(det, det_bytes) != COCO80_SD_OK ||
        coco80_sd_validate_detections(det, det_bytes, NULL) != COCO80_SD_OK)
        return COCO80_ACCEL_ERR_PACKAGE;
    det_crc = coco80_sd_crc32(det, det_bytes);

    memset(result, 0, COCO80_SD_HEADER_BYTES);
    result->common.magic = COCO80_SD_MAGIC_RESULT;
    result->common.header_bytes = COCO80_SD_HEADER_BYTES;
    result->common.payload_offset = COCO80_SD_HEADER_BYTES;
    result->common.payload_bytes = records_bytes + COCO80_ACCEL_TIMING_RECORD_BYTES;
    result->run_id_low = runner->sequence; result->run_id_high = input->image_id;
    result->image_count = 1U; result->detection_count = decode_result->detection_count;
    result->status = COCO80_SD_RESULT_SUCCESS; result->error_code = 0U;
    result->clock_hz = runner->config->expected_clock_hz;
    result->detections.offset = COCO80_SD_HEADER_BYTES; result->detections.bytes = records_bytes;
    memcpy(ws->result_package + result->detections.offset,
           ws->detection_package + det->records.offset, records_bytes);
    result->detections.crc32 = coco80_sd_crc32(
        ws->result_package + result->detections.offset, records_bytes);
    result->timings.offset = result->detections.offset + records_bytes;
    result->timings.bytes = COCO80_ACCEL_TIMING_RECORD_BYTES;
    memcpy(ws->result_package + result->timings.offset, timing, sizeof(*timing));
    result->timings.crc32 = coco80_sd_crc32(
        ws->result_package + result->timings.offset, result->timings.bytes);
    result->input_package_crc32 = input_crc;
    result->parameter_package_crc32 = runner->parameter_package_crc32;
    result->raw_head_package_crc32 = raw_crc; result->detection_package_crc32 = det_crc;
    result->software_build_crc32 = runner->config->software_build_crc32;
    result->hardware_build_crc32 = runner->config->hardware_build_crc32;
    if (coco80_sd_seal_package(result, result_bytes) != COCO80_SD_OK ||
        coco80_sd_validate_result(result, result_bytes, NULL) != COCO80_SD_OK ||
        coco80_sd_validate_pipeline_prevalidated_parameters(
            input_package, COCO80_ACCEL_INPUT_PACKAGE_BYTES,
            runner->parameter_package_crc32,
            raw, COCO80_ACCEL_RAW_PACKAGE_BYTES,
            det, det_bytes, result, result_bytes) != COCO80_SD_OK) {
        return COCO80_ACCEL_ERR_PACKAGE;
    }
    (void)mode;
    output->image_id = input->image_id; output->detection_count = decode_result->detection_count;
    output->raw_head_package = raw; output->raw_head_package_bytes = COCO80_ACCEL_RAW_PACKAGE_BYTES;
    output->detection_package = det; output->detection_package_bytes = det_bytes;
    output->result_package = result; output->result_package_bytes = result_bytes;
    output->timing = *timing;
    return COCO80_ACCEL_OK;
}

int coco80_accel_infer_package_ex(
    coco80_accel_runner_t *runner, const void *input_package,
    uint32_t input_package_bytes, const coco80_accel_infer_options_t *options,
    coco80_accel_output_t *output)
{
#if defined(COCO80_ABLATION_VARIANT_A0) && COCO80_ABLATION_VARIANT_A0 == 1
    (void)runner;
    (void)input_package;
    (void)input_package_bytes;
    (void)options;
    (void)output;
    return COCO80_ACCEL_ERR_CONFIG;
#else
    coco80_accel_workspace_t *ws;
    coco80_sd_input_header_t input;
    const uint8_t *input_tensor;
    coco80_decode_config_t decode_config;
    coco80_quantized_head_t heads[COCO80_HEAD_COUNT];
    coco80_letterbox_t letterbox;
    coco80_decode_workspace_t decode_ws;
    coco80_decode_result_t decode_result;
    coco80_decode_timing_t decode_timing;
    coco80_accel_timing_record_t timing;
    coco80_accel_extended_timing_t extended;
    uint64_t total_start, a53_start, decode_start;
    uint32_t input_crc;
    int rc;
    if (runner == NULL || !runner->initialized || input_package == NULL ||
        options == NULL || output == NULL ||
        input_package_bytes != COCO80_ACCEL_INPUT_PACKAGE_BYTES ||
        options->output_kind > COCO80_ACCEL_OUTPUT_TIMING ||
        options->decode_profile > COCO80_ACCEL_DECODE_DEMO) {
        return COCO80_ACCEL_ERR_ARGUMENT;
    }
    memset(output, 0, sizeof(*output));
    memset(&timing, 0, sizeof(timing));
    memset(&extended, 0, sizeof(extended));
    memset(&decode_timing, 0, sizeof(decode_timing));
    rc = coco80_sd_validate_input(input_package, input_package_bytes, &input);
    if (rc != COCO80_SD_OK || input.input_scale_f32 != runner->config->layers[0].input_scale_f32 ||
        input.input_zero_point != runner->config->layers[0].input_zero_point) {
        return c8_fail(runner, COCO80_ACCEL_ERR_INPUT, rc, UINT32_MAX, NULL);
    }
    input_crc = coco80_sd_crc32(input_package, input_package_bytes);
    if (input_crc == 0U) return c8_fail(runner, COCO80_ACCEL_ERR_INPUT, -1, UINT32_MAX, NULL);
    ws = runner->workspace;
    input_tensor = (const uint8_t *)input_package + COCO80_SD_HEADER_BYTES;
    rc = c8_hook(runner, COCO80_ACCEL_TENSOR_INPUT, input_tensor,
                 COCO80_MODEL_WIDTH * COCO80_MODEL_HEIGHT * 3U);
    if (rc != COCO80_ACCEL_OK) return rc;
    runner->sequence += 1U; if (runner->sequence == 0U) runner->sequence = 1U;
    total_start = runner->ticks(runner->ticks_opaque);
#define C8_PL(layer, src, dst) do { rc = c8_dispatch(runner, layer, src, c8_plan[(layer)].ifm_bytes, 1U, runner->stream_config, 1, dst, &timing.pl_ticks, &extended); if (rc) return rc; } while (0)
#define C8_A53(op, expr) do { uint64_t c8_elapsed; a53_start = runner->ticks(runner->ticks_opaque); rc = (expr); c8_elapsed = runner->ticks(runner->ticks_opaque) - a53_start; timing.a53_ticks += c8_elapsed; extended.a53_op_ticks[(op)] += c8_elapsed; if (rc != COCO80_TENSOR_OK) return c8_fail(runner, COCO80_ACCEL_ERR_TENSOR, rc, UINT32_MAX, NULL); } while (0)
#define C8_HOOK(id, data, bytes) do { rc = c8_hook(runner, id, data, bytes); if (rc) return rc; } while (0)
    C8_PL(0U, input_tensor, ws->slot0);
    C8_HOOK(COCO80_ACCEL_TENSOR_POOL1, ws->slot0, 692224U);
    C8_PL(1U, ws->slot0, ws->slot1);
    C8_HOOK(COCO80_ACCEL_TENSOR_POOL3, ws->slot1, 346112U);
    C8_PL(2U, ws->slot1, ws->slot0);
    C8_HOOK(COCO80_ACCEL_TENSOR_POOL5, ws->slot0, 173056U);
    C8_PL(3U, ws->slot0, ws->slot1);
    C8_HOOK(COCO80_ACCEL_TENSOR_POOL7, ws->slot1, 86528U);
    C8_PL(4U, ws->slot1, ws->route_m8);
    C8_HOOK(COCO80_ACCEL_TENSOR_M8, ws->route_m8, 173056U);
    if (runner->tensor_backend.pool_s2 != NULL) {
        coco80_hwc_u8_t source = c8_tensor(ws->route_m8, 26U, 26U, 256U);
        coco80_hwc_u8_t dest = c8_tensor(ws->slot1, 13U, 13U, 256U);
        C8_A53(COCO80_ACCEL_A53_POOL9,
               runner->tensor_backend.pool_s2(
                   runner->tensor_backend.opaque, &source, &dest));
    } else {
        C8_A53(COCO80_ACCEL_A53_POOL9,
               c8_pool_s2(ws->route_m8, 26U, 26U, 256U, ws->slot1));
    }
    C8_HOOK(COCO80_ACCEL_TENSOR_POOL9, ws->slot1, 43264U);
    C8_PL(5U, ws->slot1, ws->slot0);
    C8_HOOK(COCO80_ACCEL_TENSOR_M10, ws->slot0, 86528U);
    {
        coco80_hwc_u8_t source = c8_tensor(ws->slot0, 13U, 13U, 512U);
        coco80_hwc_u8_t dest = c8_tensor(ws->slot1, 13U, 13U, 512U);
        if (runner->tensor_backend.pool_s1_pad != NULL) {
            C8_A53(COCO80_ACCEL_A53_POOL12,
                   runner->tensor_backend.pool_s1_pad(
                       runner->tensor_backend.opaque, &source,
                       (uint8_t)runner->config->layers[5].output_zero_point,
                       &dest));
        } else {
            C8_A53(COCO80_ACCEL_A53_POOL12,
                   coco80_maxpool2x2_s1_pad_right_bottom(
                       &source,
                       (uint8_t)runner->config->layers[5].output_zero_point,
                       &dest));
        }
    }
    C8_HOOK(COCO80_ACCEL_TENSOR_POOL12, ws->slot1, 86528U);
    C8_PL(6U, ws->slot1, ws->slot0);
    C8_HOOK(COCO80_ACCEL_TENSOR_M13, ws->slot0, 173056U);
    C8_PL(7U, ws->slot0, ws->slot1);
    C8_HOOK(COCO80_ACCEL_TENSOR_M14, ws->slot1, 43264U);
    C8_PL(8U, ws->slot1, ws->route_m15);
    C8_HOOK(COCO80_ACCEL_TENSOR_M15, ws->route_m15, 86528U);
    C8_PL(9U, ws->slot1, ws->slot0);
    C8_HOOK(COCO80_ACCEL_TENSOR_M16, ws->slot0, 21632U);
    {
        coco80_hwc_u8_t small = c8_tensor(ws->slot0, 13U, 13U, 128U);
        coco80_hwc_u8_t route = c8_tensor(ws->route_m8, 26U, 26U, 256U);
        coco80_hwc_u8_t dest = c8_tensor(ws->concat18, 26U, 26U, 384U);
        if (runner->tensor_hook != NULL) {
            coco80_hwc_u8_t upsampled = c8_tensor(ws->slot1, 26U, 26U, 128U);
            C8_A53(COCO80_ACCEL_A53_UPSAMPLE17,
                   coco80_nearest2x(&small, &upsampled));
            C8_HOOK(COCO80_ACCEL_TENSOR_UPSAMPLE17, ws->slot1, 86528U);
            C8_A53(COCO80_ACCEL_A53_REQUANT_CONCAT18,
                   coco80_requant_concat(
                       &upsampled, &route,
                       (int32_t)runner->config->route_input_zero_point,
                       (int32_t)runner->config->route_output_zero_point,
                       runner->config->route_multiplier,
                       runner->config->route_shift, &dest));
        } else {
            if (runner->tensor_backend.nearest_requant_concat != NULL) {
                C8_A53(COCO80_ACCEL_A53_REQUANT_CONCAT18,
                       runner->tensor_backend.nearest_requant_concat(
                           runner->tensor_backend.opaque, &small, &route,
                           (int32_t)runner->config->route_input_zero_point,
                           (int32_t)runner->config->route_output_zero_point,
                           runner->config->route_multiplier,
                           runner->config->route_shift, &dest));
            } else {
                C8_A53(COCO80_ACCEL_A53_REQUANT_CONCAT18,
                       coco80_nearest2x_requant_concat(
                           &small, &route,
                           (int32_t)runner->config->route_input_zero_point,
                           (int32_t)runner->config->route_output_zero_point,
                           runner->config->route_multiplier,
                           runner->config->route_shift, &dest));
            }
        }
    }
    C8_HOOK(COCO80_ACCEL_TENSOR_CONCAT18, ws->concat18, 259584U);
    C8_PL(10U, ws->concat18, ws->slot0);
    C8_HOOK(COCO80_ACCEL_TENSOR_M19, ws->slot0, 173056U);
    C8_PL(11U, ws->slot0, ws->raw_package + COCO80_SD_HEADER_BYTES);
    C8_HOOK(COCO80_ACCEL_TENSOR_P4,
            ws->raw_package + COCO80_SD_HEADER_BYTES, COCO80_P4_TENSOR_BYTES);
    /*
     * P4 is 172380 bytes, so a tightly packed P5 destination would be only
     * four-byte aligned.  The 64-bit S2MM has no DRE: receive into the aligned
     * reusable slot, then preserve the on-card protocol's tight P4/P5 layout.
     */
    C8_PL(12U, ws->route_m15, ws->slot1);
    a53_start = runner->ticks(runner->ticks_opaque);
    memcpy(ws->raw_package + COCO80_SD_HEADER_BYTES + COCO80_P4_TENSOR_BYTES,
           ws->slot1, COCO80_P5_TENSOR_BYTES);
    {
        uint64_t elapsed = runner->ticks(runner->ticks_opaque) - a53_start;
        timing.a53_ticks += elapsed;
        extended.a53_op_ticks[COCO80_ACCEL_A53_P5_COPY] += elapsed;
    }
    C8_HOOK(COCO80_ACCEL_TENSOR_P5,
            ws->raw_package + COCO80_SD_HEADER_BYTES + COCO80_P4_TENSOR_BYTES,
            COCO80_P5_TENSOR_BYTES);
#undef C8_PL
#undef C8_A53
#undef C8_HOOK
    if (options->decode_profile == COCO80_ACCEL_DECODE_ACCURACY) {
        coco80_decode_config_accuracy(&decode_config);
    } else {
        coco80_decode_config_demo(&decode_config);
    }
    heads[0].data = ws->raw_package + COCO80_SD_HEADER_BYTES;
    heads[0].bytes = COCO80_P4_TENSOR_BYTES;
    heads[0].scale = coco80_sd_bits_to_float(runner->config->layers[11].output_scale_f32);
    heads[0].zero_point = (int32_t)runner->config->layers[11].output_zero_point;
    heads[1].data = heads[0].data + COCO80_P4_TENSOR_BYTES;
    heads[1].bytes = COCO80_P5_TENSOR_BYTES;
    heads[1].scale = coco80_sd_bits_to_float(runner->config->layers[12].output_scale_f32);
    heads[1].zero_point = (int32_t)runner->config->layers[12].output_zero_point;
    letterbox.original_width = input.original_width; letterbox.original_height = input.original_height;
    letterbox.scale = coco80_sd_bits_to_float(input.letterbox_scale_f32);
    letterbox.pad_x = coco80_sd_bits_to_float(input.pad_x_f32);
    letterbox.pad_y = coco80_sd_bits_to_float(input.pad_y_f32);
    decode_ws.candidates = ws->decode_candidates; decode_ws.capacity = COCO80_ACCURACY_MAX_NMS;
    decode_start = runner->ticks(runner->ticks_opaque);
    rc = coco80_decode_dual_head_profiled(
        heads, &letterbox, &decode_config, &decode_ws,
        ws->detections, COCO80_ACCURACY_MAX_DETECTIONS, &decode_result,
        runner->ticks, runner->ticks_opaque, &decode_timing);
    timing.decode_ticks = runner->ticks(runner->ticks_opaque) - decode_start;
    timing.a53_ticks += timing.decode_ticks;
    if (rc != COCO80_DECODE_OK) return c8_fail(runner, COCO80_ACCEL_ERR_DECODE, rc, UINT32_MAX, NULL);
    timing.total_ticks = runner->ticks(runner->ticks_opaque) - total_start;
    timing.tick_hz = runner->tick_hz; timing.layer_count = COCO80_ACCEL_LAYER_COUNT;
    timing.mode = options->output_kind; timing.image_id = input.image_id;
    timing.detection_count = decode_result.detection_count; timing.sequence = runner->sequence;
    timing.pl_dispatches = COCO80_ACCEL_LAYER_COUNT;
    extended.magic = COCO80_ACCEL_EXTENDED_TIMING_MAGIC;
    extended.version = COCO80_ACCEL_EXTENDED_TIMING_VERSION;
    extended.bytes = COCO80_ACCEL_EXTENDED_TIMING_BYTES;
    extended.stream_config = runner->stream_config;
    extended.telemetry_layer_count = COCO80_ACCEL_LAYER_COUNT;
    extended.telemetry_record_bytes = COCO80_ACCEL_LAYER_TELEMETRY_BYTES;
    extended.image_id = input.image_id;
    extended.sequence = runner->sequence;
    extended.tick_hz = runner->tick_hz;
    extended.output_kind = options->output_kind;
    extended.decode_profile = options->decode_profile;
    extended.total_ticks = timing.total_ticks;
    extended.pl_ticks = timing.pl_ticks;
    extended.a53_ticks = timing.a53_ticks;
    extended.decode_ticks = timing.decode_ticks;
    extended.candidate_ticks = decode_timing.candidate_ticks;
    extended.sort_ticks = decode_timing.sort_ticks;
    extended.nms_ticks = decode_timing.nms_ticks;
    extended.detection_count = decode_result.detection_count;
    extended.pl_dispatches = COCO80_ACCEL_LAYER_COUNT;
    extended.status = COCO80_ACCEL_OK;
    rc = c8_make_packages(runner, input_package, &input, input_crc,
                          (coco80_accel_mode_t)options->output_kind, &decode_config,
                          &decode_result, &timing, output);
    if (rc != COCO80_ACCEL_OK) return c8_fail(runner, rc, 0, UINT32_MAX, NULL);
    if (options->output_kind == COCO80_ACCEL_OUTPUT_RAW) {
        extended.output_crc32 = coco80_sd_crc32(
            output->raw_head_package, output->raw_head_package_bytes);
    } else {
        /* Timing-only runs still fingerprint the product detections. */
        extended.output_crc32 = coco80_sd_crc32(
            output->detection_package, output->detection_package_bytes);
    }
    if (extended.output_crc32 == 0U) {
        return c8_fail(runner, COCO80_ACCEL_ERR_PACKAGE, -1, UINT32_MAX, NULL);
    }
    output->extended_timing = extended;
    memset(&runner->failure, 0, sizeof(runner->failure));
    return COCO80_ACCEL_OK;
#endif
}

int coco80_accel_infer_package(
    coco80_accel_runner_t *runner, const void *input_package,
    uint32_t input_package_bytes, coco80_accel_mode_t mode,
    coco80_accel_output_t *output)
{
    coco80_accel_infer_options_t options;
    if (mode > COCO80_ACCEL_MODE_PERFORMANCE) {
        return COCO80_ACCEL_ERR_ARGUMENT;
    }
    if (mode == COCO80_ACCEL_MODE_ACCURACY) {
        options.output_kind = COCO80_ACCEL_OUTPUT_RAW;
        options.decode_profile = COCO80_ACCEL_DECODE_ACCURACY;
    } else if (mode == COCO80_ACCEL_MODE_PRODUCT) {
        options.output_kind = COCO80_ACCEL_OUTPUT_DETECTIONS;
        options.decode_profile = COCO80_ACCEL_DECODE_DEMO;
    } else {
        options.output_kind = COCO80_ACCEL_OUTPUT_TIMING;
        options.decode_profile = COCO80_ACCEL_DECODE_DEMO;
    }
    return coco80_accel_infer_package_ex(
        runner, input_package, input_package_bytes, &options, output);
}

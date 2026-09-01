#include "coco80_net_protocol.h"

#include <stddef.h>
#include <string.h>

typedef char c8_net_header_size[
    sizeof(coco80_net_header_t) == COCO80_NET_HEADER_BYTES ? 1 : -1];
typedef char c8_net_hello_size[
    sizeof(coco80_net_hello_t) == COCO80_NET_HELLO_BYTES ? 1 : -1];
typedef char c8_net_end_size[
    sizeof(coco80_net_end_t) == COCO80_NET_END_BYTES ? 1 : -1];
typedef char c8_net_result_prefix_size[
    sizeof(coco80_net_result_prefix_t) == COCO80_NET_RESULT_PREFIX_BYTES ? 1 : -1];
typedef char c8_net_representative_size[
    sizeof(coco80_net_representative_header_t) == COCO80_NET_REP_HEADER_BYTES ? 1 : -1];
typedef char c8_net_chunk_timing_size[
    sizeof(coco80_net_chunk_timing_t) == COCO80_NET_CHUNK_TIMING_BYTES ? 1 : -1];

int coco80_net_hash_nonzero(const uint32_t hash[8])
{
    uint32_t index;
    uint32_t value = 0U;
    if (hash == NULL) {
        return 0;
    }
    for (index = 0U; index < 8U; ++index) {
        value |= hash[index];
    }
    return value != 0U;
}

uint32_t coco80_net_representative_header_crc32(
    const coco80_net_representative_header_t *header)
{
    coco80_net_representative_header_t canonical;
    if (header == NULL) return 0U;
    canonical = *header;
    canonical.header_crc32 = 0U;
    return coco80_sd_crc32(&canonical, sizeof(canonical));
}

int coco80_net_seal_representative(
    coco80_net_representative_header_t *header, const void *payload)
{
    uint32_t payload_bytes;
    if (header == NULL || header->header_bytes != COCO80_NET_REP_HEADER_BYTES ||
        header->total_bytes < COCO80_NET_REP_HEADER_BYTES) {
        return COCO80_NET_ERR_ARGUMENT;
    }
    payload_bytes = header->total_bytes - COCO80_NET_REP_HEADER_BYTES;
    if ((payload_bytes != 0U && payload == NULL) ||
        (header->magic == COCO80_NET_REP_INPUT_MAGIC &&
         payload_bytes != header->ifm_bytes + header->bias_bytes +
             header->weight_bytes) ||
        (header->magic == COCO80_NET_REP_OUTPUT_MAGIC &&
         (header->ifm_bytes != 0U || header->bias_bytes != 0U ||
          header->weight_bytes != 0U || payload_bytes != header->ofm_bytes))) {
        return COCO80_NET_ERR_LENGTH;
    }
    header->payload_crc32 = coco80_sd_crc32(payload, payload_bytes);
    header->header_crc32 = 0U;
    header->header_crc32 = coco80_net_representative_header_crc32(header);
    return COCO80_NET_OK;
}

int coco80_net_validate_representative(
    const void *package, uint32_t package_bytes, uint32_t expected_magic)
{
    const coco80_net_representative_header_t *header =
        (const coco80_net_representative_header_t *)package;
    const uint8_t *payload;
    uint32_t payload_bytes;
    uint32_t index;
    if (package == NULL || package_bytes < COCO80_NET_REP_HEADER_BYTES ||
        (expected_magic != COCO80_NET_REP_INPUT_MAGIC &&
         expected_magic != COCO80_NET_REP_OUTPUT_MAGIC)) {
        return COCO80_NET_ERR_ARGUMENT;
    }
    if (header->magic != expected_magic || header->version != COCO80_NET_VERSION ||
        header->header_bytes != COCO80_NET_REP_HEADER_BYTES ||
        header->total_bytes != package_bytes || header->image_id == 0U ||
        header->layer_index >= COCO80_ACCEL_LAYER_COUNT ||
        header->input_mode > COCO80_ACCEL_LAYER_INPUT_A0_PREPACKED ||
        header->expected_ofm_crc32 == 0U ||
        header->header_crc32 != coco80_net_representative_header_crc32(header)) {
        return COCO80_NET_ERR_CONTENT;
    }
    payload = (const uint8_t *)package + COCO80_NET_REP_HEADER_BYTES;
    payload_bytes = package_bytes - COCO80_NET_REP_HEADER_BYTES;
    if ((expected_magic == COCO80_NET_REP_INPUT_MAGIC &&
         (payload_bytes != header->ifm_bytes + header->bias_bytes +
              header->weight_bytes || header->ofm_bytes == 0U)) ||
        (expected_magic == COCO80_NET_REP_OUTPUT_MAGIC &&
         (header->ifm_bytes != 0U || header->bias_bytes != 0U ||
          header->weight_bytes != 0U || payload_bytes != header->ofm_bytes)) ||
        header->payload_crc32 == 0U ||
        header->payload_crc32 != coco80_sd_crc32(payload, payload_bytes)) {
        return COCO80_NET_ERR_PAYLOAD_CRC;
    }
    if (expected_magic == COCO80_NET_REP_INPUT_MAGIC) {
        if (header->override_mode == COCO80_ACCEL_REP_OVERRIDE_NONE) {
            if (header->override_tile_h != 0U || header->override_kernel != 0U ||
                header->bias_bytes != 0U || header->weight_bytes != 0U ||
                header->bias_packets != 0U || header->weight_packets != 0U ||
                header->parameter_crc32 != 0U) return COCO80_NET_ERR_CONTENT;
        } else if ((header->override_mode != COCO80_ACCEL_REP_OVERRIDE_SPARSE_3X3 &&
                    header->override_mode != COCO80_ACCEL_REP_OVERRIDE_TILE) ||
                   header->override_tile_h == 0U ||
                   (header->override_kernel != 1U && header->override_kernel != 3U) ||
                   header->bias_bytes == 0U || header->weight_bytes == 0U ||
                   header->bias_packets == 0U || header->weight_packets == 0U ||
                   header->parameter_crc32 == 0U ||
                   header->parameter_crc32 != coco80_sd_crc32(
                       payload + header->ifm_bytes,
                       header->bias_bytes + header->weight_bytes)) {
            return COCO80_NET_ERR_CONTENT;
        }
    } else if (header->override_mode != 0U || header->override_tile_h != 0U ||
               header->override_kernel != 0U || header->bias_packets != 0U ||
               header->weight_packets != 0U || header->parameter_crc32 != 0U) {
        return COCO80_NET_ERR_CONTENT;
    }
    for (index = 0U; index < 11U; ++index) {
        if (header->reserved[index] != 0U) return COCO80_NET_ERR_CONTENT;
    }
    return COCO80_NET_OK;
}

uint32_t coco80_net_header_crc32(const coco80_net_header_t *header)
{
    coco80_net_header_t copy;
    if (header == NULL) {
        return 0U;
    }
    copy = *header;
    copy.header_crc32 = 0U;
    return coco80_sd_crc32(&copy, sizeof(copy));
}

static int c8_net_type_valid(uint32_t type)
{
    return type >= COCO80_NET_MSG_HELLO && type <= COCO80_NET_MSG_END;
}

static int c8_net_profile_valid(const coco80_net_header_t *header)
{
    if (header->message_type == COCO80_NET_MSG_INPUT_CHUNK ||
        header->message_type == COCO80_NET_MSG_RUN ||
        header->message_type == COCO80_NET_MSG_RESULT_CHUNK ||
        header->message_type == COCO80_NET_MSG_TIMING_CHUNK) {
        return header->output_kind <= COCO80_ACCEL_OUTPUT_TIMING &&
            header->decode_profile <= COCO80_ACCEL_DECODE_DEMO;
    }
    return header->output_kind == 0U && header->decode_profile == 0U;
}

int coco80_net_validate_header(const coco80_net_header_t *header)
{
    if (header == NULL) {
        return COCO80_NET_ERR_ARGUMENT;
    }
    if (header->magic != COCO80_NET_MAGIC) {
        return COCO80_NET_ERR_MAGIC;
    }
    if (header->version != COCO80_NET_VERSION) {
        return COCO80_NET_ERR_VERSION;
    }
    if (header->header_bytes != COCO80_NET_HEADER_BYTES ||
        header->reserved0 != 0U || header->reserved[0] != 0U ||
        header->reserved[1] != 0U || header->reserved[2] != 0U ||
        header->reserved[3] != 0U) {
        return COCO80_NET_ERR_HEADER;
    }
    if (!c8_net_type_valid(header->message_type)) {
        return COCO80_NET_ERR_TYPE;
    }
    if ((header->flags & ~COCO80_NET_FLAG_KNOWN_MASK) != 0U) {
        return COCO80_NET_ERR_FLAGS;
    }
    if (header->sequence == 0U ||
        (header->session_id_low == 0U && header->session_id_high == 0U)) {
        return COCO80_NET_ERR_SEQUENCE;
    }
    if (header->record_count > COCO80_NET_CHUNK_RECORDS ||
        header->chunk_records != COCO80_NET_CHUNK_RECORDS) {
        return COCO80_NET_ERR_RECORDS;
    }
    if (header->payload_bytes > COCO80_NET_INPUT_CHUNK_BYTES) {
        return COCO80_NET_ERR_LENGTH;
    }
    if (!coco80_net_hash_nonzero(header->binding_sha256)) {
        return COCO80_NET_ERR_BINDING;
    }
    if (!c8_net_profile_valid(header)) {
        return COCO80_NET_ERR_PROFILE;
    }
    if (coco80_net_header_crc32(header) != header->header_crc32) {
        return COCO80_NET_ERR_HEADER_CRC;
    }
    return COCO80_NET_OK;
}

int coco80_net_seal_header(coco80_net_header_t *header, const void *payload)
{
    if (header == NULL || (header->payload_bytes != 0U && payload == NULL)) {
        return COCO80_NET_ERR_ARGUMENT;
    }
    header->magic = COCO80_NET_MAGIC;
    header->version = COCO80_NET_VERSION;
    header->header_bytes = COCO80_NET_HEADER_BYTES;
    header->chunk_records = COCO80_NET_CHUNK_RECORDS;
    header->payload_crc32 = coco80_sd_crc32(payload, header->payload_bytes);
    header->header_crc32 = 0U;
    header->header_crc32 = coco80_net_header_crc32(header);
    return coco80_net_validate_header(header);
}

int coco80_net_validate_message(
    const coco80_net_header_t *header,
    const void *payload,
    uint32_t payload_bytes)
{
    int rc = coco80_net_validate_header(header);
    if (rc != COCO80_NET_OK) {
        return rc;
    }
    if (payload_bytes != header->payload_bytes ||
        (payload_bytes != 0U && payload == NULL)) {
        return COCO80_NET_ERR_LENGTH;
    }
    if (coco80_sd_crc32(payload, payload_bytes) != header->payload_crc32) {
        return COCO80_NET_ERR_PAYLOAD_CRC;
    }
    return COCO80_NET_OK;
}

int coco80_net_validate_hello(const void *payload, uint32_t payload_bytes)
{
    const coco80_net_hello_t *hello = (const coco80_net_hello_t *)payload;
    if (payload == NULL || payload_bytes != COCO80_NET_HELLO_BYTES) {
        return COCO80_NET_ERR_LENGTH;
    }
    if (hello->magic != COCO80_NET_HELLO_MAGIC ||
        hello->version != COCO80_NET_VERSION ||
        hello->bytes != COCO80_NET_HELLO_BYTES ||
        hello->extended_timing_bytes != COCO80_ACCEL_EXTENDED_TIMING_BYTES ||
        hello->parameter_package_bytes == 0U) {
        return COCO80_NET_ERR_CONTENT;
    }
    if ((hello->flags & COCO80_NET_FLAG_ABLATION_REPRESENTATIVE) != 0U) {
        if (hello->input_package_bytes != COCO80_NET_INPUT_CHUNK_BYTES ||
            hello->max_chunk_records != 1U ||
            (hello->flags & COCO80_NET_FLAG_TRANSPORT_ONLY) != 0U) {
            return COCO80_NET_ERR_CONTENT;
        }
    } else if (hello->input_package_bytes != COCO80_ACCEL_INPUT_PACKAGE_BYTES ||
               hello->max_chunk_records != COCO80_NET_CHUNK_RECORDS) {
        return COCO80_NET_ERR_CONTENT;
    }
    if ((hello->flags & ~COCO80_NET_FLAG_KNOWN_MASK) != 0U ||
        !coco80_net_hash_nonzero(hello->bit_sha256) ||
        !coco80_net_hash_nonzero(hello->xsa_sha256) ||
        !coco80_net_hash_nonzero(hello->elf_sha256) ||
        !coco80_net_hash_nonzero(hello->parameter_sha256) ||
        !coco80_net_hash_nonzero(hello->dataset_index_sha256) ||
        !coco80_net_hash_nonzero(hello->quantization_sha256)) {
        return COCO80_NET_ERR_BINDING;
    }
    {
        uint32_t index;
        for (index = 0U; index < 6U; ++index) {
            if (hello->reserved[index] != 0U) {
                return COCO80_NET_ERR_CONTENT;
            }
        }
    }
    return COCO80_NET_OK;
}

int coco80_net_validate_end(const void *payload, uint32_t payload_bytes)
{
    const coco80_net_end_t *end = (const coco80_net_end_t *)payload;
    uint32_t index;
    if (payload == NULL || payload_bytes != COCO80_NET_END_BYTES) {
        return COCO80_NET_ERR_LENGTH;
    }
    if (end->magic != COCO80_NET_END_MAGIC ||
        end->version != COCO80_NET_VERSION ||
        end->bytes != COCO80_NET_END_BYTES ||
        end->records_completed > end->records_received ||
        end->results_sent > end->records_completed) {
        return COCO80_NET_ERR_CONTENT;
    }
    for (index = 0U; index < 18U; ++index) {
        if (end->reserved[index] != 0U) {
            return COCO80_NET_ERR_CONTENT;
        }
    }
    return COCO80_NET_OK;
}

int coco80_net_validate_chunk_timing(
    const void *payload, uint32_t payload_bytes, uint32_t expected_records,
    uint32_t expected_input_payload_bytes)
{
    const coco80_net_chunk_timing_t *timing =
        (const coco80_net_chunk_timing_t *)payload;
    uint32_t index;
    uint32_t expected_bytes;
    if (payload == NULL || expected_records == 0U ||
        expected_records > COCO80_NET_CHUNK_RECORDS ||
        expected_input_payload_bytes == 0U ||
        expected_input_payload_bytes > COCO80_NET_INPUT_CHUNK_BYTES ||
        payload_bytes < COCO80_NET_CHUNK_TIMING_BYTES) {
        return COCO80_NET_ERR_LENGTH;
    }
    expected_bytes = COCO80_NET_CHUNK_TIMING_BYTES +
        expected_records * COCO80_ACCEL_EXTENDED_TIMING_BYTES;
    if (payload_bytes != expected_bytes ||
        timing->magic != COCO80_NET_CHUNK_TIMING_MAGIC ||
        timing->version != COCO80_NET_VERSION ||
        timing->bytes != COCO80_NET_CHUNK_TIMING_BYTES ||
        timing->status != COCO80_NET_OK ||
        timing->record_count != expected_records ||
        timing->output_kind > COCO80_ACCEL_OUTPUT_TIMING ||
        timing->decode_profile > COCO80_ACCEL_DECODE_DEMO ||
        timing->tick_hz == 0U ||
        timing->timing_record_bytes != COCO80_ACCEL_EXTENDED_TIMING_BYTES ||
        timing->input_chunk_crc32 == 0U || timing->error_count != 0U) {
        return COCO80_NET_ERR_CONTENT;
    }
    if (timing->input_payload_bytes != expected_input_payload_bytes) {
        return COCO80_NET_ERR_CONTENT;
    }
    if (timing->current_temp_millic < -40000 ||
        timing->current_temp_millic >= 85000 ||
        timing->max_temp_millic < timing->current_temp_millic ||
        timing->max_temp_millic >= 85000) {
        return COCO80_NET_ERR_CONTENT;
    }
    for (index = 0U; index < 9U; ++index) {
        if (timing->reserved[index] != 0U) {
            return COCO80_NET_ERR_CONTENT;
        }
    }
    return COCO80_NET_OK;
}

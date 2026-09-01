#include "coco80_net_protocol.h"

#include <stdio.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { \
    printf("FAIL line=%d: %s\n", __LINE__, #expr); return 1; \
} } while (0)

static void fill_hash(uint32_t hash[8], uint32_t seed)
{
    uint32_t index;
    for (index = 0U; index < 8U; ++index) hash[index] = seed + index;
}

int main(void)
{
    coco80_net_header_t header;
    coco80_net_hello_t hello;
    coco80_net_end_t end;
    uint8_t timing_payload[
        COCO80_NET_CHUNK_TIMING_BYTES + 2U * COCO80_ACCEL_EXTENDED_TIMING_BYTES];
    coco80_net_chunk_timing_t *timing = (coco80_net_chunk_timing_t *)timing_payload;
    uint8_t representative_package[COCO80_NET_REP_HEADER_BYTES + 17U];
    coco80_net_representative_header_t *representative =
        (coco80_net_representative_header_t *)representative_package;
    uint8_t payload[17];
    uint8_t custom_package[COCO80_NET_REP_HEADER_BYTES + 12U];
    coco80_net_representative_header_t *custom =
        (coco80_net_representative_header_t *)custom_package;
    uint32_t index;

    memset(&header, 0, sizeof(header));
    memset(&hello, 0, sizeof(hello));
    memset(&end, 0, sizeof(end));
    memset(timing_payload, 0, sizeof(timing_payload));
    for (index = 0U; index < sizeof(payload); ++index) payload[index] = (uint8_t)index;

    header.message_type = COCO80_NET_MSG_INPUT_CHUNK;
    header.flags = COCO80_NET_FLAG_ACK_REQUIRED;
    header.session_id_low = 1U;
    header.sequence = 2U;
    header.record_count = 1U;
    header.payload_bytes = sizeof(payload);
    header.output_kind = COCO80_ACCEL_OUTPUT_DETECTIONS;
    header.decode_profile = COCO80_ACCEL_DECODE_ACCURACY;
    header.tick_hz = 200000000U;
    fill_hash(header.binding_sha256, 0x100U);
    CHECK(coco80_net_seal_header(&header, payload) == COCO80_NET_OK);
    CHECK(coco80_net_validate_message(&header, payload, sizeof(payload)) == COCO80_NET_OK);
    payload[0] ^= 1U;
    CHECK(coco80_net_validate_message(&header, payload, sizeof(payload)) ==
          COCO80_NET_ERR_PAYLOAD_CRC);
    payload[0] ^= 1U;
    header.sequence = 3U;
    CHECK(coco80_net_validate_header(&header) == COCO80_NET_ERR_HEADER_CRC);

    hello.magic = COCO80_NET_HELLO_MAGIC;
    hello.version = COCO80_NET_VERSION;
    hello.bytes = COCO80_NET_HELLO_BYTES;
    fill_hash(hello.bit_sha256, 1U);
    fill_hash(hello.xsa_sha256, 2U);
    fill_hash(hello.elf_sha256, 3U);
    fill_hash(hello.parameter_sha256, 4U);
    fill_hash(hello.dataset_index_sha256, 5U);
    fill_hash(hello.quantization_sha256, 6U);
    hello.input_package_bytes = COCO80_ACCEL_INPUT_PACKAGE_BYTES;
    hello.parameter_package_bytes = 18682508U;
    hello.max_chunk_records = COCO80_NET_CHUNK_RECORDS;
    hello.extended_timing_bytes = COCO80_ACCEL_EXTENDED_TIMING_BYTES;
    CHECK(coco80_net_validate_hello(&hello, sizeof(hello)) == COCO80_NET_OK);
    hello.max_chunk_records += 1U;
    CHECK(coco80_net_validate_hello(&hello, sizeof(hello)) == COCO80_NET_ERR_CONTENT);
    hello.flags = COCO80_NET_FLAG_NON_RELEASE |
        COCO80_NET_FLAG_ABLATION_REPRESENTATIVE;
    hello.input_package_bytes = COCO80_NET_INPUT_CHUNK_BYTES;
    hello.max_chunk_records = 1U;
    CHECK(coco80_net_validate_hello(&hello, sizeof(hello)) == COCO80_NET_OK);

    memset(representative_package, 0, sizeof(representative_package));
    representative->magic = COCO80_NET_REP_INPUT_MAGIC;
    representative->version = COCO80_NET_VERSION;
    representative->header_bytes = COCO80_NET_REP_HEADER_BYTES;
    representative->total_bytes = sizeof(representative_package);
    representative->image_id = 7U;
    representative->layer_index = 6U;
    representative->input_mode = COCO80_ACCEL_LAYER_INPUT_A0_PREPACKED;
    representative->stream_config = COCO80_ACCEL_A0_PREPACKED_STREAM_CONFIG;
    representative->ifm_bytes = 17U;
    representative->ofm_bytes = 86528U;
    representative->expected_ofm_crc32 = 0x12345678U;
    memcpy(representative_package + COCO80_NET_REP_HEADER_BYTES,
           payload, sizeof(payload));
    CHECK(coco80_net_seal_representative(representative,
          representative_package + COCO80_NET_REP_HEADER_BYTES) == COCO80_NET_OK);
    CHECK(coco80_net_validate_representative(
          representative_package, sizeof(representative_package),
          COCO80_NET_REP_INPUT_MAGIC) == COCO80_NET_OK);
    representative_package[sizeof(representative_package) - 1U] ^= 1U;

    memset(custom_package, 0, sizeof(custom_package));
    custom->magic = COCO80_NET_REP_INPUT_MAGIC;
    custom->version = COCO80_NET_VERSION;
    custom->header_bytes = COCO80_NET_REP_HEADER_BYTES;
    custom->total_bytes = sizeof(custom_package);
    custom->image_id = 8U;
    custom->layer_index = 6U;
    custom->input_mode = COCO80_ACCEL_LAYER_INPUT_RAW_HWC;
    custom->stream_config = 0x2bU;
    custom->ifm_bytes = 3U;
    custom->ofm_bytes = 173056U;
    custom->expected_ofm_crc32 = 0x87654321U;
    custom->override_mode = COCO80_ACCEL_REP_OVERRIDE_TILE;
    custom->override_tile_h = 4U;
    custom->override_kernel = 3U;
    custom->bias_bytes = 4U;
    custom->weight_bytes = 5U;
    custom->bias_packets = 1U;
    custom->weight_packets = 1U;
    memcpy(custom_package + COCO80_NET_REP_HEADER_BYTES, "ifmbiaswght", 12U);
    custom->parameter_crc32 = coco80_sd_crc32(
        custom_package + COCO80_NET_REP_HEADER_BYTES + custom->ifm_bytes,
        custom->bias_bytes + custom->weight_bytes);
    CHECK(coco80_net_seal_representative(
          custom, custom_package + COCO80_NET_REP_HEADER_BYTES) == COCO80_NET_OK);
    CHECK(coco80_net_validate_representative(
          custom_package, sizeof(custom_package), COCO80_NET_REP_INPUT_MAGIC) ==
          COCO80_NET_OK);
    custom->parameter_crc32 ^= 1U;
    custom->header_crc32 = coco80_net_representative_header_crc32(custom);
    CHECK(coco80_net_validate_representative(
          custom_package, sizeof(custom_package), COCO80_NET_REP_INPUT_MAGIC) ==
          COCO80_NET_ERR_CONTENT);
    CHECK(coco80_net_validate_representative(
          representative_package, sizeof(representative_package),
          COCO80_NET_REP_INPUT_MAGIC) == COCO80_NET_ERR_PAYLOAD_CRC);
    representative_package[sizeof(representative_package) - 1U] ^= 1U;

    end.magic = COCO80_NET_END_MAGIC;
    end.version = COCO80_NET_VERSION;
    end.bytes = COCO80_NET_END_BYTES;
    end.records_received = 128U;
    end.records_completed = 128U;
    end.results_sent = 128U;
    CHECK(coco80_net_validate_end(&end, sizeof(end)) == COCO80_NET_OK);
    end.results_sent = 129U;
    CHECK(coco80_net_validate_end(&end, sizeof(end)) == COCO80_NET_ERR_CONTENT);

    timing->magic = COCO80_NET_CHUNK_TIMING_MAGIC;
    timing->version = COCO80_NET_VERSION;
    timing->bytes = COCO80_NET_CHUNK_TIMING_BYTES;
    timing->first_record = 10U;
    timing->record_count = 2U;
    timing->output_kind = COCO80_ACCEL_OUTPUT_DETECTIONS;
    timing->decode_profile = COCO80_ACCEL_DECODE_ACCURACY;
    timing->tick_hz = 100000000U;
    timing->input_payload_bytes = 2U * COCO80_ACCEL_INPUT_PACKAGE_BYTES;
    timing->timing_record_bytes = COCO80_ACCEL_EXTENDED_TIMING_BYTES;
    timing->input_chunk_crc32 = 1U;
    timing->current_temp_millic = 33000;
    timing->max_temp_millic = 34000;
    CHECK(coco80_net_validate_chunk_timing(
        timing_payload, sizeof(timing_payload), 2U,
        2U * COCO80_ACCEL_INPUT_PACKAGE_BYTES) == COCO80_NET_OK);
    CHECK(coco80_net_validate_chunk_timing(
        timing_payload, sizeof(timing_payload), 2U,
        COCO80_ACCEL_INPUT_PACKAGE_BYTES) == COCO80_NET_ERR_CONTENT);
    timing->record_count = 1U;
    CHECK(coco80_net_validate_chunk_timing(
        timing_payload, sizeof(timing_payload), 2U,
        2U * COCO80_ACCEL_INPUT_PACKAGE_BYTES) == COCO80_NET_ERR_CONTENT);
    timing->input_payload_bytes = COCO80_NET_REP_HEADER_BYTES + 256U;
    CHECK(coco80_net_validate_chunk_timing(
        timing_payload,
        COCO80_NET_CHUNK_TIMING_BYTES + COCO80_ACCEL_EXTENDED_TIMING_BYTES,
        1U, COCO80_NET_REP_HEADER_BYTES + 256U) == COCO80_NET_OK);

    puts("PASS: COCO80 network protocol");
    return 0;
}

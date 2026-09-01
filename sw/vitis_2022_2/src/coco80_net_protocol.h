#ifndef COCO80_NET_PROTOCOL_H
#define COCO80_NET_PROTOCOL_H

#include "coco80_accel.h"

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define COCO80_NET_MAGIC COCO80_SD_FOURCC('C', '8', 'N', 'W')
#define COCO80_NET_HELLO_MAGIC COCO80_SD_FOURCC('C', '8', 'H', 'I')
#define COCO80_NET_END_MAGIC COCO80_SD_FOURCC('C', '8', 'E', 'N')
#define COCO80_NET_CHUNK_TIMING_MAGIC COCO80_SD_FOURCC('C', '8', 'C', 'T')
#define COCO80_NET_REP_INPUT_MAGIC COCO80_SD_FOURCC('C', '8', 'A', 'I')
#define COCO80_NET_REP_OUTPUT_MAGIC COCO80_SD_FOURCC('C', '8', 'A', 'O')
#define COCO80_NET_VERSION 1U
#define COCO80_NET_HEADER_BYTES 128U
#define COCO80_NET_HELLO_BYTES 256U
#define COCO80_NET_END_BYTES 128U
#define COCO80_NET_CHUNK_TIMING_BYTES 128U
#define COCO80_NET_RESULT_PREFIX_BYTES 16U
#define COCO80_NET_REP_HEADER_BYTES 128U
#define COCO80_NET_CHUNK_RECORDS 128U
#define COCO80_NET_INPUT_CHUNK_BYTES \
    (COCO80_NET_CHUNK_RECORDS * COCO80_ACCEL_INPUT_PACKAGE_BYTES)

#define COCO80_NET_FLAG_ACK_REQUIRED 0x00000001U
#define COCO80_NET_FLAG_FINAL 0x00000002U
#define COCO80_NET_FLAG_NON_RELEASE 0x00000004U
#define COCO80_NET_FLAG_TRANSPORT_ONLY 0x00000008U
#define COCO80_NET_FLAG_ABLATION_REPRESENTATIVE 0x00000010U
#define COCO80_NET_FLAG_KNOWN_MASK \
    (COCO80_NET_FLAG_ACK_REQUIRED | COCO80_NET_FLAG_FINAL | \
     COCO80_NET_FLAG_NON_RELEASE | COCO80_NET_FLAG_TRANSPORT_ONLY | \
     COCO80_NET_FLAG_ABLATION_REPRESENTATIVE)

typedef enum {
    COCO80_NET_MSG_HELLO = 1,
    COCO80_NET_MSG_PARAMETERS = 2,
    COCO80_NET_MSG_INPUT_CHUNK = 3,
    COCO80_NET_MSG_RUN = 4,
    COCO80_NET_MSG_RESULT_CHUNK = 5,
    COCO80_NET_MSG_TIMING_CHUNK = 6,
    COCO80_NET_MSG_STATUS = 7,
    COCO80_NET_MSG_ERROR = 8,
    COCO80_NET_MSG_END = 9
} coco80_net_message_type_t;

typedef enum {
    COCO80_NET_OK = 0,
    COCO80_NET_ERR_ARGUMENT = -400,
    COCO80_NET_ERR_MAGIC = -401,
    COCO80_NET_ERR_VERSION = -402,
    COCO80_NET_ERR_HEADER = -403,
    COCO80_NET_ERR_TYPE = -404,
    COCO80_NET_ERR_FLAGS = -405,
    COCO80_NET_ERR_SEQUENCE = -406,
    COCO80_NET_ERR_RECORDS = -407,
    COCO80_NET_ERR_LENGTH = -408,
    COCO80_NET_ERR_HEADER_CRC = -409,
    COCO80_NET_ERR_PAYLOAD_CRC = -410,
    COCO80_NET_ERR_BINDING = -411,
    COCO80_NET_ERR_PROFILE = -412,
    COCO80_NET_ERR_CONTENT = -413
} coco80_net_status_t;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t header_bytes;
    uint32_t message_type;
    uint32_t flags;
    uint32_t session_id_low;
    uint32_t session_id_high;
    uint32_t sequence;
    uint32_t first_record;
    uint32_t record_count;
    uint32_t payload_bytes;
    uint32_t payload_crc32;
    uint32_t header_crc32;
    uint32_t status;
    uint32_t error_code;
    uint32_t output_kind;
    uint32_t decode_profile;
    uint32_t tick_hz;
    uint32_t chunk_records;
    uint32_t reserved0;
    uint32_t binding_sha256[8];
    uint32_t reserved[4];
} coco80_net_header_t;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t bytes;
    uint32_t flags;
    uint32_t bit_sha256[8];
    uint32_t xsa_sha256[8];
    uint32_t elf_sha256[8];
    uint32_t parameter_sha256[8];
    uint32_t dataset_index_sha256[8];
    uint32_t quantization_sha256[8];
    uint32_t software_build_crc32;
    uint32_t hardware_build_crc32;
    uint32_t input_package_bytes;
    uint32_t parameter_package_bytes;
    uint32_t max_chunk_records;
    uint32_t extended_timing_bytes;
    uint32_t reserved[6];
} coco80_net_hello_t;

typedef struct {
    uint32_t image_id;
    uint32_t bytes;
    uint32_t crc32;
    uint32_t reserved;
} coco80_net_result_prefix_t;

/* One representative-layer tensor per network chunk.  The input form carries
 * IFM bytes after this header; the output form carries OFM bytes.  The host
 * supplies the authoritative OFM CRC so timing-only performance runs retain
 * the same byte-exact correctness gate without returning the tensor. */
typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t header_bytes;
    uint32_t total_bytes;
    uint32_t image_id;
    uint32_t layer_index;
    uint32_t input_mode;
    uint32_t stream_config;
    uint32_t ifm_bytes;
    uint32_t ofm_bytes;
    uint32_t payload_crc32;
    uint32_t expected_ofm_crc32;
    uint32_t header_crc32;
    uint32_t override_mode;
    uint32_t override_tile_h;
    uint32_t override_kernel;
    uint32_t bias_bytes;
    uint32_t weight_bytes;
    uint32_t bias_packets;
    uint32_t weight_packets;
    uint32_t parameter_crc32;
    uint32_t reserved[11];
} coco80_net_representative_header_t;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t bytes;
    uint32_t status;
    uint32_t records_received;
    uint32_t records_completed;
    uint32_t results_sent;
    uint32_t error_count;
    uint32_t input_crc32;
    uint32_t result_crc32;
    uint32_t parameter_crc32;
    uint32_t reconnect_count;
    uint32_t elapsed_ticks_low;
    uint32_t elapsed_ticks_high;
    uint32_t reserved[18];
} coco80_net_end_t;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t bytes;
    uint32_t status;
    uint32_t first_record;
    uint32_t record_count;
    uint32_t output_kind;
    uint32_t decode_profile;
    uint32_t tick_hz;
    uint32_t input_payload_bytes;
    uint32_t result_payload_bytes;
    uint32_t timing_record_bytes;
    uint64_t input_receive_ticks;
    uint64_t compute_ticks;
    uint64_t result_send_ticks;
    uint32_t input_chunk_crc32;
    uint32_t result_chunk_crc32;
    uint32_t error_count;
    int32_t current_temp_millic;
    int32_t max_temp_millic;
    uint32_t reserved[9];
} coco80_net_chunk_timing_t;

uint32_t coco80_net_header_crc32(const coco80_net_header_t *header);
int coco80_net_seal_header(coco80_net_header_t *header, const void *payload);
int coco80_net_validate_header(const coco80_net_header_t *header);
int coco80_net_validate_message(
    const coco80_net_header_t *header,
    const void *payload,
    uint32_t payload_bytes);
int coco80_net_validate_hello(const void *payload, uint32_t payload_bytes);
int coco80_net_validate_end(const void *payload, uint32_t payload_bytes);
int coco80_net_validate_chunk_timing(
    const void *payload, uint32_t payload_bytes, uint32_t expected_records,
    uint32_t expected_input_payload_bytes);
int coco80_net_hash_nonzero(const uint32_t hash[8]);
uint32_t coco80_net_representative_header_crc32(
    const coco80_net_representative_header_t *header);
int coco80_net_seal_representative(
    coco80_net_representative_header_t *header, const void *payload);
int coco80_net_validate_representative(
    const void *package, uint32_t package_bytes, uint32_t expected_magic);

#ifdef __cplusplus
}
#endif

#endif

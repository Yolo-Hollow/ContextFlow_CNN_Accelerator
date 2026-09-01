#ifndef COCO80_SD_INDEX_H
#define COCO80_SD_INDEX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define COCO80_SD_INDEX_MAGIC 0x58493843U /* C8IX, little endian */
#define COCO80_SD_INDEX_VERSION 1U
#define COCO80_SD_INDEX_HEADER_BYTES 128U
#define COCO80_SD_INDEX_SHARD_BYTES 80U
#define COCO80_SD_INDEX_ENTRY_BYTES 32U

#define COCO80_SD_SELECTION_MAGIC 0x58533843U /* C8SX, little endian */
#define COCO80_SD_SELECTION_VERSION 1U
#define COCO80_SD_SELECTION_HEADER_BYTES 128U
#define COCO80_SD_SELECTION_ENTRY_BYTES 8U
#define COCO80_SD_SELECTION_MAX_ENTRIES 128U

typedef enum {
    COCO80_SD_INDEX_OK = 0,
    COCO80_SD_INDEX_ERR_ARGUMENT = -300,
    COCO80_SD_INDEX_ERR_HEADER = -301,
    COCO80_SD_INDEX_ERR_CRC = -302,
    COCO80_SD_INDEX_ERR_TABLE = -303,
    COCO80_SD_INDEX_ERR_RECORD = -304,
    COCO80_SD_INDEX_ERR_SELECTION = -305
} coco80_sd_index_status_t;

typedef struct {
    uint32_t magic, version, header_bytes, total_bytes;
    uint32_t image_count, shard_count, shard_record_bytes, entry_record_bytes;
    uint32_t shards_offset, shards_bytes, entries_offset, entries_bytes;
    uint32_t shards_crc32, entries_crc32, header_crc32, reserved;
    uint32_t content_sha256[8];
    uint32_t source_set_sha256[8];
} coco80_sd_index_header_t;

typedef struct {
    uint32_t shard_id, first_record, record_count, bytes, crc32, filename_bytes;
    uint32_t filename_words[4];
    uint32_t sha256[8];
    uint32_t reserved[2];
} coco80_sd_index_shard_t;

typedef struct {
    uint32_t image_id, shard_id, record_index, offset;
    uint32_t bytes, package_crc32, original_width, original_height;
} coco80_sd_index_entry_t;

typedef struct {
    uint32_t magic, version, header_bytes, total_bytes;
    uint32_t entry_count, entry_bytes, entries_offset, entries_bytes;
    uint32_t input_index_crc32, entries_crc32, header_crc32, reserved;
    uint32_t selection_manifest_sha256[8];
    uint32_t input_index_sha256[8];
    uint32_t reserved_tail[4];
} coco80_sd_selection_header_t;

typedef struct {
    uint32_t image_id, record_index;
} coco80_sd_selection_entry_t;

typedef char coco80_sd_index_header_size[
    sizeof(coco80_sd_index_header_t) == COCO80_SD_INDEX_HEADER_BYTES ? 1 : -1];
typedef char coco80_sd_index_shard_size[
    sizeof(coco80_sd_index_shard_t) == COCO80_SD_INDEX_SHARD_BYTES ? 1 : -1];
typedef char coco80_sd_index_entry_size[
    sizeof(coco80_sd_index_entry_t) == COCO80_SD_INDEX_ENTRY_BYTES ? 1 : -1];
typedef char coco80_sd_selection_header_size[
    sizeof(coco80_sd_selection_header_t) == COCO80_SD_SELECTION_HEADER_BYTES ? 1 : -1];
typedef char coco80_sd_selection_entry_size[
    sizeof(coco80_sd_selection_entry_t) == COCO80_SD_SELECTION_ENTRY_BYTES ? 1 : -1];

uint32_t coco80_sd_crc32_begin(void);
uint32_t coco80_sd_crc32_extend(uint32_t state, const void *data, uint32_t bytes);
uint32_t coco80_sd_crc32_end(uint32_t state);

int coco80_sd_index_validate(
    const void *data, uint32_t bytes, coco80_sd_index_header_t *header_out);
int coco80_sd_index_get_shard(
    const void *data, uint32_t bytes, uint32_t shard_id,
    coco80_sd_index_shard_t *shard_out, char filename_out[17]);
int coco80_sd_index_get_entry(
    const void *data, uint32_t bytes, uint32_t record_index,
    coco80_sd_index_entry_t *entry_out);
int coco80_sd_selection_validate(
    const void *selection_data, uint32_t selection_bytes,
    const void *index_data, uint32_t index_bytes,
    coco80_sd_selection_header_t *header_out);
int coco80_sd_selection_get_entry(
    const void *data, uint32_t bytes, uint32_t selection_index,
    coco80_sd_selection_entry_t *entry_out);

#ifdef __cplusplus
}
#endif

#endif

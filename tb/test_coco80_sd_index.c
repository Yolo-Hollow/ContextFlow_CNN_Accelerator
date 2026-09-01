#include "coco80_sd_index.h"

#include "coco80_sd_protocol.h"

#include <stdio.h>
#include <string.h>

static unsigned pass_count, fail_count;
#define CHECK(x) do { if (x) ++pass_count; else { ++fail_count; printf("FAIL line=%d\n", __LINE__); } } while (0)

int main(void)
{
    uint8_t bytes[COCO80_SD_INDEX_HEADER_BYTES + COCO80_SD_INDEX_SHARD_BYTES +
                  2U * COCO80_SD_INDEX_ENTRY_BYTES];
    coco80_sd_index_header_t *header = (coco80_sd_index_header_t *)bytes;
    coco80_sd_index_shard_t *shard = (coco80_sd_index_shard_t *)(bytes + 128U);
    coco80_sd_index_entry_t *entry = (coco80_sd_index_entry_t *)(bytes + 208U);
    coco80_sd_index_header_t parsed;
    char filename[17];
    uint32_t index;
    uint8_t selection_bytes[COCO80_SD_SELECTION_HEADER_BYTES +
                            2U * COCO80_SD_SELECTION_ENTRY_BYTES];
    coco80_sd_selection_header_t *selection =
        (coco80_sd_selection_header_t *)selection_bytes;
    coco80_sd_selection_entry_t *selected = (coco80_sd_selection_entry_t *)(
        selection_bytes + COCO80_SD_SELECTION_HEADER_BYTES);
    coco80_sd_selection_header_t parsed_selection;
    memset(bytes, 0, sizeof(bytes));
    header->magic = COCO80_SD_INDEX_MAGIC; header->version = 1U;
    header->header_bytes = 128U; header->total_bytes = sizeof(bytes);
    header->image_count = 2U; header->shard_count = 1U;
    header->shard_record_bytes = 80U; header->entry_record_bytes = 32U;
    header->shards_offset = 128U; header->shards_bytes = 80U;
    header->entries_offset = 208U; header->entries_bytes = 64U;
    for (index = 0U; index < 8U; ++index) {
        header->content_sha256[index] = index + 1U;
        header->source_set_sha256[index] = index + 11U;
        shard->sha256[index] = index + 21U;
    }
    shard->shard_id = 0U; shard->first_record = 0U; shard->record_count = 2U;
    shard->bytes = 2048U; shard->crc32 = 123U; shard->filename_bytes = 11U;
    memcpy(shard->filename_words, "in_0000.bin", 11U);
    for (index = 0U; index < 2U; ++index) {
        entry[index].image_id = index + 1U; entry[index].shard_id = 0U;
        entry[index].record_index = index; entry[index].offset = index * 1024U;
        entry[index].bytes = 1024U; entry[index].package_crc32 = index + 77U;
        entry[index].original_width = 640U; entry[index].original_height = 480U;
    }
    header->shards_crc32 = coco80_sd_crc32(shard, 80U);
    header->entries_crc32 = coco80_sd_crc32(entry, 64U);
    header->header_crc32 = 0U;
    header->header_crc32 = coco80_sd_crc32(header, 128U);
    CHECK(coco80_sd_index_validate(bytes, sizeof(bytes), &parsed) == 0);
    CHECK(parsed.image_count == 2U);
    CHECK(coco80_sd_index_get_shard(bytes, sizeof(bytes), 0U, NULL, filename) == 0);
    CHECK(strcmp(filename, "in_0000.bin") == 0);
    memset(selection_bytes, 0, sizeof(selection_bytes));
    selection->magic = COCO80_SD_SELECTION_MAGIC;
    selection->version = COCO80_SD_SELECTION_VERSION;
    selection->header_bytes = COCO80_SD_SELECTION_HEADER_BYTES;
    selection->total_bytes = sizeof(selection_bytes);
    selection->entry_count = 2U;
    selection->entry_bytes = COCO80_SD_SELECTION_ENTRY_BYTES;
    selection->entries_offset = COCO80_SD_SELECTION_HEADER_BYTES;
    selection->entries_bytes = 2U * COCO80_SD_SELECTION_ENTRY_BYTES;
    selection->input_index_crc32 = coco80_sd_crc32(bytes, sizeof(bytes));
    for (index = 0U; index < 8U; ++index) {
        selection->selection_manifest_sha256[index] = index + 31U;
        selection->input_index_sha256[index] = index + 41U;
    }
    selected[0].image_id = 2U; selected[0].record_index = 1U;
    selected[1].image_id = 1U; selected[1].record_index = 0U;
    selection->entries_crc32 = coco80_sd_crc32(
        selected, 2U * COCO80_SD_SELECTION_ENTRY_BYTES);
    selection->header_crc32 = 0U;
    selection->header_crc32 = coco80_sd_crc32(selection, sizeof(*selection));
    CHECK(coco80_sd_selection_validate(
        selection_bytes, sizeof(selection_bytes), bytes, sizeof(bytes),
        &parsed_selection) == 0);
    CHECK(parsed_selection.entry_count == 2U);
    selected[0].image_id = 1U;
    selection->entries_crc32 = coco80_sd_crc32(
        selected, 2U * COCO80_SD_SELECTION_ENTRY_BYTES);
    selection->header_crc32 = 0U;
    selection->header_crc32 = coco80_sd_crc32(selection, sizeof(*selection));
    CHECK(coco80_sd_selection_validate(
        selection_bytes, sizeof(selection_bytes), bytes, sizeof(bytes), NULL) ==
        COCO80_SD_INDEX_ERR_SELECTION);
    selected[0].image_id = 2U;
    selection->entries_crc32 = coco80_sd_crc32(
        selected, 2U * COCO80_SD_SELECTION_ENTRY_BYTES);
    selection->header_crc32 = 0U;
    selection->header_crc32 = coco80_sd_crc32(selection, sizeof(*selection));
    selection_bytes[COCO80_SD_SELECTION_HEADER_BYTES] ^= 1U;
    CHECK(coco80_sd_selection_validate(
        selection_bytes, sizeof(selection_bytes), bytes, sizeof(bytes), NULL) ==
        COCO80_SD_INDEX_ERR_CRC);
    bytes[210] ^= 1U;
    CHECK(coco80_sd_index_validate(bytes, sizeof(bytes), NULL) == COCO80_SD_INDEX_ERR_CRC);
    bytes[210] ^= 1U;
    header->header_crc32 ^= 1U;
    CHECK(coco80_sd_index_validate(bytes, sizeof(bytes), NULL) == COCO80_SD_INDEX_ERR_HEADER);
    CHECK(coco80_sd_crc32_end(coco80_sd_crc32_extend(
        coco80_sd_crc32_begin(), "123456789", 9U)) == 0xcbf43926U);
    printf("PASS: COCO80_SD_INDEX pass=%u fail=%u\n", pass_count, fail_count);
    return fail_count == 0U ? 0 : 1;
}

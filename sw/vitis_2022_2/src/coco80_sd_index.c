#include "coco80_sd_index.h"

#include "coco80_sd_protocol.h"

#include <stddef.h>
#include <string.h>

uint32_t coco80_sd_crc32_begin(void) { return 0xffffffffU; }

uint32_t coco80_sd_crc32_extend(uint32_t state, const void *data, uint32_t bytes)
{
    return coco80_sd_crc32_extend_state(state, data, bytes);
}

uint32_t coco80_sd_crc32_end(uint32_t state) { return state ^ 0xffffffffU; }

static int c8_nonzero_hash(const uint32_t hash[8])
{
    uint32_t index, value = 0U;
    for (index = 0U; index < 8U; ++index) value |= hash[index];
    return value != 0U;
}

static uint32_t c8_header_crc(const coco80_sd_index_header_t *header)
{
    coco80_sd_index_header_t copy;
    memcpy(&copy, header, sizeof(copy));
    copy.header_crc32 = 0U;
    return coco80_sd_crc32(&copy, sizeof(copy));
}

static int c8_bounds(uint32_t offset, uint32_t length, uint32_t total)
{
    return offset <= total && length <= total - offset;
}

int coco80_sd_index_validate(
    const void *data, uint32_t bytes, coco80_sd_index_header_t *header_out)
{
    const uint8_t *raw = (const uint8_t *)data;
    coco80_sd_index_header_t header;
    uint32_t index, expected_record = 0U, shard_cursor = 0U, active_shard = 0U;
    if (data == NULL || bytes < sizeof(header)) return COCO80_SD_INDEX_ERR_ARGUMENT;
    memcpy(&header, data, sizeof(header));
    if (header.magic != COCO80_SD_INDEX_MAGIC ||
        header.version != COCO80_SD_INDEX_VERSION ||
        header.header_bytes != sizeof(header) || header.total_bytes != bytes ||
        header.image_count == 0U || header.shard_count == 0U ||
        header.shard_record_bytes != sizeof(coco80_sd_index_shard_t) ||
        header.entry_record_bytes != sizeof(coco80_sd_index_entry_t) ||
        header.shards_offset != sizeof(header) ||
        header.shards_bytes != header.shard_count * sizeof(coco80_sd_index_shard_t) ||
        header.entries_offset != header.shards_offset + header.shards_bytes ||
        header.entries_bytes != header.image_count * sizeof(coco80_sd_index_entry_t) ||
        !c8_bounds(header.shards_offset, header.shards_bytes, bytes) ||
        !c8_bounds(header.entries_offset, header.entries_bytes, bytes) ||
        header.entries_offset + header.entries_bytes != bytes ||
        header.reserved != 0U || !c8_nonzero_hash(header.content_sha256) ||
        !c8_nonzero_hash(header.source_set_sha256) ||
        c8_header_crc(&header) != header.header_crc32) {
        return COCO80_SD_INDEX_ERR_HEADER;
    }
    if (coco80_sd_crc32(raw + header.shards_offset, header.shards_bytes) !=
            header.shards_crc32 ||
        coco80_sd_crc32(raw + header.entries_offset, header.entries_bytes) !=
            header.entries_crc32) return COCO80_SD_INDEX_ERR_CRC;
    for (index = 0U; index < header.shard_count; ++index) {
        coco80_sd_index_shard_t shard;
        char filename[17];
        if (coco80_sd_index_get_shard(data, bytes, index, &shard, filename) != 0 ||
            shard.first_record != expected_record) return COCO80_SD_INDEX_ERR_RECORD;
        expected_record += shard.record_count;
    }
    if (expected_record != header.image_count) return COCO80_SD_INDEX_ERR_RECORD;
    for (index = 0U; index < header.image_count; ++index) {
        coco80_sd_index_entry_t entry;
        coco80_sd_index_shard_t shard;
        if (coco80_sd_index_get_entry(data, bytes, index, &entry) != 0 ||
            coco80_sd_index_get_shard(data, bytes, entry.shard_id, &shard, NULL) != 0 ||
            entry.record_index < shard.first_record ||
            entry.record_index >= shard.first_record + shard.record_count ||
            entry.offset > shard.bytes || entry.bytes > shard.bytes - entry.offset) {
            return COCO80_SD_INDEX_ERR_RECORD;
        }
        if (entry.shard_id != active_shard) {
            coco80_sd_index_shard_t previous;
            if (entry.shard_id != active_shard + 1U ||
                coco80_sd_index_get_shard(data, bytes, active_shard, &previous, NULL) != 0 ||
                shard_cursor != previous.bytes) return COCO80_SD_INDEX_ERR_RECORD;
            active_shard = entry.shard_id;
            shard_cursor = 0U;
        }
        if (entry.offset != shard_cursor) return COCO80_SD_INDEX_ERR_RECORD;
        shard_cursor += entry.bytes;
    }
    {
        coco80_sd_index_shard_t last;
        if (coco80_sd_index_get_shard(data, bytes, active_shard, &last, NULL) != 0 ||
            shard_cursor != last.bytes) return COCO80_SD_INDEX_ERR_RECORD;
    }
    if (header_out != NULL) *header_out = header;
    return COCO80_SD_INDEX_OK;
}

int coco80_sd_index_get_shard(
    const void *data, uint32_t bytes, uint32_t shard_id,
    coco80_sd_index_shard_t *shard_out, char filename_out[17])
{
    const uint8_t *raw = (const uint8_t *)data;
    coco80_sd_index_header_t header;
    coco80_sd_index_shard_t shard;
    const uint8_t *name;
    uint32_t index;
    if (data == NULL || bytes < sizeof(header)) return COCO80_SD_INDEX_ERR_ARGUMENT;
    memcpy(&header, data, sizeof(header));
    if (shard_id >= header.shard_count ||
        !c8_bounds(header.shards_offset, header.shards_bytes, bytes))
        return COCO80_SD_INDEX_ERR_RECORD;
    memcpy(&shard, raw + header.shards_offset + shard_id * sizeof(shard), sizeof(shard));
    name = (const uint8_t *)shard.filename_words;
    if (shard.shard_id != shard_id || shard.record_count == 0U || shard.bytes == 0U ||
        shard.crc32 == 0U || shard.filename_bytes == 0U || shard.filename_bytes > 16U ||
        !c8_nonzero_hash(shard.sha256) || shard.reserved[0] != 0U || shard.reserved[1] != 0U)
        return COCO80_SD_INDEX_ERR_RECORD;
    for (index = 0U; index < shard.filename_bytes; ++index) {
        uint8_t value = name[index];
        if (value < 0x21U || value > 0x7eU || value == '/' || value == '\\')
            return COCO80_SD_INDEX_ERR_RECORD;
    }
    for (; index < 16U; ++index) if (name[index] != 0U) return COCO80_SD_INDEX_ERR_RECORD;
    if (filename_out != NULL) {
        memcpy(filename_out, name, shard.filename_bytes);
        filename_out[shard.filename_bytes] = '\0';
    }
    if (shard_out != NULL) *shard_out = shard;
    return COCO80_SD_INDEX_OK;
}

int coco80_sd_index_get_entry(
    const void *data, uint32_t bytes, uint32_t record_index,
    coco80_sd_index_entry_t *entry_out)
{
    const uint8_t *raw = (const uint8_t *)data;
    coco80_sd_index_header_t header;
    coco80_sd_index_entry_t entry;
    if (data == NULL || entry_out == NULL || bytes < sizeof(header))
        return COCO80_SD_INDEX_ERR_ARGUMENT;
    memcpy(&header, data, sizeof(header));
    if (record_index >= header.image_count ||
        !c8_bounds(header.entries_offset, header.entries_bytes, bytes))
        return COCO80_SD_INDEX_ERR_RECORD;
    memcpy(&entry, raw + header.entries_offset + record_index * sizeof(entry), sizeof(entry));
    if (entry.image_id == 0U || entry.shard_id >= header.shard_count ||
        entry.record_index != record_index || entry.bytes < COCO80_SD_HEADER_BYTES ||
        entry.package_crc32 == 0U || entry.original_width == 0U || entry.original_height == 0U)
        return COCO80_SD_INDEX_ERR_RECORD;
    *entry_out = entry;
    return COCO80_SD_INDEX_OK;
}

static uint32_t c8_selection_header_crc(const coco80_sd_selection_header_t *header)
{
    coco80_sd_selection_header_t copy;
    memcpy(&copy, header, sizeof(copy));
    copy.header_crc32 = 0U;
    return coco80_sd_crc32(&copy, sizeof(copy));
}

int coco80_sd_selection_get_entry(
    const void *data, uint32_t bytes, uint32_t selection_index,
    coco80_sd_selection_entry_t *entry_out)
{
    const uint8_t *raw = (const uint8_t *)data;
    coco80_sd_selection_header_t header;
    coco80_sd_selection_entry_t entry;
    uint32_t offset;
    if (data == NULL || entry_out == NULL || bytes < sizeof(header))
        return COCO80_SD_INDEX_ERR_ARGUMENT;
    memcpy(&header, data, sizeof(header));
    if (selection_index >= header.entry_count ||
        header.entry_bytes != sizeof(entry) ||
        header.entries_offset != sizeof(header))
        return COCO80_SD_INDEX_ERR_SELECTION;
    offset = header.entries_offset + selection_index * sizeof(entry);
    if (!c8_bounds(offset, sizeof(entry), bytes))
        return COCO80_SD_INDEX_ERR_SELECTION;
    memcpy(&entry, raw + offset, sizeof(entry));
    if (entry.image_id == 0U) return COCO80_SD_INDEX_ERR_SELECTION;
    *entry_out = entry;
    return COCO80_SD_INDEX_OK;
}

int coco80_sd_selection_validate(
    const void *selection_data, uint32_t selection_bytes,
    const void *index_data, uint32_t index_bytes,
    coco80_sd_selection_header_t *header_out)
{
    const uint8_t *raw = (const uint8_t *)selection_data;
    coco80_sd_selection_header_t header;
    coco80_sd_index_header_t index_header;
    uint32_t selection_index;
    if (selection_data == NULL || index_data == NULL ||
        selection_bytes < sizeof(header)) return COCO80_SD_INDEX_ERR_ARGUMENT;
    if (coco80_sd_index_validate(index_data, index_bytes, &index_header) != 0)
        return COCO80_SD_INDEX_ERR_SELECTION;
    memcpy(&header, selection_data, sizeof(header));
    if (header.magic != COCO80_SD_SELECTION_MAGIC ||
        header.version != COCO80_SD_SELECTION_VERSION ||
        header.header_bytes != sizeof(header) ||
        header.total_bytes != selection_bytes ||
        header.entry_count == 0U ||
        header.entry_count > COCO80_SD_SELECTION_MAX_ENTRIES ||
        header.entry_bytes != sizeof(coco80_sd_selection_entry_t) ||
        header.entries_offset != sizeof(header) ||
        header.entries_bytes != header.entry_count * sizeof(coco80_sd_selection_entry_t) ||
        header.entries_offset + header.entries_bytes != selection_bytes ||
        header.input_index_crc32 != coco80_sd_crc32(index_data, index_bytes) ||
        header.reserved != 0U || !c8_nonzero_hash(header.selection_manifest_sha256) ||
        !c8_nonzero_hash(header.input_index_sha256) ||
        header.reserved_tail[0] != 0U || header.reserved_tail[1] != 0U ||
        header.reserved_tail[2] != 0U || header.reserved_tail[3] != 0U ||
        c8_selection_header_crc(&header) != header.header_crc32)
        return COCO80_SD_INDEX_ERR_SELECTION;
    if (coco80_sd_crc32(raw + header.entries_offset, header.entries_bytes) !=
        header.entries_crc32) return COCO80_SD_INDEX_ERR_CRC;
    for (selection_index = 0U; selection_index < header.entry_count; ++selection_index) {
        coco80_sd_selection_entry_t selected;
        coco80_sd_index_entry_t indexed;
        uint32_t previous;
        if (coco80_sd_selection_get_entry(
                selection_data, selection_bytes, selection_index, &selected) != 0 ||
            selected.record_index >= index_header.image_count ||
            coco80_sd_index_get_entry(
                index_data, index_bytes, selected.record_index, &indexed) != 0 ||
            indexed.image_id != selected.image_id)
            return COCO80_SD_INDEX_ERR_SELECTION;
        for (previous = 0U; previous < selection_index; ++previous) {
            coco80_sd_selection_entry_t earlier;
            if (coco80_sd_selection_get_entry(
                    selection_data, selection_bytes, previous, &earlier) != 0 ||
                earlier.image_id == selected.image_id ||
                earlier.record_index == selected.record_index)
                return COCO80_SD_INDEX_ERR_SELECTION;
        }
    }
    if (header_out != NULL) *header_out = header;
    return COCO80_SD_INDEX_OK;
}

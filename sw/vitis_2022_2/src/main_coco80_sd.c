#include "accel_smoke.h"
#include "accel_runtime_v2.h"
#include "coco80_accel.h"
#include "coco80_generated_config.h"
#include "coco80_sd_index.h"

#include "ff.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xtime_l.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef COCO80_BOARD_MODE
#define COCO80_BOARD_MODE COCO80_ACCEL_MODE_ACCURACY
#endif
#ifndef COCO80_BOARD_IMAGE_LIMIT
#define COCO80_BOARD_IMAGE_LIMIT 5000U
#endif
#ifndef COCO80_BOARD_PERF_WARMUP
#define COCO80_BOARD_PERF_WARMUP 20U
#endif
#ifndef COCO80_BOARD_CONFORMANCE
#define COCO80_BOARD_CONFORMANCE 0
#endif

#define C8_INDEX_MAX_BYTES 262144U
#define C8_IMAGE_COUNT 5000U
#define C8_OUTPUT_MAGIC COCO80_SD_FOURCC('C', '8', 'O', 'X')
#define C8_OUTPUT_VERSION 2U
#define C8_OUTPUT_HEADER_BYTES 128U
#define C8_OUTPUT_ENTRY_BYTES 32U
#define C8_NODE_MAGIC COCO80_SD_FOURCC('C', '8', 'N', 'X')
#define C8_CONFORMANCE_MAX_IMAGES 128U
#define C8_ROOT "0:/COCO80_R5"
#define C8_INPUT_INDEX C8_ROOT "/INPUT/input_index.bin"
#define C8_CONFORMANCE_INDEX C8_ROOT "/INPUT/conformance_index.bin"
#define C8_PARAMETER_PACKAGE C8_ROOT "/PARAM/coco80_parameters.c8pa"

typedef struct {
    uint32_t magic, version, header_bytes, mode;
    uint32_t input_records, output_records, entry_bytes, entries_bytes;
    uint32_t data_bytes, data_crc32, entries_crc32, parameter_crc32;
    uint32_t input_index_crc32, software_build_crc32, hardware_build_crc32;
    uint32_t header_crc32;
    uint32_t selection_index_crc32;
    uint32_t reserved[15];
} c8_output_header_t;

typedef struct {
    uint32_t image_id, record_index, data_offset, data_bytes;
    uint32_t package_crc32, detection_count, total_ticks_lo, total_ticks_hi;
} c8_output_entry_t;

typedef char c8_output_header_size[
    sizeof(c8_output_header_t) == C8_OUTPUT_HEADER_BYTES ? 1 : -1];
typedef char c8_output_entry_size[
    sizeof(c8_output_entry_t) == C8_OUTPUT_ENTRY_BYTES ? 1 : -1];

static uint8_t c8_parameter_package[COCO80_SD_PARAMETER_PACKAGE_BYTES]
    __attribute__((aligned(64)));
static uint8_t c8_input_package[COCO80_ACCEL_INPUT_PACKAGE_BYTES]
    __attribute__((aligned(64)));
static uint8_t c8_index[C8_INDEX_MAX_BYTES] __attribute__((aligned(64)));
#if COCO80_BOARD_CONFORMANCE
static uint8_t c8_selection_index[
    COCO80_SD_SELECTION_HEADER_BYTES +
    COCO80_SD_SELECTION_MAX_ENTRIES * COCO80_SD_SELECTION_ENTRY_BYTES]
    __attribute__((aligned(64)));
#endif
static uint8_t c8_workspace_arena[COCO80_ACCEL_WORKSPACE_BYTES]
    __attribute__((aligned(64)));
static c8_output_entry_t c8_output_entries[C8_IMAGE_COUNT];
static FATFS c8_fatfs;

#if COCO80_BOARD_CONFORMANCE
typedef struct {
    uint32_t image_id, tensor_id, data_offset, data_bytes, crc32, sequence;
} c8_node_entry_t;
typedef struct {
    uint32_t magic, version, header_bytes, image_records;
    uint32_t node_records, entry_bytes, entries_bytes, data_bytes;
    uint32_t data_crc32, entries_crc32, parameter_crc32, input_index_crc32;
    uint32_t software_build_crc32, hardware_build_crc32, tensor_count, header_crc32;
    uint32_t selection_index_crc32;
    uint32_t reserved[15];
} c8_node_header_t;
typedef char c8_node_header_size[sizeof(c8_node_header_t) == 128U ? 1 : -1];
typedef char c8_node_entry_size[sizeof(c8_node_entry_t) == 24U ? 1 : -1];
typedef struct {
    FIL file;
    uint32_t image_id, node_count, data_bytes, crc_state;
    c8_node_entry_t entries[C8_CONFORMANCE_MAX_IMAGES * COCO80_ACCEL_TENSOR_COUNT];
} c8_node_writer_t;
static c8_node_writer_t c8_nodes;
#endif

static uint32_t c8_read32(void *opaque, uint32_t base, uint32_t offset)
{
    (void)opaque;
    return Xil_In32((UINTPTR)base + offset);
}

static void c8_write32(void *opaque, uint32_t base, uint32_t offset, uint32_t value)
{
    (void)opaque;
    Xil_Out32((UINTPTR)base + offset, value);
}

static void c8_flush(void *opaque, uintptr_t address, uint32_t bytes)
{
    (void)opaque;
    Xil_DCacheFlushRange((UINTPTR)address, bytes);
}

static void c8_invalidate(void *opaque, uintptr_t address, uint32_t bytes)
{
    (void)opaque;
    Xil_DCacheInvalidateRange((UINTPTR)address, bytes);
}

static uint64_t c8_ticks(void *opaque)
{
    XTime value;
    (void)opaque;
    XTime_GetTime(&value);
    return (uint64_t)value;
}

static accel_v2_runtime_t c8_runtime(void)
{
    accel_v2_runtime_t runtime;
    memset(&runtime, 0, sizeof(runtime));
    runtime.read32 = c8_read32;
    runtime.write32 = c8_write32;
    runtime.cache_flush = c8_flush;
    runtime.cache_invalidate = c8_invalidate;
    runtime.accel_base = ACCEL_BASE_ADDR;
    runtime.dma_base[ACCEL_V2_DMA_BIAS] = DMA_BIAS_BASE_ADDR;
    runtime.dma_base[ACCEL_V2_DMA_WEIGHT] = DMA_WEIGHT_BASE_ADDR;
    runtime.dma_base[ACCEL_V2_DMA_IFM] = DMA_IFM_BASE_ADDR;
    runtime.dma_base[ACCEL_V2_DMA_OFM] = DMA_OFM_BASE_ADDR;
    runtime.poll_limit = ACCEL_V2_DEFAULT_POLL_LIMIT;
    return runtime;
}

static int c8_read_exact(FIL *file, void *data, uint32_t bytes)
{
    uint8_t *cursor = (uint8_t *)data;
    while (bytes != 0U) {
        UINT got = 0U;
        UINT request = bytes > 1024U * 1024U ? 1024U * 1024U : (UINT)bytes;
        if (f_read(file, cursor, request, &got) != FR_OK || got != request) return -1;
        cursor += got;
        bytes -= got;
    }
    return 0;
}

static int c8_write_exact(FIL *file, const void *data, uint32_t bytes)
{
    const uint8_t *cursor = (const uint8_t *)data;
    while (bytes != 0U) {
        UINT put = 0U;
        UINT request = bytes > 1024U * 1024U ? 1024U * 1024U : (UINT)bytes;
        if (f_write(file, cursor, request, &put) != FR_OK || put != request) return -1;
        cursor += put;
        bytes -= put;
    }
    return 0;
}

#if COCO80_BOARD_CONFORMANCE
static int c8_node_hook(
    void *opaque, uint32_t tensor_id, const void *data, uint32_t bytes)
{
    c8_node_writer_t *writer = (c8_node_writer_t *)opaque;
    c8_node_entry_t *entry;
    uint32_t capacity = C8_CONFORMANCE_MAX_IMAGES * COCO80_ACCEL_TENSOR_COUNT;
    if (writer == NULL || data == NULL || bytes == 0U ||
        tensor_id >= COCO80_ACCEL_TENSOR_COUNT || writer->node_count >= capacity ||
        writer->data_bytes > 0xffffffffU - bytes) return -1;
    if (c8_write_exact(&writer->file, data, bytes) != 0) return -2;
    entry = &writer->entries[writer->node_count];
    entry->image_id = writer->image_id; entry->tensor_id = tensor_id;
    entry->data_offset = writer->data_bytes; entry->data_bytes = bytes;
    entry->crc32 = coco80_sd_crc32(data, bytes); entry->sequence = writer->node_count;
    writer->crc_state = coco80_sd_crc32_extend(writer->crc_state, data, bytes);
    writer->data_bytes += bytes; writer->node_count += 1U;
    return 0;
}

static int c8_write_node_index(
    uint32_t input_index_crc32, uint32_t selection_index_crc32)
{
    c8_node_header_t header;
    FIL file;
    uint32_t entry_bytes = c8_nodes.node_count * sizeof(c8_node_entry_t);
    memset(&header, 0, sizeof(header));
    header.magic = C8_NODE_MAGIC; header.version = 2U; header.header_bytes = 128U;
    header.image_records = c8_nodes.node_count / COCO80_ACCEL_TENSOR_COUNT;
    header.node_records = c8_nodes.node_count; header.entry_bytes = sizeof(c8_node_entry_t);
    header.entries_bytes = entry_bytes; header.data_bytes = c8_nodes.data_bytes;
    header.data_crc32 = coco80_sd_crc32_end(c8_nodes.crc_state);
    header.entries_crc32 = coco80_sd_crc32(c8_nodes.entries, entry_bytes);
    header.parameter_crc32 = coco80_runtime_config.parameter_package_crc32;
    header.input_index_crc32 = input_index_crc32;
    header.software_build_crc32 = coco80_runtime_config.software_build_crc32;
    header.hardware_build_crc32 = coco80_runtime_config.hardware_build_crc32;
    header.tensor_count = COCO80_ACCEL_TENSOR_COUNT;
    header.selection_index_crc32 = selection_index_crc32;
    header.header_crc32 = 0U;
    header.header_crc32 = coco80_sd_crc32(&header, sizeof(header));
    if (f_open(&file, C8_ROOT "/OUTPUT/CONFORM/node_index.partial",
               FA_WRITE | FA_CREATE_NEW) != FR_OK) return -1;
    if (c8_write_exact(&file, &header, sizeof(header)) != 0 ||
        c8_write_exact(&file, c8_nodes.entries, entry_bytes) != 0 ||
        f_sync(&file) != FR_OK || f_close(&file) != FR_OK) return -2;
    return f_rename(C8_ROOT "/OUTPUT/CONFORM/node_index.partial",
                    C8_ROOT "/OUTPUT/CONFORM/node_index.bin") == FR_OK ? 0 : -3;
}
#endif

static int c8_load_file(const char *path, void *data, uint32_t capacity, uint32_t *bytes_out)
{
    FIL file;
    FSIZE_t size;
    int rc;
    if (f_open(&file, path, FA_READ) != FR_OK) return -1;
    size = f_size(&file);
    if (size == 0U || size > capacity || (FSIZE_t)(uint32_t)size != size) {
        (void)f_close(&file);
        return -2;
    }
    rc = c8_read_exact(&file, data, (uint32_t)size);
    if (f_close(&file) != FR_OK) rc = -3;
    if (rc == 0 && bytes_out != NULL) *bytes_out = (uint32_t)size;
    return rc;
}

static uint32_t c8_output_header_crc(c8_output_header_t *header)
{
    uint32_t saved = header->header_crc32;
    uint32_t result;
    header->header_crc32 = 0U;
    result = coco80_sd_crc32(header, sizeof(*header));
    header->header_crc32 = saved;
    return result;
}

static const char *c8_data_partial(void)
{
#if COCO80_BOARD_CONFORMANCE
    return C8_ROOT "/OUTPUT/CONFORM/raw_heads.partial";
#endif
    if (COCO80_BOARD_MODE == COCO80_ACCEL_MODE_ACCURACY)
        return C8_ROOT "/OUTPUT/ACCURACY/raw_heads.partial";
    if (COCO80_BOARD_MODE == COCO80_ACCEL_MODE_PRODUCT)
        return C8_ROOT "/OUTPUT/PRODUCT/results.partial";
    return C8_ROOT "/OUTPUT/PERF/timings.partial";
}

static const char *c8_data_final(void)
{
#if COCO80_BOARD_CONFORMANCE
    return C8_ROOT "/OUTPUT/CONFORM/raw_heads.bin";
#endif
    if (COCO80_BOARD_MODE == COCO80_ACCEL_MODE_ACCURACY)
        return C8_ROOT "/OUTPUT/ACCURACY/raw_heads.bin";
    if (COCO80_BOARD_MODE == COCO80_ACCEL_MODE_PRODUCT)
        return C8_ROOT "/OUTPUT/PRODUCT/results.bin";
    return C8_ROOT "/OUTPUT/PERF/timings.bin";
}

static const char *c8_index_partial(void)
{
#if COCO80_BOARD_CONFORMANCE
    return C8_ROOT "/OUTPUT/CONFORM/output_index.partial";
#endif
    if (COCO80_BOARD_MODE == COCO80_ACCEL_MODE_ACCURACY)
        return C8_ROOT "/OUTPUT/ACCURACY/output_index.partial";
    if (COCO80_BOARD_MODE == COCO80_ACCEL_MODE_PRODUCT)
        return C8_ROOT "/OUTPUT/PRODUCT/output_index.partial";
    return C8_ROOT "/OUTPUT/PERF/output_index.partial";
}

static const char *c8_index_final(void)
{
#if COCO80_BOARD_CONFORMANCE
    return C8_ROOT "/OUTPUT/CONFORM/output_index.bin";
#endif
    if (COCO80_BOARD_MODE == COCO80_ACCEL_MODE_ACCURACY)
        return C8_ROOT "/OUTPUT/ACCURACY/output_index.bin";
    if (COCO80_BOARD_MODE == COCO80_ACCEL_MODE_PRODUCT)
        return C8_ROOT "/OUTPUT/PRODUCT/output_index.bin";
    return C8_ROOT "/OUTPUT/PERF/output_index.bin";
}

static int c8_path_must_not_exist(const char *path)
{
    FILINFO info;
    FRESULT result = f_stat(path, &info);
    if (result == FR_NO_FILE) return 0;
    return result == FR_OK ? -1 : -2;
}

static int c8_remove_incomplete_file(const char *path)
{
    FRESULT result = f_unlink(path);
    return result == FR_OK || result == FR_NO_FILE ? 0 : -1;
}

static int c8_prepare_output_paths(void)
{
    if (c8_path_must_not_exist(c8_data_final()) != 0 ||
        c8_path_must_not_exist(c8_index_final()) != 0) return -1;
#if COCO80_BOARD_CONFORMANCE
    if (c8_path_must_not_exist(C8_ROOT "/OUTPUT/CONFORM/nodes.bin") != 0 ||
        c8_path_must_not_exist(C8_ROOT "/OUTPUT/CONFORM/node_index.bin") != 0)
        return -2;
#endif
    if (c8_remove_incomplete_file(c8_data_partial()) != 0 ||
        c8_remove_incomplete_file(c8_index_partial()) != 0) return -3;
#if COCO80_BOARD_CONFORMANCE
    if (c8_remove_incomplete_file(C8_ROOT "/OUTPUT/CONFORM/nodes.partial") != 0 ||
        c8_remove_incomplete_file(C8_ROOT "/OUTPUT/CONFORM/node_index.partial") != 0)
        return -4;
#endif
    return 0;
}

static int c8_write_output_index(
    uint32_t input_records, uint32_t output_records,
    uint32_t data_bytes, uint32_t data_crc32, uint32_t input_index_crc32,
    uint32_t selection_index_crc32)
{
    c8_output_header_t header;
    FIL file;
    uint32_t entry_bytes = output_records * sizeof(c8_output_entry_t);
    memset(&header, 0, sizeof(header));
    header.magic = C8_OUTPUT_MAGIC; header.version = C8_OUTPUT_VERSION;
    header.header_bytes = sizeof(header); header.mode = COCO80_BOARD_MODE;
    header.input_records = input_records; header.output_records = output_records;
    header.entry_bytes = sizeof(c8_output_entry_t); header.entries_bytes = entry_bytes;
    header.data_bytes = data_bytes; header.data_crc32 = data_crc32;
    header.entries_crc32 = coco80_sd_crc32(c8_output_entries, entry_bytes);
    header.parameter_crc32 = coco80_runtime_config.parameter_package_crc32;
    header.input_index_crc32 = input_index_crc32;
    header.software_build_crc32 = coco80_runtime_config.software_build_crc32;
    header.hardware_build_crc32 = coco80_runtime_config.hardware_build_crc32;
    header.selection_index_crc32 = selection_index_crc32;
    header.header_crc32 = c8_output_header_crc(&header);
    if (f_open(&file, c8_index_partial(), FA_WRITE | FA_CREATE_NEW) != FR_OK) return -1;
    if (c8_write_exact(&file, &header, sizeof(header)) != 0 ||
        c8_write_exact(&file, c8_output_entries, entry_bytes) != 0 ||
        f_sync(&file) != FR_OK || f_close(&file) != FR_OK) return -2;
    if (f_rename(c8_index_partial(), c8_index_final()) != FR_OK) return -3;
    return 0;
}

int main(void)
{
    coco80_sd_index_header_t index_header;
    coco80_sd_index_entry_t entry;
    coco80_sd_index_shard_t shard;
    coco80_accel_workspace_t workspace;
    coco80_accel_runner_t runner;
    coco80_accel_output_t output;
    accel_v2_runtime_t runtime;
    FIL shard_file, data_file;
    uint32_t index_bytes = 0U, parameter_bytes = 0U, current_shard = 0xffffffffU;
    uint32_t input_limit = 0U, record, output_records = 0U, data_bytes = 0U;
    uint32_t data_crc_state = coco80_sd_crc32_begin();
    uint32_t input_index_crc, selection_index_crc = 0U;
#if COCO80_BOARD_CONFORMANCE
    coco80_sd_selection_header_t selection_header;
    coco80_sd_selection_entry_t selected;
    uint32_t selection_bytes = 0U;
#endif
    char shard_name[17], shard_path[64];
    int rc = 0, failure_detail = 0;

    memset(&runner, 0, sizeof(runner));
    Xil_DCacheEnable();
    xil_printf("COCO80_R5 BEGIN mode=%lu\r\n", (unsigned long)COCO80_BOARD_MODE);
    if (COCO80_BOARD_MODE > COCO80_ACCEL_MODE_PERFORMANCE ||
        COCO80_BOARD_IMAGE_LIMIT == 0U || COCO80_BOARD_IMAGE_LIMIT > C8_IMAGE_COUNT) {
        rc = -1; goto done;
    }
#if COCO80_BOARD_CONFORMANCE
    if (COCO80_BOARD_MODE != COCO80_ACCEL_MODE_ACCURACY ||
        COCO80_BOARD_IMAGE_LIMIT > C8_CONFORMANCE_MAX_IMAGES) { rc = -23; goto done; }
#endif
    {
        FRESULT mount_rc = f_mount(&c8_fatfs, "0:/", 1U);
        if (mount_rc != FR_OK) {
            failure_detail = (int)mount_rc; rc = -2; goto done;
        }
    }
    {
        int index_rc = c8_load_file(
            C8_INPUT_INDEX, c8_index, sizeof(c8_index), &index_bytes);
        if (index_rc != 0) {
            failure_detail = index_rc; rc = -3; goto done;
        }
        index_rc = coco80_sd_index_validate(c8_index, index_bytes, &index_header);
        if (index_rc != 0 || index_header.image_count != C8_IMAGE_COUNT) {
            failure_detail = index_rc != 0 ? index_rc : -305;
            rc = -3; goto done;
        }
    }
    input_index_crc = coco80_sd_crc32(c8_index, index_bytes);
#if COCO80_BOARD_CONFORMANCE
    {
        int selection_rc = c8_load_file(
            C8_CONFORMANCE_INDEX, c8_selection_index,
            sizeof(c8_selection_index), &selection_bytes);
        if (selection_rc != 0) {
            failure_detail = selection_rc; rc = -31; goto done;
        }
        selection_rc = coco80_sd_selection_validate(
            c8_selection_index, selection_bytes, c8_index, index_bytes,
            &selection_header);
        if (selection_rc != 0 ||
            selection_header.entry_count != COCO80_BOARD_IMAGE_LIMIT) {
            failure_detail = selection_rc != 0 ? selection_rc : -306;
            rc = -31; goto done;
        }
        selection_index_crc = coco80_sd_crc32(c8_selection_index, selection_bytes);
    }
#endif
    {
        int parameter_rc = c8_load_file(
            C8_PARAMETER_PACKAGE, c8_parameter_package,
            sizeof(c8_parameter_package), &parameter_bytes);
        if (parameter_rc != 0 ||
            parameter_bytes != (uint32_t)sizeof(c8_parameter_package)) {
            failure_detail = parameter_rc != 0 ? parameter_rc : -1;
            rc = -4; goto done;
        }
    }
    {
        int workspace_rc = coco80_accel_workspace_init(
            &workspace, c8_workspace_arena, sizeof(c8_workspace_arena));
        if (workspace_rc != 0) {
            failure_detail = workspace_rc; rc = -5; goto done;
        }
    }
    runtime = c8_runtime();
    if (coco80_accel_initialize(
            &runner, &runtime, c8_ticks, NULL, (uint32_t)COUNTS_PER_SECOND,
            &coco80_runtime_config, c8_parameter_package, parameter_bytes,
            &workspace) != 0) { rc = -6; goto done; }
#if defined(COCO80_ABLATION_RUNTIME) && COCO80_ABLATION_RUNTIME == 1
    if (coco80_accel_set_ablation_stream_config(
            &runner, COCO80_SD_ABLATION_STREAM_CONFIG) != COCO80_ACCEL_OK) {
        rc = -6; failure_detail = -601; goto done;
    }
#endif
    {
        int output_rc = c8_prepare_output_paths();
        if (output_rc != 0) {
            failure_detail = output_rc; rc = -30; goto done;
        }
    }
    if (f_open(&data_file, c8_data_partial(), FA_WRITE | FA_CREATE_NEW) != FR_OK) {
        rc = -7; goto done;
    }
#if COCO80_BOARD_CONFORMANCE
    memset(&c8_nodes, 0, sizeof(c8_nodes));
    c8_nodes.crc_state = coco80_sd_crc32_begin();
    if (f_open(&c8_nodes.file, C8_ROOT "/OUTPUT/CONFORM/nodes.partial",
               FA_WRITE | FA_CREATE_NEW) != FR_OK) {
        (void)f_close(&data_file); rc = -24; goto done;
    }
    if (coco80_accel_set_tensor_hook(&runner, c8_node_hook, &c8_nodes) != 0) {
        (void)f_close(&c8_nodes.file); (void)f_close(&data_file);
        rc = -24; goto done;
    }
#endif
    input_limit = COCO80_BOARD_IMAGE_LIMIT;
    if (COCO80_BOARD_MODE == COCO80_ACCEL_MODE_PERFORMANCE) {
        if (input_limit > C8_IMAGE_COUNT - COCO80_BOARD_PERF_WARMUP) {
            input_limit = C8_IMAGE_COUNT - COCO80_BOARD_PERF_WARMUP;
        }
        input_limit += COCO80_BOARD_PERF_WARMUP;
    }
    memset(&shard_file, 0, sizeof(shard_file));
    for (record = 0U; record < input_limit; ++record) {
        const void *write_data;
        uint32_t write_bytes, package_crc, timed = 1U, source_record = record;
#if COCO80_BOARD_CONFORMANCE
        if (coco80_sd_selection_get_entry(
                c8_selection_index, selection_bytes, record, &selected) != 0) {
            rc = -32; break;
        }
        source_record = selected.record_index;
#endif
        if (coco80_sd_index_get_entry(c8_index, index_bytes, source_record, &entry) != 0 ||
            entry.bytes != sizeof(c8_input_package)) { rc = -8; break; }
#if COCO80_BOARD_CONFORMANCE
        if (entry.image_id != selected.image_id) { rc = -32; break; }
#endif
        if (entry.shard_id != current_shard) {
            if (current_shard != 0xffffffffU && f_close(&shard_file) != FR_OK) { rc = -9; break; }
            if (coco80_sd_index_get_shard(
                    c8_index, index_bytes, entry.shard_id, &shard, shard_name) != 0) {
                rc = -10; break;
            }
            (void)snprintf(shard_path, sizeof(shard_path), C8_ROOT "/INPUT/%s", shard_name);
            if (f_open(&shard_file, shard_path, FA_READ) != FR_OK ||
                f_size(&shard_file) != shard.bytes) { rc = -11; break; }
            current_shard = entry.shard_id;
        }
        if (f_lseek(&shard_file, entry.offset) != FR_OK ||
            c8_read_exact(&shard_file, c8_input_package, entry.bytes) != 0) { rc = -12; break; }
        package_crc = coco80_sd_crc32(c8_input_package, entry.bytes);
        if (package_crc != entry.package_crc32) { rc = -13; break; }
#if COCO80_BOARD_CONFORMANCE
        c8_nodes.image_id = entry.image_id;
#endif
        if (coco80_accel_infer_package(
                &runner, c8_input_package, entry.bytes,
                (coco80_accel_mode_t)COCO80_BOARD_MODE, &output) != 0) {
            rc = -14; break;
        }
        if (COCO80_BOARD_MODE == COCO80_ACCEL_MODE_ACCURACY) {
            write_data = output.raw_head_package; write_bytes = output.raw_head_package_bytes;
        } else if (COCO80_BOARD_MODE == COCO80_ACCEL_MODE_PRODUCT) {
            write_data = output.result_package; write_bytes = output.result_package_bytes;
        } else {
            timed = record >= COCO80_BOARD_PERF_WARMUP;
            write_data = &output.timing; write_bytes = sizeof(output.timing);
        }
        if (timed != 0U) {
            if (data_bytes > 0xffffffffU - write_bytes ||
                c8_write_exact(&data_file, write_data, write_bytes) != 0) { rc = -15; break; }
            c8_output_entries[output_records].image_id = output.image_id;
            c8_output_entries[output_records].record_index = record;
            c8_output_entries[output_records].data_offset = data_bytes;
            c8_output_entries[output_records].data_bytes = write_bytes;
            c8_output_entries[output_records].package_crc32 = coco80_sd_crc32(write_data, write_bytes);
            c8_output_entries[output_records].detection_count = output.detection_count;
            c8_output_entries[output_records].total_ticks_lo = (uint32_t)output.timing.total_ticks;
            c8_output_entries[output_records].total_ticks_hi = (uint32_t)(output.timing.total_ticks >> 32);
            data_crc_state = coco80_sd_crc32_extend(data_crc_state, write_data, write_bytes);
            data_bytes += write_bytes; output_records += 1U;
        }
        if ((record + 1U) % 100U == 0U) {
            if (f_sync(&data_file) != FR_OK) { rc = -16; break; }
            xil_printf("COCO80_R5 PROGRESS images=%lu outputs=%lu\r\n",
                       (unsigned long)(record + 1U), (unsigned long)output_records);
        }
    }
    if (current_shard != 0xffffffffU && f_close(&shard_file) != FR_OK && rc == 0) rc = -17;
    if (f_sync(&data_file) != FR_OK && rc == 0) rc = -18;
    if (f_close(&data_file) != FR_OK && rc == 0) rc = -19;
    if (rc == 0 && output_records == 0U) rc = -20;
    if (rc == 0 && f_rename(c8_data_partial(), c8_data_final()) != FR_OK) rc = -21;
    if (rc == 0 && c8_write_output_index(
            input_limit, output_records, data_bytes, coco80_sd_crc32_end(data_crc_state),
            input_index_crc, selection_index_crc) != 0) rc = -22;
#if COCO80_BOARD_CONFORMANCE
    if (f_sync(&c8_nodes.file) != FR_OK && rc == 0) rc = -25;
    if (f_close(&c8_nodes.file) != FR_OK && rc == 0) rc = -26;
    if (rc == 0 && c8_nodes.node_count !=
            input_limit * COCO80_ACCEL_TENSOR_COUNT) rc = -27;
    if (rc == 0 && f_rename(C8_ROOT "/OUTPUT/CONFORM/nodes.partial",
                            C8_ROOT "/OUTPUT/CONFORM/nodes.bin") != FR_OK) rc = -28;
    if (rc == 0 && c8_write_node_index(
            input_index_crc, selection_index_crc) != 0) rc = -29;
#endif

done:
    if (rc == 0) {
        xil_printf("COCO80_R5 PASS mode=%lu images=%lu outputs=%lu bytes=%lu\r\n",
                   (unsigned long)COCO80_BOARD_MODE, (unsigned long)input_limit,
                   (unsigned long)output_records, (unsigned long)data_bytes);
    } else {
        xil_printf("COCO80_R5 FAIL rc=%d layer=%lu detail=%d\r\n", rc,
                   (unsigned long)(runner.initialized != 0U ?
                       runner.failure.layer_index : UINT32_MAX),
                   runner.failure.detail != 0 ? runner.failure.detail : failure_detail);
    }
    return rc == 0 ? 0 : 1;
}

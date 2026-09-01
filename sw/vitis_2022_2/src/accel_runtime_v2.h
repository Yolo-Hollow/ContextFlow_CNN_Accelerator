#ifndef ACCEL_RUNTIME_V2_H
#define ACCEL_RUNTIME_V2_H

#include "accel_smoke.h"

#include <stddef.h>
#include <stdint.h>

/*
 * Platform-independent ABI-v2 layer dispatcher.
 *
 * The board application supplies MMIO/cache callbacks.  Keeping the ordering
 * logic here makes the exact four-DMA transaction and recovery sequence
 * executable in a host mock without weakening the fail-closed board build.
 */

#define ACCEL_V2_DMA_COUNT 4U
#define ACCEL_V2_DMA_COMPLETE_ALL ((1U << ACCEL_V2_DMA_COUNT) - 1U)
#define ACCEL_V2_DEFAULT_POLL_LIMIT 50000000U
#define ACCEL_V2_INVALID_DMA 0xffU

enum {
    ACCEL_V2_DMA_BIAS = 0,
    ACCEL_V2_DMA_WEIGHT = 1,
    ACCEL_V2_DMA_IFM = 2,
    ACCEL_V2_DMA_OFM = 3
};

enum {
    ACCEL_V2_RUN_OK = 0,
    ACCEL_V2_RUN_ERR_ARGUMENT = -100,
    ACCEL_V2_RUN_ERR_LENGTH = -101,
    ACCEL_V2_RUN_ERR_DMA_STATUS = -102,
    ACCEL_V2_RUN_ERR_DMA_NOT_IDLE = -103,
    ACCEL_V2_RUN_ERR_ACCEL_NOT_IDLE = -104,
    ACCEL_V2_RUN_ERR_PROGRAM = -105,
    ACCEL_V2_RUN_ERR_TELEMETRY_VERSION = -106,
    ACCEL_V2_RUN_ERR_DATAPATH = -107,
    ACCEL_V2_RUN_ERR_CONFIG = -108,
    ACCEL_V2_RUN_ERR_TIMEOUT = -109,
    ACCEL_V2_RUN_ERR_LIFECYCLE = -110,
    ACCEL_V2_RUN_ERR_CONTEXT_COUNTER = -111,
    ACCEL_V2_RUN_ERR_RESET = -112,
    ACCEL_V2_RUN_ERR_ALIGNMENT = -113
};

typedef uint32_t (*accel_v2_mmio_read_fn)(
    void *opaque, uint32_t base, uint32_t offset);
typedef void (*accel_v2_mmio_write_fn)(
    void *opaque, uint32_t base, uint32_t offset, uint32_t value);
typedef void (*accel_v2_cache_range_fn)(
    void *opaque, uintptr_t address, uint32_t bytes);
typedef void (*accel_v2_poll_hook_fn)(void *opaque);
typedef int (*accel_v2_program_layer_fn)(void *opaque);

typedef struct {
    void *opaque;
    accel_v2_mmio_read_fn read32;
    accel_v2_mmio_write_fn write32;
    accel_v2_cache_range_fn cache_flush;
    accel_v2_cache_range_fn cache_invalidate;
    accel_v2_poll_hook_fn poll_hook;
    uint32_t accel_base;
    uint32_t dma_base[ACCEL_V2_DMA_COUNT];
    uint32_t poll_limit;
} accel_v2_runtime_t;

typedef struct {
    const void *bias_data;
    uint32_t bias_bytes;
    const void *weight_data;
    uint32_t weight_bytes;
    const void *ifm_data;
    uint32_t ifm_bytes;
    void *ofm_data;
    uint32_t ofm_bytes;
    uint32_t expected_contexts;
    accel_v2_program_layer_fn program_layer;
    void *program_opaque;
} accel_v2_layer_transfer_t;

typedef struct {
    uint32_t version;
    uint32_t alloc;
    uint32_t input_issued;
    uint32_t array_retired;
    uint32_t collector_done;
    uint32_t context_gap;
    uint32_t ifm_owner_stall;
    uint32_t weight_owner_stall;
    uint32_t psum_credit_stall;
    uint32_t epoch_mismatch;
    uint32_t context_mismatch;
    uint32_t ifm_underflow;
    uint32_t psum_underflow;
    uint32_t fifo_drop;
    uint32_t bank_overwrite;
    uint32_t context_full_stall;
} accel_v2_context_telemetry_t;

typedef struct {
    int failure;
    int recovery_result;
    uint8_t failed_dma;
    uint32_t poll_count;
    uint32_t dma_complete_mask;
    uint32_t datapath_errors;
    accel_v2_context_telemetry_t before;
    accel_v2_context_telemetry_t after;
    accel_v2_context_telemetry_t delta;
} accel_v2_layer_report_t;

static inline uint32_t accel_v2_u32_delta(uint32_t after, uint32_t before)
{
    return after - before;
}

static inline uint32_t accel_v2_poll_limit(const accel_v2_runtime_t *runtime)
{
    return runtime->poll_limit != 0U ? runtime->poll_limit :
        ACCEL_V2_DEFAULT_POLL_LIMIT;
}

/*
 * AXI DMA resets into HALTED with no transfer in flight.  A channel that has
 * completed a transfer reports IDLE instead.  Both are safe states from
 * which software may program the next simple-mode transfer; status==0 means
 * a RUNSTOP channel is active but has not completed and is not quiescent.
 */
static inline int accel_v2_dma_status_quiescent(uint32_t status)
{
    return (status & (DMA_DMASR_HALTED | DMA_DMASR_IDLE)) != 0U;
}

static inline int accel_v2_dma_status_completed(uint32_t status)
{
    return (status & DMA_DMASR_IDLE) != 0U &&
        (status & DMA_DMASR_HALTED) == 0U;
}

static inline void accel_v2_poll_hook(const accel_v2_runtime_t *runtime)
{
    if (runtime->poll_hook != NULL) {
        runtime->poll_hook(runtime->opaque);
    }
}

static inline int accel_v2_runtime_valid(const accel_v2_runtime_t *runtime)
{
    return runtime != NULL && runtime->read32 != NULL &&
        runtime->write32 != NULL && runtime->accel_base != 0U &&
        runtime->dma_base[ACCEL_V2_DMA_BIAS] != 0U &&
        runtime->dma_base[ACCEL_V2_DMA_WEIGHT] != 0U &&
        runtime->dma_base[ACCEL_V2_DMA_IFM] != 0U &&
        runtime->dma_base[ACCEL_V2_DMA_OFM] != 0U;
}

static inline uint32_t accel_v2_dma_status_offset(uint32_t dma)
{
    return dma == ACCEL_V2_DMA_OFM ? DMA_S2MM_DMASR : DMA_MM2S_DMASR;
}

static inline uint32_t accel_v2_dma_control_offset(uint32_t dma)
{
    return dma == ACCEL_V2_DMA_OFM ? DMA_S2MM_DMACR : DMA_MM2S_DMACR;
}

static inline void accel_v2_read_context_telemetry(
    const accel_v2_runtime_t *runtime,
    accel_v2_context_telemetry_t *value)
{
    value->version = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_TELEMETRY_VERSION_REG);
    value->alloc = runtime->read32(
        runtime->opaque, runtime->accel_base, ACCEL_CONTEXT_ALLOC_COUNT_REG);
    value->input_issued = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_INPUT_ISSUED_COUNT_REG);
    value->array_retired = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_ARRAY_RETIRED_COUNT_REG);
    value->collector_done = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_COLLECTOR_DONE_COUNT_REG);
    value->context_gap = runtime->read32(
        runtime->opaque, runtime->accel_base, ACCEL_CONTEXT_GAP_CYCLES_REG);
    value->ifm_owner_stall = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_IFM_OWNER_STALL_CYCLES_REG);
    value->weight_owner_stall = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_WEIGHT_OWNER_STALL_CYCLES_REG);
    value->psum_credit_stall = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_PSUM_CREDIT_STALL_CYCLES_REG);
    value->epoch_mismatch = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_EPOCH_MISMATCH_COUNT_REG);
    value->context_mismatch = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_MISMATCH_COUNT_REG);
    value->ifm_underflow = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_IFM_UNDERFLOW_COUNT_REG);
    value->psum_underflow = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_PSUM_UNDERFLOW_COUNT_REG);
    value->fifo_drop = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_FIFO_DROP_COUNT_REG);
    value->bank_overwrite = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_BANK_OVERWRITE_COUNT_REG);
    value->context_full_stall = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_CONTEXT_FULL_STALL_CYCLES_REG);
}

static inline void accel_v2_context_telemetry_delta(
    const accel_v2_context_telemetry_t *after,
    const accel_v2_context_telemetry_t *before,
    accel_v2_context_telemetry_t *delta)
{
    delta->version = after->version;
    delta->alloc = accel_v2_u32_delta(after->alloc, before->alloc);
    delta->input_issued = accel_v2_u32_delta(
        after->input_issued, before->input_issued);
    delta->array_retired = accel_v2_u32_delta(
        after->array_retired, before->array_retired);
    delta->collector_done = accel_v2_u32_delta(
        after->collector_done, before->collector_done);
    delta->context_gap = accel_v2_u32_delta(
        after->context_gap, before->context_gap);
    delta->ifm_owner_stall = accel_v2_u32_delta(
        after->ifm_owner_stall, before->ifm_owner_stall);
    delta->weight_owner_stall = accel_v2_u32_delta(
        after->weight_owner_stall, before->weight_owner_stall);
    delta->psum_credit_stall = accel_v2_u32_delta(
        after->psum_credit_stall, before->psum_credit_stall);
    delta->epoch_mismatch = accel_v2_u32_delta(
        after->epoch_mismatch, before->epoch_mismatch);
    delta->context_mismatch = accel_v2_u32_delta(
        after->context_mismatch, before->context_mismatch);
    delta->ifm_underflow = accel_v2_u32_delta(
        after->ifm_underflow, before->ifm_underflow);
    delta->psum_underflow = accel_v2_u32_delta(
        after->psum_underflow, before->psum_underflow);
    delta->fifo_drop = accel_v2_u32_delta(
        after->fifo_drop, before->fifo_drop);
    delta->bank_overwrite = accel_v2_u32_delta(
        after->bank_overwrite, before->bank_overwrite);
    delta->context_full_stall = accel_v2_u32_delta(
        after->context_full_stall, before->context_full_stall);
}

static inline int accel_v2_validate_context_delta(
    const accel_v2_context_telemetry_t *delta,
    uint32_t expected_contexts)
{
    if (delta->alloc != expected_contexts ||
        delta->input_issued != expected_contexts ||
        delta->array_retired != expected_contexts ||
        delta->collector_done != expected_contexts ||
        delta->alloc != delta->input_issued ||
        delta->input_issued != delta->array_retired ||
        delta->array_retired != delta->collector_done) {
        return ACCEL_V2_RUN_ERR_LIFECYCLE;
    }
    if (delta->epoch_mismatch != 0U || delta->context_mismatch != 0U ||
        delta->ifm_underflow != 0U || delta->psum_underflow != 0U ||
        delta->fifo_drop != 0U || delta->bank_overwrite != 0U ||
        delta->context_full_stall != 0U) {
        return ACCEL_V2_RUN_ERR_CONTEXT_COUNTER;
    }
    return ACCEL_V2_RUN_OK;
}

static inline int accel_v2_dma_reset_one(
    const accel_v2_runtime_t *runtime, uint32_t dma)
{
    uint32_t limit = accel_v2_poll_limit(runtime);
    uint32_t control_offset = accel_v2_dma_control_offset(dma);
    uint32_t status_offset = accel_v2_dma_status_offset(dma);
    int reset_cleared = 0;

    runtime->write32(runtime->opaque, runtime->dma_base[dma],
                     control_offset, DMA_DMACR_RESET);
    for (uint32_t i = 0U; i < limit; ++i) {
        uint32_t control = runtime->read32(
            runtime->opaque, runtime->dma_base[dma], control_offset);
        if ((control & DMA_DMACR_RESET) == 0U) {
            uint32_t status;
            reset_cleared = 1;
            runtime->write32(runtime->opaque, runtime->dma_base[dma],
                             status_offset, DMA_DMASR_IRQ_ACK_MASK);
            status = runtime->read32(
                runtime->opaque, runtime->dma_base[dma], status_offset);
            if ((status & DMA_DMASR_ERR_MASK) != 0U) {
                return ACCEL_V2_RUN_ERR_DMA_STATUS;
            }
            if (accel_v2_dma_status_quiescent(status)) {
                return ACCEL_V2_RUN_OK;
            }
        }
        accel_v2_poll_hook(runtime);
    }
    return reset_cleared ? ACCEL_V2_RUN_ERR_DMA_NOT_IDLE :
        ACCEL_V2_RUN_ERR_RESET;
}

static inline int accel_v2_runtime_recover(
    const accel_v2_runtime_t *runtime)
{
    uint32_t reset_count_before;
    uint32_t limit;
    int dma_failure = ACCEL_V2_RUN_OK;

    if (!accel_v2_runtime_valid(runtime)) {
        return ACCEL_V2_RUN_ERR_ARGUMENT;
    }
    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        int rc = accel_v2_dma_reset_one(runtime, dma);
        if (rc != ACCEL_V2_RUN_OK && dma_failure == ACCEL_V2_RUN_OK) {
            dma_failure = rc;
        }
    }
    if (dma_failure != ACCEL_V2_RUN_OK) {
        return dma_failure;
    }

    reset_count_before = runtime->read32(
        runtime->opaque, runtime->accel_base,
        ACCEL_DATAPATH_RESET_COUNT_REG);
    runtime->write32(runtime->opaque, runtime->accel_base, ACCEL_CTRL,
                     ACCEL_CTRL_DATAPATH_RESET_MASK);
    limit = accel_v2_poll_limit(runtime);
    for (uint32_t i = 0U; i < limit; ++i) {
        uint32_t control = runtime->read32(
            runtime->opaque, runtime->accel_base, ACCEL_CTRL);
        uint32_t reset_count = runtime->read32(
            runtime->opaque, runtime->accel_base,
            ACCEL_DATAPATH_RESET_COUNT_REG);
        if (accel_v2_u32_delta(reset_count, reset_count_before) == 1U &&
            (control & ACCEL_CTRL_RESET_ACTIVE_MASK) == 0U) {
            uint32_t errors = runtime->read32(
                runtime->opaque, runtime->accel_base,
                ACCEL_DATAPATH_ERRORS_REG);
            if ((control & (ACCEL_CTRL_BUSY_MASK |
                            ACCEL_CTRL_CONFIG_ERROR_MASK)) == 0U &&
                errors == 0U) {
                return ACCEL_V2_RUN_OK;
            }
            return ACCEL_V2_RUN_ERR_RESET;
        }
        accel_v2_poll_hook(runtime);
    }
    return ACCEL_V2_RUN_ERR_RESET;
}

static inline int accel_v2_check_dma_idle(
    const accel_v2_runtime_t *runtime, uint8_t *failed_dma)
{
    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        uint32_t status = runtime->read32(
            runtime->opaque, runtime->dma_base[dma],
            accel_v2_dma_status_offset(dma));
        if ((status & DMA_DMASR_ERR_MASK) != 0U) {
            *failed_dma = (uint8_t)dma;
            return ACCEL_V2_RUN_ERR_DMA_STATUS;
        }
        if (!accel_v2_dma_status_completed(status)) {
            *failed_dma = (uint8_t)dma;
            return ACCEL_V2_RUN_ERR_DMA_NOT_IDLE;
        }
    }
    return ACCEL_V2_RUN_OK;
}

static inline int accel_v2_check_dma_quiescent(
    const accel_v2_runtime_t *runtime, uint8_t *failed_dma)
{
    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        uint32_t status = runtime->read32(
            runtime->opaque, runtime->dma_base[dma],
            accel_v2_dma_status_offset(dma));
        if ((status & DMA_DMASR_ERR_MASK) != 0U) {
            *failed_dma = (uint8_t)dma;
            return ACCEL_V2_RUN_ERR_DMA_STATUS;
        }
        if (!accel_v2_dma_status_quiescent(status)) {
            *failed_dma = (uint8_t)dma;
            return ACCEL_V2_RUN_ERR_DMA_NOT_IDLE;
        }
    }
    return ACCEL_V2_RUN_OK;
}

static inline int accel_v2_length_valid(uint32_t bytes)
{
    return bytes != 0U && bytes < DMA_SIMPLE_MAX_LENGTH;
}

static inline int accel_v2_address_aligned(const void *data)
{
    /* The four 64-bit AXI DMA channels are built without a DRE. */
    return (((uintptr_t)data) & 7U) == 0U;
}

static inline void accel_v2_start_mm2s(
    const accel_v2_runtime_t *runtime, uint32_t dma,
    const void *data, uint32_t bytes)
{
    uintptr_t address = (uintptr_t)data;
    if (runtime->cache_flush != NULL) {
        runtime->cache_flush(runtime->opaque, address, bytes);
    }
    runtime->write32(runtime->opaque, runtime->dma_base[dma],
                     DMA_MM2S_DMACR, DMA_DMACR_RUNSTOP);
    runtime->write32(runtime->opaque, runtime->dma_base[dma],
                     DMA_MM2S_SA, (uint32_t)address);
    runtime->write32(runtime->opaque, runtime->dma_base[dma],
                     DMA_MM2S_SA_MSB, (uint32_t)(address >> 32));
    runtime->write32(runtime->opaque, runtime->dma_base[dma],
                     DMA_MM2S_LENGTH, bytes);
}

static inline void accel_v2_start_s2mm(
    const accel_v2_runtime_t *runtime, void *data, uint32_t bytes)
{
    uintptr_t address = (uintptr_t)data;
    uint32_t base = runtime->dma_base[ACCEL_V2_DMA_OFM];
    if (runtime->cache_flush != NULL) {
        runtime->cache_flush(runtime->opaque, address, bytes);
    }
    runtime->write32(runtime->opaque, base,
                     DMA_S2MM_DMACR, DMA_DMACR_RUNSTOP);
    runtime->write32(runtime->opaque, base,
                     DMA_S2MM_DA, (uint32_t)address);
    runtime->write32(runtime->opaque, base,
                     DMA_S2MM_DA_MSB, (uint32_t)(address >> 32));
    runtime->write32(runtime->opaque, base, DMA_S2MM_LENGTH, bytes);
}

static inline int accel_v2_dispatch_failure(
    const accel_v2_runtime_t *runtime,
    accel_v2_layer_report_t *report,
    int failure)
{
    report->failure = failure;
    report->recovery_result = accel_v2_runtime_recover(runtime);
    return failure;
}

static inline int accel_v2_dispatch_layer(
    const accel_v2_runtime_t *runtime,
    const accel_v2_layer_transfer_t *transfer,
    accel_v2_layer_report_t *report)
{
    uint32_t complete_mask = 0U;
    uint32_t limit;
    int rc;

    if (!accel_v2_runtime_valid(runtime) || transfer == NULL ||
        report == NULL || transfer->program_layer == NULL ||
        transfer->bias_data == NULL || transfer->weight_data == NULL ||
        transfer->ifm_data == NULL || transfer->ofm_data == NULL ||
        transfer->expected_contexts == 0U) {
        return ACCEL_V2_RUN_ERR_ARGUMENT;
    }
    *report = (accel_v2_layer_report_t){0};
    report->failed_dma = ACCEL_V2_INVALID_DMA;
    if (!accel_v2_length_valid(transfer->bias_bytes) ||
        !accel_v2_length_valid(transfer->weight_bytes) ||
        !accel_v2_length_valid(transfer->ifm_bytes) ||
        !accel_v2_length_valid(transfer->ofm_bytes)) {
        report->failure = ACCEL_V2_RUN_ERR_LENGTH;
        return ACCEL_V2_RUN_ERR_LENGTH;
    }
    if (!accel_v2_address_aligned(transfer->bias_data) ||
        !accel_v2_address_aligned(transfer->weight_data) ||
        !accel_v2_address_aligned(transfer->ifm_data) ||
        !accel_v2_address_aligned(transfer->ofm_data)) {
        report->failure = ACCEL_V2_RUN_ERR_ALIGNMENT;
        return ACCEL_V2_RUN_ERR_ALIGNMENT;
    }

    rc = accel_v2_check_dma_quiescent(runtime, &report->failed_dma);
    if (rc != ACCEL_V2_RUN_OK) {
        return accel_v2_dispatch_failure(runtime, report, rc);
    }
    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        runtime->write32(runtime->opaque, runtime->dma_base[dma],
                         accel_v2_dma_status_offset(dma),
                         DMA_DMASR_IRQ_ACK_MASK);
    }
    {
        uint32_t control = runtime->read32(
            runtime->opaque, runtime->accel_base, ACCEL_CTRL);
        uint32_t errors = runtime->read32(
            runtime->opaque, runtime->accel_base,
            ACCEL_DATAPATH_ERRORS_REG);
        if ((control & (ACCEL_CTRL_BUSY_MASK |
                        ACCEL_CTRL_RESET_ACTIVE_MASK)) != 0U) {
            return accel_v2_dispatch_failure(
                runtime, report, ACCEL_V2_RUN_ERR_ACCEL_NOT_IDLE);
        }
        if ((control & ACCEL_CTRL_CONFIG_ERROR_MASK) != 0U || errors != 0U) {
            return accel_v2_dispatch_failure(
                runtime, report,
                errors != 0U ? ACCEL_V2_RUN_ERR_DATAPATH :
                    ACCEL_V2_RUN_ERR_CONFIG);
        }
    }

    runtime->write32(runtime->opaque, runtime->accel_base, ACCEL_CTRL,
                     ACCEL_CTRL_CLEAR_STATUS_MASK);
    accel_v2_poll_hook(runtime);
    if (transfer->program_layer(transfer->program_opaque) != 0) {
        return accel_v2_dispatch_failure(
            runtime, report, ACCEL_V2_RUN_ERR_PROGRAM);
    }
    accel_v2_read_context_telemetry(runtime, &report->before);
    if (report->before.version != ACCEL_CONTEXT_TELEMETRY_VERSION) {
        return accel_v2_dispatch_failure(
            runtime, report, ACCEL_V2_RUN_ERR_TELEMETRY_VERSION);
    }

    /* The sink is armed before any source can produce a byte. */
    accel_v2_start_s2mm(runtime, transfer->ofm_data, transfer->ofm_bytes);
    accel_v2_start_mm2s(runtime, ACCEL_V2_DMA_BIAS,
                       transfer->bias_data, transfer->bias_bytes);
    accel_v2_start_mm2s(runtime, ACCEL_V2_DMA_WEIGHT,
                       transfer->weight_data, transfer->weight_bytes);
    accel_v2_start_mm2s(runtime, ACCEL_V2_DMA_IFM,
                       transfer->ifm_data, transfer->ifm_bytes);
    runtime->write32(runtime->opaque, runtime->accel_base, ACCEL_CTRL,
                     ACCEL_CTRL_START_MASK);

    limit = accel_v2_poll_limit(runtime);
    for (uint32_t i = 0U; i < limit; ++i) {
        uint32_t status[ACCEL_V2_DMA_COUNT];
        uint32_t control;
        uint32_t errors;

        report->poll_count = i + 1U;
        for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
            status[dma] = runtime->read32(
                runtime->opaque, runtime->dma_base[dma],
                accel_v2_dma_status_offset(dma));
        }
        /* Error has priority even when an IOC bit is asserted in the same read. */
        for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
            if ((status[dma] & DMA_DMASR_ERR_MASK) != 0U) {
                report->failed_dma = (uint8_t)dma;
                return accel_v2_dispatch_failure(
                    runtime, report, ACCEL_V2_RUN_ERR_DMA_STATUS);
            }
        }
        errors = runtime->read32(
            runtime->opaque, runtime->accel_base,
            ACCEL_DATAPATH_ERRORS_REG);
        control = runtime->read32(
            runtime->opaque, runtime->accel_base, ACCEL_CTRL);
        report->datapath_errors = errors;
        if (errors != 0U) {
            return accel_v2_dispatch_failure(
                runtime, report, ACCEL_V2_RUN_ERR_DATAPATH);
        }
        if ((control & ACCEL_CTRL_CONFIG_ERROR_MASK) != 0U) {
            return accel_v2_dispatch_failure(
                runtime, report, ACCEL_V2_RUN_ERR_CONFIG);
        }

        for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
            uint32_t bit = 1U << dma;
            if ((complete_mask & bit) == 0U &&
                (status[dma] & DMA_DMASR_IOC_IRQ) != 0U) {
                complete_mask |= bit;
                runtime->write32(runtime->opaque, runtime->dma_base[dma],
                                 accel_v2_dma_status_offset(dma),
                                 DMA_DMASR_IOC_IRQ);
            }
        }
        report->dma_complete_mask = complete_mask;
        if (complete_mask == ACCEL_V2_DMA_COMPLETE_ALL &&
            (control & ACCEL_CTRL_DONE_MASK) != 0U &&
            (control & (ACCEL_CTRL_BUSY_MASK |
                        ACCEL_CTRL_RESET_ACTIVE_MASK)) == 0U) {
            rc = accel_v2_check_dma_idle(runtime, &report->failed_dma);
            if (rc != ACCEL_V2_RUN_OK) {
                return accel_v2_dispatch_failure(runtime, report, rc);
            }
            accel_v2_read_context_telemetry(runtime, &report->after);
            if (report->after.version != ACCEL_CONTEXT_TELEMETRY_VERSION) {
                return accel_v2_dispatch_failure(
                    runtime, report,
                    ACCEL_V2_RUN_ERR_TELEMETRY_VERSION);
            }
            accel_v2_context_telemetry_delta(
                &report->after, &report->before, &report->delta);
            rc = accel_v2_validate_context_delta(
                &report->delta, transfer->expected_contexts);
            if (rc != ACCEL_V2_RUN_OK) {
                return accel_v2_dispatch_failure(runtime, report, rc);
            }
            if (runtime->cache_invalidate != NULL) {
                runtime->cache_invalidate(
                    runtime->opaque, (uintptr_t)transfer->ofm_data,
                    transfer->ofm_bytes);
            }
            report->failure = ACCEL_V2_RUN_OK;
            report->recovery_result = ACCEL_V2_RUN_OK;
            return ACCEL_V2_RUN_OK;
        }
        accel_v2_poll_hook(runtime);
    }

    return accel_v2_dispatch_failure(
        runtime, report, ACCEL_V2_RUN_ERR_TIMEOUT);
}

#endif

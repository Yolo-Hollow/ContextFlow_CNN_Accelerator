#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "accel_runtime_v2.h"

#define MOCK_REG_WORDS 256U
#define MOCK_EVENT_CAPACITY 512U
#define MOCK_EVENT_MMIO_WRITE 1U
#define MOCK_EVENT_CACHE_FLUSH 2U
#define MOCK_EVENT_CACHE_INVALIDATE 3U
#define MOCK_EVENT_PROGRAM 4U

typedef struct {
    uint32_t kind;
    uint32_t base;
    uint32_t offset;
    uint32_t value;
} mock_event_t;

typedef struct {
    uint32_t accel[MOCK_REG_WORDS];
    uint32_t dma[ACCEL_V2_DMA_COUNT][MOCK_REG_WORDS];
    uint32_t dma_reset_delay[ACCEL_V2_DMA_COUNT];
    uint32_t dma_reset_nonidle_mask;
    uint32_t datapath_reset_delay;
    uint32_t transfer_ticks;
    uint32_t expected_contexts;
    uint32_t inject_dma_error;
    uint32_t complete_halted_mask;
    uint32_t inject_datapath_error;
    uint32_t inject_config_error;
    uint32_t never_complete;
    uint32_t lifecycle_skew;
    uint32_t telemetry_error;
    uint32_t program_failure;
    uint32_t stagger_ioc;
    mock_event_t events[MOCK_EVENT_CAPACITY];
    uint32_t event_count;
} mock_t;

static int failures;

static void check(int condition, const char *message)
{
    if (!condition) {
        ++failures;
        printf("FAIL: %s\n", message);
    }
}

static int mock_dma_index(uint32_t base)
{
    switch (base) {
    case DMA_BIAS_BASE_ADDR:
        return ACCEL_V2_DMA_BIAS;
    case DMA_WEIGHT_BASE_ADDR:
        return ACCEL_V2_DMA_WEIGHT;
    case DMA_IFM_BASE_ADDR:
        return ACCEL_V2_DMA_IFM;
    case DMA_OFM_BASE_ADDR:
        return ACCEL_V2_DMA_OFM;
    default:
        return -1;
    }
}

static void mock_log(
    mock_t *mock, uint32_t kind, uint32_t base,
    uint32_t offset, uint32_t value)
{
    if (mock->event_count < MOCK_EVENT_CAPACITY) {
        mock_event_t *event = &mock->events[mock->event_count++];
        event->kind = kind;
        event->base = base;
        event->offset = offset;
        event->value = value;
    }
}

static uint32_t mock_read32(void *opaque, uint32_t base, uint32_t offset)
{
    mock_t *mock = (mock_t *)opaque;
    int dma = mock_dma_index(base);
    if (base == ACCEL_BASE_ADDR) {
        return mock->accel[offset / 4U];
    }
    if (dma >= 0) {
        return mock->dma[(uint32_t)dma][offset / 4U];
    }
    return 0U;
}

static void mock_write32(
    void *opaque, uint32_t base, uint32_t offset, uint32_t value)
{
    mock_t *mock = (mock_t *)opaque;
    int dma = mock_dma_index(base);
    mock_log(mock, MOCK_EVENT_MMIO_WRITE, base, offset, value);
    if (base == ACCEL_BASE_ADDR) {
        if (offset == ACCEL_CTRL) {
            if ((value & ACCEL_CTRL_DATAPATH_RESET_MASK) != 0U) {
                mock->datapath_reset_delay = 4U;
                mock->accel[ACCEL_CTRL / 4U] =
                    ACCEL_CTRL_RESET_ACTIVE_MASK;
            } else if ((value & ACCEL_CTRL_CLEAR_STATUS_MASK) != 0U) {
                mock->accel[ACCEL_CTRL / 4U] &=
                    ~(ACCEL_CTRL_DONE_MASK | ACCEL_CTRL_CONFIG_ERROR_MASK);
            } else if ((value & ACCEL_CTRL_START_MASK) != 0U) {
                mock->transfer_ticks = 0U;
                mock->accel[ACCEL_CTRL / 4U] = ACCEL_CTRL_BUSY_MASK;
            }
        } else {
            mock->accel[offset / 4U] = value;
        }
        return;
    }
    if (dma >= 0) {
        uint32_t index = (uint32_t)dma;
        uint32_t control_offset = accel_v2_dma_control_offset(index);
        uint32_t status_offset = accel_v2_dma_status_offset(index);
        if (offset == control_offset && (value & DMA_DMACR_RESET) != 0U) {
            mock->dma[index][control_offset / 4U] = DMA_DMACR_RESET;
            mock->dma_reset_delay[index] = 1U;
        } else if (offset == status_offset) {
            mock->dma[index][status_offset / 4U] &= ~value;
        } else {
            mock->dma[index][offset / 4U] = value;
            if (offset == control_offset &&
                (value & DMA_DMACR_RUNSTOP) != 0U) {
                mock->dma[index][status_offset / 4U] &= ~DMA_DMASR_HALTED;
            }
            if (offset == DMA_MM2S_LENGTH || offset == DMA_S2MM_LENGTH) {
                mock->dma[index][status_offset / 4U] &= ~DMA_DMASR_IDLE;
            }
        }
    }
}

static void mock_cache_flush(void *opaque, uintptr_t address, uint32_t bytes)
{
    mock_log((mock_t *)opaque, MOCK_EVENT_CACHE_FLUSH,
             (uint32_t)address, (uint32_t)(address >> 32), bytes);
}

static void mock_cache_invalidate(
    void *opaque, uintptr_t address, uint32_t bytes)
{
    mock_log((mock_t *)opaque, MOCK_EVENT_CACHE_INVALIDATE,
             (uint32_t)address, (uint32_t)(address >> 32), bytes);
}

static void mock_complete_accel(mock_t *mock)
{
    uint32_t regs[] = {
        ACCEL_CONTEXT_ALLOC_COUNT_REG,
        ACCEL_CONTEXT_INPUT_ISSUED_COUNT_REG,
        ACCEL_CONTEXT_ARRAY_RETIRED_COUNT_REG,
        ACCEL_CONTEXT_COLLECTOR_DONE_COUNT_REG
    };
    for (uint32_t i = 0U; i < 4U; ++i) {
        uint32_t increment = mock->expected_contexts;
        if (i == 2U) {
            increment += mock->lifecycle_skew;
        }
        mock->accel[regs[i] / 4U] += increment;
    }
    mock->accel[ACCEL_CONTEXT_EPOCH_MISMATCH_COUNT_REG / 4U] +=
        mock->telemetry_error;
    mock->accel[ACCEL_CTRL / 4U] = ACCEL_CTRL_DONE_MASK;
}

static void mock_complete_transfer(mock_t *mock)
{
    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        uint32_t status_offset = accel_v2_dma_status_offset(dma);
        mock->dma[dma][status_offset / 4U] = DMA_DMASR_IOC_IRQ |
            (((mock->complete_halted_mask & (1U << dma)) != 0U) ?
                 DMA_DMASR_HALTED : DMA_DMASR_IDLE);
    }
    mock_complete_accel(mock);
}

static void mock_poll_hook(void *opaque)
{
    mock_t *mock = (mock_t *)opaque;
    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        if (mock->dma_reset_delay[dma] != 0U) {
            --mock->dma_reset_delay[dma];
            if (mock->dma_reset_delay[dma] == 0U) {
                uint32_t control_offset = accel_v2_dma_control_offset(dma);
                uint32_t status_offset = accel_v2_dma_status_offset(dma);
                mock->dma[dma][control_offset / 4U] = 0U;
                mock->dma[dma][status_offset / 4U] =
                    (mock->dma_reset_nonidle_mask & (1U << dma)) != 0U ?
                        0U : DMA_DMASR_HALTED;
            }
        }
    }
    if (mock->datapath_reset_delay != 0U) {
        --mock->datapath_reset_delay;
        if (mock->datapath_reset_delay == 0U) {
            uint32_t reset_count =
                mock->accel[ACCEL_DATAPATH_RESET_COUNT_REG / 4U] + 1U;
            memset(mock->accel, 0, sizeof(mock->accel));
            mock->accel[ACCEL_CONTEXT_TELEMETRY_VERSION_REG / 4U] =
                ACCEL_CONTEXT_TELEMETRY_VERSION;
            mock->accel[ACCEL_DATAPATH_RESET_COUNT_REG / 4U] = reset_count;
        }
    } else if ((mock->accel[ACCEL_CTRL / 4U] & ACCEL_CTRL_BUSY_MASK) != 0U) {
        ++mock->transfer_ticks;
        if (mock->inject_dma_error != 0U && mock->transfer_ticks == 1U) {
            mock->dma[ACCEL_V2_DMA_WEIGHT][DMA_MM2S_DMASR / 4U] =
                DMA_DMASR_IDLE | DMA_DMASR_IOC_IRQ | DMA_DMASR_ERR_MASK;
        } else if (mock->inject_datapath_error != 0U &&
                   mock->transfer_ticks == 1U) {
            mock->accel[ACCEL_DATAPATH_ERRORS_REG / 4U] =
                ACCEL_ERROR_CONTEXT_MISMATCH;
        } else if (mock->inject_config_error != 0U &&
                   mock->transfer_ticks == 1U) {
            mock->accel[ACCEL_CTRL / 4U] |= ACCEL_CTRL_CONFIG_ERROR_MASK;
        } else if (mock->never_complete == 0U && mock->stagger_ioc != 0U) {
            uint32_t completed_dma = ACCEL_V2_DMA_COUNT;
            switch (mock->transfer_ticks) {
            case 2U:
                completed_dma = ACCEL_V2_DMA_WEIGHT;
                break;
            case 3U:
                completed_dma = ACCEL_V2_DMA_OFM;
                break;
            case 4U:
                completed_dma = ACCEL_V2_DMA_BIAS;
                break;
            case 5U:
                completed_dma = ACCEL_V2_DMA_IFM;
                break;
            default:
                break;
            }
            if (completed_dma < ACCEL_V2_DMA_COUNT) {
                uint32_t status_offset =
                    accel_v2_dma_status_offset(completed_dma);
                mock->dma[completed_dma][status_offset / 4U] |=
                    DMA_DMASR_IDLE | DMA_DMASR_IOC_IRQ;
            }
            if (mock->transfer_ticks == 5U) {
                mock_complete_accel(mock);
            }
        } else if (mock->never_complete == 0U && mock->transfer_ticks == 2U) {
            mock_complete_transfer(mock);
        }
    }
}

static int mock_program_layer(void *opaque)
{
    mock_t *mock = (mock_t *)opaque;
    mock_log(mock, MOCK_EVENT_PROGRAM, ACCEL_BASE_ADDR,
             ACCEL_LAYER_DESC_REG, 0x8000000dU);
    if (mock->program_failure != 0U) {
        return -1;
    }
    mock_write32(mock, ACCEL_BASE_ADDR, ACCEL_LAYER_DESC_REG, 0x8000000dU);
    mock_write32(mock, ACCEL_BASE_ADDR, ACCEL_IFM_TOTAL_BYTES_REG, 128U);
    mock_write32(mock, ACCEL_BASE_ADDR, ACCEL_OFM_TOTAL_BYTES_REG, 64U);
    return 0;
}

static void mock_init(mock_t *mock)
{
    memset(mock, 0, sizeof(*mock));
    mock->accel[ACCEL_CONTEXT_TELEMETRY_VERSION_REG / 4U] =
        ACCEL_CONTEXT_TELEMETRY_VERSION;
    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        mock->dma[dma][accel_v2_dma_status_offset(dma) / 4U] =
            DMA_DMASR_HALTED;
    }
}

static accel_v2_runtime_t make_runtime(mock_t *mock, uint32_t poll_limit)
{
    accel_v2_runtime_t runtime;
    memset(&runtime, 0, sizeof(runtime));
    runtime.opaque = mock;
    runtime.read32 = mock_read32;
    runtime.write32 = mock_write32;
    runtime.cache_flush = mock_cache_flush;
    runtime.cache_invalidate = mock_cache_invalidate;
    runtime.poll_hook = mock_poll_hook;
    runtime.accel_base = ACCEL_BASE_ADDR;
    runtime.dma_base[ACCEL_V2_DMA_BIAS] = DMA_BIAS_BASE_ADDR;
    runtime.dma_base[ACCEL_V2_DMA_WEIGHT] = DMA_WEIGHT_BASE_ADDR;
    runtime.dma_base[ACCEL_V2_DMA_IFM] = DMA_IFM_BASE_ADDR;
    runtime.dma_base[ACCEL_V2_DMA_OFM] = DMA_OFM_BASE_ADDR;
    runtime.poll_limit = poll_limit;
    return runtime;
}

static accel_v2_layer_transfer_t make_transfer(mock_t *mock)
{
    static uint64_t bias[128U / 8U];
    static uint64_t weight[576U / 8U];
    static uint64_t ifm[128U / 8U];
    static uint64_t ofm[64U / 8U];
    accel_v2_layer_transfer_t transfer;
    memset(&transfer, 0, sizeof(transfer));
    transfer.bias_data = bias;
    transfer.bias_bytes = sizeof(bias);
    transfer.weight_data = weight;
    transfer.weight_bytes = sizeof(weight);
    transfer.ifm_data = ifm;
    transfer.ifm_bytes = sizeof(ifm);
    transfer.ofm_data = ofm;
    transfer.ofm_bytes = sizeof(ofm);
    transfer.expected_contexts = 32U;
    transfer.program_layer = mock_program_layer;
    transfer.program_opaque = mock;
    mock->expected_contexts = transfer.expected_contexts;
    return transfer;
}

static void set_transfer_bytes(
    accel_v2_layer_transfer_t *transfer, uint32_t dma, uint32_t bytes)
{
    switch (dma) {
    case ACCEL_V2_DMA_BIAS:
        transfer->bias_bytes = bytes;
        break;
    case ACCEL_V2_DMA_WEIGHT:
        transfer->weight_bytes = bytes;
        break;
    case ACCEL_V2_DMA_IFM:
        transfer->ifm_bytes = bytes;
        break;
    case ACCEL_V2_DMA_OFM:
        transfer->ofm_bytes = bytes;
        break;
    default:
        break;
    }
}

static uint32_t transfer_length_offset(uint32_t dma)
{
    return dma == ACCEL_V2_DMA_OFM ? DMA_S2MM_LENGTH : DMA_MM2S_LENGTH;
}

static int find_write(
    const mock_t *mock, uint32_t start, uint32_t base,
    uint32_t offset, uint32_t value)
{
    for (uint32_t i = start; i < mock->event_count; ++i) {
        const mock_event_t *event = &mock->events[i];
        if (event->kind == MOCK_EVENT_MMIO_WRITE && event->base == base &&
            event->offset == offset && event->value == value) {
            return (int)i;
        }
    }
    return -1;
}

static int recovery_reset_order_is_valid(
    const mock_t *mock, uint32_t start)
{
    int reset_bias = find_write(
        mock, start, DMA_BIAS_BASE_ADDR,
        DMA_MM2S_DMACR, DMA_DMACR_RESET);
    int reset_weight;
    int reset_ifm;
    int reset_ofm;
    int reset_accel;

    if (reset_bias < 0) {
        return 0;
    }
    reset_weight = find_write(
        mock, (uint32_t)(reset_bias + 1), DMA_WEIGHT_BASE_ADDR,
        DMA_MM2S_DMACR, DMA_DMACR_RESET);
    if (reset_weight < 0) {
        return 0;
    }
    reset_ifm = find_write(
        mock, (uint32_t)(reset_weight + 1), DMA_IFM_BASE_ADDR,
        DMA_MM2S_DMACR, DMA_DMACR_RESET);
    if (reset_ifm < 0) {
        return 0;
    }
    reset_ofm = find_write(
        mock, (uint32_t)(reset_ifm + 1), DMA_OFM_BASE_ADDR,
        DMA_S2MM_DMACR, DMA_DMACR_RESET);
    if (reset_ofm < 0) {
        return 0;
    }
    reset_accel = find_write(
        mock, (uint32_t)(reset_ofm + 1), ACCEL_BASE_ADDR,
        ACCEL_CTRL, ACCEL_CTRL_DATAPATH_RESET_MASK);
    return reset_accel > reset_ofm;
}

static int recovery_state_is_valid(
    const mock_t *mock, uint32_t expected_reset_count)
{
    uint32_t invalid_control = ACCEL_CTRL_BUSY_MASK |
        ACCEL_CTRL_RESET_ACTIVE_MASK | ACCEL_CTRL_CONFIG_ERROR_MASK;

    if (mock->accel[ACCEL_DATAPATH_RESET_COUNT_REG / 4U] !=
            expected_reset_count ||
        (mock->accel[ACCEL_CTRL / 4U] & invalid_control) != 0U ||
        mock->accel[ACCEL_DATAPATH_ERRORS_REG / 4U] != 0U) {
        return 0;
    }
    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        uint32_t status = mock->dma[dma]
            [accel_v2_dma_status_offset(dma) / 4U];
        if (!accel_v2_dma_status_quiescent(status) ||
            (status & DMA_DMASR_ERR_MASK) != 0U) {
            return 0;
        }
    }
    return 1;
}

static int recovered_runtime_dispatches_again(
    mock_t *mock, const accel_v2_runtime_t *runtime,
    const accel_v2_layer_transfer_t *transfer)
{
    accel_v2_layer_report_t report;
    uint32_t reset_count_before =
        mock->accel[ACCEL_DATAPATH_RESET_COUNT_REG / 4U];
    int rc = accel_v2_dispatch_layer(runtime, transfer, &report);

    return rc == ACCEL_V2_RUN_OK &&
        report.recovery_result == ACCEL_V2_RUN_OK &&
        report.dma_complete_mask == ACCEL_V2_DMA_COMPLETE_ALL &&
        report.delta.alloc == transfer->expected_contexts &&
        report.delta.input_issued == transfer->expected_contexts &&
        report.delta.array_retired == transfer->expected_contexts &&
        report.delta.collector_done == transfer->expected_contexts &&
        mock->accel[ACCEL_DATAPATH_RESET_COUNT_REG / 4U] ==
            reset_count_before &&
        recovery_state_is_valid(mock, reset_count_before);
}

static void test_success_and_wrap(void)
{
    mock_t mock;
    accel_v2_runtime_t runtime;
    accel_v2_layer_transfer_t transfer;
    accel_v2_layer_report_t report;
    int ofm_arm;
    int bias_start;
    int weight_start;
    int ifm_start;
    int accel_start;
    int rc;

    mock_init(&mock);
    mock.accel[ACCEL_CONTEXT_ALLOC_COUNT_REG / 4U] = 0xfffffff0U;
    mock.accel[ACCEL_CONTEXT_INPUT_ISSUED_COUNT_REG / 4U] = 0xfffffff0U;
    mock.accel[ACCEL_CONTEXT_ARRAY_RETIRED_COUNT_REG / 4U] = 0xfffffff0U;
    mock.accel[ACCEL_CONTEXT_COLLECTOR_DONE_COUNT_REG / 4U] = 0xfffffff0U;
    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        mock.dma[dma][accel_v2_dma_status_offset(dma) / 4U] |=
            DMA_DMASR_IOC_IRQ;
    }
    runtime = make_runtime(&mock, 16U);
    transfer = make_transfer(&mock);
    rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);

    check(rc == ACCEL_V2_RUN_OK, "successful four-DMA dispatch");
    check(report.delta.alloc == 32U &&
          report.delta.input_issued == 32U &&
          report.delta.array_retired == 32U &&
          report.delta.collector_done == 32U,
          "uint32 lifecycle delta validates across wrap");
    check(report.dma_complete_mask == ACCEL_V2_DMA_COMPLETE_ALL,
          "all four DMA completions observed");
    check(report.poll_count >= 3U,
          "stale DMA IOC status is cleared before transfers are armed");
    ofm_arm = find_write(&mock, 0U, DMA_OFM_BASE_ADDR,
                         DMA_S2MM_LENGTH, transfer.ofm_bytes);
    bias_start = find_write(&mock, 0U, DMA_BIAS_BASE_ADDR,
                            DMA_MM2S_LENGTH, transfer.bias_bytes);
    weight_start = find_write(&mock, 0U, DMA_WEIGHT_BASE_ADDR,
                              DMA_MM2S_LENGTH, transfer.weight_bytes);
    ifm_start = find_write(&mock, 0U, DMA_IFM_BASE_ADDR,
                           DMA_MM2S_LENGTH, transfer.ifm_bytes);
    accel_start = find_write(&mock, 0U, ACCEL_BASE_ADDR, ACCEL_CTRL,
                             ACCEL_CTRL_START_MASK);
    check(ofm_arm >= 0 && ofm_arm < bias_start && bias_start < weight_start &&
          weight_start < ifm_start && ifm_start < accel_start,
          "S2MM is armed before bias/weight/IFM and accelerator start");
    check(find_write(&mock, 0U, DMA_BIAS_BASE_ADDR, DMA_MM2S_SA,
                     (uint32_t)(uintptr_t)transfer.bias_data) >= 0 &&
          find_write(&mock, 0U, DMA_WEIGHT_BASE_ADDR, DMA_MM2S_SA,
                     (uint32_t)(uintptr_t)transfer.weight_data) >= 0 &&
          find_write(&mock, 0U, DMA_IFM_BASE_ADDR, DMA_MM2S_SA,
                     (uint32_t)(uintptr_t)transfer.ifm_data) >= 0 &&
          find_write(&mock, 0U, DMA_OFM_BASE_ADDR, DMA_S2MM_DA,
                     (uint32_t)(uintptr_t)transfer.ofm_data) >= 0,
          "all four DMA source/destination addresses are programmed");
    check(mock.events[mock.event_count - 1U].kind ==
              MOCK_EVENT_CACHE_INVALIDATE,
          "packed OFM cache invalidated only after completion");
}

static void test_dma_error_priority_and_recovery(void)
{
    mock_t mock;
    accel_v2_runtime_t runtime;
    accel_v2_layer_transfer_t transfer;
    accel_v2_layer_report_t report;
    int reset_bias;
    int reset_weight;
    int reset_ifm;
    int reset_ofm;
    int reset_accel;
    int rc;

    mock_init(&mock);
    mock.inject_dma_error = 1U;
    runtime = make_runtime(&mock, 16U);
    transfer = make_transfer(&mock);
    rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);

    check(rc == ACCEL_V2_RUN_ERR_DMA_STATUS,
          "DMA ERR wins over simultaneous IOC");
    check(report.failed_dma == ACCEL_V2_DMA_WEIGHT,
          "failing DMA channel is reported");
    check(report.recovery_result == ACCEL_V2_RUN_OK,
          "DMA failure performs recoverable datapath reset");
    check(mock.accel[ACCEL_DATAPATH_RESET_COUNT_REG / 4U] == 1U &&
          mock.accel[ACCEL_CTRL / 4U] == 0U &&
          mock.accel[ACCEL_DATAPATH_ERRORS_REG / 4U] == 0U,
          "recovery verifies count, busy, and datapath errors");

    reset_bias = find_write(&mock, 0U, DMA_BIAS_BASE_ADDR,
                            DMA_MM2S_DMACR, DMA_DMACR_RESET);
    reset_weight = find_write(&mock, (uint32_t)(reset_bias + 1),
                              DMA_WEIGHT_BASE_ADDR,
                              DMA_MM2S_DMACR, DMA_DMACR_RESET);
    reset_ifm = find_write(&mock, (uint32_t)(reset_weight + 1),
                           DMA_IFM_BASE_ADDR,
                           DMA_MM2S_DMACR, DMA_DMACR_RESET);
    reset_ofm = find_write(&mock, (uint32_t)(reset_ifm + 1),
                           DMA_OFM_BASE_ADDR,
                           DMA_S2MM_DMACR, DMA_DMACR_RESET);
    reset_accel = find_write(&mock, (uint32_t)(reset_ofm + 1),
                             ACCEL_BASE_ADDR, ACCEL_CTRL,
                             ACCEL_CTRL_DATAPATH_RESET_MASK);
    check(reset_bias >= 0 && reset_bias < reset_weight &&
          reset_weight < reset_ifm && reset_ifm < reset_ofm &&
          reset_ofm < reset_accel,
          "recovery resets four DMAs before datapath reset");
    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        check(accel_v2_dma_status_quiescent(
                  mock.dma[dma]
                      [accel_v2_dma_status_offset(dma) / 4U]),
              "recovery leaves every DMA channel quiescent");
    }

    mock.inject_dma_error = 0U;
    transfer = make_transfer(&mock);
    rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);
    check(rc == ACCEL_V2_RUN_OK &&
          report.dma_complete_mask == ACCEL_V2_DMA_COMPLETE_ALL &&
          report.delta.collector_done == transfer.expected_contexts,
          "next dispatch succeeds after DMA/datapath recovery");
    check(mock.accel[ACCEL_DATAPATH_RESET_COUNT_REG / 4U] == 1U,
          "successful retry does not request another datapath reset");
}

static void test_staggered_out_of_order_ioc(void)
{
    mock_t mock;
    accel_v2_runtime_t runtime;
    accel_v2_layer_transfer_t transfer;
    accel_v2_layer_report_t report;
    int accel_start;
    int weight_ioc;
    int ofm_ioc;
    int bias_ioc;
    int ifm_ioc;
    int rc;

    mock_init(&mock);
    mock.stagger_ioc = 1U;
    runtime = make_runtime(&mock, 32U);
    transfer = make_transfer(&mock);
    rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);

    check(rc == ACCEL_V2_RUN_OK && report.poll_count >= 6U,
          "batched polling accepts staggered out-of-order DMA IOC");
    check(report.dma_complete_mask == ACCEL_V2_DMA_COMPLETE_ALL,
          "staggered IOC records all four completions");
    accel_start = find_write(&mock, 0U, ACCEL_BASE_ADDR, ACCEL_CTRL,
                             ACCEL_CTRL_START_MASK);
    weight_ioc = find_write(&mock, (uint32_t)(accel_start + 1),
                            DMA_WEIGHT_BASE_ADDR, DMA_MM2S_DMASR,
                            DMA_DMASR_IOC_IRQ);
    ofm_ioc = find_write(&mock, (uint32_t)(weight_ioc + 1),
                         DMA_OFM_BASE_ADDR, DMA_S2MM_DMASR,
                         DMA_DMASR_IOC_IRQ);
    bias_ioc = find_write(&mock, (uint32_t)(ofm_ioc + 1),
                          DMA_BIAS_BASE_ADDR, DMA_MM2S_DMASR,
                          DMA_DMASR_IOC_IRQ);
    ifm_ioc = find_write(&mock, (uint32_t)(bias_ioc + 1),
                         DMA_IFM_BASE_ADDR, DMA_MM2S_DMASR,
                         DMA_DMASR_IOC_IRQ);
    check(accel_start >= 0 && accel_start < weight_ioc &&
          weight_ioc < ofm_ioc && ofm_ioc < bias_ioc &&
          bias_ioc < ifm_ioc,
          "IOC acknowledgements preserve observed out-of-order completion");
}

static void test_program_failure_and_dma_reset_idle(void)
{
    mock_t mock;
    accel_v2_runtime_t runtime;
    accel_v2_layer_transfer_t transfer;
    accel_v2_layer_report_t report;
    int rc;

    mock_init(&mock);
    mock.program_failure = 1U;
    runtime = make_runtime(&mock, 16U);
    transfer = make_transfer(&mock);
    rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);
    check(rc == ACCEL_V2_RUN_ERR_PROGRAM &&
          report.recovery_result == ACCEL_V2_RUN_OK,
          "descriptor/program readback failure is reported and recovered");
    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        check(find_write(&mock, 0U, runtime.dma_base[dma],
                         transfer_length_offset(dma),
                         dma == ACCEL_V2_DMA_BIAS ? transfer.bias_bytes :
                         dma == ACCEL_V2_DMA_WEIGHT ? transfer.weight_bytes :
                         dma == ACCEL_V2_DMA_IFM ? transfer.ifm_bytes :
                         transfer.ofm_bytes) < 0,
              "program failure does not arm any DMA transfer");
    }

    mock_init(&mock);
    mock.dma_reset_nonidle_mask = 1U << ACCEL_V2_DMA_IFM;
    runtime = make_runtime(&mock, 4U);
    rc = accel_v2_runtime_recover(&runtime);
    check(rc == ACCEL_V2_RUN_ERR_DMA_NOT_IDLE,
          "DMA reset must observe HALTED or IDLE before recovery can succeed");
    check(mock.accel[ACCEL_DATAPATH_RESET_COUNT_REG / 4U] == 0U,
          "failed DMA reset does not proceed to datapath reset");
    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        check(find_write(&mock, 0U, runtime.dma_base[dma],
                         accel_v2_dma_control_offset(dma),
                         DMA_DMACR_RESET) >= 0,
              "recovery attempts every DMA reset after one channel fails");
    }
}

static void test_halted_completion_is_not_success(void)
{
    mock_t mock;
    accel_v2_runtime_t runtime;
    accel_v2_layer_transfer_t transfer;
    accel_v2_layer_report_t report;
    int rc;

    mock_init(&mock);
    mock.complete_halted_mask = 1U << ACCEL_V2_DMA_IFM;
    runtime = make_runtime(&mock, 16U);
    transfer = make_transfer(&mock);
    rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);
    check(rc == ACCEL_V2_RUN_ERR_DMA_NOT_IDLE &&
          report.failed_dma == ACCEL_V2_DMA_IFM,
          "IOC plus HALTED is rejected as an incomplete DMA transfer");
    check(report.recovery_result == ACCEL_V2_RUN_OK &&
          recovery_state_is_valid(&mock, 1U),
          "abnormal halted completion performs a successful recovery");
}

static void test_timeout_and_lifecycle_failure(void)
{
    mock_t mock;
    accel_v2_runtime_t runtime;
    accel_v2_layer_transfer_t transfer;
    accel_v2_layer_report_t report;
    int rc;

    mock_init(&mock);
    mock.never_complete = 1U;
    runtime = make_runtime(&mock, 8U);
    transfer = make_transfer(&mock);
    rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);
    check(rc == ACCEL_V2_RUN_ERR_TIMEOUT &&
          report.recovery_result == ACCEL_V2_RUN_OK,
          "timeout is reported and recovered");
    check(recovery_reset_order_is_valid(&mock, 0U),
          "timeout recovery resets four DMAs before datapath reset");
    check(recovery_state_is_valid(&mock, 1U),
          "timeout recovery verifies reset count, idle, busy, and errors");
    mock.never_complete = 0U;
    check(recovered_runtime_dispatches_again(&mock, &runtime, &transfer),
          "next dispatch succeeds after timeout recovery");

    mock_init(&mock);
    mock.lifecycle_skew = 1U;
    runtime = make_runtime(&mock, 16U);
    transfer = make_transfer(&mock);
    rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);
    check(rc == ACCEL_V2_RUN_ERR_LIFECYCLE &&
          report.recovery_result == ACCEL_V2_RUN_OK,
          "lifecycle mismatch is fail-stop and recovered");

    mock_init(&mock);
    mock.telemetry_error = 1U;
    runtime = make_runtime(&mock, 16U);
    transfer = make_transfer(&mock);
    rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);
    check(rc == ACCEL_V2_RUN_ERR_CONTEXT_COUNTER &&
          report.recovery_result == ACCEL_V2_RUN_OK,
          "context error counter delta is fail-stop and recovered");
}

static void test_datapath_and_config_fail_stop(void)
{
    mock_t mock;
    accel_v2_runtime_t runtime;
    accel_v2_layer_transfer_t transfer;
    accel_v2_layer_report_t report;
    int rc;

    mock_init(&mock);
    mock.inject_datapath_error = 1U;
    runtime = make_runtime(&mock, 16U);
    transfer = make_transfer(&mock);
    rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);
    check(rc == ACCEL_V2_RUN_ERR_DATAPATH &&
          report.recovery_result == ACCEL_V2_RUN_OK,
          "datapath sticky error triggers recovery");
    check(recovery_reset_order_is_valid(&mock, 0U),
          "datapath recovery resets four DMAs before datapath reset");
    check(recovery_state_is_valid(&mock, 1U),
          "datapath recovery verifies reset count, idle, busy, and errors");
    mock.inject_datapath_error = 0U;
    check(recovered_runtime_dispatches_again(&mock, &runtime, &transfer),
          "next dispatch succeeds after datapath recovery");

    mock_init(&mock);
    mock.inject_config_error = 1U;
    runtime = make_runtime(&mock, 16U);
    transfer = make_transfer(&mock);
    rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);
    check(rc == ACCEL_V2_RUN_ERR_CONFIG &&
          report.recovery_result == ACCEL_V2_RUN_OK,
          "accelerator config error triggers recovery");
}

static void test_recovery_count_wrap_and_length_boundaries(void)
{
    mock_t mock;
    accel_v2_runtime_t runtime;
    accel_v2_layer_transfer_t transfer;
    accel_v2_layer_report_t report;
    int rc;

    mock_init(&mock);
    mock.accel[ACCEL_DATAPATH_RESET_COUNT_REG / 4U] = 0xffffffffU;
    runtime = make_runtime(&mock, 16U);
    rc = accel_v2_runtime_recover(&runtime);
    check(rc == ACCEL_V2_RUN_OK &&
          mock.accel[ACCEL_DATAPATH_RESET_COUNT_REG / 4U] == 0U,
          "datapath reset count wrap is accepted");

    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        const uint32_t invalid_lengths[] = {0U, DMA_SIMPLE_MAX_LENGTH};
        for (uint32_t i = 0U;
             i < sizeof(invalid_lengths) / sizeof(invalid_lengths[0]); ++i) {
            uint32_t events_before;
            mock_init(&mock);
            runtime = make_runtime(&mock, 16U);
            transfer = make_transfer(&mock);
            set_transfer_bytes(&transfer, dma, invalid_lengths[i]);
            events_before = mock.event_count;
            rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);
            check(rc == ACCEL_V2_RUN_ERR_LENGTH &&
                  mock.event_count == events_before,
                  "0 and 2^26 lengths fail before MMIO on every DMA");
        }

        mock_init(&mock);
        runtime = make_runtime(&mock, 16U);
        transfer = make_transfer(&mock);
        set_transfer_bytes(&transfer, dma, DMA_SIMPLE_MAX_LENGTH - 1U);
        rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);
        check(rc == ACCEL_V2_RUN_OK,
              "2^26-1 length is accepted on every DMA");
        check(find_write(&mock, 0U, runtime.dma_base[dma],
                         transfer_length_offset(dma),
                         DMA_SIMPLE_MAX_LENGTH - 1U) >= 0,
              "accepted boundary length is programmed exactly");
    }
}

static void test_unaligned_dma_addresses_fail_before_mmio(void)
{
    mock_t mock;
    accel_v2_runtime_t runtime;
    accel_v2_layer_transfer_t transfer;
    accel_v2_layer_report_t report;
    const void *aligned[ACCEL_V2_DMA_COUNT];
    int rc;

    mock_init(&mock);
    runtime = make_runtime(&mock, 16U);
    transfer = make_transfer(&mock);
    aligned[ACCEL_V2_DMA_BIAS] = transfer.bias_data;
    aligned[ACCEL_V2_DMA_WEIGHT] = transfer.weight_data;
    aligned[ACCEL_V2_DMA_IFM] = transfer.ifm_data;
    aligned[ACCEL_V2_DMA_OFM] = transfer.ofm_data;
    for (uint32_t dma = 0U; dma < ACCEL_V2_DMA_COUNT; ++dma) {
        uint32_t events_before = mock.event_count;
        transfer = make_transfer(&mock);
        switch (dma) {
        case ACCEL_V2_DMA_BIAS:
            transfer.bias_data = (const uint8_t *)aligned[dma] + 1U;
            break;
        case ACCEL_V2_DMA_WEIGHT:
            transfer.weight_data = (const uint8_t *)aligned[dma] + 1U;
            break;
        case ACCEL_V2_DMA_IFM:
            transfer.ifm_data = (const uint8_t *)aligned[dma] + 1U;
            break;
        case ACCEL_V2_DMA_OFM:
            transfer.ofm_data = (uint8_t *)aligned[dma] + 1U;
            break;
        default:
            break;
        }
        rc = accel_v2_dispatch_layer(&runtime, &transfer, &report);
        check(rc == ACCEL_V2_RUN_ERR_ALIGNMENT &&
              report.failure == ACCEL_V2_RUN_ERR_ALIGNMENT &&
              mock.event_count == events_before,
              "unaligned address fails before MMIO on every DMA");
    }
}

int main(void)
{
    test_success_and_wrap();
    test_dma_error_priority_and_recovery();
    test_staggered_out_of_order_ioc();
    test_program_failure_and_dma_reset_idle();
    test_halted_completion_is_not_success();
    test_timeout_and_lifecycle_failure();
    test_datapath_and_config_fail_stop();
    test_recovery_count_wrap_and_length_boundaries();
    test_unaligned_dma_addresses_fail_before_mmio();
    if (failures != 0) {
        printf("FAIL: %d ABI v2 runtime mock checks failed\n", failures);
        return 1;
    }
    printf("PASS: ABI v2 four-DMA dispatch, telemetry, timeout, and recovery\n");
    return 0;
}

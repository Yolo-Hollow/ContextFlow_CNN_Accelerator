#ifndef ACCEL_ABI_V2_H
#define ACCEL_ABI_V2_H

#include <stdint.h>

/*
 * Software-visible accelerator ABI.  ABI v2 deliberately uses registers that
 * were not decoded by the v1 core so a v2 runtime can fail closed instead of
 * silently driving the byte-addressed v1 datapath.
 */
#define ACCEL_ABI_VERSION_V1              1U
#define ACCEL_ABI_VERSION_V2              2U
#define ACCEL_RELEASE_ABI_VERSION         ACCEL_ABI_VERSION_V2

#define ACCEL_ABI_VERSION_REG             0x1dcU
#define ACCEL_CAPABILITY_REG              0x1e0U
#define ACCEL_LAYER_DESC_REG              0x1e8U
#define ACCEL_IFM_TOTAL_BYTES_REG          0x1ecU
#define ACCEL_OFM_TOTAL_BYTES_REG          0x1f0U

/*
 * Packed-HWC OFM telemetry.  The existing sink-write counter is the AXIS beat
 * count in packed mode.  A valid cycle is exactly either a transferred beat
 * or a stalled TVALID cycle, so it is derived without narrowing either
 * software-visible 32-bit counter.
 */
#define ACCEL_OFM_AXIS_BEATS_REG           0x030U
#define ACCEL_PACKED_OFM_BYTES_REG         0x1f4U
#define ACCEL_PACKED_OFM_STALL_CYCLES_REG  0x1f8U
#define ACCEL_DATAPATH_ERRORS_REG          0x1fcU

/* CTRL write/read semantics added by the recoverable ABI-v2 datapath. */
#define ACCEL_CTRL_START_MASK              (1U << 0)
#define ACCEL_CTRL_CLEAR_STATUS_MASK       (1U << 1)
#define ACCEL_CTRL_DATAPATH_RESET_MASK     (1U << 2)
#define ACCEL_CTRL_BUSY_MASK               (1U << 0)
#define ACCEL_CTRL_DONE_MASK               (1U << 1)
#define ACCEL_CTRL_CONFIG_ERROR_MASK       (1U << 2)
#define ACCEL_CTRL_RESET_ACTIVE_MASK       (1U << 3)

/* Tagged-context telemetry occupies the first 64 bytes above the v2 map. */
#define ACCEL_CONTEXT_TELEMETRY_VERSION_REG       0x200U
#define ACCEL_CONTEXT_ALLOC_COUNT_REG             0x204U
#define ACCEL_CONTEXT_INPUT_ISSUED_COUNT_REG      0x208U
#define ACCEL_CONTEXT_ARRAY_RETIRED_COUNT_REG     0x20cU
#define ACCEL_CONTEXT_COLLECTOR_DONE_COUNT_REG    0x210U
#define ACCEL_CONTEXT_GAP_CYCLES_REG              0x214U
#define ACCEL_CONTEXT_IFM_OWNER_STALL_CYCLES_REG  0x218U
#define ACCEL_CONTEXT_WEIGHT_OWNER_STALL_CYCLES_REG 0x21cU
#define ACCEL_CONTEXT_PSUM_CREDIT_STALL_CYCLES_REG  0x220U
#define ACCEL_CONTEXT_EPOCH_MISMATCH_COUNT_REG    0x224U
#define ACCEL_CONTEXT_MISMATCH_COUNT_REG          0x228U
#define ACCEL_CONTEXT_IFM_UNDERFLOW_COUNT_REG     0x22cU
#define ACCEL_CONTEXT_PSUM_UNDERFLOW_COUNT_REG    0x230U
#define ACCEL_CONTEXT_FIFO_DROP_COUNT_REG         0x234U
#define ACCEL_CONTEXT_BANK_OVERWRITE_COUNT_REG    0x238U
#define ACCEL_CONTEXT_FULL_STALL_CYCLES_REG       0x23cU
#define ACCEL_DATAPATH_RESET_COUNT_REG             0x240U
#define ACCEL_CONTEXT_TELEMETRY_VERSION            2U

#define ACCEL_ERROR_IFM_MATERIALIZER_CFG   (1U << 3)
#define ACCEL_ERROR_IFM_TKEEP              (1U << 4)
#define ACCEL_ERROR_IFM_TLAST              (1U << 5)
#define ACCEL_ERROR_IFM_MATERIALIZER_OVF   (1U << 6)
#define ACCEL_ERROR_IFM_BANK_COLLISION     (1U << 7)
#define ACCEL_ERROR_IFM_ROW_OVERWRITE      (1U << 8)
#define ACCEL_ERROR_IFM_PROTOCOL           (1U << 9)
#define ACCEL_ERROR_IFM_CACHE_CFG          (1U << 10)
#define ACCEL_ERROR_IFM_CACHE_ORDER        (1U << 11)
#define ACCEL_ERROR_IFM_CACHE_EPOCH        (1U << 12)
#define ACCEL_ERROR_IFM_CACHE_OWNERSHIP    (1U << 13)
#define ACCEL_ERROR_IFM_CACHE_OVERFLOW     (1U << 14)
#define ACCEL_ERROR_IFM_RELEASE            (1U << 15)
#define ACCEL_ERROR_VECTOR_EPOCH           (1U << 19)
#define ACCEL_ERROR_VECTOR_OVERFLOW        (1U << 20)
#define ACCEL_ERROR_VECTOR_PROTOCOL        (1U << 21)
#define ACCEL_ERROR_WEIGHT_OWNERSHIP       (1U << 22)
#define ACCEL_ERROR_WEIGHT_EPOCH           (1U << 23)
#define ACCEL_ERROR_CONTEXT_MISMATCH       (1U << 24)
#define ACCEL_ERROR_CONTEXT_DROP           (1U << 25)
#define ACCEL_ERROR_OUTPUT_CREDIT          (1U << 26)
#define ACCEL_ERROR_ARRAY_RETIREMENT       (1U << 27)
#define ACCEL_ERROR_PSUM_TAG               (1U << 30)
#define ACCEL_ERROR_PACKED_OFM_PROTOCOL    (1U << 31)

#define ACCEL_PACKED_OFM_VALID_CYCLES(beats, stalls) \
    ((uint32_t)((uint32_t)(beats) + (uint32_t)(stalls)))

#define ACCEL_LAYER_DESC_TILE_H_MAX_MASK   0x1ffU
#define ACCEL_LAYER_DESC_LAST_MASK         (1U << 31)

#define ACCEL_CAP_ROWS_SHIFT              0U
#define ACCEL_CAP_COLS_SHIFT              8U
#define ACCEL_CAP_COUT_TILE_SHIFT         16U
#define ACCEL_CAP_FLAGS_SHIFT             24U
#define ACCEL_CAP_FIELD_MASK              0xffU

/* Required data-plane properties for the layer-long v2 runtime. */
#define ACCEL_CAP_FLAG_HWC_IFM            (1U << 0)
#define ACCEL_CAP_FLAG_PACKED_HWC_OFM     (1U << 1)
#define ACCEL_CAP_FLAG_LAYER_LONG_DMA     (1U << 2)
#define ACCEL_CAP_FLAG_EPOCH_CONTEXT      (1U << 3)
#define ACCEL_CAP_V2_REQUIRED_FLAGS       \
    (ACCEL_CAP_FLAG_HWC_IFM | ACCEL_CAP_FLAG_PACKED_HWC_OFM | \
     ACCEL_CAP_FLAG_LAYER_LONG_DMA | ACCEL_CAP_FLAG_EPOCH_CONTEXT)

#define ACCEL_RELEASE_ROWS                18U
#define ACCEL_RELEASE_COLS                16U
#define ACCEL_RELEASE_COUT_TILE           32U

#define ACCEL_CAPABILITY_PACK(rows, cols, cout_tile, flags) \
    ((((uint32_t)(rows) & ACCEL_CAP_FIELD_MASK) << ACCEL_CAP_ROWS_SHIFT) | \
     (((uint32_t)(cols) & ACCEL_CAP_FIELD_MASK) << ACCEL_CAP_COLS_SHIFT) | \
     (((uint32_t)(cout_tile) & ACCEL_CAP_FIELD_MASK) << ACCEL_CAP_COUT_TILE_SHIFT) | \
     (((uint32_t)(flags) & ACCEL_CAP_FIELD_MASK) << ACCEL_CAP_FLAGS_SHIFT))

#define ACCEL_RELEASE_CAPABILITY \
    ACCEL_CAPABILITY_PACK(ACCEL_RELEASE_ROWS, ACCEL_RELEASE_COLS, \
                          ACCEL_RELEASE_COUT_TILE, ACCEL_CAP_V2_REQUIRED_FLAGS)

typedef struct {
    uint8_t rows;
    uint8_t cols;
    uint8_t cout_tile;
    uint8_t flags;
} accel_capability_t;

enum {
    ACCEL_ABI_OK = 0,
    ACCEL_ABI_ERR_VERSION = -1,
    ACCEL_ABI_ERR_ROWS = -2,
    ACCEL_ABI_ERR_COLS = -3,
    ACCEL_ABI_ERR_COUT_TILE = -4,
    ACCEL_ABI_ERR_CAP_RELATION = -5,
    ACCEL_ABI_ERR_FLAGS = -6,
    ACCEL_ABI_ERR_RUNTIME_NOT_READY = -7
};

static inline accel_capability_t accel_capability_decode(uint32_t raw)
{
    accel_capability_t capability;

    capability.rows = (uint8_t)((raw >> ACCEL_CAP_ROWS_SHIFT) & ACCEL_CAP_FIELD_MASK);
    capability.cols = (uint8_t)((raw >> ACCEL_CAP_COLS_SHIFT) & ACCEL_CAP_FIELD_MASK);
    capability.cout_tile =
        (uint8_t)((raw >> ACCEL_CAP_COUT_TILE_SHIFT) & ACCEL_CAP_FIELD_MASK);
    capability.flags = (uint8_t)((raw >> ACCEL_CAP_FLAGS_SHIFT) & ACCEL_CAP_FIELD_MASK);
    return capability;
}

/* Strict v2 check.  In particular, an undecoded register value of zero fails. */
static inline int accel_abi_v2_validate(uint32_t abi_version,
                                        uint32_t capability_raw,
                                        uint32_t required_flags)
{
    accel_capability_t capability = accel_capability_decode(capability_raw);

    if (abi_version != ACCEL_ABI_VERSION_V2) {
        return ACCEL_ABI_ERR_VERSION;
    }
    if (capability.rows != ACCEL_RELEASE_ROWS) {
        return ACCEL_ABI_ERR_ROWS;
    }
    if (capability.cols != ACCEL_RELEASE_COLS) {
        return ACCEL_ABI_ERR_COLS;
    }
    if (capability.cout_tile != ACCEL_RELEASE_COUT_TILE) {
        return ACCEL_ABI_ERR_COUT_TILE;
    }
    if (capability.cout_tile != (uint8_t)(capability.cols * 2U)) {
        return ACCEL_ABI_ERR_CAP_RELATION;
    }
    if ((((uint32_t)capability.flags) & required_flags) != required_flags) {
        return ACCEL_ABI_ERR_FLAGS;
    }
    return ACCEL_ABI_OK;
}

#endif

#ifndef COCO80_MULTICORE_H
#define COCO80_MULTICORE_H

#include "coco80_tensor_ops.h"
#include "coco80_cpu_conv.h"

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define COCO80_MC_MAGIC 0x434D3843U /* C8MC */
#define COCO80_MC_VERSION 3U
#define COCO80_MC_WORKERS 3U
#define COCO80_MC_MAILBOX_ADDRESS ((uintptr_t)0x7D600000U)
#define COCO80_MC_TLB_BLOCK_BYTES 0x00200000U
#define COCO80_MC_INNER_WB_ATTRIBUTE 0x705U

enum coco80_mc_task_state {
    COCO80_MC_TASK_IDLE = 0,
    COCO80_MC_TASK_READY = 1,
    COCO80_MC_TASK_RUNNING = 2,
    COCO80_MC_TASK_DONE = 3,
    COCO80_MC_TASK_ERROR = 4
};

enum coco80_mc_operation {
    COCO80_MC_OP_POOL_S2 = 1,
    COCO80_MC_OP_POOL_S1_PAD = 2,
    COCO80_MC_OP_NEAREST_REQUANT_CONCAT = 3,
    COCO80_MC_OP_CPU_CONV_KCO = 4
};

typedef struct __attribute__((aligned(64))) {
    volatile uint32_t state;
    volatile uint32_t generation;
    volatile uint32_t operation;
    volatile int32_t status;
    uint64_t source0;
    uint64_t source1;
    uint64_t destination;
    uint64_t auxiliary0;
    uint64_t auxiliary1;
    uint32_t height;
    uint32_t width;
    uint32_t channels0;
    uint32_t channels1;
    uint32_t pad_value;
    int32_t input_zero_point;
    int32_t output_zero_point;
    uint32_t multiplier;
    uint32_t shift;
    uint32_t range_begin;
    uint32_t range_end;
    uint32_t reserved[7];
} coco80_mc_task_t;

typedef struct __attribute__((aligned(64))) {
    volatile uint32_t magic;
    volatile uint32_t version;
    volatile uint32_t controller_ready;
    volatile uint32_t generation;
    volatile uint32_t worker_ready[COCO80_MC_WORKERS];
    volatile int32_t last_error;
    uint64_t shared_region_base;
    uint32_t shared_region_bytes;
    uint32_t shared_region_attribute;
    uint32_t reserved[4];
    coco80_mc_task_t tasks[COCO80_MC_WORKERS];
} coco80_mc_mailbox_t;

typedef struct {
    coco80_mc_mailbox_t *mailbox;
    uint32_t generation;
    uint32_t initialized;
    uint64_t timeout_ticks;
} coco80_mc_controller_t;

int coco80_mc_controller_initialize(
    coco80_mc_controller_t *controller,
    uint64_t timeout_ticks,
    void *shared_region,
    uint32_t shared_region_bytes);

int coco80_mc_set_inner_shareable_region(
    void *region,
    uint32_t region_bytes);

int coco80_mc_pool_s2(
    coco80_mc_controller_t *controller,
    const coco80_hwc_u8_t *source,
    coco80_hwc_u8_t *destination);

int coco80_mc_pool_s1_pad(
    coco80_mc_controller_t *controller,
    const coco80_hwc_u8_t *source,
    uint8_t pad_value,
    coco80_hwc_u8_t *destination);

int coco80_mc_nearest_requant_concat(
    coco80_mc_controller_t *controller,
    const coco80_hwc_u8_t *small,
    const coco80_hwc_u8_t *route,
    int32_t input_zero_point,
    int32_t output_zero_point,
    uint32_t multiplier,
    uint32_t shift,
    coco80_hwc_u8_t *destination);

int coco80_mc_cpu_conv_kco(
    coco80_mc_controller_t *controller,
    const uint8_t *ifm,
    uint8_t *ofm,
    const int8_t *weight_kco,
    const int32_t *bias_i32,
    const uint8_t *activation_lut_u8,
    const coco80_cpu_layer_t *layer);

void coco80_mc_worker_loop(uint32_t worker_id);

#ifdef __cplusplus
}
#endif

#endif

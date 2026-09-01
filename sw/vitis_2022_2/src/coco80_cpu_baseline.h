#ifndef COCO80_CPU_BASELINE_H
#define COCO80_CPU_BASELINE_H

#include <stdint.h>

#define COCO80_CPU_BASELINE_MAGIC 0x42433843U /* C8CB */
#define COCO80_CPU_BASELINE_VERSION 1U
#define COCO80_CPU_BASELINE_MAX_SAMPLES 8U
#define COCO80_CPU_BASELINE_RESULT_ADDRESS ((uintptr_t)0x53F00000U)

enum {
    COCO80_CPU_BASELINE_RUNNING = 1,
    COCO80_CPU_BASELINE_PASS = 2,
    COCO80_CPU_BASELINE_ERR_ARGUMENT = -401,
    COCO80_CPU_BASELINE_ERR_CRC = -402,
    COCO80_CPU_BASELINE_ERR_COMPUTE = -403,
    COCO80_CPU_BASELINE_ERR_MISMATCH = -404,
    COCO80_CPU_BASELINE_ERR_DECODE = -405,
    COCO80_CPU_BASELINE_ERR_MULTICORE = -406
};

typedef struct __attribute__((aligned(64))) {
    uint32_t magic;
    uint32_t version;
    volatile int32_t status;
    uint32_t mode;
    uint64_t tick_hz;
    uint32_t warmup_runs;
    uint32_t timed_runs;
    uint32_t image_id;
    uint32_t detection_count;
    uint32_t parameter_crc32;
    uint32_t input_crc32;
    uint32_t expected_heads_crc32;
    uint32_t actual_heads_crc32;
    uint32_t mismatch_bytes;
    uint32_t first_mismatch_offset;
    uint32_t reserved0;
    uint64_t total_ticks[COCO80_CPU_BASELINE_MAX_SAMPLES];
    uint64_t conv_ticks[COCO80_CPU_BASELINE_MAX_SAMPLES];
    uint64_t tensor_ticks[COCO80_CPU_BASELINE_MAX_SAMPLES];
    uint64_t decode_ticks[COCO80_CPU_BASELINE_MAX_SAMPLES];
    uint64_t layer_ticks[COCO80_CPU_BASELINE_MAX_SAMPLES][13];
} coco80_cpu_baseline_result_t;

#endif

#ifndef ACCEL_SMOKE_H
#define ACCEL_SMOKE_H

#include <stdint.h>

#define ACCEL_BASE_ADDR       0xA0000000U
#define GPIO_BASE_ADDR        0xA0010000U
#define DMA_BIAS_BASE_ADDR    0xA0020000U
#define DMA_WEIGHT_BASE_ADDR  0xA0030000U
#define DMA_IFM_BASE_ADDR     0xA0040000U
#define DMA_OFM_BASE_ADDR     0xA0050000U

#define ACCEL_CTRL            0x00U
#define ACCEL_FM_SIZE         0x04U
#define ACCEL_OFM_SIZE        0x08U
#define ACCEL_CONV            0x0cU
#define ACCEL_K_TOTAL         0x10U
#define ACCEL_COUT_TOTAL      0x14U
#define ACCEL_NUM_PIXELS      0x18U
#define ACCEL_ACT_CFG         0x1cU
#define ACCEL_TILE_ROWS       0x20U
#define ACCEL_PIXEL_BASE      0x24U
#define ACCEL_DBG_EXPECTED    0x28U
#define ACCEL_DBG_CORE_WR     0x2cU
#define ACCEL_DBG_AXIS_WR     0x30U
#define ACCEL_DBG_TLASTS      0x34U
#define ACCEL_DBG_LAST_END    0x38U
#define ACCEL_IFM_ZP          0x3cU
#define ACCEL_POOL_CFG        0x40U
#define ACCEL_EXPECTED_BYTES  0x44U
#define ACCEL_PERF_BUSY       0x48U
#define ACCEL_PERF_WAIT_ANY   0x4cU
#define ACCEL_PERF_WAIT_BIAS  0x50U
#define ACCEL_PERF_WAIT_WEIGHT 0x54U
#define ACCEL_PERF_WAIT_IFM   0x58U
#define ACCEL_PERF_WAIT_OFM   0x5cU
#define ACCEL_PERF_COMPUTE    0x60U
#define ACCEL_STREAM_CFG      0x64U
#define ACCEL_STREAM_BIAS_PACKETS 0x68U
#define ACCEL_STREAM_WEIGHT_PACKETS 0x6cU
#define ACCEL_STREAM_IFM_PACKETS 0x70U
#define ACCEL_STREAM_BIAS_DONE 0x74U
#define ACCEL_STREAM_WEIGHT_DONE 0x78U
#define ACCEL_STREAM_IFM_DONE 0x7cU
#define ACCEL_QUANT_ADDR      0x80U
#define ACCEL_QUANT_DATA      0x84U
#define ACCEL_LUT_ADDR        0x88U
#define ACCEL_LUT_DATA        0x8cU
#define ACCEL_VECTOR_PACKETS  0x90U
#define ACCEL_VECTOR_PIXELS   0x94U
#define ACCEL_VECTOR_BEATS    0x98U
#define ACCEL_VECTOR_STALLS   0x9cU
#define ACCEL_STAGE_BIAS      0xa0U
#define ACCEL_STAGE_WEIGHT    0xa4U
#define ACCEL_STAGE_FEEDER    0xa8U
#define ACCEL_STAGE_COMPUTE   0xacU
#define ACCEL_STAGE_DRAIN     0xb0U
#define ACCEL_STAGE_OFM_POST  0xb4U
#define ACCEL_FEED_FILL_WAIT  0xb8U
#define ACCEL_FEED_PUSH       0xbcU
#define ACCEL_FEED_FIFO_STALL 0xc0U
#define ACCEL_FEED_WIN_NOT_READY 0xc4U
#define ACCEL_COMP_WLOAD      0xc8U
#define ACCEL_COMP_ACTIVE     0xccU
#define ACCEL_COMP_FIRE       0xd0U
#define ACCEL_COMP_IFM_STALL  0xd4U
#define ACCEL_COMP_TAIL       0xd8U
#define ACCEL_SUBPERF_VERSION 0xdcU
#define ACCEL_TAIL_CONFIG     0xe0U
#define ACCEL_TAIL_ELAPSED    0xe4U
#define ACCEL_DRAIN_EMPTY_WAIT 0xe8U
#define ACCEL_DRAIN_EMPTY_STICKY 0xecU
#define ACCEL_RAW_LOAD_ACTIVE 0xf0U
#define ACCEL_RAW_LOAD_UNPACK 0xf4U
#define ACCEL_RAW_REPLAY_ACTIVE 0xf8U
#define ACCEL_RAW_REPLAY_WAIT_READY 0xfcU
#define ACCEL_DRAIN_READ_FIRE 0x100U
#define ACCEL_DRAIN_PACKET_FIRE 0x104U
#define ACCEL_DRAIN_READY_STALL 0x108U
#define ACCEL_DRAIN_INTERNAL_FULL 0x10cU
#define ACCEL_DRAINPERF_VERSION 0x110U
#define ACCEL_PREFETCH_START  0x114U
#define ACCEL_PREFETCH_WEIGHT_DONE 0x118U
#define ACCEL_PREFETCH_FEED_DONE 0x11cU
#define ACCEL_PREFETCH_HIT    0x120U
#define ACCEL_PREFETCH_MISS   0x124U
#define ACCEL_PREFETCH_STALL  0x128U
#define ACCEL_PREFETCHPERF_VERSION 0x12cU
#define ACCEL_PSUMOVL_START   0x130U
#define ACCEL_PSUMOVL_HIT     0x134U
#define ACCEL_PSUMOVL_WAIT_PSUM 0x138U
#define ACCEL_PSUMOVL_UNDERFLOW 0x13cU
#define ACCEL_PSUMOVLPERF_VERSION 0x140U
#define ACCEL_COLLECT_PACKET_FIRE 0x144U
#define ACCEL_COLLECT_PARTIAL_WRITE 0x148U
#define ACCEL_COLLECT_FINAL_WRITE 0x14cU
#define ACCEL_COLLECT_CONTEXT_PUSH 0x150U
#define ACCEL_COLLECT_CONTEXT_POP 0x154U
#define ACCEL_COLLECT_CONTEXT_FULL_STALL 0x158U
#define ACCEL_COLLECT_COLUMN_EMPTY_WAIT 0x15cU
#define ACCEL_COLLECTPERF_VERSION 0x160U
#define ACCEL_PASSTRACE_SELECT 0x164U
#define ACCEL_PASS_COUNT 0x168U
#define ACCEL_PASS_START_TO_FIRST_FIRE 0x16cU
#define ACCEL_PASS_FIRST_TO_LAST_FIRE 0x170U
#define ACCEL_PASS_LAST_FIRE_TO_DONE 0x174U
#define ACCEL_PASS_COLLECT_FIRST_WAIT 0x178U
#define ACCEL_PASS_COLLECT_COLUMN_EMPTY 0x17cU
#define ACCEL_PASS_REPLAY_DURING_COMPUTE 0x180U
#define ACCEL_PASS_COMPUTE_IDLE_STAGE 0x184U
#define ACCEL_TRACE_WEIGHT_DONE 0x188U
#define ACCEL_TRACE_FEED_START 0x18cU
#define ACCEL_TRACE_FEED_READY 0x190U
#define ACCEL_TRACE_FEED_DONE 0x194U
#define ACCEL_TRACE_COMPUTE_START 0x198U
#define ACCEL_TRACE_FIRST_FIRE 0x19cU
#define ACCEL_TRACE_LAST_FIRE 0x1a0U
#define ACCEL_TRACE_COMPUTE_DONE 0x1a4U
#define ACCEL_TRACE_COLLECT_FIRST 0x1a8U
#define ACCEL_TRACE_COLLECT_LAST 0x1acU
#define ACCEL_TRACE_PASS_DONE 0x1b0U
#define ACCEL_PASSPERF_VERSION 0x1b4U
#define ACCEL_COLTRACE_CTRL 0x1b8U
#define ACCEL_COLTRACE_FIRST_WR 0x1bcU
#define ACCEL_COLTRACE_LAST_WR 0x1c0U
#define ACCEL_COLTRACE_WR_COUNT 0x1c4U
#define ACCEL_COLTRACE_EMPTY_WAIT 0x1c8U
#define ACCEL_COLTRACE_MISSING_OR 0x1ccU
#define ACCEL_COLTRACE_MISSING_FIRST 0x1d0U
#define ACCEL_COLTRACE_MISSING_LAST 0x1d4U
#define ACCEL_COLTRACE_VERSION 0x1d8U

#define ACCEL_CONV_KERNEL_1X1 (1U << 16)

#define ACCEL_QUANT_PACK(mult, shift, zp) \
    ((((uint32_t)(zp)) << 24) | (((uint32_t)(shift)) << 16) | ((uint32_t)(mult)))

#define GPIO_DATA             0x00U
#define GPIO_TRI              0x04U
#define GPIO2_DATA            0x08U
#define GPIO2_TRI             0x0cU

#define OFM_AXIS_BEAT_BYTES   8U

#define DMA_MM2S_DMACR        0x00U
#define DMA_MM2S_DMASR        0x04U
#define DMA_MM2S_SA           0x18U
#define DMA_MM2S_SA_MSB       0x1cU
#define DMA_MM2S_LENGTH       0x28U
#define DMA_S2MM_DMACR        0x30U
#define DMA_S2MM_DMASR        0x34U
#define DMA_S2MM_DA           0x48U
#define DMA_S2MM_DA_MSB       0x4cU
#define DMA_S2MM_LENGTH       0x58U

#define DMA_DMACR_RUNSTOP     0x00000001U
#define DMA_DMACR_RESET       0x00000004U
#define DMA_DMASR_HALTED      0x00000001U
#define DMA_DMASR_IDLE        0x00000002U
#define DMA_DMASR_IOC_IRQ     0x00001000U
#define DMA_DMASR_ERR_MASK    0x00000070U

#define ST_BIAS_REQ           (1U << 0)
#define ST_WEIGHT_REQ         (1U << 1)
#define ST_IFM_REQ            (1U << 2)
#define ST_OFM_FULL           (1U << 3)
#define ST_BIAS_ERR           (1U << 4)
#define ST_WEIGHT_ERR         (1U << 5)
#define ST_IFM_ERR            (1U << 6)
#define ST_FILL_FY_SHIFT      7U
#define ST_FILL_FY_MASK       (0x1ffU << ST_FILL_FY_SHIFT)
#define ST_ERROR_MASK         (ST_BIAS_ERR | ST_WEIGHT_ERR | ST_IFM_ERR)

#ifndef ACCEL_BATCH_STREAM
#define ACCEL_BATCH_STREAM    0
#endif

#ifndef ACCEL_NATIVE_1X1
#define ACCEL_NATIVE_1X1      0
#endif

#ifndef ACCEL_PREPACKED_WEIGHT
#define ACCEL_PREPACKED_WEIGHT 0
#endif

#ifndef ACCEL_RAW_HWC_IFM
#define ACCEL_RAW_HWC_IFM    0
#endif

#ifndef ACCEL_TILE_PERF_TRACE
#define ACCEL_TILE_PERF_TRACE 0
#endif

#ifndef ACCEL_RAW_HWC_COMPUTE_START_LEVEL
#define ACCEL_RAW_HWC_COMPUTE_START_LEVEL 0U
#endif
#ifndef ACCEL_EARLY_DRAIN
#define ACCEL_EARLY_DRAIN 0
#endif
#ifndef ACCEL_PASS_PREFETCH
#define ACCEL_PASS_PREFETCH 0
#endif
#ifndef ACCEL_DURING_COMPUTE_PREFETCH
#define ACCEL_DURING_COMPUTE_PREFETCH 0
#endif
#ifndef ACCEL_PSUM_STREAM_OVERLAP
#define ACCEL_PSUM_STREAM_OVERLAP 0
#endif
#ifndef ACCEL_CONTINUOUS_PSUM
#define ACCEL_CONTINUOUS_PSUM 0
#endif
#ifndef ACCEL_COLUMN_PSUM
#define ACCEL_COLUMN_PSUM 0
#endif
#ifndef ACCEL_PASS_TRACE_ENABLE
#define ACCEL_PASS_TRACE_ENABLE 0
#endif
#ifndef ACCEL_PASS_TRACE_COUT_BLOCK
#define ACCEL_PASS_TRACE_COUT_BLOCK 0U
#endif
#ifndef ACCEL_PASS_TRACE_K_PASS
#define ACCEL_PASS_TRACE_K_PASS 0U
#endif

#define ACCEL_STREAM_CFG_BATCH   0x1U
#define ACCEL_STREAM_CFG_RAW_HWC 0x2U
#define ACCEL_STREAM_CFG_EARLY_DRAIN 0x4U
#define ACCEL_STREAM_CFG_PASS_PREFETCH 0x8U
#define ACCEL_STREAM_CFG_PSUM_STREAM_OVERLAP 0x10U
#define ACCEL_STREAM_CFG_CONTINUOUS_PSUM 0x20U
#define ACCEL_STREAM_CFG_COLUMN_PSUM 0x40U
#define ACCEL_STREAM_CFG_DURING_COMPUTE_PREFETCH 0x80U

/* Mirrors tb_conv_accel_core_axi_lite_axis_stream_r18_c8_smoke.v. */
#ifndef ACCEL_SMOKE_REAL_CONV0_CROP_POOL
#define ACCEL_SMOKE_REAL_CONV0_CROP_POOL 0
#endif

#ifndef ACCEL_SMOKE_CONV0_CROP_POOL_TILES
#define ACCEL_SMOKE_CONV0_CROP_POOL_TILES 0
#endif

#ifndef ACCEL_SMOKE_LAYER06_TILE4
#define ACCEL_SMOKE_LAYER06_TILE4 0
#endif

#ifndef ACCEL_SMOKE_LAYER06_TILES
#define ACCEL_SMOKE_LAYER06_TILES 0
#endif

#ifndef ACCEL_SMOKE_LAYER06_POOL_TILES
#define ACCEL_SMOKE_LAYER06_POOL_TILES 0
#endif

#ifndef ACCEL_SMOKE_CONV4_POOL_TILES
#define ACCEL_SMOKE_CONV4_POOL_TILES 0
#endif

#define ACCEL_SMOKE_LAYER06_ANY \
    (ACCEL_SMOKE_LAYER06_TILE4 || ACCEL_SMOKE_LAYER06_TILES || ACCEL_SMOKE_LAYER06_POOL_TILES)

#define ACCEL_SMOKE_EXTERNAL_GOLDEN \
    (ACCEL_SMOKE_REAL_CONV0_CROP_POOL || ACCEL_SMOKE_LAYER06_ANY || ACCEL_SMOKE_CONV4_POOL_TILES)

#if ACCEL_SMOKE_CONV4_POOL_TILES

#define ROWS                  18
#define COLS                  8
#define IFM_BANKS             2
#define FM_W                  26
#define FM_H                  26
#define OFM_W                 26
#define OFM_H                 26
#define CIN                   128
#define KH                    3
#define KW                    3
#define K_TOTAL               (CIN * KH * KW)
#define COUT_TILE             (COLS * 2)
#define COUT_TOTAL            256
#define CONV_PAD              1
#define CONV_STRIDE           1
#define TILE_OY_BASE          0
#define TILE_OFM_H            4
#define SMOKE_TILE_COUNT      7
#define SMOKE_NAME            "conv4 pool tiles"
#define TILE_PIXEL_BASE       0
#define TILE_PIXELS           (OFM_W * TILE_OFM_H)
#define FULL_PIXELS           (OFM_W * OFM_H)
#define K_PASSES              ((K_TOTAL + ROWS - 1) / ROWS)
#define COUT_BLOCKS           ((COUT_TOTAL + COUT_TILE - 1) / COUT_TILE)
#define INPUT_ZERO_POINT      16
#define ACT_MODE              2
#define POOL_ENABLE           1
#define POOL_STRIDE           2
#define QUANT_MULT            18831U
#define QUANT_SHIFT           7U
#define QUANT_ZP              73U
#define EXPECTED_OUTPUT_PIXELS ((OFM_W / 2) * (TILE_OFM_H / 2))
#define EXPECTED_OFM_BYTES    (EXPECTED_OUTPUT_PIXELS * COUT_TOTAL)
#define TOTAL_OUTPUT_PIXELS   ((OFM_W / 2) * (OFM_H / 2))
#define TOTAL_EXPECTED_OFM_BYTES (TOTAL_OUTPUT_PIXELS * COUT_TOTAL)
#define OFM_AXIS_BYTES        (EXPECTED_OFM_BYTES * OFM_AXIS_BEAT_BYTES)

#elif ACCEL_SMOKE_LAYER06_ANY

#define ROWS                  18
#define COLS                  8
#define IFM_BANKS             2
#define FM_W                  52
#define FM_H                  52
#define OFM_W                 52
#define OFM_H                 52
#define CIN                   64
#define KH                    3
#define KW                    3
#define K_TOTAL               (CIN * KH * KW)
#define COUT_TILE             (COLS * 2)
#define COUT_TOTAL            128
#define CONV_PAD              1
#define CONV_STRIDE           1
#define TILE_OY_BASE          0
#define TILE_OFM_H            4
#if ACCEL_SMOKE_LAYER06_POOL_TILES
#define SMOKE_TILE_COUNT      13
#define SMOKE_NAME            "layer06 pool tiles"
#elif ACCEL_SMOKE_LAYER06_TILES
#define SMOKE_TILE_COUNT      13
#define SMOKE_NAME            "layer06 tiles"
#else
#define SMOKE_TILE_COUNT      1
#define SMOKE_NAME            "layer06 tile4"
#endif
#define TILE_PIXEL_BASE       0
#define TILE_PIXELS           (OFM_W * TILE_OFM_H)
#define FULL_PIXELS           (OFM_W * OFM_H)
#define K_PASSES              ((K_TOTAL + ROWS - 1) / ROWS)
#define COUT_BLOCKS           ((COUT_TOTAL + COUT_TILE - 1) / COUT_TILE)
#define INPUT_ZERO_POINT      36
#define ACT_MODE              2
#if ACCEL_SMOKE_LAYER06_POOL_TILES
#define POOL_ENABLE           1
#define POOL_STRIDE           2
#else
#define POOL_ENABLE           0
#define POOL_STRIDE           0
#endif
#define QUANT_MULT            18055U
#define QUANT_SHIFT           7U
#define QUANT_ZP              75U
#if ACCEL_SMOKE_LAYER06_POOL_TILES
#define EXPECTED_OUTPUT_PIXELS ((OFM_W / 2) * (TILE_OFM_H / 2))
#else
#define EXPECTED_OUTPUT_PIXELS TILE_PIXELS
#endif
#define EXPECTED_OFM_BYTES    (EXPECTED_OUTPUT_PIXELS * COUT_TOTAL)
#if ACCEL_SMOKE_LAYER06_POOL_TILES
#define TOTAL_OUTPUT_PIXELS   ((OFM_W / 2) * (OFM_H / 2))
#define TOTAL_EXPECTED_OFM_BYTES (TOTAL_OUTPUT_PIXELS * COUT_TOTAL)
#elif ACCEL_SMOKE_LAYER06_TILES
#define TOTAL_OUTPUT_PIXELS   FULL_PIXELS
#define TOTAL_EXPECTED_OFM_BYTES (FULL_PIXELS * COUT_TOTAL)
#else
#define TOTAL_OUTPUT_PIXELS   EXPECTED_OUTPUT_PIXELS
#define TOTAL_EXPECTED_OFM_BYTES EXPECTED_OFM_BYTES
#endif
#define OFM_AXIS_BYTES        (EXPECTED_OFM_BYTES * OFM_AXIS_BEAT_BYTES)

#elif ACCEL_SMOKE_REAL_CONV0_CROP_POOL

#define ROWS                  18
#define COLS                  8
#define IFM_BANKS             2
#define FM_W                  16
#define FM_H                  8
#define OFM_W                 16
#define OFM_H                 8
#define CIN                   3
#define KH                    3
#define KW                    3
#define K_TOTAL               (CIN * KH * KW)
#define COUT_TILE             (COLS * 2)
#define COUT_TOTAL            16
#define CONV_PAD              1
#define CONV_STRIDE           1
#define TILE_OY_BASE          0
#if ACCEL_SMOKE_CONV0_CROP_POOL_TILES
#define TILE_OFM_H            4
#define SMOKE_TILE_COUNT      2
#define SMOKE_NAME            "conv0 crop pool tiles"
#else
#define TILE_OFM_H            8
#define SMOKE_TILE_COUNT      1
#define SMOKE_NAME            "conv0 crop pool"
#endif
#define TILE_PIXEL_BASE       0
#define TILE_PIXELS           (OFM_W * TILE_OFM_H)
#define FULL_PIXELS           (OFM_W * OFM_H)
#define K_PASSES              ((K_TOTAL + ROWS - 1) / ROWS)
#define COUT_BLOCKS           ((COUT_TOTAL + COUT_TILE - 1) / COUT_TILE)
#define INPUT_ZERO_POINT      0
#define ACT_MODE              2
#define POOL_ENABLE           1
#define POOL_STRIDE           2
#define QUANT_MULT            18898U
#define QUANT_SHIFT           9U
#define QUANT_ZP              69U
#define EXPECTED_OUTPUT_PIXELS ((OFM_W / 2) * (TILE_OFM_H / 2))
#define EXPECTED_OFM_BYTES    (EXPECTED_OUTPUT_PIXELS * COUT_TOTAL)
#define TOTAL_OUTPUT_PIXELS   ((OFM_W / 2) * (OFM_H / 2))
#define TOTAL_EXPECTED_OFM_BYTES (TOTAL_OUTPUT_PIXELS * COUT_TOTAL)
#define OFM_AXIS_BYTES        (EXPECTED_OFM_BYTES * OFM_AXIS_BEAT_BYTES)

#else

#define ROWS                  18
#define COLS                  8
#define IFM_BANKS             2
#define FM_W                  5
#define FM_H                  5
#define OFM_W                 5
#define OFM_H                 5
#define CIN                   16
#define KH                    3
#define KW                    3
#define K_TOTAL               (CIN * KH * KW)
#define COUT_TILE             (COLS * 2)
#define COUT_TOTAL            16
#define CONV_PAD              1
#define CONV_STRIDE           1
#define TILE_OY_BASE          0
#define TILE_OFM_H            2
#define SMOKE_TILE_COUNT      1
#define TILE_PIXEL_BASE       0
#define TILE_PIXELS           (OFM_W * TILE_OFM_H)
#define FULL_PIXELS           (OFM_W * OFM_H)
#define K_PASSES              ((K_TOTAL + ROWS - 1) / ROWS)
#define COUT_BLOCKS           ((COUT_TOTAL + COUT_TILE - 1) / COUT_TILE)
#define INPUT_ZERO_POINT      0
#define ACT_MODE              0
#define POOL_ENABLE           0
#define POOL_STRIDE           0
#define QUANT_MULT            32767U
#define QUANT_SHIFT           0U
#define QUANT_ZP              0U
#define EXPECTED_OUTPUT_PIXELS TILE_PIXELS
#define EXPECTED_OFM_BYTES    (TILE_PIXELS * COUT_TOTAL)
#define TOTAL_OUTPUT_PIXELS   EXPECTED_OUTPUT_PIXELS
#define TOTAL_EXPECTED_OFM_BYTES EXPECTED_OFM_BYTES
#define OFM_AXIS_BYTES        (EXPECTED_OFM_BYTES * OFM_AXIS_BEAT_BYTES)
#define SMOKE_NAME            "r18_c8"

#endif

/* The carrier-based XSA exposes feeder_fill_fy on GPIO2[15:7]. */
#ifndef USE_GPIO_FILL_FY
#define USE_GPIO_FILL_FY      1
#endif

#endif

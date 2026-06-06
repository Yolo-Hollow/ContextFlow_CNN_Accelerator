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
#define ACCEL_QUANT_ADDR      0x80U
#define ACCEL_QUANT_DATA      0x84U
#define ACCEL_LUT_ADDR        0x88U
#define ACCEL_LUT_DATA        0x8cU

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

#if ACCEL_SMOKE_LAYER06_TILE4 || ACCEL_SMOKE_LAYER06_TILES

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
#if ACCEL_SMOKE_LAYER06_TILES
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
#define POOL_ENABLE           0
#define POOL_STRIDE           0
#define QUANT_MULT            18055U
#define QUANT_SHIFT           7U
#define QUANT_ZP              75U
#define EXPECTED_OUTPUT_PIXELS TILE_PIXELS
#define EXPECTED_OFM_BYTES    (EXPECTED_OUTPUT_PIXELS * COUT_TOTAL)
#if ACCEL_SMOKE_LAYER06_TILES
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

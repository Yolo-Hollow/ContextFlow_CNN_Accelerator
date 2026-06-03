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

#define GPIO_DATA             0x00U
#define GPIO_TRI              0x04U
#define GPIO2_DATA            0x08U
#define GPIO2_TRI             0x0cU

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

/* Mirrors tb_conv_accel_core_axi_lite_axis_stream_r18_c16_smoke.v. */
#define ROWS                  18
#define COLS                  16
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
#define COUT_TOTAL            20
#define CONV_PAD              1
#define CONV_STRIDE           1
#define TILE_OY_BASE          0
#define TILE_OFM_H            2
#define TILE_PIXEL_BASE       0
#define TILE_PIXELS           (OFM_W * TILE_OFM_H)
#define FULL_PIXELS           (OFM_W * OFM_H)
#define K_PASSES              ((K_TOTAL + ROWS - 1) / ROWS)
#define COUT_BLOCKS           ((COUT_TOTAL + COUT_TILE - 1) / COUT_TILE)
#define EXPECTED_OFM_BYTES    (TILE_PIXELS * COUT_TOTAL)
#define OFM_AXIS_BYTES        (EXPECTED_OFM_BYTES * 4)

/* The carrier-based XSA exposes feeder_fill_fy on GPIO2[15:7]. */
#ifndef USE_GPIO_FILL_FY
#define USE_GPIO_FILL_FY      1
#endif

#endif

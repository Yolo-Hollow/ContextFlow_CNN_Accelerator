#include "accel_smoke.h"
#include "accel_layer_desc.h"
#include "accel_single_scale_plan.h"
#include "accel_single_scale_scheduler.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_types.h"
#include "xil_printf.h"

#if ACCEL_SMOKE_REAL_CONV0_CROP_POOL
#include "conv0_crop_pool_data.h"
#endif

#if ACCEL_SMOKE_LAYER06_ANY
#include "layer06_tile4_data.h"
#endif

#if ACCEL_SMOKE_CONV4_POOL_TILES
#include "conv4_pool_data.h"
#endif

/* Zynq UltraScale+ PS UARTs. Write both so either KV260 FTDI channel can show logs. */
#define UART0_BASE            0xFF000000U
#define UART1_BASE            0xFF010000U
#define UART_SR_OFFSET        0x2CU
#define UART_FIFO_OFFSET      0x30U
#define UART_SR_TXFULL        0x10U

static int8_t feat[CIN][FM_H][FM_W];
static int8_t weight[K_TOTAL][COUT_TOTAL];
static int32_t bias[COUT_TOTAL];
#if !ACCEL_SMOKE_EXTERNAL_GOLDEN
static int32_t golden[FULL_PIXELS][COUT_TOTAL];
#endif
static uint8_t ofm_mem[FULL_PIXELS * COUT_TOTAL];

static uint64_t bias_buf[COUT_TILE / 2] __attribute__((aligned(64)));
static uint64_t weight_buf[(ROWS * COUT_TILE) / 8] __attribute__((aligned(64)));
static uint64_t ifm_buf[FM_W] __attribute__((aligned(64)));
static uint64_t ofm_axis_buf[EXPECTED_OFM_BYTES] __attribute__((aligned(64)));
volatile uint32_t debug_stage = 0;
volatile uint32_t debug_value = 0;

static const accel_layer_desc_t active_layer = {
    .name = SMOKE_NAME,
    .fm_w = FM_W,
    .fm_h = FM_H,
    .ofm_w = OFM_W,
    .ofm_h = OFM_H,
    .cin = CIN,
    .cout_total = COUT_TOTAL,
    .k_total = K_TOTAL,
    .conv_stride = CONV_STRIDE,
    .conv_pad = CONV_PAD,
    .act_mode = ACT_MODE,
    .input_zero_point = INPUT_ZERO_POINT,
    .pool_enable = POOL_ENABLE,
    .pool_stride = POOL_STRIDE,
    .tile_oy_base = TILE_OY_BASE,
    .tile_ofm_h = TILE_OFM_H,
    .tile_pixel_base = TILE_PIXEL_BASE,
    .tile_pixels = TILE_PIXELS,
    .expected_output_pixels = EXPECTED_OUTPUT_PIXELS,
    .expected_ofm_bytes = EXPECTED_OFM_BYTES,
    .quant_mult = QUANT_MULT,
    .quant_shift = QUANT_SHIFT,
    .quant_zp = QUANT_ZP,
#if ACCEL_SMOKE_REAL_CONV0_CROP_POOL
    .activation_lut = conv0_crop_activation_lut_u8,
    .golden_ofm_u8 = conv0_crop_golden_pool_u8,
#elif ACCEL_SMOKE_LAYER06_POOL_TILES
    .activation_lut = layer06_tile4_activation_lut_u8,
    .golden_ofm_u8 = layer06_pool_golden_ofm_u8,
#elif ACCEL_SMOKE_LAYER06_ANY
    .activation_lut = layer06_tile4_activation_lut_u8,
    .golden_ofm_u8 = layer06_tile4_golden_ofm_u8,
#elif ACCEL_SMOKE_CONV4_POOL_TILES
    .activation_lut = conv4_pool_activation_lut_u8,
    .golden_ofm_u8 = conv4_pool_golden_ofm_u8,
#else
    .activation_lut = NULL,
    .golden_ofm_u8 = NULL,
#endif
};

static const accel_layer_runtime_t active_runtime = {
    .layer = &active_layer,
    .bias_buf = bias_buf,
    .bias_bytes = sizeof(bias_buf),
    .weight_buf = weight_buf,
    .weight_bytes = sizeof(weight_buf),
    .ifm_buf = ifm_buf,
    .ifm_bytes = sizeof(ifm_buf),
    .ofm_axis_buf = ofm_axis_buf,
    .ofm_axis_bytes = OFM_AXIS_BYTES,
};

typedef struct {
    const char *name;
    uint32_t tile_oy_base;
    uint32_t tile_ofm_h;
    uint32_t tile_pixel_base;
    uint32_t tile_pixels;
    uint32_t expected_output_pixels;
    uint32_t expected_ofm_bytes;
} smoke_tile_desc_t;

static const smoke_tile_desc_t smoke_tiles[SMOKE_TILE_COUNT] = {
#if ACCEL_SMOKE_CONV0_CROP_POOL_TILES
    {"tile0", 0U, 4U, 0U, 16U * 4U, 8U * 2U, 8U * 2U * 16U},
    {"tile1", 4U, 4U, 16U, 16U * 4U, 8U * 2U, 8U * 2U * 16U},
#elif ACCEL_SMOKE_LAYER06_POOL_TILES
    {"tile0", 0U, 4U, 0U * 52U, 52U * 4U, 26U * 2U, 26U * 2U * 128U},
    {"tile1", 4U, 4U, 1U * 52U, 52U * 4U, 26U * 2U, 26U * 2U * 128U},
    {"tile2", 8U, 4U, 2U * 52U, 52U * 4U, 26U * 2U, 26U * 2U * 128U},
    {"tile3", 12U, 4U, 3U * 52U, 52U * 4U, 26U * 2U, 26U * 2U * 128U},
    {"tile4", 16U, 4U, 4U * 52U, 52U * 4U, 26U * 2U, 26U * 2U * 128U},
    {"tile5", 20U, 4U, 5U * 52U, 52U * 4U, 26U * 2U, 26U * 2U * 128U},
    {"tile6", 24U, 4U, 6U * 52U, 52U * 4U, 26U * 2U, 26U * 2U * 128U},
    {"tile7", 28U, 4U, 7U * 52U, 52U * 4U, 26U * 2U, 26U * 2U * 128U},
    {"tile8", 32U, 4U, 8U * 52U, 52U * 4U, 26U * 2U, 26U * 2U * 128U},
    {"tile9", 36U, 4U, 9U * 52U, 52U * 4U, 26U * 2U, 26U * 2U * 128U},
    {"tile10", 40U, 4U, 10U * 52U, 52U * 4U, 26U * 2U, 26U * 2U * 128U},
    {"tile11", 44U, 4U, 11U * 52U, 52U * 4U, 26U * 2U, 26U * 2U * 128U},
    {"tile12", 48U, 4U, 12U * 52U, 52U * 4U, 26U * 2U, 26U * 2U * 128U},
#elif ACCEL_SMOKE_CONV4_POOL_TILES
    {"tile0", 0U, 4U, 0U * 26U, 26U * 4U, 13U * 2U, 13U * 2U * 256U},
    {"tile1", 4U, 4U, 1U * 26U, 26U * 4U, 13U * 2U, 13U * 2U * 256U},
    {"tile2", 8U, 4U, 2U * 26U, 26U * 4U, 13U * 2U, 13U * 2U * 256U},
    {"tile3", 12U, 4U, 3U * 26U, 26U * 4U, 13U * 2U, 13U * 2U * 256U},
    {"tile4", 16U, 4U, 4U * 26U, 26U * 4U, 13U * 2U, 13U * 2U * 256U},
    {"tile5", 20U, 4U, 5U * 26U, 26U * 4U, 13U * 2U, 13U * 2U * 256U},
    {"tile6", 24U, 2U, 6U * 26U, 26U * 2U, 13U * 1U, 13U * 1U * 256U},
#elif ACCEL_SMOKE_LAYER06_TILES
    {"tile0", 0U, 4U, 0U * 52U, 52U * 4U, 52U * 4U, 52U * 4U * 128U},
    {"tile1", 4U, 4U, 4U * 52U, 52U * 4U, 52U * 4U, 52U * 4U * 128U},
    {"tile2", 8U, 4U, 8U * 52U, 52U * 4U, 52U * 4U, 52U * 4U * 128U},
    {"tile3", 12U, 4U, 12U * 52U, 52U * 4U, 52U * 4U, 52U * 4U * 128U},
    {"tile4", 16U, 4U, 16U * 52U, 52U * 4U, 52U * 4U, 52U * 4U * 128U},
    {"tile5", 20U, 4U, 20U * 52U, 52U * 4U, 52U * 4U, 52U * 4U * 128U},
    {"tile6", 24U, 4U, 24U * 52U, 52U * 4U, 52U * 4U, 52U * 4U * 128U},
    {"tile7", 28U, 4U, 28U * 52U, 52U * 4U, 52U * 4U, 52U * 4U * 128U},
    {"tile8", 32U, 4U, 32U * 52U, 52U * 4U, 52U * 4U, 52U * 4U * 128U},
    {"tile9", 36U, 4U, 36U * 52U, 52U * 4U, 52U * 4U, 52U * 4U * 128U},
    {"tile10", 40U, 4U, 40U * 52U, 52U * 4U, 52U * 4U, 52U * 4U * 128U},
    {"tile11", 44U, 4U, 44U * 52U, 52U * 4U, 52U * 4U, 52U * 4U * 128U},
    {"tile12", 48U, 4U, 48U * 52U, 52U * 4U, 52U * 4U, 52U * 4U * 128U},
#else
    {"tile0", TILE_OY_BASE, TILE_OFM_H, TILE_PIXEL_BASE,
     TILE_PIXELS, EXPECTED_OUTPUT_PIXELS, EXPECTED_OFM_BYTES},
#endif
};

static void uart_putc_one(uint32_t base, char c)
{
    for (uint32_t i = 0; i < 100000U; ++i) {
        if ((Xil_In32(base + UART_SR_OFFSET) & UART_SR_TXFULL) == 0U) {
            Xil_Out32(base + UART_FIFO_OFFSET, (uint32_t)c);
            return;
        }
    }
}

static void uart_putc_all(char c)
{
    if (c == '\n') {
        uart_putc_all('\r');
    }
    uart_putc_one(UART0_BASE, c);
    uart_putc_one(UART1_BASE, c);
}

static void uart_puts_all(const char *s)
{
    while (*s != '\0') {
        uart_putc_all(*s++);
    }
}

static void log_printf(const char *fmt, ...)
{
    char buf[256];
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    uart_puts_all(buf);
}

#define xil_printf(...) log_printf(__VA_ARGS__)

static void print_single_scale_buffer_id(uint32_t id)
{
    if (id == ACCEL_SINGLE_SCALE_BUFFER_EXTERNAL) {
        xil_printf("ext");
    } else {
        xil_printf("fb%lu", (unsigned long)id);
    }
}

static int run_single_scale_scheduler_dry_run(void)
{
    accel_single_scale_layer_schedule_t schedule[ACCEL_SINGLE_SCALE_LAYER_COUNT];
    accel_single_scale_schedule_summary_t summary;
    int rc = accel_single_scale_dry_run(schedule, ACCEL_SINGLE_SCALE_LAYER_COUNT, &summary);

    if (rc != 0) {
        xil_printf("single-scale scheduler dry-run failed rc=%d\r\n", rc);
        return rc;
    }

    xil_printf("single-scale dry-run: layers=%lu ext_in=%lu fb0=%lu fb1=%lu max_axis=%lu max_tile_axis=%lu tiles=%lu blocks=%lu\r\n",
               (unsigned long)summary.layer_count,
               (unsigned long)summary.external_input_bytes,
               (unsigned long)summary.feature_buffer_bytes[0],
               (unsigned long)summary.feature_buffer_bytes[1],
               (unsigned long)summary.max_ofm_axis_bytes,
               (unsigned long)summary.max_tile_axis_bytes,
               (unsigned long)summary.total_spatial_tiles,
               (unsigned long)summary.total_schedule_blocks);

    for (uint32_t i = 0U; i < ACCEL_SINGLE_SCALE_LAYER_COUNT; ++i) {
        const accel_single_scale_layer_plan_t *p = schedule[i].plan;
        xil_printf("plan[%lu] %s m=%u infer=%u ",
                   (unsigned long)i,
                   p->name,
                   (unsigned)p->model_index,
                   (unsigned)p->infer_index);
        print_single_scale_buffer_id(schedule[i].input_buffer_id);
        xil_printf("->");
        print_single_scale_buffer_id(schedule[i].output_buffer_id);
        xil_printf(" %lux%lux%u -> %lux%lux%u bytes=%lu tile_h=%lu tiles=%lu tile_axis=%lu kpass=%lu cblk=%lu\r\n",
                   (unsigned long)p->fm_w,
                   (unsigned long)p->fm_h,
                   (unsigned)p->cin,
                   (unsigned long)schedule[i].final_w,
                   (unsigned long)schedule[i].final_h,
                   (unsigned)p->cout_total,
                   (unsigned long)schedule[i].output_bytes,
                   (unsigned long)schedule[i].max_tile_ofm_h,
                   (unsigned long)schedule[i].tile_count,
                   (unsigned long)schedule[i].max_tile_axis_bytes,
                   (unsigned long)p->k_passes,
                   (unsigned long)p->cout_blocks);
    }

    return 0;
}

static inline void wr32(uint32_t base, uint32_t off, uint32_t v)
{
    Xil_Out32(base + off, v);
}

static inline uint32_t rd32(uint32_t base, uint32_t off)
{
    return Xil_In32(base + off);
}

static void accel_write_reg(uint32_t off, uint32_t v)
{
    wr32(ACCEL_BASE_ADDR, off, v);
}

static uint32_t accel_read_reg(uint32_t off)
{
    return rd32(ACCEL_BASE_ADDR, off);
}

static int program_quant_tile(uint16_t mult, uint8_t shift, uint8_t zp)
{
    uint32_t packed = ACCEL_QUANT_PACK(mult, shift, zp);

    for (uint32_t lane = 0; lane < COUT_TILE; ++lane) {
        accel_write_reg(ACCEL_QUANT_ADDR, lane);
        accel_write_reg(ACCEL_QUANT_DATA, packed);
        if (accel_read_reg(ACCEL_QUANT_DATA) != packed) {
            xil_printf("quant readback mismatch lane=%lu got=0x%08lx exp=0x%08lx\r\n",
                       (unsigned long)lane,
                       (unsigned long)accel_read_reg(ACCEL_QUANT_DATA),
                       (unsigned long)packed);
            return -1;
        }
    }
    return 0;
}

static int program_activation_lut(const uint8_t *lut)
{
    for (uint32_t idx = 0; idx < 256U; ++idx) {
        uint32_t data = (lut != NULL) ? lut[idx] : idx;
        accel_write_reg(ACCEL_LUT_ADDR, idx);
        accel_write_reg(ACCEL_LUT_DATA, data);
        if ((accel_read_reg(ACCEL_LUT_DATA) & 0xffU) != data) {
            xil_printf("lut readback mismatch idx=%lu got=0x%08lx exp=0x%02lx\r\n",
                       (unsigned long)idx,
                       (unsigned long)accel_read_reg(ACCEL_LUT_DATA),
                       (unsigned long)data);
            return -1;
        }
    }
    return 0;
}

#if !ACCEL_SMOKE_EXTERNAL_GOLDEN
static uint8_t clamp8(int32_t v)
{
    if (v > 127) {
        return 127U;
    }
    if (v < -128) {
        return 128U;
    }
    return (uint8_t)v;
}
#endif

static int pass_needs_ch(int k_base, int c)
{
    return (c < CIN) && (k_base < (c + 1) * 9) && ((k_base + ROWS) > c * 9);
}

static int channel_for_bank(int k_base, int bank)
{
    for (int c = 0; c < CIN; ++c) {
        if (pass_needs_ch(k_base, c) && ((c % IFM_BANKS) == bank)) {
            return c;
        }
    }
    return -1;
}

static void make_vectors(void)
{
#if ACCEL_SMOKE_REAL_CONV0_CROP_POOL
    for (int ch = 0; ch < CIN; ++ch) {
        for (int y = 0; y < FM_H; ++y) {
            for (int x = 0; x < FM_W; ++x) {
                int idx = (y * FM_W + x) * CIN + ch;
                feat[ch][y][x] = (int8_t)conv0_crop_ifm_u8[idx];
            }
        }
    }

    for (int k = 0; k < K_TOTAL; ++k) {
        for (int co = 0; co < COUT_TOTAL; ++co) {
            weight[k][co] = conv0_crop_weight_s8[k * COUT_TOTAL + co];
        }
    }

    for (int co = 0; co < COUT_TOTAL; ++co) {
        bias[co] = conv0_crop_bias_i32[co];
    }
#elif ACCEL_SMOKE_LAYER06_ANY
    for (int ch = 0; ch < CIN; ++ch) {
        for (int y = 0; y < FM_H; ++y) {
            for (int x = 0; x < FM_W; ++x) {
                int idx = (y * FM_W + x) * CIN + ch;
                feat[ch][y][x] = (int8_t)layer06_tile4_ifm_u8[idx];
            }
        }
    }

    for (int k = 0; k < K_TOTAL; ++k) {
        for (int co = 0; co < COUT_TOTAL; ++co) {
            weight[k][co] = layer06_tile4_weight_s8[k * COUT_TOTAL + co];
        }
    }

    for (int co = 0; co < COUT_TOTAL; ++co) {
        bias[co] = layer06_tile4_bias_i32[co];
    }
#elif ACCEL_SMOKE_CONV4_POOL_TILES
    for (int ch = 0; ch < CIN; ++ch) {
        for (int y = 0; y < FM_H; ++y) {
            for (int x = 0; x < FM_W; ++x) {
                int idx = (y * FM_W + x) * CIN + ch;
                feat[ch][y][x] = (int8_t)conv4_pool_ifm_u8[idx];
            }
        }
    }

    for (int k = 0; k < K_TOTAL; ++k) {
        for (int co = 0; co < COUT_TOTAL; ++co) {
            weight[k][co] = conv4_pool_weight_s8[k * COUT_TOTAL + co];
        }
    }

    for (int co = 0; co < COUT_TOTAL; ++co) {
        bias[co] = conv4_pool_bias_i32[co];
    }
#else
    for (int ch = 0; ch < CIN; ++ch) {
        for (int y = 0; y < FM_H; ++y) {
            for (int x = 0; x < FM_W; ++x) {
                feat[ch][y][x] = (int8_t)(((ch * 3 + y * 5 + x * 2) % 9) - 4);
            }
        }
    }

    for (int k = 0; k < K_TOTAL; ++k) {
        for (int co = 0; co < COUT_TOTAL; ++co) {
            weight[k][co] = (int8_t)(((k * 2 + co * 3) % 7) - 3);
        }
    }

    for (int co = 0; co < COUT_TOTAL; ++co) {
        bias[co] = co - 9;
        for (int idx = 0; idx < FULL_PIXELS; ++idx) {
            int y = idx / OFM_W;
            int x = idx % OFM_W;
            int32_t acc = bias[co];
            for (int k = 0; k < K_TOTAL; ++k) {
                int ch = k / 9;
                int ker = k % 9;
                int ky = ker / 3;
                int kx = ker % 3;
                int fy = y * CONV_STRIDE + ky - CONV_PAD;
                int fx = x * CONV_STRIDE + kx - CONV_PAD;
                if (fy >= 0 && fy < FM_H && fx >= 0 && fx < FM_W) {
                    acc += (int32_t)feat[ch][fy][fx] * (int32_t)weight[k][co];
                }
            }
            golden[idx][co] = acc;
        }
    }
#endif
}

static void pack_bias(int cout_base)
{
    for (int i = 0; i < COUT_TILE; i += 2) {
        int lo_co = cout_base + i;
        int hi_co = cout_base + i + 1;
        uint32_t lo = (lo_co < COUT_TOTAL) ? (uint32_t)bias[lo_co] : 0U;
        uint32_t hi = (hi_co < COUT_TOTAL) ? (uint32_t)bias[hi_co] : 0U;
        bias_buf[i / 2] = ((uint64_t)hi << 32) | lo;
    }
}

static void pack_weight(int k_base, int cout_base)
{
    int lane = 0;
    uint64_t word = 0;
    int out = 0;

    for (int kk = 0; kk < ROWS; ++kk) {
        for (int cc = 0; cc < COUT_TILE; ++cc) {
            int gk = k_base + kk;
            int co = cout_base + cc;
            uint8_t v = 0;
            if (gk < K_TOTAL && co < COUT_TOTAL) {
                v = (uint8_t)weight[gk][co];
            }
            word |= ((uint64_t)v) << (lane * 8);
            if (lane == 7) {
                weight_buf[out++] = word;
                word = 0;
                lane = 0;
            } else {
                ++lane;
            }
        }
    }
}

static void pack_ifm_line(int fy, int k_base)
{
    for (int x = 0; x < FM_W; ++x) {
        uint64_t word = 0;
        for (int b = 0; b < IFM_BANKS; ++b) {
            int ch = channel_for_bank(k_base, b);
            uint8_t v = (ch >= 0) ? (uint8_t)feat[ch][fy][x] : 0U;
            word |= ((uint64_t)v) << (b * 8);
        }
        ifm_buf[x] = word;
    }
}

static void dma_reset_named(const char *name, uint32_t base, uint32_t cr_off, uint32_t sr_off)
{
    xil_printf("dma reset: %s base=0x%08lx write reset\r\n", name, (unsigned long)base);
    wr32(base, cr_off, DMA_DMACR_RESET);
    xil_printf("dma reset: %s poll reset bit\r\n", name);
    for (uint32_t i = 0; i < 1000000U; ++i) {
        if ((rd32(base, cr_off) & DMA_DMACR_RESET) == 0U) {
            break;
        }
    }
    xil_printf("dma reset: %s clear irq\r\n", name);
    wr32(base, sr_off, 0x00007000U);
    xil_printf("dma reset: %s done\r\n", name);
}

static int dma_wait(uint32_t base, uint32_t sr_off, const char *name)
{
    for (uint32_t i = 0; i < 50000000U; ++i) {
        uint32_t sr = rd32(base, sr_off);
        if ((sr & DMA_DMASR_IOC_IRQ) != 0U) {
            wr32(base, sr_off, DMA_DMASR_IOC_IRQ);
            return 0;
        }
        if ((sr & DMA_DMASR_ERR_MASK) != 0U) {
            debug_stage = 0xe0000000U | sr_off;
            debug_value = sr;
            xil_printf("%s DMA error, dmasr=0x%08lx\r\n", name, (unsigned long)sr);
            return -1;
        }
    }
    xil_printf("%s DMA timeout, dmasr=0x%08lx\r\n",
               name, (unsigned long)rd32(base, sr_off));
    debug_stage = 0xe1000000U | sr_off;
    debug_value = rd32(base, sr_off);
    return -1;
}

static void dma_start_mm2s(uint32_t base, const void *buf, uint32_t bytes)
{
    UINTPTR addr = (UINTPTR)buf;
    Xil_DCacheFlushRange(addr, bytes);
    wr32(base, DMA_MM2S_DMACR, DMA_DMACR_RUNSTOP);
    wr32(base, DMA_MM2S_SA, (uint32_t)addr);
    wr32(base, DMA_MM2S_SA_MSB, (uint32_t)(addr >> 32));
    wr32(base, DMA_MM2S_LENGTH, bytes);
}

static void dma_start_s2mm(uint32_t base, void *buf, uint32_t bytes)
{
    UINTPTR addr = (UINTPTR)buf;
    Xil_DCacheFlushRange(addr, bytes);
    wr32(base, DMA_S2MM_DMACR, DMA_DMACR_RUNSTOP);
    wr32(base, DMA_S2MM_DA, (uint32_t)addr);
    wr32(base, DMA_S2MM_DA_MSB, (uint32_t)(addr >> 32));
    wr32(base, DMA_S2MM_LENGTH, bytes);
}

static int wait_gpio_deassert(uint32_t mask)
{
    for (uint32_t i = 0; i < 10000000U; ++i) {
        if ((rd32(GPIO_BASE_ADDR, GPIO2_DATA) & mask) == 0U) {
            return 0;
        }
    }
    xil_printf("GPIO request did not deassert, mask=0x%08lx status=0x%08lx\r\n",
               (unsigned long)mask, (unsigned long)rd32(GPIO_BASE_ADDR, GPIO2_DATA));
    return -1;
}

static int status_fill_fy(uint32_t status)
{
    return (int)((status & ST_FILL_FY_MASK) >> ST_FILL_FY_SHIFT);
}

static int wait_ifm_request_advance(uint32_t serviced_status)
{
    uint32_t serviced_fy = serviced_status & ST_FILL_FY_MASK;

    for (uint32_t i = 0; i < 10000000U; ++i) {
        uint32_t st = rd32(GPIO_BASE_ADDR, GPIO2_DATA);
        if ((st & ST_IFM_REQ) == 0U) {
            return 0;
        }
#if USE_GPIO_FILL_FY
        if ((st & ST_FILL_FY_MASK) != serviced_fy) {
            return 0;
        }
#endif
    }

    xil_printf("IFM request did not advance, serviced_fy=%d status=0x%08lx\r\n",
               status_fill_fy(serviced_status),
               (unsigned long)rd32(GPIO_BASE_ADDR, GPIO2_DATA));
    return -1;
}

#if ACCEL_SMOKE_EXTERNAL_GOLDEN
static uint32_t expected_ifm_services_for_tile(const smoke_tile_desc_t *tile)
{
    int first_fy = (int)tile->tile_oy_base * CONV_STRIDE - CONV_PAD;
    int last_fy = ((int)tile->tile_oy_base + (int)tile->tile_ofm_h - 1) * CONV_STRIDE +
                  (KH - 1) - CONV_PAD;

    if (first_fy < 0) {
        first_fy = 0;
    }
    if (last_fy >= FM_H) {
        last_fy = FM_H - 1;
    }
    if (last_fy < first_fy) {
        return 0U;
    }
    return (uint32_t)(last_fy - first_fy + 1) * K_PASSES * COUT_BLOCKS;
}
#endif

static int service_bias(int cout_base)
{
    pack_bias(cout_base);
    dma_start_mm2s(DMA_BIAS_BASE_ADDR, active_runtime.bias_buf, active_runtime.bias_bytes);
    if (dma_wait(DMA_BIAS_BASE_ADDR, DMA_MM2S_DMASR, "bias MM2S") != 0) {
        return -1;
    }
    return wait_gpio_deassert(ST_BIAS_REQ);
}

static int service_weight(int *next_k_pass, int *active_k_base, int cout_base)
{
    int k_base = (*next_k_pass) * ROWS;
    *active_k_base = k_base;
    pack_weight(k_base, cout_base);
    dma_start_mm2s(DMA_WEIGHT_BASE_ADDR, active_runtime.weight_buf, active_runtime.weight_bytes);
    if (dma_wait(DMA_WEIGHT_BASE_ADDR, DMA_MM2S_DMASR, "weight MM2S") != 0) {
        return -1;
    }
    *next_k_pass = (*next_k_pass + 1) % K_PASSES;
    return wait_gpio_deassert(ST_WEIGHT_REQ);
}

static int service_ifm(uint32_t status, int active_k_base, int *ifm_row_phase)
{
#if USE_GPIO_FILL_FY
    int fy = status_fill_fy(status);
#else
    /*
     * Old XSA compatibility path.
     *
     * The r18_c8 smoke tile computes oy=0..1 with pad=1/stride=1, so every
     * K pass needs physical IFM rows 0, 1, 2 in that order. The line scheduler
     * resets its line-valid state at each K pass, and COUT_BLOCKS is 1 here.
     */
    static const int smoke_fy_seq[3] = {0, 1, 2};
    int fy = smoke_fy_seq[*ifm_row_phase];
    *ifm_row_phase = (*ifm_row_phase + 1) % 3;
    (void)status;
#endif

    if (fy < 0 || fy >= FM_H) {
        xil_printf("Bad feeder fy=%d, status=0x%08lx\r\n", fy, (unsigned long)status);
        return -1;
    }

    pack_ifm_line(fy, active_k_base);
    dma_start_mm2s(DMA_IFM_BASE_ADDR, active_runtime.ifm_buf, active_runtime.ifm_bytes);
    if (dma_wait(DMA_IFM_BASE_ADDR, DMA_MM2S_DMASR, "ifm MM2S") != 0) {
        return -1;
    }
    return 0;
}

static void clear_ofm_mem(void)
{
    for (int i = 0; i < FULL_PIXELS * COUT_TOTAL; ++i) {
        ofm_mem[i] = 0xeeU;
    }
}

static int parse_ofm_tile(const smoke_tile_desc_t *tile)
{
    Xil_DCacheInvalidateRange((UINTPTR)ofm_axis_buf,
                              tile->expected_ofm_bytes * OFM_AXIS_BEAT_BYTES);
    for (uint32_t i = 0U; i < 8U && i < tile->expected_ofm_bytes; ++i) {
        uint64_t beat = ofm_axis_buf[i];
        uint32_t raw = (uint32_t)(beat & 0xffffffffULL);
        xil_printf("%s ofm raw[%lu]=hi=0x%08lx lo=0x%08lx addr=%lu data=%u\r\n",
                   tile->name,
                   (unsigned long)i,
                   (unsigned long)(uint32_t)(beat >> 32),
                   (unsigned long)raw,
                   (unsigned long)(raw & 0x00ffffffU),
                   (unsigned)((raw >> 24) & 0xffU));
    }
    uint32_t parsed = 0U;
    for (uint32_t i = 0U; i < tile->expected_ofm_bytes; ++i) {
        uint32_t raw = (uint32_t)(ofm_axis_buf[i] & 0xffffffffULL);
        uint32_t addr = raw & 0x00ffffffU;
        uint8_t data = (uint8_t)((raw >> 24) & 0xffU);
        if (addr >= (FULL_PIXELS * COUT_TOTAL)) {
            xil_printf("Bad OFM packet %s index=%lu addr=%lu data=%u\r\n",
                       tile->name, (unsigned long)i, (unsigned long)addr, data);
            return -1;
        }
        ofm_mem[addr] = data;
        ++parsed;
    }
    xil_printf("%s ofm parsed=%lu expected=%lu\r\n",
               tile->name, (unsigned long)parsed, (unsigned long)tile->expected_ofm_bytes);
    return 0;
}

static int compare_ofm(void)
{
    for (int idx = 0; idx < TOTAL_OUTPUT_PIXELS; ++idx) {
        for (int co = 0; co < COUT_TOTAL; ++co) {
            uint8_t got = ofm_mem[idx * COUT_TOTAL + co];
#if ACCEL_SMOKE_EXTERNAL_GOLDEN
            uint8_t exp = active_layer.golden_ofm_u8[idx * COUT_TOTAL + co];
#else
            uint8_t exp = clamp8(golden[idx][co]);
#endif
            if (got != exp) {
                xil_printf("Mismatch pixel=%d cout=%d got=%u exp=%u raw=%ld\r\n",
                           idx, co, got, exp,
#if ACCEL_SMOKE_EXTERNAL_GOLDEN
                           (long)exp);
#else
                           (long)golden[idx][co]);
#endif
                return -1;
            }
        }
    }
    xil_printf("ofm full compare=%lu bytes\r\n", (unsigned long)TOTAL_EXPECTED_OFM_BYTES);
    return 0;
}

static int run_one_tile(const smoke_tile_desc_t *tile, uint32_t tile_index,
                        int *total_bias_services, int *total_weight_services,
                        int *total_ifm_services)
{
    int k_pass = 0;
    int active_k_base = 0;
    int bias_services = 0;
    int weight_services = 0;
    int ifm_services = 0;
    int ifm_row_phase = 0;
    int done_seen = 0;
    uint32_t dbg_core_base;
    uint32_t dbg_axis_base;
    uint32_t dbg_tlast_base;
    uint32_t dbg_last_base;
    uint32_t dbg_core_now;
    uint32_t dbg_axis_now;
    uint32_t dbg_tlast_now;
    uint32_t dbg_last_now;
    uint32_t dbg_core_delta;
    uint32_t dbg_axis_delta;
    uint32_t dbg_tlast_delta;
    uint32_t dbg_last_delta;

    debug_stage = 0x30000000U | tile_index;
    xil_printf("tile[%lu] %s config oy=%lu h=%lu pixel_base=%lu pixels=%lu expected=%lu\r\n",
               (unsigned long)tile_index,
               tile->name,
               (unsigned long)tile->tile_oy_base,
               (unsigned long)tile->tile_ofm_h,
               (unsigned long)tile->tile_pixel_base,
               (unsigned long)tile->tile_pixels,
               (unsigned long)tile->expected_ofm_bytes);

    wr32(ACCEL_BASE_ADDR, ACCEL_NUM_PIXELS, tile->tile_pixels);
    wr32(ACCEL_BASE_ADDR, ACCEL_TILE_ROWS, (tile->tile_ofm_h << 16) | tile->tile_oy_base);
    wr32(ACCEL_BASE_ADDR, ACCEL_PIXEL_BASE, tile->tile_pixel_base);
    wr32(ACCEL_BASE_ADDR, ACCEL_EXPECTED_BYTES, tile->expected_ofm_bytes);
    xil_printf("tile[%lu] cfg readback: cout=%lu pixels=%lu tile_rows=0x%08lx pixel_base=%lu expected=%lu\r\n",
               (unsigned long)tile_index,
               (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_COUT_TOTAL),
               (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_NUM_PIXELS),
               (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_TILE_ROWS),
               (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_PIXEL_BASE),
               (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_EXPECTED_BYTES));

    dbg_core_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_CORE_WR);
    dbg_axis_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_AXIS_WR);
    dbg_tlast_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_TLASTS);
    dbg_last_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_LAST_END);

    dma_start_s2mm(DMA_OFM_BASE_ADDR, active_runtime.ofm_axis_buf,
                   tile->expected_ofm_bytes * OFM_AXIS_BEAT_BYTES);
    xil_printf("tile[%lu] stage: start accel\r\n", (unsigned long)tile_index);
    wr32(ACCEL_BASE_ADDR, ACCEL_CTRL, 1U);

    for (uint32_t loops = 0; loops < 50000000U; ++loops) {
        uint32_t ctrl = rd32(ACCEL_BASE_ADDR, ACCEL_CTRL);
        uint32_t st = rd32(GPIO_BASE_ADDR, GPIO2_DATA);
        debug_value = st;

        if ((st & ST_ERROR_MASK) != 0U) {
            debug_stage = 0xe2000000U;
            xil_printf("AXIS protocol error, gpio2=0x%08lx\r\n", (unsigned long)st);
            return -1;
        }

        if ((st & ST_BIAS_REQ) != 0U) {
            int cout_base = (bias_services % COUT_BLOCKS) * COUT_TILE;
            debug_stage = 0x41000000U | (tile_index << 12) | (uint32_t)bias_services;
            xil_printf("tile[%lu] service: bias %d cout_base=%d\r\n",
                       (unsigned long)tile_index, bias_services, cout_base);
            if (service_bias(cout_base) != 0) {
                return -1;
            }
            ++bias_services;
            continue;
        }

        if ((st & ST_WEIGHT_REQ) != 0U) {
            int cout_base = ((weight_services / K_PASSES) % COUT_BLOCKS) * COUT_TILE;
            debug_stage = 0x42000000U | (tile_index << 12) | (uint32_t)weight_services;
#if ACCEL_SMOKE_LAYER06_TILES || ACCEL_SMOKE_LAYER06_POOL_TILES || ACCEL_SMOKE_CONV4_POOL_TILES
            if ((weight_services % K_PASSES) == 0) {
                xil_printf("tile[%lu] service: weight block=%d cout_base=%d\r\n",
                           (unsigned long)tile_index, weight_services / K_PASSES, cout_base);
            }
#else
            xil_printf("tile[%lu] service: weight %d cout_base=%d k_base=%d\r\n",
                       (unsigned long)tile_index, weight_services, cout_base, k_pass * ROWS);
#endif
            if (service_weight(&k_pass, &active_k_base, cout_base) != 0) {
                return -1;
            }
            ++weight_services;
            continue;
        }

        if ((st & ST_IFM_REQ) != 0U) {
            debug_stage = 0x43000000U | (tile_index << 12) | (uint32_t)ifm_services;
#if ACCEL_SMOKE_LAYER06_TILES || ACCEL_SMOKE_LAYER06_POOL_TILES || ACCEL_SMOKE_CONV4_POOL_TILES
            if ((ifm_services % (K_PASSES * 5)) == 0) {
                xil_printf("tile[%lu] service: ifm progress=%d fy=%d k_base=%d status=0x%08lx\r\n",
                           (unsigned long)tile_index, ifm_services, status_fill_fy(st),
                           active_k_base, (unsigned long)st);
            }
#else
            xil_printf("tile[%lu] service: ifm %d fy=%d k_base=%d status=0x%08lx\r\n",
                       (unsigned long)tile_index, ifm_services, status_fill_fy(st),
                       active_k_base, (unsigned long)st);
#endif
            if (service_ifm(st, active_k_base, &ifm_row_phase) != 0) {
                return -1;
            }
            if (wait_ifm_request_advance(st) != 0) {
                return -1;
            }
            ++ifm_services;
            continue;
        }

        if (((ctrl & 0x2U) != 0U) && ((ctrl & 0x1U) == 0U)) {
            done_seen = 1;
            break;
        }
    }

    if (!done_seen) {
        debug_stage = 0xe3000000U;
        xil_printf("Accelerator timeout tile=%lu ctrl=0x%08lx gpio2=0x%08lx\r\n",
                   (unsigned long)tile_index,
                   (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_CTRL),
                   (unsigned long)rd32(GPIO_BASE_ADDR, GPIO2_DATA));
        return -1;
    }

    if (dma_wait(DMA_OFM_BASE_ADDR, DMA_S2MM_DMASR, "ofm S2MM") != 0) {
        return -1;
    }
    dbg_core_now = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_CORE_WR);
    dbg_axis_now = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_AXIS_WR);
    dbg_tlast_now = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_TLASTS);
    dbg_last_now = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_LAST_END);
    dbg_core_delta = dbg_core_now - dbg_core_base;
    dbg_axis_delta = dbg_axis_now - dbg_axis_base;
    dbg_tlast_delta = dbg_tlast_now - dbg_tlast_base;
    dbg_last_delta = dbg_last_now - dbg_last_base;

    xil_printf("tile[%lu] ofm debug: expected=%lu core_wr=%lu axis_wr=%lu tlast=%lu last_end=%lu\r\n",
               (unsigned long)tile_index,
               (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_DBG_EXPECTED),
               (unsigned long)dbg_core_now,
               (unsigned long)dbg_axis_now,
               (unsigned long)dbg_tlast_now,
               (unsigned long)dbg_last_now);
    xil_printf("tile[%lu] ofm debug delta: core_wr=%lu axis_wr=%lu tlast=%lu last_end=%lu\r\n",
               (unsigned long)tile_index,
               (unsigned long)dbg_core_delta,
               (unsigned long)dbg_axis_delta,
               (unsigned long)dbg_tlast_delta,
               (unsigned long)dbg_last_delta);
    if (dbg_core_delta != tile->expected_ofm_bytes ||
        dbg_axis_delta != tile->expected_ofm_bytes ||
        dbg_tlast_delta != 1U ||
        dbg_last_delta != tile->expected_ofm_bytes) {
        xil_printf("Unexpected OFM debug delta\r\n");
        debug_stage = 0xe6000000U;
        debug_value = dbg_axis_delta;
        return -1;
    }
    debug_stage = 0x50000000U;
    wr32(ACCEL_BASE_ADDR, ACCEL_CTRL, 2U);

    xil_printf("tile[%lu] services: bias=%d weight=%d ifm=%d\r\n",
               (unsigned long)tile_index, bias_services, weight_services, ifm_services);
    if (bias_services != COUT_BLOCKS || weight_services != (COUT_BLOCKS * K_PASSES) ||
        ifm_services <= 0) {
        xil_printf("Unexpected service counts\r\n");
        debug_stage = 0xe4000000U;
        debug_value = ((uint32_t)bias_services << 24) |
                      ((uint32_t)weight_services << 12) |
                      (uint32_t)ifm_services;
        return -1;
    }
#if ACCEL_SMOKE_EXTERNAL_GOLDEN
    uint32_t expected_ifm_services = expected_ifm_services_for_tile(tile);
    if ((uint32_t)ifm_services != expected_ifm_services) {
        xil_printf("Unexpected IFM service count got=%d exp=%lu\r\n",
                   ifm_services, (unsigned long)expected_ifm_services);
        debug_stage = 0xe7000000U;
        debug_value = (uint32_t)ifm_services;
        return -1;
    }
#endif

    *total_bias_services += bias_services;
    *total_weight_services += weight_services;
    *total_ifm_services += ifm_services;

    return parse_ofm_tile(tile);
}

static int run_smoke(void)
{
    int total_bias_services = 0;
    int total_weight_services = 0;
    int total_ifm_services = 0;
    uint32_t initial_ctrl = rd32(ACCEL_BASE_ADDR, ACCEL_CTRL);

    if ((initial_ctrl & 0x1U) != 0U) {
        xil_printf("FAIL: accelerator busy before configuration ctrl=0x%08lx; reprogram bitstream or reset PL\r\n",
                   (unsigned long)initial_ctrl);
        debug_stage = 0xef000000U;
        debug_value = initial_ctrl;
        return -1;
    }
    wr32(ACCEL_BASE_ADDR, ACCEL_CTRL, 2U);

    debug_stage = 0x10000000U;
    xil_printf("stage: dma reset\r\n");
    dma_reset_named("bias", DMA_BIAS_BASE_ADDR, DMA_MM2S_DMACR, DMA_MM2S_DMASR);
    dma_reset_named("weight", DMA_WEIGHT_BASE_ADDR, DMA_MM2S_DMACR, DMA_MM2S_DMASR);
    dma_reset_named("ifm", DMA_IFM_BASE_ADDR, DMA_MM2S_DMACR, DMA_MM2S_DMASR);
    dma_reset_named("ofm", DMA_OFM_BASE_ADDR, DMA_S2MM_DMACR, DMA_S2MM_DMASR);
    xil_printf("stage: dma reset done\r\n");

    wr32(GPIO_BASE_ADDR, GPIO_TRI, 0x00000000U);
    wr32(GPIO_BASE_ADDR, GPIO2_TRI, 0x0000ffffU);
    wr32(GPIO_BASE_ADDR, GPIO_DATA, FM_W);

    debug_stage = 0x20000000U;
    xil_printf("stage: config common regs\r\n");
    wr32(ACCEL_BASE_ADDR, ACCEL_FM_SIZE, (active_layer.fm_w << 16) | active_layer.fm_h);
    wr32(ACCEL_BASE_ADDR, ACCEL_OFM_SIZE, (active_layer.ofm_w << 16) | active_layer.ofm_h);
    wr32(ACCEL_BASE_ADDR, ACCEL_CONV, (active_layer.conv_pad << 8) | active_layer.conv_stride);
    wr32(ACCEL_BASE_ADDR, ACCEL_K_TOTAL, active_layer.k_total);
    wr32(ACCEL_BASE_ADDR, ACCEL_COUT_TOTAL, active_layer.cout_total);
    wr32(ACCEL_BASE_ADDR, ACCEL_ACT_CFG, active_layer.act_mode);
    wr32(ACCEL_BASE_ADDR, ACCEL_IFM_ZP, active_layer.input_zero_point);
    wr32(ACCEL_BASE_ADDR, ACCEL_POOL_CFG, (active_layer.pool_stride << 2) | active_layer.pool_enable);
    if (program_quant_tile(active_layer.quant_mult, active_layer.quant_shift, active_layer.quant_zp) != 0) {
        return -1;
    }
    if (program_activation_lut(active_layer.activation_lut) != 0) {
        return -1;
    }

    clear_ofm_mem();
    for (uint32_t tile_idx = 0U; tile_idx < SMOKE_TILE_COUNT; ++tile_idx) {
        if (run_one_tile(&smoke_tiles[tile_idx], tile_idx,
                         &total_bias_services,
                         &total_weight_services,
                         &total_ifm_services) != 0) {
            debug_stage = 0xe5000000U | tile_idx;
            return -1;
        }
    }

    xil_printf("total services: bias=%d weight=%d ifm=%d\r\n",
               total_bias_services, total_weight_services, total_ifm_services);
#if ACCEL_SMOKE_EXTERNAL_GOLDEN
    uint32_t expected_total_ifm_services = 0U;
    for (uint32_t tile_idx = 0U; tile_idx < SMOKE_TILE_COUNT; ++tile_idx) {
        expected_total_ifm_services += expected_ifm_services_for_tile(&smoke_tiles[tile_idx]);
    }
    if (total_bias_services != (SMOKE_TILE_COUNT * COUT_BLOCKS) ||
        total_weight_services != (SMOKE_TILE_COUNT * COUT_BLOCKS * K_PASSES) ||
        (uint32_t)total_ifm_services != expected_total_ifm_services) {
        xil_printf("Unexpected total service counts\r\n");
        debug_stage = 0xe8000000U;
        debug_value = ((uint32_t)total_bias_services << 24) |
                      ((uint32_t)total_weight_services << 12) |
                      (uint32_t)total_ifm_services;
        return -1;
    }
#endif

    int rc = compare_ofm();
    debug_stage = (rc == 0) ? 0x60000000U : 0xe5000000U;
    return rc;
}

int main(void)
{
    debug_stage = 0x01000000U;
    xil_printf("\r\n%s AXI DMA smoke test\r\n", SMOKE_NAME);
    xil_printf("FM=%dx%d Cin=%d Cout=%d tile_h=%d expected_ofm=%d bytes\r\n",
               FM_W, FM_H, CIN, COUT_TOTAL, TILE_OFM_H, EXPECTED_OFM_BYTES);
    xil_printf("single-scale plan: layers=%lu first=%s last=%s cout_tile=%lu\r\n",
               (unsigned long)ACCEL_SINGLE_SCALE_LAYER_COUNT,
               accel_single_scale_plan[0].name,
               accel_single_scale_plan[ACCEL_SINGLE_SCALE_LAYER_COUNT - 1U].name,
               (unsigned long)ACCEL_SINGLE_SCALE_COUT_TILE);
    if (run_single_scale_scheduler_dry_run() != 0) {
        xil_printf("FAIL: single-scale scheduler dry-run failed\r\n");
        return -1;
    }

    make_vectors();
    debug_stage = 0x02000000U;
    int rc = run_smoke();
    if (rc == 0) {
        xil_printf("PASS: %s smoke matches RTL golden\r\n", SMOKE_NAME);
    } else {
        xil_printf("FAIL: %s smoke failed\r\n", SMOKE_NAME);
    }

    return rc;
}

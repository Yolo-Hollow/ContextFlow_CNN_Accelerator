#include "accel_smoke.h"
#include "layer06_tile4_data.h"
#include "conv4_pool_data.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_types.h"

#define UART0_BASE            0xFF000000U
#define UART1_BASE            0xFF010000U
#define UART_SR_OFFSET        0x2CU
#define UART_FIFO_OFFSET      0x30U
#define UART_SR_TXFULL        0x10U

#define CHAIN_ROWS            18U
#define CHAIN_COLS            8U
#define CHAIN_IFM_BANKS       2U
#define CHAIN_COUT_TILE       (CHAIN_COLS * 2U)
#define CHAIN_KH              3U
#define CHAIN_KW              3U

#define MAX_FM_W              52U
#define MAX_COUT_TOTAL        256U
#define MAX_OFM_BYTES         (26U * 26U * 128U)
#define MAX_TILE_OFM_BYTES    (13U * 2U * 256U)

typedef struct {
    const char *name;
    uint32_t tile_oy_base;
    uint32_t tile_ofm_h;
    uint32_t tile_pixel_base;
    uint32_t tile_pixels;
    uint32_t expected_ofm_bytes;
} chain_tile_t;

typedef struct {
    const char *name;
    uint32_t fm_w;
    uint32_t fm_h;
    uint32_t ofm_w;
    uint32_t ofm_h;
    uint32_t cin;
    uint32_t cout_total;
    uint32_t k_total;
    uint32_t k_passes;
    uint32_t cout_blocks;
    uint32_t input_zero_point;
    uint32_t quant_mult;
    uint32_t quant_shift;
    uint32_t quant_zp;
    uint32_t total_output_pixels;
    uint32_t total_expected_ofm_bytes;
    const uint8_t *ifm_u8;
    const int8_t *weight_s8;
    const int32_t *bias_i32;
    const uint8_t *activation_lut_u8;
    const uint8_t *golden_ofm_u8;
    uint8_t *ofm_u8;
    const chain_tile_t *tiles;
    uint32_t tile_count;
} chain_layer_t;

static uint64_t bias_buf[CHAIN_COUT_TILE / 2U] __attribute__((aligned(64)));
static uint64_t weight_buf[(CHAIN_ROWS * CHAIN_COUT_TILE) / 8U] __attribute__((aligned(64)));
static uint64_t ifm_buf[MAX_FM_W] __attribute__((aligned(64)));
static uint64_t ofm_axis_buf[MAX_TILE_OFM_BYTES] __attribute__((aligned(64)));
static uint8_t conv3_ofm[26U * 26U * 128U] __attribute__((aligned(64)));
static uint8_t conv4_ofm[13U * 13U * 256U] __attribute__((aligned(64)));
volatile uint32_t debug_stage = 0;
volatile uint32_t debug_value = 0;

static const chain_tile_t conv3_tiles[13] = {
    {"conv3_tile0", 0U, 4U, 0U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile1", 4U, 4U, 1U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile2", 8U, 4U, 2U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile3", 12U, 4U, 3U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile4", 16U, 4U, 4U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile5", 20U, 4U, 5U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile6", 24U, 4U, 6U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile7", 28U, 4U, 7U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile8", 32U, 4U, 8U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile9", 36U, 4U, 9U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile10", 40U, 4U, 10U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile11", 44U, 4U, 11U * 52U, 52U * 4U, 26U * 2U * 128U},
    {"conv3_tile12", 48U, 4U, 12U * 52U, 52U * 4U, 26U * 2U * 128U},
};

static const chain_tile_t conv4_tiles[7] = {
    {"conv4_tile0", 0U, 4U, 0U * 26U, 26U * 4U, 13U * 2U * 256U},
    {"conv4_tile1", 4U, 4U, 1U * 26U, 26U * 4U, 13U * 2U * 256U},
    {"conv4_tile2", 8U, 4U, 2U * 26U, 26U * 4U, 13U * 2U * 256U},
    {"conv4_tile3", 12U, 4U, 3U * 26U, 26U * 4U, 13U * 2U * 256U},
    {"conv4_tile4", 16U, 4U, 4U * 26U, 26U * 4U, 13U * 2U * 256U},
    {"conv4_tile5", 20U, 4U, 5U * 26U, 26U * 4U, 13U * 2U * 256U},
    {"conv4_tile6", 24U, 2U, 6U * 26U, 26U * 2U, 13U * 1U * 256U},
};

static chain_layer_t conv3_layer = {
    "conv3_pool",
    52U, 52U, 52U, 52U,
    64U, 128U, 64U * 9U, 32U, 8U,
    36U, 18055U, 7U, 75U,
    26U * 26U, 26U * 26U * 128U,
    layer06_tile4_ifm_u8,
    layer06_tile4_weight_s8,
    layer06_tile4_bias_i32,
    layer06_tile4_activation_lut_u8,
    layer06_pool_golden_ofm_u8,
    conv3_ofm,
    conv3_tiles,
    13U,
};

static chain_layer_t conv4_layer = {
    "conv4_pool",
    26U, 26U, 26U, 26U,
    128U, 256U, 128U * 9U, 64U, 16U,
    16U, 18831U, 7U, 73U,
    13U * 13U, 13U * 13U * 256U,
    conv3_ofm,
    conv4_pool_weight_s8,
    conv4_pool_bias_i32,
    conv4_pool_activation_lut_u8,
    conv4_pool_golden_ofm_u8,
    conv4_ofm,
    conv4_tiles,
    7U,
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

static int program_quant_tile(const chain_layer_t *layer)
{
    uint32_t packed = ACCEL_QUANT_PACK(layer->quant_mult, layer->quant_shift, layer->quant_zp);
    for (uint32_t lane = 0U; lane < CHAIN_COUT_TILE; ++lane) {
        accel_write_reg(ACCEL_QUANT_ADDR, lane);
        accel_write_reg(ACCEL_QUANT_DATA, packed);
        if (accel_read_reg(ACCEL_QUANT_DATA) != packed) {
            xil_printf("%s quant readback mismatch lane=%lu\r\n", layer->name, (unsigned long)lane);
            return -1;
        }
    }
    return 0;
}

static int program_activation_lut(const chain_layer_t *layer)
{
    for (uint32_t idx = 0U; idx < 256U; ++idx) {
        uint32_t data = layer->activation_lut_u8[idx];
        accel_write_reg(ACCEL_LUT_ADDR, idx);
        accel_write_reg(ACCEL_LUT_DATA, data);
        if ((accel_read_reg(ACCEL_LUT_DATA) & 0xffU) != data) {
            xil_printf("%s lut readback mismatch idx=%lu\r\n", layer->name, (unsigned long)idx);
            return -1;
        }
    }
    return 0;
}

static int pass_needs_ch(const chain_layer_t *layer, uint32_t k_base, uint32_t ch)
{
    return (ch < layer->cin) && (k_base < (ch + 1U) * 9U) && ((k_base + CHAIN_ROWS) > ch * 9U);
}

static int channel_for_bank(const chain_layer_t *layer, uint32_t k_base, uint32_t bank)
{
    for (uint32_t ch = 0U; ch < layer->cin; ++ch) {
        if (pass_needs_ch(layer, k_base, ch) && ((ch % CHAIN_IFM_BANKS) == bank)) {
            return (int)ch;
        }
    }
    return -1;
}

static void pack_bias(const chain_layer_t *layer, uint32_t cout_base)
{
    for (uint32_t i = 0U; i < CHAIN_COUT_TILE; i += 2U) {
        uint32_t lo_co = cout_base + i;
        uint32_t hi_co = cout_base + i + 1U;
        uint32_t lo = (lo_co < layer->cout_total) ? (uint32_t)layer->bias_i32[lo_co] : 0U;
        uint32_t hi = (hi_co < layer->cout_total) ? (uint32_t)layer->bias_i32[hi_co] : 0U;
        bias_buf[i / 2U] = ((uint64_t)hi << 32) | lo;
    }
}

static void pack_weight(const chain_layer_t *layer, uint32_t k_base, uint32_t cout_base)
{
    uint32_t lane = 0U;
    uint64_t word = 0U;
    uint32_t out = 0U;
    for (uint32_t kk = 0U; kk < CHAIN_ROWS; ++kk) {
        for (uint32_t cc = 0U; cc < CHAIN_COUT_TILE; ++cc) {
            uint32_t gk = k_base + kk;
            uint32_t co = cout_base + cc;
            uint8_t v = 0U;
            if (gk < layer->k_total && co < layer->cout_total) {
                v = (uint8_t)layer->weight_s8[gk * layer->cout_total + co];
            }
            word |= ((uint64_t)v) << (lane * 8U);
            if (lane == 7U) {
                weight_buf[out++] = word;
                word = 0U;
                lane = 0U;
            } else {
                ++lane;
            }
        }
    }
}

static void pack_ifm_line(const chain_layer_t *layer, int fy, uint32_t k_base)
{
    for (uint32_t x = 0U; x < layer->fm_w; ++x) {
        uint64_t word = 0U;
        for (uint32_t b = 0U; b < CHAIN_IFM_BANKS; ++b) {
            int ch = channel_for_bank(layer, k_base, b);
            uint8_t v = (ch >= 0) ? layer->ifm_u8[((uint32_t)fy * layer->fm_w + x) * layer->cin + (uint32_t)ch] : 0U;
            word |= ((uint64_t)v) << (b * 8U);
        }
        ifm_buf[x] = word;
    }
}

static void dma_reset_named(const char *name, uint32_t base, uint32_t cr_off, uint32_t sr_off)
{
    xil_printf("dma reset: %s\r\n", name);
    wr32(base, cr_off, DMA_DMACR_RESET);
    for (uint32_t i = 0U; i < 1000000U; ++i) {
        if ((rd32(base, cr_off) & DMA_DMACR_RESET) == 0U) {
            break;
        }
    }
    wr32(base, sr_off, 0x00007000U);
}

static void dma_reset_all(void)
{
    dma_reset_named("bias", DMA_BIAS_BASE_ADDR, DMA_MM2S_DMACR, DMA_MM2S_DMASR);
    dma_reset_named("weight", DMA_WEIGHT_BASE_ADDR, DMA_MM2S_DMACR, DMA_MM2S_DMASR);
    dma_reset_named("ifm", DMA_IFM_BASE_ADDR, DMA_MM2S_DMACR, DMA_MM2S_DMASR);
    dma_reset_named("ofm", DMA_OFM_BASE_ADDR, DMA_S2MM_DMACR, DMA_S2MM_DMASR);
}

static int dma_wait(uint32_t base, uint32_t sr_off, const char *name)
{
    for (uint32_t i = 0U; i < 50000000U; ++i) {
        uint32_t sr = rd32(base, sr_off);
        if ((sr & DMA_DMASR_IOC_IRQ) != 0U) {
            wr32(base, sr_off, DMA_DMASR_IOC_IRQ);
            return 0;
        }
        if ((sr & DMA_DMASR_ERR_MASK) != 0U) {
            xil_printf("%s DMA error dmasr=0x%08lx\r\n", name, (unsigned long)sr);
            return -1;
        }
    }
    xil_printf("%s DMA timeout dmasr=0x%08lx\r\n", name, (unsigned long)rd32(base, sr_off));
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

static int status_fill_fy(uint32_t status)
{
    return (int)((status & ST_FILL_FY_MASK) >> ST_FILL_FY_SHIFT);
}

static int wait_gpio_deassert(uint32_t mask)
{
    for (uint32_t i = 0U; i < 10000000U; ++i) {
        if ((rd32(GPIO_BASE_ADDR, GPIO2_DATA) & mask) == 0U) {
            return 0;
        }
    }
    xil_printf("GPIO request did not deassert mask=0x%08lx status=0x%08lx\r\n",
               (unsigned long)mask, (unsigned long)rd32(GPIO_BASE_ADDR, GPIO2_DATA));
    return -1;
}

static int wait_ifm_request_advance(uint32_t serviced_status)
{
    uint32_t serviced_fy = serviced_status & ST_FILL_FY_MASK;
    for (uint32_t i = 0U; i < 10000000U; ++i) {
        uint32_t st = rd32(GPIO_BASE_ADDR, GPIO2_DATA);
        if ((st & ST_IFM_REQ) == 0U) {
            return 0;
        }
        if ((st & ST_FILL_FY_MASK) != serviced_fy) {
            return 0;
        }
    }
    xil_printf("IFM request did not advance fy=%d status=0x%08lx\r\n",
               status_fill_fy(serviced_status), (unsigned long)rd32(GPIO_BASE_ADDR, GPIO2_DATA));
    return -1;
}

static uint32_t expected_ifm_services_for_tile(const chain_layer_t *layer, const chain_tile_t *tile)
{
    int first_fy = (int)tile->tile_oy_base - 1;
    int last_fy = (int)tile->tile_oy_base + (int)tile->tile_ofm_h;
    if (first_fy < 0) {
        first_fy = 0;
    }
    if (last_fy >= (int)layer->fm_h) {
        last_fy = (int)layer->fm_h - 1;
    }
    if (last_fy < first_fy) {
        return 0U;
    }
    return (uint32_t)(last_fy - first_fy + 1) * layer->k_passes * layer->cout_blocks;
}

static int service_bias(const chain_layer_t *layer, uint32_t cout_base)
{
    pack_bias(layer, cout_base);
    dma_start_mm2s(DMA_BIAS_BASE_ADDR, bias_buf, sizeof(bias_buf));
    if (dma_wait(DMA_BIAS_BASE_ADDR, DMA_MM2S_DMASR, "bias MM2S") != 0) {
        return -1;
    }
    return wait_gpio_deassert(ST_BIAS_REQ);
}

static int service_weight(const chain_layer_t *layer, uint32_t *next_k_pass, uint32_t *active_k_base, uint32_t cout_base)
{
    uint32_t k_base = (*next_k_pass) * CHAIN_ROWS;
    *active_k_base = k_base;
    pack_weight(layer, k_base, cout_base);
    dma_start_mm2s(DMA_WEIGHT_BASE_ADDR, weight_buf, sizeof(weight_buf));
    if (dma_wait(DMA_WEIGHT_BASE_ADDR, DMA_MM2S_DMASR, "weight MM2S") != 0) {
        return -1;
    }
    *next_k_pass = (*next_k_pass + 1U) % layer->k_passes;
    return wait_gpio_deassert(ST_WEIGHT_REQ);
}

static int service_ifm(const chain_layer_t *layer, uint32_t status, uint32_t active_k_base)
{
    int fy = status_fill_fy(status);
    if (fy < 0 || fy >= (int)layer->fm_h) {
        xil_printf("%s bad feeder fy=%d status=0x%08lx\r\n", layer->name, fy, (unsigned long)status);
        return -1;
    }
    pack_ifm_line(layer, fy, active_k_base);
    dma_start_mm2s(DMA_IFM_BASE_ADDR, ifm_buf, layer->fm_w * sizeof(ifm_buf[0]));
    if (dma_wait(DMA_IFM_BASE_ADDR, DMA_MM2S_DMASR, "ifm MM2S") != 0) {
        return -1;
    }
    return 0;
}

static void clear_ofm(uint8_t *ofm, uint32_t bytes)
{
    for (uint32_t i = 0U; i < bytes; ++i) {
        ofm[i] = 0xeeU;
    }
}

static int parse_ofm_tile(const chain_layer_t *layer, const chain_tile_t *tile)
{
    Xil_DCacheInvalidateRange((UINTPTR)ofm_axis_buf, tile->expected_ofm_bytes * OFM_AXIS_BEAT_BYTES);
    for (uint32_t i = 0U; i < 4U && i < tile->expected_ofm_bytes; ++i) {
        uint32_t raw = (uint32_t)(ofm_axis_buf[i] & 0xffffffffULL);
        xil_printf("%s raw[%lu] addr=%lu data=%u\r\n",
                   tile->name, (unsigned long)i,
                   (unsigned long)(raw & 0x00ffffffU),
                   (unsigned)((raw >> 24) & 0xffU));
    }
    for (uint32_t i = 0U; i < tile->expected_ofm_bytes; ++i) {
        uint32_t raw = (uint32_t)(ofm_axis_buf[i] & 0xffffffffULL);
        uint32_t addr = raw & 0x00ffffffU;
        uint8_t data = (uint8_t)((raw >> 24) & 0xffU);
        if (addr >= layer->total_expected_ofm_bytes) {
            xil_printf("%s bad OFM packet index=%lu addr=%lu data=%u\r\n",
                       tile->name, (unsigned long)i, (unsigned long)addr, data);
            return -1;
        }
        layer->ofm_u8[addr] = data;
    }
    xil_printf("%s ofm parsed=%lu expected=%lu\r\n",
               tile->name, (unsigned long)tile->expected_ofm_bytes,
               (unsigned long)tile->expected_ofm_bytes);
    return 0;
}

static int compare_layer_ofm(const chain_layer_t *layer)
{
    for (uint32_t i = 0U; i < layer->total_expected_ofm_bytes; ++i) {
        if (layer->ofm_u8[i] != layer->golden_ofm_u8[i]) {
            xil_printf("%s mismatch byte=%lu got=%u exp=%u\r\n",
                       layer->name, (unsigned long)i,
                       (unsigned)layer->ofm_u8[i], (unsigned)layer->golden_ofm_u8[i]);
            return -1;
        }
    }
    xil_printf("%s full compare=%lu bytes\r\n",
               layer->name, (unsigned long)layer->total_expected_ofm_bytes);
    return 0;
}

static int run_one_tile(const chain_layer_t *layer, const chain_tile_t *tile, uint32_t tile_index,
                        uint32_t *total_bias, uint32_t *total_weight, uint32_t *total_ifm)
{
    uint32_t k_pass = 0U;
    uint32_t active_k_base = 0U;
    uint32_t bias_services = 0U;
    uint32_t weight_services = 0U;
    uint32_t ifm_services = 0U;
    uint32_t dbg_core_base;
    uint32_t dbg_axis_base;
    uint32_t dbg_tlast_base;
    uint32_t dbg_last_base;

    xil_printf("%s tile[%lu] oy=%lu h=%lu pixel_base=%lu expected=%lu\r\n",
               layer->name, (unsigned long)tile_index,
               (unsigned long)tile->tile_oy_base, (unsigned long)tile->tile_ofm_h,
               (unsigned long)tile->tile_pixel_base, (unsigned long)tile->expected_ofm_bytes);

    wr32(ACCEL_BASE_ADDR, ACCEL_NUM_PIXELS, tile->tile_pixels);
    wr32(ACCEL_BASE_ADDR, ACCEL_TILE_ROWS, (tile->tile_ofm_h << 16) | tile->tile_oy_base);
    wr32(ACCEL_BASE_ADDR, ACCEL_PIXEL_BASE, tile->tile_pixel_base);
    wr32(ACCEL_BASE_ADDR, ACCEL_EXPECTED_BYTES, tile->expected_ofm_bytes);

    dbg_core_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_CORE_WR);
    dbg_axis_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_AXIS_WR);
    dbg_tlast_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_TLASTS);
    dbg_last_base = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_LAST_END);

    dma_start_s2mm(DMA_OFM_BASE_ADDR, ofm_axis_buf, tile->expected_ofm_bytes * OFM_AXIS_BEAT_BYTES);
    wr32(ACCEL_BASE_ADDR, ACCEL_CTRL, 1U);

    int done_seen = 0;
    for (uint32_t loops = 0U; loops < 80000000U; ++loops) {
        uint32_t ctrl = rd32(ACCEL_BASE_ADDR, ACCEL_CTRL);
        uint32_t st = rd32(GPIO_BASE_ADDR, GPIO2_DATA);
        debug_value = st;

        if ((st & ST_ERROR_MASK) != 0U) {
            xil_printf("%s AXIS protocol error gpio2=0x%08lx\r\n", layer->name, (unsigned long)st);
            return -1;
        }
        if ((st & ST_BIAS_REQ) != 0U) {
            uint32_t cout_base = (bias_services % layer->cout_blocks) * CHAIN_COUT_TILE;
            if (service_bias(layer, cout_base) != 0) {
                return -1;
            }
            ++bias_services;
            continue;
        }
        if ((st & ST_WEIGHT_REQ) != 0U) {
            uint32_t cout_base = ((weight_services / layer->k_passes) % layer->cout_blocks) * CHAIN_COUT_TILE;
            if ((weight_services % layer->k_passes) == 0U) {
                xil_printf("%s tile[%lu] weight block=%lu cout_base=%lu\r\n",
                           layer->name, (unsigned long)tile_index,
                           (unsigned long)(weight_services / layer->k_passes),
                           (unsigned long)cout_base);
            }
            if (service_weight(layer, &k_pass, &active_k_base, cout_base) != 0) {
                return -1;
            }
            ++weight_services;
            continue;
        }
        if ((st & ST_IFM_REQ) != 0U) {
            if ((ifm_services % (layer->k_passes * 5U)) == 0U) {
                xil_printf("%s tile[%lu] ifm progress=%lu fy=%d k_base=%lu\r\n",
                           layer->name, (unsigned long)tile_index,
                           (unsigned long)ifm_services, status_fill_fy(st),
                           (unsigned long)active_k_base);
            }
            if (service_ifm(layer, st, active_k_base) != 0) {
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
        xil_printf("%s accelerator timeout tile=%lu ctrl=0x%08lx gpio2=0x%08lx\r\n",
                   layer->name, (unsigned long)tile_index,
                   (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_CTRL),
                   (unsigned long)rd32(GPIO_BASE_ADDR, GPIO2_DATA));
        return -1;
    }
    if (dma_wait(DMA_OFM_BASE_ADDR, DMA_S2MM_DMASR, "ofm S2MM") != 0) {
        return -1;
    }

    uint32_t dbg_core_delta = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_CORE_WR) - dbg_core_base;
    uint32_t dbg_axis_delta = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_AXIS_WR) - dbg_axis_base;
    uint32_t dbg_tlast_delta = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_TLASTS) - dbg_tlast_base;
    uint32_t dbg_last_delta = rd32(ACCEL_BASE_ADDR, ACCEL_DBG_LAST_END) - dbg_last_base;
    xil_printf("%s tile[%lu] debug delta core=%lu axis=%lu tlast=%lu last=%lu\r\n",
               layer->name, (unsigned long)tile_index,
               (unsigned long)dbg_core_delta, (unsigned long)dbg_axis_delta,
               (unsigned long)dbg_tlast_delta, (unsigned long)dbg_last_delta);
    if (dbg_core_delta != tile->expected_ofm_bytes ||
        dbg_axis_delta != tile->expected_ofm_bytes ||
        dbg_tlast_delta != 1U ||
        dbg_last_delta != tile->expected_ofm_bytes) {
        xil_printf("%s unexpected OFM debug delta\r\n", layer->name);
        return -1;
    }

    wr32(ACCEL_BASE_ADDR, ACCEL_CTRL, 2U);
    xil_printf("%s tile[%lu] services bias=%lu weight=%lu ifm=%lu\r\n",
               layer->name, (unsigned long)tile_index,
               (unsigned long)bias_services, (unsigned long)weight_services,
               (unsigned long)ifm_services);

    uint32_t expected_ifm = expected_ifm_services_for_tile(layer, tile);
    if (bias_services != layer->cout_blocks ||
        weight_services != (layer->cout_blocks * layer->k_passes) ||
        ifm_services != expected_ifm) {
        xil_printf("%s unexpected service counts got b=%lu w=%lu i=%lu exp_i=%lu\r\n",
                   layer->name, (unsigned long)bias_services,
                   (unsigned long)weight_services, (unsigned long)ifm_services,
                   (unsigned long)expected_ifm);
        return -1;
    }

    *total_bias += bias_services;
    *total_weight += weight_services;
    *total_ifm += ifm_services;
    return parse_ofm_tile(layer, tile);
}

static int configure_layer(const chain_layer_t *layer)
{
    if ((rd32(ACCEL_BASE_ADDR, ACCEL_CTRL) & 0x1U) != 0U) {
        xil_printf("%s accelerator busy before config ctrl=0x%08lx\r\n",
                   layer->name, (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_CTRL));
        return -1;
    }
    wr32(ACCEL_BASE_ADDR, ACCEL_CTRL, 2U);
    wr32(GPIO_BASE_ADDR, GPIO_DATA, layer->fm_w);
    wr32(ACCEL_BASE_ADDR, ACCEL_FM_SIZE, (layer->fm_w << 16) | layer->fm_h);
    wr32(ACCEL_BASE_ADDR, ACCEL_OFM_SIZE, (layer->ofm_w << 16) | layer->ofm_h);
    wr32(ACCEL_BASE_ADDR, ACCEL_CONV, 0x00000101U);
    wr32(ACCEL_BASE_ADDR, ACCEL_K_TOTAL, layer->k_total);
    wr32(ACCEL_BASE_ADDR, ACCEL_COUT_TOTAL, layer->cout_total);
    wr32(ACCEL_BASE_ADDR, ACCEL_ACT_CFG, 2U);
    wr32(ACCEL_BASE_ADDR, ACCEL_IFM_ZP, layer->input_zero_point);
    wr32(ACCEL_BASE_ADDR, ACCEL_POOL_CFG, 0x00000009U);
    if (program_quant_tile(layer) != 0) {
        return -1;
    }
    return program_activation_lut(layer);
}

static int run_layer(chain_layer_t *layer)
{
    uint32_t total_bias = 0U;
    uint32_t total_weight = 0U;
    uint32_t total_ifm = 0U;

    xil_printf("\r\n=== run %s ===\r\n", layer->name);
    dma_reset_all();
    if (configure_layer(layer) != 0) {
        return -1;
    }
    clear_ofm(layer->ofm_u8, layer->total_expected_ofm_bytes);
    for (uint32_t i = 0U; i < layer->tile_count; ++i) {
        if (run_one_tile(layer, &layer->tiles[i], i, &total_bias, &total_weight, &total_ifm) != 0) {
            return -1;
        }
    }
    xil_printf("%s total services bias=%lu weight=%lu ifm=%lu\r\n",
               layer->name, (unsigned long)total_bias,
               (unsigned long)total_weight, (unsigned long)total_ifm);
    if (compare_layer_ofm(layer) != 0) {
        return -1;
    }
    Xil_DCacheFlushRange((UINTPTR)layer->ofm_u8, layer->total_expected_ofm_bytes);
    return 0;
}

int main(void)
{
    xil_printf("\r\nconv3_pool -> conv4_pool chained smoke\r\n");
    wr32(GPIO_BASE_ADDR, GPIO_TRI, 0x00000000U);
    wr32(GPIO_BASE_ADDR, GPIO2_TRI, 0x0000ffffU);

    if (run_layer(&conv3_layer) != 0) {
        xil_printf("FAIL: conv3_pool stage failed\r\n");
        return -1;
    }
    if (run_layer(&conv4_layer) != 0) {
        xil_printf("FAIL: conv4_pool chained stage failed\r\n");
        return -1;
    }
    xil_printf("PASS: conv3_pool -> conv4_pool chained smoke matches RTL golden\r\n");
    return 0;
}

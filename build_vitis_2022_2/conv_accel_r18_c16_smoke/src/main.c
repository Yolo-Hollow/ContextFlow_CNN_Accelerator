#include "accel_smoke.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_types.h"
#include "xil_printf.h"

/* Zynq UltraScale+ PS UARTs. Write both so either KV260 FTDI channel can show logs. */
#define UART0_BASE            0xFF000000U
#define UART1_BASE            0xFF010000U
#define UART_SR_OFFSET        0x2CU
#define UART_FIFO_OFFSET      0x30U
#define UART_SR_TXFULL        0x10U

static int8_t feat[CIN][FM_H][FM_W];
static int8_t weight[K_TOTAL][COUT_TOTAL];
static int32_t bias[COUT_TOTAL];
static int32_t golden[FULL_PIXELS][COUT_TOTAL];
static uint8_t ofm_mem[FULL_PIXELS * COUT_TOTAL];

static uint64_t bias_buf[COUT_TILE / 2] __attribute__((aligned(64)));
static uint64_t weight_buf[(ROWS * COUT_TILE) / 8] __attribute__((aligned(64)));
static uint64_t ifm_buf[FM_W] __attribute__((aligned(64)));
static uint64_t ofm_axis_buf[EXPECTED_OFM_BYTES] __attribute__((aligned(64)));
volatile uint32_t debug_stage = 0;
volatile uint32_t debug_value = 0;

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
}

static void pack_bias(void)
{
    for (int i = 0; i < COUT_TILE; i += 2) {
        uint32_t lo = (i < COUT_TOTAL) ? (uint32_t)bias[i] : 0U;
        uint32_t hi = ((i + 1) < COUT_TOTAL) ? (uint32_t)bias[i + 1] : 0U;
        bias_buf[i / 2] = ((uint64_t)hi << 32) | lo;
    }
}

static void pack_weight(int k_base)
{
    int lane = 0;
    uint64_t word = 0;
    int out = 0;

    for (int kk = 0; kk < ROWS; ++kk) {
        for (int cc = 0; cc < COUT_TILE; ++cc) {
            int gk = k_base + kk;
            uint8_t v = 0;
            if (gk < K_TOTAL && cc < COUT_TOTAL) {
                v = (uint8_t)weight[gk][cc];
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

static void dma_reset(uint32_t base, uint32_t cr_off, uint32_t sr_off)
{
    wr32(base, cr_off, DMA_DMACR_RESET);
    for (uint32_t i = 0; i < 1000000U; ++i) {
        if ((rd32(base, cr_off) & DMA_DMACR_RESET) == 0U) {
            break;
        }
    }
    wr32(base, sr_off, 0x00007000U);
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

static int service_bias(void)
{
    pack_bias();
    dma_start_mm2s(DMA_BIAS_BASE_ADDR, bias_buf, sizeof(bias_buf));
    if (dma_wait(DMA_BIAS_BASE_ADDR, DMA_MM2S_DMASR, "bias MM2S") != 0) {
        return -1;
    }
    return wait_gpio_deassert(ST_BIAS_REQ);
}

static int service_weight(int *next_k_pass, int *active_k_base)
{
    int k_base = (*next_k_pass) * ROWS;
    *active_k_base = k_base;
    pack_weight(k_base);
    dma_start_mm2s(DMA_WEIGHT_BASE_ADDR, weight_buf, sizeof(weight_buf));
    if (dma_wait(DMA_WEIGHT_BASE_ADDR, DMA_MM2S_DMASR, "weight MM2S") != 0) {
        return -1;
    }
    *next_k_pass = (*next_k_pass + 1) % K_PASSES;
    return wait_gpio_deassert(ST_WEIGHT_REQ);
}

static int service_ifm(uint32_t status, int active_k_base, int *ifm_row_phase)
{
#if USE_GPIO_FILL_FY
    int fy = (int)((status & ST_FILL_FY_MASK) >> ST_FILL_FY_SHIFT);
#else
    /*
     * Old XSA compatibility path.
     *
     * The r18_c16 smoke tile computes oy=0..1 with pad=1/stride=1, so every
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
    dma_start_mm2s(DMA_IFM_BASE_ADDR, ifm_buf, sizeof(ifm_buf));
    if (dma_wait(DMA_IFM_BASE_ADDR, DMA_MM2S_DMASR, "ifm MM2S") != 0) {
        return -1;
    }
    return 0;
}

static int parse_ofm(void)
{
    for (int i = 0; i < FULL_PIXELS * COUT_TOTAL; ++i) {
        ofm_mem[i] = 0xeeU;
    }

    Xil_DCacheInvalidateRange((UINTPTR)ofm_axis_buf, OFM_AXIS_BYTES);
    for (int i = 0; i < EXPECTED_OFM_BYTES; ++i) {
        uint32_t packet = (uint32_t)ofm_axis_buf[i];
        uint32_t addr = packet & 0x00ffffffU;
        uint8_t data = (uint8_t)((packet >> 24) & 0xffU);
        if (addr >= (FULL_PIXELS * COUT_TOTAL)) {
            xil_printf("Bad OFM packet %d addr=%lu data=%u\r\n",
                       i, (unsigned long)addr, data);
            return -1;
        }
        ofm_mem[addr] = data;
    }

    for (int idx = 0; idx < TILE_PIXELS; ++idx) {
        int global_pixel = TILE_PIXEL_BASE + idx;
        for (int co = 0; co < COUT_TOTAL; ++co) {
            uint8_t got = ofm_mem[global_pixel * COUT_TOTAL + co];
            uint8_t exp = clamp8(golden[global_pixel][co]);
            if (got != exp) {
                xil_printf("Mismatch pixel=%d cout=%d got=%u exp=%u raw=%ld\r\n",
                           global_pixel, co, got, exp,
                           (long)golden[global_pixel][co]);
                return -1;
            }
        }
    }
    return 0;
}

static int run_smoke(void)
{
    int k_pass = 0;
    int active_k_base = 0;
    int bias_services = 0;
    int weight_services = 0;
    int ifm_services = 0;
    int ifm_row_phase = 0;
    int done_seen = 0;

    debug_stage = 0x10000000U;
    xil_printf("stage: dma reset\r\n");
    dma_reset(DMA_BIAS_BASE_ADDR, DMA_MM2S_DMACR, DMA_MM2S_DMASR);
    dma_reset(DMA_WEIGHT_BASE_ADDR, DMA_MM2S_DMACR, DMA_MM2S_DMASR);
    dma_reset(DMA_IFM_BASE_ADDR, DMA_MM2S_DMACR, DMA_MM2S_DMASR);
    dma_reset(DMA_OFM_BASE_ADDR, DMA_S2MM_DMACR, DMA_S2MM_DMASR);
    xil_printf("stage: dma reset done\r\n");

    wr32(GPIO_BASE_ADDR, GPIO_TRI, 0x00000000U);
    wr32(GPIO_BASE_ADDR, GPIO2_TRI, 0x0000ffffU);
    wr32(GPIO_BASE_ADDR, GPIO_DATA, FM_W);

    debug_stage = 0x20000000U;
    xil_printf("stage: config regs\r\n");
    wr32(ACCEL_BASE_ADDR, ACCEL_FM_SIZE, ((uint32_t)FM_W << 16) | FM_H);
    wr32(ACCEL_BASE_ADDR, ACCEL_OFM_SIZE, ((uint32_t)OFM_W << 16) | OFM_H);
    wr32(ACCEL_BASE_ADDR, ACCEL_CONV, ((uint32_t)CONV_PAD << 8) | CONV_STRIDE);
    wr32(ACCEL_BASE_ADDR, ACCEL_K_TOTAL, K_TOTAL);
    wr32(ACCEL_BASE_ADDR, ACCEL_COUT_TOTAL, COUT_TOTAL);
    wr32(ACCEL_BASE_ADDR, ACCEL_ACT_CFG, 0U);
    wr32(ACCEL_BASE_ADDR, ACCEL_NUM_PIXELS, TILE_PIXELS);
    wr32(ACCEL_BASE_ADDR, ACCEL_TILE_ROWS, ((uint32_t)TILE_OFM_H << 16) | TILE_OY_BASE);
    wr32(ACCEL_BASE_ADDR, ACCEL_PIXEL_BASE, TILE_PIXEL_BASE);

    dma_start_s2mm(DMA_OFM_BASE_ADDR, ofm_axis_buf, OFM_AXIS_BYTES);
    debug_stage = 0x30000000U;
    xil_printf("stage: start accel\r\n");
    wr32(ACCEL_BASE_ADDR, ACCEL_CTRL, 1U);

    debug_stage = 0x41000000U;
    xil_printf("service: bias %d\r\n", bias_services);
    if (service_bias() != 0) {
        return -1;
    }
    ++bias_services;

    for (int pass_idx = 0; pass_idx < K_PASSES; ++pass_idx) {
        debug_stage = 0x42000000U | (uint32_t)weight_services;
        xil_printf("service: weight %d k_base=%d\r\n", weight_services, k_pass * ROWS);
        if (service_weight(&k_pass, &active_k_base) != 0) {
            return -1;
        }
        ++weight_services;

        for (int row = 0; row < 3; ++row) {
            debug_stage = 0x43000000U | (uint32_t)ifm_services;
            xil_printf("service: ifm %d k_base=%d\r\n", ifm_services, active_k_base);
            if (service_ifm(0U, active_k_base, &ifm_row_phase) != 0) {
                return -1;
            }
            ++ifm_services;
        }
    }

    for (uint32_t loops = 0; loops < 50000000U; ++loops) {
        uint32_t ctrl = rd32(ACCEL_BASE_ADDR, ACCEL_CTRL);
        uint32_t st = rd32(GPIO_BASE_ADDR, GPIO2_DATA);
        debug_value = st;

        if ((st & ST_ERROR_MASK) != 0U) {
            debug_stage = 0xe2000000U;
            xil_printf("AXIS protocol error, gpio2=0x%08lx\r\n", (unsigned long)st);
            return -1;
        }

        if (((ctrl & 0x2U) != 0U) && ((ctrl & 0x1U) == 0U)) {
            done_seen = 1;
            break;
        }
    }

    if (!done_seen) {
        debug_stage = 0xe3000000U;
        xil_printf("Accelerator timeout, ctrl=0x%08lx gpio2=0x%08lx\r\n",
                   (unsigned long)rd32(ACCEL_BASE_ADDR, ACCEL_CTRL),
                   (unsigned long)rd32(GPIO_BASE_ADDR, GPIO2_DATA));
        return -1;
    }

    if (dma_wait(DMA_OFM_BASE_ADDR, DMA_S2MM_DMASR, "ofm S2MM") != 0) {
        return -1;
    }
    debug_stage = 0x50000000U;
    wr32(ACCEL_BASE_ADDR, ACCEL_CTRL, 2U);

    xil_printf("services: bias=%d weight=%d ifm=%d\r\n",
               bias_services, weight_services, ifm_services);
    if (bias_services != COUT_BLOCKS || weight_services != (COUT_BLOCKS * K_PASSES) ||
        ifm_services <= 0) {
        xil_printf("Unexpected service counts\r\n");
        debug_stage = 0xe4000000U;
        debug_value = ((uint32_t)bias_services << 24) |
                      ((uint32_t)weight_services << 12) |
                      (uint32_t)ifm_services;
        return -1;
    }

    int rc = parse_ofm();
    debug_stage = (rc == 0) ? 0x60000000U : 0xe5000000U;
    return rc;
}

int main(void)
{
    debug_stage = 0x01000000U;
    xil_printf("\r\nr18_c16 AXI DMA smoke test\r\n");
    xil_printf("FM=%dx%d Cin=%d Cout=%d tile_h=%d expected_ofm=%d bytes\r\n",
               FM_W, FM_H, CIN, COUT_TOTAL, TILE_OFM_H, EXPECTED_OFM_BYTES);

    make_vectors();
    debug_stage = 0x02000000U;
    int rc = run_smoke();
    if (rc == 0) {
        xil_printf("PASS: r18_c16 smoke matches RTL golden\r\n");
    } else {
        xil_printf("FAIL: r18_c16 smoke failed\r\n");
    }

    return rc;
}

#include "cpu_yolo_baseline.h"
#include "cpu_yolo_data.h"
#include "yolo_decode.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if defined(ARMA53_64) && defined(ACCEL_CPU_YOLO_USE_NEON)
#include <arm_neon.h>
#endif

#ifdef ARMA53_64
#include "xil_cache.h"
#include "xil_io.h"
#include "xtime_l.h"

#define UART0_BASE 0xFF000000U
#define UART1_BASE 0xFF010000U
#define UART_SR_OFFSET 0x2CU
#define UART_FIFO_OFFSET 0x30U
#define UART_SR_TXFULL 0x10U

static void uart_putc_one(uint32_t base, char c)
{
    uint32_t i;
    for (i = 0U; i < 100000U; ++i) {
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

static uint64_t ticks_now(void)
{
    XTime t;
    XTime_GetTime(&t);
    return (uint64_t)t;
}

static uint64_t ticks_to_us(uint64_t ticks)
{
    return (ticks * 1000000ULL) / (uint64_t)COUNTS_PER_SECOND;
}
#else
#include <time.h>
#define log_printf printf

static uint64_t ticks_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static uint64_t ticks_to_us(uint64_t ticks)
{
    return ticks / 1000ULL;
}
#endif

#define xil_printf(...) log_printf(__VA_ARGS__)

static uint8_t conv_scratch[CPU_YOLO_MAX_CONV_BYTES] __attribute__((aligned(64)));
static uint8_t feature_a[CPU_YOLO_MAX_FINAL_BYTES] __attribute__((aligned(64)));
static uint8_t feature_b[CPU_YOLO_MAX_FINAL_BYTES] __attribute__((aligned(64)));
static int32_t psum_accum[1024] __attribute__((aligned(64)));
static yolo_detection_t yolo_detections[YOLO_MAX_CANDIDATES];

static int8_t clamp_s8(int32_t value)
{
    if (value > 127) {
        return 127;
    }
    if (value < -128) {
        return -128;
    }
    return (int8_t)value;
}

static int32_t center_u8_to_s8(uint8_t value, uint8_t zero_point)
{
    return (int32_t)clamp_s8((int32_t)value - (int32_t)zero_point);
}

static uint8_t requant_lut_u8(int32_t psum, const cpu_yolo_layer_t *layer)
{
    const int effective_shift = (int)layer->quant_shift + 15;
    int64_t v = (int64_t)psum * (int64_t)layer->quant_mult;
    v += (int64_t)1 << (effective_shift - 1);
    v >>= effective_shift;
    v += (int64_t)layer->output_zero_point;
    return layer->activation_lut_u8[(uint8_t)clamp_s8((int32_t)v)];
}

#if defined(ARMA53_64) && defined(ACCEL_CPU_YOLO_USE_NEON)
static void accum_weight_row_neon(int32_t *accum, const int8_t *weight, uint32_t cout, int8_t ifm_s8)
{
    uint32_t co;
    int8x8_t x8 = vdup_n_s8(ifm_s8);
    for (co = 0U; co < cout; co += 8U) {
        int8x8_t w8 = vld1_s8(weight + co);
        int16x8_t prod16 = vmull_s8(w8, x8);
        int32x4_t acc0 = vld1q_s32(accum + co);
        int32x4_t acc1 = vld1q_s32(accum + co + 4U);
        acc0 = vaddq_s32(acc0, vmovl_s16(vget_low_s16(prod16)));
        acc1 = vaddq_s32(acc1, vmovl_s16(vget_high_s16(prod16)));
        vst1q_s32(accum + co, acc0);
        vst1q_s32(accum + co + 4U, acc1);
    }
}
#endif

static void accum_weight_row_scalar(int32_t *accum, const int8_t *weight, uint32_t cout, int32_t ifm_s8)
{
    uint32_t co;
    for (co = 0U; co < cout; ++co) {
        accum[co] += ifm_s8 * (int32_t)weight[co];
    }
}

static void conv2d_kco_u8s8(const uint8_t *ifm, uint8_t *ofm, const cpu_yolo_layer_t *layer)
{
    uint32_t oy;
    for (oy = 0U; oy < layer->conv_h; ++oy) {
        uint32_t ox;
        for (ox = 0U; ox < layer->conv_w; ++ox) {
            uint32_t co;
            uint32_t k_index = 0U;

            for (co = 0U; co < layer->ofm_c; ++co) {
                psum_accum[co] = layer->bias_i32[co];
            }

            for (uint32_t ci = 0U; ci < layer->ifm_c; ++ci) {
                uint32_t ky;
                for (ky = 0U; ky < layer->kernel; ++ky) {
                    int32_t iy = (int32_t)(oy * layer->stride + ky) - (int32_t)layer->pad;
                    uint32_t kx;
                    for (kx = 0U; kx < layer->kernel; ++kx) {
                        int32_t ix = (int32_t)(ox * layer->stride + kx) - (int32_t)layer->pad;
                        int32_t ifm_s8 = 0;
                        const int8_t *w = &layer->weight_s8_kco[k_index * layer->ofm_c];

                        if (iy >= 0 && ix >= 0 &&
                            iy < (int32_t)layer->ifm_h && ix < (int32_t)layer->ifm_w) {
                            uint32_t ifm_idx =
                                (((uint32_t)iy * layer->ifm_w + (uint32_t)ix) * layer->ifm_c) + ci;
                            ifm_s8 = center_u8_to_s8(ifm[ifm_idx], layer->input_zero_point);
                        }
                        if (ifm_s8 != 0) {
#if defined(ARMA53_64) && defined(ACCEL_CPU_YOLO_USE_NEON)
                            accum_weight_row_neon(psum_accum, w, layer->ofm_c, (int8_t)ifm_s8);
#else
                            accum_weight_row_scalar(psum_accum, w, layer->ofm_c, ifm_s8);
#endif
                        }
                        ++k_index;
                    }
                }
            }

            for (co = 0U; co < layer->ofm_c; ++co) {
                ofm[(oy * layer->conv_w + ox) * layer->ofm_c + co] =
                    requant_lut_u8(psum_accum[co], layer);
            }
        }
    }
}

static void conv2d_1x1_kco_u8s8(const uint8_t *ifm, uint8_t *ofm, const cpu_yolo_layer_t *layer)
{
    uint32_t pixel_count = (uint32_t)layer->conv_h * layer->conv_w;
    uint32_t p;
    for (p = 0U; p < pixel_count; ++p) {
        uint32_t co;
        for (co = 0U; co < layer->ofm_c; ++co) {
            psum_accum[co] = layer->bias_i32[co];
        }

        for (uint32_t ci = 0U; ci < layer->ifm_c; ++ci) {
            int32_t ifm_s8 = center_u8_to_s8(ifm[p * layer->ifm_c + ci], layer->input_zero_point);
            const int8_t *w = &layer->weight_s8_kco[ci * layer->ofm_c];
            if (ifm_s8 != 0) {
#if defined(ARMA53_64) && defined(ACCEL_CPU_YOLO_USE_NEON)
                accum_weight_row_neon(psum_accum, w, layer->ofm_c, (int8_t)ifm_s8);
#else
                accum_weight_row_scalar(psum_accum, w, layer->ofm_c, ifm_s8);
#endif
            }
        }

        for (co = 0U; co < layer->ofm_c; ++co) {
            ofm[p * layer->ofm_c + co] = requant_lut_u8(psum_accum[co], layer);
        }
    }
}

#if 0
static void conv2d_oihw_reference_u8s8(const uint8_t *ifm, uint8_t *ofm, const cpu_yolo_layer_t *layer)
{
    uint32_t oy;
    for (oy = 0U; oy < layer->conv_h; ++oy) {
        uint32_t ox;
        for (ox = 0U; ox < layer->conv_w; ++ox) {
            uint32_t co;
            for (co = 0U; co < layer->ofm_c; ++co) {
                int32_t psum = layer->bias_i32[co];
                uint32_t ci;
                for (ci = 0U; ci < layer->ifm_c; ++ci) {
                    uint32_t ky;
                    for (ky = 0U; ky < layer->kernel; ++ky) {
                        int32_t iy = (int32_t)(oy * layer->stride + ky) - (int32_t)layer->pad;
                        uint32_t kx;
                        for (kx = 0U; kx < layer->kernel; ++kx) {
                            int32_t ix = (int32_t)(ox * layer->stride + kx) - (int32_t)layer->pad;
                            int32_t ifm_s8 = 0;
                            int8_t weight;
                            uint32_t weight_idx;
                            if (iy >= 0 && ix >= 0 &&
                                iy < (int32_t)layer->ifm_h && ix < (int32_t)layer->ifm_w) {
                                uint32_t ifm_idx =
                                    (((uint32_t)iy * layer->ifm_w + (uint32_t)ix) * layer->ifm_c) + ci;
                                ifm_s8 = center_u8_to_s8(ifm[ifm_idx], layer->input_zero_point);
                            }
                            weight_idx =
                                (((co * layer->ifm_c + ci) * layer->kernel + ky) * layer->kernel) + kx;
                            weight = layer->weight_s8_kco[weight_idx];
                            psum += ifm_s8 * (int32_t)weight;
                        }
                    }
                }
                ofm[(oy * layer->conv_w + ox) * layer->ofm_c + co] = requant_lut_u8(psum, layer);
            }
        }
    }
}
#endif

static void maxpool2x2s2_u8(const uint8_t *ifm, uint8_t *ofm, const cpu_yolo_layer_t *layer)
{
    uint32_t oy;
    for (oy = 0U; oy < layer->ofm_h; ++oy) {
        uint32_t ox;
        for (ox = 0U; ox < layer->ofm_w; ++ox) {
            uint32_t c;
            for (c = 0U; c < layer->ofm_c; ++c) {
                uint8_t m = 0U;
                uint32_t py;
                for (py = 0U; py < layer->pool_stride; ++py) {
                    uint32_t px;
                    for (px = 0U; px < layer->pool_stride; ++px) {
                        uint32_t idx =
                            (((oy * layer->pool_stride + py) * layer->conv_w +
                              (ox * layer->pool_stride + px)) * layer->ofm_c) + c;
                        uint8_t v = ifm[idx];
                        if (v > m) {
                            m = v;
                        }
                    }
                }
                ofm[(oy * layer->ofm_w + ox) * layer->ofm_c + c] = m;
            }
        }
    }
}

static uint32_t count_mismatch(const uint8_t *got, const uint8_t *expected, uint32_t bytes)
{
    uint32_t mismatches = 0U;
    uint32_t i;
    if (expected == 0) {
        return 0U;
    }
    for (i = 0U; i < bytes; ++i) {
        if (got[i] != expected[i]) {
            ++mismatches;
        }
    }
    return mismatches;
}

static int run_layer(
    const cpu_yolo_layer_t *layer,
    const uint8_t *ifm,
    uint8_t *ofm,
    uint64_t *elapsed_us)
{
    uint64_t t0 = ticks_now();
    uint64_t t1;
    uint32_t out_bytes = (uint32_t)layer->ofm_h * layer->ofm_w * layer->ofm_c;
    uint32_t conv_bytes = (uint32_t)layer->conv_h * layer->conv_w * layer->ofm_c;

    if (conv_bytes > CPU_YOLO_MAX_CONV_BYTES || out_bytes > CPU_YOLO_MAX_FINAL_BYTES) {
        xil_printf("CPU_LAYER name=%s error=buffer_too_small\r\n", layer->name);
        return -1;
    }

    if (layer->kernel == 1U) {
        conv2d_1x1_kco_u8s8(ifm, conv_scratch, layer);
    } else {
        conv2d_kco_u8s8(ifm, conv_scratch, layer);
    }
    if (layer->pool_enable) {
        maxpool2x2s2_u8(conv_scratch, ofm, layer);
    } else {
        memcpy(ofm, conv_scratch, out_bytes);
    }
    t1 = ticks_now();
    *elapsed_us = ticks_to_us(t1 - t0);

    xil_printf(
        "CPU_LAYER name=%s us=%llu bytes=%lu golden_mismatch=%lu\r\n",
        layer->name,
        (unsigned long long)*elapsed_us,
        (unsigned long)out_bytes,
        (unsigned long)count_mismatch(ofm, layer->golden_ofm_u8, layer->golden_bytes));
    return 0;
}

static int decode_and_print(const uint8_t *conv9)
{
    int detection_count = yolo_decode_single_scale(
        conv9,
        0.25f,
        0.45f,
        yolo_detections,
        YOLO_MAX_CANDIDATES);
    int i;
    if (detection_count < 0) {
        xil_printf("YOLO decode error=%d\r\n", detection_count);
        return -1;
    }

    xil_printf("DECODE count=%d\r\n", detection_count);
    for (i = 0; i < detection_count; ++i) {
        yolo_detection_t original_detection;
        char score[24];
        char model_x1[24];
        char model_y1[24];
        char model_x2[24];
        char model_y2[24];
        char original_x1[24];
        char original_y1[24];
        char original_x2[24];
        char original_y2[24];

        yolo_inverse_letterbox(
            &yolo_detections[i],
            512.0f,
            366.0f,
            0.8125f,
            0.0f,
            59.0f,
            &original_detection);
        yolo_format_fixed6(yolo_detections[i].score, score, sizeof(score));
        yolo_format_fixed6(yolo_detections[i].x1, model_x1, sizeof(model_x1));
        yolo_format_fixed6(yolo_detections[i].y1, model_y1, sizeof(model_y1));
        yolo_format_fixed6(yolo_detections[i].x2, model_x2, sizeof(model_x2));
        yolo_format_fixed6(yolo_detections[i].y2, model_y2, sizeof(model_y2));
        yolo_format_fixed6(original_detection.x1, original_x1, sizeof(original_x1));
        yolo_format_fixed6(original_detection.y1, original_y1, sizeof(original_y1));
        yolo_format_fixed6(original_detection.x2, original_x2, sizeof(original_x2));
        yolo_format_fixed6(original_detection.y2, original_y2, sizeof(original_y2));
        xil_printf(
            "DET index=%d class=%lu name=%s score=%s "
            "model_x1=%s model_y1=%s model_x2=%s model_y2=%s "
            "orig_x1=%s orig_y1=%s orig_x2=%s orig_y2=%s\r\n",
            i,
            (unsigned long)yolo_detections[i].class_id,
            yolo_class_name(yolo_detections[i].class_id),
            score,
            model_x1,
            model_y1,
            model_x2,
            model_y2,
            original_x1,
            original_y1,
            original_x2,
            original_y2);
    }
    return 0;
}

int main(void)
{
    const uint8_t *ifm = cpu_yolo_input_u8;
    uint8_t *ofm = feature_a;
    uint64_t total_start;
    uint64_t pre_start;
    uint64_t pre_us;
    uint64_t layers_us = 0U;
    uint64_t decode_start;
    uint64_t decode_us;
    uint32_t i;

#ifdef ARMA53_64
    Xil_ICacheEnable();
    Xil_DCacheEnable();
#endif

#if defined(ARMA53_64) && defined(ACCEL_CPU_YOLO_USE_NEON)
    xil_printf("\r\nCPU YOLOv3-tiny baseline: single-thread optimized C INT8 NEON\r\n");
#else
    xil_printf("\r\nCPU YOLOv3-tiny baseline: single-thread optimized C INT8 scalar\r\n");
#endif
    total_start = ticks_now();
    pre_start = ticks_now();
    pre_us = ticks_to_us(ticks_now() - pre_start);
    xil_printf("CPU_PRE us=%llu bytes=%lu\r\n",
               (unsigned long long)pre_us,
               (unsigned long)CPU_YOLO_INPUT_BYTES);

    for (i = 0U; i < CPU_YOLO_LAYER_COUNT; ++i) {
        uint64_t layer_us = 0U;
        if (run_layer(&cpu_yolo_layers[i], ifm, ofm, &layer_us) != 0) {
            xil_printf("FAIL: CPU layer %lu failed\r\n", (unsigned long)i);
            return -1;
        }
        layers_us += layer_us;
        ifm = ofm;
        ofm = (ofm == feature_a) ? feature_b : feature_a;
    }

    decode_start = ticks_now();
    if (decode_and_print(ifm) != 0) {
        xil_printf("FAIL: CPU YOLO decode failed\r\n");
        return -1;
    }
    decode_us = ticks_to_us(ticks_now() - decode_start);
    xil_printf("CPU_DECODE us=%llu\r\n", (unsigned long long)decode_us);
    xil_printf("CPU_TOTAL us=%llu layer_us=%llu pre_us=%llu decode_us=%llu\r\n",
               (unsigned long long)ticks_to_us(ticks_now() - total_start),
               (unsigned long long)layers_us,
               (unsigned long long)pre_us,
               (unsigned long long)decode_us);
    xil_printf("PASS: CPU YOLO baseline complete\r\n");
    return 0;
}

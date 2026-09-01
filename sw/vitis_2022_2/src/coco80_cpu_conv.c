#include "coco80_cpu_conv.h"

#include <stddef.h>

#if defined(__aarch64__) && defined(COCO80_CPU_USE_NEON)
#include <arm_neon.h>
#endif

static int32_t c8_center(uint8_t value, uint32_t zero_point)
{
    int32_t centered = (int32_t)value - (int32_t)zero_point;
    if (centered > 127) centered = 127;
    if (centered < -128) centered = -128;
    return centered;
}

static int8_t c8_clamp_s8(int64_t value)
{
    if (value > 127) return 127;
    if (value < -128) return -128;
    return (int8_t)value;
}

static uint8_t c8_requant(
    int32_t accumulator,
    uint32_t multiplier,
    uint32_t shift,
    uint32_t output_zero_point,
    const uint8_t *lut)
{
    uint32_t effective_shift = shift + 15U;
    int64_t value = (int64_t)accumulator * (int64_t)multiplier;
    value += (int64_t)1 << (effective_shift - 1U);
    value >>= effective_shift;
    /* The r5 convolution requantizer is programmed with RTL output-zp zero.
     * The tensor-domain zero point is already encoded by the 256-byte LUT. */
    (void)output_zero_point;
    return lut[(uint8_t)c8_clamp_s8(value)];
}

#if !defined(__aarch64__) || !defined(COCO80_CPU_USE_NEON)
static void c8_accumulate_scalar(
    int32_t *accumulator,
    const int8_t *weight,
    uint32_t channels,
    int32_t input)
{
    uint32_t channel;
    for (channel = 0U; channel < channels; ++channel)
        accumulator[channel] += input * (int32_t)weight[channel];
}
#endif

#if defined(__aarch64__) && defined(COCO80_CPU_USE_NEON)
static void c8_accumulate_neon(
    int32_t *accumulator,
    const int8_t *weight,
    uint32_t channels,
    int32_t input)
{
    uint32_t channel = 0U;
    int8x8_t input8 = vdup_n_s8((int8_t)input);
    for (; channel + 8U <= channels; channel += 8U) {
        int16x8_t product = vmull_s8(vld1_s8(weight + channel), input8);
        int32x4_t low = vld1q_s32(accumulator + channel);
        int32x4_t high = vld1q_s32(accumulator + channel + 4U);
        low = vaddq_s32(low, vmovl_s16(vget_low_s16(product)));
        high = vaddq_s32(high, vmovl_s16(vget_high_s16(product)));
        vst1q_s32(accumulator + channel, low);
        vst1q_s32(accumulator + channel + 4U, high);
    }
    for (; channel < channels; ++channel)
        accumulator[channel] += input * (int32_t)weight[channel];
}
#endif

int coco80_cpu_conv_kco_range(
    const uint8_t *ifm,
    uint8_t *ofm,
    const int8_t *weight_kco,
    const int32_t *bias_i32,
    const uint8_t *activation_lut_u8,
    const coco80_cpu_layer_t *layer,
    uint32_t channel_begin,
    uint32_t channel_end)
{
    int32_t accumulator[COCO80_CPU_MAX_CHANNELS];
    uint32_t range;
    uint32_t oy;
    if (ifm == NULL || ofm == NULL || weight_kco == NULL || bias_i32 == NULL ||
        activation_lut_u8 == NULL || layer == NULL)
        return COCO80_CPU_ERR_ARGUMENT;
    if (layer->ofm_c == 0U || layer->ofm_c > COCO80_CPU_MAX_CHANNELS ||
        channel_begin > channel_end || channel_end > layer->ofm_c)
        return COCO80_CPU_ERR_RANGE;
    if (channel_begin == channel_end) return COCO80_CPU_OK;
    if ((layer->kernel != 1U && layer->kernel != 3U) || layer->stride != 1U ||
        layer->quant_mult == 0U || layer->quant_shift > 15U)
        return COCO80_CPU_ERR_QUANT;
    range = channel_end - channel_begin;
    for (oy = 0U; oy < layer->ofm_h; ++oy) {
        uint32_t ox;
        for (ox = 0U; ox < layer->ofm_w; ++ox) {
            uint32_t channel;
            uint32_t ci;
            for (channel = 0U; channel < range; ++channel)
                accumulator[channel] = bias_i32[channel_begin + channel];
            for (ci = 0U; ci < layer->ifm_c; ++ci) {
                uint32_t ky;
                for (ky = 0U; ky < layer->kernel; ++ky) {
                    int32_t iy = (int32_t)oy + (int32_t)ky - (int32_t)layer->pad;
                    uint32_t kx;
                    for (kx = 0U; kx < layer->kernel; ++kx) {
                        int32_t ix = (int32_t)ox + (int32_t)kx - (int32_t)layer->pad;
                        uint32_t k_index =
                            (ci * layer->kernel + ky) * layer->kernel + kx;
                        const int8_t *weights = weight_kco +
                            (uint64_t)k_index * layer->ofm_c + channel_begin;
                        int32_t input = 0;
                        if (iy >= 0 && ix >= 0 &&
                            iy < (int32_t)layer->ifm_h &&
                            ix < (int32_t)layer->ifm_w) {
                            uint32_t input_index =
                                (((uint32_t)iy * layer->ifm_w + (uint32_t)ix) *
                                 layer->ifm_c) + ci;
                            input = c8_center(ifm[input_index], layer->input_zero_point);
                        }
                        if (input == 0) continue;
#if defined(__aarch64__) && defined(COCO80_CPU_USE_NEON)
                        c8_accumulate_neon(accumulator, weights, range, input);
#else
                        c8_accumulate_scalar(accumulator, weights, range, input);
#endif
                    }
                }
            }
            for (channel = 0U; channel < range; ++channel) {
                uint32_t output_index =
                    (oy * layer->ofm_w + ox) * layer->ofm_c +
                    channel_begin + channel;
                ofm[output_index] = c8_requant(
                    accumulator[channel], layer->quant_mult, layer->quant_shift,
                    layer->output_zero_point, activation_lut_u8);
            }
        }
    }
    return COCO80_CPU_OK;
}

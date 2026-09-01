#include "coco80_tensor_ops.h"

#include <stddef.h>
#include <string.h>

static uint32_t tensor_bytes(uint32_t h, uint32_t w, uint32_t c)
{
    uint64_t value = (uint64_t)h * (uint64_t)w * (uint64_t)c;
    return value <= UINT32_MAX ? (uint32_t)value : 0U;
}

static int tensor_valid(const coco80_hwc_u8_t *tensor)
{
    uint32_t expected;
    if (tensor == NULL || tensor->data == NULL || tensor->height == 0U ||
        tensor->width == 0U || tensor->channels == 0U) {
        return 0;
    }
    expected = tensor_bytes(tensor->height, tensor->width, tensor->channels);
    return expected != 0U && tensor->bytes >= expected;
}

int coco80_maxpool2x2_s2_channel_range(
    const coco80_hwc_u8_t *source,
    coco80_hwc_u8_t *destination,
    uint32_t channel_begin,
    uint32_t channel_end)
{
    uint32_t out_h;
    uint32_t out_w;
    uint32_t expected;
    if (!tensor_valid(source) || destination == NULL || destination->data == NULL) {
        return COCO80_TENSOR_ERR_ARGUMENT;
    }
    if ((source->height & 1U) != 0U || (source->width & 1U) != 0U) {
        return COCO80_TENSOR_ERR_SHAPE;
    }
    if (channel_begin >= channel_end || channel_end > source->channels) {
        return COCO80_TENSOR_ERR_SHAPE;
    }
    out_h = source->height / 2U;
    out_w = source->width / 2U;
    expected = tensor_bytes(out_h, out_w, source->channels);
    if (destination->bytes < expected) {
        return COCO80_TENSOR_ERR_CAPACITY;
    }
    for (uint32_t oy = 0U; oy < out_h; ++oy) {
        const uint8_t *row0 = source->data +
            (oy * 2U) * source->width * source->channels;
        const uint8_t *row1 = row0 + source->width * source->channels;
        uint8_t *output = destination->data +
            oy * out_w * source->channels;
        for (uint32_t ox = 0U; ox < out_w; ++ox) {
            const uint8_t *p00 = row0 + ox * 2U * source->channels;
            const uint8_t *p01 = p00 + source->channels;
            const uint8_t *p10 = row1 + ox * 2U * source->channels;
            const uint8_t *p11 = p10 + source->channels;
            uint8_t *target = output + ox * source->channels;
            for (uint32_t channel = channel_begin; channel < channel_end; ++channel) {
                uint8_t maximum = p00[channel] > p01[channel] ?
                    p00[channel] : p01[channel];
                uint8_t lower = p10[channel] > p11[channel] ?
                    p10[channel] : p11[channel];
                target[channel] = maximum > lower ? maximum : lower;
            }
        }
    }
    destination->height = out_h;
    destination->width = out_w;
    destination->channels = source->channels;
    destination->bytes = expected;
    return COCO80_TENSOR_OK;
}

int coco80_maxpool2x2_s2(
    const coco80_hwc_u8_t *source,
    coco80_hwc_u8_t *destination)
{
    return coco80_maxpool2x2_s2_channel_range(
        source, destination, 0U, source == NULL ? 0U : source->channels);
}

int coco80_maxpool2x2_s1_pad_right_bottom_channel_range(
    const coco80_hwc_u8_t *source,
    uint8_t pad_value,
    coco80_hwc_u8_t *destination,
    uint32_t channel_begin,
    uint32_t channel_end)
{
    uint32_t expected;
    if (!tensor_valid(source) || destination == NULL || destination->data == NULL) {
        return COCO80_TENSOR_ERR_ARGUMENT;
    }
    if (channel_begin >= channel_end || channel_end > source->channels) {
        return COCO80_TENSOR_ERR_SHAPE;
    }
    expected = tensor_bytes(source->height, source->width, source->channels);
    if (destination->bytes < expected) {
        return COCO80_TENSOR_ERR_CAPACITY;
    }
    for (uint32_t oy = 0U; oy < source->height; ++oy) {
        const uint8_t *row0 = source->data +
            oy * source->width * source->channels;
        const uint8_t *row1 = oy + 1U < source->height ?
            row0 + source->width * source->channels : NULL;
        uint8_t *output = destination->data +
            oy * source->width * source->channels;
        for (uint32_t ox = 0U; ox < source->width; ++ox) {
            const uint8_t *p00 = row0 + ox * source->channels;
            const uint8_t *p01 = ox + 1U < source->width ?
                p00 + source->channels : NULL;
            const uint8_t *p10 = row1 == NULL ? NULL :
                row1 + ox * source->channels;
            const uint8_t *p11 = p10 == NULL || p01 == NULL ? NULL :
                p10 + source->channels;
            uint8_t *target = output + ox * source->channels;
            for (uint32_t channel = channel_begin; channel < channel_end; ++channel) {
                uint8_t maximum = p00[channel];
                if (p01 != NULL && p01[channel] > maximum) maximum = p01[channel];
                if (p10 != NULL && p10[channel] > maximum) maximum = p10[channel];
                if (p11 != NULL && p11[channel] > maximum) maximum = p11[channel];
                if ((p01 == NULL || p10 == NULL) && pad_value > maximum)
                    maximum = pad_value;
                target[channel] = maximum;
            }
        }
    }
    destination->height = source->height;
    destination->width = source->width;
    destination->channels = source->channels;
    destination->bytes = expected;
    return COCO80_TENSOR_OK;
}

int coco80_maxpool2x2_s1_pad_right_bottom(
    const coco80_hwc_u8_t *source,
    uint8_t pad_value,
    coco80_hwc_u8_t *destination)
{
    return coco80_maxpool2x2_s1_pad_right_bottom_channel_range(
        source, pad_value, destination, 0U,
        source == NULL ? 0U : source->channels);
}

static uint8_t requant_one(
    uint8_t value,
    int32_t input_zero_point,
    int32_t output_zero_point,
    uint32_t multiplier,
    uint32_t shift)
{
    int64_t product = ((int64_t)value - input_zero_point) * multiplier;
    int64_t half = (int64_t)1 << (shift - 1U);
    int64_t rounded = product >= 0 ?
        (product + half) >> shift : -(((-product) + half) >> shift);
    int64_t output = rounded + output_zero_point;
    if (output < 0) {
        return 0U;
    }
    if (output > 127) {
        return 127U;
    }
    return (uint8_t)output;
}

int coco80_nearest2x(
    const coco80_hwc_u8_t *source,
    coco80_hwc_u8_t *destination)
{
    uint32_t out_h, out_w, expected;
    if (!tensor_valid(source) || destination == NULL || destination->data == NULL)
        return COCO80_TENSOR_ERR_ARGUMENT;
    if (source->height > UINT32_MAX / 2U || source->width > UINT32_MAX / 2U)
        return COCO80_TENSOR_ERR_SHAPE;
    out_h = source->height * 2U; out_w = source->width * 2U;
    expected = tensor_bytes(out_h, out_w, source->channels);
    if (expected == 0U || destination->bytes < expected)
        return COCO80_TENSOR_ERR_CAPACITY;
    for (uint32_t y = 0U; y < out_h; ++y) {
        for (uint32_t x = 0U; x < out_w; ++x) {
            uint32_t source_offset =
                ((y / 2U) * source->width + (x / 2U)) * source->channels;
            uint32_t target_offset = (y * out_w + x) * source->channels;
            for (uint32_t channel = 0U; channel < source->channels; ++channel)
                destination->data[target_offset + channel] = source->data[source_offset + channel];
        }
    }
    destination->height = out_h; destination->width = out_w;
    destination->channels = source->channels; destination->bytes = expected;
    return COCO80_TENSOR_OK;
}

int coco80_requant_concat(
    const coco80_hwc_u8_t *upsampled,
    const coco80_hwc_u8_t *route,
    int32_t route_input_zero_point,
    int32_t output_zero_point,
    uint32_t multiplier,
    uint32_t shift,
    coco80_hwc_u8_t *destination)
{
    uint32_t out_c, expected, pixels;
    uint8_t requant_lut[256];
    if (!tensor_valid(upsampled) || !tensor_valid(route) || destination == NULL ||
        destination->data == NULL) return COCO80_TENSOR_ERR_ARGUMENT;
    if (shift == 0U || shift > 30U || multiplier == 0U)
        return COCO80_TENSOR_ERR_QUANT;
    if (upsampled->height != route->height || upsampled->width != route->width)
        return COCO80_TENSOR_ERR_SHAPE;
    out_c = upsampled->channels + route->channels;
    expected = tensor_bytes(upsampled->height, upsampled->width, out_c);
    if (expected == 0U || destination->bytes < expected)
        return COCO80_TENSOR_ERR_CAPACITY;
    for (uint32_t value = 0U; value < 256U; ++value)
        requant_lut[value] = requant_one(
            (uint8_t)value, route_input_zero_point, output_zero_point,
            multiplier, shift);
    pixels = upsampled->height * upsampled->width;
    for (uint32_t pixel = 0U; pixel < pixels; ++pixel) {
        uint32_t target = pixel * out_c;
        uint32_t up = pixel * upsampled->channels;
        uint32_t skip = pixel * route->channels;
        memcpy(destination->data + target, upsampled->data + up,
               upsampled->channels);
        for (uint32_t channel = 0U; channel < route->channels; ++channel)
            destination->data[target + upsampled->channels + channel] =
                requant_lut[route->data[skip + channel]];
    }
    destination->height = upsampled->height; destination->width = upsampled->width;
    destination->channels = out_c; destination->bytes = expected;
    return COCO80_TENSOR_OK;
}

int coco80_nearest2x_requant_concat_pixel_range(
    const coco80_hwc_u8_t *small,
    const coco80_hwc_u8_t *route,
    int32_t route_input_zero_point,
    int32_t output_zero_point,
    uint32_t multiplier,
    uint32_t shift,
    coco80_hwc_u8_t *destination,
    uint32_t pixel_begin,
    uint32_t pixel_end)
{
    uint32_t out_h;
    uint32_t out_w;
    uint32_t out_c;
    uint32_t expected;
    uint8_t requant_lut[256];
    if (!tensor_valid(small) || !tensor_valid(route) || destination == NULL ||
        destination->data == NULL) {
        return COCO80_TENSOR_ERR_ARGUMENT;
    }
    if (shift == 0U || shift > 30U || multiplier == 0U) {
        return COCO80_TENSOR_ERR_QUANT;
    }
    out_h = small->height * 2U;
    out_w = small->width * 2U;
    if (route->height != out_h || route->width != out_w) {
        return COCO80_TENSOR_ERR_SHAPE;
    }
    out_c = small->channels + route->channels;
    expected = tensor_bytes(out_h, out_w, out_c);
    if (expected == 0U || destination->bytes < expected) {
        return COCO80_TENSOR_ERR_CAPACITY;
    }
    if (pixel_begin >= pixel_end || pixel_end > out_h * out_w) {
        return COCO80_TENSOR_ERR_SHAPE;
    }
    for (uint32_t value = 0U; value < 256U; ++value)
        requant_lut[value] = requant_one(
            (uint8_t)value, route_input_zero_point, output_zero_point,
            multiplier, shift);
    for (uint32_t pixel = pixel_begin; pixel < pixel_end; ++pixel) {
        uint32_t y = pixel / out_w;
        uint32_t x = pixel - y * out_w;
        uint32_t target = pixel * out_c;
        uint32_t small_source =
            ((y / 2U) * small->width + (x / 2U)) * small->channels;
        uint32_t route_source = pixel * route->channels;
        memcpy(destination->data + target, small->data + small_source,
               small->channels);
        for (uint32_t channel = 0U; channel < route->channels; ++channel)
            destination->data[target + small->channels + channel] =
                requant_lut[route->data[route_source + channel]];
    }
    destination->height = out_h; destination->width = out_w;
    destination->channels = out_c; destination->bytes = expected;
    return COCO80_TENSOR_OK;
}

int coco80_nearest2x_requant_concat(
    const coco80_hwc_u8_t *small,
    const coco80_hwc_u8_t *route,
    int32_t route_input_zero_point,
    int32_t output_zero_point,
    uint32_t multiplier,
    uint32_t shift,
    coco80_hwc_u8_t *destination)
{
    uint32_t pixels = route == NULL ? 0U : route->height * route->width;
    return coco80_nearest2x_requant_concat_pixel_range(
        small, route, route_input_zero_point, output_zero_point,
        multiplier, shift, destination, 0U, pixels);
}

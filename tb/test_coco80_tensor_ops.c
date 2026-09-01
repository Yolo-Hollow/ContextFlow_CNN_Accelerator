#include "coco80_tensor_ops.h"

#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(expr) do { if (!(expr)) { ++failures; printf("FAIL line=%d: %s\n", __LINE__, #expr); } } while (0)

static void reference_pool_s2(
    const uint8_t *source, uint32_t h, uint32_t w, uint32_t c,
    uint8_t *destination)
{
    for (uint32_t oy = 0; oy < h / 2U; ++oy) {
        for (uint32_t ox = 0; ox < w / 2U; ++ox) {
            for (uint32_t ch = 0; ch < c; ++ch) {
                uint8_t maximum = 0U;
                for (uint32_t ky = 0; ky < 2U; ++ky) {
                    for (uint32_t kx = 0; kx < 2U; ++kx) {
                        uint8_t value = source[
                            (((oy * 2U + ky) * w + ox * 2U + kx) * c) + ch];
                        if (value > maximum) maximum = value;
                    }
                }
                destination[(oy * (w / 2U) + ox) * c + ch] = maximum;
            }
        }
    }
}

static void reference_pool_s1_pad(
    const uint8_t *source, uint32_t h, uint32_t w, uint32_t c,
    uint8_t pad, uint8_t *destination)
{
    for (uint32_t oy = 0; oy < h; ++oy) {
        for (uint32_t ox = 0; ox < w; ++ox) {
            for (uint32_t ch = 0; ch < c; ++ch) {
                uint8_t maximum = 0U;
                for (uint32_t ky = 0; ky < 2U; ++ky) {
                    for (uint32_t kx = 0; kx < 2U; ++kx) {
                        uint32_t iy = oy + ky, ix = ox + kx;
                        uint8_t value = iy < h && ix < w ?
                            source[(iy * w + ix) * c + ch] : pad;
                        if (value > maximum) maximum = value;
                    }
                }
                destination[(oy * w + ox) * c + ch] = maximum;
            }
        }
    }
}

int main(void)
{
    uint8_t source_data[4 * 4 * 2];
    uint8_t pool_data[2 * 2 * 2];
    coco80_hwc_u8_t source = {4,4,2,sizeof(source_data),source_data};
    coco80_hwc_u8_t pool = {0,0,0,sizeof(pool_data),pool_data};
    for (uint32_t i = 0; i < sizeof(source_data); ++i) source_data[i] = (uint8_t)i;
    CHECK(coco80_maxpool2x2_s2(&source, &pool) == 0);
    CHECK(pool.height == 2 && pool.width == 2 && pool.channels == 2);
    CHECK(pool_data[0] == source_data[(1 * 4 + 1) * 2]);

    {
        uint8_t wide_source[6 * 8 * 5];
        uint8_t wide_pool[3 * 4 * 5] = {0};
        uint8_t wide_reference[3 * 4 * 5] = {0};
        coco80_hwc_u8_t wide = {6,8,5,sizeof(wide_source),wide_source};
        coco80_hwc_u8_t pooled = {0,0,0,sizeof(wide_pool),wide_pool};
        for (uint32_t i = 0; i < sizeof(wide_source); ++i)
            wide_source[i] = (uint8_t)((i * 73U + 19U) & 127U);
        reference_pool_s2(wide_source, 6, 8, 5, wide_reference);
        CHECK(coco80_maxpool2x2_s2(&wide, &pooled) == 0);
        CHECK(memcmp(wide_pool, wide_reference, sizeof(wide_pool)) == 0);
    }

    {
        uint8_t odd_data[2 * 2] = {1,2,3,4};
        uint8_t special_data[2 * 2] = {0};
        coco80_hwc_u8_t odd = {2,2,1,sizeof(odd_data),odd_data};
        coco80_hwc_u8_t special = {0,0,0,sizeof(special_data),special_data};
        CHECK(coco80_maxpool2x2_s1_pad_right_bottom(&odd, 9, &special) == 0);
        CHECK(special_data[0] == 4 && special_data[1] == 9 && special_data[2] == 9 && special_data[3] == 9);
    }
    {
        uint8_t odd_source[3 * 5 * 7];
        uint8_t odd_pool[3 * 5 * 7] = {0};
        uint8_t odd_reference[3 * 5 * 7] = {0};
        coco80_hwc_u8_t odd = {3,5,7,sizeof(odd_source),odd_source};
        coco80_hwc_u8_t special = {0,0,0,sizeof(odd_pool),odd_pool};
        for (uint32_t i = 0; i < sizeof(odd_source); ++i)
            odd_source[i] = (uint8_t)((i * 29U + 3U) & 127U);
        reference_pool_s1_pad(odd_source, 3, 5, 7, 19, odd_reference);
        CHECK(coco80_maxpool2x2_s1_pad_right_bottom(&odd, 19, &special) == 0);
        CHECK(memcmp(odd_pool, odd_reference, sizeof(odd_pool)) == 0);
    }
    {
        uint8_t small_data[2] = {10,20};
        uint8_t route_data[8] = {14,15,16,17,18,19,20,21};
        uint8_t result_data[16] = {0};
        uint8_t upsample_data[8] = {0};
        uint8_t split_data[16] = {0};
        coco80_hwc_u8_t small = {1,2,1,sizeof(small_data),small_data};
        coco80_hwc_u8_t route = {2,4,1,sizeof(route_data),route_data};
        coco80_hwc_u8_t result = {0,0,0,sizeof(result_data),result_data};
        coco80_hwc_u8_t upsample = {0,0,0,sizeof(upsample_data),upsample_data};
        coco80_hwc_u8_t split = {0,0,0,sizeof(split_data),split_data};
        CHECK(coco80_nearest2x_requant_concat(&small,&route,15,7,2,0,&result) == COCO80_TENSOR_ERR_QUANT);
        CHECK(coco80_nearest2x_requant_concat(&small,&route,15,7,4,1,&result) == 0);
        CHECK(result.height == 2 && result.width == 4 && result.channels == 2);
        CHECK(result_data[0] == 10 && result_data[1] == 5);
        CHECK(result_data[2] == 10 && result_data[3] == 7);
        CHECK(result_data[4] == 20 && result_data[5] == 9);
        CHECK(coco80_nearest2x(&small, &upsample) == 0);
        CHECK(upsample.height == 2 && upsample.width == 4 && upsample.channels == 1);
        CHECK(coco80_requant_concat(&upsample,&route,15,7,4,1,&split) == 0);
        CHECK(memcmp(result_data, split_data, sizeof(result_data)) == 0);
    }
    printf("PASS: COCO80_TENSOR_OPS fail=%d\n", failures);
    return failures ? 1 : 0;
}

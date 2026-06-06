#include "yolo_decode.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int failures = 0;

static void check(int condition, const char *message)
{
    if (!condition) {
        printf("FAIL: %s\n", message);
        ++failures;
    }
}

static int nearly_equal(float a, float b, float tolerance)
{
    return fabsf(a - b) <= tolerance;
}

int main(void)
{
    static uint8_t empty_tensor[YOLO_TENSOR_BYTES];
    static uint8_t capacity_tensor[YOLO_TENSOR_BYTES];
    static yolo_detection_t output[YOLO_MAX_CANDIDATES];
    yolo_detection_t small_output[2];
    yolo_detection_t nms_cases[3] = {
        {10.0f, 10.0f, 110.0f, 110.0f, 0.9f, 0U, 2U},
        {12.0f, 12.0f, 108.0f, 108.0f, 0.8f, 0U, 1U},
        {12.0f, 12.0f, 108.0f, 108.0f, 0.7f, 1U, 0U},
    };
    yolo_detection_t model = {0.0f, 59.0f, 416.0f, 416.0f, 0.5f, 0U, 0U};
    yolo_detection_t original;
    char formatted[32];
    int count;
    uint32_t kept;

    memset(empty_tensor, 0, sizeof(empty_tensor));
    count = yolo_decode_single_scale(empty_tensor, 0.25f, 0.45f, output, YOLO_MAX_CANDIDATES);
    check(count == 0, "zero tensor should produce no candidates");

    memset(capacity_tensor, 0, sizeof(capacity_tensor));
    {
        static const uint8_t candidate[YOLO_VALUES_PER_ANCHOR] = {
            80U, 80U, 80U, 80U, 100U, 100U, 0U, 0U
        };
        memcpy(&capacity_tensor[0], candidate, sizeof(candidate));
        memcpy(&capacity_tensor[YOLO_CHANNELS], candidate, sizeof(candidate));
    }
    memset(small_output, 0, sizeof(small_output));
    small_output[1].source_index = 0x12345678U;
    count = yolo_decode_single_scale(capacity_tensor, 0.25f, 0.45f, small_output, 1U);
    check(count == 1, "decode should respect the requested output capacity");
    check(small_output[1].source_index == 0x12345678U, "decode should not overrun output capacity");

    kept = yolo_class_aware_nms(nms_cases, 3U, 0.45f, 3U);
    check(kept == 2U, "same-class overlap should be suppressed while different class remains");
    check(nms_cases[0].source_index == 2U, "highest score should sort first");
    check(nms_cases[1].class_id == 1U, "different-class overlap should remain");

    yolo_inverse_letterbox(&model, 512.0f, 366.0f, 0.8125f, 0.0f, 59.0f, &original);
    check(nearly_equal(original.x1, 0.0f, 0.001f), "inverse letterbox x1");
    check(nearly_equal(original.y1, 0.0f, 0.001f), "inverse letterbox y1");
    check(nearly_equal(original.x2, 512.0f, 0.001f), "inverse letterbox x2");
    check(nearly_equal(original.y2, 366.0f, 0.001f), "inverse letterbox clips y2");

    yolo_format_fixed6(1.2345674f, formatted, sizeof(formatted));
    check(strcmp(formatted, "1.234567") == 0, "fixed-point formatting");

    if (failures != 0) {
        printf("FAIL: yolo decode C tests failures=%d\n", failures);
        return 1;
    }
    printf("PASS: yolo decode C unit tests\n");
    return 0;
}

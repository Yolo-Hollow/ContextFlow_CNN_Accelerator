#include "yolo_decode.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int read_tensor(const char *path, uint8_t tensor[YOLO_TENSOR_BYTES])
{
    FILE *stream = fopen(path, "rb");
    size_t bytes;
    if (stream == 0) {
        return -1;
    }
    bytes = fread(tensor, 1U, YOLO_TENSOR_BYTES, stream);
    fclose(stream);
    return (bytes == YOLO_TENSOR_BYTES) ? 0 : -1;
}

static void print_detection(uint32_t index, const yolo_detection_t *model)
{
    yolo_detection_t original;
    char score[32];
    char model_x1[32];
    char model_y1[32];
    char model_x2[32];
    char model_y2[32];
    char orig_x1[32];
    char orig_y1[32];
    char orig_x2[32];
    char orig_y2[32];

    yolo_inverse_letterbox(model, 512.0f, 366.0f, 0.8125f, 0.0f, 59.0f, &original);
    yolo_format_fixed6(model->score, score, sizeof(score));
    yolo_format_fixed6(model->x1, model_x1, sizeof(model_x1));
    yolo_format_fixed6(model->y1, model_y1, sizeof(model_y1));
    yolo_format_fixed6(model->x2, model_x2, sizeof(model_x2));
    yolo_format_fixed6(model->y2, model_y2, sizeof(model_y2));
    yolo_format_fixed6(original.x1, orig_x1, sizeof(orig_x1));
    yolo_format_fixed6(original.y1, orig_y1, sizeof(orig_y1));
    yolo_format_fixed6(original.x2, orig_x2, sizeof(orig_x2));
    yolo_format_fixed6(original.y2, orig_y2, sizeof(orig_y2));

    printf(
        "DET index=%lu class=%lu name=%s score=%s "
        "model_x1=%s model_y1=%s model_x2=%s model_y2=%s "
        "orig_x1=%s orig_y1=%s orig_x2=%s orig_y2=%s\n",
        (unsigned long)index,
        (unsigned long)model->class_id,
        yolo_class_name(model->class_id),
        score,
        model_x1,
        model_y1,
        model_x2,
        model_y2,
        orig_x1,
        orig_y1,
        orig_x2,
        orig_y2);
}

int main(int argc, char **argv)
{
    static uint8_t tensor[YOLO_TENSOR_BYTES];
    static yolo_detection_t detections[YOLO_MAX_CANDIDATES];
    int count;
    int index;

    if (argc != 2) {
        fprintf(stderr, "usage: yolo_decode_host <tensor.bin>\n");
        return 2;
    }
    if (read_tensor(argv[1], tensor) != 0) {
        fprintf(stderr, "failed to read %u tensor bytes\n", (unsigned)YOLO_TENSOR_BYTES);
        return 2;
    }
    count = yolo_decode_single_scale(tensor, 0.25f, 0.45f, detections, YOLO_MAX_CANDIDATES);
    if (count < 0) {
        fprintf(stderr, "decode failed rc=%d\n", count);
        return 1;
    }
    printf("DECODE count=%d\n", count);
    for (index = 0; index < count; ++index) {
        print_detection((uint32_t)index, &detections[index]);
    }
    return 0;
}

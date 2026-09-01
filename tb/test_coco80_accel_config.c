#include "coco80_generated_config.h"

#include <limits.h>
#include <stdio.h>
#include <string.h>

int main(void)
{
    static const unsigned upstream[13] = {
        UINT_MAX, 0U, 1U, 2U, 3U, 4U, 5U, 6U, 7U, 7U, 9U, 10U, 8U
    };
    unsigned index, bad = 0U, bias_offset = 0U, weight_offset = 0U;
    coco80_accel_plan_summary_t summary;
    if (coco80_accel_plan_summary(&summary) != 0) {
        printf("plan summary ifm=%u ofm=%u bias=%u weight=%u contexts=%u max_ifm=%u max_ofm=%u\n",
               summary.total_ifm_bytes, summary.total_ofm_bytes,
               summary.total_bias_bytes, summary.total_weight_bytes,
               summary.total_contexts, summary.max_ifm_bytes, summary.max_ofm_bytes);
        ++bad;
    }
    if (summary.total_ofm_bytes != 2270515U || summary.max_ofm_bytes != 692224U) {
        puts("fused pool OFM summary"); ++bad;
    }
    if (coco80_runtime_config.config_crc32 !=
        coco80_accel_config_crc32(&coco80_runtime_config)) { puts("config crc"); ++bad; }
    for (index = 0U; index < 13U; ++index) {
        const coco80_accel_layer_plan_t *plan = coco80_accel_plan(index);
        const coco80_accel_layer_binding_t *binding = &coco80_runtime_layer_bindings[index];
        if (binding->bias_offset != bias_offset || binding->bias_bytes != plan->bias_bytes ||
            binding->weight_offset != weight_offset || binding->weight_bytes != plan->weight_bytes ||
            binding->bias_packets != plan->bias_packets ||
            binding->weight_packets != plan->weight_packets ||
            binding->quant_multiplier == 0U || binding->quant_multiplier > 65535U ||
            binding->quant_shift > 15U || binding->activation_lut_offset != index * 256U ||
            binding->activation_lut_crc32 == 0U ||
            (binding->bias_offset & 63U) != 0U || (binding->weight_offset & 63U) != 0U) {
            printf("binding %u\n", index); ++bad;
        }
        if (plan->pool_stride != (index < 4U ? 2U : 0U)) {
            printf("pool stride %u\n", index); ++bad;
        }
        if (upstream[index] != UINT_MAX) {
            const coco80_accel_layer_binding_t *source =
                &coco80_runtime_layer_bindings[upstream[index]];
            if (binding->input_scale_f32 != source->output_scale_f32 ||
                binding->input_zero_point != source->output_zero_point) {
                printf("edge %u <- %u\n", index, upstream[index]); ++bad;
            }
        }
        bias_offset += binding->bias_bytes;
        weight_offset += binding->weight_bytes;
    }
    printf("validate=%d bad=%u bias=%u weight=%u route=%u/%u\n",
           coco80_accel_validate_config(&coco80_runtime_config), bad,
           bias_offset, weight_offset, coco80_runtime_config.route_input_zero_point,
           coco80_runtime_config.route_output_zero_point);
    return bad == 0U && coco80_accel_validate_config(&coco80_runtime_config) == 0 ? 0 : 1;
}

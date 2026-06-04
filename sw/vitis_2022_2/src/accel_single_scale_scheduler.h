#ifndef ACCEL_SINGLE_SCALE_SCHEDULER_H
#define ACCEL_SINGLE_SCALE_SCHEDULER_H

#include "accel_smoke.h"
#include "accel_single_scale_plan.h"

#include <stdint.h>

#define ACCEL_SINGLE_SCALE_BUFFER_EXTERNAL 0xffffffffU

typedef struct {
    const accel_single_scale_layer_plan_t *plan;
    uint32_t conv_w;
    uint32_t conv_h;
    uint32_t final_w;
    uint32_t final_h;
    uint32_t input_bytes;
    uint32_t output_bytes;
    uint32_t ofm_axis_bytes;
    uint32_t tile_oy_base;
    uint32_t tile_ofm_h;
    uint32_t tile_pixel_base;
    uint32_t tile_pixels;
    uint32_t tile_count;
    uint32_t max_tile_ofm_h;
    uint32_t max_tile_pixels;
    uint32_t max_tile_output_pixels;
    uint32_t max_tile_ofm_bytes;
    uint32_t max_tile_axis_bytes;
    uint32_t expected_output_pixels;
    uint32_t input_buffer_id;
    uint32_t output_buffer_id;
} accel_single_scale_layer_schedule_t;

typedef struct {
    uint32_t layer_count;
    uint32_t external_input_bytes;
    uint32_t feature_buffer_bytes[2];
    uint32_t max_ofm_axis_bytes;
    uint32_t max_tile_axis_bytes;
    uint32_t total_output_bytes;
    uint32_t total_spatial_tiles;
    uint32_t total_schedule_blocks;
} accel_single_scale_schedule_summary_t;

static uint32_t accel_ceil_div_u32(uint32_t value, uint32_t divisor)
{
    return (value + divisor - 1U) / divisor;
}

static uint32_t accel_conv_out_dim_u32(uint32_t input, uint32_t kernel,
                                       uint32_t stride, uint32_t pad)
{
    return ((input + (2U * pad) - kernel) / stride) + 1U;
}

static int accel_single_scale_make_layer_schedule(
    const accel_single_scale_layer_plan_t *layer,
    uint32_t layer_index,
    const accel_single_scale_layer_schedule_t *prev,
    accel_single_scale_layer_schedule_t *schedule)
{
    uint32_t conv_w;
    uint32_t conv_h;
    uint32_t final_w;
    uint32_t final_h;
    uint32_t input_bytes;
    uint32_t output_bytes;
    uint32_t expected_pixels;
    uint32_t max_tile_h;
    uint32_t tile_count;
    uint32_t last_tile_h;
    uint32_t max_tile_output_pixels;

    if (layer == 0 || schedule == 0) {
        return -1;
    }
    if (layer->kernel == 0U || layer->stride == 0U) {
        return -2;
    }
    if (layer->pool_enable != 0U && layer->pool_stride == 0U) {
        return -3;
    }

    conv_w = accel_conv_out_dim_u32(layer->fm_w, layer->kernel, layer->stride, layer->pad);
    conv_h = accel_conv_out_dim_u32(layer->fm_h, layer->kernel, layer->stride, layer->pad);
    final_w = conv_w;
    final_h = conv_h;
    if (layer->pool_enable != 0U) {
        if ((conv_w % layer->pool_stride) != 0U || (conv_h % layer->pool_stride) != 0U) {
            return -4;
        }
        final_w = conv_w / layer->pool_stride;
        final_h = conv_h / layer->pool_stride;
    }

    input_bytes = (uint32_t)layer->fm_w * (uint32_t)layer->fm_h * (uint32_t)layer->cin;
    expected_pixels = final_w * final_h;
    output_bytes = expected_pixels * (uint32_t)layer->cout_total;

    if (layer->conv_pixels != (conv_w * conv_h)) {
        return -10;
    }
    if (layer->final_pixels != expected_pixels) {
        return -11;
    }
    if (layer->expected_ofm_bytes != output_bytes) {
        return -12;
    }
    if (layer->k_total != ((uint32_t)layer->cin * (uint32_t)layer->kernel * (uint32_t)layer->kernel)) {
        return -13;
    }
    if (layer->k_passes != accel_ceil_div_u32(layer->k_total, ACCEL_SINGLE_SCALE_ROWS)) {
        return -14;
    }
    if (layer->cout_blocks != accel_ceil_div_u32(layer->cout_total, ACCEL_SINGLE_SCALE_COUT_TILE)) {
        return -15;
    }
    if (ACCEL_SINGLE_SCALE_MAX_TILE_OFM_H == 0U) {
        return -16;
    }

    if (layer_index > 0U) {
        if (prev == 0) {
            return -20;
        }
        if (layer->fm_w != prev->final_w || layer->fm_h != prev->final_h ||
            layer->cin != prev->plan->cout_total) {
            return -21;
        }
    }

    max_tile_h = ACCEL_SINGLE_SCALE_MAX_TILE_OFM_H;
    if (layer->pool_enable != 0U) {
        if ((max_tile_h % layer->pool_stride) != 0U) {
            max_tile_h -= (max_tile_h % layer->pool_stride);
        }
        if (max_tile_h == 0U) {
            return -30;
        }
    }
    if (max_tile_h > conv_h) {
        max_tile_h = conv_h;
    }

    tile_count = accel_ceil_div_u32(conv_h, max_tile_h);
    last_tile_h = conv_h - ((tile_count - 1U) * max_tile_h);
    if (layer->pool_enable != 0U && (last_tile_h % layer->pool_stride) != 0U) {
        return -31;
    }

    max_tile_output_pixels = conv_w * max_tile_h;
    if (layer->pool_enable != 0U) {
        max_tile_output_pixels = (conv_w / layer->pool_stride) *
                                 (max_tile_h / layer->pool_stride);
    }

    schedule->plan = layer;
    schedule->conv_w = conv_w;
    schedule->conv_h = conv_h;
    schedule->final_w = final_w;
    schedule->final_h = final_h;
    schedule->input_bytes = input_bytes;
    schedule->output_bytes = output_bytes;
    schedule->ofm_axis_bytes = output_bytes * OFM_AXIS_BEAT_BYTES;
    schedule->tile_oy_base = 0U;
    schedule->tile_ofm_h = max_tile_h;
    schedule->tile_pixel_base = 0U;
    schedule->tile_pixels = conv_w * max_tile_h;
    schedule->tile_count = tile_count;
    schedule->max_tile_ofm_h = max_tile_h;
    schedule->max_tile_pixels = conv_w * max_tile_h;
    schedule->max_tile_output_pixels = max_tile_output_pixels;
    schedule->max_tile_ofm_bytes = max_tile_output_pixels * (uint32_t)layer->cout_total;
    schedule->max_tile_axis_bytes = schedule->max_tile_ofm_bytes * OFM_AXIS_BEAT_BYTES;
    schedule->expected_output_pixels = expected_pixels;
    schedule->input_buffer_id = (layer_index == 0U) ?
        ACCEL_SINGLE_SCALE_BUFFER_EXTERNAL : prev->output_buffer_id;
    schedule->output_buffer_id = layer_index & 1U;

    if (layer_index > 0U && schedule->input_buffer_id == schedule->output_buffer_id) {
        return -22;
    }

    return 0;
}

static int accel_single_scale_dry_run(
    accel_single_scale_layer_schedule_t *schedule,
    uint32_t schedule_count,
    accel_single_scale_schedule_summary_t *summary)
{
    uint32_t i;

    if (schedule == 0 || summary == 0) {
        return -1;
    }
    if (schedule_count < ACCEL_SINGLE_SCALE_LAYER_COUNT) {
        return -2;
    }
    if (ACCEL_SINGLE_SCALE_COUT_TILE != (ACCEL_SINGLE_SCALE_COLS * 2U)) {
        return -3;
    }
    if (ACCEL_SINGLE_SCALE_ROWS != ROWS || ACCEL_SINGLE_SCALE_COLS != COLS ||
        ACCEL_SINGLE_SCALE_IFM_BANKS != IFM_BANKS ||
        ACCEL_SINGLE_SCALE_COUT_TILE != COUT_TILE) {
        return -4;
    }

    summary->layer_count = ACCEL_SINGLE_SCALE_LAYER_COUNT;
    summary->external_input_bytes = 0U;
    summary->feature_buffer_bytes[0] = 0U;
    summary->feature_buffer_bytes[1] = 0U;
    summary->max_ofm_axis_bytes = 0U;
    summary->max_tile_axis_bytes = 0U;
    summary->total_output_bytes = 0U;
    summary->total_spatial_tiles = 0U;
    summary->total_schedule_blocks = 0U;

    for (i = 0U; i < ACCEL_SINGLE_SCALE_LAYER_COUNT; ++i) {
        const accel_single_scale_layer_schedule_t *prev = (i == 0U) ? 0 : &schedule[i - 1U];
        int rc = accel_single_scale_make_layer_schedule(&accel_single_scale_plan[i], i, prev, &schedule[i]);
        uint32_t out_id;

        if (rc != 0) {
            return -100 - (int)i;
        }

        if (i == 0U) {
            summary->external_input_bytes = schedule[i].input_bytes;
        }

        out_id = schedule[i].output_buffer_id;
        if (schedule[i].output_bytes > summary->feature_buffer_bytes[out_id]) {
            summary->feature_buffer_bytes[out_id] = schedule[i].output_bytes;
        }
        if (schedule[i].ofm_axis_bytes > summary->max_ofm_axis_bytes) {
            summary->max_ofm_axis_bytes = schedule[i].ofm_axis_bytes;
        }
        if (schedule[i].max_tile_axis_bytes > summary->max_tile_axis_bytes) {
            summary->max_tile_axis_bytes = schedule[i].max_tile_axis_bytes;
        }
        summary->total_output_bytes += schedule[i].output_bytes;
        summary->total_spatial_tiles += schedule[i].tile_count;
        summary->total_schedule_blocks += schedule[i].tile_count *
                                          schedule[i].plan->cout_blocks;
    }

    return 0;
}

#endif

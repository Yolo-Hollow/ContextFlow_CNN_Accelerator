#include "coco80_multicore.h"

#include "xil_cache.h"
#include "xil_mmu.h"
#include "xtime_l.h"

#include <stddef.h>
#include <string.h>

typedef char coco80_mc_task_must_be_128_bytes[
    sizeof(coco80_mc_task_t) == 128U ? 1 : -1];
typedef char coco80_mc_mailbox_header_must_be_64_bytes[
    offsetof(coco80_mc_mailbox_t, tasks) == 64U ? 1 : -1];

static void c8_mc_barrier(void)
{
    __asm__ volatile("dmb sy" ::: "memory");
}

static void c8_mc_event(void)
{
    __asm__ volatile("sev" ::: "memory");
}

static void c8_mc_wait_event(void)
{
    __asm__ volatile("wfe" ::: "memory");
}

static int c8_mc_inner_region_bounds(
    uintptr_t address, uint32_t bytes, uintptr_t *first, uintptr_t *limit)
{
    uintptr_t end;
    if (bytes == 0U || first == NULL || limit == NULL ||
        (address & (COCO80_MC_TLB_BLOCK_BYTES - 1U)) != 0U ||
        address >= 0x80000000U || bytes > 0x80000000U - address)
        return COCO80_TENSOR_ERR_ARGUMENT;
    end = address + bytes;
    *first = address & ~(uintptr_t)(COCO80_MC_TLB_BLOCK_BYTES - 1U);
    *limit = (end + COCO80_MC_TLB_BLOCK_BYTES - 1U) &
        ~(uintptr_t)(COCO80_MC_TLB_BLOCK_BYTES - 1U);
    if (*limit <= *first || *limit > 0x80000000U ||
        (*first < COCO80_MC_MAILBOX_ADDRESS + COCO80_MC_TLB_BLOCK_BYTES &&
         *limit > (COCO80_MC_MAILBOX_ADDRESS &
                   ~(uintptr_t)(COCO80_MC_TLB_BLOCK_BYTES - 1U))))
        return COCO80_TENSOR_ERR_ARGUMENT;
    return COCO80_TENSOR_OK;
}

int coco80_mc_set_inner_shareable_region(void *region, uint32_t region_bytes)
{
    uintptr_t address = (uintptr_t)region;
    uintptr_t block, limit;
    int rc = c8_mc_inner_region_bounds(
        address, region_bytes, &block, &limit);
    if (rc != COCO80_TENSOR_OK) return rc;
    /* The EL2 chain-loader (or the Xilinx EL3 boot path) establishes SMPEN.
     * CPUECTLR_EL1 is deliberately not accessed from Non-Secure EL1. */
    for (; block < limit; block += COCO80_MC_TLB_BLOCK_BYTES)
        Xil_SetTlbAttributes(block, COCO80_MC_INNER_WB_ATTRIBUTE);
    c8_mc_barrier();
    return COCO80_TENSOR_OK;
}

static uint64_t c8_mc_now(void)
{
    XTime value;
    XTime_GetTime(&value);
    return (uint64_t)value;
}

static void c8_mc_set_mailbox_attributes(void)
{
    Xil_SetTlbAttributes(
        COCO80_MC_MAILBOX_ADDRESS, NORM_NONCACHE | INNER_SHAREABLE);
    c8_mc_barrier();
}

static void c8_mc_clear_mailbox(coco80_mc_mailbox_t *mailbox)
{
    volatile uint32_t *words = (volatile uint32_t *)(uintptr_t)mailbox;
    uint32_t index;
    for (index = 0U; index < sizeof(*mailbox) / sizeof(uint32_t); ++index)
        words[index] = 0U;
}

static uint32_t c8_mc_tensor_bytes(uint32_t h, uint32_t w, uint32_t c)
{
    uint64_t value = (uint64_t)h * w * c;
    return value <= UINT32_MAX ? (uint32_t)value : 0U;
}

static void c8_mc_flush_channel_range(
    uint8_t *destination, uint32_t pixels, uint32_t channels,
    uint32_t begin, uint32_t end)
{
    uint32_t pixel;
    for (pixel = 0U; pixel < pixels; ++pixel) {
        Xil_DCacheFlushRange(
            (UINTPTR)(destination + pixel * channels + begin), end - begin);
    }
}

static void c8_mc_flush_pixel_range(
    uint8_t *destination, uint32_t channels,
    uint32_t begin, uint32_t end)
{
    Xil_DCacheFlushRange(
        (UINTPTR)(destination + begin * channels), (end - begin) * channels);
}

static int c8_mc_wait_workers(
    coco80_mc_controller_t *controller, uint32_t generation)
{
    uint64_t deadline = c8_mc_now() + controller->timeout_ticks;
    uint32_t index;
    for (;;) {
        uint32_t complete = 0U;
        c8_mc_barrier();
        for (index = 0U; index < COCO80_MC_WORKERS; ++index) {
            const coco80_mc_task_t *task = &controller->mailbox->tasks[index];
            if (task->generation != generation) return COCO80_TENSOR_ERR_ARGUMENT;
            if (task->state == COCO80_MC_TASK_ERROR) return task->status;
            if (task->state == COCO80_MC_TASK_DONE) complete += 1U;
        }
        if (complete == COCO80_MC_WORKERS) return COCO80_TENSOR_OK;
        if (c8_mc_now() > deadline) return COCO80_TENSOR_ERR_ARGUMENT;
    }
}

static void c8_mc_publish(coco80_mc_controller_t *controller)
{
    uint32_t index;
    c8_mc_barrier();
    for (index = 0U; index < COCO80_MC_WORKERS; ++index)
        controller->mailbox->tasks[index].state = COCO80_MC_TASK_READY;
    c8_mc_barrier();
    c8_mc_event();
}

int coco80_mc_controller_initialize(
    coco80_mc_controller_t *controller,
    uint64_t timeout_ticks,
    void *shared_region,
    uint32_t shared_region_bytes)
{
    coco80_mc_mailbox_t *mailbox =
        (coco80_mc_mailbox_t *)COCO80_MC_MAILBOX_ADDRESS;
    uint64_t deadline;
    uint32_t index;
    int rc;
    if (controller == NULL || timeout_ticks == 0U || shared_region == NULL)
        return COCO80_TENSOR_ERR_ARGUMENT;
    memset(controller, 0, sizeof(*controller));
    c8_mc_set_mailbox_attributes();
    c8_mc_clear_mailbox(mailbox);
    mailbox->magic = COCO80_MC_MAGIC;
    mailbox->version = COCO80_MC_VERSION;
    mailbox->shared_region_base = (uint64_t)(uintptr_t)shared_region;
    mailbox->shared_region_bytes = shared_region_bytes;
    mailbox->shared_region_attribute = COCO80_MC_INNER_WB_ATTRIBUTE;
    rc = coco80_mc_set_inner_shareable_region(
        shared_region, shared_region_bytes);
    if (rc != COCO80_TENSOR_OK) {
        mailbox->last_error = rc;
        return rc;
    }
    mailbox->controller_ready = 1U;
    c8_mc_barrier();
    c8_mc_event();
    deadline = c8_mc_now() + timeout_ticks;
    for (;;) {
        uint32_t ready = 0U;
        c8_mc_barrier();
        for (index = 0U; index < COCO80_MC_WORKERS; ++index) {
            if ((mailbox->worker_ready[index] & 0x80000000U) != 0U)
                return mailbox->last_error != 0 ? mailbox->last_error :
                    COCO80_TENSOR_ERR_ARGUMENT;
            ready += mailbox->worker_ready[index] == index + 1U ? 1U : 0U;
        }
        if (ready == COCO80_MC_WORKERS) break;
        if (c8_mc_now() > deadline) return COCO80_TENSOR_ERR_ARGUMENT;
    }
    controller->mailbox = mailbox;
    controller->generation = 0U;
    controller->timeout_ticks = timeout_ticks;
    controller->initialized = 1U;
    return COCO80_TENSOR_OK;
}

static int c8_mc_check_controller(coco80_mc_controller_t *controller)
{
    return controller != NULL && controller->initialized != 0U &&
        controller->mailbox != NULL &&
        controller->mailbox->magic == COCO80_MC_MAGIC &&
        controller->mailbox->version == COCO80_MC_VERSION;
}

int coco80_mc_pool_s2(
    coco80_mc_controller_t *controller,
    const coco80_hwc_u8_t *source,
    coco80_hwc_u8_t *destination)
{
    uint32_t index, channels_per_worker, generation, output_bytes, output_pixels;
    int rc;
    if (!c8_mc_check_controller(controller) || source == NULL || destination == NULL ||
        source->channels == 0U || (source->channels & 3U) != 0U)
        return COCO80_TENSOR_ERR_ARGUMENT;
    output_bytes = c8_mc_tensor_bytes(
        source->height / 2U, source->width / 2U, source->channels);
    if (output_bytes == 0U || destination->bytes < output_bytes)
        return COCO80_TENSOR_ERR_CAPACITY;
    channels_per_worker = source->channels / 4U;
    output_pixels = (source->height / 2U) * (source->width / 2U);
    Xil_DCacheFlushRange((UINTPTR)source->data, source->bytes);
    Xil_DCacheInvalidateRange((UINTPTR)destination->data, output_bytes);
    generation = ++controller->generation;
    if (generation == 0U) generation = ++controller->generation;
    for (index = 0U; index < COCO80_MC_WORKERS; ++index) {
        coco80_mc_task_t *task = &controller->mailbox->tasks[index];
        memset((void *)task, 0, sizeof(*task));
        task->generation = generation;
        task->operation = COCO80_MC_OP_POOL_S2;
        task->source0 = (uint64_t)(uintptr_t)source->data;
        task->destination = (uint64_t)(uintptr_t)destination->data;
        task->height = source->height; task->width = source->width;
        task->channels0 = source->channels;
        task->range_begin = (index + 1U) * channels_per_worker;
        task->range_end = (index + 2U) * channels_per_worker;
    }
    c8_mc_publish(controller);
    rc = coco80_maxpool2x2_s2_channel_range(
        source, destination, 0U, channels_per_worker);
    c8_mc_flush_channel_range(
        destination->data, output_pixels, source->channels, 0U, channels_per_worker);
    if (rc == COCO80_TENSOR_OK) rc = c8_mc_wait_workers(controller, generation);
    Xil_DCacheInvalidateRange((UINTPTR)destination->data, output_bytes);
    return rc;
}

int coco80_mc_pool_s1_pad(
    coco80_mc_controller_t *controller,
    const coco80_hwc_u8_t *source,
    uint8_t pad_value,
    coco80_hwc_u8_t *destination)
{
    uint32_t index, channels_per_worker, generation, output_bytes, output_pixels;
    int rc;
    if (!c8_mc_check_controller(controller) || source == NULL || destination == NULL ||
        source->channels == 0U || (source->channels & 3U) != 0U)
        return COCO80_TENSOR_ERR_ARGUMENT;
    output_bytes = c8_mc_tensor_bytes(source->height, source->width, source->channels);
    if (output_bytes == 0U || destination->bytes < output_bytes)
        return COCO80_TENSOR_ERR_CAPACITY;
    channels_per_worker = source->channels / 4U;
    output_pixels = source->height * source->width;
    Xil_DCacheFlushRange((UINTPTR)source->data, source->bytes);
    Xil_DCacheInvalidateRange((UINTPTR)destination->data, output_bytes);
    generation = ++controller->generation;
    if (generation == 0U) generation = ++controller->generation;
    for (index = 0U; index < COCO80_MC_WORKERS; ++index) {
        coco80_mc_task_t *task = &controller->mailbox->tasks[index];
        memset((void *)task, 0, sizeof(*task));
        task->generation = generation;
        task->operation = COCO80_MC_OP_POOL_S1_PAD;
        task->source0 = (uint64_t)(uintptr_t)source->data;
        task->destination = (uint64_t)(uintptr_t)destination->data;
        task->height = source->height; task->width = source->width;
        task->channels0 = source->channels; task->pad_value = pad_value;
        task->range_begin = (index + 1U) * channels_per_worker;
        task->range_end = (index + 2U) * channels_per_worker;
    }
    c8_mc_publish(controller);
    rc = coco80_maxpool2x2_s1_pad_right_bottom_channel_range(
        source, pad_value, destination, 0U, channels_per_worker);
    c8_mc_flush_channel_range(
        destination->data, output_pixels, source->channels, 0U, channels_per_worker);
    if (rc == COCO80_TENSOR_OK) rc = c8_mc_wait_workers(controller, generation);
    Xil_DCacheInvalidateRange((UINTPTR)destination->data, output_bytes);
    return rc;
}

int coco80_mc_nearest_requant_concat(
    coco80_mc_controller_t *controller,
    const coco80_hwc_u8_t *small,
    const coco80_hwc_u8_t *route,
    int32_t input_zero_point,
    int32_t output_zero_point,
    uint32_t multiplier,
    uint32_t shift,
    coco80_hwc_u8_t *destination)
{
    uint32_t index, pixels, pixels_per_worker, generation, output_channels, output_bytes;
    int rc;
    if (!c8_mc_check_controller(controller) || small == NULL || route == NULL ||
        destination == NULL || route->height != small->height * 2U ||
        route->width != small->width * 2U)
        return COCO80_TENSOR_ERR_ARGUMENT;
    pixels = route->height * route->width;
    if ((pixels & 3U) != 0U) return COCO80_TENSOR_ERR_SHAPE;
    pixels_per_worker = pixels / 4U;
    output_channels = small->channels + route->channels;
    output_bytes = c8_mc_tensor_bytes(route->height, route->width, output_channels);
    if (output_bytes == 0U || destination->bytes < output_bytes)
        return COCO80_TENSOR_ERR_CAPACITY;
    Xil_DCacheFlushRange((UINTPTR)small->data, small->bytes);
    Xil_DCacheFlushRange((UINTPTR)route->data, route->bytes);
    Xil_DCacheInvalidateRange((UINTPTR)destination->data, output_bytes);
    generation = ++controller->generation;
    if (generation == 0U) generation = ++controller->generation;
    for (index = 0U; index < COCO80_MC_WORKERS; ++index) {
        coco80_mc_task_t *task = &controller->mailbox->tasks[index];
        memset((void *)task, 0, sizeof(*task));
        task->generation = generation;
        task->operation = COCO80_MC_OP_NEAREST_REQUANT_CONCAT;
        task->source0 = (uint64_t)(uintptr_t)small->data;
        task->source1 = (uint64_t)(uintptr_t)route->data;
        task->destination = (uint64_t)(uintptr_t)destination->data;
        task->height = small->height; task->width = small->width;
        task->channels0 = small->channels; task->channels1 = route->channels;
        task->input_zero_point = input_zero_point;
        task->output_zero_point = output_zero_point;
        task->multiplier = multiplier; task->shift = shift;
        task->range_begin = (index + 1U) * pixels_per_worker;
        task->range_end = (index + 2U) * pixels_per_worker;
    }
    c8_mc_publish(controller);
    rc = coco80_nearest2x_requant_concat_pixel_range(
        small, route, input_zero_point, output_zero_point, multiplier, shift,
        destination, 0U, pixels_per_worker);
    c8_mc_flush_pixel_range(
        destination->data, output_channels, 0U, pixels_per_worker);
    if (rc == COCO80_TENSOR_OK) rc = c8_mc_wait_workers(controller, generation);
    Xil_DCacheInvalidateRange((UINTPTR)destination->data, output_bytes);
    return rc;
}

#ifdef COCO80_MC_ENABLE_CPU_CONV
static void c8_mc_channel_partition(
    uint32_t channels, uint32_t part, uint32_t *begin, uint32_t *end)
{
    uint32_t blocks = (channels + 7U) / 8U;
    uint32_t base = blocks / 4U;
    uint32_t extra = blocks % 4U;
    uint32_t first_block = part * base + (part < extra ? part : extra);
    uint32_t block_count = base + (part < extra ? 1U : 0U);
    *begin = first_block * 8U;
    *end = (first_block + block_count) * 8U;
    if (*begin > channels) *begin = channels;
    if (*end > channels) *end = channels;
}

int coco80_mc_cpu_conv_kco(
    coco80_mc_controller_t *controller,
    const uint8_t *ifm,
    uint8_t *ofm,
    const int8_t *weight_kco,
    const int32_t *bias_i32,
    const uint8_t *activation_lut_u8,
    const coco80_cpu_layer_t *layer)
{
    uint32_t index, generation, begin, end;
    int rc;
    if (!c8_mc_check_controller(controller) || ifm == NULL || ofm == NULL ||
        weight_kco == NULL || bias_i32 == NULL || activation_lut_u8 == NULL ||
        layer == NULL || layer->ifm_h != layer->ofm_h ||
        layer->ifm_w != layer->ofm_w)
        return COCO80_CPU_ERR_ARGUMENT;
    generation = ++controller->generation;
    if (generation == 0U) generation = ++controller->generation;
    for (index = 0U; index < COCO80_MC_WORKERS; ++index) {
        coco80_mc_task_t *task = &controller->mailbox->tasks[index];
        memset((void *)task, 0, sizeof(*task));
        c8_mc_channel_partition(layer->ofm_c, index + 1U, &begin, &end);
        task->generation = generation;
        task->operation = COCO80_MC_OP_CPU_CONV_KCO;
        task->source0 = (uint64_t)(uintptr_t)ifm;
        task->source1 = (uint64_t)(uintptr_t)weight_kco;
        task->destination = (uint64_t)(uintptr_t)ofm;
        task->auxiliary0 = (uint64_t)(uintptr_t)bias_i32;
        task->auxiliary1 = (uint64_t)(uintptr_t)activation_lut_u8;
        task->height = layer->ifm_h; task->width = layer->ifm_w;
        task->channels0 = layer->ifm_c; task->channels1 = layer->ofm_c;
        task->pad_value = layer->kernel | (layer->pad << 8U) |
            (layer->stride << 16U);
        task->input_zero_point = (int32_t)layer->input_zero_point;
        task->output_zero_point = (int32_t)layer->output_zero_point;
        task->multiplier = layer->quant_mult; task->shift = layer->quant_shift;
        task->range_begin = begin; task->range_end = end;
    }
    c8_mc_channel_partition(layer->ofm_c, 0U, &begin, &end);
    c8_mc_publish(controller);
    rc = coco80_cpu_conv_kco_range(
        ifm, ofm, weight_kco, bias_i32, activation_lut_u8,
        layer, begin, end);
    if (rc == COCO80_CPU_OK) rc = c8_mc_wait_workers(controller, generation);
    return rc;
}
#endif

static int c8_mc_worker_execute(const coco80_mc_task_t *task)
{
    coco80_hwc_u8_t source0, source1, destination;
    uint32_t source0_bytes, source1_bytes = 0U, destination_bytes;
    uint32_t output_h, output_w, output_channels;
    int rc;
    source0.height = task->height; source0.width = task->width;
    source0.channels = task->channels0;
    source0_bytes = c8_mc_tensor_bytes(source0.height, source0.width, source0.channels);
    source0.bytes = source0_bytes;
    source0.data = (uint8_t *)(uintptr_t)task->source0;
    source1.data = (uint8_t *)(uintptr_t)task->source1;
    destination.data = (uint8_t *)(uintptr_t)task->destination;
    if (source0_bytes == 0U || source0.data == NULL || destination.data == NULL)
        return COCO80_TENSOR_ERR_ARGUMENT;
#ifdef COCO80_MC_ENABLE_CPU_CONV
    if (task->operation == COCO80_MC_OP_CPU_CONV_KCO) {
        coco80_cpu_layer_t layer;
        memset(&layer, 0, sizeof(layer));
        layer.ifm_h = task->height; layer.ifm_w = task->width;
        layer.ifm_c = task->channels0;
        layer.ofm_h = task->height; layer.ofm_w = task->width;
        layer.ofm_c = task->channels1;
        layer.kernel = task->pad_value & 0xFFU;
        layer.pad = (task->pad_value >> 8U) & 0xFFU;
        layer.stride = (task->pad_value >> 16U) & 0xFFU;
        layer.input_zero_point = (uint32_t)task->input_zero_point;
        layer.output_zero_point = (uint32_t)task->output_zero_point;
        layer.quant_mult = task->multiplier; layer.quant_shift = task->shift;
        return coco80_cpu_conv_kco_range(
            source0.data, destination.data,
            (const int8_t *)(uintptr_t)task->source1,
            (const int32_t *)(uintptr_t)task->auxiliary0,
            (const uint8_t *)(uintptr_t)task->auxiliary1,
            &layer, task->range_begin, task->range_end);
    }
#endif
    if (task->operation == COCO80_MC_OP_POOL_S2) {
        output_h = task->height / 2U; output_w = task->width / 2U;
        output_channels = task->channels0;
    } else if (task->operation == COCO80_MC_OP_POOL_S1_PAD) {
        output_h = task->height; output_w = task->width;
        output_channels = task->channels0;
    } else if (task->operation == COCO80_MC_OP_NEAREST_REQUANT_CONCAT) {
        source1.height = task->height * 2U; source1.width = task->width * 2U;
        source1.channels = task->channels1;
        source1_bytes = c8_mc_tensor_bytes(
            source1.height, source1.width, source1.channels);
        source1.bytes = source1_bytes;
        output_h = source1.height; output_w = source1.width;
        output_channels = task->channels0 + task->channels1;
    } else {
        return COCO80_TENSOR_ERR_ARGUMENT;
    }
    destination_bytes = c8_mc_tensor_bytes(output_h, output_w, output_channels);
    if (destination_bytes == 0U) return COCO80_TENSOR_ERR_CAPACITY;
    destination.height = output_h; destination.width = output_w;
    destination.channels = output_channels; destination.bytes = destination_bytes;
    Xil_DCacheInvalidateRange((UINTPTR)source0.data, source0_bytes);
    if (source1_bytes != 0U)
        Xil_DCacheInvalidateRange((UINTPTR)source1.data, source1_bytes);
    Xil_DCacheInvalidateRange((UINTPTR)destination.data, destination_bytes);
    if (task->operation == COCO80_MC_OP_POOL_S2) {
        rc = coco80_maxpool2x2_s2_channel_range(
            &source0, &destination, task->range_begin, task->range_end);
        if (rc == COCO80_TENSOR_OK)
            c8_mc_flush_channel_range(
                destination.data, output_h * output_w, output_channels,
                task->range_begin, task->range_end);
    } else if (task->operation == COCO80_MC_OP_POOL_S1_PAD) {
        rc = coco80_maxpool2x2_s1_pad_right_bottom_channel_range(
            &source0, (uint8_t)task->pad_value, &destination,
            task->range_begin, task->range_end);
        if (rc == COCO80_TENSOR_OK)
            c8_mc_flush_channel_range(
                destination.data, output_h * output_w, output_channels,
                task->range_begin, task->range_end);
    } else {
        rc = coco80_nearest2x_requant_concat_pixel_range(
            &source0, &source1, task->input_zero_point,
            task->output_zero_point, task->multiplier, task->shift,
            &destination, task->range_begin, task->range_end);
        if (rc == COCO80_TENSOR_OK)
            c8_mc_flush_pixel_range(
                destination.data, output_channels,
                task->range_begin, task->range_end);
    }
    return rc;
}

void coco80_mc_worker_loop(uint32_t worker_id)
{
    coco80_mc_mailbox_t *mailbox =
        (coco80_mc_mailbox_t *)COCO80_MC_MAILBOX_ADDRESS;
    coco80_mc_task_t *task;
    uint32_t last_generation = 0U;
    if (worker_id == 0U || worker_id > COCO80_MC_WORKERS) for (;;) c8_mc_wait_event();
    c8_mc_set_mailbox_attributes();
    while (mailbox->magic != COCO80_MC_MAGIC ||
           mailbox->version != COCO80_MC_VERSION ||
           mailbox->controller_ready == 0U) c8_mc_wait_event();
    if (mailbox->shared_region_attribute != COCO80_MC_INNER_WB_ATTRIBUTE ||
        coco80_mc_set_inner_shareable_region(
            (void *)(uintptr_t)mailbox->shared_region_base,
            mailbox->shared_region_bytes) != COCO80_TENSOR_OK) {
        mailbox->last_error = COCO80_TENSOR_ERR_ARGUMENT;
        mailbox->worker_ready[worker_id - 1U] = 0x80000000U | worker_id;
        c8_mc_barrier();
        c8_mc_event();
        for (;;) c8_mc_wait_event();
    }
    mailbox->worker_ready[worker_id - 1U] = worker_id;
    c8_mc_barrier();
    c8_mc_event();
    task = &mailbox->tasks[worker_id - 1U];
    for (;;) {
        int rc;
        while (task->state != COCO80_MC_TASK_READY ||
               task->generation == last_generation) c8_mc_wait_event();
        last_generation = task->generation;
        task->state = COCO80_MC_TASK_RUNNING;
        c8_mc_barrier();
        rc = c8_mc_worker_execute(task);
        task->status = rc;
        c8_mc_barrier();
        task->state = rc == COCO80_TENSOR_OK ?
            COCO80_MC_TASK_DONE : COCO80_MC_TASK_ERROR;
        c8_mc_barrier();
        c8_mc_event();
    }
}

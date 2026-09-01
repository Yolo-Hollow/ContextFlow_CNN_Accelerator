#include "accel_smoke.h"
#include "accel_runtime_v2.h"
#include "coco80_accel.h"
#include "coco80_generated_config.h"
#include "coco80_multicore.h"
#include "coco80_net_build_config.h"
#include "coco80_net_platform.h"
#include "coco80_net_protocol.h"
#include "coco80_sd_index.h"

#include "lwip/init.h"
#include "lwip/ip_addr.h"
#include "lwip/priv/tcp_priv.h"
#include "lwip/tcp.h"
#include "netif/xadapter.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xsysmonpsu.h"
#include "xtime_l.h"
#include "bspconfig.h"

#include <stdint.h>
#include <string.h>

#ifndef COCO80_NET_ABLATION_OVERRIDE_MODE
#define COCO80_NET_ABLATION_OVERRIDE_MODE 0U
#define COCO80_NET_ABLATION_OVERRIDE_TILE_H 0U
#define COCO80_NET_ABLATION_OVERRIDE_KERNEL 0U
#endif

#define C8_NET_PORT 5001U
#define C8_NET_TX_SLICE 16384U
#define C8_NET_ATOMIC_FRAME_PAYLOAD_BYTES 4096U
#define C8_NET_TX_TIMEOUT_SECONDS 120U
#define C8_NET_CHUNK_ACK_TIMEOUT_SECONDS 30U
#define C8_NET_LOW_DDR_LIMIT 0x80000000ULL
#define C8_NET_RESULT_BUFFER_BYTES \
    (COCO80_NET_CHUNK_RECORDS * \
     (COCO80_NET_RESULT_PREFIX_BYTES + COCO80_ACCEL_RAW_PACKAGE_BYTES))
#define C8_NET_TIMING_BUFFER_BYTES \
    (COCO80_NET_CHUNK_TIMING_BYTES + \
     COCO80_NET_CHUNK_RECORDS * COCO80_ACCEL_EXTENDED_TIMING_BYTES)

enum c8_net_phase {
    C8_PHASE_HELLO = 0,
    C8_PHASE_PARAMETERS,
    C8_PHASE_INPUT,
    C8_PHASE_RUN
};

static uint8_t c8_parameter_package[COCO80_SD_PARAMETER_PACKAGE_BYTES]
    __attribute__((aligned(COCO80_MC_TLB_BLOCK_BYTES)));
static uint8_t c8_input_chunk[2][COCO80_NET_INPUT_CHUNK_BYTES]
    __attribute__((aligned(COCO80_MC_TLB_BLOCK_BYTES)));
static uint8_t c8_result_chunk[C8_NET_RESULT_BUFFER_BYTES]
    __attribute__((aligned(64)));
static uint8_t c8_timing_chunk[C8_NET_TIMING_BUFFER_BYTES]
    __attribute__((aligned(64)));
static uint8_t c8_atomic_tx_frame[
    COCO80_NET_HEADER_BYTES + C8_NET_ATOMIC_FRAME_PAYLOAD_BYTES]
    __attribute__((aligned(64)));
static uint8_t c8_workspace_arena[COCO80_ACCEL_WORKSPACE_BYTES]
    __attribute__((aligned(COCO80_MC_TLB_BLOCK_BYTES)));

typedef struct {
    struct netif netif;
    struct tcp_pcb *pcb;
    coco80_accel_runner_t runner;
    coco80_accel_workspace_t workspace;
    coco80_net_header_t rx_header;
    coco80_net_header_t active_header;
    coco80_net_hello_t hello;
    coco80_net_end_t host_end;
    uint8_t rx_header_bytes[COCO80_NET_HEADER_BYTES];
    uint8_t binding[32];
    uint8_t phase;
    uint8_t command_ready;
    uint8_t command_released;
    uint8_t connection_open;
    uint8_t input_buffer_index;
    uint8_t *rx_payload;
    uint32_t rx_header_have;
    uint32_t rx_payload_have;
    uint32_t rx_payload_capacity;
    uint32_t expected_sequence;
    uint32_t chunk_first_record;
    uint32_t chunk_record_count;
    uint32_t records_received;
    uint32_t records_completed;
    uint32_t results_sent;
    uint32_t error_count;
    uint32_t reconnect_count;
    uint32_t input_crc_state;
    uint32_t result_crc_state;
    uint32_t chunk_input_crc32;
    uint32_t chunk_input_bytes;
    uint32_t chunk_result_crc32;
    uint32_t chunk_result_bytes;
    int fatal_error;
    uint64_t session_start_ticks;
    uint64_t rx_start_ticks;
    uint64_t rx_done_ticks;
    uint64_t tx_queued;
    uint64_t tx_acked;
} c8_net_server_t;

typedef struct {
    XSysMonPsu instance;
    int32_t max_temp_millic;
} c8_net_thermal_t;

static c8_net_server_t c8_server;
static c8_net_thermal_t c8_thermal;
static coco80_mc_controller_t c8_multicore;

#define C8_PSCI_CPU_ON_64 0xC4000003ULL
#define C8_PSCI_ALREADY_ON (-4LL)
#define C8_WORKER_ENTRY_ADDRESS 0x7C100000ULL

static volatile int64_t c8_psci_status[COCO80_MC_WORKERS];

static int64_t c8_psci_cpu_on(uint64_t target_cpu, uint64_t entry_address)
{
#if defined(__aarch64__) && defined(EL1_NONSECURE) && EL1_NONSECURE
    register uint64_t x0 __asm__("x0") = C8_PSCI_CPU_ON_64;
    register uint64_t x1 __asm__("x1") = target_cpu;
    register uint64_t x2 __asm__("x2") = entry_address;
    register uint64_t x3 __asm__("x3") = 0U;
    __asm__ volatile(
        "smc #0"
        : "+r"(x0)
        : "r"(x1), "r"(x2), "r"(x3)
        : "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11",
          "x12", "x13", "x14", "x15", "x16", "x17", "cc", "memory");
    return (int64_t)x0;
#else
    (void)target_cpu;
    (void)entry_address;
    return C8_PSCI_ALREADY_ON;
#endif
}

static int c8_start_secondary_workers(void)
{
    uint32_t worker;
    for (worker = 1U; worker <= COCO80_MC_WORKERS; ++worker) {
        int64_t status = c8_psci_cpu_on(worker, C8_WORKER_ENTRY_ADDRESS);
        c8_psci_status[worker - 1U] = status;
        if (status != 0 && status != C8_PSCI_ALREADY_ON) {
            return -100 - (int)worker;
        }
    }
    return 0;
}

static int c8_mc_backend_pool_s2(
    void *opaque, const coco80_hwc_u8_t *source,
    coco80_hwc_u8_t *destination)
{
    return coco80_mc_pool_s2(
        (coco80_mc_controller_t *)opaque, source, destination);
}

static int c8_mc_backend_pool_s1_pad(
    void *opaque, const coco80_hwc_u8_t *source, uint8_t pad_value,
    coco80_hwc_u8_t *destination)
{
    return coco80_mc_pool_s1_pad(
        (coco80_mc_controller_t *)opaque, source, pad_value, destination);
}

static int c8_mc_backend_nearest_requant_concat(
    void *opaque, const coco80_hwc_u8_t *small,
    const coco80_hwc_u8_t *route, int32_t input_zero_point,
    int32_t output_zero_point, uint32_t multiplier, uint32_t shift,
    coco80_hwc_u8_t *destination)
{
    return coco80_mc_nearest_requant_concat(
        (coco80_mc_controller_t *)opaque, small, route,
        input_zero_point, output_zero_point, multiplier, shift, destination);
}

static int32_t c8_temp_millic(uint16_t raw)
{
    float value = XSysMonPsu_RawToTemperature_OnChip(raw);
    return (int32_t)(value * 1000.0f + (value >= 0.0f ? 0.5f : -0.5f));
}

static int c8_sysmon_cfg_initialize(
    XSysMonPsu *instance, XSysMonPsu_Config *config)
{
#if defined(__aarch64__) && defined(EL1_NONSECURE) && EL1_NONSECURE
    uint32_t poll;
    uint64_t status;
    instance->Config = *config;
    instance->IsPlAccessibleByPs = 0U;
    instance->IsReady = 0U;
    instance->Handler = NULL;
    instance->CallBackRef = NULL;
    (void)XSysMonPsu_UpdateAdcClkDivisor(instance, XSYSMON_PS);
    Xil_Out32((UINTPTR)config->BaseAddress + XPS_BA_OFFSET +
              XSYSMONPSU_VP_VN_OFFSET, XSYSMONPSU_VP_VN_MASK);
    for (poll = 0U; poll < 1000000U; ++poll) {
        if (Xil_In32((UINTPTR)config->BaseAddress +
                     XSYSMONPSU_PS_SYSMON_CSTS_OFFSET) ==
            XSYSMONPSU_PS_SYSMON_READY) {
            break;
        }
    }
    if (poll == 1000000U) {
        return XST_FAILURE;
    }
    instance->IsReady = XIL_COMPONENT_IS_READY;
    status = XSysMonPsu_IntrGetStatus(instance);
    XSysMonPsu_IntrClear(instance, status);
    return XST_SUCCESS;
#else
    return XSysMonPsu_CfgInitialize(
        instance, config, (uint32_t)config->BaseAddress);
#endif
}

static int c8_thermal_init(void)
{
    XSysMonPsu_Config *config;
    uint64_t eos_mask = (uint64_t)XSYSMONPSU_ISR_1_EOS_MASK << 32;
    uint64_t channels = XSYSMONPSU_SEQ_CH0_TEMP_MASK |
        XSYSMONPSU_SEQ_CH0_CALIBRTN_MASK;
    uint32_t poll;
    memset(&c8_thermal, 0, sizeof(c8_thermal));
    config = XSysMonPsu_LookupConfig(XPAR_XSYSMONPSU_0_DEVICE_ID);
    if (config == NULL || c8_sysmon_cfg_initialize(
            &c8_thermal.instance, config) != XST_SUCCESS)
        return -1;
    XSysMonPsu_SetSequencerMode(&c8_thermal.instance, XSM_SEQ_MODE_SAFE, XSYSMON_PS);
    XSysMonPsu_SetAvg(&c8_thermal.instance, XSM_AVG_16_SAMPLES, XSYSMON_PS);
    if (XSysMonPsu_SetSeqAvgEnables(&c8_thermal.instance, channels, XSYSMON_PS) != XST_SUCCESS ||
        XSysMonPsu_SetSeqChEnables(&c8_thermal.instance, channels, XSYSMON_PS) != XST_SUCCESS)
        return -2;
    XSysMonPsu_IntrClear(&c8_thermal.instance,
                         XSysMonPsu_IntrGetStatus(&c8_thermal.instance));
    XSysMonPsu_SetSequencerMode(
        &c8_thermal.instance, XSM_SEQ_MODE_CONTINPASS, XSYSMON_PS);
    for (poll = 0U; poll < 1000000U; ++poll) {
        if ((XSysMonPsu_IntrGetStatus(&c8_thermal.instance) & eos_mask) != 0U) {
            XSysMonPsu_IntrClear(&c8_thermal.instance, eos_mask);
            c8_thermal.max_temp_millic = c8_temp_millic(XSysMonPsu_GetAdcData(
                &c8_thermal.instance, XSM_CH_TEMP, XSYSMON_PS));
            return 0;
        }
    }
    return -3;
}

static int c8_sample_temperature(int32_t *current)
{
    uint64_t overtemp = (uint64_t)(XSYSMONPSU_ISR_1_PL_OT_MASK |
        XSYSMONPSU_ISR_1_PS_LPD_OT_MASK | XSYSMONPSU_ISR_1_PS_FPD_OT_MASK) << 32;
    uint64_t status = XSysMonPsu_IntrGetStatus(&c8_thermal.instance);
    *current = c8_temp_millic(XSysMonPsu_GetAdcData(
        &c8_thermal.instance, XSM_CH_TEMP, XSYSMON_PS));
    if (*current > c8_thermal.max_temp_millic) c8_thermal.max_temp_millic = *current;
    return *current >= -40000 && *current < 85000 && (status & overtemp) == 0U ? 0 : -1;
}

static uint32_t c8_read32(void *opaque, uint32_t base, uint32_t offset)
{
    (void)opaque;
    return Xil_In32((UINTPTR)base + offset);
}

static void c8_write32(void *opaque, uint32_t base, uint32_t offset, uint32_t value)
{
    (void)opaque;
    Xil_Out32((UINTPTR)base + offset, value);
}

static void c8_flush(void *opaque, uintptr_t address, uint32_t bytes)
{
    (void)opaque;
    Xil_DCacheFlushRange((UINTPTR)address, bytes);
}

static void c8_invalidate(void *opaque, uintptr_t address, uint32_t bytes)
{
    (void)opaque;
    Xil_DCacheInvalidateRange((UINTPTR)address, bytes);
}

static uint64_t c8_ticks(void *opaque)
{
    XTime value;
    (void)opaque;
    XTime_GetTime(&value);
    return (uint64_t)value;
}

static accel_v2_runtime_t c8_runtime(void)
{
    accel_v2_runtime_t runtime;
    memset(&runtime, 0, sizeof(runtime));
    runtime.read32 = c8_read32;
    runtime.write32 = c8_write32;
    runtime.cache_flush = c8_flush;
    runtime.cache_invalidate = c8_invalidate;
    runtime.accel_base = ACCEL_BASE_ADDR;
    runtime.dma_base[ACCEL_V2_DMA_BIAS] = DMA_BIAS_BASE_ADDR;
    runtime.dma_base[ACCEL_V2_DMA_WEIGHT] = DMA_WEIGHT_BASE_ADDR;
    runtime.dma_base[ACCEL_V2_DMA_IFM] = DMA_IFM_BASE_ADDR;
    runtime.dma_base[ACCEL_V2_DMA_OFM] = DMA_OFM_BASE_ADDR;
    runtime.poll_limit = ACCEL_V2_DEFAULT_POLL_LIMIT;
    return runtime;
}

static int c8_low_aligned(const void *address, uint32_t bytes)
{
    uint64_t start = (uint64_t)(uintptr_t)address;
    uint64_t end = start + (uint64_t)bytes;
    return (start & 63U) == 0U && end >= start && end <= C8_NET_LOW_DDR_LIMIT;
}

static int c8_validate_dma_memory(void)
{
    return c8_low_aligned(c8_parameter_package, sizeof(c8_parameter_package)) &&
        c8_low_aligned(c8_input_chunk[0], sizeof(c8_input_chunk[0])) &&
        c8_low_aligned(c8_input_chunk[1], sizeof(c8_input_chunk[1])) &&
        c8_low_aligned(c8_workspace_arena, sizeof(c8_workspace_arena));
}

static int c8_hex_nibble(char value)
{
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    return -1;
}

static int c8_hash_matches_hex(const uint32_t hash[8], const char *hex)
{
    const uint8_t *bytes = (const uint8_t *)hash;
    uint32_t index;
    if (hash == NULL || hex == NULL) return 0;
    for (index = 0U; index < 32U; ++index) {
        int high = c8_hex_nibble(hex[index * 2U]);
        int low = c8_hex_nibble(hex[index * 2U + 1U]);
        if (high < 0 || low < 0 || bytes[index] != (uint8_t)((high << 4) | low))
            return 0;
    }
    return hex[64] == '\0';
}

static void c8_pump(void)
{
    coco80_net_platform_poll(&c8_server.netif);
    if (coco80_net_tcp_fast_timer != 0) {
        tcp_fasttmr();
        coco80_net_tcp_fast_timer = 0;
    }
    if (coco80_net_tcp_slow_timer != 0) {
        tcp_slowtmr();
        coco80_net_tcp_slow_timer = 0;
    }
    (void)xemacif_input(&c8_server.netif);
}

static err_t c8_sent(void *arg, struct tcp_pcb *pcb, u16_t length)
{
    c8_net_server_t *server = (c8_net_server_t *)arg;
    (void)pcb;
    if (server != NULL) server->tx_acked += length;
    return ERR_OK;
}

static void c8_connection_error(void *arg, err_t error)
{
    c8_net_server_t *server = (c8_net_server_t *)arg;
    if (server != NULL) {
        if (server->phase != C8_PHASE_HELLO) {
            xil_printf("COCO80_NET connection_error=%d phase=%lu sequence=%lu\r\n",
                       (int)error, (unsigned long)server->phase,
                       (unsigned long)server->expected_sequence);
        }
        server->pcb = NULL;
        server->connection_open = 0U;
        if (server->phase != C8_PHASE_HELLO) server->fatal_error = COCO80_NET_ERR_SEQUENCE;
    }
}

static int c8_send_bytes(const void *data, uint32_t bytes)
{
    const uint8_t *cursor = (const uint8_t *)data;
    uint32_t queued = 0U;
    uint64_t deadline = c8_ticks(NULL) +
        (uint64_t)COUNTS_PER_SECOND * C8_NET_TX_TIMEOUT_SECONDS;
    if (data == NULL || bytes == 0U || c8_server.pcb == NULL) return -1;
    while (queued < bytes) {
        u16_t available = tcp_sndbuf(c8_server.pcb);
        uint32_t amount = bytes - queued;
        err_t error;
        if (amount > C8_NET_TX_SLICE) amount = C8_NET_TX_SLICE;
        if (amount > available) amount = available;
        if (amount == 0U) {
            c8_pump();
            if (!c8_server.connection_open || c8_ticks(NULL) > deadline) return -2;
            continue;
        }
        error = tcp_write(c8_server.pcb, cursor + queued, (u16_t)amount,
                          TCP_WRITE_FLAG_COPY);
        if (error == ERR_MEM) {
            c8_pump();
            if (!c8_server.connection_open || c8_ticks(NULL) > deadline) return -3;
            continue;
        }
        if (error != ERR_OK) return -4;
        queued += amount;
        c8_server.tx_queued += amount;
        error = tcp_output(c8_server.pcb);
        if (error == ERR_MEM) {
            c8_pump();
            if (!c8_server.connection_open || c8_ticks(NULL) > deadline) return -5;
            continue;
        }
        if (error != ERR_OK) return -6;
    }
    /* TCP_WRITE_FLAG_COPY transfers ownership to lwIP.  Returning once the
     * complete application frame is queued avoids coupling command state to
     * transport ACK timing; the peer validates every response at the
     * application layer and a later socket error still fail-closes the active
     * session. */
    return 0;
}

static int c8_wait_for_acked(
    c8_net_server_t *server, uint64_t target_acked, uint32_t timeout_seconds)
{
    uint64_t deadline;
    if (server == NULL || timeout_seconds == 0U ||
        target_acked > server->tx_queued) return -1;
    deadline = c8_ticks(NULL) +
        (uint64_t)COUNTS_PER_SECOND * timeout_seconds;
    while (server->tx_acked < target_acked) {
        err_t output_error;
        c8_pump();
        if (server->tx_acked >= target_acked) break;
        if (server->pcb == NULL || server->connection_open == 0U ||
            c8_ticks(NULL) > deadline) return -2;
        /* The polled GEM path can leave a copied segment on lwIP's unsent
         * queue after an ACK frees space.  Retry output after every input/ACK
         * pass so a completed application chunk cannot accumulate transport
         * debt across subsequent RUN commands. */
        output_error = tcp_output(server->pcb);
        if (output_error != ERR_OK && output_error != ERR_MEM) return -3;
    }
    return 0;
}

static void c8_fill_response_header(
    coco80_net_header_t *header, uint32_t type, uint32_t payload_bytes,
    uint32_t payload_crc32, uint32_t output_kind, uint32_t decode_profile,
    uint32_t status, uint32_t error_code)
{
    const coco80_net_header_t *request = c8_server.command_released != 0U ?
        &c8_server.active_header : &c8_server.rx_header;
    memset(header, 0, sizeof(*header));
    header->message_type = type;
    header->flags = COCO80_NET_FLAG_NON_RELEASE;
    header->session_id_low = request->session_id_low;
    header->session_id_high = request->session_id_high;
    header->sequence = request->sequence;
    header->first_record = request->first_record;
    header->record_count = request->record_count;
    header->payload_bytes = payload_bytes;
    header->payload_crc32 = payload_crc32;
    header->status = status;
    header->error_code = error_code;
    header->output_kind = output_kind;
    header->decode_profile = decode_profile;
    header->tick_hz = (uint32_t)COUNTS_PER_SECOND;
    memcpy(header->binding_sha256, c8_server.binding, sizeof(c8_server.binding));
}

static int c8_send_frame(
    uint32_t type, const void *payload, uint32_t payload_bytes,
    uint32_t output_kind, uint32_t decode_profile,
    uint32_t status, uint32_t error_code)
{
    coco80_net_header_t header;
    uint32_t payload_crc = coco80_sd_crc32(payload, payload_bytes);
    c8_fill_response_header(&header, type, payload_bytes, payload_crc,
                            output_kind, decode_profile, status, error_code);
    if (coco80_net_seal_header(&header, payload) != COCO80_NET_OK) return -1;
    /* Keep every small response header and payload in one queue operation.
     * Splitting a representative timing response immediately after a large
     * raw tensor can leave its final short segment on lwIP's unsent queue,
     * while the peer waits for that payload before it can send the next
     * request.  The static frame also avoids a multi-kilobyte stack object. */
    if (payload_bytes != 0U &&
        payload_bytes <= C8_NET_ATOMIC_FRAME_PAYLOAD_BYTES) {
        memcpy(c8_atomic_tx_frame, &header, sizeof(header));
        memcpy(c8_atomic_tx_frame + sizeof(header), payload, payload_bytes);
        return c8_send_bytes(c8_atomic_tx_frame,
                             (uint32_t)sizeof(header) + payload_bytes) == 0 ?
            0 : -2;
    }
    if (c8_send_bytes(&header, sizeof(header)) != 0) return -2;
    if (payload_bytes != 0U && c8_send_bytes(payload, payload_bytes) != 0) return -3;
    return 0;
}

static int c8_select_payload(c8_net_server_t *server)
{
    uint32_t expected = 0U;
    server->rx_payload = NULL;
    server->rx_payload_capacity = 0U;
    switch (server->rx_header.message_type) {
    case COCO80_NET_MSG_HELLO:
        expected = COCO80_NET_HELLO_BYTES;
        server->rx_payload = (uint8_t *)&server->hello;
        server->rx_payload_capacity = sizeof(server->hello);
        break;
    case COCO80_NET_MSG_PARAMETERS:
        expected = COCO80_SD_PARAMETER_PACKAGE_BYTES;
        server->rx_payload = c8_parameter_package;
        server->rx_payload_capacity = sizeof(c8_parameter_package);
        break;
    case COCO80_NET_MSG_INPUT_CHUNK:
        if (server->rx_header.record_count == 0U) return COCO80_NET_ERR_RECORDS;
#if defined(COCO80_NET_ABLATION_REPRESENTATIVE) && \
    COCO80_NET_ABLATION_REPRESENTATIVE == 1
        if (server->rx_header.record_count != 1U ||
            server->rx_header.payload_bytes <= COCO80_NET_REP_HEADER_BYTES) {
            return COCO80_NET_ERR_RECORDS;
        }
        expected = server->rx_header.payload_bytes;
#else
        expected = server->rx_header.record_count * COCO80_ACCEL_INPUT_PACKAGE_BYTES;
#endif
        server->rx_payload = c8_input_chunk[server->input_buffer_index];
        server->rx_payload_capacity = sizeof(c8_input_chunk[0]);
        break;
    case COCO80_NET_MSG_RUN:
        expected = 0U;
        break;
    case COCO80_NET_MSG_END:
        expected = COCO80_NET_END_BYTES;
        server->rx_payload = (uint8_t *)&server->host_end;
        server->rx_payload_capacity = sizeof(server->host_end);
        break;
    default:
        return COCO80_NET_ERR_TYPE;
    }
    if (server->rx_header.payload_bytes != expected ||
        expected > server->rx_payload_capacity) return COCO80_NET_ERR_LENGTH;
    return COCO80_NET_OK;
}

static int c8_ingest(c8_net_server_t *server, const uint8_t *data, uint32_t bytes)
{
    while (bytes != 0U) {
        uint32_t amount;
        int rc;
        if (server->command_ready != 0U) return COCO80_NET_ERR_SEQUENCE;
        if (server->rx_header_have == 0U && server->rx_payload_have == 0U)
            server->rx_start_ticks = c8_ticks(NULL);
        if (server->rx_header_have < COCO80_NET_HEADER_BYTES) {
            amount = COCO80_NET_HEADER_BYTES - server->rx_header_have;
            if (amount > bytes) amount = bytes;
            memcpy(server->rx_header_bytes + server->rx_header_have, data, amount);
            server->rx_header_have += amount;
            data += amount;
            bytes -= amount;
            if (server->rx_header_have != COCO80_NET_HEADER_BYTES) continue;
            memcpy(&server->rx_header, server->rx_header_bytes, sizeof(server->rx_header));
            rc = coco80_net_validate_header(&server->rx_header);
            if (rc != COCO80_NET_OK) return rc;
            if (server->rx_header.sequence != server->expected_sequence) return COCO80_NET_ERR_SEQUENCE;
            rc = c8_select_payload(server);
            if (rc != COCO80_NET_OK) return rc;
            if (server->rx_header.payload_bytes == 0U) {
                server->rx_done_ticks = c8_ticks(NULL);
                server->command_ready = 1U;
                if (bytes != 0U) return COCO80_NET_ERR_SEQUENCE;
            }
        } else {
            amount = server->rx_header.payload_bytes - server->rx_payload_have;
            if (amount > bytes) amount = bytes;
            memcpy(server->rx_payload + server->rx_payload_have, data, amount);
            server->rx_payload_have += amount;
            data += amount;
            bytes -= amount;
            if (server->rx_payload_have == server->rx_header.payload_bytes) {
                server->rx_done_ticks = c8_ticks(NULL);
                rc = coco80_net_validate_message(
                    &server->rx_header, server->rx_payload, server->rx_payload_have);
                if (rc != COCO80_NET_OK) return rc;
                server->command_ready = 1U;
                if (bytes != 0U) return COCO80_NET_ERR_SEQUENCE;
            }
        }
    }
    return COCO80_NET_OK;
}

static err_t c8_receive(void *arg, struct tcp_pcb *pcb, struct pbuf *packet, err_t error)
{
    c8_net_server_t *server = (c8_net_server_t *)arg;
    struct pbuf *part;
    int rc = COCO80_NET_OK;
    if (server == NULL) {
        if (packet != NULL) pbuf_free(packet);
        return ERR_ARG;
    }
    if (packet == NULL) {
        server->connection_open = 0U;
        server->pcb = NULL;
        (void)tcp_close(pcb);
        return ERR_OK;
    }
    /*
     * A response is sent synchronously and the transmit path pumps lwIP while
     * queueing bytes or waiting for a chunk ACK.  The peer may legally ACK a
     * response and carry the next request in the same TCP segment.  Until the
     * current command has released its receive state, leave such a pbuf owned
     * by lwIP and request a retry.
     * Consuming it here would make c8_ingest() see command_ready and falsely
     * reject an otherwise in-order request as COCO80_NET_ERR_SEQUENCE.
     */
    if (server->command_ready != 0U) return ERR_MEM;
    if (error != ERR_OK) rc = COCO80_NET_ERR_CONTENT;
    for (part = packet; part != NULL && rc == COCO80_NET_OK; part = part->next)
        rc = c8_ingest(server, (const uint8_t *)part->payload, part->len);
    tcp_recved(pcb, packet->tot_len);
    pbuf_free(packet);
    if (rc != COCO80_NET_OK) {
        server->fatal_error = rc;
        server->error_count += 1U;
    }
    return ERR_OK;
}

static void c8_reset_rx(c8_net_server_t *server)
{
    memset(&server->rx_header, 0, sizeof(server->rx_header));
    memset(server->rx_header_bytes, 0, sizeof(server->rx_header_bytes));
    server->rx_header_have = 0U;
    server->rx_payload_have = 0U;
    server->rx_payload = NULL;
    server->rx_payload_capacity = 0U;
    server->command_ready = 0U;
}

static int c8_release_command(c8_net_server_t *server)
{
    if (server == NULL || server->command_ready == 0U ||
        server->command_released != 0U) return COCO80_NET_ERR_SEQUENCE;
    server->active_header = server->rx_header;
    server->expected_sequence += 1U;
    c8_reset_rx(server);
    server->command_released = 1U;
    return COCO80_NET_OK;
}

static void c8_reset_session(c8_net_server_t *server)
{
    server->phase = C8_PHASE_HELLO;
    server->expected_sequence = 1U;
    server->input_buffer_index = 0U;
    server->chunk_first_record = 0U;
    server->chunk_record_count = 0U;
    server->records_received = 0U;
    server->records_completed = 0U;
    server->results_sent = 0U;
    server->error_count = 0U;
    server->input_crc_state = coco80_sd_crc32_begin();
    server->result_crc_state = coco80_sd_crc32_begin();
    server->chunk_input_crc32 = 0U;
    server->chunk_input_bytes = 0U;
    server->chunk_result_crc32 = 0U;
    server->chunk_result_bytes = 0U;
    server->fatal_error = 0;
    server->command_released = 0U;
    server->session_start_ticks = 0U;
    server->tx_queued = 0U;
    server->tx_acked = 0U;
    memset(&server->runner, 0, sizeof(server->runner));
    memset(&server->workspace, 0, sizeof(server->workspace));
    memset(&server->hello, 0, sizeof(server->hello));
    memset(&server->host_end, 0, sizeof(server->host_end));
    memset(&server->active_header, 0, sizeof(server->active_header));
    memset(server->binding, 0, sizeof(server->binding));
    c8_reset_rx(server);
}

static err_t c8_accept(void *arg, struct tcp_pcb *new_pcb, err_t error)
{
    c8_net_server_t *server = (c8_net_server_t *)arg;
    if (server == NULL || error != ERR_OK || server->connection_open != 0U) {
        tcp_abort(new_pcb);
        return ERR_ABRT;
    }
    c8_reset_session(server);
    server->pcb = new_pcb;
    server->connection_open = 1U;
    server->reconnect_count += 1U;
    tcp_arg(new_pcb, server);
    tcp_recv(new_pcb, c8_receive);
    tcp_sent(new_pcb, c8_sent);
    tcp_err(new_pcb, c8_connection_error);
    tcp_nagle_disable(new_pcb);
    xil_printf("COCO80_NET CONNECT reconnect=%lu\r\n",
               (unsigned long)(server->reconnect_count - 1U));
    return ERR_OK;
}

static int c8_hello_valid(c8_net_server_t *server)
{
    if (coco80_net_validate_hello(&server->hello, sizeof(server->hello)) != COCO80_NET_OK ||
        (server->hello.flags & COCO80_NET_FLAG_NON_RELEASE) == 0U ||
        server->hello.software_build_crc32 != coco80_runtime_config.software_build_crc32 ||
        server->hello.hardware_build_crc32 != coco80_runtime_config.hardware_build_crc32 ||
        server->hello.parameter_package_bytes != COCO80_SD_PARAMETER_PACKAGE_BYTES ||
        !c8_hash_matches_hex(server->hello.bit_sha256, COCO80_EXPECTED_BIT_SHA256_HEX) ||
        !c8_hash_matches_hex(server->hello.xsa_sha256, COCO80_EXPECTED_XSA_SHA256_HEX) ||
        !c8_hash_matches_hex(server->hello.parameter_sha256,
                             COCO80_NET_EXPECTED_PARAMETER_SHA256_HEX) ||
        !c8_hash_matches_hex(server->hello.quantization_sha256,
                             COCO80_EXPECTED_QUANTIZATION_MANIFEST_SHA256_HEX)) return 0;
#if defined(COCO80_NET_ABLATION_REPRESENTATIVE) && \
    COCO80_NET_ABLATION_REPRESENTATIVE == 1
    if ((server->hello.flags & COCO80_NET_FLAG_ABLATION_REPRESENTATIVE) == 0U)
        return 0;
#else
    if ((server->hello.flags & COCO80_NET_FLAG_ABLATION_REPRESENTATIVE) != 0U)
        return 0;
#endif
    return 1;
}

static int c8_process_hello(c8_net_server_t *server)
{
    if (server->phase != C8_PHASE_HELLO || server->rx_header.record_count != 0U ||
        server->rx_header.first_record != 0U || !c8_hello_valid(server))
        return COCO80_NET_ERR_CONTENT;
    memcpy(server->binding, server->rx_header.binding_sha256, sizeof(server->binding));
    server->session_start_ticks = c8_ticks(NULL);
    server->phase = C8_PHASE_PARAMETERS;
    if (c8_release_command(server) != COCO80_NET_OK)
        return COCO80_NET_ERR_SEQUENCE;
    return c8_send_frame(COCO80_NET_MSG_STATUS, NULL, 0U, 0U, 0U,
                         COCO80_NET_OK, 0U) == 0 ? COCO80_NET_OK : COCO80_NET_ERR_CONTENT;
}

static int c8_process_parameters(c8_net_server_t *server)
{
    accel_v2_runtime_t runtime;
    coco80_accel_tensor_backend_t tensor_backend;
    int rc;
    if (server->phase != C8_PHASE_PARAMETERS || server->rx_header.record_count != 0U ||
        memcmp(server->rx_header.binding_sha256, server->binding, 32U) != 0)
        return COCO80_NET_ERR_SEQUENCE;
    rc = coco80_accel_workspace_init(
        &server->workspace, c8_workspace_arena, sizeof(c8_workspace_arena));
    if (rc != COCO80_ACCEL_OK) return rc;
    runtime = c8_runtime();
    rc = coco80_accel_initialize(
        &server->runner, &runtime, c8_ticks, NULL, (uint32_t)COUNTS_PER_SECOND,
        &coco80_runtime_config, c8_parameter_package,
        sizeof(c8_parameter_package), &server->workspace);
    if (rc != COCO80_ACCEL_OK) return rc;
#if defined(COCO80_NET_ABLATION_BUILD) && COCO80_NET_ABLATION_BUILD == 1
    rc = coco80_accel_set_ablation_stream_config(
        &server->runner, COCO80_NET_ABLATION_STREAM_CONFIG);
    if (rc != COCO80_ACCEL_OK) return rc;
#endif
    memset(&tensor_backend, 0, sizeof(tensor_backend));
    tensor_backend.opaque = &c8_multicore;
    tensor_backend.pool_s2 = c8_mc_backend_pool_s2;
    tensor_backend.pool_s1_pad = c8_mc_backend_pool_s1_pad;
    tensor_backend.nearest_requant_concat =
        c8_mc_backend_nearest_requant_concat;
    rc = coco80_accel_set_tensor_backend(&server->runner, &tensor_backend);
    if (rc != COCO80_ACCEL_OK) return rc;
    server->phase = C8_PHASE_INPUT;
    if (c8_release_command(server) != COCO80_NET_OK)
        return COCO80_NET_ERR_SEQUENCE;
    return c8_send_frame(COCO80_NET_MSG_STATUS, NULL, 0U, 0U, 0U,
                         COCO80_NET_OK, 0U) == 0 ? COCO80_NET_OK : COCO80_NET_ERR_CONTENT;
}

static int c8_validate_input_chunk(c8_net_server_t *server)
{
#if defined(COCO80_NET_ABLATION_REPRESENTATIVE) && \
    COCO80_NET_ABLATION_REPRESENTATIVE == 1
    const coco80_net_representative_header_t *header =
        (const coco80_net_representative_header_t *)
        c8_input_chunk[server->input_buffer_index];
    int rc = coco80_net_validate_representative(
        header, server->rx_header.payload_bytes, COCO80_NET_REP_INPUT_MAGIC);
    if (rc != COCO80_NET_OK || server->rx_header.record_count != 1U ||
        header->layer_index != COCO80_NET_ABLATION_LAYER_INDEX ||
        header->input_mode != COCO80_NET_ABLATION_INPUT_MODE ||
        header->stream_config != COCO80_NET_ABLATION_STREAM_CONFIG ||
        header->override_mode != COCO80_NET_ABLATION_OVERRIDE_MODE ||
        header->override_tile_h != COCO80_NET_ABLATION_OVERRIDE_TILE_H ||
        header->override_kernel != COCO80_NET_ABLATION_OVERRIDE_KERNEL) {
        return rc != COCO80_NET_OK ? rc : COCO80_NET_ERR_CONTENT;
    }
    return COCO80_NET_OK;
#else
    uint8_t *base = c8_input_chunk[server->input_buffer_index];
    uint32_t index;
    for (index = 0U; index < server->rx_header.record_count; ++index) {
        coco80_sd_input_header_t input;
        const uint8_t *package = base + index * COCO80_ACCEL_INPUT_PACKAGE_BYTES;
        int rc = coco80_sd_validate_input(
            package, COCO80_ACCEL_INPUT_PACKAGE_BYTES, &input);
        if (rc != COCO80_SD_OK || input.image_id == 0U ||
            input.input_scale_f32 != coco80_runtime_config.layers[0].input_scale_f32 ||
            input.input_zero_point != coco80_runtime_config.layers[0].input_zero_point)
            return rc != COCO80_SD_OK ? rc : COCO80_NET_ERR_CONTENT;
    }
    return COCO80_NET_OK;
#endif
}

static int c8_process_input(c8_net_server_t *server)
{
    uint32_t expected_first = server->records_received == 0U ?
        server->rx_header.first_record :
        server->chunk_first_record + server->chunk_record_count;
    int rc;
    if (server->phase != C8_PHASE_INPUT ||
        memcmp(server->rx_header.binding_sha256, server->binding, 32U) != 0 ||
        server->rx_header.first_record != expected_first) return COCO80_NET_ERR_SEQUENCE;
    rc = c8_validate_input_chunk(server);
    if (rc != COCO80_NET_OK) return rc;
    server->chunk_first_record = server->rx_header.first_record;
    server->chunk_record_count = server->rx_header.record_count;
    server->chunk_input_crc32 = server->rx_header.payload_crc32;
    server->chunk_input_bytes = server->rx_header.payload_bytes;
    server->input_crc_state = coco80_sd_crc32_extend(
        server->input_crc_state, c8_input_chunk[server->input_buffer_index],
        server->rx_header.payload_bytes);
    server->records_received += server->chunk_record_count;
    if ((server->hello.flags & COCO80_NET_FLAG_TRANSPORT_ONLY) != 0U) {
        server->records_completed += server->chunk_record_count;
        server->input_buffer_index ^= 1U;
    } else {
        server->phase = C8_PHASE_RUN;
    }
    if (c8_release_command(server) != COCO80_NET_OK)
        return COCO80_NET_ERR_SEQUENCE;
    return c8_send_frame(COCO80_NET_MSG_STATUS, NULL, 0U, 0U, 0U,
                         COCO80_NET_OK, 0U) == 0 ? COCO80_NET_OK : COCO80_NET_ERR_CONTENT;
}

#if defined(COCO80_NET_ABLATION_REPRESENTATIVE) && \
    COCO80_NET_ABLATION_REPRESENTATIVE == 1
static int c8_build_representative_results(
    c8_net_server_t *server, uint64_t *compute_ticks)
{
    const uint8_t *input_package = c8_input_chunk[server->input_buffer_index];
    const coco80_net_representative_header_t *input =
        (const coco80_net_representative_header_t *)input_package;
    uint8_t *ofm = c8_input_chunk[server->input_buffer_index ^ 1U];
    coco80_accel_extended_timing_t *timing =
        (coco80_accel_extended_timing_t *)
        (c8_timing_chunk + COCO80_NET_CHUNK_TIMING_BYTES);
    coco80_net_chunk_timing_t *chunk_timing =
        (coco80_net_chunk_timing_t *)c8_timing_chunk;
    coco80_net_result_prefix_t prefix;
    coco80_net_representative_header_t output;
    coco80_accel_representative_override_t override;
    const coco80_accel_representative_override_t *override_ptr = NULL;
    uint64_t start = c8_ticks(NULL);
    uint32_t output_kind = server->rx_header.output_kind;
    int rc;
    if (output_kind != COCO80_ACCEL_OUTPUT_RAW &&
        output_kind != COCO80_ACCEL_OUTPUT_TIMING) {
        return COCO80_NET_ERR_PROFILE;
    }
    if (input->override_mode != COCO80_ACCEL_REP_OVERRIDE_NONE) {
        const uint8_t *parameters = input_package + COCO80_NET_REP_HEADER_BYTES +
            input->ifm_bytes;
        memset(&override, 0, sizeof(override));
        override.mode = input->override_mode;
        override.tile_h = input->override_tile_h;
        override.kernel = input->override_kernel;
        override.bias_data = parameters;
        override.bias_bytes = input->bias_bytes;
        override.bias_packets = input->bias_packets;
        override.weight_data = parameters + input->bias_bytes;
        override.weight_bytes = input->weight_bytes;
        override.weight_packets = input->weight_packets;
        override_ptr = &override;
    }
    rc = coco80_accel_run_representative_layer(
        &server->runner, input->layer_index,
        (coco80_accel_layer_input_mode_t)input->input_mode,
        input_package + COCO80_NET_REP_HEADER_BYTES, input->ifm_bytes,
        ofm, input->ofm_bytes, input->image_id, override_ptr, timing);
    *compute_ticks = c8_ticks(NULL) - start;
    if (rc != COCO80_ACCEL_OK || timing->output_crc32 != input->expected_ofm_crc32) {
        xil_printf("COCO80_NET ABLATION layer=%lu image=%lu rc=%d crc=%08lx expected=%08lx\r\n",
                   (unsigned long)input->layer_index,
                   (unsigned long)input->image_id, rc,
                   (unsigned long)timing->output_crc32,
                   (unsigned long)input->expected_ofm_crc32);
        return rc != COCO80_ACCEL_OK ? rc : COCO80_NET_ERR_CONTENT;
    }
    timing->output_kind = output_kind;
    timing->decode_profile = server->rx_header.decode_profile;
    memset(chunk_timing, 0, sizeof(*chunk_timing));
    server->chunk_result_bytes = 0U;
    if (output_kind == COCO80_ACCEL_OUTPUT_RAW) {
        if (input->ofm_bytes > sizeof(c8_input_chunk[0]) ||
            input->ofm_bytes > sizeof(c8_result_chunk) - sizeof(prefix) -
                sizeof(output)) {
            return COCO80_NET_ERR_LENGTH;
        }
        memset(&output, 0, sizeof(output));
        output.magic = COCO80_NET_REP_OUTPUT_MAGIC;
        output.version = COCO80_NET_VERSION;
        output.header_bytes = COCO80_NET_REP_HEADER_BYTES;
        output.total_bytes = COCO80_NET_REP_HEADER_BYTES + input->ofm_bytes;
        output.image_id = input->image_id;
        output.layer_index = input->layer_index;
        output.input_mode = input->input_mode;
        output.stream_config = input->stream_config;
        output.ifm_bytes = 0U;
        output.ofm_bytes = input->ofm_bytes;
        output.expected_ofm_crc32 = input->expected_ofm_crc32;
        rc = coco80_net_seal_representative(&output, ofm);
        if (rc != COCO80_NET_OK) return rc;
        prefix.image_id = input->image_id;
        prefix.bytes = output.total_bytes;
        prefix.reserved = 0U;
        memcpy(c8_result_chunk + sizeof(prefix), &output, sizeof(output));
        memcpy(c8_result_chunk + sizeof(prefix) + sizeof(output), ofm,
               input->ofm_bytes);
        prefix.crc32 = coco80_sd_crc32(
            c8_result_chunk + sizeof(prefix), prefix.bytes);
        memcpy(c8_result_chunk, &prefix, sizeof(prefix));
        server->chunk_result_bytes = sizeof(prefix) + prefix.bytes;
    }
    server->chunk_result_crc32 = coco80_sd_crc32(
        c8_result_chunk, server->chunk_result_bytes);
    chunk_timing->magic = COCO80_NET_CHUNK_TIMING_MAGIC;
    chunk_timing->version = COCO80_NET_VERSION;
    chunk_timing->bytes = COCO80_NET_CHUNK_TIMING_BYTES;
    chunk_timing->first_record = server->chunk_first_record;
    chunk_timing->record_count = 1U;
    chunk_timing->output_kind = output_kind;
    chunk_timing->decode_profile = server->rx_header.decode_profile;
    chunk_timing->tick_hz = (uint32_t)COUNTS_PER_SECOND;
    chunk_timing->input_payload_bytes = server->chunk_input_bytes;
    chunk_timing->result_payload_bytes = server->chunk_result_bytes;
    chunk_timing->timing_record_bytes = COCO80_ACCEL_EXTENDED_TIMING_BYTES;
    chunk_timing->input_receive_ticks = server->rx_done_ticks - server->rx_start_ticks;
    chunk_timing->compute_ticks = *compute_ticks;
    chunk_timing->input_chunk_crc32 = server->chunk_input_crc32;
    chunk_timing->result_chunk_crc32 = server->chunk_result_crc32;
    if (c8_sample_temperature(&chunk_timing->current_temp_millic) != 0)
        return COCO80_NET_ERR_CONTENT;
    chunk_timing->max_temp_millic = c8_thermal.max_temp_millic;
    return COCO80_NET_OK;
}
#endif

static int c8_build_results(c8_net_server_t *server, uint64_t *compute_ticks)
{
#if defined(COCO80_NET_ABLATION_REPRESENTATIVE) && \
    COCO80_NET_ABLATION_REPRESENTATIVE == 1
    return c8_build_representative_results(server, compute_ticks);
#else
    uint8_t *input = c8_input_chunk[server->input_buffer_index];
    uint8_t *result_cursor = c8_result_chunk;
    coco80_net_chunk_timing_t *chunk_timing =
        (coco80_net_chunk_timing_t *)c8_timing_chunk;
    coco80_accel_extended_timing_t *timings =
        (coco80_accel_extended_timing_t *)(c8_timing_chunk + COCO80_NET_CHUNK_TIMING_BYTES);
    coco80_accel_infer_options_t options;
    uint32_t index;
    uint64_t start = c8_ticks(NULL);
    options.output_kind = server->rx_header.output_kind;
    options.decode_profile = server->rx_header.decode_profile;
    memset(chunk_timing, 0, sizeof(*chunk_timing));
    /* The complete chunk is one application command, but TCP timers and the
     * ACK for the RUN frame must continue to advance while images execute.
     * Pumping only between images keeps network maintenance outside every
     * recorded per-image inference interval. */
    c8_pump();
    if (server->connection_open == 0U || server->fatal_error != 0)
        return COCO80_NET_ERR_CONTENT;
    for (index = 0U; index < server->chunk_record_count; ++index) {
        coco80_accel_output_t output;
        coco80_net_result_prefix_t prefix;
        const void *record = NULL;
        uint32_t record_bytes = 0U;
        int rc = coco80_accel_infer_package_ex(
            &server->runner, input + index * COCO80_ACCEL_INPUT_PACKAGE_BYTES,
            COCO80_ACCEL_INPUT_PACKAGE_BYTES, &options, &output);
        if (rc != COCO80_ACCEL_OK) {
            const coco80_accel_failure_t *failure = &server->runner.failure;
            xil_printf("COCO80_NET RUN infer index=%lu rc=%d\r\n",
                       (unsigned long)index, rc);
            xil_printf(
                "COCO80_NET ACCEL failure status=%d detail=%d layer=%lu "
                "err=0x%08lx packed=%lu ofm_beats=%lu ifm_beats=%lu "
                "bias=%lu weight=%lu fire=%lu packets=%lu tlast=%lu "
                "last=%lu prefetch=%lu psum_underflow=%lu\r\n",
                failure->status, failure->detail,
                (unsigned long)failure->layer_index,
                (unsigned long)c8_read32(NULL, ACCEL_BASE_ADDR,
                                         ACCEL_DATAPATH_ERRORS_REG),
                (unsigned long)c8_read32(NULL, ACCEL_BASE_ADDR,
                                         ACCEL_PACKED_OFM_BYTES_REG),
                (unsigned long)c8_read32(NULL, ACCEL_BASE_ADDR,
                                         ACCEL_OFM_AXIS_BEATS_REG),
                (unsigned long)c8_read32(NULL, ACCEL_BASE_ADDR,
                                         ACCEL_VECTOR_BEATS),
                (unsigned long)c8_read32(NULL, ACCEL_BASE_ADDR,
                                         ACCEL_STREAM_BIAS_DONE),
                (unsigned long)c8_read32(NULL, ACCEL_BASE_ADDR,
                                         ACCEL_STREAM_WEIGHT_DONE),
                (unsigned long)c8_read32(NULL, ACCEL_BASE_ADDR,
                                         ACCEL_COMP_FIRE),
                (unsigned long)c8_read32(NULL, ACCEL_BASE_ADDR,
                                         ACCEL_DBG_CORE_WR),
                (unsigned long)c8_read32(NULL, ACCEL_BASE_ADDR,
                                         ACCEL_DBG_TLASTS),
                (unsigned long)c8_read32(NULL, ACCEL_BASE_ADDR,
                                         ACCEL_DBG_LAST_END),
                (unsigned long)c8_read32(NULL, ACCEL_BASE_ADDR,
                                         ACCEL_PREFETCH_MISS),
                (unsigned long)c8_read32(NULL, ACCEL_BASE_ADDR,
                                         ACCEL_PSUMOVL_UNDERFLOW));
            return rc;
        }
        timings[index] = output.extended_timing;
        if (options.output_kind == COCO80_ACCEL_OUTPUT_RAW) {
            record = output.raw_head_package;
            record_bytes = output.raw_head_package_bytes;
        } else if (options.output_kind == COCO80_ACCEL_OUTPUT_DETECTIONS) {
            record = output.detection_package;
            record_bytes = output.detection_package_bytes;
        }
        if (record_bytes != 0U) {
            uint32_t used = (uint32_t)(result_cursor - c8_result_chunk);
            if (used > sizeof(c8_result_chunk) - sizeof(prefix) ||
                record_bytes > sizeof(c8_result_chunk) - used - sizeof(prefix)) {
                xil_printf("COCO80_NET RUN result_capacity index=%lu used=%lu record=%lu\r\n",
                           (unsigned long)index, (unsigned long)used,
                           (unsigned long)record_bytes);
                return COCO80_NET_ERR_LENGTH;
            }
            prefix.image_id = output.image_id;
            prefix.bytes = record_bytes;
            prefix.crc32 = coco80_sd_crc32(record, record_bytes);
            prefix.reserved = 0U;
            memcpy(result_cursor, &prefix, sizeof(prefix));
            result_cursor += sizeof(prefix);
            memcpy(result_cursor, record, record_bytes);
            result_cursor += record_bytes;
        }
        c8_pump();
        if (server->connection_open == 0U || server->fatal_error != 0)
            return COCO80_NET_ERR_CONTENT;
    }
    *compute_ticks = c8_ticks(NULL) - start;
    server->chunk_result_bytes = (uint32_t)(result_cursor - c8_result_chunk);
    server->chunk_result_crc32 = coco80_sd_crc32(
        c8_result_chunk, server->chunk_result_bytes);
    chunk_timing->magic = COCO80_NET_CHUNK_TIMING_MAGIC;
    chunk_timing->version = COCO80_NET_VERSION;
    chunk_timing->bytes = COCO80_NET_CHUNK_TIMING_BYTES;
    chunk_timing->first_record = server->chunk_first_record;
    chunk_timing->record_count = server->chunk_record_count;
    chunk_timing->output_kind = options.output_kind;
    chunk_timing->decode_profile = options.decode_profile;
    chunk_timing->tick_hz = (uint32_t)COUNTS_PER_SECOND;
    chunk_timing->input_payload_bytes =
        server->chunk_record_count * COCO80_ACCEL_INPUT_PACKAGE_BYTES;
    chunk_timing->result_payload_bytes = server->chunk_result_bytes;
    chunk_timing->timing_record_bytes = COCO80_ACCEL_EXTENDED_TIMING_BYTES;
    chunk_timing->input_receive_ticks = server->rx_done_ticks - server->rx_start_ticks;
    chunk_timing->compute_ticks = *compute_ticks;
    chunk_timing->input_chunk_crc32 = server->chunk_input_crc32;
    chunk_timing->result_chunk_crc32 = server->chunk_result_crc32;
    if (c8_sample_temperature(&chunk_timing->current_temp_millic) != 0) {
        xil_printf("COCO80_NET RUN temperature_sample_failed\r\n");
        return COCO80_NET_ERR_CONTENT;
    }
    chunk_timing->max_temp_millic = c8_thermal.max_temp_millic;
    return COCO80_NET_OK;
#endif
}

static int c8_process_run(c8_net_server_t *server)
{
    coco80_net_header_t request = server->rx_header;
    coco80_net_chunk_timing_t *chunk_timing =
        (coco80_net_chunk_timing_t *)c8_timing_chunk;
    uint64_t compute_ticks, tx_start, target_acked;
    uint32_t timing_bytes;
    int rc;
    if (server->phase != C8_PHASE_RUN ||
        (server->hello.flags & COCO80_NET_FLAG_TRANSPORT_ONLY) != 0U ||
        memcmp(request.binding_sha256, server->binding, 32U) != 0 ||
        request.first_record != server->chunk_first_record ||
        request.record_count != server->chunk_record_count) return COCO80_NET_ERR_SEQUENCE;
    rc = c8_build_results(server, &compute_ticks);
    if (rc != COCO80_NET_OK) {
        xil_printf("COCO80_NET RUN build_results rc=%d\r\n", rc);
        return rc;
    }
    if (server->chunk_result_bytes != 0U) {
        tx_start = c8_ticks(NULL);
        rc = c8_send_frame(
            COCO80_NET_MSG_RESULT_CHUNK, c8_result_chunk,
            server->chunk_result_bytes, request.output_kind,
            request.decode_profile, COCO80_NET_OK, 0U);
        chunk_timing->result_send_ticks = c8_ticks(NULL) - tx_start;
        if (rc != 0) {
            xil_printf("COCO80_NET RUN result_send rc=%d bytes=%lu\r\n", rc,
                       (unsigned long)server->chunk_result_bytes);
            return COCO80_NET_ERR_CONTENT;
        }
        server->result_crc_state = coco80_sd_crc32_extend(
            server->result_crc_state, c8_result_chunk, server->chunk_result_bytes);
        /* Do not append the timing frame behind a large raw tensor while the
         * latter still occupies lwIP's send queue.  On the polled GEM path a
         * short tail can otherwise remain unsent until the peer times out,
         * even though the tensor payload itself was received intact. */
        target_acked = server->tx_queued;
        rc = c8_wait_for_acked(
            server, target_acked, C8_NET_CHUNK_ACK_TIMEOUT_SECONDS);
        if (rc != 0) {
            xil_printf("COCO80_NET RESULT_ACK_FAIL rc=%d open=%lu queued=%lu "
                       "acked=%lu target=%lu\r\n",
                       rc, (unsigned long)server->connection_open,
                       (unsigned long)server->tx_queued,
                       (unsigned long)server->tx_acked,
                       (unsigned long)target_acked);
            return COCO80_NET_ERR_CONTENT;
        }
    }
    timing_bytes = COCO80_NET_CHUNK_TIMING_BYTES +
        server->chunk_record_count * COCO80_ACCEL_EXTENDED_TIMING_BYTES;
    rc = coco80_net_validate_chunk_timing(
        c8_timing_chunk, timing_bytes, server->chunk_record_count,
        server->chunk_input_bytes);
    if (rc != COCO80_NET_OK) {
        xil_printf("COCO80_NET RUN timing_validate rc=%d bytes=%lu\r\n", rc,
                   (unsigned long)timing_bytes);
        return rc;
    }
    server->records_completed += server->chunk_record_count;
    server->results_sent += server->chunk_record_count;
    server->input_buffer_index ^= 1U;
    server->phase = C8_PHASE_INPUT;
    if (c8_release_command(server) != COCO80_NET_OK)
        return COCO80_NET_ERR_SEQUENCE;
    rc = c8_send_frame(
        COCO80_NET_MSG_TIMING_CHUNK, c8_timing_chunk, timing_bytes,
        request.output_kind, request.decode_profile, COCO80_NET_OK, 0U);
    if (rc != 0) {
        xil_printf("COCO80_NET RUN timing_send rc=%d bytes=%lu\r\n", rc,
                   (unsigned long)timing_bytes);
        return COCO80_NET_ERR_CONTENT;
    }
    target_acked = server->tx_queued;
    rc = c8_wait_for_acked(
        server, target_acked, C8_NET_CHUNK_ACK_TIMEOUT_SECONDS);
    if (rc != 0) {
        xil_printf("COCO80_NET RUN_ACK_FAIL rc=%d open=%lu queued=%lu "
                   "acked=%lu target=%lu\r\n",
                   rc, (unsigned long)server->connection_open,
                   (unsigned long)server->tx_queued,
                   (unsigned long)server->tx_acked,
                   (unsigned long)target_acked);
        return COCO80_NET_ERR_CONTENT;
    }
    return COCO80_NET_OK;
}

static int c8_process_end(c8_net_server_t *server)
{
    coco80_net_end_t response;
    uint64_t elapsed = c8_ticks(NULL) - server->session_start_ticks;
    uint64_t target_acked;
    int rc;
    if (server->phase != C8_PHASE_INPUT ||
        memcmp(server->rx_header.binding_sha256, server->binding, 32U) != 0 ||
        coco80_net_validate_end(&server->host_end, sizeof(server->host_end)) != COCO80_NET_OK ||
        server->host_end.records_received != server->records_received ||
        server->host_end.records_completed != server->records_completed ||
        server->host_end.results_sent != server->results_sent ||
        server->host_end.error_count != 0U) return COCO80_NET_ERR_CONTENT;
    memset(&response, 0, sizeof(response));
    response.magic = COCO80_NET_END_MAGIC;
    response.version = COCO80_NET_VERSION;
    response.bytes = COCO80_NET_END_BYTES;
    response.status = COCO80_NET_OK;
    response.records_received = server->records_received;
    response.records_completed = server->records_completed;
    response.results_sent = server->results_sent;
    response.error_count = server->error_count;
    response.input_crc32 = coco80_sd_crc32_end(server->input_crc_state);
    response.result_crc32 = coco80_sd_crc32_end(server->result_crc_state);
    response.parameter_crc32 = coco80_runtime_config.parameter_package_crc32;
    response.reconnect_count = server->reconnect_count - 1U;
    response.elapsed_ticks_low = (uint32_t)elapsed;
    response.elapsed_ticks_high = (uint32_t)(elapsed >> 32);
    /* END is the final response and a peer may close immediately after
     * receiving it.  Release the receive state first so the close cannot be
     * misclassified as an interrupted session. */
    server->phase = C8_PHASE_HELLO;
    if (c8_release_command(server) != COCO80_NET_OK)
        return COCO80_NET_ERR_SEQUENCE;
    rc = c8_send_frame(COCO80_NET_MSG_END, &response, sizeof(response),
                       0U, 0U, COCO80_NET_OK, 0U);
    target_acked = server->tx_queued;
    if (rc == 0) rc = c8_wait_for_acked(server, target_acked, 5U);
    if (rc == 0) {
        xil_printf("COCO80_NET PASS received=%lu completed=%lu outputs=%lu "
                   "tx_acked=%lu\r\n",
                   (unsigned long)server->records_received,
                   (unsigned long)server->records_completed,
                   (unsigned long)server->results_sent,
                   (unsigned long)server->tx_acked);
    } else {
        xil_printf("COCO80_NET END_ACK_FAIL open=%lu queued=%lu acked=%lu "
                   "target=%lu\r\n",
                   (unsigned long)server->connection_open,
                   (unsigned long)server->tx_queued,
                   (unsigned long)server->tx_acked,
                   (unsigned long)target_acked);
    }
    return rc == 0 ? COCO80_NET_OK : COCO80_NET_ERR_CONTENT;
}

static int c8_process_command(c8_net_server_t *server)
{
    int rc;
    if (server->command_ready == 0U) return COCO80_NET_ERR_ARGUMENT;
    server->active_header = server->rx_header;
    server->command_released = 0U;
    switch (server->rx_header.message_type) {
    case COCO80_NET_MSG_HELLO: rc = c8_process_hello(server); break;
    case COCO80_NET_MSG_PARAMETERS: rc = c8_process_parameters(server); break;
    case COCO80_NET_MSG_INPUT_CHUNK: rc = c8_process_input(server); break;
    case COCO80_NET_MSG_RUN: rc = c8_process_run(server); break;
    case COCO80_NET_MSG_END: rc = c8_process_end(server); break;
    default: rc = COCO80_NET_ERR_TYPE; break;
    }
    if (rc == COCO80_NET_OK && server->command_released == 0U) {
        server->expected_sequence += 1U;
        c8_reset_rx(server);
    }
    return rc;
}

static void c8_fail_close(c8_net_server_t *server, int error)
{
    if (server->pcb != NULL && server->connection_open != 0U &&
        coco80_net_hash_nonzero(server->rx_header.binding_sha256)) {
        (void)c8_send_frame(COCO80_NET_MSG_ERROR, NULL, 0U, 0U, 0U,
                            1U, (uint32_t)(-error));
    }
    xil_printf("COCO80_NET FAIL error=%d phase=%lu sequence=%lu\r\n", error,
               (unsigned long)server->phase,
               (unsigned long)server->expected_sequence);
    if (server->pcb != NULL) {
        tcp_arg(server->pcb, NULL);
        tcp_recv(server->pcb, NULL);
        tcp_sent(server->pcb, NULL);
        tcp_err(server->pcb, NULL);
        tcp_abort(server->pcb);
    }
    server->pcb = NULL;
    server->connection_open = 0U;
    c8_reset_session(server);
}

int main(void)
{
    struct tcp_pcb *listener;
    ip_addr_t ip, mask, gateway;
    unsigned char mac[6] = {0x02U, 0x00U, 0x00U, 0x00U, 0x80U, 0x05U};
    int rc;
    memset(&c8_server, 0, sizeof(c8_server));
    if (!c8_validate_dma_memory()) {
        xil_printf("COCO80_NET FAIL DMA memory is not low-DDR/64B aligned\r\n");
        return 1;
    }
    rc = coco80_net_platform_initialize();
    if (rc != 0) {
        xil_printf("COCO80_NET FAIL platform=%d\r\n", rc);
        return 1;
    }
    rc = coco80_mc_set_inner_shareable_region(
        c8_parameter_package, sizeof(c8_parameter_package));
    if (rc == COCO80_TENSOR_OK) {
        rc = coco80_mc_set_inner_shareable_region(
            c8_input_chunk, sizeof(c8_input_chunk));
    }
    if (rc != COCO80_TENSOR_OK) {
        xil_printf("COCO80_NET FAIL inference memory=%d\r\n", rc);
        return 1;
    }
    rc = c8_start_secondary_workers();
    if (rc != 0) {
        xil_printf("COCO80_NET FAIL PSCI workers=%d status=%ld/%ld/%ld\r\n",
                   rc, (long)c8_psci_status[0], (long)c8_psci_status[1],
                   (long)c8_psci_status[2]);
        return 1;
    }
    rc = coco80_mc_controller_initialize(
        &c8_multicore, (uint64_t)COUNTS_PER_SECOND * 10U,
        c8_workspace_arena, sizeof(c8_workspace_arena));
    if (rc != COCO80_TENSOR_OK) {
        xil_printf("COCO80_NET FAIL multicore=%d\r\n", rc);
        return 1;
    }
    xil_printf("COCO80_NET multicore workers=3 ready inference_memory=inner\r\n");
    rc = c8_thermal_init();
    if (rc != 0) {
        xil_printf("COCO80_NET FAIL SysMon=%d\r\n", rc);
        return 1;
    }
    lwip_init();
    IP4_ADDR(&ip, 192U, 168U, 10U, 2U);
    IP4_ADDR(&mask, 255U, 255U, 255U, 0U);
    IP4_ADDR(&gateway, 192U, 168U, 10U, 1U);
    if (xemac_add(&c8_server.netif, &ip, &mask, &gateway, mac,
                  XPAR_XEMACPS_0_BASEADDR) == NULL) {
        xil_printf("COCO80_NET FAIL xemac_add\r\n");
        return 1;
    }
    netif_set_default(&c8_server.netif);
    netif_set_up(&c8_server.netif);
    coco80_net_platform_enable_interrupts();
    listener = tcp_new_ip_type(IPADDR_TYPE_V4);
    if (listener == NULL || tcp_bind(listener, IP_ANY_TYPE, C8_NET_PORT) != ERR_OK) {
        xil_printf("COCO80_NET FAIL tcp_bind\r\n");
        if (listener != NULL) tcp_abort(listener);
        return 1;
    }
    listener = tcp_listen_with_backlog(listener, 1U);
    if (listener == NULL) {
        xil_printf("COCO80_NET FAIL tcp_listen\r\n");
        return 1;
    }
    c8_reset_session(&c8_server);
    tcp_arg(listener, &c8_server);
    tcp_accept(listener, c8_accept);
    xil_printf("COCO80_NET READY ip=192.168.10.2 port=5001 chunk=128 non_release=1\r\n");
    for (;;) {
        c8_pump();
        if (c8_server.fatal_error != 0) {
            int error = c8_server.fatal_error;
            c8_fail_close(&c8_server, error);
        } else if (c8_server.command_ready != 0U) {
            rc = c8_process_command(&c8_server);
            if (rc != COCO80_NET_OK) {
                c8_server.error_count += 1U;
                c8_fail_close(&c8_server, rc);
            }
            c8_server.command_released = 0U;
        }
    }
}

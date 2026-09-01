/*
 * ZynqMP standalone timer/interrupt glue for the lwIP raw API.
 * Derived from the BSD-licensed Xilinx lwip211_v1_8 platform example.
 */

#include "coco80_net_platform.h"

#include "xil_exception.h"
#include "xil_io.h"
#include "xparameters.h"
#include "xparameters_ps.h"
#include "xscugic.h"
#include "xemacps.h"
#include "xttcps.h"
#include "bspconfig.h"

#include "netif/xadapter.h"

#include <stdint.h>

#define C8_INTC_DEVICE_ID XPAR_SCUGIC_SINGLE_DEVICE_ID
#define C8_TIMER_DEVICE_ID XPAR_XTTCPS_0_DEVICE_ID
#define C8_TIMER_INTERRUPT XPAR_XTTCPS_0_INTR
#define C8_INTC_CPU_BASE XPAR_SCUGIC_0_CPU_BASEADDR
#define C8_INTC_DIST_BASE XPAR_SCUGIC_0_DIST_BASEADDR
#define C8_TIMER_HZ 4U
#define C8_AFI_FS 0xFD615000U
#define C8_AFI_FS_WIDTH_MASK 0x00000300U
#define C8_AFI_FS_WIDTH_128 0x00000200U
#define C8_AFIFM_WIDTH_MASK 0x00000003U
#define C8_AFIFM_WIDTH_64 0x00000001U

static XTtcPs c8_timer;
volatile int coco80_net_tcp_fast_timer = 0;
volatile int coco80_net_tcp_slow_timer = 0;

static int c8_configure_pl_afi_widths(void)
{
    static const UINTPTR width_registers[] = {
        0xFD380000U, 0xFD380014U,
        0xFD390000U, 0xFD390014U,
        0xFD3A0000U, 0xFD3A0014U,
        0xFD3B0000U, 0xFD3B0014U,
    };
    uint32_t value;
    uint32_t index;

    /* The generic QSPI firmware leaves HP0..HP3 at their 128-bit reset
     * width.  The signed-off r5 design connects four 64-bit AXI DMA masters,
     * and the XSA psu_init handoff programs AFIFM2..5 accordingly.  Apply the
     * same static interface contract before any PL DMA can run. */
    value = Xil_In32(C8_AFI_FS);
    Xil_Out32(C8_AFI_FS,
              (value & ~C8_AFI_FS_WIDTH_MASK) | C8_AFI_FS_WIDTH_128);
    for (index = 0U;
         index < sizeof(width_registers) / sizeof(width_registers[0]);
         ++index) {
        value = Xil_In32(width_registers[index]);
        Xil_Out32(width_registers[index],
                  (value & ~C8_AFIFM_WIDTH_MASK) | C8_AFIFM_WIDTH_64);
    }
    __asm__ volatile("dsb sy" ::: "memory");
    if ((Xil_In32(C8_AFI_FS) & C8_AFI_FS_WIDTH_MASK) !=
        C8_AFI_FS_WIDTH_128) {
        return -1;
    }
    for (index = 0U;
         index < sizeof(width_registers) / sizeof(width_registers[0]);
         ++index) {
        if ((Xil_In32(width_registers[index]) & C8_AFIFM_WIDTH_MASK) !=
            C8_AFIFM_WIDTH_64) {
            return -2;
        }
    }
    return 0;
}

static void c8_timer_callback(void *reference)
{
    XTtcPs *timer = (XTtcPs *)reference;
    static uint32_t odd = 1U;
    uint32_t events = XTtcPs_GetInterruptStatus(timer);
    XTtcPs_ClearInterruptStatus(timer, events);
    coco80_net_tcp_fast_timer = 1;
    odd ^= 1U;
    if (odd != 0U) {
        coco80_net_tcp_slow_timer = 1;
    }
}

int coco80_net_platform_initialize(void)
{
    XTtcPs_Config *config;
    XInterval interval;
    uint8_t prescaler;
    int status;

    status = c8_configure_pl_afi_widths();
    if (status != 0) {
        return -10 + status;
    }

    config = XTtcPs_LookupConfig(C8_TIMER_DEVICE_ID);
    if (config == NULL) {
        return -1;
    }
    status = XTtcPs_CfgInitialize(&c8_timer, config, config->BaseAddress);
    if (status != XST_SUCCESS) {
        return -2;
    }
    XTtcPs_SetOptions(
        &c8_timer, XTTCPS_OPTION_INTERVAL_MODE | XTTCPS_OPTION_WAVE_DISABLE);
    XTtcPs_CalcIntervalFromFreq(&c8_timer, C8_TIMER_HZ, &interval, &prescaler);
    XTtcPs_SetInterval(&c8_timer, interval);
    XTtcPs_SetPrescaler(&c8_timer, prescaler);

    Xil_ExceptionInit();
    status = XScuGic_DeviceInitialize(C8_INTC_DEVICE_ID);
    if (status != XST_SUCCESS) {
        return -3;
    }
    Xil_ExceptionRegisterHandler(
        XIL_EXCEPTION_ID_IRQ_INT,
        (Xil_ExceptionHandler)XScuGic_DeviceInterruptHandler,
        (void *)(uintptr_t)C8_INTC_DEVICE_ID);
    XScuGic_RegisterHandler(
        C8_INTC_CPU_BASE, C8_TIMER_INTERRUPT,
        (Xil_ExceptionHandler)c8_timer_callback, &c8_timer);
    XScuGic_EnableIntr(C8_INTC_DIST_BASE, C8_TIMER_INTERRUPT);
    return 0;
}

void coco80_net_platform_enable_interrupts(void)
{
    Xil_ExceptionEnableMask(XIL_EXCEPTION_IRQ);
    XScuGic_EnableIntr(C8_INTC_DIST_BASE, C8_TIMER_INTERRUPT);
    XTtcPs_EnableInterrupts(&c8_timer, XTTCPS_IXR_INTERVAL_MASK);
    XTtcPs_Start(&c8_timer);
}

void coco80_net_platform_poll(struct netif *netif)
{
#if defined(EL1_NONSECURE) && EL1_NONSECURE
    uint32_t timer_events;
    struct xemac_s *xemac;
    XEmacPs *emacps;

    /* A QSPI chain-loaded application runs at non-secure EL1.  Some Vitis
     * 2022.2 exported domains incorrectly describe the GIC distributor as
     * DDR (0x03001000), so neither the TTC nor GEM ISR is delivered.  Poll
     * the same device status and dispatch the vendor handlers here. */
    timer_events = XTtcPs_GetInterruptStatus(&c8_timer);
    if ((timer_events & XTTCPS_IXR_INTERVAL_MASK) != 0U) {
        c8_timer_callback(&c8_timer);
    }

    if (netif == NULL || netif->state == NULL) {
        return;
    }
    xemac = (struct xemac_s *)netif->state;
    if (xemac->state == NULL) {
        return;
    }
    /* Xilinx's private xemacpsif_s embeds XEmacPs as its first member. */
    emacps = (XEmacPs *)xemac->state;
    if (XEmacPs_ReadReg(emacps->Config.BaseAddress,
                        XEMACPS_ISR_OFFSET) != 0U) {
        XEmacPs_IntrHandler(emacps);
    }
#else
    /* The EL3 standalone domain receives both TTC and GEM through the GIC.
     * Calling the vendor GEM handler again from the foreground creates a
     * race with the real IRQ path and can process the same RX descriptor ring
     * concurrently.  Device polling is exclusively an EL1 fallback. */
    (void)netif;
#endif
}

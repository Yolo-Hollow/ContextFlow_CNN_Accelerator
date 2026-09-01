/*
 * Minimal AArch64 EL2 -> EL1 Non-Secure transition for the KV260 QSPI
 * U-Boot chain-loader. U-Boot disables its caches and MMU before entering
 * this shim. The standalone Core0 image is already loaded at address 0.
 *
 * Xilinx standalone boot.S sets CPUECTLR_EL1.SMPEN only on its EL3 path.
 * The QSPI firmware has already set it before U-Boot.  Verify the bit while
 * still at EL2, but never rewrite this implementation-defined register: an
 * MSR from EL2 or Non-Secure EL1 traps into the KV260 EL3 firmware.
 */

    .section .text
    .align  6
    .global _start
    .type   _start, %function

_start:
    mrs     x0, CurrentEL
    cmp     x0, #0x8              /* EL2 */
    b.eq    from_el2
    cmp     x0, #0x4              /* already EL1 */
    b.eq    from_el1
unexpected_el:
    wfe                             /* fail closed at an unexpected EL */
    b       unexpected_el

from_el2:
    bl      verify_smp

    /* Allow EL1 access to the physical counter and timer. */
    mrs     x0, cnthctl_el2
    orr     x0, x0, #0x3
    msr     cnthctl_el2, x0
    msr     cntvoff_el2, xzr

    /* Mirror the physical CPU identity into the virtual identity. */
    mrs     x0, midr_el1
    msr     vpidr_el2, x0
    mrs     x0, mpidr_el1
    msr     vmpidr_el2, x0

    /* Disable EL2 traps and enable FP/SIMD in EL1. */
    ldr     x0, =0x33ff
    msr     cptr_el2, x0
    msr     hstr_el2, xzr
    ldr     x0, =0x300000
    msr     cpacr_el1, x0

    /* EL1 starts little-endian with caches and MMU disabled. */
    ldr     x0, =0x30d00800
    msr     sctlr_el1, x0
    mov     x0, sp
    msr     sp_el1, x0
    mrs     x0, vbar_el2
    msr     vbar_el1, x0

    /* AArch64 EL1, HVC disabled. */
    ldr     x0, =0xa0000000
    msr     hcr_el2, x0
    adr     x0, from_el1
    msr     elr_el2, x0
    ldr     x0, =0x3c5            /* D/A/I/F masked, EL1h */
    msr     spsr_el2, x0
    isb
    eret

from_el1:
    /* EL2 established SMPEN before eret.  Never write CPUECTLR from EL1. */
    br      xzr                    /* standalone Core0 entry = 0 */

verify_smp:
    mrs     x0, S3_1_C15_C2_1     /* CPUECTLR_EL1 */
    tbz     x0, #6, unexpected_el  /* SMPEN must already be set */
    ret

    .size _start, . - _start

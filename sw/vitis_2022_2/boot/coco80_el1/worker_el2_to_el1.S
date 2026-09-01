/*
 * Shared A53 secondary-core transition shim for the KV260 QSPI U-Boot
 * chain-loader. It selects a private worker entry from MPIDR.Aff0 and
 * establishes the EL1 Non-Secure state expected by the standalone BSP.
 *
 * SMPEN must be set per core before the worker enables its Inner Shareable
 * DDR mapping.  The QSPI firmware already sets it before U-Boot; verify the
 * bit at EL2, but do not rewrite it because the KV260 traps that MSR to EL3.
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

    /* Preserve the physical CPU identity in the virtual identity. */
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
    ldr     x0, =0xa0000000
    msr     hcr_el2, x0

    adr     x0, from_el1
    msr     elr_el2, x0
    ldr     x0, =0x3c5            /* D/A/I/F masked, EL1h */
    msr     spsr_el2, x0
    isb
    eret

from_el1:
    bl      worker_entry
    br      x1

worker_entry:
    mrs     x0, mpidr_el1
    and     x0, x0, #0xff
    cmp     x0, #1
    b.lt    unexpected_el
    cmp     x0, #3
    b.gt    unexpected_el
    sub     x0, x0, #1
    lsl     x0, x0, #21           /* worker origins are 2 MiB apart */
    ldr     x1, =0x7d000000
    add     x1, x1, x0
    ret

verify_smp:
    mrs     x0, S3_1_C15_C2_1     /* CPUECTLR_EL1 */
    tbz     x0, #6, unexpected_el  /* SMPEN must already be set */
    ret

    .size _start, . - _start

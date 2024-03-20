
.section .text.startup
.global _start

_start:
    ldr x30, =stack_top
    mov sp, x30

    // Enable fpu (disable fpu traps)
    mrs x0, CPACR_EL1
    orr x0, x0, #0x300000
    msr CPACR_EL1, x0

    b extern_kernel_main
    hlt 0

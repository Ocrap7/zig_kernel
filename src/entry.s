
.section .text.startup
.global _start

_start:
    ldr x30, =stack_top
    mov sp, x30

    // Enable fpu (disable fpu traps)
    mrs x0, CPACR_EL1
    orr x0, x0, #0x300000
    msr CPACR_EL1, x0

    mrs x0, CurrentEL

    cmp x0, #0b0100
    beq in_el1
    cmp x0, #0b1000
    beq in_invalid
    blo in_invalid

    in_el3:
        adr x0, in_el1
        msr ELR_EL3, x0

        mov x0, xzr
        orr x0, x0, #0b1111000000 // Interrupts mask

        mov x8,     #0b00000101 // EL1 with it's specific stack
        orr x0, x0, x8

        msr SPSR_EL3, x0

        mov x0, sp
        msr SP_EL1, x0

        eret
    
    in_el1:
        b run_normal

    in_invalid:
        brk 0
        b .
    
    run_normal:

    b extern_kernel_main
    hlt 0

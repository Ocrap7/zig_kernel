
.section .text.startup
.global _start

_start:
    ldr x30, =stack_top
    mov sp, x30

    // mrs x2, HCR_EL2

    // Enable fpu (disable fpu traps)
    mrs x0, CPACR_EL1
    orr x0, x0, #0x300000
    msr CPACR_EL1, x0

    adr x0, vector_table
    msr VBAR_EL1, x0
    //msr VBAR_EL2, x0
    //msr VBAR_EL3, x0



    // msr SPSR_EL3, x0
    // mrs x0, CurrentEL
    // cmp x0, #0b1000  // remember the EL value is stored in bits 2 and 3
    // beq in_el1
    // blo in_invalid


  MOV      x0, #1                           // NS=1
  ORR      x0, x0, #(1 << 1)                // IRQ=1         IRQs routed to EL3
  ORR      x0, x0, #(1 << 2)                // FIQ=1         FIQs routed to EL3
  ORR      x0, x0, #(1 << 3)                // EA=1          SError routed to EL3
  ORR      x0, x0, #(1 << 8)                // HCE=1         HVC instructions are enabled
  ORR      x0, x0, #(1 << 10)               // RW=1          Next EL down uses AArch64
  ORR      x0, x0, #(1 << 11)               // ST=1          Secure EL1 can access CNTPS_TVAL_EL1, CNTPS_CTL_EL1 & CNTPS_CVAL_EL1
                                            // SIF=0         Secure state instruction fetches from Non-secure memory are permitted
                                            // SMD=0         SMC instructions are enabled
                                            // TWI=0         EL2, EL1 and EL0 execution of WFI instructions is not trapped to EL3
                                            // TWE=0         EL2, EL1 and EL0 execution of WFE instructions is not trapped to EL3
  //MSR      SCR_EL3, x0

    //mrs      x0, midr_el1
    //msr      vpidr_el1, x0
    //mrs      x0, mpidr_el1
    //msr      vmpidr_el2, x0

    //msr vttbr_el1, xzr
    //msr sctlr_el2, xzr


  ORR      w0, wzr, #(1 << 3)               // FMO=1
  ORR      x0, x0,  #(1 << 4)               // IMO=1
  ORR      x0, x0,  #(1 << 31)              // RW=1          NS.EL1 is AArch64
                                            // TGE=0         Entry to NS.EL1 is possible
                                            // VM=0          Stage 2 MMU disabled
  //MSR      HCR_EL2, x0

    msr sctlr_el1, xzr

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


.section .text
.global vector_table
.balign 2048
vector_table:
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .
.balign 0x80
    b .


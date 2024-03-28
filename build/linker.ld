ENTRY(_start)
SECTIONS {
    . = 0x40100000; /* RAM starts at 0x40000000 but if we ask to load the kernel there, QEMU will not load a DTB */
    .text.startup : { *(.text.startup) }
    .text : { .text }
    .data : { 
        device_tree_native = 0x40000000;
        *(.data) 
    }
    .rodata : { *(.rodata .rodata.*) }
    .bss : { *(.bss COMMON) }
    . = ALIGN(8);
    . += 2m; /* 4kB of stack memory */
    stack_top = .;
    . = ALIGN(64k);
    heap_base = .;
}

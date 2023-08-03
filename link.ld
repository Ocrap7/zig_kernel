ENTRY(kernel_start)

/* Changes to KERNEL_ADDR_OFFSET must also be made to KERNEL_PAGE_NUMBER in boot.zig */
KERNEL_ADDR_OFFSET = 0x200000000000;
KERNEL_VADDR_START = 0x200000100000;

SECTIONS {
	. = KERNEL_ADDR_OFFSET;

	.text ALIGN(4K) : AT (ADDR(.text) - KERNEL_ADDR_OFFSET) {
		*(.text)
	}

	.rodata ALIGN(4K) : AT (ADDR(.rodata) - KERNEL_ADDR_OFFSET) {
		*(.rodata)
	}

	.data ALIGN(4K) : AT (ADDR(.data) - KERNEL_ADDR_OFFSET) {
		*(.data)
	}

	.bss ALIGN(4K) : AT (ADDR(.bss) - KERNEL_ADDR_OFFSET) {
		*(COMMON)
		*(.bss)
	}

	.bss.stack ALIGN(4K) : AT (ADDR(.bss.stack) - KERNEL_ADDR_OFFSET) {
		KERNEL_STACK_START = .;
		KEEP(*(.bss.stack))
		KERNEL_STACK_END = .;
	}

	KERNEL_VADDR_END = .;
	KERNEL_PHYSADDR_END = . - KERNEL_ADDR_OFFSET;

}
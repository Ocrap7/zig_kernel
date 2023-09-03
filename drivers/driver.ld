DRIVER_ADDRR_OFFSET = 0x100000000000;

SECTIONS {
	. = DRIVER_ADDRR_OFFSET;

	.text ALIGN(4K) : AT (ADDR(.text) - DRIVER_ADDRR_OFFSET) {
		*(.text)
	}

	.rodata ALIGN(4K) : AT (ADDR(.rodata) - DRIVER_ADDRR_OFFSET) {
		*(.rodata)
	}

	.data ALIGN(4K) : AT (ADDR(.data) - DRIVER_ADDRR_OFFSET) {
		*(.data)
	}

	.bss ALIGN(4K) : AT (ADDR(.bss) - DRIVER_ADDRR_OFFSET) {
		*(COMMON)
		*(.bss)
	}

	.bss.stack ALIGN(4K) : AT (ADDR(.bss.stack) - DRIVER_ADDRR_OFFSET) {
		DRIVER_STACK_START = .;
		KEEP(*(.bss.stack))
		DRIVER_STACK_END = .;
	}

	DRIVER_VADDR_END = .;
	DRIVER_PHYSADDR_END = . - DRIVER_ADDRR_OFFSET;

}
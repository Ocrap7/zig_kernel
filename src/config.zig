const acpi = @import("./acpi/acpi.zig");
const alloc = @import("./allocator.zig");

/// Virtual address that the kernel should be loaded at
pub const KERNEL_CODE_VIRTUAL_START: usize = 0x200000000000;
/// Virtual address of kernel stack
pub const KERNEL_STACK_VIRTUAL_START: usize = 0x400000000000;
pub const KERNEL_STACK_LENGTH: usize = 1024 * 1024 * 8; // 8MB

pub const KERNEL_HEAP_START: usize = 0x500000000000;

pub const PROCESS_CODE_START: usize = 0x2000000000;
pub const PROCESS_STACK_START: usize = 0x4000000000;
pub const PROCESS_STACK_LENGTH: usize = 1024 * 1024 * 8; // 8MB
pub const PROCESS_HEAP_START: usize = 0x5000000000;

pub const KernelParams = struct {
    rsdt: *align(1) const acpi.RSDT,
    xsdt: *align(1) const acpi.XSDT,

    memory_map: []alloc.MemoryDescriptor,
    allocated: alloc.MappedPages,
    ramdisk: []const u8,
};
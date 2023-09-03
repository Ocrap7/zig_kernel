const acpi = @import("./acpi/acpi.zig");
const alloc = @import("./allocator.zig");

/// Virtual address that the kernel should be loaded at
pub const KERNEL_CODE_VIRTUAL_START: usize = 0x200000000000;
/// Virtual address of kernel stack
pub const KERNEL_STACK_VIRTUAL_START: usize = 0x400000000000;
pub const KERNEL_STACK_LENGTH: usize = 1024 * 1024 * 8; // 8MB

pub const KernelParams = struct {
    rsdt: *align(1) const acpi.RSDT,
    xsdt: *align(1) const acpi.XSDT,

    memory_map: []alloc.MemoryDescriptor,
    allocated: alloc.MappedPages,
};

/// See build.zig where this is added as a module
const KERNEL_CODE = @embedFile("kernel");

/// this is a workaround to align the code on a page boundry.
/// TODO: once embedfile is able to align, use that directly
/// as this creates two copies of the data in memory
fn kernel_code() type {
    return struct { code: [KERNEL_CODE.len:0]u8 align(4096) };
}

pub const KERNEL: kernel_code() = .{ .code = KERNEL_CODE.* };
const std = @import("std");
const uefi = @import("std").os.uefi;

const log = @import("./logger.zig");
const regs = @import("./registers.zig");
const alloc = @import("./allocator.zig");
const acpi = @import("./acpi/acpi.zig");
const gdt = @import("./gdt.zig");
const irq = @import("./irq.zig");
const devices = @import("./devices/devices.zig");

pub const KernelParams = struct {
    rsdt: *align(1) const acpi.RSDT,
    xsdt: *align(1) const acpi.XSDT,

    memory_map: []alloc.MemoryDescriptor,
    allocated: alloc.MappedPages,
};

export fn kernel_start(params: *const KernelParams) callconv(.C) void {
    gdt.init_gdt();
    irq.init_idt();

    log.set_kernel();
    devices.init_default();

    alloc.copyMemoryMap(params.memory_map, params.allocated); // We copy the memory map so that we can eventually (safely) unmap the bootloader pages
    alloc.printMemoryMap();

    const stats = alloc.MemoryStats.collect();
    stats.print();

    log.info("kernel", .{}, @src());

    regs.sti();

    while (true) {}
}

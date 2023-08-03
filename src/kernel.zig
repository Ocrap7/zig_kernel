const std = @import("std");
const uefi = @import("std").os.uefi;

const log = @import("./logger.zig");
const paging = @import("./paging.zig");
const regs = @import("./registers.zig");
const alloc = @import("./allocator.zig");
const acpi = @import("./acpi/acpi.zig");
const irq = @import("./irq.zig");
const config = @import("./config.zig");

pub const KernelParams = struct {
    rsdt_length: usize,
    rsdt: *align(1) const acpi.RSDP,
    xsdt: *align(1) const acpi.XSDT,
};

export fn kernel_start(params: *const KernelParams) callconv(.C) void {
    const write = log.getLogger().*.?.writer();

    write.print("Hello Kernel {} {*} {X}\n", .{ params.rsdt, params.xsdt, regs.getIP() }) catch {};
    for (params.rsdt.entries()) |entry| {
        write.print("RSDT Entry: {X:0>8}\n", .{entry}) catch {};
    }

    for (params.xsdt.entries()) |entry| {
        write.print("XSDT Entry: {X} {s}\n", .{ entry.signature, entry.signatureStr() }) catch {};
    }

    irq.init(params.xsdt);

    regs.sti();
    asm volatile ("int3");

    while (true) {}
    // }
}

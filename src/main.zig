const std = @import("std");
const uefi = @import("std").os.uefi;

const log = @import("./logger.zig");
const paging = @import("./paging.zig");
const regs = @import("./registers.zig");
const alloc = @import("./allocator.zig");
const acpi = @import("./acpi/acpi.zig");
const config = @import("./config.zig");
const kernel = @import("./kernel.zig");
// pub const lib = @import("./lib.zig");

// comptime {
//     _ = lib;
// }

pub export const _fltused: i32 = 0;


pub fn main() uefi.Status {
    log.init();

    switch (alloc.initMemoryMap()) {
        .Success => {},
        else => |err| {
            log.panic("Error in memory init: {}\n", .{err}, @src());
        },
    }

    regs.cli();
    regs.mask_legacy_pic();

    // write protect needs to be disabled so we can write to page table
    var cr0 = regs.CR0.get();
    cr0.write_protect = false;
    regs.CR0.set(cr0);

    paging.PageTable.setRecursiveEntry();

    var rsdp: ?*align(1) acpi.RSDP = null;

    // Find RSDP
    for (0..uefi.system_table.number_of_table_entries) |i| {
        const table = &uefi.system_table.configuration_table[i];

        if (table.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
            rsdp = @ptrCast(table.vendor_table);
            break;
        }
    }

    if (rsdp == null) log.panic("RSDP not found", .{}, @src());

    var fbs = std.io.FixedBufferStream([]const u8){ .buffer = &config.KERNEL.code, .pos = 0 };

    const headers = std.elf.Header.read(&fbs) catch {
        log.panic("Unable to read kernel elf file", .{}, @src());
    };
    var iter = headers.program_header_iterator(&fbs);

    // We map each program header into the virtual address space starting at KERNEL_CODE_VIRTUAL_START
    while (iter.next() catch {
        log.panic("Unable to get next program header", .{}, @src());
    }) |header| {
        switch (header.p_type) {
            std.elf.PT_LOAD => {
                paging.addKernelHeader(header) catch {
                    log.panic("Too many kernel headers!", .{}, @src());
                };
            },
            else => {},
        }
    }

    paging.mapKernel();
    log.info("Mapped kernel", .{}, @src());

    const kernel_params = config.KernelParams{
        .rsdt = @ptrFromInt(rsdp.?.rsdt),
        .xsdt = @ptrFromInt(rsdp.?.xsdt),

        .memory_map = alloc.getMemoryMap(),
        .allocated = alloc.getMappedPages(),
    };

    // Jumping to kernel entry with parameters
    regs.jumpIP(headers.entry, config.KERNEL_STACK_VIRTUAL_START, &kernel_params);
}

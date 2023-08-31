const std = @import("std");
const uefi = @import("std").os.uefi;

const log = @import("./logger.zig");
const paging = @import("./paging.zig");
const regs = @import("./registers.zig");
const alloc = @import("./allocator.zig");
const acpi = @import("./acpi/acpi.zig");
const kernel = @import("./kernel.zig");

pub export const _fltused: i32 = 0;

/// See build.zig where this is added as a module
const KERNEL_CODE = @embedFile("kernel");

/// this is a workaround to align the code on a page boundry.
/// TODO: once embedfile is able to align, use that directly
/// as this creates two copies of the data in memory
fn kernel_code() type {
    return struct { code: [KERNEL_CODE.len:0]u8 align(4096) };
}

const KERNEL: kernel_code() = .{ .code = KERNEL_CODE.* };

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

    var fbs = std.io.FixedBufferStream([]const u8){ .buffer = &KERNEL.code, .pos = 0 };

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
                const exe = header.p_flags & std.elf.PF_X > 0;
                _ = exe;
                const flag_write = header.p_flags & std.elf.PF_W > 0;

                var physical = &KERNEL.code[header.p_offset];

                // .bss section doesn't have file contents, so instead we allocate the amount of memory it requires
                if (header.p_filesz != header.p_memsz) {
                    const value = alloc.page_allocator.alloc(u8, header.p_memsz) catch {
                        return .OutOfResources;
                    };
                    @memset(value, 0);
                    physical = @ptrCast(value);
                }

                switch (paging.mapPages(@intFromPtr(physical), header.p_vaddr, header.p_memsz / 4097 + 1, .{ .writable = flag_write })) {
                    .success => |_| {
                        log.info("Mapped kernel page {x} {x} - {} {}", .{ header.p_offset, header.p_vaddr, header.p_memsz, flag_write }, @src());
                    },
                    else => |err| {
                        log.panic("Error mapping kernel: {}", .{err}, @src());
                    },
                }
            },
            else => {},
        }
    }

    const kernel_params = kernel.KernelParams{
        .rsdt = @ptrFromInt(rsdp.?.rsdt),
        .xsdt = @ptrFromInt(rsdp.?.xsdt),

        .memory_map = alloc.getMemoryMap(),
        .allocated = alloc.getMappedPages(),
    };

    // Jumping to kernel entry with parameters
    regs.jumpIP(headers.entry, &kernel_params);
}

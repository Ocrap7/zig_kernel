const std = @import("std");
const uefi = @import("std").os.uefi;

const log = @import("./logger.zig");
const paging = @import("./paging.zig");
const regs = @import("./registers.zig");
const alloc = @import("./allocator.zig");
const acpi = @import("./acpi/acpi.zig");
const config = @import("./config.zig");

pub export const _fltused: i32 = 0;

pub fn toUtf16(comptime ascii: []const u8) [ascii.len:0]u16 {
    const curr = [1:0]u16{ascii[0]};
    if (ascii.len == 1) return curr;
    return curr ++ toUtf16(ascii[1..]);
}

var file_protocol: *uefi.protocol.File = undefined;

var RAMDISK: [1024 * 1024]u8 = undefined;

pub fn readFile(comptime path: []const u8) []u8 {
    const utf16_path = comptime toUtf16(path);

    var file: *uefi.protocol.File = undefined;

    if (file_protocol.open(
        &file,
        &utf16_path,
        uefi.protocol.File.efi_file_mode_read,
        uefi.protocol.File.efi_file_read_only,
    ) != .Success) {
        log.panic("Can't open file '{s}'", .{path}, @src());
    }

    log.info("Hello 1", .{}, @src());

    var position = uefi.protocol.File.efi_file_position_end_of_file;
    _ = file.setPosition(position);
    _ = file.getPosition(&position);
    _ = file.setPosition(0);
    log.info("Hello 2", .{}, @src());

    // var buffer: []u8 = alloc.physical_page_allocator.alloc(u8, position) catch unreachable;
    if (file.read(&position, &RAMDISK) != .Success) {
        log.panic("Can't read file '{s}'", .{path}, @src());
    }
    log.info("Hello 3", .{}, @src());

    return RAMDISK[0..position];
}

/// See build.zig where this is added as a module
const KERNEL_CODE = @embedFile("kernel");

/// this is a workaround to align the code on a page boundry.
/// TODO: once embedfile is able to align, use that directly
/// as this creates two copies of the data in memory
fn kernel_code() type {
    return struct { code: [KERNEL_CODE.len:0]u8 align(4096) };
}

pub const KERNEL: kernel_code() = .{ .code = KERNEL_CODE.* };

pub fn main() uefi.Status {
    log.init();

    var filesystem_protocol_opt: ?*uefi.protocol.SimpleFileSystem = undefined;
    if (uefi.system_table.boot_services.?.locateProtocol(&uefi.protocol.SimpleFileSystem.guid, null, @ptrCast(&filesystem_protocol_opt)) != .Success) {
        return .Aborted;
    }

    const filesystem_protocol = filesystem_protocol_opt.?;

    if (filesystem_protocol.openVolume(&file_protocol) != .Success) {
        return .Aborted;
    }

    const ramdisk = readFile("ramdisk");
    log.info("Hello 4", .{}, @src());

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
                paging.addKernelHeader(header) catch {
                    log.panic("Too many kernel headers!", .{}, @src());
                };
            },
            else => {},
        }
    }

    paging.mapKernel(&KERNEL.code);
    log.info("Mapped kernel", .{}, @src());

    const kernel_params = config.KernelParams{
        .rsdt = @ptrFromInt(rsdp.?.rsdt),
        .xsdt = @ptrFromInt(rsdp.?.xsdt),

        .memory_map = alloc.getMemoryMap(),
        .allocated = alloc.getMappedPages(),
        .ramdisk = ramdisk,
    };

    // Jumping to kernel entry with parameters
    regs.jumpIP(headers.entry, config.KERNEL_STACK_VIRTUAL_START, &kernel_params);
}

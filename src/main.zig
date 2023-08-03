const std = @import("std");
const uefi = @import("std").os.uefi;

const log = @import("./logger.zig");
const paging = @import("./paging.zig");
const regs = @import("./registers.zig");
const alloc = @import("./allocator.zig");
const acpi = @import("./acpi/acpi.zig");
const irq = @import("./irq.zig");
const config = @import("./config.zig");

pub export const _fltused: i32 = 0;

fn stringFromMemoryType(mem_type: uefi.tables.MemoryType) []const u8 {
    const str = switch (mem_type) {
        .ReservedMemoryType => "\x1b[1;31mReservedMemoryType\x1b[39m",
        .LoaderCode => "\x1b[1;32mLoaderCode\x1b[39m",
        .LoaderData => "\x1b[1;32mLoaderData\x1b[39m",
        .BootServicesCode => "BootServicesCode",
        .BootServicesData => "BootServicesData",
        .RuntimeServicesCode => "RuntimeServicesCode",
        .RuntimeServicesData => "RuntimeServicesData",
        .ConventionalMemory => "\x1b[1;33mConventionalMemory\x1b[39m",
        .UnusableMemory => "UnusableMemory",
        .ACPIReclaimMemory => "ACPIReclaimMemory",
        .ACPIMemoryNVS => "ACPIMemoryNVS",
        .MemoryMappedIO => "MemoryMappedIO",
        .MemoryMappedIOPortSpace => "MemoryMappedIOPortSpace",
        .PalCode => "PalCode",
        .PersistentMemory => "PersistentMemory",
        .MaxMemoryType => "MaxMemoryType",
        else => "Unknown",
    };

    // return "\x1b[1;31m" ++ str ++ "\x1b[0";
    return str;
}

extern fn EfiMain() void;
// export fn EfiMain() void {}

/// Return the index into `alloc.getMemoryMap()` that contains the descriptor that describes this loaded iamge.
fn getLoaderMemoryIndex() ?usize {
    const start_address: usize = @intFromPtr(@as(*const fn () callconv(.C) void, EfiMain));
    const descs = alloc.getMemoryMap();
    for (descs, 0..) |desc, i| {
        if (start_address >= desc.physical_start and start_address < desc.physical_start + desc.number_of_pages * 4096) {
            return i;
        }
    }

    return null;
}

const KernelParams = struct {
    rsdt_length: usize,
    rsdt: *align(1) const acpi.RSDP,
    xsdt: *align(1) const acpi.XSDT,
};

pub fn main() uefi.Status {

    regs.cli();
    regs.mask_legacy_pic();

    // while (true) {}

    const con_out = uefi.system_table.con_out.?;

    log.setLogger(.{ .console = con_out });
    const write = log.getLogger().*.?.writer();

    switch (alloc.initMemoryMap()) {
        .Success => {},
        else => |err| {
            write.print("Error in memory init: {}\n", .{err}) catch {};
            return err;
        },
    }

    const mem_map = alloc.getMemoryMap();
    // for (mem_map) |desc| {
    //     write.print("{s:<16} {x:>8}: 0x{x:0>16} -> 0x{x:0>16} - {}\n", .{stringFromMemoryType(desc.type), @intFromEnum(desc.type), desc.physical_start, desc.physical_start + desc.number_of_pages * 4096, desc.number_of_pages}) catch {};
    // }

    const loader_code_index = getLoaderMemoryIndex() orelse return .OutOfResources;
    const loader_code = &mem_map[loader_code_index];

    const Rsdp align(1) = packed struct { sig: u64, checksum: u8, oemid: u48, revision: u8, rsdt: u32, length: u32, xsdt: *const acpi.XSDT };

    var rsdp : ?*align(1) Rsdp = null;

    // Find RSDP
    for (0..uefi.system_table.number_of_table_entries) |i| {
        const table = &uefi.system_table.configuration_table[i];
        if (table.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
            rsdp = @ptrCast(table.vendor_table);
            break;
        }
    }

    if (rsdp == null) @panic("RSDP not found");

    irq.init(rsdp.?.xsdt);

    // asm volatile ("1: jmp 1b");

    // Let's us map page tables
    var cr0 = regs.CR0.get();
    cr0.write_protect = false;
    regs.CR0.set(cr0);

    paging.PageTable.setRecursiveEntry();

    switch (paging.mapPages(loader_code.physical_start, config.KERNEL_CODE_VIRTUAL_START, loader_code.number_of_pages, .{})) {
        .success => |_| {},
        else => |err| {
            write.print("Error mapping kernel: {}\n", .{err}) catch {};
            return .OutOfResources;
        },
    }

    const kernel_start_ptr: *const fn (*const KernelParams) callconv(.C) void = kernel_start;
    const kernel_start_address: usize = @intFromPtr(kernel_start_ptr);
    const kernel_start_offset = kernel_start_address - loader_code.physical_start;
    const kernel_params = KernelParams{
        .rsdt_length = rsdp.?.length,
        .rsdt = @ptrFromInt(rsdp.?.rsdt),
        .xsdt = rsdp.?.xsdt,
    };

    regs.jumpIP(config.KERNEL_CODE_VIRTUAL_START + kernel_start_offset, &kernel_params);

    return .Success;
}

fn kernel_start(params: *const KernelParams) callconv(.C) void {
    const write = log.getLogger().*.?.writer();

    write.print("Hello Kernel {} {*} {X}\n", .{ params.rsdt, params.xsdt, regs.getIP() }) catch {};
    for (params.rsdt.entries()) |entry| {
        write.print("RSDT Entry: {X:0>8}\n", .{entry}) catch {};
    }

    for (params.xsdt.entries()) |entry| {
        write.print("XSDT Entry: {X} {s}\n", .{ entry.signature, entry.signatureStr() }) catch {};
    }

    // regs.sti();

    while (true) { }
    // }
}

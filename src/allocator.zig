const std = @import("std");
const uefi = std.os.uefi;
const log = @import("./logger.zig");

var MEMORY_MAP = [_]uefi.tables.MemoryDescriptor{ std.mem.zeroInit(uefi.tables.MemoryDescriptor, .{}) } ** 1024;
var MEMORY_MAP_SIZE: usize = 0;

var alloc_page: struct { descriptor: usize, offset: usize } = .{
    .descriptor = 0,
    .offset = 0,
};

pub fn getMemoryMap() []uefi.tables.MemoryDescriptor {
    return MEMORY_MAP[0..MEMORY_MAP_SIZE];
}

pub fn initMemoryMap() uefi.Status {
    const boot_services = uefi.system_table.boot_services.?;

    var size: usize = @sizeOf(@TypeOf(MEMORY_MAP));
    var key: usize = 0;
    var desc_size: usize = 0;
    var desc_ver: u32 = 0;

    switch (boot_services.getMemoryMap(&size, &MEMORY_MAP, &key, &desc_size, &desc_ver)) {
        .Success => {},
        else => |err| {
            _ = boot_services.exitBootServices(uefi.handle, key);
            return err;
        },
    }

    const num_descs = size / @sizeOf(uefi.tables.MemoryDescriptor);
    MEMORY_MAP_SIZE = num_descs;

    alloc_page.descriptor = next_usable_descriptor() orelse return .OutOfResources;

    return .Success;
}

pub const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .free = free,  
};

pub const page_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &vtable,  
};

fn next_usable_descriptor() ?usize {
    const map = getMemoryMap()[alloc_page.descriptor + 1..];
    for (map, alloc_page.descriptor+1..map.len) |desc, i| {
        switch (desc.type) {
            .BootServicesCode, .BootServicesData, .ConventionalMemory => return i,
            else => {}
        }
    }

    return null;
}

fn alloc(_: *anyopaque, n: usize, log2_align: u8, ra: usize) ?[*]u8 {
    _ = ra;
    _ = log2_align;

    // n - 1 because otherwise if n is 4096, 2 pages would be mapped
    const pages = (n - 1) / 4096 + 1;

    const desc = &getMemoryMap()[alloc_page.descriptor];

    if (pages + alloc_page.offset > desc.number_of_pages) {
        alloc_page.descriptor = next_usable_descriptor() orelse return null;
        alloc_page.offset = 0;
    }

    const used_desc = &getMemoryMap()[alloc_page.descriptor];
    const offset = used_desc.physical_start + alloc_page.offset * 4096;

    alloc_page.offset += pages;

    return @ptrFromInt(offset);
}

fn resize(
    _: *anyopaque,
    buf_unaligned: []u8,
    log2_buf_align: u8,
    new_size: usize,
    return_address: usize,
) bool {
    _ = buf_unaligned;
    _ = log2_buf_align;
    _ = return_address;
    _ = new_size;

    return false;
}

fn free(_: *anyopaque, slice: []u8, log2_buf_align: u8, return_address: usize) void {
    _ = slice;
    _ = log2_buf_align;
    _ = return_address;

    
}

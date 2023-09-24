const std = @import("std");
const uefi = std.os.uefi;
const log = @import("./logger.zig");
const config = @import("./config.zig");
const paging = @import("./paging.zig");
const schedular = @import("./schedular.zig");

/// This is temporary as the std lib doesn't have the last reserved field
pub const MemoryDescriptor = extern struct {
    type: uefi.tables.MemoryType,
    physical_start: u64,
    virtual_start: u64,
    number_of_pages: u64,
    attribute: uefi.tables.MemoryDescriptorAttribute,
    _: u64,

    fn is_usable(self: *const MemoryDescriptor) bool {
        switch (self.type) {
            .BootServicesCode, .BootServicesData, .ConventionalMemory => return true,
            else => return false,
        }
    }
};

/// Global memory map storage
var MEMORY_MAP = [_]MemoryDescriptor{std.mem.zeroInit(MemoryDescriptor, .{})} ** 1024;
/// Number of entries in the above memory map
var MEMORY_MAP_SIZE: usize = 0;

pub const MappedPages = struct {
    /// The next descriptor that can be allocated
    descriptor: usize,
    /// The next offset into the descriptor that can be allocated
    offset: usize,
};

/// Keeps track of mapped pages
var mapped_pages: MappedPages = .{
    .descriptor = 0,
    .offset = 0,
};

pub fn copyMemoryMap(map: []MemoryDescriptor, alloc_page_map: MappedPages) void {
    @memcpy(MEMORY_MAP[0..map.len], map);
    MEMORY_MAP_SIZE = map.len;

    mapped_pages = alloc_page_map;
}

pub fn getMemoryMap() []MemoryDescriptor {
    return MEMORY_MAP[0..MEMORY_MAP_SIZE];
}

pub fn getMappedPages() MappedPages {
    return mapped_pages;
}

/// Returns the memory descriptor type in a human readable string
fn stringFromMemoryType(mem_type: uefi.tables.MemoryType) []const u8 {
    const str = switch (mem_type) {
        .ReservedMemoryType => "\x1b[1;31mReservedMemoryType",
        .LoaderCode => "\x1b[1;32mLoaderCode",
        .LoaderData => "\x1b[1;32mLoaderData",
        .BootServicesCode => "\x1b[1;39mBootServicesCode",
        .BootServicesData => "\x1b[1;39mBootServicesData",
        .RuntimeServicesCode => "\x1b[1;39mRuntimeServicesCode",
        .RuntimeServicesData => "\x1b[1;39mRuntimeServicesData",
        .ConventionalMemory => "\x1b[1;33mConventionalMemory",
        .UnusableMemory => "\x1b[1;39mUnusableMemory",
        .ACPIReclaimMemory => "\x1b[1;39mACPIReclaimMemory",
        .ACPIMemoryNVS => "\x1b[1;39mACPIMemoryNVS",
        .MemoryMappedIO => "\x1b[1;39mMemoryMappedIO",
        .MemoryMappedIOPortSpace => "\x1b[1;39mMemoryMappedIOPortSpace",
        .PalCode => "\x1b[1;39mPalCode",
        .PersistentMemory => "\x1b[1;39mPersistentMemory",
        .MaxMemoryType => "\x1b[1;39mMaxMemoryType",
        else => "\x1b[1;39mUnknown",
    };

    return str;
}

/// Pretty print the global memory map. Also prints total free memory
pub fn printMemoryMap() void {
    log.print("cnt {s:<25}\x1b[39m {s:>4}: {s:<18} -> {s:<18} - pages\n", .{ "Type", "ty", "Start Addr", "End Addr" });
    const mem_map = getMemoryMap();

    for (mem_map, 0..) |desc, i| {
        log.print("{:>3} {s:<32}\x1b[39m {x:>4}: 0x{x:0>16} -> 0x{x:0>16} - {}\n", .{ i, stringFromMemoryType(desc.type), @intFromEnum(desc.type), desc.physical_start, desc.physical_start + desc.number_of_pages * 4096, desc.number_of_pages });
    }

    var n_pages: u64 = 0;
    for (mem_map) |desc| {
        if (desc.is_usable()) {
            n_pages += desc.number_of_pages;
        }
    }

    log.info("Total number of pages: {} ({} bytes, {} KB, {} MB)", .{ n_pages, n_pages * 4096, n_pages * 4096 / 1024, n_pages * 4096 / 1024 / 1024 }, @src());
}

/// Initialize the memory map with UEFI boot services. This should only be called in the bootloader, and should only be called once.
pub fn initMemoryMap() uefi.Status {
    const boot_services = uefi.system_table.boot_services.?;

    var size: usize = @sizeOf(@TypeOf(MEMORY_MAP));
    var key: usize = 0;
    var desc_size: usize = 0;
    var desc_ver: u32 = 0;

    var tmp_map: [*]uefi.tables.MemoryDescriptor = @ptrCast(&MEMORY_MAP);

    switch (boot_services.getMemoryMap(&size, tmp_map, &key, &desc_size, &desc_ver)) {
        .Success => {},
        else => |err| {
            _ = boot_services.exitBootServices(uefi.handle, key);
            return err;
        },
    }

    const num_descs = size / @sizeOf(MemoryDescriptor);
    MEMORY_MAP_SIZE = num_descs;

    mapped_pages.descriptor = next_usable_descriptor() orelse return .OutOfResources;

    return .Success;
}

/// Mapped memory statistics
pub const MemoryStats = struct {
    /// Amount of used memory in pages
    used: usize,
    /// Total memory in pages
    total: usize,

    /// Calculate the system's memory statistics
    pub fn collect() @This() {
        const mem_map = getMemoryMap();

        var n_pages: u64 = 0;
        var n_used_pages: u64 = 0;
        for (mem_map, 0..) |desc, i| {
            if (desc.is_usable()) {
                n_pages += desc.number_of_pages;
            }

            if (i < mapped_pages.descriptor) {
                n_used_pages += desc.number_of_pages;
            }
        }

        return .{
            .used = n_used_pages,
            .total = n_pages,
        };
    }

    /// Pretty print the memory statistics
    pub fn print(self: *const MemoryStats) void {
        log.info("Memory Stats: {} pages used, {} pages total ({} MB / {} MB)", .{ self.used, self.total, self.used * 4096 / 1024 / 1024, self.total * 4096 / 1024 / 1024 }, @src());
    }
};

pub const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .free = free,
};

var freed_allocations = blk: {
    var buffer: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    break :blk std.ArrayList(struct { start: u64, len: u64 }).init(fba.allocator());
};

pub const physical_page_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &vtable,
};

/// Gets the next usable memory descriptor in the memory map starting at the index `alloc_page.descriptor`
fn next_usable_descriptor() ?usize {
    const map = getMemoryMap()[mapped_pages.descriptor + 1 ..];
    for (map, mapped_pages.descriptor + 1..) |desc, i| {
        switch (desc.type) {
            .BootServicesCode, .BootServicesData, .ConventionalMemory => return i,
            else => {},
        }
    }

    return null;
}

pub fn allocPage() ?[*]u8 {
    const desc = &getMemoryMap()[mapped_pages.descriptor];

    if (mapped_pages.offset >= desc.number_of_pages) {
        mapped_pages.descriptor = next_usable_descriptor() orelse return null;
        mapped_pages.offset = 0;
    }

    const used_desc = &getMemoryMap()[mapped_pages.descriptor];
    const offset = used_desc.physical_start + mapped_pages.offset * 4096;

    mapped_pages.offset += 1;

    return @ptrFromInt(offset);
}

fn alloc(_: *anyopaque, n: usize, log2_align: u8, ra: usize) ?[*]u8 {
    _ = ra;
    _ = log2_align;

    // n - 1 because otherwise if n is 4096, 2 pages would be mapped
    const pages = (n - 1) / 4096 + 1;

    const desc = &getMemoryMap()[mapped_pages.descriptor];

    if (pages + mapped_pages.offset > desc.number_of_pages) {
        mapped_pages.descriptor = next_usable_descriptor() orelse return null;
        mapped_pages.offset = 0;
    }

    const used_desc = &getMemoryMap()[mapped_pages.descriptor];
    const offset = used_desc.physical_start + mapped_pages.offset * 4096;

    mapped_pages.offset += pages;

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

fn free(address: *anyopaque, slice: []u8, log2_buf_align: u8, return_address: usize) void {
    _ = address;
    _ = log2_buf_align;
    _ = return_address;

    freed_allocations.append(.{ .start = @intFromPtr(slice.ptr), .len = @as(u64, slice.len - 1) / 4096 + 1 }) catch {};
}

pub const virtual_vtable = std.mem.Allocator.VTable{
    .alloc = virtual_alloc,
    .resize = virtual_resize,
    .free = virtual_free,
};

const VirtualConfig = struct {
    kernel: bool,
};

var process_allocator_config = VirtualConfig{
    .kernel = false
};

var kernel_allocator_config = VirtualConfig{
    .kernel = true
};

pub const process_page_allocator = std.mem.Allocator{
    .ptr = @ptrCast(&process_allocator_config),
    .vtable = &virtual_vtable,
};

pub const kernel_page_allocator = std.mem.Allocator{
    .ptr = @ptrCast(&kernel_allocator_config),
    .vtable = &virtual_vtable,
};

var kernel_heap = config.KERNEL_HEAP_START;

pub fn remapKernelHeap(from: *paging.PageTable, into: *paging.PageTable) void {
    const l4_index = (config.KERNEL_HEAP_START >> 39) & 0x1FF;

    into.entries[l4_index] = from.entries[l4_index];
}

pub fn allocVirtualPage() *anyopaque {
    const base = if (schedular.instance().current_process) |proc|
        proc.data.context.heap_base
    else
        @as(u64, kernel_heap);

    if (schedular.instance().current_process) |proc| {
        proc.data.context.heap_base += 4096;
    } else {
        kernel_heap += 4096;
    }

    return @ptrFromInt(base);
}

fn virtual_alloc(vconfig_opaque: *anyopaque, n: usize, log2_align: u8, ra: usize) ?[*]u8 {
    const vconfig: *VirtualConfig = @ptrCast(vconfig_opaque);
    _ = ra;
    _ = log2_align;

    const pages = (n - 1) / 4096 + 1;
    const base = if (schedular.is_init() and !vconfig.kernel)
        if (schedular.instance().current_process) |proc|
            proc.data.context.heap_base
        else
            @as(u64, kernel_heap)
    else
        @as(u64, kernel_heap);

    if (schedular.is_init() and !vconfig.kernel) {
        if (schedular.instance().current_process) |proc| {
            proc.data.context.heap_base += pages * 4096;
        } else {
            kernel_heap += pages * 4096;
        }
    } else {
        kernel_heap += pages * 4096;
    }

    const pt = paging.getPageTable();
    _ = pt;

    for (0..pages) |i| {
        const physical = allocPage() orelse return null;

        const res = paging.mapPage(@intFromPtr(physical), base + 4096 * i, .{ .writable = true });
        log.info("Page {}", .{res}, @src());
    }

    return @ptrFromInt(base);
}

fn virtual_resize(
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

fn virtual_free(address: *anyopaque, slice: []u8, log2_buf_align: u8, return_address: usize) void {
    _ = slice;
    _ = address;
    _ = log2_buf_align;
    _ = return_address;
}

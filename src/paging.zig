const logger = @import("./logger.zig").getLogger();
const alloc = @import("./allocator.zig");
const assert = @import("std").debug.assert;

pub const PageTableMode = enum(u1) {
    user,
    kernel,
};

pub const PageSize = enum(u1) {
    small,
    large,
};

pub const MappingFlags = packed struct {
    present: bool = false,
    writable: bool = false,
    mode: PageTableMode = .kernel,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    size: PageSize = .small,
    global: bool = false,

    os: u3 = 0,
};

pub const PageTableEntry = packed struct {
    flags: MappingFlags = .{},

    address: u40 = 0,

    os_high: u7 = 0,

    protection: u4 = 0,
    execute_disable: bool = false,

    pub fn getAddress(self: *const PageTableEntry) usize {
        return self.address << 12;
    }

    pub fn setAddress(self: *PageTableEntry, addr: usize) void {
        self.address = @truncate(addr >> 12);
    }

    pub fn getAddress2MB(self: *PageTableEntry) usize {
        return (self.address >> 9) << 21;
    }

    pub fn setAddress2MB(self: *PageTableEntry, addr: usize) void {
        self.address = @truncate((addr >> 21) << 9);
    }

    pub fn getAddress1GB(self: *PageTableEntry) usize {
        return (self.address >> 9) << 30;
    }

    pub fn setAddress1GB(self: *PageTableEntry, addr: usize) void {
        self.address = @truncate((addr >> 30) << 9);
    }

    pub fn getPageTable(self: *PageTableEntry) *PageTable {
        return @ptrFromInt(self.getAddress());
    }
};

pub const PAGE_TABLE_ENTRIES = 512;
var RECURSIVE_INDEX: usize = 255;

pub const PageTable align(4096) = struct {
    entries: [PAGE_TABLE_ENTRIES]PageTableEntry = [_]PageTableEntry{ .{} } ** PAGE_TABLE_ENTRIES,

    /// Inserts the recusrive page entry at `RECUSRIVE_INDEX`. This should only be allowed for the top level page table.
    pub fn setRecursiveEntry() void {
        const page_table = getPageTable();
        const recursive_entry = &page_table.entries[RECURSIVE_INDEX];

        if (!recursive_entry.flags.present) {
            recursive_entry.setAddress(@intFromPtr(page_table));
            recursive_entry.flags = .{
                .present = true,
                .writable = true,
            };
        } else {
            @panic("Unable to set entry 511");
        }
    }

    /// Returns a level 1 page table entry by forming a recursive address
    pub fn level1Entry(level4: usize, level3: usize, level2: usize, level1: usize) *PageTableEntry {
        const r = RECURSIVE_INDEX;
        return @ptrFromInt((r << 39) | ((level4 & 0o777) << 30) | ((level3 & 0o777) << 21) | ((level2 & 0o777) << 12) | (level1 & 0o777) * 8);
    }

    /// Returns a level 2 page table entry by forming a recursive address
    pub fn level2Entry(level4: usize, level3: usize, level2: usize) *PageTableEntry {
        const r = RECURSIVE_INDEX;
        return @ptrFromInt((r << 39) | (r << 30) | ((level4 & 0o777) << 21) | ((level3 & 0o777) << 12) | (level2 & 0o777) * 8);
    }

    /// Returns a level 3 page table entry by forming a recursive address
    pub fn level3Entry(level4: usize, level3: usize) *PageTableEntry {
        const r = RECURSIVE_INDEX;
        return @ptrFromInt((r << 39) | (r << 30) | (r << 21) | ((level4 & 0o777) << 12) | (level3 & 0o777) * 8);
    }

    /// Returns a level 4 page table entry by forming a recursive address
    pub fn level4Entry(level4: usize) *PageTableEntry {
        const r = RECURSIVE_INDEX;
        return @ptrFromInt((r << 39) | (r << 30) | (r << 21) | (r << 12) | (level4 & 0o777) * 8);
    }
};

comptime {
    assert(@sizeOf(PageTable) == 4096);
}

/// Returns the top level page table (reads cr3 register).
pub fn getPageTable() *PageTable {
    var address = asm volatile ("mov %cr3, %rax" : [ret] "={rax}" (-> u64));

    return @ptrFromInt(address);
}

const PagingLevel = enum(u8) {
    L1 = 1,
    L2,
    L3,
    L4,
    L5,  
};

const PagingError = union(enum) {
    /// An error occured in a translation process
    translation: PagingLevel,
    /// An error occured while mapping a page
    mapping: PagingLevel,
    /// An error occured when allocating a page table during the mapping process
    allocate_page_table: PagingLevel,
    /// A page entry is not present
    not_present: PagingLevel,
    /// Expected a small page entry but found a huge page
    not_small: PagingLevel,
    /// The page entry is already in use
    already_mapped: PagingLevel,
    /// Success will contain an address (physical or virtual)
    success: usize,
};

/// Translates a virtual address to a physical address.
/// `virtual` is the virtual address to convert.
/// On success PagingError.success is returned with the physical address
pub fn translateToPhysical(virtual: usize) PagingError {
    const offset = virtual & 0xFFF;
    const l1_index = (virtual >> 12) & 0x1FF;
    const l2_index = (virtual >> 21) & 0x1FF;
    const l3_index = (virtual >> 30) & 0x1FF;
    const l4_index = (virtual >> 39) & 0x1FF;

    const l4_entry = PageTable.level4Entry(l4_index);
    if (!l4_entry.flags.present or l4_entry.flags.size != .small) return .{ .translation = .L4 };

    const l3_entry = PageTable.level3Entry(l4_index, l3_index);
    if (!l3_entry.flags.present) return .{ .not_present = .L3 };
    if (l3_entry.flags.size == .large) {
        return .{ .success = l3_entry.getAddress1GB() + (virtual & 0x3FFF_FFFF) };
    }

    const l2_entry = PageTable.level2Entry(l4_index, l3_index, l2_index);
    if (!l2_entry.flags.present) return .{ .not_present = .L2 };
    if (l2_entry.flags.size == .large) {
        return .{ .success = l2_entry.getAddress2MB() + (virtual & 0x1F_FFFF) };
    }

    const l1_entry = PageTable.level1Entry(l4_index, l3_index, l2_index, l1_index);
    if (!l1_entry.flags.present or l1_entry.flags.size != .small) return  .{ .not_present = .L1 };

    return .{ .success = l1_entry.getAddress() + offset };
}

/// Maps one page from `virtual` address to `physical` address. `flags` are written to the page table entry.
/// Page levels are resolved recursivley via `RECURSIVE_INDEX` on the 4th level page table
pub fn mapPage(physical: usize, virtual: usize, flags: MappingFlags) PagingError {
    const l1_index = (virtual >> 12) & 0x1FF;
    const l2_index = (virtual >> 21) & 0x1FF;
    const l3_index = (virtual >> 30) & 0x1FF;
    const l4_index = (virtual >> 39) & 0x1FF;

    const l4_entry = PageTable.level4Entry(l4_index);
    if (l4_entry.flags.size != .small) return .{ .mapping = .L4 };
    if (!l4_entry.flags.present) {
        const new_addr = alloc.page_allocator.create(PageTable) catch return .{ .allocate_page_table = .L4 };
        new_addr.* = .{};
        l4_entry.setAddress(@intFromPtr(new_addr));
        l4_entry.flags.present = true;
    }

    const l3_entry = PageTable.level3Entry(l4_index, l3_index);
    if (!l3_entry.flags.present) {
        const new_addr = alloc.page_allocator.create(PageTable) catch return .{ .allocate_page_table = .L3 };
        new_addr.* = .{};

        l3_entry.setAddress(@intFromPtr(new_addr));
        l3_entry.flags.present = true;
    } else if (l3_entry.flags.size != .small) {
        return .{ .not_small = .L3 };
    }

    const l2_entry = PageTable.level2Entry(l4_index, l3_index, l2_index);
    if (!l2_entry.flags.present) {
        const new_addr = alloc.page_allocator.create(PageTable) catch return .{ .allocate_page_table = .L2 };
        new_addr.* = .{};

        l2_entry.setAddress(@intFromPtr(new_addr));
        l2_entry.flags.present = true;
    } else if (l2_entry.flags.size != .small) {
        return .{ .mapping = .L2 };
    }

    const l1_entry = PageTable.level1Entry(l4_index, l3_index, l2_index, l1_index);
    if (l1_entry.flags.present) return .{ .already_mapped = .L1 };

    l1_entry.setAddress(physical);
    l1_entry.flags = flags;
    l1_entry.flags.present = true;

    return .{ .success = physical };
}

/// Maps one 2MB huge page from `virtual` address to `physical` address. `flags` are written to the page table entry.
/// Page levels are resolved recursivley via `RECURSIVE_INDEX` on the 4th level page table
pub fn mapPage2MB(physical: usize, virtual: usize, flags: MappingFlags) PagingError {
    const l2_index = (virtual >> 21) & 0x1FF;
    const l3_index = (virtual >> 30) & 0x1FF;
    const l4_index = (virtual >> 39) & 0x1FF;

    const l4_entry = PageTable.level4Entry(l4_index);
    if (!l4_entry.flags.present) {
        const new_addr = alloc.page_allocator.create(PageTable) catch return .{ .allocate_page_table = .L4 };
        new_addr.* = .{};

        l4_entry.setAddress(@intFromPtr(new_addr));
        l4_entry.flags.present = true;
    } else if (l4_entry.flags.size != .small) {
        return .{ .not_small = .L4 };
    }

    const l3_entry = PageTable.level3Entry(l4_index, l3_index);
    if (!l3_entry.flags.present) {
        const new_addr = alloc.page_allocator.create(PageTable) catch return .{ .allocate_page_table = .L3 };
        new_addr.* = .{};

        l3_entry.setAddress(@intFromPtr(new_addr));
        l3_entry.flags = .{
            .present = true,
        };
    } else if (l4_entry.flags.size != .small) {
        return .{ .not_small = .L3 };
    }

    const l2_entry = PageTable.level2Entry(l4_index, l3_index, l2_index);
    if (l2_entry.flags.present) return .{ .already_mapped = .L2 };

    l2_entry.setAddress2MB(physical);
    l2_entry.flags = flags;
    l2_entry.flags.present = true;
    l2_entry.flags.size = .large;

    return .{ .success = physical };
}

/// Maps one 1GB huge page from `virtual` address to `physical` address. `flags` are written to the page table entry.
/// Page levels are resolved recursivley via `RECURSIVE_INDEX` on the 4th level page table
pub fn mapPage1GB(physical: usize, virtual: usize, flags: MappingFlags) PagingError {
    const l3_index = (virtual >> 30) & 0x1FF;
    const l4_index = (virtual >> 39) & 0x1FF;

    const l4_entry = PageTable.level4Entry(l4_index);
    if (!l4_entry.flags.present) {
        const new_addr = alloc.page_allocator.create(PageTable) catch return .{ .allocate_page_table = .L4 };
        new_addr.* = .{};

        l4_entry.setAddress(@intFromPtr(new_addr));
        l4_entry.flags.present = true;
    } else if (l4_entry.flags.size != .small) {
        return .{ .not_small = .L4 };
    }

    const l3_entry = PageTable.level3Entry(l4_index, l3_index);
    if (l3_entry.flags.present) return .{ .already_mapped = .L3 };

    l3_entry.setAddress1GB(physical);
    l3_entry.flags = flags;
    l3_entry.flags.present = true;
    l3_entry.flags.size = .large;

    return .{ .success = physical };
}

/// Maps `count` pages using the given `physical` and `virtual` address.
/// PagingError.success is returned on success
pub fn mapPages(physical: usize, virtual: usize, count: usize, flags: MappingFlags) PagingError {
    var i: usize = 0;
    while (i < count) {
        switch (mapPage(physical + i * 4096, virtual + i * 4096, flags)) {
            .success => |_| {
                // logger.*.?.writer().print("Mapped {x} {x}\n", .{physical + i * 4096, virtual + i * 4096}) catch {};
                // logger.*.?.writer().print("Mapped {}\n", .{i}) catch {};
            },
            else => |err| return err,
        }
        i += 1;
    }

    return .{ .success = physical };
}

/// Maps `count` 2MB huge pages using the given `physical` and `virtual` address.
/// PagingError.success is returned on success
pub fn mapPages2MB(physical: usize, virtual: usize, count: usize, flags: MappingFlags) PagingError {
    var i: usize = 0;
    while (i < count) {
        switch (mapPage2MB(physical + i * 0x200000, virtual + i * 0x200000, flags)) {
            .success => |_| {},
            else => |err| return err,
        }
        i += 1;
    }

    return .{ .success = physical };
}

/// Maps `count` 1GB huge pages using the given `physical` and `virtual` address.
/// PagingError.success is returned on success
pub fn mapPages1GB(physical: usize, virtual: usize, count: usize, flags: MappingFlags) PagingError {
    var i: usize = 0;
    while (i < count) {
        switch (mapPage1GB(physical + i * 0x4000_0000, virtual + i * 0x4000_0000, flags)) {
            .success => |_| {},
            else => |err| return err,
        }
        i += 1;
    }

    return .{ .success = physical };
}
const std = @import("std");
const heap = @import("./heap.zig");
const pl = @import("./drivers/pl011.zig");
const config = @import("./config.zig");
const util = @import("./util.zig");

pub const MAIRegister = struct {
    value: u64 = 0,

    pub const DeviceType = enum(u8) {
        /// nGnRnE - gathering, reordering and early write acknowledgement are not allowed;
        nGnRnE = 0b00,
        /// gathering and reording are prohibitted, but early write acknowledgement is allowed;
        nGnRE = 0b01,
        /// gathering is prohibited, but reordering and early write acknoweldgement are allowed
        nGRE = 0b10,
        /// gathering, reording and early write acknowledgment are allowed.
        GRE = 0b11,
    };

    /// Normal memory attributes. Default initializer is no cache
    pub const NormalAttribute = packed struct(u4) {
        read: bool = false,
        write: bool = false,
        write_back: bool = true,
        non_transient: bool = false,
    };

    const Self = @This();

    pub fn setDevice(self: *Self, index: usize, device_type: DeviceType) void {
        const new_value = self.value & ~(@as(u64, std.math.boolMask(u8, true)) << @as(u6, @truncate(index * 8)));
        self.value = new_value | (@as(u64, @intFromEnum(device_type)) << @as(u6, @truncate(index * 8)));
    }

    pub fn setNormal(self: *Self, index: usize, outer: NormalAttribute, inner: NormalAttribute) void {
        const new_value = self.value & ~(@as(u64, std.math.boolMask(u8, true)) << @as(u6, @truncate(index * 8)));
        self.value = new_value |
            (@as(u64, @as(u4, @bitCast(inner))) << @as(u6, @truncate(index * 8))) |
            (@as(u64, @as(u4, @bitCast(outer))) << @as(u6, @truncate(index * 8 + 4)));
    }

    pub inline fn apply(self: Self) void {
        asm volatile ("msr MAIR_EL1, %[value]"
            :
            : [value] "r" (self.value),
        );

        asm volatile ("isb");
    }
};

pub const Granule = enum {
    @"4K",
    @"16K",
    @"64K",

    pub fn entryCount(granule: Granule, level: i8) usize {
        return switch (granule) {
            .@"4K" => switch (level) {
                -1 => 16,
                else => 512,
            },
            .@"16K" => switch (level) {
                0 => 232,
                1, 2, 3 => 2048,
                else => @compileError("Invalid level for granule"),
            },
            .@"64K" => switch (level) {
                0, 1 => 64,
                2, 3 => 8192,
                else => @compileError("Invalid level for granule"),
            },
        };
    }
};

const UpperAttributes = packed struct(u14) {
    all: u14 = 0,
};

const LowerAttributes = packed struct(u10) {
    attr_index: u3,
    ns: u1 = 0,
    ap: u2 = 0,
    sh: u2 = 0,
    access: bool = false,
    nse: bool = false,
};

pub fn PageTableEntry(comptime granule: Granule) type {
    const block_l2_n: u16 = switch (granule) {
        .@"4K" => 21,
        .@"16K" => 25,
        .@"64K" => 29,
    };

    const table_m: u16 = switch (granule) {
        .@"4K" => 12,
        .@"16K" => 14,
        .@"64K" => 16,
    };

    const block_l2_res_ty = std.builtin.Type{ .Int = .{
        .signedness = .unsigned,
        .bits = block_l2_n - 17,
    } };
    const block_l2_adr_ty = std.builtin.Type{ .Int = .{
        .signedness = .unsigned,
        .bits = 47 - block_l2_n + 1,
    } };

    const table_res_ty = std.builtin.Type{ .Int = .{
        .signedness = .unsigned,
        .bits = table_m - 12,
    } };
    const table_adr_ty = std.builtin.Type{ .Int = .{
        .signedness = .unsigned,
        .bits = 47 - table_m + 1,
    } };

    return packed union {
        invalid: packed struct(u64) { _: u64 = 0 },
        block_l1: packed struct(u64) {
            valid: bool = true,
            ty: u1 = 0b0,
            lower_attrs: LowerAttributes,
            _res2: u4 = 0,
            nT: u1 = 0,
            _res1: u13 = 0,
            address: u18,
            _res0: u2 = 0,
            upper_attrs: UpperAttributes,

            fn addressMask() u64 {
                comptime {
                    var mask = std.bit_set.IntegerBitSet(64).initEmpty();
                    mask.setRangeValue(.{ .start = @bitOffsetOf(@This(), "address"), .end = @bitOffsetOf(@This(), "_res0") }, true);
                    return mask.mask;
                }
            }

            pub fn getAddress(self: *const @This()) u64 {
                const mask = comptime addressMask();
                const addr: *const u64 = @ptrCast(self);
                return addr.* & mask;
            }

            pub fn setAddress(self: *@This(), address: u64) void {
                const mask = comptime addressMask();
                const addr: *u64 = @ptrCast(self);
                addr.* |= address & mask;
            }
        },
        block_l2: packed struct(u64) {
            valid: bool = true,
            ty: u1 = 0b0,
            lower_attrs: LowerAttributes,
            _res2: u4 = 0,
            nT: u1 = 0,
            _res1: @Type(block_l2_res_ty) = 0,
            address: @Type(block_l2_adr_ty),
            _res0: u2 = 0,
            upper_attrs: UpperAttributes,

            fn addressMask() u64 {
                comptime {
                    var mask = std.bit_set.IntegerBitSet(64).initEmpty();
                    mask.setRangeValue(.{ .start = @bitOffsetOf(@This(), "address"), .end = @bitOffsetOf(@This(), "_res0") }, true);
                    return mask.mask;
                }
            }

            pub fn getAddress(self: *const @This()) u64 {
                const mask = comptime addressMask();
                const addr: *const u64 = @ptrCast(self);
                return addr.* & mask;
            }

            pub fn setAddress(self: *@This(), address: u64) void {
                const mask = comptime addressMask();
                const addr: *u64 = @ptrCast(self);
                addr.* |= address & mask;
            }
        },
        page: packed struct(u64) {
            valid: bool = true,
            ty: u1 = 0b1,
            lower_attrs: LowerAttributes,
            _res1: @Type(table_res_ty) = 0,
            address: @Type(table_adr_ty),
            _res0: u2 = 0,
            upper_attrs: UpperAttributes,

            fn addressMask() u64 {
                comptime {
                    var mask = std.bit_set.IntegerBitSet(64).initEmpty();
                    mask.setRangeValue(.{ .start = @bitOffsetOf(@This(), "address"), .end = @bitOffsetOf(@This(), "_res0") }, true);
                    return mask.mask;
                }
            }

            pub fn getAddress(self: *const @This()) u64 {
                const mask = comptime addressMask();
                const addr: *const u64 = @ptrCast(self);
                return addr.* & mask;
            }

            pub fn setAddress(self: *@This(), address: u64) void {
                const mask = comptime addressMask();
                const addr: *u64 = @ptrCast(self);
                addr.* |= address & mask;
            }
        },
        table: packed struct(u64) {
            valid: bool = true,
            ty: u1 = 0b1,
            ignored3: u8 = 0,
            access: bool = true,
            ignored2: u1 = 0,
            _res1: @Type(table_res_ty) = 0,
            address: @Type(table_adr_ty),
            _res0: u3 = 0,
            ignored: u8 = 0,
            attrs: u5,

            fn addressMask() u64 {
                comptime {
                    var mask = std.bit_set.IntegerBitSet(64).initEmpty();
                    mask.setRangeValue(.{ .start = @bitOffsetOf(@This(), "address"), .end = @bitOffsetOf(@This(), "_res0") }, true);
                    return mask.mask;
                }
            }

            pub fn getAddress(self: *const @This()) u64 {
                const mask = comptime addressMask();
                const addr: *const u64 = @ptrCast(self);
                return addr.* & mask;
            }

            pub fn setAddress(self: *@This(), address: u64) void {
                const mask = comptime addressMask();
                const addr: *u64 = @ptrCast(self);
                addr.* |= address & mask;
            }
        },

        pub inline fn isValid(self: *const @This()) bool {
            const addr: *const u64 = @ptrCast(self);
            return addr.* & 1 > 0;
        }

        pub inline fn getTy(self: *const @This()) u64 {
            const addr: *const u64 = @ptrCast(self);
            return @as(u64, addr.* & 0b10) >> 1;
        }

        pub inline fn isBlock(self: *const @This()) bool {
            return self.getTy() == 0;
        }

        pub inline fn isTable(self: *const @This()) bool {
            return self.getTy() == 1;
        }

        pub inline fn isPage(self: *const @This()) bool {
            return self.getTy() == 1;
        }
    };
}

/// Constructs the base address of a page table from an array of indicies.
///
/// This acts on the specified granual for which the number of indicies depends on.
/// This follow the follow specificiation:
///
/// - 4K => 4 indicies of 9 bits each with an optional 5th index of 4 bits if using 52 bit paging
///     [_]u64{[l-1_index], l0_index, l1, index, l2_index, l3_index}
///     l-1_index is zero if not given
///
/// - 16K => 4 indicies with first index is 5 bits and rest are 11 bits
///     [_]u64{l0_index, l1, index, l2_index, l3_index}
///
/// - 64K => 3 indicies with first index is 10 bits and rest are 13 bits
///     [_]u64{l1, index, l2_index, l3_index}
///
pub inline fn baseFromIndicies(granule: Granule, indicies: anytype) usize {
    const argTy = @typeInfo(@TypeOf(indicies)).Array;
    if (argTy.child != u64) {
        @compileError(std.fmt.comptimePrint("Expected indicies to be an array of integers. Found {}", .{argTy.child}));
    }

    switch (granule) {
        .@"4K" => {
            if (indicies.len != 4 and indicies.len != 5) {
                @compileError(std.fmt.comptimePrint("Expected an array of 4 or 5 indicies. Found {}", .{indicies.len}));
            }

            var result: u64 = 0;
            if (indicies.len == 5) {
                result |= (indicies[0] & 0xF) << 48;
            }

            inline for (indicies.len - 4..indicies.len) |i| {
                result |= (indicies[i] & 0x1FF) << ((4 - i) * 9 + 12);
            }

            return result;
        },
        else => @compileError("Unimplemented"),
    }
}

/// Constructs an address for the specified table level at the specified granule
/// This uses the recursive mapping method to avoid mapping pages in temporarily
///
/// `indicies` contains the indicies to use when walking entries
///
pub fn levelEntry(comptime granule: Granule, comptime table_level: i8, indicies: anytype) *PageTableEntry(granule) {
    const size = comptime granule.entryCount(table_level);
    const recursive_index = size - 1;
    _ = recursive_index;
    switch (granule) {
        .@"4K" => {
            const normal_level: usize = @intCast(table_level + 1);

            if (normal_level == 0) {
                if (indicies.len != 1) {
                    @compileError("Expected 2 indicies for level -1");
                }
            } else if (indicies.len != normal_level and indicies.len != normal_level + 1) {
                @compileError(std.fmt.comptimePrint("Expected {} or {} indicies for level {}", .{ normal_level, normal_level + 1, table_level }));
            }
            // const recursive_indicies = ([_]u64{comptime granule.entryCount(-1) - 1}) ++ [_]u64{comptime granule.entryCount(0) - 1} ** 4;
            const recursive_indicies = ([_]u64{0}) ++ [_]u64{comptime granule.entryCount(0) - 1} ** 4;

            const all_indicies: [5]u64 = recursive_indicies[0..(5 - indicies.len + 1)].* ++ indicies[0 .. indicies.len - 1].*;

            const addr = baseFromIndicies(granule, all_indicies);
            const table: *PageTable(granule, table_level) = @ptrFromInt(addr);
            return &table.entries[indicies[indicies.len - 1]];
        },
        else => @compileError("Unimplemented"),
    }
}

// 111111111 111111111 111111111 111111111 000000010000

pub fn PageTable(comptime granule: Granule, comptime level: i8) type {
    const size = comptime granule.entryCount(level);
    const NextResult = if (level < 3) union(enum) { addr: usize, table: *const PageTable(granule, level + 1) } else usize;
    const NextResultMut = if (level < 3) union(enum) { addr: usize, table: *PageTable(granule, level + 1) } else usize;

    const Table = struct {
        entries: [size]PageTableEntry(granule) align(size) = [1]PageTableEntry(granule){.{ .invalid = .{} }} ** size,

        pub const LEVEL: i8 = level;
        const RECURSIVE_INDEX: usize = size - 1;

        pub fn setRecursiveEntry(self: *@This()) !void {
            const entry = &self.entries[RECURSIVE_INDEX];
            if (entry.isValid())
                return error.already_mapped;

            entry.* = .{ .table = .{ .attrs = 0, .address = 0 } };
            entry.table.setAddress(@intFromPtr(self) & ~@as(u64, 0xFFF));
        }

        pub fn nextLevel(self: *const @This(), index: usize) ?NextResult {
            const entry = self.entries[index];
            if (!entry.isValid()) {
                return null;
            }

            if (level < 3) {
                if (entry.isTable()) {
                    return .{ .table = @ptrFromInt(entry.table.getAddress()) };
                } else if (entry.isBlock()) {
                    return switch (level) {
                        1 => .{ .addr = entry.block_l1.getAddress() },
                        2 => .{ .addr = entry.block_l2.getAddress() },
                        // else => @compileError(std.fmt.comptimePrint("Invalid block level {}", .{level})),
                        else => unreachable,
                    };
                } else {
                    unreachable;
                }
            } else {
                if (entry.isPage()) {
                    return entry.page.getAddress();
                } else unreachable;
            }
        }

        pub fn nextLevelMut(self: *@This(), index: usize) ?NextResultMut {
            const entry = self.entries[index];
            if (!entry.isValid()) {
                return null;
            }

            if (level < 3) {
                if (entry.isTable()) {
                    return .{ .table = @ptrFromInt(entry.table.getAddress()) };
                } else if (entry.isBlock()) {
                    return switch (level) {
                        1 => .{ .addr = entry.block_l1.getAddress() },
                        2 => .{ .addr = entry.block_l2.getAddress() },
                        // else => @compileError(std.fmt.comptimePrint("Invalid block level {}", .{level})),
                        else => unreachable,
                    };
                } else {
                    unreachable;
                }
            } else {
                if (entry.isPage()) {
                    return entry.page.getAddress();
                } else unreachable;
            }
        }

        pub fn print(self: *const @This(), writer: anytype, indent: usize) !void {
            var i: u64 = 0;
            // try writer.print("\x1b[33mLooking at table {*}\x1b[0m\n", .{self});
            while (i < self.entries.len) : (i += 1) {
                const entry = &self.entries[i];
                if (!entry.isValid()) continue;

                for (0..indent) |_| {
                    try writer.print("  ", .{});
                }

                if (entry.isTable() and LEVEL != 3) {
                    if (i == RECURSIVE_INDEX) {
                        try writer.print("recursive page @{*}\n", .{entry});
                    } else {
                        try writer.print("table at {} @{*}\n", .{ i, entry });
                        if (level < 3) {
                            const next: *const PageTable(granule, level + 1) = @ptrFromInt(entry.table.getAddress());
                            try next.print(writer, indent + 1);
                        }
                    }
                } else if (entry.isBlock()) {
                    if (LEVEL == 1) {
                        try writer.print("block at {} @{*} => {x}", .{ i, entry, entry.block_l1.getAddress() });
                    } else if (LEVEL == 2) {
                        try writer.print("block at {} @{*} => {x}", .{ i, entry, entry.block_l2.getAddress() });
                    } else {
                        try writer.print("block at {} @{*}", .{ i, entry });
                    }
                    try writer.print("\n", .{});
                } else if (entry.isPage()) {
                    try writer.print("page at {} @{*} => {x}\n", .{ i, entry, entry.page.getAddress() });
                }
            }
        }
    };

    if (@alignOf(Table) != size) {
        @compileError(std.fmt.comptimePrint("Bad page table alignment found {} expected {}", .{ @alignOf(Table), size }));
    }

    return Table;
}

pub const PageError = error{
    already_mapped,
    already_mapped_to_bloc,
} || std.mem.Allocator.Error;

pub fn allocTable(comptime granule: Granule) !*PageTable(granule) {
    const addr = heap.physical_page_allocator.alloc(
        @sizeOf(PageTable(granule)),
        12,
        @returnAddress(),
    ) orelse return std.mem.Allocator.Error.OutOfMemory;

    return @ptrCast(@alignCast(&addr[0]));
}

const TEMP_PAGE: usize = 0x100000000000;

fn mapTmpPageRecursive(comptime granule: Granule, physical: u64) PageError!void {
    switch (granule) {
        .@"4K" => {
            // const l3_index = (TEMP_PAGE >> 12) & 0x1FF;
            // const l2_index = (TEMP_PAGE >> 21) & 0x1FF;
            // const l1_index = (TEMP_PAGE >> 30) & 0x1FF;
            const l0_index = (TEMP_PAGE >> 39) & 0x1FF;

            _ = physical;

            const l0_entry = levelEntry(granule, 0, [_]u64{l0_index});
            if (!l0_entry.isValid()) {
                const new_addr = try allocTable(granule);

                l0_entry.* = .{ .table = .{ .attrs = 0, .address = 0 } };
                l0_entry.table.setAddress(@intFromPtr(new_addr));
            }

            // const l1_entry = levelEntry(granule, 1, .{l0_index, l1_index});
            // const l2_entry = levelEntry(granule, 2, .{l0_index, l1_index, l2_index,});
            // const l3_entry = levelEntry(granule, 3, .{l0_index, l1_index, l2_index, l3_index});
        },
        else => @compileError("Unimplemented"),
    }
}

pub fn mapOnLevelRecursive(
    comptime granule: Granule,
    comptime level: i8,
    physical_allocator: std.mem.Allocator,
    options: PagingOptions,
    address: u64,
    physical: u64,
) !void {
    switch (granule) {
        .@"4K" => {
            var indicies: [5]u64 = undefined;
            comptime var i: i8 = 0;

            inline while (i <= level) : (i += 1) {
                const entry_count = comptime granule.entryCount(i);
                const l_index = (address >> @as(u6, @intCast(((3 - i) * 9 + 12)))) & (entry_count - 1);
                indicies[i] = l_index;
            }

            i = 0;

            inline while (i <= level) : (i += 1) {
                const entry = levelEntry(granule, i, indicies[0 .. @as(i8, @max(i, 0)) + 1].*);

                if (i == level) {
                    // Map page or block
                    if (entry.isValid()) {
                        return error.already_mapped;
                    }

                    var empty_val = .{
                        .upper_attrs = options.upper_attrs,
                        .lower_attrs = options.lower_attrs,
                        .address = 0,
                    };
                    empty_val.lower_attrs.access = true;

                    // 3 is the last level.
                    // We map pages on the last level
                    if (i == 3) {
                        entry.* = .{
                            .page = empty_val,
                        };

                        entry.page.setAddress(physical);
                    } else if (i == 1) { // Otherwise we map blocks
                        entry.* = .{
                            .block_l1 = empty_val,
                        };

                        entry.page.setAddress(physical);
                    } else if (i == 2) { // Otherwise we map blocks
                        entry.* = .{
                            .block_l2 = empty_val,
                        };

                        entry.block_l2.setAddress(physical);
                    } else unreachable;
                } else {
                    // Map next table

                    if (!entry.isValid()) {
                        const next_table = try physical_allocator.create(PageTable(granule, 0));

                        entry.* = .{ .table = .{ .attrs = 0, .address = 0 } };
                        entry.table.setAddress(@intFromPtr(next_table));
                    } else if (!entry.isTable()) {
                        return error.already_mapped_to_block;
                    }
                }
            }
        },
        else => @compileError("Unimplemented"),
    }
}

pub fn mapOnLevelInTable(
    comptime granule: Granule,
    comptime level: i8,
    physical_allocator: std.mem.Allocator,
    table: anytype,
    options: PagingOptions,
    address: u64,
    physical: u64,
) !void {
    const table_ty = std.meta.Child(@TypeOf(table));
    switch (granule) {
        .@"4K" => {
            if (table_ty.LEVEL != -1 and table_ty.LEVEL != 0) {
                @compileError("Expected level -1 or 0 table while mapping");
            }

            comptime var i: i8 = table_ty.LEVEL;
            var parent_table: *table_ty = table;

            inline while (i <= level) : (i += 1) {
                const entry_count = comptime granule.entryCount(i);
                const l_index = (address >> @as(u6, @intCast(((3 - i) * 9 + 12)))) & (entry_count - 1);
                const entry = &parent_table.entries[l_index];

                // @TODO: Check if we should flush tlb. Probably not since we haven't loaded the root table yet.
                if (i == level) {
                    // Map page or block
                    if (entry.isValid()) {
                        return error.already_mapped;
                    }

                    var empty_val = .{
                        .upper_attrs = options.upper_attrs,
                        .lower_attrs = options.lower_attrs,
                        .address = 0,
                    };
                    empty_val.lower_attrs.access = true;

                    // 3 is the last level.
                    // We map pages on the last level
                    if (i == 3) {
                        entry.* = .{
                            .page = empty_val,
                        };

                        entry.page.setAddress(physical);
                    } else if (i == 1) { // Otherwise we map blocks
                        entry.* = .{
                            .block_l1 = empty_val,
                        };

                        entry.page.setAddress(physical);
                    } else if (i == 2) { // Otherwise we map blocks
                        entry.* = .{
                            .block_l2 = empty_val,
                        };

                        entry.block_l2.setAddress(physical);
                    } else unreachable;

                    // asm volatile (
                    //     \\tlbi vmalle1
                    //     \\dsb sy
                    //     \\isb
                    // );

                    return;
                } else {
                    // Map next table

                    if (!entry.isValid()) {
                        const next_table = try physical_allocator.create(table_ty);

                        entry.* = .{ .table = .{ .attrs = 0, .address = 0 } };
                        entry.table.setAddress(@intFromPtr(next_table));
                        try next_table.setRecursiveEntry();
                    } else if (!entry.isTable()) {
                        return error.already_mapped_to_block;
                    }

                    parent_table = @ptrFromInt(entry.table.getAddress());
                }

                // asm volatile (
                //     \\tlbi vmalle1
                //     \\dsb sy
                //     \\isb
                // );
            }
        },
        else => @compileError("Unimplemented"),
    }
}

pub const PagingOptions = struct {
    lower_attrs: LowerAttributes,
    upper_attrs: UpperAttributes = .{},
};

fn getLevelAndStep(comptime granule: Granule, length: u64) struct { i8, u64 } {
    return switch (granule) {
        .@"4K" => blk: {
            std.debug.assert(length & 0xFFF == 0);
            if (length / util.gb(1) > 0) {
                break :blk .{ 1, util.gb(1) };
            } else if (length / util.mb(2) > 0) {
                break :blk .{ 2, util.mb(2) };
            } else {
                break :blk .{ 3, util.kb(4) };
            }
        },
        else => @compileError("Unimplemented"),
    };
}

pub fn mapRangeRecursively(
    comptime granule: Granule,
    physical_allocator: std.mem.Allocator,
    options: PagingOptions,
    virtual_start: u64,
    physical_start: u64,
    length: u64,
) !void {
    const level_and_step = getLevelAndStep(granule, length);

    std.log.info("Allocating rec range {x} => {x} of {} bytes", .{ virtual_start, physical_start, length });
    std.log.info("  Allocating rec on level {} with a step of {} bytes", .{ level_and_step[0], level_and_step[1] });

    var offset: u64 = 0;
    comptime var i = -1;
    inline while (i <= 3) : (i += 1) {
        if (level_and_step[0] == i) {
            while (offset < length) : (offset += level_and_step[1]) {
                try mapOnLevelRecursive(
                    granule,
                    i,
                    physical_allocator,
                    options,
                    virtual_start + offset,
                    physical_start + offset,
                );
            }

            return;
        }
    }
}

pub fn mapRangeInTable(
    comptime granule: Granule,
    physical_allocator: std.mem.Allocator,
    table: anytype,
    options: PagingOptions,
    virtual_start: u64,
    physical_start: u64,
    length: u64,
) !void {
    const level_and_step = getLevelAndStep(granule, length);

    std.log.info("Allocating range {x} => {x} of {} bytes", .{ virtual_start, physical_start, length });
    std.log.info("  Allocating on level {} with a step of {} bytes", .{ level_and_step[0], level_and_step[1] });

    var offset: u64 = 0;
    comptime var i = -1;
    inline while (i <= 3) : (i += 1) {
        if (level_and_step[0] == i) {
            while (offset < length) : (offset += level_and_step[1]) {
                // std.log.info("Map page {x} => {x}", .{virtual_start + offset, physical_start + offset});
                try mapOnLevelInTable(
                    granule,
                    i,
                    physical_allocator,
                    table,
                    options,
                    virtual_start + offset,
                    physical_start + offset,
                );
            }

            return;
        }
    }
}

pub const TCR = packed struct(u64) {
    t0sz: u6,
    _res0: u1,
    epd0: u1,
    igrn0: u2,
    ogrn0: u2,
    sh0: u2,
    tg0: u2,
    t1sz: u6,
    a1: u1,
    epd1: u1,
    igrn1: u2,
    ogrn1: u2,
    sh1: u2,
    tg1: u2,
    ips: u3,
    _res1: u1,
    as: u1,
    tbi0: u1,
    tbi1: u1,
    rest: u25,
};

var base_page_table: PageTable(.@"4K", 0) align(4096) = .{};

pub fn debug_print_table() !void {
    var writer = pl.PL011.writer();
    try base_page_table.print(writer, 0);
}

pub fn init() !void {
    try base_page_table.setRecursiveEntry();

    asm volatile ("dsb sy");
    const mmfr0 = asm ("mrs %[out], id_aa64mmfr0_el1"
        : [out] "=r" (-> packed struct(u64) {
            parange: u4,
            asid: u4,
            big_end: u4,
            sns_mem: u4,
            big_end_el0: u4,
            tgran16: u4,
            tgran64: u4,
            tgran4: u4,
            tgran16_s2: u4,
            tgran64_s2: u4,
            tgran4_s2: u4,
            _: u20,
          }),
    );
    std.debug.assert(mmfr0.tgran4 == 0);

    asm volatile ("msr ttbr0_el1, %[table_addr]"
        :
        : [table_addr] "r" (&base_page_table),
    );

    {
        var tcr: TCR = @bitCast(@as(u64, 0));
        // tcr.ips = @truncate(mmfr0.parange);
        tcr.ips = 0b101;
        tcr.sh0 = 0b11;
        tcr.ogrn0 = 0b01;
        tcr.igrn0 = 0b01;
        tcr.t0sz = 16;

        asm volatile ("msr TCR_EL1, %[value]"
            :
            : [value] "r" (tcr),
        );
        asm volatile ("isb");
    }

    std.log.info("Table address {*}", .{&base_page_table});

    try mapRangeInTable(
        .@"4K",
        heap.physical_page_allocator,
        &base_page_table,
        .{ .lower_attrs = .{ .attr_index = 2 } },
        0x0,
        0x0,
        util.gb(1),
    );

    std.log.info("Size: {x:0<8}", .{util.gb(1)});

    try mapRangeInTable(
        .@"4K",
        heap.physical_page_allocator,
        &base_page_table,
        .{ .lower_attrs = .{ .attr_index = 0 } },
        0x40000000,
        0x40000000,
        util.mb(20),
    );

    var writer = pl.PL011.writer();

    asm volatile (
        \\tlbi vmalle1
        \\dsb sy
        \\isb
    );

    const sctlr: u64 = 0b1000000000101;
    asm volatile (
        \\msr sctlr_el1, %[value]
        :
        : [value] "r" (sctlr),
    );

    asm volatile (
        \\isb
        \\nop
        \\nop
        \\nop
    );

    try base_page_table.print(writer, 0);
}

const testing = std.testing;
test "Level entry" {
    const ln14k = levelEntry(.@"4K", -1, [_]u64{2});
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFF010), @as(u64, @intFromPtr(ln14k)));

    const l04k1 = levelEntry(.@"4K", 0, [_]u64{2});
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFF010), @as(u64, @intFromPtr(l04k1)));
    const l04k2 = levelEntry(.@"4K", 0, [_]u64{ 0x45, 2 });
    try testing.expectEqual(@as(u64, 0xFFFFFFFE45010), @as(u64, @intFromPtr(l04k2)));

    const l14k1 = levelEntry(.@"4K", 1, [_]u64{ 0x45, 2 });
    try testing.expectEqual(@as(u64, 0xFFFFFFFE45010), @as(u64, @intFromPtr(l14k1)));
    const l14k2 = levelEntry(.@"4K", 1, [_]u64{ 0xAA, 0x45, 2 });
    try testing.expectEqual(@as(u64, 0xFFFFFD5445010), @as(u64, @intFromPtr(l14k2)));

    const l24k1 = levelEntry(.@"4K", 2, [_]u64{ 0xAA, 0x45, 2 });
    try testing.expectEqual(@as(u64, 0xFFFFFD5445010), @as(u64, @intFromPtr(l24k1)));
    const l24k2 = levelEntry(.@"4K", 2, [_]u64{ 0x45, 0xAA, 0x45, 2 });
    try testing.expectEqual(@as(u64, 0xFFF9155445010), @as(u64, @intFromPtr(l24k2)));

    const l34k1 = levelEntry(.@"4K", 3, [_]u64{ 0x45, 0xAA, 0x45, 2 });
    try testing.expectEqual(@as(u64, 0xFFF9155445010), @as(u64, @intFromPtr(l34k1)));
    const l34k2 = levelEntry(.@"4K", 3, [_]u64{ 0xAA, 0x45, 0xAA, 0x45, 2 });
    try testing.expectEqual(@as(u64, 0xF551155445010), @as(u64, @intFromPtr(l34k2)));
}

test "map on level 3 with table" {
    var allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer allocator.deinit();
    var page_table: PageTable(.@"4K", 0) = .{};

    // 0000 000001011 010010110 100101101 001011010 000000000000
    // 0          0x0B     0x96     0x12D      0x5A
    try mapOnLevelInTable(.@"4K", 3, allocator.allocator(), &page_table, .{ .lower_attrs = .{ .attr_index = 0 } }, 0x5A5A5A5A000, 0x6969000);

    const level1 = page_table.nextLevel(0x0B);
    try testing.expect(level1 != null and level1.? == .table);

    const level2 = level1.?.table.nextLevel(0x96);
    try testing.expect(level2 != null and level2.? == .table);

    const level3 = level2.?.table.nextLevel(0x12D);
    try testing.expect(level3 != null and level3.? == .table);

    const page = level3.?.table.nextLevel(0x5A);
    try testing.expect(page != null and page.? == 0x6969000);
}

test "map on level 2 with table" {
    var allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer allocator.deinit();
    var page_table: PageTable(.@"4K", 0) = .{};

    // 0000 000001011 010010110 100101101 000000000 000000000000
    // 0          0x0B     0x96     0x12D      0x00
    try mapOnLevelInTable(.@"4K", 2, allocator.allocator(), &page_table, .{ .lower_attrs = .{ .attr_index = 0 } }, 0x5A5A5A00000, 0x6969000);

    const level1 = page_table.nextLevel(0x0B);
    try testing.expect(level1 != null and level1.? == .table);

    const level2 = level1.?.table.nextLevel(0x96);
    try testing.expect(level2 != null and level2.? == .table);

    const block = level2.?.table.nextLevel(0x12D);
    std.log.warn("\nl2 {?}\n", .{block});
    try testing.expect(block != null and block.? == .addr and block.?.addr == 0x6969000);
}

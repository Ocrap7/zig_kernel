const std = @import("std");

extern const device_tree_native: Header;

pub const Header = extern struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
};

pub const TokenKind = enum(u32) { begin_node = 1, end_node, property, nop, end = 9 };

pub const Token = union(TokenKind) {
    begin_node: []const u8,
    end_node,
    property: struct {
        len: u32,
        name: []const u8,
        data: []const u8,

        pub fn isKnownProperty(self: @This()) bool {
            return standard_property_info.contains(self.name);
        }
    },
    nop,
    end,
};

pub const ReserveEntry = extern struct {
    address: u64,
    size: u64,
};

inline fn alignTo(value: u32, comptime to: u32) u32 {
    return ((value + (to - 1)) & ~(to - 1));
}

pub const Status = enum { okay, disabled, reserved, fail, fail_sss };

pub const StringList = struct { []const u8 };
pub const PropertyHandle = u32;
// pub const AddressLength = struct {address:

const standard_property_info = std.ComptimeStringMap(type, .{
    .{ "compatible", StringList },
    .{ "model", []const u8 },
    .{ "phandle", u32 },
    .{ "status", Status },
    .{ "#address-cells", u32 },
    .{ "#size-cells", u32 },
    .{ "reg", []const u8 },
    .{ "virtual-reg", u32 },
    .{ "ranges", []const u8 },
    .{ "dma-ranges", []const u8 },
    .{ "name", []const u8 },
    .{ "device_type", []const u8 },

    .{ "interrupts", []const u8 },
    .{ "interrupt-parent", PropertyHandle },
    .{ "interrupts-extended", struct { PropertyHandle, []const u8 } },
    .{ "#interrupt-cells", u32 },
    .{ "interrupt-controller", bool },
    .{ "interrupt-map", []const u8 },
    .{ "interrupt-map-mask", []const u8 },
});

pub const TokenIterator = struct {
    tree: *const DeviceTree,
    token_index: usize,

    pub fn next(self: *TokenIterator) ?Token {
        if (self.token_index >= self.tree.structs_table.len) return null;

        const val = std.mem.readIntBig(u32, @as(*const [4]u8, @ptrCast(&self.tree.structs_table[self.token_index])));
        const enum_val: TokenKind = @enumFromInt(val);

        const result = switch (enum_val) {
            .begin_node => blk: {
                const ptr: [*:0]const u8 = @ptrCast(&self.tree.structs_table[self.token_index + 1]);
                const exact_len = std.mem.len(ptr);
                const len: u32 = @truncate(exact_len / 4 + 1);

                const result = Token{ .begin_node = ptr[0..exact_len] };
                self.token_index += len;

                break :blk result;
            },
            .end_node => .end_node,
            .property => blk: {
                const len_val = std.mem.readIntBig(u32, @as(*const [4]u8, @ptrCast(&self.tree.structs_table[self.token_index + 1])));
                const name_offset_val = std.mem.readIntBig(u32, @as(*const [4]u8, @ptrCast(&self.tree.structs_table[self.token_index + 2])));
                self.token_index += 2;
                self.token_index += alignTo(len_val, 4) / 4;

                const data_ptr: [*:0]const u8 = @ptrCast(&self.tree.structs_table[self.token_index]);

                const name_ptr: [*:0]const u8 = @ptrCast(&self.tree.strings_table[name_offset_val]);
                const exact_len = std.mem.len(name_ptr);

                break :blk Token{
                    .property = .{
                        .len = len_val,
                        .name = name_ptr[0..exact_len],
                        .data = data_ptr[0..len_val],
                    },
                };
            },
            .nop => .nop,
            .end => .end,
        };

        self.token_index += 1;
        return result;
    }
};

pub var device_tree: Header = undefined;

pub const DeviceTree = struct {
    strings_table: []const u8,
    structs_table: []const u32,
    reserve_table: []const ReserveEntry,

    const Self = @This();

    pub fn init() Self {
        const fields = comptime std.meta.fields(Header);
        inline for (fields) |field| {
            @field(device_tree, field.name) = std.mem.readIntBig(u32, @as(*const [4]u8, @ptrCast(&@field(device_tree_native, field.name))));
        }

        if (device_tree.magic != 0xD00DFEED) {
            @panic("Malformed device tree blob!");
        }

        const structs_ptr: [*]align(4) const u8 = @ptrCast(@alignCast(&@as([*]align(4) const u8, @ptrCast(&device_tree_native))[device_tree.off_dt_struct]));

        const reserve_ptr: [*]const ReserveEntry = @ptrCast(@alignCast(&@as([*]align(4) const u8, @ptrCast(&device_tree_native))[device_tree.off_mem_rsvmap]));
        var reserve_len: usize = 0;
        while (reserve_ptr[reserve_len].address != 0 or reserve_ptr[reserve_len].size != 0) : (reserve_len += 1) {}

        return .{
            .strings_table = @as([*]const u8, @ptrCast(&device_tree_native))[device_tree.off_dt_strings .. device_tree.off_dt_strings + device_tree.size_dt_strings],
            .structs_table = @as([*]const u32, @ptrCast(structs_ptr))[0 .. device_tree.size_dt_struct / @sizeOf(u32)],
            .reserve_table = reserve_ptr[0..reserve_len],
        };
    }

    pub fn iterator(self: *const Self) TokenIterator {
        return .{ .tree = self, .token_index = 0 };
    }
};

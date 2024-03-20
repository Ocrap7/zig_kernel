const std = @import("std");

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
    }
};

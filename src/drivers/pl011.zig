const std = @import("std");

pub const WriteError = error{
    Error,
};

pub const PL011 = struct {
    base: [*]volatile u32 = @ptrFromInt(0x9000000),

    pub const Reg = struct {
        offset: usize,
        width: usize,

        fn init(offset: usize, width: usize) Reg {
            return .{ .offset = offset, .width = width };
        }

        pub fn widthType(comptime self: Reg) type {
            return @Type(std.builtin.Type{ .Int = std.builtin.Type.Int{ .signedness = .unsigned, .bits = self.width } });
        }

        pub const DR: Reg = init(0x00, 8);
        pub const SR: Reg = init(0x04, 8);
        pub const FR: Reg = init(0x18, 8);
        pub const ILPR: Reg = init(0x20, 8);
        pub const IBRD: Reg = init(0x24, 8);
        pub const FBRD: Reg = init(0x28, 6);
        pub const LCRH: Reg = init(0x2C, 8);
        pub const CR: Reg = init(0x30, 16);
        pub const IFLS: Reg = init(0x34, 6);
        pub const IMSC: Reg = init(0x38, 11);
        pub const RIS: Reg = init(0x3C, 11);
        pub const MIS: Reg = init(0x40, 11);
        pub const ICR: Reg = init(0x44, 11);
        pub const DMACR: Reg = init(0x48, 3);
    };

    pub fn readReg(self: *const PL011, comptime reg: Reg) reg.widthType() {
        return @intCast(self.base[reg.offset]);
    }

    pub fn writeReg(self: *const PL011, comptime reg: Reg, value: reg.widthType()) void {
        self.base[reg.offset] = value;
    }

    pub fn writer() std.io.Writer(PL011, WriteError, writeFn) {
        return .{ .context = .{} };
    }

    pub fn writeBytes(self: PL011, bytes: []const u8) void {
        for (bytes) |c| {
            self.writeReg(PL011.Reg.DR, c);
            waitPL();
            if (c == '\n') {
                self.writeReg(PL011.Reg.DR, '\r');
                waitPL();
            }
        }
    }

    fn writeFn(context: PL011, bytes: []const u8) WriteError!usize {
        context.writeBytes(bytes);

        return bytes.len;
    }
};

fn waitPL() void {
    const pl = PL011{};
    while (pl.readReg(PL011.Reg.FR) & 0b1000 > 0) {}
}
